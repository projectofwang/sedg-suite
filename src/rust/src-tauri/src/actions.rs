//! The closed action surface (design §2.6). The window sends what the user typed; this module is
//! the only place that turns it into the engine's wire arguments. `protocol::validate_args` stays
//! the authority on values, so the field rules live in exactly one place.

use serde_json::{json, Map, Value};

use crate::engine::protocol::{self, Action};

/// Maps the UI input for `action` to the engine's wire arguments.
///
/// The input shape is closed per action: one entry here per control the review panel renders.
pub fn wire_args(action: Action, input: &Value) -> Result<Value, String> {
    let object = input
        .as_object()
        .ok_or("The action input must be a JSON object.")?;

    let allowed: &[&str] = match action {
        Action::Install => &["clean"],
        Action::SetUpstream => &["upstreamCustom", "upstreamUrl"],
        Action::SetDns => &["servers"],
        Action::SetLanguage => &["language"],
        _ => &[],
    };
    if let Some(key) = object
        .keys()
        .find(|key| !allowed.contains(&key.as_str()))
    {
        return Err(format!(
            "Unknown input field '{key}' for action '{}'.",
            action.wire()
        ));
    }

    let wire = match action {
        Action::Install => {
            let mut wire = Map::new();
            if flag(object, "clean")? {
                wire.insert("mode".to_string(), json!("clean"));
            }
            Value::Object(wire)
        }

        Action::SetUpstream => {
            if flag(object, "upstreamCustom")? {
                let url = object
                    .get("upstreamUrl")
                    .and_then(Value::as_str)
                    .ok_or("A custom upstream needs a URL.")?;
                json!({ "mode": "custom", "upstreamUrl": url })
            } else {
                json!({ "mode": "resetDefaults" })
            }
        }

        Action::SetDns => {
            let raw = object
                .get("servers")
                .and_then(Value::as_str)
                .ok_or("The DNS server list is required.")?;
            json!({ "servers": split_servers(raw) })
        }

        Action::SetLanguage => {
            let language = object
                .get("language")
                .and_then(Value::as_str)
                .ok_or("The language is required.")?;
            json!({ "language": language })
        }

        _ => json!({}),
    };

    protocol::validate_args(action, &wire)?;
    Ok(wire)
}

fn flag(object: &Map<String, Value>, key: &str) -> Result<bool, String> {
    match object.get(key) {
        None | Some(Value::Null) => Ok(false),
        Some(Value::Bool(value)) => Ok(*value),
        Some(_) => Err(format!("Field '{key}' must be true or false.")),
    }
}

/// Splits the entered list on commas and whitespace, dropping empties and duplicates (v1 parity).
fn split_servers(raw: &str) -> Vec<String> {
    let mut servers: Vec<String> = Vec::new();
    for token in raw.split([',', ' ', '\t', '\r', '\n']) {
        let token = token.trim();
        if !token.is_empty() && !servers.iter().any(|seen| seen == token) {
            servers.push(token.to_string());
        }
    }
    servers
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn install_is_repair_by_default_and_clean_only_when_asked() {
        assert_eq!(wire_args(Action::Install, &json!({})).unwrap(), json!({}));
        assert_eq!(
            wire_args(Action::Install, &json!({ "clean": true })).unwrap(),
            json!({ "mode": "clean" })
        );
        assert_eq!(
            wire_args(Action::Install, &json!({ "clean": false })).unwrap(),
            json!({})
        );
        assert!(wire_args(Action::Install, &json!({ "clean": "yes" }))
            .unwrap_err()
            .contains("must be true or false"));
    }

    #[test]
    fn upstream_defaults_to_reset_and_requires_a_url_for_custom() {
        assert_eq!(
            wire_args(Action::SetUpstream, &json!({ "upstreamCustom": false })).unwrap(),
            json!({ "mode": "resetDefaults" })
        );
        assert_eq!(
            wire_args(
                Action::SetUpstream,
                &json!({ "upstreamCustom": true, "upstreamUrl": "https://dns.example/dns-query" })
            )
            .unwrap(),
            json!({ "mode": "custom", "upstreamUrl": "https://dns.example/dns-query" })
        );
        assert!(wire_args(
            Action::SetUpstream,
            &json!({ "upstreamCustom": true, "upstreamUrl": "" })
        )
        .is_err());
        assert!(wire_args(Action::SetUpstream, &json!({ "upstreamCustom": true })).is_err());
    }

    #[test]
    fn a_plaintext_upstream_is_refused_by_the_wire_validator() {
        let error = wire_args(
            Action::SetUpstream,
            &json!({ "upstreamCustom": true, "upstreamUrl": "http://dns.example/dns-query" }),
        )
        .unwrap_err();
        assert!(error.contains("https"), "{error}");
    }

    #[test]
    fn dns_input_is_split_trimmed_and_deduplicated() {
        assert_eq!(
            wire_args(
                Action::SetDns,
                &json!({ "servers": " 1.1.1.1, 8.8.8.8  1.1.1.1\t::1 " })
            )
            .unwrap(),
            json!({ "servers": ["1.1.1.1", "8.8.8.8", "::1"] })
        );
    }

    #[test]
    fn dns_rejects_an_empty_or_invalid_list() {
        assert!(wire_args(Action::SetDns, &json!({ "servers": "   " })).is_err());
        assert!(wire_args(Action::SetDns, &json!({ "servers": "1.2.3" })).is_err());
        assert!(wire_args(
            Action::SetDns,
            &json!({ "servers": "1.1.1.1, 1.1.1.2, 1.1.1.3, 1.1.1.4, 1.1.1.5" })
        )
        .is_err());
    }

    #[test]
    fn language_is_checked_against_the_two_supported_codes() {
        assert_eq!(
            wire_args(Action::SetLanguage, &json!({ "language": "vi" })).unwrap(),
            json!({ "language": "vi" })
        );
        assert!(wire_args(Action::SetLanguage, &json!({ "language": "fr" })).is_err());
        assert!(wire_args(Action::SetLanguage, &json!({})).is_err());
    }

    #[test]
    fn an_action_without_a_form_takes_no_input() {
        for action in [
            Action::Update,
            Action::Pause,
            Action::Resume,
            Action::Restart,
            Action::Uninstall,
            Action::TestCdnOptimization,
        ] {
            assert_eq!(wire_args(action, &json!({})).unwrap(), json!({}));
            assert!(
                wire_args(action, &json!({ "clean": true })).is_err(),
                "{} accepted a field it does not have",
                action.wire()
            );
        }
    }

    #[test]
    fn the_input_must_be_an_object() {
        assert!(wire_args(Action::Update, &json!([])).is_err());
        assert!(wire_args(Action::Update, &Value::Null).is_err());
    }
}
