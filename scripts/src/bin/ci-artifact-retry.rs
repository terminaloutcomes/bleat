#![deny(warnings, clippy::panic, clippy::unwrap_used)]

#[path = "../ci_artifact_retry.rs"]
mod ci_artifact_retry;

use std::process::ExitCode;

fn main() -> ExitCode {
    match ci_artifact_retry::run(&std::env::args().skip(1).collect::<Vec<_>>()) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("::error::Artifact upload orchestration failed: {error}");
            ExitCode::FAILURE
        }
    }
}
