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
