//! Scoped name/record parity. This is not semantic review or execution evidence.
use std::{collections::BTreeSet, fs, path::Path};

use regex::Regex;
use serde_json::Value;
use thiserror::Error;

const CORE: &str = "TestSupport/TestAudit/core.json";
const OTHER: &str = "TestSupport/TestAudit/other.json";
const INDEX: &str = "TestSupport/TestAudit/source-index.json";

#[derive(Debug, Error)]
pub enum AuditInventoryError {
    #[error("cannot read {path}: {source}")]
    Read {
        path: String,
        source: std::io::Error,
    },
    #[error("invalid JSON in {path}: {source}")]
    Json {
        path: String,
        source: serde_json::Error,
    },
    #[error("invalid audit shape: {0}")]
    Shape(String),
    #[error("missing {kind}: {identity}")]
    Missing {
        kind: &'static str,
        identity: String,
    },
    #[error("duplicate {kind}: {identity}")]
    Duplicate {
        kind: &'static str,
        identity: String,
    },
    #[error("incomplete review for {identity}: {field}")]
    Review { identity: String, field: String },
    #[error("source no longer declares {identity}")]
    StaleSource { identity: String },
    #[error("unsupported Rust test declaration in {0}; reconcile source discovery explicitly")]
    RustDeclaration(String),
    #[error("invalid declaration matcher: {0}")]
    Matcher(#[from] regex::Error),
}

#[derive(Debug, PartialEq, Eq)]
pub struct AuditCoverage {
    pub host_functions: usize,
    pub rust_functions: usize,
}

fn read(root: &Path, relative: &str) -> Result<String, AuditInventoryError> {
    fs::read_to_string(root.join(relative)).map_err(|source| AuditInventoryError::Read {
        path: relative.to_owned(),
        source,
    })
}

fn json(root: &Path, relative: &str) -> Result<Value, AuditInventoryError> {
    serde_json::from_str(&read(root, relative)?).map_err(|source| AuditInventoryError::Json {
        path: relative.to_owned(),
        source,
    })
}

fn array<'a>(value: &'a Value, key: &str) -> Result<&'a Vec<Value>, AuditInventoryError> {
    value[key]
        .as_array()
        .ok_or_else(|| AuditInventoryError::Shape(key.to_owned()))
}

fn text<'a>(value: &'a Value, identity: &str, field: &str) -> Result<&'a str, AuditInventoryError> {
    let candidate = value.as_str().unwrap_or_default().trim();
    if candidate.is_empty()
        || matches!(
            candidate.to_ascii_lowercase().as_str(),
            "todo" | "tbd" | "placeholder" | "pending" | "n/a"
        )
    {
        return Err(AuditInventoryError::Review {
            identity: identity.to_owned(),
            field: field.to_owned(),
        });
    }
    Ok(candidate)
}

fn decision(value: &Value, identity: &str, field: &str) -> Result<(), AuditInventoryError> {
    match text(value, identity, field)? {
        "keep" | "fix" | "follow_up" | "follow-up" => Ok(()),
        _ => Err(AuditInventoryError::Review {
            identity: identity.to_owned(),
            field: field.to_owned(),
        }),
    }
}

fn one<'a>(
    matches: Vec<&'a Value>,
    kind: &'static str,
    identity: &str,
) -> Result<&'a Value, AuditInventoryError> {
    match matches.as_slice() {
        [row] => Ok(row),
        [] => Err(AuditInventoryError::Missing {
            kind,
            identity: identity.to_owned(),
        }),
        _ => Err(AuditInventoryError::Duplicate {
            kind,
            identity: identity.to_owned(),
        }),
    }
}

fn index_entry(index: &[Value], path: &str, name: &str) -> Result<(), AuditInventoryError> {
    let identity = format!("{path}::{name}");
    one(
        index
            .iter()
            .filter(|row| row["path"] == path && row["name"] == name)
            .collect(),
        "source-index entry",
        &identity,
    )?;
    Ok(())
}

fn rules(value: &Value, identity: &str) -> Result<(), AuditInventoryError> {
    for number in 1..=9 {
        text(
            &value[number.to_string()],
            identity,
            &format!("rule {number}"),
        )?;
    }
    Ok(())
}

fn rust_files(
    root: &Path,
    directory: &str,
    output: &mut Vec<String>,
) -> Result<(), AuditInventoryError> {
    let entries =
        fs::read_dir(root.join(directory)).map_err(|source| AuditInventoryError::Read {
            path: directory.to_owned(),
            source,
        })?;
    for entry in entries {
        let entry = entry.map_err(|source| AuditInventoryError::Read {
            path: directory.to_owned(),
            source,
        })?;
        let relative = format!("{directory}/{}", entry.file_name().to_string_lossy());
        let kind = entry
            .file_type()
            .map_err(|source| AuditInventoryError::Read {
                path: relative.clone(),
                source,
            })?;
        if kind.is_dir() {
            rust_files(root, &relative, output)?;
        } else if kind.is_file()
            && entry
                .path()
                .extension()
                .is_some_and(|extension| extension == "rs")
        {
            output.push(relative);
        }
    }
    Ok(())
}

/// Require audited/indexed current host inventory functions and ordinary Rust
/// #[test] declarations in build-scripts plus this gate's own regression file.
/// Platform-conditional Rust declarations remain included. Compiler discovery,
/// argument multiplicities, line-number freshness and semantic review are separate.
pub fn validate(root: &Path) -> Result<AuditCoverage, AuditInventoryError> {
    let inventory = json(root, "TestSupport/HostTests/inventory.json")?;
    let core = json(root, CORE)?;
    let other = json(root, OTHER)?;
    let index = json(root, INDEX)?;
    let core_rows = array(&core, "tests")?;
    let other_rows = array(&other, "tests")?;
    let index_rows = array(&index, "declarations")?;
    let suites = inventory
        .as_object()
        .ok_or_else(|| AuditInventoryError::Shape("host inventory object".to_owned()))?;
    let swift_declaration = Regex::new(r"\bfunc\s+(\w+)\s*\(")?;
    let mut host_seen = BTreeSet::new();
    for (suite, methods) in suites {
        let (module, class) = suite
            .split_once('.')
            .ok_or_else(|| AuditInventoryError::Shape(suite.clone()))?;
        if !matches!(module, "BleatCoreTests" | "BleatTranscriptionTests")
            || class.is_empty()
            || !class.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
        {
            return Err(AuditInventoryError::Shape(format!(
                "unsupported host suite {suite}"
            )));
        }
        let path = format!("Tests/{module}/{class}.swift");
        let source = read(root, &path)?;
        let declared: BTreeSet<_> = swift_declaration
            .captures_iter(&source)
            .filter_map(|capture| capture.get(1).map(|name| name.as_str()))
            .collect();
        for method in methods
            .as_array()
            .ok_or_else(|| AuditInventoryError::Shape(suite.clone()))?
        {
            let method = text(method, suite, "host method")?;
            let name = method.split_once('(').map_or(method, |(name, _)| name);
            let identity = format!("{path}::{name}");
            if !host_seen.insert(identity.clone()) {
                return Err(AuditInventoryError::Duplicate {
                    kind: "host function",
                    identity,
                });
            }
            if !declared.contains(name) {
                return Err(AuditInventoryError::StaleSource { identity });
            }
            let row = one(
                core_rows
                    .iter()
                    .filter(|row| row["identifier"] == identity && row["source"]["path"] == path)
                    .collect(),
                "core audit entry",
                &identity,
            )?;
            if row["source_reviewed"] != true {
                return Err(AuditInventoryError::Review {
                    identity,
                    field: "source_reviewed".to_owned(),
                });
            }
            text(&row["purpose"], &identity, "purpose")?;
            text(&row["reason"], &identity, "reason")?;
            decision(&row["decision"], &identity, "decision")?;
            rules(&row["rules"], &identity)?;
            index_entry(index_rows, &path, name)?;
        }
    }
    if host_seen.is_empty() {
        return Err(AuditInventoryError::Shape(
            "empty host inventory".to_owned(),
        ));
    }
    let mut files = Vec::new();
    rust_files(root, "build-scripts/tests", &mut files)?;
    rust_files(root, "build-scripts/src", &mut files)?;
    if files.is_empty() {
        return Err(AuditInventoryError::Shape(
            "empty build-scripts test source scope".to_owned(),
        ));
    }
    files.push("scripts/tests/test_audit_inventory.rs".to_owned());
    files.sort();
    let attribute = Regex::new(r"(?m)^\s*#\[test\]")?;
    let declaration = Regex::new(
        r"(?m)^\s*#\[test\]\s*(?:#\[[^\]]*\]\s*)*(?:pub(?:\([^)]*\))?\s+)?(?:async\s+)?fn\s+(\w+)\s*\(",
    )?;
    let mut rust_seen = BTreeSet::new();
    let mut build_test_count = 0;
    for path in files {
        let source = read(root, &path)?;
        let declarations: Vec<_> = declaration.captures_iter(&source).collect();
        if attribute.find_iter(&source).count() != declarations.len() {
            return Err(AuditInventoryError::RustDeclaration(path));
        }
        if path.starts_with("build-scripts/") {
            build_test_count += declarations.len();
        }
        for capture in declarations {
            let name = capture
                .get(1)
                .ok_or_else(|| AuditInventoryError::RustDeclaration(path.clone()))?
                .as_str();
            let identity = format!("{path}::{name}");
            if !rust_seen.insert(identity.clone()) {
                return Err(AuditInventoryError::Duplicate {
                    kind: "Rust declaration",
                    identity,
                });
            }
            let row = one(
                other_rows
                    .iter()
                    .filter(|row| {
                        row["path"] == path
                            && row["id"]
                                .as_str()
                                .is_some_and(|id| id.rsplit("::").next() == Some(name))
                    })
                    .collect(),
                "Rust audit entry",
                &identity,
            )?;
            for field in [
                "purpose",
                "enablement",
                "setup_dependencies",
                "action_postconditions",
                "synchronization_timeout",
            ] {
                text(&row[field], &identity, field)?;
            }
            if !matches!(
                text(&row["review"]["status"], &identity, "review.status")?,
                "reviewed" | "source_reviewed"
            ) {
                return Err(AuditInventoryError::Review {
                    identity,
                    field: "review.status".to_owned(),
                });
            }
            decision(&row["review"]["decision"], &identity, "review.decision")?;
            text(&row["review"]["reason"], &identity, "review.reason")?;
            let assessments = if row["rules"].is_object() {
                &row["rules"]
            } else {
                let profile = text(&row["profile"], &identity, "profile")?;
                &other["profiles"][profile]["rules"]
            };
            rules(assessments, &identity)?;
            index_entry(index_rows, &path, name)?;
        }
    }
    if build_test_count == 0 {
        return Err(AuditInventoryError::Shape(
            "empty build-scripts test declarations".to_owned(),
        ));
    }
    if rust_seen.is_empty() {
        return Err(AuditInventoryError::Shape(
            "empty Rust test source scope".to_owned(),
        ));
    }
    Ok(AuditCoverage {
        host_functions: host_seen.len(),
        rust_functions: rust_seen.len(),
    })
}
