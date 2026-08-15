use axum::{
    body::Body,
    http::{Request, StatusCode},
};
use bleat_api::{
    config::{Arguments, Config, TelemetryExportConfig},
    router,
};
use clap::Parser;
use http_body_util::BodyExt;
use serde_json::Value;
use tower::ServiceExt;
use uuid::Uuid;

fn test_config(extra_arguments: &[&str]) -> Config {
    let arguments = std::iter::once("bleat-api")
        .chain(extra_arguments.iter().copied())
        .collect::<Vec<_>>();
    Config::from_arguments(
        Arguments::try_parse_from(arguments).expect("test arguments should parse"),
        TelemetryExportConfig::default(),
    )
    .expect("test configuration should validate")
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
        let response = router(&test_config(&[]))
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
async fn versioned_routes_return_bounded_typed_unavailable_errors() {
    for path in [
        "/v1/attestation/challenge",
        "/v1/attestation/enroll",
        "/v1/token/challenge",
        "/v1/token",
    ] {
        let response = router(&test_config(&[]))
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
async fn malformed_and_oversized_requests_are_rejected_before_placeholder_work() {
    let malformed = router(&test_config(&[]))
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
    let oversized = router(&test_config(&["--max-request-body-bytes", "1024"]))
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
    let response = router(&test_config(&[]))
        .oneshot(
            Request::get("/v1/token")
                .body(Body::empty())
                .expect("valid request"),
        )
        .await
        .expect("router should respond");
    assert_eq!(response.status(), StatusCode::METHOD_NOT_ALLOWED);
}
