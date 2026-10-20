use std::{fs, path::Path};

use scripts::test_audit_inventory::{AuditInventoryError, validate};
use serde_json::{Value, json};

struct Fixture {
    root: tempfile::TempDir,
    inventory: Value,
    core: Value,
    other: Value,
    index: Value,
}

impl Fixture {
    fn new() -> Self {
        let root = tempfile::tempdir().expect("isolated audit fixture");
        let rules: Value = (1..=9).map(|n| (n.to_string(), json!(format!("Rule {n}: explicit fixture ownership, expected postcondition and applicable boundary.")))).collect();
        let core = json!({"tests":[{"identifier":"Tests/BleatCoreTests/ExampleTests.swift::example","source":{"path":"Tests/BleatCoreTests/ExampleTests.swift","line":2},"source_reviewed":true,"purpose":"Check the expected semantic result using an isolated fixture.","reason":"Exact typed output is asserted from the owned input.","decision":"keep","rules":rules}]});
        let rust_row = |id: &str, path: &str| json!({"id":id,"path":path,"line":2,"purpose":"Reject invalid named metadata through typed results.","enablement":"Default Rust test target; no external service required.","setup_dependencies":"Unique temporary root and deterministic local metadata.","action_postconditions":"Validate input and require its exact typed outcome.","synchronization_timeout":"Synchronous local validation; no asynchronous wait.","review":{"status":"reviewed","decision":"keep","reason":"Owned inputs and exact typed results establish the boundary."},"profile":"rust_deterministic"});
        let other = json!({"profiles":{"rust_deterministic":{"rules":rules}},"tests":[rust_row("build-scripts::package_case","build-scripts/tests/example.rs"),rust_row("scripts::registry_case","scripts/tests/test_audit_inventory.rs")]});
        let fixture = Self {
            root,
            inventory: json!({"BleatCoreTests.ExampleTests":["example()"]}),
            core,
            other,
            index: json!({"declarations":[{"path":"Tests/BleatCoreTests/ExampleTests.swift","name":"example","line":2},{"path":"build-scripts/tests/example.rs","name":"package_case","line":2},{"path":"scripts/tests/test_audit_inventory.rs","name":"registry_case","line":2}]}),
        };
        fixture.write(
            "Tests/BleatCoreTests/ExampleTests.swift",
            "@Test\nfunc example() {}\n",
        );
        fixture.write(
            "build-scripts/tests/example.rs",
            "#[test]\nfn package_case() {}\n",
        );
        fixture.write("build-scripts/src/lib.rs", "fn helper_only() {}\n");
        fixture.write(
            "scripts/tests/test_audit_inventory.rs",
            "#[test]\nfn registry_case() {}\n",
        );
        fixture
    }

    fn write(&self, path: &str, contents: &str) {
        let path = self.root.path().join(path);
        fs::create_dir_all(path.parent().expect("fixture parent")).expect("fixture directories");
        fs::write(path, contents).expect("fixture contents");
    }

    fn check(&self) -> Result<scripts::test_audit_inventory::AuditCoverage, AuditInventoryError> {
        for (path, value) in [
            ("TestSupport/HostTests/inventory.json", &self.inventory),
            ("TestSupport/TestAudit/core.json", &self.core),
            ("TestSupport/TestAudit/other.json", &self.other),
            ("TestSupport/TestAudit/source-index.json", &self.index),
        ] {
            self.write(path, &serde_json::to_string(value).expect("fixture JSON"));
        }
        validate(self.root.path())
    }
}

#[test]
fn current_repository_has_scoped_audit_parity() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("repository root");
    let actual = validate(root).expect("current host/build-helper audits and source index");
    assert!(actual.host_functions > 0);
    assert!(actual.rust_functions > 0);
}

#[test]
fn missing_host_audit_is_rejected() {
    let mut fixture = Fixture::new();
    fixture.core["tests"] = json!([]);
    assert!(
        matches!(fixture.check(),Err(AuditInventoryError::Missing {kind:"core audit entry", identity}) if identity.ends_with("ExampleTests.swift::example"))
    );
}

#[test]
fn missing_rust_audit_is_rejected() {
    let mut fixture = Fixture::new();
    fixture.other["tests"]
        .as_array_mut()
        .expect("rows")
        .remove(0);
    assert!(
        matches!(fixture.check(),Err(AuditInventoryError::Missing {kind:"Rust audit entry", identity}) if identity.ends_with("example.rs::package_case"))
    );
}

#[test]
fn missing_source_index_entries_are_rejected() {
    for index in [0, 1, 2] {
        let mut fixture = Fixture::new();
        fixture.index["declarations"]
            .as_array_mut()
            .expect("index rows")
            .remove(index);
        assert!(matches!(
            fixture.check(),
            Err(AuditInventoryError::Missing {
                kind: "source-index entry",
                ..
            })
        ));
    }
}

#[test]
fn stale_audit_identity_is_rejected() {
    let mut fixture = Fixture::new();
    fixture.other["tests"][0]["id"] = json!("build-scripts::retired_name");
    assert!(
        matches!(fixture.check(),Err(AuditInventoryError::Missing {kind:"Rust audit entry", identity}) if identity.ends_with("example.rs::package_case"))
    );
    for removed_source in [Some("fn package_case() {}\n"), Some(""), None] {
        for orphan_index_only in [false, true] {
            let mut fixture = Fixture::new();
            if let Some(source) = removed_source {
                fixture.write("build-scripts/tests/example.rs", source);
            } else {
                fs::remove_file(fixture.root.path().join("build-scripts/tests/example.rs"))
                    .expect("remove owned source fixture");
            }
            fixture.write(
                "build-scripts/src/lib.rs",
                "#[test]\nfn surviving_case() {}\n",
            );
            let mut surviving_audit = fixture.other["tests"][0].clone();
            surviving_audit["id"] = json!("build-scripts::surviving_case");
            surviving_audit["path"] = json!("build-scripts/src/lib.rs");
            fixture.other["tests"]
                .as_array_mut()
                .expect("rows")
                .push(surviving_audit);
            fixture.index["declarations"]
                .as_array_mut()
                .expect("index rows")
                .push(json!({"path":"build-scripts/src/lib.rs","name":"surviving_case","line":2}));
            if orphan_index_only {
                fixture.other["tests"]
                    .as_array_mut()
                    .expect("rows")
                    .remove(0);
            }
            let expected_kind = if orphan_index_only {
                "source-index entry"
            } else {
                "Rust audit entry"
            };
            assert!(
                matches!(fixture.check(), Err(AuditInventoryError::Orphan { kind, identity })
                    if kind == expected_kind && identity == "build-scripts/tests/example.rs::package_case")
            );
        }
    }
    let fixture = Fixture::new();
    fixture.write(
        "Tests/BleatCoreTests/ExampleTests.swift",
        "@Test\nfunc renamed() {}\n",
    );
    assert!(
        matches!(fixture.check(),Err(AuditInventoryError::StaleSource {identity}) if identity.ends_with("ExampleTests.swift::example"))
    );
}

#[test]
fn duplicate_audit_entries_are_rejected() {
    for core in [true, false] {
        let mut fixture = Fixture::new();
        let rows = if core {
            &mut fixture.core["tests"]
        } else {
            &mut fixture.other["tests"]
        };
        let duplicate = rows[0].clone();
        rows.as_array_mut().expect("rows").push(duplicate);
        assert!(matches!(
            fixture.check(),
            Err(AuditInventoryError::Duplicate { .. })
        ));
    }
}

#[test]
fn placeholder_reviews_are_rejected() {
    for core in [true, false] {
        let mut fixture = Fixture::new();
        let row = if core {
            &mut fixture.core["tests"][0]
        } else {
            &mut fixture.other["tests"][0]
        };
        row["purpose"] = json!("TODO");
        assert!(
            matches!(fixture.check(),Err(AuditInventoryError::Review {field,..}) if field=="purpose")
        );
        let mut fixture = Fixture::new();
        if core {
            fixture.core["tests"][0]["decision"] = json!("not_a_decision");
        } else {
            fixture.other["tests"][0]["review"]["decision"] = json!("not_a_decision");
        }
        assert!(
            matches!(fixture.check(), Err(AuditInventoryError::Review {field,..}) if field.ends_with("decision"))
        );
        let mut fixture = Fixture::new();
        if core {
            fixture.core["tests"][0]["source_reviewed"] = json!(false);
        } else {
            fixture.other["tests"][0]["review"]["status"] = json!("not_reviewed");
        }
        assert!(matches!(
            fixture.check(),
            Err(AuditInventoryError::Review { .. })
        ));
    }
}

#[test]
fn empty_required_scopes_are_rejected() {
    let mut fixture = Fixture::new();
    fixture.inventory = json!({});
    assert!(
        matches!(fixture.check(),Err(AuditInventoryError::Shape(message)) if message=="empty host inventory")
    );
    let fixture = Fixture::new();
    fixture.write("build-scripts/tests/example.rs", "fn helper_only() {}\n");
    assert!(
        matches!(fixture.check(), Err(AuditInventoryError::Shape(message)) if message=="empty build-scripts test declarations")
    );
}
