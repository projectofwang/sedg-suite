use std::fmt;
use std::path::PathBuf;

/// One binary, three modes (spec §2.2). Parsed before any webview exists, so the broker never
/// initialises a GUI.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Mode {
    /// The engine is installed: manage it.
    Manager,
    /// Nothing installed yet: offer the first install.
    Setup,
    /// Elevated, windowless: own one engine run (B3).
    Broker(BrokerArgs),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BrokerArgs {
    pub nonce: String,
    pub issued_utc: String,
    pub expires_utc: String,
    /// First install only: the staged installer the broker may run instead of the engine.
    pub setup_script: Option<PathBuf>,
}

#[derive(Debug, PartialEq, Eq)]
pub struct ModeError(String);

impl ModeError {
    fn new(message: impl Into<String>) -> Self {
        Self(message.into())
    }
}

impl fmt::Display for ModeError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl std::error::Error for ModeError {}

impl Mode {
    /// `args` are the process arguments after the executable name.
    pub fn parse(args: &[String]) -> Result<Self, ModeError> {
        match args.split_first() {
            None => Ok(Self::Manager),
            Some((flag, rest)) if flag == "--setup" && rest.is_empty() => Ok(Self::Setup),
            Some((flag, rest)) if flag == "--broker" => {
                let (nonce, issued_utc, expires_utc, setup_script) = match rest {
                    [nonce, issued_utc, expires_utc] => (nonce, issued_utc, expires_utc, None),
                    [nonce, issued_utc, expires_utc, setup, path] if setup == "--setup" => {
                        (nonce, issued_utc, expires_utc, Some(PathBuf::from(path)))
                    }
                    _ => {
                        return Err(ModeError::new(
                            "--broker needs a nonce, an issue time, and an expiry time, optionally followed by --setup <path>.",
                        ))
                    }
                };
                Ok(Self::Broker(BrokerArgs {
                    nonce: nonce.clone(),
                    issued_utc: issued_utc.clone(),
                    expires_utc: expires_utc.clone(),
                    setup_script,
                }))
            }
            Some((flag, _)) => Err(ModeError::new(format!("Unknown argument: {flag}"))),
        }
    }

    /// `--setup` always means setup; a bare launch follows the machine.
    pub fn resolve(self, engine_installed: bool) -> Self {
        match self {
            Self::Manager if !engine_installed => Self::Setup,
            other => other,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(values: &[&str]) -> Vec<String> {
        values.iter().map(|value| value.to_string()).collect()
    }

    #[test]
    fn no_argument_opens_the_manager() {
        assert_eq!(Mode::parse(&[]), Ok(Mode::Manager));
    }

    #[test]
    fn setup_flag_opens_the_first_install() {
        assert_eq!(Mode::parse(&args(&["--setup"])), Ok(Mode::Setup));
    }

    #[test]
    fn broker_takes_exactly_three_values() {
        let parsed = Mode::parse(&args(&["--broker", "abc", "2026-01-01T00:00:00Z", "2026-01-01T00:05:00Z"]));
        assert_eq!(
            parsed,
            Ok(Mode::Broker(BrokerArgs {
                nonce: "abc".to_string(),
                issued_utc: "2026-01-01T00:00:00Z".to_string(),
                expires_utc: "2026-01-01T00:05:00Z".to_string(),
                setup_script: None,
            }))
        );
    }

    #[test]
    fn broker_rejects_a_short_or_long_argument_list() {
        assert!(Mode::parse(&args(&["--broker", "abc"])).is_err());
        assert!(Mode::parse(&args(&["--broker", "a", "b", "c", "d"])).is_err());
        assert!(Mode::parse(&args(&["--broker", "a", "b", "c", "--setup"])).is_err());
    }

    #[test]
    fn broker_carries_the_staged_setup_script() {
        let parsed = Mode::parse(&args(&[
            "--broker",
            "abc",
            "2026-01-01T00:00:00Z",
            "2026-01-01T00:05:00Z",
            "--setup",
            r"C:\Users\u\AppData\Local\Temp\sedg-setup-x\manager.ps1",
        ]));

        assert_eq!(
            parsed,
            Ok(Mode::Broker(BrokerArgs {
                nonce: "abc".to_string(),
                issued_utc: "2026-01-01T00:00:00Z".to_string(),
                expires_utc: "2026-01-01T00:05:00Z".to_string(),
                setup_script: Some(PathBuf::from(
                    r"C:\Users\u\AppData\Local\Temp\sedg-setup-x\manager.ps1"
                )),
            }))
        );
    }

    /// A bare launch (the one-command bootstrap runs the staged copy with no arguments) follows
    /// the machine, so re-running it on an installed PC opens the manager, not a first-install
    /// screen. `--setup` stays the explicit override.
    #[test]
    fn a_bare_launch_follows_the_machine() {
        assert_eq!(Mode::Manager.resolve(false), Mode::Setup);
        assert_eq!(Mode::Manager.resolve(true), Mode::Manager);
        assert_eq!(Mode::Setup.resolve(true), Mode::Setup);
        assert_eq!(Mode::Setup.resolve(false), Mode::Setup);
    }

    #[test]
    fn the_broker_mode_is_never_resolved_into_a_window() {
        let broker = Mode::parse(&args(&[
            "--broker",
            "abc",
            "2026-01-01T00:00:00Z",
            "2026-01-01T00:05:00Z",
        ]))
        .unwrap();
        assert_eq!(broker.clone().resolve(true), broker);
    }

    #[test]
    fn unknown_or_trailing_arguments_are_rejected() {
        assert!(Mode::parse(&args(&["--setup", "extra"])).is_err());
        assert!(Mode::parse(&args(&["--elevate"])).is_err());
    }
}
