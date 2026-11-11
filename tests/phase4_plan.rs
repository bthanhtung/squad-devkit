use assert_cmd::Command;
use std::fs;

#[test]
fn plan_validation_and_context() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("p.md");
    fs::write(&file, "## Goal\nhello\n\n## Findings\nworld\n").unwrap();
    Command::cargo_bin("squad")
        .unwrap()
        .current_dir(dir.path())
        .args(["plan", "validate"])
        .arg(&file)
        .assert()
        .failure()
        .stdout(predicates::str::contains("missing section: ## Triage"));
    Command::cargo_bin("squad")
        .unwrap()
        .current_dir(dir.path())
        .args(["plan", "context"])
        .arg(&file)
        .assert()
        .success()
        .stdout("### Plan Goal\nhello\n\n### Plan Findings\nworld\n\n");
}
