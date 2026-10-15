use std::{fs, path::Path, process::Command};

use plist::Value;
use scripts::build_metadata::{MetadataError, write_metadata};

fn git(root: &Path, args: &[&str]) -> String {
    let result = Command::new("git")
        .arg("-C")
        .arg(root)
        .args(args)
        .output()
        .expect("run fixture Git");
    assert!(result.status.success(), "fixture Git failed");
    String::from_utf8(result.stdout)
        .expect("Git output")
        .trim()
        .into()
}

fn repository() -> tempfile::TempDir {
    let directory = tempfile::tempdir().expect("repository fixture");
    git(directory.path(), &["init", "--quiet"]);
    git(
        directory.path(),
        &[
            "-c",
            "user.name=Build Test",
            "-c",
            "user.email=build@example.invalid",
            "-c",
            "commit.gpgsign=false",
            "commit",
            "--quiet",
            "--allow-empty",
            "-m",
            "Fixture",
        ],
    );
    directory
}

fn template(root: &Path) -> std::path::PathBuf {
    let path = root.join("template.plist");
    let data = Value::Dictionary(plist::Dictionary::from_iter([
        ("BleatBuildDate", Value::String("Unavailable".into())),
        ("BleatGitCommit", Value::String("Unavailable".into())),
        (
            "CFBundleVersion",
            Value::String("$(CURRENT_PROJECT_VERSION)".into()),
        ),
        ("Capability", Value::Boolean(true)),
    ]));
    data.to_file_xml(&path).expect("template plist");
    path
}

#[test]
fn generates_metadata_without_mutating_template_or_build_setting_placeholders() {
    let repository = repository();
    let template = template(repository.path());
    let original = Value::from_file(&template).expect("original template");
    let output = repository.path().join("generated.plist");
    write_metadata(repository.path(), &template, &output).expect("generate metadata");
    let generated = Value::from_file(&output).expect("generated plist");
    let fields = generated.as_dictionary().expect("dictionary");
    assert_eq!(
        fields["BleatGitCommit"].as_string(),
        Some(git(repository.path(), &["rev-parse", "--short=8", "HEAD"]).as_str())
    );
    let date = fields["BleatBuildDate"].as_string().expect("build date");
    assert!(chrono::DateTime::parse_from_rfc3339(date).is_ok());
    assert!(date.ends_with('Z'));
    let mut expected = original
        .clone()
        .into_dictionary()
        .expect("template dictionary");
    expected.insert("BleatGitCommit".into(), fields["BleatGitCommit"].clone());
    expected.insert("BleatBuildDate".into(), fields["BleatBuildDate"].clone());
    assert_eq!(generated, Value::Dictionary(expected));
    assert_eq!(
        Value::from_file(&template).expect("unchanged template"),
        original
    );
}

#[test]
fn reads_commit_from_detached_worktree_git_file() {
    let repository = repository();
    let checkout = tempfile::tempdir().expect("worktree parent");
    let worktree = checkout.path().join("checkout");
    git(
        repository.path(),
        &[
            "worktree",
            "add",
            "--detach",
            worktree.to_str().expect("worktree path"),
            "HEAD",
        ],
    );
    assert!(worktree.join(".git").is_file());
    let template = template(&worktree);
    let output = worktree.join("generated.plist");
    write_metadata(&worktree, &template, &output).expect("worktree metadata");
    assert_eq!(
        Value::from_file(output)
            .expect("metadata")
            .as_dictionary()
            .expect("dictionary")["BleatGitCommit"]
            .as_string(),
        Some(git(repository.path(), &["rev-parse", "--short=8", "HEAD"]).as_str())
    );
}

#[test]
fn missing_git_preserves_existing_output_and_reports_git_stage() {
    let root = tempfile::tempdir().expect("fixture");
    let template = template(root.path());
    let output = root.path().join("generated.plist");
    fs::copy(&template, &output).expect("prior output");
    let original = Value::from_file(&output).expect("prior plist");
    let error = write_metadata(root.path(), &template, &output).expect_err("no Git checkout");
    assert!(matches!(error, MetadataError::GitExit(_)));
    assert!(error.to_string().starts_with("metadata.git.exit:"));
    assert!(
        !error
            .to_string()
            .contains(root.path().to_str().expect("fixture path"))
    );
    assert_eq!(
        Value::from_file(output).expect("preserved output"),
        original
    );
}

#[test]
fn distinguishes_missing_malformed_and_non_dictionary_templates() {
    let repository = repository();
    let template = repository.path().join("template.plist");
    let output = repository.path().join("generated.plist");
    assert!(matches!(
        write_metadata(repository.path(), &template, &output),
        Err(MetadataError::Read(_))
    ));
    fs::write(&template, b"not a plist").expect("malformed template");
    assert!(matches!(
        write_metadata(repository.path(), &template, &output),
        Err(MetadataError::Decode(_))
    ));
    Value::Array(vec![])
        .to_file_xml(&template)
        .expect("array template");
    assert!(matches!(
        write_metadata(repository.path(), &template, &output),
        Err(MetadataError::NotDictionary)
    ));
    assert!(!output.exists());
}

#[test]
fn output_failure_is_typed() {
    let repository = repository();
    let template = template(repository.path());
    assert!(matches!(
        write_metadata(
            repository.path(),
            &template,
            &repository.path().join("missing/generated.plist")
        ),
        Err(MetadataError::Write(_))
    ));
}

#[cfg(target_os = "macos")]
#[test]
fn command_works_with_canonical_sandbox_inputs_and_only_derived_output_writable() {
    let repository = repository();
    let root = repository.path().canonicalize().expect("canonical fixture");
    let template = template(&root);
    let output = root.join("generated.plist");
    let original = Value::from_file(&template).expect("template");
    fs::write(root.join("undeclared.txt"), b"must remain inaccessible").expect("undeclared input");
    let quote = |path: &Path| {
        serde_json::to_string(path.to_str().expect("fixture path")).expect("quoted path")
    };
    let profile = format!(
        "(version 1)(allow default)(deny file-read* file-write* (subpath {}))(allow file-read* (literal {})(literal {})(subpath {}))(allow file-read* file-write* (literal {}))",
        quote(&root),
        quote(&root),
        quote(&template),
        quote(&root.join(".git")),
        quote(&output),
    );
    let denied = Command::new("/usr/bin/sandbox-exec")
        .args(["-p", &profile, "/bin/cat"])
        .arg(root.join("undeclared.txt"))
        .output()
        .expect("sandbox probe");
    assert!(
        !denied.status.success(),
        "sandbox must actually restrict canonical paths"
    );
    let result = Command::new("/usr/bin/sandbox-exec")
        .args([
            "-p",
            &profile,
            env!("CARGO_BIN_EXE_write-build-metadata"),
            "--repository-root",
        ])
        .arg(&root)
        .arg("--template")
        .arg(&template)
        .arg("--output")
        .arg(&output)
        .output()
        .expect("sandboxed metadata command");
    assert!(
        result.status.success(),
        "{}",
        String::from_utf8_lossy(&result.stderr)
    );
    assert_eq!(
        Value::from_file(&template).expect("template retained"),
        original
    );
    assert_ne!(
        Value::from_file(&output).expect("generated metadata"),
        original
    );
}
