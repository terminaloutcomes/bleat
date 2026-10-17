use build_scripts::release_version_check::{self, ReleaseVersionError};
use chrono::{DateTime, Utc};
use clap::{Parser, ValueEnum};
use std::{
    path::{Path, PathBuf},
    process::Command,
};
use thiserror::Error;

#[derive(Clone, Copy, Debug, PartialEq, Eq, ValueEnum)]
enum Mode {
    Enabled,
    Disabled,
}
impl Mode {
    fn setting(self) -> &'static str {
        match self {
            Self::Enabled => "enabled",
            Self::Disabled => "disabled",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, ValueEnum)]
enum PersonalTeam {
    #[value(name = "YES")]
    Yes,
    #[value(name = "NO")]
    No,
}
impl PersonalTeam {
    fn setting(self) -> &'static str {
        match self {
            Self::Yes => "YES",
            Self::No => "NO",
        }
    }
}

#[derive(Parser)]
struct Configuration {
    #[arg(long, env = "BLEAT_DEVICE_ID", hide_env_values = true)]
    device_id: String,
    #[arg(long, env = "BLEAT_DEVICE_BUILD_DIRECTORY")]
    directory: PathBuf,
    #[arg(long, env = "BLEAT_BUNDLE_ID")]
    bundle_id: String,
    #[arg(long, env = "BLEAT_DEVELOPMENT_TEAM", hide_env_values = true)]
    team: String,
    #[arg(long, env = "BLEAT_TELEMETRY_AUTH_BASE_URL", hide_env_values = true)]
    auth_url: String,
    #[arg(long, env = "BLEAT_TELEMETRY_OTLP_ENDPOINT", hide_env_values = true)]
    otlp_url: String,
    #[arg(long, env = "BUILD_VERBOSE", default_value = "false", action = clap::ArgAction::Set)]
    verbose: bool,
    #[arg(
        long,
        env = "BUILD_WITHOUT_PAID_DEVELOPER",
        default_value = "NO",
        value_enum
    )]
    personal_team: PersonalTeam,
    #[arg(
        long,
        env = "BLEAT_CARPLAY_MODE",
        default_value = "enabled",
        value_enum
    )]
    carplay: Mode,
    #[arg(
        long,
        env = "BLEAT_APP_ATTEST_MODE",
        default_value = "enabled",
        value_enum
    )]
    app_attest: Mode,
    #[arg(
        long,
        env = "BLEAT_CLOUDKIT_MODE",
        default_value = "enabled",
        value_enum
    )]
    cloudkit: Mode,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BuildStage {
    Xcode,
    SignedEntitlements,
    ProvisioningProfile,
}
impl std::fmt::Display for BuildStage {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            Self::Xcode => "device build",
            Self::SignedEntitlements => "signed entitlements",
            Self::ProvisioningProfile => "provisioning profile",
        })
    }
}

#[derive(Debug, Error)]
pub enum DeviceBuildError {
    #[error("{0}")]
    ReleaseVersion(#[from] ReleaseVersionError),
    #[error("{0}")]
    Configuration(Box<clap::Error>),
    #[error("telemetry configuration is invalid at {key}: {source}")]
    TelemetryInvalid {
        key: &'static str,
        source: url::ParseError,
    },
    #[error("telemetry configuration requires HTTPS at {key}")]
    TelemetryRequiresHttps { key: &'static str },
    #[error("could not prepare the device build: {0}")]
    Prepare(std::io::Error),
    #[error("could not start {stage}: {source}")]
    CommandStart {
        stage: BuildStage,
        source: std::io::Error,
    },
    #[error("{stage} failed with {status}")]
    CommandFailed {
        stage: BuildStage,
        status: std::process::ExitStatus,
    },
    #[error("built app is missing")]
    AppMissing,
    #[error("could not read built metadata: {0}")]
    Metadata(plist::Error),
    #[error("{stage} did not return a property-list dictionary")]
    InvalidPlist { stage: BuildStage },
    #[error("built app metadata is missing {key}")]
    MissingField { key: &'static str },
    #[error("built app metadata has an invalid value at {key}")]
    InvalidField { key: &'static str },
    #[error("built app configuration differs at {key}")]
    ConfigurationMismatch { key: &'static str },
    #[error("signed capability validation failed at {key}")]
    EntitlementMismatch { key: &'static str },
}

pub struct DeviceRelease {
    pub version: String,
    pub build: String,
}

pub fn resolve_release(
    root: &Path,
    requested_version: Option<&str>,
    build_override: Option<&str>,
    now: DateTime<Utc>,
) -> Result<DeviceRelease, ReleaseVersionError> {
    let version = release_version_check::validate_repository(root, requested_version)?;
    let build = build_scripts::release_versions::resolve_build_number(build_override, now)?;
    release_version_check::validate_effective_build(&version, &build)?;
    Ok(DeviceRelease { version, build })
}

pub struct BuiltDeviceApp {
    pub app: PathBuf,
    pub bundle_id: String,
    pub device_id: String,
}

pub fn run() -> Result<BuiltDeviceApp, DeviceBuildError> {
    let release = resolve_release(
        Path::new("."),
        std::env::var("BLEAT_MARKETING_VERSION").ok().as_deref(),
        std::env::var("BLEAT_BUILD_NUMBER").ok().as_deref(),
        Utc::now(),
    )?;
    let config = Configuration::try_parse_from(std::env::args_os())
        .map_err(|error| DeviceBuildError::Configuration(Box::new(error)))?;
    let auth_url = validate_telemetry_url("BLEAT_TELEMETRY_AUTH_BASE_URL", &config.auth_url)?;
    let otlp_url = validate_telemetry_url("BLEAT_TELEMETRY_OTLP_ENDPOINT", &config.otlp_url)?;
    let app = config
        .directory
        .join("Build/Products/Release-iphoneos/Bleat.app");
    if app.exists() {
        std::fs::remove_dir_all(&app).map_err(DeviceBuildError::Prepare)?;
    }
    let mut command = Command::new("xcodebuild");
    command.args([
        "-project",
        "Bleat.xcodeproj",
        "-scheme",
        "Bleat",
        "-configuration",
        "Release",
    ]);
    if !config.verbose {
        command.arg("-quiet");
    }
    command
        .arg(format!("CURRENT_PROJECT_VERSION={}", release.build))
        .arg(format!("MARKETING_VERSION={}", release.version))
        .arg("-destination")
        .arg(format!("platform=iOS,id={}", config.device_id))
        .arg("-derivedDataPath")
        .arg(&config.directory)
        .args([
            "-allowProvisioningUpdates",
            "-allowProvisioningDeviceRegistration",
            "CODE_SIGN_STYLE=Automatic",
        ])
        .arg(format!("DEVELOPMENT_TEAM={}", config.team))
        .arg(format!("PRODUCT_BUNDLE_IDENTIFIER={}", config.bundle_id))
        .arg(format!(
            "BUILD_WITHOUT_PAID_DEVELOPER={}",
            config.personal_team.setting()
        ))
        .arg(format!(
            "BLEAT_APP_ATTEST_MODE={}",
            config.app_attest.setting()
        ))
        .arg(format!("BLEAT_CARPLAY_MODE={}", config.carplay.setting()))
        .arg(format!("BLEAT_CLOUDKIT_MODE={}", config.cloudkit.setting()))
        .arg(format!("BLEAT_TELEMETRY_AUTH_BASE_URL={}", config.auth_url))
        .arg(format!("BLEAT_TELEMETRY_OTLP_ENDPOINT={}", config.otlp_url))
        .arg("build");
    eprintln!(
        "Building Bleat for the configured device, this will take at least four minutes - do not poll before then."
    );
    let status = command
        .status()
        .map_err(|source| DeviceBuildError::CommandStart {
            stage: BuildStage::Xcode,
            source,
        })?;
    if !status.success() {
        return Err(DeviceBuildError::CommandFailed {
            stage: BuildStage::Xcode,
            status,
        });
    }
    if !app.is_dir() {
        return Err(DeviceBuildError::AppMissing);
    }
    release_version_check::validate_built_app(
        &app.join("Info.plist"),
        &release.version,
        &release.build,
    )?;
    let metadata =
        plist::Value::from_file(app.join("Info.plist")).map_err(DeviceBuildError::Metadata)?;
    let values = metadata
        .as_dictionary()
        .ok_or(DeviceBuildError::InvalidPlist {
            stage: BuildStage::Xcode,
        })?;
    let carplay = if config.personal_team == PersonalTeam::Yes {
        Mode::Disabled
    } else {
        config.carplay
    };
    // Bundle identifiers are opaque settings identities; compare their decoded values.
    if string_field(values, "CFBundleIdentifier")? != config.bundle_id {
        return Err(DeviceBuildError::ConfigurationMismatch {
            key: "CFBundleIdentifier",
        });
    }
    for (key, expected) in [
        ("BleatTelemetryAuthenticationBaseURL", &auth_url),
        ("BleatTelemetryOTLPEndpoint", &otlp_url),
    ] {
        let actual = url::Url::parse(string_field(values, key)?)
            .map_err(|_| DeviceBuildError::InvalidField { key })?;
        if actual != *expected {
            return Err(DeviceBuildError::ConfigurationMismatch { key });
        }
    }
    validate_mode(values, "BleatCarPlayMode", carplay)?;
    let mut codesign = Command::new("codesign");
    codesign.args(["-d", "--entitlements", ":-"]).arg(&app);
    let entitlements = command_plist(BuildStage::SignedEntitlements, &mut codesign)?;
    const CARPLAY: &str = "com.apple.developer.carplay-audio";
    if carplay == Mode::Enabled {
        if entitlements.get(CARPLAY).and_then(plist::Value::as_boolean) != Some(true) {
            return Err(DeviceBuildError::EntitlementMismatch { key: CARPLAY });
        }
        let mut security = Command::new("security");
        security
            .args(["cms", "-D", "-i"])
            .arg(app.join("embedded.mobileprovision"));
        let profile = command_plist(BuildStage::ProvisioningProfile, &mut security)?;
        if profile
            .get("Entitlements")
            .and_then(plist::Value::as_dictionary)
            .and_then(|values| values.get(CARPLAY))
            .and_then(plist::Value::as_boolean)
            != Some(true)
        {
            return Err(DeviceBuildError::EntitlementMismatch { key: CARPLAY });
        }
    } else if entitlements.contains_key(CARPLAY) {
        return Err(DeviceBuildError::EntitlementMismatch { key: CARPLAY });
    }
    if config.personal_team == PersonalTeam::Yes {
        for key in ["BleatAppAttestMode", "BleatCloudKitMode"] {
            validate_mode(values, key, Mode::Disabled)?;
        }
        for key in entitlements.keys() {
            if key == "com.apple.developer.devicecheck.appattest-environment"
                || key.starts_with("com.apple.developer.icloud-")
            {
                return Err(DeviceBuildError::EntitlementMismatch {
                    key: "paid-capabilities",
                });
            }
        }
        if !entitlements
            .get("keychain-access-groups")
            .and_then(plist::Value::as_array)
            .is_some_and(|groups| !groups.is_empty())
        {
            return Err(DeviceBuildError::EntitlementMismatch {
                key: "keychain-access-groups",
            });
        }
    }
    Ok(BuiltDeviceApp {
        app,
        bundle_id: config.bundle_id,
        device_id: config.device_id,
    })
}

fn command_plist(
    stage: BuildStage,
    command: &mut Command,
) -> Result<plist::Dictionary, DeviceBuildError> {
    let output = command
        .output()
        .map_err(|source| DeviceBuildError::CommandStart { stage, source })?;
    if !output.status.success() {
        return Err(DeviceBuildError::CommandFailed {
            stage,
            status: output.status,
        });
    }
    let value = plist::Value::from_reader(std::io::Cursor::new(output.stdout))
        .map_err(DeviceBuildError::Metadata)?;
    value
        .into_dictionary()
        .ok_or(DeviceBuildError::InvalidPlist { stage })
}

fn string_field<'a>(
    values: &'a plist::Dictionary,
    key: &'static str,
) -> Result<&'a str, DeviceBuildError> {
    values
        .get(key)
        .ok_or(DeviceBuildError::MissingField { key })?
        .as_string()
        .ok_or(DeviceBuildError::InvalidField { key })
}

fn validate_mode(
    values: &plist::Dictionary,
    key: &'static str,
    expected: Mode,
) -> Result<(), DeviceBuildError> {
    let actual = Mode::from_str(string_field(values, key)?, false)
        .map_err(|_| DeviceBuildError::InvalidField { key })?;
    if actual != expected {
        return Err(DeviceBuildError::ConfigurationMismatch { key });
    }
    Ok(())
}

/// Validate without including sensitive input in diagnostics.
pub fn validate_telemetry_url(
    key: &'static str,
    value: &str,
) -> Result<url::Url, DeviceBuildError> {
    let url = url::Url::parse(value)
        .map_err(|source| DeviceBuildError::TelemetryInvalid { key, source })?;
    if url.scheme() != "https" {
        return Err(DeviceBuildError::TelemetryRequiresHttps { key });
    }
    Ok(url)
}
