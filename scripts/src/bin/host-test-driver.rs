#![deny(warnings, clippy::panic, clippy::unwrap_used)]
use clap::Parser;
fn main() -> std::process::ExitCode {
    match scripts::host_test_driver::run(scripts::host_test_driver::Arguments::parse()) {
        Ok(()) => std::process::ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("host_driver_error code={} {error}", error.code());
            std::process::ExitCode::from(error.exit_code())
        }
    }
}
