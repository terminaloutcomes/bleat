#![deny(warnings, clippy::panic, clippy::unwrap_used)]

fn main() -> std::process::ExitCode {
    match scripts::xcode_test_runner::run() {
        Ok(()) => std::process::ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("Xcode test runner failed: {error}");
            std::process::ExitCode::FAILURE
        }
    }
}
