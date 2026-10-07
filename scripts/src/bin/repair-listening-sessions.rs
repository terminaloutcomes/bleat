use clap::Parser;
use scripts::listening_repair::{self, Arguments};
use std::process::ExitCode;

#[tokio::main(flavor = "current_thread")]
async fn main() -> ExitCode {
    match listening_repair::run(Arguments::parse()).await {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!(
                "Listening-session repair failed [{}]: {error}",
                error.code()
            );
            ExitCode::FAILURE
        }
    }
}
