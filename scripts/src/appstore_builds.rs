//! Read processing state for an exact iOS App Store Connect build.

use clap::Parser;
use reqwest::Client;
use serde::{Deserialize, Serialize};
use thiserror::Error;
use url::Url;

use crate::app_store_connect::{AppStoreTokenError, CliOpts, generate_app_store_token};
use crate::appstore::types::{Build, BuildAttributesProcessingState, PrereleaseVersion};

#[derive(Clone, Debug, Parser)]
pub struct BuildStatusArgs {
    #[arg(long, env = "APPSTORE_CONNECT_APP_ID", hide_env_values = true)]
    pub app_id: String,
    #[arg(long)]
    pub version: String,
    #[arg(long)]
    pub build: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ProcessingState {
    NotFound,
    Processing,
    Valid,
    Failed,
    Invalid,
}

#[derive(Debug, PartialEq, Eq, Serialize)]
pub struct BuildStatus {
    pub version: String,
    pub build: String,
    pub processing_state: ProcessingState,
}

#[derive(Debug)]
pub struct ResolvedBuild {
    pub id: String,
    pub processing_state: ProcessingState,
}

#[derive(Debug, Error)]
pub enum BuildStatusError {
    #[error(transparent)]
    Token(#[from] AppStoreTokenError),
    #[error("app, version, and build must be nonempty")]
    EmptyIdentifier,
    #[error("build must contain one to three nonnegative integer components")]
    InvalidBuildArgument,
    #[error("Apple returned an invalid build number")]
    InvalidRemoteBuild,
    #[error("invalid App Store Connect base URL")]
    Url,
    #[error("could not create the Apple HTTP client")]
    Client(#[source] reqwest::Error),
    #[error("Apple build-status request timed out")]
    Timeout(#[source] reqwest::Error),
    #[error("could not connect to Apple")]
    Connection(#[source] reqwest::Error),
    #[error("Apple build-status request failed")]
    Request(#[source] reqwest::Error),
    #[error("Apple rejected the build-status request (HTTP {0})")]
    Http(u16),
    #[error("Apple returned an invalid build-status response")]
    Decode(#[source] reqwest::Error),
    #[error("Apple omitted the build number")]
    MissingBuild,
    #[error("Apple omitted the associated release version")]
    MissingVersion,
    #[error("Apple omitted the processing state")]
    MissingState,
    #[error("Apple returned multiple matching builds")]
    Ambiguous,
    #[error("Apple returned an incomplete build list")]
    Incomplete,
}

impl BuildStatusError {
    pub fn code(&self) -> String {
        if let Self::Http(status) = self {
            return format!("http_{status}");
        }
        match self {
            Self::Token(AppStoreTokenError::Configuration(_)) => "missing_configuration",
            Self::Token(AppStoreTokenError::KeyEncoding) => "invalid_key_encoding",
            Self::Token(AppStoreTokenError::PrivateKey) => "invalid_private_key",
            Self::Token(AppStoreTokenError::Signing) => "token_signing_failed",
            Self::EmptyIdentifier => "empty_identifier",
            Self::InvalidBuildArgument => "invalid_build_argument",
            Self::InvalidRemoteBuild => "invalid_remote_build_number",
            Self::Url => "invalid_url",
            Self::Client(_) => "http_client",
            Self::Timeout(_) => "request_timeout",
            Self::Connection(_) => "connection_failed",
            Self::Request(_) => "request_failed",
            Self::Http(_) => "http_rejected",
            Self::Decode(_) => "invalid_response",
            Self::MissingBuild => "missing_build_number",
            Self::MissingVersion => "missing_release_version",
            Self::MissingState => "missing_processing_state",
            Self::Ambiguous => "ambiguous_build",
            Self::Incomplete => "incomplete_response",
        }
        .into()
    }
}

#[derive(Deserialize)]
struct BuildPage {
    data: Vec<Build>,
    #[serde(default)]
    included: Vec<PrereleaseVersion>,
    links: Option<PageLinks>,
}

#[derive(Deserialize)]
struct PageLinks {
    next: Option<String>,
}

fn build_components(value: &str) -> Option<[u64; 3]> {
    crate::release_versions::validate_build_number(value).ok()?;
    let mut components = [0; 3];
    for (value, component) in value.split('.').zip(components.iter_mut()) {
        *component = value.parse().ok()?;
    }
    Some(components)
}

pub async fn build_status(
    args: &BuildStatusArgs,
    options: &CliOpts,
) -> Result<BuildStatus, BuildStatusError> {
    let token = generate_app_store_token(options)?;
    let base = Url::parse("https://api.appstoreconnect.apple.com/v1/")
        .map_err(|_| BuildStatusError::Url)?;
    fetch_status(args, &token, &base).await
}

pub async fn fetch_status(
    args: &BuildStatusArgs,
    token: &str,
    base: &Url,
) -> Result<BuildStatus, BuildStatusError> {
    let resolved = fetch_build(args, token, base).await?;
    Ok(BuildStatus {
        version: args.version.clone(),
        build: args.build.clone(),
        processing_state: resolved
            .map_or(ProcessingState::NotFound, |build| build.processing_state),
    })
}

pub async fn fetch_build(
    args: &BuildStatusArgs,
    token: &str,
    base: &Url,
) -> Result<Option<ResolvedBuild>, BuildStatusError> {
    if [&args.app_id, &args.version, &args.build]
        .iter()
        .any(|value| value.trim().is_empty())
    {
        return Err(BuildStatusError::EmptyIdentifier);
    }
    // Apple's CFBundleVersion integer components ignore leading zeros and
    // interpret missing components as zero. Compare decoded numeric values.
    // https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleversion
    let requested_build =
        build_components(&args.build).ok_or(BuildStatusError::InvalidBuildArgument)?;
    let query_build = requested_build
        .iter()
        .take(args.build.split('.').count())
        .map(u64::to_string)
        .collect::<Vec<_>>()
        .join(".");
    // Query parameters follow the checked-in Apple OpenAPI /v1/builds contract.
    let mut url = base.join("builds").map_err(|_| BuildStatusError::Url)?;
    url.query_pairs_mut().extend_pairs([
        ("filter[app]", args.app_id.as_str()),
        ("filter[version]", query_build.as_str()),
        ("filter[preReleaseVersion.version]", args.version.as_str()),
        ("filter[preReleaseVersion.platform]", "IOS"),
        ("include", "preReleaseVersion"),
    ]);
    let client = Client::builder()
        .timeout(std::time::Duration::from_secs(45))
        .build()
        .map_err(BuildStatusError::Client)?;
    let response = client
        .get(url)
        .bearer_auth(token)
        .send()
        .await
        .map_err(|error| {
            if error.is_timeout() {
                BuildStatusError::Timeout(error)
            } else if error.is_connect() {
                BuildStatusError::Connection(error)
            } else {
                BuildStatusError::Request(error)
            }
        })?;
    if !response.status().is_success() {
        return Err(BuildStatusError::Http(response.status().as_u16()));
    }
    let page: BuildPage = response.json().await.map_err(BuildStatusError::Decode)?;
    if page.links.and_then(|links| links.next).is_some() {
        return Err(BuildStatusError::Incomplete);
    }
    let mut resolved = None;
    for build in page.data {
        let attributes = build.attributes.ok_or(BuildStatusError::MissingBuild)?;
        let number = attributes.version.ok_or(BuildStatusError::MissingBuild)?;
        let remote_build = build_components(&number).ok_or(BuildStatusError::InvalidRemoteBuild)?;
        if remote_build != requested_build {
            continue;
        }
        let version_id = build
            .relationships
            .and_then(|relationships| relationships.pre_release_version)
            .and_then(|relationship| relationship.data)
            .ok_or(BuildStatusError::MissingVersion)?
            .id;
        let version = page
            .included
            .iter()
            .find(|version| version.id == version_id)
            .and_then(|version| version.attributes.as_ref())
            .and_then(|attributes| attributes.version.as_ref())
            .ok_or(BuildStatusError::MissingVersion)?;
        if version != &args.version {
            continue;
        }
        if resolved.is_some() {
            return Err(BuildStatusError::Ambiguous);
        }
        let processing_state = match attributes
            .processing_state
            .ok_or(BuildStatusError::MissingState)?
        {
            BuildAttributesProcessingState::Processing => ProcessingState::Processing,
            BuildAttributesProcessingState::Valid => ProcessingState::Valid,
            BuildAttributesProcessingState::Failed => ProcessingState::Failed,
            BuildAttributesProcessingState::Invalid => ProcessingState::Invalid,
        };
        resolved = Some(ResolvedBuild {
            id: build.id,
            processing_state,
        });
    }
    Ok(resolved)
}
