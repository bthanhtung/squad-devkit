use std::path::Path;

#[test]
fn trace_normalizes_supported_engine_records_and_skips_bad_lines() {
    for (engine, line) in [
        (
            "claude",
            r#"{"type":"assistant","timestamp":"t","message":{"model":"m","usage":{"input_tokens":4,"output_tokens":2}}}"#,
        ),
        (
            "codex",
            r#"{"type":"token_count","usage":{"input_tokens":4,"output_tokens":2}}"#,
        ),
        ("opencode", r#"{"type":"step-start","model":"m"}"#),
    ] {
        let events = squad::trace::normalize(engine, &format!("bad\n{line}"));
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].schema_version, 1);
        assert_eq!(events[0].engine, engine);
    }
}

#[test]
fn pass_at_k_and_fixture_baseline() {
    assert!((squad::eval::pass_at_k(3, 1, 1) - 1.0 / 3.0).abs() < 1e-9);
    assert_eq!(squad::eval::pass_at_k(3, 1, 3), 1.0);
    let dir = tempfile::tempdir().unwrap();
    let suite = dir.path().join("suite.json");
    std::fs::write(&suite, r#"{"trials":2,"tasks":[{"id":"ok","cmd":"true"}]}"#).unwrap();
    let report = squad::eval::run_fixture_suite(Path::new(&suite), None).unwrap();
    assert_eq!(report.tasks[0].passed, 2);
    let mut baseline = report.clone();
    baseline.tasks[0].pass_at_k[0] = 1.0;
    let mut regressed = report;
    regressed.tasks[0].pass_at_k[0] = 0.0;
    assert!(squad::eval::check_baseline(&regressed, &baseline).is_err());
}

#[test]
fn baseline_comparison_rejects_removed_task() {
    let dir = tempfile::tempdir().unwrap();
    let suite = dir.path().join("suite.json");
    std::fs::write(
        &suite,
        r#"{"tasks":[{"id":"missing","cmd":"false"},{"id":"kept","cmd":"true"}]}"#,
    )
    .unwrap();
    let baseline = squad::eval::run_fixture_suite(&suite, None).unwrap();
    let mut candidate = baseline.clone();
    candidate.tasks.remove(0);

    let error = squad::eval::check_baseline(&candidate, &baseline).unwrap_err();
    assert!(error.to_string().contains("missing"));
}

#[test]
fn duplicate_task_ids_are_rejected() {
    let dir = tempfile::tempdir().unwrap();
    let suite = dir.path().join("suite.json");
    std::fs::write(
        &suite,
        r#"{"tasks":[{"id":"dup","cmd":"true"},{"id":"dup","cmd":"true"}]}"#,
    )
    .unwrap();
    let error = squad::eval::run_fixture_suite(&suite, None).unwrap_err();
    assert!(error.to_string().contains("dup"));

    std::fs::write(&suite, r#"{"tasks":[{"id":"dup","cmd":"true"}]}"#).unwrap();
    let report = squad::eval::run_fixture_suite(&suite, None).unwrap();
    let mut duplicate = report.clone();
    duplicate.tasks.push(duplicate.tasks[0].clone());
    for (candidate, baseline) in [(&duplicate, &report), (&report, &duplicate)] {
        let error = squad::eval::check_baseline(candidate, baseline).unwrap_err();
        assert!(error.to_string().contains("dup"));
    }
}

#[test]
fn fixture_trials_are_isolated_and_oracle_grades_independently() {
    let dir = tempfile::tempdir().unwrap();
    let fixture = dir.path().join("fixture");
    std::fs::create_dir(&fixture).unwrap();
    std::fs::write(fixture.join("count"), "0").unwrap();
    let suite = dir.path().join("suite.json");
    let fixture = fixture.to_str().unwrap();
    std::fs::write(
        &suite,
        format!(r#"{{"trials":2,"tasks":[{{"id":"isolated","cmd":"echo changed > count; exit 1","fixture_dir":{fixture:?},"oracle":"test \"$(cat count)\" = changed"}}]}}"#),
    )
    .unwrap();
    let report = squad::eval::run_fixture_suite(&suite, None).unwrap();
    assert_eq!(report.tasks[0].passed, 2);
}

#[test]
fn timed_out_command_fails_even_when_oracle_would_pass() {
    let dir = tempfile::tempdir().unwrap();
    let suite = dir.path().join("suite.json");
    std::fs::write(
        &suite,
        r#"{"tasks":[{"id":"timeout","cmd":"sleep 2","timeout_secs":1,"oracle":"true"}]}"#,
    )
    .unwrap();
    let report = squad::eval::run_fixture_suite(&suite, None).unwrap();
    assert_eq!(report.tasks[0].passed, 0);
}
