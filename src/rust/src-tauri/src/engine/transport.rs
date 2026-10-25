//! The app-side transport (design §2.4): read-only actions run the engine directly; everything
//! that mutates the machine goes through the elevated broker, one authenticated pipe session for
//! the lifetime of the app.
//!
//! `run` blocks (pipe reads and the engine child are worker-thread work by contract). The Tauri
//! command layer calls it from a blocking worker, never from the UI thread.

use std::fs::File;
use std::io::{BufReader, BufWriter};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard};
use std::time::Duration;

use serde_json::json;
use time::OffsetDateTime;

use crate::broker::pipe::{self, PipeServer, MAX_LINE_BYTES};
use crate::elevate::{self, ElevateError};
use crate::engine::client::{Outcome, Runner};
use crate::engine::protocol::{self, EngineCode, Request, Response};

const CONNECT_TIMEOUT: Duration = Duration::from_secs(120);

/// Anything that can run one request and stream its responses to `sink`.
pub trait Transport: Send + Sync {
    fn run(&self, request: &Request, sink: &dyn Fn(Response)) -> Outcome;
}

/// The unelevated path: Status and other reads the engine can answer as the current user.
pub struct DirectTransport {
    runner: Runner,
}

impl DirectTransport {
    pub fn new(runner: Runner) -> Self {
        Self { runner }
    }

    pub fn runner(&self) -> &Runner {
        &self.runner
    }
}

impl Transport for DirectTransport {
    fn run(&self, request: &Request, sink: &dyn Fn(Response)) -> Outcome {
        self.runner.run(request, sink)
    }
}

/// The launch seam. Production uses [`elevate::launch_elevated`]; tests substitute a launcher that
/// starts the broker without UAC so the refusal paths stay testable.
pub type Launcher = Box<dyn Fn(&Path, &[String]) -> Result<(), ElevateError> + Send + Sync>;

enum Session {
    Idle,
    Ready {
        reader: BufReader<File>,
        writer: BufWriter<File>,
        nonce: String,
    },
    Declined {
        code: EngineCode,
        reason: String,
    },
}

pub struct BrokerTransport {
    exe: PathBuf,
    launch: Launcher,
    /// First install only: the staged installer the broker runs instead of the engine.
    setup: Option<PathBuf>,
    session: Mutex<Session>,
}

impl BrokerTransport {
    pub fn new(exe: impl Into<PathBuf>) -> Self {
        Self::with_launcher(exe, Box::new(elevate::launch_elevated))
    }

    /// Test seam: the elevation check still runs against the real client token.
    #[doc(hidden)]
    pub fn with_launcher(exe: impl Into<PathBuf>, launch: Launcher) -> Self {
        Self {
            exe: exe.into(),
            launch,
            setup: None,
            session: Mutex::new(Session::Idle),
        }
    }

    /// Test seam for the first-install transport without UAC.
    #[doc(hidden)]
    pub fn with_launcher_for_setup(
        exe: impl Into<PathBuf>,
        script: impl Into<PathBuf>,
        launch: Launcher,
    ) -> Self {
        let mut transport = Self::with_launcher(exe, launch);
        transport.setup = Some(script.into());
        transport
    }

    /// The first-install transport: the broker validates and runs the staged installer.
    pub fn for_setup(exe: impl Into<PathBuf>, script: impl Into<PathBuf>) -> Self {
        Self::with_launcher_for_setup(exe, script, Box::new(elevate::launch_elevated))
    }

    /// Mirrors v1 `CanInvokeMutations`: a declined (or lost) session disables mutations until the
    /// app retries elevation.
    pub fn can_invoke_mutations(&self) -> bool {
        !matches!(*self.lock(), Session::Declined { .. })
    }

    pub fn decline_reason(&self) -> Option<String> {
        match &*self.lock() {
            Session::Declined { reason, .. } => Some(reason.clone()),
            _ => None,
        }
    }

    fn lock(&self) -> MutexGuard<'_, Session> {
        // A panicked worker must not poison the session permanently.
        self.session.lock().unwrap_or_else(|error| error.into_inner())
    }
}

impl Transport for BrokerTransport {
    fn run(&self, request: &Request, sink: &dyn Fn(Response)) -> Outcome {
        let mut session = self.lock();
        match self.run_locked(&mut session, request, sink) {
            Ok(outcome) => outcome,
            Err((code, reason)) => {
                *session = Session::Declined {
                    code,
                    reason: reason.clone(),
                };
                Outcome::fault(code, reason)
            }
        }
    }
}

impl BrokerTransport {
    fn run_locked(
        &self,
        session: &mut Session,
        request: &Request,
        sink: &dyn Fn(Response),
    ) -> Result<Outcome, (EngineCode, String)> {
        if let Session::Declined { code, reason } = session {
            // The session is already gone; report the same refusal without relaunching.
            return Ok(Outcome::fault(*code, reason.clone()));
        }

        if matches!(session, Session::Idle) {
            *session = self.open()?;
        }

        let Session::Ready {
            reader,
            writer,
            nonce,
        } = session
        else {
            unreachable!("a declined session returned above");
        };

        self.exchange(reader, writer, nonce, request, sink)
    }

    /// Creates the pipe, raises UAC, accepts the client, and verifies its token before sending
    /// anything (v1 `BrokerCoordinator` order).
    fn open(&self) -> Result<Session, (EngineCode, String)> {
        let nonce = elevate::new_nonce().map_err(|error| (error.code(), error.message()))?;
        let sid = elevate::current_user_sid().map_err(|error| (error.code(), error.message()))?;
        let issued = elevate::format_utc(OffsetDateTime::now_utc());
        let expires = elevate::format_utc(OffsetDateTime::now_utc() + elevate::NONCE_VALIDITY);
        let args = elevate::broker_args(&nonce, &issued, &expires, self.setup.as_deref())
            .map_err(|error| (error.code(), error.message()))?;

        let server = PipeServer::create(&sid, &nonce).map_err(|error| {
            (
                EngineCode::BrokerDenied,
                format!("The broker pipe could not be created: {error}"),
            )
        })?;

        (self.launch)(&self.exe, &args).map_err(|error| (error.code(), error.message()))?;

        if let Err(error) = server.connect_timeout(CONNECT_TIMEOUT) {
            return Err((
                EngineCode::Timeout,
                format!("The elevated broker did not connect: {error}"),
            ));
        }

        if !server.client_is_elevated() {
            return Err((
                EngineCode::BrokerDenied,
                "The connecting broker process is not elevated; the session was dropped."
                    .to_string(),
            ));
        }

        let (reader, writer) = server.into_halves().map_err(|error| {
            (
                EngineCode::BrokerDenied,
                format!("The broker pipe could not be split: {error}"),
            )
        })?;

        Ok(Session::Ready {
            reader,
            writer,
            nonce,
        })
    }

    fn exchange(
        &self,
        reader: &mut BufReader<File>,
        writer: &mut BufWriter<File>,
        nonce: &str,
        request: &Request,
        sink: &dyn Fn(Response),
    ) -> Result<Outcome, (EngineCode, String)> {
        let now = OffsetDateTime::now_utc();
        let issued = elevate::format_utc(now);
        let expires = elevate::format_utc(now + elevate::NONCE_VALIDITY);
        let line = envelope_line(request, nonce, &issued, &expires);

        pipe::write_line(writer, &line).map_err(|error| {
            (
                EngineCode::Protocol,
                format!("The broker request could not be written: {error}"),
            )
        })?;

        loop {
            let line = pipe::read_line(reader, MAX_LINE_BYTES)
                .map_err(|error| {
                    (
                        EngineCode::Protocol,
                        format!("The broker response could not be read: {error}"),
                    )
                })?
                .ok_or_else(|| {
                    (
                        EngineCode::Protocol,
                        "The broker session ended before a result.".to_string(),
                    )
                })?;

            match protocol::parse_line(&line) {
                Err(_) => continue, // v1 logged and kept reading; diagnostics never block the result.
                Ok(Response::Result(result)) => return Ok(Outcome::from_result(result)),
                Ok(response @ (Response::Event { .. } | Response::Progress { .. })) => sink(response),
                Ok(Response::Hello { .. }) => {}
            }
        }
    }
}

/// The request envelope protocol v1 expects from the app (request plus the session nonce window).
pub fn envelope_line(request: &Request, nonce: &str, issued_utc: &str, expires_utc: &str) -> String {
    let mut value = serde_json::to_value(request).expect("a request always serializes");
    let object = value.as_object_mut().expect("a request serializes to an object");
    object.insert("nonce".to_string(), json!(nonce));
    object.insert("issuedUtc".to_string(), json!(issued_utc));
    object.insert("expiresUtc".to_string(), json!(expires_utc));
    value.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::protocol::Action;
    use serde_json::Value;

    #[test]
    fn the_envelope_is_a_protocol_request_plus_the_nonce_window() {
        let request = Request::new(Action::Status, json!({}));
        let nonce = "ab".repeat(32);
        let line = envelope_line(&request, &nonce, "2026-10-25T12:00:00Z", "2026-10-25T12:01:00Z");
        let value: Value = serde_json::from_str(&line).unwrap();

        assert_eq!(value["type"], "request");
        assert_eq!(value["protocolVersion"], 1);
        assert_eq!(value["action"], "Status");
        assert_eq!(value["operationId"], request.operation_id);
        assert_eq!(value["args"], json!({}));
        assert_eq!(value["nonce"], nonce);
        assert_eq!(value["issuedUtc"], "2026-10-25T12:00:00Z");
        assert_eq!(value["expiresUtc"], "2026-10-25T12:01:00Z");
    }
}
