use scripts::deploy_device;
use std::process::ExitCode;

fn main() -> ExitCode {
    match deploy_device::run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("Failed to deploy Bleat: {error}");
            ExitCode::FAILURE
        }
    }
}
