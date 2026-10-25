//! Setup mode (design §2.6): the preflight gate, staging the one-time installer, and the one
//! download that precedes the first install.
//!
//! Nothing here elevates or runs a script. The app stages the installer and hands its path to the
//! broker, which re-validates it (see `broker::validate_setup_script`) before spawning PowerShell.

use std::fmt;
use std::mem::size_of;
use std::path::{Path, PathBuf};

use serde::Serialize;
use windows_sys::Win32::Networking::WinInet::InternetGetConnectedState;
use windows_sys::Win32::Storage::FileSystem::GetDiskFreeSpaceExW;
use windows_sys::Win32::System::LibraryLoader::{GetModuleHandleW, GetProcAddress};
use windows_sys::Win32::System::SystemInformation::{
    GetNativeSystemInfo, PROCESSOR_ARCHITECTURE_AMD64, SYSTEM_INFO,
};

use crate::http;
use crate::manifest::MANIFEST_URL;

const MINIMUM_FREE_BYTES: u64 = 512 * 1024 * 1024;
const WINDOWS_11_BUILD: u32 = 22000;
const MAX_INSTALLER_BYTES: usize = 8 * 1024 * 1024;
/// `RtlGetVersion` reports the real build; `GetVersionExW` lies without a manifest.
const RTL_GET_VERSION: &[u8] = b"RtlGetVersion\0";

#[derive(Debug)]
pub enum SetupError {
    Preflight(String),
    Http(String),
    Io(String),
}

impl fmt::Display for SetupError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Preflight(message) | Self::Http(message) | Self::Io(message) => {
                formatter.write_str(message)
            }
        }
    }
}

impl std::error::Error for SetupError {}

/// What the machine reports, read once per check. Tests construct this directly.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Facts {
    /// `RtlGetVersion` build; `None` when it could not be read.
    pub os_build: Option<u32>,
    pub os_arch_x64: bool,
    pub process_x64: bool,
    pub engine_present: bool,
    pub free_bytes: Option<u64>,
    pub online: Option<bool>,
}

impl Facts {
    /// Reads the host without elevating and without a network call.
    pub fn read() -> Self {
        Self {
            os_build: os_build(),
            os_arch_x64: native_arch_is_x64(),
            process_x64: size_of::<usize>() == 8,
            engine_present: Path::new(crate::broker::ENGINE_SCRIPT).is_file(),
            free_bytes: free_bytes(),
            online: online(),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Level {
    Ok,
    Warn,
    Block,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Check {
    pub code: &'static str,
    pub level: Level,
    pub detail: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Preflight {
    pub checks: Vec<Check>,
    pub can_install: bool,
}

/// v1 `Preflight`: the OS and architecture are gates; disk and network are warnings. A missing
/// engine is the normal setup state, and an existing one is a warning because Install repairs it.
pub fn evaluate(facts: &Facts) -> Preflight {
    let mut checks = Vec::with_capacity(5);

    let os = match facts.os_build {
        Some(build) if build >= WINDOWS_11_BUILD => Check {
            code: "preflight.os",
            level: Level::Ok,
            detail: Some(format!("build {build}")),
        },
        Some(build) => Check {
            code: "preflight.os",
            level: Level::Block,
            detail: Some(format!("build {build}")),
        },
        None => Check {
            code: "preflight.os",
            level: Level::Block,
            detail: None,
        },
    };
    checks.push(os);

    checks.push(Check {
        code: "preflight.arch",
        level: if facts.os_arch_x64 && facts.process_x64 {
            Level::Ok
        } else {
            Level::Block
        },
        detail: None,
    });

    if let Some(free) = facts.free_bytes {
        checks.push(if free < MINIMUM_FREE_BYTES {
            Check {
                code: "preflight.disk",
                level: Level::Warn,
                detail: Some(format!("{} MB", free / (1024 * 1024))),
            }
        } else {
            Check {
                code: "preflight.disk",
                level: Level::Ok,
                detail: Some(format!("{} MB", free / (1024 * 1024))),
            }
        });
    }

    if let Some(online) = facts.online {
        checks.push(Check {
            code: "preflight.network",
            level: if online { Level::Ok } else { Level::Warn },
            detail: None,
        });
    }

    checks.push(Check {
        code: "preflight.enginePresent",
        level: if facts.engine_present {
            Level::Warn
        } else {
            Level::Ok
        },
        detail: None,
    });

    let can_install = checks.iter().all(|check| check.level != Level::Block);
    Preflight {
        checks,
        can_install,
    }
}

/// The staged installer and the temporary directory that owns it. Dropping the guard removes
/// both; the broker validates the path again before it runs.
pub struct Staged {
    directory: PathBuf,
    script: PathBuf,
}

impl Staged {
    pub fn create(installer: &[u8]) -> Result<Self, SetupError> {
        if installer.is_empty() {
            return Err(SetupError::Io(
                "The installer download is empty; nothing was staged.".to_string(),
            ));
        }

        let directory = std::env::temp_dir().join(format!("sedg-setup-{}", uuid::Uuid::new_v4()));
        crate::broker::pipe::create_private_directory(&directory).map_err(|error| {
            SetupError::Io(format!(
                "The staging directory {} could not be created: {error}",
                directory.display()
            ))
        })?;

        let script = directory.join("manager.ps1");
        if let Err(error) = std::fs::write(&script, installer) {
            let _ = std::fs::remove_dir_all(&directory);
            return Err(SetupError::Io(format!(
                "The installer could not be staged at {}: {error}",
                script.display()
            )));
        }

        Ok(Self { directory, script })
    }

    pub fn script(&self) -> &Path {
        &self.script
    }
}

impl Drop for Staged {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.directory);
    }
}

/// The installer lives beside the manifest on the pinned host.
pub fn installer_url() -> String {
    format!(
        "{}/installer.ps1",
        MANIFEST_URL.trim_end_matches("/approved-releases.json")
    )
}

/// The first install's one download. There is no hash pin for the installer (spec N-07): TLS to
/// the pinned host is the trust, and the engine refuses to run when its version disagrees with the
/// manifest (`installer.ps1:912`).
pub fn download_installer() -> Result<Vec<u8>, SetupError> {
    let url = installer_url();
    let bytes =
        http::get(&url, MAX_INSTALLER_BYTES).map_err(|error| SetupError::Http(error.to_string()))?;

    if bytes.is_empty() || !String::from_utf8_lossy(&bytes).contains("InstallerVersion") {
        return Err(SetupError::Http(format!(
            "The download from {url} is not the gateway installer ({} bytes).",
            bytes.len()
        )));
    }

    crate::log::app(
        "info",
        &format!(
            "setup: downloaded {url} ({} bytes); the engine verifies its version against the approved manifest.",
            bytes.len()
        ),
    );
    Ok(bytes)
}


fn os_build() -> Option<u32> {
    let module = unsafe { GetModuleHandleW(wide("ntdll.dll").as_ptr()) };
    if module.is_null() {
        return None;
    }

    let address = unsafe { GetProcAddress(module, RTL_GET_VERSION.as_ptr()) };
    let rtl_get_version: Option<unsafe extern "system" fn(*mut OsVersionInfoW) -> i32> =
        address.map(|address| unsafe { std::mem::transmute(address) });
    let rtl_get_version = rtl_get_version?;

    let mut info: OsVersionInfoW = unsafe { std::mem::zeroed() };
    info.size = size_of::<OsVersionInfoW>() as u32;
    if unsafe { rtl_get_version(&mut info) } != 0 {
        return None;
    }
    Some(info.build)
}

fn native_arch_is_x64() -> bool {
    let mut info = SYSTEM_INFO::default();
    unsafe { GetNativeSystemInfo(&mut info) };
    unsafe { info.Anonymous.Anonymous.wProcessorArchitecture == PROCESSOR_ARCHITECTURE_AMD64 }
}

fn free_bytes() -> Option<u64> {
    let root = wide(r"C:\");
    let mut free = 0u64;
    let ok = unsafe {
        GetDiskFreeSpaceExW(
            root.as_ptr(),
            &mut free,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
        )
    };
    (ok != 0).then_some(free)
}

fn online() -> Option<bool> {
    let mut flags = 0u32;
    Some(unsafe { InternetGetConnectedState(&mut flags, 0) } != 0)
}

fn wide(value: &str) -> Vec<u16> {
    value.encode_utf16().chain(Some(0)).collect()
}

/// `RTL_OSVERSIONINFOW`; windows-sys exposes only the identical `OSVERSIONINFOW`.
#[repr(C)]
struct OsVersionInfoW {
    size: u32,
    major: u32,
    minor: u32,
    build: u32,
    platform_id: u32,
    service_pack: [u16; 128],
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_host_facts_are_readable_without_a_panic() {
        let facts = Facts::read();
        assert!(facts.os_build.is_some(), "RtlGetVersion reports a build");
        assert!(facts.os_arch_x64, "this build targets x64");
        assert!(facts.process_x64);
        assert!(facts.free_bytes.is_some(), "C: reports free space");
    }
}
