use clap::Parser;
use std::{path::PathBuf, process::ExitCode};

#[derive(Parser)]
struct Arguments {
    #[arg(long, env = "BLEAT_LARGE_LIBRARY_COUNT", default_value = "10000")]
    count: usize,
    #[arg(long, env = "BLEAT_REPOSITORY_ROOT", default_value = ".")]
    root: PathBuf,
    /// Print the live scan polling budget without generating or touching media.
    #[arg(long, conflicts_with = "output")]
    print_scan_attempts: bool,
    output: Option<PathBuf>,
}

fn main() -> ExitCode {
    let args = Arguments::parse();
    if args.print_scan_attempts {
        return match scripts::large_library::scan_attempts(args.count) {
            Ok(attempts) => {
                println!("{attempts}");
                ExitCode::SUCCESS
            }
            Err(error) => {
                eprintln!("{error}");
                ExitCode::FAILURE
            }
        };
    }
    let output = args
        .output
        .unwrap_or_else(|| args.root.join("TestSupport/ServerHarness/media-large"));
    match scripts::large_library::generate(&output, args.count) {
        Ok(()) => {
            println!("Generated {} synthetic books", args.count);
            ExitCode::SUCCESS
        }
        Err(error) => {
            eprintln!("{error}");
            ExitCode::FAILURE
        }
    }
}
