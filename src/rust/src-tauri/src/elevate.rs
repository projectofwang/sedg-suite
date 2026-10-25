//! Elevation and the broker launch (design §2.2/§2.3): the same executable, started with the
//! `runas` verb, no separate asset.

use std::ffi::OsStr;
use std::os::windows::ffi::OsStrExt;
use std::path::Path;
use std::ptr;
use std::time::Duration;

use time::format_description::well_known::Rfc3339;
use time::OffsetDateTime;
use windows_sys::Win32::Foundation::{CloseHandle, GetLastError, ERROR_CANCELLED};
use windows_sys::Win32::Security::Cryptography::{
    BCryptGenRandom, BCRYPT_USE_SYSTEM_PREFERRED_RNG,
};
use windows_sys::Win32::UI::Shell::{
    ShellExecuteExW, SEE_MASK_FLAG_NO_UI, SEE_MASK_NOCLOSEPROCESS, SHELLEXECUTEINFOW,
};
use windows_sys::Win32::UI::WindowsAndMessaging::SW_HIDE;

use crate::broker::pipe;
use crate::engine::protocol::EngineCode;

/// The nonce and its validity window mirror v1 `BrokerCoordinator`.
pub const NONCE_BYTES: usize = 32;
pub const NONCE_VALIDITY: Duration = Duration::from_secs(60);

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ElevateError {
    /// The user declined the UAC prompt (`ERROR_CANCELLED`).
    Denied,
    /// The platform call failed; the message is already user-facing.
    Platform(String),
    /// `ShellExecuteExW` returned a shell error code.
    Launch(u32),
}

impl ElevateError {
    pub fn code(&self) -> EngineCode {
        match self {
            Self::Denied => EngineCode::UacDenied,
            Self::Platform(_) | Self::Launch(_) => EngineCode::BrokerDenied,
        }
    }

    pub fn message(&self) -> String {
        match self {
            Self::Denied => {
                "Elevation was declined. Mutating actions stay unavailable until you approve the prompt."
                    .to_string()
            }
            Self::Platform(message) => message.clone(),
            Self::Launch(code) => {
                format!("The elevated broker could not be started (shell error {code}).")
            }
        }
    }
}

/// v1 `WindowsIdentity.GetCurrent().User`: the same identity the broker's mutex and pipe use.
pub fn is_elevated() -> bool {
    pipe::is_process_elevated(std::process::id())
}

pub fn current_user_sid() -> Result<String, ElevateError> {
    pipe::current_user_sid().map_err(|error| {
        ElevateError::Platform(format!("The user SID could not be resolved: {error}"))
    })
}

/// 32 bytes from the system CSPRNG, as the 64 lowercase hex characters both sides accept.
pub fn new_nonce() -> Result<String, ElevateError> {
    let mut bytes = [0u8; NONCE_BYTES];
    let status = unsafe {
        BCryptGenRandom(
            ptr::null_mut(),
            bytes.as_mut_ptr(),
            bytes.len() as u32,
            BCRYPT_USE_SYSTEM_PREFERRED_RNG,
        )
    };
    if status != 0 {
        return Err(ElevateError::Platform(format!(
            "The system random generator failed ({status})."
        )));
    }

    Ok(bytes.iter().map(|byte| format!("{byte:02x}")).collect())
}

pub fn format_utc(value: OffsetDateTime) -> String {
    value
        .format(&Rfc3339)
        .expect("a UTC timestamp always formats as RFC 3339")
}

/// The broker command line. The fixed shapes are checked here so no member can inject a space or
/// a quote into the string `ShellExecuteExW` receives.
pub fn broker_args(
    nonce: &str,
    issued_utc: &str,
    expires_utc: &str,
    setup_script: Option<&Path>,
) -> Result<Vec<String>, ElevateError> {
    if nonce.len() != NONCE_BYTES * 2 || !nonce.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err(ElevateError::Platform(
            "The broker nonce must be 64 hexadecimal characters.".to_string(),
        ));
    }

    for stamp in [issued_utc, expires_utc] {
        if OffsetDateTime::parse(stamp, &Rfc3339).is_err() {
            return Err(ElevateError::Platform(
                "The broker timestamps must be RFC 3339.".to_string(),
            ));
        }
    }

    let mut args = vec![
        "--broker".to_string(),
        nonce.to_string(),
        issued_utc.to_string(),
        expires_utc.to_string(),
    ];

    if let Some(path) = setup_script {
        if !path.is_absolute() {
            return Err(ElevateError::Platform(
                "The setup script path must be absolute.".to_string(),
            ));
        }
        let text = path.to_string_lossy();
        if text.contains('"') || text.contains(['\r', '\n']) {
            return Err(ElevateError::Platform(
                "The setup script path contains an unusable character.".to_string(),
            ));
        }
        args.push("--setup".to_string());
        args.push(text.into_owned());
    }

    Ok(args)
}

/// The pipe name both sides derive from the session identity.
pub fn pipe_name(sid: &str, nonce: &str) -> String {
    format!("Sedg.Broker.{sid}.{nonce}")
}

pub fn launch_elevated(exe: &Path, args: &[String]) -> Result<(), ElevateError> {
    let file = wide(&exe.to_string_lossy());
    let verb = wide("runas");
    let parameters = wide(&command_line(args));

    let mut info: SHELLEXECUTEINFOW = unsafe { std::mem::zeroed() };
    info.cbSize = std::mem::size_of::<SHELLEXECUTEINFOW>() as u32;
    info.fMask = SEE_MASK_NOCLOSEPROCESS | SEE_MASK_FLAG_NO_UI;
    info.lpVerb = verb.as_ptr();
    info.lpFile = file.as_ptr();
    info.lpParameters = parameters.as_ptr();
    info.nShow = SW_HIDE;

    let launched = unsafe { ShellExecuteExW(&mut info) } != 0;
    if !launched {
        return Err(launch_error(unsafe { GetLastError() }));
    }

    // The broker outlives this call; the handle only has to be released.
    if !info.hProcess.is_null() {
        unsafe {
            CloseHandle(info.hProcess);
        }
    }
    Ok(())
}

/// One command-line string: a token containing whitespace is quoted, which is how a user name
/// with a space survives `ShellExecuteExW`.
fn command_line(args: &[String]) -> String {
    args.iter()
        .map(|arg| {
            if arg.contains([' ', '\t']) {
                format!("\"{arg}\"")
            } else {
                arg.clone()
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

fn launch_error(code: u32) -> ElevateError {
    if code == ERROR_CANCELLED {
        ElevateError::Denied
    } else {
        ElevateError::Launch(code)
    }
}

fn wide(value: &str) -> Vec<u16> {
    OsStr::new(value).encode_wide().chain(Some(0)).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_broker_command_is_the_documented_one() {
        let nonce = "0123456789abcdef".repeat(4);
        let args = broker_args(
            &nonce,
            "2026-10-25T12:00:00Z",
            "2026-10-25T12:01:00Z",
            None,
        )
        .unwrap();

        assert_eq!(
            args,
            vec![
                "--broker".to_string(),
                nonce,
                "2026-10-25T12:00:00Z".to_string(),
                "2026-10-25T12:01:00Z".to_string(),
            ]
        );
    }

    #[test]
    fn a_malformed_nonce_or_stamp_cannot_reach_the_shell() {
        let nonce = "ab".repeat(32);
        for bad in ["", "abc", &"g".repeat(64), &format!("{nonce} ")] {
            assert!(broker_args(bad, "2026-10-25T12:00:00Z", "2026-10-25T12:01:00Z", None).is_err());
        }
        assert!(broker_args(&nonce, "not-a-time", "2026-10-25T12:01:00Z", None).is_err());
        assert!(broker_args(&nonce, "2026-10-25T12:00:00Z", "2026-10-25 12:01:00", None).is_err());
    }

    #[test]
    fn the_setup_script_follows_the_nonce_window() {
        let nonce = "0123456789abcdef".repeat(4);
        let script = Path::new(r"C:\Users\Jane Doe\AppData\Local\Temp\sedg-setup-x\manager.ps1");

        let args = broker_args(
            &nonce,
            "2026-10-25T12:00:00Z",
            "2026-10-25T12:01:00Z",
            Some(script),
        )
        .unwrap();

        assert_eq!(args[4], "--setup");
        assert_eq!(args[5], script.to_string_lossy());
        assert_eq!(
            command_line(&args),
            format!(
                "--broker {nonce} 2026-10-25T12:00:00Z 2026-10-25T12:01:00Z --setup \"{}\"",
                script.to_string_lossy()
            )
        );
    }

    #[test]
    fn a_relative_or_quoted_setup_path_cannot_reach_the_shell() {
        let nonce = "0123456789abcdef".repeat(4);
        for script in [
            Path::new("manager.ps1"),
            Path::new("C:\\a\\\"b\\manager.ps1"),
        ] {
            assert!(broker_args(
                &nonce,
                "2026-10-25T12:00:00Z",
                "2026-10-25T12:01:00Z",
                Some(script)
            )
            .is_err());
        }
    }

    #[test]
    fn the_pipe_name_matches_the_broker_side() {
        let sid = "S-1-5-21-1-2-3-1001";
        let nonce = "ab".repeat(32);
        assert_eq!(
            pipe_name(sid, &nonce),
            format!("Sedg.Broker.{sid}.{nonce}")
        );
        assert_eq!(
            pipe::path(&pipe_name(sid, &nonce)),
            format!(r"\\.\pipe\Sedg.Broker.{sid}.{nonce}")
        );
    }

    #[test]
    fn a_declined_prompt_is_the_uac_code() {
        assert_eq!(launch_error(ERROR_CANCELLED), ElevateError::Denied);
        assert_eq!(ElevateError::Denied.code(), EngineCode::UacDenied);
        assert_eq!(launch_error(5), ElevateError::Launch(5));
        assert_eq!(ElevateError::Launch(5).code(), EngineCode::BrokerDenied);
    }

    #[test]
    fn the_nonce_is_64_hex_characters() {
        let nonce = new_nonce().unwrap();
        assert_eq!(nonce.len(), 64);
        assert!(nonce.bytes().all(|byte| byte.is_ascii_hexdigit()));
        assert_ne!(nonce, new_nonce().unwrap());
    }

    #[test]
    fn elevation_reflects_the_process_token() {
        assert_eq!(
            is_elevated(),
            pipe::is_process_elevated(std::process::id())
        );
    }
}
