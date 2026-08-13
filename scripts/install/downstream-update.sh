#!/bin/sh

set -eu

OFFICIAL_LATEST_API="https://api.github.com/repos/openai/codex/releases/latest"
DOWNSTREAM_LATEST_API="https://api.github.com/repos/ttys3/codex/releases/latest"
DOWNSTREAM_RELEASES_BASE="https://github.com/ttys3/codex/releases/download"
UP_TO_DATE_EXIT_CODE=10

current_exe="${CODEX_CURRENT_EXE:-}"
current_version="${CODEX_CURRENT_VERSION:-}"
current_downstream_tag="${CODEX_CURRENT_DOWNSTREAM_TAG:-}"
tmp_dir=""
exe_backup=""
resource_backup=""
new_exe_tmp=""
new_resource_tmp=""
resource_existed="false"
exe_replaced="false"
resource_replaced="false"
update_committed="false"

fail() {
  printf 'Codex downstream update failed: %s\n' "$1" >&2
  exit 1
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

restore_file() {
  backup="$1"
  destination="$2"
  destination_dir="$(dirname "$destination")"
  restore_tmp="$(mktemp "$destination_dir/.codex-restore.XXXXXX")"
  cp -p "$backup" "$restore_tmp"
  mv -f "$restore_tmp" "$destination"
}

rollback() {
  if [ "$exe_replaced" = "true" ] && [ -n "$exe_backup" ]; then
    restore_file "$exe_backup" "$current_exe" || true
  fi
  if [ "$resource_replaced" = "true" ]; then
    if [ "$resource_existed" = "true" ]; then
      restore_file "$resource_backup" "$resource_path" || true
    else
      rm -f "$resource_path" || true
    fi
  fi
}

cleanup() {
  status=$?
  trap - EXIT
  if [ "$update_committed" != "true" ]; then
    rollback
  fi
  if [ -n "$new_exe_tmp" ]; then
    rm -f "$new_exe_tmp"
  fi
  if [ -n "$new_resource_tmp" ]; then
    rm -f "$new_resource_tmp"
  fi
  if [ -n "$tmp_dir" ]; then
    rm -rf "$tmp_dir"
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

if [ "$official_update" != "true" ]; then
  current_revision="${current_downstream_tag##*-r}"
  downstream_revision="${downstream_tag##*-r}"
  if [ "$downstream_revision" -le "$current_revision" ]; then
    printf 'Codex is already up to date (%s; downstream latest is %s).\n' \
      "$current_downstream_tag" "$downstream_tag"
    exit "$UP_TO_DATE_EXIT_CODE"
  fi
fi

case "$(uname -s):$(uname -m)" in
  Linux:x86_64 | Linux:amd64)
    platform="linux-amd64"
    ;;
  Linux:aarch64 | Linux:arm64)
    platform="linux-arm64"
    ;;
  Darwin:arm64 | Darwin:aarch64)
    platform="macos-arm64"
    ;;
  *)
    fail "unsupported update platform: $(uname -s) $(uname -m)"
    ;;
esac

asset="codex-${downstream_tag}-${platform}.tar.gz"
asset_url="${DOWNSTREAM_RELEASES_BASE}/${downstream_tag}/${asset}"
checksum_url="${asset_url}.sha256"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/codex-downstream-update.XXXXXX")"
archive_path="$tmp_dir/$asset"
checksum_path="$tmp_dir/${asset}.sha256"
extract_dir="$tmp_dir/extract"
mkdir -p "$extract_dir"

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

tar -xzf "$archive_path" -C "$extract_dir"
new_exe="$extract_dir/codex"
[ -x "$new_exe" ] || fail "archive does not contain an executable codex binary"
new_version="$(version_from_binary "$new_exe" || true)"
[ "$new_version" = "$official_version" ] \
  || fail "downloaded binary reports $new_version, expected $official_version"

exe_dir="$(CDPATH='' cd -- "$(dirname "$current_exe")" && pwd -P)"
current_exe="$exe_dir/$(basename "$current_exe")"
[ -w "$exe_dir" ] || fail "executable directory is not writable: $exe_dir"

package_root="$(dirname "$exe_dir")"
if [ "$(basename "$exe_dir")" = "bin" ] && [ -f "$package_root/codex-package.json" ]; then
  resource_dir="$package_root/codex-resources"
else
  resource_dir="$exe_dir/codex-resources"
fi
resource_path="$resource_dir/bwrap"

exe_backup="$tmp_dir/current-codex.backup"
cp -p "$current_exe" "$exe_backup"
new_exe_tmp="$(mktemp "$exe_dir/.codex-update.XXXXXX")"
cp "$new_exe" "$new_exe_tmp"
chmod 0755 "$new_exe_tmp"

if [ "$platform" = "linux-amd64" ] || [ "$platform" = "linux-arm64" ]; then
  new_resource="$extract_dir/codex-resources/bwrap"
  [ -x "$new_resource" ] || fail "Linux archive does not contain executable bwrap"
  mkdir -p "$resource_dir"
  [ -w "$resource_dir" ] || fail "resource directory is not writable: $resource_dir"
  resource_backup="$tmp_dir/current-bwrap.backup"
  if [ -e "$resource_path" ]; then
    resource_existed="true"
    cp -p "$resource_path" "$resource_backup"
  fi
  new_resource_tmp="$(mktemp "$resource_dir/.bwrap-update.XXXXXX")"
  cp "$new_resource" "$new_resource_tmp"
  chmod 0755 "$new_resource_tmp"
  mv -f "$new_resource_tmp" "$resource_path"
  resource_replaced="true"
fi

mv -f "$new_exe_tmp" "$current_exe"
exe_replaced="true"
installed_version="$(version_from_binary "$current_exe" || true)"
[ "$installed_version" = "$official_version" ] \
  || fail "installed binary validation failed"

update_committed="true"
printf 'Updated Codex from %s to downstream %s (%s).\n' \
  "${current_downstream_tag:-$current_version}" "$official_version" "$downstream_tag"
