#![deny(warnings, clippy::panic, clippy::unwrap_used)]

#[path = "../ci_smoke.rs"]
mod ci_smoke;

use std::process::ExitCode;

fn main() -> ExitCode {
    match ci_smoke::run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("iOS smoke validation failed: {error}");
            ExitCode::FAILURE
        }
    }
}
