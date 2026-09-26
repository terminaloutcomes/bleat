use chrono::{DateTime, Datelike, Timelike, Utc};
use thiserror::Error;

#[derive(Debug, Error, PartialEq, Eq)]
pub enum VersionError {
    #[error("BLEAT_BUILD_NUMBER must contain one to three dot-separated integers")]
    InvalidBuildNumber,
    #[error("BLEAT_MARKETING_VERSION is required when BLEAT_BUILD_NUMBER is not a UTC timestamp")]
    MissingMarketingVersionForCustomBuild,
    #[error("BLEAT_MARKETING_VERSION must use YYYY.MM.DD")]
    InvalidMarketingVersionFormat,
    #[error("BLEAT_MARKETING_VERSION must contain a valid calendar date")]
    InvalidMarketingVersionDate,
}

impl VersionError {
    pub const fn exit_code(&self) -> u8 {
        match self {
            Self::InvalidBuildNumber => 64,
            Self::MissingMarketingVersionForCustomBuild => 65,
            Self::InvalidMarketingVersionFormat => 66,
            Self::InvalidMarketingVersionDate => 67,
        }
    }
}

pub fn validate_build_number(value: &str) -> Result<(), VersionError> {
    let mut components = value.split('.');
    let valid = components.by_ref().take(4).collect::<Vec<_>>();
    if (1..=3).contains(&valid.len())
        && valid.iter().all(|component| {
            !component.is_empty() && component.bytes().all(|byte| byte.is_ascii_digit())
        })
    {
        Ok(())
    } else {
        Err(VersionError::InvalidBuildNumber)
    }
}

pub fn resolve_build_number(
    override_value: Option<&str>,
    now: DateTime<Utc>,
) -> Result<String, VersionError> {
    let value = override_value
        .filter(|value| !value.is_empty())
        .map(str::to_owned)
        .unwrap_or_else(|| {
            format!(
                "{:04}{:02}{:02}.{:02}{:02}.{:02}",
                now.year(),
                now.month(),
                now.day(),
                now.hour(),
                now.minute(),
                now.second()
            )
        });
    validate_build_number(&value)?;
    Ok(value)
}

pub fn resolve_marketing_version(
    build: &str,
    override_value: Option<&str>,
) -> Result<String, VersionError> {
    let version = if let Some(value) = override_value.filter(|value| !value.is_empty()) {
        value.to_owned()
    } else if build.len() == 16
        && build.as_bytes()[8] == b'.'
        && build.as_bytes()[13] == b'.'
        && build
            .bytes()
            .enumerate()
            .all(|(index, byte)| index == 8 || index == 13 || byte.is_ascii_digit())
    {
        format!("{}.{}.{}", &build[..4], &build[4..6], &build[6..8])
    } else {
        return Err(VersionError::MissingMarketingVersionForCustomBuild);
    };

    let bytes = version.as_bytes();
    if bytes.len() != 10
        || bytes[4] != b'.'
        || bytes[7] != b'.'
        || !bytes
            .iter()
            .enumerate()
            .all(|(index, byte)| index == 4 || index == 7 || byte.is_ascii_digit())
    {
        return Err(VersionError::InvalidMarketingVersionFormat);
    }
    let year = version[..4]
        .parse::<i32>()
        .map_err(|_| VersionError::InvalidMarketingVersionFormat)?;
    let month = version[5..7]
        .parse::<u32>()
        .map_err(|_| VersionError::InvalidMarketingVersionFormat)?;
    let day = version[8..10]
        .parse::<u32>()
        .map_err(|_| VersionError::InvalidMarketingVersionFormat)?;
    if chrono::NaiveDate::from_ymd_opt(year, month, day).is_none() {
        return Err(VersionError::InvalidMarketingVersionDate);
    }
    Ok(version)
}
