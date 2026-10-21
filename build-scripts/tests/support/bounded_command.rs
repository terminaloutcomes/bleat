//! Test-only Unix command ownership. Output is captured in anonymous regular
//! files, not pipes whose EOF can be retained by a descendant.
use std::{
    fs::File,
    io::{self, Read, Seek, SeekFrom},
    os::unix::process::CommandExt,
    process::{Child, Command, ExitStatus, Output, Stdio},
    thread,
    time::{Duration, Instant},
};

const CLEANUP_BUDGET: Duration = Duration::from_secs(3);
const POLL_INTERVAL: Duration = Duration::from_millis(10);
const MAX_CAPTURE: u64 = 1024 * 1024;

#[derive(Debug, thiserror::Error)]
pub enum Cause {
    #[error("capture setup failed: {0}")]
    Setup(io::Error),
    #[error("spawn failed: {0}")]
    Spawn(io::Error),
    #[error("command deadline after {elapsed:?}; budget {budget:?}")]
    Deadline { elapsed: Duration, budget: Duration },
    #[error("observing child exit failed: {0}")]
    Poll(io::Error),
    #[error("process group cleanup did not complete")]
    Cleanup,
    #[error("output capture failed")]
    Capture,
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

#[derive(Debug, thiserror::Error)]
#[error(
    "{cause}; cleanup={cleanup:?}; capture_errors={capture_errors:?}; stdout={stdout:?}; stderr={stderr:?}"
)]
pub struct Failure {
    pub cause: Cause,
    pub cleanup: Option<Cleanup>,
    pub capture_errors: Vec<(&'static str, io::Error)>,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
}
impl Failure {
    fn before_spawn(cause: Cause) -> Box<Self> {
        Box::new(Self {
            cause,
            cleanup: None,
            capture_errors: vec![],
            stdout: vec![],
            stderr: vec![],
        })
    }
}

struct OwnedGroup {
    child: Child,
    group: i32,
    finished: bool,
    signalled: bool,
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
            let _ = self.cleanup(CLEANUP_BUDGET);
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

fn capture(file: &mut File) -> io::Result<Vec<u8>> {
    file.seek(SeekFrom::Start(0))?;
    let mut bytes = Vec::new();
    file.take(MAX_CAPTURE + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > MAX_CAPTURE {
        return Err(io::Error::new(
            io::ErrorKind::FileTooLarge,
            "test command exceeded 1 MiB capture limit",
        ));
    }
    Ok(bytes)
}

pub fn run(command: &mut Command, budget: Duration) -> Result<Output, Box<Failure>> {
    run_observing_exit(command, budget, |_| {})
}

/// Private test seam observes the real exited-but-unreaped leader before cleanup.
pub fn run_observing_exit(
    command: &mut Command,
    budget: Duration,
    observed: impl FnOnce(u32),
) -> Result<Output, Box<Failure>> {
    let mut stdout =
        tempfile::tempfile().map_err(|error| Failure::before_spawn(Cause::Setup(error)))?;
    let mut stderr =
        tempfile::tempfile().map_err(|error| Failure::before_spawn(Cause::Setup(error)))?;
    let out = stdout
        .try_clone()
        .map_err(|error| Failure::before_spawn(Cause::Setup(error)))?;
    let err = stderr
        .try_clone()
        .map_err(|error| Failure::before_spawn(Cause::Setup(error)))?;
    command
        .stdin(Stdio::null())
        .stdout(out)
        .stderr(err)
        .process_group(0);
    let child = command
        .spawn()
        .map_err(|error| Failure::before_spawn(Cause::Spawn(error)))?;
    // Unix pid_t is a positive signed int; Child::id exposes that value as u32.
    let group = child.id() as i32;
    let mut owner = OwnedGroup {
        child,
        group,
        finished: false,
        signalled: false,
    };
    let started = Instant::now();
    let deadline = started + budget;
    let mut cause = loop {
        match owner.exited_without_reaping() {
            Ok(true) => {
                observed(owner.child.id());
                break None;
            }
            Ok(false) => {}
            Err(error) => break Some(Cause::Poll(error)),
        }
        if !pause_until(deadline) {
            break Some(Cause::Deadline {
                elapsed: started.elapsed(),
                budget,
            });
        }
    };
    let cleanup = owner.cleanup(CLEANUP_BUDGET);
    if !cleanup.succeeded() && cause.is_none() {
        cause = Some(Cause::Cleanup);
    }
    let mut capture_errors = Vec::new();
    let mut read = |file: &mut File, stream| match capture(file) {
        Ok(bytes) => bytes,
        Err(error) => {
            capture_errors.push((stream, error));
            Vec::new()
        }
    };
    let stdout = read(&mut stdout, "stdout");
    let stderr = read(&mut stderr, "stderr");
    if !capture_errors.is_empty() && cause.is_none() {
        cause = Some(Cause::Capture);
    }
    if let Some(cause) = cause {
        return Err(Box::new(Failure {
            cause,
            cleanup: Some(cleanup),
            capture_errors,
            stdout,
            stderr,
        }));
    }
    match cleanup.child_status {
        Some(status) => Ok(Output {
            status,
            stdout,
            stderr,
        }),
        None => Err(Box::new(Failure {
            cause: Cause::Cleanup,
            cleanup: Some(cleanup),
            capture_errors,
            stdout,
            stderr,
        })),
    }
}
