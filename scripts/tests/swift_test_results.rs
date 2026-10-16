use std::collections::{BTreeMap, BTreeSet};

use scripts::swift_test_results::{
    AllowedSkips, ExpectedTests, SwiftTestResultsError, XCTestObservationOutcome,
    XCTestObservationRecord, verify_execution_results, verify_observation_records,
};

const X: &str = "BleatCoreLiveTests.SampleTests/testReturnsValue";
const S: &str = "BleatCoreTests.SampleTests/testReturnsValue()";

fn expected(xctest: &[&str], swift_testing: &[&str]) -> ExpectedTests {
    ExpectedTests {
        xctest: counts(xctest),
        swift_testing: counts(swift_testing),
    }
}

fn counts(identities: &[&str]) -> BTreeMap<String, usize> {
    identities
        .iter()
        .map(|identity| ((*identity).to_owned(), 1))
        .collect()
}

fn record(identity: &str, outcome: XCTestObservationOutcome) -> XCTestObservationRecord {
    XCTestObservationRecord {
        identity: identity.to_owned(),
        outcome,
    }
}

fn xml(identity: &str, outcome: &str) -> String {
    let (class, name) = identity
        .split_once('/')
        .expect("identity has suite/test separator");
    format!(
        "<testsuites><testsuite><testcase classname=\"{class}\" name=\"{name}\">{outcome}</testcase></testsuite></testsuites>"
    )
}

fn write_report(directory: &std::path::Path, file: &str, content: &str) -> std::path::PathBuf {
    let path = directory.join(file);
    std::fs::write(&path, content).expect("report is written");
    path
}

fn write_observations(directory: &std::path::Path, records: &[XCTestObservationRecord]) {
    let json = serde_json::to_vec(records).expect("observations are serialized");
    write_report(
        directory,
        "xctest.xml.xctest-observation.123.json",
        std::str::from_utf8(&json).expect("JSON is UTF-8"),
    );
}

#[test]
fn verifies_exact_xctest_and_swift_testing_selections() {
    let directory = tempfile::tempdir().expect("temporary report directory is created");
    write_observations(
        directory.path(),
        &[record(X, XCTestObservationOutcome::Passed)],
    );
    let swift_testing = write_report(directory.path(), "swift-testing.xml", &xml(S, ""));
    let reports = BTreeMap::from([(
        scripts::swift_test_results::TestRunner::SwiftTesting,
        swift_testing,
    )]);
    let observation_prefix = directory.path().join("xctest.xml.xctest-observation");

    let result = verify_execution_results(
        &expected(&[X], &[S]),
        &reports,
        &observation_prefix,
        true,
        true,
        &BTreeSet::new(),
    )
    .expect("both runner reports match discovery");

    assert_eq!(result.passed, 2);
    assert_eq!(result.xctest_selected, 1);
    assert_eq!(result.swift_testing_selected, 1);
}

#[test]
fn rejects_unexpected_or_unknown_observation_identities() {
    let expected = counts(&[X]);
    let error = verify_observation_records(
        &[record(S, XCTestObservationOutcome::Passed)],
        &expected,
        &BTreeSet::new(),
    )
    .expect_err("a Swift Testing identity cannot satisfy XCTest discovery");
    assert!(matches!(
        error,
        SwiftTestResultsError::IdentityMismatch { .. }
    ));

    let error = verify_observation_records(
        &[record(
            "UnknownTests.Suite/testUnknown",
            XCTestObservationOutcome::Passed,
        )],
        &expected,
        &BTreeSet::new(),
    )
    .expect_err("unknown identities cannot pass");
    assert!(matches!(
        error,
        SwiftTestResultsError::IdentityMismatch { .. }
    ));
}

#[test]
fn rejects_duplicate_observation_records() {
    let records = [
        record(X, XCTestObservationOutcome::Passed),
        record(X, XCTestObservationOutcome::Passed),
    ];
    let error = verify_observation_records(&records, &counts(&[X]), &BTreeSet::new())
        .expect_err("duplicate observations cannot pass");
    assert!(matches!(
        error,
        SwiftTestResultsError::IdentityMismatch { .. }
    ));
}

#[test]
fn rejects_missing_observations_and_partial_dual_runner_output() {
    let directory = tempfile::tempdir().expect("temporary report directory is created");
    let swift_testing = write_report(directory.path(), "swift-testing.xml", &xml(S, ""));
    let reports = BTreeMap::from([(
        scripts::swift_test_results::TestRunner::SwiftTesting,
        swift_testing,
    )]);
    let prefix = directory.path().join("missing.xctest-observation");
    let error = verify_execution_results(
        &expected(&[X], &[S]),
        &reports,
        &prefix,
        true,
        true,
        &BTreeSet::new(),
    )
    .expect_err("missing XCTest observer output cannot be hidden by Swift Testing output");
    assert!(matches!(error, SwiftTestResultsError::MissingReport { .. }));

    write_observations(
        directory.path(),
        &[record(X, XCTestObservationOutcome::Passed)],
    );
    let reports = BTreeMap::new();
    let error = verify_execution_results(
        &expected(&[X], &[S]),
        &reports,
        &directory.path().join("xctest.xml.xctest-observation"),
        true,
        true,
        &BTreeSet::new(),
    )
    .expect_err("a missing Swift Testing report cannot be hidden by XCTest observations");
    assert!(matches!(error, SwiftTestResultsError::MissingReport { .. }));
}

#[test]
fn rejects_all_skipped_results_even_when_each_skip_is_allowlisted() {
    let allowed = AllowedSkips::from([X.to_owned()]);
    let error = verify_observation_records(
        &[record(X, XCTestObservationOutcome::Skipped)],
        &counts(&[X]),
        &allowed,
    )
    .expect_err("an allowlist cannot make an all-skipped run pass");
    assert!(matches!(
        error,
        SwiftTestResultsError::NoPassingTests { .. }
    ));
}

#[test]
fn accepts_an_allowed_skip_when_another_test_passes() {
    const SECOND: &str = "BleatCoreLiveTests.SampleTests/testOtherValue";
    let allowed = AllowedSkips::from([X.to_owned()]);
    let (passed, skipped) = verify_observation_records(
        &[
            record(X, XCTestObservationOutcome::Skipped),
            record(SECOND, XCTestObservationOutcome::Passed),
        ],
        &counts(&[X, SECOND]),
        &allowed,
    )
    .expect("one allowed skip does not hide a passing selected case");
    assert_eq!((passed, skipped), (1, 1));
}

#[test]
fn rejects_failed_and_unexpected_skipped_observations() {
    let error = verify_observation_records(
        &[record(X, XCTestObservationOutcome::Failed)],
        &counts(&[X]),
        &BTreeSet::new(),
    )
    .expect_err("failed XCTest outcomes are not passes");
    assert!(matches!(error, SwiftTestResultsError::FailedTest { .. }));

    let error = verify_observation_records(
        &[record(X, XCTestObservationOutcome::Skipped)],
        &counts(&[X]),
        &BTreeSet::new(),
    )
    .expect_err("unapproved skips are not passes");
    assert!(matches!(
        error,
        SwiftTestResultsError::UnexpectedSkip { .. }
    ));
}

#[test]
fn rejects_nonzero_or_inconsistent_aggregate_counts() {
    let directory = tempfile::tempdir().expect("temporary report directory is created");
    let xctest = directory
        .path()
        .join("xctest.xml.xctest-observation.123.json");
    std::fs::write(
        &xctest,
        serde_json::to_vec(&[record(X, XCTestObservationOutcome::Passed)])
            .expect("observation JSON is encoded"),
    )
    .expect("observation JSON is written");
    let path = write_report(
        directory.path(),
        "swift-testing.xml",
        &format!(
            "<testsuites failures=\"1\"><testsuite tests=\"1\"><testcase classname=\"{}\" name=\"{}\"/></testsuite></testsuites>",
            S.split_once('/')
                .expect("identity has suite/test separator")
                .0,
            S.split_once('/')
                .expect("identity has suite/test separator")
                .1
        ),
    );
    let reports = BTreeMap::from([(scripts::swift_test_results::TestRunner::SwiftTesting, path)]);
    let error = verify_execution_results(
        &expected(&[X], &[S]),
        &reports,
        &directory.path().join("xctest.xml.xctest-observation"),
        true,
        true,
        &BTreeSet::new(),
    )
    .expect_err("root aggregate failures cannot be hidden by passing testcases");
    assert!(matches!(
        error,
        SwiftTestResultsError::AggregateFailure { .. }
    ));

    let path = write_report(
        directory.path(),
        "swift-testing.xml",
        &format!(
            "<testsuites><testsuite tests=\"2\"><testcase classname=\"{}\" name=\"{}\"/></testsuite></testsuites>",
            S.split_once('/')
                .expect("identity has suite/test separator")
                .0,
            S.split_once('/')
                .expect("identity has suite/test separator")
                .1
        ),
    );
    let reports = BTreeMap::from([(scripts::swift_test_results::TestRunner::SwiftTesting, path)]);
    let error = verify_execution_results(
        &expected(&[X], &[S]),
        &reports,
        &directory.path().join("xctest.xml.xctest-observation"),
        true,
        true,
        &BTreeSet::new(),
    )
    .expect_err("suite test count must agree with testcase records");
    assert!(matches!(
        error,
        SwiftTestResultsError::InconsistentAggregateCount { .. }
    ));
}

#[test]
fn accepts_empty_auxiliary_swift_testing_suites() {
    let directory = tempfile::tempdir().expect("temporary report directory is created");
    write_observations(
        directory.path(),
        &[record(X, XCTestObservationOutcome::Passed)],
    );
    let swift_testing = write_report(
        directory.path(),
        "swift-testing.xml",
        "<testsuites><testsuite name=\"TestResults\" errors=\"0\" tests=\"0\" failures=\"0\" skipped=\"0\"/></testsuites>",
    );
    let reports = BTreeMap::from([(
        scripts::swift_test_results::TestRunner::SwiftTesting,
        swift_testing,
    )]);

    verify_execution_results(
        &expected(&[X], &[]),
        &reports,
        &directory.path().join("xctest.xml.xctest-observation"),
        true,
        true,
        &BTreeSet::new(),
    )
    .expect("empty Swift Testing suites do not invalidate XCTest results");
}

#[test]
fn ignores_neighboring_observation_artifacts() {
    let directory = tempfile::tempdir().expect("temporary report directory is created");
    write_observations(
        directory.path(),
        &[record(X, XCTestObservationOutcome::Passed)],
    );
    write_report(
        directory.path(),
        "xctest.xml.xctest-observation-backup.json",
        "this is not an observation shard",
    );
    let result = verify_execution_results(
        &expected(&[X], &[]),
        &BTreeMap::new(),
        &directory.path().join("xctest.xml.xctest-observation"),
        true,
        false,
        &BTreeSet::new(),
    )
    .expect("neighboring files are not treated as owned observation shards");
    assert_eq!(result.passed, 1);
}
