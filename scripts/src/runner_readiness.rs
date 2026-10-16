//! Bounded readiness checks for disposable integration runners.

use clap::{Parser, Subcommand};
use std::{io::Cursor, path::PathBuf, time::Duration};
use thiserror::Error;
use tokio::time::{Instant, sleep};

#[derive(Parser)]
pub struct Arguments {
    #[command(subcommand)]
    command: Operation,
}

#[derive(Subcommand)]
enum Operation {
    /// Read an HTTP response with connection, request, and overall deadlines.
    Http {
        #[arg(long)]
        url: reqwest::Url,
        #[arg(long, default_value_t = 5, value_parser = clap::value_parser!(u64).range(1..=300))]
        wait_seconds: u64,
    },
    /// Acknowledge actual on-disk scenario persistence and receipt clearing.
    DeepLinkSeed {
        #[arg(long)]
        preferences: PathBuf,
        #[arg(long, default_value_t = 30, value_parser = clap::value_parser!(u64).range(1..=300))]
        wait_seconds: u64,
    },
    /// Allocate a unique, exclusively owned failure-artifact directory.
    ArtifactDirectory {
        #[arg(long)]
        root: PathBuf,
    },
    /// Retain a driver log without local paths, URLs, or credential text.
    RetainDriverLog {
        #[arg(long)]
        input: PathBuf,
        #[arg(long)]
        output: PathBuf,
    },
}

#[derive(Debug, Error)]
pub enum ReadinessError {
    #[error("http_client_configuration_failed")]
    HttpClient(#[source] reqwest::Error),
    #[error("http_readiness_deadline: last_stage={0}")]
    HttpDeadline(HttpStage),
    #[error("deep_link_seed_deadline: last_state={0}")]
    SeedDeadline(SeedState),
    #[error("artifact_io_failed: {0}")]
    ArtifactIo(#[from] std::io::Error),
    #[error("driver_log_redaction_configuration_failed")]
    Redaction(#[from] regex::Error),
}

#[derive(Clone, Copy, Debug)]
pub enum HttpStage {
    Connect,
    Timeout,
    Transport,
    Status(u16),
    Body,
}

impl std::fmt::Display for HttpStage {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Connect => f.write_str("connect"),
            Self::Timeout => f.write_str("request_timeout"),
            Self::Transport => f.write_str("transport"),
            Self::Status(code) => write!(f, "http_status_{code}"),
            Self::Body => f.write_str("response_body"),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SeedState {
    Missing,
    Unreadable,
    InvalidPlist,
    ScenarioMissing,
    ScenarioMismatch,
    ReceiptPresent,
    Ready,
}

impl std::fmt::Display for SeedState {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            Self::Missing => "preferences_missing",
            Self::Unreadable => "preferences_unreadable",
            Self::InvalidPlist => "invalid_preferences_plist",
            Self::ScenarioMissing => "scenario_missing",
            Self::ScenarioMismatch => "scenario_mismatch",
            Self::ReceiptPresent => "receipt_not_cleared",
            Self::Ready => "ready",
        })
    }
}

pub async fn run(arguments: Arguments) -> Result<(), ReadinessError> {
    match arguments.command {
        Operation::Http { url, wait_seconds } => {
            print!(
                "{}",
                http_ready(url, Duration::from_secs(wait_seconds)).await?
            );
        }
        Operation::DeepLinkSeed {
            preferences,
            wait_seconds,
        } => {
            wait_for_seed(&preferences, Duration::from_secs(wait_seconds)).await?;
        }
        Operation::ArtifactDirectory { root } => {
            let path = artifact_directory(&root).await?;
            println!("{}", path.display());
        }
        Operation::RetainDriverLog { input, output } => {
            let text = tokio::fs::read_to_string(input).await?;
            tokio::fs::write(output, redact_driver_log(&text)?).await?;
        }
    }
    Ok(())
}

async fn artifact_directory(root: &std::path::Path) -> Result<PathBuf, std::io::Error> {
    tokio::fs::create_dir_all(root).await?;
    // Exclusive creation prevents reusing another run's artifacts on a collision.
    let path = root.join(format!("run-{:032x}", rand::random::<u128>()));
    tokio::fs::create_dir(&path).await?;
    Ok(path)
}

async fn http_ready(url: reqwest::Url, budget: Duration) -> Result<String, ReadinessError> {
    let client = reqwest::Client::builder()
        .connect_timeout(Duration::from_secs(2))
        .timeout(Duration::from_secs(5))
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .map_err(ReadinessError::HttpClient)?;
    let deadline = Instant::now() + budget;
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        let stage = match client
            .get(url.clone())
            .timeout(remaining.min(Duration::from_secs(5)))
            .send()
            .await
        {
            Ok(response) if response.status().is_success() => match response.text().await {
                Ok(body) => return Ok(body),
                Err(error) if error.is_timeout() => HttpStage::Timeout,
                Err(_) => HttpStage::Body,
            },
            Ok(response) => HttpStage::Status(response.status().as_u16()),
            Err(error) if error.is_timeout() => HttpStage::Timeout,
            Err(error) if error.is_connect() => HttpStage::Connect,
            Err(_) => HttpStage::Transport,
        };
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(ReadinessError::HttpDeadline(stage));
        }
        sleep(remaining.min(Duration::from_millis(200))).await;
        if Instant::now() >= deadline {
            return Err(ReadinessError::HttpDeadline(stage));
        }
    }
}

fn seed_state(bytes: &[u8]) -> SeedState {
    let Ok(value) = plist::Value::from_reader(Cursor::new(bytes)) else {
        return SeedState::InvalidPlist;
    };
    let Some(dictionary) = value.as_dictionary() else {
        return SeedState::InvalidPlist;
    };
    match dictionary
        .get("Bleat.UITest.persistedScenario")
        .and_then(plist::Value::as_string)
    {
        None => return SeedState::ScenarioMissing,
        Some("--ui-testing-signed-in") => (),
        Some(_) => return SeedState::ScenarioMismatch,
    }
    if dictionary.contains_key("bleatUITestLastDeepLinkReceipt")
        || dictionary.contains_key("bleatUITestDeepLinkReceiptRevision")
    {
        SeedState::ReceiptPresent
    } else {
        SeedState::Ready
    }
}

async fn wait_for_seed(path: &std::path::Path, budget: Duration) -> Result<(), ReadinessError> {
    let deadline = Instant::now() + budget;
    loop {
        let state = match tokio::fs::read(path).await {
            Ok(bytes) => seed_state(&bytes),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => SeedState::Missing,
            Err(_) => SeedState::Unreadable,
        };
        if state == SeedState::Ready {
            return Ok(());
        }
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(ReadinessError::SeedDeadline(state));
        }
        sleep(remaining.min(Duration::from_millis(100))).await;
    }
}

fn redact_driver_log(text: &str) -> Result<String, regex::Error> {
    let sensitive = regex::Regex::new(
        r"(?i)(authorization|password|cookie|access.?token|refresh.?token|eyJ[A-Za-z0-9_-]+\.)",
    )?;
    let paths = regex::Regex::new(r#"/(?:Users|private|tmp|var|Volumes)/[^\s\"'<>]+"#)?;
    let urls = regex::Regex::new(r#"[A-Za-z][A-Za-z0-9+.-]*://[^\s\"'<>]+"#)?;
    let ids = regex::Regex::new(r"(?i)\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\b")?;
    Ok(text
        .lines()
        .map(|line| {
            if sensitive.is_match(line) {
                "[REDACTED_SENSITIVE_LINE]".to_owned()
            } else {
                let line = paths.replace_all(line, "[LOCAL_PATH]");
                let line = urls.replace_all(&line, "[URL]");
                ids.replace_all(&line, "[ID]").into_owned()
            }
        })
        .collect::<Vec<_>>()
        .join("\n")
        + "\n")
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    fn preferences(receipt: bool) -> Vec<u8> {
        let mut values = plist::Dictionary::new();
        values.insert(
            "Bleat.UITest.persistedScenario".into(),
            "--ui-testing-signed-in".into(),
        );
        if receipt {
            values.insert("bleatUITestLastDeepLinkReceipt".into(), "old".into());
        }
        let mut bytes = Vec::new();
        plist::Value::Dictionary(values)
            .to_writer_binary(&mut bytes)
            .expect("encode fixture");
        bytes
    }

    #[tokio::test]
    async fn seed_requires_persisted_scenario_and_absent_receipt() {
        assert_eq!(seed_state(&preferences(true)), SeedState::ReceiptPresent);
        assert_eq!(seed_state(&preferences(false)), SeedState::Ready);
        assert_eq!(seed_state(b"partial write"), SeedState::InvalidPlist);
        let root = artifact_directory(&std::env::temp_dir())
            .await
            .expect("temporary root");
        let path = root.join("preferences.plist");
        let writer_path = path.clone();
        let mut tasks = tokio::task::JoinSet::new();
        tasks.spawn(async move {
            tokio::fs::write(&writer_path, preferences(true))
                .await
                .expect("write old receipt");
            sleep(Duration::from_millis(50)).await;
            tokio::fs::write(writer_path, preferences(false))
                .await
                .expect("persist cleared receipt");
        });
        let result = wait_for_seed(&path, Duration::from_secs(2)).await;
        tasks.abort_all();
        let _ = tasks.join_next().await;
        tokio::fs::remove_dir_all(root)
            .await
            .expect("clean fixture");
        result.expect("observe persisted seed");
    }

    #[tokio::test]
    async fn seed_missing_fails_with_a_bounded_typed_state() {
        let root = artifact_directory(&std::env::temp_dir())
            .await
            .expect("temporary root");
        let result = wait_for_seed(&root.join("absent"), Duration::from_millis(30)).await;
        tokio::fs::remove_dir_all(root)
            .await
            .expect("clean fixture");
        assert!(matches!(
            result,
            Err(ReadinessError::SeedDeadline(SeedState::Missing))
        ));
    }

    #[tokio::test]
    async fn http_bounds_a_server_that_accepts_but_never_replies() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind fixture");
        let url = format!("http://{}/", listener.local_addr().expect("local address"))
            .parse()
            .expect("URL");
        let mut tasks = tokio::task::JoinSet::new();
        tasks.spawn(async move {
            let (_stream, _) = listener.accept().await.expect("accept request");
            std::future::pending::<()>().await;
        });
        let result = tokio::time::timeout(
            Duration::from_secs(2),
            http_ready(url, Duration::from_millis(100)),
        )
        .await
        .expect("outer watchdog");
        assert!(matches!(
            result,
            Err(ReadinessError::HttpDeadline(HttpStage::Timeout))
        ));
        tasks.abort_all();
        assert!(
            tasks
                .join_next()
                .await
                .expect("server exists")
                .expect_err("server cancelled")
                .is_cancelled()
        );
    }

    #[tokio::test]
    async fn http_retries_status_and_returns_the_actual_body() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind fixture");
        let url = format!("http://{}/", listener.local_addr().expect("local address"))
            .parse()
            .expect("URL");
        let mut tasks = tokio::task::JoinSet::new();
        tasks.spawn(async move {
            for response in [
                "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\n\r\n",
                "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nready",
            ] {
                let (mut stream, _) = listener.accept().await.expect("accept request");
                let mut request = [0; 4096];
                stream.read(&mut request).await.expect("read request");
                stream.write_all(response.as_bytes()).await.expect("reply");
            }
        });
        assert_eq!(
            http_ready(url, Duration::from_secs(2))
                .await
                .expect("ready response"),
            "ready"
        );
        tasks
            .join_next()
            .await
            .expect("server exists")
            .expect("server finishes");
    }

    #[test]
    fn driver_log_removes_paths_urls_identifiers_and_sensitive_lines() {
        let output = redact_driver_log("error /Users/example/project/file.swift https://example.test/private\nauthorization: Bearer test-secret\nSimulator 12345678-1234-1234-1234-123456789abc\nTest Case passed\n").expect("redact log");
        assert_eq!(
            output,
            "error [LOCAL_PATH] [URL]\n[REDACTED_SENSITIVE_LINE]\nSimulator [ID]\nTest Case passed\n"
        );
    }

    #[tokio::test]
    async fn artifact_cleanup_preserves_other_runs() {
        let root = artifact_directory(&std::env::temp_dir())
            .await
            .expect("temporary root");
        let first = artifact_directory(&root).await.expect("first run");
        let second = artifact_directory(&root).await.expect("second run");
        assert_ne!(first, second);
        tokio::fs::write(second.join("evidence"), b"retained")
            .await
            .expect("write evidence");
        tokio::fs::remove_dir_all(first)
            .await
            .expect("clean first run");
        let evidence = tokio::fs::read(second.join("evidence")).await;
        tokio::fs::remove_dir_all(root)
            .await
            .expect("clean fixture");
        assert_eq!(evidence.expect("retained evidence"), b"retained");
    }

    #[tokio::test]
    async fn http_deadline_includes_response_body() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind fixture");
        let url = format!("http://{}/", listener.local_addr().expect("local address"))
            .parse()
            .expect("URL");
        let mut tasks = tokio::task::JoinSet::new();
        tasks.spawn(async move {
            let (mut stream, _) = listener.accept().await.expect("accept request");
            let mut request = [0; 4096];
            stream.read(&mut request).await.expect("read request");
            stream
                .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n")
                .await
                .expect("send headers");
            std::future::pending::<()>().await;
        });
        let result = tokio::time::timeout(
            Duration::from_secs(2),
            http_ready(url, Duration::from_millis(100)),
        )
        .await
        .expect("outer watchdog");
        tasks.abort_all();
        assert!(
            tasks
                .join_next()
                .await
                .expect("server exists")
                .expect_err("server cancelled")
                .is_cancelled()
        );
        assert!(matches!(
            result,
            Err(ReadinessError::HttpDeadline(HttpStage::Timeout))
        ));
    }
}
