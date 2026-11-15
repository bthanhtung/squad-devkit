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

#[test]
fn quick_plan_perspectives() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("quick.md");
    for (risk, complexity, perspectives, valid) in [
        ("low", "low", "", true),
        ("moderate", "high", "", false),
        ("low", "moderate", "", false),
        ("low", "low", "## Perspectives\n- End user: works.\n", false),
    ] {
        fs::write(&file, format!("## Triage\n- Risk: {risk}\n- Complexity: {complexity}\n- squad-route: dev\n## Goal\nShip\n{perspectives}## Tasks\n- dev: implement\n## Acceptance\n- Works\n")).unwrap();
        let mut cmd = Command::cargo_bin("squad").unwrap();
        let assertion = cmd.args(["plan", "validate"]).arg(&file).assert();
        if valid {
            assertion.success();
        } else {
            assertion.failure();
        }
    }
}
