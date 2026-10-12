use std::path::PathBuf;
use std::process::Command;

use crate::error::BleatError;

pub fn run() -> Result<(), BleatError> {
    let version =
        crate::release_version_check::validate_repository(std::path::Path::new("."), None)?;
    let build_override = std::env::var("BLEAT_BUILD_NUMBER").ok();
    let build = crate::release_versions::resolve_build_number(
        build_override.as_deref(),
        chrono::Utc::now(),
    )
    .map_err(crate::release_version_check::ReleaseVersionError::from)?;
    crate::release_version_check::validate_effective_build(&version, &build)?;
    let bleat_device_id = required_environment_variable("BLEAT_DEVICE_ID")?;

    let bleat_device_build_directory = PathBuf::from(required_environment_variable(
        "BLEAT_DEVICE_BUILD_DIRECTORY",
    )?);

    let bleat_bundle_id = required_environment_variable("BLEAT_BUNDLE_ID")?;
    required_environment_variable("BLEAT_TELEMETRY_AUTH_BASE_URL")?;
    required_environment_variable("BLEAT_TELEMETRY_OTLP_ENDPOINT")?;

    let bleat_app = PathBuf::from(&bleat_device_build_directory)
        .join("Build/Products/Release-iphoneos/Bleat.app");

    run_command(
        "device build",
        Command::new("./scripts/build-device.sh").env("BLEAT_BUILD_NUMBER", &build),
    )?;

    crate::release_version_check::validate_built_app(
        &bleat_app.join("Info.plist"),
        &version,
        &build,
    )?;

    run_command(
        "device install",
        Command::new("xcrun")
            .arg("devicectl")
            .arg("device")
            .arg("install")
            .arg("app")
            .arg("--device")
            .arg(&bleat_device_id)
            .arg(&bleat_app),
    )?;

    run_command(
        "device launch",
        Command::new("xcrun")
            .arg("devicectl")
            .arg("device")
            .arg("process")
            .arg("launch")
            .arg("--device")
            .arg(&bleat_device_id)
            .arg("--terminate-existing")
            .arg(&bleat_bundle_id),
    )?;

    Ok(())
}

fn required_environment_variable(name: &str) -> Result<String, BleatError> {
    std::env::var(name).map_err(|_| BleatError::MissingEnvironmentVariable(name.to_string()))
}

fn run_command(stage: &str, command: &mut Command) -> Result<(), BleatError> {
    eprintln!("Running {stage}");
    let status = command
        .status()
        .map_err(|source| BleatError::CommandStart {
            stage: stage.to_string(),
            source,
        })?;

    if status.success() {
        Ok(())
    } else {
        Err(BleatError::CommandFailed {
            stage: stage.to_string(),
            status,
        })
    }
}
