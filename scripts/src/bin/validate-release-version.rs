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
    let result =
        release_version_check::validate_repository(&args.repository_root, args.version.as_deref())
            .and_then(|version| {
                if let Some(build) = args.build.as_deref() {
                    release_version_check::validate_effective_build(&version, build)?;
                }
                Ok(version)
            });
    match result {
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
