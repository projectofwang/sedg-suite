//! Broker authentication and framing: every refusal happens before an executor could run.

use std::cell::Cell;
use std::io::Cursor;
use std::time::Duration;

use serde_json::{json, Value};
use time::format_description::well_known::Rfc3339;
use time::OffsetDateTime;
use uuid::Uuid;

use sedg_manager::broker::pipe::{self, MAX_LINE_BYTES};
use sedg_manager::broker::{BrokerError, Executor, Nonce, Session};
use sedg_manager::engine::client::Outcome;
use sedg_manager::engine::protocol::{self, Action, EngineCode, Request, Response};
use sedg_manager::mode::BrokerArgs;

fn nonce() -> String {
    "0123456789abcdef".repeat(4)
}

/// Unique per call: the two tests that create a pipe must never share a name.
fn unique_nonce() -> String {
    format!("{}{}", Uuid::new_v4().simple(), Uuid::new_v4().simple())
}

fn stamp(offset_seconds: i64) -> String {
    (OffsetDateTime::now_utc() + time::Duration::seconds(offset_seconds))
        .format(&Rfc3339)
        .unwrap()
}

fn envelope(action: &str, args: Value, nonce: &str, issued: &str, expires: &str) -> String {
    json!({
        "type": "request",
        "protocolVersion": 1,
        "action": action,
        "operationId": Uuid::new_v4().to_string(),
        "args": args,
        "nonce": nonce,
        "issuedUtc": issued,
        "expiresUtc": expires,
    })
    .to_string()
}

fn valid_line(action: &str, args: Value) -> String {
    envelope(action, args, &nonce(), &stamp(0), &stamp(60))
}

fn session() -> Session {
    Session::new(Nonce::parse(&nonce()).unwrap())
}

/// Counts executions and emits one event, so a refused line has an observable "did not run".
struct Recording {
    calls: Cell<usize>,
}

impl Recording {
    fn new() -> Self {
        Self { calls: Cell::new(0) }
    }
}

impl Executor for Recording {
    fn execute(&self, _request: &Request, sink: &dyn Fn(Response)) -> Outcome {
        self.calls.set(self.calls.get() + 1);
        sink(Response::Event {
            seq: 1,
            ts_utc: "2026-01-01T00:00:00Z".to_string(),
            phase: "install".to_string(),
            message: "working".to_string(),
        });
        Outcome {
            ok: true,
            code: EngineCode::None,
            message: "done".to_string(),
            current_state: "installed".to_string(),
            restored_state: "unchanged".to_string(),
            next_step: "none".to_string(),
            data: None,
            transcript_path: None,
            stderr_tail: String::new(),
            exit_code: Some(0),
        }
    }
}

#[test]
fn a_wrong_nonce_is_refused_before_any_engine_could_run() {
    let error = session()
        .accept(&envelope(
            "Pause",
            json!({}),
            &"f".repeat(64),
            &stamp(0),
            &stamp(60),
        ))
        .unwrap_err();

    assert_eq!(
        error,
        BrokerError::Nonce("The request nonce does not match the handshake nonce.".to_string())
    );
}

#[test]
fn a_malformed_nonce_is_refused() {
    let error = session()
        .accept(&envelope("Pause", json!({}), "not-a-nonce", &stamp(0), &stamp(60)))
        .unwrap_err();

    assert!(matches!(error, BrokerError::Nonce(ref message) if message.contains("64 hexadecimal")));
}

#[test]
fn an_expired_window_is_refused() {
    let error = session()
        .accept(&envelope(
            "Pause",
            json!({}),
            &nonce(),
            &stamp(-600),
            &stamp(-540),
        ))
        .unwrap_err();

    assert_eq!(
        error,
        BrokerError::Nonce("The nonce issue time is more than 120 s in the past.".to_string())
    );
}

#[test]
fn a_window_that_is_too_far_ahead_is_refused() {
    let error = session()
        .accept(&envelope(
            "Pause",
            json!({}),
            &nonce(),
            &stamp(300),
            &stamp(360),
        ))
        .unwrap_err();

    assert!(matches!(error, BrokerError::Nonce(ref message) if message.contains("in the future")));
}

#[test]
fn a_non_allow_listed_action_is_refused() {
    for action in ["Purge", "RestoreEngine", "SetLanguage", "TestCdnOptimization"] {
        let error = session()
            .accept(&valid_line(action, json!({})))
            .unwrap_err();
        assert!(
            matches!(error, BrokerError::Schema(ref message)
                if message.contains("is not allowed by the broker")),
            "{action} produced {error:?}"
        );
    }
}

#[test]
fn an_unknown_action_name_is_refused() {
    let error = session()
        .accept(&valid_line("Explode", json!({})))
        .unwrap_err();
    assert!(matches!(error, BrokerError::Schema(_)), "{error:?}");
}

#[test]
fn a_missing_action_is_refused() {
    let line = json!({
        "type": "request",
        "protocolVersion": 1,
        "operationId": Uuid::new_v4().to_string(),
        "args": {},
        "nonce": nonce(),
        "issuedUtc": stamp(0),
        "expiresUtc": stamp(60),
    })
    .to_string();

    assert!(matches!(
        session().accept(&line).unwrap_err(),
        BrokerError::Schema(ref message) if message.contains("no action")
    ));
}

#[test]
fn an_unknown_envelope_field_is_refused_rather_than_forwarded() {
    let mut value: Value = serde_json::from_str(&valid_line("Install", json!({}))).unwrap();
    value["note"] = json!("ignore me");

    let error = session().accept(&value.to_string()).unwrap_err();
    assert!(
        matches!(error, BrokerError::Schema(ref message) if message.contains("unknown field")),
        "{error:?}"
    );
}

#[test]
fn the_wrong_protocol_version_is_refused() {
    let mut value: Value = serde_json::from_str(&valid_line("Install", json!({}))).unwrap();
    value["protocolVersion"] = json!(2);

    assert!(matches!(
        session().accept(&value.to_string()).unwrap_err(),
        BrokerError::Schema(ref message) if message.contains("Unsupported protocolVersion 2")
    ));
}

#[test]
fn a_blank_operation_id_is_refused() {
    let mut value: Value = serde_json::from_str(&valid_line("Install", json!({}))).unwrap();
    value["operationId"] = json!("00000000-0000-0000-0000-000000000000");

    assert!(matches!(
        session().accept(&value.to_string()).unwrap_err(),
        BrokerError::Schema(ref message) if message.contains("non-empty GUID")
    ));
}

#[test]
fn the_argument_schema_is_rechecked_on_the_broker_side() {
    let cases = [
        ("Install", json!({ "mode": "full" })),
        ("SetUpstream", json!({ "mode": "custom" })),
        ("SetUpstream", json!({ "mode": "resetDefaults", "upstreamUrl": 7 })),
        ("SetDns", json!({ "servers": ["1.1.1.1", "8.8.8.8", "9.9.9.9", "1.0.0.1", "1.0.0.2"] })),
        ("SetDns", json!({ "servers": ["not-an-address"] })),
        ("Pause", json!({ "force": true })),
    ];

    for (action, args) in cases {
        let error = session().accept(&valid_line(action, args)).unwrap_err();
        assert!(
            matches!(error, BrokerError::Schema(_)),
            "{action} accepted {error:?}"
        );
    }
}

#[test]
fn a_valid_request_is_rebuilt_from_its_own_fields() {
    let mut session = session();
    let operation = Uuid::new_v4();
    let line = json!({
        "type": "request",
        "protocolVersion": 1,
        "action": "Install",
        "operationId": operation.to_string().to_uppercase(),
        "args": { "mode": "clean" },
        "nonce": nonce(),
        "issuedUtc": stamp(0),
        "expiresUtc": stamp(60),
    })
    .to_string();

    let request = session.accept(&line).unwrap();
    assert_eq!(request.action, Action::Install);
    assert_eq!(request.protocol_version, 1);
    assert_eq!(request.operation_id, operation.hyphenated().to_string());
    assert_eq!(request.args, json!({ "mode": "clean" }));
}

#[test]
fn an_operation_id_is_authorized_only_once_per_session() {
    let mut session = session();
    let line = valid_line("Pause", json!({}));

    session.accept(&line).unwrap();
    let error = session.accept(&line).unwrap_err();

    assert!(
        matches!(error, BrokerError::Schema(ref message)
            if message.contains("already been authorized")),
        "{error:?}"
    );
}

#[test]
fn an_oversized_line_is_refused_and_the_engine_never_runs() {
    let mut input = vec![b'a'; MAX_LINE_BYTES + 1];
    input.push(b'\n');
    let executor = Recording::new();
    let mut output = Vec::new();

    session()
        .serve(Cursor::new(input), &mut output, &executor)
        .unwrap();

    assert_eq!(executor.calls.get(), 0);
    let lines = String::from_utf8(output).unwrap();
    let Response::Result(result) = protocol::parse_line(lines.trim_end()).unwrap() else {
        panic!("expected a terminal result, got {lines:?}");
    };
    assert!(!result.ok);
    assert_eq!(result.code, EngineCode::BrokerSchema);
}

#[test]
fn the_session_streams_events_and_one_terminal_result() {
    let mut input = valid_line("Install", json!({}));
    input.push('\n');
    let executor = Recording::new();
    let mut output = Vec::new();

    session()
        .serve(Cursor::new(input), &mut output, &executor)
        .unwrap();

    assert_eq!(executor.calls.get(), 1);
    let lines = String::from_utf8(output).unwrap();
    let parsed: Vec<Response> = lines
        .lines()
        .map(|line| protocol::parse_line(line).unwrap())
        .collect();
    assert_eq!(parsed.len(), 2, "{lines:?}");
    assert!(matches!(parsed[0], Response::Event { .. }));
    let Response::Result(result) = &parsed[1] else {
        panic!("expected a terminal result, got {lines:?}");
    };
    assert!(result.ok);
    assert_eq!(result.code, EngineCode::None);
}

#[test]
fn a_refused_request_still_gets_its_terminal_result_and_keeps_serving() {
    let mut input = envelope("Pause", json!({}), &"f".repeat(64), &stamp(0), &stamp(60));
    input.push('\n');
    input.push_str(&valid_line("Pause", json!({})));
    input.push('\n');
    let executor = Recording::new();
    let mut output = Vec::new();

    session()
        .serve(Cursor::new(input), &mut output, &executor)
        .unwrap();

    assert_eq!(executor.calls.get(), 1);
    let lines = String::from_utf8(output).unwrap();
    let parsed: Vec<Response> = lines
        .lines()
        .map(|line| protocol::parse_line(line).unwrap())
        .collect();
    assert_eq!(parsed.len(), 3, "{lines:?}");
    let Response::Result(first) = &parsed[0] else {
        panic!("expected a refusal first");
    };
    assert_eq!(first.code, EngineCode::BrokerNonce);
    assert!(matches!(parsed[1], Response::Event { .. }));
    let Response::Result(second) = &parsed[2] else {
        panic!("expected the accepted result third");
    };
    assert!(second.ok);
}

#[test]
fn a_loopback_pipe_carries_one_line_each_way() {
    let sid = pipe::current_user_sid().expect("the current user has a SID");
    let nonce = unique_nonce();
    let server = pipe::PipeServer::create(&sid, &nonce).expect("create the pipe");
    assert_eq!(server.name(), format!("Sedg.Broker.{sid}.{nonce}"));
    assert_eq!(
        pipe::path(server.name()),
        format!(r"\\.\pipe\{}", server.name())
    );

    let name = server.name().to_string();
    let client = std::thread::spawn(move || pipe::connect(&name, Duration::from_secs(10)));

    server.connect_timeout(Duration::from_secs(10)).expect("accept the client");
    let pid = server.client_pid().expect("the client's pid");
    let (mut reader, mut writer) = server.into_halves().expect("split the server handle");
    let (mut client_reader, mut client_writer) = client
        .join()
        .expect("the client thread")
        .expect("the client connects");

    pipe::write_line(&mut client_writer, "ping").unwrap();
    assert_eq!(
        pipe::read_line(&mut reader, MAX_LINE_BYTES).unwrap(),
        Some("ping".to_string())
    );

    pipe::write_line(&mut writer, "pong").unwrap();
    assert_eq!(
        pipe::read_line(&mut client_reader, MAX_LINE_BYTES).unwrap(),
        Some("pong".to_string())
    );

    assert_eq!(pid, std::process::id());
}

#[test]
fn a_client_that_never_connects_times_out_instead_of_blocking_forever() {
    let sid = pipe::current_user_sid().expect("the current user has a SID");
    let server = pipe::PipeServer::create(&sid, &unique_nonce()).expect("create the pipe");

    let started = std::time::Instant::now();
    let error = server
        .connect_timeout(Duration::from_millis(150))
        .expect_err("no client is coming");
    assert_eq!(error.kind(), std::io::ErrorKind::TimedOut);
    assert!(started.elapsed() < Duration::from_secs(2));
}

#[test]
fn a_line_at_the_limit_is_accepted_and_one_byte_more_is_not() {
    let mut exact = vec![b'a'; MAX_LINE_BYTES];
    exact.push(b'\n');
    assert_eq!(
        pipe::read_line(&mut Cursor::new(exact), MAX_LINE_BYTES)
            .unwrap()
            .map(|line| line.len()),
        Some(MAX_LINE_BYTES)
    );

    let mut over = vec![b'a'; MAX_LINE_BYTES + 1];
    over.push(b'\n');
    assert!(pipe::read_line(&mut Cursor::new(over), MAX_LINE_BYTES).is_err());
}

#[test]
fn a_user_writable_engine_script_is_refused() {
    let path = std::env::temp_dir().join(format!("sedg-broker-{}.ps1", Uuid::new_v4()));
    std::fs::write(&path, "# fixture").unwrap();

    let error = sedg_manager::broker::validate_engine_path(&path).unwrap_err();
    assert!(
        error.contains("not owned by SYSTEM")
            || error.contains("reparse point")
            || error.contains("grants write access to untrusted principal"),
        "{error}"
    );

    let _ = std::fs::remove_file(path);
}

#[test]
fn the_installed_engine_path_passes_the_v1_acl_guard() {
    let path = std::path::Path::new(sedg_manager::broker::ENGINE_SCRIPT);
    if !path.exists() {
        // CI has no engine; the owner's machine and the release check do.
        return;
    }

    sedg_manager::broker::validate_engine_path(path).unwrap();
}

#[test]
fn broker_arguments_from_the_command_line_are_accepted_by_the_validator() {
    let args = BrokerArgs {
        nonce: nonce(),
        issued_utc: stamp(0),
        expires_utc: stamp(60),
        setup_script: None,
    };
    assert!(Nonce::parse(&args.nonce).is_ok());
    assert!(sedg_manager::broker::check_window(
        &args.issued_utc,
        &args.expires_utc,
        OffsetDateTime::now_utc()
    )
    .is_ok());
}
