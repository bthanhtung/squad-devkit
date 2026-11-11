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
