use super::{Error, Result, model::invalid};
use crate::ci_smoke::owned_command::{Running, Stage};
use std::{
    cell::Cell,
    ffi::CString,
    os::unix::ffi::OsStrExt,
    path::{Path, PathBuf},
    process::{Command, Output},
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
    thread,
    time::{Duration, Instant},
};

pub(super) const MIN_FREE: u64 = 3 * 1024 * 1024 * 1024;
pub(super) struct Native {
    root: PathBuf,
    pub(super) space_probe: fn(&Path, u64) -> Result<u64>,
    interrupted: Arc<AtomicUsize>,
    registrations: Vec<signal_hook::SigId>,
    pub(super) guarding: Cell<bool>,
    pub(super) cleaning: Cell<bool>,
}
impl Native {
    pub(super) fn new(root: PathBuf) -> Result<Self> {
        let mut owner = Self {
            root,
            space_probe: check_space,
            interrupted: Arc::new(AtomicUsize::new(0)),
            registrations: vec![],
            guarding: Cell::new(false),
            cleaning: Cell::new(false),
        };
        for signal in [libc::SIGHUP, libc::SIGINT, libc::SIGQUIT, libc::SIGTERM] {
            owner.registrations.push(signal_hook::flag::register_usize(
                signal,
                Arc::clone(&owner.interrupted),
                signal as usize,
            )?);
        }
        Ok(owner)
    }
    pub(super) fn check(&self) -> Result<()> {
        if !self.cleaning.get() {
            let signal = self.interrupted.load(Ordering::SeqCst);
            if signal != 0 {
                return Err(Error::Interrupted(signal as i32));
            }
            if self.guarding.get() {
                (self.space_probe)(&self.root, MIN_FREE)?;
            }
        }
        Ok(())
    }
    pub(super) fn command(&self, program: &str, args: &[&str]) -> Command {
        let mut command = Command::new(program);
        command.current_dir(&self.root).args(args);
        command
    }
    pub(super) fn run(
        &self,
        label: &'static str,
        command: &mut Command,
        seconds: u64,
        capture: bool,
    ) -> Result<Output> {
        self.check()?;
        eprintln!("Screenshot phase: {label}");
        let mut running = Running::start(
            command,
            Stage::ReleaseScreenshots,
            Duration::from_secs(seconds),
            Duration::from_secs(5),
            None,
            capture,
        )
        .map_err(|source| Error::Native { label, source })?;
        let mut space_check = Instant::now();
        loop {
            if let Some(result) = running.poll() {
                return result.map_err(|source| Error::Native { label, source });
            }
            if !self.cleaning.get() {
                let signal = self.interrupted.load(Ordering::SeqCst);
                if signal != 0 {
                    return Err(retirement_outcome(
                        Error::Interrupted(signal as i32),
                        running.interrupt(signal as i32),
                    ));
                }
                if self.guarding.get() && space_check.elapsed() >= Duration::from_secs(1) {
                    if let Err(error) = (self.space_probe)(&self.root, MIN_FREE) {
                        return Err(retirement_outcome(error, running.cancel()));
                    }
                    space_check = Instant::now();
                }
            }
            thread::sleep(Duration::from_millis(20));
        }
    }
    pub(super) fn output(
        &self,
        label: &'static str,
        program: &str,
        args: &[&str],
        seconds: u64,
    ) -> Result<String> {
        let output = self.run(label, &mut self.command(program, args), seconds, true)?;
        String::from_utf8(output.stdout).map_err(|_| Error::Invalid("native output encoding"))
    }
    pub(super) fn status(
        &self,
        label: &'static str,
        program: &str,
        args: &[&str],
        seconds: u64,
    ) -> Result<()> {
        self.run(label, &mut self.command(program, args), seconds, false)?;
        Ok(())
    }
    pub(super) fn dimensions(&self, path: &Path) -> Result<(u32, u32)> {
        if !path.is_file() {
            return invalid("screenshot/cover image is missing");
        }
        let mut command = self.command("sips", &["-g", "pixelWidth", "-g", "pixelHeight"]);
        command.arg(path);
        let output = self.run("image dimensions", &mut command, 30, true)?;
        parse_sips(
            &String::from_utf8(output.stdout)
                .map_err(|_| Error::Invalid("image dimensions encoding"))?,
        )
    }
}
impl Drop for Native {
    fn drop(&mut self) {
        for id in self.registrations.drain(..) {
            signal_hook::low_level::unregister(id);
        }
    }
}
pub(super) fn parse_sips(value: &str) -> Result<(u32, u32)> {
    let read = |key: &str| {
        value
            .lines()
            .find_map(|line| {
                line.trim()
                    .strip_prefix(key)
                    .and_then(|s| s.trim().parse::<u32>().ok())
            })
            .filter(|v| *v > 0)
            .ok_or(Error::Invalid("decoded image dimensions"))
    };
    Ok((read("pixelWidth:")?, read("pixelHeight:")?))
}
pub(super) fn check_space(path: &Path, minimum: u64) -> Result<u64> {
    let path =
        CString::new(path.as_os_str().as_bytes()).map_err(|_| Error::Invalid("filesystem path"))?;
    let mut stat = std::mem::MaybeUninit::<libc::statvfs>::uninit();
    // statvfs initializes this output only on success; the path owns its NUL terminator.
    if unsafe { libc::statvfs(path.as_ptr(), stat.as_mut_ptr()) } != 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    let stat = unsafe { stat.assume_init() };
    // libc uses different filesystem-counter widths on Darwin and Linux.
    #[allow(clippy::unnecessary_cast)]
    let available = (stat.f_bavail as u64).saturating_mul(stat.f_frsize as u64);
    require_space(available, minimum)?;
    Ok(available)
}
pub(super) fn require_space(available: u64, minimum: u64) -> Result<()> {
    if available < minimum {
        Err(Error::Disk { available, minimum })
    } else {
        Ok(())
    }
}

pub(super) struct Recording {
    running: Option<Running>,
    file: PathBuf,
}
impl Recording {
    pub(super) fn start(native: &Native, simulator: &str, file: PathBuf) -> Result<Self> {
        native.check()?;
        let mut command = native.command(
            "xcrun",
            &[
                "simctl",
                "io",
                simulator,
                "recordVideo",
                "--codec=h264",
                "--force",
            ],
        );
        command.arg(&file);
        Self::spawn(native, &mut command, file, false)
    }
    pub(super) fn spawn(
        native: &Native,
        command: &mut Command,
        file: PathBuf,
        capture: bool,
    ) -> Result<Self> {
        native.check()?;
        let running = Running::start(
            command,
            Stage::ReleaseScreenshots,
            Duration::from_secs(3600),
            Duration::from_secs(5),
            None,
            capture,
        )
        .map_err(|source| Error::Native {
            label: "screen recording",
            source,
        })?;
        Ok(Self {
            running: Some(running),
            file,
        })
    }
    pub(super) fn stop(mut self) -> Result<()> {
        let mut running = self
            .running
            .take()
            .ok_or(Error::Invalid("recording ownership"))?;
        if let Some(result) = running.poll() {
            result.map_err(|source| Error::Native {
                label: "recording completion",
                source,
            })?;
        } else {
            if let Err(error) = running.request_signal(libc::SIGINT) {
                return Err(retirement_outcome(Error::Io(error), running.cancel()));
            }
            let deadline = Instant::now() + Duration::from_secs(15);
            loop {
                if let Some(result) = running.poll() {
                    result.map_err(|source| Error::Native {
                        label: "recording flush",
                        source,
                    })?;
                    break;
                }
                if Instant::now() >= deadline {
                    return Err(retirement_outcome(
                        Error::Invalid("screen recording flush deadline"),
                        running.cancel(),
                    ));
                }
                thread::sleep(Duration::from_millis(20));
            }
        }
        if !self.file.metadata().is_ok_and(|s| s.len() > 0) {
            return invalid("screen recording is empty");
        }
        Ok(())
    }
}

fn retirement_outcome(
    primary: Error,
    outcome: std::result::Result<Output, Box<crate::ci_smoke::owned_command::Failure>>,
) -> Error {
    match outcome {
        Err(source) if source.cleanup.as_ref().is_none_or(|c| !c.succeeded()) => {
            Error::Retirement {
                primary: Box::new(primary),
                source,
            }
        }
        _ => primary,
    }
}
