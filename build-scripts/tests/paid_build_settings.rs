use std::collections::BTreeMap;

use build_scripts::paid_build_settings::{PaidBuildSettingsError as Error, validate_environment};

fn settings(platform: &str) -> BTreeMap<String, String> {
    BTreeMap::from([
        ("BUILD_WITHOUT_PAID_DEVELOPER".to_owned(), "NO".to_owned()),
        ("BLEAT_CLOUDKIT_MODE".to_owned(), "enabled".to_owned()),
        ("PLATFORM_NAME".to_owned(), platform.to_owned()),
        ("BLEAT_APP_ATTEST_MODE".to_owned(), "enabled".to_owned()),
        ("BLEAT_CARPLAY_MODE".to_owned(), "disabled".to_owned()),
        (
            "BLEAT_TELEMETRY_AUTH_BASE_URL".to_owned(),
            "https://telemetry.example.invalid/auth".to_owned(),
        ),
        (
            "BLEAT_TELEMETRY_OTLP_ENDPOINT".to_owned(),
            "https://telemetry.example.invalid".to_owned(),
        ),
    ])
}

fn validate(values: &BTreeMap<String, String>) -> Result<Vec<String>, Error> {
    validate_environment(|name| values.get(name).cloned().ok_or(()))
}

#[test]
fn validates_common_and_macos_settings_without_requiring_telemetry_values() {
    let mut values = settings("macosx");
    values.remove("BLEAT_APP_ATTEST_MODE");
    values.remove("BLEAT_CARPLAY_MODE");
    values.remove("BLEAT_TELEMETRY_AUTH_BASE_URL");
    values.remove("BLEAT_TELEMETRY_OTLP_ENDPOINT");

    let messages = validate(&values).expect("macOS settings");
    assert_eq!(messages.len(), 4);
    assert!(
        messages
            .last()
            .is_some_and(|message| message.contains("telemetry checks skipped"))
    );
}

#[test]
fn validates_ios_secure_endpoints_and_debug_loopback() {
    let values = settings("iphoneos");
    let messages = validate(&values).expect("secure iOS settings");
    assert!(
        messages
            .iter()
            .any(|message| message.contains("BLEAT_APP_ATTEST_MODE"))
    );
    assert!(
        messages
            .iter()
            .any(|message| message.contains("OTLP_ENDPOINT is set"))
    );

    let mut debug = settings("iphonesimulator");
    debug.insert("CONFIGURATION".to_owned(), "Debug".to_owned());
    debug.insert(
        "BLEAT_TELEMETRY_AUTH_BASE_URL".to_owned(),
        "http://localhost:8080/auth".to_owned(),
    );
    validate(&debug).expect("debug loopback HTTP");
}

#[test]
fn reports_typed_missing_and_invalid_common_settings_with_original_exit_codes() {
    let mut missing = settings("macosx");
    missing.remove("BUILD_WITHOUT_PAID_DEVELOPER");
    let error = validate(&missing).expect_err("required variable");
    assert!(matches!(error, Error::MissingEnvironmentVariable { .. }));
    assert_eq!(error.exit_code(), 1);

    let mut invalid = settings("macosx");
    invalid.insert("BLEAT_CLOUDKIT_MODE".to_owned(), "YES".to_owned());
    let error = validate(&invalid).expect_err("unsupported mode");
    assert!(matches!(error, Error::InvalidAllowedValue { .. }));
    assert_eq!(error.exit_code(), 2);
}

#[test]
fn rejects_insecure_auth_urls_and_non_origin_otlp_endpoints() {
    let mut values = settings("iphoneos");
    values.insert(
        "BLEAT_TELEMETRY_AUTH_BASE_URL".to_owned(),
        "http://telemetry.example.invalid/auth".to_owned(),
    );
    assert!(matches!(
        validate(&values),
        Err(Error::InsecureTelemetryAuthBaseUrl)
    ));

    values.insert(
        "BLEAT_TELEMETRY_AUTH_BASE_URL".to_owned(),
        "http://localhost:8080/auth".to_owned(),
    );
    assert!(matches!(
        validate(&values),
        Err(Error::InsecureTelemetryAuthBaseUrl)
    ));

    values.insert("CONFIGURATION".to_owned(), "Debug".to_owned());
    values.insert(
        "BLEAT_TELEMETRY_OTLP_ENDPOINT".to_owned(),
        "https://telemetry.example.invalid/path".to_owned(),
    );
    assert!(matches!(
        validate(&values),
        Err(Error::TelemetryUrlMustBeOrigin { .. })
    ));
}

#[test]
fn rejects_otlp_policy_violations_by_typed_variant() {
    let cases = [
        (
            "http://telemetry.example.invalid",
            Error::OtlpEndpointMustUseHttps,
        ),
        (
            "https://telemetry.example.invalid/#section",
            Error::OtlpEndpointHasFragment,
        ),
        (
            "https://telemetry.example.invalid/?mode=debug",
            Error::OtlpEndpointHasQuery,
        ),
        (
            "https://user:password@telemetry.example.invalid",
            Error::OtlpEndpointHasCredentials,
        ),
    ];
    for (endpoint, expected) in cases {
        let mut values = settings("iphonesimulator");
        values.insert("CONFIGURATION".to_owned(), "Debug".to_owned());
        values.insert(
            "BLEAT_TELEMETRY_AUTH_BASE_URL".to_owned(),
            "http://127.0.0.1:8080/auth".to_owned(),
        );
        values.insert(
            "BLEAT_TELEMETRY_OTLP_ENDPOINT".to_owned(),
            endpoint.to_owned(),
        );
        let actual = validate(&values).expect_err("invalid OTLP endpoint");
        assert_eq!(actual, expected);
        assert_eq!(actual.exit_code(), 2);
    }
}

#[test]
fn rejects_invalid_telemetry_urls_without_losing_the_variable_identity() {
    let mut values = settings("iphoneos");
    values.insert(
        "BLEAT_TELEMETRY_AUTH_BASE_URL".to_owned(),
        "https://host:bad".to_owned(),
    );
    assert!(matches!(
        validate(&values),
        Err(Error::InvalidTelemetryUrl {
            name: "BLEAT_TELEMETRY_AUTH_BASE_URL",
            ..
        })
    ));
}

#[test]
fn accepts_https_loopback_for_instrumented_release_simulator() {
    for host in ["localhost", "127.0.0.1"] {
        let mut values = settings("iphonesimulator");
        values.insert("CONFIGURATION".to_owned(), "Release".to_owned());
        values.insert(
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS".to_owned(),
            "OTHER_FLAG BLEAT_RELEASE_SECRET_SCAN ANOTHER_FLAG".to_owned(),
        );
        values.insert(
            "BLEAT_TELEMETRY_AUTH_BASE_URL".to_owned(),
            format!("https://{host}:8443"),
        );
        values.insert(
            "BLEAT_TELEMETRY_OTLP_ENDPOINT".to_owned(),
            format!("https://{host}:8444"),
        );
        validate(&values).expect("instrumented Release Simulator requires its HTTPS fixture");
    }
}

#[test]
fn keeps_release_device_and_uninstrumented_loopback_rejected() {
    for (platform, configuration, conditions) in [
        ("iphoneos", "Release", "BLEAT_RELEASE_SECRET_SCAN"),
        ("iphonesimulator", "Release", ""),
        (
            "iphonesimulator",
            "Release",
            "BLEAT_RELEASE_SECRET_SCAN_OTHER",
        ),
        ("iphonesimulator", "Release", "bleat_release_secret_scan"),
        (
            "iphonesimulator",
            "Distribution",
            "BLEAT_RELEASE_SECRET_SCAN",
        ),
        ("iphonesimulator", "", "BLEAT_RELEASE_SECRET_SCAN"),
    ] {
        let mut values = settings(platform);
        values.insert("CONFIGURATION".to_owned(), configuration.to_owned());
        values.insert(
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS".to_owned(),
            conditions.to_owned(),
        );
        values.insert(
            "BLEAT_TELEMETRY_AUTH_BASE_URL".to_owned(),
            "https://localhost:8443".to_owned(),
        );
        let error = validate(&values).expect_err("ordinary Release loopback stays rejected");
        assert_eq!(
            error,
            Error::InsecureTelemetryAuthBaseUrl,
            "platform={platform}, configuration={configuration}, conditions={conditions}"
        );
        assert_eq!(error.exit_code(), 2);
    }
}

#[test]
fn release_scan_simulator_preserves_https_and_otlp_origin_policy() {
    let cases = [
        (
            "http://localhost:8443",
            "https://localhost:8444",
            Error::InsecureTelemetryAuthBaseUrl,
        ),
        (
            "https://localhost:8443",
            "http://localhost:8444",
            Error::OtlpEndpointMustUseHttps,
        ),
        (
            "https://localhost:8443",
            "https://localhost:8444/path",
            Error::TelemetryUrlMustBeOrigin {
                value: "https://localhost:8444/path".to_owned(),
            },
        ),
        (
            "https://localhost:8443",
            "https://localhost:8444/?query=synthetic",
            Error::OtlpEndpointHasQuery,
        ),
        (
            "https://localhost:8443",
            "https://localhost:8444/#synthetic",
            Error::OtlpEndpointHasFragment,
        ),
        (
            "https://localhost:8443",
            "https://user:synthetic@localhost:8444",
            Error::OtlpEndpointHasCredentials,
        ),
    ];
    for (auth, otlp, expected) in cases {
        let mut values = settings("iphonesimulator");
        values.insert("CONFIGURATION".to_owned(), "Release".to_owned());
        values.insert(
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS".to_owned(),
            "BLEAT_RELEASE_SECRET_SCAN".to_owned(),
        );
        values.insert("BLEAT_TELEMETRY_AUTH_BASE_URL".to_owned(), auth.to_owned());
        values.insert("BLEAT_TELEMETRY_OTLP_ENDPOINT".to_owned(), otlp.to_owned());
        let error =
            validate(&values).expect_err("instrumented fixture still obeys transport policy");
        assert_eq!(error, expected);
        assert_eq!(error.exit_code(), 2);
    }
}
