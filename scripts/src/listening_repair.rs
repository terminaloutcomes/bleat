//! Repair only closed sessions with measured, account-matched Bleat history.
//! Contract: Audiobookshelf v2.36.0 PlaybackSessionManager.syncLocalSession.
use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

use clap::Parser;
use reqwest::{Client, StatusCode};
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use thiserror::Error;
use url::Url;

#[derive(Parser)]
pub struct Arguments {
    /// Bleat statistics JSON export for one account.
    #[arg(long)]
    archive: PathBuf,
    #[arg(long)]
    server: Url,
    /// Keep credentials out of command arguments and generated reports.
    #[arg(long, env = "BLEAT_ABS_TOKEN", hide_env_values = true)]
    token: String,
    /// Apply the displayed corrections; otherwise perform a read-only preview.
    #[arg(long)]
    apply: bool,
}

#[derive(Debug, Error)]
pub enum RepairError {
    #[error("Cannot read statistics export")]
    Read(#[from] std::io::Error),
    #[error("Statistics export could not be decoded")]
    InvalidExport,
    #[error("HTTPS server without credentials, query, or fragment is required")]
    Server,
    #[error("Request failed at {0}; no credentials or session routes are included in this error")]
    Transport(&'static str),
    #[error("Server rejected {stage} with HTTP {status}")]
    Http { stage: &'static str, status: u16 },
    #[error("Export does not match the authenticated server and account")]
    Account,
    #[error("Unsupported statistics export version")]
    UnsupportedVersion,
    #[error("Listening slice belongs to a different account")]
    SliceAccountMismatch,
    #[error("Invalid measured listening time")]
    InvalidListeningTime,
    #[error("Listening slice has missing identity")]
    InvalidIdentity,
    #[error("Duplicate listening slice identity")]
    DuplicateSlice,
    #[error("Invalid or changing session history; retry after stopping playback")]
    History,
    #[error("Session changed or remains open; stop playback and preview again")]
    Changed,
    #[error("Server did not acknowledge or retain the corrected total")]
    Unconfirmed,
    #[error("Playback progress changed during repair; stop playback before continuing")]
    ProgressChanged,
}

impl RepairError {
    pub fn code(&self) -> &'static str {
        match self {
            Self::Read(_) => "export_read_failed",
            Self::InvalidExport => "export_decode_failed",
            Self::Server => "invalid_server_url",
            Self::Transport(_) => "request_transport_failed",
            Self::Http { .. } => "request_http_failed",
            Self::Account => "account_mapping_mismatch",
            Self::UnsupportedVersion => "unsupported_export_version",
            Self::SliceAccountMismatch => "slice_account_mismatch",
            Self::InvalidListeningTime => "invalid_listening_time",
            Self::InvalidIdentity => "missing_slice_identity",
            Self::DuplicateSlice => "duplicate_slice_identity",
            Self::History => "invalid_history_response",
            Self::Changed => "session_changed",
            Self::Unconfirmed => "correction_unconfirmed",
            Self::ProgressChanged => "progress_changed",
        }
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Document {
    version: u32,
    #[serde(rename = "sourceAccountID")]
    source_account_id: String,
    #[serde(rename = "serverURL")]
    server_url: String,
    #[serde(rename = "remoteUserID")]
    remote_user_id: String,
    archive: Archive,
}

#[derive(Deserialize)]
struct Archive {
    version: u32,
    slices: Vec<Slice>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Slice {
    id: String,
    #[serde(rename = "accountID")]
    account_id: String,
    #[serde(rename = "itemID")]
    item_id: String,
    #[serde(rename = "sessionID")]
    session_id: String,
    real_seconds: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Page {
    total: usize,
    num_pages: usize,
    page: usize,
    items_per_page: usize,
    sessions: Vec<Value>,
}

fn portable_id(id: &str) -> String {
    if id.starts_with("portable:") {
        return id.to_owned();
    }
    let digest = Sha256::digest(format!("bleat-statistics-session-v1\0{id}"));
    format!(
        "portable:{}",
        digest
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect::<String>()
    )
}

fn ledger(document: &Document) -> Result<BTreeMap<(String, String), f64>, RepairError> {
    if document.version != 1 || document.archive.version != 1 {
        return Err(RepairError::UnsupportedVersion);
    }
    let mut ids = BTreeSet::new();
    let mut totals = BTreeMap::new();
    for slice in &document.archive.slices {
        if slice.account_id != document.source_account_id {
            return Err(RepairError::SliceAccountMismatch);
        }
        if !slice.real_seconds.is_finite() || slice.real_seconds < 0.0 {
            return Err(RepairError::InvalidListeningTime);
        }
        if slice.item_id.is_empty() || slice.session_id.is_empty() || slice.id.is_empty() {
            return Err(RepairError::InvalidIdentity);
        }
        if !ids.insert(&slice.id) {
            return Err(RepairError::DuplicateSlice);
        }
        let total = totals
            .entry((portable_id(&slice.session_id), slice.item_id.clone()))
            .or_insert(0.0);
        *total += slice.real_seconds;
        if !total.is_finite() {
            return Err(RepairError::InvalidListeningTime);
        }
    }
    Ok(totals)
}

fn corrected(
    session: &Value,
    totals: &BTreeMap<(String, String), f64>,
) -> Result<Option<Value>, RepairError> {
    let id = session["id"].as_str().ok_or(RepairError::History)?;
    let Some(item) = session["libraryItemId"].as_str() else {
        return Ok(None);
    };
    let Some(total) = totals.get(&(portable_id(id), item.to_owned())) else {
        return Ok(None);
    };
    let existing = session["timeListening"]
        .as_f64()
        .ok_or(RepairError::History)?;
    if !existing.is_finite() || existing < 0.0 {
        return Err(RepairError::History);
    }
    if *total <= existing + 0.001 {
        return Ok(None);
    }
    // Reuse the server's complete session, including timestamps and position.
    // Do not invent session IDs or upload inferred media-position differences.
    let mut value = session.clone();
    value["timeListening"] = json!(total);
    Ok(Some(value))
}

fn endpoint(server: &Url, route: &[&str]) -> Result<Url, RepairError> {
    let mut url = server.clone();
    url.path_segments_mut()
        .map_err(|_| RepairError::Server)?
        .pop_if_empty()
        .extend(route);
    Ok(url)
}

async fn get(
    client: &Client,
    url: Url,
    token: &str,
    stage: &'static str,
) -> Result<Value, RepairError> {
    let response = client
        .get(url)
        .bearer_auth(token)
        .send()
        .await
        .map_err(|_| RepairError::Transport(stage))?;
    if !response.status().is_success() {
        return Err(RepairError::Http {
            stage,
            status: response.status().as_u16(),
        });
    }
    response
        .json()
        .await
        .map_err(|_| RepairError::Transport(stage))
}

async fn history(client: &Client, server: &Url, token: &str) -> Result<Vec<Value>, RepairError> {
    let mut sessions = Vec::new();
    let mut expected_total = None;
    let mut ids = BTreeSet::new();
    let mut index = 0;
    loop {
        let mut url = endpoint(server, &["api", "me", "listening-sessions"])?;
        url.query_pairs_mut()
            .append_pair("itemsPerPage", "500")
            .append_pair("page", &index.to_string());
        let page: Page = serde_json::from_value(get(client, url, token, "history").await?)
            .map_err(|_| RepairError::History)?;
        if page.page != index
            || page.items_per_page != 500
            || page.num_pages != page.total.div_ceil(500)
            || expected_total.is_some_and(|total| total != page.total)
            || page.sessions.len() != page.total.saturating_sub(index * 500).min(500)
        {
            return Err(RepairError::History);
        }
        expected_total = Some(page.total);
        for session in page.sessions {
            let id = session["id"]
                .as_str()
                .ok_or(RepairError::History)?
                .to_owned();
            if !ids.insert(id) {
                return Err(RepairError::History);
            }
            sessions.push(session);
        }
        index += 1;
        if index >= page.num_pages {
            break;
        }
    }
    Ok(sessions)
}

enum ProgressProtection {
    Protected(Value),
    Missing,
    NotNewer,
}

fn protect_progress(session: &Value, progress: &Value) -> Result<ProgressProtection, RepairError> {
    let records = progress["mediaProgress"]
        .as_array()
        .ok_or(RepairError::History)?;
    let Some(record) = records.iter().find(|value| {
        value["libraryItemId"] == session["libraryItemId"] && value["episodeId"].is_null()
    }) else {
        return Ok(ProgressProtection::Missing);
    };
    let updated = record["lastUpdate"].as_i64().ok_or(RepairError::History)?;
    let session_updated = session["updatedAt"].as_i64().ok_or(RepairError::History)?;
    // The pinned local-session endpoint updates progress unless its timestamp
    // is strictly newer. Require that guard to avoid changing completion state.
    if updated > session_updated {
        Ok(ProgressProtection::Protected(record.clone()))
    } else {
        Ok(ProgressProtection::NotNewer)
    }
}

pub async fn run(arguments: Arguments) -> Result<(), RepairError> {
    let server = &arguments.server;
    if server.scheme() != "https"
        || !server.username().is_empty()
        || server.password().is_some()
        || server.query().is_some()
        || server.fragment().is_some()
    {
        return Err(RepairError::Server);
    }
    let document: Document = serde_json::from_slice(&tokio::fs::read(&arguments.archive).await?)
        .map_err(|_| RepairError::InvalidExport)?;
    let exported_server = Url::parse(&document.server_url).map_err(|_| RepairError::Account)?;
    if exported_server.as_str().trim_end_matches('/') != server.as_str().trim_end_matches('/') {
        return Err(RepairError::Account);
    }
    let totals = ledger(&document)?;
    let client = Client::builder()
        .https_only(true)
        .redirect(reqwest::redirect::Policy::none())
        .timeout(std::time::Duration::from_secs(30))
        .build()
        .map_err(|_| RepairError::Transport("client"))?;
    let user = get(
        &client,
        endpoint(server, &["api", "me"])?,
        &arguments.token,
        "account",
    )
    .await?;
    if user["id"].as_str() != Some(document.remote_user_id.as_str()) {
        return Err(RepairError::Account);
    }
    let sessions = history(&client, server, &arguments.token).await?;
    let mut count = 0;
    for session in sessions {
        let Some(payload) = corrected(&session, &totals)? else {
            continue;
        };
        let id = session["id"].as_str().ok_or(RepairError::History)?;
        let response = client
            .get(endpoint(server, &["api", "session", id])?)
            .bearer_auth(&arguments.token)
            .send()
            .await
            .map_err(|_| RepairError::Transport("open session check"))?;
        match response.status() {
            StatusCode::NOT_FOUND => {}
            StatusCode::OK => {
                println!("Skipped an active session; stop playback before repairing it.");
                continue;
            }
            status => {
                return Err(RepairError::Http {
                    stage: "open session check",
                    status: status.as_u16(),
                });
            }
        }
        let progress = get(
            &client,
            endpoint(server, &["api", "me", "progress"])?,
            &arguments.token,
            "progress protection",
        )
        .await?;
        let protected = match protect_progress(&session, &progress)? {
            ProgressProtection::Protected(record) => record,
            ProgressProtection::Missing => {
                println!("Skipped: missing playback progress; repair would create progress.");
                continue;
            }
            ProgressProtection::NotNewer => {
                println!(
                    "Skipped: playback progress is not newer than the session; repair could alter completion state."
                );
                continue;
            }
        };
        println!(
            "Closed session: {:.1} → {:.1} listening seconds",
            session["timeListening"]
                .as_f64()
                .ok_or(RepairError::History)?,
            payload["timeListening"]
                .as_f64()
                .ok_or(RepairError::History)?
        );
        if arguments.apply {
            // Fresh structural comparison prevents applying a stale preview.
            let current = history(&client, server, &arguments.token).await?;
            if current
                .iter()
                .find(|value| value["id"].as_str() == Some(id))
                != Some(&session)
            {
                return Err(RepairError::Changed);
            }
            let response = client
                .post(endpoint(server, &["api", "session", "local-all"])?)
                .bearer_auth(&arguments.token)
                .json(&json!({"sessions": [payload]}))
                .send()
                .await
                .map_err(|_| RepairError::Transport("repair"))?;
            if !response.status().is_success() {
                return Err(RepairError::Http {
                    stage: "repair",
                    status: response.status().as_u16(),
                });
            }
            let result: Value = response
                .json()
                .await
                .map_err(|_| RepairError::Transport("acknowledgement"))?;
            if result["results"][0]["id"].as_str() != Some(id)
                || result["results"][0]["success"] != true
            {
                return Err(RepairError::Unconfirmed);
            }
            let verified = history(&client, server, &arguments.token).await?;
            let stored = verified
                .iter()
                .find(|value| value["id"].as_str() == Some(id))
                .ok_or(RepairError::Unconfirmed)?;
            for key in ["timeListening", "currentTime"] {
                let actual = stored[key].as_f64().ok_or(RepairError::Unconfirmed)?;
                let expected = payload[key].as_f64().ok_or(RepairError::Unconfirmed)?;
                if (actual - expected).abs() > 0.001 {
                    return Err(RepairError::Unconfirmed);
                }
            }
            for key in ["startedAt", "updatedAt"] {
                if stored[key] != payload[key] {
                    return Err(RepairError::Unconfirmed);
                }
            }
            let after = get(
                &client,
                endpoint(server, &["api", "me", "progress"])?,
                &arguments.token,
                "progress verification",
            )
            .await?;
            let records = after["mediaProgress"]
                .as_array()
                .ok_or(RepairError::History)?;
            if records.iter().find(|value| value["id"] == protected["id"]) != Some(&protected) {
                return Err(RepairError::ProgressChanged);
            }
        }
        count += 1;
    }
    println!(
        "{count} session corrections {}. Unmatched history was not inferred or uploaded.",
        if arguments.apply {
            "verified"
        } else {
            "previewed; use --apply to repair"
        }
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn document() -> Document {
        serde_json::from_value(json!({"version":1,"sourceAccountID":"account","serverURL":"https://example.test/abs/","remoteUserID":"user","archive":{"version":1,"slices":[{"id":"slice","accountID":"account","itemID":"book","sessionID":portable_id("session"),"realSeconds":90}]}})).expect("valid export")
    }

    #[test]
    fn repairs_only_exact_identity_with_larger_measured_total() {
        let totals = ledger(&document()).expect("valid ledger");
        let session = json!({"id":"session","libraryItemId":"book","timeListening":30,"currentTime":123,"startedAt":1000,"updatedAt":2000});
        let repaired = corrected(&session, &totals)
            .expect("valid session")
            .expect("correction");
        assert_eq!(repaired["timeListening"].as_f64(), Some(90.0));
        for key in ["currentTime", "startedAt", "updatedAt"] {
            assert_eq!(session[key], repaired[key]);
        }
        assert!(
            corrected(&repaired, &totals)
                .expect("valid retry")
                .is_none()
        );
        let mut other = session.clone();
        other["libraryItemId"] = json!("other");
        assert!(
            corrected(&other, &totals)
                .expect("valid other book")
                .is_none()
        );
        other = session;
        other["timeListening"] = json!(120);
        assert!(
            corrected(&other, &totals)
                .expect("valid larger total")
                .is_none()
        );
    }

    #[test]
    fn rejects_wrong_accounts_duplicates_and_invalid_time() {
        let mut archive = document();
        archive.archive.slices[0].account_id = "other".into();
        assert!(matches!(
            ledger(&archive),
            Err(RepairError::SliceAccountMismatch)
        ));
        let mut archive = document();
        archive.archive.slices[0].real_seconds = f64::NAN;
        assert!(matches!(
            ledger(&archive),
            Err(RepairError::InvalidListeningTime)
        ));
        let mut archive = document();
        archive.archive.slices.push(Slice {
            id: "slice".into(),
            account_id: "account".into(),
            item_id: "book".into(),
            session_id: "session".into(),
            real_seconds: 1.0,
        });
        assert!(matches!(ledger(&archive), Err(RepairError::DuplicateSlice)));
    }

    #[test]
    fn protects_missing_current_and_newer_progress_separately() {
        let session = json!({"libraryItemId":"book","updatedAt":2000});
        assert!(matches!(
            protect_progress(&session, &json!({"mediaProgress":[]}))
                .expect("valid missing progress"),
            ProgressProtection::Missing
        ));
        for timestamp in [1000, 2000] {
            assert!(matches!(
                protect_progress(
                    &session,
                    &json!({"mediaProgress":[{"libraryItemId":"book","lastUpdate":timestamp}]})
                )
                .expect("valid current progress"),
                ProgressProtection::NotNewer
            ));
        }
        assert!(matches!(
            protect_progress(
                &session,
                &json!({"mediaProgress":[{"libraryItemId":"book","lastUpdate":3000}]})
            )
            .expect("valid newer progress"),
            ProgressProtection::Protected(_)
        ));
    }

    #[test]
    fn preserves_path_prefix_and_encodes_session_ids() {
        let server = Url::parse("https://example.test/abs/").expect("valid server");
        assert_eq!(
            endpoint(&server, &["api", "session", "secret/id"])
                .expect("valid endpoint")
                .as_str(),
            "https://example.test/abs/api/session/secret%2Fid"
        );
    }
}
