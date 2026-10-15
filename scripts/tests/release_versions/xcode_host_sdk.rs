#![cfg(target_os = "macos")]

use std::{fs, os::unix::fs::PermissionsExt, path::Path, process::Command};

fn sdk_path(sdk: &str) -> String {
    let output = Command::new("xcrun")
        .args(["--sdk", sdk, "--show-sdk-path"])
        .output()
        .expect("resolve SDK");
    assert!(output.status.success(), "SDK lookup failed");
    String::from_utf8(output.stdout)
        .expect("SDK path is UTF-8")
        .trim()
        .to_owned()
}

#[test]
fn xcode_cargo_launchers_select_host_sdk_for_native_dependencies() {
    let repository = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("workspace root");
    let project = fs::read_to_string(repository.join("project.yml")).expect("project definition");
    let documents = yaml_rust::YamlLoader::load_from_str(&project).expect("project YAML");
    let preparation = documents[0]["targets"]["BleatApp"]["preBuildScripts"]
        .as_vec()
        .expect("build phases")
        .iter()
        .find(|phase| phase["name"].as_str() == Some("Prepare Build Metadata"))
        .expect("build preparation phase")["script"]
        .as_str()
        .expect("build preparation commands");
    let cargo_build = preparation
        .lines()
        .find(|line| line.contains("cargo build "))
        .expect("host helper compilation command");
    let fixture = tempfile::tempdir().expect("compiler fixture");
    let bin = fixture.path().join("bin");
    fs::create_dir(&bin).expect("fixture tools");
    // Substitute only Cargo. The actual launchers must select the host SDK, and
    // Xcode's real compiler must compile the same headers its native crates use.
    let cargo = bin.join("cargo");
    fs::write(
        &cargo,
        "#!/bin/sh\nprintf '%s' \"$SDKROOT\" > sdk.txt\nexec \"$BLEAT_TEST_CC\" -c probe.c -o probe.o\n",
    )
    .expect("Cargo boundary probe");
    fs::set_permissions(&cargo, fs::Permissions::from_mode(0o755)).expect("executable probe");
    fs::write(
        fixture.path().join("probe.c"),
        "#include <stdio.h>\n#include <stdlib.h>\n#include <sys/random.h>\nint probe(void) { return 0; }\n",
    )
    .expect("native dependency header probe");
    let compiler = Command::new("xcrun")
        .args(["--sdk", "macosx", "--find", "cc"])
        .output()
        .expect("Xcode compiler");
    assert!(compiler.status.success(), "compiler lookup failed");
    let compiler = String::from_utf8(compiler.stdout).expect("compiler path is UTF-8");
    let compiler = compiler.trim();
    let host_sdk = sdk_path("macosx");
    let paths = std::env::join_paths(
        [
            bin.as_path(),
            Path::new(compiler).parent().expect("toolchain"),
        ]
        .into_iter()
        .map(Path::to_path_buf)
        .chain(std::env::split_paths(
            &std::env::var_os("PATH").expect("PATH"),
        )),
    )
    .expect("tool search path");
    for incoming_sdk in ["iphoneos", "iphonesimulator"] {
        for launcher in [
            cargo_build.to_owned(),
            format!(
                "\"{}/scripts/validate-paid-developer-build-settings.sh\"",
                repository.display()
            ),
        ] {
            let output = Command::new("/bin/bash")
                .args(["-c", &launcher])
                .current_dir(fixture.path())
                .env("SRCROOT", repository)
                .env("TARGET_TEMP_DIR", fixture.path())
                .env("SDKROOT", sdk_path(incoming_sdk))
                .env("PATH", &paths)
                .env("BLEAT_TEST_CC", compiler)
                .env_remove("CFLAGS_aarch64_apple_darwin")
                .env_remove("CFLAGS_x86_64_apple_darwin")
                .output()
                .expect("run actual Xcode Cargo launcher");
            assert!(
                output.status.success(),
                "native compilation failed with incoming {incoming_sdk}: {}",
                String::from_utf8_lossy(&output.stderr)
            );
            let selected =
                fs::read_to_string(fixture.path().join("sdk.txt")).expect("selected compiler SDK");
            assert!(
                Path::new(&selected) == Path::new(&host_sdk),
                "Cargo launcher did not select the host SDK"
            );
            assert!(fixture.path().join("probe.o").is_file());
            fs::remove_file(fixture.path().join("probe.o")).expect("reset compiler output");
        }
    }
}
