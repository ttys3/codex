# Codex status-line downstream

This public fork carries status-line extensions independently of whether the upstream project
accepts them.

## Status-line extensions

The `custom-command` item displays the first non-empty stdout line from an argv-style command.
Codex injects `CODEX_STATUS_OTEL_ENABLED=1` when the effective
`otel.exporter.otlp-grpc.endpoint` is non-empty, and `0` otherwise. The command controls whether
and how that state is displayed:

```toml
[tui]
status_line = ["model-with-reasoning", "current-dir", "git-branch", "custom-command"]

[tui.status_line_command]
command = ["sh", "-c", "if [ \"$CODEX_STATUS_OTEL_ENABLED\" = 1 ]; then printf '📡'; fi"]
timeout_ms = 1000
refresh_interval_ms = 5000
```

The command runs asynchronously in the active working directory. There is no implicit shell;
use an explicit shell argv as above when shell syntax is required. Runtime is clamped to 50 ms–10
seconds, refresh interval to 250 ms–60 seconds, captured output to 4 KiB, and displayed output to
120 characters. Empty output, failures, and timeouts are hidden. Project-local config cannot set
the command because it executes automatically; configure it in user-level config.

## Updates

Downstream release binaries embed both a build marker and their
`statusline-vX.Y.Z-rN` release tag. `codex update` always queries
`https://api.github.com/repos/openai/codex/releases/latest` first and compares that official
version with the running binary. It then queries `ttys3/codex` only when either the official
version is newer or this fork has a newer `rN` revision for the same official version.

The updater accepts a downstream release only when its `statusline-vX.Y.Z-rN` tag matches the
official version. It downloads the archive and `.sha256` sidecar for the current supported
platform exclusively from `ttys3/codex` GitHub Releases, verifies the checksum and the downloaded
binary's reported version, and installs the complete canonical package under
`$CODEX_HOME/packages/standalone/releases`. The visible `codex` and `codex-code-mode-host`
commands point through the managed `current` symlink, so switching a release is atomic.

Every package contains `codex`, `codex-code-mode-host`, pinned ripgrep, and the patched zsh fork
selected from OpenAI's official `codex-zsh` release for the target architecture. Linux packages
also contain the bundled `codex-resources/bwrap`. The updater validates all required components
and rolls back the visible commands and `current` link after any failed post-install check. It
also repairs a current-version flat install that is missing the canonical package layout.

Release r1 used a flat archive and its embedded updater only copies `codex` and Linux `bwrap`.
The package keeps top-level compatibility entrypoints so r1 can install the r2 binary; running
`codex update` once more from r2 performs the one-time migration and installs the remaining
components.

The downstream update script is embedded in the binary, so `codex update` does not fetch mutable
installer code at runtime. The app-server daemon uses the same embedded path in downstream builds
and therefore cannot overwrite the fork with OpenAI's standalone installer.

## Upstream and release policy

`downstream/statusline` is the maintained branch. `.downstream/upstream-tag` records its upstream
base. The scheduled workflow checks every six hours for the latest stable `rust-vX.Y.Z` upstream
tag. A manual run can select a prerelease tag and a downstream revision.

The workflow creates a temporary candidate branch and merges only forward from the recorded
upstream tag, judging forward by semantic version rather than by history. It then validates the
patch and builds exactly these release packages. The expected workspace-version conflict is
resolved deterministically. Up to six remaining text conflicts can be resolved by GitHub Copilot
CLI using the job-scoped `GITHUB_TOKEN` and the repository owner's Copilot allowance, capped at 30
AI credits per run. Copilot can write only the original conflict paths; unresolved or invalid
output stops the release before a candidate branch is pushed.

- `linux-amd64` (`x86_64-unknown-linux-musl`)
- `linux-arm64` (`aarch64-unknown-linux-musl`)
- `macos-arm64` (`aarch64-apple-darwin`, cross-compiled on Linux arm64 with the private Fedora 44
  toolchain image; not Developer ID-signed or notarized)

Each build compiles both `codex` and `codex-code-mode-host`. Packaging downloads OpenAI's patched
zsh manifest from the `CODEX_ZSH_RELEASE_TAG` pinned by the matching upstream release workflow;
the package builder selects and verifies the asset for the current target architecture.

Only after every validation and build job succeeds does it fast-forward `downstream/statusline`,
create a `statusline-vX.Y.Z-rN` tag, and publish a GitHub Release. Merge conflicts, test failures,
architecture mismatches, or build failures leave the maintained branch untouched. Failed
candidate branches are retained for diagnosis; successful ones are removed.

Scheduled workflows run from the repository default branch, so this fork intentionally uses
`downstream/statusline` as its default branch. The `main` branch remains available as an upstream
mirror branch.

## Release workflow pitfalls

Five behaviours in this workflow have already broken or silently degraded a release run.

Upstream builds every `rust-vX.Y.Z` tag on a throwaway commit that only rewrites the workspace
version in `codex-rs/Cargo.toml`, and never merges that commit back into `main`, which keeps the
version there at `0.0.0`. Each stable tag is therefore a leaf hanging off `main` rather than a
point on it, and no two tags share an ancestry line. Testing forward progress with
`git merge-base --is-ancestor` between two tagged commits consequently fails for *every* upstream
bump, not just for a genuine rollback, which is why the fork sat on `rust-v0.147.0` while upstream
shipped `rust-v0.148.0`. Compare versions instead. `sort -V` alone is not enough: it orders
`0.148.0` before `0.148.0-alpha.23`, the opposite of semver, so translate the prerelease `-` into
Debian's `~` before sorting. The same topology makes the two release commits collide on the version
line during every merge; upstream owns that field, so the workflow resolves it to the incoming
value once it has confirmed the fork never touched the file.

`actions/upload-artifact` runs inside the macOS cross-compile container, and the runner translates
host paths to container paths by rewriting an input's entire value as a single path. A multi-line
`path:` therefore keeps only its first line pointing inside the container, while every later line
still names a host directory that does not exist there. The upload matches a subset of the intended
files, falls back to `/` as the artifact root, and ships the archive under an `__w/_temp/` prefix
where the publish job's asset check cannot find it. `if-no-files-found: error` does not catch this,
because the first line still matches something. Keep artifact globs on a single line.

`taiki-e/install-action` accepts only `tool`, `checksum` and `fallback`. A `version:` key is not an
input: the runner logs `Unexpected input(s) 'version'` as a warning and installs whatever the
pinned action's manifest calls latest. Write `tool: sccache@0.17.0` instead, and check that the
pinned action is new enough to know that version, because the manifest ships inside the action and
an old pin cannot resolve a recently released tool.

The publish job refuses to fast-forward once `downstream/statusline` has moved past the candidate
commit. Pushing to the maintained branch while a release run is in flight aborts that run after
every build has already succeeded, which wastes the whole run and burns its revision number. Wait
for the run to finish before pushing.

`Swatinem/rust-cache` prunes each profile directory down to `build/`, `.fingerprint/` and `deps/`
before saving. The v8 build script unpacks `librusty_v8.a` into
`target/<triple>/release/gn_out/obj` and points `rustc-link-search` there, so the library is
deleted while the fingerprint asserting it was already unpacked is kept. A restored build then
links against an empty `gn_out` and fails with ``could not find native static library `rusty_v8` ``.
The build jobs therefore unpack the archive back into place after `setup-rusty-v8` runs. Clearing
the fingerprint instead also works, but forces v8 through the compiler again and costs roughly a
third of the build. Because rust-cache skips saving when the cache key already matches, `gn_out`
never enters the cache and this unpack runs every time; it takes about a second. Any crate that
writes outside `build/`, `.fingerprint/` and `deps/` within a profile directory hits the same trap.
