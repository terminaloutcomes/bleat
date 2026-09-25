//! Daily App Store Connect analytics report lifecycle and local dump.
use async_compression::tokio::bufread::GzipDecoder;
use base64::Engine;
use chrono::{Datelike, Utc};
use jsonwebtoken::{Algorithm, EncodingKey, Header, encode};
use md5::{Digest, Md5};
use reqwest::{Client, StatusCode, Url};
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use std::{
    collections::{BTreeMap, BTreeSet},
    path::{Path, PathBuf},
};
use thiserror::Error;
use tokio::{
    fs,
    io::{AsyncReadExt, AsyncWriteExt, BufReader},
};

const BASE: &str = "https://api.appstoreconnect.apple.com/v1/";
const DEFAULT_DIR: &str = ".build/appstore-reports";

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
    #[error("local storage failed: {0}")]
    Storage(#[from] std::io::Error),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
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
        let path = dir.join("snapshots.json");
        let mut snapshots: BTreeMap<String, String> = load_json_or_default(&path).await?;
        let requests = self.requests().await?;
        if let Some(id) = snapshots.get(&month) {
            if requests
                .iter()
                .any(|r| &r.id == id && r.access() == Some(AccessType::OneTimeSnapshot))
            {
                return Ok(id.clone());
            }
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
            load_json_or_default::<BTreeMap<String, String>>(
                &Path::new(DEFAULT_DIR).join("snapshots.json"),
            )
            .await?
            .get(&current_month())
            .cloned()
        } else {
            None
        };
        let request = requests
            .into_iter()
            .filter(|r| {
                r.access() == Some(access)
                    && (access != AccessType::Ongoing
                        || r.attributes.stopped_due_to_inactivity != Some(true))
            })
            .filter(|r| snapshot_id.as_ref().is_none_or(|id| &r.id == id))
            .max_by(|a, b| a.id.cmp(&b.id))
            .ok_or(AnalyticsError::NoRequest)?;
        let mut count = 0;
        for report in self
            .pages::<Resource>(&format!(
                "analyticsReportRequests/{}/reports?limit=200",
                request.id
            ))
            .await?
        {
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
                for segment in self
                    .pages::<Resource>(&format!(
                        "analyticsReportInstances/{}/segments?limit=200",
                        instance.id
                    ))
                    .await?
                {
                    if self
                        .save_segment(dir, access, &request, &report, &instance, &segment)
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
        if manifest.get(&key).is_some_and(|entry| {
            entry.raw == relative(dir, &raw) && entry.normalized == relative(dir, &normalized)
        }) && fs::try_exists(&raw).await?
            && fs::try_exists(&normalized).await?
        {
            let bytes = fs::read(&raw).await?;
            if verify(&bytes, size, checksum).is_ok() {
                return Ok(false);
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
        };
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
        manifest.insert(
            key,
            ManifestEntry {
                raw: relative(dir, &raw),
                normalized: relative(dir, &normalized),
            },
        );
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
#[derive(Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Attributes {
    access_type: Option<String>,
    stopped_due_to_inactivity: Option<bool>,
    name: Option<String>,
    granularity: Option<String>,
    processing_date: Option<String>,
    checksum: Option<String>,
    size_in_bytes: Option<i64>,
    url: Option<String>,
}
impl Resource {
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
}
#[derive(Serialize)]
struct Row<'a> {
    #[serde(flatten)]
    metadata: &'a Metadata<'a>,
    columns: BTreeMap<&'a str, &'a str>,
}
fn variant(name: &str) -> Option<&'static str> {
    if name.ends_with(" Detailed") {
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
    let mut output = String::new();
    for line in lines {
        let values: Vec<&str> = line.split('\t').collect();
        if values.len() != names.len() {
            return Err(AnalyticsError::Parse("column count mismatch"));
        }
        let columns = names.iter().copied().zip(values).collect();
        output.push_str(&serde_json::to_string(&Row { metadata, columns })?);
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
