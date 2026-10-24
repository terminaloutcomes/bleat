use build_scripts::release_version_check::{ReleaseVersionError, validate_metadata};
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
    use build_scripts::release_version_check::validate_built_app;
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
    use build_scripts::release_version_check::validate_effective_build;
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

#[test]
fn validates_every_explicit_configuration_including_macos_test_host() {
    let project =
        format!("configs:\n  Debug: debug\n  Release: release\n  MacTesting: debug\n{PROJECT}");
    let mut value = generated();
    value["objects"]["mac-tests"] = value["objects"]["debug"].clone();
    value["objects"]["mac-tests"]["name"] = json!("MacTesting");
    assert!(validate_metadata(&project, &value, CHANGELOG, None).is_ok());
    value["objects"]["mac-tests"]["buildSettings"]["MARKETING_VERSION"] = json!("2026.10.08");
    assert!(matches!(
        validate_metadata(&project, &value, CHANGELOG, None),
        Err(ReleaseVersionError::GeneratedMismatch)
    ));
    assert!(matches!(
        validate_metadata(&project, &generated(), CHANGELOG, None),
        Err(ReleaseVersionError::GeneratedMismatch)
    ));
    assert!(matches!(
        validate_metadata(PROJECT, &value, CHANGELOG, None),
        Err(ReleaseVersionError::GeneratedMismatch)
    ));
}
