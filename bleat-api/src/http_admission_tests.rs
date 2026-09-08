use super::*;
use crate::config::ForwardingHeader;
use governor::{Quota, clock::DefaultClock};
use std::{num::NonZeroU32, time::Duration};
use tower::ServiceExt;

fn admission_router(
    trusted: TrustedProxyConfig,
    maximum: usize,
) -> (Router, Arc<tokio::sync::Semaphore>) {
    let limiter = Arc::new(IssuanceLimiter::new(
        Quota::per_minute(NonZeroU32::new(1).expect("rate")),
        maximum,
        DefaultClock::default(),
    ));
    let permits = Arc::new(tokio::sync::Semaphore::new(1));
    let challenges = Router::new()
        .route(
            "/v1/attestation/challenge",
            post(|| async { StatusCode::CREATED }),
        )
        .route(
            "/v1/token/challenge",
            post(|| async { StatusCode::UNAUTHORIZED }),
        )
        .route_layer(middleware::from_fn_with_state(
            ChallengeAdmission {
                limiter,
                rate: 1,
                burst: 1,
            },
            admit_challenge,
        ));
    let router = Router::new()
        .route("/healthz", get(health))
        .route("/readyz", get(|| async { StatusCode::OK }))
        .merge(apply_limits(
            challenges,
            RequestLimits {
                timeout: Duration::from_secs(1),
                permits: Arc::clone(&permits),
            },
            1024,
        ))
        .layer(middleware::from_fn_with_state(trusted, instrument_request));
    (router, permits)
}

fn no_forwarding() -> TrustedProxyConfig {
    TrustedProxyConfig::new(Vec::new(), Vec::new(), false).expect("proxy policy")
}

fn request(route: &str, peer: Option<&str>, headers: &[(&str, &str)]) -> Request<Body> {
    let mut request = Request::post(route);
    if let Some(peer) = peer {
        request = request.extension(ConnectInfo(peer.parse::<SocketAddr>().expect("peer")));
    }
    for (key, value) in headers {
        request = request.header(*key, *value);
    }
    request.body(Body::empty()).expect("request")
}

async fn error_body(response: Response, code: &str) {
    let request_id = response.headers()["x-request-id"]
        .to_str()
        .expect("ID")
        .to_owned();
    let bytes = http_body_util::BodyExt::collect(response.into_body())
        .await
        .expect("body")
        .to_bytes();
    let body: serde_json::Value = serde_json::from_slice(&bytes).expect("JSON");
    assert_eq!(body["error"]["code"], code);
    assert_eq!(body["request_id"], request_id);
    assert!(
        body["error"]["message"]
            .as_str()
            .expect("message")
            .parse::<std::net::IpAddr>()
            .is_err()
    );
}

#[tokio::test]
async fn both_routes_share_quota_failed_handlers_are_not_refunded_and_clients_are_independent() {
    let (router, _) = admission_router(no_forwarding(), 8);
    let first = router
        .clone()
        .oneshot(request("/v1/token/challenge", Some("192.0.2.1:1234"), &[]))
        .await
        .expect("response");
    assert_eq!(first.status(), StatusCode::UNAUTHORIZED);
    let second = router
        .clone()
        .oneshot(request(
            "/v1/attestation/challenge",
            Some("[::ffff:192.0.2.1]:9999"),
            &[],
        ))
        .await
        .expect("response");
    assert_eq!(second.status(), StatusCode::TOO_MANY_REQUESTS);
    assert_eq!(second.headers()["retry-after"], "60");
    error_body(second, "rate_limited").await;
    let other = router
        .oneshot(request(
            "/v1/attestation/challenge",
            Some("192.0.2.2:1234"),
            &[],
        ))
        .await
        .expect("response");
    assert_eq!(other.status(), StatusCode::CREATED);
}

#[tokio::test]
async fn global_saturation_does_not_consume_quota_and_health_and_readiness_remain_available() {
    let (router, permits) = admission_router(no_forwarding(), 1);
    let held = permits.acquire().await.expect("permit");
    let response = router
        .clone()
        .oneshot(request(
            "/v1/attestation/challenge",
            Some("192.0.2.1:1234"),
            &[],
        ))
        .await
        .expect("response");
    assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
    error_body(response, "global_capacity").await;
    for route in ["/healthz", "/readyz"] {
        assert_eq!(
            router
                .clone()
                .oneshot(Request::get(route).body(Body::empty()).expect("request"))
                .await
                .expect("response")
                .status(),
            StatusCode::OK
        );
    }
    drop(held);
    assert_eq!(
        router
            .oneshot(request(
                "/v1/attestation/challenge",
                Some("192.0.2.1:1234"),
                &[]
            ))
            .await
            .expect("response")
            .status(),
        StatusCode::CREATED
    );
}

#[tokio::test]
async fn missing_connection_identity_skips_client_admission_even_with_forwarding_headers() {
    let (router, _) = admission_router(no_forwarding(), 1);
    for _ in 0..3 {
        assert_eq!(
            router
                .clone()
                .oneshot(request(
                    "/v1/attestation/challenge",
                    None,
                    &[("x-forwarded-for", "192.0.2.1")]
                ))
                .await
                .expect("response")
                .status(),
            StatusCode::CREATED
        );
    }
}

#[tokio::test]
async fn map_capacity_is_distinct_and_existing_clients_keep_their_quota() {
    let (router, _) = admission_router(no_forwarding(), 1);
    assert_eq!(
        router
            .clone()
            .oneshot(request(
                "/v1/attestation/challenge",
                Some("192.0.2.1:1"),
                &[]
            ))
            .await
            .expect("response")
            .status(),
        StatusCode::CREATED
    );
    let full = router
        .clone()
        .oneshot(request(
            "/v1/attestation/challenge",
            Some("192.0.2.2:1"),
            &[],
        ))
        .await
        .expect("response");
    assert_eq!(full.status(), StatusCode::SERVICE_UNAVAILABLE);
    assert!(!full.headers().contains_key("retry-after"));
    error_body(full, "limiter_capacity").await;
    assert_eq!(
        router
            .oneshot(request(
                "/v1/attestation/challenge",
                Some("192.0.2.1:1"),
                &[]
            ))
            .await
            .expect("response")
            .status(),
        StatusCode::TOO_MANY_REQUESTS
    );
}

#[tokio::test]
async fn forwarding_decisions_are_reused_for_admission_without_reparsing() {
    let overlong = vec!["192.0.2.99"; 33].join(", ");
    let cases = vec![
        (
            "10.0.0.1:1",
            vec![("x-forwarded-for", "192.0.2.1")],
            "192.0.2.1:2",
        ),
        (
            "192.0.2.1:1",
            vec![("x-forwarded-for", "198.51.100.1")],
            "192.0.2.1:2",
        ),
        ("10.0.0.1:1", vec![], "10.0.0.1:2"),
        (
            "10.0.0.1:1",
            vec![("x-forwarded-for", "garbage")],
            "10.0.0.1:2",
        ),
        (
            "10.0.0.1:1",
            vec![
                ("x-forwarded-for", "192.0.2.1"),
                ("forwarded", "for=192.0.2.2"),
            ],
            "10.0.0.1:2",
        ),
        (
            "10.0.0.1:1",
            vec![("x-forwarded-for", overlong.as_str())],
            "10.0.0.1:2",
        ),
        ("[2001:db8::1]:1", vec![], "[2001:db8::abcd]:2"),
    ];
    for (peer, headers, same_client) in cases {
        let trusted = TrustedProxyConfig::new(
            vec!["10.0.0.0/8".to_owned()],
            vec![ForwardingHeader::XForwardedFor, ForwardingHeader::Forwarded],
            false,
        )
        .expect("policy");
        let (router, _) = admission_router(trusted, 8);
        assert_eq!(
            router
                .clone()
                .oneshot(request("/v1/attestation/challenge", Some(peer), &headers))
                .await
                .expect("response")
                .status(),
            StatusCode::CREATED
        );
        assert_eq!(
            router
                .oneshot(request("/v1/token/challenge", Some(same_client), &[]))
                .await
                .expect("response")
                .status(),
            StatusCode::TOO_MANY_REQUESTS,
            "peer {peer}"
        );
    }
}

#[derive(Clone, Default)]
struct LogBuffer(Arc<std::sync::Mutex<Vec<u8>>>);

impl std::io::Write for LogBuffer {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        self.0
            .lock()
            .expect("test log buffer")
            .extend_from_slice(bytes);
        Ok(bytes.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

#[tokio::test]
async fn every_rejection_logs_actor_or_capacity_classification_and_correlation() {
    use tracing::instrument::WithSubscriber;
    let _guard = crate::TRACING_TEST_LOCK.lock().await;
    let buffer = LogBuffer::default();
    let writer = buffer.clone();
    let subscriber = tracing_subscriber::fmt()
        .json()
        .with_writer(move || writer.clone())
        .finish();
    let ids = async {
        let (router, permits) = admission_router(no_forwarding(), 1);
        let mut ids = Vec::new();
        for peer in [
            "[2001:db8:1:2::1234]:1",
            "[2001:db8:1:2::abcd]:2",
            "[2001:db8:1:2::abcd]:3",
            "192.0.2.1:4",
        ] {
            let response = router
                .clone()
                .oneshot(request("/v1/attestation/challenge", Some(peer), &[]))
                .await
                .expect("response");
            if response.status() != StatusCode::CREATED {
                ids.push(
                    response.headers()["x-request-id"]
                        .to_str()
                        .expect("ID")
                        .to_owned(),
                );
            }
        }
        let _held = permits.acquire().await.expect("permit");
        let response = router
            .oneshot(request(
                "/v1/attestation/challenge",
                Some("192.0.2.1:4"),
                &[],
            ))
            .await
            .expect("response");
        ids.push(
            response.headers()["x-request-id"]
                .to_str()
                .expect("ID")
                .to_owned(),
        );
        ids
    }
    .with_subscriber(subscriber)
    .await;
    let bytes = buffer.0.lock().expect("logs").clone();
    let logs = String::from_utf8(bytes).expect("UTF8 logs");
    let events: Vec<serde_json::Value> = logs
        .lines()
        .map(|line| serde_json::from_str::<serde_json::Value>(line).expect("JSON log"))
        .filter(|event| event["fields"]["rejection.count"] == 1)
        .collect();
    assert_eq!(events.len(), 4);
    for (event, id) in events.iter().zip(ids) {
        assert_eq!(event["fields"]["request.id"], id);
        assert!(event["timestamp"].is_string());
    }
    for event in &events[..2] {
        let fields = &event["fields"];
        assert_eq!(fields["limit.kind"], "client_quota");
        assert_eq!(fields["failure.code"], "rate_limited");
        assert_eq!(fields["failure.stage"], "challenge_admission");
        assert_eq!(fields["client.address"], "2001:db8:1:2::/64");
        assert_eq!(fields["configured.rate"], 1);
        assert_eq!(fields["configured.burst"], 1);
        assert_eq!(fields["http.route"], "/v1/attestation/challenge");
        assert_eq!(fields["retry_after_seconds"], 60);
    }
    assert_eq!(events[2]["fields"]["limit.kind"], "client_map_capacity");
    assert_eq!(events[2]["fields"]["failure.code"], "limiter_capacity");
    assert_eq!(events[3]["fields"]["limit.kind"], "global_concurrency");
    assert_eq!(events[3]["fields"]["failure.code"], "global_capacity");
    for event in &events[2..] {
        assert!(event["fields"].get("client.address").is_none());
    }
}
