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
upstream tag. It then validates the patch and builds exactly these release packages:

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

Three behaviours in this workflow have already broken or silently degraded a release run.

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
