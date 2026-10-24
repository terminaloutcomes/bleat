//! Admission checks before Xcode may load a macOS app-hosted test bundle.
use super::{Result, XcodeRunnerError};
use crate::ci_smoke::owned_command::{self, Stage};
use plist::Value;
use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
    time::Duration,
};

pub(super) const HOST_ID: &str = "com.terminaloutcomes.Bleat.MacTestHost";

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("macOS test preflight rejected {stage}: {cause}")]
    Rejected {
        stage: &'static str,
        cause: &'static str,
    },
    #[error("macOS test preflight could not read artifact: {0}")]
    Io(#[from] std::io::Error),
    #[error("macOS test preflight could not decode plist: {0}")]
    Plist(#[from] plist::Error),
}
fn reject(stage: &'static str, cause: &'static str) -> Error {
    Error::Rejected { stage, cause }
}
fn text<'a>(value: &'a Value, name: &str) -> Option<&'a str> {
    value.as_dictionary()?.get(name)?.as_string()
}
fn array<'a>(value: &'a Value, name: &str) -> Option<&'a Vec<Value>> {
    value.as_dictionary()?.get(name)?.as_array()
}
fn one<'a>(
    items: Option<&'a Vec<Value>>,
    stage: &'static str,
) -> std::result::Result<&'a Value, Error> {
    match items.map(Vec::as_slice) {
        Some([value]) => Ok(value),
        _ => Err(reject(stage, "expected_exactly_one")),
    }
}

fn resolve(raw: &str, products: &Path, host: &Path) -> std::result::Result<PathBuf, Error> {
    let path = raw
        .replace("__TESTROOT__", &products.to_string_lossy())
        .replace("__TESTHOST__", &host.to_string_lossy());
    if path.contains("__") {
        return Err(reject("manifest_paths", "unknown_placeholder"));
    }
    Ok(PathBuf::from(path).canonicalize()?)
}

fn validate_manifest(
    value: &Value,
    products: &Path,
) -> std::result::Result<(PathBuf, PathBuf), Error> {
    let target = if value
        .as_dictionary()
        .is_some_and(|v| v.contains_key("TestConfigurations"))
    {
        let configuration = one(
            array(value, "TestConfigurations"),
            "manifest_configurations",
        )?;
        one(array(configuration, "TestTargets"), "manifest_targets")?
    } else {
        let targets = value
            .as_dictionary()
            .ok_or(reject("manifest_targets", "not_dictionary"))?
            .iter()
            .filter(|(name, _)| name.as_str() != "__xctestrun_metadata__")
            .collect::<Vec<_>>();
        match targets.as_slice() {
            [(name, target)] if name.as_str() == "BleatAppTests" => *target,
            _ => return Err(reject("manifest_targets", "expected_exactly_one")),
        }
    };
    if text(target, "BlueprintName") != Some("BleatAppTests") {
        return Err(reject("manifest_target", "unexpected_target"));
    }
    let host = products.join("MacTesting/Bleat.app").canonicalize()?;
    let executable = host.join("Contents/MacOS/Bleat").canonicalize()?;
    let test_bundle = host
        .join("Contents/PlugIns/BleatAppTests.xctest")
        .canonicalize()?;
    let selected_host = resolve(
        text(target, "TestHostPath").ok_or(reject("manifest_host", "missing_path"))?,
        products,
        &host,
    )?;
    // Current Xcode emits a v1 app-bundle path; v2 plans can name the executable.
    if selected_host != host && selected_host != executable {
        return Err(reject("manifest_host", "unexpected_path"));
    }
    if resolve(
        text(target, "TestBundlePath").ok_or(reject("manifest_bundle", "missing_path"))?,
        products,
        &host,
    )? != test_bundle
    {
        return Err(reject("manifest_bundle", "unexpected_path"));
    }
    if text(target, "TestHostBundleIdentifier") != Some(HOST_ID) {
        return Err(reject("manifest_identity", "unexpected_host"));
    }
    let environment = target
        .as_dictionary()
        .and_then(|d| d.get("EnvironmentVariables"));
    if environment.and_then(|e| text(e, "BLEAT_MACOS_TEST_HOST")) != Some("1") {
        return Err(reject("manifest_environment", "missing_admission"));
    }
    Ok((host, test_bundle))
}
fn validate_identity(info: &Value, expected: &str) -> std::result::Result<(), Error> {
    if text(info, "CFBundleIdentifier") != Some(expected) {
        return Err(reject("bundle_identity", "unexpected_identifier"));
    }
    Ok(())
}
fn validate_entitlements(value: &Value) -> std::result::Result<(), Error> {
    let dict = value
        .as_dictionary()
        .ok_or(reject("entitlements", "not_dictionary"))?;
    // Xcode injects these exact development test-loader exceptions. They do
    // not admit production Keychain groups, CloudKit, app groups or arbitrary
    // additional capabilities. The test bundle itself can have no entitlements.
    for (name, value) in dict {
        let expected = match name.as_str() {
            "com.apple.security.get-task-allow" => Value::Boolean(true),
            "com.apple.security.temporary-exception.files.absolute-path.read-only" => {
                Value::Array(vec![Value::String("/".to_owned())])
            }
            "com.apple.security.temporary-exception.mach-lookup.global-name" => Value::Array(
                [
                    "com.apple.testmanagerd",
                    "com.apple.dt.testmanagerd.runner",
                    "com.apple.coresymbolicationd",
                ]
                .into_iter()
                .map(|name| Value::String(name.to_owned()))
                .collect(),
            ),
            _ => return Err(reject("entitlements", "unexpected_capability")),
        };
        if value != &expected {
            return Err(reject("entitlements", "unexpected_test_loader_value"));
        }
    }
    Ok(())
}
fn codesign(args: &[&str], path: &Path) -> Result<std::process::Output> {
    owned_command::run(
        Command::new("codesign").args(args).arg(path),
        Stage::XcodeBuildForTesting,
        Duration::from_secs(30),
        Duration::from_secs(3),
        None,
    )
    .map_err(|source| XcodeRunnerError::NativeCommand {
        stage: "macOS signature preflight".to_owned(),
        source,
    })
}
fn validate_signature_identity(details: &str, team: &str) -> std::result::Result<(), Error> {
    if !details
        .lines()
        .any(|line| line == format!("TeamIdentifier={team}"))
    {
        return Err(reject("signature_identity", "unexpected_team"));
    }
    if !details
        .lines()
        .any(|line| line.starts_with("Authority=Apple Development:"))
    {
        return Err(reject(
            "signature_identity",
            "development_identity_required",
        ));
    }
    Ok(())
}

pub(super) fn preflight(root: &Path, derived: &str, team: &str) -> Result<PathBuf> {
    let products = root.join(derived).join("Build/Products");
    let mut manifests = fs::read_dir(&products)?
        .filter_map(|entry| entry.ok().map(|e| e.path()))
        .filter(|p| {
            p.extension().is_some_and(|e| e == "xctestrun")
                && p.file_name()
                    .is_some_and(|n| n.to_string_lossy().starts_with("BleatMac_"))
        })
        .collect::<Vec<_>>();
    if manifests.len() != 1 {
        return Err(Error::Rejected {
            stage: "manifest_selection",
            cause: "expected_exactly_one",
        }
        .into());
    }
    let manifest = manifests.remove(0);
    let value = Value::from_file(&manifest).map_err(Error::from)?;
    let (host, bundle) = validate_manifest(&value, &products)?;
    for (path, id) in [
        (&host, HOST_ID.to_owned()),
        (&bundle, format!("{HOST_ID}.Tests")),
    ] {
        validate_identity(
            &Value::from_file(path.join("Contents/Info.plist")).map_err(Error::from)?,
            &id,
        )?;
        codesign(&["--verify", "--deep", "--strict"], path)?;
        let identity = codesign(&["-d", "--verbose=4"], path)?;
        validate_signature_identity(&String::from_utf8_lossy(&identity.stderr), team)?;
        let entitlements = codesign(&["-d", "--entitlements", "-", "--xml"], path)?;
        if !entitlements.stdout.is_empty() {
            validate_entitlements(
                &Value::from_reader_xml(entitlements.stdout.as_slice()).map_err(Error::from)?,
            )?;
        }
    }
    Ok(manifest)
}

/// Keep __TESTROOT__ resolution unchanged by placing the admitted copy alongside
/// the built manifest. The copy and its injected fixture root live for this run.
pub(super) fn prepare_run(manifest: &Path, owned_root: &str) -> Result<tempfile::NamedTempFile> {
    let mut value = Value::from_file(manifest).map_err(Error::from)?;
    let root = value
        .as_dictionary_mut()
        .ok_or(reject("run_environment", "not_dictionary"))?;
    let target = if root.contains_key("TestConfigurations") {
        root.get_mut("TestConfigurations")
            .and_then(Value::as_array_mut)
            .and_then(|v| v.first_mut())
            .and_then(Value::as_dictionary_mut)
            .and_then(|v| v.get_mut("TestTargets"))
            .and_then(Value::as_array_mut)
            .and_then(|v| v.first_mut())
            .and_then(Value::as_dictionary_mut)
    } else {
        root.get_mut("BleatAppTests")
            .and_then(Value::as_dictionary_mut)
    }
    .ok_or(reject("run_environment", "missing_target"))?;
    let environment = target
        .get_mut("EnvironmentVariables")
        .and_then(Value::as_dictionary_mut)
        .ok_or(reject("run_environment", "missing_environment"))?;
    environment.insert(
        "BLEAT_MACOS_TEST_ROOT".to_owned(),
        Value::String(owned_root.to_owned()),
    );
    let copy = tempfile::Builder::new()
        .prefix("admitted-")
        .suffix(".xctestrun")
        .tempfile_in(
            manifest
                .parent()
                .ok_or(reject("run_environment", "missing_products"))?,
        )?;
    value.to_file_xml(copy.path()).map_err(Error::from)?;
    Ok(copy)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rejects_production_and_adhoc_signatures_and_wrong_team() {
        assert!(
            validate_signature_identity(
                "Authority=Apple Development: Fixture\nTeamIdentifier=TEST",
                "TEST"
            )
            .is_ok()
        );
        for details in [
            "Signature=adhoc\nTeamIdentifier=TEST",
            "Authority=Developer ID Application: Fixture\nTeamIdentifier=TEST",
            "Authority=Apple Development: Fixture\nTeamIdentifier=OTHER",
        ] {
            assert!(validate_signature_identity(details, "TEST").is_err());
        }
    }
    #[test]
    fn rejects_production_bundle_identity_and_capabilities() {
        let mut info = plist::Dictionary::new();
        info.insert(
            "CFBundleIdentifier".into(),
            Value::String("com.terminaloutcomes.Bleat".into()),
        );
        assert!(validate_identity(&Value::Dictionary(info.clone()), HOST_ID).is_err());
        info.insert("CFBundleIdentifier".into(), Value::String(HOST_ID.into()));
        assert!(validate_identity(&Value::Dictionary(info), HOST_ID).is_ok());
        let mut entitlements = plist::Dictionary::new();
        assert!(validate_entitlements(&Value::Dictionary(entitlements.clone())).is_ok());
        entitlements.insert("keychain-access-groups".into(), Value::Array(vec![]));
        assert!(validate_entitlements(&Value::Dictionary(entitlements)).is_err());
    }
    #[test]
    fn admits_exact_manifest_and_rejects_changed_host_bundle_target_or_admission() {
        let root = tempfile::tempdir().expect("owned products");
        let host = root.path().join("MacTesting/Bleat.app");
        fs::create_dir_all(host.join("Contents/MacOS")).expect("host folder");
        fs::write(host.join("Contents/MacOS/Bleat"), b"fixture").expect("host executable");
        fs::create_dir_all(host.join("Contents/PlugIns/BleatAppTests.xctest"))
            .expect("test bundle");
        let fixture = r#"<?xml version="1.0"?><plist version="1.0"><dict><key>TestConfigurations</key><array><dict><key>TestTargets</key><array><dict>
            <key>BlueprintName</key><string>BleatAppTests</string>
            <key>TestHostPath</key><string>__TESTROOT__/MacTesting/Bleat.app/Contents/MacOS/Bleat</string>
            <key>TestBundlePath</key><string>__TESTHOST__/Contents/PlugIns/BleatAppTests.xctest</string>
            <key>TestHostBundleIdentifier</key><string>com.terminaloutcomes.Bleat.MacTestHost</string>
            <key>EnvironmentVariables</key><dict><key>BLEAT_MACOS_TEST_HOST</key><string>1</string></dict>
        </dict></array></dict></array></dict></plist>"#;
        let value = Value::from_reader_xml(fixture.as_bytes()).expect("manifest fixture");
        assert!(validate_manifest(&value, root.path()).is_ok());
        let mut target = one(
            array(
                one(array(&value, "TestConfigurations"), "config").expect("config"),
                "TestTargets",
            ),
            "target",
        )
        .expect("target")
        .clone();
        target.as_dictionary_mut().expect("target").insert(
            "TestHostPath".to_owned(),
            Value::String("__TESTROOT__/MacTesting/Bleat.app".to_owned()),
        );
        let mut v1 = plist::Dictionary::new();
        v1.insert("BleatAppTests".to_owned(), target);
        assert!(validate_manifest(&Value::Dictionary(v1.clone()), root.path()).is_ok());
        v1.insert(
            "UnexpectedTests".to_owned(),
            Value::Dictionary(plist::Dictionary::new()),
        );
        assert!(matches!(
            validate_manifest(&Value::Dictionary(v1), root.path()),
            Err(Error::Rejected {
                stage: "manifest_targets",
                ..
            })
        ));

        for (key, replacement, stage) in [
            ("BlueprintName", "BleatUITests", "manifest_target"),
            (
                "TestHostBundleIdentifier",
                "com.terminaloutcomes.Bleat",
                "manifest_identity",
            ),
            ("TestHostPath", "__TESTROOT__", "manifest_host"),
            ("TestBundlePath", "__TESTHOST__", "manifest_bundle"),
        ] {
            let mut invalid = value.clone();
            let target = invalid
                .as_dictionary_mut()
                .expect("manifest")
                .get_mut("TestConfigurations")
                .expect("configs")
                .as_array_mut()
                .expect("array")[0]
                .as_dictionary_mut()
                .expect("config")
                .get_mut("TestTargets")
                .expect("targets")
                .as_array_mut()
                .expect("array")[0]
                .as_dictionary_mut()
                .expect("target");
            target.insert(key.into(), Value::String(replacement.into()));
            assert!(
                matches!(validate_manifest(&invalid, root.path()), Err(Error::Rejected {stage: actual, ..}) if actual == stage)
            );
        }
        let missing = fixture.replace("<string>1</string>", "<string>0</string>");
        let missing = Value::from_reader_xml(missing.as_bytes()).expect("missing marker fixture");
        assert!(matches!(
            validate_manifest(&missing, root.path()),
            Err(Error::Rejected {
                stage: "manifest_environment",
                ..
            })
        ));
    }

    #[test]
    fn prepared_run_owns_a_copy_and_injects_only_its_fixture_root() {
        let directory = tempfile::tempdir().expect("owned products");
        let manifest = directory.path().join("BleatMac_fixture.xctestrun");
        let original = Value::from_reader_xml(br#"<plist version="1.0"><dict><key>TestConfigurations</key><array><dict><key>TestTargets</key><array><dict><key>EnvironmentVariables</key><dict><key>BLEAT_MACOS_TEST_HOST</key><string>1</string></dict></dict></array></dict></array></dict></plist>"#.as_slice()).expect("built plan fixture");
        original.to_file_xml(&manifest).expect("write original");
        let path;
        {
            let admitted = prepare_run(&manifest, "synthetic-owned-root").expect("admitted copy");
            path = admitted.path().to_owned();
            assert_eq!(path.parent(), manifest.parent());
            assert_ne!(path, manifest);
            let prepared = Value::from_file(&path).expect("read copy");
            let configuration =
                one(array(&prepared, "TestConfigurations"), "config").expect("configuration");
            let target = one(array(configuration, "TestTargets"), "target").expect("target");
            let environment = &target.as_dictionary().expect("target")["EnvironmentVariables"];
            assert_eq!(text(environment, "BLEAT_MACOS_TEST_HOST"), Some("1"));
            assert_eq!(
                text(environment, "BLEAT_MACOS_TEST_ROOT"),
                Some("synthetic-owned-root")
            );
            assert_eq!(
                Value::from_file(&manifest).expect("original survives"),
                original
            );
        }
        assert!(!path.exists());
        assert!(manifest.exists());
    }

    #[test]
    fn scheme_runs_the_application_and_confines_isolation_to_tests() {
        let root = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("repository root");
        let scheme = fs::read_to_string(
            root.join("Bleat.xcodeproj/xcshareddata/xcschemes/BleatMac.xcscheme"),
        )
        .expect("generated macOS scheme");
        let document = roxmltree::Document::parse(&scheme).expect("scheme XML");
        let action = |name| {
            document
                .descendants()
                .find(|node| node.has_tag_name(name))
                .expect("scheme action")
        };
        assert_eq!(
            action("LaunchAction").attribute("buildConfiguration"),
            Some("Debug")
        );
        assert_eq!(
            action("TestAction").attribute("buildConfiguration"),
            Some("MacTesting")
        );
    }

    #[test]
    fn rejects_empty_and_multiple_test_configurations() {
        for count in [0, 2] {
            let mut manifest = plist::Dictionary::new();
            manifest.insert(
                "TestConfigurations".into(),
                Value::Array(
                    (0..count)
                        .map(|_| Value::Dictionary(plist::Dictionary::new()))
                        .collect(),
                ),
            );
            assert!(matches!(
                validate_manifest(&Value::Dictionary(manifest), Path::new("unused")),
                Err(Error::Rejected {
                    stage: "manifest_configurations",
                    ..
                })
            ));
        }
    }
}
