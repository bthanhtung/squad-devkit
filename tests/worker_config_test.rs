#[cfg(unix)]
use assert_cmd::Command;
#[cfg(unix)]
use predicates::prelude::*;
use squad::worker_config::{parse_agy_models, parse_codex_models, parse_config};
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
    assert!(parse_config(r#"{"version":2,"engines":{}}"#).is_err());
    assert!(parse_config(r#"{"version":1,"engines":{"ccr":{}}}"#).is_err());
    assert!(parse_agy_models("broken output").is_err());
    let models = parse_agy_models("fixture-id\tFriendly fixture\nfixture-id\tDuplicate\n").unwrap();
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
    f.cli("agy", "#!/bin/sh\ncase \"$1\" in\nmodels) printf 'fixture-id\\tFriendly fixture\\n';;\n--help) echo '--effort (low|high)' >&2;;\nesac\n");
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
        parsed.engines["agy"]
            .fast
            .as_ref()
            .unwrap()
            .effort
            .as_deref(),
        Some("high")
    );
    assert_eq!(
        parsed.engines["agy"].balanced.as_ref().unwrap().effort,
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
    f.cli("agy", "#!/bin/sh\ncase \"$1\" in\nmodels) printf 'fixture-id\\tFriendly fixture\\n';;\n--help) echo '--effort (low|high)' >&2;;\nesac\n");
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
