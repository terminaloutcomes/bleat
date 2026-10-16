#![cfg(unix)]

use serde_json::json;
use std::{fs, os::unix::fs::PermissionsExt, path::Path, process::Command};

fn executable(path: &Path, body: &str) {
    fs::write(path, body).expect("write command fixture");
    fs::set_permissions(path, fs::Permissions::from_mode(0o755))
        .expect("make command fixture executable");
}

fn run_fixture(script: &str, identities: &[&str], outcomes: &[&str]) -> std::process::Output {
    let root = tempfile::tempdir().expect("isolated runner fixture");
    let scripts = root.path().join("scripts");
    let commands = root.path().join("commands");
    fs::create_dir_all(&scripts).expect("create scripts fixture");
    fs::create_dir_all(&commands).expect("create commands fixture");
    fs::copy(
        Path::new(env!("CARGO_MANIFEST_DIR")).join(script),
        scripts.join(script),
    )
    .expect("copy actual runner");
    let cases: Vec<_> = identities
        .iter()
        .zip(outcomes)
        .map(|(id, outcome)| {
            json!({
                "nodeType": "Test Case",
                "nodeIdentifier": id.split_once('/').expect("qualified identity").1,
                "nodeIdentifierURL": format!("test://com.apple.xcode/Bleat/{id}"),
                "name": id.rsplit('/').next().expect("function name"),
                "result": outcome
            })
        })
        .collect();
    fs::write(
        root.path().join("tests.json"),
        serde_json::to_vec(&json!({"testNodes": cases})).expect("serialize result fixture"),
    )
    .expect("write result fixture");
    // Deliberately passing summary: the exact tree must still reject bad cases.
    fs::write(
        root.path().join("summary.json"),
        serde_json::to_vec(&json!({
            "result": "Passed", "passedTests": identities.len(), "failedTests": 0,
            "skippedTests": 0, "expectedFailures": 0, "testFailures": [],
            "runtimeWarnings": [], "totalTestCount": identities.len()
        }))
        .expect("serialize summary"),
    )
    .expect("write summary");
    executable(&commands.join("xcodebuild"), "#!/bin/sh\nexit 0\n");
    executable(
        &commands.join("xcrun"),
        "#!/bin/sh\ncase \"$4\" in\n tests) cat \"$RUNNER_FIXTURE/tests.json\";;\n summary) cat \"$RUNNER_FIXTURE/summary.json\";;\n *) exit 64;;\nesac\n",
    );
    executable(
        &commands.join("cargo"),
        "#!/bin/sh\nwhile [ \"$#\" -gt 0 ] && [ \"$1\" != -- ]; do shift; done\n[ \"$#\" -gt 0 ] || exit 64\nshift\nexec \"$RESULT_VERIFIER\" \"$@\"\n",
    );
    let mut paths = vec![commands];
    paths.extend(std::env::split_paths(
        &std::env::var_os("PATH").expect("test PATH exists"),
    ));
    Command::new("zsh")
        .arg(scripts.join(script))
        .current_dir(root.path())
        .env("PATH", std::env::join_paths(paths).expect("fixture PATH"))
        .env("RUNNER_FIXTURE", root.path())
        .env("RESULT_VERIFIER", env!("CARGO_BIN_EXE_verify-test-results"))
        .output()
        .expect("execute isolated runner")
}

const CAPACITY: &str =
    "BleatAppTests/AppModelTests/testDownloadPreflightRejectsInsufficientCapacityBeforeScheduling";
const DOWNLOAD: &str =
    "BleatAppTests/AppModelTests/testThreeHundredTrackDownloadRepairAndPublicationStayResponsive";
const PERFORMANCE: &str =
    "BleatUITests/BleatPerformanceUITests/testTenKBooksLaunchBrowsingAndSearchPerformance";
const LANDSCAPE: [&str; 3] = [
    "BleatUITests/BleatLandscapeUITests/testPrimaryScreensRemainUsableInLandscape",
    "BleatUITests/BleatLandscapeUITests/testLoginRemainsUsableInLandscape",
    "BleatUITests/BleatLandscapeUITests/testRotationPreservesNavigationAndPlayback",
];

#[test]
fn download_runner_accepts_exact_results_without_literal_tab_matching() {
    let result = run_fixture(
        "test-download-performance.sh",
        &[CAPACITY, DOWNLOAD],
        &["Passed", "Passed"],
    );
    assert!(
        result.status.success(),
        "{}",
        String::from_utf8_lossy(&result.stderr)
    );
}

#[test]
fn download_runner_rejects_missing_duplicate_and_wrong_target_results() {
    for identities in [
        vec![CAPACITY],
        vec![CAPACITY, CAPACITY],
        vec![
            CAPACITY,
            "WrongTarget/AppModelTests/testThreeHundredTrackDownloadRepairAndPublicationStayResponsive",
        ],
    ] {
        let outcomes = vec!["Passed"; identities.len()];
        assert!(
            !run_fixture("test-download-performance.sh", &identities, &outcomes)
                .status
                .success()
        );
    }
}

#[test]
fn performance_runner_rejects_extra_failed_skipped_and_unknown_results() {
    assert!(
        run_fixture("test-performance.sh", &[PERFORMANCE], &["Passed"])
            .status
            .success()
    );
    for outcome in ["Failed", "Skipped", "Unknown"] {
        assert!(
            !run_fixture("test-performance.sh", &[PERFORMANCE], &[outcome])
                .status
                .success()
        );
    }
    assert!(
        !run_fixture(
            "test-performance.sh",
            &[PERFORMANCE, CAPACITY],
            &["Passed", "Passed"]
        )
        .status
        .success()
    );
    assert!(
        !run_fixture("test-performance.sh", &[], &[])
            .status
            .success()
    );
}

#[test]
fn landscape_runner_checks_names_not_only_the_passing_count() {
    assert!(
        run_fixture("test-landscape-ui.sh", &LANDSCAPE, &["Passed"; 3])
            .status
            .success()
    );
    let mut wrong = LANDSCAPE;
    wrong[1] = PERFORMANCE;
    assert!(
        !run_fixture("test-landscape-ui.sh", &wrong, &["Passed"; 3])
            .status
            .success()
    );
}
