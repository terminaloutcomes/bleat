use scripts::ci_artifact_retry::{
    MissingFiles, Outcome, completed, retry_delay, run, validate_input,
};
use std::time::Duration;

fn cli(arguments: &[&str]) -> std::process::Output {
    std::process::Command::new(env!("CARGO_BIN_EXE_ci-artifact-retry"))
        .args(arguments)
        .output()
        .expect("CLI starts")
}

#[test]
fn cli_propagates_validation_and_terminal_gate_failures() {
    let directory = tempfile::tempdir().unwrap();
    let missing = directory.path().join("missing.xml");
    let path = missing.to_str().unwrap();
    assert!(!cli(&["prepare", path, "error"]).status.success());
    assert!(cli(&["prepare", path, "warn"]).status.success());
    assert!(!cli(&["prepare", path, "unknown"]).status.success());
    for outcomes in [
        ["success", "skipped", "skipped"],
        ["failure", "success", "skipped"],
        ["failure", "failure", "success"],
    ] {
        assert!(
            cli(&["finish", outcomes[0], outcomes[1], outcomes[2]])
                .status
                .success()
        );
    }
    for outcomes in [
        ["failure", "failure", "failure"],
        ["skipped", "skipped", "skipped"],
        ["success", "cancelled", "skipped"],
    ] {
        assert!(
            !cli(&["finish", outcomes[0], outcomes[1], outcomes[2]])
                .status
                .success()
        );
    }
}

#[test]
fn cli_writes_retry_output_after_backoff_and_stops_on_cancellation() {
    let directory = tempfile::tempdir().unwrap();
    for (outcome, expected) in [
        ("failure", "true"),
        ("success", "false"),
        ("cancelled", "false"),
    ] {
        let output_path = directory.path().join(outcome);
        std::fs::write(&output_path, "existing=value\n").unwrap();
        let output = std::process::Command::new(env!("CARGO_BIN_EXE_ci-artifact-retry"))
            .args(["retry", outcome, "2"])
            .env("GITHUB_OUTPUT", &output_path)
            .output()
            .unwrap();
        assert!(output.status.success());
        assert_eq!(
            std::fs::read_to_string(&output_path).unwrap(),
            format!("existing=value\nretry={expected}\n")
        );
    }
}

fn simulate(outcomes: &[Outcome]) -> (usize, bool) {
    let mut attempts = Vec::new();
    for (index, outcome) in outcomes.iter().enumerate().take(3) {
        attempts.push(*outcome);
        if index == 2
            || retry_delay(*outcome, index + 2)
                .expect("valid attempt")
                .is_none()
        {
            break;
        }
    }
    (attempts.len(), completed(&attempts))
}

#[test]
fn success_stops_at_each_attempt() {
    use Outcome::{Failure, Success};
    assert_eq!(simulate(&[Success, Failure, Failure]), (1, true));
    assert_eq!(simulate(&[Failure, Success, Failure]), (2, true));
    assert_eq!(simulate(&[Failure, Failure, Success]), (3, true));
}

#[test]
fn exhausted_and_permanent_upload_failures_remain_failed() {
    // Upstream does not expose typed errors. Permanent service failures have the
    // same bounded policy as transient ones; no log-message classification.
    assert_eq!(simulate(&[Outcome::Failure; 4]), (3, false));
    assert!(run(&["finish", "failure", "failure", "failure"].map(str::to_owned)).is_err());
}

#[test]
fn delays_are_finite_and_invalid_attempts_are_rejected() {
    assert_eq!(
        retry_delay(Outcome::Failure, 2).unwrap(),
        Some(Duration::from_secs(5))
    );
    assert_eq!(
        retry_delay(Outcome::Failure, 3).unwrap(),
        Some(Duration::from_secs(15))
    );
    assert!(retry_delay(Outcome::Failure, 4).is_err());
}

#[test]
fn cancellation_and_skips_never_retry_or_pass_the_gate() {
    for outcome in [Outcome::Cancelled, Outcome::Skipped] {
        assert_eq!(retry_delay(outcome, 2).unwrap(), None);
        assert_eq!(simulate(&[outcome, Outcome::Success]), (1, false));
    }
    assert!(!completed(&[Outcome::Success, Outcome::Cancelled]));
}

#[test]
fn non_retryable_missing_required_files_fail_before_upload() {
    let directory = tempfile::tempdir().unwrap();
    let missing = directory.path().join("coverage.xml");
    assert!(validate_input(&missing, MissingFiles::Error).is_err());
    assert!(validate_input(directory.path(), MissingFiles::Error).is_err());
    assert!(validate_input(&missing, MissingFiles::Warn).is_ok());
    std::fs::write(&missing, "report").unwrap();
    assert!(validate_input(&missing, MissingFiles::Error).is_ok());
}

#[test]
fn unknown_outcomes_and_policies_fail_closed() {
    assert!("unknown".parse::<Outcome>().is_err());
    assert!("ignore".parse::<MissingFiles>().is_err());
    assert!(run(&["finish", "success", "unknown", "skipped"].map(str::to_owned)).is_err());
}

#[test]
fn partial_success_requires_confirmed_replacement() {
    // A failed attempt may have left an artifact on the service. It is never
    // counted as success just because something with that name exists.
    assert_eq!(simulate(&[Outcome::Failure, Outcome::Success]), (2, true));
    assert_eq!(simulate(&[Outcome::Failure; 3]), (3, false));
    let action = include_str!("../../.github/actions/upload-artifact/action.yml");
    assert_eq!(action.matches("overwrite: true").count(), 2);
    assert_eq!(action.matches("name: ${{ inputs.name }}").count(), 3);
    for output in ["artifact-id", "artifact-url", "artifact-digest"] {
        assert!(action.contains(&format!("steps.attempt3.outputs.{output} || steps.attempt2.outputs.{output} || steps.attempt1.outputs.{output}")));
    }
}

#[test]
fn workflow_keeps_required_coverage_and_failed_test_diagnostics() {
    let workflow = include_str!("../../.github/workflows/ci.yml");
    assert_eq!(
        workflow
            .matches("uses: ./.github/actions/upload-artifact")
            .count(),
        5
    );
    assert_eq!(workflow.matches("timeout-minutes: 15").count(), 5);
    for name in ["swift-coverage", "swift-host-coverage", "rust-coverage"] {
        let block = workflow
            .split(&format!("name: {name}\n"))
            .nth(1)
            .unwrap()
            .split("      - ")
            .next()
            .unwrap();
        assert!(block.contains("if-no-files-found: error"));
    }
    for name in ["ios-smoke-results", "swift-host-results"] {
        let start = workflow.find(&format!("name: {name}\n")).unwrap();
        let upload = &workflow[..start];
        let block = upload
            .rsplit("      - uses: ./.github/actions/upload-artifact")
            .next()
            .unwrap();
        assert!(block.contains("if: always()"));
    }
    assert!(workflow.contains("needs: [ios, host, rust]"));
    for path in [
        "coverage/swift-coverage/cobertura.xml",
        "coverage/swift-host-coverage/lcov.info",
        "coverage/rust-coverage/lcov.info",
    ] {
        assert!(workflow.contains(path));
    }
    // The diagnostic action is allowed after failed tests; its success does not
    // change the original test step's failure (there is no job-level waiver).
    assert!(!workflow[..workflow.find("  coverage:").unwrap()].contains("continue-on-error"));
    let action = include_str!("../../.github/actions/upload-artifact/action.yml");
    assert!(action.contains("!cancelled() && steps.prepare.outcome == 'success'"));
    assert!(!action.contains(".conclusion"));
}
