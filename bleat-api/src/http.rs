use std::{sync::Arc, time::Instant};

use axum::{
    Json, Router,
    body::Body,
    extract::{DefaultBodyLimit, Extension, MatchedPath, State, rejection::JsonRejection},
    http::{HeaderName, HeaderValue, Request, StatusCode},
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::{get, post},
};
use chrono::{DateTime, Utc};
use opentelemetry::global;
use opentelemetry_http::HeaderExtractor;
use sea_orm::DatabaseConnection;
use serde::{Deserialize, Serialize};
use tracing::{Instrument, field, info, info_span};
use tracing_opentelemetry::OpenTelemetrySpanExt;
use uuid::Uuid;

use crate::{
    challenge::{
        ChallengeConsumeOutcome, ChallengePurpose, ChallengeRepository, ChallengeStoreError,
        ExpectedChallenge, IssuedChallenge,
    },
    config::{Config, DeploymentMode},
    database,
    error::ApiError,
    installation::{
        CounterAdvanceOutcome, InstallationEnvironment, InstallationRepository,
        InstallationStoreError, NewInstallation,
    },
    telemetry_auth::{
        ClientDataPurpose, DevelopmentTokenIssuer, JwkSet, OpenIdConfiguration, TokenResponse,
        client_data_hash, verify_development_assertion, verify_development_attestation,
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
    deployment_mode: DeploymentMode,
    development_token_issuer: Option<Arc<DevelopmentTokenIssuer>>,
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

pub fn router(config: &Config, database: DatabaseConnection) -> Router {
    let limits = RequestLimits {
        timeout: config.request_timeout,
        permits: Arc::new(tokio::sync::Semaphore::new(config.max_concurrent_requests)),
    };
    let state = AppState {
        challenges: ChallengeRepository::new(
            database.clone(),
            config.challenge_cleanup_batch_size as u64,
        ),
        installations: InstallationRepository::new(database.clone()),
        deployment_mode: config.deployment_mode,
        development_token_issuer: if config.deployment_mode == DeploymentMode::Development {
            DevelopmentTokenIssuer::generate(&config.public_issuer, config.token_lifetime)
                .ok()
                .map(Arc::new)
        } else {
            None
        },
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

    Router::new()
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
        .layer(middleware::from_fn(instrument_request))
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
    if state.deployment_mode != DeploymentMode::Development {
        return Err(ApiError::authentication_rejected(request_id.0));
    }
    let hash = client_data_hash(
        ClientDataPurpose::AttestationEnroll,
        payload.challenge_id,
        &payload.challenge,
        None,
    );
    let public_key =
        verify_development_attestation(&payload.key_id, &payload.attestation_object, &hash)
            .map_err(|_| ApiError::authentication_rejected(request_id.0))?;
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
            public_key,
            environment: InstallationEnvironment::Development,
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
    let Some(issuer) = state.development_token_issuer.as_ref() else {
        return Err(ApiError::authentication_rejected(request_id.0));
    };
    let installation = state
        .installations
        .find_active(payload.installation_id)
        .await
        .map_err(|error| map_installation_error(error, request_id))?
        .ok_or_else(|| ApiError::authentication_rejected(request_id.0))?;
    if installation.environment != InstallationEnvironment::Development {
        return Err(ApiError::authentication_rejected(request_id.0));
    }
    let hash = client_data_hash(
        ClientDataPurpose::TokenIssue,
        payload.challenge_id,
        &payload.challenge,
        Some(payload.installation_id),
    );
    verify_development_assertion(&installation.public_key, &payload.assertion_object, &hash)
        .map_err(|_| ApiError::authentication_rejected(request_id.0))?;
    consume_challenge(
        &state,
        payload.challenge_id,
        &payload.challenge,
        ExpectedChallenge {
            purpose: ChallengePurpose::TokenIssue,
            installation_id: Some(payload.installation_id),
        },
        request_id,
    )
    .await?;
    let Some(next_counter) = installation.sign_count.checked_add(1) else {
        return Err(ApiError::authentication_rejected(request_id.0));
    };
    match state
        .installations
        .advance_counter(
            payload.installation_id,
            installation.sign_count,
            next_counter,
        )
        .await
        .map_err(|error| map_installation_error(error, request_id))?
    {
        CounterAdvanceOutcome::Advanced => {}
        CounterAdvanceOutcome::Conflict
        | CounterAdvanceOutcome::Disabled
        | CounterAdvanceOutcome::NotFound
        | CounterAdvanceOutcome::InvalidTransition => {
            return Err(ApiError::authentication_rejected(request_id.0));
        }
    }
    let response: TokenResponse = issuer
        .issue(payload.installation_id, Utc::now())
        .map_err(|_| ApiError::temporarily_unavailable(request_id.0))?;
    Ok(Json(response).into_response())
}

async fn discovery(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
) -> Result<Json<OpenIdConfiguration>, ApiError> {
    let issuer = state
        .development_token_issuer
        .as_ref()
        .ok_or_else(|| ApiError::temporarily_unavailable(request_id.0))?;
    Ok(Json(issuer.discovery()))
}

async fn jwks(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
) -> Result<Json<JwkSet>, ApiError> {
    let issuer = state
        .development_token_issuer
        .as_ref()
        .ok_or_else(|| ApiError::temporarily_unavailable(request_id.0))?;
    issuer
        .jwks()
        .map(Json)
        .map_err(|_| ApiError::temporarily_unavailable(request_id.0))
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
        | InstallationStoreError::InvalidStoredState => {
            ApiError::authentication_rejected(request_id.0)
        }
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
    let parent_context = global::get_text_map_propagator(|propagator| {
        propagator.extract(&HeaderExtractor(request.headers()))
    });
    let span = info_span!(
        "http.request",
        http.request.method = %method,
        http.route = %route,
        http.response.status_code = field::Empty,
        request.id = %request_id,
    );
    if let Err(error) = span.set_parent(parent_context) {
        tracing::debug!(error = %error, "ignored invalid remote trace context");
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
