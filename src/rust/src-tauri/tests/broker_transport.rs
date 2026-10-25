//! The app-side transport: envelope agreement with the broker, the decline path, the non-elevated
//! client refusal, and the direct read-only path.

use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};

use serde_json::json;
use time::OffsetDateTime;

use sedg_manager::broker::{Nonce, Session};
use sedg_manager::elevate::{self, ElevateError};
use sedg_manager::engine::client::Runner;
use sedg_manager::engine::protocol::{Action, EngineCode, Request};
use sedg_manager::engine::transport::{
    envelope_line, BrokerTransport, DirectTransport, Launcher, Transport,
};

fn broker_exe() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_sedg-manager"))
}

fn fixture(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("fixtures")
        .join(name)
}

fn pinned_powershell() -> PathBuf {
    let system_root = std::env::var("SystemRoot").expect("SystemRoot is always set on Windows");
    PathBuf::from(system_root).join(r"System32\WindowsPowerShell\v1.0\powershell.exe")
}

#[test]
fn the_app_envelope_is_accepted_by_the_broker() {
    let nonce = "ab".repeat(32);
    let now = OffsetDateTime::now_utc();
    let issued = elevate::format_utc(now);
    let expires = elevate::format_utc(now + elevate::NONCE_VALIDITY);
    let request = Request::new(Action::SetDns, json!({ "servers": ["1.1.1.1"] }));

    let line = envelope_line(&request, &nonce, &issued, &expires);
    let mut session = Session::new(Nonce::parse(&nonce).expect("a valid nonce"));
    let accepted = session.accept(&line).expect("the broker accepts the app's envelope");

    assert_eq!(accepted.action, Action::SetDns);
    assert_eq!(accepted.operation_id, request.operation_id);
    assert_eq!(accepted.args, json!({ "servers": ["1.1.1.1"] }));
}

#[test]
fn a_declined_prompt_reports_uac_denied_and_disables_mutations() {
    let declined: Launcher = Box::new(|_, _| Err(ElevateError::Denied));
    let transport = BrokerTransport::with_launcher(broker_exe(), declined);
    assert!(transport.can_invoke_mutations(), "nothing has been attempted yet");

    let first = transport.run(&Request::new(Action::Pause, json!({})), &|_| {});
    assert!(!first.ok);
    assert_eq!(first.code, EngineCode::UacDenied);
    assert!(first.message.contains("declined"), "{}", first.message);

    assert!(!transport.can_invoke_mutations());
    assert!(transport
        .decline_reason()
        .is_some_and(|reason| reason.contains("declined")));

    // A retry is refused with the same code without relaunching the shell.
    let second = transport.run(&Request::new(Action::Resume, json!({})), &|_| {});
    assert_eq!(second.code, EngineCode::UacDenied);
}

#[test]
fn a_non_elevated_broker_is_refused_before_any_request_is_sent() {
    let child: Arc<Mutex<Option<Child>>> = Arc::new(Mutex::new(None));
    let spawned = Arc::clone(&child);
    let launcher: Launcher = Box::new(move |exe: &Path, args: &[String]| {
        let process = Command::new(exe)
            .args(args)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|error| ElevateError::Platform(error.to_string()))?;
        *spawned.lock().unwrap() = Some(process);
        Ok(())
    });

    let transport = BrokerTransport::with_launcher(broker_exe(), launcher);
    let outcome = transport.run(&Request::new(Action::Pause, json!({})), &|_| {});

    assert!(!outcome.ok);
    assert_eq!(outcome.code, EngineCode::BrokerDenied);
    assert!(
        outcome.message.contains("not elevated"),
        "{}",
        outcome.message
    );
    assert!(!transport.can_invoke_mutations());

    let leaked = child.lock().unwrap().take();
    if let Some(mut process) = leaked {
        let _ = process.kill();
        let _ = process.wait();
    }
}

#[test]
fn the_direct_transport_runs_a_read_only_request() {
    let transport = DirectTransport::new(Runner {
        powershell: pinned_powershell(),
        script: fixture("mock-engine.ps1"),
    });

    let events = Mutex::new(Vec::new());
    let outcome = transport.run(&Request::new(Action::Status, json!({})), &|response| {
        events.lock().unwrap().push(response);
    });

    assert!(outcome.ok, "{} ({:?})", outcome.message, outcome.code);
    assert_eq!(outcome.code, EngineCode::None);
    assert_eq!(events.lock().unwrap().len(), 2, "one event and one progress line");
}

#[test]
fn an_unelevated_status_runs_the_installed_engine() {
    // CI has no engine; the owner's machine does (same guard as the B3 ACL check).
    let script = PathBuf::from(r"C:\serverless-edge-dns-gateway\manager.ps1");
    if !script.is_file() {
        return;
    }

    let transport = DirectTransport::new(Runner {
        powershell: pinned_powershell(),
        script,
    });
    let outcome = transport.run(&Request::new(Action::Status, json!({})), &|_| {});

    assert!(
        outcome.ok,
        "{} ({:?}, exit {:?}, stderr {:?})",
        outcome.message, outcome.code, outcome.exit_code, outcome.stderr_tail
    );
    assert_eq!(outcome.code, EngineCode::None);
    assert!(outcome.data.is_some(), "Status carries a snapshot");
}

/// Manual release check (plan B4 step 4): proves the real UAC launch, the elevated-token check,
/// and one long-lived session for two requests. Mutates services, so it only runs on request:
/// `cargo test --test broker_transport -- --ignored`.
#[test]
#[ignore = "needs an interactive UAC approval; pauses and resumes the installed gateway"]
fn an_elevated_session_serves_pause_then_resume_without_a_second_prompt() {
    let transport = BrokerTransport::new(broker_exe());

    let pause = transport.run(&Request::new(Action::Pause, json!({})), &|_| {});
    assert!(pause.ok, "Pause failed: {} ({:?})", pause.message, pause.code);

    let resume = transport.run(&Request::new(Action::Resume, json!({})), &|_| {});
    assert!(resume.ok, "Resume failed: {} ({:?})", resume.message, resume.code);
}
