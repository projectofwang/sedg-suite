//! Engine protocol v1 (design §4.1-§4.3): one JSONL request line in,
//! hello/event/progress/result out.
//!
//! The wire schema is owned by `src/Sedg.Protocol`; this module is a port that keeps the same
//! required fields, the same closed vocabularies, and the same refusal of unknown members, so an
//! engine that satisfies one client satisfies the other.

use std::net::IpAddr;

use serde::{Deserialize, Serialize, Serializer};
use serde_json::{json, Value};
use uuid::Uuid;

pub const PROTOCOL_VERSION: u32 = 1;

/// The closed action vocabulary. The broker allow-list is a strict subset.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Deserialize)]
pub enum Action {
    Status,
    Install,
    Update,
    Pause,
    Resume,
    Restart,
    Uninstall,
    Purge,
    SetUpstream,
    SetDns,
    RestoreEngine,
    SetLanguage,
    TestCdnOptimization,
}

impl Action {
    /// The engine's `ProtocolAction` name, verbatim (PascalCase, not camelCase).
    pub fn wire(self) -> &'static str {
        match self {
            Self::Status => "Status",
            Self::Install => "Install",
            Self::Update => "Update",
            Self::Pause => "Pause",
            Self::Resume => "Resume",
            Self::Restart => "Restart",
            Self::Uninstall => "Uninstall",
            Self::Purge => "Purge",
            Self::SetUpstream => "SetUpstream",
            Self::SetDns => "SetDns",
            Self::RestoreEngine => "RestoreEngine",
            Self::SetLanguage => "SetLanguage",
            Self::TestCdnOptimization => "TestCdnOptimization",
        }
    }
}

impl Serialize for Action {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(self.wire())
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum UpstreamMode {
    ResetDefaults,
    Custom,
}

impl UpstreamMode {
    fn wire(self) -> &'static str {
        match self {
            Self::ResetDefaults => "resetDefaults",
            Self::Custom => "custom",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Language {
    En,
    Vi,
}

impl Language {
    fn wire(self) -> &'static str {
        match self {
            Self::En => "en",
            Self::Vi => "vi",
        }
    }
}

/// Everything the app can put into a request. Each action reads only the fields it owns, so the
/// default value is a valid request for every argument-less action.
#[derive(Clone, Debug, Default)]
pub struct ActionInput {
    pub install_clean: bool,
    pub upstream_mode: Option<UpstreamMode>,
    pub upstream_url: Option<String>,
    pub servers: Vec<String>,
    pub language: Option<Language>,
}

/// Builds the per-action `args` object, mirroring the v1 app mapping and the engine's fixed
/// schemas: only the documented fields are emitted, and an invalid input fails before any spawn.
pub fn args_for(action: Action, input: &ActionInput) -> Result<Value, String> {
    match action {
        Action::Install => Ok(if input.install_clean {
            json!({ "mode": "clean" })
        } else {
            json!({})
        }),

        Action::SetUpstream => {
            let mode = input
                .upstream_mode
                .ok_or("Choose 'resetDefaults' or 'custom' for the upstream.")?;
            match mode {
                UpstreamMode::ResetDefaults => {
                    if input.upstream_url.is_some() {
                        return Err(
                            "A custom upstream URL has no meaning when the mode is 'resetDefaults'."
                                .to_string(),
                        );
                    }
                    Ok(json!({ "mode": mode.wire() }))
                }
                UpstreamMode::Custom => {
                    let url = input.upstream_url.as_deref().ok_or(
                        "An upstream URL is required when the mode is 'custom'.",
                    )?;
                    if !is_valid_upstream_url(url) {
                        return Err("The upstream URL must be an absolute https, tls, h3, or quic URL with a host.".to_string());
                    }
                    Ok(json!({ "mode": mode.wire(), "upstreamUrl": url }))
                }
            }
        }

        Action::SetDns => {
            let servers = distinct_non_empty(input.servers.iter().map(String::as_str));
            if servers.is_empty() || servers.len() > 4 {
                return Err("Enter 1 to 4 DNS server addresses.".to_string());
            }
            for address in &servers {
                if address.parse::<IpAddr>().is_err() {
                    return Err(format!("'{address}' is not an IPv4 or IPv6 address."));
                }
            }
            Ok(json!({ "servers": servers }))
        }

        Action::SetLanguage => {
            let language = input.language.ok_or("Choose a language.")?;
            Ok(json!({ "language": language.wire() }))
        }

        _ => Ok(json!({})),
    }
}

/// Splits the DNS text box the way the v1 app does: commas and any whitespace, trimmed, de-duplicated.
pub fn split_servers(raw: &str) -> Vec<String> {
    distinct_non_empty(raw.split([',', ' ', '\t', '\r', '\n']))
}

fn distinct_non_empty<'a>(parts: impl Iterator<Item = &'a str>) -> Vec<String> {
    let mut kept: Vec<String> = Vec::new();
    for part in parts {
        let part = part.trim();
        if !part.is_empty() && !kept.iter().any(|seen| seen == part) {
            kept.push(part.to_string());
        }
    }
    kept
}

fn is_valid_upstream_url(value: &str) -> bool {
    if value.trim().is_empty() || value.contains(['\r', '\n']) {
        return false;
    }

    match url::Url::parse(value) {
        Ok(parsed) => matches!(parsed.scheme(), "https" | "tls" | "h3" | "quic")
            && parsed.host_str().is_some_and(|host| !host.is_empty()),
        Err(_) => false,
    }
}

/// Validates an `args` object received from the wire against the engine's fixed schema
/// (`ArgumentSchemas`): unknown fields are refused, required fields are checked, and the broker
/// never forwards bytes it has not understood.
pub fn validate_args(action: Action, args: &Value) -> Result<(), String> {
    let object = args
        .as_object()
        .ok_or("args must be a JSON object.")?;

    match action {
        Action::Install => {
            reject_unknown(object, action, &["mode"])?;
            if let Some(mode) = object.get("mode") {
                if mode.as_str() != Some("clean") {
                    return Err("Field 'mode' must be 'clean' when provided.".to_string());
                }
            }
        }

        Action::SetUpstream => {
            reject_unknown(object, action, &["mode", "upstreamUrl"])?;
            let mode = object
                .get("mode")
                .and_then(Value::as_str)
                .ok_or("Field 'mode' is required and must be 'resetDefaults' or 'custom'.")?;
            if !matches!(mode, "resetDefaults" | "custom") {
                return Err("Field 'mode' must be 'resetDefaults' or 'custom'.".to_string());
            }

            if let Some(url) = object.get("upstreamUrl") {
                if !url.is_string() && !url.is_null() {
                    return Err("Field 'upstreamUrl' must be a string.".to_string());
                }
            }

            if mode == "custom" {
                let url = object
                    .get("upstreamUrl")
                    .and_then(Value::as_str)
                    .ok_or("Field 'upstreamUrl' is required when mode is 'custom'.")?;
                if !is_valid_upstream_url(url) {
                    return Err(
                        "Field 'upstreamUrl' must be an absolute https/tls/h3/quic URL with a host."
                            .to_string(),
                    );
                }
            }
        }

        Action::SetDns => {
            reject_unknown(object, action, &["servers"])?;
            let servers = object
                .get("servers")
                .and_then(Value::as_array)
                .ok_or("Field 'servers' is required and must be an array.")?;
            if servers.is_empty() || servers.len() > 4 {
                return Err("Field 'servers' must contain 1 to 4 addresses.".to_string());
            }
            for (index, server) in servers.iter().enumerate() {
                let text = server.as_str().ok_or_else(|| {
                    format!("Field 'servers[{index}]' is not a parseable IPv4/IPv6 address.")
                })?;
                if text.trim().parse::<IpAddr>().is_err() {
                    return Err(format!(
                        "Field 'servers[{index}]' is not a parseable IPv4/IPv6 address."
                    ));
                }
            }
        }

        Action::SetLanguage => {
            reject_unknown(object, action, &["language"])?;
            if !matches!(object.get("language").and_then(Value::as_str), Some("en" | "vi")) {
                return Err("Field 'language' must be 'en' or 'vi'.".to_string());
            }
        }

        _ => {
            if let Some(key) = object.keys().next() {
                return Err(format!(
                    "Unknown field '{key}' for action '{}'.",
                    action.wire()
                ));
            }
        }
    }

    Ok(())
}

fn reject_unknown(
    object: &serde_json::Map<String, Value>,
    action: Action,
    allowed: &[&str],
) -> Result<(), String> {
    for key in object.keys() {
        if !allowed.contains(&key.as_str()) {
            return Err(format!(
                "Unknown field '{key}' for action '{}'.",
                action.wire()
            ));
        }
    }
    Ok(())
}

/// One request line. `type` is fixed, and every value is the engine's own spelling.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Request {
    #[serde(rename = "type")]
    kind: &'static str,
    pub protocol_version: u32,
    pub action: Action,
    pub operation_id: String,
    pub args: Value,
}

impl Request {
    pub fn new(action: Action, args: Value) -> Self {
        Self {
            kind: "request",
            protocol_version: PROTOCOL_VERSION,
            action,
            operation_id: Uuid::new_v4().to_string(),
            args,
        }
    }

    /// The single line written to the engine's stdin.
    pub fn line(&self) -> String {
        serde_json::to_string(self).expect("a request of strings and JSON values always serializes")
    }
}

/// The closed error vocabulary (design §6.1), same names as `Sedg.Protocol.ErrorCode`. The
/// discriminants are the v1 process exit codes, so the broker can return them unchanged.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[repr(u8)]
pub enum EngineCode {
    None,
    EngineSpawn,
    Protocol,
    Timeout,
    BrokerDenied,
    BrokerNonce,
    BrokerSchema,
    MutexBusy,
    VersionMismatch,
    UnsupportedOs,
    Offline,
    ManifestUnapproved,
    HashMismatch,
    InsufficientDisk,
    UacDenied,
    Network,
    SourceUnreachable,
    NoNetwork,
    EngineGeneric,
    Validation,
    Preflight,
    Cancelled,
    NotInstalled,
    Config,
}

#[derive(Clone, Debug, PartialEq)]
pub enum Response {
    Hello {
        protocol_version: u32,
        pid: u32,
        engine_version: String,
    },
    Event {
        seq: u64,
        ts_utc: String,
        phase: String,
        message: String,
    },
    Progress {
        seq: u64,
        ts_utc: String,
        phase: String,
        bytes_transferred: Option<u64>,
        bytes_total: Option<u64>,
    },
    Result(ResultLine),
}

/// The terminal line. A schema-valid result is authoritative regardless of the exit code.
#[derive(Clone, Debug, PartialEq)]
pub struct ResultLine {
    pub ok: bool,
    pub code: EngineCode,
    pub message: String,
    pub current_state: String,
    pub restored_state: String,
    pub next_step: String,
    pub data: Option<Value>,
    pub transcript_path: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RawLine {
    #[serde(rename = "type")]
    kind: String,
    protocol_version: Option<u32>,
    pid: Option<u32>,
    engine_version: Option<String>,
    seq: Option<u64>,
    ts_utc: Option<String>,
    phase: Option<String>,
    message: Option<String>,
    bytes_transferred: Option<u64>,
    bytes_total: Option<u64>,
    ok: Option<bool>,
    code: Option<EngineCode>,
    current_state: Option<String>,
    restored_state: Option<String>,
    next_step: Option<String>,
    data: Option<Value>,
    transcript_path: Option<String>,
}

/// Parses one stdout line. A malformed line is a classification input, never a panic.
pub fn parse_line(line: &str) -> Result<Response, String> {
    let line = line.strip_prefix('\u{feff}').unwrap_or(line);
    if line.trim().is_empty() {
        return Err("The protocol line is empty.".to_string());
    }

    let raw: RawLine =
        serde_json::from_str(line).map_err(|error| format!("Malformed protocol line: {error}"))?;

    match raw.kind.as_str() {
        "hello" => Ok(Response::Hello {
            protocol_version: raw
                .protocol_version
                .ok_or("A hello line requires protocolVersion.")?,
            pid: raw
                .pid
                .filter(|pid| *pid > 0)
                .ok_or("A hello line requires a positive pid.")?,
            engine_version: raw
                .engine_version
                .filter(|version| !version.trim().is_empty())
                .ok_or("A hello line requires engineVersion.")?,
        }),

        "event" => Ok(Response::Event {
            seq: raw.seq.ok_or("An event line requires seq.")?,
            ts_utc: raw.ts_utc.ok_or("An event line requires tsUtc.")?,
            phase: raw
                .phase
                .filter(|phase| !phase.is_empty())
                .ok_or("An event line requires phase.")?,
            message: raw.message.ok_or("An event line requires message.")?,
        }),

        "progress" => Ok(Response::Progress {
            seq: raw.seq.ok_or("A progress line requires seq.")?,
            ts_utc: raw.ts_utc.ok_or("A progress line requires tsUtc.")?,
            phase: raw
                .phase
                .filter(|phase| !phase.is_empty())
                .ok_or("A progress line requires phase.")?,
            bytes_transferred: raw.bytes_transferred,
            bytes_total: raw.bytes_total,
        }),

        "result" => Ok(Response::Result(ResultLine {
            ok: raw.ok.ok_or("A result line requires ok.")?,
            code: raw.code.ok_or("A result line requires code.")?,
            message: raw.message.ok_or("A result line requires message.")?,
            current_state: raw
                .current_state
                .ok_or("A result line requires currentState.")?,
            restored_state: raw
                .restored_state
                .ok_or("A result line requires restoredState.")?,
            next_step: raw.next_step.ok_or("A result line requires nextStep.")?,
            data: raw.data,
            transcript_path: raw.transcript_path,
        })),

        other => Err(format!("Unknown protocol line type '{other}'.")),
    }
}

impl Response {
    /// The wire line for this response, in the shape [`parse_line`] accepts. `hello` returns
    /// `None`: the broker keeps its own candidate handshake internal and the app never needs it.
    pub fn to_line(&self) -> Option<String> {
        let mut map = serde_json::Map::new();
        match self {
            Self::Hello { .. } => return None,

            Self::Event {
                seq,
                ts_utc,
                phase,
                message,
            } => {
                map.insert("type".into(), json!("event"));
                map.insert("seq".into(), json!(seq));
                map.insert("tsUtc".into(), json!(ts_utc));
                map.insert("phase".into(), json!(phase));
                map.insert("message".into(), json!(message));
            }

            Self::Progress {
                seq,
                ts_utc,
                phase,
                bytes_transferred,
                bytes_total,
            } => {
                map.insert("type".into(), json!("progress"));
                map.insert("seq".into(), json!(seq));
                map.insert("tsUtc".into(), json!(ts_utc));
                map.insert("phase".into(), json!(phase));
                if let Some(bytes) = bytes_transferred {
                    map.insert("bytesTransferred".into(), json!(bytes));
                }
                if let Some(total) = bytes_total {
                    map.insert("bytesTotal".into(), json!(total));
                }
            }

            Self::Result(result) => {
                map.insert("type".into(), json!("result"));
                map.insert("ok".into(), json!(result.ok));
                map.insert("code".into(), json!(result.code));
                map.insert("message".into(), json!(result.message));
                map.insert("currentState".into(), json!(result.current_state));
                map.insert("restoredState".into(), json!(result.restored_state));
                map.insert("nextStep".into(), json!(result.next_step));
                if let Some(data) = &result.data {
                    map.insert("data".into(), data.clone());
                }
                if let Some(path) = &result.transcript_path {
                    map.insert("transcriptPath".into(), json!(path));
                }
            }
        }

        Some(Value::Object(map).to_string())
    }
}

/// Wire shape of `StatusSnapshot` (design §4.3), used to reject an `ok` status whose payload is
/// not a snapshot. Unknown members are refused, as the v1 client does.
#[derive(Debug, Default, Deserialize)]
#[serde(default, deny_unknown_fields, rename_all = "camelCase")]
pub struct StatusSnapshot {
    pub install_presence: Probe<InstallPresence>,
    pub services: Probe<Vec<ServiceSummary>>,
    pub watchdog: Probe<WatchdogSummary>,
    pub dns_per_adapter: Probe<Vec<AdapterDns>>,
    pub upstream: Probe<UpstreamSummary>,
    pub versions: Probe<Vec<VersionEntry>>,
    pub last_update: Probe<UpdateRecord>,
    pub readiness: Probe<Readiness>,
    pub phases: Vec<PhaseInfo>,
    pub observed_utc: String,
}

/// Tri-state value. An unknown probe never carries a value and a known one always does.
#[derive(Debug, Default, Deserialize)]
#[serde(tag = "state", rename_all = "camelCase")]
pub enum Probe<T> {
    Known { value: T },
    Unknown { reason: String },
    #[default]
    NotApplicable,
}

#[derive(Debug, Default, Deserialize)]
#[serde(default, deny_unknown_fields, rename_all = "camelCase")]
pub struct InstallPresence {
    pub installed: bool,
    pub install_path: String,
    pub install_utc: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(default, deny_unknown_fields, rename_all = "camelCase")]
pub struct ServiceSummary {
    pub name: String,
    pub status: String,
    pub start_type: String,
    pub last_change_utc: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(default, deny_unknown_fields, rename_all = "camelCase")]
pub struct WatchdogSummary {
    pub task_name: String,
    pub enabled: bool,
    pub last_run_utc: Option<String>,
    pub last_outcome: Option<String>,
    pub last_fallback_utc: Option<String>,
    pub last_fallback_reason: Option<String>,
    pub fail_closed: bool,
}

#[derive(Debug, Default, Deserialize)]
#[serde(default, deny_unknown_fields, rename_all = "camelCase")]
pub struct AdapterDns {
    pub adapter_name: String,
    pub mode: String,
    pub servers: Vec<String>,
    pub gateway_bypassed: bool,
}

#[derive(Debug, Default, Deserialize)]
#[serde(default, deny_unknown_fields, rename_all = "camelCase")]
pub struct UpstreamSummary {
    pub host: String,
    pub scheme: String,
    pub source: String,
    pub credentials_redacted: bool,
}

/// The engine writes the version matrix as an array of component entries.
#[derive(Debug, Default, Deserialize)]
#[serde(default, deny_unknown_fields, rename_all = "camelCase")]
pub struct VersionEntry {
    pub component: String,
    pub installed: Option<String>,
    pub approved: Option<String>,
    #[serde(rename = "match")]
    pub matched: String,
}

#[derive(Debug, Default, Deserialize)]
#[serde(default, deny_unknown_fields, rename_all = "camelCase")]
pub struct UpdateRecord {
    pub utc: String,
    pub from_version: Option<String>,
    pub to_version: Option<String>,
    pub outcome: String,
    pub reported_by: String,
}

#[derive(Debug, Default, Deserialize)]
#[serde(default, deny_unknown_fields, rename_all = "camelCase")]
pub struct Readiness {
    pub state: String,
    pub reasons: Vec<String>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(default, deny_unknown_fields, rename_all = "camelCase")]
pub struct PhaseInfo {
    pub id: String,
    pub label: String,
    pub state: String,
}

/// Returns the snapshot only when the payload is a schema-valid snapshot object.
pub fn status_snapshot(data: Option<&Value>) -> Option<StatusSnapshot> {
    let data = data?;
    if !data.is_object() {
        return None;
    }
    serde_json::from_value(data.clone()).ok()
}
