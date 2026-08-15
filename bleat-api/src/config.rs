use std::{net::SocketAddr, str::FromStr, time::Duration};

use clap::{Parser, ValueEnum};
use serde::Serialize;
use thiserror::Error;
use url::Url;

const DEFAULT_BIND_ADDRESS: &str = "127.0.0.1:8080";
const DEFAULT_ISSUER: &str = "http://127.0.0.1:8080";
const DEFAULT_LOG_FILTER: &str =
    "bleat_api=info,opentelemetry=warn,opentelemetry_sdk=warn,opentelemetry-otlp=warn";

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, ValueEnum)]
#[serde(rename_all = "snake_case")]
pub enum DeploymentMode {
    Development,
    Production,
}

impl std::fmt::Display for DeploymentMode {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Development => formatter.write_str("development"),
            Self::Production => formatter.write_str("production"),
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, ValueEnum)]
#[serde(rename_all = "snake_case")]
pub enum AppAttestEnvironment {
    Development,
    Production,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, ValueEnum)]
pub enum LogFormat {
    Compact,
    Json,
}

#[derive(Debug, Parser)]
#[command(
    name = "bleat-api",
    version,
    about = "Bleat telemetry authentication API"
)]
pub struct Arguments {
    #[arg(long, env = "BLEAT_API_BIND_ADDRESS", default_value = DEFAULT_BIND_ADDRESS)]
    pub bind_address: SocketAddr,

    #[arg(long, env = "BLEAT_API_PUBLIC_ISSUER", default_value = DEFAULT_ISSUER)]
    pub public_issuer: Url,

    #[arg(long, env = "BLEAT_API_DEPLOYMENT_MODE", value_enum, default_value_t = DeploymentMode::Development)]
    pub deployment_mode: DeploymentMode,

    #[arg(long, env = "BLEAT_API_APPLE_TEAM_ID")]
    pub apple_team_id: Option<String>,

    #[arg(long, env = "BLEAT_API_APP_IDENTIFIER")]
    pub app_identifier: Option<String>,

    #[arg(long, env = "BLEAT_API_APP_ATTEST_ENVIRONMENT", value_enum, default_value_t = AppAttestEnvironment::Development)]
    pub app_attest_environment: AppAttestEnvironment,

    #[arg(
        long,
        env = "BLEAT_API_CHALLENGE_LIFETIME_SECONDS",
        default_value_t = 120
    )]
    pub challenge_lifetime_seconds: u64,

    #[arg(long, env = "BLEAT_API_TOKEN_LIFETIME_SECONDS", default_value_t = 600)]
    pub token_lifetime_seconds: u64,

    #[arg(long, env = "BLEAT_API_REQUEST_TIMEOUT_SECONDS", default_value_t = 10)]
    pub request_timeout_seconds: u64,

    #[arg(
        long,
        env = "BLEAT_API_MAX_REQUEST_BODY_BYTES",
        default_value_t = 65_536
    )]
    pub max_request_body_bytes: usize,

    #[arg(long, env = "BLEAT_API_MAX_CONCURRENT_REQUESTS", default_value_t = 64)]
    pub max_concurrent_requests: usize,

    #[arg(long, env = "BLEAT_API_LOG_FILTER", default_value = DEFAULT_LOG_FILTER)]
    pub log_filter: String,

    #[arg(long, env = "BLEAT_API_LOG_FORMAT", value_enum, default_value_t = LogFormat::Compact)]
    pub log_format: LogFormat,
}

#[derive(Clone, Debug)]
pub struct Config {
    pub bind_address: SocketAddr,
    pub public_issuer: Url,
    pub deployment_mode: DeploymentMode,
    pub apple_team_id: Option<String>,
    pub app_identifier: Option<String>,
    pub app_attest_environment: AppAttestEnvironment,
    pub challenge_lifetime: Duration,
    pub token_lifetime: Duration,
    pub request_timeout: Duration,
    pub max_request_body_bytes: usize,
    pub max_concurrent_requests: usize,
    pub log_filter: String,
    pub log_format: LogFormat,
    pub telemetry: TelemetryExportConfig,
}

impl TryFrom<Arguments> for Config {
    type Error = ConfigError;

    fn try_from(arguments: Arguments) -> Result<Self, Self::Error> {
        Self::from_arguments(arguments, TelemetryExportConfig::from_environment()?)
    }
}

impl Config {
    pub fn from_arguments(
        arguments: Arguments,
        telemetry: TelemetryExportConfig,
    ) -> Result<Self, ConfigError> {
        let config = Self {
            bind_address: arguments.bind_address,
            public_issuer: arguments.public_issuer,
            deployment_mode: arguments.deployment_mode,
            apple_team_id: non_empty(arguments.apple_team_id),
            app_identifier: non_empty(arguments.app_identifier),
            app_attest_environment: arguments.app_attest_environment,
            challenge_lifetime: Duration::from_secs(arguments.challenge_lifetime_seconds),
            token_lifetime: Duration::from_secs(arguments.token_lifetime_seconds),
            request_timeout: Duration::from_secs(arguments.request_timeout_seconds),
            max_request_body_bytes: arguments.max_request_body_bytes,
            max_concurrent_requests: arguments.max_concurrent_requests,
            log_filter: arguments.log_filter,
            log_format: arguments.log_format,
            telemetry,
        };
        config.validate()?;
        Ok(config)
    }

    pub fn validate(&self) -> Result<(), ConfigError> {
        bounded_duration("challenge lifetime", self.challenge_lifetime, 30, 600)?;
        bounded_duration("token lifetime", self.token_lifetime, 60, 3_600)?;
        bounded_duration("request timeout", self.request_timeout, 1, 60)?;
        bounded_usize(
            "maximum request body",
            self.max_request_body_bytes,
            1_024,
            1_048_576,
        )?;
        bounded_usize(
            "maximum concurrent requests",
            self.max_concurrent_requests,
            1,
            1_024,
        )?;

        if self.log_filter.trim().is_empty() {
            return Err(ConfigError::EmptyLogFilter);
        }

        if self.deployment_mode == DeploymentMode::Production {
            if self.public_issuer.scheme() != "https" {
                return Err(ConfigError::ProductionIssuerMustUseHttps);
            }
            if self.apple_team_id.is_none() {
                return Err(ConfigError::MissingProductionValue("Apple team ID"));
            }
            if self.app_identifier.is_none() {
                return Err(ConfigError::MissingProductionValue("app identifier"));
            }
            if self.app_attest_environment != AppAttestEnvironment::Production {
                return Err(ConfigError::ProductionAppAttestRequired);
            }
        }

        Ok(())
    }

    pub fn jwt_algorithm(&self) -> compact_jwt::JwaAlg {
        compact_jwt::JwaAlg::ES256
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct TelemetryExportConfig {
    pub traces_enabled: bool,
    pub logs_enabled: bool,
}

impl TelemetryExportConfig {
    pub fn from_environment() -> Result<Self, ConfigError> {
        Self::from_lookup(|name| std::env::var(name).ok())
    }

    pub fn from_lookup(lookup: impl Fn(&str) -> Option<String>) -> Result<Self, ConfigError> {
        let common = endpoint(&lookup, "OTEL_EXPORTER_OTLP_ENDPOINT")?;
        let traces = endpoint(&lookup, "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT")?;
        let logs = endpoint(&lookup, "OTEL_EXPORTER_OTLP_LOGS_ENDPOINT")?;

        validate_protocol(&lookup, "OTEL_EXPORTER_OTLP_PROTOCOL")?;
        validate_protocol(&lookup, "OTEL_EXPORTER_OTLP_TRACES_PROTOCOL")?;
        validate_protocol(&lookup, "OTEL_EXPORTER_OTLP_LOGS_PROTOCOL")?;

        Ok(Self {
            traces_enabled: common.is_some() || traces.is_some(),
            logs_enabled: common.is_some() || logs.is_some(),
        })
    }
}

#[derive(Debug, Error, Eq, PartialEq)]
pub enum ConfigError {
    #[error("{0} must be between {1} and {2}")]
    ValueOutOfRange(&'static str, u64, u64),
    #[error("the log filter must not be empty")]
    EmptyLogFilter,
    #[error("the production public issuer must use HTTPS")]
    ProductionIssuerMustUseHttps,
    #[error("production configuration requires {0}")]
    MissingProductionValue(&'static str),
    #[error("production configuration accepts production App Attest evidence only")]
    ProductionAppAttestRequired,
    #[error("{0} must be an absolute HTTP or HTTPS URL without a query or fragment")]
    InvalidOtlpEndpoint(&'static str),
    #[error("{0} must be http/protobuf when configured")]
    InvalidOtlpProtocol(&'static str),
}

fn non_empty(value: Option<String>) -> Option<String> {
    value.and_then(|value| {
        let trimmed = value.trim();
        (!trimmed.is_empty()).then(|| trimmed.to_owned())
    })
}

fn bounded_duration(
    name: &'static str,
    value: Duration,
    minimum: u64,
    maximum: u64,
) -> Result<(), ConfigError> {
    bounded_value(name, value.as_secs(), minimum, maximum)
}

fn bounded_value<T>(name: &'static str, value: T, minimum: T, maximum: T) -> Result<(), ConfigError>
where
    T: Copy + Into<u64> + Ord,
{
    if value < minimum || value > maximum {
        return Err(ConfigError::ValueOutOfRange(
            name,
            minimum.into(),
            maximum.into(),
        ));
    }
    Ok(())
}

fn bounded_usize(
    name: &'static str,
    value: usize,
    minimum: usize,
    maximum: usize,
) -> Result<(), ConfigError> {
    if value < minimum || value > maximum {
        return Err(ConfigError::ValueOutOfRange(
            name,
            minimum as u64,
            maximum as u64,
        ));
    }
    Ok(())
}

fn endpoint(
    lookup: &impl Fn(&str) -> Option<String>,
    name: &'static str,
) -> Result<Option<Url>, ConfigError> {
    let Some(value) = lookup(name) else {
        return Ok(None);
    };
    let parsed = Url::from_str(&value).map_err(|_| ConfigError::InvalidOtlpEndpoint(name))?;
    let valid_scheme = matches!(parsed.scheme(), "http" | "https");
    if !valid_scheme
        || parsed.host_str().is_none()
        || parsed.query().is_some()
        || parsed.fragment().is_some()
    {
        return Err(ConfigError::InvalidOtlpEndpoint(name));
    }
    Ok(Some(parsed))
}

fn validate_protocol(
    lookup: &impl Fn(&str) -> Option<String>,
    name: &'static str,
) -> Result<(), ConfigError> {
    if lookup(name).is_some_and(|value| value != "http/protobuf") {
        return Err(ConfigError::InvalidOtlpProtocol(name));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;

    use super::*;

    fn arguments(values: &[&str]) -> Arguments {
        Arguments::try_parse_from(values).expect("test arguments should parse")
    }

    fn config(values: &[&str]) -> Result<Config, ConfigError> {
        Config::from_arguments(arguments(values), TelemetryExportConfig::default())
    }

    #[test]
    fn development_defaults_are_bounded_and_use_es256() {
        let config = config(&["bleat-api"]).expect("development defaults should validate");

        assert_eq!(config.bind_address.to_string(), DEFAULT_BIND_ADDRESS);
        assert_eq!(config.public_issuer.as_str(), "http://127.0.0.1:8080/");
        assert_eq!(config.deployment_mode, DeploymentMode::Development);
        assert_eq!(config.challenge_lifetime, Duration::from_secs(120));
        assert_eq!(config.token_lifetime, Duration::from_secs(600));
        assert_eq!(config.jwt_algorithm(), compact_jwt::JwaAlg::ES256);
        assert!(!config.telemetry.traces_enabled);
        assert!(!config.telemetry.logs_enabled);
    }

    #[test]
    fn command_line_values_override_defaults() {
        let config = config(&[
            "bleat-api",
            "--bind-address",
            "0.0.0.0:9000",
            "--challenge-lifetime-seconds",
            "60",
            "--token-lifetime-seconds",
            "900",
            "--log-format",
            "json",
        ])
        .expect("valid overrides should be accepted");

        assert_eq!(config.bind_address.to_string(), "0.0.0.0:9000");
        assert_eq!(config.challenge_lifetime, Duration::from_secs(60));
        assert_eq!(config.token_lifetime, Duration::from_secs(900));
        assert_eq!(config.log_format, LogFormat::Json);
    }

    #[test]
    fn production_configuration_fails_closed() {
        let insecure = config(&[
            "bleat-api",
            "--deployment-mode",
            "production",
            "--apple-team-id",
            "TEAM",
            "--app-identifier",
            "com.example.bleat",
            "--app-attest-environment",
            "production",
        ]);
        assert_eq!(
            insecure.expect_err("HTTP issuer must fail"),
            ConfigError::ProductionIssuerMustUseHttps
        );

        let missing_team = config(&[
            "bleat-api",
            "--deployment-mode",
            "production",
            "--public-issuer",
            "https://telemetry.example",
            "--app-identifier",
            "com.example.bleat",
            "--app-attest-environment",
            "production",
        ]);
        assert_eq!(
            missing_team.expect_err("team ID must be required"),
            ConfigError::MissingProductionValue("Apple team ID")
        );

        let development_attest = config(&[
            "bleat-api",
            "--deployment-mode",
            "production",
            "--public-issuer",
            "https://telemetry.example",
            "--apple-team-id",
            "TEAM",
            "--app-identifier",
            "com.example.bleat",
        ]);
        assert_eq!(
            development_attest.expect_err("development evidence must fail"),
            ConfigError::ProductionAppAttestRequired
        );
    }

    #[test]
    fn numeric_limits_are_validated() {
        let config = config(&["bleat-api", "--request-timeout-seconds", "0"]);
        assert_eq!(
            config.expect_err("zero timeout must fail"),
            ConfigError::ValueOutOfRange("request timeout", 1, 60)
        );
    }

    #[test]
    fn common_otlp_endpoint_enables_traces_and_logs() {
        let values = HashMap::from([(
            "OTEL_EXPORTER_OTLP_ENDPOINT",
            "https://collector.example/otel",
        )]);
        let telemetry = TelemetryExportConfig::from_lookup(|name| {
            values.get(name).map(|value| (*value).to_owned())
        })
        .expect("valid common endpoint should be accepted");

        assert!(telemetry.traces_enabled);
        assert!(telemetry.logs_enabled);
    }

    #[test]
    fn signal_specific_otlp_endpoints_enable_independently() {
        let trace_values = HashMap::from([(
            "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT",
            "https://collector.example/v1/traces",
        )]);
        let traces = TelemetryExportConfig::from_lookup(|name| {
            trace_values.get(name).map(|value| (*value).to_owned())
        })
        .expect("valid trace endpoint should be accepted");
        assert!(traces.traces_enabled);
        assert!(!traces.logs_enabled);

        let log_values = HashMap::from([(
            "OTEL_EXPORTER_OTLP_LOGS_ENDPOINT",
            "https://collector.example/v1/logs",
        )]);
        let logs = TelemetryExportConfig::from_lookup(|name| {
            log_values.get(name).map(|value| (*value).to_owned())
        })
        .expect("valid log endpoint should be accepted");
        assert!(!logs.traces_enabled);
        assert!(logs.logs_enabled);
    }

    #[test]
    fn invalid_otlp_configuration_is_rejected_without_echoing_values() {
        let invalid_endpoint =
            HashMap::from([("OTEL_EXPORTER_OTLP_ENDPOINT", "secret-token@not-a-url")]);
        let error = TelemetryExportConfig::from_lookup(|name| {
            invalid_endpoint.get(name).map(|value| (*value).to_owned())
        })
        .expect_err("invalid endpoint should fail");
        assert_eq!(
            error,
            ConfigError::InvalidOtlpEndpoint("OTEL_EXPORTER_OTLP_ENDPOINT")
        );
        assert!(!error.to_string().contains("secret-token"));

        let invalid_protocol = HashMap::from([("OTEL_EXPORTER_OTLP_PROTOCOL", "grpc")]);
        assert_eq!(
            TelemetryExportConfig::from_lookup(|name| {
                invalid_protocol.get(name).map(|value| (*value).to_owned())
            })
            .expect_err("gRPC protocol should fail"),
            ConfigError::InvalidOtlpProtocol("OTEL_EXPORTER_OTLP_PROTOCOL")
        );
    }
}
