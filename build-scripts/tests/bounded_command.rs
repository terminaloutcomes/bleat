#![cfg(unix)]
#[path = "support/bounded_command.rs"]
mod bounded_command;

use bounded_command::{Cause, run};
use std::{
    fs, io,
    os::unix::process::ExitStatusExt,
    process::Command,
    time::{Duration, Instant},
};

const BUDGET: Duration = Duration::from_secs(2);

#[test]
fn captures_success_and_nonzero_exit_after_cleanup() {
    for code in [0, 17] {
        let output = run(
            Command::new("/bin/sh").args([
                "-c",
                &format!("printf stdout-marker; printf stderr-marker >&2; exit {code}"),
            ]),
            BUDGET,
        )
        .expect("command and cleanup complete");
        assert_eq!(output.status.code(), Some(code));
        assert_eq!(output.stdout, b"stdout-marker");
        assert_eq!(output.stderr, b"stderr-marker");
    }
}

#[test]
fn spawn_failure_retains_io_cause_without_a_child() {
    let fixture = tempfile::tempdir().expect("fixture");
    let failure = run(
        &mut Command::new(fixture.path().join("missing-command")),
        BUDGET,
    )
    .expect_err("missing executable");
    assert!(
        matches!(failure.cause, Cause::Spawn(ref error) if error.kind() == io::ErrorKind::NotFound)
    );
    assert!(failure.cleanup.is_none());
    assert!(failure.stdout.is_empty() && failure.stderr.is_empty());
}

#[test]
fn deadline_reaps_child_and_preserves_ready_diagnostics() {
    let fixture = tempfile::tempdir().expect("fixture");
    let started = Instant::now();
    let failure = run(Command::new("/bin/sh").args(["-c", "printf ready > ready; printf stdout-ready; printf stderr-ready >&2; exec /bin/sleep 60"]).current_dir(fixture.path()), BUDGET).expect_err("held child hits failure budget");
    assert_eq!(
        fs::read(fixture.path().join("ready")).expect("child entered"),
        b"ready"
    );
    assert!(matches!(
        failure.cause,
        Cause::Deadline { budget: BUDGET, .. }
    ));
    let cleanup = failure.cleanup.expect("spawned child has cleanup report");
    assert_eq!(
        cleanup.child_status.expect("direct child reaped").signal(),
        Some(9)
    );
    assert!(cleanup.group_gone && cleanup.signal_error.is_none() && cleanup.poll_error.is_none());
    assert_eq!(failure.stdout, b"stdout-ready");
    assert_eq!(failure.stderr, b"stderr-ready");
    assert!(
        started.elapsed() < Duration::from_secs(10),
        "execution and cleanup remain bounded"
    );
}

#[test]
fn descendant_output_holder_is_retired_after_parent_exit() {
    let fixture = tempfile::tempdir().expect("fixture");
    let output = run(
        Command::new("/bin/sh")
            .args([
                "-c",
                "/bin/sleep 60 & printf '%s' \"$!\" > descendant; printf parent-complete",
            ])
            .current_dir(fixture.path()),
        BUDGET,
    )
    .expect("parent exit also retires its descendant");
    assert!(output.status.success());
    assert_eq!(output.stdout, b"parent-complete");
    let pid = fs::read_to_string(fixture.path().join("descendant")).expect("descendant spawned");
    assert!(pid.parse::<u32>().expect("owned child pid") > 1);
    // Successful helper return requires both direct-child reaping and process
    // group disappearance, even though the descendant held the output file.
}

#[test]
fn deadline_retires_descendants_with_the_parent() {
    let fixture = tempfile::tempdir().expect("fixture");
    let failure = run(Command::new("/bin/sh").args(["-c", "trap '' TERM; /bin/sleep 60 & printf '%s' \"$!\" > descendant; printf group-ready; wait"]).current_dir(fixture.path()), BUDGET).expect_err("held group hits failure budget");
    assert!(matches!(failure.cause, Cause::Deadline { .. }));
    assert!(
        fs::read_to_string(fixture.path().join("descendant"))
            .expect("descendant spawned")
            .parse::<u32>()
            .expect("pid")
            > 1
    );
    let cleanup = failure.cleanup.expect("cleanup report");
    assert!(cleanup.child_status.is_some() && cleanup.group_gone);
    assert!(cleanup.signal_error.is_none() && cleanup.poll_error.is_none());
    assert_eq!(failure.stdout, b"group-ready");
}

#[test]
fn normal_exit_is_observed_before_reaping_group_leader() {
    let pid = std::cell::Cell::new(0);
    let output = bounded_command::run_observing_exit(
        Command::new("/bin/sh").args(["-c", "exit 0"]),
        BUDGET,
        |child| {
            pid.set(child as i32);
            // SAFETY: signal0 only probes the child owned by this invocation.
            assert_eq!(
                unsafe { libc::kill(child as i32, 0) },
                0,
                "exited leader remains pinned until group cleanup"
            );
            // SAFETY: the non-signalling probe targets this still-pinned group.
            if unsafe { libc::kill(-(child as i32), 0) } != 0 {
                assert_eq!(
                    io::Error::last_os_error().raw_os_error(),
                    Some(libc::EPERM),
                    "only the exited-only group signal boundary is permitted"
                );
            }
        },
    )
    .expect("normal exit and cleanup");
    assert!(output.status.success());
    // SAFETY: signal0 probes identity without delivering a signal.
    assert_eq!(unsafe { libc::kill(pid.get(), 0) }, -1);
    assert_eq!(io::Error::last_os_error().raw_os_error(), Some(libc::ESRCH));
    let failure = bounded_command::run_observing_exit(
        Command::new("/bin/sh").args(["-c", "exit 0"]),
        BUDGET,
        |child| {
            let mut status = 0;
            // SAFETY: deliberately consume this invocation's already-exited
            // child to reproduce an unexpected external reaper boundary.
            assert_eq!(
                unsafe { libc::waitpid(child as i32, &mut status, libc::WNOHANG) },
                child as i32
            );
        },
    )
    .expect_err("lost ownership must fail without signalling a reusable id");
    assert!(matches!(failure.cause, Cause::Cleanup));
    let cleanup = failure.cleanup.expect("ownership failure report");
    assert!(!cleanup.signal_attempted);
    assert_eq!(
        cleanup
            .poll_error
            .expect("lost-child native cause")
            .raw_os_error(),
        Some(libc::ECHILD)
    );
}

#[test]
fn unwinding_after_exit_observation_retires_the_owned_group() {
    let group = std::cell::Cell::new(0);
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let _ = bounded_command::run_observing_exit(
            Command::new("/bin/sh").args(["-c", "/bin/sleep 60 & exit 0"]),
            BUDGET,
            |pid| {
                group.set(pid as i32);
                panic!("intentional owned-observer unwind");
            },
        );
    }));
    assert!(result.is_err());
    assert!(group.get() > 1);
    // SAFETY: signal0 probes the invocation's recorded group; it never signals.
    assert_eq!(unsafe { libc::kill(-group.get(), 0) }, -1);
    assert_eq!(io::Error::last_os_error().raw_os_error(), Some(libc::ESRCH));
    // SAFETY: same non-signalling probe for the direct child after Drop cleanup.
    assert_eq!(unsafe { libc::kill(group.get(), 0) }, -1);
    assert_eq!(io::Error::last_os_error().raw_os_error(), Some(libc::ESRCH));
}

#[test]
fn oversized_capture_reports_failure_after_group_cleanup() {
    let failure = run(
        Command::new("/bin/sh").args(["-c", "/bin/sleep 60 & /usr/bin/head -c 1048577 /dev/zero"]),
        BUDGET,
    )
    .expect_err("capture limit must fail");
    assert!(matches!(failure.cause, Cause::Capture), "{failure:?}");
    assert_eq!(failure.capture_errors.len(), 1);
    assert_eq!(failure.capture_errors[0].0, "stdout");
    assert_eq!(
        failure.capture_errors[0].1.kind(),
        io::ErrorKind::FileTooLarge
    );
    let cleanup = failure.cleanup.expect("cleanup report");
    assert!(cleanup.child_status.is_some() && cleanup.group_gone);
    assert!(cleanup.signal_error.is_none() && cleanup.poll_error.is_none());
}
