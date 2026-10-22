use super::{Error, capture, model::*, native};
use serde_json::{Value, json};
use std::{
    collections::BTreeMap,
    fs,
    path::{Path, PathBuf},
    process::Command,
    thread,
    time::{Duration, Instant},
};
fn root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("workspace")
        .to_path_buf()
}
fn fixture() -> Value {
    read_json(&root().join("TestSupport/ReleaseScreenshots/fixtures.json"))
        .expect("checked-in fixture")
}
fn config(env: BTreeMap<String, String>) -> super::Result<Configuration> {
    Configuration::from_environment(&root(), &env)
}
#[test]
fn release_screenshot_fixture_preserves_hero_and_ordered_ten_scenes() {
    validate_fixture(&fixture()).expect("fixture contracts");
}
#[test]
fn release_screenshot_fixture_rejects_invalid_duration_progress_chapters_and_duplicate_names() {
    for (pointer, value) in [
        ("/books/0/duration", json!(1)),
        ("/books/0/progress/currentTime", json!(46801)),
        ("/books/0/chapters/4/start", json!(17999)),
        ("/screenshots/1/file", json!("00-login.png")),
        ("/books/1/title", json!("Thirteen Hours of Goat Sounds")),
    ] {
        let mut f = fixture();
        *f.pointer_mut(pointer).expect("fixture field") = value;
        assert!(validate_fixture(&f).is_err(), "mutation at {pointer}");
    }
}
#[test]
fn release_screenshot_fixture_rejects_paths_outside_owned_assets() {
    for field in ["cover", "folder", "mediaFile"] {
        let mut f = fixture();
        f["books"][0][field] = json!("../outside");
        assert!(validate_fixture(&f).is_err());
    }
}
#[test]
fn release_screenshot_options_normalize_and_deduplicate_selections() {
    let c = config(BTreeMap::from([(
        "BLEAT_SCREENSHOT_ORIENTATIONS".to_owned(),
        "landscapeLeft, portrait,landscapeLeft".to_owned(),
    )]))
    .expect("valid selections");
    assert_eq!(c.orientations, ["landscapeLeft", "portrait"]);
    assert_eq!(c.appearances, ["light", "dark"]);
}
#[test]
fn release_screenshot_options_reject_empty_invalid_modes_locale_port_and_video() {
    for (key, value) in [
        ("BLEAT_SCREENSHOT_ORIENTATIONS", ""),
        ("BLEAT_SCREENSHOT_ORIENTATIONS", "portrait,upsideDown"),
        ("BLEAT_SCREENSHOT_APPEARANCES", "sepia"),
        ("BLEAT_SCREENSHOT_LOCALE", "en"),
        ("BLEAT_SCREENSHOT_PORT", "65536"),
        ("BLEAT_SCREENSHOT_PORT", "0"),
        ("BLEAT_SCREENSHOT_RECORD_VIDEO", "2"),
        ("BLEAT_SCREENSHOT_DEVICES", "com.apple.iPad"),
    ] {
        assert!(
            config(BTreeMap::from([(key.to_owned(), value.to_owned())])).is_err(),
            "{key}"
        );
    }
}
#[test]
fn release_screenshot_options_allow_phone_only_but_reject_duplicate_devices() {
    assert!(
        config(BTreeMap::from([(
            "BLEAT_SCREENSHOT_DEVICES".to_owned(),
            "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max".to_owned()
        )]))
        .is_ok()
    );
    assert!(
        config(BTreeMap::from([(
            "BLEAT_SCREENSHOT_DEVICES".to_owned(),
            "iPhone,iPhone".to_owned()
        )]))
        .is_err()
    );
}
fn attachment_manifest() -> Value {
    let mut rows = Vec::new();
    for appearance in ["light", "dark"] {
        for screen in fixture()["screenshots"].as_array().expect("screens") {
            let name = screenshot_name(screen["file"].as_str().expect("file"), appearance);
            rows.push(json!({"suggestedHumanReadableName":format!("{}_0_fixture.png",name.trim_end_matches(".png")),"exportedFileName":name}));
        }
    }
    json!([{"attachments":rows}])
}
fn names(mode: &str) -> Vec<String> {
    fixture()["screenshots"]
        .as_array()
        .expect("screens")
        .iter()
        .map(|v| screenshot_name(v["file"].as_str().expect("file"), mode))
        .collect()
}
#[test]
fn release_screenshot_attachment_manifest_requires_exact_complete_light_and_dark_sets() {
    let m = attachment_manifest();
    assert_eq!(
        attachment_files(&m, &names("light")).expect("light").len(),
        10
    );
    assert_eq!(
        attachment_files(&m, &names("dark")).expect("dark").len(),
        10
    );
}
#[test]
fn release_screenshot_attachment_manifest_rejects_missing_duplicate_and_aliased_images() {
    let mut missing = attachment_manifest();
    missing[0]["attachments"]
        .as_array_mut()
        .expect("attachments")
        .pop();
    assert!(attachment_files(&missing, &names("dark")).is_err());
    let mut duplicate = attachment_manifest();
    let a = duplicate[0]["attachments"][0].clone();
    duplicate[0]["attachments"]
        .as_array_mut()
        .expect("attachments")
        .push(a);
    assert!(attachment_files(&duplicate, &names("light")).is_err());
    let mut alias = attachment_manifest();
    alias[0]["attachments"][1]["exportedFileName"] =
        alias[0]["attachments"][0]["exportedFileName"].clone();
    assert!(attachment_files(&alias, &names("light")).is_err());
}
#[test]
fn release_screenshot_attachment_manifest_rejects_export_path_traversal() {
    let mut m = attachment_manifest();
    m[0]["attachments"][0]["exportedFileName"] = json!("../secret.png");
    assert!(attachment_files(&m, &names("light")).is_err());
}
#[test]
fn release_screenshot_dimensions_reject_wrong_device_or_orientation() {
    validate_dimensions((1320, 2868), (1320, 2868), "portrait").expect("portrait");
    validate_dimensions((2868, 1320), (2868, 1320), "landscapeLeft").expect("landscape");
    assert!(validate_dimensions((2064, 2752), (1320, 2868), "portrait").is_err());
    assert!(validate_dimensions((1320, 2868), (1320, 2868), "landscapeLeft").is_err());
    assert!(parse_dimensions("0x2868").is_err());
}
#[test]
fn release_screenshot_public_manifest_rejects_sensitive_nested_keys_and_values() {
    validate_public_manifest(&json!({"app":{"version":"1.0","build":"1"},"screenshots":[{"scenario":"Native password login"}]})).expect("public manifest");
    for value in [
        json!({"nested":[{"accessToken":"synthetic-marker"}]}),
        json!({"description":"prefixBearer synthetic-marker"}),
        json!({"url":"https://fixture.invalid"}),
        json!({"path":"/Users/private"}),
        json!({"value":"refresh-token"}),
    ] {
        assert!(validate_public_manifest(&value).is_err());
    }
}
#[test]
fn release_screenshot_profile_requires_matching_version_and_pinned_digest() {
    let mut v = read_json(&root().join("TestSupport/ServerHarness/profiles/current-stable.json"))
        .expect("profile");
    validate_profile(&v).expect("pinned");
    v["seedVersion"] = json!("0.0.0");
    assert!(validate_profile(&v).is_err());
}
#[test]
fn release_screenshot_runtime_checks_availability_and_device_support() {
    let inventory = json!({"runtimes":[{"identifier":"iOS-26-5","name":"iOS 26.5","version":"26.5","isAvailable":true,"supportedDeviceTypes":[{"identifier":"iPhone"}]}]});
    assert_eq!(
        capture::resolve_runtime(&inventory, None, &["iPhone".to_owned()]).expect("supported"),
        "iOS-26-5"
    );
    assert!(capture::resolve_runtime(&inventory, Some("missing"), &[]).is_err());
    assert!(capture::resolve_runtime(&inventory, None, &["iPad".to_owned()]).is_err());
}
#[test]
fn release_screenshot_summary_rejects_zero_tests_skip_failure_and_runtime_warning() {
    let good = json!({"result":"Passed","passedTests":1,"totalTestCount":1,"failedTests":0,"skippedTests":0,"expectedFailures":0,"runtimeWarnings":[]});
    capture::verify_summary(&good).expect("exact unskipped summary");
    for (field, value) in [
        ("passedTests", json!(0)),
        ("totalTestCount", json!(0)),
        ("skippedTests", json!(1)),
        ("failedTests", json!(1)),
        ("expectedFailures", json!(1)),
        ("runtimeWarnings", json!([{"message":"warning"}])),
    ] {
        let mut v = good.clone();
        v[field] = value;
        assert!(capture::verify_summary(&v).is_err());
    }
}
#[test]
fn release_screenshot_xctestrun_environment_targets_only_ui_tests() {
    let mut plan=plist::Value::from_reader_xml(std::io::Cursor::new(br#"<?xml version="1.0"?><plist version="1.0"><dict><key>BleatUITests</key><dict><key>EnvironmentVariables</key><dict><key>KEEP</key><string>value</string></dict></dict><key>BleatAppTests</key><dict/></dict></plist>"#)).expect("plist");
    let env = BTreeMap::from([(
        "BLEAT_SCREENSHOT_PASSWORD".to_owned(),
        "synthetic-marker".to_owned(),
    )]);
    assert_eq!(capture::install_test_environment(&mut plan, false, &env), 1);
    let dict = plan.as_dictionary().expect("dict");
    assert!(
        dict["BleatAppTests"]
            .as_dictionary()
            .expect("app")
            .is_empty()
    );
    let ui = dict["BleatUITests"].as_dictionary().expect("ui")["EnvironmentVariables"]
        .as_dictionary()
        .expect("env");
    assert_eq!(ui["KEEP"].as_string(), Some("value"));
    assert_eq!(
        ui["BLEAT_SCREENSHOT_PASSWORD"].as_string(),
        Some("synthetic-marker")
    );
}
#[test]
fn release_screenshot_redaction_removes_credentials_without_erasing_useful_failure() {
    let raw = "upstream failed: Authorization: Bearer jwt.marker and {\"password\":\"pw-marker\",\"refreshToken\":\"refresh-marker\"}";
    let redacted = capture::redact(raw, "pw-marker");
    assert!(redacted.contains("upstream failed"));
    for secret in ["pw-marker", "jwt.marker", "refresh-marker"] {
        assert!(!redacted.contains(secret));
    }
}
#[test]
fn release_screenshot_source_launch_contract_is_explicit_not_runtime_evidence() {
    let test =
        fs::read_to_string(root().join("Tests/BleatUITests/BleatReleaseScreenshotTests.swift"))
            .expect("source");
    let app = fs::read_to_string(root().join("App/BleatApp.swift")).expect("source");
    let flag = "--release-screenshot-disable-nearby-server-discovery";
    assert!(
        test.contains(flag)
            && test.contains("BLEAT_SCREENSHOT_ENABLED")
            && test.contains("app.launchArguments = [")
    );
    assert!(app.contains(flag) && app.contains("NoResultsNearbyServerDiscovery()"));
}
#[test]
fn release_screenshot_disk_guard_rejects_before_spawning_a_command() {
    let dir = tempfile::tempdir().expect("temp");
    let mut native = native::Native::new(dir.path().to_owned()).expect("native");
    native.space_probe = |_, minimum| {
        Err(Error::Disk {
            available: 0,
            minimum,
        })
    };
    native.guarding.set(true);
    let mut command = Command::new("not-an-executable");
    assert!(matches!(
        native.run("not spawned", &mut command, 1, true),
        Err(Error::Disk { .. })
    ));
}
#[test]
fn release_screenshot_native_deadline_preserves_owned_retirement() {
    const CHILD: &str = "BLEAT_SCREENSHOT_DEADLINE_CHILD";
    if std::env::var_os(CHILD).is_some() {
        loop {
            thread::park_timeout(Duration::from_secs(10));
        }
    }
    let native = native::Native::new(root()).expect("native");
    let mut command = Command::new(std::env::current_exe().expect("test binary"));
    command.args(["--exact","release_screenshots::tests::release_screenshot_native_deadline_preserves_owned_retirement"]).env(CHILD,"1");
    let error = native
        .run("deadline child", &mut command, 1, true)
        .expect_err("deadline");
    match error {
        Error::Native { source, .. } => {
            assert!(matches!(
                source.cause,
                crate::ci_smoke::owned_command::Cause::Deadline { .. }
            ));
            assert!(source.cleanup.as_ref().is_some_and(|c| c.succeeded()));
        }
        other => panic!("unexpected {other}"),
    }
}
#[test]
fn release_screenshot_recording_flushes_after_graceful_interrupt_before_retirement() {
    const CHILD: &str = "BLEAT_SCREENSHOT_RECORDING_CHILD";
    if let Some(path) = std::env::var_os(CHILD) {
        let stopped = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        signal_hook::flag::register(libc::SIGINT, stopped.clone()).expect("signal");
        fs::write(PathBuf::from(&path).with_extension("ready"), b"ready").expect("ready");
        while !stopped.load(std::sync::atomic::Ordering::SeqCst) {
            thread::park_timeout(Duration::from_millis(10));
        }
        fs::write(path, b"flushed recording").expect("flush");
        return;
    }
    let dir = tempfile::tempdir().expect("temp");
    let path = dir.path().join("recording.mp4");
    let native = native::Native::new(root()).expect("native");
    let mut command = Command::new(std::env::current_exe().expect("test binary"));
    command.args(["--exact","release_screenshots::tests::release_screenshot_recording_flushes_after_graceful_interrupt_before_retirement"]).env(CHILD,&path);
    let recording =
        native::Recording::spawn(&native, &mut command, path.clone(), true).expect("recording");
    let deadline = Instant::now() + Duration::from_secs(5);
    while !path.with_extension("ready").exists() {
        assert!(Instant::now() < deadline, "child readiness");
        thread::park_timeout(Duration::from_millis(10));
    }
    recording.stop().expect("flushed and retired");
    assert_eq!(fs::read(path).expect("recording"), b"flushed recording");
}
#[test]
fn release_screenshot_fixture_missing_cover_is_rejected_before_native_image_inspection() {
    let dir = tempfile::tempdir().expect("temp");
    let mut value = fixture();
    value["books"][0]["cover"] = json!("covers/missing.png");
    let path = dir.path().join("fixture.json");
    write_json(&path, &value).expect("fixture");
    let native = native::Native::new(root()).expect("native");
    assert!(super::Fixture::load(&path, &root(), &native).is_err());
}
#[test]
fn release_screenshot_image_metadata_requires_positive_decoded_dimensions() {
    assert_eq!(
        native::parse_sips("image.png\n  pixelWidth: 1320\n  pixelHeight: 2868\n")
            .expect("dimensions"),
        (1320, 2868)
    );
    for input in [
        "",
        "pixelWidth: 1320\npixelHeight: 0",
        "pixelWidth: <nil>\npixelHeight: 2868",
    ] {
        assert!(native::parse_sips(input).is_err());
    }
}
#[test]
fn release_screenshot_output_admission_preserves_previous_evidence() {
    let dir = tempfile::tempdir().expect("temp");
    let output = dir.path().join("capture");
    capture::claim_output(&output).expect("new output");
    fs::write(output.join("retained-receipt.json"), b"prior evidence").expect("receipt");
    assert!(capture::claim_output(&output).is_err());
    assert_eq!(
        fs::read(output.join("retained-receipt.json")).expect("preserved"),
        b"prior evidence"
    );
}
#[test]
fn release_screenshot_cleanup_does_not_certify_malformed_or_owned_simulator_inventory() {
    let owned = vec!["owned-id".to_owned()];
    capture::verify_simulators_absent(
        &json!({"devices":{"runtime":[{"udid":"unrelated-id"}]}}),
        &owned,
    )
    .expect("unrelated device preserved");
    for value in [
        json!({}),
        json!({"devices":{"runtime":null}}),
        json!({"devices":{"runtime":[{}]}}),
        json!({"devices":{"runtime":[{"udid":"owned-id"}]}}),
    ] {
        assert!(capture::verify_simulators_absent(&value, &owned).is_err());
    }
}
