//! The read-only Status snapshot (design §4.3): one engine call, validated against the wire
//! schema, returned to the window exactly as the engine delivered it. Nothing is computed,
//! repaired, or guessed here; an unknown probe keeps its own reason for the UI to show.

use serde_json::{json, Value};

use crate::engine::protocol::{self, Action, Request};
use crate::engine::transport::Transport;

pub fn read(transport: &dyn Transport) -> Result<Value, String> {
    let outcome = transport.run(&Request::new(Action::Status, json!({})), &|_| {});

    if !outcome.ok {
        return Err(outcome.message);
    }

    let data = outcome
        .data
        .ok_or_else(|| "The status result carried no snapshot.".to_string())?;
    protocol::status_snapshot(Some(&data))
        .ok_or_else(|| "The status snapshot is malformed.".to_string())?;
    Ok(data)
}

#[cfg(test)]
mod tests {
    use std::sync::Mutex;

    use super::*;
    use crate::engine::client::Outcome;
    use crate::engine::protocol::{EngineCode, Response};

    fn outcome(ok: bool, message: &str, data: Option<Value>) -> Outcome {
        Outcome {
            ok,
            code: if ok { EngineCode::None } else { EngineCode::Protocol },
            message: message.to_string(),
            current_state: "unknown".to_string(),
            restored_state: "unchanged".to_string(),
            next_step: String::new(),
            data,
            transcript_path: None,
            stderr_tail: String::new(),
            exit_code: None,
        }
    }

    /// One canned outcome per test; the transport is called exactly once.
    struct Fake(Mutex<Option<Outcome>>);

    impl Fake {
        fn new(outcome: Outcome) -> Self {
            Self(Mutex::new(Some(outcome)))
        }
    }

    impl Transport for Fake {
        fn run(&self, _request: &Request, _sink: &dyn Fn(Response)) -> Outcome {
            self.0
                .lock()
                .expect("the fake is not poisoned")
                .take()
                .expect("the fake is called once")
        }
    }

    fn minimal_snapshot() -> Value {
        json!({
            "installPresence": {
                "state": "known",
                "value": { "installed": true, "installPath": r"C:\serverless-edge-dns-gateway" }
            },
            "readiness": { "state": "unknown", "reason": "the watchdog probe found no task" },
            "observedUtc": "2026-10-25T12:00:00Z",
            "phases": []
        })
    }

    #[test]
    fn a_valid_snapshot_is_returned_to_the_window_unchanged() {
        let snapshot = minimal_snapshot();
        let transport = Fake::new(outcome(true, "", Some(snapshot.clone())));

        assert_eq!(read(&transport).unwrap(), snapshot);
    }

    #[test]
    fn a_failed_status_returns_the_engine_message() {
        let transport = Fake::new(outcome(false, "The engine probe failed.", None));

        let error = read(&transport).unwrap_err();
        assert_eq!(error, "The engine probe failed.");
    }

    #[test]
    fn a_success_without_a_snapshot_is_refused() {
        let transport = Fake::new(outcome(true, "", None));

        assert!(read(&transport)
            .unwrap_err()
            .contains("carried no snapshot"));
    }

    #[test]
    fn a_malformed_snapshot_is_refused_instead_of_rendered() {
        for data in [json!({ "installPresence": { "state": "known" } }), json!([])] {
            let transport = Fake::new(outcome(true, "", Some(data)));
            assert!(read(&transport).unwrap_err().contains("malformed"));
        }
    }
}
