#![deny(warnings, clippy::panic, clippy::unwrap_used)]

use std::process::ExitCode;

fn main() -> ExitCode {
    match scripts::ci_smoke::run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("iOS smoke validation failed: {error}");
            ExitCode::FAILURE
        }
    }
}
