use std::{net::TcpListener, process::Command};

use uuid::Uuid;

mod support;

use support::TestPostgres;

#[tokio::test]
async fn signing_configuration_failure_happens_before_listener_bind() {
    let postgres = TestPostgres::start().await;
    let listener = TcpListener::bind("127.0.0.1:0").expect("test port should be allocated");
    let bind_address = listener
        .local_addr()
        .expect("test listener address should resolve");
    drop(listener);

    let missing_signing_key =
        std::env::temp_dir().join(format!("bleat-missing-signing-key-{}.der", Uuid::new_v4()));
    let bind_address = bind_address.to_string();
    let missing_signing_key = missing_signing_key.to_string_lossy().into_owned();
    let mut command = Command::new(env!("CARGO_BIN_EXE_bleat-api"));
    command.env_clear().args([
        "--database-url",
        postgres.database_url(),
        "--bind-address",
        &bind_address,
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
        &missing_signing_key,
    ]);
    let output = command.output().expect("bleat-api process should run");

    assert!(!output.status.success());
    let stderr = String::from_utf8(output.stderr).expect("process stderr should be UTF-8");
    let safe_stderr = stderr
        .replace(postgres.database_url(), "[DATABASE_URL]")
        .replace("development-only", "[DATABASE_PASSWORD]")
        .replace(&missing_signing_key, "[SIGNING_KEY_PATH]");
    assert!(
        stderr.contains("TokenIssuer(SigningKeyConfiguration)"),
        "unexpected privacy-safe process error: {safe_stderr}"
    );
    assert!(!stderr.contains(postgres.database_url()));
    assert!(!stderr.contains("development-only"));
    assert!(!stderr.contains(&missing_signing_key));

    let rebound = TcpListener::bind(&bind_address)
        .expect("startup failure should happen before the listener is bound");
    drop(rebound);
}
