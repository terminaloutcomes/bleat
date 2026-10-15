use std::process::Command;

use crate::error::BleatError;

pub fn run() -> Result<(), BleatError> {
    let built = crate::device_build::run()?;
    run_command(
        "device install",
        Command::new("xcrun")
            .arg("devicectl")
            .arg("device")
            .arg("install")
            .arg("app")
            .arg("--device")
            .arg(&built.device_id)
            .arg(&built.app),
    )?;

    run_command(
        "device launch",
        Command::new("xcrun")
            .arg("devicectl")
            .arg("device")
            .arg("process")
            .arg("launch")
            .arg("--device")
            .arg(&built.device_id)
            .arg("--terminate-existing")
            .arg(&built.bundle_id),
    )?;

    Ok(())
}

fn run_command(stage: &str, command: &mut Command) -> Result<(), BleatError> {
    eprintln!("Running {stage}");
    let status = command
        .status()
        .map_err(|source| BleatError::CommandStart {
            stage: stage.to_string(),
            source,
        })?;

    if status.success() {
        Ok(())
    } else {
        Err(BleatError::CommandFailed {
            stage: stage.to_string(),
            status,
        })
    }
}
