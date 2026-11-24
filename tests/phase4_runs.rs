use assert_cmd::Command;
use std::fs;
#[test]
fn status_upsert_preserves_unknown_telemetry_and_old_database() {
    let dir = tempfile::tempdir().unwrap();
    fs::create_dir_all(dir.path().join(".squad/workers")).unwrap();
    let db = dir.path().join(".squad/messages.db");
    let conn = rusqlite::Connection::open(&db).unwrap();
    conn.execute_batch("CREATE TABLE keep_me (value TEXT); INSERT INTO keep_me VALUES ('old');")
        .unwrap();
    let status = dir.path().join(".squad/workers/run.status");
    fs::write(
        &status,
        "worker=dev\nengine=codex\nstate=running\ntokens_in=\n",
    )
    .unwrap();
    for state in ["running", "completed"] {
        fs::write(
            &status,
            format!("worker=dev\nengine=codex\nstate={state}\ntokens_in=\n"),
        )
        .unwrap();
        Command::cargo_bin("squad")
            .unwrap()
            .args(["run", "record", "--workspace"])
            .arg(dir.path())
            .arg("--status-file")
            .arg(&status)
            .assert()
            .success();
    }
    let output = Command::cargo_bin("squad")
        .unwrap()
        .current_dir(dir.path())
        .args(["run", "list", "--json", "--workspace"])
        .arg(dir.path())
        .output()
        .unwrap();
    assert!(output.status.success());
    let rows: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(rows.as_array().unwrap().len(), 1);
    assert_eq!(rows[0]["state"], "completed");
    assert!(rows[0]["tokens_in"].is_null());
    assert_eq!(
        conn.query_row("SELECT value FROM keep_me", [], |r| r.get::<_, String>(0))
            .unwrap(),
        "old"
    );
}

#[test]
fn concurrent_records_and_invalid_input() {
    let dir = tempfile::tempdir().unwrap();
    fs::create_dir_all(dir.path().join(".squad/workers")).unwrap();
    let status = dir.path().join(".squad/workers/run.status");
    fs::write(
        &status,
        "worker=dev'; DROP TABLE worker_runs; --\nengine=codex\nstate=failed\ntokens_in=0\n",
    )
    .unwrap();
    let binary = assert_cmd::cargo::cargo_bin("squad");
    let children: Vec<_> = (0..4)
        .map(|_| {
            std::process::Command::new(&binary)
                .current_dir(dir.path())
                .args(["run", "record", "--workspace"])
                .arg(dir.path())
                .arg("--status-file")
                .arg(&status)
                .spawn()
                .unwrap()
        })
        .collect();
    let statuses: Vec<_> = children
        .into_iter()
        .map(|mut child| child.wait().unwrap())
        .collect();
    assert!(statuses.iter().all(std::process::ExitStatus::success));
    let conn = rusqlite::Connection::open(dir.path().join(".squad/messages.db")).unwrap();
    assert_eq!(
        conn.query_row("SELECT count(*) FROM worker_runs", [], |r| r
            .get::<_, i64>(0))
            .unwrap(),
        1
    );
    fs::write(
        &status,
        "worker=dev\nengine=codex\nstate=completed\ntokens_in=-1\n",
    )
    .unwrap();
    Command::cargo_bin("squad")
        .unwrap()
        .current_dir(dir.path())
        .args(["run", "record", "--workspace"])
        .arg(dir.path())
        .arg("--status-file")
        .arg(&status)
        .assert()
        .failure();
    assert_eq!(
        conn.query_row("SELECT state FROM worker_runs", [], |r| r
            .get::<_, String>(0))
            .unwrap(),
        "failed"
    );
    Command::cargo_bin("squad")
        .unwrap()
        .current_dir(dir.path())
        .args(["run", "list", "--json", "--wat"])
        .assert()
        .failure();
}

#[test]
fn write_preserves_entries_and_rejects_stale_projection() {
    let dir = tempfile::tempdir().unwrap();
    let workers = dir.path().join(".squad/workers");
    fs::create_dir_all(&workers).unwrap();
    let status = workers.join("run.status");
    let input = "worker=dev\nengine=codex\nstate=completed\ngate_command_hex=61\ngate_command_hex=62\nexpect_path=a\nexpect_path=b\n";
    Command::cargo_bin("squad")
        .unwrap()
        .args(["run", "write", "--workspace"])
        .arg(dir.path())
        .arg("--status-file")
        .arg(&status)
        .write_stdin(input)
        .assert()
        .success();
    assert_eq!(fs::read_to_string(&status).unwrap(), input);
    let conn = rusqlite::Connection::open(dir.path().join(".squad/messages.db")).unwrap();
    let entries: String = conn
        .query_row("SELECT entries_json FROM worker_runs", [], |r| r.get(0))
        .unwrap();
    let entries: Vec<(String, String)> = serde_json::from_str(&entries).unwrap();
    assert_eq!(
        entries
            .iter()
            .filter(|(k, _)| k == "gate_command_hex")
            .count(),
        2
    );
    assert_eq!(
        entries.iter().filter(|(k, _)| k == "expect_path").count(),
        2
    );
    fs::write(&status, "worker=stale\nengine=codex\nstate=running\n").unwrap();
    Command::cargo_bin("squad")
        .unwrap()
        .args(["run", "record", "--workspace"])
        .arg(dir.path())
        .arg("--status-file")
        .arg(&status)
        .assert()
        .success();
    assert_eq!(
        conn.query_row("SELECT state FROM worker_runs", [], |r| r
            .get::<_, String>(0))
            .unwrap(),
        "completed"
    );
    Command::cargo_bin("squad")
        .unwrap()
        .args(["run", "list", "--json", "--workspace"])
        .arg(dir.path())
        .arg("--directory")
        .arg(&workers)
        .assert()
        .success()
        .stdout(predicates::str::contains("\"state\":\"completed\""));
    assert_eq!(fs::read_dir(&workers).unwrap().count(), 1);
    for invalid in [
        "state=bogus",
        "pid=-1",
        "tokens_in=no",
        "started=-1",
        "tokens_reasoning=-2",
    ] {
        Command::cargo_bin("squad")
            .unwrap()
            .args(["run", "write", "--workspace"])
            .arg(dir.path())
            .arg("--status-file")
            .arg(&status)
            .write_stdin(format!(
                "worker=dev\nengine=codex\nstate=completed\n{invalid}\n"
            ))
            .assert()
            .failure();
    }
}

#[test]
fn projection_failure_keeps_sqlite_and_cleans_temporary_file() {
    let dir = tempfile::tempdir().unwrap();
    let workers = dir.path().join(".squad/workers");
    let status = workers.join("run.status");
    fs::create_dir_all(&status).unwrap();
    Command::cargo_bin("squad")
        .unwrap()
        .args(["run", "write", "--workspace"])
        .arg(dir.path())
        .arg("--status-file")
        .arg(&status)
        .write_stdin("worker=dev\nengine=codex\nstate=completed\n")
        .assert()
        .failure()
        .stderr(predicates::str::contains(
            "SQLite saved; status projection failed",
        ));
    assert_eq!(fs::read_dir(&workers).unwrap().count(), 1);
    Command::cargo_bin("squad")
        .unwrap()
        .args(["run", "list", "--json", "--workspace"])
        .arg(dir.path())
        .assert()
        .success()
        .stdout(predicates::str::contains("\"state\":\"completed\""));
}

#[test]
fn legacy_run_keeps_syncing_after_another_run_becomes_authoritative() {
    let dir = tempfile::tempdir().unwrap();
    let workers = dir.path().join(".squad/workers");
    fs::create_dir_all(&workers).unwrap();
    let legacy = workers.join("legacy.status");
    fs::write(&legacy, "worker=dev\nengine=codex\nstate=running\n").unwrap();
    Command::cargo_bin("squad")
        .unwrap()
        .args(["run", "list", "--json", "--workspace"])
        .arg(dir.path())
        .arg("--directory")
        .arg(&workers)
        .assert()
        .success()
        .stdout(predicates::str::contains("\"state\":\"running\""));
    Command::cargo_bin("squad")
        .unwrap()
        .args(["run", "write", "--workspace"])
        .arg(dir.path())
        .arg("--status-file")
        .arg(workers.join("other.status"))
        .write_stdin("worker=other\nengine=codex\nstate=completed\n")
        .assert()
        .success();
    fs::write(&legacy, "worker=dev\nengine=codex\nstate=completed\n").unwrap();
    let output = Command::cargo_bin("squad")
        .unwrap()
        .args(["run", "list", "--json", "--workspace"])
        .arg(dir.path())
        .arg("--directory")
        .arg(&workers)
        .output()
        .unwrap();
    assert!(output.status.success());
    let rows: Vec<serde_json::Value> = serde_json::from_slice(&output.stdout).unwrap();
    let run = rows.iter().find(|row| row["run_name"] == "legacy").unwrap();
    assert_eq!(run["state"], "completed");
}
