use squad::surface_lint::{lint_harness_path, lint_workspace, LintLimits};
use std::fs;

#[test]
fn empty_single_file_harness_is_rejected() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("harness.txt");
    fs::write(&path, "").unwrap();
    let report = lint_harness_path(&path, &LintLimits::default()).unwrap();
    assert!(report.findings.iter().any(|f| f.code == "empty_harness"));
}

#[test]
fn workspace_and_harness_checks() {
    let dir = tempfile::tempdir().unwrap();
    let limits = LintLimits::default();
    assert!(lint_harness_path(dir.path(), &limits).unwrap().has_errors());
    fs::create_dir_all(dir.path().join(".squad/roles")).unwrap();
    fs::write(
        dir.path().join(".squad/roles/worker.md"),
        "<!-- squad-devkit template: worker -->\n",
    )
    .unwrap();
    fs::write(dir.path().join("AGENTS.md"), "x".repeat(8193)).unwrap();
    let report = lint_workspace(dir.path(), &limits).unwrap();
    assert_eq!(report.error_count(), 1);
    assert_eq!(report.warn_count(), 1);
    assert!(!report.passed(true));
}

#[test]
fn repository_surface_is_clean() {
    let report = lint_workspace(
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")),
        &LintLimits::default(),
    )
    .unwrap();
    assert!(report.findings.is_empty(), "{:?}", report.findings);
}

#[test]
fn limits_placeholders_and_cli() {
    use std::process::Command;
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    fs::create_dir_all(root.join(".squad/roles")).unwrap();
    fs::create_dir_all(root.join(".squad/rules")).unwrap();
    let manager = root.join(".squad/roles/manager-devkit.md");
    fs::write(&manager, "a".repeat(19_000)).unwrap();
    assert!(lint_workspace(root, &LintLimits::default())
        .unwrap()
        .findings
        .is_empty());
    fs::write(&manager, "a".repeat(24_577)).unwrap();
    assert_eq!(
        lint_workspace(root, &LintLimits::default())
            .unwrap()
            .warn_count(),
        1
    );
    fs::write(&manager, "a".repeat(32_769)).unwrap();
    assert_eq!(
        lint_workspace(root, &LintLimits::default())
            .unwrap()
            .error_count(),
        1
    );
    fs::remove_file(manager).unwrap();
    let role = root.join(".squad/roles/worker.md");
    fs::write(&role, "a".repeat(4097)).unwrap();
    assert_eq!(
        lint_workspace(root, &LintLimits::default())
            .unwrap()
            .warn_count(),
        1
    );
    fs::write(&role, "a".repeat(16385)).unwrap();
    assert_eq!(
        lint_workspace(root, &LintLimits::default())
            .unwrap()
            .error_count(),
        1
    );
    fs::write(&role, "`{{ ignored }}`\n```\n{% ignored %}\n```\n").unwrap();
    assert!(lint_harness_path(&role, &LintLimits::default())
        .unwrap()
        .findings
        .is_empty());
    fs::write(&role, "{{ value }} {% if %}").unwrap();
    let bin = env!("CARGO_BIN_EXE_squad");
    assert!(Command::new(bin)
        .args(["lint", "--dir"])
        .arg(root)
        .status()
        .unwrap()
        .success());
    assert!(!Command::new(bin)
        .args(["lint", "--strict", "--dir"])
        .arg(root)
        .status()
        .unwrap()
        .success());
    let output = Command::new(bin)
        .args(["lint", "--json", "--dir"])
        .arg(root)
        .output()
        .unwrap();
    let json: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(json["findings"][0]["code"], "template_placeholder");
    fs::write(root.join(".squad/rules/rule.md"), "x".repeat(2049)).unwrap();
    let report = lint_workspace(root, &LintLimits::default()).unwrap();
    assert!(report.has_errors());
    assert!(report.findings.iter().any(|f| f.code == "missing_paths"));
    fs::write(root.join("AGENTS.md"), "x".repeat(32769)).unwrap();
    assert!(lint_workspace(root, &LintLimits::default())
        .unwrap()
        .findings
        .iter()
        .any(|f| f.code == "size_error" && f.path.ends_with("AGENTS.md")));
}

#[cfg(unix)]
#[test]
fn rejects_symlinks() {
    use std::os::unix::fs::symlink;
    let dir = tempfile::tempdir().unwrap();
    symlink("/missing", dir.path().join("AGENTS.md")).unwrap();
    let report = lint_workspace(dir.path(), &LintLimits::default()).unwrap();
    assert_eq!(report.findings[0].code, "symlink");
    assert_eq!(
        lint_harness_path(&dir.path().join("AGENTS.md"), &LintLimits::default())
            .unwrap()
            .findings[0]
            .code,
        "symlink"
    );
}

#[cfg(unix)]
#[test]
fn rejects_symlinked_workspace_ancestor_without_traversing() {
    use std::os::unix::fs::symlink;
    let root = tempfile::tempdir().unwrap();
    let external = tempfile::tempdir().unwrap();
    fs::create_dir(external.path().join("rules")).unwrap();
    fs::write(external.path().join("rules/ext.md"), "{{ external }}").unwrap();
    symlink(external.path(), root.path().join(".squad")).unwrap();
    let report = lint_workspace(root.path(), &LintLimits::default()).unwrap();
    assert_eq!(report.error_count(), 1);
    assert_eq!(report.findings[0].code, "symlink");
    assert_eq!(report.checked_files, 0);
}
