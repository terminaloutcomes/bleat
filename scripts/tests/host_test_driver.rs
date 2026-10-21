//! Native CLI fixtures never invoke Swift, Xcode, signing or user configuration.
use std::{
    collections::BTreeSet,
    fs, io,
    os::unix::{fs::PermissionsExt, process::CommandExt},
    path::Path,
    process::{Child, Command, ExitStatus, Stdio},
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
        mpsc,
    },
    thread,
    time::{Duration, Instant},
};

struct Fixture {
    root: Option<tempfile::TempDir>,
    preserve: AtomicBool,
}
impl Fixture {
    fn new(swift: Option<&str>) -> Self {
        let root = tempfile::tempdir().expect("isolated synthetic host repository");
        for path in [
            "bin",
            "TestSupport/HostTests",
            ".build/coverage-input",
            ".build/synthetic-bin",
        ] {
            fs::create_dir_all(root.path().join(path)).expect("fixture directories");
        }
        let value = Self {
            root: Some(root),
            preserve: AtomicBool::new(false),
        };
        if let Some(script) = swift {
            value.executable("swift", script);
        }
        value
    }
    fn path(&self) -> &Path {
        self.root.as_ref().expect("owned fixture").path()
    }
    fn executable(&self, name: &str, script: &str) {
        let path = self.path().join("bin").join(name);
        fs::write(&path, format!("#!/bin/sh\nset -eu\n{script}\n")).expect("synthetic command");
        fs::set_permissions(path, fs::Permissions::from_mode(0o700)).expect("executable fixture");
    }
    fn pid(&self, name: &str) -> Option<i32> {
        fs::read_to_string(self.path().join(name))
            .ok()?
            .trim()
            .parse()
            .ok()
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        if let Some(root) = self.root.take() {
            if self.preserve.load(Ordering::SeqCst) {
                let _ = root.keep();
            } else {
                if let Err(error) = root.close() {
                    if thread::panicking() {
                        eprintln!("synthetic_fixture_cleanup_failed kind={:?}", error.kind());
                    } else {
                        panic!("synthetic_fixture_cleanup_failed kind={:?}", error.kind());
                    }
                }
            }
        }
    }
}
struct Driver<'a> {
    fixture: &'a Fixture,
    child: Child,
    status: Option<ExitStatus>,
    watchdog: Option<thread::JoinHandle<io::Result<()>>>,
    stop: Option<mpsc::Sender<()>>,
    watchdog_fired: Arc<AtomicBool>,
    cleaned: bool,
    admitted: Option<Admitted>,
}
#[derive(Clone, Copy)]
struct Admitted {
    phase: i32,
    descendant: i32,
    phase_group: i32,
    descendant_group: i32,
}

struct Outcome {
    status: ExitStatus,
    log: String,
    retired_before_release: bool,
    phase_absent_before_release: bool,
    descendant_absent_before_release: bool,
    watchdog_fired: bool,
}
fn group_exists(pid: i32) -> bool {
    // SAFETY: signal zero only observes the recorded synthetic group.
    let result = unsafe { libc::kill(-pid, 0) };
    result == 0 || io::Error::last_os_error().raw_os_error() != Some(libc::ESRCH)
}
fn process_exists(pid: i32) -> bool {
    // SAFETY: signal zero only observes a recorded synthetic process.
    let result = unsafe { libc::kill(pid, 0) };
    result == 0 || io::Error::last_os_error().raw_os_error() != Some(libc::ESRCH)
}
impl<'a> Driver<'a> {
    fn start(fixture: &'a Fixture) -> Self {
        Self::launch(fixture, false)
    }
    fn public_launcher(fixture: &'a Fixture) -> Self {
        fs::create_dir_all(fixture.path().join("scripts")).expect("public launcher directory");
        fs::create_dir_all(fixture.path().join("src")).expect("isolated Cargo entry directory");
        fs::copy(
            Path::new(env!("CARGO_MANIFEST_DIR")).join("test-host.sh"),
            fixture.path().join("scripts/test-host.sh"),
        )
        .expect("unchanged public launcher");
        // Use real Cargo's Unix exec behavior in a dependency-free, exclusively
        // owned workspace, avoiding the parent Cargo test's build-directory lock.
        // The tiny entry point immediately execs the exact Cargo-built driver.
        fs::write(
            fixture.path().join("Cargo.toml"),
            r#"[package]
name = "scripts"
version = "0.0.0"
edition = "2024"
[[bin]]
name = "host-test-driver"
path = "src/main.rs"
"#,
        )
        .expect("synthetic package manifest");
        fs::write(
            fixture.path().join("Cargo.lock"),
            r#"version = 4
[[package]]
name = "scripts"
version = "0.0.0"
"#,
        )
        .expect("dependency-free fixture lockfile");
        fs::write(fixture.path().join(".envrc"), "").expect("synthetic empty configuration");
        fs::write(fixture.path().join("src/main.rs"), format!(r#"use std::os::unix::process::CommandExt;
fn main() {{ let error = std::process::Command::new({:?}).args(std::env::args_os().skip(1)).exec(); eprintln!("fixture_exec_failed: {{error}}"); std::process::exit(70); }}
"#, env!("CARGO_BIN_EXE_host-test-driver"))).expect("composition-only fixture entry");
        Self::launch(fixture, true)
    }
    fn launch(fixture: &'a Fixture, public: bool) -> Self {
        let log = fs::File::create(fixture.path().join("driver.log")).expect("private driver log");
        let mut command = if public {
            let mut command = Command::new("/bin/zsh");
            command.arg(fixture.path().join("scripts/test-host.sh"));
            command
        } else {
            Command::new(env!("CARGO_BIN_EXE_host-test-driver"))
        };
        command.env_clear();
        if public {
            let current = std::env::var_os("PATH").expect("supported Rust toolchain PATH");
            let path = std::env::join_paths(
                std::iter::once(fixture.path().join("bin")).chain(std::env::split_paths(&current)),
            )
            .expect("fixture-first toolchain PATH");
            command.env("PATH", path);
            for name in [
                "HOME",
                "CARGO_HOME",
                "RUSTUP_HOME",
                "RUSTUP_TOOLCHAIN",
                "RUSTC",
                "RUSTDOC",
                "RUSTC_WRAPPER",
                "RUSTC_WORKSPACE_WRAPPER",
                "RUSTFLAGS",
                "SDKROOT",
            ] {
                if let Some(value) = std::env::var_os(name) {
                    command.env(name, value);
                }
            }
        } else {
            command.env("PATH", fixture.path().join("bin"));
        }
        let child = command
            .args(["--signing", "unsigned", "--repository-root"])
            .arg(fixture.path())
            .env("HOST_FIXTURE", fixture.path())
            .stdin(Stdio::null())
            .stdout(log.try_clone().expect("log clone"))
            .stderr(log)
            .process_group(0)
            .spawn()
            .expect("synthetic native host driver");
        let (stop, wait) = mpsc::channel();
        let release = fixture.path().join("release");
        let fired = Arc::new(AtomicBool::new(false));
        let marker = Arc::clone(&fired);
        // Independent of the tested driver: even a regressed return/cancellation
        // path releases the exact controlled phase and descendant on the watchdog.
        let watchdog = thread::spawn(move || {
            if wait.recv_timeout(Duration::from_secs(60)).is_err() {
                marker.store(true, Ordering::SeqCst);
                fs::write(release, b"release")?;
            }
            Ok(())
        });
        Self {
            fixture,
            child,
            status: None,
            watchdog: Some(watchdog),
            stop: Some(stop),
            watchdog_fired: fired,
            cleaned: false,
            admitted: None,
        }
    }
    fn ready(&mut self) -> Option<Admitted> {
        let deadline = Instant::now() + Duration::from_secs(30);
        loop {
            if let (Some(phase), Some(descendant)) = (
                self.fixture.pid("phase.pid"),
                self.fixture.pid("descendant.pid"),
            ) {
                // SAFETY: query the admitted fixture processes, without signalling.
                let phase_group = unsafe { libc::getpgid(phase) };
                let descendant_group = unsafe { libc::getpgid(descendant) };
                if phase_group > 0 && descendant_group > 0 {
                    let admitted = Admitted {
                        phase,
                        descendant,
                        phase_group,
                        descendant_group,
                    };
                    self.admitted = Some(admitted);
                    return Some(admitted);
                }
            }
            if Instant::now() >= deadline {
                return None;
            }
            thread::sleep(Duration::from_millis(10));
        }
    }
    fn native_retired(&self) -> bool {
        match self.admitted {
            Some(admitted) => {
                !process_exists(admitted.phase)
                    && !process_exists(admitted.descendant)
                    && !group_exists(admitted.phase_group)
                    && !group_exists(admitted.descendant_group)
            }
            None => {
                self.fixture
                    .pid("phase.pid")
                    .is_none_or(|pid| !process_exists(pid))
                    && self
                        .fixture
                        .pid("descendant.pid")
                        .is_none_or(|pid| !process_exists(pid))
            }
        }
    }
    fn wait(&mut self, budget: Duration) -> io::Result<bool> {
        let deadline = Instant::now() + budget;
        loop {
            if self.status.is_some() {
                return Ok(true);
            }
            if let Some(status) = self.child.try_wait()? {
                self.status = Some(status);
                return Ok(true);
            }
            if Instant::now() >= deadline {
                return Ok(false);
            }
            thread::sleep(Duration::from_millis(10));
        }
    }
    fn retire(&mut self) -> bool {
        let mut confirmed = fs::write(self.fixture.path().join("release"), b"release").is_ok();
        match self.wait(Duration::from_secs(5)) {
            Ok(true) => (),
            Ok(false) => {
                // A successful non-reaping ownership observation above still
                // leaves this direct Child owned by the fixture supervisor.
                confirmed &= self.child.kill().is_ok();
                confirmed &= self.wait(Duration::from_secs(3)).unwrap_or(false);
            }
            Err(error) => {
                confirmed = false;
                eprintln!("fixture_driver_observation_failed kind={:?}", error.kind());
            }
        }
        let deadline = Instant::now() + Duration::from_secs(3);
        let retired = loop {
            if self.native_retired() {
                break true;
            }
            if Instant::now() >= deadline {
                break false;
            }
            thread::sleep(Duration::from_millis(10));
        };
        if let Some(stop) = self.stop.take() {
            confirmed &= stop.send(()).is_ok();
        }
        if let Some(watchdog) = self.watchdog.take() {
            confirmed &= matches!(watchdog.join(), Ok(Ok(())));
        }
        confirmed &= retired;
        self.fixture.preserve.store(!confirmed, Ordering::SeqCst);
        self.cleaned = true;
        confirmed
    }
    fn finish(mut self) -> Outcome {
        let returned = self.wait(Duration::from_secs(8)).unwrap_or(false);
        let retired_before_release = returned && self.native_retired();
        let phase_absent_before_release = self.admitted.is_some_and(|a| !process_exists(a.phase));
        let descendant_absent_before_release =
            self.admitted.is_some_and(|a| !process_exists(a.descendant));
        let fired = self.watchdog_fired.load(Ordering::SeqCst);
        let retired = self.retire();
        let log =
            fs::read_to_string(self.fixture.path().join("driver.log")).expect("driver outcome log");
        assert!(
            retired,
            "synthetic fixture retirement unconfirmed; resources retained"
        );
        assert!(
            returned,
            "driver did not return before independent release; {log}"
        );
        Outcome {
            status: self.status.expect("observed driver status"),
            log,
            retired_before_release,
            phase_absent_before_release,
            descendant_absent_before_release,
            watchdog_fired: fired,
        }
    }
}
impl Drop for Driver<'_> {
    fn drop(&mut self) {
        if !self.cleaned {
            let _ = self.retire();
        }
    }
}

#[test]
fn sigterm_retires_admitted_native_phase_and_descendant() {
    let fixture = Fixture::new(Some(
        r#"
[ "$*" = 'build --build-tests --enable-code-coverage' ] || exit 64
/bin/ps -o ppid= -p "$$" > "$HOST_FIXTURE/phase.parent"
/bin/sh -c 'printf "%s" "$$" > "$HOST_FIXTURE/descendant.pending"; /bin/mv "$HOST_FIXTURE/descendant.pending" "$HOST_FIXTURE/descendant.pid"; while [ ! -f "$HOST_FIXTURE/release" ]; do /bin/sleep 0.01; done' &
printf '%s' "$$" > "$HOST_FIXTURE/phase.pending"
/bin/mv "$HOST_FIXTURE/phase.pending" "$HOST_FIXTURE/phase.pid"
while [ ! -f "$HOST_FIXTURE/release" ]; do /bin/sleep 0.01; done
wait
"#,
    ));
    let mut driver = Driver::public_launcher(&fixture);
    let driver_pid = driver.child.id() as i32;
    let admitted = driver.ready();
    let phase_parent = fs::read_to_string(fixture.path().join("phase.parent"))
        .ok()
        .and_then(|text| text.trim().parse::<i32>().ok());
    let live_before =
        admitted.is_some_and(|a| process_exists(a.phase) && process_exists(a.descendant));
    // SAFETY: this test still owns its unreaped direct child; only that driver
    // PID receives SIGTERM. Native-phase group signalling belongs to the driver.
    let sent = unsafe { libc::kill(driver.child.id() as i32, libc::SIGTERM) };
    let outcome = driver.finish();
    assert!(
        admitted.is_some() && live_before,
        "both controlled native processes must be admitted"
    );
    assert_eq!(
        phase_parent,
        Some(driver_pid),
        "public shell/Cargo entry must preserve the driver PID before its native phase"
    );
    let admitted = admitted.expect("positive fixture admission");
    assert_eq!(
        admitted.phase_group, admitted.phase,
        "native phase must own its actual group"
    );
    assert_eq!(
        admitted.descendant_group, admitted.phase_group,
        "recorded child must belong to the admitted group"
    );
    assert!(
        outcome.phase_absent_before_release,
        "recorded phase PID survived driver return"
    );
    assert!(
        outcome.descendant_absent_before_release,
        "recorded descendant PID survived driver return"
    );
    eprintln!(
        "host_driver_retirement driver_pid={driver_pid} phase_pid={} descendant_pid={} phase_pgid={} child_pgid={} phase_absent={} descendant_absent={} groups_absent={}",
        admitted.phase,
        admitted.descendant,
        admitted.phase_group,
        admitted.descendant_group,
        outcome.phase_absent_before_release,
        outcome.descendant_absent_before_release,
        outcome.retired_before_release
    );
    assert_eq!(sent, 0);
    assert_eq!(outcome.status.code(), Some(143), "{}", outcome.log);
    assert!(
        outcome.retired_before_release,
        "driver returned with an owned phase group alive"
    );
    assert!(
        !outcome.watchdog_fired,
        "independent rescue must not manufacture retirement"
    );
    assert!(outcome.log.contains("code=host_driver_interrupted"));
}

#[test]
fn native_nonzero_exit_preserves_status_and_stops_before_later_phases() {
    let fixture = Fixture::new(Some("exit 47"));
    let outcome = Driver::start(&fixture).finish();
    assert_eq!(outcome.status.code(), Some(47));
    assert!(outcome.log.contains("code=native_exit_failed"));
    assert!(outcome.log.contains("phase=BuildTests"));
    assert!(!outcome.watchdog_fired);
}

#[test]
fn missing_native_tool_reports_spawn_failure_without_real_tool_fallback() {
    let fixture = Fixture::new(None);
    let outcome = Driver::start(&fixture).finish();
    assert_eq!(outcome.status.code(), Some(1));
    assert!(outcome.log.contains("code=native_spawn_failed"));
    assert!(outcome.log.contains("phase=BuildTests"));
    assert!(!outcome.watchdog_fired);
}

#[test]
fn unsigned_product_reports_and_profiles_survive_full_synthetic_workflow() {
    let fixture = Fixture::new(Some(
        r#"
case "$*" in
  'build --build-tests --enable-code-coverage') exit 0 ;;
  'build --show-bin-path') printf '%s\n' "$HOST_FIXTURE/.build/synthetic-bin"; printf 'fixture path-query warning\n' >&2 ;;
  'test --show-codecov-path') printf '%s\n' "$HOST_FIXTURE/.build/coverage-input/coverage.json" ;;
  test\ --skip-build*)
    product=''; report=''
    while [ "$#" -gt 0 ]; do
      case "$1" in --test-product) shift; product="$1" ;; --xunit-output) shift; report="$1" ;; esac
      shift
    done
    printf '<testsuites><testsuite><testcase classname="%s.Fixture" name="testContract()"/></testsuite></testsuites>' "$product" > "$report"
    printf '%s' "$product" > "$HOST_FIXTURE/.build/coverage-input/default.profdata"
    ;;
  *) exit 65 ;;
esac
"#,
    ));
    let reports = fixture.path().join("TestSupport/HostTests/reports.py");
    fs::copy(
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../TestSupport/HostTests/reports.py"),
        reports,
    )
    .expect("unchanged report verifier");
    fs::write(fixture.path().join("TestSupport/HostTests/inventory.json"), r#"{"BleatCoreTests.Fixture":["testContract()"],"BleatTranscriptionTests.Fixture":["testContract()"]}"#).expect("synthetic inventory");
    std::os::unix::fs::symlink("/usr/bin/python3", fixture.path().join("bin/python3"))
        .expect("native Python report interpreter");
    for product in ["BleatCoreTests", "BleatTranscriptionTests"] {
        let binary = fixture.path().join(format!(
            ".build/synthetic-bin/{product}.xctest/Contents/MacOS/{product}"
        ));
        fs::create_dir_all(binary.parent().expect("product parent")).expect("product directories");
        fs::write(binary, b"synthetic test product").expect("product marker");
    }
    fixture.executable("xcrun", r#"
case "$1 $2" in
  'llvm-profdata merge')
    output=''
    while [ "$#" -gt 0 ]; do if [ "$1" = '-o' ]; then shift; output="$1"; fi; shift; done
    printf merged > "$output"
    ;;
  'llvm-cov export')
    printf 'SF:%s/Sources/BleatCore/Fixture.swift\nDA:1,1\nend_of_record\nSF:%s/Sources/BleatTranscription/Fixture.swift\nDA:1,1\nend_of_record\n' "$HOST_FIXTURE" "$HOST_FIXTURE"
    ;;
  *) exit 66 ;;
esac
"#);
    let sentinel = fixture
        .path()
        .join(".build/coverage/swift-host/unrelated-sentinel");
    fs::create_dir_all(sentinel.parent().expect("coverage directory")).expect("coverage setup");
    fs::write(&sentinel, b"retained").expect("unrelated sentinel");
    let outcome = Driver::start(&fixture).finish();
    assert!(outcome.status.success(), "{}", outcome.log);
    assert!(!outcome.watchdog_fired);
    assert!(
        outcome.log.contains("fixture path-query warning"),
        "successful native path-query stderr must remain visible"
    );
    assert!(sentinel.is_file());
    for product in ["BleatCoreTests", "BleatTranscriptionTests"] {
        // Profiles are opaque binary artifacts: exact synthetic bytes prove each
        // product was copied before the next test overwrote default.profdata.
        assert_eq!(
            fs::read(
                fixture
                    .path()
                    .join(format!(".build/coverage/swift-host/{product}.profdata"))
            )
            .expect("retained product profile"),
            product.as_bytes()
        );
    }
    let report = fs::read_to_string(fixture.path().join(".build/host-results/tests.xml"))
        .expect("verified XML report");
    let xml = roxmltree::Document::parse(&report).expect("well-formed combined report");
    let identities: BTreeSet<_> = xml
        .descendants()
        .filter(|n| n.has_tag_name("testcase"))
        .map(|n| {
            (
                n.attribute("classname").expect("suite"),
                n.attribute("name").expect("name"),
            )
        })
        .collect();
    assert_eq!(
        identities,
        BTreeSet::from([
            ("BleatCoreTests.Fixture", "testContract()"),
            ("BleatTranscriptionTests.Fixture", "testContract()")
        ])
    );
    let lcov = fs::read_to_string(fixture.path().join(".build/coverage/swift-host/lcov.info"))
        .expect("normalized coverage");
    let sources: BTreeSet<_> = lcov
        .lines()
        .filter_map(|line| line.strip_prefix("SF:"))
        .collect();
    assert_eq!(
        sources,
        BTreeSet::from([
            "Sources/BleatCore/Fixture.swift",
            "Sources/BleatTranscription/Fixture.swift"
        ])
    );
}
