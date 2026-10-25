//! One HTTPS GET through the system stack (WinHTTP): no extra crate, the OS certificate store,
//! the system proxy, and redirects handled by the platform. Only HTTPS is accepted.

use std::ffi::c_void;
use std::fmt;
use std::ptr;

use url::{Position, Url};
use windows_sys::Win32::Networking::WinHttp::{
    WinHttpCloseHandle, WinHttpConnect, WinHttpOpen, WinHttpOpenRequest, WinHttpQueryDataAvailable,
    WinHttpQueryHeaders, WinHttpReadData, WinHttpReceiveResponse, WinHttpSendRequest,
    WinHttpSetTimeouts, WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, WINHTTP_FLAG_SECURE,
    WINHTTP_QUERY_FLAG_NUMBER, WINHTTP_QUERY_STATUS_CODE,
};

#[derive(Debug)]
pub enum HttpError {
    /// The URL itself is unusable; no socket was opened.
    Url(String),
    /// The host could not be reached, answered with a non-200 status, or sent too much.
    Transport(String),
}

impl fmt::Display for HttpError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Url(message) | Self::Transport(message) => formatter.write_str(message),
        }
    }
}

impl std::error::Error for HttpError {}

/// v1 `Invoke-WebRequest -TimeoutSec 30`.
pub const TIMEOUT_MS: i32 = 30_000;
pub const READ_CHUNK_BYTES: u32 = 64 * 1024;
/// Same agent string as `installer.ps1`, so the host sees one client family.
pub const USER_AGENT: &str = "Serverless-Edge-DNS-Gateway-Installer";

pub fn get(url: &str, max_bytes: usize) -> Result<Vec<u8>, HttpError> {
    let parsed = Url::parse(url).map_err(|error| HttpError::Url(format!("The URL is invalid: {error}")))?;
    if parsed.scheme() != "https" {
        return Err(HttpError::Url(format!("The URL must use HTTPS: {url}")));
    }
    let host = parsed
        .host_str()
        .ok_or_else(|| HttpError::Url("The URL has no host.".to_string()))?;
    let port = parsed
        .port_or_known_default()
        .ok_or_else(|| HttpError::Url("The URL has no port.".to_string()))?;
    let target = wide(&parsed[Position::BeforePath..]);
    let host = wide(host);
    let agent = wide(USER_AGENT);
    let verb = wide("GET");

    unsafe {
        let session = Handle::new(WinHttpOpen(
            agent.as_ptr(),
            WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,
            ptr::null(),
            ptr::null(),
            0,
        ))
        .ok_or_else(|| transport_error("The HTTPS session could not be opened"))?;

        if WinHttpSetTimeouts(
            session.0,
            TIMEOUT_MS,
            TIMEOUT_MS,
            TIMEOUT_MS,
            TIMEOUT_MS,
        ) == 0
        {
            return Err(transport_error("The HTTPS timeouts could not be set"));
        }

        let connect = Handle::new(WinHttpConnect(session.0, host.as_ptr(), port, 0))
            .ok_or_else(|| transport_error("The host could not be reached"))?;

        let request = Handle::new(WinHttpOpenRequest(
            connect.0,
            verb.as_ptr(),
            target.as_ptr(),
            ptr::null(),
            ptr::null(),
            ptr::null(),
            WINHTTP_FLAG_SECURE,
        ))
        .ok_or_else(|| transport_error("The HTTPS request could not be created"))?;

        if WinHttpSendRequest(request.0, ptr::null(), 0, ptr::null(), 0, 0, 0) == 0 {
            return Err(transport_error("The HTTPS request could not be sent"));
        }
        if WinHttpReceiveResponse(request.0, ptr::null_mut()) == 0 {
            return Err(transport_error("The host did not answer"));
        }

        let mut status = 0u32;
        let mut length = std::mem::size_of::<u32>() as u32;
        if WinHttpQueryHeaders(
            request.0,
            WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
            ptr::null(),
            &mut status as *mut u32 as *mut c_void,
            &mut length,
            ptr::null_mut(),
        ) == 0
        {
            return Err(transport_error("The HTTP status could not be read"));
        }
        if status != 200 {
            return Err(HttpError::Transport(format!(
                "The host answered HTTP {status}."
            )));
        }

        let mut body = Vec::new();
        loop {
            let mut available = 0u32;
            if WinHttpQueryDataAvailable(request.0, &mut available) == 0 {
                return Err(transport_error("The response body could not be read"));
            }
            if available == 0 {
                break;
            }

            let take = available.min(READ_CHUNK_BYTES);
            let mut chunk = vec![0u8; take as usize];
            let mut read = 0u32;
            if WinHttpReadData(request.0, chunk.as_mut_ptr() as *mut c_void, take, &mut read) == 0 {
                return Err(transport_error("The response body could not be read"));
            }
            if read == 0 {
                break;
            }
            body.extend_from_slice(&chunk[..read as usize]);
            if body.len() > max_bytes {
                return Err(HttpError::Transport(format!(
                    "The response is larger than {max_bytes} bytes."
                )));
            }
        }

        Ok(body)
    }
}

fn transport_error(what: &str) -> HttpError {
    HttpError::Transport(format!("{what}: {}", std::io::Error::last_os_error()))
}

fn wide(value: &str) -> Vec<u16> {
    value.encode_utf16().chain(Some(0)).collect()
}

/// A WinHTTP handle that closes on every exit path.
struct Handle(*mut c_void);

impl Handle {
    unsafe fn new(raw: *mut c_void) -> Option<Self> {
        (!raw.is_null()).then_some(Self(raw))
    }
}

impl Drop for Handle {
    fn drop(&mut self) {
        unsafe {
            WinHttpCloseHandle(self.0);
        }
    }
}
