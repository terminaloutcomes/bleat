//! iOS app and smoke validation with Simulator startup concurrent with compilation.

use std::error::Error;
use std::fs;
use std::io::{self, Write};
use std::path::Path;
use std::process::{Command, ExitStatus, Stdio};
use std::thread;
use std::time::Instant;

pub type Result<T> = std::result::Result<T, Box<dyn Error + Send + Sync>>;

const RESULT: &str = ".build/ci-smoke/results.xcresult";
const DERIVED: &str = ".build/ci-smoke/derived";
const APP_TESTS: &str = "BleatAppTests";
const STARTUP: &str = "BleatUITests/BleatUITests/testLaunchingScreenDescribesStartupWork";
const SIGNED_IN: &str = "BleatUITests/BleatUITests/testMiniPlayerIsAbsentBeforePlayback";

#[derive(Debug)]
enum SimulatorSelectionError {
    NoAvailableDevice,
}

impl std::fmt::Display for SimulatorSelectionError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NoAvailableDevice => formatter.write_str(
                "No available iPhone 17 Pro on iOS 26 or newer; inspect the simulator inventory above",
            ),
        }
    }
}

impl Error for SimulatorSelectionError {}

fn default_simulator_destination(devices: &[u8]) -> Result<String> {
    let id = jq(
        devices,
        &[
            "-r",
            r#"[.devices | to_entries[]
                | select(.key | startswith("com.apple.CoreSimulator.SimRuntime.iOS-"))
                | (.key | ltrimstr("com.apple.CoreSimulator.SimRuntime.iOS-") | split("-") | map(tonumber)) as $version
                | select($version[0] >= 26)
                | .value[] | select(.isAvailable == true and .name == "iPhone 17 Pro")
                | {version: $version, id: .udid}]
                | sort_by(.version, .id) | last | .id // empty"#,
        ],
    )?;
    if id.is_empty() {
        return Err(SimulatorSelectionError::NoAvailableDevice.into());
    }
    Ok(format!("platform=iOS Simulator,id={id}"))
}

fn xcodebuild() -> Command {
    let mut command = Command::new("xcodebuild");
    command.args([
        "-project",
        "Bleat.xcodeproj",
        "-scheme",
        "Bleat",
        "-configuration",
        "Debug",
        "-derivedDataPath",
        DERIVED,
    ]);
    command
}

fn ensure_success(status: ExitStatus, stage: &str) -> Result<()> {
    if !status.success() {
        return Err(format!("{stage} exited with {status}").into());
    }
    Ok(())
}

fn checked_output(command: &mut Command, stage: &str) -> Result<Vec<u8>> {
    let output = command.output()?;
    if !output.status.success() {
        eprint!("{}", String::from_utf8_lossy(&output.stderr));
        ensure_success(output.status, stage)?;
    }
    Ok(output.stdout)
}

fn jq(input: &[u8], arguments: &[&str]) -> Result<String> {
    let mut child = Command::new("jq")
        .args(arguments)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()?;
    child
        .stdin
        .as_mut()
        .ok_or_else(|| io::Error::other("jq stdin unavailable"))?
        .write_all(input)?;
    let output = child.wait_with_output()?;
    ensure_success(output.status, "jq result inspection")?;
    Ok(String::from_utf8(output.stdout)?.trim().to_owned())
}

fn boot_simulator(id: String, state: String) -> Result<()> {
    let started = Instant::now();
    if state == "Shutdown" {
        ensure_success(
            Command::new("xcrun")
                .args(["simctl", "boot", &id])
                .status()?,
            "Simulator boot",
        )?;
    } else if state != "Booted" {
        return Err(format!("Simulator is in unexpected state: {state}").into());
    }
    ensure_success(
        Command::new("xcrun")
            .args(["simctl", "bootstatus", &id, "-b"])
            .status()?,
        "Simulator boot readiness",
    )?;
    println!("Simulator ready in {}s", started.elapsed().as_secs());
    Ok(())
}

fn remove_previous_result() -> Result<()> {
    let path = Path::new(RESULT);
    if path.is_dir() {
        fs::remove_dir_all(path)?;
    } else if path.exists() {
        fs::remove_file(path)?;
    }
    Ok(())
}

pub fn run() -> Result<()> {
    remove_previous_result()?;

    ensure_success(
        Command::new("xcodebuild").arg("-version").status()?,
        "Report Xcode",
    )?;
    // Initialize CoreSimulator and resolve an installed device before asking Xcode
    // for settings. A name-only destination implicitly asks for OS:latest.
    let devices = checked_output(
        Command::new("xcrun").args(["simctl", "list", "devices", "available", "--json"]),
        "List available Simulators",
    )?;
    println!(
        "Available Simulators: {}",
        String::from_utf8_lossy(&devices)
    );
    let destination = match std::env::var("BLEAT_SIMULATOR_DESTINATION") {
        Ok(destination) => destination,
        Err(std::env::VarError::NotPresent) => default_simulator_destination(&devices)?,
        Err(error) => return Err(error.into()),
    };
    println!("Selected destination: {destination}");

    // Ask Xcode for the same target, product and device used by both test phases.
    let settings = checked_output(
        xcodebuild().args(["-destination", &destination, "-showBuildSettings", "-json"]),
        "Resolve Xcode build settings",
    )?;
    let app_settings = jq(
        &settings,
        &[
            "-e",
            "[.[] | select(.target == \"BleatApp\") | .buildSettings] | if length == 1 then .[0] else error(\"Expected one BleatApp target\") end",
        ],
    )?;
    let simulator_id = jq(
        app_settings.as_bytes(),
        &[
            "-er",
            ".TARGET_DEVICE_IDENTIFIER | select(type == \"string\" and length > 0)",
        ],
    )?;
    let app_path = jq(
        app_settings.as_bytes(),
        &["-er", ".TARGET_BUILD_DIR + \"/\" + .FULL_PRODUCT_NAME"],
    )?;
    let simulator_state = jq(
        &devices,
        &[
            "-er",
            "--arg",
            "id",
            &simulator_id,
            "[.devices[][] | select(.udid == $id) | .state] | if length == 1 then .[0] else error(\"Expected one Simulator\") end",
        ],
    )?;
    let resolved_destination = format!("platform=iOS Simulator,id={simulator_id}");

    // The named Simulator is shared runner state, not a task-created device.
    // Join the boot worker even when compilation fails so it is never orphaned.
    let boot_id = simulator_id.clone();
    let boot_worker = thread::spawn(move || boot_simulator(boot_id, simulator_state));
    let build_started = Instant::now();
    let build_status = xcodebuild()
        .args([
            "-enableCodeCoverage",
            "YES",
            "-parallel-testing-enabled",
            "NO",
            "-destination",
            &resolved_destination,
            &format!("-only-testing:{APP_TESTS}"),
            &format!("-only-testing:{STARTUP}"),
            &format!("-only-testing:{SIGNED_IN}"),
            "build-for-testing",
        ])
        .status();
    let build_seconds = build_started.elapsed().as_secs();
    let boot_result = boot_worker
        .join()
        .map_err(|_| io::Error::other("Simulator boot worker terminated unexpectedly"))?;
    let build_status = build_status?;
    ensure_success(build_status, "Build for testing")?;
    println!("Build for testing completed in {build_seconds}s");
    boot_result?;

    // Resolve the app path from the build settings used above, then verify
    // both test targets from the result bundle even if xcodebuild fails.
    ensure_success(
        Command::new("xcrun")
            .args(["simctl", "install", &simulator_id, &app_path])
            .status()?,
        "Install smoke app",
    )?;
    let test_status = xcodebuild()
        .args([
            "-enableCodeCoverage",
            "YES",
            "-parallel-testing-enabled",
            "NO",
            "-destination",
            &resolved_destination,
            &format!("-only-testing:{APP_TESTS}"),
            &format!("-only-testing:{STARTUP}"),
            &format!("-only-testing:{SIGNED_IN}"),
            "-resultBundlePath",
            RESULT,
            "test-without-building",
        ])
        .status()?;
    let summary = checked_output(
        Command::new("xcrun").args([
            "xcresulttool",
            "get",
            "test-results",
            "summary",
            "--path",
            RESULT,
            "--format",
            "json",
        ]),
        "Read smoke result summary",
    )?;
    print!("{}", String::from_utf8_lossy(&summary));
    let tests = checked_output(
        Command::new("xcrun").args([
            "xcresulttool",
            "get",
            "test-results",
            "tests",
            "--path",
            RESULT,
            "--format",
            "json",
        ]),
        "Read smoke test results",
    )?;
    let verification = jq(
        &tests,
        &[
            "-e",
            "[.. | objects | select(.nodeType == \"Test Case\")] as $tests | ($tests | length) > 2 and all($tests[]; .result == \"Passed\") and any(.. | objects; .name == \"BleatAppTests\") and ([\"testLaunchingScreenDescribesStartupWork()\", \"testMiniPlayerIsAbsentBeforePlayback()\"] - [$tests[].name] | length) == 0",
        ],
    )?;
    println!("{verification}");
    ensure_success(test_status, "iOS tests")
}

#[cfg(test)]
mod tests {
    use super::{SimulatorSelectionError, default_simulator_destination};

    #[test]
    fn selects_installed_runtime_even_when_newer_sdk_has_no_device() {
        let inventory = br#"{"devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
                {"name":"iPhone 17 Pro","udid":"installed","isAvailable":true}],
            "com.apple.CoreSimulator.SimRuntime.iOS-26-6": []
        }}"#;
        assert_eq!(
            default_simulator_destination(inventory).expect("select installed simulator"),
            "platform=iOS Simulator,id=installed"
        );
    }

    #[test]
    fn prefers_newest_available_runtime_by_numeric_version() {
        let inventory = br#"{"devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-26-9": [
                {"name":"iPhone 17 Pro","udid":"old","isAvailable":true}],
            "com.apple.CoreSimulator.SimRuntime.iOS-26-10": [
                {"name":"iPhone 17 Pro","udid":"new","isAvailable":true}],
            "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
                {"name":"iPhone 17 Pro","udid":"unavailable","isAvailable":false}]
        }}"#;
        assert_eq!(
            default_simulator_destination(inventory).expect("select newest simulator"),
            "platform=iOS Simulator,id=new"
        );
    }

    #[test]
    fn rejects_missing_devices_old_runtimes_and_other_platforms() {
        for inventory in [
            br#"{"devices":{}}"#.as_slice(),
            br#"{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-25-0":[{"name":"iPhone 17 Pro","udid":"old","isAvailable":true}]}}"#,
            br#"{"devices":{"com.apple.CoreSimulator.SimRuntime.tvOS-26-5":[{"name":"iPhone 17 Pro","udid":"other","isAvailable":true}]}}"#,
            br#"{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-26-5":[{"name":"iPhone 17 Pro","udid":"missing","isAvailable":false}]}}"#,
        ] {
            let error = default_simulator_destination(inventory)
                .expect_err("inventory must not select an unusable simulator");
            assert!(matches!(
                error.downcast_ref::<SimulatorSelectionError>(),
                Some(SimulatorSelectionError::NoAvailableDevice)
            ));
        }
    }
}
