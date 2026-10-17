//! Exact verification for Xcode's structured test result and test discovery JSON.

use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet};
use std::error::Error;
use std::fmt;
use std::fs;
use std::path::Path;
use std::path::PathBuf;
use std::process::Command;

#[derive(Clone, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub struct TestId {
    pub target: String,
    pub suite: String,
    pub function: String,
}

impl TestId {
    pub fn parse(value: &str) -> Result<Self> {
        let parts: Vec<_> = value.split('/').collect();
        if parts.len() != 3 || parts.iter().any(|part| part.is_empty()) {
            return Err(VerifyError::InvalidIdentity(value.to_owned()));
        }
        Ok(Self {
            target: parts[0].to_owned(),
            suite: parts[1].to_owned(),
            function: normalize_function(parts[2]),
        })
    }

    pub fn as_string(&self) -> String {
        format!("{}/{}/{}", self.target, self.suite, self.function)
    }

    fn matches_selector(&self, selector: &str) -> bool {
        let selector = selector.trim_end_matches("()");
        let id = self.as_string();
        id == selector || id.starts_with(&format!("{selector}/"))
    }
}

fn normalize_function(value: &str) -> String {
    value.strip_suffix("()").unwrap_or(value).to_owned()
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ExpectedTest {
    pub id: TestId,
    pub repetitions: usize,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct VerificationReport {
    pub passed: usize,
    pub skipped: usize,
    pub passed_cases: usize,
    pub skipped_cases: usize,
}

#[derive(Debug)]
pub enum VerifyError {
    InvalidIdentity(String),
    InvalidJson(String),
    InvalidDiscovery(&'static str),
    DiscoveryErrors(Vec<String>),
    DuplicateDiscoveredTest(String),
    UnmatchedSelector(String),
    EmptyDiscovery,
    DuplicateExpectation(String),
    DuplicateResult(String),
    InvalidAllowedSkip(String),
    DuplicateAllowedSkip(String),
    InvalidRepetitions,
    InvalidResult(&'static str),
    UnknownNodeType(String),
    UnknownOutcome(String),
    FailedOutcome(String),
    UnexpectedSkip(String),
    AllSkipped,
    MissingTest(String),
    ExtraTest(String),
    WrongRepetitionCount {
        id: String,
        expected: usize,
        actual: usize,
    },
    ProcessStart(std::io::Error),
    ProcessFailed(String),
    FileRead(std::io::Error),
}

impl fmt::Display for VerifyError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidIdentity(value) => write!(f, "invalid_test_identity: {value}"),
            Self::InvalidJson(error) => write!(f, "invalid_json: {error}"),
            Self::InvalidDiscovery(message) => write!(f, "invalid_test_discovery: {message}"),
            Self::DiscoveryErrors(errors) => {
                write!(f, "test_discovery_errors: {}", errors.join("; "))
            }
            Self::DuplicateDiscoveredTest(id) => write!(f, "duplicate_discovered_test: {id}"),
            Self::UnmatchedSelector(selector) => write!(f, "unmatched_test_selector: {selector}"),
            Self::EmptyDiscovery => f.write_str("empty_test_discovery"),
            Self::DuplicateExpectation(id) => write!(f, "duplicate_expected_test: {id}"),
            Self::DuplicateResult(id) => write!(f, "duplicate_test_result_node: {id}"),
            Self::InvalidAllowedSkip(id) => write!(f, "allowed_skip_not_expected: {id}"),
            Self::DuplicateAllowedSkip(id) => write!(f, "duplicate_allowed_skip: {id}"),
            Self::InvalidRepetitions => {
                f.write_str("invalid_repetitions: expected a positive count")
            }
            Self::InvalidResult(message) => write!(f, "invalid_test_results: {message}"),
            Self::UnknownNodeType(value) => write!(f, "unknown_test_result_node_type: {value}"),
            Self::UnknownOutcome(value) => write!(f, "unknown_test_result_outcome: {value}"),
            Self::FailedOutcome(id) => write!(f, "failed_test_outcome: {id}"),
            Self::UnexpectedSkip(id) => write!(f, "unexpected_test_skip: {id}"),
            Self::AllSkipped => f.write_str("all_tests_skipped"),
            Self::MissingTest(id) => write!(f, "missing_expected_test: {id}"),
            Self::ExtraTest(id) => write!(f, "unexpected_test_result: {id}"),
            Self::WrongRepetitionCount {
                id,
                expected,
                actual,
            } => write!(
                f,
                "wrong_repetition_count: {id} expected {expected}, got {actual}"
            ),
            Self::ProcessStart(error) => write!(f, "xcresulttool_start_failed: {error}"),
            Self::ProcessFailed(error) => write!(f, "xcresulttool_failed: {error}"),
            Self::FileRead(error) => write!(f, "results_file_read_failed: {error}"),
        }
    }
}

impl Error for VerifyError {}

pub type Result<T> = std::result::Result<T, VerifyError>;

#[derive(Clone, Debug)]
pub enum ResultsInput {
    Bundle(PathBuf),
    Json(PathBuf),
}

#[derive(Clone, Debug)]
pub enum ExpectedInput {
    Fixed(Vec<String>),
    Discovery(PathBuf),
}

#[derive(Clone, Debug)]
pub struct RunOptions {
    pub results: ResultsInput,
    pub expected: ExpectedInput,
    pub only: Vec<String>,
    pub exclude: Vec<String>,
    pub allow_skip: Vec<TestId>,
    pub repetitions: usize,
}

pub fn verify_files(options: RunOptions) -> Result<VerificationReport> {
    let (results, summary_counts) = match options.results {
        ResultsInput::Bundle(path) => {
            let (json, counts) = read_bundle_tests(&path)?;
            (json, Some(counts))
        }
        ResultsInput::Json(path) => (
            fs::read_to_string(path).map_err(VerifyError::FileRead)?,
            None,
        ),
    };
    let expected = match options.expected {
        ExpectedInput::Fixed(ids) if options.only.is_empty() && options.exclude.is_empty() => {
            expected_from_ids(&ids, options.repetitions)?
        }
        ExpectedInput::Fixed(_) => {
            return Err(VerifyError::InvalidResult(
                "--only and --exclude require --discovery",
            ));
        }
        ExpectedInput::Discovery(path) => {
            let json = fs::read_to_string(path).map_err(VerifyError::FileRead)?;
            discover_expected(&json, &options.only, &options.exclude, options.repetitions)?
        }
    };
    let report = verify_result_json(&results, &expected, &options.allow_skip)?;
    if let Some(counts) = summary_counts
        && (counts.passed != report.passed_cases || counts.skipped != report.skipped_cases)
    {
        return Err(VerifyError::InvalidResult(
            "summary counts do not match verified outcomes",
        ));
    }
    Ok(report)
}

pub fn discover_expected(
    json: &str,
    only: &[String],
    exclude: &[String],
    repetitions: usize,
) -> Result<Vec<ExpectedTest>> {
    if repetitions == 0 {
        return Err(VerifyError::InvalidRepetitions);
    }
    let value: Value =
        serde_json::from_str(json).map_err(|error| VerifyError::InvalidJson(error.to_string()))?;
    let root = value
        .as_object()
        .ok_or(VerifyError::InvalidDiscovery("root must be an object"))?;
    if let Some(errors) = root.get("errors") {
        let errors = errors
            .as_array()
            .ok_or(VerifyError::InvalidDiscovery("errors must be an array"))?;
        let messages: Vec<String> = errors
            .iter()
            .map(|error| {
                error
                    .as_str()
                    .map(str::to_owned)
                    .unwrap_or_else(|| error.to_string())
            })
            .collect();
        if !messages.is_empty() {
            return Err(VerifyError::DiscoveryErrors(messages));
        }
    }
    let values = root
        .get("values")
        .and_then(Value::as_array)
        .ok_or(VerifyError::InvalidDiscovery("values must be an array"))?;
    let mut discovered = BTreeSet::new();
    for configuration in values {
        let enabled = configuration
            .get("enabledTests")
            .and_then(Value::as_array)
            .ok_or(VerifyError::InvalidDiscovery(
                "enabledTests must be an array",
            ))?;
        for test in enabled {
            let identifier = test.get("identifier").and_then(Value::as_str).ok_or(
                VerifyError::InvalidDiscovery("enabled test identifier must be a string"),
            )?;
            let id = TestId::parse(identifier)?;
            let string = id.as_string();
            if !discovered.insert(id.clone()) {
                return Err(VerifyError::DuplicateDiscoveredTest(string));
            }
        }
    }
    for selector in only.iter().chain(exclude) {
        if !discovered.iter().any(|id| id.matches_selector(selector)) {
            return Err(VerifyError::UnmatchedSelector(selector.clone()));
        }
    }
    let selected: Vec<_> = discovered
        .into_iter()
        .filter(|id| {
            (only.is_empty() || only.iter().any(|selector| id.matches_selector(selector)))
                && !exclude.iter().any(|selector| id.matches_selector(selector))
        })
        .map(|id| ExpectedTest { id, repetitions })
        .collect();
    if selected.is_empty() {
        return Err(VerifyError::EmptyDiscovery);
    }
    Ok(selected)
}

pub fn expected_from_ids(ids: &[String], repetitions: usize) -> Result<Vec<ExpectedTest>> {
    if repetitions == 0 {
        return Err(VerifyError::InvalidRepetitions);
    }
    let mut seen = BTreeSet::new();
    let mut expected = Vec::with_capacity(ids.len());
    for value in ids {
        let id = TestId::parse(value)?;
        let string = id.as_string();
        if !seen.insert(id.clone()) {
            return Err(VerifyError::DuplicateExpectation(string));
        }
        expected.push(ExpectedTest { id, repetitions });
    }
    if expected.is_empty() {
        return Err(VerifyError::EmptyDiscovery);
    }
    Ok(expected)
}

pub fn verify_result_json(
    json: &str,
    expected: &[ExpectedTest],
    allow_skip: &[TestId],
) -> Result<VerificationReport> {
    if expected.is_empty() {
        return Err(VerifyError::EmptyDiscovery);
    }
    let value: Value =
        serde_json::from_str(json).map_err(|error| VerifyError::InvalidJson(error.to_string()))?;
    let nodes = value
        .get("testNodes")
        .and_then(Value::as_array)
        .ok_or(VerifyError::InvalidResult("testNodes must be an array"))?;
    let expected_map: BTreeMap<_, _> = expected
        .iter()
        .map(|test| (test.id.clone(), test.repetitions))
        .collect();
    if expected_map.len() != expected.len() {
        return Err(VerifyError::DuplicateExpectation(
            "expected list contains repeated identity".to_owned(),
        ));
    }
    let allowed: BTreeSet<_> = allow_skip.iter().cloned().collect();
    if allowed.len() != allow_skip.len() {
        return Err(VerifyError::DuplicateAllowedSkip(
            "allow-skip list contains duplicate identity".to_owned(),
        ));
    }
    for id in &allowed {
        if !expected_map.contains_key(id) {
            return Err(VerifyError::InvalidAllowedSkip(id.as_string()));
        }
    }
    let mut outcomes: BTreeMap<TestId, TestCaseResult> = BTreeMap::new();
    for node in nodes {
        collect_node(node, &mut outcomes)?;
    }
    for id in expected_map.keys() {
        if !outcomes.contains_key(id) {
            return Err(VerifyError::MissingTest(id.as_string()));
        }
    }
    for id in outcomes.keys() {
        if !expected_map.contains_key(id) {
            return Err(VerifyError::ExtraTest(id.as_string()));
        }
    }
    let mut passed = 0;
    let mut skipped = 0;
    let mut passed_cases = 0;
    let mut skipped_cases = 0;
    for (id, expected_count) in expected_map {
        let actual = outcomes
            .get(&id)
            .ok_or_else(|| VerifyError::MissingTest(id.as_string()))?;
        if actual.outcomes.len() != expected_count {
            return Err(VerifyError::WrongRepetitionCount {
                id: id.as_string(),
                expected: expected_count,
                actual: actual.outcomes.len(),
            });
        }
        match actual.aggregate {
            Outcome::Passed => passed_cases += 1,
            Outcome::Skipped if allowed.contains(&id) => skipped_cases += 1,
            Outcome::Skipped => return Err(VerifyError::UnexpectedSkip(id.as_string())),
            Outcome::Failed => return Err(VerifyError::FailedOutcome(id.as_string())),
        }
        for outcome in &actual.outcomes {
            match outcome {
                Outcome::Passed => passed += 1,
                Outcome::Skipped if allowed.contains(&id) => skipped += 1,
                Outcome::Skipped => return Err(VerifyError::UnexpectedSkip(id.as_string())),
                Outcome::Failed => return Err(VerifyError::FailedOutcome(id.as_string())),
            }
        }
    }
    if passed == 0 || passed_cases == 0 {
        return Err(VerifyError::AllSkipped);
    }
    Ok(VerificationReport {
        passed,
        skipped,
        passed_cases,
        skipped_cases,
    })
}

pub fn verify_result_bundle(
    path: &Path,
    expected: &[ExpectedTest],
    allow_skip: &[TestId],
) -> Result<VerificationReport> {
    let (json, counts) = read_bundle_tests(path)?;
    verify_result_json_with_summary_counts(&json, counts, expected, allow_skip)
}

pub fn verify_result_json_with_summary(
    results_json: &str,
    summary_json: &str,
    expected: &[ExpectedTest],
    allow_skip: &[TestId],
) -> Result<VerificationReport> {
    let summary: Value = serde_json::from_str(summary_json)
        .map_err(|error| VerifyError::InvalidJson(error.to_string()))?;
    let counts = validate_summary(&summary)?;
    verify_result_json_with_summary_counts(results_json, counts, expected, allow_skip)
}

fn verify_result_json_with_summary_counts(
    results_json: &str,
    counts: SummaryCounts,
    expected: &[ExpectedTest],
    allow_skip: &[TestId],
) -> Result<VerificationReport> {
    let report = verify_result_json(results_json, expected, allow_skip)?;
    if counts.passed != report.passed_cases || counts.skipped != report.skipped_cases {
        return Err(VerifyError::InvalidResult(
            "summary counts do not match verified outcomes",
        ));
    }
    Ok(report)
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Outcome {
    Passed,
    Failed,
    Skipped,
}

#[derive(Clone, Debug)]
struct TestCaseResult {
    aggregate: Outcome,
    outcomes: Vec<Outcome>,
}

fn collect_node(node: &Value, outcomes: &mut BTreeMap<TestId, TestCaseResult>) -> Result<()> {
    let node_type = node
        .get("nodeType")
        .and_then(Value::as_str)
        .ok_or(VerifyError::InvalidResult("nodeType must be a string"))?;
    let children = node
        .get("children")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    match node_type {
        "Test Case" => {
            let id = id_from_case(node)?;
            if outcomes.contains_key(&id) {
                return Err(VerifyError::DuplicateResult(id.as_string()));
            }
            let repetitions: Vec<_> = children
                .iter()
                .filter(|child| child.get("nodeType").and_then(Value::as_str) == Some("Repetition"))
                .collect();
            let aggregate = outcome(node)?;
            if aggregate == Outcome::Failed {
                return Err(VerifyError::FailedOutcome(id.as_string()));
            }
            let found = if repetitions.is_empty() {
                vec![aggregate]
            } else {
                let mut ordinals = BTreeSet::new();
                for repetition in &repetitions {
                    let ordinal = repetition
                        .get("nodeIdentifier")
                        .and_then(Value::as_str)
                        .and_then(|value| value.parse::<usize>().ok())
                        .ok_or(VerifyError::InvalidResult("invalid repetition identifier"))?;
                    if ordinal == 0 || ordinal > repetitions.len() || !ordinals.insert(ordinal) {
                        return Err(VerifyError::InvalidResult(
                            "repetition identifiers must be distinct consecutive ordinals",
                        ));
                    }
                }
                for child in &children {
                    if !matches!(
                        child.get("nodeType").and_then(Value::as_str),
                        Some("Repetition" | "Failure Message" | "Skip Message")
                    ) {
                        return Err(VerifyError::UnknownNodeType(
                            child
                                .get("nodeType")
                                .and_then(Value::as_str)
                                .unwrap_or("<missing>")
                                .to_owned(),
                        ));
                    }
                }
                for child in &children {
                    if let Some(url) = child.get("nodeIdentifierURL").and_then(Value::as_str)
                        && id_from_url(url)? != id
                    {
                        return Err(VerifyError::InvalidResult(
                            "repetition identity does not match its test case",
                        ));
                    }
                }
                repetitions
                    .into_iter()
                    .map(outcome)
                    .collect::<Result<Vec<_>>>()?
            };
            for child in &children {
                match child.get("nodeType").and_then(Value::as_str) {
                    Some("Failure Message" | "Skip Message") => validate_message_node(child)?,
                    Some("Repetition") => {
                        if let Some(nested) = child.get("children").and_then(Value::as_array) {
                            for nested_child in nested {
                                match nested_child.get("nodeType").and_then(Value::as_str) {
                                    Some("Failure Message" | "Skip Message") => {
                                        validate_message_node(nested_child)?
                                    }
                                    Some(other) => {
                                        return Err(VerifyError::UnknownNodeType(other.to_owned()));
                                    }
                                    None => {
                                        return Err(VerifyError::InvalidResult(
                                            "repetition child nodeType is missing",
                                        ));
                                    }
                                }
                            }
                        }
                    }
                    Some(other) => return Err(VerifyError::UnknownNodeType(other.to_owned())),
                    None => {
                        return Err(VerifyError::InvalidResult(
                            "test case child nodeType is missing",
                        ));
                    }
                }
            }
            outcomes.insert(
                id,
                TestCaseResult {
                    aggregate,
                    outcomes: found,
                },
            );
        }
        "Failure Message" | "Skip Message" => validate_message_node(node)?,
        "Test Plan" | "Unit test bundle" | "UI test bundle" | "Test Suite" | "Repetition" => {
            if let Some(result) = node.get("result") {
                let state = result
                    .as_str()
                    .ok_or(VerifyError::InvalidResult("result must be a string"))?;
                if !matches!(state, "Passed" | "Failed" | "Skipped") {
                    return Err(VerifyError::UnknownOutcome(state.to_owned()));
                }
                if state == "Failed" {
                    let name = node
                        .get("nodeIdentifier")
                        .and_then(Value::as_str)
                        .or_else(|| node.get("name").and_then(Value::as_str))
                        .unwrap_or(node_type);
                    return Err(VerifyError::FailedOutcome(name.to_owned()));
                }
            }
            for child in children {
                collect_node(&child, outcomes)?;
            }
        }
        other => return Err(VerifyError::UnknownNodeType(other.to_owned())),
    }
    Ok(())
}

fn id_from_case(node: &Value) -> Result<TestId> {
    let url = node
        .get("nodeIdentifierURL")
        .and_then(Value::as_str)
        .ok_or(VerifyError::InvalidResult(
            "test case nodeIdentifierURL is required",
        ))?;
    id_from_url(url)
}

fn id_from_url(url: &str) -> Result<TestId> {
    let (_, path) = url
        .split_once("://")
        .ok_or(VerifyError::InvalidResult("test case URL is malformed"))?;
    let path = path
        .split_once('/')
        .map(|(_, path)| path)
        .ok_or(VerifyError::InvalidResult(
            "test case URL has no identity path",
        ))?;
    let parts: Vec<_> = path.split('/').filter(|part| !part.is_empty()).collect();
    if parts.len() < 3 {
        return Err(VerifyError::InvalidIdentity(url.to_owned()));
    }
    TestId::parse(&parts[parts.len() - 3..].join("/"))
}

fn outcome(node: &Value) -> Result<Outcome> {
    let result = node
        .get("result")
        .and_then(Value::as_str)
        .ok_or(VerifyError::InvalidResult("test outcome is missing"))?;
    match result {
        "Passed" => Ok(Outcome::Passed),
        "Failed" => Ok(Outcome::Failed),
        "Skipped" => Ok(Outcome::Skipped),
        other => Err(VerifyError::UnknownOutcome(other.to_owned())),
    }
}

fn validate_message_node(node: &Value) -> Result<()> {
    let message = node
        .get("name")
        .and_then(Value::as_str)
        .ok_or(VerifyError::InvalidResult("message node name is missing"))?;
    if node.get("nodeType").and_then(Value::as_str) == Some("Failure Message") {
        return Err(VerifyError::FailedOutcome(message.to_owned()));
    }
    Ok(())
}

struct SummaryCounts {
    passed: usize,
    skipped: usize,
}

fn read_bundle_tests(path: &Path) -> Result<(String, SummaryCounts)> {
    let output = Command::new("xcrun")
        .args(["xcresulttool", "get", "test-results", "tests", "--path"])
        .arg(path)
        .output()
        .map_err(VerifyError::ProcessStart)?;
    if !output.status.success() {
        return Err(VerifyError::ProcessFailed(
            String::from_utf8_lossy(&output.stderr).trim().to_owned(),
        ));
    }
    let json = String::from_utf8(output.stdout)
        .map_err(|error| VerifyError::InvalidJson(error.to_string()))?;
    let summary = Command::new("xcrun")
        .args(["xcresulttool", "get", "test-results", "summary", "--path"])
        .arg(path)
        .output()
        .map_err(VerifyError::ProcessStart)?;
    if !summary.status.success() {
        return Err(VerifyError::ProcessFailed(
            String::from_utf8_lossy(&summary.stderr).trim().to_owned(),
        ));
    }
    let summary: Value = serde_json::from_slice(&summary.stdout)
        .map_err(|error| VerifyError::InvalidJson(error.to_string()))?;
    let counts = validate_summary_with_legacy_fallback(&summary, || read_legacy_summary(path))?;
    Ok((json, counts))
}

fn read_legacy_summary(path: &Path) -> Result<Value> {
    let output = Command::new("xcrun")
        .args(["xcresulttool", "get", "object", "--legacy", "--path"])
        .arg(path)
        .args(["--format", "json"])
        .output()
        .map_err(VerifyError::ProcessStart)?;
    if !output.status.success() {
        return Err(VerifyError::ProcessFailed(
            String::from_utf8_lossy(&output.stderr).trim().to_owned(),
        ));
    }
    serde_json::from_slice(&output.stdout)
        .map_err(|error| VerifyError::InvalidJson(error.to_string()))
}

fn validate_summary_with_legacy_fallback<F>(
    summary: &Value,
    load_legacy: F,
) -> Result<SummaryCounts>
where
    F: FnOnce() -> Result<Value>,
{
    if !summary.is_object() {
        return Err(VerifyError::InvalidResult("summary must be an object"));
    }
    if summary.get("runtimeWarnings").is_some() {
        return validate_summary(summary);
    }

    let legacy = load_legacy()?;
    validate_legacy_issue_summaries(&legacy)?;
    let mut compatible_summary = summary.clone();
    compatible_summary["runtimeWarnings"] = serde_json::json!([]);
    validate_summary(&compatible_summary)
}

fn validate_legacy_issue_summaries(record: &Value) -> Result<()> {
    if record
        .get("_type")
        .and_then(|value| value.get("_name"))
        .and_then(Value::as_str)
        != Some("ActionsInvocationRecord")
    {
        return Err(VerifyError::InvalidResult(
            "legacy invocation record type missing or invalid",
        ));
    }
    let actions = typed_array_values(record.get("actions"), "legacy actions array missing")?;
    if actions.is_empty() {
        return Err(VerifyError::InvalidResult("legacy actions array is empty"));
    }

    for action in actions {
        if action
            .get("_type")
            .and_then(|value| value.get("_name"))
            .and_then(Value::as_str)
            != Some("ActionRecord")
        {
            return Err(VerifyError::InvalidResult(
                "legacy action record type missing or invalid",
            ));
        }
        let action_result = action
            .get("actionResult")
            .ok_or(VerifyError::InvalidResult("legacy action result missing"))?;
        if action_result
            .get("_type")
            .and_then(|value| value.get("_name"))
            .and_then(Value::as_str)
            != Some("ActionResult")
        {
            return Err(VerifyError::InvalidResult(
                "legacy action result type missing or invalid",
            ));
        }
        let issues = action_result
            .get("issues")
            .ok_or(VerifyError::InvalidResult(
                "legacy action result issues missing",
            ))?;
        if issues
            .get("_type")
            .and_then(|value| value.get("_name"))
            .and_then(Value::as_str)
            != Some("ResultIssueSummaries")
        {
            return Err(VerifyError::InvalidResult(
                "legacy action result issues type missing or invalid",
            ));
        }
        for (field, expected_type) in [
            ("errorSummaries", "IssueSummary"),
            ("testFailureSummaries", "TestFailureIssueSummary"),
            ("analyzerWarningSummaries", "IssueSummary"),
            ("warningSummaries", "IssueSummary"),
            ("testWarningSummaries", "TestIssueSummary"),
        ] {
            let Some(value) = issues.get(field) else {
                // xcresulttool's typed legacy JSON omits empty arrays.
                continue;
            };
            let values = typed_array_values(Some(value), "legacy issue summary array is invalid")?;
            for item in values {
                if item
                    .get("_type")
                    .and_then(|typed| typed.get("_name"))
                    .and_then(Value::as_str)
                    != Some(expected_type)
                {
                    return Err(VerifyError::InvalidResult(
                        "legacy issue summary entry type is invalid",
                    ));
                }
            }
            if !values.is_empty() {
                return Err(VerifyError::FailedOutcome(format!(
                    "legacy action result reports {field}"
                )));
            }
        }
    }
    Ok(())
}

fn typed_array_values<'a>(value: Option<&'a Value>, missing: &'static str) -> Result<&'a [Value]> {
    let value = value.ok_or(VerifyError::InvalidResult(missing))?;
    if value
        .get("_type")
        .and_then(|typed| typed.get("_name"))
        .and_then(Value::as_str)
        != Some("Array")
    {
        return Err(VerifyError::InvalidResult(missing));
    }
    value
        .get("_values")
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .ok_or(VerifyError::InvalidResult(missing))
}

fn validate_summary(summary: &Value) -> Result<SummaryCounts> {
    let root = summary
        .as_object()
        .ok_or(VerifyError::InvalidResult("summary must be an object"))?;
    for key in [
        "passedTests",
        "failedTests",
        "skippedTests",
        "expectedFailures",
    ] {
        if root.get(key).and_then(Value::as_u64).is_none() {
            return Err(VerifyError::InvalidResult(
                "summary outcome count missing or invalid",
            ));
        }
    }
    if root["failedTests"].as_u64() != Some(0) || root["expectedFailures"].as_u64() != Some(0) {
        return Err(VerifyError::FailedOutcome(
            "summary reports failures or expected failures".to_owned(),
        ));
    }
    let failures =
        root.get("testFailures")
            .and_then(Value::as_array)
            .ok_or(VerifyError::InvalidResult(
                "summary testFailures array missing",
            ))?;
    if !failures.is_empty() {
        return Err(VerifyError::FailedOutcome(
            "summary reports test failures".to_owned(),
        ));
    }
    let warnings = root
        .get("runtimeWarnings")
        .and_then(Value::as_array)
        .ok_or(VerifyError::InvalidResult(
            "summary runtimeWarnings array missing",
        ))?;
    if !warnings.is_empty() {
        return Err(VerifyError::FailedOutcome(
            "summary reports runtime warnings".to_owned(),
        ));
    }
    let result = root
        .get("result")
        .and_then(Value::as_str)
        .ok_or(VerifyError::InvalidResult("summary result missing"))?;
    if result != "Passed" {
        return Err(VerifyError::FailedOutcome(format!(
            "summary result {result}"
        )));
    }
    Ok(SummaryCounts {
        passed: root["passedTests"]
            .as_u64()
            .and_then(|count| usize::try_from(count).ok())
            .ok_or(VerifyError::InvalidResult(
                "summary passed count is invalid",
            ))?,
        skipped: root["skippedTests"]
            .as_u64()
            .and_then(|count| usize::try_from(count).ok())
            .ok_or(VerifyError::InvalidResult(
                "summary skipped count is invalid",
            ))?,
    })
}

pub fn validate_summary_json(json: &str) -> Result<()> {
    let summary: Value =
        serde_json::from_str(json).map_err(|error| VerifyError::InvalidJson(error.to_string()))?;
    validate_summary(&summary).map(|_| ())
}

#[cfg(test)]
mod tests {
    use super::*;

    const LEGACY_EMPTY_ISSUES: &str =
        include_str!("../tests/fixtures/test-results/legacy-empty-issue-summaries.json");

    fn passed_summary() -> Value {
        serde_json::json!({
            "result": "Passed",
            "passedTests": 2,
            "failedTests": 0,
            "skippedTests": 0,
            "expectedFailures": 0,
            "testFailures": []
        })
    }

    fn legacy_with_issue(field: &str, type_name: &str) -> Value {
        let mut record: Value = serde_json::from_str(LEGACY_EMPTY_ISSUES).expect("legacy fixture");
        record["actions"]["_values"][0]["actionResult"]["issues"][field] = serde_json::json!({
            "_type": { "_name": "Array" },
            "_values": [{ "_type": { "_name": type_name } }]
        });
        record
    }

    #[test]
    fn missing_modern_warning_field_uses_real_legacy_empty_array_shape() {
        let summary = passed_summary();
        let legacy: Value = serde_json::from_str(LEGACY_EMPTY_ISSUES).expect("legacy fixture");
        assert!(validate_summary_with_legacy_fallback(&summary, || Ok(legacy)).is_ok());
        assert!(validate_summary_json(&summary.to_string()).is_err());
    }

    #[test]
    fn legacy_warning_and_error_summaries_fail_closed() {
        for (field, type_name) in [
            ("warningSummaries", "IssueSummary"),
            ("testWarningSummaries", "TestIssueSummary"),
            ("analyzerWarningSummaries", "IssueSummary"),
            ("errorSummaries", "IssueSummary"),
            ("testFailureSummaries", "TestFailureIssueSummary"),
        ] {
            let summary = passed_summary();
            let legacy = legacy_with_issue(field, type_name);
            assert!(
                matches!(
                    validate_summary_with_legacy_fallback(&summary, || Ok(legacy)),
                    Err(VerifyError::FailedOutcome(_))
                ),
                "accepted legacy issue summary {field}"
            );
        }
    }

    #[test]
    fn legacy_record_requires_nonempty_actions_and_action_issues() {
        let summary = passed_summary();
        let mut missing_issues: Value =
            serde_json::from_str(LEGACY_EMPTY_ISSUES).expect("legacy fixture");
        missing_issues["actions"]["_values"][0]["actionResult"]
            .as_object_mut()
            .expect("action result object")
            .remove("issues");
        assert!(matches!(
            validate_summary_with_legacy_fallback(&summary, || Ok(missing_issues)),
            Err(VerifyError::InvalidResult(_))
        ));

        let mut no_actions: Value =
            serde_json::from_str(LEGACY_EMPTY_ISSUES).expect("legacy fixture");
        no_actions["actions"]["_values"] = serde_json::json!([]);
        assert!(matches!(
            validate_summary_with_legacy_fallback(&summary, || Ok(no_actions)),
            Err(VerifyError::InvalidResult(_))
        ));
    }

    #[test]
    fn non_object_summary_is_rejected_before_legacy_fallback() {
        for summary in [Value::Null, serde_json::json!([]), serde_json::json!(42)] {
            assert!(matches!(
                validate_summary_with_legacy_fallback(&summary, || {
                    panic!("invalid summary must not request legacy evidence")
                }),
                Err(VerifyError::InvalidResult("summary must be an object"))
            ));
        }
    }

    #[test]
    fn null_modern_warning_field_does_not_use_legacy_fallback() {
        let mut summary = passed_summary();
        summary["runtimeWarnings"] = Value::Null;
        assert!(matches!(
            validate_summary_with_legacy_fallback(&summary, || {
                Err(VerifyError::InvalidResult(
                    "legacy fallback unexpectedly requested",
                ))
            }),
            Err(VerifyError::InvalidResult(
                "summary runtimeWarnings array missing"
            ))
        ));
    }
}
