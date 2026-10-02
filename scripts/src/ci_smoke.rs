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
    let destination = std::env::var("BLEAT_SIMULATOR_DESTINATION")
        .unwrap_or_else(|_| "platform=iOS Simulator,name=iPhone 17 Pro".to_owned());
    remove_previous_result()?;

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
    let devices = checked_output(
        Command::new("xcrun").args(["simctl", "list", "devices", "available", "--json"]),
        "List available Simulators",
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
