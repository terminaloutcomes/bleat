use std::{path::PathBuf, process::ExitCode};

use clap::Parser;
use scripts::release_version_check;

#[derive(Parser)]
struct Arguments {
    #[arg(long, default_value = ".")]
    repository_root: PathBuf,
    #[arg(long)]
    version: Option<String>,
    #[arg(long)]
    build: Option<String>,
}

fn main() -> ExitCode {
    let args = Arguments::parse();
    if let Some(build) = args.build.as_deref()
        && let Err(error) = scripts::release_versions::validate_build_number(build)
    {
        eprintln!("Release version validation failed: {error}");
        return ExitCode::FAILURE;
    }
    match release_version_check::validate_repository(&args.repository_root, args.version.as_deref())
    {
        Ok(version) => {
            println!(
                "Verified release version {version} across project.yml, Xcode, and CHANGELOG.md"
            );
            ExitCode::SUCCESS
        }
        Err(error) => {
            eprintln!("Release version validation failed: {error}");
            ExitCode::FAILURE
        }
    }
}
