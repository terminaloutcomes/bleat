use std::{fs, os::unix::fs::PermissionsExt, path::Path, process::Command};

fn executable(path: &Path, content: &str) {
    fs::write(path, content).expect("write tool fixture");
    fs::set_permissions(path, fs::Permissions::from_mode(0o755)).expect("executable");
}

#[test]
fn large_library_wrapper_forwards_count_output_and_repository_override() {
    let fixture = tempfile::tempdir().expect("fixture");
    let tools = fixture.path().join("bin");
    fs::create_dir(&tools).expect("tools");
    // Capture the wrapper's Cargo invocation, then run the real Rust CLI with
    // precisely the arguments after Cargo's separator. No nested Cargo build.
    executable(
        &tools.join("cargo"),
        "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$CAPTURE\"\nwhile [ \"$1\" != -- ]; do shift; done\nshift\nexec \"$GENERATOR\" \"$@\"\n",
    );
    executable(
        &tools.join("ffmpeg"),
        "#!/bin/sh\nfor arg do output=$arg; done\nprintf 'fixture audio' > \"$output\"\n",
    );
    let root = fixture.path().join("override");
    let capture = fixture.path().join("capture");
    let wrapper = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../TestSupport/ServerHarness/generate-large-library.sh");
    for explicit in [false, true] {
        let output = if explicit {
            fixture.path().join("explicit")
        } else {
            root.join("TestSupport/ServerHarness/media-large")
        };
        for count in [3, 1, 1] {
            let mut command = Command::new(&wrapper);
            command
                .current_dir(fixture.path())
                .env("PATH", format!("{}:/usr/bin:/bin", tools.display()))
                .env("ZDOTDIR", fixture.path())
                .env("CAPTURE", &capture)
                .env("GENERATOR", env!("CARGO_BIN_EXE_generate-large-library"))
                .env("BLEAT_REPOSITORY_ROOT", &root)
                .env("BLEAT_LARGE_LIBRARY_COUNT", count.to_string());
            if explicit {
                command.arg(&output);
            }
            let result = command.output().expect("wrapper");
            assert!(
                result.status.success(),
                "{}",
                String::from_utf8_lossy(&result.stderr)
            );
            assert_eq!(fs::read_dir(&output).expect("output").count(), count + 1);
            assert!(output.join("book-00000/metadata.json").is_file());
        }
        let args = fs::read_to_string(&capture).expect("capture");
        let lines = args.lines().collect::<Vec<_>>();
        assert_eq!(
            &lines[..8],
            &[
                "run",
                "--quiet",
                "--locked",
                "--manifest-path",
                root.join("Cargo.toml").to_str().expect("path"),
                "--package",
                "scripts",
                "--bin"
            ]
        );
        assert!(
            lines
                .windows(2)
                .any(|pair| pair == ["--root", root.to_str().expect("root")])
        );
    }
}

#[test]
fn large_library_cli_rejects_invalid_counts_without_creating_output() {
    let root = tempfile::tempdir().expect("fixture");
    let output = root.path().join("output");
    for count in ["0", "-1", "abc", "100001"] {
        let result = Command::new(env!("CARGO_BIN_EXE_generate-large-library"))
            .env("BLEAT_LARGE_LIBRARY_COUNT", count)
            .arg(&output)
            .output()
            .expect("CLI");
        assert!(!result.status.success());
        assert!(!output.exists());
    }
}
