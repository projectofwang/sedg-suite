//! The approved manifest (design §2.3): the only statement of what the distribution host is
//! allowed to hand this app. It is fetched over HTTPS, and every pin is checked here before a
//! later task downloads, stages, or runs anything.

use std::collections::BTreeMap;
use std::ffi::c_void;
use std::fmt;
use std::fs::File;
use std::io::Read;
use std::path::Path;
use std::ptr;

use serde::Deserialize;
use serde_json::Value;
use windows_sys::Win32::Security::Cryptography::{
    BCryptCloseAlgorithmProvider, BCryptCreateHash, BCryptDestroyHash, BCryptFinishHash,
    BCryptHashData, BCryptOpenAlgorithmProvider, BCRYPT_SHA256_ALGORITHM,
};

/// The pinned host, same value as `installer.ps1` `$script:manifestUrl`.
pub const MANIFEST_URL: &str = "https://dl.taiyuanwangjie.dpdns.org/approved-releases.json";
const MAX_BODY_BYTES: usize = 1024 * 1024;
const ASSET_PREFIX: &str = "sedg-manager-win-x64-";

#[derive(Debug)]
pub enum ManifestError {
    /// The host could not be reached, answered with a non-200 status, or was not HTTPS.
    Transport(String),
    /// The document parsed but is not an approved manifest.
    Invalid(String),
    /// A local file could not be read.
    Io(String),
    HashMismatch { expected: String, actual: String },
}

impl fmt::Display for ManifestError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Transport(message) => write!(formatter, "{message}"),
            Self::Invalid(message) => write!(formatter, "The approved manifest is invalid: {message}"),
            Self::Io(message) => write!(formatter, "{message}"),
            Self::HashMismatch { expected, actual } => write!(
                formatter,
                "SHA-256 mismatch: expected {expected}, the file is {actual}."
            ),
        }
    }
}

impl std::error::Error for ManifestError {}

#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
pub struct InstallerPin {
    pub version: String,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
pub struct ManagerPin {
    pub repository: String,
    pub tag: String,
    pub asset: String,
    pub sha256: String,
}

impl ManagerPin {
    /// The tag without its optional `v`, which is what release assets carry.
    pub fn version(&self) -> &str {
        self.tag.strip_prefix('v').unwrap_or(&self.tag)
    }
}

/// A component the app only displays or hands to the engine; the engine owns its download.
#[derive(Clone, Debug, Default, Deserialize, PartialEq, Eq)]
pub struct ComponentPin {
    pub repository: Option<String>,
    pub tag: Option<String>,
    pub version: Option<String>,
    pub asset: Option<String>,
    pub url: Option<String>,
    pub sha256: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Manifest {
    pub installer: InstallerPin,
    pub manager: ManagerPin,
    pub components: BTreeMap<String, ComponentPin>,
}

#[derive(Deserialize)]
struct Raw {
    schema: u32,
    policy: String,
    installer: InstallerPin,
    components: BTreeMap<String, Value>,
}

impl Manifest {
    pub fn parse(text: &str) -> Result<Self, ManifestError> {
        let raw: Raw = serde_json::from_str(text)
            .map_err(|error| ManifestError::Invalid(error.to_string()))?;

        // v1 `Get-ApprovedManifest`: an unknown schema or policy is a refusal, never a fallback.
        if raw.schema != 1 {
            return Err(ManifestError::Invalid(format!(
                "schema {} is not 1",
                raw.schema
            )));
        }
        if raw.policy != "approved-only" {
            return Err(ManifestError::Invalid(format!(
                "policy {:?} is not \"approved-only\"",
                raw.policy
            )));
        }
        if !is_version(&raw.installer.version) {
            return Err(ManifestError::Invalid(format!(
                "installer.version {:?} is not a version",
                raw.installer.version
            )));
        }

        let manager = raw
            .components
            .get("manager")
            .ok_or_else(|| ManifestError::Invalid("components.manager is missing".to_string()))?;
        let manager: ManagerPin = serde_json::from_value(manager.clone())
            .map_err(|error| ManifestError::Invalid(format!("components.manager: {error}")))?;

        // v1 `Get-PinnedManagerSource` shape rules: the tag names the version and the asset is
        // exactly that version's archive, so a mismatched pin cannot slip through.
        if !is_version(&manager.tag) {
            return Err(ManifestError::Invalid(format!(
                "the manager tag {:?} is not a version",
                manager.tag
            )));
        }
        if !is_sha256(manager.sha256.trim()) {
            return Err(ManifestError::Invalid(
                "the manager sha256 is not 64 hexadecimal characters".to_string(),
            ));
        }
        if manager.repository.trim().is_empty() {
            return Err(ManifestError::Invalid(
                "the manager repository is empty".to_string(),
            ));
        }
        let asset = format!("{ASSET_PREFIX}{}.zip", manager.version());
        if manager.asset != asset {
            return Err(ManifestError::Invalid(format!(
                "the manager asset {:?} does not match the tag (expected {asset:?})",
                manager.asset
            )));
        }

        let components = raw
            .components
            .into_iter()
            .filter(|(name, _)| name != "manager")
            .filter_map(|(name, value)| serde_json::from_value(value).ok().map(|pin| (name, pin)))
            .collect();

        Ok(Self {
            installer: raw.installer,
            manager,
            components,
        })
    }
}

pub fn fetch(url: &str) -> Result<Manifest, ManifestError> {
    let body = crate::http::get(url, MAX_BODY_BYTES)
        .map_err(|error| ManifestError::Transport(error.to_string()))?;
    let text = String::from_utf8(body)
        .map_err(|_| ManifestError::Invalid("the manifest is not UTF-8".to_string()))?;
    Manifest::parse(&text)
}

pub fn verify_sha256(path: &Path, expected: &str) -> Result<(), ManifestError> {
    let expected = expected.trim().to_ascii_lowercase();
    if !is_sha256(&expected) {
        return Err(ManifestError::Invalid(format!(
            "The expected SHA-256 is not 64 hexadecimal characters: {expected:?}"
        )));
    }

    let actual = file_sha256(path)?;
    if actual != expected {
        return Err(ManifestError::HashMismatch { expected, actual });
    }
    Ok(())
}

fn is_version(value: &str) -> bool {
    let digits = value.strip_prefix('v').unwrap_or(value);
    !digits.is_empty()
        && digits
            .split('.')
            .all(|part| !part.is_empty() && part.bytes().all(|byte| byte.is_ascii_digit()))
}

fn is_sha256(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}

/// The SHA-256 of the file's bytes, streamed so an archive is never held in memory.
fn file_sha256(path: &Path) -> Result<String, ManifestError> {
    let mut file = File::open(path).map_err(|error| {
        ManifestError::Io(format!("{} could not be opened: {error}", path.display()))
    })?;

    let mut algorithm = ptr::null_mut();
    let status = unsafe {
        BCryptOpenAlgorithmProvider(&mut algorithm, BCRYPT_SHA256_ALGORITHM, ptr::null(), 0)
    };
    if status < 0 {
        return Err(ManifestError::Io(format!(
            "The SHA-256 provider could not be opened (NTSTATUS {status})."
        )));
    }
    let algorithm = Algorithm(algorithm);

    let mut hasher = ptr::null_mut();
    let status =
        unsafe { BCryptCreateHash(algorithm.0, &mut hasher, ptr::null_mut(), 0, ptr::null(), 0, 0) };
    if status < 0 {
        return Err(ManifestError::Io(format!(
            "The SHA-256 hash could not be created (NTSTATUS {status})."
        )));
    }
    let hasher = Hasher(hasher);

    let mut buffer = vec![0u8; crate::http::READ_CHUNK_BYTES as usize];
    loop {
        let read = file.read(&mut buffer).map_err(|error| {
            ManifestError::Io(format!("{} could not be read: {error}", path.display()))
        })?;
        if read == 0 {
            break;
        }
        let status = unsafe { BCryptHashData(hasher.0, buffer.as_ptr(), read as u32, 0) };
        if status < 0 {
            return Err(ManifestError::Io(format!(
                "The SHA-256 hash could not be updated (NTSTATUS {status})."
            )));
        }
    }

    let mut digest = [0u8; 32];
    let status =
        unsafe { BCryptFinishHash(hasher.0, digest.as_mut_ptr(), digest.len() as u32, 0) };
    if status < 0 {
        return Err(ManifestError::Io(format!(
            "The SHA-256 hash could not be finished (NTSTATUS {status})."
        )));
    }

    Ok(digest.iter().map(|byte| format!("{byte:02x}")).collect())
}

struct Algorithm(*mut c_void);

impl Drop for Algorithm {
    fn drop(&mut self) {
        unsafe {
            BCryptCloseAlgorithmProvider(self.0, 0);
        }
    }
}

struct Hasher(*mut c_void);

impl Drop for Hasher {
    fn drop(&mut self) {
        unsafe {
            BCryptDestroyHash(self.0);
        }
    }
}
