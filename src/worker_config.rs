//! Worker model setup: lists models from installed CLIs and saves fast,
//! balanced, and strong choices to `.squad/worker-models.json`.
//!
//! The file is plain data. The worker launcher reads it with jq and never
//! sources it. Discovery runs only the CLIs' own model-list commands (no
//! inference) under a timeout, and never reads credentials.

use anyhow::{bail, Context, Result};
use chrono::{DateTime, SecondsFormat, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;
use std::io::{BufRead, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::time::{Duration, Instant};

pub const CONFIG_FILE: &str = "worker-models.json";
pub const CACHE_FILE: &str = "worker-model-cache.json";
pub const TIERS: [&str; 3] = ["fast", "balanced", "strong"];
/// Engines whose saved tiers the worker launcher reads (CCR uses its router).
pub const CONFIG_ENGINES: [&str; 5] = ["claude", "codex", "opencode", "grok", "agy"];
/// Engines with a model-list command and a CLI-supported effort setting.
pub const DISCOVERY_ENGINES: [&str; 2] = ["codex", "agy"];
pub const DEFAULT_TIMEOUT_SECS: u64 = 20;
const STALE_AFTER_DAYS: i64 = 7;
const MAX_OUTPUT_BYTES: u64 = 8 * 1024 * 1024;
const MAX_NAME_CHARS: usize = 80;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Selection {
    pub model: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub effort: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct EngineConfig {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fast: Option<Selection>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub balanced: Option<Selection>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub strong: Option<Selection>,
    /// Model list the selections were made from, and when it was fetched.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fetched_at: Option<String>,
}

impl EngineConfig {
    pub fn tier(&self, tier: &str) -> Option<&Selection> {
        match tier {
            "fast" => self.fast.as_ref(),
            "balanced" => self.balanced.as_ref(),
            "strong" => self.strong.as_ref(),
            _ => None,
        }
    }

    fn tier_mut(&mut self, tier: &str) -> &mut Option<Selection> {
        match tier {
            "fast" => &mut self.fast,
            "balanced" => &mut self.balanced,
            _ => &mut self.strong,
        }
    }

    fn is_empty(&self) -> bool {
        TIERS.iter().all(|tier| self.tier(tier).is_none())
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct WorkerConfig {
    pub version: u32,
    #[serde(default)]
    pub engines: BTreeMap<String, EngineConfig>,
}

impl Default for WorkerConfig {
    fn default() -> Self {
        Self {
            version: 1,
            engines: BTreeMap::new(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ModelChoice {
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub efforts: Vec<String>,
}

/// A model list with where it came from. `live` is true only when the CLI
/// confirmed a fresh fetch.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ModelList {
    pub source: String,
    pub fetched_at: Option<String>,
    pub live: bool,
    pub models: Vec<ModelChoice>,
}

#[derive(Debug, Default, Serialize, Deserialize)]
struct CacheFile {
    version: u32,
    #[serde(default)]
    engines: BTreeMap<String, ModelList>,
}

/// Model IDs are passed to CLIs as single arguments: no whitespace, control
/// characters, or leading dash.
pub fn validate_model_id(id: &str) -> Result<()> {
    if id.is_empty()
        || id.len() > 256
        || id.starts_with('-')
        || id.chars().any(|c| c.is_control() || c.is_whitespace())
    {
        bail!("invalid model id {:?}", truncate(id, 60));
    }
    Ok(())
}

pub fn validate_effort(effort: &str) -> Result<()> {
    let valid = matches!(
        effort,
        "none" | "minimal" | "low" | "medium" | "high" | "xhigh" | "max"
    );
    if !valid {
        bail!("invalid reasoning effort {:?}", truncate(effort, 40));
    }
    Ok(())
}

pub fn config_path(workspace: &Path) -> PathBuf {
    workspace.join(".squad").join(CONFIG_FILE)
}

pub fn parse_config(text: &str) -> Result<WorkerConfig> {
    let config: WorkerConfig = serde_json::from_str(text).context("not valid worker model JSON")?;
    if config.version != 1 {
        bail!("unsupported version {}", config.version);
    }
    for (engine, entry) in &config.engines {
        if entry
            .source
            .as_ref()
            .is_some_and(|s| s.chars().any(char::is_control) || s.len() > 1024)
            || entry
                .fetched_at
                .as_deref()
                .is_some_and(|time| parse_time(time).is_none())
        {
            bail!("invalid model source or timestamp");
        }
        if !CONFIG_ENGINES.contains(&engine.as_str()) {
            bail!("unsupported engine {:?}", truncate(engine, 40));
        }
        for tier in TIERS {
            let Some(selection) = entry.tier(tier) else {
                continue;
            };
            validate_model_id(&selection.model).with_context(|| format!("{engine} {tier}"))?;
            if let Some(name) = &selection.name {
                if name.chars().any(char::is_control) || name.chars().count() > 200 {
                    bail!("{engine} {tier}: invalid display name");
                }
            }
            if let Some(effort) = &selection.effort {
                if !DISCOVERY_ENGINES.contains(&engine.as_str()) {
                    bail!("{engine} {tier}: reasoning effort is unsupported for {engine}");
                }
                validate_effort(effort).with_context(|| format!("{engine} {tier}"))?;
            }
        }
    }
    Ok(config)
}

/// A missing file is an empty configuration; an invalid one is an error, so
/// setup never overwrites a file it cannot read.
pub fn load_config(workspace: &Path) -> Result<WorkerConfig> {
    let path = config_path(workspace);
    match std::fs::read_to_string(&path) {
        Ok(text) => parse_config(&text).with_context(|| {
            format!(
                "invalid {}; fix or remove it, then rerun `squad config workers`",
                path.display()
            )
        }),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(WorkerConfig::default()),
        Err(error) => Err(error).with_context(|| format!("failed to read {}", path.display())),
    }
}

fn write_atomic(path: &Path, content: &str) -> Result<()> {
    let tmp = path.with_extension(format!("tmp-{}", std::process::id()));
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&tmp)
        .with_context(|| format!("failed to create {}", tmp.display()))?;
    let result = file
        .write_all(content.as_bytes())
        .and_then(|_| std::fs::rename(&tmp, path));
    if result.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    result.with_context(|| format!("failed to save {}", path.display()))
}

pub fn save_config(workspace: &Path, config: &WorkerConfig) -> Result<()> {
    let text = serde_json::to_string_pretty(config)? + "\n";
    parse_config(&text)?;
    write_atomic(&config_path(workspace), &text)
}

fn load_cache(workspace: &Path) -> (BTreeMap<String, ModelList>, Option<String>) {
    let path = workspace.join(".squad").join(CACHE_FILE);
    let Ok(text) = std::fs::read_to_string(&path) else {
        return (BTreeMap::new(), None);
    };
    let parsed = serde_json::from_str::<CacheFile>(&text)
        .ok()
        .filter(|cache| cache.version == 1)
        .filter(|cache| {
            cache.engines.iter().all(|(engine, list)| {
                DISCOVERY_ENGINES.contains(&engine.as_str())
                    && list.fetched_at.as_deref().and_then(parse_time).is_some()
                    && valid_list(list)
            })
        });
    match parsed {
        Some(cache) => (cache.engines, None),
        None => (
            BTreeMap::new(),
            Some(format!("ignored unreadable model cache {}", path.display())),
        ),
    }
}

fn valid_list(list: &ModelList) -> bool {
    !list.source.chars().any(char::is_control)
        && list.source.len() <= 1024
        && !list.models.is_empty()
        && list.models.iter().all(|model| {
            validate_model_id(&model.id).is_ok()
                && !model.name.chars().any(char::is_control)
                && model.efforts.iter().all(|e| validate_effort(e).is_ok())
        })
}

fn store_cache(workspace: &Path, lists: &BTreeMap<String, ModelList>) -> Result<()> {
    let (mut engines, _) = load_cache(workspace);
    for (engine, list) in lists {
        engines.insert(engine.clone(), list.clone());
    }
    let text = serde_json::to_string_pretty(&CacheFile {
        version: 1,
        engines,
    })? + "\n";
    write_atomic(&workspace.join(".squad").join(CACHE_FILE), &text)
}

// --- Discovery ---

fn now() -> String {
    Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true)
}

fn parse_time(value: &str) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(value)
        .ok()
        .map(|time| time.with_timezone(&Utc))
}

fn truncate(text: &str, limit: usize) -> String {
    text.chars().take(limit).collect()
}

fn display_name(name: &str, id: &str) -> String {
    let clean: String = name.chars().filter(|c| !c.is_control()).collect();
    let clean = truncate(clean.trim(), MAX_NAME_CHARS);
    if clean.is_empty() {
        id.to_string()
    } else {
        clean
    }
}

fn push_unique(models: &mut Vec<ModelChoice>, choice: ModelChoice) {
    if validate_model_id(&choice.id).is_ok() && !models.iter().any(|m| m.id == choice.id) {
        models.push(choice);
    }
}

/// `agy models` prints `id<TAB>friendly name` lines; anything else is skipped.
pub fn parse_agy_models(text: &str) -> Result<Vec<ModelChoice>> {
    let mut models = Vec::new();
    for line in text.lines() {
        let Some((id, name)) = line.split_once('\t') else {
            continue;
        };
        let id = id.trim();
        push_unique(
            &mut models,
            ModelChoice {
                id: id.to_string(),
                name: display_name(name, id),
                efforts: Vec::new(),
            },
        );
    }
    if models.is_empty() {
        bail!("no models in `agy models` output");
    }
    Ok(models)
}

/// Effort values documented by `agy --help`, e.g. `--effort ... (low|high)`.
pub fn parse_agy_efforts(help: &str) -> Vec<String> {
    let Some(line) = help
        .lines()
        .find(|line| line.trim_start().starts_with("--effort"))
    else {
        return Vec::new();
    };
    let (Some(start), Some(end)) = (line.rfind('('), line.rfind(')')) else {
        return Vec::new();
    };
    if end <= start {
        return Vec::new();
    }
    let values: Vec<String> = line[start + 1..end]
        .split('|')
        .map(|value| value.trim().to_string())
        .collect();
    if values.iter().all(|value| validate_effort(value).is_ok()) {
        values
    } else {
        Vec::new()
    }
}

/// Codex catalog JSON (`codex debug models` and models_cache.json): only
/// picker-visible models, with their advertised reasoning efforts.
pub fn parse_codex_models(value: &Value) -> Result<Vec<ModelChoice>> {
    let items = value
        .get("models")
        .and_then(Value::as_array)
        .context("no models array in Codex catalog")?;
    let mut models = Vec::new();
    for item in items {
        if item.get("visibility").and_then(Value::as_str) != Some("list") {
            continue;
        }
        let Some(id) = item.get("slug").and_then(Value::as_str) else {
            continue;
        };
        let name = item
            .get("display_name")
            .and_then(Value::as_str)
            .unwrap_or(id);
        let efforts = item
            .get("supported_reasoning_levels")
            .and_then(Value::as_array)
            .map(|levels| {
                levels
                    .iter()
                    .filter_map(|level| level.get("effort").and_then(Value::as_str))
                    .filter(|effort| validate_effort(effort).is_ok())
                    .map(String::from)
                    .collect()
            })
            .unwrap_or_default();
        push_unique(
            &mut models,
            ModelChoice {
                id: id.to_string(),
                name: display_name(name, id),
                efforts,
            },
        );
    }
    if models.is_empty() {
        bail!("no listed models in Codex catalog");
    }
    Ok(models)
}

struct ChildGuard(Child);

impl Drop for ChildGuard {
    fn drop(&mut self) {
        // Discovery wrappers can leave descendants holding the output pipes.
        #[cfg(unix)]
        let _ = Command::new("/bin/kill")
            .args(["-KILL", "--", &format!("-{}", self.0.id())])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn read_in_background<R: Read + Send + 'static>(reader: R) -> mpsc::Receiver<Vec<u8>> {
    let (sender, receiver) = mpsc::channel();
    std::thread::spawn(move || {
        let mut buffer = Vec::new();
        let _ = reader.take(MAX_OUTPUT_BYTES).read_to_end(&mut buffer);
        let _ = sender.send(buffer);
    });
    receiver
}

/// Runs a CLI with no stdin, bounded by `timeout`; the child is killed and
/// reaped on every exit path.
fn run_bounded(program: &str, args: &[&str], timeout: Duration) -> Result<(bool, String, String)> {
    let label = format!("`{} {}`", program, args.join(" "));
    let mut command = Command::new(program);
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        command.process_group(0);
    }
    let mut child = command
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .with_context(|| format!("could not start {label}"))?;
    let stdout = read_in_background(child.stdout.take().context("no stdout")?);
    let stderr = read_in_background(child.stderr.take().context("no stderr")?);
    let mut guard = ChildGuard(child);
    let deadline = Instant::now() + timeout;
    let status = loop {
        if let Some(status) = guard.0.try_wait()? {
            break status;
        }
        if Instant::now() >= deadline {
            bail!("{label} timed out after {}s", timeout.as_secs());
        }
        std::thread::sleep(Duration::from_millis(25));
    };
    // A grandchild may hold the pipes open; do not wait for it indefinitely.
    let collect = |receiver: mpsc::Receiver<Vec<u8>>| {
        let wait = deadline
            .saturating_duration_since(Instant::now())
            .max(Duration::from_millis(500));
        receiver
            .recv_timeout(wait)
            .map(|bytes| String::from_utf8_lossy(&bytes).into_owned())
    };
    let out = collect(stdout).with_context(|| format!("{label} kept its output open"))?;
    let err = collect(stderr).unwrap_or_default();
    Ok((status.success(), out, err))
}

pub fn codex_cache_path() -> Option<PathBuf> {
    let home = match std::env::var_os("CODEX_HOME").filter(|v| !v.is_empty()) {
        Some(home) => PathBuf::from(home),
        None => PathBuf::from(std::env::var_os("HOME").filter(|v| !v.is_empty())?).join(".codex"),
    };
    Some(home.join("models_cache.json"))
}

/// Reads only `fetched_at` and model fields; other cache keys are ignored.
fn read_codex_cache(path: &Path) -> Result<(Option<String>, Vec<ModelChoice>)> {
    let size = std::fs::metadata(path)?.len();
    if size > MAX_OUTPUT_BYTES {
        bail!("{} is too large", path.display());
    }
    let value: Value = serde_json::from_str(&std::fs::read_to_string(path)?)?;
    let fetched_at = value
        .get("fetched_at")
        .and_then(Value::as_str)
        .and_then(parse_time)
        .map(|time| time.to_rfc3339_opts(SecondsFormat::Secs, true));
    Ok((fetched_at, parse_codex_models(&value)?))
}

fn discover_codex(timeout: Duration) -> Result<ModelList> {
    let before = codex_cache_path()
        .and_then(|path| read_codex_cache(&path).ok())
        .and_then(|(time, _)| time);
    let started = Utc::now() - chrono::Duration::seconds(1);
    let (ok, out, _err) = run_bounded("codex", &["debug", "models"], timeout)?;
    if !ok {
        bail!("`codex debug models` failed; check the CLI login or retry");
    }
    let value: Value =
        serde_json::from_str(&out).context("`codex debug models` printed invalid JSON")?;
    let models = parse_codex_models(&value)?;
    // The CLI refreshes its cache when it can and silently falls back when it
    // cannot; only an advanced cache timestamp proves a fresh fetch.
    let fetched_at = codex_cache_path()
        .and_then(|path| read_codex_cache(&path).ok())
        .and_then(|(fetched_at, _)| fetched_at);
    let live = fetched_at != before
        && fetched_at
            .as_deref()
            .and_then(parse_time)
            .is_some_and(|time| time >= started);
    let source = if live {
        "live: codex debug models".to_string()
    } else {
        "codex debug models (refresh not confirmed; may be cached or bundled)".to_string()
    };
    Ok(ModelList {
        source,
        fetched_at,
        live,
        models,
    })
}

fn discover_agy(timeout: Duration) -> Result<ModelList> {
    let (ok, out, _err) = run_bounded("agy", &["models"], timeout)?;
    if !ok {
        bail!("`agy models` failed; check the CLI login or retry");
    }
    let mut models = parse_agy_models(&out)?;
    // Go-style help goes to stderr; its exit status is not meaningful.
    let efforts = run_bounded("agy", &["--help"], timeout)
        .map(|(_, out, err)| parse_agy_efforts(&format!("{out}\n{err}")))
        .unwrap_or_default();
    for model in &mut models {
        model.efforts = efforts.clone();
    }
    Ok(ModelList {
        source: "live: agy models".to_string(),
        fetched_at: Some(now()),
        live: true,
        models,
    })
}

pub fn discover(engine: &str, timeout: Duration) -> Result<ModelList> {
    match engine {
        "codex" => discover_codex(timeout),
        "agy" => discover_agy(timeout),
        _ => bail!("live model discovery is not supported for {engine}"),
    }
}

/// The newest cached list: squad's own copy of an earlier live fetch, or for
/// Codex its CLI cache. Always labeled as a fallback.
fn fallback_list(engine: &str, cache: &BTreeMap<String, ModelList>) -> Option<ModelList> {
    let mut candidates: Vec<ModelList> = cache
        .get(engine)
        .map(|list| ModelList {
            source: format!("squad cache of {}", list.source),
            live: false,
            ..list.clone()
        })
        .into_iter()
        .collect();
    if engine == "codex" {
        if let Some(path) = codex_cache_path() {
            if let Ok((fetched_at, models)) = read_codex_cache(&path) {
                candidates.push(ModelList {
                    source: format!("Codex CLI cache {}", path.display()),
                    fetched_at,
                    live: false,
                    models,
                });
            }
        }
    }
    candidates.into_iter().max_by_key(|list| {
        list.fetched_at
            .as_deref()
            .and_then(parse_time)
            .map(|time| time.timestamp())
            .unwrap_or(i64::MIN)
    })
}

fn age_label(list: &ModelList) -> String {
    let Some(fetched_at) = list.fetched_at.as_deref() else {
        return "fetch time unknown".to_string();
    };
    let Some(time) = parse_time(fetched_at) else {
        return "fetch time unknown".to_string();
    };
    let age = Utc::now().signed_duration_since(time);
    let stale = if age.num_days() >= STALE_AFTER_DAYS {
        ", stale"
    } else {
        ""
    };
    let age_text = if age.num_days() > 0 {
        format!("{} days old", age.num_days())
    } else if age.num_hours() > 0 {
        format!("{} hours old", age.num_hours())
    } else {
        "just now".to_string()
    };
    format!("fetched {fetched_at}, {age_text}{stale}")
}

// --- Interactive setup ---

pub enum Outcome {
    Saved,
    Unchanged,
    Cancelled,
}

enum Flow<T> {
    Go(T),
    Skip,
    Cancel,
}

fn ask(input: &mut dyn BufRead, out: &mut dyn Write, prompt: &str) -> Result<Option<String>> {
    write!(out, "{prompt}")?;
    out.flush()?;
    let mut line = String::new();
    if input.read_line(&mut line)? == 0 {
        writeln!(out)?;
        return Ok(None);
    }
    Ok(Some(line.trim().to_string()))
}

fn selection_label(selection: Option<&Selection>) -> String {
    match selection {
        None => "unset".to_string(),
        Some(selection) => {
            let mut label = match &selection.name {
                Some(name) if name != &selection.model => format!("{name} ({})", selection.model),
                _ => selection.model.clone(),
            };
            if let Some(effort) = &selection.effort {
                label.push_str(&format!(", effort {effort}"));
            }
            label
        }
    }
}

fn engine_notes(out: &mut dyn Write) -> Result<()> {
    for engine in ["claude", "opencode", "grok", "ccr"] {
        if !crate::setup::is_installed(engine) {
            continue;
        }
        let upper = engine.to_ascii_uppercase();
        match engine {
            "claude" => writeln!(
                out,
                "claude: no model list command; tiers use the haiku/sonnet/opus aliases unless SQUAD_WORKER_CLAUDE_MODEL_<TIER> is set."
            )?,
            "ccr" => writeln!(out, "ccr: model tiers are unsupported; the router chooses its model.")?,
            _ => writeln!(
                out,
                "{engine}: live model discovery is not supported; set SQUAD_WORKER_{upper}_MODEL_<TIER> or pass --model."
            )?,
        }
    }
    Ok(())
}

fn obtain_list(
    engine: &str,
    input: &mut dyn BufRead,
    out: &mut dyn Write,
    cache: &BTreeMap<String, ModelList>,
    timeout: Duration,
) -> Result<Flow<ModelList>> {
    loop {
        writeln!(
            out,
            "Listing {engine} models (up to {}s)...",
            timeout.as_secs()
        )?;
        let error = match discover(engine, timeout) {
            Ok(list) => return Ok(Flow::Go(list)),
            Err(error) => error,
        };
        writeln!(out, "Could not list {engine} models: {error:#}")?;
        let fallback = fallback_list(engine, cache);
        loop {
            let prompt = match &fallback {
                Some(list) => format!(
                    "[r]etry, use [c]ached list ({}; {}), [s]kip {engine}, or [q]uit: ",
                    list.source,
                    age_label(list)
                ),
                None => format!("No cached list. [r]etry, [s]kip {engine}, or [q]uit: "),
            };
            match ask(input, out, &prompt)?.as_deref() {
                None | Some("q") => return Ok(Flow::Cancel),
                Some("s") => return Ok(Flow::Skip),
                Some("r") => break,
                Some("c") if fallback.is_some() => return Ok(Flow::Go(fallback.unwrap())),
                _ => {}
            }
        }
    }
}

fn pick_model(
    tier: &str,
    list: &ModelList,
    current: Option<&Selection>,
    input: &mut dyn BufRead,
    out: &mut dyn Write,
) -> Result<Flow<Option<Selection>>> {
    let current_label = selection_label(current);
    if let Some(current) = current {
        if !list.models.iter().any(|m| m.id == current.model) {
            writeln!(
                out,
                "  current {tier} model {} is not in this list",
                current.model
            )?;
        }
    }
    let count = list.models.len();
    let choice = loop {
        let prompt =
            format!("{tier} model [1-{count}, Enter keeps {current_label}, - clears, q cancels]: ");
        match ask(input, out, &prompt)?.as_deref() {
            None | Some("q") => return Ok(Flow::Cancel),
            Some("") => {
                // Keeping a model re-offers effort only when the list knows it.
                match current.and_then(|c| list.models.iter().find(|m| m.id == c.model)) {
                    Some(model) => break model,
                    None => return Ok(Flow::Go(current.cloned())),
                }
            }
            Some("-") => return Ok(Flow::Go(None)),
            Some(text) => match text.parse::<usize>() {
                Ok(number) if (1..=count).contains(&number) => break &list.models[number - 1],
                _ => writeln!(out, "Enter a number from 1 to {count}.")?,
            },
        }
    };
    let kept_effort = current
        .filter(|c| c.model == choice.id)
        .and_then(|c| c.effort.clone())
        .filter(|effort| choice.efforts.contains(effort));
    let mut effort = kept_effort.clone();
    if !choice.efforts.is_empty() {
        let options: Vec<String> = choice
            .efforts
            .iter()
            .enumerate()
            .map(|(index, effort)| format!("{}) {effort}", index + 1))
            .collect();
        let keep = kept_effort.as_deref().unwrap_or("CLI default");
        loop {
            let prompt = format!(
                "  effort for {}: 0) CLI default  {} [Enter keeps {keep}]: ",
                choice.id,
                options.join("  ")
            );
            match ask(input, out, &prompt)?.as_deref() {
                None | Some("q") => return Ok(Flow::Cancel),
                Some("") => break,
                Some("0") => {
                    effort = None;
                    break;
                }
                Some(text) => match text.parse::<usize>() {
                    Ok(number) if (1..=choice.efforts.len()).contains(&number) => {
                        effort = Some(choice.efforts[number - 1].clone());
                        break;
                    }
                    _ => writeln!(out, "Enter a number from 0 to {}.", choice.efforts.len())?,
                },
            }
        }
    }
    Ok(Flow::Go(Some(Selection {
        model: choice.id.clone(),
        name: Some(choice.name.clone()),
        effort,
    })))
}

fn print_review(out: &mut dyn Write, config: &WorkerConfig) -> Result<()> {
    writeln!(out, "Review worker models:")?;
    if config.engines.is_empty() {
        writeln!(out, "  (none)")?;
    }
    for (engine, entry) in &config.engines {
        for tier in TIERS {
            writeln!(
                out,
                "  {engine:<6} {tier:<8} {}",
                selection_label(entry.tier(tier))
            )?;
        }
        if let Some(source) = &entry.source {
            let fetched = entry.fetched_at.as_deref().unwrap_or("unknown time");
            writeln!(out, "         from {source}, fetched {fetched}")?;
        }
    }
    Ok(())
}

fn cancelled(out: &mut dyn Write) -> Result<Outcome> {
    writeln!(out, "Cancelled; nothing was saved.")?;
    Ok(Outcome::Cancelled)
}

/// Interactive setup. End of input or `q` cancels without writing anything.
pub fn run_setup(
    workspace: &Path,
    input: &mut dyn BufRead,
    out: &mut dyn Write,
    timeout: Duration,
) -> Result<Outcome> {
    let original = load_config(workspace)?;
    let mut config = original.clone();
    let (cache, cache_note) = load_cache(workspace);
    let path = config_path(workspace);
    writeln!(
        out,
        "Worker model setup: choices are saved to {} only (no shell or CLI config changes).",
        path.display()
    )?;
    if let Some(note) = cache_note {
        writeln!(out, "Note: {note}")?;
    }
    engine_notes(out)?;
    let engines: Vec<&str> = DISCOVERY_ENGINES
        .into_iter()
        .filter(|engine| crate::setup::is_installed(engine))
        .collect();
    if engines.is_empty() {
        writeln!(
            out,
            "No engine with a model list command (codex, agy) is installed; nothing to set up."
        )?;
        return Ok(Outcome::Unchanged);
    }
    let mut fresh_lists = BTreeMap::new();
    for engine in engines {
        let entry = config.engines.get(engine).cloned().unwrap_or_default();
        writeln!(out)?;
        for tier in TIERS {
            writeln!(
                out,
                "{engine} {tier}: {}",
                selection_label(entry.tier(tier))
            )?;
        }
        let configure = loop {
            match ask(
                input,
                out,
                &format!("Configure {engine}? [Y/n, q cancels]: "),
            )?
            .map(|a| a.to_ascii_lowercase())
            .as_deref()
            {
                None | Some("q") => return cancelled(out),
                Some("" | "y" | "yes") => break true,
                Some("n" | "no") => break false,
                _ => {}
            }
        };
        if !configure {
            continue;
        }
        let list = loop {
            let list = match obtain_list(engine, input, out, &cache, timeout)? {
                Flow::Go(list) => list,
                Flow::Skip => break None,
                Flow::Cancel => return cancelled(out),
            };
            writeln!(
                out,
                "{engine} models from {} ({}):",
                list.source,
                age_label(&list)
            )?;
            for (index, model) in list.models.iter().enumerate() {
                writeln!(out, "  {:>2}) {}  [{}]", index + 1, model.name, model.id)?;
            }
            let refresh = loop {
                match ask(
                    input,
                    out,
                    "Enter to choose, r refreshes the list, q cancels: ",
                )?
                .as_deref()
                {
                    None | Some("q") => return cancelled(out),
                    Some("r") => break true,
                    Some("") => break false,
                    _ => continue,
                }
            };
            if !refresh {
                break Some(list);
            }
        };
        let Some(list) = list else {
            continue;
        };
        let mut updated = entry.clone();
        for tier in TIERS {
            match pick_model(tier, &list, entry.tier(tier), input, out)? {
                Flow::Go(selection) => *updated.tier_mut(tier) = selection,
                Flow::Skip => {}
                Flow::Cancel => return cancelled(out),
            }
        }
        if updated != entry {
            updated.source = Some(list.source.clone());
            updated.fetched_at = list.fetched_at.clone();
        }
        if updated.is_empty() {
            config.engines.remove(engine);
        } else {
            config.engines.insert(engine.to_string(), updated);
        }
        if list.live {
            fresh_lists.insert(engine.to_string(), list);
        }
    }
    writeln!(out)?;
    if config == original {
        writeln!(out, "No changes; {} was left as it was.", path.display())?;
        return Ok(Outcome::Unchanged);
    }
    print_review(out, &config)?;
    match ask(input, out, &format!("Save to {}? [y/N]: ", path.display()))?
        .map(|a| a.to_ascii_lowercase())
        .as_deref()
    {
        Some("y" | "yes") => {}
        _ => return cancelled(out),
    }
    save_config(workspace, &config)?;
    if let Err(error) = store_cache(workspace, &fresh_lists) {
        writeln!(out, "Note: model list cache not updated: {error:#}")?;
    }
    writeln!(
        out,
        "Saved. squad-worker --model-tier uses these unless --model or SQUAD_WORKER_<ENGINE>_MODEL_<TIER> is set; check with squad-worker --models."
    )?;
    Ok(Outcome::Saved)
}
