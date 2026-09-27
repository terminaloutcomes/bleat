//! Daily App Store Connect analytics report lifecycle and local dump.
use async_compression::tokio::bufread::GzipDecoder;
use base64::Engine;
use chrono::{Datelike, NaiveDate, Utc};
use jsonwebtoken::{Algorithm, EncodingKey, Header, encode};
use md5::{Digest, Md5};
use reqwest::{Client, StatusCode, Url};
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use std::{
    collections::{BTreeMap, BTreeSet},
    ffi::OsString,
    path::{Path, PathBuf},
};
use thiserror::Error;
use tokio::{
    fs,
    io::{AsyncReadExt, AsyncWriteExt, BufReader},
};

const BASE: &str = "https://api.appstoreconnect.apple.com/v1/";
const DOWNLOAD_DIR_ENV: &str = "APPSTORE_CONNECT_DOWNLOAD_DIR";

pub fn download_dir_from_env() -> Result<PathBuf, AnalyticsError> {
    parse_download_dir(std::env::var_os(DOWNLOAD_DIR_ENV))
}

fn parse_download_dir(value: Option<OsString>) -> Result<PathBuf, AnalyticsError> {
    let path = value
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .ok_or(AnalyticsError::Configuration(DOWNLOAD_DIR_ENV))?;
    if !path.is_absolute() {
        return Err(AnalyticsError::Configuration(
            "APPSTORE_CONNECT_DOWNLOAD_DIR must be an absolute path",
        ));
    }
    Ok(path)
}

fn snapshot_manifest_path(dir: &Path) -> PathBuf {
    dir.join("snapshots.json")
}

#[derive(Debug, Error)]
pub enum AnalyticsError {
    #[error("missing configuration: {0}")]
    Configuration(&'static str),
    #[error("invalid private key encoding")]
    KeyEncoding,
    #[error("invalid private key")]
    PrivateKey,
    #[error("unable to sign App Store Connect token")]
    Signing,
    #[error("Apple denied the requested operation (HTTP {0})")]
    Authorization(u16),
    #[error("Apple API returned HTTP {0}")]
    Api(u16),
    #[error("network operation failed: {0}")]
    Network(#[from] reqwest::Error),
    #[error("invalid Apple API response: {0}")]
    Response(#[from] serde_json::Error),
    #[error("invalid API pagination link")]
    Pagination,
    #[error("request state is incomplete")]
    RequestState,
    #[error("daily report instance has a missing or invalid processing date")]
    ProcessingDate,
    #[error("no suitable report request exists")]
    NoRequest,
    #[error("report segment metadata is incomplete")]
    SegmentMetadata,
    #[error("downloaded segment has incorrect size")]
    SizeMismatch,
    #[error("downloaded segment has incorrect MD5 checksum")]
    ChecksumMismatch,
    #[error("segment URL expired after refresh")]
    ExpiredUrl,
    #[error("segment parsing failed: {0}")]
    Parse(&'static str),
    #[error("Downloads report has a missing column: {0}")]
    MissingDownloadColumn(&'static str),
    #[error("Downloads report has an invalid value in: {0}")]
    InvalidDownloadValue(&'static str),
    #[error("Downloads report contains an unsupported download type")]
    UnsupportedDownloadType,
    #[error("Discovery and Engagement report has a missing column: {0}")]
    MissingDiscoveryColumn(&'static str),
    #[error("Discovery and Engagement report has an invalid value in: {0}")]
    InvalidDiscoveryValue(&'static str),
    #[error("Discovery and Engagement report contains an unsupported event")]
    UnsupportedDiscoveryEvent,
    #[error("Purchases report has a missing column: {0}")]
    MissingPurchaseColumn(&'static str),
    #[error("Purchases report has an invalid value in: {0}")]
    InvalidPurchaseValue(&'static str),
    #[error("Purchases report contains an unsupported purchase type")]
    UnsupportedPurchaseType,
    #[error("paying users cannot be added across dimensional rows")]
    NonAdditivePayingUsers,
    #[error("unique counts cannot be added across dimensional rows")]
    NonAdditiveUniqueCounts,
    #[error("Installations and Deletions report has a missing column: {0}")]
    MissingInstallationColumn(&'static str),
    #[error("Installations and Deletions report has an invalid value in: {0}")]
    InvalidInstallationValue(&'static str),
    #[error("Installations and Deletions report contains an unsupported event")]
    UnsupportedInstallationEvent,
    #[error("Installations and Deletions report contains an unsupported download type")]
    UnsupportedInstallationDownloadType,
    #[error("App Sessions report has a missing column: {0}")]
    MissingSessionColumn(&'static str),
    #[error("App Sessions report has an invalid value in: {0}")]
    InvalidSessionValue(&'static str),
    #[error("App Crashes report has a missing column: {0}")]
    MissingCrashColumn(&'static str),
    #[error("App Crashes report has an invalid value in: {0}")]
    InvalidCrashValue(&'static str),
    #[error("unique devices cannot be added across dimensional rows")]
    NonAdditiveUniqueDevices,
    #[error("install and delete counts cannot be combined")]
    MixedInstallationEvents,
    #[error("Standard and Detailed report counts cannot be combined")]
    MixedReportVariants,
    #[error("local storage failed: {0}")]
    Storage(#[from] std::io::Error),
}

#[derive(clap::ValueEnum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum AccessType {
    Ongoing,
    OneTimeSnapshot,
}
impl AccessType {
    fn api(self) -> &'static str {
        match self {
            Self::Ongoing => "ONGOING",
            Self::OneTimeSnapshot => "ONE_TIME_SNAPSHOT",
        }
    }
}

#[derive(Serialize)]
struct Claims {
    iss: String,
    iat: i64,
    exp: i64,
    aud: &'static str,
}

pub struct AnalyticsClient {
    http: Client,
    signing_key: EncodingKey,
    key_id: String,
    issuer: String,
    base: Url,
    app_id: String,
}
impl AnalyticsClient {
    pub fn from_env() -> Result<Self, AnalyticsError> {
        let issuer = std::env::var("APPSTORE_CONNECT_ISSUER_ID")
            .map_err(|_| AnalyticsError::Configuration("APPSTORE_CONNECT_ISSUER_ID"))?;
        let key_id = std::env::var("APPSTORE_CONNECT_KEY_ID")
            .map_err(|_| AnalyticsError::Configuration("APPSTORE_CONNECT_KEY_ID"))?;
        let key = std::env::var("APPSTORE_CONNECT_PRIVATE_KEY_BASE64")
            .map_err(|_| AnalyticsError::Configuration("APPSTORE_CONNECT_PRIVATE_KEY_BASE64"))?;
        let app_id = std::env::var("APPSTORE_CONNECT_APP_ID")
            .map_err(|_| AnalyticsError::Configuration("APPSTORE_CONNECT_APP_ID"))?;
        if issuer.is_empty() || key_id.is_empty() || key.is_empty() || app_id.is_empty() {
            return Err(AnalyticsError::Configuration(
                "nonempty App Store Connect environment variables",
            ));
        }
        let key = base64::engine::general_purpose::STANDARD
            .decode(key)
            .map_err(|_| AnalyticsError::KeyEncoding)?;
        let signing_key = EncodingKey::from_ec_pem(&key).map_err(|_| AnalyticsError::PrivateKey)?;
        Ok(Self {
            http: Client::builder().no_gzip().build()?,
            signing_key,
            key_id,
            issuer,
            base: Url::parse(BASE).map_err(|_| AnalyticsError::Pagination)?,
            app_id,
        })
    }
    fn token(&self) -> Result<String, AnalyticsError> {
        let mut header = Header::new(Algorithm::ES256);
        header.kid = Some(self.key_id.clone());
        let now = Utc::now().timestamp();
        encode(
            &header,
            &Claims {
                iss: self.issuer.clone(),
                iat: now,
                exp: now + 600,
                aud: "appstoreconnect-v1",
            },
            &self.signing_key,
        )
        .map_err(|_| AnalyticsError::Signing)
    }
    fn url(&self, path: &str) -> Result<Url, AnalyticsError> {
        self.base.join(path).map_err(|_| AnalyticsError::Pagination)
    }
    async fn get<T: DeserializeOwned>(&self, url: Url) -> Result<T, AnalyticsError> {
        let response = self.http.get(url).bearer_auth(self.token()?).send().await?;
        let response = checked(response).await?;
        Ok(response.json().await?)
    }
    async fn pages<T: DeserializeOwned>(&self, path: &str) -> Result<Vec<T>, AnalyticsError> {
        let mut next = Some(self.url(path)?);
        let mut seen = BTreeSet::new();
        let mut all = Vec::new();
        while let Some(url) = next.take() {
            if !seen.insert(url.to_string()) {
                return Err(AnalyticsError::Pagination);
            }
            let page: Page<T> = self.get(url).await?;
            all.extend(page.data);
            next = page
                .links
                .next
                .map(|link| {
                    let parsed = Url::parse(&link).map_err(|_| AnalyticsError::Pagination)?;
                    if parsed.origin() != self.base.origin() {
                        return Err(AnalyticsError::Pagination);
                    }
                    Ok(parsed)
                })
                .transpose()?;
        }
        Ok(all)
    }
    async fn requests(&self) -> Result<Vec<Resource>, AnalyticsError> {
        self.pages(&format!(
            "apps/{}/analyticsReportRequests?limit=200",
            self.app_id
        ))
        .await
    }
    async fn create(&self, access: AccessType) -> Result<String, AnalyticsError> {
        let body = serde_json::json!({"data":{"type":"analyticsReportRequests","attributes":{"accessType":access.api()},"relationships":{"app":{"data":{"type":"apps","id":self.app_id}}}}});
        let response = self
            .http
            .post(self.url("analyticsReportRequests")?)
            .bearer_auth(self.token()?)
            .json(&body)
            .send()
            .await?;
        let response = checked(response).await?;
        let result: Single<Resource> = response.json().await?;
        Ok(result.data.id)
    }
    pub async fn create_report(&self) -> Result<String, AnalyticsError> {
        if let Some(existing) = self
            .requests()
            .await?
            .into_iter()
            .filter(|r| {
                r.access() == Some(AccessType::Ongoing)
                    && r.attributes.stopped_due_to_inactivity != Some(true)
            })
            .min_by(|a, b| a.id.cmp(&b.id))
        {
            return Ok(existing.id);
        }
        self.create(AccessType::Ongoing).await
    }
    pub async fn one_time_snapshot(&self, dir: &Path) -> Result<String, AnalyticsError> {
        let month = current_month();
        let path = snapshot_manifest_path(dir);
        let mut snapshots: BTreeMap<String, String> = load_json_or_default(&path).await?;
        let requests = self.requests().await?;
        if let Some(id) = snapshots.get(&month)
            && requests
                .iter()
                .any(|r| &r.id == id && r.access() == Some(AccessType::OneTimeSnapshot))
        {
            return Ok(id.clone());
        }
        let id = self.create(AccessType::OneTimeSnapshot).await?;
        snapshots.insert(month, id.clone());
        atomic_json(&path, &snapshots).await?;
        Ok(id)
    }
    pub async fn download_reports(
        &self,
        access: AccessType,
        dir: &Path,
    ) -> Result<usize, AnalyticsError> {
        let requests = self.requests().await?;
        let snapshot_id = if access == AccessType::OneTimeSnapshot {
            load_json_or_default::<BTreeMap<String, String>>(&snapshot_manifest_path(dir))
                .await?
                .get(&current_month())
                .cloned()
        } else {
            None
        };
        let candidates: Vec<_> = requests
            .into_iter()
            .filter(|r| {
                r.access() == Some(access)
                    && (access != AccessType::Ongoing
                        || r.attributes.stopped_due_to_inactivity != Some(true))
            })
            .filter(|r| snapshot_id.as_ref().is_none_or(|id| &r.id == id))
            .collect();
        if candidates.is_empty() {
            return Err(AnalyticsError::NoRequest);
        }
        let mut inventories = Vec::new();
        for request in candidates {
            for report in self
                .pages::<Resource>(&format!(
                    "analyticsReportRequests/{}/reports?limit=200",
                    request.id
                ))
                .await?
            {
                let mut daily_instances = Vec::new();
                let mut latest_daily = None;
                for instance in self
                    .pages::<Resource>(&format!(
                        "analyticsReports/{}/instances?limit=200",
                        report.id
                    ))
                    .await?
                {
                    if instance.attributes.granularity.as_deref() != Some("DAILY") {
                        continue;
                    }
                    let date = instance
                        .attributes
                        .processing_date
                        .as_deref()
                        .ok_or(AnalyticsError::ProcessingDate)
                        .and_then(|value| {
                            NaiveDate::parse_from_str(value, "%Y-%m-%d")
                                .map_err(|_| AnalyticsError::ProcessingDate)
                        })?;
                    latest_daily =
                        Some(latest_daily.map_or(date, |previous: NaiveDate| previous.max(date)));
                    daily_instances.push(DailyInstance {
                        resource: instance,
                        date,
                    });
                }
                inventories.push(ReportInventory {
                    request: request.clone(),
                    report,
                    instances: daily_instances,
                    latest_daily,
                });
            }
        }
        let mut count = 0;
        for inventory in select_latest(inventories) {
            for daily in inventory.instances {
                let instance = daily.resource;
                for segment in self
                    .pages::<Resource>(&format!(
                        "analyticsReportInstances/{}/segments?limit=200",
                        instance.id
                    ))
                    .await?
                {
                    if self
                        .save_segment(
                            dir,
                            access,
                            &inventory.request,
                            &inventory.report,
                            &instance,
                            &segment,
                        )
                        .await?
                    {
                        count += 1;
                    }
                }
            }
        }
        Ok(count)
    }
    async fn save_segment(
        &self,
        dir: &Path,
        access: AccessType,
        request: &Resource,
        report: &Resource,
        instance: &Resource,
        segment: &Resource,
    ) -> Result<bool, AnalyticsError> {
        let checksum = segment
            .attributes
            .checksum
            .as_deref()
            .ok_or(AnalyticsError::SegmentMetadata)?;
        let size = segment
            .attributes
            .size_in_bytes
            .ok_or(AnalyticsError::SegmentMetadata)?;
        if size < 0 || !is_md5(checksum) {
            return Err(AnalyticsError::SegmentMetadata);
        }
        let folder = dir
            .join("segments")
            .join(safe_id(&request.id)?)
            .join(safe_id(&report.id)?)
            .join(safe_id(&instance.id)?);
        fs::create_dir_all(&folder).await?;
        let stem = safe_id(&segment.id)?;
        let raw = folder.join(format!("{stem}.gz"));
        let normalized = folder.join(format!("{stem}.ndjson"));
        let manifest_path = dir.join("manifest.json");
        let mut manifest: BTreeMap<String, ManifestEntry> =
            load_json_or_default(&manifest_path).await?;
        let key = format!("{}:{}", segment.id, checksum.to_ascii_lowercase());
        let metadata = Metadata {
            request_id: &request.id,
            access_type: access.api(),
            report_id: &report.id,
            report_name: report.attributes.name.as_deref(),
            variant: report.attributes.name.as_deref().and_then(variant),
            instance_id: &instance.id,
            segment_id: &segment.id,
            granularity: "DAILY",
            checksum,
            processing_date: instance.attributes.processing_date.as_deref(),
            privacy: privacy_context(report.attributes.name.as_deref()),
        };
        let existing = manifest.get(&key).filter(|entry| {
            entry.raw == relative(dir, &raw) && entry.normalized == relative(dir, &normalized)
        });
        if existing.is_some() && fs::try_exists(&raw).await? {
            let bytes = fs::read(&raw).await?;
            if verify(&bytes, size, checksum).is_ok() {
                if existing.is_some_and(|entry| {
                    entry.normalization_version
                        >= required_normalization_version(metadata.report_name)
                }) && fs::try_exists(&normalized).await?
                {
                    return Ok(false);
                }
                let lines = normalize(&raw, &metadata).await?;
                let normalized_temp = write_temp(&normalized, lines.as_bytes()).await?;
                fs::rename(&normalized_temp, &normalized).await?;
                manifest.insert(key, manifest_entry(dir, &raw, &normalized));
                atomic_json(&manifest_path, &manifest).await?;
                return Ok(true);
            }
        }
        let mut source = segment.clone();
        let mut bytes = None;
        for attempt in 0..2 {
            let signed = source
                .attributes
                .url
                .as_deref()
                .ok_or(AnalyticsError::SegmentMetadata)?;
            let url = Url::parse(signed).map_err(|_| AnalyticsError::SegmentMetadata)?;
            if url.scheme() != "https" {
                return Err(AnalyticsError::SegmentMetadata);
            }
            let response = self.http.get(url).send().await?;
            if matches!(
                response.status(),
                StatusCode::FORBIDDEN | StatusCode::UNAUTHORIZED
            ) {
                if attempt == 0 {
                    source = self
                        .get::<Single<Resource>>(
                            self.url(&format!("analyticsReportSegments/{}", segment.id))?,
                        )
                        .await?
                        .data;
                    continue;
                }
                return Err(AnalyticsError::ExpiredUrl);
            }
            bytes = Some(checked(response).await?.bytes().await?.to_vec());
            break;
        }
        let bytes = bytes.ok_or(AnalyticsError::ExpiredUrl)?;
        verify(&bytes, size, checksum)?;
        let raw_temp = write_temp(&raw, &bytes).await?;
        let lines = match normalize(&raw_temp, &metadata).await {
            Ok(lines) => lines,
            Err(error) => {
                let _ = fs::remove_file(&raw_temp).await;
                return Err(error);
            }
        };
        let normalized_temp = write_temp(&normalized, lines.as_bytes()).await?;
        fs::rename(&raw_temp, &raw).await?;
        fs::rename(&normalized_temp, &normalized).await?;
        manifest.insert(key, manifest_entry(dir, &raw, &normalized));
        atomic_json(&manifest_path, &manifest).await?;
        Ok(true)
    }
}

async fn checked(response: reqwest::Response) -> Result<reqwest::Response, AnalyticsError> {
    let status = response.status();
    if status.is_success() {
        Ok(response)
    } else if matches!(status, StatusCode::UNAUTHORIZED | StatusCode::FORBIDDEN) {
        Err(AnalyticsError::Authorization(status.as_u16()))
    } else {
        Err(AnalyticsError::Api(status.as_u16()))
    }
}
#[derive(Deserialize)]
struct Page<T> {
    data: Vec<T>,
    links: Links,
}
#[derive(Deserialize)]
struct Links {
    next: Option<String>,
}
#[derive(Deserialize)]
struct Single<T> {
    data: T,
}
#[derive(Clone, Deserialize)]
struct Resource {
    id: String,
    #[serde(default)]
    attributes: Attributes,
}
struct ReportInventory {
    request: Resource,
    report: Resource,
    instances: Vec<DailyInstance>,
    latest_daily: Option<NaiveDate>,
}
struct DailyInstance {
    resource: Resource,
    date: NaiveDate,
}
fn select_latest(inventories: Vec<ReportInventory>) -> Vec<ReportInventory> {
    let mut newest_by_report_and_date = BTreeMap::new();
    for item in &inventories {
        for instance in &item.instances {
            let key = (item.report.identity(), instance.date);
            newest_by_report_and_date
                .entry(key)
                .and_modify(|newest: &mut Option<NaiveDate>| {
                    *newest = (*newest).max(item.latest_daily)
                })
                .or_insert(item.latest_daily);
        }
    }
    inventories
        .into_iter()
        .filter_map(|mut item| {
            item.instances.retain(|instance| {
                newest_by_report_and_date.get(&(item.report.identity(), instance.date))
                    == Some(&item.latest_daily)
            });
            if item.instances.is_empty() {
                None
            } else {
                Some(item)
            }
        })
        .collect()
}
#[derive(Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Attributes {
    access_type: Option<String>,
    stopped_due_to_inactivity: Option<bool>,
    name: Option<String>,
    category: Option<String>,
    granularity: Option<String>,
    processing_date: Option<String>,
    checksum: Option<String>,
    size_in_bytes: Option<i64>,
    url: Option<String>,
}
impl Resource {
    fn identity(&self) -> (String, String) {
        (
            self.attributes.category.clone().unwrap_or_default(),
            self.attributes
                .name
                .clone()
                .unwrap_or_else(|| self.id.clone()),
        )
    }
    fn access(&self) -> Option<AccessType> {
        match self.attributes.access_type.as_deref() {
            Some("ONGOING") => Some(AccessType::Ongoing),
            Some("ONE_TIME_SNAPSHOT") => Some(AccessType::OneTimeSnapshot),
            _ => None,
        }
    }
}
#[derive(Serialize, Deserialize)]
struct ManifestEntry {
    raw: PathBuf,
    normalized: PathBuf,
    #[serde(default)]
    normalization_version: u8,
}
fn manifest_entry(dir: &Path, raw: &Path, normalized: &Path) -> ManifestEntry {
    ManifestEntry {
        raw: relative(dir, raw),
        normalized: relative(dir, normalized),
        normalization_version: 6,
    }
}
#[derive(Serialize)]
struct Metadata<'a> {
    request_id: &'a str,
    access_type: &'a str,
    report_id: &'a str,
    report_name: Option<&'a str>,
    variant: Option<&'static str>,
    instance_id: &'a str,
    segment_id: &'a str,
    granularity: &'a str,
    checksum: &'a str,
    processing_date: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    privacy: Option<PrivacyContext>,
}
#[derive(Clone, Copy, Serialize)]
struct PrivacyContext {
    opted_in_users_only: bool,
    minimum_users_for_report: u8,
    missing_rows_mean_zero: bool,
}
fn privacy_context(name: Option<&str>) -> Option<PrivacyContext> {
    (session_variant(name).is_some() || crash_variant(name).is_some()).then_some(PrivacyContext {
        opted_in_users_only: true,
        minimum_users_for_report: 5,
        missing_rows_mean_zero: false,
    })
}
#[derive(Serialize)]
struct Row<'a> {
    #[serde(flatten)]
    metadata: &'a Metadata<'a>,
    columns: BTreeMap<&'a str, &'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    download: Option<DownloadRow>,
    #[serde(skip_serializing_if = "Option::is_none")]
    discovery: Option<DiscoveryRow>,
    #[serde(skip_serializing_if = "Option::is_none")]
    purchase: Option<PurchaseRow>,
    #[serde(skip_serializing_if = "Option::is_none")]
    installation: Option<InstallationRow>,
    #[serde(skip_serializing_if = "Option::is_none")]
    session: Option<SessionRow>,
    #[serde(skip_serializing_if = "Option::is_none")]
    crash: Option<CrashRow>,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum DownloadVariant {
    Standard,
    Detailed,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum DownloadType {
    FirstTimeDownload,
    Redownload,
    ManualUpdate,
    AutoUpdate,
    Restore,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum PreOrderState {
    Yes,
    No,
}
impl PreOrderState {
    fn parse(value: &str) -> Result<Self, AnalyticsError> {
        match value.to_ascii_lowercase().as_str() {
            "yes" => Ok(Self::Yes),
            "no" => Ok(Self::No),
            _ => Err(AnalyticsError::InvalidDownloadValue("Pre-Order")),
        }
    }
}
impl DownloadType {
    fn parse(value: &str) -> Result<Self, AnalyticsError> {
        match value.to_ascii_lowercase().as_str() {
            "first-time download" => Ok(Self::FirstTimeDownload),
            "redownload" => Ok(Self::Redownload),
            "manual update" => Ok(Self::ManualUpdate),
            "auto-update" => Ok(Self::AutoUpdate),
            "restore" => Ok(Self::Restore),
            _ => Err(AnalyticsError::UnsupportedDownloadType),
        }
    }
    pub fn counts_toward_total(self) -> bool {
        matches!(self, Self::FirstTimeDownload | Self::Redownload)
    }
}

#[derive(Debug, Serialize)]
pub struct DownloadRow {
    date: NaiveDate,
    app_name: String,
    app_apple_identifier: u64,
    variant: DownloadVariant,
    download_type: DownloadType,
    app_version: String,
    device: String,
    platform_version: String,
    source_type: String,
    source_info: Option<String>,
    campaign: Option<String>,
    page_type: String,
    page_title: Option<String>,
    pre_order: PreOrderState,
    territory: String,
    count: u64,
    total_downloads: u64,
}
impl DownloadRow {
    fn parse(
        columns: &BTreeMap<&str, &str>,
        variant: DownloadVariant,
    ) -> Result<Self, AnalyticsError> {
        fn required<'a>(
            columns: &'a BTreeMap<&str, &str>,
            name: &'static str,
        ) -> Result<&'a str, AnalyticsError> {
            columns
                .get(name)
                .copied()
                .ok_or(AnalyticsError::MissingDownloadColumn(name))
        }
        fn nonempty<'a>(
            columns: &'a BTreeMap<&str, &str>,
            name: &'static str,
        ) -> Result<&'a str, AnalyticsError> {
            let value = required(columns, name)?;
            if value.trim().is_empty() {
                Err(AnalyticsError::InvalidDownloadValue(name))
            } else {
                Ok(value)
            }
        }
        let date = NaiveDate::parse_from_str(nonempty(columns, "Date")?, "%Y-%m-%d")
            .map_err(|_| AnalyticsError::InvalidDownloadValue("Date"))?;
        let app_apple_identifier = nonempty(columns, "App Apple Identifier")?
            .parse()
            .map_err(|_| AnalyticsError::InvalidDownloadValue("App Apple Identifier"))?;
        let download_type = DownloadType::parse(nonempty(columns, "Download Type")?)?;
        let count = nonempty(columns, "Counts")?
            .parse()
            .map_err(|_| AnalyticsError::InvalidDownloadValue("Counts"))?;
        let detailed = variant == DownloadVariant::Detailed;
        let total_downloads = if download_type.counts_toward_total() {
            count
        } else {
            0
        };
        Ok(Self {
            date,
            app_name: nonempty(columns, "App Name")?.into(),
            app_apple_identifier,
            variant,
            download_type,
            app_version: nonempty(columns, "App Version")?.into(),
            device: nonempty(columns, "Device")?.into(),
            platform_version: nonempty(columns, "Platform Version")?.into(),
            source_type: nonempty(columns, "Source Type")?.into(),
            source_info: detailed
                .then(|| columns.get("Source Info").copied())
                .flatten()
                .map(str::to_owned),
            campaign: detailed
                .then(|| columns.get("Campaign").copied())
                .flatten()
                .map(str::to_owned),
            page_type: nonempty(columns, "Page Type")?.into(),
            page_title: detailed
                .then(|| columns.get("Page Title").copied())
                .flatten()
                .map(str::to_owned),
            pre_order: PreOrderState::parse(nonempty(columns, "Pre-Order")?)?,
            territory: nonempty(columns, "Territory")?.into(),
            count,
            total_downloads,
        })
    }
}

fn download_variant(name: Option<&str>) -> Option<DownloadVariant> {
    match name {
        Some("App Store Downloads Standard" | "Downloads Standard") => {
            Some(DownloadVariant::Standard)
        }
        Some("App Store Downloads Detailed" | "Downloads Detailed") => {
            Some(DownloadVariant::Detailed)
        }
        _ => None,
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum DiscoveryEvent {
    Impression,
    PageView,
    Tap,
}
impl DiscoveryEvent {
    fn parse(value: &str) -> Result<Self, AnalyticsError> {
        match value.to_ascii_lowercase().as_str() {
            "impression" => Ok(Self::Impression),
            "page view" => Ok(Self::PageView),
            "tap" => Ok(Self::Tap),
            _ => Err(AnalyticsError::UnsupportedDiscoveryEvent),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum DiscoveryVariant {
    Standard,
    Detailed,
}

#[derive(Debug, Serialize)]
pub struct DiscoveryRow {
    date: NaiveDate,
    app_name: String,
    app_apple_identifier: u64,
    variant: DiscoveryVariant,
    event: DiscoveryEvent,
    page_type: String,
    page_title: Option<String>,
    source_type: String,
    source_info: Option<String>,
    campaign: Option<String>,
    engagement_type: Option<String>,
    device: String,
    platform_version: String,
    territory: String,
    count: u64,
    unique_count: u64,
}
impl DiscoveryRow {
    fn parse(
        columns: &BTreeMap<&str, &str>,
        variant: DiscoveryVariant,
    ) -> Result<Self, AnalyticsError> {
        fn required<'a>(
            columns: &'a BTreeMap<&str, &str>,
            name: &'static str,
        ) -> Result<&'a str, AnalyticsError> {
            columns
                .get(name)
                .copied()
                .ok_or(AnalyticsError::MissingDiscoveryColumn(name))
        }
        fn nonempty<'a>(
            columns: &'a BTreeMap<&str, &str>,
            name: &'static str,
        ) -> Result<&'a str, AnalyticsError> {
            let value = required(columns, name)?;
            if value.trim().is_empty() {
                Err(AnalyticsError::InvalidDiscoveryValue(name))
            } else {
                Ok(value)
            }
        }
        let date = NaiveDate::parse_from_str(nonempty(columns, "Date")?, "%Y-%m-%d")
            .map_err(|_| AnalyticsError::InvalidDiscoveryValue("Date"))?;
        let app_apple_identifier = nonempty(columns, "App Apple Identifier")?
            .parse()
            .map_err(|_| AnalyticsError::InvalidDiscoveryValue("App Apple Identifier"))?;
        let count = nonempty(columns, "Counts")?
            .parse()
            .map_err(|_| AnalyticsError::InvalidDiscoveryValue("Counts"))?;
        let unique_count = nonempty(columns, "Unique Counts")?
            .parse()
            .map_err(|_| AnalyticsError::InvalidDiscoveryValue("Unique Counts"))?;
        let detailed = variant == DiscoveryVariant::Detailed;
        Ok(Self {
            date,
            app_name: nonempty(columns, "App Name")?.into(),
            app_apple_identifier,
            variant,
            event: DiscoveryEvent::parse(nonempty(columns, "Event")?)?,
            page_type: nonempty(columns, "Page Type")?.into(),
            page_title: detailed
                .then(|| columns.get("Page Title").copied())
                .flatten()
                .filter(|value| !value.is_empty())
                .map(str::to_owned),
            source_type: nonempty(columns, "Source Type")?.into(),
            source_info: detailed
                .then(|| columns.get("Source Info").copied())
                .flatten()
                .filter(|value| !value.is_empty())
                .map(str::to_owned),
            campaign: detailed
                .then(|| columns.get("Campaign").copied())
                .flatten()
                .filter(|value| !value.is_empty())
                .map(str::to_owned),
            engagement_type: columns
                .get("Engagement Type")
                .copied()
                .filter(|value| !value.is_empty())
                .map(str::to_owned),
            device: nonempty(columns, "Device")?.into(),
            platform_version: nonempty(columns, "Platform Version")?.into(),
            territory: nonempty(columns, "Territory")?.into(),
            count,
            unique_count,
        })
    }
    pub fn sum_counts(rows: &[Self], unique: bool) -> Result<u64, AnalyticsError> {
        if unique {
            return Err(AnalyticsError::NonAdditiveUniqueCounts);
        }
        let Some(first) = rows.first() else {
            return Ok(0);
        };
        if rows.iter().any(|row| row.variant != first.variant) {
            return Err(AnalyticsError::MixedReportVariants);
        }
        rows.iter().try_fold(0u64, |sum, row| {
            sum.checked_add(row.count)
                .ok_or(AnalyticsError::InvalidDiscoveryValue("Counts"))
        })
    }
}

fn discovery_variant(name: Option<&str>) -> Option<DiscoveryVariant> {
    match name {
        Some(
            "App Store Discovery and Engagement Standard" | "Discovery and Engagement Standard",
        ) => Some(DiscoveryVariant::Standard),
        Some(
            "App Store Discovery and Engagement Detailed" | "Discovery and Engagement Detailed",
        ) => Some(DiscoveryVariant::Detailed),
        _ => None,
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum PurchaseVariant {
    Standard,
    Detailed,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum PurchaseType {
    AppPurchase,
    InAppPurchases,
}
impl PurchaseType {
    fn parse(value: &str) -> Result<Self, AnalyticsError> {
        match value.to_ascii_lowercase().as_str() {
            "app purchase" => Ok(Self::AppPurchase),
            "in-app purchases" => Ok(Self::InAppPurchases),
            _ => Err(AnalyticsError::UnsupportedPurchaseType),
        }
    }
}

#[derive(Debug, Serialize)]
pub struct PurchaseRow {
    date: NaiveDate,
    app_name: String,
    app_apple_identifier: u64,
    variant: PurchaseVariant,
    purchase_type: PurchaseType,
    content_name: String,
    content_apple_identifier: u64,
    payment_method: String,
    device: String,
    platform_version: String,
    source_type: String,
    source_info: Option<String>,
    campaign: Option<String>,
    page_type: String,
    page_title: Option<String>,
    app_download_date: Option<NaiveDate>,
    pre_order: PreOrderState,
    territory: String,
    purchases: i64,
    #[serde(serialize_with = "serialize_decimal_number")]
    proceeds_usd: Decimal,
    #[serde(serialize_with = "serialize_decimal_number")]
    sales_usd: Decimal,
    paying_users: u64,
}
impl PurchaseRow {
    fn parse(
        columns: &BTreeMap<&str, &str>,
        variant: PurchaseVariant,
    ) -> Result<Self, AnalyticsError> {
        fn value<'a>(
            columns: &'a BTreeMap<&str, &str>,
            name: &'static str,
        ) -> Result<&'a str, AnalyticsError> {
            columns
                .get(name)
                .copied()
                .ok_or(AnalyticsError::MissingPurchaseColumn(name))
        }
        fn nonempty<'a>(
            columns: &'a BTreeMap<&str, &str>,
            name: &'static str,
        ) -> Result<&'a str, AnalyticsError> {
            let value = value(columns, name)?;
            if value.trim().is_empty() {
                Err(AnalyticsError::InvalidPurchaseValue(name))
            } else {
                Ok(value)
            }
        }
        fn optional(columns: &BTreeMap<&str, &str>, name: &'static str) -> Option<String> {
            columns
                .get(name)
                .copied()
                .filter(|value| !value.is_empty())
                .map(str::to_owned)
        }
        fn date(value: &str, name: &'static str) -> Result<NaiveDate, AnalyticsError> {
            NaiveDate::parse_from_str(value, "%Y-%m-%d")
                .map_err(|_| AnalyticsError::InvalidPurchaseValue(name))
        }
        fn number<T: std::str::FromStr>(
            columns: &BTreeMap<&str, &str>,
            name: &'static str,
        ) -> Result<T, AnalyticsError> {
            nonempty(columns, name)?
                .parse()
                .map_err(|_| AnalyticsError::InvalidPurchaseValue(name))
        }
        let detailed = variant == PurchaseVariant::Detailed;
        let pre_order = match nonempty(columns, "Pre-Order")?
            .to_ascii_lowercase()
            .as_str()
        {
            "yes" => PreOrderState::Yes,
            "no" => PreOrderState::No,
            _ => return Err(AnalyticsError::InvalidPurchaseValue("Pre-Order")),
        };
        Ok(Self {
            date: date(nonempty(columns, "Date")?, "Date")?,
            app_name: nonempty(columns, "App Name")?.into(),
            app_apple_identifier: number(columns, "App Apple Identifier")?,
            variant,
            purchase_type: PurchaseType::parse(nonempty(columns, "Purchase Type")?)?,
            content_name: nonempty(columns, "Content Name")?.into(),
            content_apple_identifier: number(columns, "Content Apple Identifier")?,
            payment_method: nonempty(columns, "Payment Method")?.into(),
            device: nonempty(columns, "Device")?.into(),
            platform_version: nonempty(columns, "Platform Version")?.into(),
            source_type: nonempty(columns, "Source Type")?.into(),
            source_info: detailed.then(|| optional(columns, "Source Info")).flatten(),
            campaign: detailed.then(|| optional(columns, "Campaign")).flatten(),
            page_type: nonempty(columns, "Page Type")?.into(),
            page_title: detailed.then(|| optional(columns, "Page Title")).flatten(),
            app_download_date: optional(columns, "App Download Date")
                .map(|value| date(&value, "App Download Date"))
                .transpose()?,
            pre_order,
            territory: nonempty(columns, "Territory")?.into(),
            purchases: number(columns, "Purchases")?,
            proceeds_usd: number(columns, "Proceeds in USD")?,
            sales_usd: number(columns, "Sales in USD")?,
            paying_users: number(columns, "Paying Users")?,
        })
    }

    pub fn sum_purchases(rows: &[Self], paying_users: bool) -> Result<i64, AnalyticsError> {
        if paying_users {
            return Err(AnalyticsError::NonAdditivePayingUsers);
        }
        let Some(first) = rows.first() else {
            return Ok(0);
        };
        if rows.iter().any(|row| row.variant != first.variant) {
            return Err(AnalyticsError::MixedReportVariants);
        }
        rows.iter().try_fold(0i64, |sum, row| {
            sum.checked_add(row.purchases)
                .ok_or(AnalyticsError::InvalidPurchaseValue("Purchases"))
        })
    }
}

fn purchase_variant(name: Option<&str>) -> Option<PurchaseVariant> {
    match name {
        Some("App Store Purchases Standard" | "Purchases Standard") => {
            Some(PurchaseVariant::Standard)
        }
        Some("App Store Purchases Detailed" | "Purchases Detailed") => {
            Some(PurchaseVariant::Detailed)
        }
        _ => None,
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum InstallationVariant {
    Standard,
    Detailed,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum InstallationEvent {
    Install,
    Delete,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum InstallationDownloadType {
    FirstTimeDownload,
    Redownload,
    ManualUpdate,
    Restore,
}

#[derive(Debug, Serialize)]
pub struct InstallationRow {
    date: NaiveDate,
    app_name: String,
    app_apple_identifier: u64,
    variant: InstallationVariant,
    event: InstallationEvent,
    download_type: InstallationDownloadType,
    app_version: String,
    device: String,
    platform_version: String,
    source_type: String,
    source_info: Option<String>,
    campaign: Option<String>,
    page_type: String,
    page_title: Option<String>,
    app_download_date: Option<NaiveDate>,
    territory: String,
    count: u64,
    unique_devices: u64,
}
impl InstallationRow {
    fn parse(
        columns: &BTreeMap<&str, &str>,
        variant: InstallationVariant,
    ) -> Result<Self, AnalyticsError> {
        fn value<'a>(
            columns: &'a BTreeMap<&str, &str>,
            name: &'static str,
        ) -> Result<&'a str, AnalyticsError> {
            columns
                .get(name)
                .copied()
                .ok_or(AnalyticsError::MissingInstallationColumn(name))
        }
        fn nonempty<'a>(
            columns: &'a BTreeMap<&str, &str>,
            name: &'static str,
        ) -> Result<&'a str, AnalyticsError> {
            let value = value(columns, name)?;
            if value.trim().is_empty() {
                Err(AnalyticsError::InvalidInstallationValue(name))
            } else {
                Ok(value)
            }
        }
        fn optional(columns: &BTreeMap<&str, &str>, name: &'static str) -> Option<String> {
            columns
                .get(name)
                .copied()
                .filter(|value| !value.is_empty())
                .map(str::to_owned)
        }
        fn date(value: &str, name: &'static str) -> Result<NaiveDate, AnalyticsError> {
            NaiveDate::parse_from_str(value, "%Y-%m-%d")
                .map_err(|_| AnalyticsError::InvalidInstallationValue(name))
        }
        fn number<T: std::str::FromStr>(
            columns: &BTreeMap<&str, &str>,
            name: &'static str,
        ) -> Result<T, AnalyticsError> {
            nonempty(columns, name)?
                .parse()
                .map_err(|_| AnalyticsError::InvalidInstallationValue(name))
        }
        let event = match nonempty(columns, "Event")?.to_ascii_lowercase().as_str() {
            "install" => InstallationEvent::Install,
            "delete" => InstallationEvent::Delete,
            _ => return Err(AnalyticsError::UnsupportedInstallationEvent),
        };
        let download_type = match nonempty(columns, "Download Type")?
            .to_ascii_lowercase()
            .as_str()
        {
            "first-time download" => InstallationDownloadType::FirstTimeDownload,
            "redownload" => InstallationDownloadType::Redownload,
            "manual update" => InstallationDownloadType::ManualUpdate,
            "restore" => InstallationDownloadType::Restore,
            _ => return Err(AnalyticsError::UnsupportedInstallationDownloadType),
        };
        let detailed = variant == InstallationVariant::Detailed;
        Ok(Self {
            date: date(nonempty(columns, "Date")?, "Date")?,
            app_name: nonempty(columns, "App Name")?.into(),
            app_apple_identifier: number(columns, "App Apple Identifier")?,
            variant,
            event,
            download_type,
            app_version: nonempty(columns, "App Version")?.into(),
            device: nonempty(columns, "Device")?.into(),
            platform_version: nonempty(columns, "Platform Version")?.into(),
            source_type: nonempty(columns, "Source Type")?.into(),
            source_info: detailed.then(|| optional(columns, "Source Info")).flatten(),
            campaign: detailed.then(|| optional(columns, "Campaign")).flatten(),
            page_type: nonempty(columns, "Page Type")?.into(),
            page_title: detailed.then(|| optional(columns, "Page Title")).flatten(),
            app_download_date: optional(columns, "App Download Date")
                .map(|value| date(&value, "App Download Date"))
                .transpose()?,
            territory: nonempty(columns, "Territory")?.into(),
            count: number(columns, "Counts")?,
            unique_devices: number(columns, "Unique Devices")?,
        })
    }
    pub fn sum_counts(rows: &[Self], unique_devices: bool) -> Result<u64, AnalyticsError> {
        if unique_devices {
            return Err(AnalyticsError::NonAdditiveUniqueDevices);
        }
        let Some(first) = rows.first() else {
            return Ok(0);
        };
        if rows.iter().any(|row| row.variant != first.variant) {
            return Err(AnalyticsError::MixedReportVariants);
        }
        if rows.iter().any(|row| row.event != first.event) {
            return Err(AnalyticsError::MixedInstallationEvents);
        }
        rows.iter().try_fold(0u64, |sum, row| {
            sum.checked_add(row.count)
                .ok_or(AnalyticsError::InvalidInstallationValue("Counts"))
        })
    }
}

fn installation_variant(name: Option<&str>) -> Option<InstallationVariant> {
    match name {
        Some(
            "App Store Installations and Deletions Standard"
            | "Installations and Deletions Standard",
        ) => Some(InstallationVariant::Standard),
        Some(
            "App Store Installations and Deletions Detailed"
            | "Installations and Deletions Detailed",
        ) => Some(InstallationVariant::Detailed),
        _ => None,
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum UsageVariant {
    Single,
    Standard,
    Detailed,
}

fn session_variant(name: Option<&str>) -> Option<UsageVariant> {
    match name {
        Some("App Sessions Standard" | "Sessions Standard") => Some(UsageVariant::Standard),
        Some("App Sessions Detailed" | "Sessions Detailed") => Some(UsageVariant::Detailed),
        _ => None,
    }
}

fn crash_variant(name: Option<&str>) -> Option<UsageVariant> {
    match name {
        Some("App Crashes" | "Crashes") => Some(UsageVariant::Single),
        Some("App Crashes Standard" | "Crashes Standard") => Some(UsageVariant::Standard),
        Some("App Crashes Detailed" | "Crashes Detailed") => Some(UsageVariant::Detailed),
        _ => None,
    }
}

#[derive(Debug, Serialize)]
pub struct SessionRow {
    date: NaiveDate,
    app_name: String,
    app_apple_identifier: u64,
    variant: UsageVariant,
    app_version: String,
    device: String,
    platform_version: String,
    source_type: String,
    source_info: Option<String>,
    campaign: Option<String>,
    page_type: String,
    page_title: Option<String>,
    app_download_date: Option<NaiveDate>,
    territory: String,
    sessions: u64,
    total_session_duration: u64,
    unique_devices: u64,
}

impl SessionRow {
    fn parse(
        columns: &BTreeMap<&str, &str>,
        variant: UsageVariant,
    ) -> Result<Self, AnalyticsError> {
        let required = |name| -> Result<&str, AnalyticsError> {
            let value = columns
                .get(name)
                .copied()
                .ok_or(AnalyticsError::MissingSessionColumn(name))?;
            if value.trim().is_empty() {
                return Err(AnalyticsError::InvalidSessionValue(name));
            }
            Ok(value)
        };
        let date = |name| -> Result<NaiveDate, AnalyticsError> {
            NaiveDate::parse_from_str(required(name)?, "%Y-%m-%d")
                .map_err(|_| AnalyticsError::InvalidSessionValue(name))
        };
        let number = |name| -> Result<u64, AnalyticsError> {
            required(name)?
                .parse()
                .map_err(|_| AnalyticsError::InvalidSessionValue(name))
        };
        let optional = |name| columns.get(name).copied().filter(|value| !value.is_empty());
        let detailed = variant == UsageVariant::Detailed;
        Ok(Self {
            date: date("Date")?,
            app_name: required("App Name")?.into(),
            app_apple_identifier: number("App Apple Identifier")?,
            variant,
            app_version: required("App Version")?.into(),
            device: required("Device")?.into(),
            platform_version: required("Platform Version")?.into(),
            source_type: required("Source Type")?.into(),
            source_info: detailed
                .then(|| optional("Source Info"))
                .flatten()
                .map(str::to_owned),
            campaign: detailed
                .then(|| optional("Campaign"))
                .flatten()
                .map(str::to_owned),
            page_type: required("Page Type")?.into(),
            page_title: detailed
                .then(|| optional("Page Title"))
                .flatten()
                .map(str::to_owned),
            app_download_date: optional("App Download Date")
                .map(|value| {
                    NaiveDate::parse_from_str(value, "%Y-%m-%d")
                        .map_err(|_| AnalyticsError::InvalidSessionValue("App Download Date"))
                })
                .transpose()?,
            territory: required("Territory")?.into(),
            sessions: number("Sessions")?,
            total_session_duration: number("Total Session Duration")?,
            unique_devices: number("Unique Devices")?,
        })
    }
}

#[derive(Debug, Serialize)]
pub struct CrashRow {
    date: NaiveDate,
    app_name: String,
    app_apple_identifier: u64,
    variant: UsageVariant,
    app_version: String,
    device: String,
    platform_version: String,
    crashes: u64,
    unique_devices: u64,
}

impl CrashRow {
    fn parse(
        columns: &BTreeMap<&str, &str>,
        variant: UsageVariant,
    ) -> Result<Self, AnalyticsError> {
        let required = |name| -> Result<&str, AnalyticsError> {
            let value = columns
                .get(name)
                .copied()
                .ok_or(AnalyticsError::MissingCrashColumn(name))?;
            if value.trim().is_empty() {
                return Err(AnalyticsError::InvalidCrashValue(name));
            }
            Ok(value)
        };
        let number = |name| -> Result<u64, AnalyticsError> {
            required(name)?
                .parse()
                .map_err(|_| AnalyticsError::InvalidCrashValue(name))
        };
        Ok(Self {
            date: NaiveDate::parse_from_str(required("Date")?, "%Y-%m-%d")
                .map_err(|_| AnalyticsError::InvalidCrashValue("Date"))?,
            app_name: required("App Name")?.into(),
            app_apple_identifier: number("App Apple Identifier")?,
            variant,
            app_version: required("App Version")?.into(),
            device: required("Device")?.into(),
            platform_version: required("Platform Version")?.into(),
            crashes: number("Crashes")?,
            unique_devices: number("Unique Devices")?,
        })
    }
}

fn required_normalization_version(name: Option<&str>) -> u8 {
    if session_variant(name).is_some() || crash_variant(name).is_some() {
        6
    } else if installation_variant(name).is_some() {
        5
    } else if purchase_variant(name).is_some() {
        4
    } else if download_variant(name).is_some() || discovery_variant(name).is_some() {
        2
    } else {
        0
    }
}

fn serialize_decimal_number<S: serde::Serializer>(
    value: &Decimal,
    serializer: S,
) -> Result<S::Ok, S::Error> {
    let number: serde_json::Number =
        serde_json::from_str(&value.to_string()).map_err(serde::ser::Error::custom)?;
    number.serialize(serializer)
}
fn variant(name: &str) -> Option<&'static str> {
    if matches!(name, "App Crashes" | "Crashes") {
        Some("SINGLE")
    } else if name.ends_with(" Detailed") {
        Some("DETAILED")
    } else if name.ends_with(" Standard") {
        Some("STANDARD")
    } else {
        None
    }
}
fn current_month() -> String {
    let date = Utc::now().date_naive();
    format!("{:04}-{:02}", date.year(), date.month())
}
fn is_md5(value: &str) -> bool {
    value.len() == 32 && value.bytes().all(|b| b.is_ascii_hexdigit())
}
fn verify(bytes: &[u8], size: i64, checksum: &str) -> Result<(), AnalyticsError> {
    if bytes.len() as i64 != size {
        return Err(AnalyticsError::SizeMismatch);
    }
    let digest = Md5::digest(bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>();
    if !digest.eq_ignore_ascii_case(checksum) {
        return Err(AnalyticsError::ChecksumMismatch);
    }
    Ok(())
}
fn safe_id(id: &str) -> Result<&str, AnalyticsError> {
    if id.is_empty()
        || !id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
    {
        return Err(AnalyticsError::SegmentMetadata);
    }
    Ok(id)
}
fn relative(root: &Path, path: &Path) -> PathBuf {
    path.strip_prefix(root).unwrap_or(path).to_path_buf()
}
async fn normalize<'a>(path: &Path, metadata: &'a Metadata<'a>) -> Result<String, AnalyticsError> {
    let file = fs::File::open(path).await?;
    let mut decoded = String::new();
    GzipDecoder::new(BufReader::new(file))
        .read_to_string(&mut decoded)
        .await
        .map_err(|_| AnalyticsError::Parse("invalid gzip or UTF-8"))?;
    let mut lines = decoded.lines();
    let header = lines
        .next()
        .ok_or(AnalyticsError::Parse("missing header"))?;
    let names: Vec<&str> = header.split('\t').collect();
    if names.is_empty()
        || names.iter().any(|n| n.is_empty())
        || names.iter().collect::<BTreeSet<_>>().len() != names.len()
    {
        return Err(AnalyticsError::Parse("invalid column names"));
    }
    let download_variant = download_variant(metadata.report_name);
    if download_variant.is_some() {
        for required in [
            "Date",
            "App Name",
            "App Apple Identifier",
            "Download Type",
            "App Version",
            "Device",
            "Platform Version",
            "Source Type",
            "Page Type",
            "Pre-Order",
            "Territory",
            "Counts",
        ] {
            if !names.contains(&required) {
                return Err(AnalyticsError::MissingDownloadColumn(required));
            }
        }
    }
    let discovery_variant = discovery_variant(metadata.report_name);
    if discovery_variant.is_some() {
        for required in [
            "Date",
            "App Name",
            "App Apple Identifier",
            "Event",
            "Page Type",
            "Source Type",
            "Engagement Type",
            "Device",
            "Platform Version",
            "Territory",
            "Counts",
            "Unique Counts",
        ] {
            if !names.contains(&required) {
                return Err(AnalyticsError::MissingDiscoveryColumn(required));
            }
        }
    }
    let purchase_variant = purchase_variant(metadata.report_name);
    if purchase_variant.is_some() {
        for required in [
            "Date",
            "App Name",
            "App Apple Identifier",
            "Purchase Type",
            "Content Name",
            "Content Apple Identifier",
            "Payment Method",
            "Device",
            "Platform Version",
            "Source Type",
            "Page Type",
            "App Download Date",
            "Pre-Order",
            "Territory",
            "Purchases",
            "Proceeds in USD",
            "Sales in USD",
            "Paying Users",
        ] {
            if !names.contains(&required) {
                return Err(AnalyticsError::MissingPurchaseColumn(required));
            }
        }
    }
    let installation_variant = installation_variant(metadata.report_name);
    if installation_variant.is_some() {
        for required in [
            "Date",
            "App Name",
            "App Apple Identifier",
            "Event",
            "Download Type",
            "App Version",
            "Device",
            "Platform Version",
            "Source Type",
            "Page Type",
            "App Download Date",
            "Territory",
            "Counts",
            "Unique Devices",
        ] {
            if !names.contains(&required) {
                return Err(AnalyticsError::MissingInstallationColumn(required));
            }
        }
    }
    let session_variant = session_variant(metadata.report_name);
    if session_variant.is_some() {
        for required in [
            "Date",
            "App Name",
            "App Apple Identifier",
            "App Version",
            "Device",
            "Platform Version",
            "Source Type",
            "Page Type",
            "App Download Date",
            "Territory",
            "Sessions",
            "Total Session Duration",
            "Unique Devices",
        ] {
            if !names.contains(&required) {
                return Err(AnalyticsError::MissingSessionColumn(required));
            }
        }
    }
    let crash_variant = crash_variant(metadata.report_name);
    if crash_variant.is_some() {
        for required in [
            "Date",
            "App Name",
            "App Apple Identifier",
            "App Version",
            "Device",
            "Platform Version",
            "Crashes",
            "Unique Devices",
        ] {
            if !names.contains(&required) {
                return Err(AnalyticsError::MissingCrashColumn(required));
            }
        }
    }
    let mut output = String::new();
    for line in lines {
        let values: Vec<&str> = line.split('\t').collect();
        if values.len() != names.len() {
            return Err(AnalyticsError::Parse("column count mismatch"));
        }
        let columns = names.iter().copied().zip(values).collect();
        let download = download_variant
            .map(|variant| DownloadRow::parse(&columns, variant))
            .transpose()?;
        let discovery = discovery_variant
            .map(|variant| DiscoveryRow::parse(&columns, variant))
            .transpose()?;
        let purchase = purchase_variant
            .map(|variant| PurchaseRow::parse(&columns, variant))
            .transpose()?;
        let installation = installation_variant
            .map(|variant| InstallationRow::parse(&columns, variant))
            .transpose()?;
        let session = session_variant
            .map(|variant| SessionRow::parse(&columns, variant))
            .transpose()?;
        let crash = crash_variant
            .map(|variant| CrashRow::parse(&columns, variant))
            .transpose()?;
        output.push_str(&serde_json::to_string(&Row {
            metadata,
            columns,
            download,
            discovery,
            purchase,
            installation,
            session,
            crash,
        })?);
        output.push('\n');
    }
    Ok(output)
}
async fn load_json_or_default<T: DeserializeOwned + Default>(
    path: &Path,
) -> Result<T, AnalyticsError> {
    match fs::read(path).await {
        Ok(data) => Ok(serde_json::from_slice(&data)?),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(T::default()),
        Err(error) => Err(error.into()),
    }
}
async fn atomic_json<T: Serialize>(path: &Path, value: &T) -> Result<(), AnalyticsError> {
    let temp = write_temp(path, &serde_json::to_vec_pretty(value)?).await?;
    fs::rename(temp, path).await?;
    Ok(())
}
async fn write_temp(path: &Path, bytes: &[u8]) -> Result<PathBuf, AnalyticsError> {
    let parent = path.parent().ok_or(AnalyticsError::RequestState)?;
    fs::create_dir_all(parent).await?;
    for _ in 0..8 {
        let nonce: u64 = rand::random();
        let temp = parent.join(format!(".segment-{nonce:016x}.tmp"));
        match fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temp)
            .await
        {
            Ok(mut file) => {
                file.write_all(bytes).await?;
                file.sync_all().await?;
                return Ok(temp);
            }
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(error.into()),
        }
    }
    Err(AnalyticsError::RequestState)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn download_directory_requires_absolute_path() {
        assert!(matches!(
            parse_download_dir(None),
            Err(AnalyticsError::Configuration(DOWNLOAD_DIR_ENV))
        ));
        assert!(parse_download_dir(Some(OsString::new())).is_err());
        assert!(parse_download_dir(Some(OsString::from(".build/appstore-reports"))).is_err());
        let directory =
            parse_download_dir(Some(OsString::from("/analytics-reports"))).expect("absolute path");
        assert_eq!(
            snapshot_manifest_path(&directory),
            directory.join("snapshots.json")
        );
    }
    fn inventory(id: &str, report_name: &str, dates: &[&str]) -> ReportInventory {
        let instances: Vec<_> = dates
            .iter()
            .map(|value| {
                let date = NaiveDate::parse_from_str(value, "%Y-%m-%d").expect("valid test date");
                DailyInstance {
                    resource: Resource {
                        id: format!("{id}-{value}"),
                        attributes: Attributes::default(),
                    },
                    date,
                }
            })
            .collect();
        let latest_daily = instances.iter().map(|item| item.date).max();
        ReportInventory {
            request: Resource {
                id: id.into(),
                attributes: Attributes::default(),
            },
            report: Resource {
                id: format!("{id}-report"),
                attributes: Attributes {
                    name: Some(report_name.into()),
                    category: Some("APP_USAGE".into()),
                    ..Attributes::default()
                },
            },
            instances,
            latest_daily,
        }
    }
    #[test]
    fn newest_daily_data_wins_over_opaque_request_id_order() {
        let selected = select_latest(vec![
            inventory("z-older", "Sessions Standard", &["2026-09-25"]),
            inventory(
                "a-newer",
                "Sessions Standard",
                &["2026-09-25", "2026-09-26"],
            ),
            inventory("m-pending", "Sessions Standard", &[]),
        ]);
        assert_eq!(
            selected
                .iter()
                .map(|item| item.request.id.as_str())
                .collect::<Vec<_>>(),
            vec!["a-newer"]
        );
    }
    #[test]
    fn equally_current_requests_are_all_included() {
        let selected = select_latest(vec![
            inventory("z-one", "Sessions Standard", &["2026-09-25"]),
            inventory("a-two", "Sessions Standard", &["2026-09-25"]),
        ]);
        assert_eq!(selected.len(), 2);
    }
    #[test]
    fn pending_report_keeps_latest_available_other_request() {
        let selected = select_latest(vec![
            inventory("z-older", "Sessions Standard", &["2026-09-24"]),
            inventory("z-older", "Downloads Standard", &["2026-09-24"]),
            inventory("a-newer", "Sessions Standard", &["2026-09-25"]),
            inventory("a-newer", "Downloads Standard", &[]),
        ]);
        let selected: Vec<_> = selected
            .iter()
            .map(|item| {
                (
                    item.request.id.as_str(),
                    item.report.attributes.name.as_deref(),
                )
            })
            .collect();
        assert_eq!(
            selected,
            vec![
                ("z-older", Some("Sessions Standard")),
                ("z-older", Some("Downloads Standard")),
                ("a-newer", Some("Sessions Standard"))
            ]
        );
    }
    #[test]
    fn older_request_preserves_dates_missing_from_newer_request() {
        let selected = select_latest(vec![
            inventory(
                "z-older",
                "Sessions Standard",
                &["2026-09-23", "2026-09-24"],
            ),
            inventory(
                "a-newer",
                "Sessions Standard",
                &["2026-09-24", "2026-09-25"],
            ),
        ]);
        let selected: Vec<_> = selected
            .iter()
            .flat_map(|item| {
                item.instances
                    .iter()
                    .map(move |instance| (item.request.id.as_str(), instance.date))
            })
            .collect();
        assert_eq!(
            selected,
            vec![
                (
                    "z-older",
                    NaiveDate::from_ymd_opt(2026, 9, 23).expect("valid test date")
                ),
                (
                    "a-newer",
                    NaiveDate::from_ymd_opt(2026, 9, 24).expect("valid test date")
                ),
                (
                    "a-newer",
                    NaiveDate::from_ymd_opt(2026, 9, 25).expect("valid test date")
                ),
            ]
        );
    }
    fn metadata() -> Metadata<'static> {
        Metadata {
            request_id: "request",
            access_type: "ONGOING",
            report_id: "report",
            report_name: Some("Example Standard"),
            variant: Some("STANDARD"),
            instance_id: "instance",
            segment_id: "segment",
            granularity: "DAILY",
            checksum: "checksum",
            processing_date: Some("2026-09-25"),
            privacy: None,
        }
    }
    #[tokio::test]
    async fn normalized_rows_use_column_names_and_retain_unknown_fields() {
        let temp = tempfile::tempdir().expect("temporary directory");
        let path = temp.path().join("segment.gz");
        fs::write(
            &path,
            include_bytes!("../tests/fixtures/appstore/reordered-unknown.tsv.gz"),
        )
        .await
        .expect("write fixture");
        let output = normalize(&path, &metadata())
            .await
            .expect("normalize fixture");
        let row: serde_json::Value = serde_json::from_str(output.trim()).expect("JSON row");
        assert_eq!(row["columns"]["Metric"], "4");
        assert_eq!(row["columns"]["Date"], "2026-09-25");
        assert_eq!(row["columns"]["Unknown"], "x");
        assert_eq!(row["processing_date"], "2026-09-25");
        assert!(row.get("url").is_none());
    }
    #[tokio::test]
    async fn malformed_row_rejects_entire_segment_and_empty_report_succeeds() {
        let temp = tempfile::tempdir().expect("temporary directory");
        let malformed = temp.path().join("malformed.gz");
        fs::write(
            &malformed,
            include_bytes!("../tests/fixtures/appstore/malformed-row.tsv.gz"),
        )
        .await
        .expect("write fixture");
        assert!(matches!(
            normalize(&malformed, &metadata()).await,
            Err(AnalyticsError::Parse("column count mismatch"))
        ));
        let empty = temp.path().join("empty.gz");
        fs::write(
            &empty,
            include_bytes!("../tests/fixtures/appstore/empty.tsv.gz"),
        )
        .await
        .expect("write fixture");
        assert_eq!(
            normalize(&empty, &metadata()).await.expect("empty report"),
            ""
        );
    }
    async fn fixture(bytes: &[u8], name: &'static str) -> Result<String, AnalyticsError> {
        let temp = tempfile::tempdir().expect("temporary directory");
        let path = temp.path().join("report.gz");
        fs::write(&path, bytes).await.expect("write fixture");
        let mut metadata = metadata();
        metadata.report_name = Some(name);
        metadata.variant = variant(name);
        metadata.privacy = privacy_context(Some(name));
        normalize(&path, &metadata).await
    }
    #[tokio::test]
    async fn session_variants_preserve_distinct_metrics_and_privacy_context() {
        for (name, bytes, expected_variant) in [
            (
                "App Sessions Standard",
                include_bytes!("../tests/fixtures/appstore/sessions-standard.tsv.gz").as_slice(),
                "standard",
            ),
            (
                "App Sessions Detailed",
                include_bytes!("../tests/fixtures/appstore/sessions-detailed.tsv.gz").as_slice(),
                "detailed",
            ),
        ] {
            let output = fixture(bytes, name).await.expect("session fixture");
            let row: serde_json::Value = serde_json::from_str(output.trim()).expect("JSON row");
            assert_eq!(row["session"]["variant"], expected_variant);
            assert_eq!(row["session"]["sessions"], 7);
            assert_eq!(row["session"]["total_session_duration"], 900);
            assert_eq!(row["session"]["unique_devices"], 5);
            assert!(row.get("crash").is_none());
            assert_eq!(row["processing_date"], "2026-09-25");
            assert_eq!(row["privacy"]["opted_in_users_only"], true);
            assert_eq!(row["privacy"]["minimum_users_for_report"], 5);
            assert_eq!(row["privacy"]["missing_rows_mean_zero"], false);
            if expected_variant == "detailed" {
                assert_eq!(row["session"]["source_info"], "example.com");
            } else {
                assert!(row["session"]["source_info"].is_null());
            }
        }
        assert_eq!(
            fixture(
                include_bytes!("../tests/fixtures/appstore/sessions-empty.tsv.gz"),
                "App Sessions Standard"
            )
            .await
            .expect("empty sessions"),
            ""
        );
        assert!(matches!(
            fixture(
                include_bytes!("../tests/fixtures/appstore/sessions-invalid-duration.tsv.gz"),
                "App Sessions Standard"
            )
            .await,
            Err(AnalyticsError::InvalidSessionValue(
                "Total Session Duration"
            ))
        ));
        assert!(matches!(
            fixture(
                include_bytes!("../tests/fixtures/appstore/sessions-missing-column.tsv.gz"),
                "App Sessions Standard"
            )
            .await,
            Err(AnalyticsError::MissingSessionColumn("Unique Devices"))
        ));
    }
    #[tokio::test]
    async fn crash_variants_preserve_distinct_metrics_and_privacy_context() {
        for (name, bytes, expected_variant) in [
            (
                "App Crashes",
                include_bytes!("../tests/fixtures/appstore/crashes-single.tsv.gz").as_slice(),
                "single",
            ),
            (
                "App Crashes Standard",
                include_bytes!("../tests/fixtures/appstore/crashes-standard.tsv.gz").as_slice(),
                "standard",
            ),
            (
                "App Crashes Detailed",
                include_bytes!("../tests/fixtures/appstore/crashes-detailed.tsv.gz").as_slice(),
                "detailed",
            ),
        ] {
            let output = fixture(bytes, name).await.expect("crash fixture");
            let row: serde_json::Value = serde_json::from_str(output.trim()).expect("JSON row");
            assert_eq!(row["crash"]["variant"], expected_variant);
            assert_eq!(row["variant"], expected_variant.to_ascii_uppercase());
            assert_eq!(row["crash"]["crashes"], 6);
            assert_eq!(row["crash"]["unique_devices"], 5);
            assert!(row.get("session").is_none());
            assert_eq!(row["processing_date"], "2026-09-25");
            assert_eq!(row["privacy"]["opted_in_users_only"], true);
            assert_eq!(row["privacy"]["missing_rows_mean_zero"], false);
        }
        assert_eq!(
            fixture(
                include_bytes!("../tests/fixtures/appstore/crashes-empty.tsv.gz"),
                "App Crashes Standard"
            )
            .await
            .expect("empty crashes"),
            ""
        );
        assert!(matches!(
            fixture(
                include_bytes!("../tests/fixtures/appstore/crashes-invalid-count.tsv.gz"),
                "App Crashes Standard"
            )
            .await,
            Err(AnalyticsError::InvalidCrashValue("Crashes"))
        ));
        assert!(matches!(
            fixture(
                include_bytes!("../tests/fixtures/appstore/crashes-missing-column.tsv.gz"),
                "App Crashes Standard"
            )
            .await,
            Err(AnalyticsError::MissingCrashColumn("Unique Devices"))
        ));
    }
    #[tokio::test]
    async fn installation_variants_preserve_events_download_types_and_nullable_dates() {
        for (name, bytes, expected_variant) in [
            (
                "App Store Installations and Deletions Standard",
                include_bytes!("../tests/fixtures/appstore/installations-standard.tsv.gz")
                    .as_slice(),
                "standard",
            ),
            (
                "App Store Installations and Deletions Detailed",
                include_bytes!("../tests/fixtures/appstore/installations-detailed.tsv.gz")
                    .as_slice(),
                "detailed",
            ),
        ] {
            let output = fixture(bytes, name).await.expect("installation fixture");
            let rows: Vec<serde_json::Value> = output
                .lines()
                .map(|line| serde_json::from_str(line).expect("JSON row"))
                .collect();
            assert_eq!(rows.len(), 5);
            for (row, download_type) in rows[..4].iter().zip([
                "first_time_download",
                "redownload",
                "manual_update",
                "restore",
            ]) {
                assert_eq!(row["installation"]["variant"], expected_variant);
                assert_eq!(row["installation"]["event"], "install");
                assert_eq!(row["installation"]["download_type"], download_type);
                assert!(row["installation"]["count"].is_u64());
                assert!(row["installation"]["unique_devices"].is_u64());
            }
            assert_eq!(rows[4]["installation"]["event"], "delete");
            assert_eq!(rows[0]["installation"]["app_download_date"], "2026-09-24");
            assert!(rows[1]["installation"]["app_download_date"].is_null());
            if expected_variant == "detailed" {
                assert_eq!(rows[0]["installation"]["source_info"], "example.com");
                assert_eq!(rows[0]["installation"]["campaign"], "campaign");
                assert_eq!(
                    rows[0]["installation"]["page_title"],
                    "Default Product Page"
                );
            } else {
                assert!(rows[0]["installation"]["source_info"].is_null());
                assert!(rows[0]["installation"]["campaign"].is_null());
                assert!(rows[0]["installation"]["page_title"].is_null());
            }
        }
    }
    #[tokio::test]
    async fn absent_installation_rows_do_not_create_zero_records() {
        assert_eq!(
            fixture(
                include_bytes!("../tests/fixtures/appstore/installations-empty.tsv.gz"),
                "App Store Installations and Deletions Standard"
            )
            .await
            .expect("empty report"),
            ""
        );
        assert!(matches!(
            fixture(
                include_bytes!("../tests/fixtures/appstore/installations-missing-column.tsv.gz"),
                "App Store Installations and Deletions Standard"
            )
            .await,
            Err(AnalyticsError::MissingInstallationColumn("Unique Devices"))
        ));
    }
    #[test]
    fn installation_unique_devices_and_variants_cannot_be_summed() {
        let base = BTreeMap::from([
            ("Date", "2026-09-25"),
            ("App Name", "Bleat"),
            ("App Apple Identifier", "123456789"),
            ("Event", "Install"),
            ("Download Type", "Redownload"),
            ("App Version", "1.0"),
            ("Device", "iPhone"),
            ("Platform Version", "26.0"),
            ("Source Type", "Unavailable"),
            ("Page Type", "No page"),
            ("App Download Date", ""),
            ("Territory", "US"),
            ("Counts", "6"),
            ("Unique Devices", "5"),
        ]);
        let standard =
            InstallationRow::parse(&base, InstallationVariant::Standard).expect("standard");
        let detailed =
            InstallationRow::parse(&base, InstallationVariant::Detailed).expect("detailed");
        assert!(matches!(
            InstallationRow::sum_counts(&[standard], true),
            Err(AnalyticsError::NonAdditiveUniqueDevices)
        ));
        assert!(matches!(
            InstallationRow::sum_counts(
                &[
                    InstallationRow::parse(&base, InstallationVariant::Standard).expect("standard"),
                    detailed
                ],
                false
            ),
            Err(AnalyticsError::MixedReportVariants)
        ));
        let mut deletion = base.clone();
        deletion.insert("Event", "Delete");
        assert!(matches!(
            InstallationRow::sum_counts(
                &[
                    InstallationRow::parse(&base, InstallationVariant::Standard).expect("install"),
                    InstallationRow::parse(&deletion, InstallationVariant::Standard)
                        .expect("delete"),
                ],
                false
            ),
            Err(AnalyticsError::MixedInstallationEvents)
        ));
    }
    #[tokio::test]
    async fn standard_downloads_decode_reordered_columns_and_keep_attribution_absent() {
        let output = fixture(
            include_bytes!("../tests/fixtures/appstore/downloads-standard-reordered.tsv.gz"),
            "App Store Downloads Standard",
        )
        .await
        .expect("standard fixture");
        let row: serde_json::Value = serde_json::from_str(output.trim()).expect("JSON row");
        assert_eq!(row["download"]["date"], "2026-09-25");
        assert_eq!(row["download"]["variant"], "standard");
        assert_eq!(row["download"]["download_type"], "first_time_download");
        assert_eq!(row["download"]["app_apple_identifier"], 123456789);
        assert_eq!(row["download"]["pre_order"], "no");
        assert_eq!(row["download"]["total_downloads"], 4);
        assert_eq!(row["columns"]["Future Field"], "future");
        assert!(row["download"]["source_info"].is_null());
    }
    #[tokio::test]
    async fn discovery_variants_preserve_event_classes_and_detailed_dimensions() {
        for (name, bytes, expected_variant) in [
            (
                "App Store Discovery and Engagement Standard",
                include_bytes!("../tests/fixtures/appstore/discovery-standard.tsv.gz").as_slice(),
                "standard",
            ),
            (
                "App Store Discovery and Engagement Detailed",
                include_bytes!("../tests/fixtures/appstore/discovery-detailed.tsv.gz").as_slice(),
                "detailed",
            ),
        ] {
            let output = fixture(bytes, name).await.expect("discovery fixture");
            let rows: Vec<serde_json::Value> = output
                .lines()
                .map(|line| serde_json::from_str(line).expect("JSON row"))
                .collect();
            assert_eq!(rows.len(), 3);
            for (row, event) in rows.iter().zip(["impression", "page_view", "tap"]) {
                assert_eq!(row["discovery"]["variant"], expected_variant);
                assert_eq!(row["discovery"]["event"], event);
                assert!(row["discovery"]["count"].is_u64());
                assert!(row["discovery"]["unique_count"].is_u64());
                assert_eq!(row["discovery"]["app_apple_identifier"], 123456789);
                if expected_variant == "detailed" {
                    assert_eq!(row["discovery"]["source_info"], "example.com");
                    assert_eq!(row["discovery"]["campaign"], "launch");
                    assert_eq!(row["discovery"]["page_title"], "Default Product Page");
                } else {
                    assert!(row["discovery"]["source_info"].is_null());
                    assert!(row["discovery"]["campaign"].is_null());
                    assert!(row["discovery"]["page_title"].is_null());
                }
            }
        }
    }
    #[tokio::test]
    async fn purchase_variants_preserve_refunds_precise_amounts_and_dimensions() {
        let standard = fixture(
            include_bytes!("../tests/fixtures/appstore/purchases-standard.tsv.gz"),
            "App Store Purchases Standard",
        )
        .await
        .expect("standard purchases");
        let rows: Vec<serde_json::Value> = standard
            .lines()
            .map(|line| serde_json::from_str(line).expect("JSON row"))
            .collect();
        assert_eq!(rows.len(), 3);
        assert_eq!(rows[0]["purchase"]["variant"], "standard");
        assert_eq!(rows[0]["purchase"]["purchase_type"], "app_purchase");
        assert!(rows[0]["purchase"]["proceeds_usd"].is_number());
        assert!(rows[0]["purchase"]["sales_usd"].is_number());
        assert_eq!(rows[0]["purchase"]["proceeds_usd"].to_string(), "1.20");
        assert_eq!(rows[0]["purchase"]["sales_usd"].to_string(), "1.99");
        assert!(rows[0]["purchase"]["source_info"].is_null());
        assert_eq!(rows[1]["purchase"]["purchases"], -1);
        assert_eq!(rows[1]["purchase"]["proceeds_usd"].to_string(), "-0.60");
        assert_eq!(rows[2]["purchase"]["purchases"], 0);
        assert_eq!(rows[2]["purchase"]["sales_usd"].to_string(), "-0.49");

        let detailed = fixture(
            include_bytes!("../tests/fixtures/appstore/purchases-detailed.tsv.gz"),
            "App Store Purchases Detailed",
        )
        .await
        .expect("detailed purchases");
        let row: serde_json::Value = serde_json::from_str(detailed.trim()).expect("JSON row");
        assert_eq!(row["purchase"]["variant"], "detailed");
        assert_eq!(row["purchase"]["purchase_type"], "in_app_purchases");
        assert_eq!(row["purchase"]["content_apple_identifier"], 987654321);
        assert_eq!(row["purchase"]["source_info"], "example.com");
        assert_eq!(row["purchase"]["campaign"], "launch");
        assert_eq!(row["purchase"]["app_download_date"], "2026-09-24");
    }
    #[tokio::test]
    async fn empty_purchases_succeed_and_missing_columns_fail() {
        assert_eq!(
            fixture(
                include_bytes!("../tests/fixtures/appstore/purchases-empty.tsv.gz"),
                "App Store Purchases Standard",
            )
            .await
            .expect("empty purchases"),
            ""
        );
        assert!(matches!(
            fixture(
                include_bytes!("../tests/fixtures/appstore/purchases-missing-column.tsv.gz"),
                "App Store Purchases Standard",
            )
            .await,
            Err(AnalyticsError::MissingPurchaseColumn("Paying Users"))
        ));
    }
    #[test]
    fn paying_users_and_mixed_variants_cannot_be_summed() {
        let columns: BTreeMap<&str, &str> = [
            ("Date", "2026-09-25"),
            ("App Name", "Bleat"),
            ("App Apple Identifier", "123456789"),
            ("Purchase Type", "App purchase"),
            ("Content Name", "Bleat"),
            ("Content Apple Identifier", "123456789"),
            ("Payment Method", "Credit card"),
            ("Device", "iPhone"),
            ("Platform Version", "26.0"),
            ("Source Type", "App Store search"),
            ("Page Type", "Product page"),
            ("App Download Date", ""),
            ("Pre-Order", "No"),
            ("Territory", "AU"),
            ("Purchases", "-1"),
            ("Proceeds in USD", "-0.60"),
            ("Sales in USD", "-0.99"),
            ("Paying Users", "1"),
        ]
        .into();
        let standard = PurchaseRow::parse(&columns, PurchaseVariant::Standard).expect("standard");
        let detailed = PurchaseRow::parse(&columns, PurchaseVariant::Detailed).expect("detailed");
        assert!(matches!(
            PurchaseRow::sum_purchases(&[standard], true),
            Err(AnalyticsError::NonAdditivePayingUsers)
        ));
        assert!(matches!(
            PurchaseRow::sum_purchases(
                &[
                    detailed,
                    PurchaseRow::parse(&columns, PurchaseVariant::Standard).expect("standard")
                ],
                false
            ),
            Err(AnalyticsError::MixedReportVariants)
        ));
        assert_eq!(
            PurchaseRow::sum_purchases(
                &[PurchaseRow::parse(&columns, PurchaseVariant::Standard).expect("standard")],
                false
            )
            .expect("signed purchases"),
            -1
        );
    }
    #[tokio::test]
    async fn discovery_empty_and_invalid_segments_do_not_invent_zero_rows() {
        assert_eq!(
            fixture(
                include_bytes!("../tests/fixtures/appstore/discovery-empty.tsv.gz"),
                "App Store Discovery and Engagement Standard"
            )
            .await
            .expect("empty report"),
            ""
        );
        assert!(matches!(
            fixture(
                include_bytes!("../tests/fixtures/appstore/discovery-missing-column.tsv.gz"),
                "App Store Discovery and Engagement Standard"
            )
            .await,
            Err(AnalyticsError::MissingDiscoveryColumn("Unique Counts"))
        ));
        assert!(matches!(
            fixture(
                include_bytes!("../tests/fixtures/appstore/discovery-unknown-event.tsv.gz"),
                "App Store Discovery and Engagement Standard"
            )
            .await,
            Err(AnalyticsError::UnsupportedDiscoveryEvent)
        ));
    }
    #[test]
    fn discovery_unique_counts_and_variants_cannot_be_summed() {
        let columns: BTreeMap<&str, &str> = [
            ("Date", "2026-09-25"),
            ("App Name", "Bleat"),
            ("App Apple Identifier", "123456789"),
            ("Event", "Impression"),
            ("Page Type", "No page"),
            ("Source Type", "App Store search"),
            ("Engagement Type", ""),
            ("Device", "iPhone"),
            ("Platform Version", "26.0"),
            ("Territory", "AU"),
            ("Counts", "7"),
            ("Unique Counts", "5"),
        ]
        .into();
        let standard =
            DiscoveryRow::parse(&columns, DiscoveryVariant::Standard).expect("standard row");
        let detailed =
            DiscoveryRow::parse(&columns, DiscoveryVariant::Detailed).expect("detailed row");
        assert!(matches!(
            DiscoveryRow::sum_counts(&[standard], true),
            Err(AnalyticsError::NonAdditiveUniqueCounts)
        ));
        assert!(matches!(
            DiscoveryRow::sum_counts(
                &[
                    DiscoveryRow::parse(&columns, DiscoveryVariant::Standard)
                        .expect("standard row"),
                    detailed
                ],
                false
            ),
            Err(AnalyticsError::MixedReportVariants)
        ));
    }
    #[tokio::test]
    async fn downloads_accept_case_insensitive_report_values() {
        let output = fixture(
            include_bytes!("../tests/fixtures/appstore/downloads-case-insensitive.tsv.gz"),
            "App Store Downloads Standard",
        )
        .await
        .expect("case-insensitive fixture");
        let row: serde_json::Value = serde_json::from_str(output.trim()).expect("JSON row");
        assert_eq!(row["download"]["download_type"], "redownload");
        assert_eq!(row["download"]["pre_order"], "yes");
        assert_eq!(row["download"]["total_downloads"], 4);
        for (value, expected) in [
            ("FIRST-TIME DOWNLOAD", DownloadType::FirstTimeDownload),
            ("manual UPDATE", DownloadType::ManualUpdate),
            ("AUTO-UPDATE", DownloadType::AutoUpdate),
            ("restore", DownloadType::Restore),
        ] {
            assert_eq!(
                DownloadType::parse(value).expect("case-insensitive type"),
                expected
            );
        }
        assert_eq!(
            PreOrderState::parse("nO").expect("case-insensitive flag"),
            PreOrderState::No
        );
    }
    #[tokio::test]
    async fn detailed_downloads_remain_distinct_and_classify_events() {
        let output = fixture(
            include_bytes!("../tests/fixtures/appstore/downloads-detailed.tsv.gz"),
            "App Store Downloads Detailed",
        )
        .await
        .expect("detailed fixture");
        let rows: Vec<serde_json::Value> = output
            .lines()
            .map(|line| serde_json::from_str(line).expect("JSON row"))
            .collect();
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0]["download"]["variant"], "detailed");
        assert_eq!(rows[0]["download"]["source_info"], "example.com");
        assert_eq!(rows[1]["download"]["download_type"], "redownload");
        assert_eq!(rows[1]["download"]["total_downloads"], 2);
        for (value, expected) in [
            ("Manual update", false),
            ("Auto-update", false),
            ("Restore", false),
            ("First-time Download", true),
            ("Redownload", true),
        ] {
            assert_eq!(
                DownloadType::parse(value)
                    .expect("supported type")
                    .counts_toward_total(),
                expected
            );
        }
    }
    #[tokio::test]
    async fn downloads_validate_required_values_and_accept_empty_report() {
        assert_eq!(
            fixture(
                include_bytes!("../tests/fixtures/appstore/downloads-empty.tsv.gz"),
                "App Store Downloads Standard",
            )
            .await
            .expect("empty report"),
            ""
        );
        assert!(matches!(
            fixture(
                include_bytes!("../tests/fixtures/appstore/downloads-missing-column.tsv.gz"),
                "App Store Downloads Standard",
            )
            .await,
            Err(AnalyticsError::MissingDownloadColumn("Counts"))
        ));
        assert!(matches!(
            fixture(
                include_bytes!("../tests/fixtures/appstore/downloads-unknown-type.tsv.gz"),
                "App Store Downloads Standard",
            )
            .await,
            Err(AnalyticsError::UnsupportedDownloadType)
        ));
        assert!(matches!(
            fixture(
                include_bytes!("../tests/fixtures/appstore/downloads-blank-required.tsv.gz"),
                "App Store Downloads Standard",
            )
            .await,
            Err(AnalyticsError::InvalidDownloadValue("Device"))
        ));
        let base: BTreeMap<&str, &str> = [
            ("Date", "2026-09-25"),
            ("App Name", "Bleat"),
            ("App Apple Identifier", "123456789"),
            ("Download Type", "Redownload"),
            ("App Version", "1.0"),
            ("Device", "iPhone"),
            ("Platform Version", "26.0"),
            ("Source Type", "App Store search"),
            ("Page Type", "Product page"),
            ("Pre-Order", "No"),
            ("Territory", "AU"),
            ("Counts", "2"),
        ]
        .into();
        for field in [
            "App Name",
            "App Version",
            "Device",
            "Platform Version",
            "Source Type",
            "Page Type",
            "Pre-Order",
            "Territory",
        ] {
            let mut columns = base.clone();
            columns.insert(field, "");
            assert!(
                matches!(DownloadRow::parse(&columns, DownloadVariant::Standard), Err(AnalyticsError::InvalidDownloadValue(name)) if name == field)
            );
            columns.insert(field, " \t ");
            assert!(
                matches!(DownloadRow::parse(&columns, DownloadVariant::Standard), Err(AnalyticsError::InvalidDownloadValue(name)) if name == field)
            );
        }
        let mut invalid_pre_order = base;
        invalid_pre_order.insert("Pre-Order", "unknown");
        assert!(matches!(
            DownloadRow::parse(&invalid_pre_order, DownloadVariant::Standard),
            Err(AnalyticsError::InvalidDownloadValue("Pre-Order"))
        ));
    }
    #[tokio::test]
    async fn cached_legacy_download_segment_is_renormalized_without_network() {
        let temp = tempfile::tempdir().expect("temporary directory");
        let dir = temp.path();
        let bytes =
            include_bytes!("../tests/fixtures/appstore/downloads-standard-reordered.tsv.gz");
        let checksum = Md5::digest(bytes)
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect::<String>();
        let folder = dir.join("segments/request/report/instance");
        fs::create_dir_all(&folder).await.expect("create folder");
        let raw = folder.join("segment.gz");
        let normalized = folder.join("segment.ndjson");
        fs::write(&raw, bytes).await.expect("write cached raw");
        fs::write(&normalized, b"{\"columns\":{}}\n")
            .await
            .expect("write old normalized output");
        let key = format!("segment:{checksum}");
        let legacy = serde_json::json!({key: {"raw": "segments/request/report/instance/segment.gz", "normalized": "segments/request/report/instance/segment.ndjson"}});
        fs::write(
            dir.join("manifest.json"),
            serde_json::to_vec(&legacy).expect("JSON"),
        )
        .await
        .expect("write legacy manifest");
        let client = AnalyticsClient {
            http: Client::new(),
            signing_key: EncodingKey::from_secret(b"unused"),
            key_id: String::new(),
            issuer: String::new(),
            base: Url::parse(BASE).expect("base URL"),
            app_id: String::new(),
        };
        let resource = |id: &str, attributes: Attributes| Resource {
            id: id.into(),
            attributes,
        };
        let request = resource("request", Attributes::default());
        let report = resource(
            "report",
            Attributes {
                name: Some("App Store Downloads Standard".into()),
                ..Attributes::default()
            },
        );
        let instance = resource(
            "instance",
            Attributes {
                processing_date: Some("2026-09-25".into()),
                ..Attributes::default()
            },
        );
        let segment = resource(
            "segment",
            Attributes {
                checksum: Some(checksum),
                size_in_bytes: Some(bytes.len() as i64),
                ..Attributes::default()
            },
        );
        assert!(
            client
                .save_segment(
                    dir,
                    AccessType::Ongoing,
                    &request,
                    &report,
                    &instance,
                    &segment
                )
                .await
                .expect("renormalize cached segment")
        );
        let output = fs::read_to_string(&normalized)
            .await
            .expect("read normalized output");
        let row: serde_json::Value = serde_json::from_str(output.trim()).expect("typed row");
        assert_eq!(row["download"]["total_downloads"], 4);
        assert!(
            !client
                .save_segment(
                    dir,
                    AccessType::Ongoing,
                    &request,
                    &report,
                    &instance,
                    &segment
                )
                .await
                .expect("already normalized")
        );
    }
    #[test]
    fn integrity_rejects_size_and_checksum() {
        let bytes = b"abc";
        let digest = Md5::digest(bytes)
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect::<String>();
        assert!(verify(bytes, 3, &digest).is_ok());
        assert!(matches!(
            verify(bytes, 4, &digest),
            Err(AnalyticsError::SizeMismatch)
        ));
        assert!(matches!(
            verify(bytes, 3, "00000000000000000000000000000000"),
            Err(AnalyticsError::ChecksumMismatch)
        ));
    }
    #[test]
    fn safe_identifiers_reject_paths() {
        assert!(safe_id("abc-123").is_ok());
        assert!(safe_id("../escape").is_err());
    }
}
