#!/bin/sh

set -eu

OFFICIAL_LATEST_API="https://api.github.com/repos/openai/codex/releases/latest"
DOWNSTREAM_LATEST_API="https://api.github.com/repos/ttys3/codex/releases/latest"
DOWNSTREAM_RELEASES_BASE="https://github.com/ttys3/codex/releases/download"
UP_TO_DATE_EXIT_CODE=10

current_exe="${CODEX_CURRENT_EXE:-}"
current_version="${CODEX_CURRENT_VERSION:-}"
current_downstream_tag="${CODEX_CURRENT_DOWNSTREAM_TAG:-}"
codex_home_dir="${CODEX_HOME:-$HOME/.codex}"
bin_dir="${CODEX_INSTALL_DIR:-$HOME/.local/bin}"
standalone_root="$codex_home_dir/packages/standalone"
releases_dir="$standalone_root/releases"
current_link="$standalone_root/current"

tmp_dir=""
stage_release=""
release_dir=""
release_created="false"
current_link_tmp=""
visible_exe_tmp=""
visible_host_tmp=""
current_link_backup=""
visible_exe_backup=""
visible_host_backup=""
current_link_existed="false"
visible_exe_existed="false"
visible_host_existed="false"
current_link_replaced="false"
visible_exe_replaced="false"
visible_host_replaced="false"
update_committed="false"

fail() {
  printf 'Codex downstream update failed: %s\n' "$1" >&2
  exit 1
}

path_exists() {
  [ -e "$1" ] || [ -L "$1" ]
}

download_text() {
  url="$1"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O - "$url"
  else
    fail "curl or wget is required"
  fi
}

download_file() {
  url="$1"
  output="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$output"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$output" "$url"
  else
    fail "curl or wget is required"
  fi
}

release_tag_from_json() {
  tr '\n' ' ' | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}

validate_plain_version() {
  printf '%s\n' "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'
}

version_is_newer() {
  latest="$1"
  current="$2"
  awk -v latest="$latest" -v current="$current" 'BEGIN {
    split(latest, latest_parts, ".")
    split(current, current_parts, ".")
    for (i = 1; i <= 3; i++) {
      if (latest_parts[i] + 0 > current_parts[i] + 0) exit 0
      if (latest_parts[i] + 0 < current_parts[i] + 0) exit 1
    }
    exit 1
  }'
}

version_from_binary() {
  "$1" --version 2>/dev/null | sed -n 's/.* \([0-9][0-9.]*\)$/\1/p' | head -n 1
}

file_sha256() {
  path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$path" | sed 's/^.*= //'
  else
    fail "sha256sum, shasum, or openssl is required"
  fi
}

resolve_path() {
  resolve_candidate="$1"
  case "$resolve_candidate" in
    /*) ;;
    *) resolve_candidate="$(pwd)/$resolve_candidate" ;;
  esac

  resolve_depth=0
  while [ -L "$resolve_candidate" ]; do
    resolve_depth=$((resolve_depth + 1))
    [ "$resolve_depth" -le 40 ] || return 1
    resolve_target="$(readlink "$resolve_candidate")" || return 1
    case "$resolve_target" in
      /*) resolve_candidate="$resolve_target" ;;
      *) resolve_candidate="$(dirname "$resolve_candidate")/$resolve_target" ;;
    esac
  done

  resolve_dir="$(CDPATH='' cd -- "$(dirname "$resolve_candidate")" && pwd -P)" \
    || return 1
  printf '%s/%s\n' "$resolve_dir" "$(basename "$resolve_candidate")"
}

package_dir_is_complete() {
  check_dir="$1"
  check_version="$2"
  check_target="$3"

  [ -f "$check_dir/codex-package.json" ] &&
    [ -x "$check_dir/bin/codex" ] &&
    [ -x "$check_dir/bin/codex-code-mode-host" ] &&
    [ -x "$check_dir/codex-path/rg" ] &&
    [ -x "$check_dir/codex-resources/zsh/bin/zsh" ] || return 1
  grep -Eq \
    "\"target\"[[:space:]]*:[[:space:]]*\"${check_target}\"" \
    "$check_dir/codex-package.json" || return 1
  grep -Eq \
    '"variant"[[:space:]]*:[[:space:]]*"codex"' \
    "$check_dir/codex-package.json" || return 1
  case "$check_target" in
    *linux*) [ -x "$check_dir/codex-resources/bwrap" ] || return 1 ;;
  esac
  [ "$(version_from_binary "$check_dir/bin/codex" || true)" = "$check_version" ]
}

installation_is_complete() {
  check_exe="$(resolve_path "$1" 2>/dev/null || true)"
  [ -n "$check_exe" ] || return 1
  check_bin_dir="$(dirname "$check_exe")"
  [ "$(basename "$check_bin_dir")" = "bin" ] || return 1
  check_package_dir="$(dirname "$check_bin_dir")"
  package_dir_is_complete "$check_package_dir" "$2" "$3"
}

restore_moved_path() {
  restore_backup="$1"
  restore_destination="$2"
  if path_exists "$restore_destination"; then
    rm -f "$restore_destination" || return 1
  fi
  if path_exists "$restore_backup"; then
    mv -f "$restore_backup" "$restore_destination" || return 1
  fi
}

rollback() {
  if [ "$visible_host_replaced" = "true" ]; then
    restore_moved_path "$visible_host_backup" "$visible_host_path" || true
  fi
  if [ "$visible_exe_replaced" = "true" ]; then
    restore_moved_path "$visible_exe_backup" "$visible_exe_path" || true
  fi
  if [ "$current_link_replaced" = "true" ]; then
    restore_moved_path "$current_link_backup" "$current_link" || true
  fi
  if [ "$release_created" = "true" ] && [ -n "$release_dir" ]; then
    rm -rf "$release_dir" || true
  fi
}

cleanup() {
  status=$?
  trap - EXIT
  if [ "$update_committed" != "true" ]; then
    rollback
  fi
  for cleanup_path in \
    "$current_link_tmp" \
    "$visible_exe_tmp" \
    "$visible_host_tmp"; do
    if [ -n "$cleanup_path" ]; then
      rm -f "$cleanup_path" || true
    fi
  done
  if [ -n "$stage_release" ]; then
    rm -rf "$stage_release" || true
  fi
  if [ -n "$tmp_dir" ]; then
    rm -rf "$tmp_dir" || true
  fi
  exit "$status"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

official_json="$(download_text "$OFFICIAL_LATEST_API")" \
  || fail "could not query the official release API"
official_tag="$(printf '%s\n' "$official_json" | release_tag_from_json)"
case "$official_tag" in
  rust-v*) official_version="${official_tag#rust-v}" ;;
  *) fail "official latest release has an unexpected tag: ${official_tag:-<empty>}" ;;
esac
validate_plain_version "$official_version" \
  || fail "official latest release is not a stable version: $official_tag"

if [ -z "$current_exe" ]; then
  current_exe="$(command -v codex 2>/dev/null || true)"
fi
[ -n "$current_exe" ] || fail "could not resolve the current Codex executable"
[ -f "$current_exe" ] || fail "current Codex executable does not exist: $current_exe"
resolved_current_exe="$(resolve_path "$current_exe" 2>/dev/null || true)"
[ -n "$resolved_current_exe" ] \
  || fail "could not resolve the current Codex executable path"

if [ -z "$current_version" ]; then
  current_version="$(version_from_binary "$current_exe" || true)"
fi
validate_plain_version "$current_version" \
  || fail "could not resolve the current Codex version"

official_update="false"
if version_is_newer "$official_version" "$current_version"; then
  official_update="true"
elif version_is_newer "$current_version" "$official_version"; then
  printf 'Local Codex %s is newer than the official latest release %s.\n' \
    "$current_version" "$official_version"
  exit "$UP_TO_DATE_EXIT_CODE"
elif [ -z "$current_downstream_tag" ]; then
  printf 'Codex is already up to date (%s; official latest is %s).\n' \
    "$current_version" "$official_version"
  exit "$UP_TO_DATE_EXIT_CODE"
fi

if [ -n "$current_downstream_tag" ]; then
  printf '%s\n' "$current_downstream_tag" \
    | grep -Eq '^statusline-v[0-9]+\.[0-9]+\.[0-9]+-r[1-9][0-9]*$' \
    || fail "current downstream release tag is invalid: $current_downstream_tag"
  current_downstream_version="${current_downstream_tag#statusline-v}"
  current_downstream_version="${current_downstream_version%-r*}"
  [ "$current_downstream_version" = "$current_version" ] \
    || fail "current downstream release tag does not match Codex $current_version"
fi

case "$(uname -s):$(uname -m)" in
  Linux:x86_64 | Linux:amd64)
    platform="linux-amd64"
    target="x86_64-unknown-linux-musl"
    ;;
  Linux:aarch64 | Linux:arm64)
    platform="linux-arm64"
    target="aarch64-unknown-linux-musl"
    ;;
  Darwin:arm64 | Darwin:aarch64)
    platform="macos-arm64"
    target="aarch64-apple-darwin"
    ;;
  *)
    fail "unsupported update platform: $(uname -s) $(uname -m)"
    ;;
esac

install_complete="false"
if installation_is_complete "$resolved_current_exe" "$current_version" "$target"; then
  install_complete="true"
fi

downstream_json="$(download_text "$DOWNSTREAM_LATEST_API")" \
  || fail "could not query the downstream release API"
downstream_tag="$(printf '%s\n' "$downstream_json" | release_tag_from_json)"
printf '%s\n' "$downstream_tag" \
  | grep -Eq '^statusline-v[0-9]+\.[0-9]+\.[0-9]+-r[1-9][0-9]*$' \
  || fail "downstream latest release has an unexpected tag: ${downstream_tag:-<empty>}"
downstream_version="${downstream_tag#statusline-v}"
downstream_version="${downstream_version%-r*}"
[ "$downstream_version" = "$official_version" ] \
  || fail "downstream build for official Codex $official_version is not available yet"

repair_install="false"
if [ "$official_update" != "true" ]; then
  current_revision="${current_downstream_tag##*-r}"
  downstream_revision="${downstream_tag##*-r}"
  if [ "$downstream_revision" -lt "$current_revision" ]; then
    printf 'Codex is already up to date (%s; downstream latest is %s).\n' \
      "$current_downstream_tag" "$downstream_tag"
    exit "$UP_TO_DATE_EXIT_CODE"
  fi
  if [ "$downstream_revision" -eq "$current_revision" ]; then
    if [ "$install_complete" = "true" ]; then
      printf 'Codex is already up to date (%s; downstream latest is %s).\n' \
        "$current_downstream_tag" "$downstream_tag"
      exit "$UP_TO_DATE_EXIT_CODE"
    fi
    repair_install="true"
  fi
fi

asset="codex-${downstream_tag}-${platform}.tar.gz"
asset_url="${DOWNSTREAM_RELEASES_BASE}/${downstream_tag}/${asset}"
checksum_url="${asset_url}.sha256"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/codex-downstream-update.XXXXXX")"
archive_path="$tmp_dir/$asset"
checksum_path="$tmp_dir/${asset}.sha256"

printf 'Downloading downstream Codex %s for %s...\n' "$official_version" "$platform"
download_file "$asset_url" "$archive_path" \
  || fail "could not download $asset_url"
download_file "$checksum_url" "$checksum_path" \
  || fail "could not download $checksum_url"

expected_digest="$(awk -v asset="$asset" '
  $2 == asset && length($1) == 64 && $1 !~ /[^0-9a-fA-F]/ {
    print tolower($1)
    exit
  }
' "$checksum_path")"
[ -n "$expected_digest" ] || fail "checksum file does not contain $asset"
actual_digest="$(file_sha256 "$archive_path")"
[ "$actual_digest" = "$expected_digest" ] || fail "archive SHA-256 mismatch"

mkdir -p "$releases_dir" "$bin_dir"
standalone_root="$(CDPATH='' cd -- "$standalone_root" && pwd -P)"
releases_dir="$standalone_root/releases"
current_link="$standalone_root/current"
bin_dir="$(CDPATH='' cd -- "$bin_dir" && pwd -P)"

release_dir="$releases_dir/${downstream_tag}-${target}"
stage_release="$releases_dir/.staging.${downstream_tag}.$$"
path_exists "$stage_release" && fail "staging path already exists: $stage_release"
mkdir "$stage_release"
tar -xzf "$archive_path" -C "$stage_release"
package_dir_is_complete "$stage_release" "$official_version" "$target" \
  || fail "downloaded archive is not a complete Codex package"

if path_exists "$release_dir"; then
  package_dir_is_complete "$release_dir" "$official_version" "$target" \
    || fail "existing downstream release directory is incomplete: $release_dir"
  rm -rf "$stage_release"
  stage_release=""
else
  mv "$stage_release" "$release_dir"
  stage_release=""
  release_created="true"
fi

current_exe_dir="$(dirname "$resolved_current_exe")"
current_package_root="$(dirname "$current_exe_dir")"
if [ "$(basename "$current_exe_dir")" = "bin" ] &&
  [ -f "$current_package_root/codex-package.json" ]; then
  visible_exe_path="$bin_dir/codex"
else
  visible_exe_path="$resolved_current_exe"
  bin_dir="$(dirname "$visible_exe_path")"
fi
visible_host_path="$bin_dir/codex-code-mode-host"
[ -w "$bin_dir" ] || fail "installation directory is not writable: $bin_dir"

current_link_tmp="$standalone_root/.current.$$"
visible_exe_tmp="$bin_dir/.codex.$$"
visible_host_tmp="$bin_dir/.codex-code-mode-host.$$"
current_link_backup="$standalone_root/.current-backup.$$"
visible_exe_backup="$bin_dir/.codex-backup.$$"
visible_host_backup="$bin_dir/.codex-code-mode-host-backup.$$"
for reserved_path in \
  "$current_link_tmp" \
  "$visible_exe_tmp" \
  "$visible_host_tmp" \
  "$current_link_backup" \
  "$visible_exe_backup" \
  "$visible_host_backup"; do
  path_exists "$reserved_path" && fail "update path already exists: $reserved_path"
done

ln -s "$release_dir" "$current_link_tmp"
ln -s "$current_link/bin/codex" "$visible_exe_tmp"
ln -s "$current_link/bin/codex-code-mode-host" "$visible_host_tmp"

if path_exists "$current_link"; then
  mv "$current_link" "$current_link_backup"
  current_link_existed="true"
fi
mv "$current_link_tmp" "$current_link"
current_link_tmp=""
current_link_replaced="true"

if path_exists "$visible_exe_path"; then
  mv "$visible_exe_path" "$visible_exe_backup"
  visible_exe_existed="true"
fi
mv "$visible_exe_tmp" "$visible_exe_path"
visible_exe_tmp=""
visible_exe_replaced="true"

if path_exists "$visible_host_path"; then
  mv "$visible_host_path" "$visible_host_backup"
  visible_host_existed="true"
fi
mv "$visible_host_tmp" "$visible_host_path"
visible_host_tmp=""
visible_host_replaced="true"

installed_version="$(version_from_binary "$visible_exe_path" || true)"
[ "$installed_version" = "$official_version" ] \
  || fail "installed binary validation failed"
[ -x "$visible_host_path" ] || fail "installed code-mode host validation failed"
installation_is_complete "$visible_exe_path" "$official_version" "$target" \
  || fail "installed Codex package validation failed"

update_committed="true"
if [ "$current_link_existed" = "true" ]; then
  rm -f "$current_link_backup" || true
fi
if [ "$visible_exe_existed" = "true" ]; then
  rm -f "$visible_exe_backup" || true
fi
if [ "$visible_host_existed" = "true" ]; then
  rm -f "$visible_host_backup" || true
fi

if [ "$repair_install" = "true" ]; then
  printf 'Repaired downstream Codex package %s (%s).\n' \
    "$official_version" "$downstream_tag"
else
  printf 'Updated Codex from %s to downstream %s (%s).\n' \
    "${current_downstream_tag:-$current_version}" "$official_version" "$downstream_tag"
fi
