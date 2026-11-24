#[cfg(unix)]
use assert_cmd::Command;
#[cfg(unix)]
use predicates::prelude::*;
use squad::worker_config::{parse_codex_models, parse_config};
#[cfg(unix)]
use std::fs;
#[cfg(unix)]
use std::path::Path;
#[cfg(unix)]
use tempfile::TempDir;

#[test]
fn validates_saved_selections_and_discovered_models() {
    for model in ["", "-flag", "bad\nvalue", "two words", "bad\u{85}value"] {
        let value = serde_json::json!({"version":1,"engines":{"codex":{"fast":{"model":model}}}});
        assert!(parse_config(&value.to_string()).is_err());
    }
    for effort in ["", "HIGH", "high\nvalue", "$(command)", "unsupported"] {
        let value = serde_json::json!({"version":1,"engines":{"codex":{"fast":{"model":"fixture","effort":effort}}}});
        assert!(parse_config(&value.to_string()).is_err());
    }
    for (length, valid) in [(1024, true), (1025, false)] {
        let value =
            serde_json::json!({"version":1,"engines":{"codex":{"source":"é".repeat(length)}}});
        assert_eq!(parse_config(&value.to_string()).is_ok(), valid);
    }
    assert!(parse_config(r#"{"version":2,"engines":{}}"#).is_err());
    assert!(parse_config(r#"{"version":1,"engines":{"ccr":{}}}"#).is_err());
    let catalog = serde_json::json!({"models":[
        {"slug":"fixture-id","display_name":"Friendly fixture","visibility":"list"},
        {"slug":"fixture-id","display_name":"Duplicate","visibility":"list"},
        {"slug":"hidden","visibility":"hide"}]});
    let models = parse_codex_models(&catalog).unwrap();
    assert_eq!(models.len(), 1);
    assert_eq!(models[0].name, "Friendly fixture");
    assert!(parse_codex_models(&serde_json::json!({"models":[]})).is_err());
}

#[cfg(unix)]
fn executable(path: &Path, content: &str) {
    use std::os::unix::fs::PermissionsExt;
    fs::write(path, content).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o755)).unwrap();
}

/// A fake `codex` whose `debug models` lists one model with low and high efforts.
#[cfg(unix)]
const FIXTURE_CODEX: &str = r#"#!/bin/sh
printf '{"models":[{"slug":"fixture-id","display_name":"Friendly fixture","visibility":"list","supported_reasoning_levels":[{"effort":"low"},{"effort":"high"}]}]}'
"#;

#[cfg(unix)]
struct Fixture {
    dir: TempDir,
}

#[cfg(unix)]
impl Fixture {
    fn new() -> Self {
        let fixture = Self {
            dir: TempDir::new().unwrap(),
        };
        for child in ["bin", "home", "home/.codex", ".squad"] {
            fs::create_dir_all(fixture.dir.path().join(child)).unwrap();
        }
        fixture
    }
    fn command(&self) -> Command {
        let mut command = Command::cargo_bin("squad").unwrap();
        command
            .current_dir(self.dir.path())
            .env("PATH", self.dir.path().join("bin"))
            .env("HOME", self.dir.path().join("home"))
            .env("CODEX_HOME", self.dir.path().join("home/.codex"))
            .env("XDG_CONFIG_HOME", self.dir.path().join("home/.config"));
        command
    }
    fn cli(&self, name: &str, content: &str) {
        executable(&self.dir.path().join("bin").join(name), content);
    }
    fn saved(&self) -> std::path::PathBuf {
        self.dir.path().join(".squad/worker-models.json")
    }
}

#[test]
#[cfg(unix)]
fn setup_saves_effort_reviews_cancels_and_preserves_existing_selections() {
    let f = Fixture::new();
    f.cli("codex", FIXTURE_CODEX);
    f.command()
        .args(["config", "workers"])
        .write_stdin("q\n")
        .assert()
        .success()
        .stdout(predicate::str::contains("Cancelled"));
    assert!(!f.saved().exists());
    f.command()
        .args(["config", "workers"])
        .write_stdin("y\n\n1\n2\n1\n0\n1\n1\ny\n")
        .assert()
        .success()
        .stdout(predicate::str::contains("Review worker models"))
        .stdout(predicate::str::contains("Friendly fixture"));
    let saved = fs::read_to_string(f.saved()).unwrap();
    let parsed = parse_config(&saved).unwrap();
    assert_eq!(
        parsed.engines["codex"]
            .fast
            .as_ref()
            .unwrap()
            .effort
            .as_deref(),
        Some("high")
    );
    assert_eq!(
        parsed.engines["codex"].balanced.as_ref().unwrap().effort,
        None
    );
    assert!(f.dir.path().join(".squad/worker-model-cache.json").exists());
    f.command()
        .args(["config", "workers"])
        .write_stdin("y\n\n-\n-\nq\n")
        .assert()
        .success();
    assert_eq!(fs::read_to_string(f.saved()).unwrap(), saved);
    f.command()
        .args(["config", "workers"])
        .write_stdin("n\n")
        .assert()
        .success()
        .stdout(predicate::str::contains("No changes"));
    assert_eq!(fs::read_to_string(f.saved()).unwrap(), saved);
    f.command()
        .arg("init")
        .assert()
        .success()
        .stdout(predicate::str::contains(
            "change with `squad config workers`",
        ));
    assert_eq!(fs::read_to_string(f.saved()).unwrap(), saved);
    fs::write(f.saved(), "invalid JSON").unwrap();
    f.command()
        .args(["config", "workers"])
        .write_stdin("y\n")
        .assert()
        .failure();
    assert_eq!(fs::read_to_string(f.saved()).unwrap(), "invalid JSON");
}

#[test]
#[cfg(unix)]
fn discovery_failure_retry_timeout_cache_and_noninteractive_init_are_safe() {
    let f = Fixture::new();
    f.cli("codex", "#!/bin/sh\nprintf called > discovery-called\nprintf '{\"models\":[{\"slug\":\"fixture-model\",\"display_name\":\"Friendly Codex\",\"visibility\":\"list\",\"supported_reasoning_levels\":[{\"effort\":\"high\"}]}]}'\n");
    f.command()
        .arg("init")
        .assert()
        .success()
        .stdout(predicate::str::contains("squad config workers"));
    assert!(!f.saved().exists());
    assert!(!f.dir.path().join("discovery-called").exists());
    f.command()
        .args(["config", "workers"])
        .write_stdin("y\n\n1\n1\n-\n-\ny\n")
        .assert()
        .success()
        .stdout(predicate::str::contains("refresh not confirmed"));
    let saved = fs::read_to_string(f.saved()).unwrap();
    f.cli("codex", "#!/bin/sh\nexit 1\n");
    fs::write(f.dir.path().join("home/.codex/models_cache.json"), r#"{"fetched_at":"2020-01-01T00:00:00Z","models":[{"slug":"cached-fixture","display_name":"Cached fixture","visibility":"list"}]}"#).unwrap();
    f.command()
        .args(["config", "workers"])
        .write_stdin("y\nr\nc\n\n-\n1\n-\ny\n")
        .assert()
        .success()
        .stdout(predicate::str::contains("stale"))
        .stdout(predicate::str::contains("Codex CLI cache"));
    assert_ne!(fs::read_to_string(f.saved()).unwrap(), saved);
    f.cli("codex", "#!/bin/sh\nexec /bin/sleep 10\n");
    let started = std::time::Instant::now();
    f.command()
        .args(["config", "workers", "--timeout", "1"])
        .write_stdin("y\nq\n")
        .assert()
        .success()
        .stdout(predicate::str::contains("timed out"));
    assert!(started.elapsed().as_secs() < 5);
    f.cli("codex", "#!/bin/sh\nprintf 'invalid JSON'\n");
    fs::write(
        f.dir.path().join("home/.codex/models_cache.json"),
        "invalid JSON",
    )
    .unwrap();
    f.command()
        .args(["config", "workers"])
        .write_stdin("y\ns\n")
        .assert()
        .success()
        .stdout(predicate::str::contains("No cached list"));
}

#[test]
#[cfg(unix)]
fn codex_refresh_requires_timestamp_advancement_and_can_be_refreshed_again() {
    let f = Fixture::new();
    let mut catalog = serde_json::json!({
        "fetched_at": chrono::Utc::now().to_rfc3339(),
        "models":[{"slug":"fixture","display_name":"Friendly fixture","visibility":"list"}]
    });
    let cache = f.dir.path().join("home/.codex/models_cache.json");
    fs::write(&cache, catalog.to_string()).unwrap();
    f.cli("codex", &format!("#!/bin/sh\nprintf '%s' '{}'\n", catalog));
    f.command()
        .args(["config", "workers"])
        .write_stdin("y\nr\nq\n")
        .assert()
        .success()
        .stdout(predicate::str::contains("refresh not confirmed").count(2));
    catalog["fetched_at"] =
        serde_json::json!((chrono::Utc::now() - chrono::Duration::seconds(10)).to_rfc3339());
    fs::write(&cache, catalog.to_string()).unwrap();
    catalog["fetched_at"] = serde_json::json!(chrono::Utc::now().to_rfc3339());
    f.cli(
        "codex",
        &format!(
            "#!/bin/sh\nprintf '%s' '{}' > \"$CODEX_HOME/models_cache.json\"\nprintf '%s' '{}'\n",
            catalog, catalog
        ),
    );
    f.command()
        .args(["config", "workers"])
        .write_stdin("y\nq\n")
        .assert()
        .success()
        .stdout(predicate::str::contains("live: codex debug models"));
}

#[test]
#[cfg(unix)]
fn global_setup_works_without_workspace_and_preserves_on_cancel() {
    let f = Fixture::new();
    fs::remove_dir(f.dir.path().join(".squad")).unwrap();
    f.cli("codex", FIXTURE_CODEX);
    let saved = f.dir.path().join("home/.squad/worker-models.json");
    f.command()
        .args(["config", "workers", "--global", "--timeout", "2"])
        .write_stdin("y\n\n1\n2\n1\n0\n1\n1\ny\n")
        .assert()
        .success();
    let original = fs::read_to_string(&saved).unwrap();
    assert!(f
        .dir
        .path()
        .join("home/.squad/worker-model-cache.json")
        .exists());
    f.command()
        .args(["config", "workers", "--global"])
        .write_stdin("q\n")
        .assert()
        .success()
        .stdout(predicate::str::contains("Cancelled"));
    assert_eq!(fs::read_to_string(&saved).unwrap(), original);
    f.command()
        .arg("init")
        .assert()
        .success()
        .stdout(predicate::str::contains("global"));
    f.command()
        .args(["config", "workers", "--global"])
        .env("HOME", "")
        .assert()
        .failure();
    f.command()
        .args(["config", "workers", "--global"])
        .env_remove("HOME")
        .assert()
        .failure();
}

#[test]
#[cfg(unix)]
fn noninteractive_config_requires_confirmation_and_merges_validated_tiers() {
    let f = Fixture::new();
    let set = [
        "config",
        "workers",
        "set",
        "--engine",
        "codex",
        "--tier",
        "fast",
        "--model",
        "fixture-fast",
    ];
    f.command()
        .args(set)
        .assert()
        .failure()
        .stderr(predicate::str::contains("human confirmation"));
    assert!(!f.saved().exists());
    f.command().args(set).arg("--yes").assert().success();
    let original = fs::read_to_string(f.saved()).unwrap();
    for flags in [
        vec!["--engine", "unknown"],
        vec!["--model", "bad value"],
        vec!["--engine", "claude", "--effort", "high"],
        vec!["--tier", "invalid"],
        vec!["--name", "bad\nname"],
        vec!["--source", "bad\nsource"],
    ] {
        f.command()
            .args(set)
            .arg("--yes")
            .args(flags)
            .assert()
            .failure();
        assert_eq!(fs::read_to_string(f.saved()).unwrap(), original);
    }
    let payload = r#"{"version":1,"engines":{"codex":{"strong":{"model":"fixture-strong","effort":"high"}},"claude":{"fast":{"model":"haiku"},"fetched_at":"2020-01-01T00:00:00Z"}}}"#;
    f.command()
        .args(["config", "workers", "apply", "--from-json", "-"])
        .write_stdin(payload)
        .assert()
        .failure();
    f.command()
        .args(["config", "workers", "apply", "--from-json", "-", "--yes"])
        .write_stdin(payload)
        .assert()
        .success();
    let config = parse_config(&fs::read_to_string(f.saved()).unwrap()).unwrap();
    assert_eq!(
        config.engines["codex"].fast.as_ref().unwrap().model,
        "fixture-fast"
    );
    assert!(config.engines["codex"].fetched_at.is_some());
    let output = f
        .command()
        .args(["config", "workers", "list", "--json"])
        .output()
        .unwrap();
    assert!(output.status.success());
    let list: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(list["engines"]["claude"]["stale"], true);
    assert_eq!(list["engines"]["codex"]["stale"], false);
    assert_eq!(list["engines"].as_object().unwrap().len(), 4);
    f.command()
        .args(set)
        .args(["--yes", "--global"])
        .assert()
        .success();
    assert!(f.dir.path().join("home/.squad/worker-models.json").exists());
    f.command()
        .args(["config", "workers", "list", "--json", "--global"])
        .assert()
        .success()
        .stdout(predicate::str::contains("fixture-fast"));
    assert!(fs::read_dir(f.saved().parent().unwrap())
        .unwrap()
        .all(|entry| !entry
            .unwrap()
            .file_name()
            .to_string_lossy()
            .contains("tmp-")));
}

#[test]
#[cfg(unix)]
fn config_atomic_save_preserves_old_file_on_failure_and_creates_directory() {
    use squad::worker_config::{save_config, WorkerConfig};
    let dir = TempDir::new().unwrap();
    save_config(dir.path(), &WorkerConfig::default()).unwrap();
    let path = dir.path().join(".squad/worker-models.json");
    let old = fs::read_to_string(&path).unwrap();
    let tmp = path.with_extension(format!("tmp-{}", std::process::id()));
    fs::write(&tmp, "existing temporary file").unwrap();
    let config =
        parse_config(r#"{"version":1,"engines":{"codex":{"fast":{"model":"new"}}}}"#).unwrap();
    assert!(save_config(dir.path(), &config).is_err());
    assert_eq!(fs::read_to_string(&path).unwrap(), old);
    assert_eq!(fs::read_to_string(&tmp).unwrap(), "existing temporary file");
    fs::remove_file(tmp).unwrap();
    // An open reader retains the complete old file across the atomic replacement.
    let mut reader = fs::File::open(&path).unwrap();
    save_config(dir.path(), &config).unwrap();
    let mut previous = String::new();
    std::io::Read::read_to_string(&mut reader, &mut previous).unwrap();
    assert_eq!(previous, old);
    assert_eq!(
        parse_config(&fs::read_to_string(path).unwrap()).unwrap(),
        config
    );
}

#[test]
#[cfg(unix)]
fn list_uses_offline_cache_and_apply_rejects_invalid_payloads_without_writing() {
    let f = Fixture::new();
    f.cli("codex", "#!/bin/sh\nexit 1\n");
    fs::write(f.dir.path().join("home/.codex/models_cache.json"), r#"{"fetched_at":"2020-01-01T00:00:00Z","models":[{"slug":"offline-model","visibility":"list"}]}"#).unwrap();
    f.command()
        .args(["config", "workers", "list", "--json"])
        .assert()
        .success()
        .stdout(predicate::str::contains("offline-model"));
    assert!(!f.saved().exists());
    for payload in [
        r#"{"version":1,"engines":{"codex":{"typo":{"model":"valid"}}}}"#,
        r#"{"version":1,"engines":{"unknown":{}}}"#,
        r#"{"version":1,"engines":{"claude":{"fast":{"model":"valid","effort":"high"}}}}"#,
        r#"{"version":1,"engines":{"codex":{"fast":{"model":"-bad"}}}}"#,
    ] {
        f.command()
            .args(["config", "workers", "apply", "--from-json", "-", "--yes"])
            .write_stdin(payload)
            .assert()
            .failure();
        assert!(!f.saved().exists());
    }
    let payload = f.dir.path().join("models.json");
    fs::write(
        &payload,
        r#"{"version":1,"engines":{"grok":{"balanced":{"model":"fixture"}}}}"#,
    )
    .unwrap();
    f.command()
        .args(["config", "workers", "apply", "--yes", "--from-json"])
        .arg(payload)
        .assert()
        .success();
    assert_eq!(
        parse_config(&fs::read_to_string(f.saved()).unwrap())
            .unwrap()
            .engines["grok"]
            .balanced
            .as_ref()
            .unwrap()
            .model,
        "fixture"
    );
}

#[test]
#[cfg(unix)]
fn option_values_do_not_change_config_scope() {
    let f = Fixture::new();
    f.command()
        .args([
            "config", "workers", "set", "--engine", "codex", "--tier", "fast", "--model",
            "fixture", "--source", "--global", "--yes",
        ])
        .assert()
        .success();
    assert!(f.saved().exists());
    assert!(!f.dir.path().join("home/.squad/worker-models.json").exists());
}
