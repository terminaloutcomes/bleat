use std::{path::PathBuf, process::ExitCode};

use clap::Parser;

#[derive(Parser)]
struct Args {
    #[arg(long)]
    root: Option<PathBuf>,
}

fn main() -> ExitCode {
    let args = Args::parse();
    let root = args
        .root
        .unwrap_or_else(|| PathBuf::from(env!("CARGO_MANIFEST_DIR")).join(".."));
    match scripts::test_audit_inventory::validate(&root) {
        Ok(coverage) => {
            println!(
                "Audit/index parity: {} host functions and {} scoped Rust functions. This does not certify semantic review or execution.",
                coverage.host_functions, coverage.rust_functions
            );
            ExitCode::SUCCESS
        }
        Err(error) => {
            eprintln!("Test audit inventory failed: {error}");
            ExitCode::FAILURE
        }
    }
}
