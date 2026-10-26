//! The approved manifest and file digests (design §2.3): what the app trusts about the
//! distribution host, checked before anything is downloaded or run.

use std::fs;
use std::path::PathBuf;

use serde_json::{json, Value};

use sedg_manager::manifest::{self, Manifest, ManifestError, MANIFEST_URL};

const ABC_SHA256: &str = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";

fn fixture_text() -> String {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("fixtures/approved-releases.json");
    fs::read_to_string(path).expect("the fixture is present")
}

/// The committed fixture with one mutation applied, so a failing case reads as the defect it is.
fn mutated(change: impl FnOnce(&mut Value)) -> Result<Manifest, ManifestError> {
    let mut value: Value = serde_json::from_str(&fixture_text()).expect("the fixture is JSON");
    change(&mut value);
    Manifest::parse(&value.to_string())
}

fn refused(change: impl FnOnce(&mut Value)) -> ManifestError {
    match mutated(change) {
        Ok(_) => panic!("the manifest was accepted"),
        Err(error) => error,
    }
}

fn temp_file(name: &str, bytes: &[u8]) -> PathBuf {
    let path = std::env::temp_dir().join(format!("sedg-manifest-{}-{name}", std::process::id()));
    fs::write(&path, bytes).expect("the temporary file is writable");
    path
}

#[test]
fn the_approved_manifest_parses() {
    let manifest = Manifest::parse(&fixture_text()).expect("the committed manifest is valid");

    assert_eq!(manifest.installer.version, "2.0.0");
    assert_eq!(manifest.manager.repository, "projectofwang/sedg-suite");
    assert_eq!(manifest.manager.tag, "2.0.0");
    assert_eq!(manifest.manager.version(), "2.0.0");
    assert_eq!(manifest.manager.asset, "sedg-manager-win-x64-2.0.0.zip");
    assert_eq!(manifest.manager.sha256.len(), 64);
    assert_eq!(
        manifest.components.len(),
        3,
        "manager is lifted out; dnsproxy, zapret, and nssm stay"
    );
    assert_eq!(
        manifest.components["nssm"].url.as_deref(),
        Some("https://nssm.cc/release/nssm-2.24.zip")
    );
}

#[test]
fn a_schema_or_policy_the_app_does_not_know_is_refused() {
    assert!(matches!(
        refused(|value| value["policy"] = json!("latest")),
        ManifestError::Invalid(_)
    ));
    assert!(matches!(
        refused(|value| value["schema"] = json!(2)),
        ManifestError::Invalid(_)
    ));
    assert!(matches!(
        refused(|value| {
            value.as_object_mut().unwrap().remove("policy");
        }),
        ManifestError::Invalid(_)
    ));
}

#[test]
fn a_manifest_without_a_usable_manager_pin_is_refused() {
    assert!(matches!(
        refused(|value| {
            value["components"].as_object_mut().unwrap().remove("manager");
        }),
        ManifestError::Invalid(_)
    ));
    assert!(matches!(
        refused(|value| {
            value["components"]["manager"]
                .as_object_mut()
                .unwrap()
                .remove("sha256");
        }),
        ManifestError::Invalid(_)
    ));
    assert!(matches!(
        refused(|value| value["components"]["manager"]["sha256"] = json!("not-a-digest")),
        ManifestError::Invalid(_)
    ));
    assert!(matches!(
        refused(|value| value["components"]["manager"]["tag"] = json!("latest")),
        ManifestError::Invalid(_)
    ));
    assert!(matches!(
        refused(|value| {
            value["components"]["manager"]["asset"] = json!("sedg-manager-win-x64-1.2.6.zip");
        }),
        ManifestError::Invalid(_)
    ));
    assert!(matches!(
        refused(|value| value["components"]["manager"]["repository"] = json!("")),
        ManifestError::Invalid(_)
    ));
}

#[test]
fn a_v_prefixed_tag_names_the_asset_without_the_v() {
    let manifest = mutated(|value| {
        value["components"]["manager"]["tag"] = json!("v2.0.0");
        value["components"]["manager"]["asset"] = json!("sedg-manager-win-x64-2.0.0.zip");
    })
    .expect("both tag spellings are accepted");

    assert_eq!(manifest.manager.version(), "2.0.0");
    assert_eq!(manifest.manager.asset, "sedg-manager-win-x64-2.0.0.zip");
}

#[test]
fn verify_sha256_accepts_the_digest_and_rejects_another() {
    let path = temp_file("abc", b"abc");

    manifest::verify_sha256(&path, ABC_SHA256).expect("the known digest matches");
    manifest::verify_sha256(&path, &format!(" {} ", ABC_SHA256.to_uppercase()))
        .expect("case and padding are normalised, as in v1");

    match manifest::verify_sha256(&path, &"0".repeat(64)).unwrap_err() {
        ManifestError::HashMismatch { expected, actual } => {
            assert_eq!(expected, "0".repeat(64));
            assert_eq!(actual, ABC_SHA256);
        }
        other => panic!("expected HashMismatch, got {other:?}"),
    }

    assert!(matches!(
        manifest::verify_sha256(&path, "abc"),
        Err(ManifestError::Invalid(_))
    ));

    fs::remove_file(&path).expect("the temporary file is removable");
    assert!(matches!(
        manifest::verify_sha256(&path, ABC_SHA256),
        Err(ManifestError::Io(_))
    ));
}

#[test]
fn a_url_that_is_not_https_is_refused_before_any_connection() {
    let error = manifest::fetch("http://dl.example/approved-releases.json").unwrap_err();
    assert!(matches!(error, ManifestError::Transport(_)), "{error:?}");
}

#[test]
#[ignore = "reaches the pinned distribution host; run manually"]
fn the_pinned_manifest_is_fetchable() {
    let manifest = manifest::fetch(MANIFEST_URL).expect("the pinned host answers");

    assert_eq!(
        manifest.manager.repository,
        "projectofwang/sedg-suite"
    );
    assert_eq!(manifest.manager.sha256.len(), 64);
}
