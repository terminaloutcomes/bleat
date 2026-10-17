use thiserror::Error;
use url::Url;

#[derive(Debug, Error, PartialEq, Eq)]
pub enum PaidBuildSettingsError {
    #[error("Environment var {name} must be set")]
    MissingEnvironmentVariable { name: &'static str },
    #[error("Environment var {name} must be one of {allowed_values:?}")]
    InvalidAllowedValue {
        name: &'static str,
        allowed_values: Vec<&'static str>,
    },
    #[error("Failed to parse {name} ({value}): Failed to parse telemetry URL: {value}")]
    InvalidTelemetryUrl { name: &'static str, value: String },
    #[error("Telemetry URL must have http or https scheme: {value}")]
    InvalidTelemetryScheme { value: String },
    #[error("Telemetry URL must be an origin: {value}")]
    TelemetryUrlMustBeOrigin { value: String },
    #[error("BLEAT_TELEMETRY_AUTH_BASE_URL must be HTTPS or Debug loopback HTTP")]
    InsecureTelemetryAuthBaseUrl,
    #[error("BLEAT_TELEMETRY_OTLP_ENDPOINT must be a valid HTTPS origin for iOS builds")]
    OtlpEndpointMustUseHttps,
    #[error("BLEAT_TELEMETRY_OTLP_ENDPOINT must not contain a URL fragment")]
    OtlpEndpointHasFragment,
    #[error("BLEAT_TELEMETRY_OTLP_ENDPOINT must not contain a URL path")]
    OtlpEndpointHasPath,
    #[error("BLEAT_TELEMETRY_OTLP_ENDPOINT must not contain a URL query")]
    OtlpEndpointHasQuery,
    #[error("BLEAT_TELEMETRY_OTLP_ENDPOINT must not contain a URL username/credentials")]
    OtlpEndpointHasCredentials,
}

impl PaidBuildSettingsError {
    pub const fn exit_code(&self) -> u8 {
        match self {
            Self::MissingEnvironmentVariable { .. } => 1,
            _ => 2,
        }
    }
}

pub fn validate_environment<E>(
    mut get: impl FnMut(&str) -> Result<String, E>,
) -> Result<Vec<String>, PaidBuildSettingsError> {
    let mut messages = Vec::new();
    check_values(
        &mut get,
        &mut messages,
        "BUILD_WITHOUT_PAID_DEVELOPER",
        &["YES", "NO"],
    )?;
    check_values(
        &mut get,
        &mut messages,
        "BLEAT_CLOUDKIT_MODE",
        &["enabled", "disabled"],
    )?;
    check_values(
        &mut get,
        &mut messages,
        "PLATFORM_NAME",
        &["iphoneos", "iphonesimulator", "macosx"],
    )?;
    let platform = required(&mut get, "PLATFORM_NAME")?;
    if platform == "macosx" {
        messages.push("✅ Running on macOS platform, telemetry checks skipped".to_owned());
    } else if ["iphoneos", "iphonesimulator"].contains(&platform.as_str()) {
        validate_ios_settings(&mut get, &mut messages)?;
    }
    Ok(messages)
}

fn required<E>(
    get: &mut impl FnMut(&str) -> Result<String, E>,
    name: &'static str,
) -> Result<String, PaidBuildSettingsError> {
    get(name).map_err(|_| PaidBuildSettingsError::MissingEnvironmentVariable { name })
}

fn check_values<E>(
    get: &mut impl FnMut(&str) -> Result<String, E>,
    messages: &mut Vec<String>,
    name: &'static str,
    allowed_values: &[&'static str],
) -> Result<(), PaidBuildSettingsError> {
    let value = required(get, name)?;
    if !allowed_values.contains(&value.as_str()) {
        return Err(PaidBuildSettingsError::InvalidAllowedValue {
            name,
            allowed_values: allowed_values.to_vec(),
        });
    }
    messages.push(format!("✅ {name} is set to {value}"));
    Ok(())
}

fn parse_telemetry_url(value: &str, requires_origin: bool) -> Result<Url, PaidBuildSettingsError> {
    let url = Url::parse(value).map_err(|_| PaidBuildSettingsError::InvalidTelemetryUrl {
        name: if requires_origin {
            "BLEAT_TELEMETRY_OTLP_ENDPOINT"
        } else {
            "BLEAT_TELEMETRY_AUTH_BASE_URL"
        },
        value: value.to_owned(),
    })?;
    if url.scheme() != "http" && url.scheme() != "https" {
        return Err(PaidBuildSettingsError::InvalidTelemetryScheme {
            value: value.to_owned(),
        });
    }
    if requires_origin && url.path() != "/" {
        return Err(PaidBuildSettingsError::TelemetryUrlMustBeOrigin {
            value: value.to_owned(),
        });
    }
    Ok(url)
}

fn validate_ios_settings<E>(
    get: &mut impl FnMut(&str) -> Result<String, E>,
    messages: &mut Vec<String>,
) -> Result<(), PaidBuildSettingsError> {
    check_values(
        get,
        messages,
        "BLEAT_APP_ATTEST_MODE",
        &["enabled", "disabled"],
    )?;
    check_values(
        get,
        messages,
        "BLEAT_CARPLAY_MODE",
        &["enabled", "disabled"],
    )?;

    let base_url = required(get, "BLEAT_TELEMETRY_AUTH_BASE_URL")?;
    let base_url = parse_telemetry_url(&base_url, false)?;
    let is_https = base_url.scheme().to_lowercase() == "https";
    let debug_config = get("CONFIGURATION")
        .map(|value| value == "Debug")
        .unwrap_or(false);
    let is_loopback =
        ["localhost", "127.0.0.1", "::1"].contains(&base_url.host_str().unwrap_or(""));
    if (!debug_config && is_loopback) || (!is_loopback && !is_https) {
        return Err(PaidBuildSettingsError::InsecureTelemetryAuthBaseUrl);
    }

    let endpoint_value = required(get, "BLEAT_TELEMETRY_OTLP_ENDPOINT")?;
    let endpoint = parse_telemetry_url(&endpoint_value, true)?;
    if endpoint.scheme().to_lowercase() != "https" {
        return Err(PaidBuildSettingsError::OtlpEndpointMustUseHttps);
    }
    if endpoint.fragment().is_some() {
        return Err(PaidBuildSettingsError::OtlpEndpointHasFragment);
    }
    if endpoint.path() != "/" {
        return Err(PaidBuildSettingsError::OtlpEndpointHasPath);
    }
    if endpoint.query().is_some() {
        return Err(PaidBuildSettingsError::OtlpEndpointHasQuery);
    }
    if !endpoint.username().is_empty() {
        return Err(PaidBuildSettingsError::OtlpEndpointHasCredentials);
    }
    messages.push("✅ BLEAT_TELEMETRY_OTLP_ENDPOINT is set".to_owned());
    Ok(())
}
