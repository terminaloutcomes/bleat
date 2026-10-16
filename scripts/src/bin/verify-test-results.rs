#![deny(warnings, clippy::panic, clippy::unwrap_used)]

use clap::Parser;
use scripts::test_results::{ExpectedInput, ResultsInput, RunOptions, TestId, verify_files};
use std::path::PathBuf;
use std::process::ExitCode;

#[derive(Debug, Parser)]
#[command(about = "Verify exact Xcode test identities and outcomes")]
struct Args {
    #[arg(long, conflicts_with = "results_json")]
    result_bundle: Option<PathBuf>,
    #[arg(long, conflicts_with = "result_bundle")]
    results_json: Option<PathBuf>,
    #[arg(
        long,
        required_unless_present = "discovery",
        conflicts_with = "discovery"
    )]
    expected: Vec<String>,
    #[arg(long, required_unless_present = "expected")]
    discovery: Option<PathBuf>,
    #[arg(long)]
    only: Vec<String>,
    #[arg(long)]
    exclude: Vec<String>,
    #[arg(long = "allow-skip")]
    allow_skip: Vec<String>,
    #[arg(long, default_value_t = 1)]
    repetitions: usize,
}

fn main() -> ExitCode {
    let args = Args::parse();
    let results = match (args.result_bundle, args.results_json) {
        (Some(path), None) => ResultsInput::Bundle(path),
        (None, Some(path)) => ResultsInput::Json(path),
        _ => {
            eprintln!(
                "::error::Test result verification failed: provide exactly one of --result-bundle or --results-json"
            );
            return ExitCode::FAILURE;
        }
    };
    let expected = match args.discovery {
        Some(path) => ExpectedInput::Discovery(path),
        None => ExpectedInput::Fixed(args.expected),
    };
    let allow_skip = match args
        .allow_skip
        .iter()
        .map(|value| TestId::parse(value))
        .collect::<Result<Vec<_>, _>>()
    {
        Ok(identities) => identities,
        Err(error) => {
            eprintln!("::error::Test result verification failed: {error}");
            return ExitCode::FAILURE;
        }
    };
    match verify_files(RunOptions {
        results,
        expected,
        only: args.only,
        exclude: args.exclude,
        allow_skip,
        repetitions: args.repetitions,
    }) {
        Ok(report) => {
            println!(
                "verified {} passed test outcomes and {} allowed skips",
                report.passed, report.skipped
            );
            ExitCode::SUCCESS
        }
        Err(error) => {
            eprintln!("::error::Test result verification failed: {error}");
            ExitCode::FAILURE
        }
    }
}
