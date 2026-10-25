//! The one IPC surface (design §2.4): `preflight` reports the machine, `run_action` starts one
//! operation on a worker thread and answers immediately. Progress and the terminal result travel
//! as events, so the UI thread never waits for an engine.
//!
//! The window cannot choose a script or a path: it names an action from the closed vocabulary, and
//! the broker re-validates everything on the elevated side.

use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use serde_json::{json, Value};
use tauri::{AppHandle, Emitter, State};
use time::format_description::well_known::Rfc3339;
use time::OffsetDateTime;
use uuid::Uuid;

use crate::broker::ENGINE_SCRIPT;
use crate::engine::client::{Outcome, Runner};
use crate::engine::protocol::{Action, EngineCode, Request, Response};
use crate::engine::transport::{BrokerTransport, DirectTransport, Transport};
use crate::log::{self, Operation};
use crate::setup::{self, Level, Preflight};
use crate::settings::{self, Settings};

pub struct AppState {
    setup: bool,
    exe: PathBuf,
    direct: Arc<DirectTransport>,
    broker: Arc<BrokerTransport>,
    busy: Arc<AtomicBool>,
}

impl AppState {
    pub fn new(setup: bool) -> Self {
        let exe = std::env::current_exe().unwrap_or_else(|_| PathBuf::from("sedg-manager.exe"));
        let runner = Runner {
            powershell: crate::broker::pipe::pinned_powershell(),
            script: PathBuf::from(ENGINE_SCRIPT),
        };

        Self {
            setup,
            direct: Arc::new(DirectTransport::new(runner)),
            broker: Arc::new(BrokerTransport::new(exe.clone())),
            exe,
            busy: Arc::new(AtomicBool::new(false)),
        }
    }

    fn begin(&self) -> Result<BusyGuard, String> {
        self.busy
            .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
            .map(|_| BusyGuard(Arc::clone(&self.busy)))
            .map_err(|_| "An operation is already running.".to_string())
    }

    fn context(&self) -> Context {
        Context {
            setup: self.setup,
            exe: self.exe.clone(),
            direct: Arc::clone(&self.direct),
            broker: Arc::clone(&self.broker),
        }
    }
}

struct Context {
    setup: bool,
    exe: PathBuf,
    direct: Arc<DirectTransport>,
    broker: Arc<BrokerTransport>,
}

/// Releases the one-operation gate on every exit path, including a panicked worker.
struct BusyGuard(Arc<AtomicBool>);

impl Drop for BusyGuard {
    fn drop(&mut self) {
        self.0.store(false, Ordering::SeqCst);
    }
}

#[tauri::command]
pub fn preflight() -> Preflight {
    setup::evaluate(&setup::Facts::read())
}

/// Which screen this process is: the first install or the installed manager.
#[tauri::command]
pub fn app_mode(state: State<'_, AppState>) -> &'static str {
    if state.setup {
        "setup"
    } else {
        "manager"
    }
}

/// Read-only status on a blocking worker, so a slow engine never freezes the window.
#[tauri::command]
pub async fn get_status(state: State<'_, AppState>) -> Result<Value, String> {
    let direct = Arc::clone(&state.direct);
    tauri::async_runtime::spawn_blocking(move || crate::status::read(direct.as_ref()))
        .await
        .map_err(|error| format!("The status worker failed: {error}"))?
}

#[tauri::command]
pub fn run_action(
    app: AppHandle,
    state: State<'_, AppState>,
    action: String,
    input: Value,
) -> Result<(), String> {
    let action: Action = serde_json::from_value(json!(action))
        .map_err(|_| format!("Unknown action '{action}'."))?;
    if state.setup && action != Action::Install {
        return Err("Setup mode only runs Install.".to_string());
    }
    let args = crate::actions::wire_args(action, &input)?;

    let guard = state.begin()?;
    let context = state.context();
    std::thread::Builder::new()
        .name("sedg-action".to_string())
        .spawn(move || {
            let _guard = guard;
            let outcome = execute(&context, action, args, &app);
            let _ = app.emit("engine://result", result_payload(&outcome));
        })
        .map_err(|error| format!("The action worker could not be started: {error}"))?;

    Ok(())
}

/// Opens the engine's transcript in Explorer with the file selected (v1 parity), or a directory in
/// Explorer. The path comes from the engine's own terminal result or from the manager's own app
/// data, and is only ever handed to Explorer, which opens or selects it and never runs it; quotes
/// and control characters are refused so it cannot add switches.
#[tauri::command]
pub fn open_log(path: String) -> Result<(), String> {
    let path = PathBuf::from(path.trim());
    if !path.is_absolute() {
        return Err("The log path is not absolute.".to_string());
    }
    if path
        .to_string_lossy()
        .chars()
        .any(|character| matches!(character, '"' | '\r' | '\n' | '\0'))
    {
        return Err("The log path contains characters that are not allowed.".to_string());
    }
    if !path.exists() {
        return Err("The log path does not exist.".to_string());
    }

    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        let argument = if path.is_dir() {
            format!("\"{}\"", path.display())
        } else {
            format!("/select,\"{}\"", path.display())
        };
        std::process::Command::new("explorer.exe")
            .raw_arg(argument)
            .spawn()
            .map_err(|error| format!("Explorer could not be started: {error}"))?;
    }

    Ok(())
}

/// The manager's own language and theme. `language` is null until the first run picks one.
#[tauri::command]
pub fn get_settings() -> Settings {
    settings::load()
}

#[tauri::command]
pub fn save_settings(settings: Settings) -> Result<Settings, String> {
    let saved = crate::settings::save(settings)?;
    log::app(
        "info",
        &format!(
            "Settings: language {}, theme {}.",
            saved.language.as_deref().unwrap_or("auto"),
            saved.theme
        ),
    );
    Ok(saved)
}

/// The last operations plus the folder they live in, for the log surface. Reading a large
/// operations.jsonl must not run on the UI thread, same rule as `get_status`.
#[tauri::command]
pub async fn recent_operations() -> Value {
    tauri::async_runtime::spawn_blocking(|| {
        json!({
            "directory": log::log_dir()
                .map(|path| path.to_string_lossy().into_owned())
                .unwrap_or_default(),
            "operations": log::recent(20),
        })
    })
    .await
    .unwrap_or_else(|_| json!({ "directory": "", "operations": [] }))
}

fn execute(context: &Context, action: Action, args: Value, app: &AppHandle) -> Outcome {
    let operation = Uuid::new_v4();
    let started = OffsetDateTime::now_utc();
    log::app(
        "info",
        &format!("{} started (operation {operation}).", action.wire()),
    );

    let outcome = if context.setup {
        install(context, args, app)
    } else {
        let request = Request::new(action, args);
        let sink = |response: Response| emit_response(app, &response);
        if needs_elevation(action) {
            context.broker.run(&request, &sink)
        } else {
            context.direct.run(&request, &sink)
        }
    };

    log::app(
        if outcome.ok { "info" } else { "warn" },
        &format!(
            "{} finished (operation {operation}): {}",
            action.wire(),
            outcome.message
        ),
    );
    log::record(&Operation {
        operation_id: operation.to_string(),
        action: log_action(action),
        started_utc: started.format(&Rfc3339).unwrap_or_default(),
        ended_utc: OffsetDateTime::now_utc()
            .format(&Rfc3339)
            .unwrap_or_default(),
        ok: outcome.ok,
        code: serde_json::to_value(outcome.code)
            .ok()
            .and_then(|value| value.as_str().map(str::to_string))
            .unwrap_or_default(),
        message: Some(outcome.message.clone()),
        transcript_path: outcome.transcript_path.clone(),
        late_completion: false,
    });
    outcome
}

/// v1 wrote the action name lowerCamel in `operations.jsonl` (`setUpstream`, not `SetUpstream`).
fn log_action(action: Action) -> String {
    let wire = action.wire();
    let mut characters = wire.chars();
    match characters.next() {
        Some(first) => first.to_lowercase().collect::<String>() + characters.as_str(),
        None => String::new(),
    }
}

/// v1's `BrokerRouted`: only actions that change the machine go through the elevated broker. The
/// engine language lives in the user's own app data and the CDN test reads, so neither raises UAC.
fn needs_elevation(action: Action) -> bool {
    !matches!(
        action,
        Action::Status | Action::SetLanguage | Action::TestCdnOptimization
    )
}

/// The first install: preflight again, download, stage, and hand the script to the elevated
/// broker. The staged directory lives until the broker returns its terminal result, because the
/// installer copies its own staged file into the engine root.
fn install(context: &Context, args: Value, app: &AppHandle) -> Outcome {
    let preflight = setup::evaluate(&setup::Facts::read());
    if !preflight.can_install {
        let blocked = preflight
            .checks
            .iter()
            .filter(|check| check.level == Level::Block)
            .map(|check| check.code)
            .collect::<Vec<_>>()
            .join(", ");
        return Outcome::fault(
            EngineCode::Preflight,
            format!("The preflight blocked the install: {blocked}."),
        );
    }

    notify(app, "download", "Downloading the installer from the pinned host.");
    let installer = match setup::download_installer() {
        Ok(bytes) => bytes,
        Err(error) => return Outcome::fault(EngineCode::SourceUnreachable, error.to_string()),
    };
    notify(
        app,
        "stage",
        &format!("Downloaded {} bytes. Staging the installer.", installer.len()),
    );

    let staged = match setup::Staged::create(&installer) {
        Ok(staged) => staged,
        Err(error) => return Outcome::fault(EngineCode::SourceUnreachable, error.to_string()),
    };

    notify(
        app,
        "elevation",
        "Asking for administrator approval. The installer verifies its version against the approved manifest.",
    );
    let transport = BrokerTransport::for_setup(&context.exe, staged.script());
    let sink = |response: Response| emit_response(app, &response);
    transport.run(&Request::new(Action::Install, args), &sink)
}

fn notify(app: &AppHandle, phase: &str, message: &str) {
    let _ = app.emit(
        "engine://event",
        json!({ "phase": phase, "message": message }),
    );
}

fn emit_response(app: &AppHandle, response: &Response) {
    let payload = match response {
        Response::Event { phase, message, .. } => {
            json!({ "phase": phase, "message": message })
        }
        Response::Progress {
            phase,
            bytes_transferred,
            bytes_total,
            ..
        } => json!({
            "phase": phase,
            "message": "",
            "bytesTransferred": bytes_transferred,
            "bytesTotal": bytes_total,
        }),
        Response::Hello { .. } | Response::Result(_) => return,
    };
    let _ = app.emit("engine://event", payload);
}

fn result_payload(outcome: &Outcome) -> Value {
    json!({
        "ok": outcome.ok,
        "code": outcome.code as u8,
        "codeName": serde_json::to_value(outcome.code).unwrap_or(Value::Null),
        "message": outcome.message,
        "currentState": outcome.current_state,
        "restoredState": outcome.restored_state,
        "nextStep": outcome.next_step,
        "transcriptPath": outcome.transcript_path,
        "stderrTail": outcome.stderr_tail,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Every action the manager exposes is either direct or on the broker allow-list. A UI action
    /// added to the broker path without the allow-list would be refused after the UAC prompt.
    #[test]
    fn every_broker_routed_action_is_allowed_by_the_broker() {
        for action in [
            Action::Status,
            Action::Install,
            Action::Update,
            Action::Pause,
            Action::Resume,
            Action::Restart,
            Action::Uninstall,
            Action::SetUpstream,
            Action::SetDns,
            Action::SetLanguage,
            Action::TestCdnOptimization,
        ] {
            if needs_elevation(action) {
                assert!(
                    crate::broker::allows(action),
                    "{} is broker-routed but not allowed by the broker",
                    action.wire()
                );
            }
        }
    }

    /// These two run in the current process so they never raise UAC; the elevated surface must not
    /// learn them either.
    #[test]
    fn the_uac_free_actions_stay_off_the_broker() {
        for action in [Action::SetLanguage, Action::TestCdnOptimization] {
            assert!(!needs_elevation(action), "{} became broker-routed", action.wire());
            assert!(
                !crate::broker::allows(action),
                "{} is on the elevated surface",
                action.wire()
            );
        }
    }

    #[test]
    fn reserved_actions_stay_off_the_broker() {
        for action in [Action::Purge, Action::RestoreEngine] {
            assert!(!crate::broker::allows(action), "{} is exposed", action.wire());
        }
    }

    /// `operations.jsonl` keeps v1's action names, so an existing support query still matches.
    #[test]
    fn the_operation_log_says_set_upstream_like_v1() {
        assert_eq!(log_action(Action::SetUpstream), "setUpstream");
        assert_eq!(log_action(Action::TestCdnOptimization), "testCdnOptimization");
        assert_eq!(log_action(Action::Install), "install");
    }
}
