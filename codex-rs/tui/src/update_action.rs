#[cfg(any(not(debug_assertions), test))]
use codex_install_context::InstallContext;
#[cfg(any(not(debug_assertions), test))]
use codex_install_context::InstallMethod;
#[cfg(any(not(debug_assertions), test))]
use codex_install_context::StandalonePlatform;

#[cfg(not(debug_assertions))]
const DOWNSTREAM_BUILD: bool = option_env!("CODEX_DOWNSTREAM_BUILD").is_some();
const DOWNSTREAM_RELEASE_TAG: Option<&str> = option_env!("CODEX_DOWNSTREAM_RELEASE_TAG");
const DOWNSTREAM_UPDATE_SCRIPT: &[u8] =
    include_bytes!("../../../scripts/install/downstream-update.sh");

/// Update action the CLI should perform after the TUI exits.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UpdateAction {
    /// Update via `npm install -g @openai/codex@latest`.
    NpmGlobalLatest,
    /// Update via `bun install -g @openai/codex@latest`.
    BunGlobalLatest,
    /// Update via `vp install -g @openai/codex@latest`.
    VitePlusGlobalLatest,
    /// Update via `pnpm add -g @openai/codex@latest`.
    PnpmGlobalLatest,
    /// Update via `brew upgrade codex`.
    BrewUpgrade,
    /// Update via `curl -fsSL https://chatgpt.com/codex/install.sh | CODEX_NON_INTERACTIVE=1 sh`.
    StandaloneUnix,
    /// Update via `$env:CODEX_NON_INTERACTIVE=1; irm https://chatgpt.com/codex/install.ps1 | iex`.
    StandaloneWindows,
    /// Update a downstream build from the ttys3/codex GitHub Release.
    DownstreamStandaloneUnix,
}

impl UpdateAction {
    #[cfg(any(not(debug_assertions), test))]
    pub(crate) fn from_install_context(context: &InstallContext) -> Option<Self> {
        match &context.method {
            InstallMethod::Npm => Some(UpdateAction::NpmGlobalLatest),
            InstallMethod::Bun => Some(UpdateAction::BunGlobalLatest),
            InstallMethod::VitePlus => Some(UpdateAction::VitePlusGlobalLatest),
            InstallMethod::Pnpm => Some(UpdateAction::PnpmGlobalLatest),
            InstallMethod::Brew => Some(UpdateAction::BrewUpgrade),
            InstallMethod::Standalone { platform, .. } => Some(match platform {
                StandalonePlatform::Unix => UpdateAction::StandaloneUnix,
                StandalonePlatform::Windows => UpdateAction::StandaloneWindows,
            }),
            InstallMethod::Other => None,
        }
    }

    #[cfg(any(not(debug_assertions), test))]
    fn from_install_context_for_build(
        context: &InstallContext,
        downstream_build: bool,
    ) -> Option<Self> {
        if downstream_build {
            Some(UpdateAction::DownstreamStandaloneUnix)
        } else {
            Self::from_install_context(context)
        }
    }

    /// Returns the list of command-line arguments for invoking the update.
    pub fn command_args(self) -> (&'static str, &'static [&'static str]) {
        match self {
            UpdateAction::NpmGlobalLatest => ("npm", &["install", "-g", "@openai/codex"]),
            UpdateAction::BunGlobalLatest => ("bun", &["install", "-g", "@openai/codex"]),
            UpdateAction::VitePlusGlobalLatest => ("vp", &["install", "-g", "@openai/codex"]),
            UpdateAction::PnpmGlobalLatest => ("pnpm", &["add", "-g", "@openai/codex"]),
            UpdateAction::BrewUpgrade => ("brew", &["upgrade", "--cask", "codex"]),
            UpdateAction::StandaloneUnix => (
                "sh",
                &[
                    "-c",
                    "curl -fsSL https://chatgpt.com/codex/install.sh | CODEX_NON_INTERACTIVE=1 sh",
                ],
            ),
            UpdateAction::StandaloneWindows => (
                "powershell",
                &[
                    "-ExecutionPolicy",
                    "Bypass",
                    "-c",
                    "$env:CODEX_NON_INTERACTIVE=1; irm https://chatgpt.com/codex/install.ps1 | iex",
                ],
            ),
            UpdateAction::DownstreamStandaloneUnix => ("/bin/sh", &["-s"]),
        }
    }

    /// Returns bytes to pipe to the update command's stdin, when required.
    pub fn stdin_bytes(self) -> Option<&'static [u8]> {
        match self {
            UpdateAction::DownstreamStandaloneUnix => Some(DOWNSTREAM_UPDATE_SCRIPT),
            _ => None,
        }
    }

    /// Returns whether this action uses the downstream release updater.
    pub fn is_downstream(self) -> bool {
        self == UpdateAction::DownstreamStandaloneUnix
    }

    /// Returns the downstream release tag embedded by the release workflow.
    pub fn downstream_release_tag(self) -> Option<&'static str> {
        if self.is_downstream() {
            DOWNSTREAM_RELEASE_TAG
        } else {
            None
        }
    }

    /// Returns string representation of the command-line arguments for invoking the update.
    pub fn command_str(self) -> String {
        if self.is_downstream() {
            return "codex update".to_string();
        }
        let (command, args) = self.command_args();
        shlex::try_join(std::iter::once(command).chain(args.iter().copied()))
            .unwrap_or_else(|_| format!("{command} {}", args.join(" ")))
    }
}

#[cfg(not(debug_assertions))]
pub fn get_update_action() -> Option<UpdateAction> {
    UpdateAction::from_install_context_for_build(InstallContext::current(), DOWNSTREAM_BUILD)
}

#[cfg(test)]
mod tests {
    use super::*;
    use codex_utils_absolute_path::AbsolutePathBuf;
    use pretty_assertions::assert_eq;

    #[test]
    fn maps_install_context_to_update_action() {
        let native_release_dir =
            AbsolutePathBuf::from_absolute_path(std::env::temp_dir().join("native-release"))
                .expect("temp dir path should be absolute");

        assert_eq!(
            UpdateAction::from_install_context(&InstallContext {
                method: InstallMethod::Other,
                package_layout: None,
            }),
            None
        );
        assert_eq!(
            UpdateAction::from_install_context(&InstallContext {
                method: InstallMethod::Npm,
                package_layout: None,
            }),
            Some(UpdateAction::NpmGlobalLatest)
        );
        assert_eq!(
            UpdateAction::from_install_context(&InstallContext {
                method: InstallMethod::Bun,
                package_layout: None,
            }),
            Some(UpdateAction::BunGlobalLatest)
        );
        assert_eq!(
            UpdateAction::from_install_context(&InstallContext {
                method: InstallMethod::Pnpm,
                package_layout: None,
            }),
            Some(UpdateAction::PnpmGlobalLatest)
        );
        assert_eq!(
            UpdateAction::from_install_context(&InstallContext {
                method: InstallMethod::Brew,
                package_layout: None,
            }),
            Some(UpdateAction::BrewUpgrade)
        );
        assert_eq!(
            UpdateAction::from_install_context(&InstallContext {
                method: InstallMethod::Standalone {
                    platform: StandalonePlatform::Unix,
                    release_dir: native_release_dir.clone(),
                    resources_dir: Some(native_release_dir.join("codex-resources")),
                },
                package_layout: None,
            }),
            Some(UpdateAction::StandaloneUnix)
        );
        assert_eq!(
            UpdateAction::from_install_context(&InstallContext {
                method: InstallMethod::Standalone {
                    platform: StandalonePlatform::Windows,
                    release_dir: native_release_dir.clone(),
                    resources_dir: Some(native_release_dir.join("codex-resources")),
                },
                package_layout: None,
            }),
            Some(UpdateAction::StandaloneWindows)
        );
    }

    #[test]
    fn downstream_build_ignores_official_install_method() {
        assert_eq!(
            UpdateAction::from_install_context_for_build(
                &InstallContext {
                    method: InstallMethod::Npm,
                    package_layout: None,
                },
                true,
            ),
            Some(UpdateAction::DownstreamStandaloneUnix)
        );
    }

    #[test]
    fn standalone_update_commands_rerun_latest_installer() {
        assert_eq!(
            UpdateAction::StandaloneUnix.command_args(),
            (
                "sh",
                &[
                    "-c",
                    "curl -fsSL https://chatgpt.com/codex/install.sh | CODEX_NON_INTERACTIVE=1 sh"
                ][..],
            )
        );
        assert_eq!(
            UpdateAction::StandaloneWindows.command_args(),
            (
                "powershell",
                &[
                    "-ExecutionPolicy",
                    "Bypass",
                    "-c",
                    "$env:CODEX_NON_INTERACTIVE=1; irm https://chatgpt.com/codex/install.ps1 | iex"
                ][..],
            )
        );
    }

    #[test]
    fn downstream_update_uses_embedded_script() {
        assert_eq!(
            UpdateAction::DownstreamStandaloneUnix.command_args(),
            ("/bin/sh", &["-s"][..])
        );
        let script = UpdateAction::DownstreamStandaloneUnix
            .stdin_bytes()
            .expect("downstream update should have an embedded script");
        assert!(script.starts_with(b"#!/bin/sh\n"));
        assert!(
            script
                .windows("api.github.com/repos/openai/codex".len())
                .any(|window| window == b"api.github.com/repos/openai/codex")
        );
        assert!(
            script
                .windows("github.com/ttys3/codex/releases".len())
                .any(|window| window == b"github.com/ttys3/codex/releases")
        );
        assert!(UpdateAction::NpmGlobalLatest.stdin_bytes().is_none());
        assert_eq!(
            UpdateAction::DownstreamStandaloneUnix.command_str(),
            "codex update"
        );
    }
}
