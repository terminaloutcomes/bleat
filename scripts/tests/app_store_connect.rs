use scripts::app_store_connect::*;
use std::fs;

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
    let directory = tempfile::tempdir().expect("temporary export options directory");
    let path = directory.path().join("export-options.plist");
    write_export_options(
        &path,
        ExportDestination::Upload,
        "ABCDE12345",
        "com.example.Bleat",
    )
    .expect("export options should serialize");
    let value = plist::Value::from_file(&path).expect("export options should decode");
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
    let directory = tempfile::tempdir().expect("temporary checksum directory");
    let path = directory.path().join("checksum-fixture");
    fs::write(&path, b"abc").expect("checksum fixture should be writable");
    let checksum = sha256(&path).expect("checksum should succeed");
    assert_eq!(
        checksum,
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    );
}

#[test]
fn app_store_token_signing_interoperates_with_rustcrypto_es256() {
    use base64::{
        Engine as _,
        engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD},
    };
    use p256::{
        ecdsa::{Signature, VerifyingKey, signature::Verifier},
        pkcs8::{EncodePrivateKey, LineEnding},
    };

    // Deterministic test-only scalar, never an App Store Connect credential.
    let key = p256::SecretKey::from_slice(&[7; 32]).expect("valid fixture scalar");
    let pem = key.to_pkcs8_pem(LineEnding::LF).expect("fixture PKCS#8");
    let options = CliOpts {
        command: Commands::CreateReport,
        issuer_id: Some("fixture-issuer".to_owned()),
        key_id: Some("fixture-key".to_owned()),
        private_key_base64: Some(STANDARD.encode(pem.as_bytes())),
    };
    let token = generate_app_store_token(&options).expect("AWS-LC should sign PKCS#8 key");
    let parts: Vec<_> = token.split('.').collect();
    assert_eq!(parts.len(), 3);
    let signature_bytes = URL_SAFE_NO_PAD
        .decode(parts[2])
        .expect("base64url signature");
    let signature = Signature::from_slice(&signature_bytes).expect("JOSE signature format");
    let verifying_key = VerifyingKey::from(key.public_key());
    let signed = format!("{}.{}", parts[0], parts[1]);
    verifying_key
        .verify(signed.as_bytes(), &signature)
        .expect("independent ES256 verification");
    let tampered = format!("{signed}x");
    assert!(
        verifying_key
            .verify(tampered.as_bytes(), &signature)
            .is_err()
    );
    let header: serde_json::Value =
        serde_json::from_slice(&URL_SAFE_NO_PAD.decode(parts[0]).expect("header encoding"))
            .expect("header JSON");
    assert_eq!(
        header,
        serde_json::json!({"alg": "ES256", "typ": "JWT", "kid": "fixture-key"})
    );
    let claims: serde_json::Value =
        serde_json::from_slice(&URL_SAFE_NO_PAD.decode(parts[1]).expect("claims encoding"))
            .expect("claims JSON");
    assert_eq!(claims["iss"], "fixture-issuer");
    assert_eq!(claims["aud"], "appstoreconnect-v1");
    assert_eq!(
        claims["exp"].as_u64().unwrap() - claims["iat"].as_u64().unwrap(),
        600
    );
    assert!(claims.get("scope").is_none());

    let mut invalid = options;
    invalid.private_key_base64 = Some(STANDARD.encode(b"invalid key"));
    assert!(matches!(
        generate_app_store_token(&invalid),
        Err(AppStoreTokenError::PrivateKey)
    ));
}
