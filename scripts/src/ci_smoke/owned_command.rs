//! Invocation-owned Unix command boundaries for smoke and result-report tooling.
use std::{
    fs::File,
    io::{self, Read, Seek, SeekFrom, Write},
    os::unix::process::CommandExt,
    process::{Child, Command, ExitStatus, Output, Stdio},
    thread,
    time::{Duration, Instant},
};
const POLL_INTERVAL: Duration = Duration::from_millis(10);
const MAX_CAPTURE: u64 = 1024 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Stage {
    JsonInspection,
    Build,
    SimulatorBoot,
    SimulatorReadiness,
    TestResults,
    TestSummary,
    LegacyTestSummary,
}
#[derive(Debug, thiserror::Error)]
pub enum Cause {
    #[error("input preparation failed: {0}")]
    Input(#[source] io::Error),
    #[error("capture preparation failed: {0}")]
    CaptureSetup(#[source] io::Error),
    #[error("spawn failed: {0}")]
    Spawn(#[source] io::Error),
    #[error("invalid execution budget")]
    InvalidBudget,
    #[error("invalid output capture limit")]
    InvalidCaptureLimit,
    #[error("deadline after {elapsed:?}, budget {budget:?}")]
    Deadline { elapsed: Duration, budget: Duration },
    #[error("exit observation failed: {0}")]
    Poll(#[source] io::Error),
    #[error("native exit {0}")]
    Exit(ExitStatus),
    #[error("interrupted after peer failure")]
    PeerFailed,
    #[error("native cleanup failed")]
    Cleanup,
    #[error("output capture failed")]
    Capture,
}
#[derive(Default)]
pub struct Captured {
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
}
impl std::fmt::Debug for Captured {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Captured")
            .field("stdout_bytes", &self.stdout.len())
            .field("stderr_bytes", &self.stderr.len())
            .finish()
    }
}
#[derive(Debug, thiserror::Error)]
#[error(
    "{stage:?}: {cause}; cleanup={cleanup:?}; capture={capture:?}; capture_errors={capture_errors:?}"
)]
pub struct Failure {
    pub stage: Stage,
    #[source]
    pub cause: Cause,
    pub cleanup: Option<Cleanup>,
    pub capture: Captured,
    pub capture_errors: Vec<(&'static str, io::Error)>,
}
impl Failure {
    pub fn before_spawn(stage: Stage, cause: Cause) -> Box<Self> {
        Box::new(Self {
            stage,
            cause,
            cleanup: None,
            capture: Captured::default(),
            capture_errors: vec![],
        })
    }
}

#[derive(Debug)]
pub struct Cleanup {
    pub child_status: Option<ExitStatus>,
    pub group_gone: bool,
    pub signal_error: Option<io::Error>,
    pub signal_attempted: bool,
    pub group_probe_error: Option<io::Error>,
    pub poll_error: Option<io::Error>,
}
impl Cleanup {
    fn succeeded(&self) -> bool {
        self.signal_attempted
            && self.child_status.is_some()
            && self.group_gone
            && self
                .group_probe_error
                .as_ref()
                .is_none_or(|error| error.raw_os_error() == Some(libc::EPERM))
            && self.poll_error.is_none()
            && self.signal_error.as_ref().is_none_or(|error| {
                // Darwin can reject killpg for an exited-only group with
                // EPERM. Accept that only after independently reaping the
                // child AND observing group disappearance. A surviving group
                // or any other signal error remains a cleanup failure. Keep
                // the original signal result in the report for diagnostics.
                error.raw_os_error() == Some(libc::EPERM)
            })
    }
}

struct OwnedGroup {
    child: Child,
    group: i32,
    finished: bool,
    signalled: bool,
    cleanup_budget: Duration,
}
impl OwnedGroup {
    fn signal(&self, signal: i32) -> io::Result<bool> {
        // SAFETY: the child was spawned into its own process group, whose ID
        // equals its positive pid. Never signal the caller's/shared group.
        let result = unsafe { libc::kill(-self.group, signal) };
        if result == 0 {
            return Ok(true);
        }
        let error = io::Error::last_os_error();
        if error.raw_os_error() == Some(libc::ESRCH) {
            Ok(false)
        } else {
            Err(error)
        }
    }

    fn exited_without_reaping(&self) -> io::Result<bool> {
        let mut info = std::mem::MaybeUninit::<libc::siginfo_t>::zeroed();
        // SAFETY: valid writable native siginfo storage; this owner exclusively
        // owns the child. WNOWAIT pins the exited group leader's pid until the
        // group signal is issued, preventing pid/group reuse before cleanup.
        let result = unsafe {
            libc::waitid(
                libc::P_PID,
                self.child.id() as libc::id_t,
                info.as_mut_ptr(),
                libc::WEXITED | libc::WNOHANG | libc::WNOWAIT,
            )
        };
        if result != 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: waitid succeeded; storage was zero initialized for WNOHANG.
        Ok(unsafe { info.assume_init() }.si_signo == libc::SIGCHLD)
    }

    fn cleanup(&mut self, budget: Duration) -> Cleanup {
        let deadline = Instant::now() + budget;
        let mut poll_error = None;
        let mut signal_attempted = false;
        let signal_error = if self.signalled {
            None
        } else {
            self.signalled = true;
            // Reconfirm exclusive child ownership immediately before signalling.
            // If another reaper consumed the leader, never signal a reusable id.
            match self.exited_without_reaping() {
                Ok(_) => {
                    signal_attempted = true;
                    self.signal(libc::SIGKILL).err()
                }
                Err(error) => {
                    poll_error = Some(error);
                    None
                }
            }
        };
        let mut report = Cleanup {
            child_status: None,
            group_gone: false,
            signal_error,
            signal_attempted,
            group_probe_error: None,
            poll_error,
        };
        if report.poll_error.is_some() {
            return report;
        }
        loop {
            if report.child_status.is_none() {
                match self.child.try_wait() {
                    Ok(status) => report.child_status = status,
                    Err(error) => {
                        report.poll_error = Some(error);
                        break;
                    }
                }
            }
            match self.signal(0) {
                Ok(exists) => report.group_gone = !exists,
                Err(error) => {
                    let exited_only = error.raw_os_error() == Some(libc::EPERM);
                    report.group_probe_error = Some(error);
                    // A transient exited-only group is not disappearance. Keep
                    // polling for ESRCH within the original cleanup budget.
                    if !exited_only {
                        break;
                    }
                }
            }
            if report.child_status.is_some() && report.group_gone {
                break;
            }
            if !pause_until(deadline) {
                break;
            }
        }
        self.finished = report.succeeded();
        report
    }
}
impl Drop for OwnedGroup {
    fn drop(&mut self) {
        if !self.finished {
            // A bounded last attempt also covers unwinding. An explicit failed
            // cleanup is still returned as failure; it cannot become success.
            let _ = self.cleanup(self.cleanup_budget);
        }
    }
}

fn pause_until(deadline: Instant) -> bool {
    let Some(remaining) = deadline.checked_duration_since(Instant::now()) else {
        return false;
    };
    // Poll the actual child/group state; the interval is not completion proof.
    thread::sleep(remaining.min(POLL_INTERVAL));
    true
}

fn capture(file: &mut File, limit: u64) -> io::Result<Vec<u8>> {
    file.seek(SeekFrom::Start(0))?;
    let mut bytes = Vec::new();
    file.take(limit.saturating_add(1)).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > limit {
        return Err(io::Error::new(
            io::ErrorKind::FileTooLarge,
            if limit == MAX_CAPTURE {
                "test command exceeded 1 MiB capture limit".to_owned()
            } else {
                format!("test command exceeded {limit} byte capture limit")
            },
        ));
    }
    Ok(bytes)
}

/// No pipe is written after spawn. Input/capture preparation finishes first.
/// Error formatting exposes byte counts, never captured JSON or stderr payloads.
pub(super) struct Running {
    owner: OwnedGroup,
    stage: Stage,
    started: Instant,
    deadline: Instant,
    budget: Duration,
    cleanup_budget: Duration,
    captures: Option<(File, File)>,
    capture_limit: u64,
}
impl Running {
    pub fn start(
        command: &mut Command,
        stage: Stage,
        budget: Duration,
        cleanup_budget: Duration,
        input: Option<&[u8]>,
        capture_output: bool,
    ) -> Result<Self, Box<Failure>> {
        Self::start_with_capture_limit(
            command,
            stage,
            budget,
            cleanup_budget,
            input,
            capture_output,
            MAX_CAPTURE,
        )
    }

    fn start_with_capture_limit(
        command: &mut Command,
        stage: Stage,
        budget: Duration,
        cleanup_budget: Duration,
        input: Option<&[u8]>,
        capture_output: bool,
        capture_limit: u64,
    ) -> Result<Self, Box<Failure>> {
        if capture_limit == 0 || capture_limit.checked_add(1).is_none() {
            return Err(Failure::before_spawn(stage, Cause::InvalidCaptureLimit));
        }
        if budget.is_zero() {
            return Err(Failure::before_spawn(
                stage,
                Cause::Deadline {
                    elapsed: Duration::ZERO,
                    budget,
                },
            ));
        }
        let stdin = if let Some(bytes) = input {
            let mut file =
                tempfile::tempfile().map_err(|e| Failure::before_spawn(stage, Cause::Input(e)))?;
            file.write_all(bytes)
                .and_then(|_| file.seek(SeekFrom::Start(0)))
                .map_err(|e| Failure::before_spawn(stage, Cause::Input(e)))?;
            Stdio::from(file)
        } else {
            Stdio::null()
        };
        let captures = if capture_output {
            let out = tempfile::tempfile()
                .map_err(|e| Failure::before_spawn(stage, Cause::CaptureSetup(e)))?;
            let err = tempfile::tempfile()
                .map_err(|e| Failure::before_spawn(stage, Cause::CaptureSetup(e)))?;
            command
                .stdout(
                    out.try_clone()
                        .map_err(|e| Failure::before_spawn(stage, Cause::CaptureSetup(e)))?,
                )
                .stderr(
                    err.try_clone()
                        .map_err(|e| Failure::before_spawn(stage, Cause::CaptureSetup(e)))?,
                );
            Some((out, err))
        } else {
            command.stdout(Stdio::inherit()).stderr(Stdio::inherit());
            None
        };
        let started = Instant::now();
        let deadline = started
            .checked_add(budget)
            .ok_or_else(|| Failure::before_spawn(stage, Cause::InvalidBudget))?;
        let child = command
            .stdin(stdin)
            .process_group(0)
            .spawn()
            .map_err(|e| Failure::before_spawn(stage, Cause::Spawn(e)))?;
        let group = child.id() as i32;
        Ok(Self {
            owner: OwnedGroup {
                child,
                group,
                finished: false,
                signalled: false,
                cleanup_budget,
            },
            stage,
            started,
            deadline,
            budget,
            cleanup_budget,
            captures,
            capture_limit,
        })
    }
    pub fn poll(&mut self) -> Option<Result<Output, Box<Failure>>> {
        match self.owner.exited_without_reaping() {
            Ok(true) => return Some(self.finish(None)),
            Ok(false) => {}
            Err(error) => return Some(self.finish(Some(Cause::Poll(error)))),
        }
        if Instant::now() >= self.deadline {
            Some(self.finish(Some(Cause::Deadline {
                elapsed: self.started.elapsed(),
                budget: self.budget,
            })))
        } else {
            None
        }
    }
    pub fn cancel(&mut self) -> Result<Output, Box<Failure>> {
        match self.owner.exited_without_reaping() {
            Ok(true) => self.finish(None),
            Ok(false) => self.finish(Some(Cause::PeerFailed)),
            Err(error) => self.finish(Some(Cause::Poll(error))),
        }
    }
    fn finish(&mut self, mut cause: Option<Cause>) -> Result<Output, Box<Failure>> {
        let cleanup = self.owner.cleanup(self.cleanup_budget);
        if !cleanup.succeeded() && cause.is_none() {
            cause = Some(Cause::Cleanup);
        }
        let mut captured = Captured::default();
        let mut capture_errors = Vec::new();
        if let Some((out, err)) = &mut self.captures {
            match capture(out, self.capture_limit) {
                Ok(bytes) => captured.stdout = bytes,
                Err(e) => capture_errors.push(("stdout", e)),
            }
            match capture(err, self.capture_limit) {
                Ok(bytes) => captured.stderr = bytes,
                Err(e) => capture_errors.push(("stderr", e)),
            }
        }
        if !capture_errors.is_empty() && cause.is_none() {
            cause = Some(Cause::Capture);
        }
        if let Some(status) = cleanup.child_status
            && !status.success()
            && cause.is_none()
        {
            cause = Some(Cause::Exit(status));
        }
        if let Some(cause) = cause {
            return Err(Box::new(Failure {
                stage: self.stage,
                cause,
                cleanup: Some(cleanup),
                capture: captured,
                capture_errors,
            }));
        }
        match cleanup.child_status {
            Some(status) => Ok(Output {
                status,
                stdout: captured.stdout,
                stderr: captured.stderr,
            }),
            None => Err(Box::new(Failure {
                stage: self.stage,
                cause: Cause::Cleanup,
                cleanup: Some(cleanup),
                capture: captured,
                capture_errors,
            })),
        }
    }
}
pub(crate) fn run(
    command: &mut Command,
    stage: Stage,
    budget: Duration,
    cleanup: Duration,
    input: Option<&[u8]>,
) -> Result<Output, Box<Failure>> {
    run_with_capture_limit(command, stage, budget, cleanup, input, MAX_CAPTURE)
}

pub(crate) fn run_with_capture_limit(
    command: &mut Command,
    stage: Stage,
    budget: Duration,
    cleanup: Duration,
    input: Option<&[u8]>,
    capture_limit: u64,
) -> Result<Output, Box<Failure>> {
    let mut running = Running::start_with_capture_limit(
        command,
        stage,
        budget,
        cleanup,
        input,
        true,
        capture_limit,
    )?;
    loop {
        if let Some(result) = running.poll() {
            return result;
        }
        thread::sleep(POLL_INTERVAL);
    }
}
