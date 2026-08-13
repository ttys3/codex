use super::*;
use pretty_assertions::assert_eq;
use std::collections::HashMap;

#[test]
fn otel_exporter_requires_non_empty_grpc_endpoint() {
    let disabled = OtelConfig::default();
    let enabled = OtelConfig {
        exporter: OtelExporterKind::OtlpGrpc {
            endpoint: "http://collector:4317".to_string(),
            headers: HashMap::new(),
            tls: None,
        },
        ..OtelConfig::default()
    };
    let blank_endpoint = OtelConfig {
        exporter: OtelExporterKind::OtlpGrpc {
            endpoint: "  ".to_string(),
            headers: HashMap::new(),
            tls: None,
        },
        ..OtelConfig::default()
    };

    assert!(!otel_exporter_configured(&disabled));
    assert!(otel_exporter_configured(&enabled));
    assert!(!otel_exporter_configured(&blank_endpoint));
}

#[test]
fn command_output_is_single_line_sanitized_and_bounded() {
    let long_suffix = "x".repeat(200);
    let output = format!("\n\u{1b}[31m  hello\tworld  \u{1b}[0m\nignored{long_suffix}");

    assert_eq!(
        normalize_status_line_command_output(&output),
        Some("hello world".to_string())
    );
    assert_eq!(normalize_status_line_command_output("\n \t\n"), None);
    assert_eq!(
        normalize_status_line_command_output(&long_suffix),
        Some("x".repeat(STATUS_LINE_COMMAND_OUTPUT_CHARS_CAP))
    );
}

#[test]
fn command_timing_is_clamped() {
    let config = StatusLineCommandConfig {
        command: vec!["status".to_string()],
        timeout_ms: 0,
        refresh_interval_ms: u64::MAX,
    };

    assert_eq!(
        status_line_command_timeout(&config),
        Duration::from_millis(MIN_STATUS_LINE_COMMAND_TIMEOUT_MS)
    );
    assert_eq!(
        status_line_command_refresh_interval(&config),
        Duration::from_millis(MAX_STATUS_LINE_COMMAND_REFRESH_INTERVAL_MS)
    );
}
