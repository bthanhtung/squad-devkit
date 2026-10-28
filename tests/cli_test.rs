use assert_cmd::Command;
use predicates::prelude::*;
use rusqlite::Connection;
use serde_json::Value;
use squad::setup::{command_content, current_version, PLATFORMS};
use std::time::{SystemTime, UNIX_EPOCH};
use tempfile::TempDir;

#[cfg(unix)]
fn make_executable(path: &std::path::Path) {
    use std::os::unix::fs::PermissionsExt;

    let mut permissions = std::fs::metadata(path).unwrap().permissions();
    permissions.set_mode(0o755);
    std::fs::set_permissions(path, permissions).unwrap();
}

fn create_fake_binary(dir: &std::path::Path, name: &str) {
    let path = dir.join(name);
    std::fs::write(&path, "#!/bin/sh\nexit 0\n").unwrap();
    #[cfg(unix)]
    make_executable(&path);
}

fn squad(workspace: &std::path::Path) -> Command {
    let mut cmd = Command::cargo_bin("squad").unwrap();
    cmd.current_dir(workspace);
    cmd
}

fn mark_agent_stale(workspace: &std::path::Path, agent_id: &str) {
    let db = workspace.join(".squad").join("messages.db");
    let conn = Connection::open(db).unwrap();
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64;
    conn.execute(
        "UPDATE agents SET last_seen = ?1 WHERE id = ?2",
        rusqlite::params![now - 601, agent_id],
    )
    .unwrap();
}

fn set_message_timestamp(workspace: &std::path::Path, content: &str, created_at: i64) {
    let db = workspace.join(".squad").join("messages.db");
    let conn = Connection::open(db).unwrap();
    conn.execute(
        "UPDATE messages SET created_at = ?1 WHERE content = ?2",
        rusqlite::params![created_at, content],
    )
    .unwrap();
}

fn first_task_id(workspace: &std::path::Path) -> String {
    let db = workspace.join(".squad").join("messages.db");
    let conn = Connection::open(db).unwrap();
    conn.query_row(
        "SELECT id FROM tasks ORDER BY created_at, id LIMIT 1",
        [],
        |row| row.get(0),
    )
    .unwrap()
}

fn message_id_by_content(workspace: &std::path::Path, content: &str) -> i64 {
    let db = workspace.join(".squad").join("messages.db");
    let conn = Connection::open(db).unwrap();
    conn.query_row(
        "SELECT id FROM messages WHERE content = ?1 ORDER BY created_at, id LIMIT 1",
        [content],
        |row| row.get(0),
    )
    .unwrap()
}

fn path_with_fake_binary(tmp: &TempDir, binary: &str) -> String {
    let bin_dir = tmp.path().join("bin");
    std::fs::create_dir_all(&bin_dir).unwrap();
    create_fake_binary(&bin_dir, binary);
    // The PATH separator is ':' on Unix and ';' on Windows.
    let mut paths = vec![bin_dir];
    if let Some(existing) = std::env::var_os("PATH") {
        paths.extend(std::env::split_paths(&existing));
    }
    std::env::join_paths(paths).unwrap().into_string().unwrap()
}

#[test]
fn test_init() {
    let tmp = TempDir::new().unwrap();
    squad(tmp.path())
        .arg("init")
        .assert()
        .success()
        .stdout(predicate::str::contains("Initialized"));
}

#[test]
fn test_init_refresh_roles_updates_builtin_files_only() {
    let tmp = TempDir::new().unwrap();
    squad(tmp.path()).arg("init").assert().success();

    let roles_dir = tmp.path().join(".squad").join("roles");
    std::fs::write(roles_dir.join("manager.md"), "stale manager").unwrap();
    std::fs::write(roles_dir.join("custom.md"), "keep custom").unwrap();

    squad(tmp.path())
        .args(["init", "--refresh-roles"])
        .assert()
        .success()
        .stdout(predicate::str::contains("Initialized"));

    assert_ne!(
        std::fs::read_to_string(roles_dir.join("manager.md")).unwrap(),
        "stale manager"
    );
    assert_eq!(
        std::fs::read_to_string(roles_dir.join("custom.md")).unwrap(),
        "keep custom"
    );
}

#[test]
fn test_join_and_agents() {
    let tmp = TempDir::new().unwrap();
    squad(tmp.path()).arg("init").assert().success();
    squad(tmp.path())
        .args(["join", "manager"])
        .assert()
        .success()
        .stdout(predicate::str::contains("Joined as manager"));
    squad(tmp.path())
        .arg("agents")
        .assert()
        .success()
        .stdout(predicate::str::contains("manager"));
}

#[test]
fn test_join_with_role_flag() {
    let tmp = TempDir::new().unwrap();
    squad(tmp.path()).arg("init").assert().success();
    squad(tmp.path())
        .args(["join", "worker-1", "--role", "worker"])
        .assert()
        .success()
        .stdout(predicate::str::contains("Joined as worker-1"));
}

#[test]
fn test_join_accepts_capability_metadata_flags() {
    let tmp = TempDir::new().unwrap();
    squad(tmp.path()).arg("init").assert().success();

    squad(tmp.path())
        .args([
            "join",
            "worker",
            "--role",
            "worker",
            "--client",
            "codex",
            "--protocol-version",
            "2",
        ])
        .assert()
        .success()
        .stdout(predicate::str::contains("Joined as worker"));

    let db = tmp.path().join(".squad").join("messages.db");
    let conn = Connection::open(db).unwrap();
    let row: (Option<String>, Option<i64>) = conn
        .query_row(
            "SELECT client_type, protocol_version FROM agents WHERE id = ?1",
            ["worker"],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap();
    assert_eq!(row.0.as_deref(), Some("codex"));
    assert_eq!(row.1, Some(2));
}

#[test]
fn test_join_rejects_role_flag_without_value() {
    let tmp = TempDir::new().unwrap();
    squad(tmp.path()).arg("init").assert().success();

    squad(tmp.path())
        .args(["join", "worker", "--role"])
        .assert()
        .failure()
        .stderr(predicate::str::contains("--role requires a value"));
}

#[test]
fn test_join_rejects_role_flag_followed_by_another_flag() {
    let tmp = TempDir::new().unwrap();
    squad(tmp.path()).arg("init").assert().success();

    squad(tmp.path())
        .args(["join", "worker", "--role", "--client", "codex"])
        .assert()
        .failure()
        .stderr(predicate::str::contains("--role requires a value"));
}

#[test]
fn test_join_rejects_client_flag_without_value() {
    let tmp = TempDir::new().unwrap();
    squad(tmp.path()).arg("init").assert().success();

    squad(tmp.path())
        .args(["join", "worker", "--client"])
        .assert()
        .failure()
        .stderr(predicate::str::contains("--client requires a value"));
}

#[test]
fn test_join_rejects_client_flag_followed_by_another_flag() {
    let tmp = TempDir::new().unwrap();
    squad(tmp.path()).arg("init").assert().success();

    squad(tmp.path())
        .args(["join", "worker", "--client", "--protocol-version", "2"])
        .assert()
        .failure()
        .stderr(predicate::str::contains("--client requires a value"));
}

#[test]
fn test_join_rejects_protocol_flag_without_value() {
    let tmp = TempDir::new().unwrap();
    squad(tmp.path()).arg("init").assert().success();

    squad(tmp.path())
        .args(["join", "worker", "--protocol-version"])
        .assert()
        .failure()
        .stderr(predicate::str::contains(
            "--protocol-version requires a value",
        ));
}

#[test]
fn test_join_rejects_protocol_flag_followed_by_another_flag() {
    let tmp = TempDir::new().unwrap();
    squad(tmp.path()).arg("init").assert().success();

    squad(tmp.path())
        .args(["join", "worker", "--protocol-version", "--client", "codex"])
        .assert()
        .failure()
        .stderr(predicate::str::contains(
            "--protocol-version requires a value",
        ));
}

#[test]
fn test_agents_json_exposes_effective_capability_fields_and_fallbacks() {
    let tmp = TempDir::new().unwrap();
    squad(tmp.path()).arg("init").assert().success();

    squad(tmp.path())
        .args(["join", "legacy", "--role", "worker"])
        .assert()
        .success();
    squad(tmp.path())
        .args([
            "join",
            "modern",
            "--role",
            "worker",
            "--client",
            "gemini",
            "--protocol-version",
            "2",
        ])
        .assert()
        .success();

    let output = squad(tmp.path())
        .args(["agents", "--json"])
        .assert()
        .success()
        .get_output()
        .stdout
        .clone();
    let entries: Vec<Value> = String::from_utf8(output)
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();

    let legacy = entries
        .iter()
        .find(|entry| entry["id"] == "legacy")
        .unwrap();
    assert_eq!(legacy["client_type_raw"], Value::Null);
    assert_eq!(legacy["protocol_version_raw"], Value::Null);
    assert_eq!(legacy["effective_client_type"], "unknown");
    assert_eq!(legacy["effective_protocol_version"], 1);
    assert_eq!(legacy["supports_task_commands"], false);
    assert_eq!(legacy["supports_json_receive"], false);

    let modern = entries
        .iter()
        .find(|entry| entry["id"] == "modern")
        .unwrap();
    assert_eq!(modern["client_type_raw"], "gemini");
    assert_eq!(modern["protocol_version_raw"], 2);
    assert_eq!(modern["effective_client_type"], "gemini");
    assert_eq!(modern["effective_protocol_version"], 2);
    assert_eq!(modern["supports_task_commands"], true);
    assert_eq!(modern["supports_json_receive"], true);
}

#[test]
fn test_agents_human_output_shows_capability_metadata_when_present() {
    let tmp = TempDir::new().unwrap();
    squad(tmp.path()).arg("init").assert().success();

    squad(tmp.path())
        .args(["join", "legacy", "--role", "worker"])
        .assert()
        .success();

    squad(tmp.path())
        .args([
            "join",
            "worker",
            "--role",
            "worker",
            "--client",
            "opencode",
            "--protocol-version",
            "2",
        ])
        .assert()
        .success();

    squad(tmp.path())
        .arg("agents")
        .assert()
        .success()
        .stdout(predicate::str::contains("client: unknown"))
        .stdout(predicate::str::contains("protocol: 1"))
        .stdout(predicate::str::contains("client: opencode"))
        .stdout(predicate::str::contains("protocol: 2"));
}

#[test]
fn test_send_and_receive() {
    let tmp = TempDir::new().unwrap();
    squad(tmp.path()).arg("init").assert().success();
    squad(tmp.path())
        .args(["join", "manager"])
        .assert()
        .success();
    squad(tmp.path())
        .args(["join", "worker"])
        .assert()
        .success();

    squad(tmp.path())
        .args(["send", "manager", "worker", "implement auth module"])
        .assert()
        .success();

    squad(tmp.path())
        .args(["receive", "worker"])
        .assert()
        .success()
        .stdout(predicate::str::contains("[from manager]"))
        .stdout(predicate::str::contains("implement auth module"))
        .stdout(predicate::str::contains(
            "After processing, run `squad receive worker --wait` to continue listening.",
        ));
}

#[test]
fn test_send_warns_when_recipient_is_stale() {
    let tmp = TempDir::new().unwrap();
    squad(tmp.path()).arg("init").assert().success();
    squad(tmp.path())
        .args(["join", "manager"])
        .assert()
        .success();
    squad(tmp.path())
        .args(["join", "worker"])
        .assert()
        .success();

    mark_agent_stale(tmp.path(), "worker");

    squad(tmp.path())
        .args(["send", "manager", "worker", "implement auth module"])
        .assert()
        .success()
        .stdout(predicate::str::contains("Sent to worker."))
        .stdout(predicate::str::contains(
            "Warning: worker is stale (last seen 10m ago). Message was queued but may not be seen soon.",
        ));
}

#[test]
fn test_send_reads_message_from_file() {
    let tmp = TempDir::new().unwrap();
    squad(tmp.path()).arg("init").assert().success();
    squad(tmp.path())
        .args(["join", "manager"])
        .assert()
        .success();
    squad(tmp.path())
        .args(["join", "worker"])
        .assert()
        .success();

    let message_path = tmp.path().join("message.txt");
    std::fs::write(&message_path, "line 1\nline 2").unwrap();

    squad(tmp.path())
        .args(["send", "--file", "message.txt", "manager", "worker"])
        .assert()
        .success()
        .stdout(predicate::str::contains("Sent to worker."));

    squad(tmp.path())
        .args(["receive", "worker"])
        .assert()
        .success()
        .stdout(predicate::str::contains("line 1\nline 2"));
}

#[test]
fn test_send_reads_message_from_stdin() {
    let tmp = TempDir::new().unwrap();
    squad(tmp.path()).arg("init").assert().success();
    squad(tmp.path())
        .args(["join", "manager"])
        .assert()
        .success();
    squad(tmp.path())
        .args(["join", "worker"])
        .assert()
        .success();

    squad(tmp.path())
        .args(["send", "--file", "-", "manager", "worker"])
        .write_stdin("line 1\nline 2")
        .assert()
        .success()
        .stdout(predicate::str::contains("Sent to worker."));

    squad(tmp.path())
        .args(["receive", "worker"])
        .assert()
        .success()
        .stdout(predicate::str::contains("line 1\nline 2"));
}

#[test]
fn test_send_broadcast() {
    let tmp = TempDir::new().unwrap();
    squad(tmp.path()).arg("init").assert().success();
    squad(tmp.path())
        .args(["join", "manager"])
        .assert()
        .success();
    squad(tmp.path())
        .args(["join", "worker-1"])
        .assert()
        .success();
    squad(tmp.path())
        .args(["join", "worker-2"])
        .assert()
        .success();

    squad(tmp.path())
        .args(["send", "manager", "@all", "interface changed"])
        .assert()
        .success()
        .stdout(predicate::str::contains("Broadcast to 2 agents"));

    squad(tmp.path())
        .args(["receive", "worker-1"])
        .assert()
        .success()
        .stdout(predicate::str::contains("interface changed"));
}

#[test]
fn test_send_keeps_inline_message_starting_with_file_flag() {
    let tmp = TempDir::new().unwrap();
    squad(tmp.path()).arg("init").assert().success();
    squad(tmp.path())
        .args(["join", "manager"])
        .assert()
        .success();
    squad(tmp.path())
        .args(["join", "worker"])
        .assert()
        .success();

    squad(tmp.path())
        .args(["send", "manager", "worker", "--file", "missing.txt"])
        .assert()
        .success();

    squad(tmp.path())
        .args(["receive", "worker"])
        .assert()
        .success()
        .stdout(predicate::str::contains("--file missing.txt"));
}

#[test]
fn test_broadcast_warns_about_stale_recipients() {
    let tmp = TempDir::new().unwrap();
    squad(tmp.path()).arg("init").assert().success();
    squad(tmp.path())
        .args(["join", "manager"])
        .assert()
        .success();
    squad(tmp.path())
        .args(["join", "worker-1"])
        .assert()
        .success();
    squad(tmp.path())
        .args(["join", "worker-2"])
        .assert()
        .success();

    mark_agent_stale(tmp.path(), "worker-2");

    squad(tmp.path())
        .args(["send", "manager", "@all", "interface changed"])
        .assert()
        .success()
        .stdout(predicate::str::contains(
            "Broadcast to 2 agents: worker-1, worker-2",
        ))
        .stdout(predicate::str::contains(
            "Warning: stale recipients: worker-2 (10m ago).",
        ));
}

#[test]
fn test_send_to_nonexistent() {
    let tmp = TempDir::new().unwrap();
    squad(tmp.path()).arg("init").assert().success();
    squad(tmp.path())
        .args(["join", "manager"])
        .assert()
        .success();

    squad(tmp.path())
        .args(["send", "manager", "nobody", "hello"])
        .assert()
        .failure()
        .stderr(predicate::str::contains("does not exist"));
}

#[test]
fn test_send_from_nonexistent_fails() {
    let tmp = TempDir::new().unwrap();
    squad(tmp.path()).arg("init").assert().success();
    squad(tmp.path())
        .args(["join", "worker"])
        .assert()
        .success();

    squad(tmp.path())
        .args(["send", "ghost", "worker", "hello"])
        .assert()
        .failure()
        .stderr(predicate::str::contains("ghost does not exist"));
}

#[test]
fn test_leave() {
    let tmp = TempDir::new().unwrap();
    squad(tmp.path()).arg("init").assert().success();
    squad(tmp.path())
        .args(["join", "manager"])
        .assert()
        .success();
    squad(tmp.path())
        .args(["leave", "manager"])
        .assert()
        .success()
        .stdout(predicate::str::contains(
            "manager archived from the squad. Unread work was preserved.",
        ));
    squad(tmp.path())
        .arg("agents")
        .assert()
        .success()
        .stdout(predicate::str::contains("No agents"));
}

#[test]
fn test_leave_nonexistent_agent_fails() {
    let tmp = TempDir::new().unwrap();
    squad(tmp.path()).arg("init").assert().success();
    squad(tmp.path())
        .args(["leave", "ghost"])
        .assert()
        .failure()
        .stderr(predicate::str::contains("ghost does not exist"));
}

#[test]
fn test_leave_archived_agent_fails_with_archived_message() {
    let tmp = TempDir::new().unwrap();
    squad(tmp.path()).arg("init").assert().success();
    squad(tmp.path())
        .args(["join", "worker"])
        .assert()
        .success();
    squad(tmp.path())
        .args(["leave", "worker"])
        .assert()
        .success();

    squad(tmp.path())
        .args(["leave", "worker"])
        .assert()
        .failure()
        .stderr(predicate::str::contains("worker is archived"));
}

#[test]
fn test_archived_agent_errors_are_distinct_from_nonexistent() {
    let tmp = TempDir::new().unwrap();
    squad(tmp.path()).arg("init").assert().success();
    squad(tmp.path())
        .args(["join", "manager"])
        .assert()
        .success();
    squad(tmp.path())
        .args(["join", "worker"])
        .assert()
        .success();
    squad(tmp.path())
        .args(["leave", "worker"])
        .assert()
        .success();

    squad(tmp.path())
        .args(["send", "manager", "worker", "hello"])
        .assert()
        .failure()
        .stderr(predicate::str::contains("worker is archived"));

    squad(tmp.path())
        .args(["receive", "worker"])
        .assert()
        .failure()
        .stderr(predicate::str::contains("worker is archived"));

    squad(tmp.path())
        .args(["send", "manager", "ghost", "hello"])
        .assert()
        .failure()
        .stderr(predicate::str::contains("ghost does not exist"));
}

#[test]
fn test_help_describes_leave_as_archive() {
    let tmp = TempDir::new().unwrap();
    squad(tmp.path())
        .arg("help")
        .assert()
        .success()
        .stdout(predicate::str::contains(
            "squad leave <id>                           Archive agent",
        ));
}

#[test]
fn test_readmes_and_manager_role_describe_archive_semantics() {
    let readme = std::fs::read_to_string("docs/squad-cli.md").unwrap();
    let readme_zh = std::fs::read_to_string("docs/squad-cli.zh-CN.md").unwrap();
    let manager_role = std::fs::read_to_string("src/roles/manager.md").unwrap();

    assert!(readme.contains("| `squad leave <id>` | Archive agent and preserve unread work |"));
    assert!(readme_zh.contains("| `squad leave <id>` | 归档 Agent，并保留未读工作 |"));
    assert!(manager_role.contains(
        "use `squad leave <id>` to archive it, preserve any unread work, and reassign its task to another agent"
    ));
}

#[test]
fn test_agents_hides_archived_by_default_and_shows_them_with_all() {
    let tmp = TempDir::new().unwrap();
    squad(tmp.path()).arg("init").assert().success();
    squad(tmp.path())
        .args(["join", "manager"])
        .assert()
        .success();
    squad(tmp.path())
        .args(["join", "worker"])
        .assert()
        .success();
    squad(tmp.path())
        .args(["leave", "worker"])
        .assert()
        .success();

    squad(tmp.path())
        .arg("agents")
        .assert()
        .success()
        .stdout(predicate::str::contains("manager"))
        .stdout(predicate::str::contains("worker").not());

    squad(tmp.path())
        .args(["agents", "--all"])
        .assert()
        .success()
        .stdout(predicate::str::contains("manager"))
        .stdout(predicate::str::contains("worker"))
        .stdout(predicate::str::contains("archived"));
}

#[test]
fn test_join_reactivates_archived_agent_with_same_id() {
    let tmp = TempDir::new().unwrap();
    squad(tmp.path()).arg("init").assert().success();
    squad(tmp.path())
        .args(["join", "worker"])
        .assert()
        .success();
    squad(tmp.path())
        .args(["leave", "worker"])
        .assert()
        .success();

    squad(tmp.path())
        .args(["join", "worker"])
        .assert()
        .success()
        .stdout(predicate::str::contains("Joined as worker"))
        .stdout(predicate::str::contains("worker-2").not());
}

#[test]
fn test_setup_list() {
    let tmp = TempDir::new().unwrap();
    squad(tmp.path())
        .args(["setup", "--list"])
        .assert()
        .success()
        .stdout(predicate::str::contains("claude"))
        .stdout(predicate::str::contains("gemini"))
        .stdout(predicate::str::contains("codex"))
        .stdout(predicate::str::contains("opencode"));
}

#[test]
fn test_help_describes_wait_as_debug_only() {
    let tmp = TempDir::new().unwrap();
    squad(tmp.path())
        .arg("help")
        .assert()
        .success()
        .stdout(predicate::str::contains(
            "squad receive <id> [--wait] [--timeout N] [--json]",
        ))
        .stdout(predicate::str::contains(
            "`--wait` blocks until a message arrives",
        ))
        .stdout(predicate::str::contains(
            "squad task create <from> <to> --title <title> [--body <body>]",
        ))
        .stdout(predicate::str::contains("squad init [--refresh-roles]"))
        .stdout(predicate::str::contains("Worker checks once for tasks"));
}

#[test]
fn test_readmes_describe_receive_timeout_debug_path() {
    let readme = std::fs::read_to_string("docs/squad-cli.md").unwrap();
    let readme_zh = std::fs::read_to_string("docs/squad-cli.zh-CN.md").unwrap();

    assert!(readme.contains("| `squad receive <id> [--wait] [--timeout N] [--json]` |"));
    assert!(readme.contains("| `squad task create <from> <to> --title <title> [--body <body>]` |"));
    assert!(readme.contains("| `squad task complete <agent> <task-id> --summary <text>` |"));
    assert!(readme.contains("| `squad task list [--agent <id>] [--status <status>]` |"));
    assert!(readme_zh.contains("| `squad receive <id> [--wait] [--timeout N] [--json]` |"));
    assert!(
        readme_zh.contains("| `squad task create <from> <to> --title <title> [--body <body>]` |")
    );
    assert!(readme_zh.contains("| `squad task complete <agent> <task-id> --summary <text>` |"));
    assert!(readme_zh.contains("| `squad task list [--agent <id>] [--status <status>]` |"));
}

#[test]
fn test_receive_rejects_unknown_flag() {
    let tmp = TempDir::new().unwrap();
    squad(tmp.path()).arg("init").assert().success();
    squad(tmp.path())
        .args(["join", "worker"])
        .assert()
        .success();

    squad(tmp.path())
        .args(["receive", "worker", "--bogus"])
        .assert()
        .failure()
        .stderr(predicate::str::contains("unknown receive flag: --bogus"));
}

#[test]
fn test_receive_rejects_invalid_timeout_value() {
    let tmp = TempDir::new().unwrap();
    squad(tmp.path()).arg("init").assert().success();
    squad(tmp.path())
        .args(["join", "worker"])
        .assert()
        .success();

    squad(tmp.path())
        .args(["receive", "worker", "--wait", "--timeout", "nope"])
        .assert()
        .failure()
        .stderr(predicate::str::contains("invalid --timeout value: nope"));
}

#[test]
fn test_receive_rejects_timeout_without_wait() {
    let tmp = TempDir::new().unwrap();
    squad(tmp.path()).arg("init").assert().success();
    squad(tmp.path())
        .args(["join", "worker"])
        .assert()
        .success();

    squad(tmp.path())
        .args(["receive", "worker", "--timeout", "5"])
        .assert()
        .failure()
        .stderr(predicate::str::contains("--timeout requires --wait"));
}

#[test]
fn test_role_prompts_prefer_task_commands_with_send_receive_fallback() {
    let manager_role = std::fs::read_to_string("src/roles/manager.md").unwrap();
    let worker_role = std::fs::read_to_string("src/roles/worker.md").unwrap();
    let inspector_role = std::fs::read_to_string("src/roles/inspector.md").unwrap();

    assert!(manager_role.contains(
        "Prefer `squad task create manager <agent> --title \"<title>\" [--body \"<body>\"]`"
    ));
    assert!(manager_role.contains("keep `squad send` / `squad receive` as the fallback path"));
    assert!(worker_role.contains("Prefer `squad task ack <your-id> <task-id>` and `squad task complete <your-id> <task-id> --summary \"<summary>\"`"));
    assert!(worker_role.contains("keep `squad send` / `squad receive` as the fallback path"));
    assert!(inspector_role.contains("Prefer `squad send --task-id <task-id> --reply-to <message-id> <your-id> <worker-id> \"<specific feedback>\"`"));
    assert!(
        inspector_role.contains("keep plain `squad send` / `squad receive` as the fallback path")
    );
}

#[test]
fn test_join_freeform_role_succeeds() {
    let tmp = TempDir::new().unwrap();
    squad(tmp.path()).arg("init").assert().success();
    squad(tmp.path())
        .args(["join", "cto"])
        .assert()
        .success()
        .stdout(predicate::str::contains("Joined as cto"))
        .stdout(predicate::str::contains("Interpret this role autonomously"))
        .stdout(predicate::str::contains("squad send"))
        .stdout(predicate::str::contains("squad receive, squad agents"))
        .stdout(predicate::str::contains("--wait").not());
}

#[test]
fn test_history() {
    let tmp = TempDir::new().unwrap();
    squad(tmp.path()).arg("init").assert().success();
    squad(tmp.path())
        .args(["join", "manager"])
        .assert()
        .success();
    squad(tmp.path())
        .args(["join", "worker"])
        .assert()
        .success();

    squad(tmp.path())
        .args(["send", "manager", "worker", "task 1"])
        .assert()
        .success();
    squad(tmp.path())
        .args(["receive", "worker"])
        .assert()
        .success(); // marks as read

    // history still shows it
    squad(tmp.path())
        .arg("history")
        .assert()
        .success()
        .stdout(predicate::str::contains("task 1"));
}

#[test]
fn test_history_shows_timestamps() {
    let tmp = TempDir::new().unwrap();
    squad(tmp.path()).arg("init").assert().success();
    squad(tmp.path())
        .args(["join", "manager"])
        .assert()
        .success();
    squad(tmp.path())
        .args(["join", "worker"])
        .assert()
        .success();

    squad(tmp.path())
        .args(["send", "manager", "worker", "task timestamped"])
        .assert()
        .success();
    set_message_timestamp(tmp.path(), "task timestamped", 1_704_067_200);

    squad(tmp.path())
        .arg("history")
        .assert()
        .success()
        .stdout(predicate::str::contains("[2024-01-01T00:00:00Z]"))
        .stdout(predicate::str::contains("task timestamped"));
}

#[test]
fn test_history_formats_multiline_messages_readably() {
    let tmp = TempDir::new().unwrap();
    squad(tmp.path()).arg("init").assert().success();
    squad(tmp.path())
        .args(["join", "manager"])
        .assert()
        .success();
    squad(tmp.path())
        .args(["join", "worker"])
        .assert()
        .success();

    squad(tmp.path())
        .args(["send", "--file", "-", "manager", "worker"])
        .write_stdin("line 1\nline 2")
        .assert()
        .success();
    set_message_timestamp(tmp.path(), "line 1\nline 2", 1_704_067_200);

    squad(tmp.path())
        .arg("history")
        .assert()
        .success()
        .stdout(predicate::str::contains(
            "* [2024-01-01T00:00:00Z] manager -> worker: line 1\n  | line 2",
        ));
}

#[test]
fn test_history_filters_by_from_and_to() {
    let tmp = TempDir::new().unwrap();
    squad(tmp.path()).arg("init").assert().success();
    for agent in ["manager", "worker", "inspector"] {
        squad(tmp.path()).args(["join", agent]).assert().success();
    }

    squad(tmp.path())
        .args(["send", "manager", "worker", "task from manager"])
        .assert()
        .success();
    squad(tmp.path())
        .args(["send", "worker", "manager", "done from worker"])
        .assert()
        .success();
    squad(tmp.path())
        .args(["send", "inspector", "worker", "review from inspector"])
        .assert()
        .success();

    squad(tmp.path())
        .args(["history", "--from", "manager"])
        .assert()
        .success()
        .stdout(predicate::str::contains("task from manager"))
        .stdout(predicate::str::contains("done from worker").not())
        .stdout(predicate::str::contains("review from inspector").not());

    squad(tmp.path())
        .args(["history", "--to", "manager"])
        .assert()
        .success()
        .stdout(predicate::str::contains("done from worker"))
        .stdout(predicate::str::contains("task from manager").not())
        .stdout(predicate::str::contains("review from inspector").not());
}

#[test]
fn test_history_positional_agent_filter_still_works() {
    let tmp = TempDir::new().unwrap();
    squad(tmp.path()).arg("init").assert().success();
    for agent in ["manager", "worker", "inspector"] {
        squad(tmp.path()).args(["join", agent]).assert().success();
    }

    squad(tmp.path())
        .args(["send", "manager", "worker", "task for worker"])
        .assert()
        .success();
    squad(tmp.path())
        .args(["send", "inspector", "manager", "review for manager"])
        .assert()
        .success();

    squad(tmp.path())
        .args(["history", "worker"])
        .assert()
        .success()
        .stdout(predicate::str::contains("task for worker"))
        .stdout(predicate::str::contains("review for manager").not());
}

#[test]
fn test_history_filters_by_since() {
    let tmp = TempDir::new().unwrap();
    squad(tmp.path()).arg("init").assert().success();
    squad(tmp.path())
        .args(["join", "manager"])
        .assert()
        .success();
    squad(tmp.path())
        .args(["join", "worker"])
        .assert()
        .success();

    squad(tmp.path())
        .args(["send", "manager", "worker", "old task"])
        .assert()
        .success();
    set_message_timestamp(tmp.path(), "old task", 1_704_067_200);

    squad(tmp.path())
        .args(["send", "manager", "worker", "new task"])
        .assert()
        .success();
    set_message_timestamp(tmp.path(), "new task", 1_704_067_320);

    squad(tmp.path())
        .args(["history", "--since", "2024-01-01T00:01:00Z"])
        .assert()
        .success()
        .stdout(predicate::str::contains("new task"))
        .stdout(predicate::str::contains("old task").not());
}

#[test]
fn test_history_filters_by_numeric_since() {
    let tmp = TempDir::new().unwrap();
    squad(tmp.path()).arg("init").assert().success();
    squad(tmp.path())
        .args(["join", "manager"])
        .assert()
        .success();
    squad(tmp.path())
        .args(["join", "worker"])
        .assert()
        .success();

    squad(tmp.path())
        .args(["send", "manager", "worker", "older task"])
        .assert()
        .success();
    set_message_timestamp(tmp.path(), "older task", 1_704_067_200);

    squad(tmp.path())
        .args(["send", "manager", "worker", "latest task"])
        .assert()
        .success();
    set_message_timestamp(tmp.path(), "latest task", 1_704_067_320);

    squad(tmp.path())
        .args(["history", "--since", "1704067260"])
        .assert()
        .success()
        .stdout(predicate::str::contains("latest task"))
        .stdout(predicate::str::contains("older task").not());
}

#[test]
fn test_receive_wait_timeout_suggests_checking_again() {
    let tmp = TempDir::new().unwrap();
    squad(tmp.path()).arg("init").assert().success();
    squad(tmp.path())
        .args(["join", "worker"])
        .assert()
        .success();

    squad(tmp.path())
        .args(["receive", "worker", "--wait", "--timeout", "0"])
        .assert()
        .success()
        .stdout(predicate::str::contains(
            "No new messages (timed out after 0s). Run `squad receive worker --wait` to continue listening.",
        ));
}

#[test]
fn test_receive_wait_message_includes_continue_listening_prompt() {
    let tmp = TempDir::new().unwrap();
    squad(tmp.path()).arg("init").assert().success();
    squad(tmp.path())
        .args(["join", "manager"])
        .assert()
        .success();
    squad(tmp.path())
        .args(["join", "worker"])
        .assert()
        .success();

    squad(tmp.path())
        .args(["send", "manager", "worker", "queued for wait"])
        .assert()
        .success();

    squad(tmp.path())
        .args(["receive", "worker", "--wait"])
        .assert()
        .success()
        .stdout(predicate::str::contains("queued for wait"))
        .stdout(predicate::str::contains(
            "After processing, run `squad receive worker --wait` to continue listening.",
        ));
}

#[test]
fn test_task_commands_cover_create_ack_complete_requeue_and_list() {
    let tmp = TempDir::new().unwrap();
    squad(tmp.path()).arg("init").assert().success();
    for agent in ["manager", "worker", "worker-2"] {
        squad(tmp.path()).args(["join", agent]).assert().success();
    }

    squad(tmp.path())
        .args([
            "task",
            "create",
            "manager",
            "worker",
            "--title",
            "auth-module",
            "--body",
            "Implement auth module",
        ])
        .assert()
        .success()
        .stdout(predicate::str::contains("Created task"))
        .stdout(predicate::str::contains("auth-module"));

    let task_id = first_task_id(tmp.path());

    squad(tmp.path())
        .args(["task", "list", "--agent", "worker", "--status", "queued"])
        .assert()
        .success()
        .stdout(predicate::str::contains(&task_id))
        .stdout(predicate::str::contains(format!("[task {task_id}] queued")))
        .stdout(predicate::str::contains("assigned_to: worker"))
        .stdout(predicate::str::contains("lease_owner: unleased"))
        .stdout(predicate::str::contains("title: auth-module"));

    squad(tmp.path())
        .args(["task", "ack", "worker", &task_id])
        .assert()
        .success()
        .stdout(predicate::str::contains(format!("Acked task {task_id}")));

    squad(tmp.path())
        .args([
            "task",
            "complete",
            "worker",
            &task_id,
            "--summary",
            "Auth shipped",
        ])
        .assert()
        .success()
        .stdout(predicate::str::contains(format!(
            "Completed task {task_id}"
        )))
        .stdout(predicate::str::contains("Auth shipped"));

    squad(tmp.path())
        .args(["task", "requeue", &task_id, "--to", "worker-2"])
        .assert()
        .success()
        .stdout(predicate::str::contains(format!("Requeued task {task_id}")))
        .stdout(predicate::str::contains("worker-2"));

    squad(tmp.path())
        .args(["task", "list", "--agent", "worker-2", "--status", "queued"])
        .assert()
        .success()
        .stdout(predicate::str::contains(&task_id))
        .stdout(predicate::str::contains(format!("[task {task_id}] queued")))
        .stdout(predicate::str::contains("assigned_to: worker-2"))
        .stdout(predicate::str::contains("lease_owner: unleased"))
        .stdout(predicate::str::contains("title: auth-module"));
}

#[test]
fn test_receive_text_formats_task_messages_with_metadata() {
    let tmp = TempDir::new().unwrap();
    squad(tmp.path()).arg("init").assert().success();
    for agent in ["manager", "worker"] {
        squad(tmp.path()).args(["join", agent]).assert().success();
    }

    squad(tmp.path())
        .args([
            "task",
            "create",
            "manager",
            "worker",
            "--title",
            "auth-module",
            "--body",
            "Implement auth module",
        ])
        .assert()
        .success();

    let task_id = first_task_id(tmp.path());

    squad(tmp.path())
        .args(["receive", "worker"])
        .assert()
        .success()
        .stdout(predicate::str::contains(format!(
            "[task {task_id}] queued from manager"
        )))
        .stdout(predicate::str::contains("Title: auth-module"))
        .stdout(predicate::str::contains("Body: Implement auth module"))
        .stdout(predicate::str::contains(format!(
            "Reply: squad send --task-id {task_id} worker manager \"<your response>\""
        )));
}

#[test]
fn test_send_supports_task_id_and_reply_to_metadata() {
    let tmp = TempDir::new().unwrap();
    squad(tmp.path()).arg("init").assert().success();
    for agent in ["manager", "worker"] {
        squad(tmp.path()).args(["join", agent]).assert().success();
    }

    squad(tmp.path())
        .args([
            "task",
            "create",
            "manager",
            "worker",
            "--title",
            "auth-module",
            "--body",
            "Implement auth module",
        ])
        .assert()
        .success();
    let task_id = first_task_id(tmp.path());

    squad(tmp.path())
        .args(["receive", "worker"])
        .assert()
        .success();
    let assignment_message_id = message_id_by_content(tmp.path(), "auth-module");

    let output = squad(tmp.path())
        .args([
            "send",
            "--task-id",
            &task_id,
            "--reply-to",
            &assignment_message_id.to_string(),
            "worker",
            "manager",
            "Need clarification on auth edge cases",
        ])
        .assert()
        .success()
        .get_output()
        .stdout
        .clone();
    assert!(String::from_utf8(output)
        .unwrap()
        .contains("Sent to manager."));

    let output = squad(tmp.path())
        .args(["receive", "manager", "--json"])
        .assert()
        .success()
        .get_output()
        .stdout
        .clone();
    let lines: Vec<Value> = String::from_utf8(output)
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    let first = &lines[0];
    assert_eq!(first["kind"], "note");
    assert_eq!(first["task_id"], task_id);
    assert_eq!(first["reply_to"], assignment_message_id);
    assert_eq!(first["content"], "Need clarification on auth edge cases");
}

#[test]
fn test_receive_json_preserves_mixed_inbox_order_and_task_structure() {
    let tmp = TempDir::new().unwrap();
    squad(tmp.path()).arg("init").assert().success();
    for agent in ["manager", "worker"] {
        squad(tmp.path()).args(["join", agent]).assert().success();
    }

    squad(tmp.path())
        .args(["send", "manager", "worker", "legacy note before task"])
        .assert()
        .success();
    set_message_timestamp(tmp.path(), "legacy note before task", 1_704_067_200);

    squad(tmp.path())
        .args([
            "task",
            "create",
            "manager",
            "worker",
            "--title",
            "auth-module",
            "--body",
            "Implement auth module",
        ])
        .assert()
        .success();
    set_message_timestamp(tmp.path(), "auth-module", 1_704_067_200);
    let task_id = first_task_id(tmp.path());

    squad(tmp.path())
        .args(["send", "manager", "worker", "legacy note after task"])
        .assert()
        .success();
    set_message_timestamp(tmp.path(), "legacy note after task", 1_704_067_200);

    let output = squad(tmp.path())
        .args(["receive", "worker", "--json"])
        .assert()
        .success()
        .get_output()
        .stdout
        .clone();
    let entries: Vec<Value> = String::from_utf8(output)
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();

    assert_eq!(entries.len(), 3);
    assert_eq!(entries[0]["kind"], "note");
    assert_eq!(entries[0]["content"], "legacy note before task");

    assert_eq!(entries[1]["kind"], "task_assigned");
    assert_eq!(entries[1]["task_id"], task_id);
    assert_eq!(entries[1]["task"]["id"], task_id);
    assert_eq!(entries[1]["task"]["title"], "auth-module");
    assert_eq!(entries[1]["task"]["body"], "Implement auth module");
    assert_eq!(entries[1]["task"]["status"], "queued");

    assert_eq!(entries[2]["kind"], "note");
    assert_eq!(entries[2]["content"], "legacy note after task");
}

#[test]
fn test_receive_json_empty_inbox_emits_no_objects() {
    let tmp = TempDir::new().unwrap();
    squad(tmp.path()).arg("init").assert().success();
    squad(tmp.path())
        .args(["join", "worker"])
        .assert()
        .success();

    squad(tmp.path())
        .args(["receive", "worker", "--json"])
        .assert()
        .success()
        .stdout(predicate::str::is_empty());
}

#[test]
fn test_receive_wait_json_empty_inbox_emits_no_objects() {
    let tmp = TempDir::new().unwrap();
    squad(tmp.path()).arg("init").assert().success();
    squad(tmp.path())
        .args(["join", "worker"])
        .assert()
        .success();

    squad(tmp.path())
        .args(["receive", "worker", "--wait", "--timeout", "0", "--json"])
        .assert()
        .success()
        .stdout(predicate::str::is_empty());
}

#[test]
fn test_join_creates_session_file() {
    let tmp = TempDir::new().unwrap();
    squad(tmp.path()).arg("init").assert().success();
    squad(tmp.path())
        .args(["join", "worker", "--role", "worker"])
        .assert()
        .success();
    let session_path = tmp.path().join(".squad").join("sessions").join("worker");
    assert!(session_path.exists());
    let token = std::fs::read_to_string(&session_path).unwrap();
    assert_eq!(token.len(), 36); // UUID v4
}

#[test]
fn test_setup_templates_pass_client_and_protocol_metadata_on_join() {
    let claude = command_content(PLATFORMS.iter().find(|p| p.name == "claude").unwrap());
    let codex = command_content(PLATFORMS.iter().find(|p| p.name == "codex").unwrap());
    let opencode = command_content(PLATFORMS.iter().find(|p| p.name == "opencode").unwrap());
    let gemini = command_content(PLATFORMS.iter().find(|p| p.name == "gemini").unwrap());

    assert!(claude.contains("--client claude"));
    assert!(claude.contains("--protocol-version 2"));
    assert!(codex.contains("--client codex"));
    assert!(opencode.contains("--client opencode"));
    assert!(gemini.contains("--client gemini"));
    assert!(gemini.contains("--protocol-version 2"));
}

#[test]
fn test_leave_deletes_session_file() {
    let tmp = TempDir::new().unwrap();
    squad(tmp.path()).arg("init").assert().success();
    squad(tmp.path())
        .args(["join", "worker"])
        .assert()
        .success();
    squad(tmp.path())
        .args(["leave", "worker"])
        .assert()
        .success();
    let session_path = tmp.path().join(".squad").join("sessions").join("worker");
    assert!(!session_path.exists());
}

#[test]
fn test_doctor_reports_template_archived_task_and_protocol_warnings_without_mutating_state() {
    let tmp = TempDir::new().unwrap();
    let home = tmp.path().join("home");
    std::fs::create_dir_all(&home).unwrap();
    let path_env = path_with_fake_binary(&tmp, "claude");

    squad(tmp.path()).arg("init").assert().success();
    squad(tmp.path())
        .args([
            "join",
            "manager",
            "--role",
            "manager",
            "--protocol-version",
            "2",
        ])
        .assert()
        .success();
    squad(tmp.path())
        .args(["join", "legacy", "--role", "worker"])
        .assert()
        .success();
    squad(tmp.path())
        .args([
            "join",
            "archived-worker",
            "--role",
            "worker",
            "--protocol-version",
            "2",
        ])
        .assert()
        .success();

    squad(tmp.path())
        .args([
            "task",
            "create",
            "manager",
            "archived-worker",
            "--title",
            "pending-task",
            "--body",
            "body",
        ])
        .assert()
        .success();
    let pending_task_id = first_task_id(tmp.path());
    squad(tmp.path())
        .args(["leave", "archived-worker"])
        .assert()
        .success();

    let template_path = home.join(".claude/commands/squad.md");
    std::fs::create_dir_all(template_path.parent().unwrap()).unwrap();
    std::fs::write(
        &template_path,
        "# squad-version: 0.0.1\noutdated template\n",
    )
    .unwrap();
    let before_template = std::fs::read_to_string(&template_path).unwrap();

    let db = tmp.path().join(".squad").join("messages.db");
    let conn = Connection::open(&db).unwrap();
    let before_last_seen: Option<i64> = conn
        .query_row(
            "SELECT last_seen FROM agents WHERE id = 'legacy'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    let before_status: String = conn
        .query_row(
            "SELECT status FROM tasks WHERE id = ?1",
            [&pending_task_id],
            |row| row.get(0),
        )
        .unwrap();
    drop(conn);

    squad(tmp.path())
        .arg("doctor")
        .env("HOME", &home)
        .env("PATH", &path_env)
        .assert()
        .success()
        .stdout(predicate::str::contains(format!(
            "WARN: slash template claude is outdated (installed=0.0.1, current={}); run squad init or squad setup",
            current_version()
        )))
        .stdout(predicate::str::contains(format!(
            "WARN: archived agent archived-worker has pending tasks: {}",
            pending_task_id
        )))
        .stdout(predicate::str::contains(
            "WARN: legacy has effective_protocol_version=1; task commands should fall back to send/receive",
        ));

    assert_eq!(
        std::fs::read_to_string(&template_path).unwrap(),
        before_template
    );
    let conn = Connection::open(&db).unwrap();
    let after_last_seen: Option<i64> = conn
        .query_row(
            "SELECT last_seen FROM agents WHERE id = 'legacy'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    let after_status: String = conn
        .query_row(
            "SELECT status FROM tasks WHERE id = ?1",
            [&pending_task_id],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(after_last_seen, before_last_seen);
    assert_eq!(after_status, before_status);
}

#[test]
fn test_doctor_reports_clean_state_and_help_mentions_command() {
    let tmp = TempDir::new().unwrap();
    let home = tmp.path().join("home");
    std::fs::create_dir_all(&home).unwrap();
    let empty_bin = tmp.path().join("empty_bin");
    std::fs::create_dir_all(&empty_bin).unwrap();

    squad(tmp.path()).arg("init").assert().success();
    squad(tmp.path())
        .args([
            "join",
            "modern",
            "--role",
            "worker",
            "--client",
            "codex",
            "--protocol-version",
            "2",
        ])
        .assert()
        .success();

    squad(tmp.path())
        .arg("doctor")
        .env("HOME", &home)
        .env("PATH", empty_bin.to_str().unwrap())
        .assert()
        .success()
        .stdout(predicate::str::contains(
            "OK: no installed slash templates detected",
        ))
        .stdout(predicate::str::contains(
            "OK: no archived agents with pending tasks",
        ))
        .stdout(predicate::str::contains(
            "OK: all agents meet protocol threshold",
        ));

    squad(tmp.path())
        .arg("help")
        .assert()
        .success()
        .stdout(predicate::str::contains("squad doctor"));
}

const ALL_CLIENTS: [&str; 7] = [
    "claude", "codex", "gemini", "opencode", "grok", "agy", "ccr",
];

fn client_type_of(dir: &std::path::Path, id: &str) -> Option<String> {
    let conn = Connection::open(dir.join(".squad").join("messages.db")).unwrap();
    conn.query_row(
        "SELECT client_type FROM agents WHERE id = ?1",
        [id],
        |row| row.get(0),
    )
    .unwrap()
}

#[test]
fn test_join_accepts_every_supported_client() {
    let tmp = TempDir::new().unwrap();
    squad(tmp.path()).arg("init").assert().success();
    for client in ALL_CLIENTS {
        let id = format!("w-{client}");
        squad(tmp.path())
            .args(["join", &id, "--client", client, "--protocol-version", "2"])
            .assert()
            .success();
        assert_eq!(client_type_of(tmp.path(), &id).as_deref(), Some(client));
    }
}

#[test]
fn test_join_rejects_unknown_or_miscased_client_without_creating_agent() {
    let tmp = TempDir::new().unwrap();
    squad(tmp.path()).arg("init").assert().success();
    for bad in ["bogus", "AGY", "Claude", "", "agy "] {
        squad(tmp.path())
            .args(["join", "bad", "--client", bad])
            .assert()
            .failure()
            .stderr(
                predicate::str::contains("invalid --client value")
                    .or(predicate::str::contains("--client requires a value")),
            );
    }
    let conn = Connection::open(tmp.path().join(".squad").join("messages.db")).unwrap();
    // The agents table is created lazily, so none yet also means no agent.
    let count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM agents WHERE id LIKE 'bad%'",
            [],
            |r| r.get(0),
        )
        .unwrap_or(0);
    assert_eq!(count, 0);
}

#[test]
fn test_join_without_client_leaves_client_type_null() {
    let tmp = TempDir::new().unwrap();
    squad(tmp.path()).arg("init").assert().success();
    squad(tmp.path()).args(["join", "plain"]).assert().success();
    assert_eq!(client_type_of(tmp.path(), "plain"), None);
}

#[test]
fn test_join_same_id_keeps_each_clients_type() {
    let tmp = TempDir::new().unwrap();
    squad(tmp.path()).arg("init").assert().success();
    squad(tmp.path())
        .args(["join", "dup", "--client", "grok"])
        .assert()
        .success();
    let out = squad(tmp.path())
        .args(["join", "dup", "--client", "agy"])
        .output()
        .unwrap();
    let text = String::from_utf8_lossy(&out.stdout);
    let second = text
        .split_whitespace()
        .skip_while(|w| *w != "as")
        .nth(1)
        .unwrap()
        .to_string();
    assert_ne!(second, "dup");
    assert_eq!(client_type_of(tmp.path(), "dup").as_deref(), Some("grok"));
    assert_eq!(client_type_of(tmp.path(), &second).as_deref(), Some("agy"));
}

#[test]
fn test_join_usage_lists_every_client() {
    let tmp = TempDir::new().unwrap();
    let out = squad(tmp.path()).arg("join").output().unwrap();
    let stderr = String::from_utf8_lossy(&out.stderr);
    for client in ALL_CLIENTS {
        assert!(stderr.contains(client), "usage lacks {client}: {stderr}");
    }
}

#[test]
fn test_agents_json_reports_new_clients() {
    let tmp = TempDir::new().unwrap();
    squad(tmp.path()).arg("init").assert().success();
    for client in ["grok", "agy", "ccr"] {
        squad(tmp.path())
            .args([
                "join",
                client,
                "--client",
                client,
                "--protocol-version",
                "2",
            ])
            .assert()
            .success();
    }
    let out = squad(tmp.path())
        .args(["agents", "--json"])
        .output()
        .unwrap();
    let text = String::from_utf8_lossy(&out.stdout);
    for client in ["grok", "agy", "ccr"] {
        assert!(text.contains(&format!("\"{client}\"")), "{text}");
    }
}

#[test]
fn test_cli_docs_join_usage_lists_every_client() {
    let docs =
        std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/docs/squad-cli.md")).unwrap();
    let line = docs
        .lines()
        .find(|l| l.contains("`squad join <id>"))
        .expect("docs/squad-cli.md documents squad join");
    for client in ALL_CLIENTS {
        assert!(line.contains(client), "docs/squad-cli.md join usage lacks {client}");
    }
}
