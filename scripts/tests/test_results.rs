use scripts::test_results::{
    ExpectedTest, TestId, VerifyError, discover_expected, expected_from_ids, validate_summary_json,
    verify_result_json, verify_result_json_with_summary,
};
use serde_json::Value;

const REAL_RESULTS: &str = include_str!("fixtures/test-results/real-repetitions.json");
const REAL_DISCOVERY: &str = include_str!("fixtures/test-results/real-discovery.json");
const TEST_ID: &str =
    "BleatAppTests/AppModelTests/testScrubberSeekDecisionConfirmsTenMinuteJumpsInEitherDirection";

fn expected(repetitions: usize) -> Vec<ExpectedTest> {
    expected_from_ids(&[TEST_ID.to_owned()], repetitions).expect("valid expectation")
}

fn mutate_results(change: impl FnOnce(&mut Value)) -> String {
    let mut value: Value = serde_json::from_str(REAL_RESULTS).expect("valid fixture");
    change(&mut value);
    serde_json::to_string(&value).expect("serialize fixture")
}

#[test]
fn genuine_xcode_repetitions_verify_each_child_and_discovery_identity() {
    let report =
        verify_result_json(REAL_RESULTS, &expected(2), &[]).expect("two passed repetitions");
    assert_eq!((report.passed, report.skipped), (2, 0));

    let discovered = discover_expected(REAL_DISCOVERY, &[], &[], 2).expect("discovery parses");
    assert_eq!(discovered.len(), 2);
    assert!(discovered.iter().all(|test| test.repetitions == 2));
    let selected = discover_expected(
        REAL_DISCOVERY,
        &["BleatAppTests/AppModelTests/testSignedInAlertQueueSerializesAndResetsForAccountChange()".to_owned()],
        &[],
        1,
    ).expect("exact function selector");
    assert_eq!(selected.len(), 1);
    assert!(
        selected[0]
            .id
            .as_string()
            .ends_with("testSignedInAlertQueueSerializesAndResetsForAccountChange")
    );
}

#[test]
fn failed_unknown_skipped_and_wrong_repetition_children_fail_closed() {
    let duplicate = mutate_results(|value| {
        value["testNodes"][0]["children"][1] = value["testNodes"][0]["children"][0].clone();
    });
    assert!(matches!(
        verify_result_json(&duplicate, &expected(2), &[]),
        Err(VerifyError::InvalidResult(_))
    ));
    let failed = mutate_results(|value| {
        value["testNodes"][0]["children"][1]["result"] = Value::String("Failed".to_owned())
    });
    assert!(matches!(
        verify_result_json(&failed, &expected(2), &[]),
        Err(VerifyError::FailedOutcome(_))
    ));

    let unknown = mutate_results(|value| {
        value["testNodes"][0]["children"][0]["result"] = Value::String("Flaky".to_owned())
    });
    assert!(matches!(
        verify_result_json(&unknown, &expected(2), &[]),
        Err(VerifyError::UnknownOutcome(_))
    ));

    let skipped = mutate_results(|value| {
        value["testNodes"][0]["children"][0]["result"] = Value::String("Skipped".to_owned())
    });
    assert!(matches!(
        verify_result_json(&skipped, &expected(2), &[]),
        Err(VerifyError::UnexpectedSkip(_))
    ));
    let allow = [TestId::parse(TEST_ID).expect("valid ID")];
    let report = verify_result_json(&skipped, &expected(2), &allow).expect("exact allowed skip");
    assert_eq!((report.passed, report.skipped), (1, 1));

    let all_skipped = mutate_results(|value| {
        value["testNodes"][0]["children"][0]["result"] = Value::String("Skipped".to_owned());
        value["testNodes"][0]["children"][1]["result"] = Value::String("Skipped".to_owned());
    });
    assert!(matches!(
        verify_result_json(&all_skipped, &expected(2), &allow),
        Err(VerifyError::AllSkipped)
    ));
    assert!(matches!(
        verify_result_json(REAL_RESULTS, &expected(1), &[]),
        Err(VerifyError::WrongRepetitionCount { .. })
    ));

    let aggregate_failed = mutate_results(|value| {
        value["testNodes"][0]["result"] = Value::String("Failed".to_owned())
    });
    assert!(matches!(
        verify_result_json(&aggregate_failed, &expected(2), &[]),
        Err(VerifyError::FailedOutcome(_))
    ));

    let unknown_child = mutate_results(|value| {
        value["testNodes"][0]["children"][0]["children"] = serde_json::json!([
            {"nodeType": "Unexpected Argument", "result": "Passed"}
        ]);
    });
    assert!(matches!(
        verify_result_json(&unknown_child, &expected(2), &[]),
        Err(VerifyError::UnknownNodeType(_))
    ));
}

#[test]
fn missing_extra_duplicate_and_malformed_discovery_are_rejected() {
    assert!(matches!(
        verify_result_json("{\"testNodes\":[]}", &expected(1), &[]),
        Err(VerifyError::MissingTest(_))
    ));
    let extra = mutate_results(|value| {
        let mut test = value["testNodes"][0].clone();
        test["nodeIdentifierURL"] = Value::String(
            "test://com.apple.xcode/Bleat/BleatUITests/OtherSuite/testUnexpected".to_owned(),
        );
        for repetition in test["children"].as_array_mut().expect("repetition array") {
            repetition["nodeIdentifierURL"] = Value::String(
                "test://com.apple.xcode/Bleat/BleatUITests/OtherSuite/testUnexpected".to_owned(),
            );
        }
        value["testNodes"].as_array_mut().expect("array").push(test);
    });
    assert!(matches!(
        verify_result_json(&extra, &expected(2), &[]),
        Err(VerifyError::ExtraTest(_))
    ));

    let mut duplicate_value: Value =
        serde_json::from_str(REAL_DISCOVERY).expect("discovery fixture");
    let first = duplicate_value["values"][0]["enabledTests"][0]["identifier"].clone();
    duplicate_value["values"][0]["enabledTests"][1]["identifier"] = first;
    let duplicate = duplicate_value.to_string();
    assert!(matches!(
        discover_expected(&duplicate, &[], &[], 1),
        Err(VerifyError::DuplicateDiscoveredTest(_))
    ));
    let with_error =
        REAL_DISCOVERY.replace("\"errors\": []", "\"errors\": [\"enumeration failed\"]");
    assert!(matches!(
        discover_expected(&with_error, &[], &[], 1),
        Err(VerifyError::DiscoveryErrors(_))
    ));
    assert!(matches!(
        discover_expected(REAL_DISCOVERY, &["NoSuchTarget".to_owned()], &[], 1),
        Err(VerifyError::UnmatchedSelector(_))
    ));
    assert!(matches!(
        discover_expected(
            REAL_DISCOVERY,
            &["BleatAppTests/AppModelTests/missing".to_owned()],
            &[],
            1
        ),
        Err(VerifyError::UnmatchedSelector(_))
    ));
    assert!(expected_from_ids(&[TEST_ID.to_owned(), TEST_ID.to_owned()], 1).is_err());
}

#[test]
fn cli_supports_offline_json_and_rejects_duplicate_expectations() {
    let results = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/tests/fixtures/test-results/real-repetitions.json"
    );
    let discovery = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/tests/fixtures/test-results/real-discovery.json"
    );
    let binary = env!("CARGO_BIN_EXE_verify-test-results");
    let passed = std::process::Command::new(binary)
        .args([
            "--results-json",
            results,
            "--expected",
            TEST_ID,
            "--repetitions",
            "2",
        ])
        .output()
        .expect("verifier starts");
    assert!(
        passed.status.success(),
        "{}",
        String::from_utf8_lossy(&passed.stderr)
    );
    let discovered = std::process::Command::new(binary)
        .args([
            "--results-json",
            results,
            "--discovery",
            discovery,
            "--only",
            TEST_ID,
            "--repetitions",
            "2",
        ])
        .output()
        .expect("verifier starts");
    assert!(
        discovered.status.success(),
        "{}",
        String::from_utf8_lossy(&discovered.stderr)
    );
    let duplicate = std::process::Command::new(binary)
        .args([
            "--results-json",
            results,
            "--expected",
            TEST_ID,
            "--expected",
            TEST_ID,
        ])
        .output()
        .expect("verifier starts");
    assert!(!duplicate.status.success());
}

#[test]
fn xcresult_summary_requires_zero_failures_expected_failures_and_runtime_warnings() {
    let passed: Value = serde_json::json!({
        "result": "Passed", "passedTests": 2, "failedTests": 0,
        "skippedTests": 0, "expectedFailures": 0,
        "testFailures": [], "runtimeWarnings": []
    });
    assert!(validate_summary_json(&passed.to_string()).is_ok());

    for (field, value) in [
        ("expectedFailures", Value::from(1)),
        (
            "runtimeWarnings",
            serde_json::json!([{"message": "warning"}]),
        ),
        (
            "testFailures",
            serde_json::json!([{"failureText": "failure"}]),
        ),
        ("result", Value::String("Failed".to_owned())),
    ] {
        let mut invalid = passed.clone();
        invalid[field] = value;
        assert!(
            validate_summary_json(&invalid.to_string()).is_err(),
            "accepted summary field {field}"
        );
    }

    let one_case_two_iterations = serde_json::json!({
        "result": "Passed", "passedTests": 1, "failedTests": 0,
        "skippedTests": 0, "expectedFailures": 0,
        "testFailures": [], "runtimeWarnings": []
    });
    let report = verify_result_json_with_summary(
        REAL_RESULTS,
        &one_case_two_iterations.to_string(),
        &expected(2),
        &[],
    )
    .expect("summary counts test cases, tree verifies both repetitions");
    assert_eq!((report.passed, report.passed_cases), (2, 1));
    let wrong_count = serde_json::json!({
        "result": "Passed", "passedTests": 2, "failedTests": 0,
        "skippedTests": 0, "expectedFailures": 0,
        "testFailures": [], "runtimeWarnings": []
    });
    assert!(
        verify_result_json_with_summary(REAL_RESULTS, &wrong_count.to_string(), &expected(2), &[])
            .is_err()
    );
}
