//! Additive worker-run index. Legacy status files remain the recovery source.
use crate::store::Store;
use anyhow::{bail, Context, Result};
use rusqlite::params;
use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeMap,
    fs,
    io::{BufRead, BufReader},
    path::{Path, PathBuf},
};

#[derive(Debug, Serialize, Deserialize)]
pub struct RunRecord {
    pub run_name: String,
    pub worker_id: String,
    pub engine: String,
    pub state: String,
    pub verdict: Option<String>,
    pub tokens_in: Option<i64>,
    pub tokens_cached: Option<i64>,
    pub tokens_out: Option<i64>,
    pub worktree: Option<String>,
    pub status_file: String,
    pub details: BTreeMap<String, String>,
    pub metrics: Option<RunMetrics>,
}

#[derive(Debug, Serialize, Deserialize, Default)]
pub struct RunMetrics {
    pub calls: usize,
    pub tokens_in: Option<i64>,
    pub tokens_out: Option<i64>,
}

// Preserve the dashboard's live log metrics without a jq subprocess per run.
fn log_metrics(run: &RunRecord) -> Option<RunMetrics> {
    let file = fs::File::open(run.details.get("log")?).ok()?;
    let codex = !matches!(
        run.engine.as_str(),
        "claude" | "ccr" | "agy" | "grok" | "opencode"
    );
    let claude = !matches!(run.engine.as_str(), "codex" | "grok" | "opencode");
    let agy = !matches!(
        run.engine.as_str(),
        "codex" | "claude" | "ccr" | "grok" | "opencode"
    );
    let mut metrics = RunMetrics::default();
    for line in BufReader::new(file).lines() {
        let line = line.ok()?;
        let Ok(event) = serde_json::from_str::<serde_json::Value>(&line) else {
            continue;
        };
        if codex
            && event["type"] == "item.completed"
            && matches!(
                event["item"]["type"].as_str(),
                Some("command_execution" | "mcp_tool_call")
            )
        {
            metrics.calls += 1;
        }
        if claude && event["type"] == "assistant" {
            metrics.calls += event["message"]["content"]
                .as_array()
                .map(|content| {
                    content
                        .iter()
                        .filter(|item| item["type"] == "tool_use")
                        .count()
                })
                .unwrap_or_default();
        }
        if agy
            && event["event"] == "step_update"
            && event["step_update"]["step_type"] == "tool"
            && event["step_update"]["state"] == "DONE"
        {
            metrics.calls += 1;
        }
        let usage = if (codex && event["type"] == "turn.completed")
            || (claude && event["type"] == "result" && !event["usage"].is_null())
        {
            Some(&event["usage"])
        } else if agy && event["event"] == "result" && !event["result"]["usage"].is_null() {
            Some(&event["result"]["usage"])
        } else {
            None
        };
        if let Some(usage) = usage {
            let input = [
                "input_tokens",
                "cache_read_input_tokens",
                "cache_creation_input_tokens",
                "cache_read_tokens",
            ]
            .iter()
            .fold(0_i64, |sum, key| {
                sum.saturating_add(usage[key].as_i64().unwrap_or_default().max(0))
            });
            metrics.tokens_in = Some(metrics.tokens_in.unwrap_or_default().saturating_add(input));
            metrics.tokens_out = Some(
                metrics
                    .tokens_out
                    .unwrap_or_default()
                    .saturating_add(usage["output_tokens"].as_i64().unwrap_or_default().max(0)),
            );
        }
    }
    Some(metrics)
}

fn numeric(details: &BTreeMap<String, String>, key: &str) -> Result<Option<i64>> {
    match details.get(key).filter(|v| !v.is_empty()) {
        None => Ok(None),
        Some(value) => {
            let n: i64 = value.parse().with_context(|| format!("invalid {key}"))?;
            if n < 0 {
                bail!("invalid {key}");
            }
            Ok(Some(n))
        }
    }
}
fn fingerprint(path: &Path) -> Result<(String, u64)> {
    let meta = path.metadata()?;
    Ok((
        format!(
            "{:039}",
            meta.modified()?
                .duration_since(std::time::UNIX_EPOCH)?
                .as_nanos()
        ),
        meta.len(),
    ))
}
fn read_status(path: &Path) -> Result<RunRecord> {
    let mut details = BTreeMap::new();
    for line in fs::read_to_string(path)?.lines() {
        if let Some((key, value)) = line.split_once('=') {
            details.insert(key.to_owned(), value.to_owned());
        }
    }
    for key in ["worker", "engine", "state"] {
        if details.get(key).is_none_or(|v| v.is_empty()) {
            bail!("status missing {key}: {}", path.display());
        }
    }
    if !["running", "completed", "failed", "stopped", "lost"].contains(&details["state"].as_str()) {
        bail!("invalid run state");
    }
    for key in ["started", "finished", "pid"] {
        if let Some(value) = numeric(&details, key)? {
            details.insert(key.to_owned(), value.to_string());
        }
    }
    Ok(RunRecord {
        run_name: path
            .file_stem()
            .context("status file requires a name")?
            .to_string_lossy()
            .into_owned(),
        worker_id: details["worker"].clone(),
        engine: details["engine"].clone(),
        state: details["state"].clone(),
        verdict: details.get("verdict").filter(|v| !v.is_empty()).cloned(),
        tokens_in: numeric(&details, "tokens_in")?,
        tokens_cached: numeric(&details, "tokens_cached")?,
        tokens_out: numeric(&details, "tokens_out")?,
        worktree: details.get("worktree").filter(|v| !v.is_empty()).cloned(),
        status_file: path.to_string_lossy().into_owned(),
        details,
        metrics: None,
    })
}
impl Store {
    pub fn record_run(&self, workspace: &Path, status_file: &Path) -> Result<()> {
        let path = fs::canonicalize(status_file)?;
        let (mtime, size) = fingerprint(&path)?;
        let run = read_status(&path)?;
        self.conn.execute("INSERT INTO worker_runs
            (workspace, run_name, worker_id, engine, state, verdict, tokens_in, tokens_cached, tokens_out, worktree, status_file, status_mtime, status_size, details)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)
            ON CONFLICT(workspace, run_name) DO UPDATE SET
              worker_id=excluded.worker_id, engine=excluded.engine, state=excluded.state,
              verdict=excluded.verdict, tokens_in=excluded.tokens_in, tokens_cached=excluded.tokens_cached,
              tokens_out=excluded.tokens_out, worktree=excluded.worktree, status_file=excluded.status_file,
              status_mtime=excluded.status_mtime, status_size=excluded.status_size, details=excluded.details
              WHERE excluded.status_mtime >= worker_runs.status_mtime",
            params![workspace.to_string_lossy(), run.run_name, run.worker_id, run.engine, run.state, run.verdict, run.tokens_in, run.tokens_cached, run.tokens_out, run.worktree, run.status_file, mtime, size, serde_json::to_string(&run.details)?])?;
        Ok(())
    }
    /// Import changed legacy files in one process, retaining historical database-only runs.
    pub fn sync_runs(&self, workspace: &Path, directory: &Path) -> Result<()> {
        if !directory.is_dir() {
            return Ok(());
        }
        let mut stmt = self.conn.prepare(
            "SELECT status_file, status_mtime, status_size FROM worker_runs WHERE workspace=?1",
        )?;
        let known: BTreeMap<String, (String, u64)> = stmt
            .query_map([workspace.to_string_lossy()], |r| {
                Ok((r.get(0)?, (r.get(1)?, r.get(2)?)))
            })?
            .collect::<rusqlite::Result<_>>()?;
        let tx = self.conn.unchecked_transaction()?;
        for entry in fs::read_dir(directory)? {
            let path = entry?.path();
            if path.extension().is_none_or(|e| e != "status") {
                continue;
            }
            let path = fs::canonicalize(path)?;
            if known.get(path.to_string_lossy().as_ref()) == Some(&fingerprint(&path)?) {
                continue;
            }
            self.record_run(workspace, &path)?;
        }
        tx.commit()?;
        Ok(())
    }
    pub fn list_runs(&self, workspace: &Path, directory: Option<&Path>) -> Result<Vec<RunRecord>> {
        let mut stmt = self.conn.prepare("SELECT run_name, worker_id, engine, state, verdict, tokens_in, tokens_cached, tokens_out, worktree, status_file, details FROM worker_runs WHERE workspace=?1 ORDER BY run_name DESC")?;
        let mut rows = stmt.query([workspace.to_string_lossy()])?;
        let mut result = vec![];
        while let Some(row) = rows.next()? {
            let status_file: String = row.get(9)?;
            if directory.is_some_and(|d| Path::new(&status_file).parent() != Some(d)) {
                continue;
            }
            let run = RunRecord {
                run_name: row.get(0)?,
                worker_id: row.get(1)?,
                engine: row.get(2)?,
                state: row.get(3)?,
                verdict: row.get(4)?,
                tokens_in: row.get(5)?,
                tokens_cached: row.get(6)?,
                tokens_out: row.get(7)?,
                worktree: row.get(8)?,
                status_file,
                details: serde_json::from_str(&row.get::<_, String>(10)?)?,
                metrics: None,
            };
            result.push(run);
        }
        Ok(result)
    }
}

pub fn command(args: &[String], default_workspace: impl FnOnce() -> Result<PathBuf>) -> Result<()> {
    let Some(op) = args.first() else {
        bail!("Usage: squad run record --status-file <file> [--workspace <dir>] | list --json [--workspace <dir>] [--directory <dir>]");
    };
    let mut workspace = None;
    let mut status = None;
    let mut directory = None;
    let mut json = false;
    let mut metrics = false;
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--workspace" | "--status-file" | "--directory" => {
                let value = args
                    .get(i + 1)
                    .filter(|v| !v.starts_with("--"))
                    .context("run flag requires a value")?;
                let target = match args[i].as_str() {
                    "--workspace" => &mut workspace,
                    "--status-file" => &mut status,
                    _ => &mut directory,
                };
                if target.replace(PathBuf::from(value)).is_some() {
                    bail!("duplicate run flag");
                }
                i += 2;
            }
            "--metrics" if !metrics => {
                metrics = true;
                i += 1;
            }
            "--json" if !json => {
                json = true;
                i += 1;
            }
            flag => bail!("unknown run flag: {flag}"),
        }
    }
    if (op == "record" && (status.is_none() || directory.is_some() || json || metrics))
        || (op == "list" && (!json || status.is_some()))
        || !["record", "list"].contains(&op.as_str())
    {
        bail!("Usage: squad run record --status-file <file> | list --json [--directory <dir>]");
    }
    let workspace = fs::canonicalize(match workspace {
        Some(p) => p,
        None => default_workspace()?,
    })?;
    if !workspace.join(".squad").is_dir() {
        bail!("Not a squad workspace");
    }
    let store = Store::open(&workspace.join(".squad/messages.db"))?;
    if op == "record" {
        store.record_run(&workspace, &status.unwrap())?;
    } else {
        let directory = directory.map(fs::canonicalize).transpose()?;
        if let Some(dir) = &directory {
            store.sync_runs(&workspace, dir)?;
        }
        let mut runs = store.list_runs(&workspace, directory.as_deref())?;
        if metrics {
            for run in &mut runs {
                run.metrics = log_metrics(run);
            }
        }
        println!("{}", serde_json::to_string(&runs)?);
    }
    Ok(())
}
