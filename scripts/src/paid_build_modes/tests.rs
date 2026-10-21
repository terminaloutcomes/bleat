use super::*;
use crate::ci_smoke::{
    lifecycle_tests::{Fixture, FixtureWorker, alive, held},
    owned_command::Cause,
};
use std::{fs, os::unix::fs::PermissionsExt, sync::mpsc, thread};

const VALID: &str = r#"[{"target":"BleatApp","buildSettings":{"BLEAT_CARPLAY_MODE":"enabled","BLEAT_EFFECTIVE_CARPLAY_MODE":"enabled","CODE_SIGN_ENTITLEMENTS":"App/Bleat.cloudkit-enabled.app-attest-enabled.carplay-enabled.entitlements"}}]"#;
fn executable(root: &Path, body: &str) -> std::path::PathBuf {
    let path = root.join("synthetic-xcodebuild");
    fs::write(&path, format!("#!/bin/sh\nset -eu\nprintf '%s' \"$$\" > native.pending\n/bin/mv native.pending native.pid\n{body}\n")).expect("private native fixture");
    fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).expect("executable fixture");
    path
}
#[test]
fn matrix_preserves_all_twelve_queries_and_exact_original_contracts() {
    let all = queries();
    assert_eq!(all.len(), 12);
    let expected = [
        ("NO", "enabled", "enabled", "disabled"),
        ("NO", "enabled", "disabled", "disabled"),
        ("NO", "disabled", "enabled", "disabled"),
        ("NO", "disabled", "disabled", "disabled"),
        ("NO", "enabled", "enabled", "enabled"),
        ("NO", "enabled", "disabled", "enabled"),
        ("NO", "disabled", "enabled", "enabled"),
        ("NO", "disabled", "disabled", "enabled"),
        ("YES", "enabled", "enabled", "enabled"),
    ];
    for (case, (global, cloud, attest, carplay)) in all[..9].iter().zip(expected) {
        let args = case.arguments();
        assert_eq!(
            &args[..10],
            [
                "-project",
                "Bleat.xcodeproj",
                "-target",
                "BleatApp",
                "-configuration",
                "Release",
                "-sdk",
                "iphoneos",
                "-showBuildSettings",
                "-json"
            ]
        );
        assert_eq!(
            &args[10..],
            [
                format!("BUILD_WITHOUT_PAID_DEVELOPER={global}"),
                format!("BLEAT_CLOUDKIT_MODE={cloud}"),
                format!("BLEAT_APP_ATTEST_MODE={attest}"),
                format!("BLEAT_CARPLAY_MODE={carplay}")
            ]
        );
    }
    for (case, sdk, global) in [
        (Query::PaidDefault, "iphoneos", "NO"),
        (Query::PersonalDefault, "iphoneos", "YES"),
        (Query::MacDefault, "macosx", "NO"),
    ] {
        let args = case.arguments();
        assert_eq!(args.len(), 11);
        assert_eq!(args[7], sdk);
        assert_eq!(args[10], format!("BUILD_WITHOUT_PAID_DEVELOPER={global}"));
    }
    assert_eq!(
        all[8].expected(),
        vec![
            (
                "CODE_SIGN_ENTITLEMENTS",
                "App/Bleat.cloudkit-disabled.app-attest-disabled.entitlements".to_owned()
            ),
            ("BLEAT_EFFECTIVE_CARPLAY_MODE", "disabled".to_owned()),
            ("BLEAT_EFFECTIVE_CLOUDKIT_MODE", "disabled".to_owned()),
            ("BLEAT_EFFECTIVE_APP_ATTEST_MODE", "disabled".to_owned())
        ]
    );
    assert_eq!(
        Query::MacDefault.expected(),
        vec![
            (
                "CODE_SIGN_ENTITLEMENTS",
                "App/BleatMac.enabled.entitlements".to_owned()
            ),
            ("BLEAT_EFFECTIVE_CARPLAY_MODE", "disabled".to_owned()),
            ("BLEAT_CARPLAY_MODE", "enabled".to_owned())
        ]
    );
}
#[test]
fn settings_reject_wrong_target_missing_fields_wrong_types_and_malformed_output() {
    verify_settings(Query::PaidDefault, VALID.as_bytes()).expect("real expected settings shape");
    let private = VALID.replace(
        "App/Bleat.cloudkit-enabled.app-attest-enabled.carplay-enabled.entitlements",
        "synthetic-private-settings-marker",
    );
    let error = verify_settings(Query::PaidDefault, private.as_bytes())
        .expect_err("mismatched private setting");
    assert!(!format!("{error}\n{error:?}").contains("synthetic-private-settings-marker"));
    for invalid in ["null", "{}", "not json"] {
        assert!(matches!(
            verify_settings(Query::PaidDefault, invalid.as_bytes()),
            Err(Error::Json { .. })
        ));
    }
    assert!(matches!(
        verify_settings(Query::PaidDefault, b"[]"),
        Err(Error::MissingTarget { .. })
    ));
    assert!(matches!(
        verify_settings(
            Query::PaidDefault,
            VALID.replace("BleatApp", "OtherTarget").as_bytes()
        ),
        Err(Error::MissingTarget { .. })
    ));
    for (field, wrong) in [
        (
            "CODE_SIGN_ENTITLEMENTS",
            serde_json::Value::String("wrong".to_owned()),
        ),
        ("BLEAT_EFFECTIVE_CARPLAY_MODE", serde_json::json!(false)),
        ("BLEAT_CARPLAY_MODE", serde_json::Value::Null),
    ] {
        let mut data: serde_json::Value = serde_json::from_str(VALID).expect("fixture");
        data[0]["buildSettings"][field] = wrong;
        assert!(
            matches!(verify_settings(Query::PaidDefault,&serde_json::to_vec(&data).expect("fixture bytes")),Err(Error::Setting { field: actual,.. }) if actual==field)
        );
    }
}
#[test]
fn native_query_retains_exit_spawn_capture_causes_and_private_output() {
    let fixture = Fixture::new();
    let root = fixture.root.path();
    fs::write(root.join("payload"), VALID).expect("private payload");
    let tool = executable(root, "exec /bin/cat payload");
    query(
        root,
        &tool,
        Query::PaidDefault,
        Duration::from_secs(2),
        Duration::from_secs(1),
        4096,
    )
    .expect("native accepted settings");
    let tool = executable(root, "printf private-output-marker; exit 23");
    let error = query(
        root,
        &tool,
        Query::PaidDefault,
        Duration::from_secs(2),
        Duration::from_secs(1),
        4096,
    )
    .expect_err("native exit fails");
    assert!(!format!("{error:?}\n{error}").contains("private-output-marker"));
    assert!(
        matches!(error,Error::Native { query: Query::PaidDefault,source } if matches!(source.cause,Cause::Exit(status) if status.code()==Some(23)) && source.cleanup.as_ref().is_some_and(|c| c.succeeded()))
    );
    let tool = executable(root, "exec /bin/cat payload");
    let error = query(
        root,
        &tool,
        Query::PaidDefault,
        Duration::from_secs(2),
        Duration::from_secs(1),
        16,
    )
    .expect_err("capture rejected");
    assert!(
        matches!(error,Error::Native { source,.. } if matches!(source.cause,Cause::Capture) && source.capture.stdout.is_empty() && source.cleanup.as_ref().is_some_and(|c|c.succeeded()))
    );
    let error = query(
        root,
        &root.join("absent-tool"),
        Query::PaidDefault,
        Duration::from_secs(2),
        Duration::from_secs(1),
        4096,
    )
    .expect_err("missing tool");
    assert!(
        matches!(error,Error::Native { source,.. } if matches!(&source.cause,Cause::Spawn(e) if e.kind()==std::io::ErrorKind::NotFound) && source.cleanup.is_none())
    );
}
#[test]
fn admitted_query_deadline_retires_child_before_returning() {
    let fixture = Fixture::new();
    let root = fixture.root.path().to_path_buf();
    let tool = executable(&root, held());
    let (tx, rx) = mpsc::channel();
    let worker = thread::spawn(move || {
        tx.send(query(
            &root,
            &tool,
            Query::PaidDefault,
            Duration::from_secs(2),
            Duration::from_secs(1),
            4096,
        ))
        .expect("deliver result");
    });
    let worker = FixtureWorker {
        worker: Some(worker),
        release: fixture.root.path().join("release"),
    };
    let pid = fixture.ready("native");
    let first = rx.recv_timeout(Duration::from_secs(5));
    let bounded = first.is_ok();
    fixture.release();
    let result = first.unwrap_or_else(|_| {
        rx.recv_timeout(Duration::from_secs(3))
            .expect("released fixture drains")
    });
    worker.join().expect("joined native owner");
    fixture.drain_pid(pid);
    assert!(bounded);
    assert!(!alive(pid));
    assert!(
        matches!(result,Err(Error::Native { source,.. }) if source.stage==Stage::PaidBuildSettings && matches!(source.cause,Cause::Deadline { elapsed,budget } if elapsed>=budget && budget==Duration::from_secs(2)) && source.cleanup.as_ref().is_some_and(|c|c.succeeded()))
    );
}
fn write_plist(root: &Path, path: &str, value: plist::Value) {
    value
        .to_file_xml(root.join(path))
        .expect("private plist fixture");
}
fn plist_fixture(root: &Path) {
    fs::create_dir(root.join("App")).expect("private App");
    let mut d = plist::Dictionary::new();
    d.insert(
        "keychain-access-groups".to_owned(),
        plist::Value::Array(vec![]),
    );
    write_plist(
        root,
        "App/Bleat.cloudkit-disabled.app-attest-disabled.entitlements",
        plist::Value::Dictionary(d),
    );
    for (path, enabled) in [
        (
            "App/Bleat.cloudkit-enabled.app-attest-enabled.carplay-enabled.entitlements",
            true,
        ),
        ("App/BleatMac.enabled.entitlements", false),
    ] {
        let mut d = plist::Dictionary::new();
        if enabled {
            d.insert(
                "com.apple.developer.carplay-audio".to_owned(),
                plist::Value::Boolean(true),
            );
        }
        write_plist(root, path, plist::Value::Dictionary(d));
    }
    let mut d = plist::Dictionary::new();
    for (key, value) in [
        ("BleatCloudKitMode", "$(BLEAT_EFFECTIVE_CLOUDKIT_MODE)"),
        ("BleatAppAttestMode", "$(BLEAT_EFFECTIVE_APP_ATTEST_MODE)"),
        ("BleatCarPlayMode", "$(BLEAT_EFFECTIVE_CARPLAY_MODE)"),
    ] {
        d.insert(key.to_owned(), plist::Value::String(value.to_owned()));
    }
    write_plist(root, "App/Info.plist", plist::Value::Dictionary(d));
}
#[test]
fn plist_contracts_fail_closed_for_each_security_and_substitution_assertion() {
    for (path, key, value) in [
        (
            "App/Bleat.cloudkit-disabled.app-attest-disabled.entitlements",
            "com.apple.developer.icloud-services",
            Some(plist::Value::Array(vec![])),
        ),
        (
            "App/Bleat.cloudkit-disabled.app-attest-disabled.entitlements",
            "com.apple.developer.devicecheck.appattest-environment",
            Some(plist::Value::String("production".to_owned())),
        ),
        (
            "App/Bleat.cloudkit-disabled.app-attest-disabled.entitlements",
            "keychain-access-groups",
            None,
        ),
        (
            "App/BleatMac.enabled.entitlements",
            "com.apple.developer.carplay-audio",
            Some(plist::Value::Boolean(true)),
        ),
        (
            "App/Bleat.cloudkit-enabled.app-attest-enabled.carplay-enabled.entitlements",
            "com.apple.developer.carplay-audio",
            Some(plist::Value::Boolean(false)),
        ),
        (
            "App/Info.plist",
            "BleatCloudKitMode",
            Some(plist::Value::String("enabled".to_owned())),
        ),
        ("App/Info.plist", "BleatAppAttestMode", None),
        (
            "App/Info.plist",
            "BleatCarPlayMode",
            Some(plist::Value::Boolean(true)),
        ),
    ] {
        let f = Fixture::new();
        let root = f.root.path();
        plist_fixture(root);
        verify_plists(root).expect("positive control");
        let mut v = plist::Value::from_file(root.join(path)).expect("plist");
        let d = v.as_dictionary_mut().expect("dictionary");
        if let Some(value) = value {
            d.insert(key.to_owned(), value);
        } else {
            d.remove(key);
        }
        write_plist(root, path, v);
        assert!(
            matches!(verify_plists(root),Err(Error::PlistContract { path: actual,key:actual_key,.. }) if actual==path && (actual_key==key || actual_key=="icloud/appattest content"))
        );
    }
    let f = Fixture::new();
    let root = f.root.path();
    plist_fixture(root);
    fs::write(root.join("App/Info.plist"), b"invalid XML").expect("malformed input");
    assert!(matches!(verify_plists(root),Err(Error::Plist { path,.. }) if path=="App/Info.plist"));
    write_plist(root, "App/Info.plist", plist::Value::Array(vec![]));
    assert!(matches!(
        verify_plists(root),
        Err(Error::PlistContract {
            requirement: PlistRequirement::Dictionary,
            ..
        })
    ));
    let f = Fixture::new();
    let root = f.root.path();
    plist_fixture(root);
    fs::remove_file(
        root.join("App/Bleat.cloudkit-enabled.app-attest-enabled.carplay-enabled.entitlements"),
    )
    .expect("remove enabled fixture");
    assert!(matches!(
        verify_plists(root),
        Err(Error::PlistContract {
            requirement: PlistRequirement::MatchingFiles,
            ..
        })
    ));
    let f = Fixture::new();
    let root = f.root.path();
    plist_fixture(root);
    fs::remove_file(root.join("App/Info.plist")).expect("remove plist fixture");
    assert!(matches!(verify_plists(root),Err(Error::Plist { path,.. }) if path=="App/Info.plist"));
    assert!(contains_paid_capability(&plist::Value::Array(vec![
        plist::Value::String("nested icloud value".to_owned())
    ])));
}
#[test]
fn negative_controls_require_exact_typed_invalid_mode_without_ambient_configuration() {
    verify_invalid_modes().expect("valid baseline and all four exact invalid controls");
}
