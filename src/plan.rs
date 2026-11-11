use anyhow::{bail, Result};
use std::{collections::HashSet, fs, io::Write, path::Path};

pub fn section(text: &str, name: &str) -> Option<String> {
    let mut found = false;
    let mut inside = false;
    let mut body = String::new();
    for line in text.split_terminator('\n') {
        if let Some(heading) = line.strip_prefix("## ") {
            inside = heading
                .trim_start_matches(' ')
                .trim_end_matches([' ', '\t', ':'])
                .eq_ignore_ascii_case(name);
            found |= inside;
        } else if inside {
            body.push_str(line);
            body.push('\n');
        }
    }
    found.then_some(body)
}

pub fn triage(text: &str, label: &str) -> String {
    for line in section(text, "Triage")
        .unwrap_or_default()
        .split_terminator('\n')
    {
        let line = line.trim_start_matches([' ', '\t']);
        let line = match line.strip_prefix('-').or_else(|| line.strip_prefix('*')) {
            Some(v) if v.starts_with([' ', '\t']) => v.trim_start_matches([' ', '\t']),
            _ => line,
        };
        if let Some((key, value)) = line.split_once(':') {
            if key.eq_ignore_ascii_case(label) {
                return value.trim_matches([' ', '\t']).to_owned();
            }
        }
    }
    String::new()
}

pub fn level(text: &str, label: &str) -> String {
    triage(text, label)
        .split([' ', '\t', '\n'])
        .find(|s| !s.is_empty())
        .unwrap_or_default()
        .to_lowercase()
        .trim_end_matches(['.', ',', ';', ':', ')', '—', '-'])
        .to_owned()
}

pub fn validate(path: &Path) -> Result<bool> {
    if !path.is_file() {
        println!("file not found: {}", path.display());
        return Ok(false);
    }
    let text = fs::read_to_string(path)?;
    let mut valid = true;
    for name in ["Triage", "Goal", "Perspectives", "Tasks", "Acceptance"] {
        if section(&text, name).is_none() {
            println!("missing section: ## {name}");
            valid = false;
        }
    }
    if section(&text, "Triage").is_some() {
        for label in ["Risk", "Complexity"] {
            if !["low", "moderate", "high"].contains(&level(&text, label).as_str()) {
                println!("missing triage line: - {label}: low|moderate|high");
                valid = false;
            }
        }
        if triage(&text, "squad-route").is_empty() {
            println!("missing triage line: - squad-route: <route>");
            valid = false;
        }
    }
    if let Some(body) = section(&text, "Perspectives") {
        for label in [
            "Principal engineer",
            "Engineering manager",
            "Technical lead",
            "QA/QC",
            "End user",
        ] {
            if !body.to_lowercase().contains(&label.to_lowercase()) {
                println!("missing perspective: {label}");
                valid = false;
            }
        }
    }
    Ok(valid)
}

pub fn approves(text: &str, action: &str, repo: &str, repo_path: &str) -> bool {
    let physical = fs::canonicalize(repo_path).ok();
    let target = physical.as_deref().unwrap_or_else(|| Path::new(repo_path));
    for line in section(text, "Approvals")
        .unwrap_or_default()
        .split_terminator('\n')
    {
        let line = line.trim_start_matches([' ', '\t']);
        let Some(line) = line.strip_prefix('-').or_else(|| line.strip_prefix('*')) else {
            continue;
        };
        if !line.starts_with([' ', '\t']) {
            continue;
        }
        let Some((key, value)) = line.trim_start_matches([' ', '\t']).split_once(':') else {
            continue;
        };
        if !key.eq_ignore_ascii_case(action) {
            continue;
        }
        let value = value
            .trim_start_matches([' ', '\t'])
            .split([' ', '\t'])
            .next()
            .unwrap_or_default()
            .split('—')
            .next()
            .unwrap_or_default();
        if value == "*" {
            return true;
        }
        if value.starts_with('/') {
            let value = if value == "/" {
                value
            } else {
                value.trim_end_matches('/')
            };
            if !repo_path.is_empty()
                && (Path::new(value) == target
                    || fs::canonicalize(value).ok().as_deref() == Some(target))
            {
                return true;
            }
        } else if !value.is_empty() && value == repo {
            return true;
        }
    }
    false
}

pub fn approval_files(
    dir: &Path,
    action: &str,
    repo: &str,
    repo_path: &str,
) -> Result<Vec<std::path::PathBuf>> {
    if !dir.is_dir() {
        return Ok(vec![]);
    }
    let Ok(entries) = fs::read_dir(dir) else {
        return Ok(vec![]);
    };
    let mut files: Vec<_> = entries
        .filter_map(|entry| entry.ok().map(|entry| entry.path()))
        .collect();
    files.retain(|p| {
        p.extension().is_some_and(|e| e == "md")
            && !p
                .file_name()
                .unwrap_or_default()
                .to_string_lossy()
                .starts_with('.')
    });
    files.sort_by(|a, b| {
        b.metadata()
            .and_then(|m| m.modified())
            .ok()
            .cmp(&a.metadata().and_then(|m| m.modified()).ok())
            .then_with(|| a.cmp(b))
    });
    let mut result = vec![];
    for file in files {
        if let Ok(bytes) = fs::read(&file) {
            if approves(&String::from_utf8_lossy(&bytes), action, repo, repo_path) {
                result.push(file);
            }
        }
    }
    Ok(result)
}

fn doc(path: &str) -> bool {
    [".md", ".mdx", ".rst"]
        .iter()
        .any(|e| path.to_lowercase().ends_with(e))
}
fn sensitive(path: &str) -> bool {
    let lower = path.to_lowercase();
    [
        "secret",
        "credential",
        "password",
        "private_key",
        "private-key",
        "_headers",
        "netlify.toml",
        "vercel.json",
    ]
    .iter()
    .any(|p| lower.contains(p))
        || (!doc(path) && lower.contains("security"))
        || lower.match_indices("token").any(|(i, _)| {
            let rest = &lower[i + 5..];
            let rest = rest.strip_prefix('s').unwrap_or(rest);
            rest.chars().next().is_none_or(|c| !c.is_ascii_lowercase())
        })
        || lower.split('/').any(|p| {
            let stem = p.split('.').next().unwrap_or_default();
            p == ".env"
                || p.starts_with(".env.")
                || ((stem.starts_with("auth") || stem.starts_with("oauth"))
                    && !stem.starts_with("author"))
        })
}

pub fn check_patch(text: &str) -> Vec<String> {
    let mut reasons = vec![];
    let mut seen = HashSet::new();
    let mut flags = [false; 4];
    let mut docs = false;
    for line in text.split_terminator('\n') {
        if let Some(rest) = line.strip_prefix("diff --git ") {
            let rest = rest.replace('"', "");
            let same = rest.match_indices(" b/").find_map(|(i, _)| {
                let a = rest[..i].strip_prefix("a/")?;
                (a == &rest[i + 3..]).then_some((a, a))
            });
            let (a, b) = same
                .or_else(|| {
                    rest.split_once(" b/")
                        .map(|(a, b)| (a.strip_prefix("a/").unwrap_or(a), b))
                })
                .unwrap_or((&rest, &rest));
            for path in [a, b] {
                if seen.insert(path.to_owned()) && sensitive(path) {
                    reasons.push(format!("patch touches {path}"));
                }
            }
            docs = doc(a) && doc(b);
            continue;
        }
        if !line.starts_with(['+', '-']) || line.starts_with("+++") || line.starts_with("---") {
            continue;
        }
        let lower = line.to_lowercase();
        let private = line.match_indices("BEGIN ").any(|(i, _)| {
            line[i + 6..]
                .split_once("PRIVATE KEY")
                .is_some_and(|(prefix, _)| {
                    prefix.chars().all(|c| c.is_ascii_alphabetic() || c == ' ')
                })
        });
        for (i, (matches, reason)) in [
            (private, "patch changes a private key"),
            (
                !docs && lower.contains("content-security-policy"),
                "patch changes a Content-Security-Policy line",
            ),
            (
                !docs && lower.contains("authorization"),
                "patch changes an Authorization line",
            ),
            (
                !docs
                    && ["apikey", "api_key", "api-key"]
                        .iter()
                        .any(|v| lower.contains(v)),
                "patch changes an API key line",
            ),
        ]
        .into_iter()
        .enumerate()
        {
            if matches && !flags[i] {
                reasons.push(reason.to_owned());
                flags[i] = true;
            }
        }
    }
    reasons
}

pub fn command(args: &[String]) -> Result<bool> {
    match args {
        [op, file] if op == "validate" => validate(Path::new(file)),
        [op, file] if op == "check-patch" => { for reason in check_patch(&fs::read_to_string(file)?) { println!("{reason}"); } Ok(true) },
        [op, file] if op == "context" => {
            if !Path::new(file).is_file() { return Ok(true); }
            let text = fs::read_to_string(file)?;
            for name in ["Goal", "Findings", "Decisions"] {
                if let Some(body) = section(&text, name) {
                    let body = body.split_terminator('\n').skip_while(|l| l.trim_matches([' ', '\t']).is_empty()).collect::<Vec<_>>().join("\n");
                    let body = body.trim_end_matches('\n');
                    if !body.is_empty() { println!("### Plan {name}\n{body}\n"); }
                }
            }
            let companion = format!("{}.context.md", file.strip_suffix(".md").unwrap_or(file));
            if companion != *file && Path::new(&companion).is_file() {
                let bytes = fs::read(&companion)?;
                if !bytes.is_empty() {
                    let max: usize = std::env::var("SQUAD_WORKER_MAX_CONTEXT_BYTES").ok().filter(|v| !v.is_empty()).unwrap_or_else(|| "16384".into()).parse()?;
                    println!("### Shared Context ({})", Path::new(&companion).file_name().unwrap_or_default().to_string_lossy());
                    std::io::stdout().write_all(&bytes[..bytes.len().min(max)])?;
                    println!("\n");
                }
            }
            Ok(true)
        },
        [op, dir, action, repo, rest @ ..] if op == "approves" && rest.len() <= 1 => {
            let files = approval_files(Path::new(dir), action, repo, rest.first().map(String::as_str).unwrap_or_default())?;
            for file in &files { println!("{}", file.display()); }
            Ok(!files.is_empty())
        },
        _ => bail!("Usage: squad plan validate|context|check-patch <file> | approves <dir> <action> <repo> [<repo_path>]"),
    }
}
