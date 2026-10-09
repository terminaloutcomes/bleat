use scripts::appstore_builds::{BuildStatusArgs, ProcessingState};
use scripts::appstore_testflight::{Api, BetaState, Cause, ReleaseArgs};
use serde_json::{Value, json};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use url::Url;

struct Step {
    method: &'static str,
    path: &'static str,
    body: Option<Value>,
    response: Value,
    status: u16,
}
fn step(method: &'static str, path: &'static str, body: Option<Value>, response: Value) -> Step {
    Step {
        method,
        path,
        body,
        response,
        status: 200,
    }
}
async fn server(steps: Vec<Step>) -> (Api, tokio::task::JoinHandle<()>) {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind fixture");
    let address = listener.local_addr().expect("fixture address");
    let handle = tokio::spawn(async move {
        for step in steps {
            let (mut stream, _) = listener.accept().await.expect("request");
            let mut bytes = vec![];
            let mut buffer = [0_u8; 4096];
            let header_end = loop {
                let count = stream.read(&mut buffer).await.expect("read HTTP");
                assert!(count > 0 && bytes.len() < 65536);
                bytes.extend_from_slice(&buffer[..count]);
                // Exact CRLF bytes implement HTTP framing, not JSON equality.
                if let Some(index) = bytes.windows(4).position(|part| part == b"\r\n\r\n") {
                    break index + 4;
                }
            };
            let header = String::from_utf8(bytes[..header_end].to_vec()).expect("HTTP header");
            let length = header
                .lines()
                .filter_map(|line| line.split_once(':'))
                .find(|(name, _)| name.eq_ignore_ascii_case("content-length"))
                .map(|(_, value)| value.trim().parse::<usize>().expect("content length"))
                .unwrap_or(0);
            while bytes.len() < header_end + length {
                let count = stream.read(&mut buffer).await.expect("read body");
                assert!(count > 0);
                bytes.extend_from_slice(&buffer[..count]);
            }
            let mut request_line = header
                .lines()
                .next()
                .expect("request line")
                .split_whitespace();
            assert_eq!(request_line.next(), Some(step.method));
            let target = Url::parse(&format!(
                "http://fixture{}",
                request_line.next().expect("target")
            ))
            .expect("target URL");
            assert_eq!(target.path(), step.path);
            if step.path == "/v1/betaGroups" {
                let filters: std::collections::BTreeMap<_, _> =
                    target.query_pairs().into_owned().collect();
                assert_eq!(
                    filters,
                    std::collections::BTreeMap::from([
                        ("filter[builds]".into(), "build".into()),
                        ("limit".into(), "200".into()),
                    ])
                );
            }
            if let Some(expected) = step.body {
                assert_eq!(
                    serde_json::from_slice::<Value>(&bytes[header_end..header_end + length])
                        .expect("JSON body"),
                    expected
                );
            } else {
                assert_eq!(length, 0);
            }
            let body = step.response.to_string();
            stream.write_all(format!("HTTP/1.1 {} Fixture\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", step.status, body.len()).as_bytes()).await.expect("response");
        }
    });
    (
        Api::new(
            "private-fixture-token".into(),
            Url::parse(&format!("http://{address}/v1/")).expect("base URL"),
        )
        .expect("API"),
        handle,
    )
}
fn args() -> ReleaseArgs {
    ReleaseArgs {
        build: BuildStatusArgs {
            app_id: "app".into(),
            version: "2026.10.09".into(),
            build: "20261009.1100.00".into(),
        },
        group_id: vec!["external".into()],
        locale: "en-AU".into(),
        whats_new: "Fix multiline synopses.".into(),
    }
}
fn build(state: &str) -> Value {
    json!({"data":[{"type":"builds","id":"build","attributes":{"version":"20261009.1100.0","processingState":state},"relationships":{"preReleaseVersion":{"data":{"type":"preReleaseVersions","id":"version"}}}}],"included":[{"type":"preReleaseVersions","id":"version","attributes":{"version":"2026.10.09","platform":"IOS"}}]})
}
fn groups(assigned: bool) -> Value {
    if assigned {
        json!({"data":[{"id":"external","attributes":{"name":"Existing external testers","isInternalGroup":false}}]})
    } else {
        json!({"data":[]})
    }
}
fn status(state: &str, assigned: bool) -> Vec<Step> {
    vec![
        step("GET", "/v1/builds", None, build("VALID")),
        step(
            "GET",
            "/v1/builds/build/buildBetaDetail",
            None,
            json!({"data":{"id":"detail","attributes":{"internalBuildState":"IN_BETA_TESTING","externalBuildState":state}}}),
        ),
        step("GET", "/v1/betaGroups", None, groups(assigned)),
    ]
}

#[tokio::test]
async fn releases_exact_build_with_notes_review_and_verified_existing_group() {
    let mut steps = status("READY_FOR_BETA_SUBMISSION", false);
    steps.extend([
        step("GET", "/v1/apps/app/betaGroups", None, groups(true)),
        step("GET", "/v1/betaBuildLocalizations", None, json!({"data":[]})),
        step("POST", "/v1/betaBuildLocalizations", Some(json!({"data":{"type":"betaBuildLocalizations","attributes":{"locale":"en-AU","whatsNew":"Fix multiline synopses."},"relationships":{"build":{"data":{"type":"builds","id":"build"}}}}})), json!({})),
        step("POST", "/v1/betaAppReviewSubmissions", Some(json!({"data":{"type":"betaAppReviewSubmissions","relationships":{"build":{"data":{"type":"builds","id":"build"}}}}})), json!({})),
        step("POST", "/v1/betaGroups/external/relationships/builds", Some(json!({"data":[{"type":"builds","id":"build"}]})), json!({})),
    ]);
    steps.extend(status("WAITING_FOR_BETA_REVIEW", true));
    let (api, handle) = server(steps).await;
    let result = api.release(&args()).await.expect("release");
    assert_eq!(result.processing_state, ProcessingState::Valid);
    assert_eq!(
        result.beta.expect("beta").external_build_state,
        BetaState::WaitingForBetaReview
    );
    assert_eq!(result.assigned_groups[0].id, "external");
    handle.await.expect("all request boundaries checked");
}

#[tokio::test]
async fn repeated_release_does_not_resubmit_review_or_duplicate_membership() {
    let mut steps = status("WAITING_FOR_BETA_REVIEW", true);
    steps.extend([
        step("GET", "/v1/apps/app/betaGroups", None, groups(true)),
        step("GET", "/v1/betaBuildLocalizations", None, json!({"data":[{"id":"notes","attributes":{"locale":"en-AU"}}]})),
        step("PATCH", "/v1/betaBuildLocalizations/notes", Some(json!({"data":{"type":"betaBuildLocalizations","id":"notes","attributes":{"whatsNew":"Fix multiline synopses."}}})), json!({})),
    ]);
    steps.extend(status("WAITING_FOR_BETA_REVIEW", true));
    let (api, handle) = server(steps).await;
    api.release(&args()).await.expect("reconcile");
    handle.await.expect("no extra mutations");
}

#[tokio::test]
async fn blocked_builds_and_export_compliance_make_no_mutations() {
    let (api, handle) = server(vec![step("GET", "/v1/builds", None, build("PROCESSING"))]).await;
    assert!(matches!(
        api.release(&args()).await.expect_err("processing").cause,
        Cause::BuildNotReady(ProcessingState::Processing)
    ));
    handle.await.expect("read only");
    for state in ["MISSING_EXPORT_COMPLIANCE", "BETA_REJECTED", "EXPIRED"] {
        let mut steps = status(state, false);
        steps.push(step("GET", "/v1/apps/app/betaGroups", None, groups(true)));
        let (api, handle) = server(steps).await;
        assert!(matches!(
            api.release(&args()).await.expect_err("blocked").cause,
            Cause::ExternalNotReady(_)
        ));
        handle.await.expect("read only");
    }
}

#[tokio::test]
async fn rejects_groups_from_another_app_and_duplicate_group_ids() {
    let mut steps = status("READY_FOR_BETA_SUBMISSION", false);
    steps.push(step("GET", "/v1/apps/app/betaGroups", None, groups(false)));
    let (api, handle) = server(steps).await;
    assert!(matches!(
        api.release(&args()).await.expect_err("unknown group").cause,
        Cause::UnknownGroup
    ));
    handle.await.expect("read only");
    let mut duplicate = args();
    duplicate.group_id.push("external".into());
    assert!(matches!(
        api.release(&duplicate).await.expect_err("duplicate").cause,
        Cause::DuplicateGroup
    ));
}

#[tokio::test]
async fn incomplete_groups_and_http_failure_preserve_stage_without_secrets() {
    let (api, handle) = server(vec![step(
        "GET",
        "/v1/apps/app/betaGroups",
        None,
        json!({"data":[],"links":{"next":"https://fixture.invalid/next"}}),
    )])
    .await;
    let error = api.app_groups("app").await.expect_err("incomplete");
    assert_eq!(
        error.diagnostic(),
        json!({"stage":"app_groups","code":"incomplete_response"})
    );
    handle.await.expect("complete");
    let (api, handle) = server(vec![Step {
        status: 403,
        ..step(
            "GET",
            "/v1/apps/app/betaGroups",
            None,
            json!({"errors":[{"code":"FORBIDDEN","detail":"private-fixture-token"}]}),
        )
    }])
    .await;
    let error = api.app_groups("app").await.expect_err("forbidden");
    assert_eq!(
        error.diagnostic(),
        json!({"stage":"app_groups","code":"http_403","apple_codes":["FORBIDDEN"]})
    );
    assert!(!error.to_string().contains("private-fixture-token"));
    handle.await.expect("complete");
}

#[tokio::test]
async fn missing_beta_state_has_a_specific_diagnostic() {
    let (api, handle) = server(vec![
        step("GET", "/v1/builds", None, build("VALID")),
        step(
            "GET",
            "/v1/builds/build/buildBetaDetail",
            None,
            json!({"data":{"id":"detail","attributes":{"internalBuildState":"IN_BETA_TESTING"}}}),
        ),
    ])
    .await;
    let error = api.status(&args().build).await.expect_err("missing state");
    assert_eq!(
        error.diagnostic(),
        json!({"stage":"beta_status","code":"missing_external_beta_state"})
    );
    handle.await.expect("read completed");
}

#[tokio::test]
async fn successful_assignment_http_status_requires_membership_verification() {
    let mut steps = status("WAITING_FOR_BETA_REVIEW", false);
    steps.extend([
        step("GET", "/v1/apps/app/betaGroups", None, groups(true)),
        step("GET", "/v1/betaBuildLocalizations", None, json!({"data":[]})),
        step("POST", "/v1/betaBuildLocalizations", Some(json!({"data":{"type":"betaBuildLocalizations","attributes":{"locale":"en-AU","whatsNew":"Fix multiline synopses."},"relationships":{"build":{"data":{"type":"builds","id":"build"}}}}})), json!({})),
        step("POST", "/v1/betaGroups/external/relationships/builds", Some(json!({"data":[{"type":"builds","id":"build"}]})), json!({})),
    ]);
    steps.extend(status("WAITING_FOR_BETA_REVIEW", false));
    let (api, handle) = server(steps).await;
    let error = api
        .release(&args())
        .await
        .expect_err("assignment unconfirmed");
    assert!(matches!(error.cause, Cause::AssignmentUnconfirmed));
    handle.await.expect("no mutation retry");
}
