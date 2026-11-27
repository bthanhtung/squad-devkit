//! Transactional working-tree merges; snapshots remain recoverable until verification succeeds.
use anyhow::{bail, Context, Result};
use fs2::FileExt;
use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeSet,
    fs,
    io::{Read, Seek, SeekFrom, Write},
    path::{Component, Path, PathBuf},
    process::{Command, Output, Stdio},
};

#[derive(Serialize, Deserialize)]
struct Snapshot {
    state: String,
    repo: PathBuf,
    created_at: String,
    tracked_list: Vec<PathBuf>,
    untracked_list: Vec<PathBuf>,
    #[serde(default)]
    ignored_paths: Vec<PathBuf>,
    existing: Vec<PathBuf>,
    missing: Vec<PathBuf>,
}
fn git(repo: &Path, args: &[&str], index: Option<&Path>) -> Result<Output> {
    let mut cmd = Command::new("git");
    cmd.current_dir(repo).args(args);
    if let Some(index) = index {
        cmd.env("GIT_INDEX_FILE", index);
    }
    Ok(cmd.output()?)
}
fn checked(repo: &Path, args: &[&str], index: Option<&Path>) -> Result<Vec<u8>> {
    let out = git(repo, args, index)?;
    if !out.status.success() {
        bail!(
            "git {}: {}",
            args.join(" "),
            String::from_utf8_lossy(&out.stderr)
        );
    }
    Ok(out.stdout)
}
fn paths(repo: &Path, args: &[&str]) -> Result<Vec<PathBuf>> {
    #[cfg(unix)]
    use std::os::unix::ffi::OsStrExt;
    checked(repo, args, None)?
        .split(|b| *b == 0)
        .filter(|s| !s.is_empty())
        .map(|s| {
            #[cfg(unix)]
            let p = PathBuf::from(std::ffi::OsStr::from_bytes(s));
            #[cfg(not(unix))]
            let p = PathBuf::from(std::str::from_utf8(s)?);
            if p.components().any(|c| !matches!(c, Component::Normal(_))) {
                bail!("unsafe git path");
            }
            Ok(p)
        })
        .filter(|p| match p {
            Ok(p) => !p.starts_with(".git") && !p.starts_with(".squad/merge-snapshots"),
            Err(_) => true,
        })
        .collect()
}
fn all_paths(repo: &Path) -> Result<BTreeSet<PathBuf>> {
    Ok(paths(
        repo,
        &[
            "ls-files",
            "-z",
            "--cached",
            "--others",
            "--exclude-standard",
        ],
    )?
    .into_iter()
    .collect())
}
fn remove(path: &Path) -> Result<()> {
    match fs::symlink_metadata(path) {
        Ok(m) if m.is_dir() => fs::remove_dir_all(path)?,
        Ok(_) => fs::remove_file(path)?,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => (),
        Err(e) => return Err(e.into()),
    }
    Ok(())
}
fn copy(source: &Path, dest: &Path) -> Result<()> {
    if let Some(parent) = dest.parent() {
        fs::create_dir_all(parent)?;
    }
    let meta = fs::symlink_metadata(source)?;
    if meta.is_symlink() {
        #[cfg(unix)]
        std::os::unix::fs::symlink(fs::read_link(source)?, dest)?;
        #[cfg(not(unix))]
        bail!("cannot snapshot symlink: {}", source.display());
    } else if meta.is_file() {
        fs::copy(source, dest)?;
    } else {
        bail!("unsupported snapshot entry: {}", source.display());
    }
    Ok(())
}
fn index_path(repo: &Path) -> Result<PathBuf> {
    let bytes = checked(repo, &["rev-parse", "--git-path", "index"], None)?;
    let path = PathBuf::from(String::from_utf8(bytes)?.trim());
    Ok(if path.is_absolute() {
        path
    } else {
        repo.join(path)
    })
}
fn snapshot_root(repo: &Path) -> Result<PathBuf> {
    let out = git(
        repo,
        &["rev-parse", "--path-format=absolute", "--git-common-dir"],
        None,
    )?;
    // Older Git may echo the unsupported option instead of failing.
    let bytes = if out.status.success() && !out.stdout.starts_with(b"--path-format=") {
        out.stdout
    } else {
        checked(repo, &["rev-parse", "--git-common-dir"], None)?
    };
    let path = PathBuf::from(String::from_utf8(bytes)?.trim());
    let common = if path.is_absolute() {
        path
    } else {
        repo.join(path)
    };
    Ok(common.canonicalize()?.join("squad-merge-snapshots"))
}
fn restore(dir: &Path, s: &Snapshot) -> Result<()> {
    for path in s
        .tracked_list
        .iter()
        .chain(&s.untracked_list)
        .chain(&s.ignored_paths)
        .chain(&s.existing)
        .chain(&s.missing)
    {
        if path.as_os_str().is_empty()
            || path
                .components()
                .any(|c| !matches!(c, Component::Normal(_)))
            || path.starts_with(".git")
            || path.starts_with(".squad/merge-snapshots")
        {
            bail!("unsafe snapshot path: {}", path.display());
        }
    }
    for path in s.tracked_list.iter().chain(&s.untracked_list) {
        let dest = s.repo.join(path);
        remove(&dest)?;
        if !s.missing.contains(path) {
            copy(&dir.join("files").join(path), &dest)?;
        }
    }
    let index = index_path(&s.repo)?;
    if dir.join("no_index").exists() {
        remove(&index)?;
    } else {
        fs::copy(dir.join("index"), index)?;
    }
    let existing: BTreeSet<_> = s.existing.iter().cloned().collect();
    for path in all_paths(&s.repo)?.difference(&existing) {
        if s.ignored_paths
            .iter()
            .any(|p| p.starts_with(path) || path.starts_with(p))
        {
            continue;
        }
        remove(&s.repo.join(path))?;
        let mut parent = path.parent();
        while let Some(dir) = parent.filter(|p| !p.as_os_str().is_empty()) {
            if existing
                .iter()
                .chain(&s.ignored_paths)
                .any(|p| p.starts_with(dir))
            {
                break;
            }
            match fs::remove_dir(s.repo.join(dir)) {
                Ok(()) => (),
                Err(e)
                    if matches!(
                        e.kind(),
                        std::io::ErrorKind::DirectoryNotEmpty | std::io::ErrorKind::NotFound
                    ) =>
                {
                    break
                }
                Err(e) => return Err(e.into()),
            }
            parent = dir.parent();
        }
    }
    Ok(())
}
fn recover(root: &Path, repo: &Path, prefix: &str) -> Result<()> {
    for entry in fs::read_dir(root)? {
        let dir = entry?.path();
        if !dir.is_dir() || !entry_name_matches(&dir, prefix) {
            continue;
        }
        if !dir.join("manifest.json").exists() {
            fs::remove_dir_all(dir)?;
            continue;
        }
        let s: Snapshot = serde_json::from_slice(&fs::read(dir.join("manifest.json"))?)?;
        if s.repo == repo {
            if s.state == "in_progress" {
                restore(&dir, &s).context("snapshot recovery failed; snapshot retained")?;
            }
            fs::remove_dir_all(dir)?;
        }
    }
    Ok(())
}
fn entry_name_matches(path: &Path, prefix: &str) -> bool {
    path.file_name()
        .and_then(|n| n.to_str())
        .is_some_and(|n| n.starts_with(prefix))
}
fn report(json: bool, state: &str, detail: serde_json::Value) {
    if json {
        println!(
            "{}",
            serde_json::json!({"merge_state":state,"details":detail})
        );
    } else {
        println!("merge_state={state}\n{detail}");
    }
}
fn tail(bytes: &[u8]) -> String {
    String::from_utf8_lossy(&bytes[bytes.len().saturating_sub(8192)..]).into_owned()
}

pub fn command(args: &[String]) -> Result<i32> {
    if args == ["--help"] || args.is_empty() {
        println!("squad merge apply --repo REPO --patch PATCH [--workspace WS] [--from-harness] [--post-merge-gate CMD]... [--json]\nsquad merge recover --repo REPO [--workspace WS] [--json]");
        return Ok(0);
    }
    let action = &args[0];
    if action != "apply" && action != "recover" {
        bail!("unknown merge action: {action}");
    }
    let (mut repo, mut patch) = (None, None);
    let (mut json, mut harness) = (false, false);
    let mut gates = Vec::new();
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--json" => json = true,
            "--from-harness" => harness = true,
            flag @ ("--repo" | "--patch" | "--workspace" | "--post-merge-gate") => {
                i += 1;
                let value = args
                    .get(i)
                    .with_context(|| format!("{flag} requires a value"))?
                    .clone();
                match flag {
                    "--repo" => repo = Some(PathBuf::from(value)),
                    "--patch" => patch = Some(PathBuf::from(value)),
                    "--workspace" => (), // Accepted for CLI compatibility; coordination is repository-scoped.
                    _ => gates.push(value),
                }
            }
            flag => bail!("unknown merge flag: {flag}"),
        }
        i += 1;
    }
    let repo = repo.context("--repo required")?.canonicalize()?;
    let top = checked(&repo, &["rev-parse", "--show-toplevel"], None)?;
    if Path::new(String::from_utf8(top)?.trim()).canonicalize()? != repo {
        bail!("--repo must be the repository root");
    }
    let patch = if action == "apply" {
        Some(patch.context("--patch required")?.canonicalize()?)
    } else {
        None
    };
    if harness {
        if let Some(config) = crate::harness_config::load_harness_config(&repo)? {
            gates.splice(0..0, config.gates.post_merge);
        }
    }
    let root = snapshot_root(&repo)?;
    fs::create_dir_all(&root)?;
    // Stable FNV-1a groups snapshots by target worktree within the common directory.
    let hash = repo
        .as_os_str()
        .as_encoded_bytes()
        .iter()
        .fold(0xcbf29ce484222325u64, |h, b| {
            (h ^ u64::from(*b)).wrapping_mul(0x100000001b3)
        });
    let lock = fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(root.join("merge.lock"))?;
    match lock.try_lock_exclusive() {
        Ok(()) => (),
        Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
            report(json, "locked", serde_json::json!({}));
            return Ok(4);
        }
        Err(e) => return Err(e.into()),
    }
    let prefix = format!("{hash:x}-");
    recover(&root, &repo, &prefix)?;
    let Some(patch) = patch else {
        report(json, "recovered", serde_json::json!({}));
        return Ok(0);
    };
    let dir = root.join(format!("{prefix}{}", uuid::Uuid::new_v4()));
    fs::create_dir(&dir)?;
    let mut s = Snapshot {
        state: "in_progress".into(),
        repo: repo.clone(),
        created_at: chrono::Utc::now().to_rfc3339(),
        tracked_list: paths(&repo, &["ls-files", "-z", "--cached"])?,
        untracked_list: paths(&repo, &["ls-files", "-z", "--others", "--exclude-standard"])?,
        ignored_paths: paths(
            &repo,
            &[
                "ls-files",
                "-z",
                "--others",
                "--ignored",
                "--exclude-standard",
            ],
        )?,
        existing: all_paths(&repo)?.into_iter().collect(),
        missing: Vec::new(),
    };
    s.existing.extend(paths(
        &repo,
        &[
            "ls-files",
            "-z",
            "--others",
            "--directory",
            "--exclude-standard",
        ],
    )?);
    s.tracked_list.sort();
    s.tracked_list.dedup();
    let index = index_path(&repo)?;
    if index.exists() {
        fs::copy(&index, dir.join("index"))?;
    } else {
        fs::write(dir.join("no_index"), "")?;
    }
    for path in s.tracked_list.iter().chain(&s.untracked_list) {
        match fs::symlink_metadata(repo.join(path)) {
            Ok(_) => copy(&repo.join(path), &dir.join("files").join(path))?,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => s.missing.push(path.clone()),
            Err(e) => return Err(e.into()),
        }
    }
    fs::write(dir.join("manifest.tmp"), serde_json::to_vec(&s)?)?;
    fs::rename(dir.join("manifest.tmp"), dir.join("manifest.json"))?;
    let result = (|| -> Result<(i32, &'static str, serde_json::Value)> {
        let temp_index = dir.join("apply.index");
        if index.exists() {
            fs::copy(&index, &temp_index)?;
        }
        let stage_paths = paths(
            &repo,
            &[
                "ls-files",
                "-z",
                "--cached",
                "--others",
                "--exclude-standard",
            ],
        )?;
        let mut stage = Command::new("git")
            .current_dir(&repo)
            .env("GIT_INDEX_FILE", &temp_index)
            .args(["update-index", "--add", "--remove", "-z", "--stdin"])
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .spawn()?;
        {
            let mut input = stage.stdin.take().context("missing git stdin")?;
            for path in stage_paths {
                input.write_all(path.as_os_str().as_encoded_bytes())?;
                input.write_all(&[0])?;
            }
        }
        let staged = stage.wait_with_output()?;
        if !staged.status.success() {
            bail!("temporary index update failed: {}", tail(&staged.stderr));
        }
        let out = git(
            &repo,
            &[
                "apply",
                "--3way",
                patch.to_str().context("patch path must be UTF-8")?,
            ],
            Some(&temp_index),
        )?;
        if !out.status.success() {
            let conflicts = paths_from_index(&repo, &temp_index)?;
            return Ok((
                1,
                "rolled_back_conflict",
                serde_json::json!({"conflicts":conflicts,"output_tail":tail(&out.stderr)}),
            ));
        }
        for gate in &gates {
            let log_path = dir.join("gate.log");
            let log = fs::File::create(&log_path)?;
            let status = Command::new("bash")
                .args(["-c", gate])
                .current_dir(&repo)
                .stdout(Stdio::from(log.try_clone()?))
                .stderr(Stdio::from(log))
                .status()?;
            if !status.success() {
                let mut log = fs::File::open(log_path)?;
                let len = log.metadata()?.len();
                log.seek(SeekFrom::Start(len.saturating_sub(8192)))?;
                let mut output = Vec::new();
                log.take(8192).read_to_end(&mut output)?;
                return Ok((
                    1,
                    "rolled_back_verify_fail",
                    serde_json::json!({"gate":gate,"exit_code":status.code(),"output_tail":tail(&output)}),
                ));
            }
        }
        Ok((0, "merged", serde_json::json!({})))
    })();
    if !matches!(&result, Ok((0, _, _))) {
        restore(&dir, &s).context("rollback failed; snapshot retained for recovery")?;
    }
    // Mark committed before cleanup so a cleanup error cannot cause later rollback.
    s.state = "complete".into();
    fs::write(dir.join("manifest.tmp"), serde_json::to_vec(&s)?)?;
    fs::rename(dir.join("manifest.tmp"), dir.join("manifest.json"))?;
    fs::remove_dir_all(&dir)?;
    let (code, state, detail) = result?;
    report(json, state, detail);
    Ok(code)
}
fn paths_from_index(repo: &Path, index: &Path) -> Result<Vec<String>> {
    let out = checked(
        repo,
        &["diff", "--name-only", "--diff-filter=U", "-z"],
        Some(index),
    )?;
    Ok(out
        .split(|b| *b == 0)
        .filter(|p| !p.is_empty())
        .map(|p| String::from_utf8_lossy(p).into_owned())
        .collect())
}
