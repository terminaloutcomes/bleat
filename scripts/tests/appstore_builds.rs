use scripts::appstore_builds::{BuildStatusArgs, BuildStatusError, ProcessingState, fetch_status};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use url::Url;

fn arguments() -> BuildStatusArgs {
    BuildStatusArgs {
        app_id: "test-app".into(),
        version: "2026.10.08".into(),
        build: "20261008.0909.41".into(),
    }
}

fn page(state: &str, version: &str) -> Value {
    json!({
        "data": [{
            "type": "builds", "id": "build-id",
            "attributes": {"version": "20261008.0909.41", "processingState": state},
            "relationships": {"preReleaseVersion": {"data": {
                "type": "preReleaseVersions", "id": "release-id"
            }}}
        }],
        "included": [{
            "type": "preReleaseVersions", "id": "release-id",
            "attributes": {"version": version, "platform": "IOS"}
        }],
        "links": {"next": null}
    })
}

async fn server(body: Value, status: u16) -> (Url, tokio::task::JoinHandle<String>) {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("fixture listener binds");
    let address = listener.local_addr().expect("listener address exists");
    let handle = tokio::spawn(async move {
        let (mut stream, _) = listener.accept().await.expect("request arrives");
        let mut request = Vec::new();
        let mut buffer = [0_u8; 1024];
        // CRLF framing is exact HTTP protocol syntax, not a structured-data comparison.
        while !request.windows(4).any(|window| window == b"\r\n\r\n") {
            let count = stream.read(&mut buffer).await.expect("read request");
            assert!(count > 0 && request.len() < 16_384);
            request.extend_from_slice(&buffer[..count]);
        }
        let body = body.to_string();
        let response = format!(
            "HTTP/1.1 {status} Fixture\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len()
        );
        stream
            .write_all(response.as_bytes())
            .await
            .expect("write response");
        String::from_utf8(request).expect("HTTP fixture request is UTF-8")
    });
    (
        Url::parse(&format!("http://{address}/v1/")).expect("fixture URL"),
        handle,
    )
}

#[tokio::test]
async fn sends_exact_build_filters_and_reports_all_processing_states() {
    for (remote, expected) in [
        ("PROCESSING", ProcessingState::Processing),
        ("VALID", ProcessingState::Valid),
        ("FAILED", ProcessingState::Failed),
        ("INVALID", ProcessingState::Invalid),
    ] {
        let (base, handle) = server(page(remote, "2026.10.08"), 200).await;
        let status = fetch_status(&arguments(), "fixture-token", &base)
            .await
            .expect("status");
        assert_eq!(status.processing_state, expected);
        assert_eq!(status.version, arguments().version);
        assert_eq!(status.build, arguments().build);
        let request = handle.await.expect("fixture completes");
        let target = request
            .lines()
            .next()
            .expect("request line")
            .split_whitespace()
            .nth(1)
            .expect("request target");
        let requested = base.join(target).expect("request URL");
        assert_eq!(requested.path(), "/v1/builds");
        let filters: BTreeMap<_, _> = requested.query_pairs().into_owned().collect();
        assert_eq!(
            filters,
            BTreeMap::from([
                ("filter[app]".into(), "test-app".into()),
                ("filter[version]".into(), "20261008.0909.41".into()),
                (
                    "filter[preReleaseVersion.version]".into(),
                    "2026.10.08".into()
                ),
                ("filter[preReleaseVersion.platform]".into(), "IOS".into()),
                ("include".into(), "preReleaseVersion".into()),
            ])
        );
        // Authorization header spelling/value is an intentional HTTP wire contract.
        assert!(
            request
                .lines()
                .any(|line| line.eq_ignore_ascii_case("authorization: Bearer fixture-token"))
        );
    }
}

#[tokio::test]
async fn absent_build_and_another_release_are_not_found() {
    for body in [json!({"data": []}), page("VALID", "2026.09.23")] {
        let (base, handle) = server(body, 200).await;
        let status = fetch_status(&arguments(), "fixture-token", &base)
            .await
            .expect("status");
        assert_eq!(status.processing_state, ProcessingState::NotFound);
        handle.await.expect("fixture completes");
    }
}

#[tokio::test]
async fn missing_metadata_remains_a_typed_failure() {
    let mut missing_version = page("VALID", "2026.10.08");
    missing_version["included"] = json!([]);
    let (base, handle) = server(missing_version, 200).await;
    assert!(matches!(
        fetch_status(&arguments(), "fixture-token", &base).await,
        Err(BuildStatusError::MissingVersion)
    ));
    handle.await.expect("fixture completes");

    let mut missing_state = page("VALID", "2026.10.08");
    missing_state["data"][0]["attributes"]
        .as_object_mut()
        .expect("attributes")
        .remove("processingState");
    let (base, handle) = server(missing_state, 200).await;
    assert!(matches!(
        fetch_status(&arguments(), "fixture-token", &base).await,
        Err(BuildStatusError::MissingState)
    ));
    handle.await.expect("fixture completes");
}

#[tokio::test]
async fn rejects_ambiguous_and_incomplete_results() {
    let mut duplicate = page("VALID", "2026.10.08");
    let extra = duplicate["data"][0].clone();
    duplicate["data"]
        .as_array_mut()
        .expect("build array")
        .push(extra);
    let (base, handle) = server(duplicate, 200).await;
    assert!(matches!(
        fetch_status(&arguments(), "fixture-token", &base).await,
        Err(BuildStatusError::Ambiguous)
    ));
    handle.await.expect("fixture completes");

    let mut incomplete = page("VALID", "2026.10.08");
    incomplete["links"]["next"] = json!("https://example.invalid/next");
    let (base, handle) = server(incomplete, 200).await;
    assert!(matches!(
        fetch_status(&arguments(), "fixture-token", &base).await,
        Err(BuildStatusError::Incomplete)
    ));
    handle.await.expect("fixture completes");
}

#[tokio::test]
async fn rejected_and_malformed_responses_do_not_become_not_found() {
    let (base, handle) = server(json!({"errors": []}), 401).await;
    assert!(matches!(
        fetch_status(&arguments(), "fixture-token", &base).await,
        Err(BuildStatusError::Http(401))
    ));
    handle.await.expect("fixture completes");
    let (base, handle) = server(page("UNKNOWN", "2026.10.08"), 200).await;
    assert!(matches!(
        fetch_status(&arguments(), "fixture-token", &base).await,
        Err(BuildStatusError::Decode(_))
    ));
    handle.await.expect("fixture completes");
}

#[tokio::test]
async fn empty_identifier_is_rejected_before_requesting() {
    let mut args = arguments();
    args.app_id.clear();
    let base = Url::parse("http://127.0.0.1:1/v1/").expect("test URL");
    assert!(matches!(
        fetch_status(&args, "fixture-token", &base).await,
        Err(BuildStatusError::EmptyIdentifier)
    ));
}

#[tokio::test]
async fn connection_failure_retains_its_cause_without_exposing_request_details() {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("reserve unused address");
    let address = listener.local_addr().expect("listener address");
    drop(listener);
    let base = Url::parse(&format!("http://{address}/v1/")).expect("fixture URL");
    let error = fetch_status(&arguments(), "private-fixture-token", &base)
        .await
        .expect_err("connection fails");
    assert!(matches!(error, BuildStatusError::Connection(_)));
    assert_eq!(error.code(), "connection_failed");
    assert_eq!(error.to_string(), "could not connect to Apple");
    assert!(std::error::Error::source(&error).is_some());
}
