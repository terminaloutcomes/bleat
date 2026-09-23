use std::fs::{self, File};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, ExitStatus, Output};
use std::time::{SystemTime, UNIX_EPOCH};

use clap::{Parser, ValueEnum};
use serde::Serialize;
use sha2::{Digest, Sha256};
use thiserror::Error;

#[derive(Clone, Copy, Debug, ValueEnum)]
pub enum CapabilityMode {
    Enabled,
    Disabled,
}

impl CapabilityMode {
    fn as_str(self) -> &'static str {
        match self {
            Self::Enabled => "enabled",
            Self::Disabled => "disabled",
        }
    }
}

#[derive(Debug, Parser)]
#[command(about = "Archive, inspect, and upload Bleat to App Store Connect")]
pub struct Arguments {
    #[arg(long, env = "BLEAT_DEVELOPMENT_TEAM", hide_env_values = true)]
    development_team: String,

    #[arg(long, env = "BLEAT_BUNDLE_ID", hide_env_values = true)]
    bundle_id: String,

    #[arg(long, env = "BLEAT_TELEMETRY_AUTH_BASE_URL", hide_env_values = true)]
    telemetry_auth_base_url: String,

    #[arg(long, env = "BLEAT_TELEMETRY_OTLP_ENDPOINT", hide_env_values = true)]
    telemetry_otlp_endpoint: String,

    #[arg(long, env = "BLEAT_BUILD_NUMBER")]
    build_number: Option<String>,

    #[arg(long, env = "BLEAT_MARKETING_VERSION")]
    marketing_version: Option<String>,

    #[arg(
        long,
        env = "BLEAT_CARPLAY_MODE",
        value_enum,
        default_value = "enabled"
    )]
    carplay_mode: CapabilityMode,

    #[arg(long, default_value = ".")]
    repository_root: PathBuf,
}

#[derive(Debug)]
pub struct UploadResult {
    pub version: String,
    pub build: String,
    pub evidence_directory: PathBuf,
}

#[derive(Debug, Error)]
pub enum UploadError {
    #[error("development team must be a ten-character uppercase Apple team identifier")]
    InvalidDevelopmentTeam,

    #[error("bundle identifier contains unsupported characters")]
    InvalidBundleIdentifier,

    #[error("{name} must be an HTTPS URL")]
    InvalidProductionUrl { name: &'static str },

    #[error("build number must contain one to three dot-separated integers")]
    InvalidBuildNumber,

    #[error("BLEAT_MARKETING_VERSION is required when BLEAT_BUILD_NUMBER is not a UTC timestamp")]
    MissingMarketingVersionForCustomBuild,

    #[error("BLEAT_MARKETING_VERSION must use YYYY.MM.DD")]
    InvalidMarketingVersionFormat,

    #[error("BLEAT_MARKETING_VERSION must contain a valid calendar date")]
    InvalidMarketingVersionDate,

    #[error("App Store Connect evidence already exists at {0}")]
    EvidenceAlreadyExists(PathBuf),

    #[error("command could not start at {stage}: {source}")]
    CommandStart {
        stage: &'static str,
        #[source]
        source: std::io::Error,
    },

    #[error("command failed at {stage} with {status}; inspect {log_path}")]
    CommandFailed {
        stage: &'static str,
        status: ExitStatus,
        log_path: PathBuf,
    },

    #[error("command failed at {stage} with {status}")]
    CommandFailedWithoutLog {
        stage: &'static str,
        status: ExitStatus,
    },

    #[error("command output at {stage} was not valid UTF-8")]
    InvalidCommandOutput { stage: &'static str },

    #[error("archive bundle identifier did not match the configured App Store Connect app")]
    ArchiveBundleIdentifierMismatch,

    #[error("App Store export produced {found} IPA files instead of exactly one")]
    UnexpectedIpaCount { found: usize },

    #[error("system time predates the Unix epoch")]
    InvalidSystemTime,

    #[error("I/O failure while {operation} at {path}: {source}")]
    Io {
        operation: &'static str,
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },

    #[error("could not serialize {format} evidence: {message}")]
    Serialization {
        format: &'static str,
        message: String,
    },

    #[error("could not decode archive Info.plist: {0}")]
    InvalidArchivePlist(String),
}

#[derive(Clone, Copy, Serialize)]
#[serde(rename_all = "lowercase")]
enum ExportDestination {
    Export,
    Upload,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ExportOptions<'a> {
    destination: ExportDestination,
    distribution_bundle_identifier: &'a str,
    manage_app_version_and_build_number: bool,
    method: &'static str,
    signing_style: &'static str,
    #[serde(rename = "teamID")]
    team_id: &'a str,
    upload_symbols: bool,
}

impl<'a> ExportOptions<'a> {
    fn app_store_connect(
        destination: ExportDestination,
        development_team: &'a str,
        bundle_id: &'a str,
    ) -> Self {
        Self {
            destination,
            distribution_bundle_identifier: bundle_id,
            manage_app_version_and_build_number: false,
            method: "app-store-connect",
            signing_style: "automatic",
            team_id: development_team,
            upload_symbols: true,
        }
    }
}

#[derive(Serialize)]
#[serde(rename_all = "kebab-case")]
enum Distribution {
    AppStoreConnect,
}

#[derive(Serialize)]
#[serde(rename_all = "lowercase")]
enum UploadStatus {
    Uploaded,
}

#[derive(Serialize)]
#[serde(rename_all = "lowercase")]
enum ProcessingStatus {
    Processing,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct UploadReport<'a> {
    schema_version: u8,
    status: UploadStatus,
    processing_status: ProcessingStatus,
    distribution: Distribution,
    version: &'a str,
    build: &'a str,
    bundle_identifier: &'a str,
    ipa_sha256: &'a str,
    uploaded_at_unix_seconds: u64,
}

pub fn run(arguments: Arguments) -> Result<UploadResult, UploadError> {
    validate_development_team(&arguments.development_team)?;
    validate_bundle_identifier(&arguments.bundle_id)?;
    validate_production_url(
        "BLEAT_TELEMETRY_AUTH_BASE_URL",
        &arguments.telemetry_auth_base_url,
    )?;
    validate_production_url(
        "BLEAT_TELEMETRY_OTLP_ENDPOINT",
        &arguments.telemetry_otlp_endpoint,
    )?;

    let repository_root = canonicalize(&arguments.repository_root)?;
    let build = match arguments.build_number {
        Some(build) => build,
        None => resolve_build_number(&repository_root)?,
    };
    validate_build_number(&build)?;
    let version = resolve_marketing_version(
        &repository_root,
        &build,
        arguments.marketing_version.as_deref(),
    )?;

    let relative_evidence_directory =
        PathBuf::from(".build/app-store-connect").join(format!("{version}-{build}"));
    let evidence_directory = repository_root.join(&relative_evidence_directory);
    if evidence_directory.exists() {
        return Err(UploadError::EvidenceAlreadyExists(evidence_directory));
    }
    create_directory(&evidence_directory)?;

    let archive_path = evidence_directory.join("Bleat.xcarchive");
    let export_options_path = evidence_directory.join("ExportOptions.plist");
    let local_export_options_path = evidence_directory.join("LocalExportOptions.plist");
    write_export_options(
        &export_options_path,
        ExportDestination::Upload,
        &arguments.development_team,
        &arguments.bundle_id,
    )?;
    write_export_options(
        &local_export_options_path,
        ExportDestination::Export,
        &arguments.development_team,
        &arguments.bundle_id,
    )?;

    eprintln!("Archiving Bleat {version} ({build}) for App Store Connect...");
    run_inherited_command(
        "release archive",
        Command::new(repository_root.join("scripts/archive-beta.sh"))
            .current_dir(&repository_root)
            .env("BLEAT_ALLOW_PROVISIONING_UPDATES", "1")
            .env("BLEAT_ARCHIVE_PATH", &archive_path)
            .env("BLEAT_BUILD_NUMBER", &build)
            .env("BLEAT_MARKETING_VERSION", &version)
            .env("BLEAT_DEVELOPMENT_TEAM", &arguments.development_team)
            .env("BUILD_WITHOUT_PAID_DEVELOPER", "NO")
            .env("BLEAT_APP_ATTEST_MODE", "enabled")
            .env("BLEAT_CARPLAY_MODE", arguments.carplay_mode.as_str())
            .env("BLEAT_CLOUDKIT_MODE", "enabled")
            .env(
                "BLEAT_TELEMETRY_AUTH_BASE_URL",
                &arguments.telemetry_auth_base_url,
            )
            .env(
                "BLEAT_TELEMETRY_OTLP_ENDPOINT",
                &arguments.telemetry_otlp_endpoint,
            ),
    )?;
    verify_archive_bundle_identifier(&archive_path, &arguments.bundle_id)?;

    let repository_root_text = repository_root.to_string_lossy();
    let redactions = [
        arguments.development_team.as_str(),
        repository_root_text.as_ref(),
        arguments.telemetry_auth_base_url.as_str(),
        arguments.telemetry_otlp_endpoint.as_str(),
    ];
    let local_export_directory = evidence_directory.join("export");
    let local_export_log = evidence_directory.join("local-export.log");
    eprintln!("Exporting the distribution-signed IPA for inspection...");
    run_logged_command(
        "distribution IPA export",
        Command::new("xcodebuild")
            .current_dir(&repository_root)
            .arg("-quiet")
            .arg("-exportArchive")
            .arg("-archivePath")
            .arg(&archive_path)
            .arg("-exportPath")
            .arg(&local_export_directory)
            .arg("-exportOptionsPlist")
            .arg(&local_export_options_path)
            .arg("-allowProvisioningUpdates"),
        &local_export_log,
        &redactions,
    )?;

    let ipa_path = single_ipa(&local_export_directory)?;
    run_inherited_command(
        "distribution IPA inspection",
        Command::new("python3")
            .current_dir(&repository_root)
            .arg(repository_root.join("scripts/inspect-testflight-ipa.py"))
            .arg("--ipa")
            .arg(&ipa_path)
            .arg("--team")
            .arg(&arguments.development_team)
            .arg("--bundle-id")
            .arg(&arguments.bundle_id)
            .arg("--version")
            .arg(&version)
            .arg("--build")
            .arg(&build)
            .arg("--carplay-mode")
            .arg(arguments.carplay_mode.as_str()),
    )?;
    let ipa_sha256 = sha256(&ipa_path)?;
    let ipa_file_name = ipa_path.file_name().and_then(|name| name.to_str()).ok_or(
        UploadError::InvalidCommandOutput {
            stage: "distribution IPA filename",
        },
    )?;
    write_bytes(
        &evidence_directory.join("SHA256SUMS"),
        format!("{ipa_sha256}  export/{ipa_file_name}\n").as_bytes(),
    )?;

    let delivery_log = evidence_directory.join("delivery.log");
    eprintln!("Uploading Bleat {version} ({build}) to App Store Connect...");
    run_logged_command(
        "App Store Connect upload",
        Command::new("xcodebuild")
            .current_dir(&repository_root)
            .arg("-quiet")
            .arg("-exportArchive")
            .arg("-archivePath")
            .arg(&archive_path)
            .arg("-exportPath")
            .arg(evidence_directory.join("upload"))
            .arg("-exportOptionsPlist")
            .arg(&export_options_path)
            .arg("-allowProvisioningUpdates"),
        &delivery_log,
        &redactions,
    )?;

    let uploaded_at_unix_seconds = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| UploadError::InvalidSystemTime)?
        .as_secs();
    let report = UploadReport {
        schema_version: 1,
        status: UploadStatus::Uploaded,
        processing_status: ProcessingStatus::Processing,
        distribution: Distribution::AppStoreConnect,
        version: &version,
        build: &build,
        bundle_identifier: &arguments.bundle_id,
        ipa_sha256: &ipa_sha256,
        uploaded_at_unix_seconds,
    };
    let report_bytes =
        serde_json::to_vec_pretty(&report).map_err(|error| UploadError::Serialization {
            format: "JSON",
            message: error.to_string(),
        })?;
    write_bytes(&evidence_directory.join("report.json"), &report_bytes)?;

    Ok(UploadResult {
        version,
        build,
        evidence_directory: relative_evidence_directory,
    })
}

fn validate_development_team(value: &str) -> Result<(), UploadError> {
    if value.len() == 10
        && value
            .bytes()
            .all(|character| character.is_ascii_uppercase() || character.is_ascii_digit())
    {
        Ok(())
    } else {
        Err(UploadError::InvalidDevelopmentTeam)
    }
}

fn validate_bundle_identifier(value: &str) -> Result<(), UploadError> {
    if !value.is_empty()
        && value.bytes().all(|character| {
            character.is_ascii_alphanumeric() || character == b'.' || character == b'-'
        })
    {
        Ok(())
    } else {
        Err(UploadError::InvalidBundleIdentifier)
    }
}

fn validate_production_url(name: &'static str, value: &str) -> Result<(), UploadError> {
    match url::Url::parse(value) {
        Ok(url) if url.scheme() == "https" && url.host_str().is_some() => Ok(()),
        _ => Err(UploadError::InvalidProductionUrl { name }),
    }
}

fn validate_build_number(value: &str) -> Result<(), UploadError> {
    let components: Vec<&str> = value.split('.').collect();
    if (1..=3).contains(&components.len())
        && components.iter().all(|component| {
            !component.is_empty() && component.bytes().all(|byte| byte.is_ascii_digit())
        })
    {
        Ok(())
    } else {
        Err(UploadError::InvalidBuildNumber)
    }
}

fn canonicalize(path: &Path) -> Result<PathBuf, UploadError> {
    path.canonicalize().map_err(|source| UploadError::Io {
        operation: "resolving repository root",
        path: path.to_path_buf(),
        source,
    })
}

fn resolve_build_number(repository_root: &Path) -> Result<String, UploadError> {
    let output = command_output(
        "build-number resolution",
        Command::new(repository_root.join("scripts/resolve-build-number.sh"))
            .current_dir(repository_root),
    )?;
    String::from_utf8(output.stdout)
        .map(|value| value.trim().to_string())
        .map_err(|_| UploadError::InvalidCommandOutput {
            stage: "build-number resolution",
        })
}

fn resolve_marketing_version(
    repository_root: &Path,
    build: &str,
    override_value: Option<&str>,
) -> Result<String, UploadError> {
    let mut command = Command::new(repository_root.join("scripts/resolve-marketing-version.sh"));
    command
        .current_dir(repository_root)
        .arg(build)
        .env_remove("BLEAT_MARKETING_VERSION");
    if let Some(value) = override_value {
        command.env("BLEAT_MARKETING_VERSION", value);
    }
    let output = command
        .output()
        .map_err(|source| UploadError::CommandStart {
            stage: "marketing-version resolution",
            source,
        })?;
    if !output.status.success() {
        return match output.status.code() {
            Some(65) => Err(UploadError::MissingMarketingVersionForCustomBuild),
            Some(66) => Err(UploadError::InvalidMarketingVersionFormat),
            Some(67) => Err(UploadError::InvalidMarketingVersionDate),
            _ => Err(UploadError::CommandFailedWithoutLog {
                stage: "marketing-version resolution",
                status: output.status,
            }),
        };
    }
    String::from_utf8(output.stdout)
        .map(|value| value.trim().to_string())
        .map_err(|_| UploadError::InvalidCommandOutput {
            stage: "marketing-version resolution",
        })
}

fn create_directory(path: &Path) -> Result<(), UploadError> {
    fs::create_dir_all(path).map_err(|source| UploadError::Io {
        operation: "creating evidence directory",
        path: path.to_path_buf(),
        source,
    })
}

fn write_export_options(
    path: &Path,
    destination: ExportDestination,
    development_team: &str,
    bundle_id: &str,
) -> Result<(), UploadError> {
    let options = ExportOptions::app_store_connect(destination, development_team, bundle_id);
    plist::to_file_xml(path, &options).map_err(|error| UploadError::Serialization {
        format: "property-list",
        message: error.to_string(),
    })
}

fn verify_archive_bundle_identifier(
    archive_path: &Path,
    expected_bundle_identifier: &str,
) -> Result<(), UploadError> {
    let info_path = archive_path.join("Products/Applications/Bleat.app/Info.plist");
    let info = plist::Value::from_file(&info_path)
        .map_err(|error| UploadError::InvalidArchivePlist(error.to_string()))?;
    let actual_bundle_identifier = info
        .as_dictionary()
        .and_then(|dictionary| dictionary.get("CFBundleIdentifier"))
        .and_then(plist::Value::as_string);
    match actual_bundle_identifier {
        Some(actual) if actual == expected_bundle_identifier => Ok(()),
        _ => Err(UploadError::ArchiveBundleIdentifierMismatch),
    }
}

fn single_ipa(export_directory: &Path) -> Result<PathBuf, UploadError> {
    let entries = fs::read_dir(export_directory).map_err(|source| UploadError::Io {
        operation: "reading IPA export directory",
        path: export_directory.to_path_buf(),
        source,
    })?;
    let mut ipas = Vec::new();
    for entry in entries {
        let entry = entry.map_err(|source| UploadError::Io {
            operation: "reading IPA export entry",
            path: export_directory.to_path_buf(),
            source,
        })?;
        let path = entry.path();
        if path.extension().is_some_and(|extension| extension == "ipa") {
            ipas.push(path);
        }
    }
    if ipas.len() == 1 {
        Ok(ipas.remove(0))
    } else {
        Err(UploadError::UnexpectedIpaCount { found: ipas.len() })
    }
}

fn sha256(path: &Path) -> Result<String, UploadError> {
    let mut file = File::open(path).map_err(|source| UploadError::Io {
        operation: "opening IPA for checksum",
        path: path.to_path_buf(),
        source,
    })?;
    let mut hasher = Sha256::new();
    let mut buffer = [0_u8; 64 * 1024];
    loop {
        let count = file.read(&mut buffer).map_err(|source| UploadError::Io {
            operation: "reading IPA for checksum",
            path: path.to_path_buf(),
            source,
        })?;
        if count == 0 {
            break;
        }
        hasher.update(&buffer[..count]);
    }
    const HEX_DIGITS: &[u8; 16] = b"0123456789abcdef";
    let digest = hasher.finalize();
    let mut encoded = String::with_capacity(digest.len() * 2);
    for byte in digest {
        encoded.push(char::from(HEX_DIGITS[usize::from(byte >> 4)]));
        encoded.push(char::from(HEX_DIGITS[usize::from(byte & 0x0f)]));
    }
    Ok(encoded)
}

fn write_bytes(path: &Path, bytes: &[u8]) -> Result<(), UploadError> {
    let mut file = File::create(path).map_err(|source| UploadError::Io {
        operation: "creating evidence file",
        path: path.to_path_buf(),
        source,
    })?;
    file.write_all(bytes).map_err(|source| UploadError::Io {
        operation: "writing evidence file",
        path: path.to_path_buf(),
        source,
    })
}

fn run_inherited_command(stage: &'static str, command: &mut Command) -> Result<(), UploadError> {
    let status = command
        .status()
        .map_err(|source| UploadError::CommandStart { stage, source })?;
    if status.success() {
        Ok(())
    } else {
        Err(UploadError::CommandFailedWithoutLog { stage, status })
    }
}

fn command_output(stage: &'static str, command: &mut Command) -> Result<Output, UploadError> {
    let output = command
        .output()
        .map_err(|source| UploadError::CommandStart { stage, source })?;
    if output.status.success() {
        Ok(output)
    } else {
        Err(UploadError::CommandFailedWithoutLog {
            stage,
            status: output.status,
        })
    }
}

fn run_logged_command(
    stage: &'static str,
    command: &mut Command,
    log_path: &Path,
    redactions: &[&str],
) -> Result<(), UploadError> {
    let output = command
        .output()
        .map_err(|source| UploadError::CommandStart { stage, source })?;
    let mut combined = String::from_utf8_lossy(&output.stdout).into_owned();
    combined.push_str(&String::from_utf8_lossy(&output.stderr));
    for value in redactions.iter().filter(|value| !value.is_empty()) {
        combined = combined.replace(value, "<redacted>");
    }
    eprint!("{combined}");
    write_bytes(log_path, combined.as_bytes())?;
    if output.status.success() {
        Ok(())
    } else {
        Err(UploadError::CommandFailed {
            stage,
            status: output.status,
            log_path: log_path.to_path_buf(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn validates_release_identifiers() {
        assert!(validate_development_team("ABCDE12345").is_ok());
        assert!(validate_development_team("invalid").is_err());
        assert!(validate_bundle_identifier("com.example.Bleat").is_ok());
        assert!(validate_bundle_identifier("com.example.$(id)").is_err());
        assert!(validate_build_number("20260921.1146.56").is_ok());
        assert!(validate_build_number("2026.09.21.1").is_err());
    }

    #[test]
    fn resolves_public_upload_marketing_version_through_shared_script() {
        let repository = tempfile::tempdir().expect("temporary repository should be created");
        let script_directory = repository.path().join("scripts");
        fs::create_dir(&script_directory).expect("script directory should be created");
        let resolver = script_directory.join("resolve-marketing-version.sh");
        fs::write(
            &resolver,
            b"#!/bin/zsh\nprint -r -- \"${BLEAT_MARKETING_VERSION:-derived-$1}\"\n",
        )
        .expect("resolver fixture should be written");
        let mut permissions = fs::metadata(&resolver)
            .expect("resolver metadata should be readable")
            .permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(&resolver, permissions).expect("resolver fixture should be executable");

        let derived = resolve_marketing_version(repository.path(), "20260923.0642.54", None)
            .expect("marketing version should be derived");
        assert_eq!(derived, "derived-20260923.0642.54");

        let overridden = resolve_marketing_version(repository.path(), "7", Some("2026.09.23"))
            .expect("marketing-version override should be forwarded");
        assert_eq!(overridden, "2026.09.23");
    }

    #[test]
    fn preserves_typed_marketing_version_failures() {
        let repository = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("scripts package should have a repository parent");

        assert!(matches!(
            resolve_marketing_version(repository, "7", None),
            Err(UploadError::MissingMarketingVersionForCustomBuild)
        ));
        assert!(matches!(
            resolve_marketing_version(repository, "7", Some("2026.9.23")),
            Err(UploadError::InvalidMarketingVersionFormat)
        ));
        assert!(matches!(
            resolve_marketing_version(repository, "7", Some("2026.02.30")),
            Err(UploadError::InvalidMarketingVersionDate)
        ));
    }

    #[test]
    fn public_export_options_omit_internal_only_restriction() {
        let path = std::env::temp_dir().join(format!(
            "bleat-app-store-options-{}-{}.plist",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .expect("test clock must be after Unix epoch")
                .as_nanos()
        ));
        write_export_options(
            &path,
            ExportDestination::Upload,
            "ABCDE12345",
            "com.example.Bleat",
        )
        .expect("export options should serialize");
        let value = plist::Value::from_file(&path).expect("export options should decode");
        fs::remove_file(&path).expect("temporary export options should be removable");
        let dictionary = value
            .as_dictionary()
            .expect("export options should be a dictionary");
        assert_eq!(dictionary.len(), 7);
        assert_eq!(
            dictionary
                .get("destination")
                .and_then(plist::Value::as_string),
            Some("upload")
        );
        assert_eq!(
            dictionary.get("method").and_then(plist::Value::as_string),
            Some("app-store-connect")
        );
        assert!(!dictionary.contains_key("testFlightInternalTestingOnly"));
    }

    #[test]
    fn computes_standard_sha256_checksum() {
        let path = std::env::temp_dir().join(format!(
            "bleat-app-store-checksum-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .expect("test clock must be after Unix epoch")
                .as_nanos()
        ));
        fs::write(&path, b"abc").expect("checksum fixture should be writable");
        let checksum = sha256(&path).expect("checksum should succeed");
        fs::remove_file(&path).expect("checksum fixture should be removable");
        assert_eq!(
            checksum,
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }
}
