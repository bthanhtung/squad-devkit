use assert_cmd::Command;
use predicates::str::contains;

#[test]
fn redacts_bearer_credentials_after_multiple_spaces_or_tabs() {
    for separator in ["  ", "\t", " \t "] {
        let input = format!("Authorization: Bearer{separator}fixture-secret");
        assert_eq!(
            squad::redact::redact(&input),
            format!("Authorization: Bearer{separator}[REDACTED]")
        );
    }
}

#[test]
fn redacts_assignment_after_multibyte_character() {
    assert_eq!(
        squad::redact::redact("🔑API_KEY=fixture-secret"),
        "🔑API_KEY=[REDACTED]"
    );
}

#[test]
fn malformed_hook_is_denied_by_default() {
    let root = tempfile::tempdir().unwrap();
    Command::cargo_bin("squad")
        .unwrap()
        .args(["guard", "pre-tool-use", root.path().to_str().unwrap()])
        .env_remove("SQUAD_DEVKIT_GUARD_FAIL_OPEN")
        .env_remove("SQUAD_DEVKIT_GUARD")
        .write_stdin("not json")
        .assert()
        .success()
        .stdout(contains("\"permissionDecision\":\"deny\""));
}

#[test]
fn explicit_fail_open_allows_invalid_input() {
    let root = tempfile::tempdir().unwrap();
    Command::cargo_bin("squad")
        .unwrap()
        .args([
            "guard",
            "pre-tool-use",
            root.path().to_str().unwrap(),
            "--guard-mode",
            "fail-open",
        ])
        .write_stdin("not json")
        .assert()
        .success()
        .stdout("");
}

#[test]
fn redacts_every_credential_in_prefixed_and_mixed_lines() {
    Command::cargo_bin("squad")
        .unwrap()
        .arg("redact")
        .write_stdin("2026-11-24 API_KEY=fixture-credential-value\npassword=fixture-one Authorization: Bearer tok123\nAPI_KEY=first PASSWORD=second\n")
        .assert()
        .success()
        .stdout("2026-11-24 API_KEY=[REDACTED]\npassword=[REDACTED] Authorization: Bearer [REDACTED]\nAPI_KEY=[REDACTED] PASSWORD=[REDACTED]\n");
}
