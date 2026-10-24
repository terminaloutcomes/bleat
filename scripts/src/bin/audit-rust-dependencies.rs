use std::{path::PathBuf, process::ExitCode};

fn main() -> ExitCode {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..");
    match scripts::dependency_audit::run(&root) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("Dependency audit failed: {error}");
            ExitCode::FAILURE
        }
    }
}
