//! Run SwiftPM tests and verify each enabled test runner against its discovered selection.

use std::collections::{BTreeMap, BTreeSet};
use std::ffi::{OsStr, OsString};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

#[path = "swift_test_results/commands.rs"]
pub(crate) mod commands;
use crate::test_results::CommandFailure;
use commands::{SwiftCommand, finish_execution, run_command};

use regex::Regex;
use roxmltree::Document;
use serde::{Deserialize, Serialize};
use thiserror::Error;

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub enum TestRunner {
    Xctest,
    SwiftTesting,
}

impl TestRunner {
    fn label(self) -> &'static str {
        match self {
            Self::Xctest => "XCTest",
            Self::SwiftTesting => "Swift Testing",
        }
    }

    fn discovery_flag(self) -> &'static str {
        match self {
            Self::Xctest => "--disable-swift-testing",
            Self::SwiftTesting => "--disable-xctest",
        }
    }
}

pub type TestCounts = BTreeMap<String, usize>;
pub type AllowedSkips = BTreeSet<String>;

#[derive(Clone, Debug, Default)]
pub struct ExpectedTests {
    pub xctest: TestCounts,
    pub swift_testing: TestCounts,
}

impl ExpectedTests {
    fn for_runner_mut(&mut self, runner: TestRunner) -> &mut TestCounts {
        match runner {
            TestRunner::Xctest => &mut self.xctest,
            TestRunner::SwiftTesting => &mut self.swift_testing,
        }
    }

    fn total(&self) -> usize {
        self.xctest.values().sum::<usize>() + self.swift_testing.values().sum::<usize>()
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct VerificationSummary {
    pub passed: usize,
    pub skipped: usize,
    pub xctest_selected: usize,
    pub swift_testing_selected: usize,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct XCTestObservationRecord {
    pub identity: String,
    pub outcome: XCTestObservationOutcome,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum XCTestObservationOutcome {
    Passed,
    Skipped,
    Failed,
}

#[derive(Debug, Error)]
pub enum SwiftTestResultsError {
    #[error("SwiftPM command failed: {0}")]
    Command(#[source] Box<CommandFailure>),
    #[error("SwiftPM execution failed: {command}; result audit failure: {report_audit:?}")]
    ExecutionAndAudit {
        #[source]
        command: Box<CommandFailure>,
        report_audit: Option<Box<Self>>,
    },
    #[error("SwiftPM {runner:?} discovery encoding failed: {source}")]
    DiscoveryEncoding {
        runner: TestRunner,
        #[source]
        source: std::str::Utf8Error,
    },
    #[error("invalid SwiftPM test invocation: {0}")]
    InvalidInvocation(String),
    #[error("invalid SwiftPM test selection pattern: {0}")]
    InvalidPattern(String),
    #[error("SwiftPM {runner} discovery failed with status {status}")]
    DiscoveryFailed {
        runner: &'static str,
        status: String,
    },
    #[error("SwiftPM {runner} discovery returned an invalid or duplicate identity: {identity}")]
    InvalidDiscoveredIdentity {
        runner: &'static str,
        identity: String,
    },
    #[error("SwiftPM test selection is empty after applying its filter and skip patterns")]
    EmptySelection,
    #[error("SwiftPM test execution failed with {status}; xUnit audit: {report_audit:?}")]
    TestCommandFailed {
        status: String,
        report_audit: Option<String>,
    },
    #[error("could not manage SwiftPM result report {path}: {source}")]
    ReportPath {
        path: PathBuf,
        source: std::io::Error,
    },
    #[error("could not write SwiftPM selection artifact {path}: {source}")]
    SelectionArtifact {
        path: PathBuf,
        source: std::io::Error,
    },
    #[error("missing {runner} xUnit report: {path}")]
    MissingReport { runner: &'static str, path: PathBuf },
    #[error("could not read {runner} xUnit report {path}: {source}")]
    ReadReport {
        runner: &'static str,
        path: PathBuf,
        source: std::io::Error,
    },
    #[error("invalid {runner} xUnit report {path}: {message}")]
    InvalidReport {
        runner: &'static str,
        path: PathBuf,
        message: String,
    },
    #[error(
        "{runner} test identities do not match discovery; missing={missing:?}, extra_or_duplicate={extra:?}"
    )]
    IdentityMismatch {
        runner: &'static str,
        missing: Vec<String>,
        extra: Vec<String>,
    },
    #[error("{runner} test {identity} failed")]
    FailedTest {
        runner: &'static str,
        identity: String,
    },
    #[error("{runner} test {identity} was skipped without an allowed skip")]
    UnexpectedSkip {
        runner: &'static str,
        identity: String,
    },
    #[error("{runner} xUnit {scope} reports {counter}={value}")]
    AggregateFailure {
        runner: &'static str,
        scope: String,
        counter: &'static str,
        value: usize,
    },
    #[error("{runner} xUnit {scope} has invalid {counter} count {value:?}")]
    InvalidAggregateCount {
        runner: &'static str,
        scope: String,
        counter: &'static str,
        value: String,
    },
    #[error(
        "{runner} xUnit {scope} reports {counter}={reported}, but contains {actual} matching records"
    )]
    InconsistentAggregateCount {
        runner: &'static str,
        scope: String,
        counter: &'static str,
        reported: usize,
        actual: usize,
    },
    #[error("{runner} had no passing tests (all selected tests were skipped)")]
    NoPassingTests { runner: &'static str },
}

#[derive(Clone, Debug, Default)]
struct InvocationOptions {
    filter: Option<String>,
    skips: Vec<String>,
    xctest_enabled: bool,
    swift_testing_enabled: bool,
    package_path: Option<OsString>,
    num_workers: Option<usize>,
}

/// Executes `swift test` (arguments excluding the `swift test` prefix) and checks its reports.
pub fn run_and_verify(
    swift_test_arguments: &[OsString],
    report_path: &Path,
    allowed_skips: &AllowedSkips,
) -> Result<VerificationSummary, SwiftTestResultsError> {
    let options = parse_invocation(swift_test_arguments)?;
    let filter = options.filter.as_deref().map(compile_pattern).transpose()?;
    let skip_patterns = options
        .skips
        .iter()
        .map(|pattern| compile_pattern(pattern))
        .collect::<Result<Vec<_>, _>>()?;

    let mut expected = ExpectedTests::default();
    for runner in [TestRunner::Xctest, TestRunner::SwiftTesting] {
        let enabled = match runner {
            TestRunner::Xctest => options.xctest_enabled,
            TestRunner::SwiftTesting => options.swift_testing_enabled,
        };
        if !enabled {
            continue;
        }

        let discovered = discover(runner, options.package_path.as_deref())?;
        for identity in discovered {
            if filter
                .as_ref()
                .is_some_and(|pattern| !pattern.is_match(&identity))
                || skip_patterns
                    .iter()
                    .any(|pattern| pattern.is_match(&identity))
            {
                continue;
            }
            *expected.for_runner_mut(runner).entry(identity).or_default() += 1;
        }
    }
    if expected.total() == 0 {
        return Err(SwiftTestResultsError::EmptySelection);
    }

    let reports = report_paths(
        report_path,
        options.xctest_enabled,
        options.swift_testing_enabled,
    );
    let selection_path = selection_artifact_path(report_path);
    let observation_prefix = observation_artifact_prefix(report_path);
    if let Some(parent) = report_path.parent()
        && !parent.as_os_str().is_empty()
    {
        fs::create_dir_all(parent).map_err(|source| SwiftTestResultsError::ReportPath {
            path: parent.to_path_buf(),
            source,
        })?;
    }
    for report in reports.values() {
        remove_owned_report(report)?;
    }
    remove_observation_shards(&observation_prefix)?;
    remove_owned_report(&selection_path)?;
    let selection = serde_json::json!({
        "xctest": expected.xctest.keys().collect::<Vec<_>>(),
        "swift_testing": expected.swift_testing.keys().collect::<Vec<_>>(),
    });
    let selection_bytes = serde_json::to_vec_pretty(&selection).map_err(|error| {
        SwiftTestResultsError::InvalidInvocation(format!(
            "could not serialize SwiftPM selection artifact: {error}"
        ))
    })?;
    fs::write(&selection_path, selection_bytes).map_err(|source| {
        SwiftTestResultsError::SelectionArtifact {
            path: selection_path.clone(),
            source,
        }
    })?;

    let mut command = Command::new("swift");
    command.arg("test").args(swift_test_arguments);
    command.arg("--xunit-output").arg(report_path);
    if options.xctest_enabled {
        command.env("BLEAT_XCTEST_OBSERVATION_PATH", &observation_prefix);
    } else {
        command.env_remove("BLEAT_XCTEST_OBSERVATION_PATH");
    }
    let execution = run_command(&mut command, SwiftCommand::Execution);
    finish_execution(execution, || {
        verify_execution_results(
            &expected,
            &reports,
            &observation_prefix,
            options.xctest_enabled,
            options.swift_testing_enabled,
            allowed_skips,
        )
    })
}

fn parse_invocation(arguments: &[OsString]) -> Result<InvocationOptions, SwiftTestResultsError> {
    let mut options = InvocationOptions {
        xctest_enabled: true,
        swift_testing_enabled: true,
        ..InvocationOptions::default()
    };
    let mut index = 0;
    while index < arguments.len() {
        let value = arguments[index].to_str().ok_or_else(|| {
            SwiftTestResultsError::InvalidInvocation(
                "test arguments must be valid UTF-8".to_owned(),
            )
        })?;
        match value {
            "--disable-xctest" => options.xctest_enabled = false,
            "--enable-xctest" => options.xctest_enabled = true,
            "--disable-swift-testing" => options.swift_testing_enabled = false,
            "--enable-swift-testing" => options.swift_testing_enabled = true,
            "--filter" => {
                index += 1;
                let pattern = arguments
                    .get(index)
                    .and_then(|value| value.to_str())
                    .ok_or_else(|| {
                        SwiftTestResultsError::InvalidInvocation(
                            "--filter requires a UTF-8 regular expression".to_owned(),
                        )
                    })?;
                if options.filter.replace(pattern.to_owned()).is_some() {
                    return Err(SwiftTestResultsError::InvalidInvocation(
                        "only one --filter pattern is supported by this verifier".to_owned(),
                    ));
                }
            }
            "--skip" => {
                index += 1;
                let pattern = arguments
                    .get(index)
                    .and_then(|value| value.to_str())
                    .ok_or_else(|| {
                        SwiftTestResultsError::InvalidInvocation(
                            "--skip requires a UTF-8 regular expression".to_owned(),
                        )
                    })?;
                options.skips.push(pattern.to_owned());
            }
            "--package-path" => {
                index += 1;
                let path = arguments.get(index).ok_or_else(|| {
                    SwiftTestResultsError::InvalidInvocation(
                        "--package-path requires a path".to_owned(),
                    )
                })?;
                if options.package_path.replace(path.clone()).is_some() {
                    return Err(SwiftTestResultsError::InvalidInvocation(
                        "only one --package-path is supported".to_owned(),
                    ));
                }
            }
            "--xunit-output" => {
                return Err(SwiftTestResultsError::InvalidInvocation(
                    "the verifier owns --xunit-output; pass its path with --report".to_owned(),
                ));
            }
            "--no-parallel" | "--parallel" => {}
            "--num-workers" => {
                index += 1;
                let workers = arguments
                    .get(index)
                    .and_then(|value| value.to_str())
                    .and_then(|value| value.parse::<usize>().ok())
                    .filter(|workers| *workers > 0)
                    .ok_or_else(|| {
                        SwiftTestResultsError::InvalidInvocation(
                            "--num-workers requires a positive integer".to_owned(),
                        )
                    })?;
                if options.num_workers.replace(workers).is_some() {
                    return Err(SwiftTestResultsError::InvalidInvocation(
                        "only one --num-workers value is supported".to_owned(),
                    ));
                }
            }
            _ => {
                return Err(SwiftTestResultsError::InvalidInvocation(format!(
                    "unsupported SwiftPM argument {value:?}; add explicit discovery handling before using it"
                )));
            }
        }
        index += 1;
    }
    if !options.xctest_enabled && !options.swift_testing_enabled {
        return Err(SwiftTestResultsError::InvalidInvocation(
            "both XCTest and Swift Testing are disabled".to_owned(),
        ));
    }
    Ok(options)
}

fn compile_pattern(pattern: &str) -> Result<Regex, SwiftTestResultsError> {
    Regex::new(pattern)
        .map_err(|error| SwiftTestResultsError::InvalidPattern(format!("{pattern:?}: {error}")))
}

fn discover(
    runner: TestRunner,
    package_path: Option<&OsStr>,
) -> Result<BTreeSet<String>, SwiftTestResultsError> {
    let phase = SwiftCommand::Discovery(runner);
    let mut command = commands::discovery_command(runner, package_path);
    let output = run_command(&mut command, phase).map_err(SwiftTestResultsError::Command)?;
    let stdout = commands::decode_discovery_output(output.stdout, runner)?;
    let mut identities = BTreeSet::new();
    for line in stdout
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
    {
        if !valid_specifier(line) || !identities.insert(line.to_owned()) {
            return Err(SwiftTestResultsError::InvalidDiscoveredIdentity {
                runner: runner.label(),
                identity: line.to_owned(),
            });
        }
    }
    Ok(identities)
}

fn valid_specifier(identity: &str) -> bool {
    let Some((suite, test)) = identity.split_once('/') else {
        return false;
    };
    !suite.is_empty()
        && suite.contains('.')
        && !test.is_empty()
        && !identity.chars().any(char::is_whitespace)
}

fn report_paths(
    base: &Path,
    xctest_enabled: bool,
    swift_testing_enabled: bool,
) -> BTreeMap<TestRunner, PathBuf> {
    let mut reports = BTreeMap::new();
    if xctest_enabled {
        reports.insert(TestRunner::Xctest, base.to_path_buf());
    }
    if swift_testing_enabled {
        let path = if xctest_enabled {
            suffixed_xml_path(base, "-swift-testing")
        } else {
            base.to_path_buf()
        };
        reports.insert(TestRunner::SwiftTesting, path);
    }
    reports
}

fn suffixed_xml_path(path: &Path, suffix: &str) -> PathBuf {
    let mut file_name = path
        .file_name()
        .unwrap_or_else(|| OsStr::new("results.xml"))
        .to_os_string();
    if let Some(name) = file_name.to_str()
        && let Some(stem) = name.strip_suffix(".xml")
    {
        file_name = OsString::from(format!("{stem}{suffix}.xml"));
    } else {
        file_name.push(suffix);
    }
    path.with_file_name(file_name)
}

fn selection_artifact_path(path: &Path) -> PathBuf {
    let mut file_name = path
        .file_name()
        .unwrap_or_else(|| OsStr::new("results.xml"))
        .to_os_string();
    if let Some(name) = file_name.to_str()
        && let Some(stem) = name.strip_suffix(".xml")
    {
        file_name = OsString::from(format!("{stem}-selection.json"));
    } else {
        file_name.push("-selection.json");
    }
    path.with_file_name(file_name)
}

fn remove_owned_report(path: &Path) -> Result<(), SwiftTestResultsError> {
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(source) => Err(SwiftTestResultsError::ReportPath {
            path: path.to_path_buf(),
            source,
        }),
    }
}

fn observation_artifact_prefix(report_path: &Path) -> PathBuf {
    let mut file_name = report_path
        .file_name()
        .unwrap_or_else(|| OsStr::new("results.xml"))
        .to_os_string();
    file_name.push(".xctest-observation");
    report_path.with_file_name(file_name)
}

fn remove_observation_shards(prefix: &Path) -> Result<(), SwiftTestResultsError> {
    let directory = observation_directory(prefix);
    let Some(prefix_name) = prefix.file_name() else {
        return Ok(());
    };
    let prefix_name = prefix_name.to_string_lossy();
    let entries = fs::read_dir(directory).map_err(|source| SwiftTestResultsError::ReportPath {
        path: directory.to_path_buf(),
        source,
    })?;
    for entry in entries {
        let entry = entry.map_err(|source| SwiftTestResultsError::ReportPath {
            path: directory.to_path_buf(),
            source,
        })?;
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if is_observation_shard(&name, prefix_name.as_ref()) {
            fs::remove_file(entry.path()).map_err(|source| SwiftTestResultsError::ReportPath {
                path: entry.path(),
                source,
            })?;
        }
    }
    Ok(())
}

fn read_observation_shards(
    prefix: &Path,
    expected: &TestCounts,
) -> Result<Vec<XCTestObservationRecord>, SwiftTestResultsError> {
    let directory = observation_directory(prefix);
    let Some(prefix_name) = prefix.file_name() else {
        return Err(SwiftTestResultsError::MissingReport {
            runner: TestRunner::Xctest.label(),
            path: prefix.to_path_buf(),
        });
    };
    let prefix_name = prefix_name.to_string_lossy();
    let entries = fs::read_dir(directory).map_err(|source| SwiftTestResultsError::ReportPath {
        path: directory.to_path_buf(),
        source,
    })?;
    let mut paths = Vec::new();
    for entry in entries {
        let entry = entry.map_err(|source| SwiftTestResultsError::ReportPath {
            path: directory.to_path_buf(),
            source,
        })?;
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if is_observation_shard(&name, prefix_name.as_ref()) {
            paths.push(entry.path());
        }
    }
    paths.sort();
    if paths.is_empty() && !expected.is_empty() {
        return Err(SwiftTestResultsError::MissingReport {
            runner: TestRunner::Xctest.label(),
            path: prefix.to_path_buf(),
        });
    }
    let mut records = Vec::new();
    for path in paths {
        let json =
            fs::read_to_string(&path).map_err(|source| SwiftTestResultsError::ReadReport {
                runner: TestRunner::Xctest.label(),
                path: path.clone(),
                source,
            })?;
        let mut shard =
            serde_json::from_str::<Vec<XCTestObservationRecord>>(&json).map_err(|error| {
                SwiftTestResultsError::InvalidReport {
                    runner: TestRunner::Xctest.label(),
                    path: path.clone(),
                    message: error.to_string(),
                }
            })?;
        records.append(&mut shard);
    }
    Ok(records)
}

fn observation_directory(prefix: &Path) -> &Path {
    prefix
        .parent()
        .filter(|directory| !directory.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."))
}

fn is_observation_shard(name: &str, prefix: &str) -> bool {
    name.strip_prefix(prefix)
        .and_then(|suffix| suffix.strip_prefix('.'))
        .and_then(|suffix| suffix.strip_suffix(".json"))
        .is_some_and(|process_id| {
            !process_id.is_empty()
                && process_id.bytes().all(|byte| byte.is_ascii_digit())
                && process_id.parse::<u32>().is_ok_and(|id| id > 0)
        })
}

pub fn verify_observation_records(
    records: &[XCTestObservationRecord],
    expected: &TestCounts,
    allowed_skips: &AllowedSkips,
) -> Result<(usize, usize), SwiftTestResultsError> {
    let mut actual = TestCounts::new();
    let mut passed = 0;
    let mut skipped = 0;
    for record in records {
        if !valid_specifier(&record.identity) {
            return Err(SwiftTestResultsError::InvalidDiscoveredIdentity {
                runner: TestRunner::Xctest.label(),
                identity: record.identity.clone(),
            });
        }
        *actual.entry(record.identity.clone()).or_default() += 1;
        match record.outcome {
            XCTestObservationOutcome::Passed => passed += 1,
            XCTestObservationOutcome::Skipped if allowed_skips.contains(&record.identity) => {
                skipped += 1;
            }
            XCTestObservationOutcome::Skipped => {
                return Err(SwiftTestResultsError::UnexpectedSkip {
                    runner: TestRunner::Xctest.label(),
                    identity: record.identity.clone(),
                });
            }
            XCTestObservationOutcome::Failed => {
                return Err(SwiftTestResultsError::FailedTest {
                    runner: TestRunner::Xctest.label(),
                    identity: record.identity.clone(),
                });
            }
        }
    }
    if actual != *expected {
        return Err(SwiftTestResultsError::IdentityMismatch {
            runner: TestRunner::Xctest.label(),
            missing: counter_difference(expected, &actual),
            extra: counter_difference(&actual, expected),
        });
    }
    if !expected.is_empty() && passed == 0 {
        return Err(SwiftTestResultsError::NoPassingTests {
            runner: TestRunner::Xctest.label(),
        });
    }
    Ok((passed, skipped))
}

pub fn verify_execution_results(
    expected: &ExpectedTests,
    reports: &BTreeMap<TestRunner, PathBuf>,
    observation_prefix: &Path,
    xctest_enabled: bool,
    swift_testing_enabled: bool,
    allowed_skips: &AllowedSkips,
) -> Result<VerificationSummary, SwiftTestResultsError> {
    if expected.total() == 0 {
        return Err(SwiftTestResultsError::EmptySelection);
    }
    let mut summary = VerificationSummary {
        xctest_selected: expected.xctest.values().sum(),
        swift_testing_selected: expected.swift_testing.values().sum(),
        ..VerificationSummary::default()
    };
    if xctest_enabled {
        let records = read_observation_shards(observation_prefix, &expected.xctest)?;
        let (passed, skipped) =
            verify_observation_records(&records, &expected.xctest, allowed_skips)?;
        summary.passed += passed;
        summary.skipped += skipped;
    }
    if swift_testing_enabled {
        let runner = TestRunner::SwiftTesting;
        if !expected.swift_testing.is_empty() {
            let path =
                reports
                    .get(&runner)
                    .ok_or_else(|| SwiftTestResultsError::MissingReport {
                        runner: runner.label(),
                        path: PathBuf::from("<not configured>"),
                    })?;
            let xml = fs::read_to_string(path).map_err(|source| {
                if source.kind() == std::io::ErrorKind::NotFound {
                    SwiftTestResultsError::MissingReport {
                        runner: runner.label(),
                        path: path.clone(),
                    }
                } else {
                    SwiftTestResultsError::ReadReport {
                        runner: runner.label(),
                        path: path.clone(),
                        source,
                    }
                }
            })?;
            let (passed, skipped) =
                verify_runner_xml(runner, &xml, &expected.swift_testing, allowed_skips, path)?;
            if passed == 0 {
                return Err(SwiftTestResultsError::NoPassingTests {
                    runner: runner.label(),
                });
            }
            summary.passed += passed;
            summary.skipped += skipped;
        } else if let Some(path) = reports.get(&runner)
            && path.exists()
        {
            let xml =
                fs::read_to_string(path).map_err(|source| SwiftTestResultsError::ReadReport {
                    runner: runner.label(),
                    path: path.clone(),
                    source,
                })?;
            verify_runner_xml(runner, &xml, &expected.swift_testing, allowed_skips, path)?;
        }
    }
    if summary.passed == 0 {
        return Err(SwiftTestResultsError::NoPassingTests { runner: "SwiftPM" });
    }
    Ok(summary)
}

fn verify_runner_xml(
    runner: TestRunner,
    xml: &str,
    expected: &TestCounts,
    allowed_skips: &AllowedSkips,
    path: &Path,
) -> Result<(usize, usize), SwiftTestResultsError> {
    let document = Document::parse(xml).map_err(|error| SwiftTestResultsError::InvalidReport {
        runner: runner.label(),
        path: path.to_path_buf(),
        message: error.to_string(),
    })?;
    for node in document.descendants().filter(|node| {
        node.is_element() && (node.has_tag_name("testsuites") || node.has_tag_name("testsuite"))
    }) {
        verify_aggregate_counts(runner, node, path)?;
    }
    let mut actual = TestCounts::new();
    let mut passed = 0;
    let mut skipped = 0;
    for case in document
        .descendants()
        .filter(|node| node.has_tag_name("testcase"))
    {
        let class =
            case.attribute("classname")
                .ok_or_else(|| SwiftTestResultsError::InvalidReport {
                    runner: runner.label(),
                    path: path.to_path_buf(),
                    message: "testcase is missing classname".to_owned(),
                })?;
        let name = case
            .attribute("name")
            .ok_or_else(|| SwiftTestResultsError::InvalidReport {
                runner: runner.label(),
                path: path.to_path_buf(),
                message: "testcase is missing name".to_owned(),
            })?;
        let identity = format!("{class}/{name}");
        *actual.entry(identity.clone()).or_default() += 1;

        let failures = case
            .descendants()
            .filter(|node| node.has_tag_name("failure") || node.has_tag_name("error"))
            .count();
        let skip_nodes = case
            .descendants()
            .filter(|node| node.has_tag_name("skipped"))
            .count();
        if failures > 0 || skip_nodes > 1 {
            return Err(SwiftTestResultsError::FailedTest {
                runner: runner.label(),
                identity,
            });
        }
        if skip_nodes == 1 {
            if !allowed_skips.contains(&identity) {
                return Err(SwiftTestResultsError::UnexpectedSkip {
                    runner: runner.label(),
                    identity,
                });
            }
            skipped += 1;
        } else {
            passed += 1;
        }
    }
    if actual != *expected {
        return Err(SwiftTestResultsError::IdentityMismatch {
            runner: runner.label(),
            missing: counter_difference(expected, &actual),
            extra: counter_difference(&actual, expected),
        });
    }
    Ok((passed, skipped))
}

fn verify_aggregate_counts(
    runner: TestRunner,
    node: roxmltree::Node<'_, '_>,
    path: &Path,
) -> Result<(), SwiftTestResultsError> {
    let scope = if node.has_tag_name("testsuites") {
        "root".to_owned()
    } else {
        format!("suite {:?}", node.attribute("name").unwrap_or("<unnamed>"))
    };
    for counter in ["failures", "errors"] {
        if let Some(value) = node.attribute(counter) {
            let value = parse_aggregate_count(runner, &scope, counter, value, path)?;
            if value > 0 {
                return Err(SwiftTestResultsError::AggregateFailure {
                    runner: runner.label(),
                    scope,
                    counter,
                    value,
                });
            }
        }
    }
    for counter in ["tests", "skipped"] {
        let Some(value) = node.attribute(counter) else {
            continue;
        };
        let reported = parse_aggregate_count(runner, &scope, counter, value, path)?;
        let tag = if counter == "tests" {
            "testcase"
        } else {
            "skipped"
        };
        let actual = if counter == "tests" {
            node.descendants()
                .filter(|child| child.has_tag_name(tag))
                .count()
        } else {
            node.descendants()
                .filter(|child| child.has_tag_name("testcase"))
                .filter(|case| case.descendants().any(|child| child.has_tag_name(tag)))
                .count()
        };
        if reported != actual {
            return Err(SwiftTestResultsError::InconsistentAggregateCount {
                runner: runner.label(),
                scope,
                counter,
                reported,
                actual,
            });
        }
    }
    let _ = path;
    Ok(())
}

fn parse_aggregate_count(
    runner: TestRunner,
    scope: &str,
    counter: &'static str,
    value: &str,
    path: &Path,
) -> Result<usize, SwiftTestResultsError> {
    value
        .parse::<usize>()
        .map_err(|_| SwiftTestResultsError::InvalidAggregateCount {
            runner: runner.label(),
            scope: format!("{scope} ({})", path.display()),
            counter,
            value: value.to_owned(),
        })
}

fn counter_difference(left: &TestCounts, right: &TestCounts) -> Vec<String> {
    left.iter()
        .flat_map(|(identity, count)| {
            let difference = count.saturating_sub(right.get(identity).copied().unwrap_or_default());
            std::iter::repeat_n(identity.clone(), difference)
        })
        .collect()
}

/// Entry point used by the thin `swift-test-results` binary.
pub fn run_cli() -> Result<VerificationSummary, SwiftTestResultsError> {
    use clap::Parser;

    #[derive(Parser)]
    struct Cli {
        #[arg(long)]
        report: PathBuf,
        #[arg(long = "allow-skip", value_name = "QUALIFIED_TEST_ID")]
        allow_skips: Vec<String>,
    }

    let arguments = std::env::args_os().collect::<Vec<_>>();
    let separator = arguments
        .iter()
        .position(|argument| argument == OsStr::new("--"))
        .ok_or_else(|| {
            SwiftTestResultsError::InvalidInvocation(
                "expected --report PATH -- swift test [OPTIONS]".to_owned(),
            )
        })?;
    let cli = Cli::try_parse_from(&arguments[..separator])
        .map_err(|error| SwiftTestResultsError::InvalidInvocation(error.to_string()))?;
    let command = &arguments[separator + 1..];
    if command.len() < 2
        || Path::new(&command[0]).file_name() != Some(OsStr::new("swift"))
        || command[1] != OsStr::new("test")
    {
        return Err(SwiftTestResultsError::InvalidInvocation(
            "expected command `swift test [OPTIONS]` after --".to_owned(),
        ));
    }
    let mut allowed_skips = AllowedSkips::new();
    for identity in &cli.allow_skips {
        if !valid_specifier(identity) || !allowed_skips.insert(identity.clone()) {
            return Err(SwiftTestResultsError::InvalidInvocation(format!(
                "invalid or duplicate --allow-skip test identity {identity:?}"
            )));
        }
    }
    let summary = run_and_verify(&command[2..], &cli.report, &allowed_skips)?;
    println!(
        "Verified SwiftPM selection: {} passed, {} skipped (XCTest {}, Swift Testing {})",
        summary.passed, summary.skipped, summary.xctest_selected, summary.swift_testing_selected
    );
    println!(
        "SwiftPM selection identities: {}",
        selection_artifact_path(&cli.report).display()
    );
    Ok(summary)
}
