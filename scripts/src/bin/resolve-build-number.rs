#![deny(
    warnings,
    clippy::panic,
    clippy::todo,
    clippy::unimplemented,
    clippy::unwrap_used,
    clippy::unreachable
)]

use std::process::ExitCode;

use clap::Parser;
use scripts::release_versions;

#[derive(Parser)]
struct Arguments {
    #[arg(long, env = "BLEAT_BUILD_NUMBER", hide = true)]
    build_number: Option<String>,
}

fn main() -> ExitCode {
    let arguments = Arguments::parse();
    match release_versions::resolve_build_number(
        arguments.build_number.as_deref(),
        chrono::Utc::now(),
    ) {
        Ok(build) => {
            println!("{build}");
            ExitCode::SUCCESS
        }
        Err(error) => {
            eprintln!("{error}");
            ExitCode::from(error.exit_code())
        }
    }
}
