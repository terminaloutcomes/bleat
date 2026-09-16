use std::error::Error;
use std::fmt;
use std::io;
use std::path::PathBuf;
use std::process::{Command, ExitStatus};

#[derive(Debug)]
pub enum DeployDeviceError {
    MissingEnvironmentVariable(&'static str),
    CommandStart {
        stage: &'static str,
        source: io::Error,
    },
    CommandFailed {
        stage: &'static str,
        status: ExitStatus,
    },
}

impl fmt::Display for DeployDeviceError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::MissingEnvironmentVariable(name) => {
                write!(formatter, "required environment variable {name} is not set")
            }
            Self::CommandStart { stage, source } => {
                write!(formatter, "could not start {stage}: {source}")
            }
            Self::CommandFailed { stage, status } => {
                write!(formatter, "{stage} exited with {status}")
            }
        }
    }
}

impl Error for DeployDeviceError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            Self::CommandStart { source, .. } => Some(source),
            Self::MissingEnvironmentVariable(_) | Self::CommandFailed { .. } => None,
        }
    }
}

pub fn run() -> Result<(), DeployDeviceError> {
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
        &mut Command::new("./scripts/build-device.sh"),
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

fn required_environment_variable(name: &'static str) -> Result<String, DeployDeviceError> {
    std::env::var(name).map_err(|_| DeployDeviceError::MissingEnvironmentVariable(name))
}

fn run_command(stage: &'static str, command: &mut Command) -> Result<(), DeployDeviceError> {
    eprintln!("Running {stage}");
    let status = command
        .status()
        .map_err(|source| DeployDeviceError::CommandStart { stage, source })?;

    if status.success() {
        Ok(())
    } else {
        Err(DeployDeviceError::CommandFailed { stage, status })
    }
}
