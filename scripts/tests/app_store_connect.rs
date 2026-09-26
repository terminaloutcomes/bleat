use scripts::app_store_connect::*;
use std::{
    fs,
    time::{SystemTime, UNIX_EPOCH},
};

#[test]
fn validates_release_identifiers() {
    assert!(validate_development_team("ABCDE12345").is_ok());
    assert!(validate_development_team("invalid").is_err());
    assert!(validate_bundle_identifier("com.example.Bleat").is_ok());
    assert!(validate_bundle_identifier("com.example.$(id)").is_err());
    assert!(validate_build_number("20260921.1146.56").is_ok());
    assert!(validate_build_number("2026.09.21.1").is_err());
}

#[test]
fn resolves_public_upload_marketing_version_through_shared_library() {
    let derived = resolve_marketing_version("20260923.0642.54", None)
        .expect("marketing version should be derived");
    assert_eq!(derived, "2026.09.23");

    let overridden = resolve_marketing_version("7", Some("2026.09.23"))
        .expect("marketing-version override should be forwarded");
    assert_eq!(overridden, "2026.09.23");
}

#[test]
fn preserves_typed_marketing_version_failures() {
    assert!(matches!(
        resolve_marketing_version("7", None),
        Err(UploadError::MissingMarketingVersionForCustomBuild)
    ));
    assert!(matches!(
        resolve_marketing_version("7", Some("2026.9.23")),
        Err(UploadError::InvalidMarketingVersionFormat)
    ));
    assert!(matches!(
        resolve_marketing_version("7", Some("2026.02.30")),
        Err(UploadError::InvalidMarketingVersionDate)
    ));
}

#[test]
fn public_export_options_omit_internal_only_restriction() {
    let path = std::env::temp_dir().join(format!(
        "bleat-app-store-options-{}-{}.plist",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("test clock must be after Unix epoch")
            .as_nanos()
    ));
    write_export_options(
        &path,
        ExportDestination::Upload,
        "ABCDE12345",
        "com.example.Bleat",
    )
    .expect("export options should serialize");
    let value = plist::Value::from_file(&path).expect("export options should decode");
    fs::remove_file(&path).expect("temporary export options should be removable");
    let dictionary = value
        .as_dictionary()
        .expect("export options should be a dictionary");
    assert_eq!(dictionary.len(), 7);
    assert_eq!(
        dictionary
            .get("destination")
            .and_then(plist::Value::as_string),
        Some("upload")
    );
    assert_eq!(
        dictionary.get("method").and_then(plist::Value::as_string),
        Some("app-store-connect")
    );
    assert!(!dictionary.contains_key("testFlightInternalTestingOnly"));
}

#[test]
fn computes_standard_sha256_checksum() {
    let path = std::env::temp_dir().join(format!(
        "bleat-app-store-checksum-{}-{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("test clock must be after Unix epoch")
            .as_nanos()
    ));
    fs::write(&path, b"abc").expect("checksum fixture should be writable");
    let checksum = sha256(&path).expect("checksum should succeed");
    fs::remove_file(&path).expect("checksum fixture should be removable");
    assert_eq!(
        checksum,
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    );
}
