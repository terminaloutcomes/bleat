use opentelemetry::{KeyValue, global, trace::TracerProvider as _};
use opentelemetry_appender_tracing::layer::OpenTelemetryTracingBridge;
use opentelemetry_sdk::{
    Resource, logs::SdkLoggerProvider, propagation::TraceContextPropagator,
    trace::SdkTracerProvider,
};
use thiserror::Error;
use tracing::Level;
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
            tracing::warn!(error = %error, "failed to flush OpenTelemetry traces");
        }
        if let Some(provider) = self.logger_provider
            && let Err(error) = provider.shutdown()
        {
            tracing::warn!(error = %error, "failed to flush OpenTelemetry logs");
        }
    }
}

pub fn log_startup_settings(config: &Config) {
    tracing::info!(
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
        request_timeout_seconds = config.request_timeout.as_secs(),
        max_request_body_bytes = config.max_request_body_bytes,
        max_concurrent_requests = config.max_concurrent_requests,
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
    target.starts_with("opentelemetry")
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
    };

    use axum::{body::Body, http::Request};
    use clap::Parser;
    use opentelemetry::{
        Key, Value,
        trace::{SpanId, TraceId},
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

    use super::*;
    use crate::{
        config::{Arguments, Config, TelemetryExportConfig},
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

    #[test]
    fn startup_event_reports_settings_without_sensitive_values() {
        let database_secret = "database-secret-marker";
        let apple_team_id = "apple-team-id-marker";
        let app_identifier = "app-identifier-marker";
        let database_url =
            format!("postgres://bleat:{database_secret}@database.example:5432/bleat");
        let arguments = Arguments::try_parse_from([
            "bleat-api",
            "--database-url",
            &database_url,
            "--bind-address",
            "0.0.0.0:9000",
            "--public-issuer",
            "https://telemetry.example/issuer",
            "--apple-team-id",
            apple_team_id,
            "--app-identifier",
            app_identifier,
            "--database-max-connections",
            "24",
            "--database-connect-timeout-seconds",
            "7",
            "--challenge-lifetime-seconds",
            "180",
            "--challenge-cleanup-batch-size",
            "750",
            "--challenge-issuance-per-minute",
            "450",
            "--token-lifetime-seconds",
            "900",
            "--request-timeout-seconds",
            "12",
            "--max-request-body-bytes",
            "131072",
            "--max-concurrent-requests",
            "96",
            "--log-format",
            "json",
        ])
        .expect("test arguments should parse");
        let config = Config::from_arguments(
            arguments,
            TelemetryExportConfig {
                traces_enabled: true,
                logs_enabled: false,
            },
        )
        .expect("test config should validate");
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
        let arguments = Arguments::try_parse_from([
            "bleat-api",
            "--database-url",
            "postgres://bleat:development@127.0.0.1:5432/bleat",
        ])
        .expect("test arguments should parse");
        let config = Config::from_arguments(arguments, TelemetryExportConfig::default())
            .expect("test config should validate");
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
        let request = Request::get("/readyz")
            .header("content-type", "application/json")
            .header("authorization", sensitive_authorization)
            .header(
                "traceparent",
                "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
            )
            .body(Body::from(sensitive_body))
            .expect("valid request");

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
            tracing::warn!(target: "opentelemetry_exporter", "exporter-local-only");
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
        assert!(!local_output.contains(sensitive_body));
        assert!(!local_output.contains(sensitive_authorization));

        let spans = span_exporter
            .get_finished_spans()
            .expect("test spans should be readable");
        assert_eq!(spans.len(), 1);
        assert_eq!(spans[0].name, "http.request");
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
            span_attribute(&spans[0].attributes, "http.response.status_code"),
            Some(&Value::I64(503))
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
