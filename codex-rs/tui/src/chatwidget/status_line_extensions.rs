//! Downstream status-line extensions for OTEL visibility and custom command output.

use super::*;
use crate::history_cell::sanitize_user_text;
use crate::workspace_command::WorkspaceCommand;
use codex_config::types::OtelConfig;
use codex_config::types::OtelExporterKind;
use codex_config::types::StatusLineCommandConfig;
use std::sync::atomic::AtomicU64;
use std::sync::atomic::Ordering;

const STATUS_LINE_OTEL_ENABLED_ENV: &str = "CODEX_STATUS_OTEL_ENABLED";
const STATUS_LINE_COMMAND_OUTPUT_BYTES_CAP: usize = 4 * 1024;
const STATUS_LINE_COMMAND_OUTPUT_CHARS_CAP: usize = 120;
const MIN_STATUS_LINE_COMMAND_TIMEOUT_MS: u64 = 50;
const MAX_STATUS_LINE_COMMAND_TIMEOUT_MS: u64 = 10_000;
const MIN_STATUS_LINE_COMMAND_REFRESH_INTERVAL_MS: u64 = 250;
const MAX_STATUS_LINE_COMMAND_REFRESH_INTERVAL_MS: u64 = 60_000;
static NEXT_STATUS_LINE_COMMAND_REQUEST_ID: AtomicU64 = AtomicU64::new(0);

impl ChatWidget {
    pub(super) fn sync_status_line_command_state(&mut self, enabled: bool, now: Instant) {
        let configured = self
            .config
            .tui_status_line_command
            .as_ref()
            .is_some_and(valid_status_line_command);
        if !enabled || !configured {
            self.clear_status_line_command_state();
            return;
        }

        let cwd = self
            .current_cwd
            .as_deref()
            .unwrap_or(self.config.cwd.as_path())
            .to_path_buf();
        if self.status_line_command_cwd.as_deref() != Some(cwd.as_path()) {
            self.clear_status_line_command_state();
            self.status_line_command_cwd = Some(cwd);
        }

        self.request_status_line_command_if_due(now);
    }

    pub(super) fn refresh_status_line_if_custom_command_due(&mut self) {
        let uses_custom_command = self
            .configured_status_line_items()
            .iter()
            .any(|id| id.parse::<StatusLineItem>() == Ok(StatusLineItem::CustomCommand));
        if uses_custom_command && self.status_line_command_should_run(Instant::now()) {
            self.refresh_status_line();
        }
    }

    pub(crate) fn set_status_line_command_output(
        &mut self,
        request_id: u64,
        result: Result<Option<String>, String>,
    ) -> bool {
        if self.status_line_command_pending_request_id != Some(request_id) {
            return false;
        }

        self.status_line_command_pending_request_id = None;
        match result {
            Ok(output) => self.status_line_command_output = output,
            Err(err) => {
                tracing::debug!(error = %err, "custom status-line command failed");
                self.status_line_command_output = None;
            }
        }

        if let Some(config) = self.config.tui_status_line_command.as_ref() {
            self.frame_requester
                .schedule_frame_in(status_line_command_refresh_interval(config));
        }
        true
    }

    fn clear_status_line_command_state(&mut self) {
        self.status_line_command_output = None;
        self.status_line_command_pending_request_id = None;
        self.status_line_command_last_requested_at = None;
        self.status_line_command_cwd = None;
    }

    fn request_status_line_command_if_due(&mut self, now: Instant) {
        if !self.status_line_command_should_run(now) {
            return;
        }
        let Some(config) = self.config.tui_status_line_command.clone() else {
            return;
        };
        let Some(runner) = self.workspace_command_runner.clone() else {
            return;
        };
        let Some(cwd) = self.status_line_command_cwd.clone() else {
            return;
        };

        let request_id = NEXT_STATUS_LINE_COMMAND_REQUEST_ID.fetch_add(1, Ordering::Relaxed);
        self.status_line_command_pending_request_id = Some(request_id);
        self.status_line_command_last_requested_at = Some(now);

        let otel_enabled = otel_exporter_configured(&self.config.otel);
        let timeout = status_line_command_timeout(&config);
        let mut command = WorkspaceCommand::new(config.command)
            .cwd(cwd)
            .env(
                STATUS_LINE_OTEL_ENABLED_ENV,
                if otel_enabled { "1" } else { "0" },
            )
            .timeout(timeout);
        command.output_bytes_cap = STATUS_LINE_COMMAND_OUTPUT_BYTES_CAP;
        let tx = self.app_event_tx.clone();
        tokio::spawn(async move {
            let result = match runner.run(command).await {
                Ok(output) if output.success() => {
                    Ok(normalize_status_line_command_output(&output.stdout))
                }
                Ok(output) => Err(format!("command exited with status {}", output.exit_code)),
                Err(err) => Err(err.to_string()),
            };
            tx.send(AppEvent::StatusLineCommandUpdated { request_id, result });
        });
    }

    fn status_line_command_should_run(&self, now: Instant) -> bool {
        let Some(config) = self
            .config
            .tui_status_line_command
            .as_ref()
            .filter(|config| valid_status_line_command(config))
        else {
            return false;
        };
        if self.status_line_command_pending_request_id.is_some() {
            return false;
        }

        self.status_line_command_last_requested_at
            .is_none_or(|last_requested_at| {
                now.saturating_duration_since(last_requested_at)
                    >= status_line_command_refresh_interval(config)
            })
    }
}

fn valid_status_line_command(config: &StatusLineCommandConfig) -> bool {
    config
        .command
        .first()
        .is_some_and(|program| !program.trim().is_empty())
}

fn status_line_command_timeout(config: &StatusLineCommandConfig) -> Duration {
    Duration::from_millis(config.timeout_ms.clamp(
        MIN_STATUS_LINE_COMMAND_TIMEOUT_MS,
        MAX_STATUS_LINE_COMMAND_TIMEOUT_MS,
    ))
}

fn status_line_command_refresh_interval(config: &StatusLineCommandConfig) -> Duration {
    Duration::from_millis(config.refresh_interval_ms.clamp(
        MIN_STATUS_LINE_COMMAND_REFRESH_INTERVAL_MS,
        MAX_STATUS_LINE_COMMAND_REFRESH_INTERVAL_MS,
    ))
}

fn normalize_status_line_command_output(stdout: &str) -> Option<String> {
    let sanitized = sanitize_user_text(stdout);
    let first_non_empty_line = sanitized.lines().find(|line| !line.trim().is_empty())?;
    let normalized = first_non_empty_line
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .chars()
        .take(STATUS_LINE_COMMAND_OUTPUT_CHARS_CAP)
        .collect::<String>();
    (!normalized.is_empty()).then_some(normalized)
}

fn otel_exporter_configured(config: &OtelConfig) -> bool {
    matches!(
        &config.exporter,
        OtelExporterKind::OtlpGrpc { endpoint, .. } if !endpoint.trim().is_empty()
    )
}

#[cfg(test)]
#[path = "status_line_extensions_tests.rs"]
mod tests;
