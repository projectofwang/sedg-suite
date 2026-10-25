//! The manager's own settings in v1's app-data folder: the interface language and the theme.
//!
//! Reading tolerates a missing, hand-edited, or damaged file and falls back to the defaults, so a
//! bad file never stops the window from opening. Writing refuses a value the window could not have
//! produced: the file is a trust boundary, our own UI is not.

use std::fs;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

pub const LANGUAGES: [&str; 2] = ["en", "vi"];
pub const THEMES: [&str; 3] = ["system", "light", "dark"];

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Settings {
    /// `None` means no choice has been made yet; the window then follows the OS language.
    #[serde(default)]
    pub language: Option<String>,
    #[serde(default = "system")]
    pub theme: String,
}

fn system() -> String {
    "system".to_string()
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            language: None,
            theme: system(),
        }
    }
}

impl Settings {
    /// A hand-edited value falls back instead of breaking the window.
    fn normalized(mut self) -> Self {
        self.language = self
            .language
            .filter(|language| LANGUAGES.contains(&language.as_str()));
        if !THEMES.contains(&self.theme.as_str()) {
            self.theme = system();
        }
        self
    }
}

pub fn path() -> Option<PathBuf> {
    crate::log::app_dir().map(|directory| directory.join("settings.json"))
}

pub fn load() -> Settings {
    path().map(|path| load_from(&path)).unwrap_or_default()
}

fn load_from(path: &Path) -> Settings {
    let Ok(text) = fs::read_to_string(path) else {
        return Settings::default();
    };
    serde_json::from_str::<Settings>(&text)
        .unwrap_or_default()
        .normalized()
}

pub fn save(settings: Settings) -> Result<Settings, String> {
    if let Some(language) = &settings.language {
        if !LANGUAGES.contains(&language.as_str()) {
            return Err(format!("Unsupported language '{language}'."));
        }
    }
    if !THEMES.contains(&settings.theme.as_str()) {
        return Err(format!("Unsupported theme '{}'.", settings.theme));
    }

    let path = path().ok_or("The app data folder is not available.")?;
    save_to(&path, &settings)?;
    Ok(settings)
}

/// Write-then-rename: a crash mid-write cannot leave a half-written settings file behind.
fn save_to(path: &Path, settings: &Settings) -> Result<(), String> {
    let directory = path
        .parent()
        .ok_or("The settings path has no parent directory.")?;
    fs::create_dir_all(directory)
        .map_err(|error| format!("The settings folder could not be created: {error}"))?;
    let text = serde_json::to_string_pretty(settings)
        .map_err(|error| format!("The settings could not be encoded: {error}"))?;
    let temporary = path.with_extension("json.tmp");
    fs::write(&temporary, text + "\n")
        .map_err(|error| format!("The settings could not be written: {error}"))?;
    fs::rename(&temporary, path)
        .map_err(|error| format!("The settings could not be replaced: {error}"))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temporary() -> PathBuf {
        let directory =
            std::env::temp_dir().join(format!("sedg-settings-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&directory).unwrap();
        directory.join("settings.json")
    }

    #[test]
    fn a_missing_file_means_follow_the_os_language_and_theme() {
        let settings = load_from(&temporary());
        assert_eq!(settings, Settings::default());
        assert_eq!(settings.language, None);
        assert_eq!(settings.theme, "system");
    }

    #[test]
    fn a_hand_edited_value_falls_back_instead_of_breaking_the_window() {
        let path = temporary();
        fs::write(&path, r#"{"language":"fr","theme":"neon"}"#).unwrap();
        let settings = load_from(&path);
        assert_eq!(settings.language, None);
        assert_eq!(settings.theme, "system");

        fs::write(&path, "not json").unwrap();
        assert_eq!(load_from(&path), Settings::default());
    }

    #[test]
    fn a_saved_choice_round_trips() {
        let path = temporary();
        let settings = Settings {
            language: Some("vi".to_string()),
            theme: "dark".to_string(),
        };
        save_to(&path, &settings).unwrap();
        assert_eq!(load_from(&path), settings);

        let text = fs::read_to_string(&path).unwrap();
        assert!(text.contains("\"language\": \"vi\""), "{text}");
        assert!(text.ends_with('\n'));
    }

    #[test]
    fn writing_refuses_a_value_the_window_never_sends() {
        let bad_language = Settings {
            language: Some("fr".to_string()),
            theme: "system".to_string(),
        };
        assert!(save(bad_language).is_err());

        let bad_theme = Settings {
            language: None,
            theme: "neon".to_string(),
        };
        assert!(save(bad_theme).is_err());
    }
}
