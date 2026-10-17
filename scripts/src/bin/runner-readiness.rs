use clap::Parser;
use scripts::runner_readiness::{Arguments, run};

#[tokio::main(flavor = "current_thread")]
async fn main() -> std::process::ExitCode {
    match run(Arguments::parse()).await {
        Ok(()) => std::process::ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("Runner readiness failed: {error}");
            std::process::ExitCode::FAILURE
        }
    }
}
