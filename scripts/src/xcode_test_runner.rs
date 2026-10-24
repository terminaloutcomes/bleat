//! Xcode test execution with build-derived inventory and exact result checks.

use crate::test_results::{
    ExpectedTest, TestId, VerificationReport, VerifyError, discover_expected, verify_result_bundle,
};
use clap::{Args, Parser, Subcommand};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitStatus};

#[path = "xcode_test_runner/commands.rs"]
mod commands;
mod macos_preflight;
use commands::{NativeBudgets, NativeRole, XcodeAction, native_command_status};

#[cfg(test)]
#[path = "xcode_test_runner/lifecycle_tests.rs"]
mod lifecycle_tests;

type Result<T> = std::result::Result<T, XcodeRunnerError>;

#[derive(Debug, thiserror::Error)]
pub enum XcodeRunnerError {
    #[error("BleatMac tests require a local macOS destination")]
    UnsupportedMacosDestination,
    #[error("BleatMac tests require the isolated MacTesting configuration")]
    UnsupportedMacosTestConfiguration,
    #[error("macOS test admission and fixture-root environment are owned by the runner")]
    ReservedMacosTestEnvironment,
    #[error(transparent)]
    MacosPreflight(#[from] macos_preflight::Error),
    #[error("{stage} native command failed: {source}")]
    NativeCommand {
        stage: String,
        #[source]
        source: Box<crate::test_results::CommandFailure>,
    },
    #[error("{0}")]
    Message(String),
    #[error(transparent)]
    PaidBuildModes(#[from] crate::paid_build_modes::Error),
    #[error(transparent)]
    Io(#[from] std::io::Error),
    #[error(transparent)]
    Verification(#[from] VerifyError),
    #[error("{stage} could not start: {source}")]
    CommandStart {
        stage: String,
        #[source]
        source: std::io::Error,
    },
    #[error("{stage} exited with {status}")]
    CommandFailed { stage: String, status: ExitStatus },
    #[error("result bundle already exists; preserve it or choose another path: {path}")]
    ExistingResultBundle { path: PathBuf },
    #[error("configured allowed skip is not in the selected test inventory: {selector}")]
    SkipNotDiscovered { selector: String },
    #[error("{name} must be 0 or 1")]
    InvalidBoolean { name: String },
    #[error("missing required environment variable: {name}")]
    MissingEnvironmentVariable { name: String },
    #[error("required environment variable must not be empty: {name}")]
    EmptyEnvironmentVariable { name: String },
    #[error("invalid forwarded test environment assignment; expected NAME=VALUE")]
    InvalidRunnerEnvironment,
    #[error("{stage} exited with {status}; result verification failed: {verification}")]
    TestAndVerificationFailed {
        stage: String,
        status: ExitStatus,
        verification: Box<Self>,
    },
    #[error("{stage} native command failed: {command}; result verification failed: {verification}")]
    TestStartAndVerificationFailed {
        stage: String,
        #[source]
        command: Box<Self>,
        verification: Box<Self>,
    },
}

impl From<String> for XcodeRunnerError {
    fn from(message: String) -> Self {
        Self::Message(message)
    }
}

impl From<&str> for XcodeRunnerError {
    fn from(message: &str) -> Self {
        Self::Message(message.to_owned())
    }
}

#[derive(Debug, Parser)]
#[command(about = "Run Xcode tests from the built test inventory and verify every outcome")]
pub struct Cli {
    #[command(subcommand)]
    command: RunnerCommand,
}

#[derive(Debug, Subcommand)]
enum RunnerCommand {
    /// The full local core, Release build, and Simulator gate.
    Core,
    /// Verify paid capability build modes with bounded native queries.
    PaidBuildModes,
    /// The signed macOS build and test gate.
    Macos(MacosArgs),
    /// Run a selected Xcode scheme using the legacy xctest.sh arguments.
    Xctest(XctestArgs),
}

#[derive(Debug, Args)]
struct MacosArgs {
    /// Exact XCTest selector(s); default is the isolated macOS app lane.
    #[arg(long = "test-id")]
    test_ids: Vec<String>,
    #[arg(short = 'r', long)]
    result_bundle: Option<PathBuf>,
    #[arg(skip)]
    destination: Option<String>,
    #[arg(skip)]
    runner_environment: Vec<(String, String)>,
}

#[derive(Debug, Args)]
struct XctestArgs {
    #[arg(short = 's', long, default_value = "Bleat")]
    scheme: String,
    #[arg(
        short = 'd',
        long,
        env = "BLEAT_SIMULATOR_DESTINATION",
        default_value = "platform=iOS Simulator,name=iPhone 17 Pro"
    )]
    destination: String,
    #[arg(short = 't', long)]
    test_id: Option<String>,
    #[arg(short = 'r', long)]
    result_bundle: Option<PathBuf>,
    #[arg(short = 'c', long)]
    configuration: Option<String>,
    #[arg(last = true, value_name = "NAME=VALUE")]
    forwarded_environment: Vec<String>,
}

pub fn run() -> Result<()> {
    let cli = Cli::parse();
    let root = repository_root()?;
    match cli.command {
        RunnerCommand::Core => run_core(&root),
        RunnerCommand::PaidBuildModes => {
            crate::paid_build_modes::run(&root).map_err(XcodeRunnerError::PaidBuildModes)
        }
        RunnerCommand::Macos(arguments) => run_macos(&root, arguments),
        RunnerCommand::Xctest(arguments) => run_xctest(&root, arguments),
    }
}

fn repository_root() -> Result<PathBuf> {
    let mut path = std::env::current_dir()?;
    loop {
        if path.join("Bleat.xcodeproj").is_dir() && path.join("scripts/Cargo.toml").is_file() {
            return Ok(path);
        }
        if !path.pop() {
            return Err("run this command from inside the Bleat repository".into());
        }
    }
}

fn env_boolean(name: &str, default: bool) -> Result<bool> {
    match std::env::var(name) {
        Ok(value) if value == "0" => Ok(false),
        Ok(value) if value == "1" => Ok(true),
        Ok(_) => Err(XcodeRunnerError::InvalidBoolean {
            name: name.to_owned(),
        }),
        Err(std::env::VarError::NotPresent) => Ok(default),
        Err(error) => Err(XcodeRunnerError::Message(error.to_string())),
    }
}

fn build_settings() -> Vec<(String, String)> {
    [
        ("BUILD_WITHOUT_PAID_DEVELOPER", "NO"),
        ("BLEAT_APP_ATTEST_MODE", "enabled"),
        ("BLEAT_CARPLAY_MODE", "enabled"),
        ("BLEAT_CLOUDKIT_MODE", "enabled"),
    ]
    .into_iter()
    .map(|(name, default)| {
        (
            name.to_owned(),
            std::env::var(name).unwrap_or_else(|_| default.to_owned()),
        )
    })
    .collect()
}

fn run_id() -> String {
    let millis = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |duration| duration.as_millis());
    format!("{}-{millis}", std::process::id())
}

// Aggregate scripts retain their own lifecycle/cleanup boundaries for a separate
// slice. An outer group deadline would not prove nested owners or EXIT traps ran.
fn command_status(command: &mut Command, stage: &str) -> Result<ExitStatus> {
    eprintln!("Running {stage}");
    command
        .status()
        .map_err(|source| XcodeRunnerError::CommandStart {
            stage: stage.to_owned(),
            source,
        })
}

fn ensure_success(status: ExitStatus, stage: &str) -> Result<()> {
    if status.success() {
        Ok(())
    } else {
        Err(XcodeRunnerError::CommandFailed {
            stage: stage.to_owned(),
            status,
        })
    }
}

fn run_swift_release_build() -> Result<()> {
    let stage = "Swift Release build";
    let status = native_command_status(
        Command::new("swift").args(["build", "-c", "release"]),
        NativeRole::SwiftRelease,
        stage,
        NativeBudgets::default(),
    )?;
    ensure_success(status, stage)
}

fn run_core(root: &Path) -> Result<()> {
    let skip_host = env_boolean("BLEAT_SKIP_HOST", false)?;
    let skip_simulator = env_boolean("BLEAT_SKIP_SIMULATOR", false)?;
    if !skip_host {
        ensure_success(
            native_command_status(
                Command::new("cargo").args([
                    "test",
                    "--locked",
                    "--package",
                    "build-scripts",
                    "--test",
                    "release_versions",
                ]),
                NativeRole::ReleaseVersionTests,
                "script release version tests",
                NativeBudgets::default(),
            )?,
            "script release version tests",
        )?;
        run_script(root, "test-host.sh", "signed host tests")?;
        run_swift_release_build()?;
        crate::paid_build_modes::run(root)?;
    }
    if skip_simulator {
        return Ok(());
    }

    let settings = build_settings();
    let simulator_build = XcodeBuildConfig::new(
        "Bleat",
        None,
        "generic/platform=iOS Simulator",
        ".build/xcode-derived",
        settings.clone(),
        false,
    );
    run_xcode_action(
        root,
        &simulator_build,
        XcodeAction::ResolvePackages,
        &[],
        &[],
    )?;
    let release_build = XcodeBuildConfig::new(
        "Bleat",
        Some("Release"),
        "generic/platform=iOS Simulator",
        ".build/xcode-derived",
        settings.clone(),
        true,
    );
    run_xcode_action(root, &release_build, XcodeAction::Build, &[], &[])?;

    let destination = std::env::var("BLEAT_SIMULATOR_DESTINATION")
        .unwrap_or_else(|_| "platform=iOS Simulator,name=iPhone 17 Pro".to_owned());
    let app_selectors = vec!["BleatAppTests".to_owned()];
    let run_id = run_id();
    let simulator_tests = XcodeBuildConfig::new(
        "Bleat",
        None,
        &destination,
        ".build/xcode-derived",
        settings.clone(),
        true,
    );
    run_test_gate(
        root,
        TestGateRequest {
            build: simulator_tests.clone(),
            only: app_selectors,
            exclude: Vec::new(),
            allowed_skip_selectors: Vec::new(),
            enable_code_coverage: true,
            runner_environment: Vec::new(),
            result_bundle: PathBuf::from(format!(
                ".build/test-core-results/app-tests-{run_id}.xcresult"
            )),
            stage: "Simulator app tests".to_owned(),
        },
    )?;

    let ui_selectors = vec!["BleatUITests".to_owned()];
    let ui_exclusions = vec!["BleatUITests/BleatAccessibilityAuditUITests".to_owned()];
    let ui_allowed = vec![
        "BleatUITests/BleatUITests/testAcceptsExternalURLConfirmationFromHost".to_owned(),
        "BleatUITests/BleatLiveUITests/testLiveOnlineLoginPlaybackAndDownload".to_owned(),
        "BleatUITests/BleatLiveUITests/testLiveOfflineCachedDownloadAndLocalProgress".to_owned(),
        "BleatUITests/BleatLiveUITests/testLiveExternalCoverReplacementSurvivesProcessRelaunch"
            .to_owned(),
        "BleatUITests/BleatReleaseScreenshotTests/testReleaseScreenshots".to_owned(),
        "BleatUITests/BleatLiveUITests/testReleaseSecretScanRefreshAfterTokenInvalidation"
            .to_owned(),
        "BleatUITests/BleatLiveUITests/testReleaseSecretScanLogout".to_owned(),
    ];
    run_test_gate(
        root,
        TestGateRequest {
            build: simulator_tests,
            only: ui_selectors,
            exclude: ui_exclusions,
            allowed_skip_selectors: ui_allowed,
            enable_code_coverage: true,
            runner_environment: Vec::new(),
            result_bundle: PathBuf::from(format!(
                ".build/test-core-results/ui-tests-{run_id}.xcresult"
            )),
            stage: "Simulator UI tests".to_owned(),
        },
    )
}

fn run_macos(root: &Path, arguments: MacosArgs) -> Result<()> {
    let team = std::env::var("BLEAT_DEVELOPMENT_TEAM").map_err(|_| {
        XcodeRunnerError::MissingEnvironmentVariable {
            name: "BLEAT_DEVELOPMENT_TEAM".to_owned(),
        }
    })?;
    let team = required_environment_value("BLEAT_DEVELOPMENT_TEAM", team)?;
    let owned_state = tempfile::Builder::new()
        .prefix("bleat-macos-tests-")
        .tempdir()?;
    let request = prepare_macos_request(arguments, team, owned_state.path());
    run_test_gate(root, request)
}

fn prepare_macos_request(arguments: MacosArgs, team: String, owned_root: &Path) -> TestGateRequest {
    let mut settings = build_settings();
    set_setting(&mut settings, "DEVELOPMENT_TEAM", team);
    set_setting(&mut settings, "CODE_SIGN_STYLE", "Manual".to_owned());
    set_setting(&mut settings, "ENABLE_TESTABILITY", "YES".to_owned());
    set_setting(
        &mut settings,
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS",
        "DEBUG BLEAT_MACOS_TESTING".to_owned(),
    );
    set_setting(
        &mut settings,
        "SWIFT_OPTIMIZATION_LEVEL",
        "-Onone".to_owned(),
    );
    // Keep the production identity out of the unit-test process.
    set_setting(&mut settings, "BLEAT_CLOUDKIT_MODE", "disabled".to_owned());
    set_setting(
        &mut settings,
        "BLEAT_APP_ATTEST_MODE",
        "disabled".to_owned(),
    );
    set_setting(&mut settings, "BLEAT_CARPLAY_MODE", "disabled".to_owned());
    let mut runner_environment = arguments.runner_environment.clone();
    runner_environment.push((
        "TEST_RUNNER_BLEAT_MACOS_TEST_ROOT".to_owned(),
        owned_root.to_string_lossy().into_owned(),
    ));
    TestGateRequest {
        build: XcodeBuildConfig::new(
            "BleatMac",
            Some("MacTesting"),
            arguments
                .destination
                .as_deref()
                .unwrap_or(if cfg!(target_arch = "aarch64") {
                    "platform=macOS,arch=arm64"
                } else {
                    "platform=macOS,arch=x86_64"
                }),
            ".build/macos-signed",
            settings,
            std::env::var("BUILD_VERBOSE").unwrap_or_default() != "true",
        ),
        only: arguments.test_ids,
        // This contract needs a separately provisioned app host. Keep the
        // observed failure and this named exclusion separate from lane passes.
        exclude: vec!["BleatAppTests/KeychainEntitlementTests/testApplicationHostKeepsRotatingTokensDeviceOnly".to_owned()],
        allowed_skip_selectors: Vec::new(),
        enable_code_coverage: false,
        runner_environment,
        result_bundle: arguments.result_bundle.unwrap_or_else(|| {
            PathBuf::from(format!(".build/macos-signed/tests-{}.xcresult", run_id()))
        }),
        stage: "signed macOS tests".to_owned(),
    }
}

fn required_environment_value(name: &str, value: String) -> Result<String> {
    if value.is_empty() {
        Err(XcodeRunnerError::EmptyEnvironmentVariable {
            name: name.to_owned(),
        })
    } else {
        Ok(value)
    }
}

fn set_setting(settings: &mut Vec<(String, String)>, name: &str, value: String) {
    if let Some((_, existing)) = settings.iter_mut().find(|(key, _)| key == name) {
        *existing = value;
    } else {
        settings.push((name.to_owned(), value));
    }
}

fn run_xctest(root: &Path, arguments: XctestArgs) -> Result<()> {
    let mut forwarded_environment = Vec::with_capacity(arguments.forwarded_environment.len());
    for assignment in &arguments.forwarded_environment {
        let (name, value) = assignment
            .split_once('=')
            .ok_or(XcodeRunnerError::InvalidRunnerEnvironment)?;
        let mut chars = name.chars();
        let valid_start = chars
            .next()
            .is_some_and(|character| character == '_' || character.is_ascii_alphabetic());
        if !valid_start
            || chars.any(|character| character != '_' && !character.is_ascii_alphanumeric())
        {
            return Err(XcodeRunnerError::InvalidRunnerEnvironment);
        }
        forwarded_environment.push((format!("TEST_RUNNER_{name}"), value.to_owned()));
    }
    if let Some(macos) = legacy_macos_arguments(&arguments, &forwarded_environment)? {
        return run_macos(root, macos);
    }
    let selectors = arguments.test_id.into_iter().collect::<Vec<_>>();
    let default_result = PathBuf::from(format!(".build/xctest-{}.xcresult", run_id()));
    let result = arguments.result_bundle.unwrap_or(default_result);
    run_test_gate(
        root,
        TestGateRequest {
            build: XcodeBuildConfig::new(
                &arguments.scheme,
                arguments.configuration.as_deref(),
                &arguments.destination,
                ".build/xcode-derived",
                build_settings(),
                true,
            ),
            only: selectors,
            exclude: Vec::new(),
            allowed_skip_selectors: Vec::new(),
            enable_code_coverage: false,
            runner_environment: forwarded_environment,
            result_bundle: result,
            stage: "Xcode tests".to_owned(),
        },
    )
}

fn legacy_macos_arguments(
    arguments: &XctestArgs,
    environment: &[(String, String)],
) -> Result<Option<MacosArgs>> {
    if arguments.scheme != "BleatMac" {
        return Ok(None);
    }
    if !arguments
        .destination
        .split(',')
        .any(|part| part == "platform=macOS")
    {
        return Err(XcodeRunnerError::UnsupportedMacosDestination);
    }
    if arguments
        .configuration
        .as_deref()
        .is_some_and(|value| value != "Debug" && value != "MacTesting")
    {
        return Err(XcodeRunnerError::UnsupportedMacosTestConfiguration);
    }
    if environment.iter().any(|(name, _)| {
        name == "TEST_RUNNER_BLEAT_MACOS_TEST_ROOT" || name == "TEST_RUNNER_BLEAT_MACOS_TEST_HOST"
    }) {
        return Err(XcodeRunnerError::ReservedMacosTestEnvironment);
    }
    Ok(Some(MacosArgs {
        test_ids: arguments.test_id.clone().into_iter().collect(),
        result_bundle: arguments.result_bundle.clone(),
        destination: Some(arguments.destination.clone()),
        runner_environment: environment.to_vec(),
    }))
}

fn run_script(root: &Path, name: &str, stage: &str) -> Result<()> {
    let script = root.join("scripts").join(name);
    let status = command_status(&mut Command::new(script), stage)?;
    ensure_success(status, stage)
}

#[derive(Clone)]
struct XcodeBuildConfig {
    scheme: String,
    configuration: Option<String>,
    destination: String,
    derived_data: String,
    settings: Vec<(String, String)>,
    quiet: bool,
}

impl XcodeBuildConfig {
    fn new(
        scheme: &str,
        configuration: Option<&str>,
        destination: &str,
        derived_data: &str,
        settings: Vec<(String, String)>,
        quiet: bool,
    ) -> Self {
        Self {
            scheme: scheme.to_owned(),
            configuration: configuration.map(str::to_owned),
            destination: destination.to_owned(),
            derived_data: derived_data.to_owned(),
            settings,
            quiet,
        }
    }
}

struct TestGateRequest {
    build: XcodeBuildConfig,
    only: Vec<String>,
    exclude: Vec<String>,
    allowed_skip_selectors: Vec<String>,
    enable_code_coverage: bool,
    runner_environment: Vec<(String, String)>,
    result_bundle: PathBuf,
    stage: String,
}

type ResultVerifier<'a> = dyn Fn(&Path, &[ExpectedTest], &[TestId]) -> std::result::Result<VerificationReport, VerifyError>
    + 'a;

fn run_xcode_action(
    root: &Path,
    build: &XcodeBuildConfig,
    action: XcodeAction,
    only: &[String],
    exclude: &[String],
) -> Result<ExitStatus> {
    run_xcode_action_with(root, build, action, only, exclude, Path::new("xcodebuild"))
}

fn run_xcode_action_with(
    root: &Path,
    build: &XcodeBuildConfig,
    action: XcodeAction,
    only: &[String],
    exclude: &[String],
    xcodebuild_path: &Path,
) -> Result<ExitStatus> {
    let mut command = xcodebuild_base(root, build, xcodebuild_path)?;
    add_selectors(&mut command, only, exclude);
    command.arg(action.argument());
    let status = native_command_status(
        &mut command,
        action.role(),
        action.argument(),
        NativeBudgets::default(),
    )?;
    ensure_success(status, action.argument())?;
    Ok(status)
}

fn xcodebuild_base(
    root: &Path,
    build: &XcodeBuildConfig,
    xcodebuild_path: &Path,
) -> Result<Command> {
    let mut command = Command::new(xcodebuild_path);
    command
        .current_dir(root)
        .args(["-project", "Bleat.xcodeproj", "-scheme", &build.scheme]);
    if build.quiet {
        command.arg("-quiet");
    }
    if let Some(configuration) = &build.configuration {
        command.args(["-configuration", configuration]);
    }
    command.args([
        "-destination",
        &build.destination,
        "-derivedDataPath",
        &build.derived_data,
    ]);
    for (name, value) in &build.settings {
        command.arg(format!("{name}={value}"));
    }
    Ok(command)
}

fn add_selectors(command: &mut Command, only: &[String], exclude: &[String]) {
    for selector in only {
        command.arg(format!("-only-testing:{selector}"));
    }
    for selector in exclude {
        command.arg(format!("-skip-testing:{selector}"));
    }
}

fn run_test_gate(root: &Path, request: TestGateRequest) -> Result<()> {
    run_test_gate_with(
        root,
        request,
        Path::new("xcodebuild"),
        &verify_result_bundle,
    )
}

fn run_test_gate_with(
    root: &Path,
    request: TestGateRequest,
    xcodebuild_path: &Path,
    verifier: &ResultVerifier<'_>,
) -> Result<()> {
    run_test_gate_with_budgets(
        root,
        request,
        xcodebuild_path,
        verifier,
        NativeBudgets::default(),
    )
}

fn run_test_gate_with_budgets(
    root: &Path,
    request: TestGateRequest,
    xcodebuild_path: &Path,
    verifier: &ResultVerifier<'_>,
    budgets: NativeBudgets,
) -> Result<()> {
    let TestGateRequest {
        build,
        only,
        exclude,
        allowed_skip_selectors,
        enable_code_coverage,
        runner_environment,
        result_bundle,
        stage,
    } = request;
    if root.join(&result_bundle).exists() {
        return Err(XcodeRunnerError::ExistingResultBundle {
            path: root.join(&result_bundle),
        });
    }
    let parent = result_bundle
        .parent()
        .ok_or("result bundle has no parent directory")?;
    fs::create_dir_all(root.join(parent))?;
    let discovery_file = parent.join(format!(
        "{}.discovery.json",
        result_bundle
            .file_stem()
            .and_then(|stem| stem.to_str())
            .unwrap_or("tests")
    ));
    let mut build_command = xcodebuild_base(root, &build, xcodebuild_path)?;
    if enable_code_coverage {
        build_command.args(["-enableCodeCoverage", "YES"]);
    }
    add_selectors(&mut build_command, &only, &exclude);
    build_command.arg("build-for-testing");
    ensure_success(
        native_command_status(
            &mut build_command,
            NativeRole::BuildForTesting,
            &format!("{stage} build-for-testing"),
            budgets,
        )?,
        &format!("{stage} build-for-testing"),
    )?;

    // Admission must precede enumeration too: Xcode can load the test host.
    let manifest = if build.scheme == "BleatMac" {
        let team = build
            .settings
            .iter()
            .find(|(name, _)| name == "DEVELOPMENT_TEAM")
            .map(|(_, value)| value.as_str())
            .ok_or(macos_preflight::Error::Rejected {
                stage: "runner_preparation",
                cause: "missing_signing_team",
            })?;
        let built = macos_preflight::preflight(root, &build.derived_data, team)?;
        let owned_root = runner_environment
            .iter()
            .find(|(name, _)| name == "TEST_RUNNER_BLEAT_MACOS_TEST_ROOT")
            .map(|(_, value)| value.as_str())
            .ok_or(macos_preflight::Error::Rejected {
                stage: "runner_preparation",
                cause: "missing_fixture_root",
            })?;
        Some(macos_preflight::prepare_run(&built, owned_root)?)
    } else {
        None
    };
    let test_base = || -> Result<Command> {
        if let Some(manifest) = &manifest {
            let mut command = Command::new(xcodebuild_path);
            command
                .current_dir(root)
                .arg("-xctestrun")
                .arg(manifest.path())
                .args(["-destination", &build.destination]);
            if build.quiet {
                command.arg("-quiet");
            }
            Ok(command)
        } else {
            xcodebuild_base(root, &build, xcodebuild_path)
        }
    };
    let mut enumeration = test_base()?;
    if enable_code_coverage {
        enumeration.args(["-enableCodeCoverage", "YES"]);
    }
    enumeration
        .args([
            "test-without-building",
            "-enumerate-tests",
            "-test-enumeration-style",
            "flat",
            "-test-enumeration-format",
            "json",
            "-test-enumeration-output-path",
        ])
        .arg(root.join(&discovery_file));
    ensure_success(
        native_command_status(
            &mut enumeration,
            NativeRole::Enumeration,
            &format!("{stage} test enumeration"),
            budgets,
        )?,
        &format!("{stage} test enumeration"),
    )?;
    let discovery = fs::read_to_string(root.join(&discovery_file))?;
    let expected = discover_expected(&discovery, &only, &exclude, 1)?;
    let expected_ids: Vec<_> = expected.iter().map(|test| test.id.as_string()).collect();
    println!("{stage}: discovered {} tests", expected_ids.len());

    let mut test = test_base()?;
    if enable_code_coverage {
        test.args(["-enableCodeCoverage", "YES"]);
    }
    add_selectors(&mut test, &only, &exclude);
    test.args(["-parallel-testing-enabled", "NO", "-resultBundlePath"])
        .arg(root.join(&result_bundle))
        .arg("test-without-building");
    test.envs(runner_environment.iter().map(|(name, value)| (name, value)));
    let test_result = native_command_status(&mut test, NativeRole::Execution, &stage, budgets);
    let result_check =
        resolve_allowed_skips(&expected, &allowed_skip_selectors).and_then(|allow| {
            verifier(&root.join(&result_bundle), &expected, &allow)
                .map_err(XcodeRunnerError::Verification)
        });
    match (test_result, result_check) {
        (Ok(status), Ok(report)) => {
            println!(
                "{stage}: {} passed, {} allowed skips",
                report.passed, report.skipped
            );
            ensure_success(status, &stage)
        }
        (Ok(status), Err(verification)) => Err(XcodeRunnerError::TestAndVerificationFailed {
            stage: stage.clone(),
            status,
            verification: Box::new(verification),
        }),
        (Err(command), Ok(_)) => Err(command),
        (Err(command), Err(verification)) => {
            Err(XcodeRunnerError::TestStartAndVerificationFailed {
                stage,
                command: Box::new(command),
                verification: Box::new(verification),
            })
        }
    }
}

fn resolve_allowed_skips(expected: &[ExpectedTest], selectors: &[String]) -> Result<Vec<TestId>> {
    selectors
        .iter()
        .map(|selector| {
            let id = TestId::parse(selector)?;
            if !expected.iter().any(|test| test.id == id) {
                return Err(XcodeRunnerError::SkipNotDiscovered {
                    selector: selector.clone(),
                });
            }
            Ok(id)
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::{
        TestGateRequest, XcodeBuildConfig, XcodeRunnerError, required_environment_value,
        resolve_allowed_skips, run_test_gate_with,
    };
    use crate::test_results::{ExpectedTest, TestId, verify_result_json};
    use std::fs;
    use std::path::{Path, PathBuf};

    #[test]
    fn configured_skip_requires_an_exact_identity_in_the_selected_inventory() {
        let expected = [ExpectedTest {
            id: TestId::parse("BleatUITests/BleatLiveUITests/testOffline()")
                .expect("valid discovered test identity"),
            repetitions: 1,
        }];
        let exact = vec!["BleatUITests/BleatLiveUITests/testOffline".to_owned()];
        assert_eq!(
            resolve_allowed_skips(&expected, &exact)
                .expect("exact skip exists")
                .len(),
            1
        );

        let partial = vec!["testOffline".to_owned()];
        assert!(resolve_allowed_skips(&expected, &partial).is_err());
        let wrong_suite = vec!["BleatUITests/BleatUITests/testOffline".to_owned()];
        assert!(resolve_allowed_skips(&expected, &wrong_suite).is_err());
    }

    #[test]
    fn required_macos_configuration_rejects_empty_values() {
        assert!(required_environment_value("BLEAT_DEVELOPMENT_TEAM", "TEAM123".to_owned()).is_ok());
        assert!(matches!(
            required_environment_value("BLEAT_DEVELOPMENT_TEAM", String::new()),
            Err(XcodeRunnerError::EmptyEnvironmentVariable { name }) if name == "BLEAT_DEVELOPMENT_TEAM"
        ));
    }

    #[test]
    fn package_resolution_is_invoked_as_an_xcodebuild_option() {
        let temporary = tempfile::tempdir().expect("create runner fixture directory");
        let root = temporary.path();
        let xcodebuild = root.join("xcodebuild");
        fs::write(
            &xcodebuild,
            "#!/bin/sh\nprintf '%s\\n' \"$@\" > arguments.txt\n",
        )
        .expect("write fake Xcode runner");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&xcodebuild, fs::Permissions::from_mode(0o755))
                .expect("make fake Xcode runner executable");
        }

        let config = XcodeBuildConfig::new(
            "Bleat",
            None,
            "generic/platform=iOS Simulator",
            ".build/derived",
            Vec::new(),
            false,
        );
        super::run_xcode_action_with(
            root,
            &config,
            super::XcodeAction::ResolvePackages,
            &[],
            &[],
            &xcodebuild,
        )
        .expect("package resolution succeeds");
        let arguments =
            fs::read_to_string(root.join("arguments.txt")).expect("read fake Xcode arguments");
        assert!(
            arguments
                .lines()
                .any(|argument| argument == "-resolvePackageDependencies")
        );
    }

    #[test]
    fn test_runner_checks_built_inventory_against_missing_and_extra_results() {
        let temporary = tempfile::tempdir().expect("create runner fixture directory");
        let root = temporary.path();
        let xcodebuild = root.join("xcodebuild");
        fs::write(
            &xcodebuild,
            "#!/bin/sh\nset -eu\ncase \" $* \" in\n  *\" -enumerate-tests \"*) cat > .build/test.discovery.json <<'JSON'\n{\"errors\":[],\"values\":[{\"enabledTests\":[{\"identifier\":\"Target/Suite/testExpected()\"}],\"disabledTests\":[]}]}\nJSON\n    ;;\n  *\" build-for-testing \"*) exit 0 ;;\n  *\" test-without-building \"*) mkdir -p .build/test.xcresult; exit 0 ;;\n  *) exit 31 ;;\nesac\n",
        )
        .expect("write fake Xcode runner");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&xcodebuild, fs::Permissions::from_mode(0o755))
                .expect("make fake Xcode runner executable");
        }

        let expected_result = r#"{"testNodes":[{"nodeType":"Test Case","nodeIdentifierURL":"test://com.apple.xcode/Target/Suite/testExpected","name":"expected","result":"Passed","children":[]}]}"#;
        let run = |json: String| {
            let verify = move |_: &Path, expected: &[ExpectedTest], allowed: &[TestId]| {
                verify_result_json(&json, expected, allowed)
            };
            run_test_gate_with(
                root,
                TestGateRequest {
                    build: XcodeBuildConfig::new(
                        "Bleat",
                        None,
                        "platform=iOS Simulator,id=fake",
                        ".build/derived",
                        Vec::new(),
                        false,
                    ),
                    only: Vec::new(),
                    exclude: Vec::new(),
                    allowed_skip_selectors: Vec::new(),
                    enable_code_coverage: false,
                    runner_environment: Vec::new(),
                    result_bundle: PathBuf::from(".build/test.xcresult"),
                    stage: "fake test gate".to_owned(),
                },
                &xcodebuild,
                &verify,
            )
        };

        run(expected_result.to_owned()).expect("the exact expected result passes");
        fs::remove_dir_all(root.join(".build/test.xcresult")).expect("remove result bundle");
        assert!(
            run(r#"{"testNodes":[]}"#.to_owned()).is_err(),
            "missing test must fail"
        );
        fs::remove_dir_all(root.join(".build/test.xcresult")).expect("remove result bundle");
        let extra_result = r#"{"testNodes":[{"nodeType":"Test Case","nodeIdentifierURL":"test://com.apple.xcode/Target/Suite/testUnexpected","name":"unexpected","result":"Passed","children":[]}] }"#;
        assert!(
            run(extra_result.to_owned()).is_err(),
            "extra test must fail"
        );
    }
}
