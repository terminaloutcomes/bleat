use clap::Parser;
use std::{path::PathBuf, process::ExitCode};

#[derive(Parser)]
#[command(
    about = "Check Markdown links, mdBook navigation, website routes, and mise tasks without writing files"
)]
struct Arguments {
    #[arg(long, default_value = ".")]
    repository_root: PathBuf,
}
fn main() -> ExitCode {
    let arguments = Arguments::parse();
    match scripts::documentation::check(&arguments.repository_root) {
        Ok(diagnostics) if diagnostics.is_empty() => {
            println!("Documentation references verified");
            ExitCode::SUCCESS
        }
        Ok(diagnostics) => {
            for diagnostic in diagnostics {
                eprintln!(
                    "{}:{}: {}: {}",
                    diagnostic.file.display(),
                    diagnostic.line,
                    diagnostic.kind.code(),
                    diagnostic.target
                );
            }
            ExitCode::FAILURE
        }
        Err(error) => {
            eprintln!("Documentation check failed: {error}");
            ExitCode::FAILURE
        }
    }
}
