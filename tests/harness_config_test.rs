use squad::harness_config::*;
use tempfile::TempDir;

#[test]
fn parsing_and_roundtrip() {
    let text = r#"version = 1 # schema
[gates]
pre_merge = ["echo \"ok\"", 'literal # value']
post_merge = [
 'test',
 # comment
 "second",
]
[policy]
protected_paths = ['.git/**']
require_review_paths = ["src/**"]
max_diff_lines = 120
[budgets]
worker_max_tokens = 1000
worker_max_usd = 1.25
plan_max_usd = 2e1
[sandbox]
profile = "strict"
network = 'allow'
"#;
    let c = parse_harness_toml(text).unwrap();
    assert_eq!(c.gates.post_merge, ["test", "second"]);
    assert_eq!(c.budgets.plan_max_usd, Some(20.0));
    assert_eq!(parse_harness_toml(&render_harness_toml(&c)).unwrap(), c);
}

#[test]
fn numeric_digit_separators() {
    let c = parse_harness_toml(
        "version = 1\n[budgets]\nworker_max_tokens = 100_000\nworker_max_usd = 1_000.50\nplan_max_usd = +1_0.2_5e+1_0",
    )
    .unwrap();
    assert_eq!(c.budgets.worker_max_tokens, Some(100_000));
    assert_eq!(c.budgets.worker_max_usd, Some(1000.5));
    assert_eq!(c.budgets.plan_max_usd, Some(10.25e10));
    for key in ["worker_max_tokens", "worker_max_usd"] {
        for value in [
            "_1", "1_", "1__0", "1._0", "1_.0", "0_1", "1_e2", "1e_2", "1e+_2", "1e2_",
        ] {
            assert!(
                parse_harness_toml(&format!("version = 1\n[budgets]\n{key} = {value}")).is_err(),
                "{key} = {value}"
            );
        }
    }
}

#[test]
fn literal_tabs_in_quoted_strings() {
    for quote in ['"', '\''] {
        let c = parse_harness_toml(&format!(
            "version = 1\n[gates]\npre_merge = [{quote}echo\tok{quote}]"
        ))
        .unwrap();
        assert_eq!(c.gates.pre_merge, ["echo\tok"]);
        assert_eq!(parse_harness_toml(&render_harness_toml(&c)).unwrap(), c);
        for control in ['\0', '\u{8}', '\n', '\u{c}', '\r', '\u{1f}', '\u{7f}'] {
            assert!(parse_harness_toml(&format!(
                "version = 1\n[gates]\npre_merge = [{quote}echo{control}ok{quote}]"
            ))
            .is_err());
        }
    }
}

#[test]
fn rejects_invalid_input() {
    for suffix in [
        "[unknown]",
        "unknown = 1",
        "version = 1",
        "[sandbox]\nprofile = 'bad'",
        "[sandbox]\nnetwork = 'bad'",
        "[budgets]\nworker_max_tokens = -1",
        "[budgets]\nworker_max_usd = nan",
        "[budgets]\nworker_max_usd = inf",
        "[budgets]\nworker_max_usd = 0",
        "[gates]\npre_merge = ['a' 'b']",
        "[gates]\npre_merge = ['a',,]",
        "[gates]\npre_merge = [1]",
        "[policy]\nmax_diff_lines = 01",
        "[gates]\npre_merge = ['x'] junk",
        "[gates]\npre_merge = ['\0']",
        "[gates]\npre_merge = [\"\\u0000\"]",
        "[gates]\npre_merge = [\"\\q\"]",
        "[gates]\n[gates]",
    ] {
        let err = parse_harness_toml(&format!("version = 1\n{suffix}")).unwrap_err();
        assert!(err.to_string().contains("line"), "{suffix}: {err}");
    }
    assert!(parse_harness_toml("").is_err());
    assert!(parse_harness_toml("version = 2").is_err());
}

#[test]
fn detects_stacks_and_loads() {
    for (file, expected) in [
        ("Cargo.toml", "cargo test --all"),
        ("package.json", "npm test"),
        ("pyproject.toml", "pytest"),
        ("pytest.ini", "pytest"),
        ("go.mod", "go test ./..."),
    ] {
        let tmp = TempDir::new().unwrap();
        std::fs::write(tmp.path().join(file), "").unwrap();
        let c = detect_default_harness(tmp.path());
        assert!(c.gates.post_merge.contains(&expected.to_owned()));
        assert_eq!(parse_harness_toml(&render_harness_toml(&c)).unwrap(), c);
    }
    let tmp = TempDir::new().unwrap();
    assert!(detect_default_harness(tmp.path())
        .gates
        .pre_merge
        .is_empty());
    assert!(load_harness_config(tmp.path()).unwrap().is_none());
    std::fs::create_dir(tmp.path().join(".squad")).unwrap();
    std::fs::write(tmp.path().join(".squad/harness.toml"), "version = 2").unwrap();
    assert!(load_harness_config(tmp.path()).is_err());
}

#[test]
fn defaults_escapes_and_numeric_boundaries() {
    let c = parse_harness_toml("version = 1\r\n").unwrap();
    assert_eq!(c.sandbox.profile, SandboxProfile::Workspace);
    assert_eq!(c.sandbox.network, NetworkPolicy::Deny);
    assert_eq!(c.policy.max_diff_lines, None);
    let c = parse_harness_toml(
        r#"version = 1
[gates]
pre_merge = ["\b\t\n\f\r\"\\\u0061\U0001F980", 'a\b#c']
[policy]
max_diff_lines = 0
[budgets]
worker_max_tokens = 18446744073709551615
"#,
    )
    .unwrap();
    assert_eq!(c.gates.pre_merge[0], "\u{8}\t\n\u{c}\r\"\\a🦀");
    assert_eq!(c.gates.pre_merge[1], "a\\b#c");
    assert_eq!(parse_harness_toml(&render_harness_toml(&c)).unwrap(), c);
    for text in [
        "version = 1\n[budgets]\nworker_max_tokens = 18446744073709551616",
        "version = 1\n[budgets]\nplan_max_usd = 1e999",
        "version = 1\n[budgets]\nplan_max_usd = -0.5",
        "version = 1\n[gates]\npre_merge = [\"\\UFFFFFFFF\"]",
        "version = 1\n[gates]\npre_merge = [\"\\uD800\"]",
        "version = 1\n[gates]\npre_merge = [\"unterminated",
        "version = 1\n[gates]\npre_merge = ['x'",
        "version = 1\n#\u{7f}",
    ] {
        assert!(parse_harness_toml(text).is_err(), "{text}");
    }
}

#[test]
fn init_preserves_manifest_and_combines_stacks() {
    let tmp = TempDir::new().unwrap();
    for file in [
        "Cargo.toml",
        "package.json",
        "pytest.ini",
        "pyproject.toml",
        "go.mod",
    ] {
        std::fs::write(tmp.path().join(file), "").unwrap();
    }
    assert!(squad::init::init_harness(tmp.path(), false).unwrap());
    let c = load_harness_config(tmp.path()).unwrap().unwrap();
    assert_eq!(c.gates.post_merge.len(), 4);
    let path = tmp.path().join(".squad/harness.toml");
    std::fs::write(&path, "custom content").unwrap();
    assert!(!squad::init::init_harness(tmp.path(), false).unwrap());
    assert_eq!(std::fs::read_to_string(&path).unwrap(), "custom content");
    assert!(squad::init::init_harness(tmp.path(), true).unwrap());
    assert_eq!(load_harness_config(tmp.path()).unwrap(), Some(c));
    std::fs::remove_file(&path).unwrap();
    std::fs::create_dir(&path).unwrap();
    assert!(load_harness_config(tmp.path()).is_err());
}
