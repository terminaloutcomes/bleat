use std::{fs, path::Path, process::Command};

use serde_json::Value;
use thiserror::Error;
use yaml_rust::YamlLoader;

use crate::release_versions::{VersionError, resolve_marketing_version};

#[derive(Debug, Error)]
pub enum ReleaseVersionError {
    #[error("could not read {file}: {source}")]
    Read {
        file: &'static str,
        source: std::io::Error,
    },
    #[error("project.yml must define one BleatApp MARKETING_VERSION")]
    ProjectInvalid,
    #[error("could not decode Bleat.xcodeproj/project.pbxproj")]
    GeneratedProjectInvalid,
    #[error("{0}")]
    InvalidVersion(#[from] VersionError),
    #[error(
        "requested version {requested} differs from project.yml version {project}; bump project.yml, regenerate Xcode, and update CHANGELOG.md first"
    )]
    RequestedMismatch { requested: String, project: String },
    #[error(
        "generated Debug and Release versions must both match project.yml; run xcodegen generate"
    )]
    GeneratedMismatch,
    #[error(
        "CURRENT_PROJECT_VERSION must be a UTC timestamp matching MARKETING_VERSION in project.yml and generated Xcode settings"
    )]
    BuildMismatch,
    #[error("the effective build number must be a UTC timestamp on the marketing-version date")]
    EffectiveBuildMismatch,
    #[error("could not decode Bleat.app/Info.plist")]
    BuiltMetadataInvalid,
    #[error("Bleat.app/Info.plist is missing {0}")]
    BuiltMetadataMissing(&'static str),
    #[error("Bleat.app/Info.plist {0} differs from the requested build")]
    BuiltMetadataMismatch(&'static str),
    #[error("CHANGELOG.md must start with exactly one dated section for {0}, with release notes")]
    ChangelogMismatch(String),
}

pub fn validate_effective_build(version: &str, build: &str) -> Result<(), ReleaseVersionError> {
    let build_version = match resolve_marketing_version(build, None) {
        Ok(version) => version,
        Err(VersionError::MissingMarketingVersionForCustomBuild) => {
            return Err(ReleaseVersionError::EffectiveBuildMismatch);
        }
        Err(error) => return Err(error.into()),
    };
    if build_version != version {
        return Err(ReleaseVersionError::EffectiveBuildMismatch);
    }
    Ok(())
}

pub fn validate_built_app(
    path: &Path,
    version: &str,
    build: &str,
) -> Result<(), ReleaseVersionError> {
    let data = fs::read(path).map_err(|source| ReleaseVersionError::Read {
        file: "Bleat.app/Info.plist",
        source,
    })?;
    let value = plist::Value::from_reader(std::io::Cursor::new(data))
        .map_err(|_| ReleaseVersionError::BuiltMetadataInvalid)?;
    let values = value
        .as_dictionary()
        .ok_or(ReleaseVersionError::BuiltMetadataInvalid)?;
    for (key, expected) in [
        ("CFBundleShortVersionString", version),
        ("CFBundleVersion", build),
    ] {
        let actual = values
            .get(key)
            .and_then(plist::Value::as_string)
            .ok_or(ReleaseVersionError::BuiltMetadataMissing(key))?;
        if actual != expected {
            return Err(ReleaseVersionError::BuiltMetadataMismatch(key));
        }
    }
    Ok(())
}

pub fn validate_repository(
    root: &Path,
    requested: Option<&str>,
) -> Result<String, ReleaseVersionError> {
    let read = |file| {
        fs::read_to_string(root.join(file))
            .map_err(|source| ReleaseVersionError::Read { file, source })
    };
    let project = read("project.yml")?;
    let changelog = read("CHANGELOG.md")?;
    let output = Command::new("plutil")
        .args(["-convert", "json", "-o", "-"])
        .arg(root.join("Bleat.xcodeproj/project.pbxproj"))
        .output()
        .map_err(|_| ReleaseVersionError::GeneratedProjectInvalid)?;
    if !output.status.success() {
        return Err(ReleaseVersionError::GeneratedProjectInvalid);
    }
    let generated = serde_json::from_slice(&output.stdout)
        .map_err(|_| ReleaseVersionError::GeneratedProjectInvalid)?;
    validate_metadata(&project, &generated, &changelog, requested)
}

pub fn validate_metadata(
    project: &str,
    generated: &Value,
    changelog: &str,
    requested: Option<&str>,
) -> Result<String, ReleaseVersionError> {
    let documents =
        YamlLoader::load_from_str(project).map_err(|_| ReleaseVersionError::ProjectInvalid)?;
    let [document] = documents.as_slice() else {
        return Err(ReleaseVersionError::ProjectInvalid);
    };
    let version = document["targets"]["BleatApp"]["settings"]["base"]["MARKETING_VERSION"]
        .as_str()
        .ok_or(ReleaseVersionError::ProjectInvalid)?;
    resolve_marketing_version("1", Some(version))?;
    let build = document["targets"]["BleatApp"]["settings"]["base"]["CURRENT_PROJECT_VERSION"]
        .as_str()
        .ok_or(ReleaseVersionError::BuildMismatch)?;
    if let Some(requested) = requested {
        resolve_marketing_version("1", Some(requested))?;
        if requested != version {
            return Err(ReleaseVersionError::RequestedMismatch {
                requested: requested.to_owned(),
                project: version.to_owned(),
            });
        }
    }
    if resolve_marketing_version(build, None)? != version {
        return Err(ReleaseVersionError::BuildMismatch);
    }
    let objects = generated["objects"]
        .as_object()
        .ok_or(ReleaseVersionError::GeneratedProjectInvalid)?;
    let configurations: Vec<_> = objects
        .values()
        .filter(|object| object["isa"] == "XCBuildConfiguration")
        .filter(|object| !object["buildSettings"]["MARKETING_VERSION"].is_null())
        .collect();
    if configurations.len() != 2
        || !["Debug", "Release"].iter().all(|name| {
            configurations.iter().any(|object| {
                object["name"] == *name && object["buildSettings"]["MARKETING_VERSION"] == version
            })
        })
    {
        return Err(ReleaseVersionError::GeneratedMismatch);
    }
    if configurations
        .iter()
        .any(|object| object["buildSettings"]["CURRENT_PROJECT_VERSION"] != build)
    {
        return Err(ReleaseVersionError::BuildMismatch);
    }
    let headings: Vec<_> = changelog
        .lines()
        .filter_map(|line| line.strip_prefix("## "))
        .collect();
    let heading = format!("{version} - {}", version.replace('.', "-"));
    let section = changelog
        .split_once(&format!("## {heading}\n"))
        .map(|(_, remainder)| remainder.split("\n## ").next().unwrap_or_default());
    if headings.first().copied() != Some(heading.as_str())
        || headings
            .iter()
            .filter(|entry| entry.split(" - ").next() == Some(version))
            .count()
            != 1
        || !section.is_some_and(|section| {
            section
                .lines()
                .any(|line| line.starts_with("- ") && line.len() > 2)
        })
    {
        return Err(ReleaseVersionError::ChangelogMismatch(version.to_owned()));
    }
    Ok(version.to_owned())
}
