use std::{path::PathBuf, process::ExitCode};

use clap::Parser;

#[derive(Parser)]
struct Arguments {
    #[arg(long, default_value = ".")]
    root: PathBuf,
}

fn main() -> ExitCode {
    match scripts::site_news::generate(&Arguments::parse().root) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("{error}");
            ExitCode::FAILURE
        }
    }
}
