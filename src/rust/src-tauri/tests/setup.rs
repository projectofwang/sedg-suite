//! Setup mode (design §2.6): the preflight gate, staging the one-time installer, and the broker
//! rule that decides which staged script may run elevated.

use serde_json::json;
use time::OffsetDateTime;

use sedg_manager::broker::{self, Nonce, Session};
use sedg_manager::engine::protocol::{Action, Request};
use sedg_manager::engine::transport::envelope_line;
use sedg_manager::setup::{self, Facts, Level};

const GIB: u64 = 1024 * 1024 * 1024;

fn healthy() -> Facts {
    Facts {
        os_build: Some(22631),
        os_arch_x64: true,
        process_x64: true,
        engine_present: false,
        free_bytes: Some(50 * GIB),
        online: Some(true),
    }
}

fn check<'a>(preflight: &'a setup::Preflight, code: &str) -> &'a setup::Check {
    preflight
        .checks
        .iter()
        .find(|check| check.code == code)
        .unwrap_or_else(|| panic!("the {code} check is missing"))
}

#[test]
fn a_supported_pc_can_install_and_the_engine_is_simply_absent() {
    let preflight = setup::evaluate(&healthy());

    assert!(preflight.can_install);
    assert_eq!(check(&preflight, "preflight.os").level, Level::Ok);
    assert_eq!(check(&preflight, "preflight.arch").level, Level::Ok);
    assert_eq!(
        check(&preflight, "preflight.enginePresent").level,
        Level::Ok,
        "nothing installed is the normal setup state"
    );
    assert_eq!(check(&preflight, "preflight.disk").level, Level::Ok);
    assert_eq!(check(&preflight, "preflight.network").level, Level::Ok);
}

#[test]
fn windows_10_and_an_unverifiable_version_are_blockers() {
    for build in [Some(19045), None] {
        let preflight = setup::evaluate(&Facts {
            os_build: build,
            ..healthy()
        });

        assert!(!preflight.can_install, "build {build:?} must block");
        assert_eq!(check(&preflight, "preflight.os").level, Level::Block);
    }
}

#[test]
fn a_non_x64_process_or_system_is_a_blocker() {
    for facts in [
        Facts {
            process_x64: false,
            ..healthy()
        },
        Facts {
            os_arch_x64: false,
            ..healthy()
        },
    ] {
        let preflight = setup::evaluate(&facts);
        assert!(!preflight.can_install);
        assert_eq!(check(&preflight, "preflight.arch").level, Level::Block);
    }
}

#[test]
fn an_existing_gateway_is_a_warning_that_install_repairs_it() {
    let preflight = setup::evaluate(&Facts {
        engine_present: true,
        ..healthy()
    });

    assert!(preflight.can_install, "a reinstall is still allowed");
    assert_eq!(
        check(&preflight, "preflight.enginePresent").level,
        Level::Warn
    );
}

#[test]
fn low_disk_and_an_offline_host_are_warnings_not_gates() {
    let preflight = setup::evaluate(&Facts {
        free_bytes: Some(120 * 1024 * 1024),
        online: Some(false),
        ..healthy()
    });

    assert!(preflight.can_install);
    let disk = check(&preflight, "preflight.disk");
    assert_eq!(disk.level, Level::Warn);
    assert_eq!(disk.detail.as_deref(), Some("120 MB"));
    assert_eq!(check(&preflight, "preflight.network").level, Level::Warn);
}

#[test]
fn unverifiable_disk_and_network_state_is_honest_and_omitted() {
    let preflight = setup::evaluate(&Facts {
        free_bytes: None,
        online: None,
        ..healthy()
    });

    assert!(preflight.can_install);
    assert!(preflight
        .checks
        .iter()
        .all(|check| check.code != "preflight.disk" && check.code != "preflight.network"));
}

#[test]
fn staging_writes_manager_ps1_under_a_fresh_temp_directory_and_cleans_up() {
    let staged = setup::Staged::create(b"#requires -Version 5.1\n").expect("staging succeeds");
    let script = staged.script().to_path_buf();
    let directory = script.parent().expect("the script has a parent").to_path_buf();

    assert_eq!(script.file_name().unwrap(), "manager.ps1");
    assert_eq!(std::fs::read(&script).unwrap(), b"#requires -Version 5.1\n");

    let name = directory
        .file_name()
        .and_then(|name| name.to_str())
        .expect("the directory has a UTF-8 name");
    assert!(
        name.starts_with("sedg-setup-"),
        "the staging directory carries the setup marker: {name}"
    );
    assert_eq!(
        directory.parent().map(|parent| parent.to_path_buf()),
        Some(std::env::temp_dir()),
        "the staging directory sits directly in %TEMP%"
    );

    drop(staged);
    assert!(!directory.exists(), "the staging directory is removed");
}

#[test]
fn an_empty_installer_is_refused_before_a_directory_is_created() {
    assert!(setup::Staged::create(b"").is_err());
}

#[test]
fn the_broker_accepts_a_script_staged_by_the_app() {
    let staged = setup::Staged::create(b"#requires -Version 5.1\n").expect("staging succeeds");
    let sid = broker::pipe::current_user_sid().expect("the user SID resolves");

    broker::validate_setup_script_with(staged.script(), &std::env::temp_dir(), &sid)
        .expect("a staged script passes the guard");
}

#[test]
fn the_broker_refuses_a_staged_script_not_owned_by_this_user() {
    let staged = setup::Staged::create(b"#requires -Version 5.1\n").expect("staging succeeds");

    let error = broker::validate_setup_script_with(
        staged.script(),
        &std::env::temp_dir(),
        "S-1-5-18",
    )
    .unwrap_err();

    assert!(error.contains("owned by the current user"), "{error}");
}

#[test]
fn the_broker_refuses_a_script_outside_the_staging_shape() {
    let scratch = std::env::temp_dir().join(format!("sedg-setup-test-{}", std::process::id()));
    std::fs::create_dir_all(&scratch).expect("the scratch directory is writable");
    let script = scratch.join("manager.ps1");
    std::fs::write(&script, b"#requires -Version 5.1\n").expect("the scratch script is writable");
    let sid = broker::pipe::current_user_sid().expect("the user SID resolves");
    let temp = std::env::temp_dir();

    let outside = broker::validate_setup_script_with(&script, &temp, &sid).unwrap_err();
    assert!(outside.contains("staging directory"), "{outside}");

    let relative = broker::validate_setup_script_with(
        std::path::Path::new("manager.ps1"),
        &temp,
        &sid,
    )
    .unwrap_err();
    assert!(relative.contains("not absolute"), "{relative}");

    // A real staging directory, but the wrong file name.
    let guid = uuid::Uuid::new_v4();
    let directory = temp.join(format!("sedg-setup-{guid}"));
    std::fs::create_dir(&directory).expect("the staging directory is writable");
    let wrong_name = directory.join("installer.ps1");
    std::fs::write(&wrong_name, b"#requires -Version 5.1\n").expect("the script is writable");
    let error = broker::validate_setup_script_with(&wrong_name, &temp, &sid).unwrap_err();
    assert!(error.contains("manager.ps1"), "{error}");

    // A real name, but one directory deeper than the staging root.
    let nested = directory.join("nested");
    std::fs::create_dir(&nested).expect("the nested directory is writable");
    let nested_script = nested.join("manager.ps1");
    std::fs::write(&nested_script, b"#requires -Version 5.1\n").expect("the script is writable");
    let error = broker::validate_setup_script_with(&nested_script, &temp, &sid).unwrap_err();
    assert!(error.contains("staging directory"), "{error}");

    let _ = std::fs::remove_dir_all(&scratch);
    let _ = std::fs::remove_dir_all(&directory);
}

#[test]
fn a_setup_session_only_runs_install() {
    let nonce = "ab".repeat(32);
    let now = OffsetDateTime::now_utc();
    let issued = sedg_manager::elevate::format_utc(now);
    let expires = sedg_manager::elevate::format_utc(now + sedg_manager::elevate::NONCE_VALIDITY);

    let install = envelope_line(&Request::new(Action::Install, json!({})), &nonce, &issued, &expires);
    let mut session = Session::for_setup(Nonce::parse(&nonce).expect("a valid nonce"));
    assert_eq!(
        session.accept(&install).expect("install is the setup action").action,
        Action::Install
    );

    let status = envelope_line(&Request::new(Action::Status, json!({})), &nonce, &issued, &expires);
    let mut session = Session::for_setup(Nonce::parse(&nonce).expect("a valid nonce"));
    let refused = session.accept(&status).unwrap_err();
    assert_eq!(refused.code(), sedg_manager::engine::protocol::EngineCode::BrokerSchema);
    assert!(refused.message().contains("only runs Install"), "{}", refused.message());
}

#[test]
fn the_installer_url_is_the_https_distribution_host() {
    let url = setup::installer_url();
    assert!(url.starts_with("https://"), "{url}");
    assert!(url.ends_with("/installer.ps1"), "{url}");
}

#[test]
#[ignore = "reaches the pinned distribution host; run manually"]
fn the_pinned_installer_is_downloadable() {
    let bytes = setup::download_installer().expect("the pinned host answers");

    assert!(bytes.len() > 1024, "the installer is {} bytes", bytes.len());
    let text = String::from_utf8_lossy(&bytes);
    assert!(text.contains("InstallerVersion"), "the body is the gateway installer");
}
