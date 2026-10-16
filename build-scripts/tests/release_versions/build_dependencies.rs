#![cfg(target_os = "macos")]

use std::{fs, os::unix::fs::PermissionsExt, path::Path, process::Command};

#[test]
fn build_launchers_preserve_the_callers_toolchain_environment() {
    let repository = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("workspace");
    let project = fs::read_to_string(repository.join("project.yml")).expect("project");
    let documents = yaml_rust::YamlLoader::load_from_str(&project).expect("project YAML");
    let phase = documents[0]["targets"]["BleatApp"]["preBuildScripts"]
        .as_vec()
        .expect("phases")
        .iter()
        .find(|phase| phase["name"].as_str() == Some("Prepare Build Metadata"))
        .expect("metadata phase")["script"]
        .as_str()
        .expect("script");
    let launcher = phase
        .lines()
        .find(|line| line.contains("cargo build "))
        .expect("Cargo build");
    let fixture = tempfile::tempdir().expect("fixture");
    let cargo = fixture.path().join("cargo");
    fs::write(
        &cargo,
        r#"#!/bin/sh
set -eu
test "$RUSTC" = caller-rustc
test "$RUSTDOC" = caller-rustdoc
test "$RUSTC_WRAPPER" = caller-wrapper
test "$RUSTC_WORKSPACE_WRAPPER" = caller-workspace-wrapper
test "$SDKROOT" = caller-sdk
printf '%s\n' "$@"
"#,
    )
    .expect("Cargo probe");
    fs::set_permissions(&cargo, fs::Permissions::from_mode(0o755)).expect("executable");
    let path = std::env::join_paths(std::iter::once(fixture.path().to_path_buf()).chain(
        std::env::split_paths(&std::env::var_os("PATH").expect("PATH")),
    ))
    .expect("PATH");
    for command in [
        launcher.to_owned(),
        format!(
            "\"{}/scripts/validate-paid-developer-build-settings.sh\"",
            repository.display()
        ),
    ] {
        let result = Command::new("/bin/bash")
            .args(["-c", &command])
            .env("PATH", &path)
            .env("SRCROOT", repository)
            .env("TARGET_TEMP_DIR", fixture.path())
            .env("RUSTC", "caller-rustc")
            .env("RUSTDOC", "caller-rustdoc")
            .env("RUSTC_WRAPPER", "caller-wrapper")
            .env("RUSTC_WORKSPACE_WRAPPER", "caller-workspace-wrapper")
            .env("SDKROOT", "caller-sdk")
            .output()
            .expect("launcher");
        assert!(
            result.status.success(),
            "{}",
            String::from_utf8_lossy(&result.stderr)
        );
        let args = String::from_utf8(result.stdout).expect("arguments");
        assert!(
            args.lines()
                .any(|arg| arg == "build-scripts" || arg.ends_with("/build-scripts/Cargo.toml")),
            "must select isolated package: {args}"
        );
    }
}

#[test]
fn build_dependency_tree_excludes_operational_and_native_tooling() {
    let result = Command::new(env!("CARGO"))
        .args([
            "tree",
            "--locked",
            "--offline",
            "--package",
            "build-scripts",
            "--edges",
            "normal,build",
            "--prefix",
            "none",
            "--format",
            "{p}",
        ])
        .current_dir(env!("CARGO_MANIFEST_DIR"))
        .output()
        .expect("dependency tree");
    assert!(
        result.status.success(),
        "{}",
        String::from_utf8_lossy(&result.stderr)
    );
    let tree = String::from_utf8(result.stdout).expect("tree");
    for line in tree.lines() {
        let name = line.split_whitespace().next().expect("package name");
        assert!(
            !matches!(
                name,
                "scripts"
                    | "bleat-api"
                    | "reqwest"
                    | "hyper"
                    | "tokio"
                    | "rustls"
                    | "ring"
                    | "aws-lc-rs"
                    | "aws-lc-sys"
                    | "openssl"
                    | "openssl-sys"
                    | "cc"
                    | "cmake"
            ),
            "build helper acquired operational/native dependency: {name}"
        );
    }
}

#[test]
fn xcode_sandbox_can_read_every_cargo_workspace_member() {
    let repository = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("workspace");
    let project = fs::read_to_string(repository.join("project.yml")).expect("project");
    let documents = yaml_rust::YamlLoader::load_from_str(&project).expect("project YAML");
    let phase = documents[0]["targets"]["BleatApp"]["preBuildScripts"]
        .as_vec()
        .expect("phases")
        .iter()
        .find(|phase| phase["name"].as_str() == Some("Prepare Build Metadata"))
        .expect("metadata phase");
    let inputs: Vec<_> = phase["inputFiles"]
        .as_vec()
        .expect("input files")
        .iter()
        .map(|input| {
            repository.join(
                input
                    .as_str()
                    .expect("input path")
                    .trim_start_matches("$(SRCROOT)/"),
            )
        })
        .collect();
    let output = Command::new(env!("CARGO"))
        .args([
            "metadata",
            "--locked",
            "--offline",
            "--no-deps",
            "--format-version",
            "1",
        ])
        .current_dir(repository)
        .output()
        .expect("workspace metadata");
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let metadata: serde_json::Value =
        serde_json::from_slice(&output.stdout).expect("metadata JSON");
    for package in metadata["packages"].as_array().expect("packages") {
        let manifest = Path::new(package["manifest_path"].as_str().expect("manifest path"));
        assert!(
            inputs.iter().any(|input| manifest.starts_with(input)),
            "Cargo must read every workspace member even when building only build-scripts: {}",
            package["name"]
        );
    }
}
