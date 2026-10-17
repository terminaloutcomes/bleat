use thiserror::Error;

#[derive(Error, Debug)]

pub enum BleatError {
    #[error("{0}")]
    DeviceBuild(#[from] crate::device_build::DeviceBuildError),
    #[error("{0}")]
    ReleaseVersion(#[from] build_scripts::release_version_check::ReleaseVersionError),
    #[error("Missing environment variable: {0}")]
    MissingEnvironmentVariable(String),

    #[error("IO error: {0}")]
    Io(std::io::Error),

    #[error("Other error: {0}")]
    Other(String),
    #[error("Command start error at stage: {stage}, source: {source}")]
    CommandStart {
        stage: String,
        source: std::io::Error,
    },
    #[error("Command failed at stage: {stage}, status: {status}")]
    CommandFailed {
        stage: String,
        status: std::process::ExitStatus,
    },
}
