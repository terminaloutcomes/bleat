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
    build_number: String,
    #[arg(long, env = "BLEAT_MARKETING_VERSION", hide = true)]
    marketing_version: Option<String>,
}

fn main() -> ExitCode {
    let arguments = Arguments::parse();
    match release_versions::resolve_marketing_version(
        &arguments.build_number,
        arguments.marketing_version.as_deref(),
    ) {
        Ok(version) => {
            println!("{version}");
            ExitCode::SUCCESS
        }
        Err(error) => {
            eprintln!("{error}");
            ExitCode::from(error.exit_code())
        }
    }
}
