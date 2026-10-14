use scripts::release_version_check::{ReleaseVersionError, validate_metadata};
use serde_json::{Value, json};

const PROJECT: &str = "targets:\n  BleatApp:\n    settings:\n      base:\n        MARKETING_VERSION: \"2026.10.11\"\n        CURRENT_PROJECT_VERSION: \"20261011.0102.03\"\n";
const CHANGELOG: &str = "# Changelog\n\n## 2026.10.11 - 2026-10-11\n\n### Fixed\n\n- Fixed startup recovery.\n\n## 2026.10.08 - 2026-10-08\n\n- Older release.\n";

fn generated() -> Value {
    json!({"objects": {
        "debug": {"isa": "XCBuildConfiguration", "name": "Debug", "buildSettings": {"MARKETING_VERSION": "2026.10.11", "CURRENT_PROJECT_VERSION": "20261011.0102.03"}},
        "release": {"isa": "XCBuildConfiguration", "name": "Release", "buildSettings": {"MARKETING_VERSION": "2026.10.11", "CURRENT_PROJECT_VERSION": "20261011.0102.03"}}
    }})
}

#[test]
fn accepts_consistent_metadata_and_effective_build_version() {
    for requested in [None, Some("2026.10.11")] {
        assert_eq!(
            validate_metadata(PROJECT, &generated(), CHANGELOG, requested)
                .expect("consistent metadata"),
            "2026.10.11"
        );
    }
}

#[test]
fn rejects_timestamp_or_cli_override_without_source_bump() {
    let result = validate_metadata(PROJECT, &generated(), CHANGELOG, Some("2026.10.12"));
    assert!(matches!(
        result,
        Err(ReleaseVersionError::RequestedMismatch { .. })
    ));
    let old_project = PROJECT.replace("2026.10.11", "2026.10.08");
    assert!(matches!(
        validate_metadata(&old_project, &generated(), CHANGELOG, Some("2026.10.11")),
        Err(ReleaseVersionError::RequestedMismatch { .. })
    ));
}

#[test]
fn rejects_stale_missing_or_wrong_generated_configurations() {
    for name in ["debug", "release"] {
        let mut project = generated();
        project["objects"][name]["buildSettings"]["MARKETING_VERSION"] = json!("2026.10.08");
        assert!(matches!(
            validate_metadata(PROJECT, &project, CHANGELOG, None),
            Err(ReleaseVersionError::GeneratedMismatch)
        ));
        project["objects"][name]["buildSettings"]
            .as_object_mut()
            .expect("settings object")
            .remove("MARKETING_VERSION");
        assert!(matches!(
            validate_metadata(PROJECT, &project, CHANGELOG, None),
            Err(ReleaseVersionError::GeneratedMismatch)
        ));
    }
}

#[test]
fn rejects_wrong_or_missing_built_app_versions_before_installing() {
    use scripts::release_version_check::validate_built_app;
    let root = tempfile::tempdir().expect("app fixture");
    let file = root.path().join("Info.plist");
    let mut metadata = std::collections::BTreeMap::from([
        ("CFBundleShortVersionString", "2026.10.11"),
        ("CFBundleVersion", "20261011.0102.03"),
    ]);
    plist::to_file_binary(&file, &metadata).expect("binary plist");
    assert!(validate_built_app(&file, "2026.10.11", "20261011.0102.03").is_ok());
    metadata.insert("CFBundleShortVersionString", "2026.10.08");
    plist::to_file_xml(&file, &metadata).expect("stale app version");
    assert!(matches!(
        validate_built_app(&file, "2026.10.11", "20261011.0102.03"),
        Err(ReleaseVersionError::BuiltMetadataMismatch(
            "CFBundleShortVersionString"
        ))
    ));
    metadata.insert("CFBundleShortVersionString", "2026.10.11");
    metadata.insert("CFBundleVersion", "2");
    plist::to_file_xml(&file, &metadata).expect("stale build number");
    assert!(matches!(
        validate_built_app(&file, "2026.10.11", "20261011.0102.03"),
        Err(ReleaseVersionError::BuiltMetadataMismatch(
            "CFBundleVersion"
        ))
    ));
    metadata.remove("CFBundleVersion");
    plist::to_file_xml(&file, &metadata).expect("missing build number");
    assert!(matches!(
        validate_built_app(&file, "2026.10.11", "20261011.0102.03"),
        Err(ReleaseVersionError::BuiltMetadataMissing("CFBundleVersion"))
    ));
}

#[test]
fn accepts_later_rebuilds_but_rejects_invalid_or_predating_timestamps() {
    use scripts::release_version_check::validate_effective_build;
    assert!(validate_effective_build("2026.10.11", "20261011.1234.56").is_ok());
    assert!(validate_effective_build("2026.10.11", "20261014.1234.56").is_ok());
    assert!(matches!(
        validate_effective_build("2026.10.11", "20261008.1234.56"),
        Err(ReleaseVersionError::EffectiveBuildPrecedesVersion)
    ));
    for build in ["2", "20261011.9999.99", "20261011.2400.00"] {
        assert!(matches!(
            validate_effective_build("2026.10.11", build),
            Err(ReleaseVersionError::EffectiveBuildMismatch)
        ));
    }
}

#[test]
fn rejects_stale_fallback_build_numbers() {
    let project = PROJECT.replace("20261011.0102.03", "20261008.0102.03");
    assert!(matches!(
        validate_metadata(&project, &generated(), CHANGELOG, None),
        Err(ReleaseVersionError::BuildMismatch)
    ));
    let mut generated = generated();
    generated["objects"]["release"]["buildSettings"]["CURRENT_PROJECT_VERSION"] = json!("2");
    assert!(matches!(
        validate_metadata(PROJECT, &generated, CHANGELOG, None),
        Err(ReleaseVersionError::BuildMismatch)
    ));
}

#[test]
fn rejects_missing_duplicate_stale_or_empty_release_notes() {
    let changelogs = [
        "# Changelog\n",
        "## 2026.10.08 - 2026-10-08\n- Old release.\n",
        "## 2026.10.11 - 2026-10-10\n- Wrong date.\n",
        "## 2026.10.11 - 2026-10-11\n### Fixed\n",
        "## 2026.10.11 - 2026-10-11\n- One.\n## 2026.10.11 - 2026-10-11\n- Two.\n",
        "## 2026.10.12 - 2026-10-12\n- Newer.\n## 2026.10.11 - 2026-10-11\n- Old.\n",
    ];
    for changelog in changelogs {
        assert!(matches!(
            validate_metadata(PROJECT, &generated(), changelog, None),
            Err(ReleaseVersionError::ChangelogMismatch(_))
        ));
    }
}

#[test]
fn rejects_malformed_sources_and_invalid_calendar_dates() {
    for project in ["[", "{}", "---\n{}\n---\n{}"] {
        assert!(matches!(
            validate_metadata(project, &generated(), CHANGELOG, None),
            Err(ReleaseVersionError::ProjectInvalid)
        ));
    }
    assert!(matches!(
        validate_metadata(
            &PROJECT.replace("2026.10.11", "2026.02.30"),
            &generated(),
            CHANGELOG,
            None
        ),
        Err(ReleaseVersionError::InvalidVersion(_))
    ));
    assert!(matches!(
        validate_metadata(PROJECT, &json!({}), CHANGELOG, None),
        Err(ReleaseVersionError::GeneratedProjectInvalid)
    ));
}

#[cfg(target_os = "macos")]
#[test]
fn command_rejects_real_pbxproj_version_drift_before_building() {
    use std::{fs, process::Command};
    let root = tempfile::tempdir().expect("temporary fixture");
    fs::create_dir(root.path().join("Bleat.xcodeproj")).expect("project directory");
    fs::write(root.path().join("project.yml"), PROJECT).expect("source version");
    fs::write(root.path().join("CHANGELOG.md"), CHANGELOG).expect("changelog");
    let file = root.path().join("Bleat.xcodeproj/project.pbxproj");
    fs::write(&file, "{ objects = { debug = { isa = XCBuildConfiguration; name = Debug; buildSettings = { MARKETING_VERSION = 2026.10.08; CURRENT_PROJECT_VERSION = 20261011.0102.03; }; }; release = { isa = XCBuildConfiguration; name = Release; buildSettings = { MARKETING_VERSION = 2026.10.11; CURRENT_PROJECT_VERSION = 20261011.0102.03; }; }; }; }").expect("OpenStep fixture");
    let run = || {
        Command::new(env!("CARGO_BIN_EXE_validate-release-version"))
            .arg("--repository-root")
            .arg(root.path())
            .output()
            .expect("validator starts")
    };
    assert!(!run().status.success());
    let project = fs::read_to_string(&file).expect("read generated fixture");
    fs::write(&file, project.replace("2026.10.08", "2026.10.11")).expect("fix fixture");
    assert!(run().status.success());

    // Exercise the upload entry point: a version override must fail before
    // creating evidence, archiving, signing, or contacting Apple.
    use clap::Parser;
    use scripts::app_store_connect::{Arguments, UploadError};
    let args = Arguments::try_parse_from([
        "upload-app-store-connect",
        "--repository-root",
        root.path().to_str().expect("fixture path"),
        "--development-team",
        "AAAAAAAAAA",
        "--bundle-id",
        "com.example.Bleat",
        "--telemetry-auth-base-url",
        "https://example.invalid",
        "--telemetry-otlp-endpoint",
        "https://example.invalid",
        "--build-number",
        "20261012.0102.03",
        "--marketing-version",
        "2026.10.12",
    ])
    .expect("upload arguments");
    assert!(matches!(
        scripts::app_store_connect::run(args),
        Err(UploadError::ReleaseVersion(
            ReleaseVersionError::RequestedMismatch { .. }
        ))
    ));
    assert!(!root.path().join(".build").exists());
}

#[cfg(target_os = "macos")]
#[test]
fn device_rebuild_keeps_source_version_and_generates_next_day_timestamp() {
    use chrono::{TimeZone, Utc};
    use scripts::device_build::resolve_release;
    let root = tempfile::tempdir().expect("temporary repository");
    std::fs::create_dir(root.path().join("Bleat.xcodeproj")).expect("project directory");
    std::fs::write(root.path().join("project.yml"), PROJECT).expect("project metadata");
    std::fs::write(root.path().join("CHANGELOG.md"), CHANGELOG).expect("release notes");
    let project = "{ objects = { debug = { isa = XCBuildConfiguration; name = Debug; buildSettings = { MARKETING_VERSION = 2026.10.11; CURRENT_PROJECT_VERSION = 20261011.0102.03; }; }; release = { isa = XCBuildConfiguration; name = Release; buildSettings = { MARKETING_VERSION = 2026.10.11; CURRENT_PROJECT_VERSION = 20261011.0102.03; }; }; }; }";
    std::fs::write(root.path().join("Bleat.xcodeproj/project.pbxproj"), project)
        .expect("generated project");
    let now = Utc
        .with_ymd_and_hms(2026, 10, 14, 5, 31, 30)
        .single()
        .expect("build date");
    let release = resolve_release(root.path(), None, None, now).expect("later device rebuild");
    assert_eq!(release.version, "2026.10.11");
    assert_eq!(release.build, "20261014.0531.30");
    assert!(matches!(
        resolve_release(root.path(), Some("2026.10.14"), None, now),
        Err(ReleaseVersionError::RequestedMismatch { .. })
    ));
    assert!(matches!(
        resolve_release(root.path(), None, Some("20261008.0102.03"), now),
        Err(ReleaseVersionError::EffectiveBuildPrecedesVersion)
    ));
}

#[test]
fn telemetry_validation_preserves_typed_failure_without_secret_values() {
    use scripts::device_build::{DeviceBuildError, validate_telemetry_url};
    let error = validate_telemetry_url(
        "BLEAT_TELEMETRY_AUTH_BASE_URL",
        "https://user:SECRET-MARKER@example.invalid:bad?token=QUERY-MARKER",
    )
    .expect_err("malformed endpoint");
    assert!(matches!(error, DeviceBuildError::TelemetryInvalid { .. }));
    let message = error.to_string();
    assert!(!message.contains("SECRET-MARKER"));
    assert!(!message.contains("QUERY-MARKER"));
    assert!(message.contains("BLEAT_TELEMETRY_AUTH_BASE_URL"));
    assert!(matches!(
        validate_telemetry_url("endpoint", "http://example.invalid"),
        Err(DeviceBuildError::TelemetryRequiresHttps { .. })
    ));
    assert!(validate_telemetry_url("endpoint", "https://example.invalid").is_ok());
}
