#[cfg(target_os = "macos")]
#[test]
fn command_rejects_real_pbxproj_version_drift_before_building() {
    use std::{fs, process::Command};

    const PROJECT: &str = "targets:\n  BleatApp:\n    settings:\n      base:\n        MARKETING_VERSION: \"2026.10.11\"\n        CURRENT_PROJECT_VERSION: \"20261011.0102.03\"\n";
    const CHANGELOG: &str = "# Changelog\n\n## 2026.10.11 - 2026-10-11\n\n- Release.\n";

    let root = tempfile::tempdir().expect("temporary fixture");
    fs::create_dir(root.path().join("Bleat.xcodeproj")).expect("project directory");
    fs::write(root.path().join("project.yml"), PROJECT).expect("source version");
    fs::write(root.path().join("CHANGELOG.md"), CHANGELOG).expect("release notes");
    let file = root.path().join("Bleat.xcodeproj/project.pbxproj");
    fs::write(&file, "{ objects = { debug = { isa = XCBuildConfiguration; name = Debug; buildSettings = { MARKETING_VERSION = 2026.10.08; CURRENT_PROJECT_VERSION = 20261011.0102.03; }; }; release = { isa = XCBuildConfiguration; name = Release; buildSettings = { MARKETING_VERSION = 2026.10.11; CURRENT_PROJECT_VERSION = 20261011.0102.03; }; }; }; }")
        .expect("OpenStep fixture");
    let run = || {
        Command::new(env!("CARGO_BIN_EXE_validate-release-version"))
            .arg("--repository-root")
            .arg(root.path())
            .output()
            .expect("validator starts")
    };
    assert!(!run().status.success());
    let project = fs::read_to_string(&file).expect("read generated fixture");
    fs::write(&file, project.replace("2026.10.08", "2026.10.11")).expect("fix fixture");
    assert!(run().status.success());
}
