use std::{io, path::Path, process::Command};

use thiserror::Error;

const LOCKFILES: [&str; 2] = ["Cargo.lock", "bleat-api/Cargo.lock"];

#[derive(Debug, Error)]
pub enum AuditError {
    #[error("dependency audit command failed to execute: {0}")]
    Io(#[from] io::Error),
    #[error("enabled dependency graph could not be checked")]
    Graph,
    #[error(
        "RUSTSEC-2026-0235 may only be ignored while rkyv is absent from the enabled feature graph"
    )]
    EnabledRkyv,
    #[error("locked dependency audit failed")]
    Advisories,
}

pub fn run(root: &Path) -> Result<(), AuditError> {
    let graph = Command::new("cargo")
        .current_dir(root)
        .args([
            "tree",
            "--locked",
            "--workspace",
            "--all-features",
            "--prefix",
            "none",
        ])
        .output()?;
    if !graph.status.success() {
        eprint!("{}", String::from_utf8_lossy(&graph.stderr));
        return Err(AuditError::Graph);
    }
    validate_graph(&String::from_utf8_lossy(&graph.stdout))?;
    audit_lockfiles(|lockfile| {
        println!("Auditing {lockfile}");
        Ok(Command::new("cargo")
            .current_dir(root)
            .args(["audit", "--file", lockfile, "--deny", "yanked"])
            .status()?
            .success())
    })
}

fn validate_graph(graph: &str) -> Result<(), AuditError> {
    if graph.lines().any(|line| line.starts_with("rkyv v")) {
        return Err(AuditError::EnabledRkyv);
    }
    Ok(())
}

fn audit_lockfiles(mut audit: impl FnMut(&str) -> io::Result<bool>) -> Result<(), AuditError> {
    let mut passed = true;
    for lockfile in LOCKFILES {
        // Always inspect both resolutions, including when the workspace fails.
        passed &= audit(lockfile)?;
    }
    if passed {
        Ok(())
    } else {
        Err(AuditError::Advisories)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn audits_workspace_and_standalone_even_when_either_fails() {
        for failures in [[false, false], [true, false], [false, true], [true, true]] {
            let mut inspected = Vec::new();
            let result = audit_lockfiles(|lockfile| {
                let passed = !failures[inspected.len()];
                inspected.push(lockfile.to_owned());
                Ok(passed)
            });
            assert_eq!(inspected, LOCKFILES);
            assert_eq!(result.is_ok(), !failures.into_iter().any(|failed| failed));
        }
    }

    #[test]
    fn rejects_enabled_rkyv_but_allows_lockfile_only_optional_dependency() {
        assert!(validate_graph("scripts v0.1.0\nrust_decimal v1.43.0\n").is_ok());
        assert!(matches!(
            validate_graph("scripts v0.1.0\nrkyv v0.7.45\n"),
            Err(AuditError::EnabledRkyv)
        ));
    }

    #[test]
    fn audit_spawn_failure_is_not_success() {
        assert!(matches!(
            audit_lockfiles(|_| Err(io::Error::from(io::ErrorKind::NotFound))),
            Err(AuditError::Io(_))
        ));
    }
}
