use std::process::ExitCode;

fn main() -> ExitCode {
    match scripts::device_build::run() {
        Ok(_) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("Failed to build Bleat: {error}");
            ExitCode::FAILURE
        }
    }
}
