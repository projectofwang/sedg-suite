#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::process::ExitCode;

use sedg_manager::broker;
use sedg_manager::commands;
use sedg_manager::mode::Mode;
use tauri::Manager;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match Mode::parse(&args) {
        Ok(Mode::Broker(args)) => broker::run(args),
        Ok(mode) => run_ui(mode),
        Err(error) => {
            eprintln!("{error}");
            ExitCode::from(2)
        }
    }
}

fn run_ui(mode: Mode) -> ExitCode {
    // A bare launch follows the machine: the bootstrap always starts the staged copy with no
    // arguments, and on an installed PC that must be the manager, not a first-install screen.
    let setup = mode.resolve(engine_installed()) == Mode::Setup;
    let result = tauri::Builder::default()
        .manage(commands::AppState::new(setup))
        .invoke_handler(tauri::generate_handler![
            commands::app_mode,
            commands::get_settings,
            commands::get_status,
            commands::open_log,
            commands::preflight,
            commands::recent_operations,
            commands::run_action,
            commands::save_settings
        ])
        .setup(move |app| {
            if setup {
                if let Some(window) = app.get_webview_window("main") {
                    let _ = window.set_title("SEDG Manager - Setup");
                }
            }
            Ok(())
        })
        .run(tauri::generate_context!());

    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("{error}");
            ExitCode::FAILURE
        }
    }
}

fn engine_installed() -> bool {
    std::path::Path::new(broker::ENGINE_SCRIPT).is_file()
}
