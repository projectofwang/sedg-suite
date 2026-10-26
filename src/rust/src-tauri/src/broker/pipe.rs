//! Named-pipe plumbing for the broker handshake (design §2.3, v1 `BrokerCoordinator` parity).
//!
//! The unelevated app creates the server instance with a DACL limited to the current user,
//! Administrators, and SYSTEM. The elevated broker connects as a client, checks the connecting
//! peer's token before trusting it, and both sides exchange newline-delimited UTF-8.

use std::ffi::{OsStr, OsString};
use std::fs::File;
use std::io::{self, BufRead, BufReader, BufWriter, Read, Write};
use std::os::windows::ffi::OsStrExt;
use std::os::windows::io::{AsRawHandle, FromRawHandle, RawHandle};
use std::path::{Path, PathBuf};
use std::ptr;
use std::thread;
use std::time::{Duration, Instant};

use windows_sys::Win32::Foundation::{
    CloseHandle, GetLastError, LocalFree, ERROR_ALREADY_EXISTS, ERROR_FILE_NOT_FOUND,
    ERROR_PIPE_BUSY, ERROR_PIPE_CONNECTED, ERROR_PIPE_LISTENING, GENERIC_READ, GENERIC_WRITE,
    HANDLE, HLOCAL, INVALID_HANDLE_VALUE,
};use windows_sys::Win32::Security::Authorization::{
    ConvertSidToStringSidW, ConvertStringSecurityDescriptorToSecurityDescriptorW,
    ConvertStringSidToSidW, SetNamedSecurityInfoW, SDDL_REVISION_1, SE_FILE_OBJECT,
};
use windows_sys::Win32::Security::{
    GetTokenInformation, TokenElevation, TokenUser, OWNER_SECURITY_INFORMATION,
    PSECURITY_DESCRIPTOR, PSID, SECURITY_ATTRIBUTES, TOKEN_ELEVATION, TOKEN_QUERY, TOKEN_USER,
};
use windows_sys::Win32::Storage::FileSystem::{
    CreateDirectoryW, CreateFileW, FILE_FLAG_FIRST_PIPE_INSTANCE, OPEN_EXISTING, PIPE_ACCESS_DUPLEX,
};
use windows_sys::Win32::System::Pipes::{
    ConnectNamedPipe, CreateNamedPipeW, GetNamedPipeClientProcessId, SetNamedPipeHandleState,
    WaitNamedPipeW, PIPE_NOWAIT, PIPE_READMODE_BYTE, PIPE_REJECT_REMOTE_CLIENTS, PIPE_TYPE_BYTE,
};
use windows_sys::Win32::System::Threading::{
    CreateMutexW, GetCurrentProcess, OpenProcess, OpenProcessToken,
    PROCESS_QUERY_LIMITED_INFORMATION,
};

/// One request or response line, bounded so a peer cannot exhaust memory through the pipe.
pub const MAX_LINE_BYTES: usize = 64 * 1024;

const PIPE_BUFFER_BYTES: u32 = 64 * 1024;
const CONNECT_POLL: Duration = Duration::from_millis(25);
const MUTEX_NAME: &str = r"Local\Sedg.Broker";
const TOKEN_SELF_SID: &str = "S-1-5-18";
const ADMINISTRATORS_SID: &str = "S-1-5-32-544";

fn wide(value: &str) -> Vec<u16> {
    OsStr::new(value).encode_wide().chain(Some(0)).collect()
}

fn last_error() -> io::Error {
    io::Error::from_raw_os_error(unsafe { GetLastError() } as i32)
}

fn handle(file: &File) -> HANDLE {
    file.as_raw_handle() as HANDLE
}

fn owned(handle: HANDLE) -> io::Result<File> {
    if handle.is_null() || handle == INVALID_HANDLE_VALUE {
        return Err(last_error());
    }
    Ok(unsafe { File::from_raw_handle(handle as RawHandle) })
}

/// The full device path the client opens. The server takes the bare name.
pub fn path(name: &str) -> String {
    format!(r"\\.\pipe\{name}")
}

/// Keeps the SDDL-owned descriptor alive for as long as the attributes that point at it.
struct Descriptor(PSECURITY_DESCRIPTOR);

impl Drop for Descriptor {
    fn drop(&mut self) {
        unsafe {
            LocalFree(self.0 as HLOCAL);
        }
    }
}

fn security_attributes(sddl: &str) -> io::Result<(Descriptor, SECURITY_ATTRIBUTES)> {
    let sddl = wide(sddl);
    let mut raw: PSECURITY_DESCRIPTOR = ptr::null_mut();
    let created = unsafe {
        ConvertStringSecurityDescriptorToSecurityDescriptorW(
            sddl.as_ptr(),
            SDDL_REVISION_1,
            &mut raw,
            ptr::null_mut(),
        )
    };
    if created == 0 {
        return Err(last_error());
    }

    let descriptor = Descriptor(raw);
    let attributes = SECURITY_ATTRIBUTES {
        nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32,
        lpSecurityDescriptor: descriptor.0,
        bInheritHandle: 0,
    };
    Ok((descriptor, attributes))
}

/// The SID of the user running this process, as `S-1-5-…`.
pub fn current_user_sid() -> io::Result<String> {
    unsafe {
        let mut token: HANDLE = ptr::null_mut();
        if OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) == 0 {
            return Err(last_error());
        }

        let mut size = 0u32;
        GetTokenInformation(token, TokenUser, ptr::null_mut(), 0, &mut size);
        if size == 0 {
            CloseHandle(token);
            return Err(last_error());
        }

        // usize words keep the buffer aligned for TOKEN_USER's pointer member.
        let words = (size as usize).div_ceil(std::mem::size_of::<usize>());
        let mut buffer = vec![0usize; words];
        let read = GetTokenInformation(
            token,
            TokenUser,
            buffer.as_mut_ptr().cast(),
            size,
            &mut size,
        );
        CloseHandle(token);
        if read == 0 {
            return Err(last_error());
        }

        let user = &*(buffer.as_ptr().cast::<TOKEN_USER>());
        let mut text: *mut u16 = ptr::null_mut();
        if ConvertSidToStringSidW(user.User.Sid, &mut text) == 0 {
            return Err(last_error());
        }

        let mut length = 0;
        while *text.add(length) != 0 {
            length += 1;
        }
        let sid = String::from_utf16_lossy(std::slice::from_raw_parts(text, length));
        LocalFree(text as HLOCAL);
        Ok(sid)
    }
}

/// Creates a directory whose DACL only the current user, Administrators, and SYSTEM may write.
/// `%TEMP%` can be redirected to a directory others can write (CI's `D:\a\_temp` is one), and the
/// broker refuses a staged script that another principal could swap.
pub(crate) fn create_private_directory(path: &Path) -> io::Result<()> {
    let sid = current_user_sid()?;
    let sddl = format!("D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;FA;;;{sid})");
    let (_descriptor, attributes) = security_attributes(&sddl)?;
    let created = unsafe { CreateDirectoryW(wide(&path.to_string_lossy()).as_ptr(), &attributes) };
    if created == 0 {
        return Err(last_error());
    }
    claim_owned(path)?;
    Ok(())
}

/// Makes `path` owned by the current user. A token that a service launched defaults new objects to
/// its own owner (Administrators on an elevated runner), while the broker requires the user.
pub(crate) fn claim_owned(path: &Path) -> io::Result<()> {
    let sid = wide(&current_user_sid()?);
    let mut raw: PSID = ptr::null_mut();
    if unsafe { ConvertStringSidToSidW(sid.as_ptr(), &mut raw) } == 0 {
        return Err(last_error());
    }
    let _guard = Descriptor(raw as PSECURITY_DESCRIPTOR);
    let name = wide(&path.to_string_lossy());
    let status = unsafe {
        SetNamedSecurityInfoW(
            name.as_ptr() as *mut u16,
            SE_FILE_OBJECT,
            OWNER_SECURITY_INFORMATION,
            raw,
            ptr::null_mut(),
            ptr::null_mut(),
            ptr::null_mut(),
        )
    };
    if status != 0 {
        return Err(io::Error::from_raw_os_error(status as i32));
    }
    Ok(())
}

/// True when the process token carries `TokenElevation`. Query failures are not elevated.
pub fn is_process_elevated(pid: u32) -> bool {
    unsafe {
        let process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
        if process.is_null() {
            return false;
        }

        let mut token: HANDLE = ptr::null_mut();
        let opened = OpenProcessToken(process, TOKEN_QUERY, &mut token) != 0;
        let mut elevation = TOKEN_ELEVATION { TokenIsElevated: 0 };
        let mut returned = 0u32;
        let queried = opened
            && GetTokenInformation(
                token,
                TokenElevation,
                (&mut elevation as *mut TOKEN_ELEVATION).cast(),
                std::mem::size_of::<TOKEN_ELEVATION>() as u32,
                &mut returned,
            ) != 0
            && returned >= std::mem::size_of::<TOKEN_ELEVATION>() as u32;

        if !token.is_null() {
            CloseHandle(token);
        }
        CloseHandle(process);
        queried && elevation.TokenIsElevated != 0
    }
}

/// One broker per session, field v1 `BrokerMutex`: a named mutex shared with Administrators and
/// the current user, so a second elevated launch cannot run a second engine.
pub struct Mutex {
    handle: HANDLE,
}

impl Mutex {
    pub fn acquire(user_sid: &str) -> io::Result<Self> {
        let sddl = format!("D:(A;;GA;;;BA)(A;;GA;;;{user_sid})");
        let (_descriptor, attributes) = security_attributes(&sddl)?;
        let name = wide(MUTEX_NAME);
        let handle = unsafe { CreateMutexW(&attributes, 0, name.as_ptr()) };
        if handle.is_null() {
            return Err(last_error());
        }
        if unsafe { GetLastError() } == ERROR_ALREADY_EXISTS {
            unsafe {
                CloseHandle(handle);
            }
            return Err(io::Error::new(
                io::ErrorKind::AlreadyExists,
                "Another broker instance is already running for this session.",
            ));
        }
        Ok(Self { handle })
    }
}

impl Drop for Mutex {
    fn drop(&mut self) {
        unsafe {
            CloseHandle(self.handle);
        }
    }
}

/// The app-side pipe instance, one client, created before UAC is raised.
pub struct PipeServer {
    name: String,
    pipe: File,
}

impl PipeServer {
    pub fn create(user_sid: &str, nonce: &str) -> io::Result<Self> {
        let name = format!("Sedg.Broker.{user_sid}.{nonce}");
        // GWGR = generic read + generic write: enough for ReadFile/WriteFile, without granting
        // pipe-instance creation or ACL editing to the client.
        let sddl = format!(
            "D:(A;;GWGR;;;{user_sid})(A;;GWGR;;;{ADMINISTRATORS_SID})(A;;GWGR;;;{TOKEN_SELF_SID})"
        );
        let (_descriptor, attributes) = security_attributes(&sddl)?;
        let path = wide(&path(&name));

        let raw = unsafe {
            CreateNamedPipeW(
                path.as_ptr(),
                PIPE_ACCESS_DUPLEX | FILE_FLAG_FIRST_PIPE_INSTANCE,
                // Nonblocking only until the accept loop below; the handle is switched back to
                // blocking mode before any byte is read.
                PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_NOWAIT | PIPE_REJECT_REMOTE_CLIENTS,
                1,
                PIPE_BUFFER_BYTES,
                PIPE_BUFFER_BYTES,
                0,
                &attributes,
            )
        };

        Ok(Self {
            name,
            pipe: owned(raw)?,
        })
    }

    pub fn name(&self) -> &str {
        &self.name
    }

    /// Polls for the client, bounded by `timeout`, then returns the pipe to blocking mode. The
    /// broker client itself retries for 120 s (v1 `ConnectionWaitMilliseconds`).
    pub fn connect_timeout(&self, timeout: Duration) -> io::Result<()> {
        let deadline = Instant::now() + timeout;
        loop {
            let connected = unsafe { ConnectNamedPipe(handle(&self.pipe), ptr::null_mut()) } != 0;
            if connected {
                break;
            }

            match unsafe { GetLastError() } {
                // The client connected between CreateNamedPipeW and ConnectNamedPipe.
                ERROR_PIPE_CONNECTED => break,
                // PIPE_NOWAIT: no client yet. The call is safe to repeat.
                ERROR_PIPE_LISTENING => {
                    if Instant::now() >= deadline {
                        return Err(io::Error::new(
                            io::ErrorKind::TimedOut,
                            "The broker did not connect in time.",
                        ));
                    }
                    thread::sleep(CONNECT_POLL);
                }
                code => return Err(io::Error::from_raw_os_error(code as i32)),
            }
        }

        // PIPE_READMODE_BYTE is zero, which also clears PIPE_NOWAIT: reads must block again.
        let mode = PIPE_READMODE_BYTE;
        let ok = unsafe { SetNamedPipeHandleState(handle(&self.pipe), &mode, ptr::null(), ptr::null()) };
        if ok == 0 {
            return Err(last_error());
        }
        Ok(())
    }

    pub fn client_pid(&self) -> io::Result<u32> {
        let mut pid = 0u32;
        if unsafe { GetNamedPipeClientProcessId(handle(&self.pipe), &mut pid) } != 0 {
            Ok(pid)
        } else {
            Err(last_error())
        }
    }

    /// The peer must be elevated before a single byte is trusted; a query failure is a mismatch.
    pub fn client_is_elevated(&self) -> bool {
        self.client_pid()
            .map(is_process_elevated)
            .unwrap_or(false)
    }

    /// Splits the connected instance into a reader and an independent writer handle.
    pub fn into_halves(self) -> io::Result<(BufReader<File>, BufWriter<File>)> {
        let writer = self.pipe.try_clone()?;
        Ok((BufReader::new(self.pipe), BufWriter::new(writer)))
    }
}

/// The broker-side client: waits for the app's instance for up to `timeout`.
pub fn connect(name: &str, timeout: Duration) -> io::Result<(BufReader<File>, BufWriter<File>)> {
    let path = wide(&path(name));
    let deadline = Instant::now() + timeout;

    loop {
        let raw = unsafe {
            CreateFileW(
                path.as_ptr(),
                GENERIC_READ | GENERIC_WRITE,
                0,
                ptr::null(),
                OPEN_EXISTING,
                0,
                ptr::null_mut(),
            )
        };
        if raw != INVALID_HANDLE_VALUE && !raw.is_null() {
            let file = unsafe { File::from_raw_handle(raw as RawHandle) };
            let writer = BufWriter::new(file.try_clone()?);
            return Ok((BufReader::new(file), writer));
        }

        let code = unsafe { GetLastError() };
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(io::Error::from_raw_os_error(code as i32));
        }

        match code {
            ERROR_PIPE_BUSY => {
                let slice = remaining.min(Duration::from_millis(250));
                unsafe {
                    WaitNamedPipeW(path.as_ptr(), slice.as_millis() as u32);
                }
            }
            // The server instance does not exist yet (the app raises UAC while we wait).
            ERROR_FILE_NOT_FOUND => thread::sleep(remaining.min(Duration::from_millis(50))),
            _ => return Err(io::Error::from_raw_os_error(code as i32)),
        }
    }
}

/// Reads one newline-terminated UTF-8 line whose payload (without `\r\n`) is at most `limit` bytes.
/// `Ok(None)` is a clean end of stream.
pub fn read_line(reader: &mut impl BufRead, limit: usize) -> io::Result<Option<String>> {
    let mut bytes = Vec::new();
    // The extra two bytes leave room for the terminator so the payload check is exact.
    let read = reader
        .by_ref()
        .take(limit as u64 + 2)
        .read_until(b'\n', &mut bytes)?;
    if read == 0 {
        return Ok(None);
    }
    if bytes.last() == Some(&b'\n') {
        bytes.pop();
    }
    if bytes.last() == Some(&b'\r') {
        bytes.pop();
    }
    if bytes.len() > limit {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("The line exceeds {limit} bytes."),
        ));
    }
    String::from_utf8(bytes)
        .map(Some)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "The line is not UTF-8."))
}

pub fn write_line(writer: &mut impl Write, line: &str) -> io::Result<()> {
    writer.write_all(line.as_bytes())?;
    writer.write_all(b"\n")?;
    writer.flush()
}

/// The pinned interpreter, never PATH-resolved (v1 rule).
pub fn pinned_powershell() -> PathBuf {
    let root = std::env::var_os("SystemRoot")
        .unwrap_or_else(|| OsString::from(r"C:\Windows"));
    PathBuf::from(root).join(r"System32\WindowsPowerShell\v1.0\powershell.exe")
}
