//! Disposable Release screenshot capture and artifact contracts.
mod capture;
mod model;
mod native;
mod png;
#[cfg(test)]
mod tests;

use clap::{ArgGroup, Parser};
use std::{path::PathBuf, process::ExitCode};

use model::{Configuration, Fixture};
use native::Native;

type Result<T> = std::result::Result<T, Error>;
#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("invalid screenshot workflow input: {0}")]
    Invalid(&'static str),
    #[error("screenshot workflow I/O failed: {0}")]
    Io(#[from] std::io::Error),
    #[error("screenshot command {label} failed: {source}")]
    Native {
        label: &'static str,
        source: Box<crate::ci_smoke::owned_command::Failure>,
    },
    #[error("screenshot workflow interrupted by signal {0}")]
    Interrupted(i32),
    #[error("screenshot disk guard: {available} bytes available, at least {minimum} required")]
    Disk { available: u64, minimum: u64 },
    #[error("screenshot HTTP operation failed: {0}")]
    Http(&'static str),
    #[error("screenshot result verification failed: {0}")]
    Verification(crate::test_results::VerifyError),
    #[error("screenshot cleanup failed for {failures:?}; original outcome retained")]
    Cleanup {
        failures: Vec<&'static str>,
        #[source]
        primary: Option<Box<Error>>,
    },
    #[error("screenshot operation failed: {primary}; additional failure: {secondary}")]
    Additional {
        primary: Box<Error>,
        secondary: Box<Error>,
    },
    #[error(
        "screenshot command retirement failed; primary outcome: {primary}; retirement: {source}"
    )]
    Retirement {
        primary: Box<Error>,
        source: Box<crate::ci_smoke::owned_command::Failure>,
    },
}

#[derive(Debug, Parser)]
#[command(about = "Capture verified Release screenshots from a disposable Barnyard server")]
#[command(group(ArgGroup::new("validation").args(["validate_options", "validate_fixtures", "validate_artifacts", "validate_manifest"])))]
pub struct Arguments {
    #[arg(long, default_value = ".")]
    repository_root: PathBuf,
    #[arg(
        long,
        env = "BLEAT_SCREENSHOT_OUTPUT_DIRECTORY",
        default_value = ".build/release-screenshots"
    )]
    output_directory: PathBuf,
    #[arg(long)]
    validate_options: bool,
    #[arg(long)]
    validate_fixtures: bool,
    #[arg(long)]
    validate_artifacts: bool,
    #[arg(long)]
    validate_manifest: bool,
}

pub fn run(arguments: Arguments) -> Result<()> {
    let root = arguments.repository_root.canonicalize()?;
    let env = std::env::vars().collect();
    let config = Configuration::from_environment(&root, &env)?;
    if arguments.validate_options {
        return Ok(());
    }
    if arguments.validate_manifest {
        return model::validate_public_manifest(&model::read_json(&model::required_path(
            &env,
            "BLEAT_SCREENSHOT_MANIFEST",
        )?)?);
    }
    let native = Native::new(root.clone())?;
    let fixture = Fixture::load(&config.fixture, &root, &native)?;
    if arguments.validate_fixtures {
        return Ok(());
    }
    if arguments.validate_artifacts {
        let manifest = model::read_json(&model::required_path(
            &env,
            "BLEAT_SCREENSHOT_ATTACHMENT_MANIFEST",
        )?)?;
        let directory = model::required_path(&env, "BLEAT_SCREENSHOT_ATTACHMENT_DIRECTORY")?;
        let dimensions = model::parse_dimensions(model::required(
            &env,
            "BLEAT_SCREENSHOT_EXPECTED_DIMENSIONS",
        )?)?;
        let orientation = model::required(&env, "BLEAT_SCREENSHOT_EXPECTED_ORIENTATION")?;
        model::validate_orientation(orientation)?;
        for appearance in &config.appearances {
            let files = model::attachment_files(&manifest, &fixture.names(appearance))?;
            for file in files.values() {
                let actual = native.dimensions(&directory.join(file))?;
                model::validate_dimensions(actual, dimensions, orientation)?;
            }
        }
        return Ok(());
    }
    let output = root.join(arguments.output_directory);
    capture::run(root, output, config, fixture, native)
}

pub fn main(arguments: Arguments) -> ExitCode {
    match run(arguments) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("Release screenshot workflow failed: {error}");
            if let Error::Cleanup {
                primary: Some(primary),
                ..
            } = &error
            {
                eprintln!("Original failure: {primary}");
            }
            ExitCode::FAILURE
        }
    }
}
