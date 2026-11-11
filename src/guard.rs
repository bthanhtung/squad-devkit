//! Manager hook policy. Hook infrastructure errors allow, matching the shell hook.
use crate::plan;
use anyhow::{bail, Result};
use serde_json::{json, Value};
use std::{
    collections::VecDeque,
    env, fs,
    io::Read,
    path::{Path, PathBuf},
    process::Command,
};

fn resolve(path: &str, base: &str) -> String {
    let path = if path.starts_with('/') {
        path.to_owned()
    } else {
        format!("{base}/{path}")
    };
    let mut pending: VecDeque<String> = path.split('/').map(str::to_owned).collect();
    let mut parts: Vec<String> = vec![];
    let mut hops = 0;
    while let Some(part) = pending.pop_front() {
        match part.as_str() {
            "" | "." => (),
            ".." => {
                parts.pop();
            }
            _ => {
                let candidate = format!("/{}/{}", parts.join("/"), part);
                if hops < 40 {
                    if let Ok(target) = fs::read_link(&candidate) {
                        hops += 1;
                        let target = target.to_string_lossy();
                        if target.starts_with('/') {
                            parts.clear();
                        }
                        for p in target.split('/').rev() {
                            pending.push_front(p.to_owned());
                        }
                        continue;
                    }
                }
                parts.push(part);
            }
        }
    }
    format!("/{}", parts.join("/"))
}
fn step(base: &str, arg: &str) -> String {
    let arg = if arg == "~" || arg.starts_with("~/") {
        format!("{}{}", env::var("HOME").unwrap_or_default(), &arg[1..])
    } else {
        arg.to_owned()
    };
    if arg.is_empty()
        || arg == "-"
        || arg.starts_with('~')
        || arg.contains(['$', '`', '*', '?', '['])
        || (!arg.starts_with('/') && base.is_empty())
    {
        return String::new();
    }
    resolve(&arg, base)
}
fn under(path: &str, root: &str) -> bool {
    path == root || path.strip_prefix(root).is_some_and(|r| r.starts_with('/'))
}
fn git(args: &[&str]) -> String {
    Command::new("git")
        .args(args)
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| {
            String::from_utf8_lossy(&o.stdout)
                .trim_end_matches('\n')
                .to_owned()
        })
        .unwrap_or_default()
}
fn repo_top(dir: &str) -> String {
    let top = git(&["-C", dir, "rev-parse", "--show-toplevel"]);
    if top.is_empty() {
        top
    } else {
        resolve(&top, dir)
    }
}
fn unresolved(action: &str) -> String {
    format!("Could not verify the target repository of {action}; run \"git -C <literal path> {action}\" after recording the approval in a plan.")
}

struct Guard {
    project: String,
    cwd: String,
    dir: String,
    gd: String,
    wt: String,
    commits: usize,
    pushes: usize,
}
impl Guard {
    fn allowed(&self, path: &str) -> bool {
        if under(
            path,
            &resolve(&format!("{}/.squad", self.project), &self.project),
        ) {
            return true;
        }
        if under(path, &self.project) {
            return false;
        }
        let config = env::var("CLAUDE_CONFIG_DIR")
            .unwrap_or_else(|_| format!("{}/.claude", env::var("HOME").unwrap_or_default()));
        let mut roots = vec![
            format!("{config}/projects"),
            "/tmp".into(),
            "/private/tmp".into(),
            "/private/var/folders".into(),
        ];
        if let Ok(tmp) = env::var("TMPDIR") {
            if !tmp.is_empty() {
                roots.push(tmp);
            }
        }
        roots.extend(
            env::var("SQUAD_DEVKIT_GUARD_ALLOW")
                .unwrap_or_default()
                .split(':')
                .filter(|v| !v.is_empty())
                .map(str::to_owned),
        );
        roots
            .iter()
            .any(|root| under(path, &resolve(root, &self.project)))
    }
    fn approved(&self, action: &str, top: &str) -> Result<Option<String>> {
        let repo = Path::new(top)
            .file_name()
            .unwrap_or_default()
            .to_string_lossy();
        let files = plan::approval_files(
            &PathBuf::from(&self.project).join(".squad/plans"),
            action,
            &repo,
            top,
        )?;
        if files.is_empty() {
            return Ok(Some(format!("git {action} in {repo} needs a human approval recorded in a plan: add \"- {action}: {top}\" under ## Approvals in .squad/plans/<plan>.md after the human approves (a bare \"{repo}\" also matches, but so does any repository with that name).")));
        }
        for file in files {
            let text = String::from_utf8_lossy(&fs::read(&file)?).into_owned();
            if action == "push"
                && plan::level(&text, "Risk") == "high"
                && !plan::approves(&text, "review", &repo, top)
            {
                return Ok(Some(format!("push of {repo} from high-risk plan {} needs \"- review: {repo}\" (or \"- review: {top}\") in ## Approvals after a reviewer passes.", file.file_name().unwrap_or_default().to_string_lossy())));
            }
        }
        Ok(None)
    }
    fn target(&self, dir: &str, gd: &str, wt: &str) -> Option<String> {
        if dir.is_empty() || !Path::new(dir).is_dir() {
            return None;
        }
        let wt = if wt.is_empty() {
            String::new()
        } else {
            let p = step(dir, wt);
            if p.is_empty() || !Path::new(&p).is_dir() {
                return None;
            }
            p
        };
        if gd.is_empty() {
            return Some(repo_top(dir));
        }
        let gd = step(dir, gd);
        if gd.is_empty()
            || !Path::new(&gd).is_dir()
            || git(&["--git-dir", &gd, "rev-parse", "--git-dir"]).is_empty()
        {
            return None;
        }
        if !wt.is_empty() {
            return Some(wt);
        }
        let cfg = git(&["--git-dir", &gd, "config", "core.worktree"]);
        if !cfg.is_empty() {
            let p = step(&gd, &cfg);
            return (!p.is_empty() && Path::new(&p).is_dir()).then_some(p);
        }
        Some(if Path::new(&gd).file_name().is_some_and(|n| n == ".git") {
            Path::new(&gd).parent()?.to_string_lossy().into_owned()
        } else {
            gd
        })
    }
    fn run_op(
        &mut self,
        action: &str,
        dir: &str,
        gd: &str,
        wt: &str,
        unres: bool,
    ) -> Result<Option<String>> {
        if action == "commit" {
            self.commits += 1;
        } else {
            self.pushes += 1;
        }
        if unres {
            return Ok(Some(unresolved(action)));
        }
        let Some(top) = self.target(dir, gd, wt) else {
            return Ok(Some(unresolved(action)));
        };
        if top.is_empty() {
            Ok(None)
        } else {
            self.approved(action, &top)
        }
    }
    fn segment(&mut self, segment: &str) -> Result<Option<String>> {
        let words: Vec<_> = segment
            .split_whitespace()
            .map(|w| w.strip_prefix(['"', '\'']).unwrap_or(w))
            .map(|w| w.strip_suffix(['"', '\'']).unwrap_or(w))
            .collect();
        let get = |i: usize| words.get(i).copied().unwrap_or_default();
        let mut i = 0;
        let (mut gd, mut wt) = (self.gd.clone(), self.wt.clone());
        let mut unres = false;
        let mut via_env = false;
        while i < words.len() {
            match get(i) {
                "sudo" | "time" | "nohup" | "exec" | "command" | "builtin" | "then" | "do"
                | "else" | "!" | "{" | "(" => i += 1,
                "env" => {
                    via_env = true;
                    i += 1;
                    while i < words.len() {
                        match get(i) {
                            "-i" | "-" | "-0" | "--ignore-environment" | "--null" => i += 1,
                            "-u" | "--unset" => {
                                unset(get(i + 1), &mut gd, &mut wt);
                                i += 2;
                            }
                            w if w.starts_with("--unset=") => {
                                unset(&w[8..], &mut gd, &mut wt);
                                i += 1;
                            }
                            w if w.starts_with('-') => {
                                unres = true;
                                i += 1;
                            }
                            w if assignment(w) => {
                                assign(w, &mut gd, &mut wt);
                                i += 1;
                            }
                            _ => break,
                        }
                    }
                }
                w if assignment(w) => {
                    assign(w, &mut gd, &mut wt);
                    i += 1;
                }
                _ => break,
            }
        }
        match get(i) {
            "" => {
                if !via_env {
                    self.gd = gd;
                    self.wt = wt;
                }
                return Ok(None);
            }
            "export" | "declare" | "typeset" => {
                for w in words.iter().skip(i + 1) {
                    assign(w, &mut gd, &mut wt);
                }
                self.gd = gd;
                self.wt = wt;
                return Ok(None);
            }
            "unset" => {
                for w in words.iter().skip(i + 1) {
                    unset(w, &mut gd, &mut wt);
                }
                self.gd = gd;
                self.wt = wt;
                return Ok(None);
            }
            "cd" | "pushd" => {
                let mut j = i + 1;
                while get(j).starts_with('-') && get(j).len() > 1 {
                    j += 1;
                }
                self.dir = if get(j).is_empty() && get(i) == "pushd" {
                    String::new()
                } else {
                    step(&self.dir, if get(j).is_empty() { "~" } else { get(j) })
                };
                return Ok(None);
            }
            "popd" => {
                self.dir.clear();
                return Ok(None);
            }
            w if w == "gh" || w.ends_with("/gh") => {
                if get(i + 1) == "pr" && get(i + 2) == "merge" {
                    unres |= words
                        .iter()
                        .skip(i + 3)
                        .any(|w| w.starts_with("-R") || *w == "--repo" || w.starts_with("--repo="));
                    return self.run_op("push", &self.dir.clone(), &gd, &wt, unres);
                }
                return Ok(None);
            }
            w if w == "git" || w.ends_with("/git") => (),
            _ => return Ok(None),
        }
        let mut dir = self.dir.clone();
        i += 1;
        while i < words.len() {
            match get(i) {
                "-C" => {
                    i += 1;
                    dir = step(&dir, get(i));
                }
                "-c" | "--namespace" => i += 1,
                "--git-dir" => {
                    i += 1;
                    gd = nonempty(get(i));
                }
                "--work-tree" => {
                    i += 1;
                    wt = nonempty(get(i));
                }
                w if w.starts_with("--git-dir=") => gd = nonempty(&w[10..]),
                w if w.starts_with("--work-tree=") => wt = nonempty(&w[12..]),
                w if w.starts_with('-') => (),
                "commit" | "push" => return self.run_op(get(i), &dir, &gd, &wt, unres),
                _ => break,
            }
            i += 1;
        }
        Ok(None)
    }
    fn bash(&mut self, raw: &str) -> Result<Option<String>> {
        let raw = raw.replace("\\\n", " ");
        let split = raw
            .replace([';', '&', '|', '`'], "\n")
            .replace('(', "\n(\n")
            .replace(')', "\n)\n");
        let mut stack = vec![];
        for segment in split.lines() {
            match segment {
                "(" => stack.push((self.dir.clone(), self.gd.clone(), self.wt.clone())),
                ")" => {
                    if let Some((dir, gd, wt)) = stack.pop() {
                        self.dir = dir;
                        self.gd = gd;
                        self.wt = wt;
                    } else {
                        self.dir.clear();
                    }
                }
                _ => {
                    if let Some(reason) = self.segment(segment)? {
                        return Ok(Some(reason));
                    }
                }
            }
        }
        let words: Vec<_> = raw.split_whitespace().collect();
        let moved = ["cd", "pushd", "popd"]
            .iter()
            .any(|word| bounded(&raw, word, "_./-"))
            || ["GIT_DIR=", "GIT_WORK_TREE="].iter().any(|word| {
                raw.match_indices(word).any(|(i, _)| {
                    raw[..i]
                        .chars()
                        .next_back()
                        .is_none_or(|c| !c.is_ascii_alphanumeric() && c != '_')
                })
            })
            || raw.contains("--chdir")
            || raw.match_indices("env").any(|(i, _)| {
                let before = raw[..i].chars().next_back();
                let after = &raw[i + 3..];
                before.is_none_or(|c| !c.is_ascii_alphanumeric() && !"_./-".contains(c))
                    && after.starts_with(char::is_whitespace)
                    && after
                        .split([';', '&', '|'])
                        .next()
                        .unwrap_or_default()
                        .split_whitespace()
                        .any(|word| word.starts_with("-C"))
            });
        let (commits, ce) = loose(&raw, "git", "commit");
        let (pushes, pe) = loose(&raw, "git", "push");
        let (merges, _) = loose(&raw, "gh", "merge");
        let explicit_commit = moved || ce;
        let explicit_push = moved
            || pe
            || (merges > 0
                && words.iter().any(|w| {
                    let w = w.trim_start_matches(['\'', '"']);
                    w.starts_with("-R") || w.starts_with("--repo")
                }));
        let wrapper = ["eval", "xargs"]
            .iter()
            .any(|word| bounded(&raw, word, "_./-"))
            || ["sh", "bash", "zsh", "dash", "ksh"].iter().any(|shell| {
                raw.match_indices(shell).any(|(i, _)| {
                    if raw[..i]
                        .chars()
                        .next_back()
                        .is_some_and(|c| c.is_ascii_alphanumeric() || "_.-".contains(c))
                    {
                        return false;
                    }
                    let after = raw[i + shell.len()..].trim_start_matches(['\'', '"']);
                    if !after.starts_with(char::is_whitespace) {
                        return false;
                    }
                    after
                        .split_whitespace()
                        .take_while(|w| w.starts_with('-'))
                        .any(|w| {
                            w[1..].chars().all(|c| c.is_ascii_alphanumeric()) && w.ends_with('c')
                        })
                })
            });
        if wrapper && (explicit_commit || explicit_push) {
            if commits > 0 {
                return Ok(Some(unresolved("commit")));
            }
            if pushes + merges > 0 {
                return Ok(Some(unresolved("push")));
            }
        }
        for (action, count, resolved, explicit) in [
            ("commit", commits, self.commits, explicit_commit),
            ("push", pushes + merges, self.pushes, explicit_push),
        ] {
            if count > resolved {
                if explicit {
                    return Ok(Some(unresolved(action)));
                }
                let top = repo_top(&self.cwd);
                if !top.is_empty() && self.approved(action, &top)?.is_none() {
                    continue;
                }
                return Ok(Some(format!("Could not verify {action} in this command; run it as a plain \"git -C <repo> {action} …\" command after recording the approval in a plan.")));
            }
        }
        Ok(None)
    }
}
fn nonempty(v: &str) -> String {
    if v.is_empty() {
        "-".into()
    } else {
        v.into()
    }
}
fn assignment(w: &str) -> bool {
    w.contains('=') && w.starts_with(|c: char| c.is_ascii_alphabetic() || c == '_')
}
fn assign(w: &str, gd: &mut String, wt: &mut String) {
    if let Some(v) = w.strip_prefix("GIT_DIR=") {
        *gd = nonempty(v);
    }
    if let Some(v) = w.strip_prefix("GIT_WORK_TREE=") {
        *wt = nonempty(v);
    }
}
fn unset(w: &str, gd: &mut String, wt: &mut String) {
    if w == "GIT_DIR" {
        gd.clear();
    }
    if w == "GIT_WORK_TREE" {
        wt.clear();
    }
}

fn bounded(raw: &str, word: &str, punctuation: &str) -> bool {
    raw.match_indices(word).any(|(i, _)| {
        let boundary = |c: char| !c.is_ascii_alphanumeric() && !punctuation.contains(c);
        raw[..i].chars().next_back().is_none_or(boundary)
            && raw[i + word.len()..].chars().next().is_none_or(boundary)
    })
}

// Loose scan sees wrapped operations missed by the intentionally conservative segment parser.
fn loose(raw: &str, tool: &str, action: &str) -> (usize, bool) {
    let mut count = 0;
    let mut explicit = false;
    for line in raw.lines() {
        let starts: Vec<_> = line
            .match_indices(tool)
            .filter(|(i, _)| {
                let before = line[..*i].chars().next_back();
                let after = &line[i + tool.len()..];
                before.is_none_or(|c| !c.is_ascii_alphanumeric() && !"_.-".contains(c))
                    && after
                        .trim_start_matches(['\'', '"'])
                        .starts_with(char::is_whitespace)
            })
            .map(|(i, _)| i + tool.len())
            .collect();
        for (n, start) in starts.iter().enumerate() {
            let end = starts
                .get(n + 1)
                .map(|i| i - tool.len())
                .unwrap_or(line.len());
            let rest = line[*start..end].trim_start_matches(['\'', '"']);
            let pre = rest.split([';', '|', '&']).next().unwrap_or_default();
            let chunk = if pre.contains(['\'', '"', '`']) {
                rest
            } else {
                pre
            };
            let found = chunk.match_indices(action).find(|(i, _)| {
                chunk[..*i]
                    .chars()
                    .next_back()
                    .is_some_and(char::is_whitespace)
                    && chunk[i + action.len()..]
                        .chars()
                        .next()
                        .is_none_or(|c| !c.is_ascii_alphanumeric() && c != '_' && c != '-')
            });
            if let Some((i, _)) = found {
                if tool == "gh" && !chunk[..i].split_whitespace().any(|w| w == "pr") {
                    continue;
                }
                count += 1;
                explicit |= chunk[..i].split_whitespace().any(|w| {
                    let w = w.trim_start_matches(['\'', '"']);
                    ["-C", "--git-dir", "--work-tree"]
                        .iter()
                        .any(|t| w == *t || w.starts_with(&format!("{t}=")))
                });
            }
        }
    }
    (count, explicit)
}

fn evaluate(project: &str, input: &Value) -> Result<Option<String>> {
    let project = fs::canonicalize(project)?.to_string_lossy().into_owned();
    let cwd = input["cwd"]
        .as_str()
        .filter(|p| Path::new(p).is_dir())
        .unwrap_or(&project)
        .to_owned();
    let mut guard = Guard {
        project,
        dir: resolve(&cwd, &cwd),
        cwd,
        gd: String::new(),
        wt: String::new(),
        commits: 0,
        pushes: 0,
    };
    match input["tool_name"].as_str().unwrap_or_default() {
        "Edit" | "Write" | "MultiEdit" | "NotebookEdit" => {
            let file = input["tool_input"]["file_path"]
                .as_str()
                .or_else(|| input["tool_input"]["notebook_path"].as_str())
                .unwrap_or_default();
            if file.is_empty() {
                return Ok(None);
            }
            let path = resolve(file, &guard.cwd);
            Ok((!guard.allowed(&path)).then(|| format!("Manager does not edit project files ({path}). Delegate the change to a worker (squad-worker ... --plan <plan>) or add an allowed path via SQUAD_DEVKIT_GUARD_ALLOW.")))
        }
        "Bash" => guard.bash(input["tool_input"]["command"].as_str().unwrap_or_default()),
        _ => Ok(None),
    }
}
pub fn command(args: &[String]) -> Result<()> {
    let [op, project] = args else {
        bail!("Usage: squad guard pre-tool-use <project_dir>")
    };
    if op != "pre-tool-use" {
        bail!("Usage: squad guard pre-tool-use <project_dir>");
    }
    if env::var("SQUAD_DEVKIT_GUARD").as_deref() == Ok("0") {
        return Ok(());
    }
    let result = (|| -> Result<Option<String>> {
        if !Path::new(project).is_dir() {
            bail!("project directory not found");
        }
        let mut input = String::new();
        std::io::stdin().read_to_string(&mut input)?;
        let value: Value = serde_json::from_str(&input)
            .map_err(|_| anyhow::anyhow!("could not parse the hook input"))?;
        evaluate(project, &value)
    })();
    match result {
        Ok(Some(reason)) => println!(
            "{}",
            json!({"hookSpecificOutput": {"hookEventName":"PreToolUse", "permissionDecision":"deny", "permissionDecisionReason": reason}})
        ),
        Ok(None) => (),
        Err(error) => eprintln!("squad-devkit-manager-guard: {error}; allowing the tool call"),
    }
    Ok(())
}
