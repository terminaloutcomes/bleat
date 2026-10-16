#![deny(
    warnings,
    clippy::panic,
    clippy::todo,
    clippy::unimplemented,
    clippy::unwrap_used,
    clippy::unreachable
)]

use std::process::ExitCode;

use build_scripts::paid_build_settings::validate_environment;

fn main() -> ExitCode {
    match validate_environment(|name| std::env::var(name)) {
        Ok(messages) => {
            for message in messages {
                eprintln!("{message}");
            }
            ExitCode::SUCCESS
        }
        Err(error) => {
            eprintln!("{error}");
            ExitCode::from(error.exit_code())
        }
    }
}
