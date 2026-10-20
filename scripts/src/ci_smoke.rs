//! iOS app and smoke validation with Simulator startup concurrent with compilation.

use crate::test_results::{discover_expected, verify_result_bundle};
use std::error::Error;
use std::path::Path;
use std::process::{Command, ExitStatus};
use std::thread;
use std::time::{Duration, Instant};

pub type Result<T> = std::result::Result<T, Box<dyn Error + Send + Sync>>;

#[path = "ci_smoke/owned_command.rs"]
mod owned_command;
use owned_command::{Cause, Failure as CommandFailure, Running, Stage};

#[cfg(test)]
#[path = "ci_smoke/lifecycle_tests.rs"]
mod lifecycle_tests;

#[derive(Clone, Copy)]
struct Budgets {
    boot: Duration,
    build: Duration,
    cleanup: Duration,
}
impl Default for Budgets {
    fn default() -> Self {
        Self {
            boot: Duration::from_secs(300),
            build: Duration::from_secs(2400),
            cleanup: Duration::from_secs(3),
        }
    }
}

#[derive(Debug, thiserror::Error)]
#[error("build outcome: {build:?}; boot outcome: {boot:?}")]
struct PreparationFailure {
    build: Option<Box<dyn Error + Send + Sync>>,
    boot: Option<Box<dyn Error + Send + Sync>>,
}

fn preparation_results(build: Result<()>, boot: Result<()>) -> Result<()> {
    match (build, boot) {
        (Ok(()), Ok(())) => Ok(()),
        (build, boot) => Err(Box::new(PreparationFailure {
            build: build.err(),
            boot: boot.err(),
        })),
    }
}
fn erase(error: Box<CommandFailure>) -> Box<dyn Error + Send + Sync> {
    error
}
fn completed(result: std::result::Result<std::process::Output, Box<CommandFailure>>) -> Result<()> {
    result.map(|_| ()).map_err(erase)
}
fn prepare(
    build: &mut Command,
    boot: Option<Command>,
    ready: Command,
    budgets: Budgets,
) -> Result<()> {
    let start = Instant::now();
    let boot_deadline = start.checked_add(budgets.boot).ok_or_else(|| {
        erase(CommandFailure::before_spawn(
            Stage::SimulatorBoot,
            Cause::InvalidBudget,
        ))
    })?;
    let mut build = match Running::start(
        build,
        Stage::Build,
        budgets.build,
        budgets.cleanup,
        None,
        false,
    ) {
        Ok(child) => child,
        Err(error) => return preparation_results(Err(erase(error)), Ok(())),
    };
    let (mut command, stage, mut pending_ready) = if let Some(command) = boot {
        (command, Stage::SimulatorBoot, Some(ready))
    } else {
        (ready, Stage::SimulatorReadiness, None)
    };
    let remaining = || boot_deadline.saturating_duration_since(Instant::now());
    let mut boot = match Running::start(
        &mut command,
        stage,
        remaining(),
        budgets.cleanup,
        None,
        false,
    ) {
        Ok(child) => child,
        Err(error) => return preparation_results(completed(build.cancel()), Err(erase(error))),
    };
    let mut build_result: Option<Result<()>> = None;
    let mut boot_result: Option<Result<()>> = None;
    loop {
        if build_result.is_none()
            && let Some(result) = build.poll()
        {
            build_result = Some(completed(result));
        }
        if boot_result.is_none()
            && let Some(result) = boot.poll()
        {
            match (result, pending_ready.take()) {
                (Ok(_), Some(mut next)) => {
                    if build_result.as_ref().is_some_and(Result::is_err) {
                        boot_result = Some(Err(erase(CommandFailure::before_spawn(
                            Stage::SimulatorReadiness,
                            Cause::PeerFailed,
                        ))));
                    } else {
                        match Running::start(
                            &mut next,
                            Stage::SimulatorReadiness,
                            remaining(),
                            budgets.cleanup,
                            None,
                            false,
                        ) {
                            Ok(next) => boot = next,
                            Err(error) => boot_result = Some(Err(erase(error))),
                        }
                    }
                }
                (result, _) => boot_result = Some(completed(result)),
            }
        }
        if build_result.as_ref().is_some_and(Result::is_err)
            || boot_result.as_ref().is_some_and(Result::is_err)
        {
            if build_result.is_none() {
                build_result = Some(completed(build.cancel()));
            }
            if boot_result.is_none() {
                boot_result = Some(completed(boot.cancel()));
            }
        }
        match (build_result.take(), boot_result.take()) {
            (Some(build), Some(boot)) => return preparation_results(build, boot),
            (build, boot) => {
                build_result = build;
                boot_result = boot;
            }
        }
        thread::sleep(Duration::from_millis(10));
    }
}

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
    jq_command(input, Command::new("jq").args(arguments))
}

fn jq_command(input: &[u8], command: &mut Command) -> Result<String> {
    jq_with_budget(
        input,
        command,
        Duration::from_secs(120),
        Duration::from_secs(3),
    )
}
#[derive(Debug, thiserror::Error)]
#[error("JSON inspection output decoding failed: {0}")]
struct OutputDecodeFailure(#[source] std::str::Utf8Error);

fn jq_with_budget(
    input: &[u8],
    command: &mut Command,
    budget: Duration,
    cleanup: Duration,
) -> Result<String> {
    let output = owned_command::run(command, Stage::JsonInspection, budget, cleanup, Some(input))
        .map_err(erase)?;
    String::from_utf8(output.stdout)
        .map(|text| text.trim().to_owned())
        .map_err(|error| -> Box<dyn Error + Send + Sync> {
            Box::new(OutputDecodeFailure(error.utf8_error()))
        })
}

pub fn run() -> Result<()> {
    let run_id = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |duration| duration.as_millis());
    let result = format!(".build/ci-smoke/{}-{run_id}.xcresult", std::process::id());

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

    // Shared runner device: only wrapper commands are invocation-owned.
    let boot = if simulator_state == "Shutdown" {
        let mut command = Command::new("xcrun");
        command.args(["simctl", "boot", &simulator_id]);
        Some(command)
    } else if simulator_state == "Booted" {
        None
    } else {
        return Err(format!("Simulator is in unexpected state: {simulator_state}").into());
    };
    let mut ready = Command::new("xcrun");
    ready.args(["simctl", "bootstatus", &simulator_id, "-b"]);
    let test_selectors = [
        format!("-only-testing:{APP_TESTS}"),
        format!("-only-testing:{STARTUP}"),
        format!("-only-testing:{SIGNED_IN}"),
    ];
    let build_started = Instant::now();
    prepare(
        xcodebuild()
            .args([
                "-enableCodeCoverage",
                "YES",
                "-parallel-testing-enabled",
                "NO",
                "-destination",
                &resolved_destination,
                "build-for-testing",
            ])
            .args(&test_selectors),
        boot,
        ready,
        Budgets::default(),
    )?;
    println!(
        "Build and readiness completed in {}s",
        build_started.elapsed().as_secs()
    );

    // Derive the expected case set from the exact products and test selection
    // just built. This catches disabled, missing, and unexpectedly added tests.
    let discovery_path = Path::new(&result).with_extension("discovery.json");
    ensure_success(
        xcodebuild()
            .args([
                "-destination",
                &resolved_destination,
                "-enumerate-tests",
                "-test-enumeration-style",
                "flat",
                "-test-enumeration-format",
                "json",
                "-test-enumeration-output-path",
            ])
            .arg(&discovery_path)
            .arg("test-without-building")
            .status()?,
        "Enumerate smoke tests",
    )?;
    let discovery_text = std::fs::read_to_string(&discovery_path)?;
    let only = [
        APP_TESTS.to_owned(),
        STARTUP.to_owned(),
        SIGNED_IN.to_owned(),
    ];
    let expected = discover_expected(&discovery_text, &only, &[], 1)?;

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
            "-resultBundlePath",
            &result,
            "test-without-building",
        ])
        .args(&test_selectors)
        .status();
    let result_verification =
        verify_result_bundle(Path::new(&result), &expected, &[]).map(|report| {
            println!(
                "Smoke results: {} passed, {} skipped",
                report.passed, report.skipped
            )
        });
    match (test_status, result_verification) {
        (Ok(status), Ok(())) => ensure_success(status, "iOS tests"),
        (Ok(status), Err(error)) => Err(format!(
            "iOS tests exited with {status}; result verification failed: {error}"
        )
        .into()),
        (Err(error), Ok(())) => {
            Err(format!("iOS tests could not start: {error}; result verification passed").into())
        }
        (Err(error), Err(verification)) => Err(format!(
            "iOS tests could not start: {error}; result verification failed: {verification}"
        )
        .into()),
    }
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
