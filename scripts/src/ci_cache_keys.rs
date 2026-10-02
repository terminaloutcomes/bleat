//! Compatible keys for Swift dependencies and the iOS smoke build.

use std::error::Error;
use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::path::Path;
use std::process::{Command, Stdio};

pub type Result<T> = std::result::Result<T, Box<dyn Error>>;

fn command_output(program: &str, arguments: &[&str]) -> Result<Vec<u8>> {
    let output = Command::new(program).args(arguments).output()?;
    if !output.status.success() {
        return Err(format!("{program} failed with {}", output.status).into());
    }
    Ok(output.stdout)
}

fn digest(parts: &[(&str, Vec<u8>)]) -> Result<String> {
    let mut child = Command::new("shasum")
        .args(["-a", "256"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()?;
    {
        let input = child
            .stdin
            .as_mut()
            .ok_or_else(|| io::Error::other("shasum stdin unavailable"))?;
        for (label, content) in parts {
            input.write_all(&(label.len() as u64).to_be_bytes())?;
            input.write_all(label.as_bytes())?;
            input.write_all(&(content.len() as u64).to_be_bytes())?;
            input.write_all(content)?;
        }
    }
    let output = child.wait_with_output()?;
    if !output.status.success() {
        return Err(format!("shasum failed with {}", output.status).into());
    }
    let line = String::from_utf8(output.stdout)?;
    let hash = line
        .split_whitespace()
        .next()
        .ok_or_else(|| io::Error::other("shasum returned no hash"))?;
    Ok(hash.to_owned())
}

fn add_file(parts: &mut Vec<(&'static str, Vec<u8>)>, path: &'static str) -> Result<()> {
    parts.push((path, fs::read(path)?));
    Ok(())
}

pub fn write_keys(lane: &str) -> Result<()> {
    let sdk = match lane {
        "ios" => "iphonesimulator",
        "host" => "macosx",
        _ => return Err(format!("Unknown cache lane: {lane}").into()),
    };
    let sdk_path = command_output("xcrun", &["--sdk", sdk, "--show-sdk-path"])?;
    let sdk_path = String::from_utf8(sdk_path)?;
    let sdk_settings = Path::new(sdk_path.trim()).join("SDKSettings.plist");
    let tools = vec![
        ("os-architecture", command_output("uname", &["-s", "-m"])?),
        (
            "os-version",
            command_output("sw_vers", &["-productVersion"])?,
        ),
        ("xcode", command_output("xcodebuild", &["-version"])?),
        ("swift-path", command_output("xcrun", &["--find", "swift"])?),
        (
            "swift-version",
            command_output("xcrun", &["swift", "--version"])?,
        ),
        (
            "sdk-version",
            command_output("xcrun", &["--sdk", sdk, "--show-sdk-version"])?,
        ),
        ("sdk-settings", fs::read(sdk_settings)?),
    ];
    let toolchain_hash = digest(&tools)?;

    let mut dependencies = Vec::new();
    add_file(&mut dependencies, "Package.swift")?;
    add_file(&mut dependencies, "Package.resolved")?;
    if lane == "ios" {
        add_file(
            &mut dependencies,
            "Bleat.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
        )?;
    }
    let dependency_hash = digest(&dependencies)?;
    let output_path = std::env::var("GITHUB_OUTPUT")?;
    let mut output = OpenOptions::new().append(true).open(output_path)?;
    writeln!(
        output,
        "dependencies={lane}-dependencies-{toolchain_hash}-{dependency_hash}"
    )?;

    if lane == "ios" {
        let mut build = vec![
            ("toolchain", toolchain_hash.into_bytes()),
            ("dependencies", dependency_hash.into_bytes()),
            (
                "configuration",
                b"Bleat Debug iphonesimulator coverage=YES parallel-testing=NO".to_vec(),
            ),
        ];
        for path in [
            "project.yml",
            "Bleat.xcodeproj/project.pbxproj",
            "scripts/src/ci_smoke.rs",
            "scripts/src/bin/ci-smoke.rs",
            "scripts/src/ci_cache_keys.rs",
            "scripts/src/bin/ci-cache-keys.rs",
        ] {
            add_file(&mut build, path)?;
        }
        writeln!(output, "build=ios-build-{}", digest(&build)?)?;
    }
    Ok(())
}
