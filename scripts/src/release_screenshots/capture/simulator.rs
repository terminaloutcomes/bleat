use super::{Session, find_plans, install_test_environment, known_dimensions, verify_summary};
use crate::release_screenshots::{
    Error, Result,
    model::{self, CADDY_IMAGE, SCREEN_TEST, invalid, text},
    native::Recording,
};
use serde_json::{Value, json};
use std::{collections::BTreeMap, fs, path::Path};

impl Session {
    pub(super) fn capture_device(&mut self, device_type: &str) -> Result<()> {
        let label = if device_type.contains("iPhone") {
            "iphone"
        } else {
            "ipad"
        };
        let name = format!("Bleat Release {label} {}", self.run_id);
        self.simulator_names.push(name.clone());
        self.record_ownership()?;
        let simulator = self
            .native
            .output(
                "create owned Simulator",
                "xcrun",
                &["simctl", "create", &name, device_type, &self.runtime],
                60,
            )?
            .trim()
            .to_owned();
        if simulator.is_empty() {
            return invalid("created Simulator identifier");
        }
        self.simulators.push(simulator.clone());
        self.record_ownership()?;
        self.configure_simulator(&simulator)?;
        let calibration = self.work.path().join(format!("{label}-calibration.png"));
        let mut cmd = self
            .native
            .command("xcrun", &["simctl", "io", &simulator, "screenshot"]);
        cmd.arg(&calibration);
        self.native
            .run("calibrate Simulator dimensions", &mut cmd, 30, true)?;
        let dimensions = self.native.dimensions(&calibration)?;
        if let Some(expected) = known_dimensions(device_type)
            && dimensions != expected
        {
            return invalid("Simulator calibration differs from documented dimensions");
        }
        let derived = self.work.path().join("derived-data");
        let destination = format!("id={simulator}");
        let mut cmd = self.native.command(
            "xcodebuild",
            &[
                "-quiet",
                "-project",
                "Bleat.xcodeproj",
                "-scheme",
                "Bleat",
                "-configuration",
                "Release",
                "-destination",
                &destination,
                "-derivedDataPath",
            ],
        );
        cmd.arg(&derived)
            .args([
                "-parallel-testing-enabled",
                "NO",
                "ENABLE_TESTABILITY=YES",
                "BUILD_WITHOUT_PAID_DEVELOPER=YES",
            ])
            .arg(format!("BLEAT_CARPLAY_MODE={}", self.config.carplay))
            .arg("build-for-testing");
        self.native
            .run("Release build-for-testing", &mut cmd, 2400, false)?;
        let mut plans = Vec::new();
        find_plans(&derived.join("Build/Products"), &mut plans)?;
        if plans.len() != 1 {
            return invalid("exactly one generated xctestrun plan required");
        }
        let plan = &plans[0];
        let mut environment = BTreeMap::from([
            ("BLEAT_SCREENSHOT_APP_URL".to_owned(), self.base_url.clone()),
            (
                "BLEAT_SCREENSHOT_USERNAME".to_owned(),
                text(&self.fixture.value["account"], "username")?.to_owned(),
            ),
            (
                "BLEAT_SCREENSHOT_PASSWORD".to_owned(),
                self.password.clone(),
            ),
            ("BLEAT_SCREENSHOT_ENABLED".to_owned(), "1".to_owned()),
        ]);
        let mut capture_descriptions = Vec::new();
        for orientation in self.config.orientations.clone() {
            let expected = if orientation == "portrait" {
                dimensions
            } else {
                (dimensions.1, dimensions.0)
            };
            capture_descriptions.push(json!({"orientation":orientation,"pixelDimensions":format!("{}x{}",expected.0,expected.1)}));
            for appearance in self.config.appearances.clone() {
                self.native.status(
                    "Simulator appearance",
                    "xcrun",
                    &["simctl", "ui", &simulator, "appearance", &appearance],
                    30,
                )?;
                environment.insert("BLEAT_SCREENSHOT_APPEARANCE".to_owned(), appearance.clone());
                environment.insert(
                    "BLEAT_SCREENSHOT_ORIENTATION".to_owned(),
                    orientation.clone(),
                );
                let mut value = plist::Value::from_file(plan)
                    .map_err(|_| Error::Invalid("generated xctestrun plist"))?;
                if install_test_environment(&mut value, false, &environment) != 1 {
                    return invalid("exactly one BleatUITests environment required");
                }
                value
                    .to_file_xml(plan)
                    .map_err(|_| Error::Invalid("write generated xctestrun plist"))?;
                let stem = format!("{label}-{orientation}-{appearance}");
                let results = self.output.join("results");
                fs::create_dir_all(&results)?;
                let bundle = results.join(format!("{stem}.xcresult"));
                if self.config.video {
                    let recordings = self.output.join("recordings");
                    fs::create_dir_all(&recordings)?;
                    self.recording = Some(Recording::start(
                        &self.native,
                        &simulator,
                        recordings.join(format!("{stem}.mp4")),
                    )?);
                }
                let mut cmd = self.native.command("xcodebuild", &["-quiet", "-xctestrun"]);
                cmd.arg(plan)
                    .args([
                        "-destination",
                        &destination,
                        "-parallel-testing-enabled",
                        "NO",
                        "-resultBundlePath",
                    ])
                    .arg(&bundle)
                    .arg(format!("-only-testing:{SCREEN_TEST}"))
                    .arg("test-without-building");
                let execution = self
                    .native
                    .run("Release screenshot test", &mut cmd, 1800, false);
                let recording = self.recording.take().map(Recording::stop).transpose();
                match (execution, recording) {
                    (Ok(_), Ok(_)) => {}
                    (Err(primary), Err(secondary)) => {
                        return Err(Error::Additional {
                            primary: Box::new(primary),
                            secondary: Box::new(secondary),
                        });
                    }
                    (Err(error), _) | (_, Err(error)) => return Err(error),
                }
                self.verify_result(&bundle, &stem)?;
                self.export(&bundle, label, &orientation, &appearance, expected, &stem)?;
            }
        }
        self.captures.insert(
            label.to_owned(),
            json!({"deviceType":device_type,"captures":capture_descriptions}),
        );
        Ok(())
    }
    fn configure_simulator(&self, device: &str) -> Result<()> {
        let locale = self.config.locale.replace('_', "-");
        for args in [
            vec!["boot", device],
            vec!["bootstatus", device, "-b"],
            vec![
                "spawn",
                device,
                "defaults",
                "write",
                "NSGlobalDomain",
                "AppleLanguages",
                "-array",
                &locale,
            ],
            vec![
                "spawn",
                device,
                "defaults",
                "write",
                "NSGlobalDomain",
                "AppleLocale",
                "-string",
                &self.config.locale,
            ],
            vec![
                "spawn",
                device,
                "defaults",
                "write",
                "com.apple.iphonesimulator",
                "ConnectHardwareKeyboard",
                "-bool",
                "NO",
            ],
            vec!["shutdown", device],
            vec!["boot", device],
            vec!["bootstatus", device, "-b"],
            vec![
                "status_bar",
                device,
                "override",
                "--time",
                "9:41",
                "--dataNetwork",
                "wifi",
                "--wifiMode",
                "active",
                "--wifiBars",
                "3",
                "--batteryState",
                "charged",
                "--batteryLevel",
                "100",
            ],
        ] {
            let mut command = self.native.command("xcrun", &["simctl"]);
            command.args(args);
            self.native
                .run("configure owned Simulator", &mut command, 180, true)?;
        }
        let mut command = self
            .native
            .command("xcrun", &["simctl", "keychain", device, "add-root-cert"]);
        command.arg(self.work.path().join("ca.crt"));
        self.native.run(
            "install fixture CA on owned Simulator",
            &mut command,
            30,
            true,
        )?;
        Ok(())
    }
    fn verify_result(&mut self, bundle: &Path, stem: &str) -> Result<()> {
        let mut command = self.native.command(
            "xcrun",
            &["xcresulttool", "get", "test-results", "summary", "--path"],
        );
        command.arg(bundle);
        let summary = self
            .native
            .run("screenshot result summary", &mut command, 60, true)?;
        let summary: Value = serde_json::from_slice(&summary.stdout)
            .map_err(|_| Error::Invalid("native summary JSON"))?;
        verify_summary(&summary)?;
        let mut command = self.native.command(
            "xcrun",
            &["xcresulttool", "get", "test-results", "tests", "--path"],
        );
        command.arg(bundle);
        let tests = self
            .native
            .run("screenshot native identities", &mut command, 60, true)?;
        let tests = String::from_utf8(tests.stdout)
            .map_err(|_| Error::Invalid("native identities encoding"))?;
        let expected = crate::test_results::expected_from_ids(&[SCREEN_TEST.to_owned()], 1)
            .map_err(Error::Verification)?;
        let report = crate::test_results::verify_result_json(&tests, &expected, &[])
            .map_err(Error::Verification)?;
        if report.passed_cases != 1 || report.skipped_cases != 0 {
            return invalid("one exact unskipped screenshot case required");
        }
        let receipts = self
            .root
            .join(".build/release-screenshot-receipts")
            .join(&self.run_id);
        fs::create_dir_all(&receipts)?;
        model::write_json(&receipts.join(format!("{stem}-summary.json")), &summary)?;
        let tree: Value =
            serde_json::from_str(&tests).map_err(|_| Error::Invalid("native identities JSON"))?;
        model::write_json(&receipts.join(format!("{stem}-tests.json")), &tree)?;
        self.results.push(json!({"capture":stem,"expectedIdentity":SCREEN_TEST,"passed":report.passed_cases,"skipped":report.skipped_cases,"runtimeWarnings":0}));
        println!(
            "Verified {stem}: exactly one screenshot journey passed, no skips or runtime warnings"
        );
        Ok(())
    }
    fn export(
        &self,
        bundle: &Path,
        label: &str,
        orientation: &str,
        appearance: &str,
        dimensions: (u32, u32),
        stem: &str,
    ) -> Result<()> {
        let attachments = self.work.path().join(format!("attachments-{stem}"));
        let mut cmd = self.native.command(
            "xcrun",
            &["xcresulttool", "export", "attachments", "--path"],
        );
        cmd.arg(bundle).arg("--output-path").arg(&attachments);
        self.native
            .run("export named screenshot attachments", &mut cmd, 120, true)?;
        let files = model::attachment_files(
            &model::read_json(&attachments.join("manifest.json"))?,
            &self.fixture.names(appearance),
        )?;
        let mut destination = self.output.join(label);
        if orientation != "portrait" {
            destination = destination.join(orientation);
        }
        fs::create_dir_all(&destination)?;
        for (name, exported) in files {
            let source = attachments.join(exported);
            let actual = self.native.dimensions(&source)?;
            if orientation == "landscapeLeft" && actual.1 > actual.0 {
                let rotated = attachments.join(format!("rotated-{name}"));
                let mut cmd = self.native.command("sips", &["--rotate", "-90"]);
                cmd.arg(&source).arg("--out").arg(&rotated);
                self.native
                    .run("normalize landscape image", &mut cmd, 30, true)?;
                fs::rename(rotated, &source)?;
            }
            if orientation == "landscapeLeft" {
                let normalized = crate::release_screenshots::png::normalize_orientation_metadata(
                    &fs::read(&source)?,
                )
                .map_err(Error::Invalid)?;
                fs::write(&source, normalized)?;
            }
            model::validate_dimensions(self.native.dimensions(&source)?, dimensions, orientation)?;
            let target = destination.join(name);
            fs::copy(&source, &target)?;
            model::validate_dimensions(self.native.dimensions(&target)?, dimensions, orientation)?;
        }
        Ok(())
    }
    pub(super) fn build_manifest(&self) -> Result<()> {
        let info = plist::Value::from_file(
            self.work
                .path()
                .join("derived-data/Build/Products/Release-iphonesimulator/Bleat.app/Info.plist"),
        )
        .map_err(|_| Error::Invalid("built Release app metadata"))?;
        let info = info
            .as_dictionary()
            .ok_or(Error::Invalid("built app plist dictionary"))?;
        let field = |key: &str| {
            info.get(key)
                .and_then(plist::Value::as_string)
                .ok_or(Error::Invalid("built app version/build"))
        };
        let commit = self
            .native
            .output("source revision", "git", &["rev-parse", "HEAD"], 15)?;
        let dirty = !self
            .native
            .output(
                "source worktree state",
                "git",
                &["status", "--porcelain"],
                15,
            )?
            .trim()
            .is_empty();
        let xcode = self
            .native
            .output("Xcode toolchain", "xcodebuild", &["-version"], 30)?
            .split_whitespace()
            .collect::<Vec<_>>()
            .join(" ");
        let mut simulator = self.captures.clone();
        simulator.insert("runtime".to_owned(), json!(self.runtime));
        simulator.insert("locale".to_owned(), json!(self.config.locale));
        simulator.insert("appearances".to_owned(), json!(self.config.appearances));
        simulator.insert("orientations".to_owned(), json!(self.config.orientations));
        let mut screenshots = Vec::new();
        for orientation in &self.config.orientations {
            for appearance in &self.config.appearances {
                for source in self.fixture.value["screenshots"]
                    .as_array()
                    .ok_or(Error::Invalid("screenshots"))?
                {
                    let mut screen = source.clone();
                    screen["file"] =
                        json!(model::screenshot_name(text(source, "file")?, appearance));
                    screen["orientation"] = json!(orientation);
                    screen["appearance"] = json!(appearance);
                    screenshots.push(screen);
                }
            }
        }
        let manifest = json!({"app":{"version":field("CFBundleShortVersionString")?,"build":field("CFBundleVersion")?},"git":{"commit":commit.trim(),"dirtyWorktree":dirty},"xcode":xcode,"simulator":simulator,"images":{"audiobookshelf":self.config.image,"caddy":CADDY_IMAGE},"fixtureSchemaVersion":self.fixture.value["schemaVersion"],"screenshots":screenshots});
        model::validate_public_manifest(&manifest)?;
        model::write_json(&self.output.join("manifest.json"), &manifest)?;
        let receipts = self
            .root
            .join(".build/release-screenshot-receipts")
            .join(&self.run_id);
        fs::create_dir_all(&receipts)?;
        model::write_json(
            &receipts.join("verified-tests.json"),
            &json!({"git":manifest["git"],"results":self.results,"run":self.run_id}),
        )?;
        Ok(())
    }
}
