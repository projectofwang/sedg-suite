//! One engine run: spawn the pinned interpreter, write one request line, read JSONL back, and keep
//! a bounded stderr tail.
//!
//! `run` blocks its caller until the engine is classified, so call it from a worker thread, never
//! from the thread that paints. The stdout and stderr pipes are drained on their own threads: the
//! 1.2.5 deadlock came from waiting for one pipe on a thread the other pipe's read needed.

use std::collections::VecDeque;
use std::io::{BufRead, BufReader, Read, Write};
use std::os::windows::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc::{self, RecvTimeoutError, Sender};
use std::thread;
use std::time::{Duration, Instant};

use serde_json::Value;

use super::protocol::{self, Action, EngineCode, Request, Response, ResultLine};

const HELLO_TIMEOUT: Duration = Duration::from_secs(15);
/// After a terminal result the operation is already decided; a stuck engine only delays the session.
const EXIT_GRACE: Duration = Duration::from_secs(30);
const EXIT_POLL: Duration = Duration::from_millis(25);
const STDERR_TAIL_BYTES: usize = 512;
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

/// Terminal outcome of one run, same fields as the v1 `EngineRunResult`.
#[derive(Clone, Debug, PartialEq)]
pub struct Outcome {
    pub ok: bool,
    pub code: EngineCode,
    pub message: String,
    pub current_state: String,
    pub restored_state: String,
    pub next_step: String,
    pub data: Option<Value>,
    pub transcript_path: Option<String>,
    pub stderr_tail: String,
    pub exit_code: Option<i32>,
}

impl Outcome {
    pub(crate) fn fault(code: EngineCode, message: impl Into<String>) -> Self {
        Self {
            ok: false,
            code,
            message: message.into(),
            current_state: "unchanged".to_string(),
            restored_state: "notRequired".to_string(),
            next_step: "Open the operation log for details.".to_string(),
            data: None,
            transcript_path: None,
            stderr_tail: String::new(),
            exit_code: None,
        }
    }

    /// The app-side view of the broker's terminal line: the engine's own fields, no diagnostics
    /// (the elevated process owns those).
    pub(crate) fn from_result(result: ResultLine) -> Self {
        Self {
            ok: result.ok,
            code: result.code,
            message: result.message,
            current_state: result.current_state,
            restored_state: result.restored_state,
            next_step: result.next_step,
            data: result.data,
            transcript_path: result.transcript_path,
            stderr_tail: String::new(),
            exit_code: None,
        }
    }

    /// The terminal line the broker writes back, with the engine's own fields and no diagnostics.
    pub fn result_line(&self) -> ResultLine {
        ResultLine {
            ok: self.ok,
            code: self.code,
            message: self.message.clone(),
            current_state: self.current_state.clone(),
            restored_state: self.restored_state.clone(),
            next_step: self.next_step.clone(),
            data: self.data.clone(),
            transcript_path: self.transcript_path.clone(),
        }
    }
}

/// The pinned interpreter and the one engine script it may run.
pub struct Runner {
    pub powershell: PathBuf,
    pub script: PathBuf,
}

impl Runner {
    /// Runs one action. `sink` receives events and progress on the calling thread; hello and the
    /// terminal result are classification only, as in v1.
    pub fn run(&self, request: &Request, sink: &dyn Fn(Response)) -> Outcome {
        if !self.script.is_file() {
            return Outcome::fault(
                EngineCode::NotInstalled,
                "The engine was not found at the canonical install path.",
            );
        }

        let mut command = Command::new(&self.powershell);
        command
            .args(["-NoProfile", "-ExecutionPolicy", "Bypass", "-File"])
            .arg(&self.script)
            .args(["-Protocol", "jsonl"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .creation_flags(CREATE_NO_WINDOW);
        if let Some(directory) = self.script.parent() {
            command.current_dir(directory);
        }

        let mut child = match command.spawn() {
            Ok(child) => child,
            Err(error) => {
                return Outcome::fault(
                    EngineCode::EngineSpawn,
                    format!("The engine process could not be started. ({error})"),
                )
            }
        };

        let stdout = child.stdout.take().expect("stdout is piped");
        let stderr = child.stderr.take().expect("stderr is piped");
        let mut stdin = child.stdin.take().expect("stdin is piped");

        let (sender, receiver) = mpsc::channel();
        let stderr_thread = thread::spawn(move || read_stderr_tail(stderr));
        let stdout_thread = thread::spawn(move || pump(stdout, sender));

        // One request, then EOF: the engine reads exactly one line.
        let _ = stdin
            .write_all(request.line().as_bytes())
            .and_then(|()| stdin.write_all(b"\n"));
        drop(stdin);

        let mut seen_hello = false;
        let mut terminal: Option<ResultLine> = None;
        let mut protocol_error: Option<String> = None;
        let mut killed_for_no_hello = false;
        let hello_deadline = Instant::now() + HELLO_TIMEOUT;

        loop {
            let next = if seen_hello || killed_for_no_hello {
                receiver.recv().ok()
            } else {
                match receiver
                    .recv_timeout(hello_deadline.saturating_duration_since(Instant::now()))
                {
                    Ok(line) => Some(line),
                    Err(RecvTimeoutError::Timeout) => {
                        // No hello: nothing has touched the machine, so stopping the engine is safe.
                        kill_tree(&mut child);
                        killed_for_no_hello = true;
                        continue;
                    }
                    Err(RecvTimeoutError::Disconnected) => None,
                }
            };

            let Some(line) = next else { break };
            match line {
                Ok(Response::Hello { .. }) => seen_hello = true,
                Ok(Response::Result(result)) => {
                    terminal = Some(result);
                    break;
                }
                Ok(other) => sink(other),
                Err(error) => {
                    protocol_error.get_or_insert(error);
                }
            }
        }

        let exit_code = wait_for_exit(&mut child, terminal.is_some());
        let stderr_tail = stderr_thread.join().unwrap_or_default();
        let _ = stdout_thread.join();

        let Some(result) = terminal else {
            let (code, message) = if seen_hello {
                let detail = protocol_error
                    .map(|error| format!(" ({error})"))
                    .unwrap_or_default();
                (
                    EngineCode::Protocol,
                    format!("The engine ended without a terminal result.{detail}"),
                )
            } else {
                (
                    EngineCode::EngineSpawn,
                    "The engine did not answer with a protocol hello.".to_string(),
                )
            };
            return Outcome {
                ok: false,
                code,
                message,
                current_state: "unknown".to_string(),
                restored_state: "notRequired".to_string(),
                next_step: "Open the operation log for details.".to_string(),
                data: None,
                transcript_path: None,
                stderr_tail,
                exit_code,
            };
        };

        // A valid terminal is authoritative regardless of exit code, but an ok status must still
        // carry a snapshot (v1 treats a missing one as a protocol fault, not as success).
        if request.action == Action::Status && result.ok && protocol::status_snapshot(result.data.as_ref()).is_none() {
            return Outcome {
                ok: false,
                code: EngineCode::Protocol,
                message: "The status result carried an invalid snapshot payload.".to_string(),
                current_state: "unknown".to_string(),
                restored_state: "notRequired".to_string(),
                next_step: "Open the operation log for details.".to_string(),
                data: result.data,
                transcript_path: None,
                stderr_tail,
                exit_code,
            };
        }

        Outcome {
            ok: result.ok,
            code: result.code,
            message: result.message,
            current_state: result.current_state,
            restored_state: result.restored_state,
            next_step: result.next_step,
            data: result.data,
            transcript_path: result.transcript_path,
            stderr_tail,
            exit_code,
        }
    }
}

/// Reads stdout until the terminal result or EOF. The sender dropping is the EOF signal.
fn pump(stdout: impl Read, sender: Sender<Result<Response, String>>) {
    let mut reader = BufReader::new(stdout);
    let mut raw = Vec::new();
    loop {
        raw.clear();
        match reader.read_until(b'\n', &mut raw) {
            Ok(0) | Err(_) => return,
            Ok(_) => {}
        }

        // Lossy on purpose: a mangled byte must not end the run (the v1 reader replaces it too).
        let line = String::from_utf8_lossy(&raw);
        let parsed = protocol::parse_line(line.trim_end_matches(['\r', '\n']));
        let is_result = matches!(parsed, Ok(Response::Result(_)));
        if sender.send(parsed).is_err() || is_result {
            return;
        }
    }
}

/// Keeps only the last [`STDERR_TAIL_BYTES`] bytes of a stream that is always drained.
fn read_stderr_tail(mut stderr: impl Read) -> String {
    let mut tail: VecDeque<u8> = VecDeque::with_capacity(STDERR_TAIL_BYTES);
    let mut chunk = [0u8; 4096];
    loop {
        match stderr.read(&mut chunk) {
            Ok(0) | Err(_) => break,
            Ok(read) => {
                for byte in &chunk[..read] {
                    if tail.len() == STDERR_TAIL_BYTES {
                        tail.pop_front();
                    }
                    tail.push_back(*byte);
                }
            }
        }
    }

    String::from_utf8_lossy(&tail.into_iter().collect::<Vec<u8>>()).into_owned()
}

/// Waits for the engine to end; after a terminal result the wait is bounded by [`EXIT_GRACE`].
fn wait_for_exit(child: &mut Child, terminal: bool) -> Option<i32> {
    if terminal {
        let deadline = Instant::now() + EXIT_GRACE;
        while Instant::now() < deadline {
            match child.try_wait() {
                Ok(Some(status)) => return status.code(),
                Ok(None) => thread::sleep(EXIT_POLL),
                Err(_) => return None,
            }
        }

        kill_tree(child);
    }

    child.wait().ok().and_then(|status| status.code())
}

/// `taskkill /T` matches the v1 `Kill(entireProcessTree: true)`; the direct kill is the fallback.
fn kill_tree(child: &mut Child) {
    let system_root = std::env::var("SystemRoot").unwrap_or_else(|_| r"C:\Windows".to_string());
    let taskkill = Path::new(&system_root).join(r"System32\taskkill.exe");
    let _ = Command::new(taskkill)
        .args(["/PID", &child.id().to_string(), "/T", "/F"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .creation_flags(CREATE_NO_WINDOW)
        .status();
    let _ = child.kill();
}
