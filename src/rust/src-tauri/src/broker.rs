//! Elevated broker mode (design §2.2/§2.3): the same binary, launched with `runas` by the app,
//! windowless, owning one authenticated pipe session.
//!
//! The broker trusts nothing the app sends. It re-checks the envelope schema, the closed action
//! allow-list, the operation identity, the 256-bit nonce, and the ±120 s window before spawning
//! the engine; anything else is refused and the engine stays unspawned.

pub mod pipe;

use std::collections::HashSet;
use std::ffi::c_void;
use std::io::{self, BufRead, Write};
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::ptr;
use std::time::Duration;

use serde::Deserialize;
use serde_json::{Map, Value};
use time::format_description::well_known::Rfc3339;
use time::OffsetDateTime;
use uuid::Uuid;

use windows_sys::Win32::Foundation::{LocalFree, HLOCAL};
use windows_sys::Win32::Security::Authorization::{
    ConvertSidToStringSidW, GetNamedSecurityInfoW, SE_FILE_OBJECT,
};
use windows_sys::Win32::Security::{
    GetAce, GetSecurityDescriptorDacl, ACCESS_ALLOWED_ACE, ACE_HEADER, ACL,
    DACL_SECURITY_INFORMATION, OWNER_SECURITY_INFORMATION, PSECURITY_DESCRIPTOR, PSID,
};
use windows_sys::Win32::Storage::FileSystem::{
    GetFileAttributesW, FILE_ATTRIBUTE_REPARSE_POINT, INVALID_FILE_ATTRIBUTES,
};

use crate::engine::client::{Outcome, Runner};
use crate::engine::protocol::{self, Action, EngineCode, Request, Response, ResultLine};
pub use crate::mode::BrokerArgs;

/// The steady-state engine script. First install stages a different script (B6), which is the one
/// place this path is not the authority.
pub const ENGINE_SCRIPT: &str = r"C:\serverless-edge-dns-gateway\manager.ps1";

const CONNECT_TIMEOUT: Duration = Duration::from_secs(120);
const NONCE_WINDOW_SECONDS: i64 = 120;

/// The actions the elevated broker may run: every mutating action the dashboard exposes plus the
/// read-only Status. Purge and RestoreEngine are unreachable from the UI; SetLanguage and
/// TestCdnOptimization run in the current process, so the elevated surface never learns them.
const ALLOWED: [Action; 9] = [
    Action::Status,
    Action::Install,
    Action::Update,
    Action::Pause,
    Action::Resume,
    Action::Restart,
    Action::Uninstall,
    Action::SetUpstream,
    Action::SetDns,
];

pub(crate) fn allows(action: Action) -> bool {
    ALLOWED.contains(&action)
}

const SYSTEM_SID: &str = "S-1-5-18";
const ADMINISTRATORS_SID: &str = "S-1-5-32-544";
const TRUSTED_INSTALLER_SID: &str =
    "S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464";
/// `ACCESS_ALLOWED_ACE_TYPE` from `Win32::System::SystemServices`; one constant does not justify
/// another feature on the FFI crate.
const ACCESS_ALLOWED_ACE_TYPE: u8 = 0;

/// v1 `EnginePathValidator` write rights: anything that lets a principal change what runs.
const WRITE_RIGHTS: u32 = 0x0000_0002 // FILE_WRITE_DATA
    | 0x0000_0004 // FILE_APPEND_DATA
    | 0x0000_0010 // FILE_WRITE_EA
    | 0x0000_0040 // FILE_DELETE_CHILD
    | 0x0000_0100 // FILE_WRITE_ATTRIBUTES
    | 0x0001_0000 // DELETE
    | 0x0004_0000 // WRITE_DAC
    | 0x0008_0000 // WRITE_OWNER
    | 0x4000_0000 // GENERIC_WRITE
    | 0x1000_0000; // GENERIC_ALL

/// A refusal the broker can turn into both a wire result and a process exit code.
#[derive(Debug, PartialEq, Eq)]
pub enum BrokerError {
    Nonce(String),
    Schema(String),
    Denied(String),
    MutexBusy(String),
}

impl BrokerError {
    pub fn code(&self) -> EngineCode {
        match self {
            Self::Nonce(_) => EngineCode::BrokerNonce,
            Self::Schema(_) => EngineCode::BrokerSchema,
            Self::Denied(_) => EngineCode::BrokerDenied,
            Self::MutexBusy(_) => EngineCode::MutexBusy,
        }
    }

    pub fn message(&self) -> &str {
        match self {
            Self::Nonce(message)
            | Self::Schema(message)
            | Self::Denied(message)
            | Self::MutexBusy(message) => message,
        }
    }

    /// The terminal line written back to the app; same shape as a refused engine action.
    pub fn result(&self) -> ResultLine {
        ResultLine {
            ok: false,
            code: self.code(),
            message: self.message().to_string(),
            current_state: "unchanged".to_string(),
            restored_state: "notRequired".to_string(),
            next_step: "Retry with a valid request or inspect the broker diagnostics.".to_string(),
            data: None,
            transcript_path: None,
        }
    }

    fn exit_code(&self) -> u8 {
        self.code() as u8
    }
}

/// A 256-bit bearer token, accepted only in the spelling the app issues (64 hex characters).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Nonce([u8; 32]);

impl Nonce {
    pub fn parse(value: &str) -> Result<Self, String> {
        let invalid = || "The broker nonce must be 64 hexadecimal characters.".to_string();
        if value.len() != 64 || !value.bytes().all(|byte| byte.is_ascii_hexdigit()) {
            return Err(invalid());
        }

        let mut bytes = [0u8; 32];
        for (index, byte) in bytes.iter_mut().enumerate() {
            *byte = u8::from_str_radix(&value[index * 2..index * 2 + 2], 16)
                .map_err(|_| invalid())?;
        }
        Ok(Self(bytes))
    }

    /// Fixed-time comparison: the loop does not stop at the first difference.
    fn matches(&self, other: &Self) -> bool {
        let mut difference = 0u8;
        for (left, right) in self.0.iter().zip(other.0.iter()) {
            difference |= left ^ right;
        }
        difference == 0
    }
}

const MALFORMED_STAMPS: &str = "The broker issue/expiry timestamps are malformed.";

/// v1 `NonceValidator.IsValid`, same window and the same rejection messages.
pub fn check_window(issued: &str, expires: &str, now: OffsetDateTime) -> Result<(), String> {
    let issued = OffsetDateTime::parse(issued, &Rfc3339).map_err(|_| MALFORMED_STAMPS)?;
    let expires = OffsetDateTime::parse(expires, &Rfc3339).map_err(|_| MALFORMED_STAMPS)?;
    if expires <= issued {
        return Err("The nonce expiry must be after its issue time.".to_string());
    }

    let window = time::Duration::seconds(NONCE_WINDOW_SECONDS);
    if issued > now + window {
        return Err("The nonce issue time is more than 120 s in the future.".to_string());
    }
    if issued < now - window {
        return Err("The nonce issue time is more than 120 s in the past.".to_string());
    }
    if expires > now + window {
        return Err("The nonce expiry is more than 120 s in the future.".to_string());
    }
    if expires < now - window {
        return Err("The nonce expired more than 120 s ago.".to_string());
    }

    Ok(())
}

/// The app-to-broker envelope: protocol v1's request plus the per-request nonce window. Every
/// member is fixed; an unknown member is a schema refusal, never something to forward.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Envelope {
    #[serde(rename = "type")]
    kind: String,
    #[serde(default)]
    protocol_version: u32,
    #[serde(default)]
    action: Option<Action>,
    #[serde(default)]
    operation_id: String,
    #[serde(default = "empty_args")]
    args: Value,
    #[serde(default)]
    nonce: Option<String>,
    #[serde(default)]
    issued_utc: Option<String>,
    #[serde(default)]
    expires_utc: Option<String>,
}

fn empty_args() -> Value {
    Value::Object(Map::new())
}

/// What the broker knows about one authenticated session.
pub struct Session {
    nonce: Nonce,
    authorized: HashSet<Uuid>,
    setup: bool,
}

impl Session {
    pub fn new(nonce: Nonce) -> Self {
        Self {
            nonce,
            authorized: HashSet::new(),
            setup: false,
        }
    }

    /// The first-install session: the staged installer is the only script, so Install is the only
    /// action that can reach it.
    pub fn for_setup(nonce: Nonce) -> Self {
        Self {
            nonce,
            authorized: HashSet::new(),
            setup: true,
        }
    }

    /// Validates one request line against v1's rules and returns the request the broker will run,
    /// re-serialized from its own fields (never the app's bytes).
    pub fn accept(&mut self, line: &str) -> Result<Request, BrokerError> {
        let envelope: Envelope = serde_json::from_str(line).map_err(|error| {
            BrokerError::Schema(format!(
                "The request is not a valid protocol request: {error}"
            ))
        })?;

        if envelope.kind != "request" {
            return Err(BrokerError::Schema(
                "A broker request must have type 'request'.".to_string(),
            ));
        }
        if envelope.protocol_version != protocol::PROTOCOL_VERSION {
            return Err(BrokerError::Schema(format!(
                "Unsupported protocolVersion {}.",
                envelope.protocol_version
            )));
        }

        let action = envelope
            .action
            .ok_or_else(|| BrokerError::Schema("The request has no action.".to_string()))?;
        if !allows(action) {
            return Err(BrokerError::Schema(format!(
                "Action '{}' is not allowed by the broker.",
                action.wire()
            )));
        }
        if self.setup && action != Action::Install {
            return Err(BrokerError::Schema(
                "The setup session only runs Install.".to_string(),
            ));
        }

        let operation = Uuid::parse_str(&envelope.operation_id)
            .ok()
            .filter(|id| !id.is_nil())
            .ok_or_else(|| {
                BrokerError::Schema("The operationId must be a non-empty GUID.".to_string())
            })?;

        protocol::validate_args(action, &envelope.args).map_err(BrokerError::Schema)?;

        let (Some(nonce), Some(issued), Some(expires)) = (
            envelope.nonce.as_deref(),
            envelope.issued_utc.as_deref(),
            envelope.expires_utc.as_deref(),
        ) else {
            return Err(BrokerError::Nonce(
                "Every broker request must carry nonce, issuedUtc, and expiresUtc.".to_string(),
            ));
        };

        let request_nonce = Nonce::parse(nonce).map_err(BrokerError::Nonce)?;
        check_window(issued, expires, OffsetDateTime::now_utc()).map_err(BrokerError::Nonce)?;
        if !self.nonce.matches(&request_nonce) {
            return Err(BrokerError::Nonce(
                "The request nonce does not match the handshake nonce.".to_string(),
            ));
        }

        if !self.authorized.insert(operation) {
            return Err(BrokerError::Schema(
                "The operationId has already been authorized in this session.".to_string(),
            ));
        }

        let mut request = Request::new(action, envelope.args);
        request.operation_id = operation.hyphenated().to_string();
        Ok(request)
    }

    /// Serves request lines until the peer closes. One operation runs at a time by construction:
    /// the next line is not read until the executor has returned its terminal result.
    pub fn serve(
        &mut self,
        mut reader: impl BufRead,
        writer: impl Write,
        executor: &dyn Executor,
    ) -> io::Result<()> {
        let writer = std::cell::RefCell::new(writer);
        loop {
            let line = match pipe::read_line(&mut reader, pipe::MAX_LINE_BYTES) {
                Ok(Some(line)) => line,
                Ok(None) => return Ok(()),
                Err(error) => {
                    // A refused line leaves the stream position unknown; reply, then close.
                    let refused = BrokerError::Schema(format!(
                        "The request line was refused: {error}"
                    ));
                    let _ = write_response(&writer, &Response::Result(refused.result()));
                    return Ok(());
                }
            };

            match self.accept(&line) {
                Ok(request) => {
                    let sink = |response: Response| {
                        let _ = write_response(&writer, &response);
                    };
                    let outcome = executor.execute(&request, &sink);
                    let _ = write_response(&writer, &Response::Result(outcome.result_line()));
                }
                Err(error) => {
                    let _ = write_response(&writer, &Response::Result(error.result()));
                }
            }
        }
    }
}

fn write_response(writer: &std::cell::RefCell<impl Write>, response: &Response) -> io::Result<()> {
    match response.to_line() {
        Some(line) => pipe::write_line(&mut *writer.borrow_mut(), &line),
        None => Ok(()),
    }
}

/// The one thing the session may do with an accepted request.
pub trait Executor {
    fn execute(&self, request: &Request, sink: &dyn Fn(Response)) -> Outcome;
}

impl Executor for Runner {
    fn execute(&self, request: &Request, sink: &dyn Fn(Response)) -> Outcome {
        self.run(request, sink)
    }
}

pub fn run(args: BrokerArgs) -> ExitCode {
    match serve(&args) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("Sedg.Manager broker: {}", error.message());
            ExitCode::from(error.exit_code())
        }
    }
}

fn serve(args: &BrokerArgs) -> Result<(), BrokerError> {
    let nonce = Nonce::parse(&args.nonce).map_err(BrokerError::Nonce)?;
    check_window(&args.issued_utc, &args.expires_utc, OffsetDateTime::now_utc())
        .map_err(BrokerError::Nonce)?;

    let sid = pipe::current_user_sid().map_err(|error| {
        BrokerError::Denied(format!("The user SID could not be resolved: {error}"))
    })?;
    let _mutex = pipe::Mutex::acquire(&sid).map_err(|error| BrokerError::MutexBusy(error.to_string()))?;

    let name = format!("Sedg.Broker.{sid}.{}", args.nonce);
    let (mut reader, mut writer) = pipe::connect(&name, CONNECT_TIMEOUT).map_err(|error| {
        BrokerError::Denied(format!("The app pipe could not be connected: {error}"))
    })?;

    let (script, setup) = match &args.setup_script {
        Some(path) => {
            validate_setup_script(path).map_err(|error| {
                BrokerError::Denied(format!("The setup script failed validation: {error}"))
            })?;
            (path.clone(), true)
        }
        None => {
            let script = PathBuf::from(ENGINE_SCRIPT);
            validate_engine_path(&script).map_err(|error| {
                BrokerError::Denied(format!("The engine path failed validation: {error}"))
            })?;
            (script, false)
        }
    };

    let runner = Runner {
        powershell: pipe::pinned_powershell(),
        script,
    };
    let mut session = if setup {
        Session::for_setup(nonce)
    } else {
        Session::new(nonce)
    };
    session
        .serve(&mut reader, &mut writer, &runner)
        .map_err(|error| BrokerError::Denied(format!("The broker session failed: {error}")))
}

/// v1 `EnginePathValidator`: the elevated broker runs only a regular file that no untrusted
/// principal can write, in a directory with the same property, and no reparse point on the way.
pub fn validate_engine_path(path: &Path) -> Result<(), String> {
    if !path.is_absolute() {
        return Err("The engine path is not absolute.".to_string());
    }
    if !path.is_file() {
        return Err(format!("The engine was not found at {}.", path.display()));
    }

    let mut current = Some(path);
    while let Some(item) = current {
        if is_reparse_point(item)? {
            return Err(format!(
                "The engine path traverses a reparse point at {}.",
                item.display()
            ));
        }
        current = item.parent();
    }

    let untrusted = "The engine path is not owned by SYSTEM, Administrators, or TrustedInstaller.";
    check_acl(path, "engine file", untrusted, &is_trusted, &is_trusted)?;
    if let Some(parent) = path.parent() {
        check_acl(parent, "engine directory", untrusted, &is_trusted, &is_trusted)?;
    }
    Ok(())
}

/// The first-install counterpart of [`validate_engine_path`]: a script the unelevated app wrote
/// under its own `%TEMP%`, in the one directory shape the app creates. The owner must be the
/// current user and no other principal may write it.
#[doc(hidden)]
pub fn validate_setup_script_with(
    path: &Path,
    temp: &Path,
    user_sid: &str,
) -> Result<(), String> {
    if !path.is_absolute() {
        return Err("The setup script path is not absolute.".to_string());
    }
    if path.file_name().and_then(|name| name.to_str()) != Some("manager.ps1") {
        return Err("The setup script must be named manager.ps1.".to_string());
    }
    if !path.is_file() {
        return Err(format!("The setup script was not found at {}.", path.display()));
    }

    let directory = path
        .parent()
        .ok_or_else(|| "The setup script has no parent directory.".to_string())?;
    let name = directory
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| "The staging directory has no usable name.".to_string())?;
    let guid = name
        .strip_prefix("sedg-setup-")
        .ok_or_else(|| "The setup script is not inside a sedg-setup-<guid> staging directory.".to_string())?;
    if Uuid::parse_str(guid).is_err() {
        return Err("The setup script is not inside a sedg-setup-<guid> staging directory.".to_string());
    }

    let root = directory
        .parent()
        .ok_or_else(|| "The staging directory has no parent.".to_string())?;
    if normalise(root) != normalise(temp) {
        return Err(format!(
            "The setup script is not directly under the temporary directory {}.",
            temp.display()
        ));
    }

    if is_reparse_point(path)? || is_reparse_point(directory)? {
        return Err("The setup script path traverses a reparse point.".to_string());
    }

    let owner_is_user = |sid: &str| sid.eq_ignore_ascii_case(user_sid);
    let writer_allowed = |sid: &str| sid.eq_ignore_ascii_case(user_sid) || is_trusted(sid);
    check_acl(
        path,
        "setup script",
        "The setup script is not owned by the current user.",
        &owner_is_user,
        &writer_allowed,
    )?;
    check_acl(
        directory,
        "staging directory",
        "The staging directory is not owned by the current user.",
        &owner_is_user,
        &writer_allowed,
    )
}

pub fn validate_setup_script(path: &Path) -> Result<(), String> {
    let sid = pipe::current_user_sid()
        .map_err(|error| format!("The user SID could not be resolved: {error}"))?;
    validate_setup_script_with(path, &std::env::temp_dir(), &sid)
}

fn is_reparse_point(path: &Path) -> Result<bool, String> {
    let name = wide(&path.to_string_lossy());
    let attributes = unsafe { GetFileAttributesW(name.as_ptr()) };
    if attributes == INVALID_FILE_ATTRIBUTES {
        return Err(format!("{} could not be inspected.", path.display()));
    }
    Ok(attributes & FILE_ATTRIBUTE_REPARSE_POINT != 0)
}

fn check_acl(
    path: &Path,
    label: &str,
    owner_error: &str,
    owner_ok: &dyn Fn(&str) -> bool,
    writer_ok: &dyn Fn(&str) -> bool,
) -> Result<(), String> {
    let name = wide(&path.to_string_lossy());
    let mut owner: PSID = ptr::null_mut();
    let mut dacl: *mut ACL = ptr::null_mut();
    let mut descriptor: PSECURITY_DESCRIPTOR = ptr::null_mut();

    let status = unsafe {
        GetNamedSecurityInfoW(
            name.as_ptr(),
            SE_FILE_OBJECT,
            OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
            &mut owner,
            ptr::null_mut(),
            &mut dacl,
            ptr::null_mut(),
            &mut descriptor,
        )
    };
    if status != 0 || descriptor.is_null() {
        return Err(format!(
            "The {label} security could not be read ({status})."
        ));
    }
    let _guard = Descriptor(descriptor);

    if owner.is_null() || sid_to_string(owner).is_none_or(|sid| !owner_ok(&sid)) {
        return Err(owner_error.to_string());
    }

    let mut present = 0;
    let mut acl: *mut ACL = ptr::null_mut();
    let mut defaulted = 0;
    if unsafe { GetSecurityDescriptorDacl(descriptor, &mut present, &mut acl, &mut defaulted) } == 0
        || present == 0
        || acl.is_null()
    {
        return Err(format!("The {label} has no discretionary ACL."));
    }

    let count = unsafe { (*acl).AceCount };
    for index in 0..count {
        let mut ace: *mut c_void = ptr::null_mut();
        if unsafe { GetAce(acl, index as u32, &mut ace) } == 0 || ace.is_null() {
            continue;
        }
        let header = unsafe { &*(ace.cast::<ACE_HEADER>()) };
        if header.AceType != ACCESS_ALLOWED_ACE_TYPE {
            continue;
        }

        let allowed = unsafe { &*(ace.cast::<ACCESS_ALLOWED_ACE>()) };
        if allowed.Mask & WRITE_RIGHTS == 0 {
            continue;
        }

        let sid: PSID = (&allowed.SidStart as *const u32 as *mut u32).cast();
        let principal = sid_to_string(sid).unwrap_or_default();
        if !writer_ok(&principal) {
            let shown = if principal.is_empty() {
                "<unresolved>"
            } else {
                &principal
            };
            return Err(format!(
                "The {label} grants write access to untrusted principal '{shown}'."
            ));
        }
    }

    Ok(())
}

fn is_trusted(sid: &str) -> bool {
    matches!(
        sid,
        SYSTEM_SID | ADMINISTRATORS_SID | TRUSTED_INSTALLER_SID
    )
}

/// Windows paths compare case-insensitively, and `%TEMP%` may arrive with a trailing separator.
fn normalise(path: &Path) -> String {
    path.to_string_lossy()
        .trim_end_matches(['\\', '/'])
        .to_ascii_lowercase()
}

fn sid_to_string(sid: PSID) -> Option<String> {
    let mut text: *mut u16 = ptr::null_mut();
    if unsafe { ConvertSidToStringSidW(sid, &mut text) } == 0 || text.is_null() {
        return None;
    }

    let mut length = 0;
    while unsafe { *text.add(length) } != 0 {
        length += 1;
    }
    let value = String::from_utf16_lossy(unsafe { std::slice::from_raw_parts(text, length) });
    unsafe {
        LocalFree(text as HLOCAL);
    }
    Some(value)
}

struct Descriptor(PSECURITY_DESCRIPTOR);

impl Drop for Descriptor {
    fn drop(&mut self) {
        unsafe {
            LocalFree(self.0 as HLOCAL);
        }
    }
}

fn wide(value: &str) -> Vec<u16> {
    use std::os::windows::ffi::OsStrExt;
    std::ffi::OsStr::new(value)
        .encode_wide()
        .chain(Some(0))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nonce_accepts_only_the_issuer_spelling() {
        let value = "0123456789abcdef".repeat(4);
        assert!(Nonce::parse(&value).is_ok());
        assert!(Nonce::parse(&value.to_uppercase()).is_ok());

        for invalid in [
            "",
            "abc",
            &value[..62],
            &format!("{value}0"),
            &"g".repeat(64),
            &"0123456789abcde".to_string().repeat(4), // 60 characters
        ] {
            assert!(Nonce::parse(invalid).is_err(), "{invalid:?} should be refused");
        }
    }

    #[test]
    fn a_nonce_only_matches_itself() {
        let left = Nonce::parse(&"ab".repeat(32)).unwrap();
        let same = Nonce::parse(&"AB".repeat(32)).unwrap();
        let other = Nonce::parse(&"ac".repeat(32)).unwrap();
        assert!(left.matches(&same));
        assert!(!left.matches(&other));
    }

    #[test]
    fn the_window_is_the_v1_two_minutes() {
        let now = OffsetDateTime::parse("2026-10-25T12:00:00Z", &Rfc3339).unwrap();
        let at = |seconds: i64| {
            (now + time::Duration::seconds(seconds))
                .format(&Rfc3339)
                .unwrap()
        };

        assert!(check_window(&at(0), &at(60), now).is_ok());
        assert!(check_window(&at(-120), &at(0), now).is_ok());
        assert!(check_window(&at(-121), &at(0), now).is_err());
        assert!(check_window(&at(121), &at(180), now).is_err());
        assert!(check_window(&at(0), &at(-1), now).is_err());
        assert!(check_window(&at(0), &at(121), now).is_err());
        assert!(check_window("not-a-time", &at(60), now).is_err());
    }

    #[test]
    fn the_exit_codes_are_the_v1_ones() {
        assert_eq!(EngineCode::None as u8, 0);
        assert_eq!(EngineCode::BrokerDenied as u8, 4);
        assert_eq!(EngineCode::BrokerNonce as u8, 5);
        assert_eq!(EngineCode::BrokerSchema as u8, 6);
        assert_eq!(EngineCode::MutexBusy as u8, 7);
        assert_eq!(EngineCode::EngineGeneric as u8, 18);
        assert_eq!(EngineCode::Config as u8, 23);
    }
}
