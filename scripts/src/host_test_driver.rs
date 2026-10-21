//! Host-test orchestration with signal-owned native command retirement.
use crate::ci_smoke::owned_command::{Cause, Failure, OutputMode, Running, Stage};
use clap::{Parser, ValueEnum};
use std::{
    ffi::OsStr,
    fs::{self, OpenOptions},
    io::{self, Cursor, Write},
    os::unix::{fs::OpenOptionsExt, process::ExitStatusExt},
    path::{Path, PathBuf},
    process::{Command, Output, Stdio},
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
    thread,
    time::Duration,
};

#[derive(Clone, Copy, Debug, PartialEq, Eq, ValueEnum)]
pub enum Signing {
    Required,
    Unsigned,
}
impl Signing {
    fn value(self) -> &'static str {
        match self {
            Self::Required => "required",
            Self::Unsigned => "unsigned",
        }
    }
}
#[derive(Parser)]
pub struct Arguments {
    #[arg(long)]
    repository_root: Option<PathBuf>,
    #[arg(long, env = "BLEAT_HOST_SIGNING", default_value = "required")]
    signing: Signing,
    #[arg(long, env = "BLEAT_DEVELOPMENT_TEAM", hide_env_values = true)]
    development_team: Option<String>,
}
#[derive(Clone, Copy, Debug)]
pub enum Phase {
    Preparation,
    BuildTests,
    BinaryDirectory,
    GenerateRunner,
    BuildRunner,
    VerifySignature,
    ReadEntitlements,
    SDKDirectory,
    SwiftToolchain,
    CoveragePath,
    ExecuteTests,
    MergeProfile,
    VerifyReports,
    ExportCoverage,
    NormalizeCoverage,
}
#[derive(Clone, Copy, Debug)]
pub enum SigningIdentityField {
    Team,
    Application,
    KeychainGroups,
}
#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("signal handler registration failed: {0}")]
    Signal(#[source] io::Error),
    #[error("required signing team is missing")]
    MissingTeam,
    #[error("repository root is unavailable")]
    Root,
    #[error("phase={phase:?}: {source}")]
    Io {
        phase: Phase,
        #[source]
        source: io::Error,
    },
    #[error("phase={phase:?}: {source}")]
    Command {
        phase: Phase,
        #[source]
        source: Box<Failure>,
    },
    #[error("phase={phase:?}: native output is not a single UTF-8 path")]
    PathOutput { phase: Phase },
    #[error("signed runner provisioning profile is missing")]
    MissingProfile,
    #[error("signed runner entitlements are malformed")]
    EntitlementsFormat,
    #[error("signed runner entitlement does not match: {0:?}")]
    EntitlementsIdentity(SigningIdentityField),
    #[error("host test product is missing")]
    MissingProduct,
    #[error("signed host produced no coverage profiles")]
    MissingProfiles,
    #[error("phase={phase:?}: interrupted by signal {signal}")]
    Interrupted { phase: Phase, signal: i32 },
}
impl Error {
    pub fn code(&self) -> &'static str {
        match self {
            Self::Signal(_) => "signal_registration_failed",
            Self::MissingTeam => "signing_team_missing",
            Self::Root => "repository_root_missing",
            Self::Io { .. } => "host_artifact_io_failed",
            Self::PathOutput { .. } => "native_path_output_invalid",
            Self::MissingProfile => "runner_profile_missing",
            Self::EntitlementsFormat => "runner_entitlements_malformed",
            Self::EntitlementsIdentity(SigningIdentityField::Team) => "runner_team_mismatch",
            Self::EntitlementsIdentity(SigningIdentityField::Application) => {
                "runner_application_identifier_mismatch"
            }
            Self::EntitlementsIdentity(SigningIdentityField::KeychainGroups) => {
                "runner_keychain_group_mismatch"
            }
            Self::MissingProduct => "host_test_product_missing",
            Self::MissingProfiles => "host_coverage_profiles_missing",
            Self::Interrupted { .. } => "host_driver_interrupted",
            Self::Command { source, .. } => match source.cause {
                Cause::Spawn(_) => "native_spawn_failed",
                Cause::Exit(_) => "native_exit_failed",
                Cause::Interrupted { .. } => "host_driver_interrupted",
                Cause::Cleanup => "native_cleanup_failed",
                Cause::Capture => "native_capture_failed",
                Cause::Poll(_) => "native_exit_observation_failed",
                Cause::Input(_) => "native_input_failed",
                Cause::CaptureSetup(_) => "native_capture_setup_failed",
                Cause::InvalidBudget => "native_budget_invalid",
                Cause::InvalidCaptureLimit => "native_capture_limit_invalid",
                Cause::Deadline { .. } => "native_deadline",
                Cause::PeerFailed => "native_peer_failed",
            },
        }
    }
    pub fn exit_code(&self) -> u8 {
        let code = match self {
            Self::Interrupted { signal, .. } => Some(128 + signal),
            Self::Command { source, .. } => match &source.cause {
                Cause::Interrupted { signal } => Some(128 + signal),
                Cause::Exit(status) => status.code().or_else(|| status.signal().map(|s| 128 + s)),
                _ => None,
            },
            _ => None,
        };
        code.and_then(|code| u8::try_from(code).ok())
            .filter(|code| *code != 0)
            .unwrap_or(1)
    }
}
type Result<T> = std::result::Result<T, Error>;
fn artifact<T>(phase: Phase, operation: io::Result<T>) -> Result<T> {
    operation.map_err(|source| Error::Io { phase, source })
}
struct Signals {
    value: Arc<AtomicUsize>,
    ids: Vec<signal_hook::SigId>,
}
impl Signals {
    fn new() -> Result<Self> {
        let mut owner = Self {
            value: Arc::new(AtomicUsize::new(0)),
            ids: vec![],
        };
        for signal in [libc::SIGHUP, libc::SIGINT, libc::SIGQUIT, libc::SIGTERM] {
            owner.ids.push(
                signal_hook::flag::register_usize(
                    signal,
                    Arc::clone(&owner.value),
                    signal as usize,
                )
                .map_err(Error::Signal)?,
            );
        }
        Ok(owner)
    }
    fn signal(&self) -> Option<i32> {
        i32::try_from(self.value.load(Ordering::SeqCst))
            .ok()
            .filter(|signal| *signal != 0)
    }
    fn check(&self, phase: Phase) -> Result<()> {
        match self.signal() {
            Some(signal) => Err(Error::Interrupted { phase, signal }),
            None => Ok(()),
        }
    }
}
impl Drop for Signals {
    fn drop(&mut self) {
        for id in self.ids.drain(..) {
            signal_hook::low_level::unregister(id);
        }
    }
}
struct Driver {
    root: PathBuf,
    signing: Signing,
    signals: Signals,
}
impl Driver {
    fn run(&self, phase: Phase, command: &mut Command, mode: OutputMode) -> Result<Output> {
        self.signals.check(phase)?;
        command
            .current_dir(&self.root)
            .env("BLEAT_HOST_SIGNING", self.signing.value());
        let mut running =
            Running::start_interruptible(command, Stage::HostDriver, Duration::from_secs(3), mode)
                .map_err(|source| Error::Command { phase, source })?;
        loop {
            if let Some(signal) = self.signals.signal() {
                return running
                    .interrupt(signal)
                    .map_err(|source| Error::Command { phase, source });
            }
            if let Some(result) = running.poll() {
                return result.map_err(|source| Error::Command { phase, source });
            }
            thread::sleep(Duration::from_millis(10));
        }
    }
    fn inherited(&self, phase: Phase, command: &mut Command) -> Result<()> {
        self.run(phase, command, OutputMode::Inherit).map(|_| ())
    }
    fn path(&self, phase: Phase, command: &mut Command) -> Result<PathBuf> {
        let output = self.run(phase, command, OutputMode::Stdout)?;
        let text = std::str::from_utf8(&output.stdout)
            .map_err(|_| Error::PathOutput { phase })?
            .trim();
        if text.is_empty() || text.lines().count() != 1 {
            return Err(Error::PathOutput { phase });
        }
        Ok(PathBuf::from(text))
    }
}
fn clean_reports(results: &Path, coverage: &Path) -> Result<()> {
    for directory in [results, coverage] {
        artifact(Phase::Preparation, fs::create_dir_all(directory))?;
        for entry in artifact(Phase::Preparation, fs::read_dir(directory))? {
            let entry = artifact(Phase::Preparation, entry)?;
            let path = entry.path();
            let remove = if directory == results {
                path.extension() == Some(OsStr::new("xml"))
            } else {
                matches!(
                    path.extension().and_then(OsStr::to_str),
                    Some("profdata" | "profraw")
                ) || matches!(entry.file_name().to_str(), Some("lcov.info" | "raw.lcov"))
            };
            if remove {
                artifact(Phase::Preparation, fs::remove_file(path))?;
            }
        }
    }
    Ok(())
}
fn verify_entitlements(bytes: &[u8], team: &str) -> Result<()> {
    let value =
        plist::Value::from_reader(Cursor::new(bytes)).map_err(|_| Error::EntitlementsFormat)?;
    let dict = value.as_dictionary().ok_or(Error::EntitlementsFormat)?;
    let identity = format!("{team}.com.terminaloutcomes.Bleat.HostTests");
    if dict
        .get("com.apple.developer.team-identifier")
        .and_then(plist::Value::as_string)
        != Some(team)
    {
        return Err(Error::EntitlementsIdentity(SigningIdentityField::Team));
    }
    if dict
        .get("com.apple.application-identifier")
        .and_then(plist::Value::as_string)
        != Some(identity.as_str())
    {
        return Err(Error::EntitlementsIdentity(
            SigningIdentityField::Application,
        ));
    }
    if dict
        .get("keychain-access-groups")
        .and_then(plist::Value::as_array)
        != Some(&vec![plist::Value::String(identity)])
    {
        return Err(Error::EntitlementsIdentity(
            SigningIdentityField::KeychainGroups,
        ));
    }
    Ok(())
}
fn write_private(path: &Path, bytes: &[u8], phase: Phase) -> Result<()> {
    let mut file = artifact(
        phase,
        OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(path),
    )?;
    artifact(phase, file.write_all(bytes))
}
pub fn run(arguments: Arguments) -> Result<()> {
    let signals = Signals::new()?;
    let root = arguments
        .repository_root
        .or_else(|| {
            Path::new(env!("CARGO_MANIFEST_DIR"))
                .parent()
                .map(Path::to_path_buf)
        })
        .ok_or(Error::Root)?;
    let root = artifact(Phase::Preparation, fs::canonicalize(root))?;
    let driver = Driver {
        root,
        signing: arguments.signing,
        signals,
    };
    let team = match arguments.signing {
        Signing::Required => Some(
            arguments
                .development_team
                .filter(|v| !v.is_empty())
                .ok_or(Error::MissingTeam)?,
        ),
        Signing::Unsigned => {
            println!("Unsigned coverage lane: synchronizable Keychain test is excluded");
            None
        }
    };
    let results = driver.root.join(".build/host-results");
    let coverage = driver.root.join(".build/coverage/swift-host");
    clean_reports(&results, &coverage)?;
    driver.inherited(
        Phase::BuildTests,
        Command::new("swift").args(["build", "--build-tests", "--enable-code-coverage"]),
    )?;
    let bin = driver.path(
        Phase::BinaryDirectory,
        Command::new("swift").args(["build", "--show-bin-path"]),
    )?;
    let mut runner = None;
    let mut platform = None;
    let mut toolchain = None;
    let mut unsigned_profile = None;
    if let Some(team) = team {
        let host = driver.root.join(".build/host-runner");
        artifact(Phase::Preparation, fs::create_dir_all(&host))?;
        artifact(
            Phase::Preparation,
            fs::copy(
                driver
                    .root
                    .join("TestSupport/HostTests/Runner.entitlements"),
                host.join("Runner.entitlements"),
            ),
        )?;
        driver.inherited(
            Phase::GenerateRunner,
            Command::new("xcodegen").args([
                "generate",
                "--spec",
                "TestSupport/HostTests/project.yml",
                "--project",
                ".build/host-runner",
            ]),
        )?;
        let architecture = driver.path(Phase::BuildRunner, Command::new("uname").arg("-m"))?;
        driver.inherited(
            Phase::BuildRunner,
            Command::new("xcodebuild")
                .args([
                    "-quiet",
                    "-project",
                    ".build/host-runner/BleatHostRunner.xcodeproj",
                    "-scheme",
                    "BleatHostRunner",
                    "-configuration",
                    "Debug",
                    "-destination",
                ])
                .arg(format!("platform=macOS,arch={}", architecture.display()))
                .args([
                    "-derivedDataPath",
                    ".build/host-runner-derived",
                    "-allowProvisioningUpdates",
                ])
                .arg(format!("DEVELOPMENT_TEAM={team}"))
                .arg("build"),
        )?;
        let app = driver
            .root
            .join(".build/host-runner-derived/Build/Products/Debug/BleatHostRunner.app");
        driver.inherited(
            Phase::VerifySignature,
            Command::new("codesign")
                .args(["--verify", "--strict"])
                .arg(&app),
        )?;
        if !app.join("Contents/embedded.provisionprofile").is_file() {
            return Err(Error::MissingProfile);
        }
        let entitlements = driver.run(
            Phase::ReadEntitlements,
            Command::new("codesign")
                .args(["-d", "--entitlements", "-", "--xml"])
                .arg(&app),
            OutputMode::Both,
        )?;
        write_private(
            &results.join("runner-entitlements.plist"),
            &entitlements.stdout,
            Phase::ReadEntitlements,
        )?;
        verify_entitlements(&entitlements.stdout, &team)?;
        println!("Verified signed host identity, Keychain entitlement, and profile presence");
        platform = Some(
            driver
                .path(
                    Phase::SDKDirectory,
                    Command::new("xcrun").args(["--sdk", "macosx", "--show-sdk-platform-path"]),
                )?
                .join("Developer"),
        );
        let swift = driver.path(
            Phase::SwiftToolchain,
            Command::new("xcrun").args(["--find", "swift"]),
        )?;
        toolchain = Some(
            swift
                .parent()
                .and_then(Path::parent)
                .map(Path::to_path_buf)
                .ok_or(Error::PathOutput {
                    phase: Phase::SwiftToolchain,
                })?,
        );
        runner = Some(app.join("Contents/MacOS/BleatHostRunner"));
    } else {
        unsigned_profile = Some(driver.path(
            Phase::CoveragePath,
            Command::new("swift").args(["test", "--show-codecov-path"]),
        )?);
    }
    let products: &[&str] = if bin
        .join("BleatCoreAppPackageTests.xctest/Contents/MacOS/BleatCoreAppPackageTests")
        .is_file()
    {
        &["BleatCoreAppPackageTests"]
    } else {
        &["BleatCoreTests", "BleatTranscriptionTests"]
    };
    let mut reports = vec![];
    let mut profiles = vec![];
    let mut objects = vec![];
    for product in products {
        let binary = bin.join(format!("{product}.xctest/Contents/MacOS/{product}"));
        if !binary.is_file() {
            return Err(Error::MissingProduct);
        }
        let report = results.join(format!("{product}.xml"));
        let profile = coverage.join(format!("{product}.profdata"));
        if let (Some(runner), Some(platform), Some(toolchain)) = (&runner, &platform, &toolchain) {
            driver.inherited(
                Phase::ExecuteTests,
                Command::new(runner)
                    .env(
                        "DYLD_FRAMEWORK_PATH",
                        format!(
                            "{}:{}",
                            platform.join("Library/Frameworks").display(),
                            platform.join("Library/PrivateFrameworks").display()
                        ),
                    )
                    .env(
                        "DYLD_LIBRARY_PATH",
                        format!(
                            "{}:{}",
                            platform.join("usr/lib").display(),
                            toolchain.join("lib/swift/macosx").display()
                        ),
                    )
                    .env(
                        "LLVM_PROFILE_FILE",
                        coverage.join(format!("{product}-%p-%m.profraw")),
                    )
                    .args(["--test-bundle-path"])
                    .arg(&binary)
                    .args([
                        "--testing-library",
                        "swift-testing",
                        "--no-parallel",
                        "--xunit-output",
                    ])
                    .arg(&report),
            )?;
            let mut raw = vec![];
            for entry in artifact(Phase::MergeProfile, fs::read_dir(&coverage))? {
                let path = artifact(Phase::MergeProfile, entry)?.path();
                if path.file_name().and_then(OsStr::to_str).is_some_and(|n| {
                    n.starts_with(&format!("{product}-")) && n.ends_with(".profraw")
                }) {
                    raw.push(path);
                }
            }
            if raw.is_empty() {
                return Err(Error::MissingProfiles);
            }
            driver.inherited(
                Phase::MergeProfile,
                Command::new("xcrun")
                    .args(["llvm-profdata", "merge", "-sparse"])
                    .args(raw)
                    .arg("-o")
                    .arg(&profile),
            )?;
        } else if let Some(codecov) = &unsigned_profile {
            driver.inherited(
                Phase::ExecuteTests,
                Command::new("swift")
                    .args([
                        "test",
                        "--skip-build",
                        "--disable-xctest",
                        "--no-parallel",
                        "--test-product",
                        product,
                        "--enable-code-coverage",
                        "--xunit-output",
                    ])
                    .arg(&report),
            )?;
            let source = codecov
                .parent()
                .ok_or(Error::PathOutput {
                    phase: Phase::CoveragePath,
                })?
                .join("default.profdata");
            artifact(Phase::MergeProfile, fs::copy(source, &profile))?;
        }
        reports.push(report);
        profiles.push(profile);
        objects.push(binary);
    }
    let mut verify = Command::new("python3");
    verify.args(["TestSupport/HostTests/reports.py", "results"]);
    if driver.signing == Signing::Unsigned {
        verify.arg("--allow-unsigned-keychain-skip");
    }
    driver.inherited(
        Phase::VerifyReports,
        verify
            .arg("TestSupport/HostTests/inventory.json")
            .arg(results.join("tests.xml"))
            .args(reports),
    )?;
    let combined = coverage.join("combined.profdata");
    driver.inherited(
        Phase::MergeProfile,
        Command::new("xcrun")
            .args(["llvm-profdata", "merge", "-sparse"])
            .args(profiles)
            .arg("-o")
            .arg(&combined),
    )?;
    let file = artifact(
        Phase::ExportCoverage,
        fs::File::create(coverage.join("raw.lcov")),
    )?;
    let mut export = Command::new("xcrun");
    export
        .args(["llvm-cov", "export", "-format=lcov", "-instr-profile"])
        .arg(&combined)
        .stdout(Stdio::from(file))
        .stderr(Stdio::inherit());
    for object in objects {
        export.arg("-object").arg(object);
    }
    driver.run(Phase::ExportCoverage, &mut export, OutputMode::Configured)?;
    driver.inherited(
        Phase::NormalizeCoverage,
        Command::new("python3")
            .args(["TestSupport/HostTests/reports.py", "coverage"])
            .arg(coverage.join("raw.lcov"))
            .arg(&driver.root)
            .arg(coverage.join("lcov.info")),
    )?;
    driver.signals.check(Phase::NormalizeCoverage)
}

#[cfg(test)]
#[path = "host_test_driver/tests.rs"]
mod tests;
