//! The two local logs v1 kept, at the same paths and with the same record fields:
//! `logs\app-yyyyMMdd.log` (local day, one line per event, 10 MiB rotation) and
//! `operations.jsonl` (one line per terminal). Nothing is sent anywhere, and a logging failure
//! never breaks an operation (v1 design §6.2/§7.5).

use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use time::format_description::well_known::Rfc3339;
use time::OffsetDateTime;

const MAX_LOG_BYTES: u64 = 10 * 1024 * 1024;
const MAX_ROTATIONS: usize = 5;

/// `%LOCALAPPDATA%\SedgManager`, the folder v1 used, so support instructions still work.
pub fn app_dir() -> Option<PathBuf> {
    std::env::var_os("LOCALAPPDATA")
        .map(PathBuf::from)
        .map(|local| local.join("SedgManager"))
}

pub fn log_dir() -> Option<PathBuf> {
    app_dir().map(|directory| directory.join("logs"))
}

pub fn operations_path() -> Option<PathBuf> {
    app_dir().map(|directory| directory.join("operations.jsonl"))
}

/// One terminal record, with v1's field names so an existing reader keeps working.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Operation {
    pub operation_id: String,
    pub action: String,
    pub started_utc: String,
    pub ended_utc: String,
    pub ok: bool,
    pub code: String,
    #[serde(default)]
    pub message: Option<String>,
    #[serde(default)]
    pub transcript_path: Option<String>,
    #[serde(default)]
    pub late_completion: bool,
}

pub fn app(level: &str, message: &str) {
    let Some(directory) = log_dir() else {
        return;
    };
    let now = OffsetDateTime::now_local().unwrap_or_else(|_| OffsetDateTime::now_utc());
    append_app(&directory, now, level, message);
}

fn append_app(directory: &Path, now: OffsetDateTime, level: &str, message: &str) {
    let day = format!("{:04}{:02}{:02}", now.year(), now.month() as u8, now.day());
    let path = directory.join(format!("app-{day}.log"));
    let _ = fs::create_dir_all(directory);
    rotate(&path);
    let stamp = now.format(&Rfc3339).unwrap_or_default();
    let line = format!("{stamp} [{}] {}\r\n", redact(level), redact(message));
    let _ = OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
        .and_then(|mut file| file.write_all(line.as_bytes()));
}

/// Rotates one daily file at the cap across at most five rotations; failures are ignored.
fn rotate(path: &Path) {
    let Ok(metadata) = fs::metadata(path) else {
        return;
    };
    if metadata.len() < MAX_LOG_BYTES {
        return;
    }

    let text = path.to_string_lossy();
    let stem = text.strip_suffix(".log").unwrap_or(&text);
    let _ = fs::remove_file(format!("{stem}-{MAX_ROTATIONS}.log"));
    for index in (1..MAX_ROTATIONS).rev() {
        let from = format!("{stem}-{index}.log");
        if fs::metadata(&from).is_ok() {
            let _ = fs::rename(&from, format!("{stem}-{}.log", index + 1));
        }
    }
    let _ = fs::rename(path, format!("{stem}-1.log"));
}

pub fn record(operation: &Operation) {
    let Some(directory) = app_dir() else {
        return;
    };
    record_to(&directory.join("operations.jsonl"), operation);
}

fn record_to(path: &Path, operation: &Operation) {
    let mut operation = operation.clone();
    operation.message = operation.message.as_deref().map(redact);
    operation.transcript_path = operation.transcript_path.as_deref().map(redact);

    let Ok(line) = serde_json::to_string(&operation) else {
        return;
    };
    if let Some(directory) = path.parent() {
        let _ = fs::create_dir_all(directory);
    }
    let _ = OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .and_then(|mut file| file.write_all(format!("{line}\r\n").as_bytes()));
}

/// Newest first, skipping lines this build cannot read (a hand-edited or future record).
pub fn recent(limit: usize) -> Vec<Operation> {
    let Some(path) = operations_path() else {
        return Vec::new();
    };
    recent_from(&path, limit)
}

fn recent_from(path: &Path, limit: usize) -> Vec<Operation> {
    let Ok(text) = fs::read_to_string(path) else {
        return Vec::new();
    };
    let mut operations: Vec<Operation> = text
        .lines()
        .filter(|line| !line.trim().is_empty())
        .filter_map(|line| serde_json::from_str(line).ok())
        .collect();
    if operations.len() > limit {
        operations.drain(..operations.len() - limit);
    }
    operations.reverse();
    operations
}

/// v1's BR-14 rule: no nonce and no URL password ever reaches the disk.
pub fn redact(text: &str) -> String {
    redact_userinfo(&redact_nonces(text))
}

/// Every 64-hex-character run is nonce-shaped; v1 replaced each match, left to right.
fn redact_nonces(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut output = String::with_capacity(text.len());
    let mut index = 0;
    while index < bytes.len() {
        if index + 64 <= bytes.len()
            && bytes[index..index + 64]
                .iter()
                .all(u8::is_ascii_hexdigit)
        {
            output.push_str("***");
            index += 64;
        } else {
            let character = text[index..].chars().next().expect("a char boundary");
            output.push(character);
            index += character.len_utf8();
        }
    }
    output
}

/// `scheme://user:password@host` becomes `scheme://***@host`, v1's userinfo rule.
fn redact_userinfo(text: &str) -> String {
    let mut output = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(marker) = rest.find("://") {
        output.push_str(&rest[..marker + 3]);
        let tail = &rest[marker + 3..];
        let end = tail
            .find(|character: char| character.is_whitespace() || character == '/')
            .unwrap_or(tail.len());
        let authority = &tail[..end];
        match authority.rfind('@') {
            Some(at) => {
                output.push_str("***");
                output.push_str(&authority[at..]);
            }
            None => output.push_str(authority),
        }
        rest = &tail[end..];
    }
    output.push_str(rest);
    output
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temporary(name: &str) -> PathBuf {
        let directory = std::env::temp_dir().join(format!("sedg-log-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&directory).unwrap();
        directory.join(name)
    }

    #[test]
    fn a_nonce_is_redacted_before_it_reaches_the_disk() {
        let nonce = "0123456789abcdef".repeat(4);
        assert_eq!(
            redact(&format!("pipe SEDG-{nonce}-tail")),
            "pipe SEDG-***-tail"
        );
    }

    #[test]
    fn a_longer_hex_run_keeps_its_tail_like_v1() {
        let run = "a".repeat(70);
        assert_eq!(redact(&run), format!("***{}", "a".repeat(6)));
    }

    #[test]
    fn a_url_password_is_redacted() {
        assert_eq!(
            redact("upstream https://user:secret@dns.example/q?x=1"),
            "upstream https://***@dns.example/q?x=1"
        );
        assert_eq!(redact("https://dns.example/q"), "https://dns.example/q");
    }

    #[test]
    fn ordinary_text_survives_character_for_character() {
        let text = "Đặt DNS — 1.2.3.4 · xong…";
        assert_eq!(redact(text), text);
    }

    #[test]
    fn the_app_log_uses_the_local_day_and_one_leveled_line() {
        let directory = temporary("app.log").parent().unwrap().to_path_buf();
        let now = OffsetDateTime::parse("2026-10-25T23:30:15+07:00", &Rfc3339).unwrap();
        append_app(&directory, now, "info", "hello — bạn");
        let file = directory.join("app-20261025.log");
        let text = fs::read_to_string(&file).unwrap();
        assert!(text.contains("[info] hello — bạn"), "{text}");
        assert!(text.starts_with("2026-10-25T23:30:15+07:00"), "{text}");
    }

    #[test]
    fn the_operation_log_lists_newest_first_and_skips_unreadable_lines() {
        let path = temporary("operations.jsonl");
        let write = |id: &str, ok: bool| {
            let operation = Operation {
                operation_id: id.to_string(),
                action: "setDns".to_string(),
                started_utc: "2026-10-25T00:00:00Z".to_string(),
                ended_utc: "2026-10-25T00:00:01Z".to_string(),
                ok,
                code: "None".to_string(),
                message: Some("done".to_string()),
                transcript_path: None,
                late_completion: false,
            };
            record_to(&path, &operation);
        };
        write("one", true);
        fs::write(&path, format!("{}\nnot json\n", fs::read_to_string(&path).unwrap())).unwrap();
        write("two", false);

        let recent = recent_from(&path, 10);
        assert_eq!(recent.len(), 2, "{recent:?}");
        assert_eq!(recent[0].operation_id, "two");
        assert!(!recent[0].ok);
        assert_eq!(recent[1].operation_id, "one");

        let limited = recent_from(&path, 1);
        assert_eq!(limited.len(), 1);
        assert_eq!(limited[0].operation_id, "two");
    }

    #[test]
    fn a_recorded_message_is_redacted() {
        let path = temporary("operations.jsonl");
        let operation = Operation {
            operation_id: "id".to_string(),
            action: "setUpstream".to_string(),
            started_utc: "2026-10-25T00:00:00Z".to_string(),
            ended_utc: "2026-10-25T00:00:01Z".to_string(),
            ok: false,
            code: "Validation".to_string(),
            message: Some("https://user:pw@dns.example/x".to_string()),
            transcript_path: Some("C:\\logs\\op.log".to_string()),
            late_completion: false,
        };
        record_to(&path, &operation);
        let text = fs::read_to_string(&path).unwrap();
        assert!(text.contains("https://***@dns.example/x"), "{text}");
        assert!(!text.contains("user:pw"), "{text}");
    }
}
