use axum::{
    body::Body,
    http::{
        Request, StatusCode,
        header::{CACHE_CONTROL, ETAG, IF_NONE_MATCH},
    },
};
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use bleat_api::{
    config::{Arguments, Config, TelemetryExportConfig},
    database::connect_and_migrate,
    http::RouterBuildError,
    installation::{
        DisableOutcome, InstallationEnvironment, InstallationRepository, NewInstallation,
    },
    router,
    telemetry_auth::{
        ClientDataPurpose, DevelopmentAssertion, DevelopmentAttestation, TokenIssuerError,
        client_data_hash,
    },
};
use clap::Parser;
use compact_jwt::{Jwk, JwsEs256Signer, JwsEs256Verifier, JwsVerifier, JwtUnverified};
use http_body_util::BodyExt;
use p256::ecdsa::{Signature, SigningKey, signature::Signer};
use sea_orm::DatabaseConnection;
use serde::Deserialize;
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::str::FromStr;
use tower::ServiceExt;
use uuid::Uuid;

mod support;

use support::TestPostgres;

fn test_config(postgres: &TestPostgres, extra_arguments: &[&str]) -> Config {
    let mut arguments = vec!["bleat-api", "--database-url", postgres.database_url()];
    arguments.extend(extra_arguments.iter().copied());
    Config::from_arguments(
        Arguments::try_parse_from(arguments).expect("test arguments should parse"),
        TelemetryExportConfig::default(),
    )
    .expect("test configuration should validate")
}

async fn database(postgres: &TestPostgres) -> DatabaseConnection {
    connect_and_migrate(&postgres.config())
        .await
        .expect("test database should connect")
}

async fn test_router(postgres: &TestPostgres, extra_arguments: &[&str]) -> axum::Router {
    let config = test_config(postgres, extra_arguments);
    router(&config, database(postgres).await).expect("router should build")
}

async fn production_router(postgres: &TestPostgres) -> axum::Router {
    let signer = JwsEs256Signer::generate_es256().expect("production test signer should generate");
    let key = signer
        .private_key_to_der()
        .expect("production test signer should export");
    let path = std::env::temp_dir().join(format!("bleat-production-jwt-{}.der", Uuid::new_v4()));
    std::fs::write(&path, key.as_slice()).expect("production test key should be written");
    let path_argument = path.to_string_lossy().into_owned();
    let config = test_config(
        postgres,
        &[
            "--deployment-mode",
            "production",
            "--public-issuer",
            "https://telemetry.example.test",
            "--apple-team-id",
            "TEAM123456",
            "--app-identifier",
            "com.example.Bleat",
            "--app-attest-environment",
            "production",
            "--app-attest-bundle-versions",
            "1",
            "--app-attest-validation-categories",
            "2,4",
            "--jwt-signing-key-file",
            path_argument.as_str(),
        ],
    );
    let result = router(&config, database(postgres).await).expect("production router should build");
    std::fs::remove_file(path).expect("production test key should be removed");
    result
}

#[tokio::test]
async fn production_router_preserves_the_signing_configuration_failure() {
    let postgres = TestPostgres::start().await;
    let path = std::env::temp_dir().join(format!("bleat-invalid-jwt-{}.der", Uuid::new_v4()));
    std::fs::write(&path, b"not-a-signing-key").expect("invalid test key should be written");
    let path_argument = path.to_string_lossy().into_owned();
    let config = test_config(
        &postgres,
        &[
            "--deployment-mode",
            "production",
            "--public-issuer",
            "https://telemetry.example.test",
            "--apple-team-id",
            "TEAM123456",
            "--app-identifier",
            "com.example.Bleat",
            "--app-attest-environment",
            "production",
            "--app-attest-bundle-versions",
            "1",
            "--app-attest-validation-categories",
            "2,4",
            "--jwt-signing-key-file",
            path_argument.as_str(),
        ],
    );
    let error = router(&config, database(&postgres).await)
        .expect_err("invalid signing material should prevent router construction");
    std::fs::remove_file(path).expect("invalid test key should be removed");

    assert_eq!(
        error,
        RouterBuildError::TokenIssuer(TokenIssuerError::SigningKeyConfiguration)
    );
    assert_eq!(
        error.to_string(),
        "JWT signing configuration is invalid: token signing-key configuration is invalid"
    );
}

async fn response_json(response: axum::response::Response) -> Value {
    let bytes = response
        .into_body()
        .collect()
        .await
        .expect("response body should collect")
        .to_bytes();
    serde_json::from_slice(&bytes).expect("response should be JSON")
}

async fn post_json(router: &axum::Router, path: &str, body: Value) -> axum::response::Response {
    router
        .clone()
        .oneshot(
            Request::post(path)
                .header("content-type", "application/json")
                .body(Body::from(body.to_string()))
                .expect("valid request"),
        )
        .await
        .expect("router should respond")
}

async fn development_challenge(router: &axum::Router, path: &str, body: Value) -> (Uuid, String) {
    let response = post_json(router, path, body).await;
    assert_eq!(response.status(), StatusCode::CREATED);
    let response = response_json(response).await;
    (
        Uuid::parse_str(
            response["challenge_id"]
                .as_str()
                .expect("challenge ID should be text"),
        )
        .expect("challenge ID should parse"),
        response["challenge"]
            .as_str()
            .expect("challenge should be text")
            .to_owned(),
    )
}

fn development_key(seed: u8) -> SigningKey {
    SigningKey::from_slice(&[seed; 32]).expect("test key should be valid")
}

fn development_key_id(signing_key: &SigningKey) -> String {
    URL_SAFE_NO_PAD.encode(Sha256::digest(
        signing_key
            .verifying_key()
            .to_encoded_point(false)
            .as_bytes(),
    ))
}

fn development_attestation(
    signing_key: &SigningKey,
    signature_key: &SigningKey,
    challenge_id: Uuid,
    challenge: &str,
) -> String {
    let hash = client_data_hash(
        ClientDataPurpose::AttestationEnroll,
        challenge_id,
        challenge,
        None,
    );
    let signature: Signature = signature_key.sign(&hash);
    let evidence = DevelopmentAttestation {
        public_key: URL_SAFE_NO_PAD.encode(
            signing_key
                .verifying_key()
                .to_encoded_point(false)
                .as_bytes(),
        ),
        signature: URL_SAFE_NO_PAD.encode(signature.to_der().as_bytes()),
    };
    URL_SAFE_NO_PAD.encode(serde_json::to_vec(&evidence).expect("evidence should encode"))
}

fn development_assertion(
    signing_key: &SigningKey,
    installation_id: Uuid,
    challenge_id: Uuid,
    challenge: &str,
) -> String {
    let hash = client_data_hash(
        ClientDataPurpose::TokenIssue,
        challenge_id,
        challenge,
        Some(installation_id),
    );
    let signature: Signature = signing_key.sign(&hash);
    let evidence = DevelopmentAssertion {
        signature: URL_SAFE_NO_PAD.encode(signature.to_der().as_bytes()),
    };
    URL_SAFE_NO_PAD.encode(serde_json::to_vec(&evidence).expect("evidence should encode"))
}

async fn enroll_development(router: &axum::Router, signing_key: &SigningKey) -> Uuid {
    let (challenge_id, challenge) =
        development_challenge(router, "/v1/attestation/challenge", serde_json::json!({})).await;
    let response = post_json(
        router,
        "/v1/attestation/enroll",
        serde_json::json!({
            "challenge_id": challenge_id,
            "challenge": challenge,
            "key_id": development_key_id(signing_key),
            "attestation_object": development_attestation(
                signing_key,
                signing_key,
                challenge_id,
                &challenge,
            ),
        }),
    )
    .await;
    assert_eq!(response.status(), StatusCode::CREATED);
    let response = response_json(response).await;
    Uuid::parse_str(
        response["installation_id"]
            .as_str()
            .expect("installation ID should be text"),
    )
    .expect("installation ID should parse")
}

#[tokio::test]
async fn health_and_readiness_are_typed_and_receive_request_ids() {
    let postgres = TestPostgres::start().await;
    for (path, expected_status) in [("/healthz", "ok"), ("/readyz", "ready")] {
        let response = test_router(&postgres, &[])
            .await
            .oneshot(
                Request::get(path)
                    .body(Body::empty())
                    .expect("valid request"),
            )
            .await
            .expect("router should respond");

        assert_eq!(response.status(), StatusCode::OK);
        let request_id = response
            .headers()
            .get("x-request-id")
            .expect("request ID header should be present")
            .to_str()
            .expect("request ID should be text");
        Uuid::parse_str(request_id).expect("request ID should be a UUID");
        assert_eq!(response_json(response).await["status"], expected_status);
    }
}

#[tokio::test]
async fn production_verification_routes_reject_development_evidence() {
    let postgres = TestPostgres::start().await;
    let production = production_router(&postgres).await;
    for (path, body) in [
        (
            "/v1/attestation/enroll",
            serde_json::json!({
                "challenge_id": Uuid::new_v4(),
                "challenge": "development-evidence",
                "key_id": "development-key",
                "attestation_object": "development-evidence",
            }),
        ),
        (
            "/v1/token",
            serde_json::json!({
                "installation_id": Uuid::new_v4(),
                "challenge_id": Uuid::new_v4(),
                "challenge": "development-evidence",
                "assertion_object": "development-evidence",
            }),
        ),
    ] {
        let response = production
            .clone()
            .oneshot(
                Request::post(path)
                    .header("content-type", "application/json")
                    .body(Body::from(body.to_string()))
                    .expect("valid request"),
            )
            .await
            .expect("router should respond");

        assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
        let header_request_id = response
            .headers()
            .get("x-request-id")
            .expect("request ID header should be present")
            .to_str()
            .expect("request ID should be text")
            .to_owned();
        let body = response_json(response).await;
        assert_eq!(body["error"]["code"], "authentication_rejected");
        assert_eq!(body["request_id"], header_request_id);
        assert!(body.to_string().len() < 300);
    }

    for path in [
        "/.well-known/openid-configuration",
        "/.well-known/jwks.json",
    ] {
        let response = production
            .clone()
            .oneshot(
                Request::get(path)
                    .body(Body::empty())
                    .expect("valid request"),
            )
            .await
            .expect("router should respond");
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(response.headers()[CACHE_CONTROL], "public, max-age=60");
        assert!(response.headers().contains_key(ETAG));
    }
}

#[derive(Clone, Debug, Deserialize)]
struct TestTokenClaims {
    scope: String,
}

#[tokio::test]
async fn development_evidence_enrolls_and_issues_verifiable_es256_token() {
    let postgres = TestPostgres::start().await;
    let router = test_router(&postgres, &[]).await;
    let signing_key = SigningKey::from_slice(&[9_u8; 32]).expect("test key should be valid");
    let public_key = signing_key.verifying_key().to_encoded_point(false);
    let public_key = public_key.as_bytes();
    let key_id = URL_SAFE_NO_PAD.encode(Sha256::digest(public_key));

    let challenge = post_json(&router, "/v1/attestation/challenge", serde_json::json!({})).await;
    assert_eq!(challenge.status(), StatusCode::CREATED);
    let challenge = response_json(challenge).await;
    let challenge_id = Uuid::parse_str(
        challenge["challenge_id"]
            .as_str()
            .expect("challenge ID should be text"),
    )
    .expect("challenge ID should parse");
    let challenge_value = challenge["challenge"]
        .as_str()
        .expect("challenge should be text");
    let hash = client_data_hash(
        ClientDataPurpose::AttestationEnroll,
        challenge_id,
        challenge_value,
        None,
    );
    let signature: Signature = signing_key.sign(&hash);
    let evidence = DevelopmentAttestation {
        public_key: URL_SAFE_NO_PAD.encode(public_key),
        signature: URL_SAFE_NO_PAD.encode(signature.to_der().as_bytes()),
    };
    let evidence =
        URL_SAFE_NO_PAD.encode(serde_json::to_vec(&evidence).expect("evidence should encode"));
    let enrollment = post_json(
        &router,
        "/v1/attestation/enroll",
        serde_json::json!({
            "challenge_id": challenge_id,
            "challenge": challenge_value,
            "key_id": key_id,
            "attestation_object": evidence,
        }),
    )
    .await;
    assert_eq!(enrollment.status(), StatusCode::CREATED);
    let enrollment = response_json(enrollment).await;
    let installation_id = Uuid::parse_str(
        enrollment["installation_id"]
            .as_str()
            .expect("installation ID should be text"),
    )
    .expect("installation ID should parse");

    let token_challenge = post_json(
        &router,
        "/v1/token/challenge",
        serde_json::json!({ "installation_id": installation_id }),
    )
    .await;
    assert_eq!(token_challenge.status(), StatusCode::CREATED);
    let token_challenge = response_json(token_challenge).await;
    let token_challenge_id = Uuid::parse_str(
        token_challenge["challenge_id"]
            .as_str()
            .expect("challenge ID should be text"),
    )
    .expect("challenge ID should parse");
    let token_challenge_value = token_challenge["challenge"]
        .as_str()
        .expect("challenge should be text");
    let hash = client_data_hash(
        ClientDataPurpose::TokenIssue,
        token_challenge_id,
        token_challenge_value,
        Some(installation_id),
    );
    let signature: Signature = signing_key.sign(&hash);
    let evidence = DevelopmentAssertion {
        signature: URL_SAFE_NO_PAD.encode(signature.to_der().as_bytes()),
    };
    let evidence =
        URL_SAFE_NO_PAD.encode(serde_json::to_vec(&evidence).expect("evidence should encode"));
    let token = post_json(
        &router,
        "/v1/token",
        serde_json::json!({
            "installation_id": installation_id,
            "challenge_id": token_challenge_id,
            "challenge": token_challenge_value,
            "assertion_object": evidence,
        }),
    )
    .await;
    assert_eq!(token.status(), StatusCode::OK);
    let token = response_json(token).await;
    assert_eq!(token["token_type"], "Bearer");
    let access_token = token["access_token"]
        .as_str()
        .expect("access token should be text");

    let discovery = router
        .clone()
        .oneshot(
            Request::get("/.well-known/openid-configuration")
                .body(Body::empty())
                .expect("valid request"),
        )
        .await
        .expect("discovery should respond");
    assert_eq!(discovery.status(), StatusCode::OK);
    let discovery = response_json(discovery).await;
    assert_eq!(discovery["issuer"], "http://127.0.0.1:8080");
    assert_eq!(
        discovery["jwks_uri"],
        "http://127.0.0.1:8080/.well-known/jwks.json"
    );
    assert_eq!(
        discovery["id_token_signing_alg_values_supported"],
        serde_json::json!(["ES256"])
    );

    let jwks = router
        .oneshot(
            Request::get("/.well-known/jwks.json")
                .body(Body::empty())
                .expect("valid request"),
        )
        .await
        .expect("JWKS should respond");
    assert_eq!(jwks.status(), StatusCode::OK);
    let jwks = response_json(jwks).await;
    let jwk: Jwk = serde_json::from_value(jwks["keys"][0].clone()).expect("JWKS key should decode");
    let verifier = JwsEs256Verifier::try_from(&jwk).expect("JWK should verify ES256");
    let unverified =
        JwtUnverified::<TestTokenClaims>::from_str(access_token).expect("token should parse");
    let verified = verifier.verify(&unverified).expect("token should verify");
    assert_eq!(
        verified.sub.as_deref(),
        Some(installation_id.to_string().as_str())
    );
    assert_eq!(verified.aud.as_deref(), Some("bleat-telemetry"));
    assert_eq!(verified.extensions.scope, "telemetry:write");
    assert!(verified.nbf.is_none());
    assert!(verified.jti.is_none());
    assert!(verified.claims.is_empty());
}

#[tokio::test]
async fn discovery_and_jwks_support_bounded_conditional_caching() {
    let postgres = TestPostgres::start().await;
    let router = test_router(&postgres, &[]).await;
    for path in [
        "/.well-known/openid-configuration",
        "/.well-known/jwks.json",
    ] {
        let first = router
            .clone()
            .oneshot(
                Request::get(path)
                    .body(Body::empty())
                    .expect("valid request"),
            )
            .await
            .expect("metadata should respond");
        assert_eq!(first.status(), StatusCode::OK);
        assert_eq!(first.headers()[CACHE_CONTROL], "public, max-age=60");
        let etag = first.headers()[ETAG]
            .to_str()
            .expect("ETag should be text")
            .to_owned();
        assert!(!response_json(first).await.is_null());

        let cached = router
            .clone()
            .oneshot(
                Request::get(path)
                    .header(IF_NONE_MATCH, etag)
                    .body(Body::empty())
                    .expect("valid request"),
            )
            .await
            .expect("conditional metadata should respond");
        assert_eq!(cached.status(), StatusCode::NOT_MODIFIED);
        assert_eq!(cached.headers()[CACHE_CONTROL], "public, max-age=60");
        assert_eq!(
            cached
                .into_body()
                .collect()
                .await
                .expect("cached response body should collect")
                .to_bytes()
                .len(),
            0
        );
    }
}

#[tokio::test]
async fn development_evidence_rejects_wrong_key_signature_and_replay() {
    let postgres = TestPostgres::start().await;
    let router = test_router(&postgres, &[]).await;
    let signing_key = development_key(11);
    let wrong_key = development_key(12);
    let (challenge_id, challenge) =
        development_challenge(&router, "/v1/attestation/challenge", serde_json::json!({})).await;
    let valid_evidence =
        development_attestation(&signing_key, &signing_key, challenge_id, &challenge);
    let request = serde_json::json!({
        "challenge_id": challenge_id,
        "challenge": challenge,
        "key_id": development_key_id(&signing_key),
        "attestation_object": valid_evidence,
    });

    let wrong_key_id = post_json(
        &router,
        "/v1/attestation/enroll",
        serde_json::json!({
            "challenge_id": challenge_id,
            "challenge": challenge,
            "key_id": development_key_id(&wrong_key),
            "attestation_object": request["attestation_object"],
        }),
    )
    .await;
    assert_eq!(wrong_key_id.status(), StatusCode::UNAUTHORIZED);

    let wrong_signature = post_json(
        &router,
        "/v1/attestation/enroll",
        serde_json::json!({
            "challenge_id": challenge_id,
            "challenge": challenge,
            "key_id": development_key_id(&signing_key),
            "attestation_object": development_attestation(
                &signing_key,
                &wrong_key,
                challenge_id,
                &challenge,
            ),
        }),
    )
    .await;
    assert_eq!(wrong_signature.status(), StatusCode::UNAUTHORIZED);

    let accepted = post_json(&router, "/v1/attestation/enroll", request.clone()).await;
    assert_eq!(accepted.status(), StatusCode::CREATED);
    let replay = post_json(&router, "/v1/attestation/enroll", request).await;
    assert_eq!(replay.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn development_assertions_reject_wrong_signature_replay_and_disabled_installation() {
    let postgres = TestPostgres::start().await;
    let database = database(&postgres).await;
    let config = test_config(&postgres, &[]);
    let router = router(&config, database.clone()).expect("router should build");
    let signing_key = development_key(13);
    let wrong_key = development_key(14);
    let installation_id = enroll_development(&router, &signing_key).await;
    let (challenge_id, challenge) = development_challenge(
        &router,
        "/v1/token/challenge",
        serde_json::json!({ "installation_id": installation_id }),
    )
    .await;

    let wrong_assertion = post_json(
        &router,
        "/v1/token",
        serde_json::json!({
            "installation_id": installation_id,
            "challenge_id": challenge_id,
            "challenge": challenge,
            "assertion_object": development_assertion(
                &wrong_key,
                installation_id,
                challenge_id,
                &challenge,
            ),
        }),
    )
    .await;
    assert_eq!(wrong_assertion.status(), StatusCode::UNAUTHORIZED);

    let request = serde_json::json!({
        "installation_id": installation_id,
        "challenge_id": challenge_id,
        "challenge": challenge,
        "assertion_object": development_assertion(
            &signing_key,
            installation_id,
            challenge_id,
            &challenge,
        ),
    });
    let accepted = post_json(&router, "/v1/token", request.clone()).await;
    assert_eq!(accepted.status(), StatusCode::OK);
    let replay = post_json(&router, "/v1/token", request).await;
    assert_eq!(replay.status(), StatusCode::UNAUTHORIZED);

    assert_eq!(
        InstallationRepository::new(database)
            .disable(installation_id)
            .await
            .expect("installation should disable"),
        DisableOutcome::Disabled
    );
    let disabled = post_json(
        &router,
        "/v1/token/challenge",
        serde_json::json!({ "installation_id": installation_id }),
    )
    .await;
    assert_eq!(disabled.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn challenge_routes_issue_typed_opaque_challenges() {
    let postgres = TestPostgres::start().await;
    let attestation = test_router(&postgres, &[])
        .await
        .oneshot(
            Request::post("/v1/attestation/challenge")
                .header("content-type", "application/json")
                .body(Body::from("{}"))
                .expect("valid request"),
        )
        .await
        .expect("router should respond");
    assert_eq!(attestation.status(), StatusCode::CREATED);
    let attestation = response_json(attestation).await;
    Uuid::parse_str(
        attestation["challenge_id"]
            .as_str()
            .expect("challenge ID should be text"),
    )
    .expect("challenge ID should be a UUID");
    assert_eq!(
        attestation["challenge"]
            .as_str()
            .expect("challenge should be text")
            .len(),
        43
    );

    let database = database(&postgres).await;
    let installations = InstallationRepository::new(database.clone());
    let installation = installations
        .create_verified(NewInstallation {
            app_attest_key_id: format!("http-key-{}", Uuid::new_v4()),
            public_key: vec![4; 65],
            environment: InstallationEnvironment::Development,
        })
        .await
        .expect("installation should persist");
    let config = test_config(&postgres, &[]);
    let token = router(&config, database)
        .expect("router should build")
        .oneshot(
            Request::post("/v1/token/challenge")
                .header("content-type", "application/json")
                .body(Body::from(format!(
                    "{{\"installation_id\":\"{}\"}}",
                    installation.id
                )))
                .expect("valid request"),
        )
        .await
        .expect("router should respond");
    assert_eq!(token.status(), StatusCode::CREATED);
}

#[tokio::test]
async fn unknown_installations_and_excess_issuance_are_typed() {
    let postgres = TestPostgres::start().await;
    let unknown = test_router(&postgres, &[])
        .await
        .oneshot(
            Request::post("/v1/token/challenge")
                .header("content-type", "application/json")
                .body(Body::from(format!(
                    "{{\"installation_id\":\"{}\"}}",
                    Uuid::new_v4()
                )))
                .expect("valid request"),
        )
        .await
        .expect("router should respond");
    assert_eq!(unknown.status(), StatusCode::UNAUTHORIZED);
    assert_eq!(
        response_json(unknown).await["error"]["code"],
        "authentication_rejected"
    );

    let router = test_router(&postgres, &["--challenge-issuance-per-minute", "1"]).await;
    let request = || {
        Request::post("/v1/attestation/challenge")
            .header("content-type", "application/json")
            .body(Body::from("{}"))
            .expect("valid request")
    };
    assert_eq!(
        router
            .clone()
            .oneshot(request())
            .await
            .expect("first issuance should respond")
            .status(),
        StatusCode::CREATED
    );
    let limited = router
        .oneshot(request())
        .await
        .expect("limited issuance should respond");
    assert_eq!(limited.status(), StatusCode::TOO_MANY_REQUESTS);
    assert_eq!(
        response_json(limited).await["error"]["code"],
        "rate_limited"
    );
}

#[tokio::test]
async fn readiness_reports_database_failure_without_details() {
    let postgres = TestPostgres::start().await;
    let database = database(&postgres).await;
    let config = test_config(&postgres, &[]);
    let router = router(&config, database.clone()).expect("router should build");
    database.close().await.expect("test pool should close");

    let response = router
        .oneshot(
            Request::get("/readyz")
                .body(Body::empty())
                .expect("valid request"),
        )
        .await
        .expect("readiness should respond");
    assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
    let body = response_json(response).await;
    assert_eq!(body["error"]["code"], "temporarily_unavailable");
    assert!(!body.to_string().contains("postgres"));
}

#[tokio::test]
async fn malformed_and_oversized_requests_are_rejected_before_placeholder_work() {
    let postgres = TestPostgres::start().await;
    let malformed = test_router(&postgres, &[])
        .await
        .oneshot(
            Request::post("/v1/token")
                .header("content-type", "application/json")
                .body(Body::from("not-json"))
                .expect("valid request"),
        )
        .await
        .expect("router should respond");
    assert_eq!(malformed.status(), StatusCode::BAD_REQUEST);
    assert_eq!(
        response_json(malformed).await["error"]["code"],
        "malformed_request"
    );

    let oversized_body = format!("\"{}\"", "x".repeat(2_048));
    let oversized = test_router(&postgres, &["--max-request-body-bytes", "1024"])
        .await
        .oneshot(
            Request::post("/v1/token")
                .header("content-type", "application/json")
                .body(Body::from(oversized_body))
                .expect("valid request"),
        )
        .await
        .expect("router should respond");
    assert_eq!(oversized.status(), StatusCode::PAYLOAD_TOO_LARGE);
    assert_eq!(
        response_json(oversized).await["error"]["code"],
        "request_too_large"
    );
}

#[tokio::test]
async fn unsupported_methods_do_not_invoke_post_handlers() {
    let postgres = TestPostgres::start().await;
    let response = test_router(&postgres, &[])
        .await
        .oneshot(
            Request::get("/v1/token")
                .body(Body::empty())
                .expect("valid request"),
        )
        .await
        .expect("router should respond");
    assert_eq!(response.status(), StatusCode::METHOD_NOT_ALLOWED);
}
