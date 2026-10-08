//! Bounded orchestration around the official upload action, without parsing its logs.

use std::error::Error;
use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::path::Path;
use std::str::FromStr;
use std::time::Duration;

pub type Result<T> = std::result::Result<T, RetryError>;

#[derive(Debug)]
pub enum RetryError {
    InvalidOutcome,
    InvalidMissingFilesPolicy,
    InvalidAttempt,
    InvalidArguments,
    RequiredFileInspection(io::Error),
    RequiredArtifactNotFile,
    MissingOutput,
    OutputOpen(io::Error),
    OutputWrite(io::Error),
    Exhausted,
}

impl std::fmt::Display for RetryError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::InvalidOutcome => formatter.write_str("invalid_action_outcome: expected success, failure, skipped or cancelled"),
            Self::InvalidMissingFilesPolicy => formatter.write_str("invalid_missing_files_policy: expected error or warn"),
            Self::InvalidAttempt => formatter.write_str("invalid_retry_attempt: expected 2 or 3"),
            Self::InvalidArguments => formatter.write_str("invalid_arguments: expected prepare PATH POLICY, retry OUTCOME ATTEMPT, or finish OUTCOME OUTCOME OUTCOME"),
            Self::RequiredFileInspection(error) => write!(formatter, "required_artifact_inspection_failed: {error}"),
            Self::RequiredArtifactNotFile => formatter.write_str("required_artifact_not_file: required coverage must be an exact file"),
            Self::MissingOutput => formatter.write_str("retry_output_missing: GITHUB_OUTPUT is required"),
            Self::OutputOpen(error) => write!(formatter, "retry_output_open_failed: {error}"),
            Self::OutputWrite(error) => write!(formatter, "retry_output_write_failed: {error}"),
            Self::Exhausted => formatter.write_str("artifact_upload_incomplete: no completed upload within three attempts"),
        }
    }
}

impl Error for RetryError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            Self::RequiredFileInspection(error)
            | Self::OutputOpen(error)
            | Self::OutputWrite(error) => Some(error),
            _ => None,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Outcome {
    Success,
    Failure,
    Skipped,
    Cancelled,
}

impl FromStr for Outcome {
    type Err = RetryError;

    fn from_str(value: &str) -> std::result::Result<Self, Self::Err> {
        match value {
            "success" => Ok(Self::Success),
            "failure" => Ok(Self::Failure),
            "skipped" => Ok(Self::Skipped),
            "cancelled" => Ok(Self::Cancelled),
            _ => Err(RetryError::InvalidOutcome),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MissingFiles {
    Error,
    Warn,
}

impl FromStr for MissingFiles {
    type Err = RetryError;

    fn from_str(value: &str) -> std::result::Result<Self, Self::Err> {
        match value {
            "error" => Ok(Self::Error),
            "warn" => Ok(Self::Warn),
            _ => Err(RetryError::InvalidMissingFilesPolicy),
        }
    }
}

// Required coverage inputs are exact files. Optional diagnostics retain upstream
// directory/glob handling, including its warn-on-missing behavior.
pub fn validate_input(path: &Path, policy: MissingFiles) -> Result<()> {
    if policy == MissingFiles::Error
        && !fs::metadata(path)
            .map_err(RetryError::RequiredFileInspection)?
            .is_file()
    {
        return Err(RetryError::RequiredArtifactNotFile);
    }
    Ok(())
}

pub fn retry_delay(outcome: Outcome, next_attempt: usize) -> Result<Option<Duration>> {
    let seconds = match next_attempt {
        2 => 5,
        3 => 15,
        _ => return Err(RetryError::InvalidAttempt),
    };
    Ok(match outcome {
        Outcome::Failure => Some(Duration::from_secs(seconds)),
        Outcome::Success | Outcome::Skipped | Outcome::Cancelled => None,
    })
}

pub fn completed(outcomes: &[Outcome]) -> bool {
    !outcomes.contains(&Outcome::Cancelled) && outcomes.contains(&Outcome::Success)
}

pub fn run(arguments: &[String]) -> Result<()> {
    match arguments.first().map(String::as_str) {
        Some("prepare") if arguments.len() == 3 => {
            validate_input(Path::new(&arguments[1]), arguments[2].parse()?)
        }
        Some("retry") if arguments.len() == 3 => {
            let delay = retry_delay(
                arguments[1].parse()?,
                arguments[2]
                    .parse()
                    .map_err(|_| RetryError::InvalidAttempt)?,
            )?;
            if let Some(delay) = delay {
                println!(
                    "::warning::Artifact upload failed; retrying in {} seconds",
                    delay.as_secs()
                );
                std::thread::sleep(delay);
            }
            let output = std::env::var_os("GITHUB_OUTPUT").ok_or(RetryError::MissingOutput)?;
            writeln!(
                OpenOptions::new()
                    .append(true)
                    .open(output)
                    .map_err(RetryError::OutputOpen)?,
                "retry={}",
                delay.is_some()
            )
            .map_err(RetryError::OutputWrite)?;
            Ok(())
        }
        Some("finish") if arguments.len() == 4 => {
            let outcomes = arguments[1..]
                .iter()
                .map(|value| value.parse())
                .collect::<std::result::Result<Vec<Outcome>, _>>()?;
            if completed(&outcomes) {
                Ok(())
            } else {
                Err(RetryError::Exhausted)
            }
        }
        _ => Err(RetryError::InvalidArguments),
    }
}
