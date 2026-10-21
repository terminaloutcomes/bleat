use super::{Fixture, FixtureWorker, alive, held};
use crate::{
    ci_smoke::owned_command::{self, Cause, Failure, Stage},
    swift_test_results::{
        SwiftTestResultsError, TestRunner, VerificationSummary,
        commands::{
            SwiftCommand, decode_discovery_output, discovery_command, finish_execution,
            run_with_budget,
        },
    },
};
use std::{
    ffi::OsStr,
    fs,
    os::unix::process::ExitStatusExt,
    process::{ExitStatus, Output},
    sync::mpsc,
    thread,
    time::Duration,
};

fn phases() -> [(SwiftCommand, Stage); 3] {
    [
        (
            SwiftCommand::Discovery(TestRunner::Xctest),
            Stage::SwiftPMXCTestDiscovery,
        ),
        (
            SwiftCommand::Discovery(TestRunner::SwiftTesting),
            Stage::SwiftTestingDiscovery,
        ),
        (SwiftCommand::Execution, Stage::SwiftPMExecution),
    ]
}
fn discoveries() -> [TestRunner; 2] {
    [TestRunner::Xctest, TestRunner::SwiftTesting]
}

#[test]
fn swiftpm_policies_and_discovery_arguments_keep_runner_and_package_selection() {
    for (phase, stage) in phases() {
        assert_eq!(phase.stage(), stage);
        assert_eq!(
            phase.budget(),
            Duration::from_secs(if matches!(phase, SwiftCommand::Execution) {
                3600
            } else {
                1200
            })
        );
    }
    for runner in discoveries() {
        for package in [None, Some(OsStr::new("synthetic package with spaces"))] {
            let command = discovery_command(runner, package);
            assert_eq!(command.get_program(), "swift");
            let mut expected = vec![OsStr::new("test")];
            if let Some(package) = package {
                expected.extend([OsStr::new("--package-path"), package]);
            }
            expected.extend([
                OsStr::new("list"),
                OsStr::new(match runner {
                    TestRunner::Xctest => "--disable-swift-testing",
                    TestRunner::SwiftTesting => "--disable-xctest",
                }),
            ]);
            assert_eq!(command.get_args().collect::<Vec<_>>(), expected);
        }
    }
}

#[test]
fn swiftpm_deadlines_reap_each_admitted_native_command() {
    for (phase, stage) in phases() {
        let fixture = Fixture::new();
        let mut command = fixture.command("swiftpm", held());
        let (tx, rx) = mpsc::channel();
        let worker = thread::spawn(move || {
            tx.send(run_with_budget(
                &mut command,
                phase,
                Duration::from_secs(2),
                Duration::from_secs(1),
            ))
            .expect("deliver native SwiftPM outcome");
        });
        let worker = FixtureWorker {
            worker: Some(worker),
            release: fixture.root.path().join("release"),
        };
        let pid = fixture.ready("swiftpm");
        let early = rx.recv_timeout(Duration::from_secs(5));
        let bounded = early.is_ok();
        fixture.release();
        let result = early.unwrap_or_else(|_| {
            rx.recv_timeout(Duration::from_secs(3))
                .expect("released fixture drains")
        });
        worker.join().expect("owned native fixture worker joined");
        fixture.drain_pid(pid);
        assert!(
            bounded,
            "native SwiftPM boundary exceeded independent observation bound"
        );
        let failure = result.expect_err("held command must fail");
        assert_eq!(failure.stage, stage);
        assert!(
            matches!(failure.cause, Cause::Deadline{elapsed,budget} if budget == Duration::from_secs(2) && elapsed >= budget)
        );
        let cleanup = failure.cleanup.as_ref().expect("cleanup report");
        assert!(cleanup.signal_attempted && cleanup.child_status.is_some() && cleanup.group_gone);
        assert!(!alive(pid), "admitted child survived cleanup");
    }
}

#[test]
fn swiftpm_native_failure_causes_and_captured_payload_remain_separate() {
    const MARKER: &str = "synthetic-private-swiftpm-stdout-marker";
    for (phase, stage) in phases() {
        let fixture = Fixture::new();
        let discovery = matches!(phase, SwiftCommand::Discovery(_));
        let mut command = fixture.command(
            "swiftpm",
            if discovery {
                "printf '%s' \"$MARKER\"; exit 23"
            } else {
                "exit 23"
            },
        );
        command.env("MARKER", MARKER);
        let failure = run_with_budget(
            &mut command,
            phase,
            Duration::from_secs(2),
            Duration::from_secs(1),
        )
        .expect_err("failed native command rejects acceptance");
        assert_eq!(failure.stage, stage);
        assert!(matches!(failure.cause, Cause::Exit(status) if status.code() == Some(23)));
        assert!(!format!("{failure}\n{failure:?}").contains(MARKER));
        if discovery {
            assert_eq!(failure.capture.stdout, MARKER.as_bytes());
        }
        assert!(failure.capture.stderr.is_empty());
        assert!(failure.cleanup.as_ref().expect("cleanup report").group_gone);
        let mut command = std::process::Command::new(fixture.root.path().join("absent-swift-tool"));
        let failure = run_with_budget(
            &mut command,
            phase,
            Duration::from_secs(2),
            Duration::from_secs(1),
        )
        .expect_err("missing tool fails");
        assert_eq!(failure.stage, stage);
        assert!(
            matches!(&failure.cause, Cause::Spawn(source) if source.kind() == std::io::ErrorKind::NotFound)
        );
        assert!(failure.cleanup.is_none());
    }
}

#[test]
fn swiftpm_discovery_transport_keeps_complete_output_and_typed_encoding() {
    const MARKER: &str = "synthetic-invalid-swiftpm-discovery-marker";
    for runner in discoveries() {
        let fixture = Fixture::new();
        let payload = " ".repeat(2 * 1024 * 1024) + "SyntheticSuite/testNativeIdentity\n";
        fs::write(fixture.root.path().join("payload"), &payload).expect("private large output");
        let mut command = fixture.command(
            "swiftpm",
            "printf 'synthetic compiler stderr control\\n' >&2; exec /bin/cat payload",
        );
        let output = run_with_budget(
            &mut command,
            SwiftCommand::Discovery(runner),
            Duration::from_secs(2),
            Duration::from_secs(1),
        )
        .expect("complete bounded discovery output");
        assert!(
            output.stderr.is_empty(),
            "live compiler stderr must not be captured or replayed"
        );
        // Exact bytes are the transport contract; identity semantics are parsed separately.
        assert_eq!(output.stdout, payload.as_bytes());
        assert_eq!(
            decode_discovery_output(output.stdout, runner).expect("valid UTF8"),
            payload
        );
        let mut invalid = MARKER.as_bytes().to_vec();
        invalid.push(255);
        fs::write(fixture.root.path().join("payload"), &invalid).expect("invalid encoding fixture");
        let mut command = fixture.command("swiftpm", "exec /bin/cat payload");
        let output = run_with_budget(
            &mut command,
            SwiftCommand::Discovery(runner),
            Duration::from_secs(2),
            Duration::from_secs(1),
        )
        .expect("native transport completes before decoding");
        let error = decode_discovery_output(output.stdout, runner)
            .expect_err("invalid UTF8 fails distinctly");
        assert!(!format!("{error}\n{error:?}").contains(MARKER));
        let SwiftTestResultsError::DiscoveryEncoding {
            runner: actual_runner,
            source,
        } = &error
        else {
            panic!("missing typed encoding cause")
        };
        assert_eq!(*actual_runner, runner);
        assert_eq!(source.valid_up_to(), MARKER.len());
        assert_eq!(source.error_len(), Some(1));
        assert!(
            std::error::Error::source(&error)
                .expect("original UTF8 cause")
                .downcast_ref::<std::str::Utf8Error>()
                .is_some()
        );
    }
}

#[test]
fn swiftpm_stdout_only_capture_rejects_oversize_without_partial_acceptance() {
    for (phase, stage) in phases()
        .into_iter()
        .filter(|(phase, _)| matches!(phase, SwiftCommand::Discovery(_)))
    {
        let fixture = Fixture::new();
        fs::write(fixture.root.path().join("payload"), vec![b'x'; 65])
            .expect("oversized private output");
        let mut command = fixture.command("swiftpm", "exec /bin/cat payload");
        let failure = owned_command::run_stdout(
            &mut command,
            phase.stage(),
            Duration::from_secs(2),
            Duration::from_secs(1),
            64,
        )
        .expect_err("stdout ceiling rejects rather than truncates");
        assert_eq!(failure.stage, stage);
        assert!(matches!(failure.cause, Cause::Capture));
        assert!(failure.capture.stdout.is_empty() && failure.capture.stderr.is_empty());
        assert!(
            failure
                .capture_errors
                .iter()
                .any(|(stream, error)| *stream == "stdout"
                    && error.kind() == std::io::ErrorKind::FileTooLarge)
        );
        assert!(failure.cleanup.as_ref().expect("cleanup report").group_gone);
    }
}

#[test]
fn swiftpm_execution_preserves_child_only_observation_environment() {
    let fixture = Fixture::new();
    let marker = fixture
        .root
        .path()
        .join("synthetic observation with spaces");
    let mut command = fixture.command(
        "swiftpm",
        "printf configured > \"$BLEAT_XCTEST_OBSERVATION_PATH\"",
    );
    command.env("BLEAT_XCTEST_OBSERVATION_PATH", &marker);
    let output = run_with_budget(
        &mut command,
        SwiftCommand::Execution,
        Duration::from_secs(2),
        Duration::from_secs(1),
    )
    .expect("child observer environment preserved");
    assert!(output.status.success() && output.stdout.is_empty() && output.stderr.is_empty());
    assert_eq!(
        fs::read_to_string(marker).expect("private observation marker"),
        "configured"
    );
    let mut command = fixture.command("swiftpm", "test -z \"${BLEAT_XCTEST_OBSERVATION_PATH+x}\"");
    command
        .env("BLEAT_XCTEST_OBSERVATION_PATH", "synthetic-removed")
        .env_remove("BLEAT_XCTEST_OBSERVATION_PATH");
    run_with_budget(
        &mut command,
        SwiftCommand::Execution,
        Duration::from_secs(2),
        Duration::from_secs(1),
    )
    .expect("Swift Testing-only invocation removes observer environment");
}

#[test]
fn swiftpm_execution_always_audits_reports_and_keeps_both_typed_causes() {
    for native_fails in [false, true] {
        for audit_fails in [false, true] {
            let native = if native_fails {
                Err(Failure::before_spawn(
                    Stage::SwiftPMExecution,
                    Cause::Deadline {
                        elapsed: Duration::from_secs(2),
                        budget: Duration::from_secs(2),
                    },
                ))
            } else {
                Ok(Output {
                    status: ExitStatus::from_raw(0),
                    stdout: vec![],
                    stderr: vec![],
                })
            };
            let mut audited = false;
            let result = finish_execution(native, || {
                audited = true;
                if audit_fails {
                    Err(SwiftTestResultsError::EmptySelection)
                } else {
                    Ok(VerificationSummary {
                        passed: 1,
                        swift_testing_selected: 1,
                        ..VerificationSummary::default()
                    })
                }
            });
            assert!(
                audited,
                "every native outcome must audit existing report artifacts"
            );
            match (native_fails, audit_fails, result) {
                (false, false, Ok(summary)) => assert_eq!(
                    summary,
                    VerificationSummary {
                        passed: 1,
                        swift_testing_selected: 1,
                        ..VerificationSummary::default()
                    }
                ),
                (false, true, Err(SwiftTestResultsError::EmptySelection)) => {}
                (true, _, Err(error @ SwiftTestResultsError::ExecutionAndAudit { .. })) => {
                    let SwiftTestResultsError::ExecutionAndAudit {
                        command,
                        report_audit,
                    } = &error
                    else {
                        unreachable!()
                    };
                    assert_eq!(command.stage, Stage::SwiftPMExecution);
                    assert!(matches!(command.cause, Cause::Deadline { .. }));
                    assert_eq!(report_audit.is_some(), audit_fails);
                    if let Some(audit) = report_audit {
                        assert!(matches!(**audit, SwiftTestResultsError::EmptySelection));
                    }
                    // Error::source can expose the boxed failure wrapper. The
                    // semantic contract is the exact original native cause;
                    // stage and both failure fields are checked above.
                    let cause = std::error::Error::source(&error)
                        .and_then(std::error::Error::source)
                        .and_then(|source| source.downcast_ref::<Cause>())
                        .expect("original typed native cause chain");
                    assert!(matches!(cause, Cause::Deadline { elapsed, budget }
                        if *elapsed == Duration::from_secs(2) && *budget == Duration::from_secs(2)));
                }
                _ => panic!("execution/report acceptance lost an original outcome"),
            }
        }
    }
}
