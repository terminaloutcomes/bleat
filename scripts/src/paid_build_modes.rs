//! Paid capability matrix; signed-host execution has a separate lifecycle.
use crate::ci_smoke::owned_command::{self, Failure, Stage};
use build_scripts::paid_build_settings::{PaidBuildSettingsError, validate_environment};
use std::{collections::BTreeMap, path::Path, process::Command, time::Duration};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mode {
    Enabled,
    Disabled,
}
impl Mode {
    fn value(self) -> &'static str {
        match self {
            Self::Enabled => "enabled",
            Self::Disabled => "disabled",
        }
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Query {
    Paid {
        cloud: Mode,
        attest: Mode,
        carplay: Mode,
    },
    PersonalOverride,
    PaidDefault,
    PersonalDefault,
    MacDefault,
}
impl Query {
    fn arguments(self) -> Vec<String> {
        let mut args = [
            "-project",
            "Bleat.xcodeproj",
            "-target",
            "BleatApp",
            "-configuration",
            "Release",
            "-sdk",
            if self == Self::MacDefault {
                "macosx"
            } else {
                "iphoneos"
            },
            "-showBuildSettings",
            "-json",
        ]
        .map(str::to_owned)
        .to_vec();
        args.push(format!(
            "BUILD_WITHOUT_PAID_DEVELOPER={}",
            if matches!(self, Self::PersonalDefault | Self::PersonalOverride) {
                "YES"
            } else {
                "NO"
            }
        ));
        let modes = match self {
            Self::Paid {
                cloud,
                attest,
                carplay,
            } => Some((cloud, attest, carplay)),
            Self::PersonalOverride => Some((Mode::Enabled, Mode::Enabled, Mode::Enabled)),
            _ => None,
        };
        if let Some((cloud, attest, carplay)) = modes {
            args.extend([
                format!("BLEAT_CLOUDKIT_MODE={}", cloud.value()),
                format!("BLEAT_APP_ATTEST_MODE={}", attest.value()),
                format!("BLEAT_CARPLAY_MODE={}", carplay.value()),
            ]);
        }
        args
    }
    fn expected(self) -> Vec<(&'static str, String)> {
        let (cloud, attest, carplay) = match self {
            Self::Paid {
                cloud,
                attest,
                carplay,
            } => (cloud, attest, carplay),
            Self::PersonalOverride | Self::PersonalDefault => {
                (Mode::Disabled, Mode::Disabled, Mode::Disabled)
            }
            Self::PaidDefault => (Mode::Enabled, Mode::Enabled, Mode::Enabled),
            Self::MacDefault => (Mode::Enabled, Mode::Enabled, Mode::Disabled),
        };
        let entitlements = if self == Self::MacDefault {
            "App/BleatMac.enabled.entitlements".to_owned()
        } else {
            format!(
                "App/Bleat.cloudkit-{}.app-attest-{}{}.entitlements",
                cloud.value(),
                attest.value(),
                if carplay == Mode::Enabled {
                    ".carplay-enabled"
                } else {
                    ""
                }
            )
        };
        let mut expected = vec![
            ("CODE_SIGN_ENTITLEMENTS", entitlements),
            ("BLEAT_EFFECTIVE_CARPLAY_MODE", carplay.value().to_owned()),
        ];
        if matches!(self, Self::Paid { .. } | Self::PersonalOverride) {
            expected.extend([
                ("BLEAT_EFFECTIVE_CLOUDKIT_MODE", cloud.value().to_owned()),
                ("BLEAT_EFFECTIVE_APP_ATTEST_MODE", attest.value().to_owned()),
            ]);
        } else {
            expected.push(("BLEAT_CARPLAY_MODE", "enabled".to_owned()));
        }
        expected
    }
}
fn queries() -> Vec<Query> {
    let mut cases = Vec::new();
    for carplay in [Mode::Disabled, Mode::Enabled] {
        for (cloud, attest) in [
            (Mode::Enabled, Mode::Enabled),
            (Mode::Enabled, Mode::Disabled),
            (Mode::Disabled, Mode::Enabled),
            (Mode::Disabled, Mode::Disabled),
        ] {
            cases.push(Query::Paid {
                cloud,
                attest,
                carplay,
            });
        }
    }
    cases.extend([
        Query::PersonalOverride,
        Query::PaidDefault,
        Query::PersonalDefault,
        Query::MacDefault,
    ]);
    cases
}

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("paid-build settings query {query:?} failed: {source}")]
    Native {
        query: Query,
        #[source]
        source: Box<Failure>,
    },
    #[error("paid-build settings query {query:?} has invalid JSON: {source}")]
    Json {
        query: Query,
        #[source]
        source: JsonDecodeFailure,
    },
    #[error("paid-build settings query {query:?} has invalid {field:?} at row {row:?}: {actual:?}")]
    Shape {
        query: Query,
        row: Option<usize>,
        field: InputField,
        actual: InputKind,
    },
    #[error("paid-build settings query {query:?} has no BleatApp target")]
    MissingTarget { query: Query },
    #[error(
        "paid-build settings query {query:?} differs at {field}; expected {expected}, observed {actual:?}"
    )]
    Setting {
        query: Query,
        field: &'static str,
        expected: String,
        actual: SettingValue,
    },
    #[error("could not read {path}: {source}")]
    Io {
        path: String,
        #[source]
        source: std::io::Error,
    },
    #[error("invalid plist {path}: {source}")]
    Plist {
        path: String,
        #[source]
        source: plist::Error,
    },
    #[error("plist contract failed in {path} at {key}: {requirement:?}")]
    PlistContract {
        path: String,
        key: String,
        requirement: PlistRequirement,
    },
    #[error("invalid-mode control for {field} returned an unexpected typed outcome: {actual:?}")]
    InvalidMode {
        field: &'static str,
        actual: Option<PaidBuildSettingsError>,
    },
}
#[derive(Debug, thiserror::Error)]
#[error("{kind:?} at line {line}, column {column}")]
pub struct JsonDecodeFailure {
    kind: JsonFailureKind,
    line: usize,
    column: usize,
}
#[derive(Debug)]
pub enum JsonFailureKind {
    Io,
    Syntax,
    Shape,
    Incomplete,
}
impl From<serde_json::Error> for JsonDecodeFailure {
    fn from(source: serde_json::Error) -> Self {
        use serde_json::error::Category;
        Self {
            kind: match source.classify() {
                Category::Io => JsonFailureKind::Io,
                Category::Syntax => JsonFailureKind::Syntax,
                Category::Data => JsonFailureKind::Shape,
                Category::Eof => JsonFailureKind::Incomplete,
            },
            line: source.line(),
            column: source.column(),
        }
    }
}
#[derive(Debug, PartialEq, Eq)]
pub enum InputField {
    Root,
    Row,
    Target,
    BuildSettings,
}
#[derive(Debug, PartialEq, Eq)]
pub enum InputKind {
    Missing,
    Null,
    Boolean,
    Number,
    String,
    Array,
    Object,
}
impl InputKind {
    fn of(value: Option<&serde_json::Value>) -> Self {
        use serde_json::Value;
        match value {
            None => Self::Missing,
            Some(Value::Null) => Self::Null,
            Some(Value::Bool(_)) => Self::Boolean,
            Some(Value::Number(_)) => Self::Number,
            Some(Value::String(_)) => Self::String,
            Some(Value::Array(_)) => Self::Array,
            Some(Value::Object(_)) => Self::Object,
        }
    }
}
#[derive(Debug)]
pub enum SettingValue {
    Missing,
    StringMismatch,
    NonString,
}
impl SettingValue {
    fn from_value(value: Option<&serde_json::Value>) -> Self {
        match value {
            None => Self::Missing,
            Some(serde_json::Value::String(_)) => Self::StringMismatch,
            Some(_) => Self::NonString,
        }
    }
}
#[derive(Debug)]
pub enum PlistRequirement {
    MatchingFiles,
    Dictionary,
    Absent,
    True,
    Substitution,
    KeychainPresent,
}

struct SettingsRow<'a> {
    target: &'a str,
    settings: &'a serde_json::Map<String, serde_json::Value>,
}
fn verify_settings(query: Query, bytes: &[u8]) -> Result<(), Error> {
    let value: serde_json::Value = serde_json::from_slice(bytes).map_err(|source| Error::Json {
        query,
        source: JsonDecodeFailure::from(source),
    })?;
    let array = value.as_array().ok_or_else(|| Error::Shape {
        query,
        row: None,
        field: InputField::Root,
        actual: InputKind::of(Some(&value)),
    })?;
    let mut rows = Vec::new();
    for (index, value) in array.iter().enumerate() {
        let shape = |field, value| Error::Shape {
            query,
            row: Some(index),
            field,
            actual: InputKind::of(value),
        };
        let object = value
            .as_object()
            .ok_or_else(|| shape(InputField::Row, Some(value)))?;
        let target = object.get("target");
        let target = target
            .and_then(serde_json::Value::as_str)
            .ok_or_else(|| shape(InputField::Target, target))?;
        let settings = object.get("buildSettings");
        let settings = settings
            .and_then(serde_json::Value::as_object)
            .ok_or_else(|| shape(InputField::BuildSettings, settings))?;
        rows.push(SettingsRow { target, settings });
    }
    // Preserve the original any(BleatApp && all expected settings) contract.
    let expected = query.expected();
    let rows: Vec<_> = rows.iter().filter(|row| row.target == "BleatApp").collect();
    if rows.is_empty() {
        return Err(Error::MissingTarget { query });
    }
    if rows.iter().any(|row| {
        expected.iter().all(|(field, value)| {
            row.settings.get(*field).and_then(serde_json::Value::as_str) == Some(value.as_str())
        })
    }) {
        return Ok(());
    }
    for (field, expected) in expected {
        let value = rows[0].settings.get(field);
        if value.and_then(serde_json::Value::as_str) != Some(expected.as_str()) {
            let actual = SettingValue::from_value(value);
            return Err(Error::Setting {
                query,
                field,
                expected,
                actual,
            });
        }
    }
    Ok(())
}
fn query(
    root: &Path,
    tool: &Path,
    case: Query,
    budget: Duration,
    cleanup: Duration,
    limit: u64,
) -> Result<(), Error> {
    let mut command = Command::new(tool);
    command.current_dir(root).args(case.arguments());
    let output = owned_command::run_stdout(
        &mut command,
        Stage::PaidBuildSettings,
        budget,
        cleanup,
        limit,
    )
    .map_err(|source| Error::Native {
        query: case,
        source,
    })?;
    verify_settings(case, &output.stdout)
}

fn read_plist(root: &Path, path: &str) -> Result<plist::Value, Error> {
    plist::Value::from_file(root.join(path)).map_err(|source| Error::Plist {
        path: path.to_owned(),
        source,
    })
}
fn dictionary<'a>(value: &'a plist::Value, path: &str) -> Result<&'a plist::Dictionary, Error> {
    value.as_dictionary().ok_or_else(|| Error::PlistContract {
        path: path.to_owned(),
        key: "root".to_owned(),
        requirement: PlistRequirement::Dictionary,
    })
}
fn reject_key(path: &str, key: &str) -> Error {
    Error::PlistContract {
        path: path.to_owned(),
        key: key.to_owned(),
        requirement: PlistRequirement::Absent,
    }
}
// The original plutil text check covered keys and string values. Inspect the
// decoded structure recursively so that this security check stays equally broad.
fn contains_paid_capability(value: &plist::Value) -> bool {
    let marker = |s: &str| s.contains("icloud") || s.contains("appattest");
    match value {
        plist::Value::String(s) => marker(s),
        plist::Value::Array(values) => values.iter().any(contains_paid_capability),
        plist::Value::Dictionary(values) => values
            .iter()
            .any(|(key, value)| marker(key) || contains_paid_capability(value)),
        _ => false,
    }
}
fn verify_plists(root: &Path) -> Result<(), Error> {
    let disabled = "App/Bleat.cloudkit-disabled.app-attest-disabled.entitlements";
    let value = read_plist(root, disabled)?;
    let dict = dictionary(&value, disabled)?;
    if contains_paid_capability(&value) {
        return Err(reject_key(disabled, "icloud/appattest content"));
    }
    if !dict.contains_key("keychain-access-groups") {
        return Err(Error::PlistContract {
            path: disabled.to_owned(),
            key: "keychain-access-groups".to_owned(),
            requirement: PlistRequirement::KeychainPresent,
        });
    }
    let entries = std::fs::read_dir(root.join("App")).map_err(|source| Error::Io {
        path: "App".to_owned(),
        source,
    })?;
    let mut carplay_enabled_files = 0;
    for entry in entries {
        let entry = entry.map_err(|source| Error::Io {
            path: "App".to_owned(),
            source,
        })?;
        let name = entry.file_name().to_string_lossy().into_owned();
        if !name.ends_with(".entitlements")
            || !(name.starts_with("Bleat.cloudkit-") || name.starts_with("BleatMac."))
        {
            continue;
        }
        let path = format!("App/{name}");
        let value = read_plist(root, &path)?;
        let dict = dictionary(&value, &path)?;
        let key = "com.apple.developer.carplay-audio";
        if name.starts_with("BleatMac.") {
            if dict.contains_key(key) {
                return Err(reject_key(&path, key));
            }
        } else if name.ends_with(".carplay-enabled.entitlements") {
            carplay_enabled_files += 1;
            if dict.get(key).and_then(plist::Value::as_boolean) != Some(true) {
                return Err(Error::PlistContract {
                    path,
                    key: key.to_owned(),
                    requirement: PlistRequirement::True,
                });
            }
        } else if dict.contains_key(key) {
            return Err(reject_key(&path, key));
        }
    }
    if carplay_enabled_files == 0 {
        return Err(Error::PlistContract {
            path: "App/Bleat.cloudkit-*.carplay-enabled.entitlements".to_owned(),
            key: "file set".to_owned(),
            requirement: PlistRequirement::MatchingFiles,
        });
    }
    let path = "App/Info.plist";
    let value = read_plist(root, path)?;
    let dict = dictionary(&value, path)?;
    for (key, expected) in [
        ("BleatCloudKitMode", "$(BLEAT_EFFECTIVE_CLOUDKIT_MODE)"),
        ("BleatAppAttestMode", "$(BLEAT_EFFECTIVE_APP_ATTEST_MODE)"),
        ("BleatCarPlayMode", "$(BLEAT_EFFECTIVE_CARPLAY_MODE)"),
    ] {
        if dict.get(key).and_then(plist::Value::as_string) != Some(expected) {
            return Err(Error::PlistContract {
                path: path.to_owned(),
                key: key.to_owned(),
                requirement: PlistRequirement::Substitution,
            });
        }
    }
    Ok(())
}
fn verify_invalid_modes() -> Result<(), Error> {
    // Isolated valid controls prevent missing ambient configuration or a failed
    // Cargo launcher from satisfying a negative assertion accidentally.
    let valid = BTreeMap::from([
        ("BUILD_WITHOUT_PAID_DEVELOPER", "NO"),
        ("BLEAT_CLOUDKIT_MODE", "enabled"),
        ("BLEAT_APP_ATTEST_MODE", "enabled"),
        ("BLEAT_CARPLAY_MODE", "disabled"),
        ("PLATFORM_NAME", "iphoneos"),
        (
            "BLEAT_TELEMETRY_AUTH_BASE_URL",
            "https://telemetry.example.invalid/auth",
        ),
        (
            "BLEAT_TELEMETRY_OTLP_ENDPOINT",
            "https://telemetry.example.invalid",
        ),
    ]);
    if let Err(actual) =
        validate_environment(|name| valid.get(name).copied().ok_or(()).map(str::to_owned))
    {
        return Err(Error::InvalidMode {
            field: "valid control",
            actual: Some(actual),
        });
    }
    for (field, bad) in [
        ("BUILD_WITHOUT_PAID_DEVELOPER", "MAYBE"),
        ("BLEAT_CLOUDKIT_MODE", "unsupported"),
        ("BLEAT_APP_ATTEST_MODE", "unsupported"),
        ("BLEAT_CARPLAY_MODE", "unsupported"),
    ] {
        let mut values = valid.clone();
        values.insert(field, bad);
        match validate_environment(|name| values.get(name).copied().ok_or(()).map(str::to_owned)) {
            Err(PaidBuildSettingsError::InvalidAllowedValue { name, .. }) if name == field => {}
            result => {
                return Err(Error::InvalidMode {
                    field,
                    actual: result.err(),
                });
            }
        }
    }
    Ok(())
}
pub fn run(root: &Path) -> Result<(), Error> {
    for case in queries() {
        query(
            root,
            Path::new("xcodebuild"),
            case,
            Duration::from_secs(300),
            Duration::from_secs(3),
            64 * 1024 * 1024,
        )?;
        println!("Verified paid-build settings {case:?}");
    }
    verify_plists(root)?;
    verify_invalid_modes()?;
    println!(
        "Verified paid-capability build modes (12 Xcode queries, plist contracts, 4 typed invalid modes)"
    );
    Ok(())
}

#[cfg(test)]
#[path = "paid_build_modes/tests.rs"]
mod tests;
