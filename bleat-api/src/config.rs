use std::{
    net::SocketAddr,
    path::{Path, PathBuf},
    str::FromStr,
    time::Duration,
};

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

impl std::fmt::Display for AppAttestEnvironment {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Development => formatter.write_str("development"),
            Self::Production => formatter.write_str("production"),
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, ValueEnum)]
pub enum LogFormat {
    Compact,
    Json,
}

impl std::fmt::Display for LogFormat {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Compact => formatter.write_str("compact"),
            Self::Json => formatter.write_str("json"),
        }
    }
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
        env = "BLEAT_API_APP_ATTEST_BUNDLE_VERSIONS",
        value_delimiter = ','
    )]
    pub app_attest_bundle_versions: Vec<String>,

    #[arg(
        long,
        env = "BLEAT_API_APP_ATTEST_VALIDATION_CATEGORIES",
        value_delimiter = ','
    )]
    pub app_attest_validation_categories: Vec<u32>,

    #[arg(long, env = "BLEAT_API_DATABASE_URL", hide_env_values = true)]
    pub database_url: String,

    #[arg(long, env = "BLEAT_API_DATABASE_MAX_CONNECTIONS", default_value_t = 16)]
    pub database_max_connections: usize,

    #[arg(
        long,
        env = "BLEAT_API_DATABASE_CONNECT_TIMEOUT_SECONDS",
        default_value_t = 5
    )]
    pub database_connect_timeout_seconds: u64,

    #[arg(
        long,
        env = "BLEAT_API_CHALLENGE_LIFETIME_SECONDS",
        default_value_t = 120
    )]
    pub challenge_lifetime_seconds: u64,

    #[arg(
        long,
        env = "BLEAT_API_CHALLENGE_CLEANUP_BATCH_SIZE",
        default_value_t = 1_000
    )]
    pub challenge_cleanup_batch_size: usize,

    #[arg(
        long,
        env = "BLEAT_API_CHALLENGE_ISSUANCE_PER_MINUTE",
        default_value_t = 600
    )]
    pub challenge_issuance_per_minute: usize,

    #[arg(long, env = "BLEAT_API_TOKEN_LIFETIME_SECONDS", default_value_t = 600)]
    pub token_lifetime_seconds: u64,

    #[arg(long, env = "BLEAT_API_JWT_SIGNING_KEY_FILE", hide_env_values = true)]
    pub jwt_signing_key_file: Option<PathBuf>,

    #[arg(
        long,
        env = "BLEAT_API_JWT_PUBLIC_KEY_SET_FILE",
        hide_env_values = true
    )]
    pub jwt_public_key_set_file: Option<PathBuf>,

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
    pub app_attest_bundle_versions: Vec<String>,
    pub app_attest_validation_categories: Vec<u32>,
    pub database: DatabaseConfig,
    pub challenge_lifetime: Duration,
    pub challenge_cleanup_batch_size: usize,
    pub challenge_issuance_per_minute: usize,
    pub token_lifetime: Duration,
    pub jwt_signing_key_file: Option<SecretFilePath>,
    pub jwt_public_key_set_file: Option<SecretFilePath>,
    pub request_timeout: Duration,
    pub max_request_body_bytes: usize,
    pub max_concurrent_requests: usize,
    pub log_filter: String,
    pub log_format: LogFormat,
    pub telemetry: TelemetryExportConfig,
}

#[derive(Clone)]
pub struct DatabaseConfig {
    url: String,
    pub max_connections: usize,
    pub connect_timeout: Duration,
}

#[derive(Clone)]
pub struct SecretFilePath(PathBuf);

impl SecretFilePath {
    pub fn as_path(&self) -> &Path {
        &self.0
    }
}

impl std::fmt::Debug for SecretFilePath {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("[REDACTED]")
    }
}

impl DatabaseConfig {
    pub fn new(
        url: String,
        max_connections: usize,
        connect_timeout: Duration,
    ) -> Result<Self, ConfigError> {
        let url = non_empty(Some(url)).ok_or(ConfigError::MissingDatabaseUrl)?;
        let parsed = Url::from_str(&url).map_err(|_| ConfigError::InvalidDatabaseUrl)?;
        if !matches!(parsed.scheme(), "postgres" | "postgresql")
            || parsed.host_str().is_none()
            || parsed.path().trim_matches('/').is_empty()
        {
            return Err(ConfigError::InvalidDatabaseUrl);
        }
        bounded_usize("maximum database connections", max_connections, 1, 128)?;
        bounded_duration("database connect timeout", connect_timeout, 1, 60)?;
        Ok(Self {
            url,
            max_connections,
            connect_timeout,
        })
    }

    pub fn url(&self) -> &str {
        &self.url
    }
}

impl std::fmt::Debug for DatabaseConfig {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("DatabaseConfig")
            .field("url", &"[REDACTED]")
            .field("max_connections", &self.max_connections)
            .field("connect_timeout", &self.connect_timeout)
            .finish()
    }
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
        let database = DatabaseConfig::new(
            arguments.database_url,
            arguments.database_max_connections,
            Duration::from_secs(arguments.database_connect_timeout_seconds),
        )?;
        let config = Self {
            bind_address: arguments.bind_address,
            public_issuer: arguments.public_issuer,
            deployment_mode: arguments.deployment_mode,
            apple_team_id: non_empty(arguments.apple_team_id),
            app_identifier: non_empty(arguments.app_identifier),
            app_attest_environment: arguments.app_attest_environment,
            app_attest_bundle_versions: arguments
                .app_attest_bundle_versions
                .into_iter()
                .filter_map(|value| non_empty(Some(value)))
                .collect(),
            app_attest_validation_categories: arguments.app_attest_validation_categories,
            database,
            challenge_lifetime: Duration::from_secs(arguments.challenge_lifetime_seconds),
            challenge_cleanup_batch_size: arguments.challenge_cleanup_batch_size,
            challenge_issuance_per_minute: arguments.challenge_issuance_per_minute,
            token_lifetime: Duration::from_secs(arguments.token_lifetime_seconds),
            jwt_signing_key_file: secret_file_path(arguments.jwt_signing_key_file),
            jwt_public_key_set_file: secret_file_path(arguments.jwt_public_key_set_file),
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
        bounded_usize(
            "challenge cleanup batch size",
            self.challenge_cleanup_batch_size,
            1,
            10_000,
        )?;
        bounded_usize(
            "challenge issuance per minute",
            self.challenge_issuance_per_minute,
            1,
            100_000,
        )?;
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
        bounded_usize(
            "maximum database connections",
            self.database.max_connections,
            1,
            128,
        )?;
        bounded_duration(
            "database connect timeout",
            self.database.connect_timeout,
            1,
            60,
        )?;

        if self.log_filter.trim().is_empty() {
            return Err(ConfigError::EmptyLogFilter);
        }

        if self.deployment_mode == DeploymentMode::Production {
            if self.public_issuer.scheme() != "https" {
                return Err(ConfigError::ProductionIssuerMustUseHttps);
            }
            if self.public_issuer.username() != ""
                || self.public_issuer.password().is_some()
                || self.public_issuer.query().is_some()
                || self.public_issuer.fragment().is_some()
                || self.public_issuer.path() != "/"
            {
                return Err(ConfigError::InvalidProductionIssuer);
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
            if self.app_attest_bundle_versions.is_empty() {
                return Err(ConfigError::MissingProductionValue(
                    "App Attest bundle-version allowlist",
                ));
            }
            if self.app_attest_validation_categories.is_empty() {
                return Err(ConfigError::MissingProductionValue(
                    "App Attest validation-category allowlist",
                ));
            }
            if self
                .app_attest_validation_categories
                .iter()
                .any(|value| !matches!(value, 1..=6 | 10))
            {
                return Err(ConfigError::InvalidAppAttestValidationCategory);
            }
            if self.jwt_signing_key_file.is_none() {
                return Err(ConfigError::MissingProductionValue("JWT signing-key file"));
            }
        } else if self.jwt_signing_key_file.is_some() || self.jwt_public_key_set_file.is_some() {
            return Err(ConfigError::ProductionSigningConfigurationOnly);
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
    #[error("the PostgreSQL database URL is required")]
    MissingDatabaseUrl,
    #[error("the database URL must be a PostgreSQL URL with a database name")]
    InvalidDatabaseUrl,
    #[error("the log filter must not be empty")]
    EmptyLogFilter,
    #[error("the production public issuer must use HTTPS")]
    ProductionIssuerMustUseHttps,
    #[error(
        "the production public issuer must be an origin URL without credentials, path, query, or fragment"
    )]
    InvalidProductionIssuer,
    #[error("production configuration requires {0}")]
    MissingProductionValue(&'static str),
    #[error("production configuration accepts production App Attest evidence only")]
    ProductionAppAttestRequired,
    #[error("JWT signing-key files are accepted only in production mode")]
    ProductionSigningConfigurationOnly,
    #[error("App Attest validation categories must use an Apple application category")]
    InvalidAppAttestValidationCategory,
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

fn secret_file_path(value: Option<PathBuf>) -> Option<SecretFilePath> {
    value.and_then(|path| (!path.as_os_str().is_empty()).then_some(SecretFilePath(path)))
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

    use clap::{CommandFactory, FromArgMatches};

    use super::*;

    fn development_arguments() -> Arguments {
        Arguments {
            bind_address: DEFAULT_BIND_ADDRESS
                .parse()
                .expect("default bind address should parse"),
            public_issuer: Url::parse(DEFAULT_ISSUER).expect("default issuer should parse"),
            deployment_mode: DeploymentMode::Development,
            apple_team_id: None,
            app_identifier: None,
            app_attest_environment: AppAttestEnvironment::Development,
            app_attest_bundle_versions: Vec::new(),
            app_attest_validation_categories: Vec::new(),
            database_url: "postgres://bleat:development@127.0.0.1:5432/bleat".to_owned(),
            database_max_connections: 16,
            database_connect_timeout_seconds: 5,
            challenge_lifetime_seconds: 120,
            challenge_cleanup_batch_size: 1_000,
            challenge_issuance_per_minute: 600,
            token_lifetime_seconds: 600,
            jwt_signing_key_file: None,
            jwt_public_key_set_file: None,
            request_timeout_seconds: 10,
            max_request_body_bytes: 65_536,
            max_concurrent_requests: 64,
            log_filter: DEFAULT_LOG_FILTER.to_owned(),
            log_format: LogFormat::Compact,
        }
    }

    fn config(configure: impl FnOnce(&mut Arguments)) -> Result<Config, ConfigError> {
        let mut arguments = development_arguments();
        configure(&mut arguments);
        Config::from_arguments(arguments, TelemetryExportConfig::default())
    }

    fn parse_arguments_without_environment(
        values: impl IntoIterator<Item = impl Into<std::ffi::OsString> + Clone>,
    ) -> Result<Arguments, clap::Error> {
        let matches = Arguments::command()
            .mut_args(|argument| argument.env(None::<&'static str>))
            .try_get_matches_from(values)?;
        Arguments::from_arg_matches(&matches)
    }

    #[test]
    fn development_configuration_is_bounded_and_uses_es256() {
        let config = config(|_| {}).expect("development defaults should validate");

        assert_eq!(config.bind_address.to_string(), DEFAULT_BIND_ADDRESS);
        assert_eq!(config.public_issuer.as_str(), "http://127.0.0.1:8080/");
        assert_eq!(config.deployment_mode, DeploymentMode::Development);
        assert_eq!(config.challenge_lifetime, Duration::from_secs(120));
        assert_eq!(config.token_lifetime, Duration::from_secs(600));
        assert_eq!(config.database.max_connections, 16);
        assert_eq!(config.database.connect_timeout, Duration::from_secs(5));
        assert_eq!(config.challenge_cleanup_batch_size, 1_000);
        assert_eq!(config.challenge_issuance_per_minute, 600);
        assert!(config.jwt_signing_key_file.is_none());
        assert!(config.jwt_public_key_set_file.is_none());
        assert_eq!(config.jwt_algorithm(), compact_jwt::JwaAlg::ES256);
        assert!(!config.telemetry.traces_enabled);
        assert!(!config.telemetry.logs_enabled);
    }

    #[test]
    fn command_line_parser_is_explicitly_isolated_from_environment() {
        let arguments = parse_arguments_without_environment([
            "bleat-api",
            "--database-url",
            "postgres://bleat:development@127.0.0.1:5432/bleat",
            "--bind-address",
            "0.0.0.0:9000",
            "--challenge-lifetime-seconds",
            "60",
            "--token-lifetime-seconds",
            "900",
            "--log-format",
            "json",
        ])
        .expect("valid command-line values should parse");
        let config = Config::from_arguments(arguments, TelemetryExportConfig::default())
            .expect("valid overrides should be accepted");

        assert_eq!(config.bind_address.to_string(), "0.0.0.0:9000");
        assert_eq!(config.challenge_lifetime, Duration::from_secs(60));
        assert_eq!(config.token_lifetime, Duration::from_secs(900));
        assert_eq!(config.log_format, LogFormat::Json);
    }

    #[test]
    fn production_configuration_fails_closed() {
        let production = |arguments: &mut Arguments| {
            arguments.deployment_mode = DeploymentMode::Production;
            arguments.apple_team_id = Some("TEAM".to_owned());
            arguments.app_identifier = Some("com.example.bleat".to_owned());
            arguments.app_attest_environment = AppAttestEnvironment::Production;
        };
        let insecure = config(production);
        assert_eq!(
            insecure.expect_err("HTTP issuer must fail"),
            ConfigError::ProductionIssuerMustUseHttps
        );

        let missing_team = config(|arguments| {
            production(arguments);
            arguments.public_issuer =
                Url::parse("https://telemetry.example").expect("test issuer should parse");
            arguments.apple_team_id = None;
        });
        assert_eq!(
            missing_team.expect_err("team ID must be required"),
            ConfigError::MissingProductionValue("Apple team ID")
        );

        let development_attest = config(|arguments| {
            production(arguments);
            arguments.public_issuer =
                Url::parse("https://telemetry.example").expect("test issuer should parse");
            arguments.app_attest_environment = AppAttestEnvironment::Development;
        });
        assert_eq!(
            development_attest.expect_err("development evidence must fail"),
            ConfigError::ProductionAppAttestRequired
        );

        let missing_bundle_versions = config(|arguments| {
            production(arguments);
            arguments.public_issuer =
                Url::parse("https://telemetry.example").expect("test issuer should parse");
        });
        assert_eq!(
            missing_bundle_versions.expect_err("bundle versions must be required"),
            ConfigError::MissingProductionValue("App Attest bundle-version allowlist")
        );

        let missing_validation_categories = config(|arguments| {
            production(arguments);
            arguments.public_issuer =
                Url::parse("https://telemetry.example").expect("test issuer should parse");
            arguments.app_attest_bundle_versions = vec!["1".to_owned()];
        });
        assert_eq!(
            missing_validation_categories.expect_err("validation categories must be required"),
            ConfigError::MissingProductionValue("App Attest validation-category allowlist")
        );

        let missing_signing_key = config(|arguments| {
            production(arguments);
            arguments.public_issuer =
                Url::parse("https://telemetry.example").expect("test issuer should parse");
            arguments.app_attest_bundle_versions = vec!["1".to_owned()];
            arguments.app_attest_validation_categories = vec![4];
        });
        assert_eq!(
            missing_signing_key.expect_err("JWT signing key must be required"),
            ConfigError::MissingProductionValue("JWT signing-key file")
        );

        let issuer_with_path = config(|arguments| {
            production(arguments);
            arguments.public_issuer =
                Url::parse("https://telemetry.example/path").expect("test issuer should parse");
            arguments.app_attest_bundle_versions = vec!["1".to_owned()];
            arguments.app_attest_validation_categories = vec![4];
            arguments.jwt_signing_key_file = Some(PathBuf::from("/run/secrets/jwt.der"));
        });
        assert_eq!(
            issuer_with_path.expect_err("issuer paths must be rejected"),
            ConfigError::InvalidProductionIssuer
        );

        let development_signing_key = config(|arguments| {
            arguments.jwt_signing_key_file = Some(PathBuf::from("/private/signing-key.der"));
        });
        assert_eq!(
            development_signing_key.expect_err("development must use ephemeral signing"),
            ConfigError::ProductionSigningConfigurationOnly
        );
    }

    #[test]
    fn signing_key_paths_are_redacted() {
        let config = config(|arguments| {
            arguments.deployment_mode = DeploymentMode::Production;
            arguments.public_issuer =
                Url::parse("https://telemetry.example").expect("test issuer should parse");
            arguments.apple_team_id = Some("TEAM".to_owned());
            arguments.app_identifier = Some("com.example.bleat".to_owned());
            arguments.app_attest_environment = AppAttestEnvironment::Production;
            arguments.app_attest_bundle_versions = vec!["1".to_owned()];
            arguments.app_attest_validation_categories = vec![4];
            arguments.jwt_signing_key_file = Some(PathBuf::from("/private/signing-key.der"));
            arguments.jwt_public_key_set_file = Some(PathBuf::from("/private/public-keys.json"));
        })
        .expect("production signing configuration should validate");

        let debug = format!("{config:?}");
        assert!(!debug.contains("signing-key.der"));
        assert!(!debug.contains("public-keys.json"));
        assert!(debug.contains("[REDACTED]"));
    }

    #[test]
    fn numeric_limits_are_validated() {
        let config = config(|arguments| arguments.request_timeout_seconds = 0);
        assert_eq!(
            config.expect_err("zero timeout must fail"),
            ConfigError::ValueOutOfRange("request timeout", 1, 60)
        );
    }

    #[test]
    fn database_configuration_is_required_and_redacted() {
        let missing = parse_arguments_without_environment(["bleat-api"])
            .expect_err("database URL argument must be required");
        assert_eq!(
            missing.kind(),
            clap::error::ErrorKind::MissingRequiredArgument
        );

        assert_eq!(
            DatabaseConfig::new(String::new(), 16, Duration::from_secs(5))
                .expect_err("empty database URL must fail"),
            ConfigError::MissingDatabaseUrl
        );

        let secret = "postgres://bleat:do-not-print@127.0.0.1:5432/bleat";
        let invalid = config(|arguments| {
            arguments.database_url = secret.to_owned();
            arguments.database_max_connections = 0;
        })
        .expect_err("zero database connections must fail");
        assert_eq!(
            invalid,
            ConfigError::ValueOutOfRange("maximum database connections", 1, 128)
        );
        assert!(!invalid.to_string().contains("do-not-print"));
    }

    #[test]
    fn challenge_resource_bounds_are_validated() {
        let invalid = config(|arguments| arguments.challenge_cleanup_batch_size = 0);
        assert_eq!(
            invalid.expect_err("zero cleanup batch must fail"),
            ConfigError::ValueOutOfRange("challenge cleanup batch size", 1, 10_000)
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
