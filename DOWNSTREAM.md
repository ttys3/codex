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
binary's reported version, and then replaces the current binary atomically. Linux updates also
replace the bundled `codex-resources/bwrap`. A failed post-install validation rolls both files
back. The installation directory must be writable by the current user.

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
- `macos-arm64` (`aarch64-apple-darwin`, unsigned)

Only after every validation and build job succeeds does it fast-forward `downstream/statusline`,
create a `statusline-vX.Y.Z-rN` tag, and publish a GitHub Release. Merge conflicts, test failures,
architecture mismatches, or build failures leave the maintained branch untouched. Failed
candidate branches are retained for diagnosis; successful ones are removed.

Scheduled workflows run from the repository default branch, so this fork intentionally uses
`downstream/statusline` as its default branch. The `main` branch remains available as an upstream
mirror branch.
