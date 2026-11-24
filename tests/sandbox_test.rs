use std::process::Command;

#[test]
fn off_runs_and_invalid_profile_fails() {
    let root = std::env::temp_dir();
    let run = |profile: &str| {
        Command::new(env!("CARGO_BIN_EXE_squad"))
            .args([
                "sandbox",
                "exec",
                "--worktree",
                root.to_str().unwrap(),
                "--profile",
                profile,
                "--",
                "/usr/bin/true",
            ])
            .status()
            .unwrap()
    };
    assert!(run("off").success());
    assert!(!run("invalid").success());
}

#[test]
fn isolation_smoke() {
    let bin = std::path::Path::new(env!("CARGO_BIN_EXE_squad"));
    let path = format!(
        "{}:{}",
        bin.parent().unwrap().display(),
        std::env::var("PATH").unwrap_or_default()
    );
    assert!(Command::new("bash")
        .arg("tests/squad_sandbox_isolation_smoke.sh")
        .env("PATH", path)
        .status()
        .unwrap()
        .success());
}

#[test]
fn missing_backend_fails_closed_and_workspace_warns() {
    let root = tempfile::tempdir().unwrap();
    let work = root.path().join("work");
    let bin = root.path().join("bin");
    std::fs::create_dir(&work).unwrap();
    std::fs::create_dir(&bin).unwrap();
    for profile in ["strict", "workspace"] {
        let output = Command::new(env!("CARGO_BIN_EXE_squad"))
            .env("PATH", &bin)
            .args([
                "sandbox",
                "exec",
                "--worktree",
                work.to_str().unwrap(),
                "--profile",
                profile,
                "--",
                "/usr/bin/touch",
                "ran",
            ])
            .output()
            .unwrap();
        assert_eq!(output.status.success(), profile == "workspace");
        assert_eq!(work.join("ran").exists(), profile == "workspace");
        assert!(
            String::from_utf8_lossy(&output.stderr).contains(if profile == "strict" {
                "preflight failed"
            } else {
                "WARNING"
            })
        );
    }
}

#[test]
fn ipc_uses_atomic_directory_exchange_without_workspace_database() {
    let dir = tempfile::tempdir().unwrap();
    let ipc = dir.path().join("ipc");
    std::fs::create_dir(&ipc).unwrap();
    let child = Command::new("bash")
        .arg("scripts/squad-ask.sh")
        .args([
            "--from",
            "fixture",
            "--workspace",
            "/does-not-exist",
            "--check",
            "--timeout",
            "3",
        ])
        .env("SQUAD_ASK_IPC_DIR", &ipc)
        .stdout(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
    loop {
        let request = std::fs::read_dir(&ipc)
            .unwrap()
            .flatten()
            .find(|e| e.file_name().to_string_lossy().ends_with(".request.json"));
        if let Some(request) = request {
            let value: serde_json::Value =
                serde_json::from_slice(&std::fs::read(request.path()).unwrap()).unwrap();
            assert_eq!(value["op"], "check");
            let response =
                serde_json::json!({"id": value["id"], "ok": true, "output": "fixture reply"});
            let pending = ipc.join("response.tmp");
            std::fs::write(&pending, response.to_string()).unwrap();
            std::fs::rename(
                pending,
                ipc.join(format!("{}.response.json", value["id"].as_str().unwrap())),
            )
            .unwrap();
            break;
        }
        assert!(std::time::Instant::now() < deadline);
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
    let result = child.wait_with_output().unwrap();
    assert!(result.status.success());
    assert_eq!(
        String::from_utf8_lossy(&result.stdout).trim(),
        "fixture reply"
    );
}

#[test]
fn workspace_preserves_child_failure_without_rerun() {
    let root = tempfile::tempdir().unwrap();
    let output = Command::new(env!("CARGO_BIN_EXE_squad"))
        .args([
            "sandbox",
            "exec",
            "--worktree",
            root.path().to_str().unwrap(),
            "--profile",
            "workspace",
            "--",
            "/bin/sh",
            "-c",
            "echo once >>count; exit 7",
        ])
        .status()
        .unwrap();
    assert_eq!(output.code(), Some(7));
    assert_eq!(
        std::fs::read_to_string(root.path().join("count")).unwrap(),
        "once\n"
    );
}
