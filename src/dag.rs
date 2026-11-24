//! Event-driven plan execution. Worker launch and merge remain the worker script's responsibility.
use crate::{plan::section, runs::RunRecord, store::Store};
use anyhow::{bail, ensure, Context, Result};
use rusqlite::{params, OptionalExtension};
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, HashSet},
    fs,
    io::Write,
    path::{Component, Path, PathBuf},
    process::{Command, Stdio},
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc, Arc,
    },
    time::Duration,
};

#[derive(Debug)]
pub struct Task {
    pub id: String,
    pub engine: String,
    pub tier: String,
    pub role: String,
    pub files: String,
    pub verify: Option<String>,
    pub dependencies: Vec<String>,
    pub hash: String,
}

fn identifier(value: &str) -> bool {
    value
        .as_bytes()
        .first()
        .is_some_and(u8::is_ascii_alphanumeric)
        && value
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || b"._-".contains(&c))
}

fn sha256(bytes: &[u8]) -> Result<String> {
    let mut child = Command::new("shasum")
        .args(["-a", "256"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .context("shasum is required for DAG hashes")?;
    child.stdin.take().context("hash stdin")?.write_all(bytes)?;
    let output = child.wait_with_output()?;
    ensure!(output.status.success(), "sha256 failed");
    let hash = String::from_utf8(output.stdout)?
        .split_whitespace()
        .next()
        .unwrap_or_default()
        .to_owned();
    ensure!(
        hash.len() == 64 && hash.bytes().all(|c| c.is_ascii_hexdigit()),
        "invalid sha256 output"
    );
    Ok(hash)
}

fn field<'a>(body: &'a str, label: &str) -> Option<&'a str> {
    body.split_once(label).map(|(_, value)| {
        value
            .split('\n')
            .next()
            .unwrap_or_default()
            .split(". Depends on:")
            .next()
            .unwrap_or_default()
            .split(". Verify:")
            .next()
            .unwrap_or_default()
            .trim()
            .trim_end_matches('.')
    })
}

pub fn parse_plan(text: &str) -> Result<Vec<Task>> {
    let section = section(text, "Tasks").context("Plan has no Tasks section")?;
    let mut entries: Vec<String> = vec![];
    for line in section.split_terminator('\n') {
        if line.starts_with("- ") || line.starts_with("### ") {
            entries.push(format!("{line}\n"));
        } else if let Some(entry) = entries.last_mut() {
            entry.push_str(line);
            entry.push('\n');
        }
    }
    ensure!(!entries.is_empty(), "Plan has no tasks");
    let mut ids = HashSet::new();
    let mut tasks = vec![];
    for entry in entries {
        let header = entry.lines().next().unwrap_or_default();
        let header = header
            .strip_prefix("- ")
            .or_else(|| header.strip_prefix("### "))
            .unwrap();
        let (id, rest) = header
            .split_once(" (")
            .context("Task requires engine, tier, and role")?;
        ensure!(
            identifier(id) && ids.insert(id.to_owned()),
            "Invalid or duplicate task ID: {id}"
        );
        let (config, title) = rest
            .split_once("): ")
            .context("Task requires engine, tier, and role")?;
        let (engine_tier, role) = config.split_once(", ").context("Task requires role")?;
        let (engine, tier) = engine_tier.split_once(' ').context("Task requires tier")?;
        ensure!(
            identifier(engine)
                && identifier(role)
                && !title.is_empty()
                && matches!(tier, "fast" | "balanced" | "strong"),
            "Invalid engine, tier, role or title for {id}"
        );
        let files = field(&entry, "Files: ").unwrap_or_default().to_owned();
        ensure!(
            !files.is_empty() || role == "reviewer",
            "Task {id} requires Files"
        );
        let deps = field(&entry, "Depends on: ").context("Task requires Depends on")?;
        let dependencies: Vec<_> = if deps == "none" {
            vec![]
        } else {
            deps.split([',', ' '])
                .filter(|s| !s.is_empty())
                .map(str::to_owned)
                .collect()
        };
        ensure!(
            deps == "none" || !dependencies.is_empty(),
            "Empty dependencies"
        );
        let verify = if let Some((_, value)) = entry.split_once("Verify:") {
            let value = value
                .trim_start()
                .strip_prefix('`')
                .context("invalid Verify syntax")?;
            let (command, _) = value.split_once('`').context("invalid Verify syntax")?;
            ensure!(
                !command.is_empty() && !command.contains('\n'),
                "invalid Verify syntax"
            );
            Some(command.to_owned())
        } else {
            None
        };
        // Shell command substitution strips trailing newlines, then the pipe adds exactly one.
        let hash = sha256(format!("{}\n", entry.trim_end_matches('\n')).as_bytes())?;
        tasks.push(Task {
            id: id.into(),
            engine: engine.into(),
            tier: tier.into(),
            role: role.into(),
            files,
            verify,
            dependencies,
            hash,
        });
    }
    let mut visited = HashSet::new();
    loop {
        let before = visited.len();
        for task in &tasks {
            for dep in &task.dependencies {
                ensure!(ids.contains(dep), "Unknown dependency: {dep}");
            }
            if task.dependencies.iter().all(|d| visited.contains(d)) {
                visited.insert(task.id.clone());
            }
        }
        if visited.len() == tasks.len() {
            break;
        }
        ensure!(visited.len() != before, "Dependency cycle");
    }
    Ok(tasks)
}

fn workspace() -> Result<PathBuf> {
    let mut path = std::env::var_os("SQUAD_DEVKIT_WORKSPACE")
        .map(PathBuf::from)
        .unwrap_or(std::env::current_dir()?);
    while !path.join(".squad").is_dir() {
        ensure!(path.pop(), "No .squad workspace found");
    }
    Ok(fs::canonicalize(path)?)
}

struct Options {
    plan: PathBuf,
    manager: String,
    jobs: usize,
    cap: usize,
    retries: HashSet<String>,
    dry: bool,
    merge: bool,
    fail_fast: bool,
    artifacts: bool,
    launcher: PathBuf,
}
impl Options {
    fn parse(args: &[String]) -> Result<Self> {
        let mut result = Self {
            plan: PathBuf::new(),
            manager: std::env::var("SQUAD_MANAGER_ID").unwrap_or_default(),
            jobs: 3,
            cap: usize::MAX,
            retries: HashSet::new(),
            dry: false,
            merge: false,
            fail_fast: false,
            artifacts: false,
            launcher: std::env::var_os("SQUAD_DAG_LAUNCHER")
                .map(PathBuf::from)
                .unwrap_or_else(|| PathBuf::from("squad-worker")),
        };
        let mut args = args.iter();
        while let Some(arg) = args.next() {
            match arg.as_str() {
                "--dry-run" => result.dry = true,
                "--merge-if-green" => result.merge = true,
                "--plan" | "--run-plan" | "--manager" | "--jobs" | "--max-launches" | "--retry"
                | "--on-failure" | "--dep-mode" => {
                    let value = args
                        .next()
                        .with_context(|| format!("Missing value for {arg}"))?;
                    match arg.as_str() {
                        "--plan" | "--run-plan" => result.plan = value.into(),
                        "--manager" => result.manager = value.clone(),
                        "--jobs" => result.jobs = value.parse()?,
                        "--max-launches" => result.cap = value.parse()?,
                        "--retry" => {
                            ensure!(identifier(value), "Invalid retry task ID");
                            result.retries.insert(value.clone());
                        }
                        "--on-failure" => {
                            ensure!(
                                matches!(value.as_str(), "stop-dependents" | "fail-fast"),
                                "Invalid failure policy"
                            );
                            result.fail_fast = value == "fail-fast";
                        }
                        "--dep-mode" => {
                            ensure!(
                                matches!(value.as_str(), "merged" | "artifact-ready"),
                                "Invalid dependency mode"
                            );
                            result.artifacts = value == "artifact-ready";
                        }
                        _ => unreachable!(),
                    }
                }
                value if !value.starts_with('-') && result.plan.as_os_str().is_empty() => {
                    result.plan = value.into()
                }
                _ => bail!("Invalid run-plan option: {arg}"),
            }
        }
        ensure!(
            identifier(&result.manager) && result.jobs > 0 && result.cap > 0,
            "run-plan requires --manager and positive --jobs/--max-launches"
        );
        result.plan = fs::canonicalize(&result.plan)?;
        if result.launcher.components().count() > 1 {
            result.launcher = fs::canonicalize(&result.launcher)?;
        }
        Ok(result)
    }
}

struct Lease<'a> {
    store: &'a Store,
    plan: String,
    owner: String,
    stop: mpsc::Sender<()>,
    heartbeat: Option<std::thread::JoinHandle<()>>,
    lost: Arc<AtomicBool>,
}
impl Drop for Lease<'_> {
    fn drop(&mut self) {
        let _ = self.stop.send(());
        if let Some(thread) = self.heartbeat.take() {
            let _ = thread.join();
        }
        let _ = self.store.release_dag(&self.plan, &self.owner);
    }
}

fn value<'a>(run: &'a RunRecord, key: &str) -> &'a str {
    run.details.get(key).map(String::as_str).unwrap_or_default()
}

pub fn command(args: &[String]) -> Result<i32> {
    let options = match Options::parse(args) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("{e:#}");
            return Ok(2);
        }
    };
    let tasks = match parse_plan(&fs::read_to_string(&options.plan)?) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("{e:#}");
            return Ok(2);
        }
    };
    for retry in &options.retries {
        if !tasks.iter().any(|t| &t.id == retry) {
            eprintln!("Unknown retry task: {retry}");
            return Ok(2);
        }
    }
    let root = workspace()?;
    let store = Store::open(&root.join(".squad/messages.db"))?;
    let plan = options.plan.to_string_lossy().into_owned();
    let owner = uuid::Uuid::new_v4().to_string();
    if !store.claim_dag(&plan, &owner, chrono::Utc::now().timestamp(), 30)? {
        eprintln!("Another runner holds the plan lease");
        return Ok(3);
    }
    let heartbeat_store = Store::open(&root.join(".squad/messages.db"))?;
    let (stop, receiver) = mpsc::channel();
    let lost = Arc::new(AtomicBool::new(false));
    let heartbeat_lost = lost.clone();
    let heartbeat_plan = plan.clone();
    let heartbeat_owner = owner.clone();
    // Merges may run long verification commands; renew independently of their duration.
    let heartbeat = std::thread::spawn(move || {
        while matches!(
            receiver.recv_timeout(Duration::from_secs(5)),
            Err(mpsc::RecvTimeoutError::Timeout)
        ) {
            if !heartbeat_store
                .heartbeat_dag(
                    &heartbeat_plan,
                    &heartbeat_owner,
                    chrono::Utc::now().timestamp(),
                    30,
                )
                .unwrap_or(false)
            {
                heartbeat_lost.store(true, Ordering::SeqCst);
                break;
            }
        }
    });
    let lease = Lease {
        store: &store,
        plan,
        owner,
        stop,
        heartbeat: Some(heartbeat),
        lost,
    };
    schedule(&options, &tasks, &root, &lease)
}

fn schedule(options: &Options, tasks: &[Task], root: &Path, lease: &Lease<'_>) -> Result<i32> {
    let store = lease.store;
    let directory = root.join(".squad/workers");
    let (tx, rx) = mpsc::channel();
    let mut running = HashSet::new();
    let mut launched = HashSet::new();
    let mut exited = BTreeMap::new();
    let mut attempts = BTreeMap::new();
    let mut total = 0;
    let mut stop = false;
    let artifact_root = root
        .join(".squad/artifacts")
        .join(sha256(&fs::read(&options.plan)?)?);
    let mut ready_artifacts = HashSet::new();
    let mut previous_states = BTreeMap::new();
    loop {
        ensure!(!lease.lost.load(Ordering::SeqCst), "DAG lease lost");
        ensure!(
            store.heartbeat_dag(
                &lease.plan,
                &lease.owner,
                chrono::Utc::now().timestamp(),
                30
            )?,
            "DAG lease lost"
        );
        store.sync_runs(root, &directory)?;
        let runs = store.list_runs(root, Some(&directory))?;
        let mut states = BTreeMap::new();
        let mut external_active = 0;
        for task in tasks {
            let run = runs
                .iter()
                .find(|r| value(r, "plan") == lease.plan && value(r, "plan_task") == task.id);
            let node: Option<(String, String, String)> = store
                .conn
                .query_row(
                    "SELECT task_hash,attempt,state FROM dag_nodes WHERE plan=?1 AND task_id=?2",
                    params![lease.plan, task.id],
                    |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
                )
                .optional()?;
            if run.is_some_and(|r| r.state == "running")
                && !running.contains(&task.id)
                && node.as_ref().is_none_or(|n| n.2 != "lost")
            {
                external_active += 1;
            }
            let mut state = "ready".to_owned();
            if let Some(run) = run {
                state = if run.state == "running" {
                    "running"
                } else if value(run, "plan_task_sha256") != task.hash {
                    "changed"
                } else if matches!(run.state.as_str(), "failed" | "lost" | "stopped")
                    || matches!(value(run, "verify"), "fail" | "timeout")
                {
                    "failed"
                } else if !value(run, "merged").is_empty() {
                    "done"
                } else if matches!(run.state.as_str(), "done" | "completed") {
                    "blocked by manager"
                } else {
                    "failed"
                }
                .into();
            } else if let Some((hash, _, _)) = &node {
                state = if hash != &task.hash {
                    "changed"
                } else {
                    "failed"
                }
                .into();
            }
            if node.as_ref().is_some_and(|n| n.2 == "lost") && state == "running" {
                state = "failed".into();
            }
            if let (Some(run), Some((_, attempt, _))) = (run, &node) {
                if !value(run, "dag_attempt").is_empty()
                    && value(run, "dag_attempt") != attempt
                    && state != "changed"
                {
                    state = "failed".into();
                }
            }
            if launched.contains(&task.id)
                && !running.contains(&task.id)
                && run.is_none_or(|r| value(r, "dag_attempt") != attempts[&task.id])
            {
                state = "failed".into();
            }
            if options.retries.contains(&task.id)
                && !launched.contains(&task.id)
                && state != "running"
            {
                state = "ready".into();
            }
            if running.contains(&task.id) {
                state = "running".into();
            }
            if exited.get(&task.id).is_some_and(|success| !success) {
                state = "failed".into();
            }
            if launched.contains(&task.id) && !running.contains(&task.id) && state == "ready" {
                state = "failed".into();
            }
            if state == "changed" {
                println!(
                    "task {} changed since its run; relaunch with --retry {}",
                    task.id, task.id
                );
            }
            if options.artifacts && !matches!(state.as_str(), "failed" | "changed" | "ready") {
                let attempt = attempts
                    .get(&task.id)
                    .map(String::as_str)
                    .or_else(|| node.as_ref().map(|n| n.1.as_str()))
                    .or_else(|| run.map(|r| r.run_name.as_str()));
                if let Some(attempt) = attempt {
                    let key = (task.id.clone(), attempt.to_owned());
                    if node
                        .as_ref()
                        .is_none_or(|n| !matches!(n.2.as_str(), "failed" | "lost"))
                        && (ready_artifacts.contains(&key)
                            || artifact_ready(&artifact_root.join(&task.id), &task.id, attempt)?)
                    {
                        ready_artifacts.insert(key);
                        state = "done".into();
                    }
                }
            }
            if state == "blocked by manager" && options.merge && !options.dry {
                let run = run.unwrap();
                if value(run, "verify") == "pass" {
                    if runs
                        .iter()
                        .find(|r| r.worker_id == task.id)
                        .is_none_or(|r| r.run_name != run.run_name)
                    {
                        println!(
                            "Waiting on manager: {} has a newer run in another plan",
                            task.id
                        );
                        state = "failed".into();
                    } else if Command::new(&options.launcher)
                        .args(["--merge", &task.id])
                        .current_dir(root)
                        .status()?
                        .success()
                    {
                        // The next event pass reads the authoritative merge result.
                        store.sync_runs(root, &directory)?;
                        let updated = store.list_runs(root, Some(&directory))?;
                        if updated
                            .iter()
                            .any(|r| r.run_name == run.run_name && !value(r, "merged").is_empty())
                        {
                            state = "done".into();
                        }
                    } else {
                        println!("Waiting on manager: {} and its dependents", task.id);
                        state = "failed".into();
                    }
                }
            }
            if options.fail_fast && matches!(state.as_str(), "failed" | "changed") {
                stop = true;
            }
            states.insert(task.id.clone(), state);
        }
        let complete = states.values().all(|s| s == "done");
        for task in tasks {
            if states[&task.id] == "ready" {
                if let Some(dep) = task.dependencies.iter().find(|d| states[*d] != "done") {
                    states.insert(task.id.clone(), format!("blocked by {dep}"));
                }
            }
        }
        if states != previous_states {
            println!("ID / STATE / ENGINE TIER");
            for task in tasks {
                println!(
                    "{} / {} / {} {}",
                    task.id, states[&task.id], task.engine, task.tier
                );
            }
            previous_states = states.clone();
        }
        if options.dry {
            return Ok(if complete { 0 } else { 3 });
        }
        for task in tasks {
            if stop || running.len() + external_active >= options.jobs || total >= options.cap {
                break;
            }
            if states[&task.id] != "ready" || launched.contains(&task.id) {
                continue;
            }
            // Refuse a plan edited after validation, including between scheduling events.
            let current = parse_plan(&fs::read_to_string(&options.plan)?)?;
            ensure!(
                current
                    .iter()
                    .any(|t| t.id == task.id && t.hash == task.hash),
                "task {} changed before launch",
                task.id
            );
            let attempt = uuid::Uuid::new_v4().to_string();
            store.write_dag_node(
                &lease.plan,
                &task.id,
                &task.hash,
                &attempt,
                "running",
                &lease.owner,
            )?;
            let mut command = Command::new(&options.launcher);
            command
                .current_dir(root)
                .arg(&task.id)
                .args([
                    "--task",
                    &task.id,
                    "--plan-task",
                    &task.id,
                    "--plan",
                    &lease.plan,
                    "--manager",
                    &options.manager,
                    "--engine",
                    &task.engine,
                    "--model-tier",
                    &task.tier,
                    "--role",
                    &task.role,
                ])
                .env("SQUAD_DAG_WORKSPACE", root)
                .env("SQUAD_DAG_ATTEMPT", &attempt)
                .env("SQUAD_DAG_PLAN", &options.plan)
                .env("SQUAD_DAG_TASK", &task.id);
            if !task.files.is_empty() {
                command.args(["--own", &task.files]);
            }
            if let Some(verify) = &task.verify {
                command.args(["--verify", verify]);
            }
            let mut child = command.spawn().context("launch DAG worker")?;
            let sender = tx.clone();
            let id = task.id.clone();
            std::thread::spawn(move || {
                let result = child.wait().map(|s| s.success()).unwrap_or(false);
                let _ = sender.send((id, result));
            });
            running.insert(task.id.clone());
            launched.insert(task.id.clone());
            attempts.insert(task.id.clone(), attempt);
            total += 1;
        }
        if running.is_empty() {
            return Ok(if complete { 0 } else { 3 });
        }
        // A timeout renews the lease and observes artifacts published before producer exit.
        match rx.recv_timeout(Duration::from_secs(1)) {
            Ok((id, success)) => {
                running.remove(&id);
                exited.insert(id.clone(), success);
                let task = tasks.iter().find(|t| t.id == id).unwrap();
                store.write_dag_node(
                    &lease.plan,
                    &id,
                    &task.hash,
                    &attempts[&id],
                    if success { "completed" } else { "failed" },
                    &lease.owner,
                )?;
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(e) => return Err(e.into()),
        }
    }
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ArtifactFile {
    pub path: String,
    pub sha256: String,
}
#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ArtifactManifest {
    pub producer_task: String,
    pub producer_attempt: String,
    pub files: Vec<ArtifactFile>,
    pub created_at: i64,
}

fn relative(path: &Path) -> Result<()> {
    ensure!(
        !path.as_os_str().is_empty()
            && path.components().all(|c| matches!(c, Component::Normal(_))),
        "artifact path must be relative without traversal: {}",
        path.display()
    );
    Ok(())
}

// Reject symlink ancestors as well as leaf files.
fn no_symlinks(path: &Path) -> Result<()> {
    let mut parent = PathBuf::new();
    for component in path.components() {
        parent.push(component);
        match fs::symlink_metadata(&parent) {
            Ok(metadata) => ensure!(
                !metadata.file_type().is_symlink(),
                "artifact symlink rejected: {}",
                parent.display()
            ),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(e.into()),
        }
    }
    Ok(())
}

fn artifact_dir(root: &Path, plan: &Path, task: &str) -> Result<PathBuf> {
    ensure!(identifier(task), "Invalid producer task");
    ensure!(
        parse_plan(&fs::read_to_string(plan)?)?
            .iter()
            .any(|t| t.id == task),
        "Unknown producer task"
    );
    let path = fs::canonicalize(root)?
        .join(".squad/artifacts")
        .join(sha256(&fs::read(plan)?)?)
        .join(task);
    no_symlinks(&path)?;
    Ok(path)
}

fn read_manifest(directory: &Path) -> Result<ArtifactManifest> {
    no_symlinks(&directory.join("manifest.json"))?;
    let manifest: ArtifactManifest =
        serde_json::from_slice(&fs::read(directory.join("manifest.json"))?)?;
    ensure!(
        identifier(&manifest.producer_task)
            && identifier(&manifest.producer_attempt)
            && !manifest.files.is_empty(),
        "Invalid artifact manifest"
    );
    let mut paths = HashSet::new();
    for file in &manifest.files {
        relative(Path::new(&file.path))?;
        ensure!(paths.insert(&file.path), "Duplicate artifact path");
        let source = directory.join(&manifest.producer_attempt).join(&file.path);
        no_symlinks(&source)?;
        ensure!(
            fs::metadata(&source)?.is_file() && sha256(&fs::read(&source)?)? == file.sha256,
            "Artifact digest mismatch: {}",
            file.path
        );
    }
    Ok(manifest)
}

fn validate_attempt(root: &Path, plan: &Path, task: &str, attempt: &str) -> Result<()> {
    let db = root.join(".squad/messages.db");
    if !db.exists() {
        return Ok(());
    }
    let store = Store::open(&db)?;
    let plan = fs::canonicalize(plan)?;
    let node: Option<(String, String, i64)> = store
        .conn
        .query_row(
            "SELECT attempt,state,lease_expires_at FROM dag_nodes WHERE plan=?1 AND task_id=?2",
            params![plan.to_string_lossy(), task],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .optional()?;
    if let Some((current, state, expires)) = node {
        ensure!(
            current == attempt
                && !matches!(state.as_str(), "failed" | "lost")
                && (state != "running" || expires > chrono::Utc::now().timestamp()),
            "Artifact producer attempt is stale or failed"
        );
    }
    Ok(())
}

fn artifact_ready(directory: &Path, task: &str, attempt: &str) -> Result<bool> {
    if !directory.join("manifest.json").exists() {
        return Ok(false);
    }
    let manifest = read_manifest(directory)?;
    Ok(manifest.producer_task == task && manifest.producer_attempt == attempt)
}

pub fn publish_artifact(
    root: &Path,
    plan: &Path,
    task: &str,
    attempt: &str,
    source: &Path,
    files: &[String],
) -> Result<()> {
    ensure!(
        identifier(attempt) && attempt != "manifest.json" && !files.is_empty(),
        "publish requires an attempt and files"
    );
    let source = fs::canonicalize(source)?;
    validate_attempt(root, plan, task, attempt)?;
    let directory = artifact_dir(root, plan, task)?;
    fs::create_dir_all(&directory)?;
    let target = directory.join(attempt);
    ensure!(!target.exists(), "Producer attempt already published");
    let stage = directory.join(format!(".{}", uuid::Uuid::new_v4()));
    fs::create_dir(&stage)?;
    let result = (|| -> Result<()> {
        let mut manifest = ArtifactManifest {
            producer_task: task.into(),
            producer_attempt: attempt.into(),
            files: vec![],
            created_at: chrono::Utc::now().timestamp(),
        };
        let mut seen = HashSet::new();
        for file in files {
            relative(Path::new(file))?;
            ensure!(seen.insert(file), "Duplicate artifact path");
            let input = source.join(file);
            no_symlinks(&input)?;
            ensure!(
                fs::metadata(&input)?.is_file(),
                "Artifact must be a regular file"
            );
            let bytes = fs::read(input)?;
            let output = stage.join(file);
            fs::create_dir_all(output.parent().context("artifact parent")?)?;
            fs::write(&output, &bytes)?;
            let mut permissions = fs::metadata(&output)?.permissions();
            permissions.set_readonly(true);
            fs::set_permissions(&output, permissions)?;
            manifest.files.push(ArtifactFile {
                path: file.clone(),
                sha256: sha256(&bytes)?,
            });
        }
        validate_attempt(root, plan, task, attempt)?;
        fs::rename(&stage, &target)?;
        let temp = directory.join(format!(".manifest-{}", uuid::Uuid::new_v4()));
        fs::write(&temp, serde_json::to_vec_pretty(&manifest)?)?;
        fs::rename(temp, directory.join("manifest.json"))?;
        Ok(())
    })();
    if stage.exists() {
        let _ = fs::remove_dir_all(stage);
    }
    result
}

pub fn fetch_artifact(root: &Path, plan: &Path, task: &str, destination: &Path) -> Result<()> {
    let directory = artifact_dir(root, plan, task)?;
    let manifest = read_manifest(&directory)?;
    ensure!(manifest.producer_task == task, "Artifact producer mismatch");
    validate_attempt(root, plan, task, &manifest.producer_attempt)?;
    let destination = std::path::absolute(destination)?;
    no_symlinks(&destination)?;
    // Replace only an empty directory; never overwrite consumer files.
    ensure!(
        !destination.exists()
            || (destination.is_dir() && fs::read_dir(&destination)?.next().is_none()),
        "Artifact destination must be absent or empty"
    );
    fs::create_dir_all(destination.parent().context("destination parent")?)?;
    let stage = destination.with_file_name(format!(".artifact-{}", uuid::Uuid::new_v4()));
    fs::create_dir(&stage)?;
    let result = (|| -> Result<()> {
        for file in &manifest.files {
            let output = stage.join(&file.path);
            fs::create_dir_all(output.parent().context("artifact parent")?)?;
            let bytes = fs::read(directory.join(&manifest.producer_attempt).join(&file.path))?;
            ensure!(
                sha256(&bytes)? == file.sha256,
                "Artifact changed during fetch"
            );
            fs::write(&output, bytes)?;
            let mut permissions = fs::metadata(&output)?.permissions();
            permissions.set_readonly(true);
            fs::set_permissions(output, permissions)?;
        }
        readonly_directories(&stage)?;
        if destination.exists() {
            fs::remove_dir(&destination)?;
        }
        fs::rename(&stage, &destination)?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_dir_all(&stage);
    }
    result
}

fn readonly_directories(path: &Path) -> Result<()> {
    for entry in fs::read_dir(path)? {
        let path = entry?.path();
        if path.is_dir() {
            readonly_directories(&path)?;
        }
    }
    let mut permissions = fs::metadata(path)?.permissions();
    permissions.set_readonly(true);
    fs::set_permissions(path, permissions)?;
    Ok(())
}

pub fn artifact_command(args: &[String]) -> Result<()> {
    let (action, args) = args
        .split_first()
        .context("Usage: squad artifact publish|fetch --plan P")?;
    ensure!(
        matches!(action.as_str(), "publish" | "fetch"),
        "Unknown artifact command"
    );
    let mut plan = std::env::var_os("SQUAD_DAG_PLAN").map(PathBuf::from);
    let mut task = std::env::var("SQUAD_DAG_TASK").ok();
    let mut attempt = std::env::var("SQUAD_DAG_ATTEMPT").ok();
    let mut source = std::env::current_dir()?;
    let mut destination = None;
    let mut files = vec![];
    let mut args = args.iter();
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--plan" | "--task" | "--from" | "--attempt" | "--root" | "--dest" => {
                let v = args
                    .next()
                    .with_context(|| format!("Missing value for {arg}"))?;
                match arg.as_str() {
                    "--plan" => plan = Some(v.into()),
                    "--task" | "--from" => task = Some(v.clone()),
                    "--attempt" => attempt = Some(v.clone()),
                    "--root" => source = v.into(),
                    "--dest" => destination = Some(PathBuf::from(v)),
                    _ => unreachable!(),
                }
            }
            "--" => {
                files.extend(args.cloned());
                break;
            }
            v if !v.starts_with('-') => files.push(v.to_owned()),
            _ => bail!("Unknown artifact option: {arg}"),
        }
    }
    let root = match std::env::var_os("SQUAD_DAG_WORKSPACE") {
        Some(path) => fs::canonicalize(path)?,
        None => workspace()?,
    };
    ensure!(
        root.join(".squad").is_dir(),
        "No .squad artifact workspace found"
    );
    let plan = fs::canonicalize(plan.context("--plan is required")?)?;
    let task = task.context("--task/--from is required")?;
    if action == "publish" {
        ensure!(destination.is_none(), "--dest is only valid for fetch");
        publish_artifact(
            &root,
            &plan,
            &task,
            &attempt.context("--attempt is required")?,
            &source,
            &files,
        )
    } else {
        ensure!(files.is_empty(), "fetch does not accept file arguments");
        fetch_artifact(
            &root,
            &plan,
            &task,
            &destination.context("--dest is required")?,
        )
    }
}
