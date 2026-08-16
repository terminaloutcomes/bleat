use axum::{
    body::Body,
    http::{Request, StatusCode},
};
use bleat_api::{
    config::{Arguments, Config, TelemetryExportConfig},
    database::connect_and_migrate,
    installation::{InstallationEnvironment, InstallationRepository, NewInstallation},
    router,
};
use clap::Parser;
use http_body_util::BodyExt;
use sea_orm::DatabaseConnection;
use serde_json::Value;
use tower::ServiceExt;
use uuid::Uuid;

fn test_config(extra_arguments: &[&str]) -> Config {
    let database_url = std::env::var("BLEAT_API_TEST_DATABASE_URL")
        .expect("BLEAT_API_TEST_DATABASE_URL must name the disposable PostgreSQL database");
    let mut arguments = vec!["bleat-api", "--database-url", database_url.as_str()];
    arguments.extend(extra_arguments.iter().copied());
    Config::from_arguments(
        Arguments::try_parse_from(arguments).expect("test arguments should parse"),
        TelemetryExportConfig::default(),
    )
    .expect("test configuration should validate")
}

fn database_config() -> Config {
    test_config(&[])
}

async fn database() -> DatabaseConnection {
    connect_and_migrate(&database_config().database)
        .await
        .expect("test database should connect")
}

async fn test_router(extra_arguments: &[&str]) -> axum::Router {
    let config = test_config(extra_arguments);
    router(&config, database().await)
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

#[tokio::test]
async fn health_and_readiness_are_typed_and_receive_request_ids() {
    for (path, expected_status) in [("/healthz", "ok"), ("/readyz", "ready")] {
        let response = test_router(&[])
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
async fn unimplemented_verification_routes_return_bounded_typed_errors() {
    for path in ["/v1/attestation/enroll", "/v1/token"] {
        let response = test_router(&[])
            .await
            .oneshot(
                Request::post(path)
                    .header("content-type", "application/json")
                    .body(Body::from("{}"))
                    .expect("valid request"),
            )
            .await
            .expect("router should respond");

        assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
        let header_request_id = response
            .headers()
            .get("x-request-id")
            .expect("request ID header should be present")
            .to_str()
            .expect("request ID should be text")
            .to_owned();
        let body = response_json(response).await;
        assert_eq!(body["error"]["code"], "temporarily_unavailable");
        assert_eq!(body["request_id"], header_request_id);
        assert!(body.to_string().len() < 300);
    }
}

#[tokio::test]
async fn challenge_routes_issue_typed_opaque_challenges() {
    let attestation = test_router(&[])
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

    let database = database().await;
    let installations = InstallationRepository::new(database.clone());
    let installation = installations
        .create_verified(NewInstallation {
            app_attest_key_id: format!("http-key-{}", Uuid::new_v4()),
            public_key: vec![4; 65],
            environment: InstallationEnvironment::Development,
        })
        .await
        .expect("installation should persist");
    let config = test_config(&[]);
    let token = router(&config, database)
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
    let unknown = test_router(&[])
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

    let router = test_router(&["--challenge-issuance-per-minute", "1"]).await;
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
    let database = database().await;
    let config = test_config(&[]);
    let router = router(&config, database.clone());
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
    let malformed = test_router(&[])
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
    let oversized = test_router(&["--max-request-body-bytes", "1024"])
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
    let response = test_router(&[])
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
