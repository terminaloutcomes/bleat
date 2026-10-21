use super::{Fixture, FixtureWorker, alive, held};
use crate::ci_smoke::{
    Cause, CommandFailure, Stage,
    smoke_commands::{SmokeCommand, TestPhaseFailure, finish_tests, run_with_budget},
};
use std::{fs, sync::mpsc, thread, time::Duration};

fn phases() -> [(SmokeCommand, Stage, u64); 6] {
    [
        (SmokeCommand::Version, Stage::XcodeVersion, 120),
        (SmokeCommand::Inventory, Stage::SimulatorInventory, 120),
        (SmokeCommand::Settings, Stage::BuildSettings, 300),
        (SmokeCommand::Enumeration, Stage::TestEnumeration, 300),
        (SmokeCommand::Install, Stage::SimulatorInstall, 300),
        (SmokeCommand::Execution, Stage::TestExecution, 2400),
    ]
}

#[test]
fn smoke_phase_policies_keep_distinct_stages_and_finite_budgets() {
    for (phase, stage, seconds) in phases() {
        assert_eq!(phase.stage(), stage);
        assert_eq!(phase.budget(), Duration::from_secs(seconds));
    }
}

#[test]
fn smoke_phase_deadlines_reap_each_admitted_command() {
    for (phase, stage, _) in phases() {
        let fixture = Fixture::new();
        let mut command = fixture.command("smoke", held());
        let (tx, rx) = mpsc::channel();
        let worker = thread::spawn(move || {
            let result = run_with_budget(
                &mut command,
                phase,
                Duration::from_secs(2),
                Duration::from_secs(1),
            );
            tx.send(result).expect("deliver smoke outcome");
        });
        let worker = FixtureWorker {
            worker: Some(worker),
            release: fixture.root.path().join("release"),
        };
        let pid = fixture.ready("smoke");
        let early = rx.recv_timeout(Duration::from_secs(5));
        let bounded = early.is_ok();
        fixture.release();
        let result = early.unwrap_or_else(|_| {
            rx.recv_timeout(Duration::from_secs(3))
                .expect("released smoke fixture drains")
        });
        worker.join().expect("owned smoke worker joined");
        fixture.drain_pid(pid);
        assert!(
            bounded,
            "phase {phase:?} exceeded independent observation bound"
        );
        let failure = result.expect_err("held smoke phase must fail");
        let failure = failure
            .downcast_ref::<CommandFailure>()
            .expect("typed command failure");
        assert_eq!(failure.stage, stage);
        assert!(
            matches!(failure.cause, Cause::Deadline{elapsed,budget} if budget == Duration::from_secs(2) && elapsed >= budget)
        );
        let cleanup = failure.cleanup.as_ref().expect("cleanup record");
        assert!(cleanup.signal_attempted && cleanup.child_status.is_some() && cleanup.group_gone);
        assert!(!alive(pid), "owned smoke child survived phase {phase:?}");
        eprintln!("phase={phase:?};deadline=true;child_reaped=true;group_gone=true");
    }
}

#[test]
fn smoke_phase_native_exits_and_missing_tools_keep_exact_causes() {
    for (phase, stage, _) in phases() {
        let fixture = Fixture::new();
        let mut command = fixture.command("smoke", "exit 23");
        let error = run_with_budget(
            &mut command,
            phase,
            Duration::from_secs(2),
            Duration::from_secs(1),
        )
        .expect_err("nonzero phase fails");
        let failure = error
            .downcast_ref::<CommandFailure>()
            .expect("typed native exit");
        assert_eq!(failure.stage, stage);
        assert!(matches!(failure.cause, Cause::Exit(status) if status.code() == Some(23)));
        assert!(failure.cleanup.as_ref().expect("cleanup record").group_gone);
        let mut absent = std::process::Command::new(fixture.root.path().join("absent-tool"));
        let error = run_with_budget(
            &mut absent,
            phase,
            Duration::from_secs(2),
            Duration::from_secs(1),
        )
        .expect_err("missing tool fails");
        let failure = error
            .downcast_ref::<CommandFailure>()
            .expect("typed missing tool");
        assert_eq!(failure.stage, stage);
        assert!(
            matches!(&failure.cause, Cause::Spawn(source) if source.kind() == std::io::ErrorKind::NotFound)
        );
        assert!(failure.cleanup.is_none());
    }
}

#[test]
fn smoke_structured_output_failure_redacts_capture_and_retains_cause() {
    const MARKER: &str = "synthetic-private-smoke-settings-marker";
    for phase in [SmokeCommand::Inventory, SmokeCommand::Settings] {
        let fixture = Fixture::new();
        let mut command = fixture.command("smoke", "printf '%s' \"$MARKER\" >&2; exit 23");
        command.env("MARKER", MARKER);
        let error = run_with_budget(
            &mut command,
            phase,
            Duration::from_secs(2),
            Duration::from_secs(1),
        )
        .expect_err("structured command fails");
        assert!(!format!("{error}\n{error:?}").contains(MARKER));
        let failure = error
            .downcast_ref::<CommandFailure>()
            .expect("typed structured failure");
        assert_eq!(failure.stage, phase.stage());
        assert!(matches!(failure.cause, Cause::Exit(status) if status.code() == Some(23)));
        // Captured bytes are deliberately retained, while diagnostics omit them.
        assert_eq!(failure.capture.stderr, MARKER.as_bytes());
    }
}

#[test]
fn smoke_phase_success_keeps_structured_bytes_and_streaming_modes() {
    for (phase, _, _) in phases() {
        let fixture = Fixture::new();
        let structured = matches!(phase, SmokeCommand::Inventory | SmokeCommand::Settings);
        let payload = if structured {
            " ".repeat(2 * 1024 * 1024) + r#"{"setting":"synthetic"}"#
        } else {
            String::new()
        };
        fs::write(fixture.root.path().join("payload"), &payload).expect("private command output");
        let mut command = fixture.command("smoke", "exec /bin/cat payload");
        let output = run_with_budget(
            &mut command,
            phase,
            Duration::from_secs(2),
            Duration::from_secs(1),
        )
        .expect("finite smoke command passes");
        if structured {
            assert_eq!(
                serde_json::from_slice::<serde_json::Value>(&output)
                    .expect("complete structured output"),
                serde_json::json!({"setting":"synthetic"})
            );
        } else {
            assert!(
                output.is_empty(),
                "streaming phases should not buffer output"
            );
        }
    }
}

#[derive(Debug, thiserror::Error)]
#[error("synthetic verification failure")]
struct VerificationFailure;

#[test]
fn smoke_result_verification_runs_after_every_execution_outcome() {
    for execution_fails in [false, true] {
        for verification_fails in [false, true] {
            let execution = if execution_fails {
                Err(crate::ci_smoke::erase(CommandFailure::before_spawn(
                    Stage::TestExecution,
                    Cause::Deadline {
                        elapsed: Duration::from_secs(2),
                        budget: Duration::from_secs(2),
                    },
                )))
            } else {
                Ok(())
            };
            let mut inspected = false;
            let result = finish_tests(execution, || {
                inspected = true;
                if verification_fails {
                    Err(Box::new(VerificationFailure))
                } else {
                    Ok(())
                }
            });
            assert!(
                inspected,
                "execution failure must not skip result verification"
            );
            if !execution_fails && !verification_fails {
                result.expect("both phases passed");
                continue;
            }
            let error = result.expect_err("one failed phase must reject acceptance");
            let failure = error
                .downcast_ref::<TestPhaseFailure>()
                .expect("typed paired failure");
            assert_eq!(failure.execution.is_some(), execution_fails);
            assert_eq!(failure.verification.is_some(), verification_fails);
            let source =
                std::error::Error::source(failure).expect("original primary failure chain");
            if execution_fails {
                assert!(source.downcast_ref::<CommandFailure>().is_some());
            } else {
                assert!(source.downcast_ref::<VerificationFailure>().is_some());
            }

            if let Some(error) = &failure.execution {
                let native = error
                    .downcast_ref::<CommandFailure>()
                    .expect("original native cause retained");
                assert_eq!(native.stage, Stage::TestExecution);
                assert!(matches!(native.cause, Cause::Deadline { .. }));
            }
            if let Some(error) = &failure.verification {
                assert!(
                    error.downcast_ref::<VerificationFailure>().is_some(),
                    "original verification cause retained"
                );
            }
        }
    }
}
