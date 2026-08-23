use opentelemetry::{KeyValue, global, trace::TracerProvider as _};
use opentelemetry_appender_tracing::layer::OpenTelemetryTracingBridge;
use opentelemetry_sdk::{
    Resource, logs::SdkLoggerProvider, propagation::TraceContextPropagator,
    trace::SdkTracerProvider,
};
use thiserror::Error;
use tracing::{Level, info, warn};
use tracing_subscriber::{
    Layer as _, Registry,
    filter::{EnvFilter, filter_fn},
    layer::SubscriberExt,
    util::SubscriberInitExt,
};

use crate::config::{Config, LogFormat};

pub struct Observability {
    tracer_provider: Option<SdkTracerProvider>,
    logger_provider: Option<SdkLoggerProvider>,
}

impl Observability {
    pub fn install(config: &Config) -> Result<Self, ObservabilityError> {
        global::set_text_map_propagator(TraceContextPropagator::new());
        let resource = Resource::builder()
            .with_service_name("bleat-api")
            .with_attributes([
                KeyValue::new("service.version", env!("CARGO_PKG_VERSION")),
                KeyValue::new(
                    "deployment.environment.name",
                    config.deployment_mode.to_string(),
                ),
            ])
            .build();

        let tracer_provider = build_tracer_provider(config, resource.clone())?;
        let logger_provider = build_logger_provider(config, resource)?;
        install_subscriber(config, tracer_provider.as_ref(), logger_provider.as_ref())?;

        Ok(Self {
            tracer_provider,
            logger_provider,
        })
    }

    pub fn shutdown(self) {
        if let Some(provider) = self.tracer_provider
            && let Err(error) = provider.shutdown()
        {
            warn!(error = %error, "failed to flush OpenTelemetry traces");
        }
        if let Some(provider) = self.logger_provider
            && let Err(error) = provider.shutdown()
        {
            warn!(error = %error, "failed to flush OpenTelemetry logs");
        }
    }
}

pub fn log_startup_settings(config: &Config) {
    info!(
        bind_address = %config.bind_address,
        public_issuer = %config.public_issuer,
        deployment_environment = %config.deployment_mode,
        app_attest_environment = %config.app_attest_environment,
        apple_team_id_configured = config.apple_team_id.is_some(),
        app_identifier_configured = config.app_identifier.is_some(),
        database_max_connections = config.database.max_connections,
        database_connect_timeout_seconds = config.database.connect_timeout.as_secs(),
        challenge_lifetime_seconds = config.challenge_lifetime.as_secs(),
        challenge_cleanup_batch_size = config.challenge_cleanup_batch_size,
        challenge_issuance_per_minute = config.challenge_issuance_per_minute,
        token_lifetime_seconds = config.token_lifetime.as_secs(),
        jwt_signing_key_configured = config.jwt_signing_key_file.is_some(),
        jwt_rotation_keys_configured = config.jwt_public_key_set_file.is_some(),
        request_timeout_seconds = config.request_timeout.as_secs(),
        max_request_body_bytes = config.max_request_body_bytes,
        max_concurrent_requests = config.max_concurrent_requests,
        trusted_proxy_cidr_count = config.trusted_proxies.cidrs().len(),
        trusted_forwarding_headers = ?config.trusted_proxies.forwarding_headers(),
        forwarding_debug = config.trusted_proxies.debug,
        log_filter = %config.log_filter,
        log_format = %config.log_format,
        otlp_traces_enabled = config.telemetry.traces_enabled,
        otlp_logs_enabled = config.telemetry.logs_enabled,
        jwt_algorithm = "ES256",
        "bleat-api started"
    );
}

#[derive(Debug, Error)]
pub enum ObservabilityError {
    #[error("invalid local log filter")]
    InvalidLogFilter(#[source] tracing_subscriber::filter::ParseError),
    #[error("failed to configure OTLP trace export")]
    TraceExporter(#[source] opentelemetry_otlp::ExporterBuildError),
    #[error("failed to configure OTLP log export")]
    LogExporter(#[source] opentelemetry_otlp::ExporterBuildError),
    #[error("the global tracing subscriber is already installed")]
    SubscriberAlreadyInstalled,
}

fn build_tracer_provider(
    config: &Config,
    resource: Resource,
) -> Result<Option<SdkTracerProvider>, ObservabilityError> {
    if !config.telemetry.traces_enabled {
        return Ok(None);
    }
    let exporter = opentelemetry_otlp::SpanExporter::builder()
        .with_http()
        .build()
        .map_err(ObservabilityError::TraceExporter)?;
    Ok(Some(
        SdkTracerProvider::builder()
            .with_resource(resource)
            .with_batch_exporter(exporter)
            .build(),
    ))
}

fn build_logger_provider(
    config: &Config,
    resource: Resource,
) -> Result<Option<SdkLoggerProvider>, ObservabilityError> {
    if !config.telemetry.logs_enabled {
        return Ok(None);
    }
    let exporter = opentelemetry_otlp::LogExporter::builder()
        .with_http()
        .build()
        .map_err(ObservabilityError::LogExporter)?;
    Ok(Some(
        SdkLoggerProvider::builder()
            .with_resource(resource)
            .with_batch_exporter(exporter)
            .build(),
    ))
}

fn install_subscriber(
    config: &Config,
    tracer_provider: Option<&SdkTracerProvider>,
    logger_provider: Option<&SdkLoggerProvider>,
) -> Result<(), ObservabilityError> {
    EnvFilter::try_new(&config.log_filter).map_err(ObservabilityError::InvalidLogFilter)?;
    let tracer = tracer_provider.map(|provider| provider.tracer("bleat-api"));
    let trace_layer = tracer.map(|tracer| {
        tracing_opentelemetry::layer()
            .with_tracer(tracer)
            .with_filter(filter_fn(export_trace_metadata))
    });
    let log_layer = logger_provider.map(|provider| {
        OpenTelemetryTracingBridge::new(provider).with_filter(filter_fn(export_log_metadata))
    });

    let registry = Registry::default().with(trace_layer).with(log_layer);
    match config.log_format {
        LogFormat::Compact => registry
            .with(
                tracing_subscriber::fmt::layer()
                    .with_writer(std::io::stderr)
                    .with_filter(
                        EnvFilter::try_new(&config.log_filter)
                            .map_err(ObservabilityError::InvalidLogFilter)?,
                    ),
            )
            .try_init()
            .map_err(|_| ObservabilityError::SubscriberAlreadyInstalled),
        LogFormat::Json => registry
            .with(
                tracing_subscriber::fmt::layer()
                    .json()
                    .with_writer(std::io::stderr)
                    .with_filter(
                        EnvFilter::try_new(&config.log_filter)
                            .map_err(ObservabilityError::InvalidLogFilter)?,
                    ),
            )
            .try_init()
            .map_err(|_| ObservabilityError::SubscriberAlreadyInstalled),
    }
}

fn is_exporter_target(target: &str) -> bool {
    target == crate::forwarding::FORWARDING_DEBUG_TARGET
        || target.starts_with("opentelemetry")
        || target.starts_with("reqwest")
        || target.starts_with("hyper")
        || target.starts_with("rustls")
}

fn export_trace_metadata(metadata: &tracing::Metadata<'_>) -> bool {
    metadata.is_span() && *metadata.level() <= Level::INFO
}

fn export_log_metadata(metadata: &tracing::Metadata<'_>) -> bool {
    metadata.is_event()
        && *metadata.level() <= Level::INFO
        && !is_exporter_target(metadata.target())
}

#[cfg(test)]
mod tests {
    use std::{
        io::{self, Write},
        sync::{Arc, Mutex},
        time::Duration,
    };

    use axum::{
        body::Body,
        extract::ConnectInfo,
        http::{Method, Request, StatusCode},
    };
    use opentelemetry::{
        Key, Value,
        trace::{SpanId, SpanKind, Status, TraceId},
    };
    use opentelemetry_sdk::{
        Resource,
        logs::{InMemoryLogExporter, SdkLoggerProvider},
        propagation::TraceContextPropagator,
        trace::{InMemorySpanExporter, Sampler, SdkTracerProvider},
    };
    use tower::ServiceExt;
    use tracing::instrument::WithSubscriber;
    use tracing_subscriber::{filter::filter_fn, layer::SubscriberExt};
    use url::Url;

    use super::*;
    use crate::{
        config::{
            AppAttestEnvironment, Config, DatabaseConfig, DeploymentMode, ForwardingHeader,
            TelemetryExportConfig, TrustedProxyConfig,
        },
        router,
    };

    #[derive(Clone, Default)]
    struct Buffer(Arc<Mutex<Vec<u8>>>);

    struct BufferWriter(Buffer);

    impl Write for BufferWriter {
        fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
            self.0
                .0
                .lock()
                .expect("test log buffer lock should not be poisoned")
                .extend_from_slice(bytes);
            Ok(bytes.len())
        }

        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    impl<'writer> tracing_subscriber::fmt::MakeWriter<'writer> for Buffer {
        type Writer = BufferWriter;

        fn make_writer(&'writer self) -> Self::Writer {
            BufferWriter(self.clone())
        }
    }

    impl Buffer {
        fn contents(&self) -> String {
            String::from_utf8(
                self.0
                    .lock()
                    .expect("test log buffer lock should not be poisoned")
                    .clone(),
            )
            .expect("test logs should be UTF-8")
        }
    }

    fn test_config(log_format: LogFormat, log_filter: &str) -> Config {
        Config {
            bind_address: "127.0.0.1:8080"
                .parse()
                .expect("test bind address should parse"),
            public_issuer: Url::parse("http://127.0.0.1:8080").expect("test issuer should parse"),
            deployment_mode: DeploymentMode::Development,
            apple_team_id: None,
            app_identifier: None,
            app_attest_environment: AppAttestEnvironment::Development,
            app_attest_bundle_versions: Vec::new(),
            app_attest_validation_categories: Vec::new(),
            database: DatabaseConfig::new(
                "postgres://bleat:development@127.0.0.1:5432/bleat".to_owned(),
                16,
                Duration::from_secs(5),
            )
            .expect("test database configuration should validate"),
            challenge_lifetime: Duration::from_secs(120),
            challenge_cleanup_batch_size: 1_000,
            challenge_issuance_per_minute: 600,
            token_lifetime: Duration::from_secs(600),
            jwt_signing_key_file: None,
            jwt_public_key_set_file: None,
            request_timeout: Duration::from_secs(10),
            max_request_body_bytes: 65_536,
            max_concurrent_requests: 64,
            trusted_proxies: crate::config::TrustedProxyConfig::new(Vec::new(), Vec::new(), false)
                .expect("empty trusted proxy configuration should validate"),
            log_filter: log_filter.to_owned(),
            log_format,
            telemetry: TelemetryExportConfig::default(),
        }
    }

    #[test]
    fn exporter_filters_exclude_internal_targets_and_debug_spans() {
        for target in [
            "opentelemetry",
            "opentelemetry_sdk",
            "reqwest",
            "hyper::client",
            "rustls::client",
            crate::forwarding::FORWARDING_DEBUG_TARGET,
        ] {
            assert!(is_exporter_target(target));
        }
        assert!(!is_exporter_target("bleat_api::http"));

        let info = tracing::info_span!("coverage_info_span");
        assert!(export_trace_metadata(
            info.metadata().expect("info span should have metadata")
        ));
        let debug = tracing::debug_span!("coverage_debug_span");
        assert!(!export_trace_metadata(
            debug.metadata().expect("debug span should have metadata")
        ));
    }

    #[test]
    fn subscriber_installation_is_typed_for_invalid_and_duplicate_configuration() {
        let invalid = test_config(LogFormat::Compact, "[");
        assert!(matches!(
            Observability::install(&invalid),
            Err(ObservabilityError::InvalidLogFilter(_))
        ));

        let json = test_config(LogFormat::Json, "bleat_api=info");
        let installed = Observability::install(&json).expect("subscriber should install once");
        let compact = test_config(LogFormat::Compact, "bleat_api=info");
        assert!(matches!(
            Observability::install(&compact),
            Err(ObservabilityError::SubscriberAlreadyInstalled)
        ));
        installed.shutdown();
    }

    #[test]
    fn startup_event_reports_settings_without_sensitive_values() {
        let database_secret = "database-secret-marker";
        let apple_team_id = "apple-team-id-marker";
        let app_identifier = "app-identifier-marker";
        let database_url =
            format!("postgres://bleat:{database_secret}@database.example:5432/bleat");
        let mut config = test_config(LogFormat::Json, "bleat_api=info");
        config.bind_address = "0.0.0.0:9000"
            .parse()
            .expect("test bind address should parse");
        config.public_issuer =
            Url::parse("https://telemetry.example/issuer").expect("test issuer should parse");
        config.apple_team_id = Some(apple_team_id.to_owned());
        config.app_identifier = Some(app_identifier.to_owned());
        config.database = DatabaseConfig::new(database_url.clone(), 24, Duration::from_secs(7))
            .expect("test database configuration should validate");
        config.challenge_lifetime = Duration::from_secs(180);
        config.challenge_cleanup_batch_size = 750;
        config.challenge_issuance_per_minute = 450;
        config.token_lifetime = Duration::from_secs(900);
        config.request_timeout = Duration::from_secs(12);
        config.max_request_body_bytes = 131_072;
        config.max_concurrent_requests = 96;
        config.telemetry = TelemetryExportConfig {
            traces_enabled: true,
            logs_enabled: false,
        };
        let local = Buffer::default();
        let subscriber = Registry::default().with(
            tracing_subscriber::fmt::layer()
                .json()
                .with_writer(local.clone()),
        );

        tracing::subscriber::with_default(subscriber, || log_startup_settings(&config));

        let output = local.contents();
        for expected in [
            "bleat-api started",
            "0.0.0.0:9000",
            "https://telemetry.example/issuer",
            "development",
            "database_max_connections\":24",
            "database_connect_timeout_seconds\":7",
            "challenge_lifetime_seconds\":180",
            "challenge_cleanup_batch_size\":750",
            "challenge_issuance_per_minute\":450",
            "token_lifetime_seconds\":900",
            "request_timeout_seconds\":12",
            "max_request_body_bytes\":131072",
            "max_concurrent_requests\":96",
            "apple_team_id_configured\":true",
            "app_identifier_configured\":true",
            "otlp_traces_enabled\":true",
            "otlp_logs_enabled\":false",
            "jwt_algorithm\":\"ES256\"",
        ] {
            assert!(output.contains(expected), "missing {expected} in {output}");
        }
        for sensitive in [
            database_secret,
            &database_url,
            apple_team_id,
            app_identifier,
        ] {
            assert!(!output.contains(sensitive));
        }
    }

    #[tokio::test]
    async fn one_request_fans_out_locally_and_to_correlated_trace_and_log_signals() {
        let _tracing_guard = crate::TRACING_TEST_LOCK.lock().await;
        global::set_text_map_propagator(TraceContextPropagator::new());
        let resource = Resource::builder_empty()
            .with_service_name("bleat-api")
            .with_attribute(KeyValue::new("deployment.environment.name", "development"))
            .build();
        let span_exporter = InMemorySpanExporter::default();
        let tracer_provider = SdkTracerProvider::builder()
            .with_resource(resource.clone())
            .with_sampler(Sampler::AlwaysOn)
            .with_simple_exporter(span_exporter.clone())
            .build();
        let log_exporter = InMemoryLogExporter::default();
        let logger_provider = SdkLoggerProvider::builder()
            .with_resource(resource)
            .with_simple_exporter(log_exporter.clone())
            .build();
        let mut config = test_config(
            LogFormat::Compact,
            "bleat_api=info,opentelemetry=warn,opentelemetry_sdk=warn,opentelemetry-otlp=warn",
        );
        config.trusted_proxies = TrustedProxyConfig::new(
            vec!["10.0.0.0/8".to_owned()],
            vec![ForwardingHeader::XForwardedFor],
            true,
        )
        .expect("test forwarding configuration should validate");
        let local = Buffer::default();
        let subscriber = Registry::default()
            .with(
                tracing_opentelemetry::layer()
                    .with_tracer(tracer_provider.tracer("bleat-api"))
                    .with_filter(filter_fn(export_trace_metadata)),
            )
            .with(
                OpenTelemetryTracingBridge::new(&logger_provider)
                    .with_filter(filter_fn(export_log_metadata)),
            )
            .with(
                tracing_subscriber::fmt::layer()
                    .json()
                    .with_writer(local.clone())
                    .with_filter(
                        EnvFilter::try_new(&config.log_filter)
                            .expect("default local log filter should parse"),
                    ),
            );

        let sensitive_body = "sensitive-attestation-marker";
        let sensitive_authorization = "Bearer sensitive-token-marker";
        let sensitive_forwarding = "203.0.113.44, 10.1.0.1";
        let mut request = Request::get("/readyz?probe=telemetry")
            .header("content-type", "application/json")
            .header("authorization", sensitive_authorization)
            .header("x-forwarded-for", sensitive_forwarding)
            .header("user-agent", "BleatTelemetryTest/1.0")
            .header(
                "traceparent",
                "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
            )
            .body(Body::from(sensitive_body))
            .expect("valid request");
        request.extensions_mut().insert(ConnectInfo(
            "10.0.0.9:43123"
                .parse::<std::net::SocketAddr>()
                .expect("test peer address should parse"),
        ));

        async {
            let response = router(&config, sea_orm::DatabaseConnection::default())
                .expect("router should build")
                .oneshot(request)
                .await
                .expect("router should respond");
            assert_eq!(
                response.status(),
                axum::http::StatusCode::SERVICE_UNAVAILABLE
            );
            warn!(target: "opentelemetry_exporter", "exporter-local-only");
        }
        .with_subscriber(subscriber)
        .await;

        tracer_provider
            .force_flush()
            .expect("test spans should flush");
        logger_provider
            .force_flush()
            .expect("test logs should flush");

        let local_output = local.contents();
        assert!(local_output.contains("request completed"));
        assert!(local_output.contains("exporter-local-only"));
        assert!(local_output.contains("forwarding diagnostics"));
        assert!(local_output.contains(sensitive_forwarding));
        assert!(!local_output.contains(sensitive_body));
        assert!(!local_output.contains(sensitive_authorization));

        let spans = span_exporter
            .get_finished_spans()
            .expect("test spans should be readable");
        assert_eq!(spans.len(), 1);
        assert_eq!(spans[0].name, "GET /readyz");
        assert_eq!(spans[0].span_kind, SpanKind::Server);
        assert_eq!(spans[0].status, Status::error(""));
        assert_eq!(
            spans[0].span_context.trace_id(),
            TraceId::from_hex("4bf92f3577b34da6a3ce929d0e0e4736").expect("trace ID should parse")
        );
        assert_eq!(
            spans[0].parent_span_id,
            SpanId::from_hex("00f067aa0ba902b7").expect("span ID should parse")
        );
        assert_eq!(
            span_attribute(&spans[0].attributes, "http.request.method"),
            Some(&Value::String("GET".into()))
        );
        assert_eq!(
            span_attribute(&spans[0].attributes, "http.route"),
            Some(&Value::String("/readyz".into()))
        );
        assert_eq!(
            span_attribute(&spans[0].attributes, "url.path"),
            Some(&Value::String("/readyz".into()))
        );
        assert_eq!(
            span_attribute(&spans[0].attributes, "url.scheme"),
            Some(&Value::String("http".into()))
        );
        assert_eq!(
            span_attribute(&spans[0].attributes, "user_agent.original"),
            Some(&Value::String("BleatTelemetryTest/1.0".into()))
        );
        assert_eq!(
            span_attribute(&spans[0].attributes, "http.response.status_code"),
            Some(&Value::I64(503))
        );
        assert_eq!(
            span_attribute(&spans[0].attributes, "error.type"),
            Some(&Value::String("503".into()))
        );
        assert_eq!(
            span_attribute(&spans[0].attributes, "network.peer.address"),
            Some(&Value::String("10.0.0.9".into()))
        );
        assert_eq!(
            span_attribute(&spans[0].attributes, "network.peer.port"),
            Some(&Value::I64(43_123))
        );
        assert_eq!(
            span_attribute(&spans[0].attributes, "client.address"),
            Some(&Value::String("203.0.113.44".into()))
        );
        assert!(spans[0].events.is_empty());
        assert!(!format!("{spans:?}").contains(sensitive_body));
        assert!(!format!("{spans:?}").contains(sensitive_authorization));

        let logs = log_exporter
            .get_emitted_logs()
            .expect("test logs should be readable");
        assert_eq!(logs.len(), 1);
        let trace_context = logs[0]
            .record
            .trace_context()
            .expect("request log should carry trace context");
        assert_eq!(trace_context.trace_id, spans[0].span_context.trace_id());
        assert_eq!(trace_context.span_id, spans[0].span_context.span_id());
        assert_eq!(
            logs[0].resource.get(&Key::new("service.name")),
            Some("bleat-api".into())
        );
        let logs_debug = format!("{logs:?}");
        assert!(!logs_debug.contains("exporter-local-only"));
        assert!(!logs_debug.contains(sensitive_forwarding));
        assert!(!logs_debug.contains(sensitive_body));
        assert!(!logs_debug.contains(sensitive_authorization));

        tracer_provider
            .shutdown()
            .expect("test tracer should shut down");
        logger_provider
            .shutdown()
            .expect("test logger should shut down");
        assert!(span_exporter.is_shutdown_called());
        assert!(log_exporter.is_shutdown_called());
    }

    #[tokio::test]
    async fn exported_http_server_spans_classify_routes_statuses_and_proxy_addresses() {
        let _tracing_guard = crate::TRACING_TEST_LOCK.lock().await;
        global::set_text_map_propagator(TraceContextPropagator::new());
        let span_exporter = InMemorySpanExporter::default();
        let tracer_provider = SdkTracerProvider::builder()
            .with_sampler(Sampler::AlwaysOn)
            .with_simple_exporter(span_exporter.clone())
            .build();
        let subscriber = Registry::default().with(
            tracing_opentelemetry::layer()
                .with_tracer(tracer_provider.tracer("bleat-api"))
                .with_filter(filter_fn(export_trace_metadata)),
        );
        let direct_peer = "198.51.100.20:41000"
            .parse::<std::net::SocketAddr>()
            .expect("direct peer should parse");
        let trusted_peer = "10.0.0.9:42000"
            .parse::<std::net::SocketAddr>()
            .expect("trusted peer should parse");

        let mut requests = Vec::new();
        let mut direct_success = request_with_peer(Method::GET, "/healthz", direct_peer);
        direct_success.headers_mut().insert(
            "x-forwarded-for",
            "203.0.113.200"
                .parse()
                .expect("spoofed forwarding header should parse"),
        );
        requests.push((
            test_config(LogFormat::Compact, "bleat_api=info"),
            direct_success,
        ));
        requests.push((
            test_config(LogFormat::Compact, "bleat_api=info"),
            request_with_peer(Method::POST, "/healthz", direct_peer),
        ));
        requests.push((
            test_config(LogFormat::Compact, "bleat_api=info"),
            request_with_peer(Method::GET, "/readyz", direct_peer),
        ));
        requests.push((
            test_config(LogFormat::Compact, "bleat_api=info"),
            request_with_peer(
                Method::GET,
                "/sensitive-unmatched-value?token=query-marker",
                direct_peer,
            ),
        ));

        let mut cloudflare = test_config(LogFormat::Compact, "bleat_api=info");
        cloudflare.trusted_proxies = TrustedProxyConfig::new(
            vec!["10.0.0.0/8".to_owned()],
            vec![ForwardingHeader::Cloudflare],
            false,
        )
        .expect("Cloudflare test configuration should validate");
        let mut cloudflare_request = request_with_peer(Method::GET, "/healthz", trusted_peer);
        cloudflare_request.headers_mut().insert(
            "cf-connecting-ip",
            "240.0.0.7"
                .parse()
                .expect("pseudo IPv4 header should parse"),
        );
        cloudflare_request.headers_mut().insert(
            "cf-connecting-ipv6",
            "2001:db8::7"
                .parse()
                .expect("visitor IPv6 header should parse"),
        );
        requests.push((cloudflare, cloudflare_request));

        let mut xff = test_config(LogFormat::Compact, "bleat_api=info");
        xff.trusted_proxies = TrustedProxyConfig::new(
            vec!["10.0.0.0/8".to_owned()],
            vec![ForwardingHeader::XForwardedFor],
            false,
        )
        .expect("X-Forwarded-For test configuration should validate");
        let mut xff_request = request_with_peer(Method::GET, "/healthz", trusted_peer);
        xff_request.headers_mut().insert(
            "x-forwarded-for",
            "203.0.113.9, 10.1.1.1"
                .parse()
                .expect("forwarded chain should parse"),
        );
        requests.push((xff, xff_request));

        let mut forwarded = test_config(LogFormat::Compact, "bleat_api=info");
        forwarded.trusted_proxies = TrustedProxyConfig::new(
            vec!["10.0.0.0/8".to_owned()],
            vec![ForwardingHeader::Forwarded],
            false,
        )
        .expect("Forwarded test configuration should validate");
        let mut forwarded_request = request_with_peer(Method::GET, "/healthz", trusted_peer);
        forwarded_request.headers_mut().insert(
            "forwarded",
            "for=203.0.113.10;proto=https, for=10.1.1.2"
                .parse()
                .expect("RFC 7239 chain should parse"),
        );
        requests.push((forwarded, forwarded_request));

        let mut conflict = test_config(LogFormat::Compact, "bleat_api=info");
        conflict.trusted_proxies =
            TrustedProxyConfig::new(vec!["10.0.0.0/8".to_owned()], Vec::new(), false)
                .expect("implicit all-family configuration should validate");
        let mut conflict_request = request_with_peer(Method::GET, "/healthz", trusted_peer);
        conflict_request.headers_mut().insert(
            "cf-connecting-ip",
            "203.0.113.11"
                .parse()
                .expect("Cloudflare conflict header should parse"),
        );
        conflict_request.headers_mut().insert(
            "x-forwarded-for",
            "203.0.113.12"
                .parse()
                .expect("X-Forwarded-For conflict header should parse"),
        );
        requests.push((conflict, conflict_request));

        let statuses = async {
            let mut statuses = Vec::new();
            for (config, request) in requests {
                let response = router(&config, sea_orm::DatabaseConnection::default())
                    .expect("router should build")
                    .oneshot(request)
                    .await
                    .expect("router should respond");
                statuses.push(response.status());
            }
            statuses
        }
        .with_subscriber(subscriber)
        .await;
        assert_eq!(
            statuses,
            [
                StatusCode::OK,
                StatusCode::METHOD_NOT_ALLOWED,
                StatusCode::SERVICE_UNAVAILABLE,
                StatusCode::NOT_FOUND,
                StatusCode::OK,
                StatusCode::OK,
                StatusCode::OK,
                StatusCode::OK,
            ]
        );

        tracer_provider
            .force_flush()
            .expect("test spans should flush");
        let spans = span_exporter
            .get_finished_spans()
            .expect("test spans should be readable");
        assert_eq!(spans.len(), 8);
        assert_eq!(spans[0].name, "GET /healthz");
        assert_eq!(spans[1].name, "POST /healthz");
        assert_eq!(spans[2].name, "GET /readyz");
        assert_eq!(spans[3].name, "GET");
        assert!(spans.iter().all(|span| span.span_kind == SpanKind::Server));
        assert_eq!(spans[0].status, Status::Unset);
        assert_eq!(spans[1].status, Status::Unset);
        assert_eq!(spans[2].status, Status::error(""));
        assert_eq!(spans[3].status, Status::Unset);
        assert_eq!(
            span_attribute(&spans[2].attributes, "error.type"),
            Some(&Value::String("503".into()))
        );
        assert!(span_attribute(&spans[1].attributes, "error.type").is_none());
        assert!(span_attribute(&spans[3].attributes, "http.route").is_none());
        assert_eq!(
            span_attribute(&spans[3].attributes, "url.path"),
            Some(&Value::String("/*".into()))
        );
        assert!(!format!("{:?}", spans[3]).contains("sensitive-unmatched-value"));
        assert!(!format!("{:?}", spans[3]).contains("query-marker"));
        for (index, expected) in [
            (0, "198.51.100.20"),
            (4, "2001:db8::7"),
            (5, "203.0.113.9"),
            (6, "203.0.113.10"),
            (7, "10.0.0.9"),
        ] {
            assert_eq!(
                span_attribute(&spans[index].attributes, "client.address"),
                Some(&Value::String(expected.into()))
            );
        }
        for span in &spans {
            assert!(span_attribute(&span.attributes, "http.request.method").is_some());
            assert!(span_attribute(&span.attributes, "http.response.status_code").is_some());
        }
        tracer_provider
            .shutdown()
            .expect("test tracer should shut down");
    }

    fn request_with_peer(method: Method, uri: &str, peer: std::net::SocketAddr) -> Request<Body> {
        let mut request = Request::builder()
            .method(method)
            .uri(uri)
            .body(Body::empty())
            .expect("test request should build");
        request.extensions_mut().insert(ConnectInfo(peer));
        request
    }

    fn span_attribute<'attributes>(
        attributes: &'attributes [KeyValue],
        name: &str,
    ) -> Option<&'attributes Value> {
        attributes
            .iter()
            .find(|attribute| attribute.key.as_str() == name)
            .map(|attribute| &attribute.value)
    }
}
