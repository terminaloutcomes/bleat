use std::{sync::Arc, time::Instant};

use axum::{
    Json, Router,
    body::Body,
    extract::{DefaultBodyLimit, Extension, MatchedPath, State, rejection::JsonRejection},
    http::{
        HeaderMap, HeaderName, HeaderValue, Request, StatusCode,
        header::{CACHE_CONTROL, CONTENT_TYPE, ETAG, IF_NONE_MATCH, USER_AGENT},
    },
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::{get, post},
};
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use chrono::{DateTime, Utc};
use opentelemetry::global;
use opentelemetry_http::HeaderExtractor;
use sea_orm::DatabaseConnection;
use serde::{Deserialize, Serialize};
use serde_json::json;
use sha2::{Digest, Sha256};
use tracing::{Instrument, debug, field, info, info_span, warn};
use tracing_opentelemetry::OpenTelemetrySpanExt;
use uuid::Uuid;

use crate::{
    app_attest::{
        AppAttestPolicy, AppAttestVerificationError, AuthenticatedInstallationPrincipal,
        InstallationEvidenceVerifier,
    },
    challenge::{
        ChallengeConsumeOutcome, ChallengePurpose, ChallengeRepository, ChallengeStoreError,
        ExpectedChallenge, IssuedChallenge,
    },
    config::{Config, DeploymentMode},
    database,
    error::ApiError,
    installation::{
        CounterAdvanceOutcome, InstallationRepository, InstallationStoreError, NewInstallation,
    },
    telemetry_auth::{
        ClientDataPurpose, JWKS_CACHE_SECONDS, TokenIssuer, TokenIssuerError, TokenResponse,
        client_data_hash,
    },
};

const REQUEST_ID_HEADER: HeaderName = HeaderName::from_static("x-request-id");

#[derive(Clone, Copy, Debug)]
struct RequestId(Uuid);

#[derive(Clone)]
struct RequestLimits {
    timeout: std::time::Duration,
    permits: Arc<tokio::sync::Semaphore>,
}

#[derive(Clone)]
struct AppState {
    database: DatabaseConnection,
    challenges: ChallengeRepository,
    installations: InstallationRepository,
    evidence_verifier: Arc<InstallationEvidenceVerifier>,
    token_issuer: Arc<TokenIssuer>,
    challenge_lifetime: std::time::Duration,
    issuance_limiter: IssuanceLimiter,
}

#[derive(Clone)]
struct IssuanceLimiter {
    maximum: usize,
    window: Arc<tokio::sync::Mutex<IssuanceWindow>>,
}

struct IssuanceWindow {
    started: Instant,
    issued: usize,
}

impl IssuanceLimiter {
    fn new(maximum: usize) -> Self {
        Self {
            maximum,
            window: Arc::new(tokio::sync::Mutex::new(IssuanceWindow {
                started: Instant::now(),
                issued: 0,
            })),
        }
    }

    async fn allow(&self) -> bool {
        let mut window = self.window.lock().await;
        if window.started.elapsed() >= std::time::Duration::from_secs(60) {
            window.started = Instant::now();
            window.issued = 0;
        }
        if window.issued >= self.maximum {
            return false;
        }
        window.issued += 1;
        true
    }
}

#[derive(Debug, Serialize)]
struct StatusBody {
    status: &'static str,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct AttestationChallengeRequest {}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct TokenChallengeRequest {
    installation_id: Uuid,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct EnrollmentRequest {
    challenge_id: Uuid,
    challenge: String,
    key_id: String,
    attestation_object: String,
}

#[derive(Debug, Serialize)]
struct EnrollmentResponse {
    installation_id: Uuid,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct TokenRequest {
    installation_id: Uuid,
    challenge_id: Uuid,
    challenge: String,
    assertion_object: String,
}

#[derive(Debug, Serialize)]
struct ChallengeResponse {
    challenge_id: Uuid,
    challenge: String,
    expires_at: DateTime<Utc>,
}

impl From<IssuedChallenge> for ChallengeResponse {
    fn from(challenge: IssuedChallenge) -> Self {
        Self {
            challenge_id: challenge.challenge_id,
            challenge: challenge.challenge,
            expires_at: challenge.expires_at,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, thiserror::Error)]
pub enum RouterBuildError {
    #[error("production App Attest verification configuration is invalid")]
    AppAttest,
    #[error("JWT signing configuration is invalid: {0}")]
    TokenIssuer(#[source] TokenIssuerError),
}

pub fn router(config: &Config, database: DatabaseConnection) -> Result<Router, RouterBuildError> {
    let limits = RequestLimits {
        timeout: config.request_timeout,
        permits: Arc::new(tokio::sync::Semaphore::new(config.max_concurrent_requests)),
    };
    let evidence_verifier = match config.deployment_mode {
        DeploymentMode::Development => InstallationEvidenceVerifier::Development,
        DeploymentMode::Production => InstallationEvidenceVerifier::production(
            config
                .apple_team_id
                .as_deref()
                .ok_or(RouterBuildError::AppAttest)?,
            config
                .app_identifier
                .as_deref()
                .ok_or(RouterBuildError::AppAttest)?,
            config.app_attest_environment,
            AppAttestPolicy::new(
                config.app_attest_bundle_versions.clone(),
                config.app_attest_validation_categories.iter().copied(),
            )
            .map_err(|_| RouterBuildError::AppAttest)?,
        )
        .map_err(|_| RouterBuildError::AppAttest)?,
    };
    let token_issuer = match config.deployment_mode {
        DeploymentMode::Development => {
            TokenIssuer::generate(&config.public_issuer, config.token_lifetime)
        }
        DeploymentMode::Production => TokenIssuer::from_files(
            &config.public_issuer,
            config.token_lifetime,
            config
                .jwt_signing_key_file
                .as_ref()
                .ok_or(RouterBuildError::TokenIssuer(
                    TokenIssuerError::SigningKeyConfiguration,
                ))?
                .as_path(),
            config
                .jwt_public_key_set_file
                .as_ref()
                .map(|path| path.as_path()),
        ),
    };
    let token_issuer = Arc::new(token_issuer.map_err(RouterBuildError::TokenIssuer)?);
    let state = AppState {
        challenges: ChallengeRepository::new(
            database.clone(),
            config.challenge_cleanup_batch_size as u64,
        ),
        installations: InstallationRepository::new(database.clone()),
        evidence_verifier: Arc::new(evidence_verifier),
        token_issuer,
        database,
        challenge_lifetime: config.challenge_lifetime,
        issuance_limiter: IssuanceLimiter::new(config.challenge_issuance_per_minute),
    };
    let protected_routes = Router::new()
        .route("/v1/attestation/challenge", post(attestation_challenge))
        .route("/v1/attestation/enroll", post(enroll))
        .route("/v1/token/challenge", post(token_challenge))
        .route("/v1/token", post(token))
        .with_state(state.clone());

    Ok(Router::new()
        .route("/healthz", get(health))
        .route("/readyz", get(ready))
        .route("/.well-known/openid-configuration", get(discovery))
        .route("/.well-known/jwks.json", get(jwks))
        .with_state(state)
        .merge(apply_limits(
            protected_routes,
            limits,
            config.max_request_body_bytes,
        ))
        .layer(middleware::from_fn(instrument_request)))
}

fn apply_limits(routes: Router, limits: RequestLimits, max_request_body_bytes: usize) -> Router {
    routes
        .layer(DefaultBodyLimit::max(max_request_body_bytes))
        .layer(middleware::from_fn_with_state(limits, enforce_limits))
}

async fn health() -> Json<StatusBody> {
    Json(StatusBody { status: "ok" })
}

async fn ready(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
) -> Result<Json<StatusBody>, ApiError> {
    if database::is_ready(&state.database).await {
        Ok(Json(StatusBody { status: "ready" }))
    } else {
        Err(ApiError::temporarily_unavailable(request_id.0))
    }
}

async fn attestation_challenge(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    payload: Result<Json<AttestationChallengeRequest>, JsonRejection>,
) -> Result<Response, ApiError> {
    let Json(_payload) = parse_json(payload, request_id)?;
    ensure_issuance_allowed(&state, request_id).await?;
    let challenge = state
        .challenges
        .issue_attestation_at(state.challenge_lifetime, Utc::now())
        .await
        .map_err(|error| map_challenge_error(error, request_id))?;
    Ok((
        StatusCode::CREATED,
        Json(ChallengeResponse::from(challenge)),
    )
        .into_response())
}

async fn token_challenge(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    payload: Result<Json<TokenChallengeRequest>, JsonRejection>,
) -> Result<Response, ApiError> {
    let Json(payload) = parse_json(payload, request_id)?;
    ensure_issuance_allowed(&state, request_id).await?;
    let challenge = state
        .challenges
        .issue_token_at(
            payload.installation_id,
            state.challenge_lifetime,
            Utc::now(),
        )
        .await
        .map_err(|error| map_challenge_error(error, request_id))?;
    Ok((
        StatusCode::CREATED,
        Json(ChallengeResponse::from(challenge)),
    )
        .into_response())
}

async fn enroll(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    payload: Result<Json<EnrollmentRequest>, JsonRejection>,
) -> Result<Response, ApiError> {
    let Json(payload) = parse_json(payload, request_id)?;
    let hash = client_data_hash(
        ClientDataPurpose::AttestationEnroll,
        payload.challenge_id,
        &payload.challenge,
        None,
    );
    let verified = state
        .evidence_verifier
        .verify_attestation(&payload.key_id, &payload.attestation_object, &hash)
        .map_err(|error| map_verification_error("attestation.enroll", error, request_id))?;
    consume_challenge(
        &state,
        payload.challenge_id,
        &payload.challenge,
        ExpectedChallenge {
            purpose: ChallengePurpose::AttestationEnroll,
            installation_id: None,
        },
        request_id,
    )
    .await?;
    let installation = state
        .installations
        .create_verified(NewInstallation {
            app_attest_key_id: payload.key_id,
            public_key: verified.public_key,
            environment: verified.environment,
        })
        .await
        .map_err(|error| map_installation_error(error, request_id))?;
    Ok((
        StatusCode::CREATED,
        Json(EnrollmentResponse {
            installation_id: installation.id,
        }),
    )
        .into_response())
}

async fn token(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    payload: Result<Json<TokenRequest>, JsonRejection>,
) -> Result<Response, ApiError> {
    let Json(payload) = parse_json(payload, request_id)?;
    let principal = authenticate_installation(&state, &payload, request_id).await?;
    let response: TokenResponse = state
        .token_issuer
        .issue(principal.installation_id, Utc::now())
        .map_err(|_| {
            warn!(
                operation = "token.issue",
                category = "token.signer_failure",
                request_id = %request_id.0,
                "token issuance failed"
            );
            ApiError::temporarily_unavailable(request_id.0)
        })?;
    info!(
        operation = "token.issue",
        outcome = "issued",
        request_id = %request_id.0,
        "telemetry token issued"
    );
    Ok(Json(response).into_response())
}

async fn authenticate_installation(
    state: &AppState,
    payload: &TokenRequest,
    request_id: RequestId,
) -> Result<AuthenticatedInstallationPrincipal, ApiError> {
    let installation = state
        .installations
        .find_active(payload.installation_id)
        .await
        .map_err(|error| map_installation_error(error, request_id))?
        .ok_or_else(|| ApiError::authentication_rejected(request_id.0))?;
    let hash = client_data_hash(
        ClientDataPurpose::TokenIssue,
        payload.challenge_id,
        &payload.challenge,
        Some(payload.installation_id),
    );
    let verified = state
        .evidence_verifier
        .verify_assertion(
            &installation.public_key,
            installation.environment,
            &payload.assertion_object,
            &hash,
            installation.sign_count,
        )
        .map_err(|error| map_verification_error("assertion.authenticate", error, request_id))?;
    consume_challenge(
        state,
        payload.challenge_id,
        &payload.challenge,
        ExpectedChallenge {
            purpose: ChallengePurpose::TokenIssue,
            installation_id: Some(payload.installation_id),
        },
        request_id,
    )
    .await?;
    match state
        .installations
        .advance_counter(
            payload.installation_id,
            installation.sign_count,
            verified.counter,
        )
        .await
        .map_err(|error| map_installation_error(error, request_id))?
    {
        CounterAdvanceOutcome::Advanced => {}
        CounterAdvanceOutcome::Conflict
        | CounterAdvanceOutcome::Disabled
        | CounterAdvanceOutcome::NotFound
        | CounterAdvanceOutcome::InvalidTransition => {
            warn!(
                operation = "assertion.authenticate",
                category = "assertion.counter_conflict",
                request_id = %request_id.0,
                "installation authentication rejected"
            );
            return Err(ApiError::authentication_rejected(request_id.0));
        }
    }
    Ok(AuthenticatedInstallationPrincipal {
        installation_id: installation.id,
        environment: installation.environment,
    })
}

fn map_verification_error(
    operation: &'static str,
    error: AppAttestVerificationError,
    request_id: RequestId,
) -> ApiError {
    let category = error.category().metric_name();
    let stage = error.stage().metric_name();
    let detail = error.detail().metric_name();
    let observed_type = error.observed_type().map(|value| value.metric_name());
    let span = tracing::Span::current();
    span.record("app_attest.failure.category", category);
    span.record("app_attest.failure.stage", stage);
    span.record("app_attest.failure.detail", detail);
    if let Some(observed_type) = observed_type {
        span.record("app_attest.observed.cbor_type", observed_type);
    }
    if let Some(observed_length) = error.observed_length() {
        span.record("app_attest.observed.length", observed_length);
    }
    if let Some(observed_count) = error.observed_count() {
        span.record("app_attest.observed.count", observed_count);
    }
    if let Some(observed_flags) = error.observed_flags() {
        span.record("app_attest.observed.flags", observed_flags);
    }
    warn!(
        operation,
        category,
        stage,
        detail,
        observed_type,
        observed_length = error.observed_length(),
        observed_count = error.observed_count(),
        observed_flags = error.observed_flags(),
        request_id = %request_id.0,
        "installation authentication rejected"
    );
    ApiError::authentication_rejected(request_id.0)
}

async fn discovery(
    State(state): State<AppState>,
    headers: HeaderMap,
    Extension(request_id): Extension<RequestId>,
) -> Result<Response, ApiError> {
    cacheable_json(&state.token_issuer.discovery(), &headers, request_id)
}

async fn jwks(
    State(state): State<AppState>,
    headers: HeaderMap,
    Extension(request_id): Extension<RequestId>,
) -> Result<Response, ApiError> {
    let jwks = state
        .token_issuer
        .jwks_at(Utc::now())
        .map_err(|_| ApiError::temporarily_unavailable(request_id.0))?;
    cacheable_json(&jwks, &headers, request_id)
}

fn cacheable_json(
    value: &impl Serialize,
    request_headers: &HeaderMap,
    request_id: RequestId,
) -> Result<Response, ApiError> {
    let body = json!(value).to_string();
    let etag = format!("\"{}\"", URL_SAFE_NO_PAD.encode(Sha256::digest(&body)));
    let not_modified = request_headers
        .get(IF_NONE_MATCH)
        .is_some_and(|candidate| candidate.as_bytes() == etag.as_bytes());

    let mut response = if not_modified {
        Response::new(Body::empty())
    } else {
        Response::new(Body::from(body))
    };
    *response.status_mut() = if not_modified {
        StatusCode::NOT_MODIFIED
    } else {
        StatusCode::OK
    };
    let etag_header = HeaderValue::from_str(&etag)
        .map_err(|_| ApiError::temporarily_unavailable(request_id.0))?;
    response.headers_mut().insert(ETAG, etag_header);
    let cache_control = HeaderValue::from_str(&format!("public, max-age={JWKS_CACHE_SECONDS}"))
        .map_err(|_| ApiError::temporarily_unavailable(request_id.0))?;
    response.headers_mut().insert(CACHE_CONTROL, cache_control);
    if !not_modified {
        response
            .headers_mut()
            .insert(CONTENT_TYPE, HeaderValue::from_static("application/json"));
    }
    Ok(response)
}

async fn consume_challenge(
    state: &AppState,
    challenge_id: Uuid,
    challenge: &str,
    expected: ExpectedChallenge,
    request_id: RequestId,
) -> Result<(), ApiError> {
    match state
        .challenges
        .consume_at(challenge_id, challenge, expected, Utc::now())
        .await
        .map_err(|error| map_challenge_error(error, request_id))?
    {
        ChallengeConsumeOutcome::Consumed => Ok(()),
        ChallengeConsumeOutcome::Invalid
        | ChallengeConsumeOutcome::WrongPurpose
        | ChallengeConsumeOutcome::WrongBinding
        | ChallengeConsumeOutcome::Expired
        | ChallengeConsumeOutcome::Replayed => Err(ApiError::authentication_rejected(request_id.0)),
    }
}

fn parse_json<T>(
    payload: Result<Json<T>, JsonRejection>,
    request_id: RequestId,
) -> Result<Json<T>, ApiError> {
    payload.map_err(|rejection| {
        if rejection.status() == StatusCode::PAYLOAD_TOO_LARGE {
            ApiError::request_too_large(request_id.0)
        } else {
            ApiError::malformed(request_id.0)
        }
    })
}

async fn ensure_issuance_allowed(state: &AppState, request_id: RequestId) -> Result<(), ApiError> {
    if state.issuance_limiter.allow().await {
        Ok(())
    } else {
        Err(ApiError::issuance_rate_limited(request_id.0))
    }
}

fn map_challenge_error(error: ChallengeStoreError, request_id: RequestId) -> ApiError {
    match error {
        ChallengeStoreError::AuthenticationRejected => {
            ApiError::authentication_rejected(request_id.0)
        }
        ChallengeStoreError::RandomUnavailable | ChallengeStoreError::Database => {
            ApiError::temporarily_unavailable(request_id.0)
        }
    }
}

fn map_installation_error(error: InstallationStoreError, request_id: RequestId) -> ApiError {
    match error {
        InstallationStoreError::Database => ApiError::temporarily_unavailable(request_id.0),
        InstallationStoreError::InvalidKeyIdentifier
        | InstallationStoreError::InvalidPublicKey
        | InstallationStoreError::InvalidStoredState
        | InstallationStoreError::DuplicateKey => ApiError::authentication_rejected(request_id.0),
    }
}

async fn enforce_limits(
    State(limits): State<RequestLimits>,
    request: Request<Body>,
    next: Next,
) -> Response {
    let request_id = request
        .extensions()
        .get::<RequestId>()
        .map_or_else(Uuid::new_v4, |request_id| request_id.0);
    let permit = match Arc::clone(&limits.permits).try_acquire_owned() {
        Ok(permit) => permit,
        Err(_) => return ApiError::rate_limited(request_id).into_response(),
    };
    let operation = async move {
        let response = next.run(request).await;
        drop(permit);
        response
    };

    match tokio::time::timeout(limits.timeout, operation).await {
        Ok(response) => response,
        Err(_) => ApiError::timed_out(request_id).into_response(),
    }
}

async fn instrument_request(mut request: Request<Body>, next: Next) -> Response {
    let request_id = Uuid::new_v4();
    request.extensions_mut().insert(RequestId(request_id));

    let method = request.method().clone();
    let route = request
        .extensions()
        .get::<MatchedPath>()
        .map_or("unmatched", MatchedPath::as_str)
        .to_owned();
    let url_scheme = request.uri().scheme_str().unwrap_or("http").to_owned();
    let user_agent = request
        .headers()
        .get(USER_AGENT)
        .and_then(|value| value.to_str().ok())
        .map(str::to_owned);
    let parent_context = global::get_text_map_propagator(|propagator| {
        propagator.extract(&HeaderExtractor(request.headers()))
    });
    let span = info_span!(
        "http.request",
        http.request.method = %method,
        http.route = %route,
        url.path = %route,
        url.scheme = %url_scheme,
        user_agent.original = field::Empty,
        app_attest.failure.category = field::Empty,
        app_attest.failure.stage = field::Empty,
        app_attest.failure.detail = field::Empty,
        app_attest.observed.cbor_type = field::Empty,
        app_attest.observed.length = field::Empty,
        app_attest.observed.count = field::Empty,
        app_attest.observed.flags = field::Empty,
        http.response.status_code = field::Empty,
        request.id = %request_id,
    );
    if let Some(user_agent) = user_agent.as_deref() {
        span.record("user_agent.original", user_agent);
    }
    if let Err(error) = span.set_parent(parent_context) {
        debug!(error = %error, "ignored invalid remote trace context");
    }

    let started = Instant::now();
    let mut response = next.run(request).instrument(span.clone()).await;
    span.record(
        "http.response.status_code",
        i64::from(response.status().as_u16()),
    );
    span.in_scope(|| {
        info!(
            event.name = "request.completed",
            http.response.status_code = response.status().as_u16(),
            duration_ms = started.elapsed().as_millis() as u64,
            "request completed"
        );
    });

    if let Ok(value) = HeaderValue::from_str(&request_id.to_string()) {
        response.headers_mut().insert(REQUEST_ID_HEADER, value);
    }
    response
}

#[cfg(test)]
mod tests {
    use std::sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    };

    use axum::{extract::State, routing::get};
    use tower::ServiceExt;

    use super::*;

    #[derive(Default)]
    struct Activity {
        active: AtomicUsize,
        maximum: AtomicUsize,
    }

    async fn slow(State(activity): State<Arc<Activity>>) -> StatusCode {
        let active = activity.active.fetch_add(1, Ordering::SeqCst) + 1;
        activity.maximum.fetch_max(active, Ordering::SeqCst);
        tokio::time::sleep(std::time::Duration::from_millis(40)).await;
        activity.active.fetch_sub(1, Ordering::SeqCst);
        StatusCode::NO_CONTENT
    }

    fn limited_router(
        timeout: std::time::Duration,
        permits: usize,
        activity: Arc<Activity>,
    ) -> Router {
        let protected = Router::new().route("/slow", get(slow)).with_state(activity);
        Router::new()
            .route("/healthz", get(health))
            .merge(apply_limits(
                protected,
                RequestLimits {
                    timeout,
                    permits: Arc::new(tokio::sync::Semaphore::new(permits)),
                },
                1_024,
            ))
            .layer(middleware::from_fn(instrument_request))
    }

    #[tokio::test]
    async fn timeout_is_typed_and_uses_the_request_correlation_id() {
        let _tracing_guard = crate::TRACING_TEST_LOCK.lock().await;
        let response = limited_router(
            std::time::Duration::from_millis(1),
            1,
            Arc::new(Activity::default()),
        )
        .oneshot(
            Request::get("/slow")
                .body(Body::empty())
                .expect("valid request"),
        )
        .await
        .expect("router should respond");

        assert_eq!(response.status(), StatusCode::GATEWAY_TIMEOUT);
        let header = response
            .headers()
            .get(REQUEST_ID_HEADER)
            .expect("request ID should be present")
            .to_str()
            .expect("request ID should be text")
            .to_owned();
        let bytes = http_body_util::BodyExt::collect(response.into_body())
            .await
            .expect("response body should collect")
            .to_bytes();
        let body: serde_json::Value =
            serde_json::from_slice(&bytes).expect("response should be JSON");
        assert_eq!(body["error"]["code"], "temporarily_unavailable");
        assert_eq!(body["request_id"], header);
    }

    #[tokio::test]
    async fn excess_concurrent_requests_are_rejected_without_queuing() {
        let _tracing_guard = crate::TRACING_TEST_LOCK.lock().await;
        let activity = Arc::new(Activity::default());
        let router = limited_router(std::time::Duration::from_secs(1), 1, Arc::clone(&activity));
        let request = || {
            Request::get("/slow")
                .body(Body::empty())
                .expect("valid request")
        };

        let (first, second) =
            tokio::join!(router.clone().oneshot(request()), router.oneshot(request()));
        let first = first.expect("first request should finish");
        let second = second.expect("second request should finish");
        let (completed, rejected) = if first.status() == StatusCode::NO_CONTENT {
            (first, second)
        } else {
            (second, first)
        };
        assert_eq!(completed.status(), StatusCode::NO_CONTENT);
        assert_eq!(rejected.status(), StatusCode::SERVICE_UNAVAILABLE);
        let rejected_body = http_body_util::BodyExt::collect(rejected.into_body())
            .await
            .expect("rejection body should collect")
            .to_bytes();
        let rejected_body: serde_json::Value =
            serde_json::from_slice(&rejected_body).expect("rejection body should be JSON");
        assert_eq!(rejected_body["error"]["code"], "rate_limited");
        assert_eq!(activity.maximum.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn health_remains_available_while_protected_capacity_is_exhausted() {
        let _tracing_guard = crate::TRACING_TEST_LOCK.lock().await;
        let activity = Arc::new(Activity::default());
        let router = limited_router(std::time::Duration::from_secs(1), 1, Arc::clone(&activity));
        let slow_router = router.clone();
        let slow_request = tokio::spawn(async move {
            slow_router
                .oneshot(
                    Request::get("/slow")
                        .body(Body::empty())
                        .expect("valid request"),
                )
                .await
                .expect("slow route should respond")
        });
        while activity.active.load(Ordering::SeqCst) == 0 {
            tokio::task::yield_now().await;
        }

        let health_response = router
            .oneshot(
                Request::get("/healthz")
                    .body(Body::empty())
                    .expect("valid request"),
            )
            .await
            .expect("health route should respond");

        assert_eq!(health_response.status(), StatusCode::OK);
        assert_eq!(
            slow_request
                .await
                .expect("slow task should finish")
                .status(),
            StatusCode::NO_CONTENT
        );
    }
}
