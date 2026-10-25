//! The 1.2.5 deadlock class, in its Rust shape: a chatty stderr must not delay the terminal result.

use std::cell::RefCell;
use std::path::PathBuf;
use std::time::{Duration, Instant};

use sedg_manager::engine::client::Runner;
use sedg_manager::engine::protocol::{
    args_for, status_snapshot, Action, ActionInput, EngineCode, Request, Response,
};

const FLOOD_LINES: usize = 2000;

fn fixture(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("fixtures")
        .join(name)
}

fn pinned_powershell() -> PathBuf {
    let system_root =
        std::env::var("SystemRoot").expect("SystemRoot is always set on Windows");
    PathBuf::from(system_root).join(r"System32\WindowsPowerShell\v1.0\powershell.exe")
}

#[test]
fn a_stderr_flood_does_not_delay_the_terminal_result() {
    let powershell = pinned_powershell();
    assert!(
        powershell.is_file(),
        "the pinned interpreter is missing: {}",
        powershell.display()
    );

    let runner = Runner {
        powershell,
        script: fixture("mock-engine.ps1"),
    };
    let request = Request::new(
        Action::Status,
        args_for(Action::Status, &ActionInput::default()).unwrap(),
    );

    let events = RefCell::new(Vec::new());
    let started = Instant::now();
    let outcome = runner.run(&request, &|response| events.borrow_mut().push(response));
    let elapsed = started.elapsed();

    assert!(
        elapsed < Duration::from_secs(5),
        "the run took {elapsed:?}: the stderr flood delayed the terminal result"
    );
    assert!(
        outcome.ok,
        "{} ({:?}, exit {:?}, stderr {:?})",
        outcome.message, outcome.code, outcome.exit_code, outcome.stderr_tail
    );
    assert_eq!(outcome.code, EngineCode::None);
    assert_eq!(outcome.current_state, "installed");
    assert_eq!(outcome.restored_state, "unchanged");
    assert_eq!(outcome.exit_code, Some(0));

    // The flood must have been drained, not skipped: the bounded tail is the end of it.
    assert_eq!(outcome.stderr_tail.len(), 512);
    assert!(
        outcome
            .stderr_tail
            .contains(&format!("diag line {} ", FLOOD_LINES - 1)),
        "the tail does not end with the last flooded line: {:?}",
        outcome.stderr_tail
    );

    assert!(
        status_snapshot(outcome.data.as_ref()).is_some(),
        "the fixture's snapshot was refused: {:?}",
        outcome.data
    );

    let events = events.into_inner();
    assert!(
        events
            .iter()
            .any(|event| matches!(event, Response::Event { .. })),
        "no event reached the sink: {events:?}"
    );
    assert!(
        events
            .iter()
            .any(|event| matches!(event, Response::Progress { .. })),
        "no progress reached the sink: {events:?}"
    );
}

#[test]
fn a_missing_engine_is_not_installed_rather_than_a_spawn_failure() {
    let runner = Runner {
        powershell: pinned_powershell(),
        script: fixture("does-not-exist.ps1"),
    };
    let outcome = runner.run(
        &Request::new(
            Action::Status,
            args_for(Action::Status, &ActionInput::default()).unwrap(),
        ),
        &|_| {},
    );

    assert!(!outcome.ok);
    assert_eq!(outcome.code, EngineCode::NotInstalled);
    assert_eq!(outcome.current_state, "unchanged");
    assert_eq!(outcome.exit_code, None);
}

#[test]
fn an_interpreter_that_cannot_start_is_a_spawn_failure() {
    let runner = Runner {
        powershell: fixture("no-such-powershell.exe"),
        script: fixture("mock-engine.ps1"),
    };
    let outcome = runner.run(
        &Request::new(
            Action::Status,
            args_for(Action::Status, &ActionInput::default()).unwrap(),
        ),
        &|_| {},
    );

    assert!(!outcome.ok);
    assert_eq!(outcome.code, EngineCode::EngineSpawn);
    assert!(outcome.message.contains("could not be started"));
}
