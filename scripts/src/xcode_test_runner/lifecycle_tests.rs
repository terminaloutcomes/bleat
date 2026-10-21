use super::{
    NativeBudgets, NativeRole, TestGateRequest, XcodeAction, XcodeBuildConfig, XcodeRunnerError,
    commands::{native_command_status, status_from_outcome},
    ensure_success, run_test_gate_with_budgets,
};
use crate::{
    ci_smoke::{
        lifecycle_tests::{Fixture, FixtureWorker, alive, held},
        owned_command::{Cause, Failure, Stage},
    },
    test_results::{TestId, VerifyError, verify_result_json},
};
use std::{
    fs,
    os::unix::{fs::PermissionsExt, process::ExitStatusExt},
    path::PathBuf,
    process::{Command, ExitStatus},
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
        mpsc,
    },
    thread,
    time::Duration,
};

fn roles() -> [(NativeRole, Stage, u64); 7] {
    [
        (NativeRole::SwiftRelease, Stage::SwiftReleaseBuild, 2400),
        (
            NativeRole::ReleaseVersionTests,
            Stage::ReleaseVersionTests,
            1200,
        ),
        (
            NativeRole::PackageResolution,
            Stage::PackageResolution,
            1200,
        ),
        (
            NativeRole::SimulatorBuild,
            Stage::SimulatorReleaseBuild,
            2400,
        ),
        (
            NativeRole::BuildForTesting,
            Stage::XcodeBuildForTesting,
            2400,
        ),
        (NativeRole::Enumeration, Stage::XcodeTestEnumeration, 300),
        (NativeRole::Execution, Stage::XcodeTestExecution, 3600),
    ]
}
fn budgets() -> NativeBudgets {
    NativeBudgets {
        command: Some(Duration::from_secs(2)),
        cleanup: Duration::from_secs(1),
    }
}

#[test]
fn direct_native_roles_preserve_policy_status_and_original_spawn_causes() {
    for (role, stage, seconds) in roles() {
        assert_eq!(role.stage(), stage);
        assert_eq!(role.budget(), Duration::from_secs(seconds));
        let fixture = Fixture::new();
        for code in [0, 23] {
            let mut command = fixture.command("native", &format!("exit {code}"));
            let status =
                native_command_status(&mut command, role, "synthetic native gate", budgets())
                    .expect("observed and retired native exit remains a status");
            assert_eq!(status.code(), Some(code));
            if code == 0 {
                ensure_success(status, "synthetic native gate").expect("zero native status passes");
            } else {
                assert!(
                    matches!(ensure_success(status, "synthetic native gate"),Err(XcodeRunnerError::CommandFailed{status,..}) if status.code()==Some(23))
                );
            }
        }
        let mut command = Command::new(fixture.root.path().join("absent-native-tool"));
        let error = native_command_status(&mut command, role, "synthetic native gate", budgets())
            .expect_err("missing tool fails");
        let XcodeRunnerError::NativeCommand {
            stage: label,
            source,
        } = error
        else {
            panic!("missing typed native command boundary")
        };
        assert_eq!(label, "synthetic native gate");
        assert_eq!(source.stage, stage);
        assert!(
            matches!(&source.cause,Cause::Spawn(error) if error.kind()==std::io::ErrorKind::NotFound)
        );
        assert!(source.cleanup.is_none());
    }
    assert_eq!(
        XcodeAction::ResolvePackages.argument(),
        "-resolvePackageDependencies"
    );
    assert_eq!(
        XcodeAction::ResolvePackages.role().stage(),
        Stage::PackageResolution
    );
    assert_eq!(XcodeAction::Build.argument(), "build");
    assert_eq!(
        XcodeAction::Build.role().stage(),
        Stage::SimulatorReleaseBuild
    );
}

#[test]
fn direct_native_deadlines_reap_all_admitted_roles() {
    for (role, stage, _) in roles() {
        let fixture = Fixture::new();
        let mut command = fixture.command("native", held());
        let (tx, rx) = mpsc::channel();
        let worker = thread::spawn(move || {
            tx.send(native_command_status(
                &mut command,
                role,
                "held native gate",
                budgets(),
            ))
            .expect("deliver native gate outcome");
        });
        let worker = FixtureWorker {
            worker: Some(worker),
            release: fixture.root.path().join("release"),
        };
        let pid = fixture.ready("native");
        let early = rx.recv_timeout(Duration::from_secs(5));
        let bounded = early.is_ok();
        fixture.release();
        let result = early.unwrap_or_else(|_| {
            rx.recv_timeout(Duration::from_secs(3))
                .expect("released fixture drains")
        });
        worker.join().expect("owned native worker joined");
        fixture.drain_pid(pid);
        assert!(
            bounded,
            "admitted native phase exceeded independent observation bound"
        );
        let error = result.expect_err("held native phase must fail");
        let XcodeRunnerError::NativeCommand { source, .. } = error else {
            panic!("missing typed native deadline")
        };
        assert_eq!(source.stage, stage);
        assert!(
            matches!(source.cause,Cause::Deadline{elapsed,budget} if budget==Duration::from_secs(2) && elapsed>=budget)
        );
        let cleanup = source.cleanup.as_ref().expect("cleanup record");
        assert!(cleanup.signal_attempted && cleanup.child_status.is_some() && cleanup.group_gone);
        assert!(!alive(pid), "admitted native child survived cleanup");
    }
}

#[test]
fn direct_native_status_never_hides_unconfirmed_cleanup() {
    // A fabricated exit without retirement evidence must not masquerade as a
    // successfully observed status. Real nonzero exits are exercised above.
    for cause in [Cause::Exit(ExitStatus::from_raw(0)), Cause::Cleanup] {
        let error = status_from_outcome(
            Err(Failure::before_spawn(Stage::XcodeTestExecution, cause)),
            "unconfirmed native gate",
        )
        .expect_err("missing retirement is a typed failure");
        let XcodeRunnerError::NativeCommand { source, .. } = error else {
            panic!("lost original native failure")
        };
        assert_eq!(source.stage, Stage::XcodeTestExecution);
        assert!(source.cleanup.is_none());
        assert!(matches!(source.cause, Cause::Exit(_) | Cause::Cleanup));
    }
}

#[derive(Clone, Copy, Debug)]
enum Execution {
    Nonzero,
    Missing,
    Held,
}

#[test]
fn direct_xcode_gate_audits_after_exit_spawn_and_deadline_failures() {
    const RESULTS: &str = r#"{"testNodes":[{"nodeType":"Test Case","nodeIdentifierURL":"test://com.apple.xcode/Target/Suite/testExpected","name":"expected","result":"Passed","children":[]}]}"#;
    for execution in [Execution::Nonzero, Execution::Missing, Execution::Held] {
        for rejected in [false, true] {
            let fixture = Fixture::new();
            let root = fixture.root.path().to_path_buf();
            let tool = root.join("xcodebuild");
            let retire = if matches!(execution, Execution::Missing) {
                "/bin/mv \"$0\" \"$0.retired\""
            } else {
                "true"
            };
            let execute = match execution {
                Execution::Nonzero => "exit 23".to_owned(),
                Execution::Missing => "exit 31".to_owned(),
                Execution::Held => format!(
                    "printf '%s' \"$$\" > execution.pending; /bin/mv execution.pending execution.pid; {}",
                    held()
                ),
            };
            let script = format!(
                "#!/bin/sh\nset -eu\ncase \" $* \" in\n *\" -enumerate-tests \"*) cat > .build/native.discovery.json <<'JSON'\n{{\"errors\":[],\"values\":[{{\"enabledTests\":[{{\"identifier\":\"Target/Suite/testExpected()\"}}],\"disabledTests\":[]}}]}}\nJSON\n {retire} ;;\n *\" build-for-testing \"*) exit 0 ;;\n *\" test-without-building \"*) {execute} ;;\n *) exit 31 ;;\nesac\n"
            );
            fs::write(&tool, script).expect("write private Xcode fixture");
            fs::set_permissions(&tool, fs::Permissions::from_mode(0o755))
                .expect("native fixture executable");
            let audited = Arc::new(AtomicBool::new(false));
            let observed = audited.clone();
            let (tx, rx) = mpsc::channel();
            let worker = thread::spawn(move || {
                let verify = move |_: &std::path::Path,
                                   expected: &[crate::test_results::ExpectedTest],
                                   allowed: &[TestId]| {
                    observed.store(true, Ordering::SeqCst);
                    assert_eq!(expected.len(), 1);
                    assert!(allowed.is_empty());
                    verify_result_json(
                        if rejected {
                            r#"{"testNodes":[]}"#
                        } else {
                            RESULTS
                        },
                        expected,
                        allowed,
                    )
                };
                let result = run_test_gate_with_budgets(
                    &root,
                    TestGateRequest {
                        build: XcodeBuildConfig::new(
                            "Bleat",
                            None,
                            "platform=iOS Simulator,id=synthetic",
                            ".build/derived",
                            vec![],
                            false,
                        ),
                        only: vec![],
                        exclude: vec![],
                        allowed_skip_selectors: vec![],
                        enable_code_coverage: false,
                        runner_environment: vec![],
                        result_bundle: PathBuf::from(".build/native.xcresult"),
                        stage: "synthetic Xcode gate".to_owned(),
                    },
                    &tool,
                    &verify,
                    budgets(),
                );
                tx.send(result).expect("deliver Xcode gate outcome");
            });
            let worker = FixtureWorker {
                worker: Some(worker),
                release: fixture.root.path().join("release"),
            };
            let pid = if matches!(execution, Execution::Held) {
                Some(fixture.ready("execution"))
            } else {
                None
            };
            let early = rx.recv_timeout(Duration::from_secs(5));
            let bounded = early.is_ok();
            fixture.release();
            let result = early.unwrap_or_else(|_| {
                rx.recv_timeout(Duration::from_secs(3))
                    .expect("released Xcode gate drains")
            });
            worker.join().expect("owned Xcode fixture worker joined");
            if let Some(pid) = pid {
                fixture.drain_pid(pid);
                assert!(!alive(pid));
            }
            assert!(bounded, "Xcode gate outlived independent observation bound");
            assert!(
                audited.load(Ordering::SeqCst),
                "native failure skipped exact result verification"
            );
            let error =
                result.expect_err("native failure prevents acceptance even if verifier passed");
            match (execution, rejected, error) {
                (Execution::Nonzero, false, XcodeRunnerError::CommandFailed { status, .. }) => {
                    assert_eq!(status.code(), Some(23))
                }
                (
                    Execution::Nonzero,
                    true,
                    XcodeRunnerError::TestAndVerificationFailed {
                        status,
                        verification,
                        ..
                    },
                ) => {
                    assert_eq!(status.code(), Some(23));
                    assert!(matches!(
                        *verification,
                        XcodeRunnerError::Verification(VerifyError::MissingTest(_))
                    ));
                }
                (kind, rejected, error) => {
                    let native = if rejected {
                        let XcodeRunnerError::TestStartAndVerificationFailed {
                            command,
                            verification,
                            ..
                        } = error
                        else {
                            panic!("missing combined native and verification causes")
                        };
                        assert!(matches!(
                            *verification,
                            XcodeRunnerError::Verification(VerifyError::MissingTest(_))
                        ));
                        *command
                    } else {
                        error
                    };
                    let XcodeRunnerError::NativeCommand { source, .. } = native else {
                        panic!("missing typed native source")
                    };
                    assert_eq!(source.stage, Stage::XcodeTestExecution);
                    match kind {
                        Execution::Missing => {
                            assert!(
                                matches!(&source.cause,Cause::Spawn(error) if error.kind()==std::io::ErrorKind::NotFound)
                            );
                            assert!(source.cleanup.is_none());
                        }
                        Execution::Held => {
                            assert!(matches!(source.cause, Cause::Deadline { .. }));
                            let cleanup = source.cleanup.as_ref().expect("cleanup report");
                            assert!(cleanup.group_gone && cleanup.child_status.is_some());
                        }
                        Execution::Nonzero => panic!("native nonzero exit status was lost"),
                    }
                }
            }
        }
    }
}

#[test]
fn existing_result_bundle_guard_uses_repository_root_for_relative_and_absolute_paths() {
    // This process stays in its normal working directory. The isolated root
    // models a CLI invocation from another directory without global chdir.
    for absolute in [true, false] {
        let fixture = Fixture::new();
        let root = fixture.root.path();
        let relative = PathBuf::from(".build/preserved.xcresult");
        let retained = root.join(&relative);
        fs::create_dir_all(&retained).expect("existing private result bundle");
        let sentinel = retained.join("synthetic-result-bytes");
        fs::write(&sentinel, b"existing synthetic result").expect("retained opaque result");
        let tool = root.join("xcodebuild");
        fs::write(
            &tool,
            "#!/bin/sh\nprintf called > native-was-called\nexit 31\n",
        )
        .expect("private native canary");
        fs::set_permissions(&tool, fs::Permissions::from_mode(0o755)).expect("executable canary");
        let request = TestGateRequest {
            build: XcodeBuildConfig::new(
                "Bleat",
                None,
                "platform=iOS Simulator,id=synthetic",
                ".build/derived",
                vec![],
                false,
            ),
            only: vec![],
            exclude: vec![],
            allowed_skip_selectors: vec![],
            enable_code_coverage: false,
            runner_environment: vec![],
            result_bundle: if absolute { retained.clone() } else { relative },
            stage: "existing result guard".to_owned(),
        };
        let verifier =
            |_: &std::path::Path, _: &[crate::test_results::ExpectedTest], _: &[TestId]| {
                panic!("Existing result guard must reject before invoking verification")
            };
        let error = run_test_gate_with_budgets(root, request, &tool, &verifier, budgets())
            .expect_err("existing result must be rejected before native execution");
        assert!(
            matches!(error, XcodeRunnerError::ExistingResultBundle { path } if path == retained)
        );
        assert!(
            !root.join("native-was-called").exists(),
            "guard invoked the native tool before rejecting existing results"
        );
        // Exact bytes deliberately prove retention of an opaque artifact.
        assert_eq!(
            fs::read(sentinel).expect("retained result remains readable"),
            b"existing synthetic result"
        );
    }
}
