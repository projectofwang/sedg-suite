//! Protocol v1 round-trip and rejection cases: the same wire the engine already speaks.

use sedg_manager::engine::protocol::{
    args_for, parse_line, split_servers, status_snapshot, Action, ActionInput, EngineCode, Language,
    Probe, Request, Response, ResultLine, UpstreamMode, PROTOCOL_VERSION,
};
use serde_json::{json, Value};

fn install(clean: bool) -> ActionInput {
    ActionInput {
        install_clean: clean,
        ..ActionInput::default()
    }
}

fn upstream(mode: UpstreamMode, url: Option<&str>) -> ActionInput {
    ActionInput {
        upstream_mode: Some(mode),
        upstream_url: url.map(str::to_string),
        ..ActionInput::default()
    }
}

fn dns(servers: &[&str]) -> ActionInput {
    ActionInput {
        servers: servers.iter().map(|server| server.to_string()).collect(),
        ..ActionInput::default()
    }
}

#[test]
fn install_sends_nothing_unless_clean_was_chosen() {
    assert_eq!(args_for(Action::Install, &install(false)).unwrap(), json!({}));
    assert_eq!(
        args_for(Action::Install, &install(true)).unwrap(),
        json!({ "mode": "clean" })
    );
}

#[test]
fn upstream_carries_its_mode_and_only_a_custom_url() {
    assert_eq!(
        args_for(
            Action::SetUpstream,
            &upstream(UpstreamMode::ResetDefaults, None)
        )
        .unwrap(),
        json!({ "mode": "resetDefaults" })
    );
    assert_eq!(
        args_for(
            Action::SetUpstream,
            &upstream(UpstreamMode::Custom, Some("https://dns.example/dns-query"))
        )
        .unwrap(),
        json!({ "mode": "custom", "upstreamUrl": "https://dns.example/dns-query" })
    );

    for scheme in ["tls", "h3", "quic"] {
        let url = format!("{scheme}://dns.example:853");
        assert!(
            args_for(Action::SetUpstream, &upstream(UpstreamMode::Custom, Some(&url))).is_ok(),
            "{scheme} should be accepted"
        );
    }
}

#[test]
fn upstream_rejects_a_missing_or_contradictory_choice() {
    assert!(args_for(Action::SetUpstream, &ActionInput::default()).is_err());
    assert!(args_for(
        Action::SetUpstream,
        &upstream(UpstreamMode::Custom, None)
    )
    .is_err());
    assert!(args_for(
        Action::SetUpstream,
        &upstream(UpstreamMode::ResetDefaults, Some("https://dns.example"))
    )
    .is_err());
    for invalid in [
        "http://dns.example",
        "dns.example",
        "https://",
        "https://dns.example/\r\nInjected: yes",
        "",
    ] {
        assert!(
            args_for(Action::SetUpstream, &upstream(UpstreamMode::Custom, Some(invalid))).is_err(),
            "{invalid:?} should be rejected"
        );
    }
}

#[test]
fn dns_trims_and_de_duplicates_the_same_way_the_v1_text_box_does() {
    assert_eq!(
        split_servers(" 1.1.1.1, 8.8.8.8\n1.1.1.1\t2606:4700:4700::1111 "),
        vec!["1.1.1.1", "8.8.8.8", "2606:4700:4700::1111"]
    );
    assert_eq!(
        args_for(
            Action::SetDns,
            &dns(&[" 9.9.9.9", "9.9.9.9", "149.112.112.112"])
        )
        .unwrap(),
        json!({ "servers": ["9.9.9.9", "149.112.112.112"] })
    );
}

#[test]
fn dns_rejects_a_list_the_engine_would_refuse() {
    assert!(args_for(Action::SetDns, &ActionInput::default()).is_err());
    assert!(args_for(Action::SetDns, &dns(&["1.1.1.1", "8.8.8.8", "9.9.9.9", "1.0.0.1", "1.0.0.2"])).is_err());
    assert!(args_for(Action::SetDns, &dns(&["not-an-address"])).is_err());
    assert!(args_for(Action::SetDns, &dns(&["1.1.1.256"])).is_err());
}

#[test]
fn language_and_argument_less_actions() {
    assert!(args_for(Action::SetLanguage, &ActionInput::default()).is_err());
    assert_eq!(
        args_for(
            Action::SetLanguage,
            &ActionInput {
                language: Some(Language::Vi),
                ..ActionInput::default()
            }
        )
        .unwrap(),
        json!({ "language": "vi" })
    );

    for action in [
        Action::Status,
        Action::Update,
        Action::Pause,
        Action::Resume,
        Action::Restart,
        Action::Uninstall,
        Action::Purge,
        Action::RestoreEngine,
        Action::TestCdnOptimization,
    ] {
        assert_eq!(
            args_for(action, &ActionInput::default()).unwrap(),
            json!({}),
            "{}",
            action.wire()
        );
    }
}

#[test]
fn the_request_line_is_the_v1_envelope() {
    let line = Request::new(Action::SetUpstream, json!({ "mode": "resetDefaults" })).line();
    let value: Value = serde_json::from_str(&line).unwrap();

    assert_eq!(value["type"], "request");
    assert_eq!(value["protocolVersion"], PROTOCOL_VERSION);
    assert_eq!(value["action"], "SetUpstream");
    assert_eq!(value["args"], json!({ "mode": "resetDefaults" }));
    let operation = value["operationId"].as_str().unwrap();
    assert_eq!(operation.len(), 36, "expected the dashed GUID shape: {operation}");
    assert!(operation.chars().all(|c| c == '-' || c.is_ascii_hexdigit()));
}

#[test]
fn every_response_line_the_engine_sends_is_understandable() {
    assert_eq!(
        parse_line(r#"{"type":"hello","protocolVersion":1,"pid":4242,"engineVersion":"1.2.5"}"#)
            .unwrap(),
        Response::Hello {
            protocol_version: 1,
            pid: 4242,
            engine_version: "1.2.5".to_string(),
        }
    );

    assert_eq!(
        parse_line(
            r#"{"type":"event","seq":7,"tsUtc":"2026-01-01T00:00:00Z","phase":"install","message":"working"}"#
        )
        .unwrap(),
        Response::Event {
            seq: 7,
            ts_utc: "2026-01-01T00:00:00Z".to_string(),
            phase: "install".to_string(),
            message: "working".to_string(),
        }
    );

    assert_eq!(
        parse_line(
            r#"{"type":"progress","seq":8,"tsUtc":"2026-01-01T00:00:01Z","phase":"download","bytesTransferred":10,"bytesTotal":100}"#
        )
        .unwrap(),
        Response::Progress {
            seq: 8,
            ts_utc: "2026-01-01T00:00:01Z".to_string(),
            phase: "download".to_string(),
            bytes_transferred: Some(10),
            bytes_total: Some(100),
        }
    );

    let Response::Result(result) = parse_line(
        r#"{"type":"result","ok":false,"code":"HashMismatch","message":"bad hash","currentState":"unchanged","restoredState":"unchanged","nextStep":"retry","data":{"k":1},"transcriptPath":"C:\\log.txt"}"#,
    )
    .unwrap() else {
        panic!("expected a result");
    };
    assert!(!result.ok);
    assert_eq!(result.code, EngineCode::HashMismatch);
    assert_eq!(result.data, Some(json!({ "k": 1 })));
    assert_eq!(result.transcript_path.as_deref(), Some(r"C:\log.txt"));
}

#[test]
fn malformed_lines_are_rejected_with_a_reason() {
    let cases = [
        ("", "empty"),
        ("   ", "empty"),
        ("not json", "Malformed"),
        (r#"{"type":"bogus"}"#, "Unknown protocol line type"),
        (
            r#"{"type":"hello","protocolVersion":1,"pid":4242,"engineVersion":"1","extra":true}"#,
            "Malformed",
        ),
        (
            r#"{"type":"hello","protocolVersion":1,"pid":0,"engineVersion":"1"}"#,
            "positive pid",
        ),
        (
            r#"{"type":"hello","protocolVersion":1,"pid":4242}"#,
            "engineVersion",
        ),
        (
            r#"{"type":"event","seq":1,"tsUtc":"2026-01-01T00:00:00Z","phase":"install"}"#,
            "message",
        ),
        (
            r#"{"type":"progress","seq":1,"tsUtc":"2026-01-01T00:00:00Z","phase":"download","bytesTransferred":-1}"#,
            "Malformed",
        ),
        (
            r#"{"type":"result","ok":true,"message":"m","currentState":"a","restoredState":"b","nextStep":"c"}"#,
            "code",
        ),
        (
            r#"{"type":"result","ok":true,"code":"MadeUp","message":"m","currentState":"a","restoredState":"b","nextStep":"c"}"#,
            "Malformed",
        ),
        (
            r#"{"type":"result","ok":true,"code":0,"message":"m","currentState":"a","restoredState":"b","nextStep":"c"}"#,
            "Malformed",
        ),
    ];

    for (line, expected) in cases {
        let error = parse_line(line).expect_err(line);
        assert!(
            error.contains(expected),
            "{line:?} produced {error:?}, expected {expected:?}"
        );
    }
}

#[test]
fn a_utf8_bom_on_the_first_line_is_absorbed() {
    assert!(parse_line("\u{feff}{\"type\":\"hello\",\"protocolVersion\":1,\"pid\":1,\"engineVersion\":\"1\"}").is_ok());
}

#[test]
fn every_response_the_broker_writes_parses_back() {
    let responses = vec![
        Response::Event {
            seq: 1,
            ts_utc: "2026-01-01T00:00:00Z".to_string(),
            phase: "install".to_string(),
            message: "working".to_string(),
        },
        Response::Progress {
            seq: 2,
            ts_utc: "2026-01-01T00:00:01Z".to_string(),
            phase: "download".to_string(),
            bytes_transferred: Some(10),
            bytes_total: Some(100),
        },
        Response::Progress {
            seq: 3,
            ts_utc: "2026-01-01T00:00:02Z".to_string(),
            phase: "download".to_string(),
            bytes_transferred: None,
            bytes_total: None,
        },
        Response::Result(ResultLine {
            ok: true,
            code: EngineCode::None,
            message: "done".to_string(),
            current_state: "installed".to_string(),
            restored_state: "unchanged".to_string(),
            next_step: "none".to_string(),
            data: Some(json!({ "observedUtc": "2026-01-01T00:00:00Z", "phases": [] })),
            transcript_path: Some(r"C:\log.txt".to_string()),
        }),
        Response::Result(ResultLine {
            ok: false,
            code: EngineCode::BrokerNonce,
            message: "refused".to_string(),
            current_state: "unchanged".to_string(),
            restored_state: "notRequired".to_string(),
            next_step: "retry".to_string(),
            data: None,
            transcript_path: None,
        }),
    ];

    for response in responses {
        let line = response.to_line().expect("forwardable response");
        assert_eq!(parse_line(&line).unwrap(), response, "{line}");
    }

    assert!(Response::Hello {
        protocol_version: 1,
        pid: 1,
        engine_version: "1".to_string(),
    }
    .to_line()
    .is_none());
}
#[test]
fn an_ok_status_needs_a_schema_valid_snapshot() {
    let minimal = json!({ "observedUtc": "2026-01-01T00:00:00Z", "phases": [] });
    let snapshot = status_snapshot(Some(&minimal)).expect("the minimal snapshot is valid");
    assert!(matches!(snapshot.install_presence, Probe::NotApplicable));
    assert!(snapshot.phases.is_empty());

    let known = json!({
        "installPresence": { "state": "known", "value": { "installed": true, "installPath": "C:\\x" } },
        "readiness": { "state": "unknown", "reason": "engine probe failed" },
        "versions": { "state": "known", "value": [{ "component": "dnsproxy", "installed": "1", "approved": "1", "match": "equal" }] },
        "observedUtc": "2026-01-01T00:00:00Z",
        "phases": [{ "id": "install", "label": "Install", "state": "done" }]
    });
    assert!(status_snapshot(Some(&known)).is_some());

    for invalid in [
        json!(null),
        json!([]),
        json!("snapshot"),
        json!({ "unknownField": 1 }),
        json!({ "installPresence": { "state": "known" } }),
        json!({ "installPresence": { "state": "unknown" } }),
        json!({ "watchdog": { "state": "known", "value": { "enabled": true, "unknownField": 1 } } }),
        json!({ "versions": { "state": "known", "value": { "components": [] } } }),
        json!({ "phases": "not-an-array" }),
    ] {
        assert!(
            status_snapshot(Some(&invalid)).is_none(),
            "{invalid} should be refused"
        );
    }
    assert!(status_snapshot(None).is_none());
}
