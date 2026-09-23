#![deny(warnings)]
#![deny(clippy::panic)]
#![deny(clippy::todo)]
#![deny(clippy::unimplemented)]
#![deny(clippy::unwrap_used)]
#![deny(clippy::unreachable)]

use std::process::ExitCode;

use clap::Parser;
use scripts::app_store_connect::{self, Arguments};

fn main() -> ExitCode {
    match app_store_connect::run(Arguments::parse()) {
        Ok(result) => {
            println!(
                "App Store Connect upload completed for Bleat {} ({}).",
                result.version, result.build
            );
            println!("Local evidence: {}", result.evidence_directory.display());
            println!(
                "Apple accepted the upload for processing; App Store review submission is a separate gate."
            );
            ExitCode::SUCCESS
        }
        Err(error) => {
            eprintln!("App Store Connect upload failed: {error}");
            ExitCode::FAILURE
        }
    }
}
