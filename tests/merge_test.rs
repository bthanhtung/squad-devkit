use std::{fs, path::Path, process::Command};
fn git(repo: &Path, args: &[&str]) -> Vec<u8> {
    let out = Command::new("git")
        .current_dir(repo)
        .args(args)
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    out.stdout
}
#[test]
fn gate_rollback_restores_dirty_layers() {
    let dir = tempfile::tempdir().unwrap();
    let repo = dir.path();
    git(repo, &["init", "-q"]);
    git(repo, &["config", "user.email", "test@example.invalid"]);
    git(repo, &["config", "user.name", "test"]);
    fs::write(repo.join("file"), "base\n").unwrap();
    git(repo, &["add", "file"]);
    git(repo, &["commit", "-qm", "base"]);
    fs::write(repo.join("file"), "worker\n").unwrap();
    let patch = git(repo, &["diff", "--binary"]);
    fs::write(repo.join("file"), "base\n").unwrap();
    fs::write(repo.join("dirty"), "staged").unwrap();
    git(repo, &["add", "dirty"]);
    fs::write(repo.join("dirty"), "unstaged\0bytes").unwrap();
    fs::write(repo.join("untracked"), "original").unwrap();
    let index = fs::read(repo.join(".git/index")).unwrap();
    let patch_file = dir.path().join(".git/change.patch");
    fs::write(&patch_file, patch).unwrap();
    let out = Command::new(env!("CARGO_BIN_EXE_squad"))
        .args(["merge", "apply", "--repo"])
        .arg(repo)
        .arg("--patch")
        .arg(patch_file)
        .args([
            "--post-merge-gate",
            "echo changed > untracked; touch leaked; exit 7",
            "--json",
        ])
        .output()
        .unwrap();
    assert!(!out.status.success());
    assert!(String::from_utf8_lossy(&out.stdout).contains("rolled_back_verify_fail"));
    assert_eq!(fs::read(repo.join(".git/index")).unwrap(), index);
    assert_eq!(fs::read(repo.join("dirty")).unwrap(), b"unstaged\0bytes");
    assert_eq!(fs::read(repo.join("untracked")).unwrap(), b"original");
    assert_eq!(fs::read(repo.join("file")).unwrap(), b"base\n");
    assert!(!repo.join("leaked").exists());
}

struct Fixture {
    dir: tempfile::TempDir,
    patch: std::path::PathBuf,
    index: Vec<u8>,
}
impl Fixture {
    fn new(conflict: bool) -> Self {
        let dir = tempfile::tempdir().unwrap();
        let r = dir.path();
        git(r, &["init", "-q"]);
        git(r, &["config", "user.email", "test@example.invalid"]);
        git(r, &["config", "user.name", "test"]);
        fs::write(r.join("file"), "base\n").unwrap();
        git(r, &["add", "."]);
        git(r, &["commit", "-qm", "base"]);
        fs::write(r.join("file"), "worker\n").unwrap();
        fs::write(r.join("new-file"), "worker addition").unwrap();
        git(r, &["add", "."]);
        let patch = r.join(".git/change.patch");
        fs::write(&patch, git(r, &["diff", "--cached", "--binary"])).unwrap();
        git(r, &["reset", "--hard", "-q", "HEAD"]);
        fs::write(r.join("dirty"), "staged").unwrap();
        git(r, &["add", "dirty"]);
        fs::write(r.join("dirty"), "unstaged\0bytes").unwrap();
        fs::write(r.join("untracked"), "original").unwrap();
        if conflict {
            fs::write(r.join("file"), "local\n").unwrap();
        }
        let index = fs::read(r.join(".git/index")).unwrap();
        Self { dir, patch, index }
    }
    fn cmd(&self) -> Command {
        let mut c = Command::new(env!("CARGO_BIN_EXE_squad"));
        c.args(["merge", "apply", "--repo"])
            .arg(self.dir.path())
            .arg("--patch")
            .arg(&self.patch)
            .arg("--json");
        c
    }
    fn restored(&self, file: &[u8]) {
        let r = self.dir.path();
        assert_eq!(fs::read(r.join(".git/index")).unwrap(), self.index);
        assert_eq!(fs::read(r.join("file")).unwrap(), file);
        assert_eq!(fs::read(r.join("dirty")).unwrap(), b"unstaged\0bytes");
        assert_eq!(fs::read(r.join("untracked")).unwrap(), b"original");
        assert!(!r.join("new-file").exists());
        assert!(!r.join("leaked").exists());
    }
}
#[test]
fn conflict_restores_partial_apply() {
    let f = Fixture::new(true);
    let out = f.cmd().output().unwrap();
    assert!(!out.status.success());
    let text = String::from_utf8_lossy(&out.stdout);
    assert!(text.contains("rolled_back_conflict"), "{text}");
    assert!(text.contains("file"));
    f.restored(b"local\n");
}
#[test]
fn successful_merge_keeps_real_index() {
    let f = Fixture::new(false);
    let out = f.cmd().output().unwrap();
    assert!(out.status.success(), "{:?}", out);
    assert_eq!(fs::read(f.dir.path().join(".git/index")).unwrap(), f.index);
    assert_eq!(fs::read(f.dir.path().join("file")).unwrap(), b"worker\n");
}
fn wait_for(path: &Path) {
    for _ in 0..200 {
        if path.exists() {
            return;
        }
        std::thread::sleep(std::time::Duration::from_millis(25));
    }
    panic!("timeout: {}", path.display());
}
#[test]
fn different_workspaces_share_lock_and_crash_recovery() {
    let f = Fixture::new(false);
    let ready = f.dir.path().join(".git/ready");
    let workspace_a = tempfile::tempdir().unwrap();
    let workspace_b = tempfile::tempdir().unwrap();
    let mut child = f.cmd().arg("--workspace").arg(workspace_a.path()).args(["--post-merge-gate", "touch .git/ready; while test ! -f .git/release; do sleep 0.05; done; echo altered > untracked; touch leaked; exit 1"]).spawn().unwrap();
    wait_for(&ready);
    let overlap = f
        .cmd()
        .arg("--workspace")
        .arg(workspace_b.path())
        .output()
        .unwrap();
    // Stop the merge after the gate finishes mutating but before Rust can roll back.
    let pid = child.id().to_string();
    assert!(Command::new("kill")
        .args(["-STOP", &pid])
        .status()
        .unwrap()
        .success());
    fs::write(f.dir.path().join(".git/release"), "").unwrap();
    wait_for(&f.dir.path().join("leaked"));
    child.kill().unwrap();
    child.wait().unwrap();
    let out = Command::new(env!("CARGO_BIN_EXE_squad"))
        .args(["merge", "recover", "--repo"])
        .arg(f.dir.path())
        .arg("--workspace")
        .arg(workspace_b.path())
        .output()
        .unwrap();
    assert_eq!(overlap.status.code(), Some(4));
    assert!(String::from_utf8_lossy(&overlap.stdout).contains("locked"));
    assert!(out.status.success(), "{:?}", out);
    f.restored(b"base\n");
}
#[test]
fn harness_gate_and_invalid_config() {
    let f = Fixture::new(false);
    fs::create_dir_all(f.dir.path().join(".squad")).unwrap();
    fs::write(
        f.dir.path().join(".squad/harness.toml"),
        "version = 1\n[gates]\npost_merge = ['touch leaked; exit 9']\n",
    )
    .unwrap();
    let out = f.cmd().arg("--from-harness").output().unwrap();
    assert!(!out.status.success());
    assert!(String::from_utf8_lossy(&out.stdout).contains("rolled_back_verify_fail"));
    f.restored(b"base\n");
    fs::write(f.dir.path().join(".squad/harness.toml"), "invalid").unwrap();
    assert!(!f
        .cmd()
        .arg("--from-harness")
        .output()
        .unwrap()
        .status
        .success());
    f.restored(b"base\n");
}

#[test]
fn rollback_preserves_deletions_symlinks_and_modes() {
    use std::os::unix::fs::{symlink, PermissionsExt};
    let f = Fixture::new(false);
    let r = f.dir.path();
    fs::write(r.join("deleted"), "original").unwrap();
    fs::write(r.join("executable"), "script").unwrap();
    fs::set_permissions(r.join("executable"), fs::Permissions::from_mode(0o751)).unwrap();
    symlink("file", r.join("link")).unwrap();
    git(r, &["add", "deleted", "executable", "link"]);
    fs::remove_file(r.join("deleted")).unwrap();
    let index = fs::read(r.join(".git/index")).unwrap();
    let out = f.cmd().args(["--post-merge-gate", "echo resurrected > deleted; chmod 644 executable; rm link; echo regular > link; echo '*.ignored' > .git/info/exclude; touch leaked.ignored; exit 1"]).output().unwrap();
    assert!(!out.status.success());
    assert!(String::from_utf8_lossy(&out.stdout).contains("rolled_back_verify_fail"));
    assert_eq!(fs::read(r.join(".git/index")).unwrap(), index);
    assert!(!r.join("deleted").exists());
    assert!(r.join("leaked.ignored").exists());
    assert_eq!(fs::read_link(r.join("link")).unwrap(), Path::new("file"));
    assert_eq!(
        fs::metadata(r.join("executable"))
            .unwrap()
            .permissions()
            .mode()
            & 0o777,
        0o751
    );
}
#[test]
fn rollback_restores_absent_index() {
    let f = Fixture::new(false);
    let r = f.dir.path();
    fs::remove_file(r.join(".git/index")).unwrap();
    let out = f
        .cmd()
        .args(["--post-merge-gate", "touch leaked; exit 1"])
        .output()
        .unwrap();
    assert!(!out.status.success());
    assert!(String::from_utf8_lossy(&out.stdout).contains("rolled_back_verify_fail"));
    assert!(!r.join(".git/index").exists());
    assert_eq!(fs::read(r.join("file")).unwrap(), b"base\n");
    assert!(!r.join("new-file").exists());
    assert!(!r.join("leaked").exists());
}

#[test]
fn rollback_preserves_ignored_files() {
    for conflict in [true, false] {
        let f = Fixture::new(conflict);
        let r = f.dir.path();
        fs::write(r.join(".git/info/exclude"), ".env\ntarget/\n").unwrap();
        fs::write(r.join(".env"), "local settings").unwrap();
        fs::create_dir(r.join("target")).unwrap();
        fs::create_dir(r.join("empty")).unwrap();
        fs::write(r.join("target/keep.bin"), b"keep\0bytes").unwrap();
        let out = f
            .cmd()
            .args([
                "--post-merge-gate",
                "mkdir -p leaked/nested; touch leaked/nested/file empty/temporary; exit 1",
            ])
            .output()
            .unwrap();
        assert!(!out.status.success());
        let expected = if conflict {
            "rolled_back_conflict"
        } else {
            "rolled_back_verify_fail"
        };
        assert!(String::from_utf8_lossy(&out.stdout).contains(expected));
        assert_eq!(fs::read(r.join(".env")).unwrap(), b"local settings");
        assert_eq!(fs::read(r.join("target/keep.bin")).unwrap(), b"keep\0bytes");
        assert!(!r.join("leaked").exists());
        assert!(r.join("empty").is_dir());
        assert!(!r.join("empty/temporary").exists());
        f.restored(if conflict { b"local\n" } else { b"base\n" });
    }
}

#[test]
fn gate_rollback_restores_non_ignored_squad_files() {
    let f = Fixture::new(false);
    let r = f.dir.path();
    fs::create_dir(r.join(".squad")).unwrap();
    fs::write(r.join(".squad/note"), "original note").unwrap();
    let out = f
        .cmd()
        .args([
            "--post-merge-gate",
            "echo altered > .squad/note; touch .squad/leak; exit 1",
        ])
        .output()
        .unwrap();
    assert!(
        String::from_utf8_lossy(&out.stdout).contains("rolled_back_verify_fail"),
        "{out:?}"
    );
    assert_eq!(fs::read(r.join(".squad/note")).unwrap(), b"original note");
    assert!(!r.join(".squad/leak").exists());
    f.restored(b"base\n");
}

#[test]
fn rollback_preserves_ignored_paths_after_ignore_rules_change() {
    let f = Fixture::new(false);
    let r = f.dir.path();
    fs::write(r.join(".gitignore"), ".env\ntarget/\n").unwrap();
    git(r, &["add", ".gitignore"]);
    fs::write(r.join(".env"), "local settings").unwrap();
    fs::create_dir(r.join("target")).unwrap();
    fs::write(r.join("target/keep"), b"keep\0bytes").unwrap();
    let index = fs::read(r.join(".git/index")).unwrap();
    let out = f
        .cmd()
        .args(["--post-merge-gate", "rm .gitignore; exit 1"])
        .output()
        .unwrap();
    assert!(!out.status.success());
    assert!(String::from_utf8_lossy(&out.stdout).contains("rolled_back_verify_fail"));
    assert_eq!(fs::read(r.join(".gitignore")).unwrap(), b".env\ntarget/\n");
    assert_eq!(fs::read(r.join(".env")).unwrap(), b"local settings");
    assert_eq!(fs::read(r.join("target/keep")).unwrap(), b"keep\0bytes");
    assert_eq!(fs::read(r.join(".git/index")).unwrap(), index);
}
