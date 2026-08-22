use std::{
    net::TcpListener,
    process::{Command, Output, Stdio},
    time::Duration,
};

use uuid::Uuid;

mod support;

use support::TestPostgres;

const PROCESS_TIMEOUT: Duration = Duration::from_secs(10);

async fn output_with_timeout(command: &mut Command) -> Output {
    let mut child = command
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("bleat-api process should start");
    let deadline = tokio::time::Instant::now() + PROCESS_TIMEOUT;

    loop {
        match child
            .try_wait()
            .expect("bleat-api process status should be readable")
        {
            Some(_) => {
                return child
                    .wait_with_output()
                    .expect("bleat-api process output should be readable");
            }
            None if tokio::time::Instant::now() >= deadline => {
                child
                    .kill()
                    .expect("timed-out bleat-api process should be terminated");
                child
                    .wait()
                    .expect("timed-out bleat-api process should be reaped");
                panic!("bleat-api process did not exit within {PROCESS_TIMEOUT:?}");
            }
            None => tokio::time::sleep(Duration::from_millis(10)).await,
        }
    }
}

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
    let output = output_with_timeout(&mut command).await;

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
