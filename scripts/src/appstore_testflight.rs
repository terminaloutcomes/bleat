//! Exact-build TestFlight status and release through Apple's checked-in OpenAPI.
//! No tester identities, credentials, or remote error messages enter diagnostics.

use clap::Parser;
use reqwest::{Client, Method};
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use serde_json::json;
use thiserror::Error;
use url::Url;

use crate::app_store_connect::{CliOpts, generate_app_store_token};
use crate::appstore_builds::{BuildStatusArgs, BuildStatusError, ProcessingState, fetch_build};

#[derive(Clone, Debug, Parser)]
pub struct GroupArgs {
    #[arg(long, env = "APPSTORE_CONNECT_APP_ID", hide_env_values = true)]
    pub app_id: String,
}

#[derive(Clone, Debug, Parser)]
pub struct ReleaseArgs {
    #[command(flatten)]
    pub build: BuildStatusArgs,
    /// Existing app-owned beta group IDs; no groups or testers are created.
    #[arg(long, required = true)]
    pub group_id: Vec<String>,
    #[arg(long)]
    pub locale: String,
    #[arg(long)]
    pub whats_new: String,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum BetaState {
    Processing,
    ProcessingException,
    MissingExportCompliance,
    ReadyForBetaTesting,
    InBetaTesting,
    Expired,
    ReadyForBetaSubmission,
    InExportComplianceReview,
    WaitingForBetaReview,
    InBetaReview,
    BetaRejected,
    BetaApproved,
    NotApplicable,
    #[serde(other)]
    Unsupported,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BetaStates {
    pub internal_build_state: BetaState,
    pub external_build_state: BetaState,
}

#[derive(Debug, Serialize)]
pub struct Group {
    pub id: String,
    pub name: String,
    pub is_internal: bool,
}

#[derive(Debug, Serialize)]
pub struct Status {
    pub version: String,
    pub build: String,
    pub build_id: Option<String>,
    pub processing_state: ProcessingState,
    pub beta: Option<BetaStates>,
    pub assigned_groups: Vec<Group>,
}

#[derive(Clone, Copy, Debug, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Stage {
    Configuration,
    BuildLookup,
    BetaStatus,
    AppGroups,
    AssignedGroups,
    ReleaseValidation,
    Localizations,
    SaveNotes,
    SubmitReview,
    AssignGroup,
}

#[derive(Debug, Error)]
pub enum Cause {
    #[error("build lookup failed: {0}")]
    Build(#[from] BuildStatusError),
    #[error("invalid API URL")]
    Url,
    #[error("could not create HTTP client")]
    Client(#[source] reqwest::Error),
    #[error("Apple request timed out")]
    Timeout(#[source] reqwest::Error),
    #[error("could not connect to Apple")]
    Connection(#[source] reqwest::Error),
    #[error("Apple request failed; inspect status before retrying a mutation")]
    Request(#[source] reqwest::Error),
    #[error("Apple rejected the request (HTTP {status})")]
    Http {
        status: u16,
        codes: Vec<String>,
        parameters: Vec<String>,
    },
    #[error("Apple returned invalid or incomplete metadata")]
    Decode(#[source] reqwest::Error),
    #[error("Apple omitted attributes")]
    MissingAttributes,
    #[error("Apple omitted the internal beta state")]
    MissingInternalState,
    #[error("Apple omitted the external beta state")]
    MissingExternalState,
    #[error("Apple omitted the group name")]
    MissingGroupName,
    #[error("Apple omitted the internal/external group kind")]
    MissingGroupKind,
    #[error("Apple returned an incomplete list")]
    Incomplete,
    #[error("identifier, locale, and release notes must be nonempty")]
    EmptyInput,
    #[error("group IDs must be distinct")]
    DuplicateGroup,
    #[error("the exact build is not ready: {0:?}")]
    BuildNotReady(ProcessingState),
    #[error("requested group does not belong to this app")]
    UnknownGroup,
    #[error("external testing is blocked by {0:?}")]
    ExternalNotReady(BetaState),
    #[error("internal testing is blocked by {0:?}")]
    InternalNotReady(BetaState),
    #[error("Apple returned duplicate locale records")]
    AmbiguousLocale,
    #[error("group assignment was not visible after the mutation; inspect status before retrying")]
    AssignmentUnconfirmed,
}

#[derive(Debug, Error)]
#[error("{stage:?}: {cause}")]
pub struct Failure {
    pub stage: Stage,
    #[source]
    pub cause: Cause,
}

impl Failure {
    pub fn diagnostic(&self) -> serde_json::Value {
        let code = match &self.cause {
            Cause::Build(error) => error.code(),
            Cause::Http { status, .. } => format!("http_{status}"),
            Cause::Url => "invalid_url".into(),
            Cause::Client(_) => "http_client".into(),
            Cause::Timeout(_) => "request_timeout".into(),
            Cause::Connection(_) => "connection_failed".into(),
            Cause::Request(_) => "request_uncertain".into(),
            Cause::Decode(_) => "invalid_response".into(),
            Cause::MissingAttributes => "missing_attributes".into(),
            Cause::MissingInternalState => "missing_internal_beta_state".into(),
            Cause::MissingExternalState => "missing_external_beta_state".into(),
            Cause::MissingGroupName => "missing_group_name".into(),
            Cause::MissingGroupKind => "missing_group_kind".into(),
            Cause::Incomplete => "incomplete_response".into(),
            Cause::EmptyInput => "empty_input".into(),
            Cause::DuplicateGroup => "duplicate_group".into(),
            Cause::BuildNotReady(state) => format!("build_{state:?}"),
            Cause::UnknownGroup => "group_not_owned_by_app".into(),
            Cause::ExternalNotReady(state) => format!("external_{state:?}"),
            Cause::InternalNotReady(state) => format!("internal_{state:?}"),
            Cause::AmbiguousLocale => "ambiguous_locale".into(),
            Cause::AssignmentUnconfirmed => "assignment_unconfirmed".into(),
        };
        let mut diagnostic = json!({"stage": self.stage, "code": code});
        if let Cause::Http {
            codes, parameters, ..
        } = &self.cause
        {
            diagnostic["apple_codes"] = json!(codes);
            if !parameters.is_empty() {
                diagnostic["parameters"] = json!(parameters);
            }
        }
        diagnostic
    }
}

fn failure(stage: Stage, cause: Cause) -> Failure {
    Failure { stage, cause }
}

#[derive(Deserialize)]
struct Resource<T> {
    id: String,
    attributes: Option<T>,
}
#[derive(Deserialize)]
struct Single<T> {
    data: Resource<T>,
}
#[derive(Deserialize)]
struct Page<T> {
    data: Vec<T>,
    links: Option<Links>,
}
#[derive(Deserialize)]
struct Links {
    next: Option<String>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct GroupAttributes {
    name: Option<String>,
    is_internal_group: Option<bool>,
}
#[derive(Deserialize)]
struct Localization {
    locale: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct BetaAttributes {
    internal_build_state: Option<BetaState>,
    external_build_state: Option<BetaState>,
}

#[derive(Deserialize)]
struct ErrorResponse {
    errors: Vec<AppleError>,
}
#[derive(Deserialize)]
struct AppleError {
    code: String,
    source: Option<ErrorSource>,
}
#[derive(Deserialize)]
struct ErrorSource {
    parameter: Option<String>,
}

pub struct Api {
    client: Client,
    token: String,
    base: Url,
}

impl Api {
    pub fn production(options: &CliOpts) -> Result<Self, Failure> {
        let token = generate_app_store_token(options).map_err(|e| {
            failure(
                Stage::Configuration,
                Cause::Build(BuildStatusError::Token(e)),
            )
        })?;
        let base = Url::parse("https://api.appstoreconnect.apple.com/v1/")
            .map_err(|_| failure(Stage::Configuration, Cause::Url))?;
        Self::new(token, base)
    }

    pub fn new(token: String, base: Url) -> Result<Self, Failure> {
        let client = Client::builder()
            .timeout(std::time::Duration::from_secs(45))
            .build()
            .map_err(|e| failure(Stage::Configuration, Cause::Client(e)))?;
        Ok(Self {
            client,
            token,
            base,
        })
    }

    async fn request(
        &self,
        stage: Stage,
        method: Method,
        path: &[&str],
        query: &[(&str, &str)],
        body: Option<serde_json::Value>,
    ) -> Result<reqwest::Response, Failure> {
        let mut url = self.base.clone();
        url.path_segments_mut()
            .map_err(|_| failure(stage, Cause::Url))?
            .pop_if_empty()
            .extend(path);
        url.query_pairs_mut().extend_pairs(query.iter().copied());
        let mut request = self.client.request(method, url).bearer_auth(&self.token);
        if let Some(body) = body {
            request = request.json(&body);
        }
        let response = request.send().await.map_err(|e| {
            let cause = if e.is_timeout() {
                Cause::Timeout(e)
            } else if e.is_connect() {
                Cause::Connection(e)
            } else {
                Cause::Request(e)
            };
            failure(stage, cause)
        })?;
        if !response.status().is_success() {
            let status = response.status().as_u16();
            let errors = response
                .json::<ErrorResponse>()
                .await
                .map(|body| body.errors)
                .unwrap_or_default();
            let parameters = errors
                .iter()
                .filter_map(|error| error.source.as_ref()?.parameter.as_ref())
                .filter(|parameter| {
                    matches!(
                        parameter.as_str(),
                        "filter[app]" | "filter[builds]" | "limit"
                    )
                })
                .cloned()
                .collect();
            let codes = errors
                .into_iter()
                .map(|error| error.code)
                .filter(|code| {
                    !code.is_empty()
                        && code.len() <= 128
                        && code.chars().all(|character| {
                            character.is_ascii_uppercase()
                                || character.is_ascii_digit()
                                || matches!(character, '.' | '_')
                        })
                })
                .collect();
            return Err(failure(
                stage,
                Cause::Http {
                    status,
                    codes,
                    parameters,
                },
            ));
        }
        Ok(response)
    }

    async fn get<T: DeserializeOwned>(
        &self,
        stage: Stage,
        path: &[&str],
        query: &[(&str, &str)],
    ) -> Result<T, Failure> {
        self.request(stage, Method::GET, path, query, None)
            .await?
            .json()
            .await
            .map_err(|e| failure(stage, Cause::Decode(e)))
    }

    async fn groups(
        &self,
        stage: Stage,
        path: &[&str],
        query: &[(&str, &str)],
    ) -> Result<Vec<Group>, Failure> {
        let mut query = query.to_vec();
        query.push(("limit", "200"));
        let page: Page<Resource<GroupAttributes>> = self.get(stage, path, &query).await?;
        if page.links.and_then(|links| links.next).is_some() {
            return Err(failure(stage, Cause::Incomplete));
        }
        page.data
            .into_iter()
            .map(|resource| {
                let attrs = resource
                    .attributes
                    .ok_or_else(|| failure(stage, Cause::MissingAttributes))?;
                Ok(Group {
                    id: resource.id,
                    name: attrs
                        .name
                        .ok_or_else(|| failure(stage, Cause::MissingGroupName))?,
                    is_internal: attrs
                        .is_internal_group
                        .ok_or_else(|| failure(stage, Cause::MissingGroupKind))?,
                })
            })
            .collect()
    }

    pub async fn app_groups(&self, app: &str) -> Result<Vec<Group>, Failure> {
        if app.trim().is_empty() {
            return Err(failure(Stage::AppGroups, Cause::EmptyInput));
        }
        self.groups(Stage::AppGroups, &["apps", app, "betaGroups"], &[])
            .await
    }

    pub async fn status(&self, args: &BuildStatusArgs) -> Result<Status, Failure> {
        let build = fetch_build(args, &self.token, &self.base)
            .await
            .map_err(|e| failure(Stage::BuildLookup, Cause::Build(e)))?;
        let mut status = Status {
            version: args.version.clone(),
            build: args.build.clone(),
            build_id: None,
            processing_state: ProcessingState::NotFound,
            beta: None,
            assigned_groups: vec![],
        };
        if let Some(build) = build {
            status.processing_state = build.processing_state;
            if build.processing_state == ProcessingState::Valid {
                let detail: Single<BetaAttributes> = self
                    .get(
                        Stage::BetaStatus,
                        &["builds", &build.id, "buildBetaDetail"],
                        &[],
                    )
                    .await?;
                let attributes = detail
                    .data
                    .attributes
                    .ok_or_else(|| failure(Stage::BetaStatus, Cause::MissingAttributes))?;
                status.beta = Some(BetaStates {
                    internal_build_state: attributes
                        .internal_build_state
                        .ok_or_else(|| failure(Stage::BetaStatus, Cause::MissingInternalState))?,
                    external_build_state: attributes
                        .external_build_state
                        .ok_or_else(|| failure(Stage::BetaStatus, Cause::MissingExternalState))?,
                });
                status.assigned_groups = self
                    // Exact build lookup already verifies app ownership. Apple's live
                    // collection rejects combining filter[app] with filter[builds].
                    .groups(
                        Stage::AssignedGroups,
                        &["betaGroups"],
                        &[("filter[builds]", &build.id)],
                    )
                    .await?;
            }
            status.build_id = Some(build.id);
        }
        Ok(status)
    }

    /// Reconcile existing group membership and submit only a ready external build.
    /// No automatic retry follows an ambiguous mutation or incomplete read.
    pub async fn release(&self, args: &ReleaseArgs) -> Result<Status, Failure> {
        if args.group_id.is_empty()
            || args.group_id.iter().any(|id| id.trim().is_empty())
            || args.locale.trim().is_empty()
            || args.whats_new.trim().is_empty()
        {
            return Err(failure(Stage::ReleaseValidation, Cause::EmptyInput));
        }
        if args
            .group_id
            .iter()
            .collect::<std::collections::BTreeSet<_>>()
            .len()
            != args.group_id.len()
        {
            return Err(failure(Stage::ReleaseValidation, Cause::DuplicateGroup));
        }
        let status = self.status(&args.build).await?;
        if status.processing_state != ProcessingState::Valid {
            return Err(failure(
                Stage::ReleaseValidation,
                Cause::BuildNotReady(status.processing_state),
            ));
        }
        let id = status.build_id.as_deref().ok_or_else(|| {
            failure(
                Stage::BuildLookup,
                Cause::BuildNotReady(ProcessingState::NotFound),
            )
        })?;
        let groups = self.app_groups(&args.build.app_id).await?;
        let selected = args
            .group_id
            .iter()
            .map(|id| {
                groups
                    .iter()
                    .find(|group| &group.id == id)
                    .ok_or_else(|| failure(Stage::ReleaseValidation, Cause::UnknownGroup))
            })
            .collect::<Result<Vec<_>, _>>()?;
        let external = selected.iter().any(|group| !group.is_internal);
        let beta = status
            .beta
            .as_ref()
            .ok_or_else(|| failure(Stage::BetaStatus, Cause::MissingAttributes))?;
        if selected.iter().any(|group| group.is_internal)
            && !matches!(
                beta.internal_build_state,
                BetaState::ReadyForBetaTesting | BetaState::InBetaTesting
            )
        {
            return Err(failure(
                Stage::ReleaseValidation,
                Cause::InternalNotReady(beta.internal_build_state),
            ));
        }
        if external
            && !matches!(
                beta.external_build_state,
                BetaState::ReadyForBetaSubmission
                    | BetaState::WaitingForBetaReview
                    | BetaState::InBetaReview
                    | BetaState::BetaApproved
                    | BetaState::ReadyForBetaTesting
                    | BetaState::InBetaTesting
            )
        {
            return Err(failure(
                Stage::ReleaseValidation,
                Cause::ExternalNotReady(beta.external_build_state),
            ));
        }
        let locales: Page<Resource<Localization>> = self
            .get(
                Stage::Localizations,
                &["betaBuildLocalizations"],
                &[("filter[build]", id), ("limit", "200")],
            )
            .await?;
        if locales.links.and_then(|links| links.next).is_some() {
            return Err(failure(Stage::Localizations, Cause::Incomplete));
        }
        let mut matching = vec![];
        for entry in locales.data {
            let attrs = entry
                .attributes
                .ok_or_else(|| failure(Stage::Localizations, Cause::MissingAttributes))?;
            if attrs.locale == args.locale {
                matching.push(entry.id);
            }
        }
        let attributes = json!({"locale": args.locale, "whatsNew": args.whats_new});
        match matching.as_slice() {
            [] => {
                self.request(Stage::SaveNotes, Method::POST, &["betaBuildLocalizations"], &[], Some(json!({"data":{"type":"betaBuildLocalizations","attributes":attributes,"relationships":{"build":{"data":{"type":"builds","id":id}}}}}))).await?;
            }
            [locale_id] => {
                self.request(Stage::SaveNotes, Method::PATCH, &["betaBuildLocalizations", locale_id], &[], Some(json!({"data":{"type":"betaBuildLocalizations","id":locale_id,"attributes":{"whatsNew":args.whats_new}}}))).await?;
            }
            _ => return Err(failure(Stage::Localizations, Cause::AmbiguousLocale)),
        }
        if external && beta.external_build_state == BetaState::ReadyForBetaSubmission {
            self.request(Stage::SubmitReview, Method::POST, &["betaAppReviewSubmissions"], &[], Some(json!({"data":{"type":"betaAppReviewSubmissions","relationships":{"build":{"data":{"type":"builds","id":id}}}}}))).await?;
        }
        for group in selected {
            if !status
                .assigned_groups
                .iter()
                .any(|assigned| assigned.id == group.id)
            {
                self.request(
                    Stage::AssignGroup,
                    Method::POST,
                    &["betaGroups", &group.id, "relationships", "builds"],
                    &[],
                    Some(json!({"data":[{"type":"builds","id":id}]})),
                )
                .await?;
            }
        }
        let final_status = self.status(&args.build).await?;
        if !args.group_id.iter().all(|id| {
            final_status
                .assigned_groups
                .iter()
                .any(|group| &group.id == id)
        }) {
            return Err(failure(Stage::AssignGroup, Cause::AssignmentUnconfirmed));
        }
        Ok(final_status)
    }
}
