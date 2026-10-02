use std::process::ExitCode;

use clap::Parser;
use scripts::live_fixtures::{self, Arguments};

fn main() -> ExitCode {
    match live_fixtures::run(Arguments::parse()) {
        Ok(version) => {
            println!("Captured redacted Audiobookshelf {version} fixtures");
            ExitCode::SUCCESS
        }
        Err(error) => {
            eprintln!("Audiobookshelf fixture capture failed: {error}");
            ExitCode::FAILURE
        }
    }
}
