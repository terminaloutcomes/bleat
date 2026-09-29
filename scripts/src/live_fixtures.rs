use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitStatus};
use std::str::FromStr;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use clap::Parser;
use reqwest::Method;
use reqwest::blocking::Client;
use serde::Deserialize;
use serde::Serialize;
use serde_json::{Value, json};
use thiserror::Error;
use url::Url;

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum Profile {
    Minimum,
    CurrentStable,
    #[serde(untagged)]
    Version(String),
}

impl FromStr for Profile {
    type Err = &'static str;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "minimum" => Ok(Self::Minimum),
            "current-stable" => Ok(Self::CurrentStable),
            version => {
                if semver::Version::parse(version).is_err() {
                    return Err("invalid version");
                }
                Ok(Self::Version(version.to_string()))
            }
        }
    }
}

impl Profile {
    fn id(&self) -> String {
        match self {
            Self::Minimum => "minimum".to_string(),
            Self::CurrentStable => "current-stable".to_string(),
            Self::Version(version) => version.to_string(),
        }
    }
}

#[derive(Debug, Parser)]
#[command(about = "Capture redacted responses from a disposable Audiobookshelf server")]
pub struct Arguments {
    #[arg(value_parser = Profile::from_str)]
    profile: Profile,

    #[arg(long, default_value = ".")]
    repository_root: PathBuf,

    #[arg(long, env = "BLEAT_ABS_ROOT_PORT", default_value_t = 13378)]
    root_port: u16,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Manifest {
    id: String,
    server_version: String,
    image: String,
    seed_version: String,
}

impl Manifest {
    fn validate(&self, profile: Profile) -> Result<(), CaptureError> {
        let version = &self.server_version;
        let numeric_version = version.split('.').count() == 3
            && version.split('.').all(|component| {
                !component.is_empty() && component.bytes().all(|b| b.is_ascii_digit())
            });
        let prefix = format!("ghcr.io/advplyr/audiobookshelf:{version}@sha256:");
        let valid_digest = self.image.strip_prefix(&prefix).is_some_and(|digest| {
            digest.len() == 64
                && digest
                    .bytes()
                    .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
        });
        if self.id != profile.id()
            || !numeric_version
            || self.seed_version != *version
            || !valid_digest
        {
            return Err(CaptureError::InvalidProfile);
        }
        Ok(())
    }
}

#[derive(Debug, Error)]
pub enum CaptureError {
    #[error(
        "BLEAT_COMPOSE_PROJECT_NAME and BLEAT_COMPOSE_OVERRIDE_FILE must be unset for fixture capture"
    )]
    InheritedComposeConfiguration,
    #[error("invalid Audiobookshelf profile manifest")]
    InvalidProfile,
    #[error("missing or malformed {field} in Audiobookshelf response")]
    MissingField { field: &'static str },
    #[error("Audiobookshelf reported version {observed}; expected {expected}")]
    VersionMismatch { observed: String, expected: String },
    #[error("{stage} returned HTTP {status}")]
    HttpStatus {
        stage: &'static str,
        status: reqwest::StatusCode,
    },
    #[error("{stage} request failed: {source}")]
    Request {
        stage: &'static str,
        #[source]
        source: reqwest::Error,
    },
    #[error("{stage} could not start: {source}")]
    CommandStart {
        stage: &'static str,
        #[source]
        source: std::io::Error,
    },
    #[error("{stage} failed with {status}")]
    CommandFailed {
        stage: &'static str,
        status: ExitStatus,
    },
    #[error("fixture contains an unredacted capture credential")]
    RedactionFailed,
    #[error("fixture capture interrupted")]
    Interrupted,
    #[error("could not install fixture capture signal handler: {0}")]
    SignalHandler(std::io::Error),
    #[error("{stage}: {source}")]
    Io {
        stage: &'static str,
        #[source]
        source: std::io::Error,
    },
    #[error("{stage}: {source}")]
    Json {
        stage: &'static str,
        #[source]
        source: serde_json::Error,
    },
    #[error("invalid local capture URL: {0}")]
    Url(#[from] url::ParseError),
    #[error("capture failed: {capture}; Docker cleanup failed: {cleanup}")]
    CaptureAndCleanup {
        capture: Box<CaptureError>,
        cleanup: Box<CaptureError>,
    },
}

struct CaptureContext {
    project_name: String,
    username: String,
    password: String,
    profile: Profile,
}

pub fn run(args: Arguments) -> Result<String, CaptureError> {
    if env::var_os("BLEAT_COMPOSE_PROJECT_NAME").is_some()
        || env::var_os("BLEAT_COMPOSE_OVERRIDE_FILE").is_some()
    {
        return Err(CaptureError::InheritedComposeConfiguration);
    }
    let root = args.repository_root;
    let manifest_path = root
        .join("TestSupport/ServerHarness/profiles")
        .join(format!("{}.json", args.profile.id()));
    let manifest_data = fs::read(&manifest_path).map_err(|source| CaptureError::Io {
        stage: "read profile manifest",
        source,
    })?;
    let manifest: Manifest =
        serde_json::from_slice(&manifest_data).map_err(|source| CaptureError::Json {
            stage: "parse profile manifest",
            source,
        })?;
    manifest.validate(args.profile.clone())?;

    let interrupted = Arc::new(AtomicBool::new(false));
    #[cfg(unix)]
    for signal in [signal_hook::consts::SIGINT, signal_hook::consts::SIGTERM] {
        signal_hook::flag::register(signal, Arc::clone(&interrupted))
            .map_err(CaptureError::SignalHandler)?;
    }

    let run_id = format!("{:032x}", rand::random::<u128>());
    let context = CaptureContext {
        project_name: format!(
            "bleat-fixtures-{}-{}-{run_id}",
            args.profile.id(),
            manifest.server_version.replace('.', "-")
        ),
        username: format!("bleat-{:032x}", rand::random::<u128>()),
        password: format!(
            "{:032x}{:032x}",
            rand::random::<u128>(),
            rand::random::<u128>()
        ),
        profile: args.profile.clone(),
    };
    let environment_script = root.join("scripts/live-test-environment.sh");
    let capture = run_environment(&environment_script, &context, "reset")
        .and_then(|()| check_interrupted(&interrupted))
        .and_then(|()| capture_responses(&root, &manifest, &context, args.root_port, &interrupted));
    let cleanup = run_environment(&environment_script, &context, "down");
    match (capture, cleanup) {
        (Ok(()), Ok(())) => {
            check_interrupted(&interrupted)?;
            Ok(manifest.server_version)
        }
        (Err(capture), Ok(())) => Err(capture),
        (Ok(()), Err(cleanup)) => Err(cleanup),
        (Err(capture), Err(cleanup)) => Err(CaptureError::CaptureAndCleanup {
            capture: Box::new(capture),
            cleanup: Box::new(cleanup),
        }),
    }
}

fn check_interrupted(interrupted: &AtomicBool) -> Result<(), CaptureError> {
    if interrupted.load(Ordering::Relaxed) {
        Err(CaptureError::Interrupted)
    } else {
        Ok(())
    }
}

fn run_environment(
    script: &Path,
    context: &CaptureContext,
    stage: &'static str,
) -> Result<(), CaptureError> {
    let status = Command::new(script)
        .arg(stage)
        .env("BLEAT_LIVE_PROFILE_ID", context.profile.id())
        .env("BLEAT_COMPOSE_PROJECT_NAME", &context.project_name)
        .env("BLEAT_TEST_USERNAME", &context.username)
        .env("BLEAT_TEST_PASSWORD", &context.password)
        .status()
        .map_err(|source| CaptureError::CommandStart { stage, source })?;
    if status.success() {
        Ok(())
    } else {
        Err(CaptureError::CommandFailed { stage, status })
    }
}

fn capture_responses(
    root: &Path,
    manifest: &Manifest,
    context: &CaptureContext,
    root_port: u16,
    interrupted: &AtomicBool,
) -> Result<(), CaptureError> {
    let client = Client::builder()
        .timeout(Duration::from_secs(15))
        .build()
        .map_err(|source| CaptureError::Request {
            stage: "create HTTP client",
            source,
        })?;
    let base = Url::parse(&format!("http://127.0.0.1:{root_port}/"))?;
    let status = request(
        &client,
        Method::GET,
        route(&base, &["status"]),
        None,
        "status",
    )?;
    let observed = string_field(&status, &["serverVersion"], "serverVersion")?;
    if observed != manifest.server_version {
        return Err(CaptureError::VersionMismatch {
            observed: observed.to_owned(),
            expected: manifest.server_version.clone(),
        });
    }
    let login = client
        .post(route(&base, &["login"]))
        .header("x-return-tokens", "true")
        .json(&json!({"username": context.username, "password": context.password}))
        .send()
        .map_err(|source| CaptureError::Request {
            stage: "login",
            source,
        })?;
    let login = parse_response(login, "login")?;
    let token = string_field(&login, &["user", "accessToken"], "user.accessToken")?.to_owned();
    let authorize = request(
        &client,
        Method::POST,
        route(&base, &["api", "authorize"]),
        Some(&token),
        "authorize",
    )?;
    let libraries = request(
        &client,
        Method::GET,
        route(&base, &["api", "libraries"]),
        Some(&token),
        "libraries",
    )?;
    let library_id = libraries["libraries"]
        .as_array()
        .and_then(|libraries| {
            libraries.iter().find_map(|library| {
                (library["name"] == "Bleat Live Fixtures")
                    .then(|| library["id"].as_str())
                    .flatten()
            })
        })
        .ok_or(CaptureError::MissingField {
            field: "Bleat Live Fixtures library ID",
        })?;
    let mut items_url = route(&base, &["api", "libraries", library_id, "items"]);
    items_url.query_pairs_mut().extend_pairs([
        ("limit", "2"),
        ("page", "0"),
        ("sort", "media.metadata.title"),
        ("minified", "1"),
        ("collapseseries", "1"),
        ("include", "progress"),
    ]);
    let items = request(
        &client,
        Method::GET,
        items_url,
        Some(&token),
        "library items",
    )?;
    let mut uncollapsed_url = route(&base, &["api", "libraries", library_id, "items"]);
    uncollapsed_url.query_pairs_mut().extend_pairs([
        ("limit", "2"),
        ("page", "0"),
        ("sort", "media.metadata.title"),
        ("minified", "1"),
        ("include", "progress"),
    ]);
    let uncollapsed = request(
        &client,
        Method::GET,
        uncollapsed_url,
        Some(&token),
        "uncollapsed library items",
    )?;
    let item_id = uncollapsed["results"]
        .as_array()
        .and_then(|items| items.first())
        .and_then(|item| item["id"].as_str())
        .ok_or(CaptureError::MissingField {
            field: "first library item ID",
        })?;
    let mut detail_url = route(&base, &["api", "items", item_id]);
    detail_url
        .query_pairs_mut()
        .extend_pairs([("expanded", "1"), ("include", "progress")]);
    let detail = request(
        &client,
        Method::GET,
        detail_url,
        Some(&token),
        "book detail",
    )?;
    let mut search_url = route(&base, &["api", "libraries", library_id, "search"]);
    search_url
        .query_pairs_mut()
        .extend_pairs([("q", "direct"), ("limit", "12")]);
    let search = request(&client, Method::GET, search_url, Some(&token), "search")?;
    check_interrupted(interrupted)?;

    let mut captured = [
        ("status", status),
        ("login", login),
        ("authorize", authorize),
        ("library-items", items),
        ("book-detail", detail),
        ("search", search),
    ];
    for (name, payload) in &mut captured {
        redact(payload, *name == "login" || *name == "authorize");
    }
    let output = root
        .join("Tests/BleatCoreTests/Fixtures")
        .join(&manifest.server_version);
    write_fixtures(
        &output,
        &manifest.server_version,
        &captured,
        &[&context.username, &context.password, &token],
    )
}

fn route(base: &Url, segments: &[&str]) -> Url {
    let mut url = base.clone();
    if let Ok(mut path) = url.path_segments_mut() {
        path.clear().extend(segments.iter().copied());
    }
    url
}

fn request(
    client: &Client,
    method: Method,
    url: Url,
    token: Option<&str>,
    stage: &'static str,
) -> Result<Value, CaptureError> {
    let mut request = client.request(method, url);
    if let Some(token) = token {
        request = request.bearer_auth(token);
    }
    let response = request
        .send()
        .map_err(|source| CaptureError::Request { stage, source })?;
    parse_response(response, stage)
}

fn parse_response(
    response: reqwest::blocking::Response,
    stage: &'static str,
) -> Result<Value, CaptureError> {
    if !response.status().is_success() {
        return Err(CaptureError::HttpStatus {
            stage,
            status: response.status(),
        });
    }
    response
        .json()
        .map_err(|source| CaptureError::Request { stage, source })
}

fn string_field<'a>(
    value: &'a Value,
    path: &[&str],
    field: &'static str,
) -> Result<&'a str, CaptureError> {
    path.iter()
        .try_fold(value, |current, key| current.get(*key))
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .ok_or(CaptureError::MissingField { field })
}

fn redact(value: &mut Value, normalize_user: bool) {
    match value {
        Value::Object(fields) => {
            for (key, field) in fields.iter_mut() {
                let lowercase = key.to_ascii_lowercase();
                if [
                    "token", "password", "cookie", "secret", "path", "url", "filename",
                ]
                .iter()
                .any(|part| lowercase.contains(part))
                {
                    *field = Value::String("[REDACTED]".to_owned());
                } else {
                    redact(field, false);
                }
            }
            if normalize_user && let Some(Value::Object(user)) = fields.get_mut("user") {
                user.insert("username".to_owned(), json!("fixture-root"));
                user.insert("id".to_owned(), json!("fixture-user"));
            }
        }
        Value::Array(items) => {
            for item in items {
                redact(item, false);
            }
        }
        _ => {}
    }
}

fn write_fixtures(
    output: &Path,
    version: &str,
    captured: &[(&str, Value)],
    secrets: &[&str],
) -> Result<(), CaptureError> {
    fs::create_dir_all(output).map_err(|source| CaptureError::Io {
        stage: "create fixture directory",
        source,
    })?;
    let staging = tempfile::Builder::new()
        .prefix(".capture-")
        .tempdir_in(output)
        .map_err(|source| CaptureError::Io {
            stage: "create fixture staging directory",
            source,
        })?;
    for (name, value) in captured {
        let mut bytes = serde_json::to_vec_pretty(value).map_err(|source| CaptureError::Json {
            stage: "serialize fixture",
            source,
        })?;
        bytes.push(b'\n');
        if secrets.iter().any(|secret| {
            !secret.is_empty() && bytes.windows(secret.len()).any(|w| w == secret.as_bytes())
        }) {
            return Err(CaptureError::RedactionFailed);
        }
        fs::write(
            staging
                .path()
                .join(format!("captured-{version}-{name}.json")),
            bytes,
        )
        .map_err(|source| CaptureError::Io {
            stage: "stage fixture",
            source,
        })?;
    }
    for (name, _) in captured {
        let filename = format!("captured-{version}-{name}.json");
        fs::rename(staging.path().join(&filename), output.join(filename)).map_err(|source| {
            CaptureError::Io {
                stage: "publish fixture",
                source,
            }
        })?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{Manifest, Profile, redact, write_fixtures};
    use serde_json::json;

    #[test]
    fn profile_rejects_tag_or_seed_mismatch() {
        let mut profile = Manifest {
            id: "minimum".to_owned(),
            server_version: "2.26.0".to_owned(),
            seed_version: "2.26.0".to_owned(),
            image: format!(
                "ghcr.io/advplyr/audiobookshelf:2.26.0@sha256:{}",
                "a".repeat(64)
            ),
        };
        assert!(profile.validate(Profile::Minimum).is_ok());
        profile.seed_version = "2.37.0".to_owned();
        assert!(profile.validate(Profile::Minimum).is_err());
        profile.seed_version = "2.26.0".to_owned();
        profile.image = profile.image.replace(":2.26.0@", ":latest@");
        assert!(profile.validate(Profile::Minimum).is_err());
    }

    #[test]
    fn redaction_rejects_raw_credentials_before_publishing() {
        let mut payload = json!({
            "user": {"id": "real-user", "username": "live-name", "accessToken": "token-value-123"},
            "nested": [{"password": "password-value-123", "mediaPath": "/private/media"}]
        });
        redact(&mut payload, true);
        assert_eq!(payload["user"]["username"], "fixture-root");
        assert_eq!(payload["user"]["id"], "fixture-user");
        assert_eq!(payload["user"]["accessToken"], "[REDACTED]");
        assert_eq!(payload["nested"][0]["mediaPath"], "[REDACTED]");
        let directory = tempfile::tempdir().expect("create fixture test directory");
        assert!(
            write_fixtures(
                directory.path(),
                "2.26.0",
                &[("login", payload)],
                &["live-name", "password-value-123", "token-value-123"]
            )
            .is_ok()
        );
        assert!(
            write_fixtures(
                directory.path(),
                "2.26.0",
                &[("login", json!({"unexpected": "token-value-123"}))],
                &["token-value-123"]
            )
            .is_err()
        );
    }
}
