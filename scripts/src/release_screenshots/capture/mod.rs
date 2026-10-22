mod server;
mod simulator;

use super::{
    Configuration, Error, Fixture, Result,
    model::{self, invalid, text},
    native::{MIN_FREE, Native, Recording, check_space},
};
use reqwest::blocking::Client;
use serde_json::{Value, json};
use std::{
    collections::BTreeMap,
    fs,
    net::{Ipv4Addr, TcpListener},
    path::{Path, PathBuf},
    process::Command,
};
use tempfile::TempDir;

struct Session {
    root: PathBuf,
    output: PathBuf,
    work: TempDir,
    config: Configuration,
    fixture: Fixture,
    native: Native,
    run_id: String,
    project: String,
    password: String,
    simulators: Vec<String>,
    simulator_names: Vec<String>,
    compose_started: bool,
    media_started: bool,
    recording: Option<Recording>,
    client: Option<Client>,
    base_url: String,
    runtime: String,
    results: Vec<Value>,
    captures: serde_json::Map<String, Value>,
}
pub(super) fn run(
    root: PathBuf,
    output: PathBuf,
    config: Configuration,
    fixture: Fixture,
    native: Native,
) -> Result<()> {
    if !root.join(".envrc").is_file() {
        return invalid(".envrc must be present");
    }
    check_space(&root, MIN_FREE + 5 * 1024 * 1024 * 1024)?;
    native.guarding.set(true);
    let run_id = format!("{:032x}", rand::random::<u128>());
    let project = format!(
        "bleat-release-screenshots-current-stable-{}-{run_id}",
        text(&config.profile, "serverVersion")?.replace('.', "-")
    );
    fs::create_dir_all(root.join(".build"))?;
    let work = tempfile::Builder::new()
        .prefix("release-screenshot-work-")
        .tempdir_in(root.join(".build"))?;
    // Never overwrite a prior successful capture or retained failure.
    claim_output(&output)?;
    let mut session = Session {
        root,
        output,
        work,
        config,
        fixture,
        native,
        run_id,
        project,
        password: format!("{:032x}", rand::random::<u128>()),
        simulators: vec![],
        simulator_names: vec![],
        compose_started: false,
        media_started: false,
        recording: None,
        client: None,
        base_url: String::new(),
        runtime: String::new(),
        results: vec![],
        captures: serde_json::Map::new(),
    };
    let result = session.execute();
    let failures = session.cleanup(result.is_ok());
    if !failures.is_empty() {
        // Retain only this invocation's private workspace if resources could not be retired.
        let _ = session.work.keep();
        return Err(Error::Cleanup {
            failures,
            primary: result.err().map(Box::new),
        });
    }
    let receipt = session.receipt_directory().join("cleanup.json");
    let removal = session.work.close();
    let update = (|| {
        let mut status = model::read_json(&receipt)?;
        status["privateWorkspaceRemoved"] = json!(removal.is_ok());
        model::write_json(&receipt, &status)
    })();
    if let Err(error) = update {
        return Err(combine_failure(result, error));
    }
    if let Err(error) = removal {
        return Err(combine_failure(result, Error::Io(error)));
    }
    result
}
impl Session {
    fn compose(&self, args: &[&str]) -> Command {
        let mut cmd = self.native.command(
            "docker",
            &["compose", "--project-name", &self.project, "--file"],
        );
        cmd.arg(
            self.root
                .join("TestSupport/ReleaseScreenshots/compose.yaml"),
        )
        .args(args)
        .env("BLEAT_SCREENSHOT_ABS_IMAGE", &self.config.image)
        .env("BLEAT_SCREENSHOT_MEDIA_DIR", self.work.path().join("media"))
        .env(
            "BLEAT_SCREENSHOT_HTTPS_PORT",
            if self.config.port == 0 {
                "0".to_owned()
            } else {
                self.config.port.to_string()
            },
        );
        cmd
    }
    fn compose_output(&self, label: &'static str, args: &[&str], seconds: u64) -> Result<String> {
        let output = self
            .native
            .run(label, &mut self.compose(args), seconds, true)?;
        String::from_utf8(output.stdout).map_err(|_| Error::Invalid("Compose output encoding"))
    }
    fn execute(&mut self) -> Result<()> {
        self.record_ownership()?;
        self.native
            .output("Docker readiness", "docker", &["info"], 30)?;
        self.native.status(
            "Compose availability",
            "docker",
            &["compose", "version"],
            30,
        )?;
        if self.config.port != 0 {
            let _ = TcpListener::bind((Ipv4Addr::LOCALHOST, self.config.port))?;
        }
        let runtimes: Value = serde_json::from_str(&self.native.output(
            "Simulator runtime inventory",
            "xcrun",
            &["simctl", "list", "runtimes", "available", "--json"],
            60,
        )?)
        .map_err(|_| Error::Invalid("Simulator runtime inventory"))?;
        self.runtime = resolve_runtime(
            &runtimes,
            self.config.runtime.as_deref(),
            &self.config.devices,
        )?;
        self.generate_media()?;
        self.compose_started = true;
        self.record_ownership()?;
        self.compose_output(
            "Barnyard startup",
            &["up", "--detach", "--wait", "--wait-timeout", "120"],
            180,
        )?;
        let address = self.compose_output("Barnyard HTTPS port", &["port", "caddy", "8443"], 30)?;
        let port = parse_port(&address)?;
        self.base_url = format!(
            "https://{}:{port}/audiobookshelf",
            text(&self.fixture.value["server"], "hostname")?
        );
        self.wait_https(port)?;
        let token = self.initialize()?;
        self.seed(&token)?;
        for device in self.config.devices.clone() {
            self.capture_device(&device)?;
        }
        self.build_manifest()?;
        println!("Verified Release screenshots and sanitized manifest are ready.");
        Ok(())
    }
    fn cleanup(&mut self, success: bool) -> Vec<&'static str> {
        self.native.cleaning.set(true);
        let mut failures = Vec::new();
        if let Some(recording) = self.recording.take()
            && recording.stop().is_err()
        {
            failures.push("recording flush/retirement");
        }
        // Creation may have succeeded before its command was interrupted. Discover
        // only exact names registered before spawning, never other jobs' devices.
        if !self.simulator_names.is_empty() {
            match self
                .native
                .output(
                    "discover owned Simulators",
                    "xcrun",
                    &["simctl", "list", "devices", "--json"],
                    60,
                )
                .ok()
                .and_then(|s| serde_json::from_str::<Value>(&s).ok())
                .and_then(|v| owned_simulators(&v, &self.simulators, &self.simulator_names).ok())
            {
                Some(ids) => self.simulators = ids,
                None => failures.push("owned Simulator discovery"),
            }
        }
        if !success {
            let directory = self.output.join("failure");
            if fs::create_dir_all(&directory).is_err() {
                failures.push("failure diagnostics directory");
            }
            if self.compose_started {
                for (name, args) in [
                    ("compose-ps.txt", vec!["ps"]),
                    ("compose.log", vec!["logs", "--no-color"]),
                ] {
                    match self.compose_output("failure diagnostics", &args, 30) {
                        Ok(output) => {
                            if fs::write(directory.join(name), redact(&output, &self.password))
                                .is_err()
                            {
                                failures.push("redacted failure log");
                            }
                        }
                        Err(_) => failures.push("failure log capture"),
                    }
                }
            }
            for simulator in &self.simulators {
                let mut command = self
                    .native
                    .command("xcrun", &["simctl", "io", simulator, "screenshot"]);
                command.arg(directory.join(format!("{simulator}.png")));
                let _ = self
                    .native
                    .run("failure screenshot", &mut command, 30, true);
            }
            // Exported images and any completed manifest are evidence, even if a
            // later capture/receipt fails. Only invocation-owned scratch is disposable.
        }
        for simulator in &self.simulators {
            let _ = self.native.output(
                "clear owned status bar",
                "xcrun",
                &["simctl", "status_bar", simulator, "clear"],
                30,
            );
            let _ = self.native.output(
                "shutdown owned Simulator",
                "xcrun",
                &["simctl", "shutdown", simulator],
                60,
            );
            let _ = self.native.output(
                "delete owned Simulator",
                "xcrun",
                &["simctl", "delete", simulator],
                60,
            );
        }
        if !self.simulators.is_empty() || !self.simulator_names.is_empty() {
            match self
                .native
                .output(
                    "verify owned Simulator cleanup",
                    "xcrun",
                    &["simctl", "list", "devices", "--json"],
                    60,
                )
                .ok()
                .and_then(|s| serde_json::from_str::<Value>(&s).ok())
            {
                Some(v) => {
                    if verify_simulators_absent(&v, &self.simulators, &self.simulator_names)
                        .is_err()
                    {
                        failures.push("owned Simulator remains or inventory is malformed");
                    }
                }
                None => failures.push("Simulator cleanup verification"),
            }
        }
        if self.media_started {
            let filter = format!("label=bleat.release-screenshot.run={}", self.run_id);
            match self.native.output(
                "list owned media containers",
                "docker",
                &["ps", "--all", "--quiet", "--filter", &filter],
                30,
            ) {
                Ok(ids) => {
                    for id in ids.split_whitespace() {
                        if self
                            .native
                            .output(
                                "remove owned media container",
                                "docker",
                                &["rm", "--force", id],
                                30,
                            )
                            .is_err()
                        {
                            failures.push("owned media container removal");
                        }
                    }
                }
                Err(_) => failures.push("owned media cleanup inventory"),
            }
        }
        if self.compose_started {
            if self
                .compose_output(
                    "retire owned Barnyard project",
                    &["down", "--volumes", "--remove-orphans", "--timeout", "10"],
                    90,
                )
                .is_err()
            {
                failures.push("owned Compose project removal");
            }
            let filter = format!("label=com.docker.compose.project={}", self.project);
            for args in [
                vec!["ps", "--all", "--quiet", "--filter", &filter],
                vec!["volume", "ls", "--quiet", "--filter", &filter],
            ] {
                if !self
                    .native
                    .output("verify owned Compose cleanup", "docker", &args, 30)
                    .is_ok_and(|s| s.trim().is_empty())
                {
                    failures.push("owned Compose resource remains or verification failed");
                }
            }
        }
        if success && failures.is_empty() {
            let results = self.output.join("results");
            if results.exists() && fs::remove_dir_all(results).is_err() {
                failures.push("successful native bundle cleanup");
            }
        }
        if self.media_started {
            let filter = format!("label=bleat.release-screenshot.run={}", self.run_id);
            if !self
                .native
                .output(
                    "verify owned media cleanup",
                    "docker",
                    &["ps", "--all", "--quiet", "--filter", &filter],
                    30,
                )
                .is_ok_and(|s| s.trim().is_empty())
            {
                failures.push("owned media container remains or verification failed");
            }
        }
        let receipt = json!({"run":self.run_id,"captureSucceeded":success,"ownedSimulators":self.simulators,"ownedSimulatorNames":self.simulator_names,"composeProject":self.project,"cleanupFailures":failures});
        if model::write_json(&self.receipt_directory().join("cleanup.json"), &receipt).is_err() {
            failures.push("cleanup receipt");
        }
        failures
    }
    fn receipt_directory(&self) -> PathBuf {
        self.root
            .join(".build/release-screenshot-receipts")
            .join(&self.run_id)
    }
    fn record_ownership(&self) -> Result<()> {
        let directory = self.receipt_directory();
        fs::create_dir_all(&directory)?;
        let workspace = self
            .work
            .path()
            .strip_prefix(&self.root)
            .map_err(|_| Error::Invalid("owned workspace location"))?;
        model::write_json(
            &directory.join("ownership.json"),
            &json!({"run":self.run_id,"composeProject":self.project,"composeStarted":self.compose_started,"mediaContainerLabel":format!("bleat.release-screenshot.run={}",self.run_id),"ownedSimulators":self.simulators,"ownedSimulatorNames":self.simulator_names,"privateWorkspace":workspace}),
        )
    }
}
pub(super) fn parse_port(value: &str) -> Result<u16> {
    value
        .trim()
        .rsplit_once(':')
        .and_then(|(_, port)| port.parse::<u16>().ok())
        .filter(|p| *p > 0)
        .ok_or(Error::Invalid("published fixture HTTPS port"))
}
pub(super) fn known_dimensions(device: &str) -> Option<(u32, u32)> {
    match device {
        "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max" => Some((1320, 2868)),
        "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB" => Some((2064, 2752)),
        _ => None,
    }
}
pub(super) fn resolve_runtime(
    inventory: &Value,
    requested: Option<&str>,
    devices: &[String],
) -> Result<String> {
    let runtimes = inventory["runtimes"]
        .as_array()
        .ok_or(Error::Invalid("runtime inventory array"))?;
    let available = runtimes
        .iter()
        .filter(|v| {
            v["isAvailable"] == true && v["name"].as_str().is_some_and(|s| s.starts_with("iOS"))
        })
        .collect::<Vec<_>>();
    let runtime = if let Some(requested) = requested {
        available
            .iter()
            .find(|v| v["identifier"] == requested)
            .copied()
    } else {
        available
            .iter()
            .max_by_key(|v| {
                v["version"]
                    .as_str()
                    .unwrap_or_default()
                    .split('.')
                    .map(|p| p.parse::<u32>().unwrap_or(0))
                    .collect::<Vec<_>>()
            })
            .copied()
    }
    .ok_or(Error::Invalid("requested/latest available iOS runtime"))?;
    for device in devices {
        if !runtime["supportedDeviceTypes"]
            .as_array()
            .is_some_and(|a| a.iter().any(|v| v["identifier"] == *device))
        {
            return invalid("selected Simulator device is unsupported by runtime");
        }
    }
    Ok(text(runtime, "identifier")?.to_owned())
}
pub(super) fn verify_summary(summary: &Value) -> Result<()> {
    if summary["result"] != "Passed"
        || summary["passedTests"] != 1
        || summary["totalTestCount"] != 1
        || summary["failedTests"] != 0
        || summary["skippedTests"] != 0
        || summary["expectedFailures"] != 0
        || !summary["runtimeWarnings"]
            .as_array()
            .is_some_and(Vec::is_empty)
    {
        return invalid(
            "one passing screenshot journey without skips/failures/runtime warnings required",
        );
    }
    Ok(())
}
pub(super) fn install_test_environment(
    value: &mut plist::Value,
    target: bool,
    environment: &BTreeMap<String, String>,
) -> usize {
    match value {
        plist::Value::Dictionary(map) => {
            if target
                || map.get("BlueprintName").and_then(plist::Value::as_string)
                    == Some("BleatUITests")
            {
                if !map.contains_key("EnvironmentVariables") {
                    map.insert(
                        "EnvironmentVariables".to_owned(),
                        plist::Value::Dictionary(plist::Dictionary::new()),
                    );
                }
                let Some(variables) = map
                    .get_mut("EnvironmentVariables")
                    .and_then(plist::Value::as_dictionary_mut)
                else {
                    return 0;
                };
                for (key, value) in environment {
                    variables.insert(key.clone(), plist::Value::String(value.clone()));
                }
                return 1;
            }
            map.iter_mut()
                .map(|(key, value)| {
                    install_test_environment(value, key == "BleatUITests", environment)
                })
                .sum()
        }
        plist::Value::Array(values) => values
            .iter_mut()
            .map(|v| install_test_environment(v, false, environment))
            .sum(),
        _ => 0,
    }
}
fn find_plans(path: &Path, result: &mut Vec<PathBuf>) -> Result<()> {
    for entry in fs::read_dir(path)? {
        let entry = entry?;
        let path = entry.path();
        if path.is_dir() {
            find_plans(&path, result)?;
        } else if path.extension().is_some_and(|e| e == "xctestrun") {
            result.push(path);
        }
    }
    Ok(())
}
fn verify_hero(v: &Value) -> Result<()> {
    let chapters = v["media"]["chapters"]
        .as_array()
        .ok_or(Error::Invalid("seeded chapters"))?;
    let required = [
        "happy goats",
        "bouncing goats",
        "romantic goats",
        "oh no leave each other alone",
    ];
    if v["media"]["duration"] != 46800
        || chapters.len() != 13
        || chapters
            .iter()
            .enumerate()
            .any(|(i, c)| c["start"] != i * 3600)
        || required
            .iter()
            .any(|title| !chapters.iter().any(|c| c["title"] == *title))
    {
        return invalid("seeded hero metadata/chapter verification");
    }
    Ok(())
}
pub(super) fn redact(text: &str, password: &str) -> String {
    let mut result = text.replace(password, "[REDACTED]");
    for expression in [
        r"(?i)(Authorization:\s*Bearer\s+)[A-Za-z0-9._-]+",
        r#"(?i)("(?:accessToken|refreshToken|password)"\s*:\s*")[^"]*"#,
    ] {
        if let Ok(regex) = regex::Regex::new(expression) {
            result = regex.replace_all(&result, "${1}[REDACTED]").into_owned();
        }
    }
    result
}

pub(super) fn claim_output(output: &Path) -> Result<()> {
    if let Some(parent) = output.parent() {
        fs::create_dir_all(parent)?;
    }
    match fs::create_dir(output) {
        Ok(()) => {}
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
            return invalid("output directory already exists; choose a new output destination");
        }
        Err(error) => return Err(error.into()),
    }
    Ok(())
}

pub(super) fn owned_simulators(
    value: &Value,
    owned: &[String],
    names: &[String],
) -> Result<Vec<String>> {
    let runtimes = value["devices"]
        .as_object()
        .ok_or(Error::Invalid("Simulator cleanup inventory"))?;
    let mut found = std::collections::BTreeSet::new();
    for devices in runtimes.values() {
        for device in devices
            .as_array()
            .ok_or(Error::Invalid("Simulator cleanup rows"))?
        {
            let id = text(device, "udid")?;
            let name = text(device, "name")?;
            if owned.iter().any(|owned| owned == id) || names.iter().any(|owned| owned == name) {
                found.insert(id.to_owned());
            }
        }
    }
    Ok(found.into_iter().collect())
}

pub(super) fn verify_simulators_absent(
    value: &Value,
    owned: &[String],
    names: &[String],
) -> Result<()> {
    if !owned_simulators(value, owned, names)?.is_empty() {
        return invalid("owned Simulator remains");
    }
    Ok(())
}

fn combine_failure(primary: Result<()>, secondary: Error) -> Error {
    match primary {
        Ok(()) => secondary,
        Err(primary) => Error::Additional {
            primary: Box::new(primary),
            secondary: Box::new(secondary),
        },
    }
}
