use super::{Fixture, FixtureWorker, alive, held};
use crate::test_results::{
    BundleReport, CommandCause, VerifyError, read_report_command, read_report_command_with_limit,
};
use std::{error::Error, fs, path::Path, sync::mpsc, thread, time::Duration};

fn reports() -> [(BundleReport, &'static str); 3] {
    [
        (BundleReport::Tests, "tests"),
        (BundleReport::Summary, "summary"),
        (BundleReport::LegacySummary, "legacy"),
    ]
}

#[test]
fn report_command_arguments_preserve_all_native_report_modes() {
    let path = Path::new("fixture with spaces/result.xcresult");
    for (report, _) in reports() {
        let command = report.command(path);
        assert_eq!(command.get_program(), "xcrun");
        let args: Vec<_> = command.get_args().collect();
        let expected: Vec<&std::ffi::OsStr> = match report {
            BundleReport::Tests => ["xcresulttool", "get", "test-results", "tests", "--path"]
                .into_iter()
                .map(std::ffi::OsStr::new)
                .chain([path.as_os_str()])
                .collect(),
            BundleReport::Summary => ["xcresulttool", "get", "test-results", "summary", "--path"]
                .into_iter()
                .map(std::ffi::OsStr::new)
                .chain([path.as_os_str()])
                .collect(),
            BundleReport::LegacySummary => ["xcresulttool", "get", "object", "--legacy", "--path"]
                .into_iter()
                .map(std::ffi::OsStr::new)
                .chain([path.as_os_str()])
                .chain(["--format", "json"].into_iter().map(std::ffi::OsStr::new))
                .collect(),
        };
        assert_eq!(args, expected);
    }
}

#[test]
fn report_command_failures_keep_stage_status_and_redact_payload() {
    const SECRET: &str = "synthetic-report-bearer-private-marker";
    for (report, role) in reports() {
        let fixture = Fixture::new();
        let mut command = fixture.command(role, "printf '%s' \"$MARKER\" >&2; exit 23");
        command.env("MARKER", SECRET);
        let result = read_report_command(
            &mut command,
            report,
            Duration::from_secs(2),
            Duration::from_secs(1),
        );
        let error = require_failure(result, "nonzero native report must fail");
        assert!(
            !format!("{error}\n{error:?}").contains(SECRET),
            "diagnostic copied synthetic report payload"
        );
        let VerifyError::Command(failure) = &error else {
            panic!("missing typed command failure")
        };
        assert_eq!(failure.stage, report.stage());
        assert!(matches!(failure.cause, CommandCause::Exit(status) if status.code() == Some(23)));
        // Exact raw capture is the wire contract; only diagnostic formatting redacts it.
        assert_eq!(failure.capture.stderr, SECRET.as_bytes());
        assert!(failure.cleanup.as_ref().expect("cleanup report").group_gone);
        assert!(error.source().is_some());
    }
}

#[test]
fn report_command_deadlines_reap_each_admitted_native_report() {
    for (report, role) in reports() {
        let fixture = Fixture::new();
        let mut command = fixture.command(role, held());
        let (tx, rx) = mpsc::channel();
        let worker = thread::spawn(move || {
            let result = read_report_command(
                &mut command,
                report,
                Duration::from_secs(2),
                Duration::from_secs(1),
            );
            tx.send(result).expect("deliver report outcome");
        });
        let worker = FixtureWorker {
            worker: Some(worker),
            release: fixture.root.path().join("release"),
        };
        let pid = fixture.ready(role);
        let early = rx.recv_timeout(Duration::from_secs(5));
        let returned_within_bound = early.is_ok();
        fixture.release();
        let result = early.unwrap_or_else(|_| {
            rx.recv_timeout(Duration::from_secs(3))
                .expect("released report fixture drains")
        });
        worker.join().expect("owned report worker joined");
        fixture.drain_pid(pid);
        assert!(
            returned_within_bound,
            "held report outlived the independent observation bound"
        );
        let error = require_failure(result, "held report must fail");
        let VerifyError::Command(failure) = error else {
            panic!("missing typed report deadline")
        };
        assert_eq!(failure.stage, report.stage());
        assert!(
            matches!(failure.cause, CommandCause::Deadline { budget, elapsed } if budget == Duration::from_secs(2) && elapsed >= budget)
        );
        let cleanup = failure.cleanup.expect("native cleanup report");
        assert!(cleanup.signal_attempted && cleanup.child_status.is_some() && cleanup.group_gone);
        assert!(!alive(pid), "admitted report child survived cleanup");
        eprintln!("report={report:?};deadline=true;child_reaped=true;group_gone=true");
    }
}

#[test]
fn report_command_capture_limit_rejects_output_without_partial_success() {
    for (report, role) in reports() {
        let fixture = Fixture::new();
        fs::write(fixture.root.path().join("payload"), vec![b'x'; 65])
            .expect("oversized synthetic report");
        let mut command = fixture.command(role, "exec /bin/cat payload");
        let result = read_report_command_with_limit(
            &mut command,
            report,
            Duration::from_secs(2),
            Duration::from_secs(1),
            64,
        );
        let Some(error) = result.err() else {
            panic!("oversized report was accepted")
        };
        let VerifyError::Command(failure) = error else {
            panic!("missing typed capture failure")
        };
        assert_eq!(failure.stage, report.stage());
        assert!(matches!(failure.cause, CommandCause::Capture));
        assert!(
            failure
                .capture_errors
                .iter()
                .any(|(stream, error)| *stream == "stdout"
                    && error.kind() == std::io::ErrorKind::FileTooLarge)
        );
        assert!(failure.capture.stdout.is_empty());
        assert!(failure.cleanup.as_ref().expect("cleanup report").group_gone);
    }
}

#[test]
fn report_command_invalid_utf8_keeps_encoding_stage_without_payload() {
    const SECRET: &str = "synthetic-invalid-report-private-marker";
    for (report, role) in reports() {
        let fixture = Fixture::new();
        let mut payload = SECRET.as_bytes().to_vec();
        payload.push(255);
        fs::write(fixture.root.path().join("payload"), payload).expect("invalid encoding fixture");
        let mut command = fixture.command(role, "exec /bin/cat payload");
        let result = read_report_command(
            &mut command,
            report,
            Duration::from_secs(2),
            Duration::from_secs(1),
        );
        let error = require_failure(result, "invalid encoding must fail");
        assert!(!format!("{error}\n{error:?}").contains(SECRET));
        let VerifyError::OutputEncoding { stage, source } = &error else {
            panic!("missing typed output encoding failure")
        };
        assert_eq!(*stage, report.stage());
        assert_eq!(source.valid_up_to(), SECRET.len());
        assert_eq!(source.error_len(), Some(1));
        assert!(
            error
                .source()
                .expect("original encoding cause")
                .downcast_ref::<std::str::Utf8Error>()
                .is_some()
        );
    }
}

#[test]
fn report_command_accepts_bounded_large_valid_utf8_json() {
    for (report, role) in reports() {
        let fixture = Fixture::new();
        let payload = " ".repeat(4 * 1024 * 1024) + r#"{"value":"synthetic-report"}"#;
        fs::write(fixture.root.path().join("payload"), payload).expect("bounded synthetic JSON");
        let mut command = fixture.command(role, "exec /bin/cat payload");
        let output = read_report_command(
            &mut command,
            report,
            Duration::from_secs(2),
            Duration::from_secs(1),
        )
        .expect("bounded valid report output");
        let parsed: serde_json::Value = serde_json::from_str(&output).expect("JSON remains valid");
        assert_eq!(parsed, serde_json::json!({"value":"synthetic-report"}));
    }
}

#[test]
fn report_command_spawn_and_invalid_limit_keep_exact_typed_causes() {
    for (report, _) in reports() {
        let fixture = Fixture::new();
        let mut command =
            std::process::Command::new(fixture.root.path().join("missing-report-tool"));
        let error = require_failure(
            read_report_command(
                &mut command,
                report,
                Duration::from_secs(2),
                Duration::from_secs(1),
            ),
            "missing report tool fails",
        );
        let VerifyError::Command(failure) = error else {
            panic!("missing typed spawn cause")
        };
        assert_eq!(failure.stage, report.stage());
        assert!(
            matches!(failure.cause, CommandCause::Spawn(ref source) if source.kind() == std::io::ErrorKind::NotFound)
        );
        assert!(failure.cleanup.is_none());
        let error = require_failure(
            read_report_command_with_limit(
                &mut command,
                report,
                Duration::from_secs(2),
                Duration::from_secs(1),
                0,
            ),
            "zero capture ceiling rejected before spawn",
        );
        let VerifyError::Command(failure) = error else {
            panic!("missing typed invalid limit cause")
        };
        assert_eq!(failure.stage, report.stage());
        assert!(matches!(failure.cause, CommandCause::InvalidCaptureLimit));
        assert!(failure.cleanup.is_none());
    }
    // Existing smoke consumers retain their one-MiB acceptance ceiling.
    let fixture = Fixture::new();
    fs::write(
        fixture.root.path().join("payload"),
        vec![b'x'; 1024 * 1024 + 1],
    )
    .expect("default ceiling fixture");
    let mut command = fixture.command("default-limit", "exec /bin/cat payload");
    let error = require_failure(
        crate::ci_smoke::owned_command::run(
            &mut command,
            crate::test_results::CommandStage::JsonInspection,
            Duration::from_secs(2),
            Duration::from_secs(1),
            None,
        ),
        "default smoke ceiling remains bounded",
    );
    assert!(matches!(error.cause, CommandCause::Capture));
    assert!(
        error
            .capture_errors
            .iter()
            .any(|(_, cause)| cause.kind() == std::io::ErrorKind::FileTooLarge)
    );
}

// Do not format an unexpected successful report into test failure diagnostics.
fn require_failure<T, E>(result: std::result::Result<T, E>, message: &str) -> E {
    match result {
        Err(error) => error,
        Ok(_) => panic!("{message}"),
    }
}
