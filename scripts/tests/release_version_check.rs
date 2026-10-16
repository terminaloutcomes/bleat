use build_scripts::release_version_check::ReleaseVersionError;

const PROJECT: &str = "targets:\n  BleatApp:\n    settings:\n      base:\n        MARKETING_VERSION: \"2026.10.11\"\n        CURRENT_PROJECT_VERSION: \"20261011.0102.03\"\n";
const CHANGELOG: &str = "# Changelog\n\n## 2026.10.11 - 2026-10-11\n\n### Fixed\n\n- Fixed startup recovery.\n\n## 2026.10.08 - 2026-10-08\n\n- Older release.\n";

#[cfg(target_os = "macos")]
#[test]
fn upload_rejects_version_override_before_building() {
    use std::fs;
    let root = tempfile::tempdir().expect("temporary fixture");
    fs::create_dir(root.path().join("Bleat.xcodeproj")).expect("project directory");
    fs::write(root.path().join("project.yml"), PROJECT).expect("source version");
    fs::write(root.path().join("CHANGELOG.md"), CHANGELOG).expect("changelog");
    fs::write(root.path().join("Bleat.xcodeproj/project.pbxproj"), "{ objects = { debug = { isa = XCBuildConfiguration; name = Debug; buildSettings = { MARKETING_VERSION = 2026.10.11; CURRENT_PROJECT_VERSION = 20261011.0102.03; }; }; release = { isa = XCBuildConfiguration; name = Release; buildSettings = { MARKETING_VERSION = 2026.10.11; CURRENT_PROJECT_VERSION = 20261011.0102.03; }; }; }; }").expect("OpenStep fixture");

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
