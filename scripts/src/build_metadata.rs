//! Generate an input plist before Xcode processes and signs the app bundle.

use std::{fs, path::Path, process::Command};

use chrono::{SecondsFormat, Utc};
use plist::Value;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum MetadataError {
    #[error("metadata.git.execute: could not start Git: {0}")]
    GitExecute(std::io::Error),
    #[error("metadata.git.exit: Git could not resolve HEAD (exit {0:?})")]
    GitExit(Option<i32>),
    #[error("metadata.git.commit: Git returned an invalid commit identifier")]
    InvalidCommit,
    #[error("metadata.template.read: could not read the Info.plist template: {0}")]
    Read(std::io::Error),
    #[error("metadata.template.decode: could not decode the Info.plist template: {0}")]
    Decode(plist::Error),
    #[error("metadata.template.dictionary: Info.plist must contain a dictionary")]
    NotDictionary,
    #[error("metadata.output.encode: could not encode the generated Info.plist: {0}")]
    Encode(plist::Error),
    #[error("metadata.output.write: could not write the generated Info.plist: {0}")]
    Write(std::io::Error),
}

pub fn write_metadata(
    repository: &Path,
    template: &Path,
    output: &Path,
) -> Result<(), MetadataError> {
    let git = Command::new("git")
        .arg("-C")
        .arg(repository)
        .args(["rev-parse", "--short=8", "--verify", "HEAD"])
        .output()
        .map_err(MetadataError::GitExecute)?;
    if !git.status.success() {
        // Git's stderr can contain sensitive checkout paths; retain the exit cause only.
        return Err(MetadataError::GitExit(git.status.code()));
    }
    let commit = std::str::from_utf8(&git.stdout)
        .map_err(|_| MetadataError::InvalidCommit)?
        .trim();
    if !(8..=64).contains(&commit.len()) || !commit.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err(MetadataError::InvalidCommit);
    }

    let bytes = fs::read(template).map_err(MetadataError::Read)?;
    let mut plist =
        Value::from_reader(std::io::Cursor::new(bytes)).map_err(MetadataError::Decode)?;
    let fields = plist
        .as_dictionary_mut()
        .ok_or(MetadataError::NotDictionary)?;
    fields.insert("BleatGitCommit".into(), Value::String(commit.into()));
    fields.insert(
        "BleatBuildDate".into(),
        Value::String(Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true)),
    );
    let mut generated = Vec::new();
    plist
        .to_writer_xml(&mut generated)
        .map_err(MetadataError::Encode)?;
    fs::write(output, generated).map_err(MetadataError::Write)
}
