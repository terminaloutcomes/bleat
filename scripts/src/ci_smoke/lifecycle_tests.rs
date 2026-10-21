use super::{Budgets, PreparationFailure, Result, jq_with_budget, preparation_results, prepare};
use std::{
    fs, io,
    os::unix::process::CommandExt,
    process::{Command, ExitStatus},
    sync::mpsc,
    thread,
    time::{Duration, Instant},
};

struct FixtureWorker {
    worker: Option<thread::JoinHandle<()>>,
    release: std::path::PathBuf,
}
impl FixtureWorker {
    fn join(mut self) -> thread::Result<()> {
        match self.worker.take() {
            Some(worker) => worker.join(),
            None => Ok(()),
        }
    }
}
impl Drop for FixtureWorker {
    fn drop(&mut self) {
        // Release this test's controlled fixture before joining, including an
        // assertion unwind before the normal channel/join path. No worker is
        // detached into a following case.
        let _ = fs::write(&self.release, b"release");
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

struct Fixture {
    root: tempfile::TempDir,
}
impl Fixture {
    fn new() -> Self {
        Self {
            root: tempfile::tempdir().expect("isolated runner fixture"),
        }
    }
    fn command(&self, role: &str, script: &str) -> Command {
        let mut command = Command::new("/bin/sh");
        command
            .args(["-c", &format!("printf '%s' \"$$\" > {role}.pending; /bin/mv {role}.pending {role}.pid; {script}")])
            .current_dir(self.root.path())
            .process_group(0);
        command
    }
    fn ready(&self, role: &str) -> i32 {
        let path = self.root.path().join(format!("{role}.pid"));
        let deadline = Instant::now() + Duration::from_secs(3);
        loop {
            if let Ok(text) = fs::read_to_string(&path)
                && let Ok(pid) = text.parse::<i32>()
            {
                return pid;
            }
            assert!(
                Instant::now() < deadline,
                "{role} did not enter; fixture={:?}",
                self.root.path()
            );
            thread::sleep(Duration::from_millis(10));
        }
    }
    fn release(&self) {
        fs::write(self.root.path().join("release"), b"release").expect("release owned fixtures");
    }
    fn drain_pid(&self, pid: i32) {
        let deadline = Instant::now() + Duration::from_secs(3);
        let mut status = 0;
        loop {
            // SAFETY: pid was recorded by a child spawned by this test; WNOHANG never blocks.
            let result = unsafe { libc::waitpid(pid, &mut status, libc::WNOHANG) };
            if result == pid
                || (result < 0 && io::Error::last_os_error().raw_os_error() == Some(libc::ECHILD))
            {
                return;
            }
            if Instant::now() >= deadline {
                break;
            }
            thread::sleep(Duration::from_millis(10));
        }
        // Reconfirm ownership without reaping before a signal, never target a reusable pid.
        let mut info = std::mem::MaybeUninit::<libc::siginfo_t>::zeroed();
        // SAFETY: native output storage and this test's recorded child id.
        if unsafe {
            libc::waitid(
                libc::P_PID,
                pid as libc::id_t,
                info.as_mut_ptr(),
                libc::WEXITED | libc::WNOHANG | libc::WNOWAIT,
            )
        } == 0
        {
            // SAFETY: still-owned invocation process group, not any shared service/device.
            unsafe { libc::kill(-pid, libc::SIGKILL) };
            let deadline = Instant::now() + Duration::from_secs(3);
            while Instant::now() < deadline {
                // SAFETY: nonblocking reap of the owned child.
                if unsafe { libc::waitpid(pid, &mut status, libc::WNOHANG) } != 0 {
                    return;
                }
                thread::sleep(Duration::from_millis(10));
            }
        }
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::write(self.root.path().join("release"), b"release");
        if let Ok(files) = fs::read_dir(self.root.path()) {
            for file in files.flatten() {
                if file.path().extension().is_some_and(|e| e == "pid")
                    && let Ok(text) = fs::read_to_string(file.path())
                    && let Ok(pid) = text.parse::<i32>()
                {
                    self.drain_pid(pid);
                }
            }
        }
    }
}
fn alive(pid: i32) -> bool {
    // SAFETY: signal0 probes only; no signal is delivered.
    unsafe { libc::kill(pid, 0) == 0 }
}
fn held() -> &'static str {
    "while [ ! -f release ]; do /bin/sleep 0.01; done"
}
fn budgets() -> Budgets {
    Budgets {
        boot: Duration::from_secs(2),
        build: Duration::from_secs(5),
        cleanup: Duration::from_secs(1),
    }
}

#[test]
fn stdin_write_failure_retires_started_child() {
    let fixture = Fixture::new();
    let mut command = fixture.command("jq", &format!("exec 0<&-; {}; printf done", held()));
    let result = jq_with_budget(
        &vec![b'x'; 1024 * 1024],
        &mut command,
        Duration::from_secs(2),
        Duration::from_secs(1),
    );
    let pid = fixture.ready("jq");
    let still_alive = alive(pid);
    let original_kind = result
        .as_ref()
        .err()
        .and_then(|e| e.downcast_ref::<io::Error>())
        .map(io::Error::kind);
    fixture.release();
    fixture.drain_pid(pid);
    eprintln!("input failure kind={original_kind:?}; child_alive_at_return={still_alive}");
    assert!(result.is_err(), "held closed-input fixture must fail");
    assert!(
        !still_alive,
        "runner returned before retiring the started jq child"
    );
    let failure = result
        .as_ref()
        .expect_err("closed-input held command fails")
        .downcast_ref::<super::CommandFailure>()
        .expect("typed native failure");
    assert_eq!(failure.stage, super::Stage::JsonInspection);
    assert!(matches!(failure.cause, super::Cause::Deadline { .. }));
    assert!(failure.cleanup.as_ref().expect("cleanup report").group_gone);
}

#[test]
fn held_boot_returns_within_preparation_budget() {
    let fixture = Fixture::new();
    let mut build = fixture.command(
        "build",
        "while [ ! -f boot.pid ]; do /bin/sleep 0.01; done; exit 0",
    );
    let ready = fixture.command("boot", held());
    let (tx, rx) = mpsc::channel();
    let worker = thread::spawn(move || {
        let result = prepare(&mut build, None, ready, budgets());
        tx.send(result).expect("deliver preparation outcome");
    });
    let worker = FixtureWorker {
        worker: Some(worker),
        release: fixture.root.path().join("release"),
    };
    fixture.ready("boot");
    fixture.ready("build");
    let early = rx.recv_timeout(Duration::from_secs(5));
    let returned_within_budget = early.is_ok();
    fixture.release();
    let result = early.unwrap_or_else(|_| {
        rx.recv_timeout(Duration::from_secs(3))
            .expect("released legacy worker drains")
    });
    worker.join().expect("owned worker joined");
    eprintln!("returned_within_failure_observation={returned_within_budget}; outcome={result:?}");
    assert!(
        returned_within_budget,
        "held boot prevented bounded preparation return"
    );
    assert!(
        result.is_err(),
        "held boot must produce a failure instead of success"
    );
    let error = result.expect_err("readiness deadline");
    let boot = command_cause(error.as_ref(), false);
    assert_eq!(boot.stage, super::Stage::SimulatorReadiness);
    assert!(matches!(boot.cause, super::Cause::Deadline { .. }));
    assert!(boot.cleanup.as_ref().expect("cleanup report").group_gone);
}

#[derive(Debug, thiserror::Error)]
#[error("native fixture exit {0}")]
struct FixtureExit(ExitStatus);
fn failed(code: i32) -> Result<()> {
    let status = Command::new("/bin/sh")
        .args(["-c", &format!("exit {code}")])
        .status()
        .expect("native exit fixture");
    assert_eq!(status.code(), Some(code));
    Err(Box::new(FixtureExit(status)))
}

#[test]
fn preparation_retains_both_native_failures() {
    let error = preparation_results(failed(17), failed(23)).expect_err("both native stages failed");
    let combined = error
        .downcast_ref::<PreparationFailure>()
        .expect("both stages need a structured combined failure");
    assert_eq!(
        combined
            .build
            .as_ref()
            .expect("build failure")
            .downcast_ref::<FixtureExit>()
            .expect("original native build cause")
            .0
            .code(),
        Some(17)
    );
    assert_eq!(
        combined
            .boot
            .as_ref()
            .expect("boot failure")
            .downcast_ref::<FixtureExit>()
            .expect("original native boot cause")
            .0
            .code(),
        Some(23)
    );
}

fn command_cause<'a>(
    error: &'a (dyn std::error::Error + Send + Sync + 'static),
    build: bool,
) -> &'a super::CommandFailure {
    let preparation = error
        .downcast_ref::<PreparationFailure>()
        .expect("typed preparation failure");
    let side = if build {
        &preparation.build
    } else {
        &preparation.boot
    };
    side.as_ref()
        .expect("specific stage failed")
        .downcast_ref::<super::CommandFailure>()
        .expect("original typed command cause")
}

#[test]
fn completed_peer_retains_native_failure_instead_of_cancellation() {
    let fixture = Fixture::new();
    let mut command = fixture.command("peer", "exit 17");
    let mut running = super::Running::start(
        &mut command,
        super::Stage::Build,
        Duration::from_secs(2),
        Duration::from_secs(1),
        None,
        false,
    )
    .expect("spawn owned peer");
    let pid = fixture.ready("peer");
    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        let mut info = std::mem::MaybeUninit::<libc::siginfo_t>::zeroed();
        // SAFETY: observe the invocation's child without consuming its status.
        assert_eq!(
            unsafe {
                libc::waitid(
                    libc::P_PID,
                    pid as libc::id_t,
                    info.as_mut_ptr(),
                    libc::WEXITED | libc::WNOHANG | libc::WNOWAIT,
                )
            },
            0
        );
        // SAFETY: successful native call into zero-initialized native storage.
        if unsafe { info.assume_init() }.si_signo == libc::SIGCHLD {
            break;
        }
        assert!(Instant::now() < deadline, "peer did not exit");
        thread::sleep(Duration::from_millis(10));
    }
    let error = running.cancel().expect_err("completed peer already failed");
    assert!(matches!(error.cause,super::Cause::Exit(status) if status.code()==Some(17)));
    let cleanup = error.cleanup.expect("cleanup report");
    assert!(cleanup.child_status.is_some() && cleanup.group_gone);
}

#[test]
fn dropping_owner_retires_the_started_wrapper() {
    let fixture = Fixture::new();
    let mut command = fixture.command("drop", held());
    let running = super::Running::start(
        &mut command,
        super::Stage::JsonInspection,
        Duration::from_secs(2),
        Duration::from_secs(1),
        None,
        true,
    )
    .expect("owned command");
    let pid = fixture.ready("drop");
    assert!(alive(pid));
    drop(running);
    assert!(!alive(pid), "scope exit must retire its native child");
}

#[test]
fn captured_payload_is_retained_without_error_format_disclosure() {
    let fixture = Fixture::new();
    let marker = "synthetic-private-runner-marker";
    let mut command = fixture.command(
        "private",
        &format!("printf {marker};printf {marker} >&2;exit 17"),
    );
    let error = jq_with_budget(
        b"synthetic-private-input",
        &mut command,
        Duration::from_secs(2),
        Duration::from_secs(1),
    )
    .expect_err("native failure");
    let failure = error
        .downcast_ref::<super::CommandFailure>()
        .expect("typed command error");
    assert!(matches!(failure.cause,super::Cause::Exit(status) if status.code()==Some(17)));
    assert_eq!(failure.capture.stdout, marker.as_bytes());
    assert_eq!(failure.capture.stderr, marker.as_bytes());
    assert!(!format!("{error}").contains(marker));
    assert!(!format!("{error:?}").contains(marker));
    assert!(!format!("{error}").contains("synthetic-private-input"));
    let mut invalid = fixture.command("invalid", &format!("printf '\\377{marker}'"));
    let error = jq_with_budget(
        b"synthetic-private-input",
        &mut invalid,
        Duration::from_secs(2),
        Duration::from_secs(1),
    )
    .expect_err("malformed UTF8 output");
    let cause = error
        .downcast_ref::<super::OutputDecodeFailure>()
        .expect("typed byte-free UTF8 cause");
    assert_eq!(cause.0.valid_up_to(), 0);
    assert_eq!(cause.0.error_len(), Some(1));
    assert!(!format!("{error}").contains(marker));
    assert!(!format!("{error:?}").contains(marker));
}

#[test]
fn build_failure_retires_held_readiness_and_keeps_both_causes() {
    let fixture = Fixture::new();
    let mut build = fixture.command(
        "build",
        "while [ ! -f ready.pid ]; do /bin/sleep 0.01; done;exit 17",
    );
    let ready = fixture.command("ready", held());
    let error =
        prepare(&mut build, None, ready, budgets()).expect_err("build failed while readiness held");
    let build = command_cause(error.as_ref(), true);
    assert!(matches!(build.cause,super::Cause::Exit(status) if status.code()==Some(17)));
    let boot = command_cause(error.as_ref(), false);
    assert!(matches!(boot.cause, super::Cause::PeerFailed));
    assert!(boot.cleanup.as_ref().expect("cancel cleanup").group_gone);
    assert!(!alive(fixture.ready("ready")));
    assert!(!alive(fixture.ready("build")));
}

#[test]
fn readiness_failure_retires_held_build_and_keeps_both_causes() {
    let fixture = Fixture::new();
    let mut build = fixture.command("build", held());
    let ready = fixture.command(
        "ready",
        "while [ ! -f build.pid ]; do /bin/sleep 0.01; done;exit 23",
    );
    let error =
        prepare(&mut build, None, ready, budgets()).expect_err("readiness failed while build held");
    let boot = command_cause(error.as_ref(), false);
    assert!(matches!(boot.cause,super::Cause::Exit(status) if status.code()==Some(23)));
    let build = command_cause(error.as_ref(), true);
    assert!(matches!(build.cause, super::Cause::PeerFailed));
    assert!(build.cleanup.as_ref().expect("cancel cleanup").group_gone);
    assert!(!alive(fixture.ready("ready")));
    assert!(!alive(fixture.ready("build")));
}

#[test]
fn boot_then_readiness_preserves_success_and_reaps_wrappers() {
    let fixture = Fixture::new();
    let mut build = fixture.command(
        "build",
        "while [ ! -f ready.pid ]; do /bin/sleep 0.01; done;exit 0",
    );
    let boot = fixture.command("boot", "exit 0");
    let ready = fixture.command("ready", "test -f boot.pid");
    prepare(&mut build, Some(boot), ready, budgets()).expect("both preparation phases succeed");
    for role in ["build", "boot", "ready"] {
        assert!(!alive(fixture.ready(role)), "{role} wrapper remains alive");
    }
}

#[test]
fn exhausted_boot_budget_does_not_start_readiness() {
    let fixture = Fixture::new();
    let mut build = fixture.command("build", "exit 0");
    let ready = fixture.command("ready", "exit 0");
    let error = prepare(
        &mut build,
        None,
        ready,
        Budgets {
            boot: Duration::ZERO,
            ..budgets()
        },
    )
    .expect_err("no readiness budget");
    let boot = command_cause(error.as_ref(), false);
    assert!(matches!(
        boot.cause,
        super::Cause::Deadline {
            budget: Duration::ZERO,
            ..
        }
    ));
    assert!(boot.cleanup.is_none());
    assert!(
        !fixture.root.path().join("ready.pid").exists(),
        "expired phase must not start a command"
    );
}

#[test]
fn fixture_supervisor_releases_and_joins_on_assertion_unwind() {
    let fixture = Fixture::new();
    let mut build = fixture.command(
        "build",
        "while [ ! -f boot.pid ]; do /bin/sleep 0.01; done;exit 0",
    );
    let ready = fixture.command("boot", held());
    let (tx, rx) = mpsc::channel();
    let worker = thread::spawn(move || {
        let result = prepare(&mut build, None, ready, budgets());
        let _ = tx.send(result);
    });
    let worker = FixtureWorker {
        worker: Some(worker),
        release: fixture.root.path().join("release"),
    };
    let boot = fixture.ready("boot");
    let build = fixture.ready("build");
    let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(move || {
        let _worker = worker;
        panic!("intentional fixture assertion unwind");
    }));
    assert!(outcome.is_err());
    assert!(
        rx.try_recv().is_ok(),
        "worker outcome delivered before scope cleanup completed"
    );
    assert!(!alive(boot));
    assert!(!alive(build));
}

#[path = "report_tests.rs"]
mod report_tests;

#[path = "smoke_command_tests.rs"]
mod smoke_command_tests;

#[path = "swiftpm_command_tests.rs"]
mod swiftpm_command_tests;
