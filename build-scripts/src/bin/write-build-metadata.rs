use std::{path::PathBuf, process::ExitCode};

use build_scripts::build_metadata::write_metadata;
use clap::Parser;

#[derive(Parser)]
struct Arguments {
    #[arg(long)]
    repository_root: PathBuf,
    #[arg(long)]
    template: PathBuf,
    #[arg(long)]
    output: PathBuf,
}

fn main() -> ExitCode {
    let args = Arguments::parse();
    match write_metadata(&args.repository_root, &args.template, &args.output) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("{error}");
            ExitCode::FAILURE
        }
    }
}
