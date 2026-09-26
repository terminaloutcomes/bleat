use std::process::Command;

use chrono::{TimeZone, Utc};
use scripts::release_versions::{self, VersionError};

#[test]
fn generates_and_validates_build_numbers() {
    let now = Utc
        .with_ymd_and_hms(2026, 9, 26, 12, 3, 4)
        .single()
        .expect("valid date");
    assert_eq!(
        release_versions::resolve_build_number(None, now).expect("generated build"),
        "20260926.1203.04"
    );
    assert_eq!(
        release_versions::resolve_build_number(Some(""), now).expect("empty override"),
        "20260926.1203.04"
    );
    assert_eq!(
        release_versions::resolve_build_number(Some("7.2"), now).expect("custom build"),
        "7.2"
    );
    for invalid in ["", ".1", "1.", "1..2", "1.2.3.4", "1.a", "1/2"] {
        if invalid.is_empty() {
            continue;
        }
        assert_eq!(
            release_versions::resolve_build_number(Some(invalid), now),
            Err(VersionError::InvalidBuildNumber)
        );
    }
}

#[test]
fn derives_and_validates_marketing_versions() {
    assert_eq!(
        release_versions::resolve_marketing_version("20240229.1203.04", None).expect("leap day"),
        "2024.02.29"
    );
    assert_eq!(
        release_versions::resolve_marketing_version("7", Some("2026.09.26"))
            .expect("explicit version"),
        "2026.09.26"
    );
    assert_eq!(
        release_versions::resolve_marketing_version("7", None),
        Err(VersionError::MissingMarketingVersionForCustomBuild)
    );
    assert_eq!(
        release_versions::resolve_marketing_version("7", Some("2026.9.26")),
        Err(VersionError::InvalidMarketingVersionFormat)
    );
    assert_eq!(
        release_versions::resolve_marketing_version("20260229.1203.04", None),
        Err(VersionError::InvalidMarketingVersionDate)
    );
    assert_eq!(
        release_versions::resolve_marketing_version("2026é926.1203.04", None),
        Err(VersionError::MissingMarketingVersionForCustomBuild)
    );
}

#[test]
fn command_line_resolvers_use_environment_without_shells() {
    let before = Utc::now().format("%Y%m%d.%H%M").to_string();
    let generated = Command::new(env!("CARGO_BIN_EXE_resolve-build-number"))
        .env_remove("BLEAT_BUILD_NUMBER")
        .output()
        .expect("build resolver starts");
    let after = Utc::now().format("%Y%m%d.%H%M").to_string();
    assert!(generated.status.success());
    let generated = String::from_utf8(generated.stdout).expect("build output is UTF-8");
    assert!(generated.starts_with(&before) || generated.starts_with(&after));
    assert_eq!(generated.trim_end().len(), 16);

    let build = Command::new(env!("CARGO_BIN_EXE_resolve-build-number"))
        .env("BLEAT_BUILD_NUMBER", "7.2")
        .output()
        .expect("build resolver starts");
    assert!(build.status.success());
    assert_eq!(build.stdout, b"7.2\n");

    let invalid = Command::new(env!("CARGO_BIN_EXE_resolve-build-number"))
        .env("BLEAT_BUILD_NUMBER", "7..2")
        .output()
        .expect("build resolver starts");
    assert_eq!(invalid.status.code(), Some(64));

    let version = Command::new(env!("CARGO_BIN_EXE_resolve-marketing-version"))
        .arg("7.2")
        .env("BLEAT_MARKETING_VERSION", "2026.09.26")
        .output()
        .expect("marketing resolver starts");
    assert!(version.status.success());
    assert_eq!(version.stdout, b"2026.09.26\n");

    let failure = Command::new(env!("CARGO_BIN_EXE_resolve-marketing-version"))
        .arg("7.2")
        .env_remove("BLEAT_MARKETING_VERSION")
        .output()
        .expect("marketing resolver starts");
    assert_eq!(failure.status.code(), Some(65));
}
