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

#[test]
fn task_commands_and_approval_validation() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("p.md");
    fs::write(&file, "## Tasks\n- one (codex high, developer): Ship\n  details\n### empty\n- dup: first\n- dup: second\n## Acceptance\nWorks\n").unwrap();
    for (op, expected) in [
        ("task", "Ship\n  details\n"),
        (
            "task-entry",
            "- one (codex high, developer): Ship\n  details\n",
        ),
    ] {
        Command::cargo_bin("squad")
            .unwrap()
            .args(["plan", op])
            .arg(&file)
            .arg("one")
            .assert()
            .success()
            .stdout(expected);
        for id in ["missing", "dup"] {
            Command::cargo_bin("squad")
                .unwrap()
                .args(["plan", op])
                .arg(&file)
                .arg(id)
                .assert()
                .code(1)
                .stdout("");
        }
    }
    Command::cargo_bin("squad")
        .unwrap()
        .args(["plan", "task"])
        .arg(&file)
        .arg("empty")
        .assert()
        .code(1);
    for line in [
        "- push: *",
        "- review-override: ",
        "- review-override: ok\n- push: *",
        "- plan-review-override: bad\r",
    ] {
        let before = fs::read(&file).unwrap();
        Command::cargo_bin("squad")
            .unwrap()
            .args(["plan", "append-approval"])
            .arg(&file)
            .arg(line)
            .assert()
            .code(2);
        assert_eq!(fs::read(&file).unwrap(), before);
    }
    for line in [
        "- review-override: accepted",
        "- plan-review-override: accepted",
    ] {
        Command::cargo_bin("squad")
            .unwrap()
            .args(["plan", "append-approval"])
            .arg(&file)
            .arg(line)
            .assert()
            .success();
        assert!(fs::read_to_string(&file).unwrap().contains(line));
    }
}

#[test]
fn context_truncates_at_utf8_boundaries() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("p.md");
    fs::write(&file, "").unwrap();
    let text = "Việt🙂\n";
    fs::write(dir.path().join("p.context.md"), text).unwrap();
    for max in 0..=text.len() + 1 {
        let mut end = max.min(text.len());
        while !text.is_char_boundary(end) {
            end -= 1;
        }
        Command::cargo_bin("squad")
            .unwrap()
            .args(["plan", "context"])
            .arg(&file)
            .env("SQUAD_WORKER_MAX_CONTEXT_BYTES", max.to_string())
            .assert()
            .success()
            .stdout(format!(
                "### Shared Context (p.context.md)\n{}\n\n",
                &text[..end]
            ));
    }
}
