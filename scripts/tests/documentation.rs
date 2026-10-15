use scripts::documentation::{CheckError, DiagnosticKind, check};
use std::{fs, path::Path};

fn fixture(files: &[(&str, &str)]) -> tempfile::TempDir {
    let root = tempfile::tempdir().expect("temporary repository");
    write(
        root.path(),
        "mise.toml",
        "[tasks.\"docs:check\"]\nrun = 'check'\n[tasks.check]\nrun = 'check'\n",
    );
    for (path, text) in files {
        write(root.path(), path, text);
    }
    root
}
fn write(root: &Path, path: &str, text: &str) {
    let file = root.join(path);
    fs::create_dir_all(file.parent().expect("parent")).expect("directories");
    fs::write(file, text).expect("fixture file");
}
#[test]
fn local_reference_links_and_unicode_duplicate_anchors() {
    let root = fixture(&[
        (
            "README.md",
            "[one](docs/page.md#café--code)\n[two][target]\n\n[target]: docs/page.md#café--code-1\n[explicit](docs/page.md#custom)\n",
        ),
        (
            "docs/page.md",
            "# Café & `code`\n# Café & code\n# Title {#custom}\n",
        ),
    ]);
    assert_eq!(check(root.path()).expect("check"), vec![]);
}
#[test]
fn broken_links_report_distinct_causes_and_relative_locations() {
    let root = fixture(&[(
        "README.md",
        "# Start\n[missing](absent.md)\n[anchor](#absent)\n[undefined][no-definition]\n",
    )]);
    let result = check(root.path()).expect("check");
    for (kind, number) in [
        (DiagnosticKind::MissingTarget, 2),
        (DiagnosticKind::MissingAnchor, 3),
        (DiagnosticKind::UndefinedReference, 4),
    ] {
        assert!(
            result
                .iter()
                .any(|d| d.kind == kind && d.line == number && d.file == Path::new("README.md"))
        );
    }
}
#[test]
fn checks_images_encoded_paths_and_html_anchors() {
    let root = fixture(&[
        (
            "README.md",
            "[encoded](docs/a%20b.md#named)\n![image](site/static/photo.svg)\n",
        ),
        ("docs/a b.md", "<a name=\"named\"></a>\n"),
    ]);
    write(root.path(), "site/static/photo.svg", "<svg/>");
    assert!(check(root.path()).expect("check").is_empty());
}
#[test]
fn website_front_matter_routes_slugs_overrides_and_internal_links() {
    let root = fixture(&[
        (
            "site/content/help/_index.md",
            "+++\ntitle = 'Help'\n+++\n[route](/help/start/#connect)\n[internal](@/help/setup.md#connect)\n[custom](/custom/)\n[asset](/logo.svg)\n",
        ),
        (
            "site/content/help/setup.md",
            "+++\nslug = 'start'\n+++\n# Connect\n",
        ),
        (
            "site/content/override.md",
            "+++\npath = 'custom'\n+++\n# Custom\n",
        ),
    ]);
    write(root.path(), "site/static/logo.svg", "<svg/>");
    assert!(check(root.path()).expect("check").is_empty());
}
#[test]
fn website_relative_routes_and_missing_route_anchor() {
    let root = fixture(&[
        (
            "site/content/help/_index.md",
            "[good](setup/)\n[bad](/help/setup/#missing)\n[unknown](/help/unknown/)\n",
        ),
        ("site/content/help/setup.md", "# Setup\n"),
    ]);
    let result = check(root.path()).expect("check");
    assert_eq!(result.len(), 2);
    assert!(
        result
            .iter()
            .any(|d| d.kind == DiagnosticKind::MissingAnchor)
    );
    assert!(
        result
            .iter()
            .any(|d| d.kind == DiagnosticKind::MissingTarget)
    );
}
#[test]
fn summary_accepts_nested_links_and_rejects_prose() {
    let root = fixture(&[
        (
            "docs/SUMMARY.md",
            "- [Guide](guide.md)\n  - [More](guide.md#more)\n",
        ),
        ("docs/guide.md", "# More\n"),
    ]);
    assert!(check(root.path()).expect("check").is_empty());
    write(
        root.path(),
        "docs/SUMMARY.md",
        "Overview prose\n- [Guide](guide.md)\n",
    );
    assert!(
        check(root.path())
            .expect("check")
            .iter()
            .any(|d| d.kind == DiagnosticKind::InvalidNavigation)
    );
}
#[test]
fn named_tasks_are_checked_in_prose_code_and_quoted_commands() {
    let root = fixture(&[(
        "README.md",
        "Use `mise run docs:check`.\n```sh\nmise run 'check'\nmise run missing\n```\n",
    )]);
    let result = check(root.path()).expect("check");
    assert_eq!(result.len(), 1);
    assert_eq!(result[0].kind, DiagnosticKind::UnknownTask);
    assert_eq!(result[0].target, "missing");
}
#[test]
fn external_urls_and_generated_files_are_excluded_without_network() {
    let root = fixture(&[
        (
            "README.md",
            "[web](https://example.invalid/nope#gone)\n[email](mailto:a@example.invalid)\n[app](bleat://book/one)\n",
        ),
        (".build/out.md", "[bad](absent)\n"),
        ("site/public/out.md", "[bad](absent)\n"),
        ("target/out.md", "[bad](absent)\n"),
    ]);
    assert!(check(root.path()).expect("check").is_empty());
}
#[test]
fn missing_and_malformed_configuration_are_typed() {
    let root = fixture(&[]);
    write(root.path(), "mise.toml", "not TOML");
    assert!(matches!(
        check(root.path()),
        Err(CheckError::Configuration { .. })
    ));
    write(root.path(), "mise.toml", "[env]\n");
    assert!(matches!(check(root.path()), Err(CheckError::MissingTasks)));
    fs::remove_file(root.path().join("mise.toml")).expect("remove config");
    assert!(matches!(check(root.path()), Err(CheckError::Read { .. })));
}
#[test]
fn does_not_modify_repository_or_follow_escaping_paths() {
    let text = "# Guide\n[escape](../private.md)\n";
    let root = fixture(&[("README.md", text)]);
    let result = check(root.path()).expect("check");
    assert_eq!(result[0].kind, DiagnosticKind::MissingTarget);
    assert_eq!(
        fs::read_to_string(root.path().join("README.md")).expect("unchanged"),
        text
    );
    assert!(!root.path().join(".build").exists());
}

#[test]
fn summary_rejects_headings_and_reports_missing_page_targets() {
    let root = fixture(&[("docs/SUMMARY.md", "# Overview\n- [Absent](absent.md)\n")]);
    let result = check(root.path()).expect("check");
    assert!(
        result
            .iter()
            .any(|d| d.kind == DiagnosticKind::InvalidNavigation && d.line == 1)
    );
    assert!(
        result
            .iter()
            .any(|d| d.kind == DiagnosticKind::MissingTarget && d.line == 2)
    );
}
#[test]
fn cli_returns_success_or_failure_with_stable_diagnostics() {
    let root = fixture(&[("README.md", "# Guide\n")]);
    let invoke = || {
        std::process::Command::new(env!("CARGO_BIN_EXE_check-documentation"))
            .arg("--repository-root")
            .arg(root.path())
            .output()
            .expect("CLI process")
    };
    let success = invoke();
    assert!(success.status.success());
    assert!(String::from_utf8_lossy(&success.stdout).contains("Documentation references verified"));
    write(root.path(), "README.md", "[absent](absent.md)\n");
    let failed = invoke();
    assert!(!failed.status.success());
    assert!(
        String::from_utf8_lossy(&failed.stderr).contains("README.md:1: missing_target: absent.md")
    );
    assert!(
        !String::from_utf8_lossy(&failed.stderr)
            .contains(&root.path().to_string_lossy().to_string())
    );
}
#[test]
fn front_matter_preserves_diagnostic_line_numbers() {
    let root = fixture(&[(
        "site/content/broken.md",
        "+++\ntitle = 'Broken'\n+++\n[bad](/absent/)\n",
    )]);
    let result = check(root.path()).expect("check");
    assert_eq!(result.len(), 1);
    assert_eq!(result[0].line, 4);
}

#[test]
fn book_links_to_unlisted_chapters_fail_before_rendering() {
    let root = fixture(&[
        ("docs/SUMMARY.md", "- [Guide](guide.md)\n"),
        ("docs/guide.md", "[hidden](hidden.md)\n"),
        ("docs/hidden.md", "# Hidden\n"),
    ]);
    let result = check(root.path()).expect("check");
    assert_eq!(result.len(), 1);
    assert_eq!(result[0].kind, DiagnosticKind::UnlistedChapter);
    write(
        root.path(),
        "docs/SUMMARY.md",
        "- [Guide](guide.md)\n  - [Hidden](hidden.md)\n",
    );
    assert!(check(root.path()).expect("check").is_empty());
}
