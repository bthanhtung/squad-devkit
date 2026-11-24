use squad::{dag::parse_plan, store::Store};

#[test]
fn grammar_cycles_and_verify() {
    let good = "## Tasks\n- a (codex strong, dev): first. Files: a. Depends on: none. Verify: `true`\n- b (codex fast, reviewer): second. Depends on: a.\n";
    let tasks = parse_plan(good).unwrap();
    assert_eq!(tasks[0].verify.as_deref(), Some("true"));
    assert_eq!(tasks[1].dependencies, vec!["a"]);
    for bad in [
        good.replace("none", "b"),
        good.replace("strong", "bogus"),
        good.replace("`true`", "true"),
        good.replace("Depends on: a", "Depends on: missing"),
        good.replace("- b", "- a"),
    ] {
        assert!(parse_plan(&bad).is_err(), "{bad}");
    }
}

#[test]
fn lease_expiry_and_owner_fencing() {
    let tmp = tempfile::tempdir().unwrap();
    let first = Store::open(&tmp.path().join("db")).unwrap();
    let second = Store::open(&tmp.path().join("db")).unwrap();
    assert!(first.claim_dag("plan", "one", 100, 30).unwrap());
    assert!(!second.claim_dag("plan", "two", 110, 30).unwrap());
    assert!(second.claim_dag("plan", "two", 131, 30).unwrap());
    assert!(!first.heartbeat_dag("plan", "one", 132, 30).unwrap());
    first.release_dag("plan", "one").unwrap();
    assert!(!first.claim_dag("plan", "three", 133, 30).unwrap());
    assert!(second.heartbeat_dag("plan", "two", 140, 30).unwrap());
}

use std::{
    fs,
    path::PathBuf,
    process::{Command, Output},
};

struct Fixture {
    tmp: tempfile::TempDir,
    root: PathBuf,
}
impl Fixture {
    fn new(tasks: &str) -> Self {
        let tmp = tempfile::tempdir().unwrap();
        let root = fs::canonicalize(tmp.path()).unwrap();
        fs::create_dir_all(root.join(".squad/workers")).unwrap();
        fs::write(root.join("plan.md"), format!("## Tasks\n{tasks}")).unwrap();
        fs::write(root.join("worker"), r#"#!/usr/bin/env bash
set -eu
id="$1"; shift
plan=
while (( $# )); do
  case "$1" in --plan) plan="$2";; esac
  shift
done
hash="$("$SQUAD_BIN" plan task-entry "$plan" "$id" | shasum -a 256 | awk '{print $1}')"
echo "$id start" >>calls
case "$id" in a) sleep 0.1;; slow) sleep 1.5;; esac
state=completed
if [[ "${FAIL_TASK:-}" == "$id" ]]; then state=failed; fi
if [[ "${PUBLISH:-}" == "$id" ]]; then
  echo payload >payload.txt
  "$SQUAD_BIN" artifact publish --root "$PWD" payload.txt
  sleep 1
fi
printf 'worker=%s\nengine=codex\nplan=%s\nplan_task=%s\nplan_task_sha256=%s\nstate=%s\nverify=pass\nmerged=yes\ndag_attempt=%s\n' "$id" "$plan" "$id" "$hash" "$state" "$SQUAD_DAG_ATTEMPT" >".squad/workers/$id.status"
echo "$id end" >>calls
"#).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(root.join("worker"), fs::Permissions::from_mode(0o755)).unwrap();
        }
        Self { tmp, root }
    }
    fn command(&self) -> Command {
        let mut cmd = Command::new(env!("CARGO_BIN_EXE_squad"));
        cmd.current_dir(&self.root)
            .env("SQUAD_DEVKIT_WORKSPACE", &self.root)
            .env("SQUAD_DAG_LAUNCHER", self.root.join("worker"))
            .env("SQUAD_BIN", env!("CARGO_BIN_EXE_squad"));
        cmd
    }
    fn run(&self, extra: &[&str]) -> Output {
        self.command()
            .args(["run-plan", "plan.md", "--manager", "mgr"])
            .args(extra)
            .output()
            .unwrap()
    }
    fn calls(&self) -> String {
        fs::read_to_string(self.root.join("calls")).unwrap_or_default()
    }
}
fn task(id: &str, dep: &str) -> String {
    format!("- {id} (codex strong, dev): work. Files: {id}. Depends on: {dep}. Verify: `true`\n")
}
fn code(output: &Output, expected: i32) {
    assert_eq!(
        output.status.code(),
        Some(expected),
        "stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
}

#[test]
fn dependents_unblock_before_slow_peer_finishes() {
    let f = Fixture::new(&(task("a", "none") + &task("slow", "none") + &task("b", "a")));
    code(&f.run(&["--jobs", "2"]), 0);
    let calls = f.calls();
    assert!(
        calls.find("b start").unwrap() < calls.find("slow end").unwrap(),
        "{calls}"
    );
}

#[test]
fn failure_isolation_and_fail_fast() {
    for (policy, independent_runs) in [("stop-dependents", true), ("fail-fast", false)] {
        let f = Fixture::new(&(task("a", "none") + &task("b", "a") + &task("c", "none")));
        let output = f
            .command()
            .env("FAIL_TASK", "a")
            .args([
                "run-plan",
                "plan.md",
                "--manager",
                "mgr",
                "--jobs",
                "1",
                "--on-failure",
                policy,
            ])
            .output()
            .unwrap();
        code(&output, 3);
        let calls = f.calls();
        assert!(!calls.contains("b start"));
        assert_eq!(calls.contains("c start"), independent_runs);
    }
}

#[test]
fn hash_retry_and_launch_cap() {
    let f = Fixture::new(&(task("a", "none") + &task("b", "a")));
    code(&f.run(&["--max-launches", "1"]), 3);
    assert!(!f.calls().contains("b start"));
    code(&f.run(&[]), 0);
    fs::write(
        f.root.join("plan.md"),
        format!(
            "## Tasks\n{}{}",
            task("a", "none").replace("work", "changed"),
            task("b", "a")
        ),
    )
    .unwrap();
    let output = f.run(&[]);
    code(&output, 3);
    assert!(String::from_utf8_lossy(&output.stdout).contains("changed since its run"));
    code(&f.run(&["--retry", "a"]), 0);
    assert_eq!(f.calls().matches("a start").count(), 2);
    code(&f.run(&["--retry", "unknown"]), 2);
}

#[test]
fn artifact_copy_validation_and_retention() {
    use squad::dag::{fetch_artifact, publish_artifact};
    let f = Fixture::new(&task("a", "none"));
    let source = f.root.join("producer");
    fs::create_dir(&source).unwrap();
    fs::write(source.join("payload"), "typed payload").unwrap();
    let plan = f.root.join("plan.md");
    publish_artifact(
        &f.root,
        &plan,
        "a",
        "attempt-1",
        &source,
        &["payload".into()],
    )
    .unwrap();
    assert!(publish_artifact(
        &f.root,
        &plan,
        "a",
        "attempt-1",
        &source,
        &["payload".into()]
    )
    .is_err());
    for path in ["../payload", "/etc/passwd", "x/../../payload"] {
        assert!(publish_artifact(&f.root, &plan, "a", "bad", &source, &[path.into()]).is_err());
    }
    #[cfg(unix)]
    {
        std::os::unix::fs::symlink("/etc/passwd", source.join("escape")).unwrap();
        assert!(
            publish_artifact(&f.root, &plan, "a", "bad-link", &source, &["escape".into()]).is_err()
        );
    }
    fs::remove_dir_all(&source).unwrap();
    let dest = f.root.join("consumer/input");
    fs::create_dir_all(&dest).unwrap();
    fetch_artifact(&f.root, &plan, "a", &dest).unwrap();
    assert_eq!(
        fs::read_to_string(dest.join("payload")).unwrap(),
        "typed payload"
    );
    assert!(fs::metadata(dest.join("payload"))
        .unwrap()
        .permissions()
        .readonly());
    assert!(fs::metadata(&dest).unwrap().permissions().readonly());
    assert!(fetch_artifact(&f.root, &plan, "a", &dest).is_err());
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&dest, fs::Permissions::from_mode(0o755)).unwrap();
    }
    // Keep TempDir alive until all filesystem assertions finish.
    assert!(f.tmp.path().exists());
}

#[test]
fn artifact_ready_unblocks_during_producer_execution() {
    let f = Fixture::new(&(task("a", "none") + &task("b", "a")));
    let output = f
        .command()
        .env("PUBLISH", "a")
        .args([
            "run-plan",
            "plan.md",
            "--manager",
            "mgr",
            "--jobs",
            "2",
            "--dep-mode",
            "artifact-ready",
        ])
        .output()
        .unwrap();
    code(&output, 0);
    let calls = f.calls();
    assert!(
        calls.find("b start").unwrap() < calls.find("a end").unwrap(),
        "{calls}"
    );
}

#[test]
fn expired_scheduler_recovers_nodes_without_implicit_relaunch() {
    let f = Fixture::new(&task("a", "none"));
    let db = f.root.join(".squad/messages.db");
    let store = Store::open(&db).unwrap();
    let plan = f.root.join("plan.md");
    let plan = plan.to_str().unwrap();
    assert!(store.claim_dag(plan, "crashed-host", 1, 30).unwrap());
    let hash = parse_plan(&fs::read_to_string(plan).unwrap())
        .unwrap()
        .remove(0)
        .hash;
    let conn = rusqlite::Connection::open(&db).unwrap();
    conn.execute(
        "INSERT INTO dag_nodes VALUES (?1,'a',?2,'old-attempt','running','crashed-host',31)",
        rusqlite::params![plan, hash],
    )
    .unwrap();
    code(&f.run(&["--dry-run"]), 3);
    assert!(f.calls().is_empty());
    let state: String = conn
        .query_row("SELECT state FROM dag_nodes", [], |r| r.get(0))
        .unwrap();
    assert_eq!(state, "lost");
    code(&f.run(&["--retry", "a"]), 0);
    assert_eq!(f.calls().matches("a start").count(), 1);
}

#[test]
fn artifact_manifest_traversal_tampering_and_stale_attempt_are_rejected() {
    use squad::dag::{fetch_artifact, publish_artifact};
    let f = Fixture::new(&task("a", "none"));
    fs::write(f.root.join("payload"), "original").unwrap();
    let plan = f.root.join("plan.md");
    publish_artifact(&f.root, &plan, "a", "manual", &f.root, &["payload".into()]).unwrap();
    let hash_dir = fs::read_dir(f.root.join(".squad/artifacts"))
        .unwrap()
        .next()
        .unwrap()
        .unwrap()
        .path();
    let manifest_path = hash_dir.join("a/manifest.json");
    let original = fs::read(&manifest_path).unwrap();
    let mut manifest: serde_json::Value = serde_json::from_slice(&original).unwrap();
    manifest["files"][0]["path"] = "../escape".into();
    fs::write(&manifest_path, serde_json::to_vec(&manifest).unwrap()).unwrap();
    assert!(fetch_artifact(&f.root, &plan, "a", &f.root.join("bad")).is_err());
    fs::write(&manifest_path, &original).unwrap();
    manifest = serde_json::from_slice(&original).unwrap();
    manifest["files"][0]["sha256"] = "0".repeat(64).into();
    fs::write(&manifest_path, serde_json::to_vec(&manifest).unwrap()).unwrap();
    assert!(fetch_artifact(&f.root, &plan, "a", &f.root.join("tampered")).is_err());
    fs::write(&manifest_path, original).unwrap();
    // A new scheduler attempt makes an old retained manifest ineligible for delivery.
    code(&f.run(&[]), 0);
    assert!(fetch_artifact(&f.root, &plan, "a", &f.root.join("stale")).is_err());
    assert!(!f.root.join("stale").exists());
}

#[test]
fn live_scheduler_lease_excludes_other_hosts() {
    let f = Fixture::new(&task("a", "none"));
    let store = Store::open(&f.root.join(".squad/messages.db")).unwrap();
    let plan = f.root.join("plan.md");
    assert!(store
        .claim_dag(
            plan.to_str().unwrap(),
            "other-host",
            chrono::Utc::now().timestamp(),
            30
        )
        .unwrap());
    let output = f.run(&[]);
    code(&output, 3);
    assert!(String::from_utf8_lossy(&output.stderr).contains("Another runner"));
    assert!(f.calls().is_empty());
}

#[test]
fn default_mode_waits_for_merge_even_when_artifact_is_ready() {
    let f = Fixture::new(&(task("a", "none") + &task("b", "a")));
    let output = f
        .command()
        .env("PUBLISH", "a")
        .args(["run-plan", "plan.md", "--manager", "mgr", "--jobs", "2"])
        .output()
        .unwrap();
    code(&output, 0);
    let calls = f.calls();
    assert!(
        calls.find("a end").unwrap() < calls.find("b start").unwrap(),
        "{calls}"
    );
}

#[test]
fn successful_exit_without_current_attempt_record_cannot_reuse_old_success() {
    let f = Fixture::new(&task("a", "none"));
    code(&f.run(&[]), 0);
    fs::write(f.root.join("worker"), "#!/usr/bin/env bash\nexit 0\n").unwrap();
    code(&f.run(&["--retry", "a"]), 3);
    code(&f.run(&[]), 3);
}

#[test]
fn externally_running_workers_count_toward_job_limit() {
    let f = Fixture::new(&(task("a", "none") + &task("b", "none")));
    let plan = f.root.join("plan.md");
    let hash = parse_plan(&fs::read_to_string(&plan).unwrap())
        .unwrap()
        .remove(0)
        .hash;
    fs::write(f.root.join(".squad/workers/a.status"), format!("worker=a\nengine=codex\nstate=running\nplan={}\nplan_task=a\nplan_task_sha256={hash}\n", plan.display())).unwrap();
    code(&f.run(&["--jobs", "1"]), 3);
    assert!(f.calls().is_empty());
    code(&f.run(&["--jobs", "2"]), 3);
    assert!(f.calls().contains("b start"));
}
