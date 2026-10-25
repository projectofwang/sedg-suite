//! The EN/VI gate the build runs: identical key sets, no empty value, and the same placeholders
//! in both languages, so a missing translation fails here instead of rendering a raw key.

use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

fn load(name: &str) -> BTreeMap<String, String> {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../ui/locales")
        .join(name);
    let text = std::fs::read_to_string(&path)
        .unwrap_or_else(|error| panic!("{}: {error}", path.display()));
    let parsed: BTreeMap<String, serde_json::Value> = serde_json::from_str(&text)
        .unwrap_or_else(|error| panic!("{}: {error}", path.display()));

    parsed
        .into_iter()
        .map(|(key, value)| {
            let value = value
                .as_str()
                .unwrap_or_else(|| panic!("{name}: '{key}' is not a string"));
            (key, value.to_string())
        })
        .collect()
}

fn placeholders(value: &str) -> BTreeSet<&str> {
    let mut found = BTreeSet::new();
    let mut rest = value;
    while let Some(start) = rest.find('{') {
        let tail = &rest[start + 1..];
        let Some(end) = tail.find('}') else {
            break;
        };
        found.insert(&tail[..end]);
        rest = &tail[end + 1..];
    }
    found
}

#[test]
fn the_two_locales_have_identical_keys_and_no_empty_values() {
    let english = load("en.json");
    let vietnamese = load("vi.json");

    let missing: Vec<_> = english
        .keys()
        .filter(|key| !vietnamese.contains_key(*key))
        .collect();
    assert!(missing.is_empty(), "vi.json is missing {missing:?}");

    let extra: Vec<_> = vietnamese
        .keys()
        .filter(|key| !english.contains_key(*key))
        .collect();
    assert!(extra.is_empty(), "vi.json has unknown keys {extra:?}");

    for (name, locale) in [("en.json", &english), ("vi.json", &vietnamese)] {
        let empty: Vec<_> = locale
            .iter()
            .filter(|(_, value)| value.trim().is_empty())
            .map(|(key, _)| key)
            .collect();
        assert!(empty.is_empty(), "{name} has empty values for {empty:?}");
    }
}

#[test]
fn the_two_locales_use_the_same_placeholders() {
    let english = load("en.json");
    let vietnamese = load("vi.json");

    for (key, value) in &english {
        let translated = &vietnamese[key];
        assert_eq!(
            placeholders(value),
            placeholders(translated),
            "'{key}' uses different placeholders"
        );
    }
}
