use anyhow::{Context, Result};
use serde::Serialize;
use std::fs;
use std::path::Path;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum LintSeverity {
    Warn,
    Error,
}
#[derive(Debug, Clone, Serialize)]
pub struct LintFinding {
    pub severity: LintSeverity,
    pub path: String,
    pub code: String,
    pub message: String,
    pub bytes: Option<usize>,
}
#[derive(Debug, Clone, Serialize)]
pub struct LintLimits {
    pub root_instruction_warn: usize,
    pub root_instruction_error: usize,
    pub worker_role_warn: usize,
    pub worker_role_error: usize,
    pub manager_role_warn: usize,
    pub manager_role_error: usize,
    pub knowledge_max_bytes: usize,
}
impl Default for LintLimits {
    fn default() -> Self {
        Self {
            root_instruction_warn: 8192,
            root_instruction_error: 32768,
            worker_role_warn: 4096,
            worker_role_error: 16384,
            manager_role_warn: 24576,
            manager_role_error: 32768,
            knowledge_max_bytes: 2048,
        }
    }
}
#[derive(Debug, Clone, Default, Serialize)]
pub struct LintReport {
    pub checked_files: usize,
    pub total_bytes: usize,
    pub findings: Vec<LintFinding>,
}
impl LintReport {
    pub fn error_count(&self) -> usize {
        self.findings
            .iter()
            .filter(|f| f.severity == LintSeverity::Error)
            .count()
    }
    pub fn warn_count(&self) -> usize {
        self.findings
            .iter()
            .filter(|f| f.severity == LintSeverity::Warn)
            .count()
    }
    pub fn has_errors(&self) -> bool {
        self.error_count() > 0
    }
    pub fn passed(&self, strict: bool) -> bool {
        !self.has_errors() && (!strict || self.warn_count() == 0)
    }
    fn add(
        &mut self,
        path: &Path,
        severity: LintSeverity,
        code: &str,
        message: &str,
        bytes: Option<usize>,
    ) {
        self.findings.push(LintFinding {
            severity,
            path: path.display().to_string(),
            code: code.into(),
            message: message.into(),
            bytes,
        });
    }
}
#[derive(Clone, Copy)]
enum Category {
    Root,
    Worker,
    Manager,
    Knowledge,
    Other,
}
fn category(path: &Path) -> Category {
    let name = path.file_name().and_then(|s| s.to_str()).unwrap_or("");
    let p = path.to_string_lossy().replace('\\', "/");
    if matches!(name, "AGENTS.md" | "CLAUDE.md" | "GEMINI.md") {
        Category::Root
    } else if p.contains("/.squad/rules/") || p.contains("/.squad/knowledge/pending/") {
        Category::Knowledge
    } else if name == "manager-devkit.md" {
        Category::Manager
    } else {
        Category::Worker
    }
}
fn placeholder(text: &str) -> bool {
    let mut fence: Option<(char, usize)> = None;
    for line in text.lines() {
        let trimmed = line.trim_start();
        let marker = trimmed.chars().next().filter(|c| *c == '`' || *c == '~');
        if let Some(c) = marker {
            let n = trimmed.chars().take_while(|x| *x == c).count();
            if n >= 3 {
                if let Some((fc, len)) = fence {
                    if c == fc && n >= len {
                        fence = None;
                    }
                } else {
                    fence = Some((c, n));
                }
                continue;
            }
        }
        if fence.is_some() {
            continue;
        }
        let mut rest = line;
        while let Some(i) = rest.find('`') {
            if rest[..i].contains("{{") || rest[..i].contains("{%") {
                return true;
            }
            let ticks = rest[i..].bytes().take_while(|b| *b == b'`').count();
            let after = &rest[i + ticks..];
            let delimiter = "`".repeat(ticks);
            if let Some(end) = after.find(&delimiter) {
                rest = &after[end + ticks..];
            } else {
                rest = after;
            }
        }
        if rest.contains("{{") || rest.contains("{%") {
            return true;
        }
    }
    false
}
fn check(path: &Path, cat: Category, limits: &LintLimits, report: &mut LintReport) -> Result<()> {
    let metadata =
        fs::symlink_metadata(path).with_context(|| format!("reading {}", path.display()))?;
    if metadata.file_type().is_symlink() {
        report.add(
            path,
            LintSeverity::Error,
            "symlink",
            "symlinks are not allowed",
            None,
        );
        return Ok(());
    }
    if !metadata.is_file() {
        return Ok(());
    }
    let bytes = usize::try_from(metadata.len()).unwrap_or(usize::MAX);
    report.checked_files += 1;
    report.total_bytes = report.total_bytes.saturating_add(bytes);
    let (warn, error) = match cat {
        Category::Root => (limits.root_instruction_warn, limits.root_instruction_error),
        Category::Worker => (limits.worker_role_warn, limits.worker_role_error),
        Category::Manager => (limits.manager_role_warn, limits.manager_role_error),
        Category::Knowledge => (limits.knowledge_max_bytes, limits.knowledge_max_bytes),
        Category::Other => (limits.root_instruction_error, limits.root_instruction_error),
    };
    if bytes > error {
        report.add(
            path,
            LintSeverity::Error,
            "size_error",
            &format!("file exceeds {error} bytes"),
            Some(bytes),
        );
    } else if bytes > warn {
        report.add(
            path,
            LintSeverity::Warn,
            "size_warn",
            &format!("file exceeds {warn} bytes"),
            Some(bytes),
        );
    }
    if path.extension().is_some_and(|e| e == "md") {
        let text =
            fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))?;
        if matches!(cat, Category::Worker | Category::Manager) {
            let body = if text.starts_with("<!-- squad-devkit template") {
                text.split_once('\n').map_or("", |(_, body)| body)
            } else {
                &text
            };
            if body.trim().is_empty() {
                report.add(
                    path,
                    LintSeverity::Error,
                    "empty_role",
                    "role is empty",
                    Some(bytes),
                );
            }
        }
        if matches!(cat, Category::Knowledge) {
            let mut lines = text.lines();
            let valid = lines.next().is_some_and(|l| l.trim() == "---") && {
                let mut frontmatter = String::new();
                let mut closed = false;
                for line in lines {
                    if line.trim() == "---" {
                        closed = true;
                        break;
                    }
                    frontmatter.push_str(line);
                    frontmatter.push('\n');
                }
                let value = serde_yaml::from_str::<serde_yaml::Value>(&frontmatter).ok();
                closed
                    && value
                        .and_then(|v| v.get("paths").cloned())
                        .is_some_and(|v| match v {
                            serde_yaml::Value::String(s) => !s.trim().is_empty(),
                            serde_yaml::Value::Sequence(s) => !s.is_empty(),
                            _ => false,
                        })
            };
            if !valid {
                report.add(
                    path,
                    LintSeverity::Warn,
                    "missing_paths",
                    "missing frontmatter with non-empty paths",
                    None,
                );
            }
        }
        if placeholder(&text) {
            report.add(
                path,
                LintSeverity::Warn,
                "template_placeholder",
                "unexpanded template placeholder",
                None,
            );
        }
    }
    Ok(())
}
fn entries(path: &Path) -> Result<Vec<std::path::PathBuf>> {
    let mut paths = fs::read_dir(path)?
        .map(|e| e.map(|e| e.path()))
        .collect::<std::io::Result<Vec<_>>>()?;
    paths.sort();
    Ok(paths)
}
pub fn lint_workspace(root: &Path, limits: &LintLimits) -> Result<LintReport> {
    let metadata =
        fs::symlink_metadata(root).with_context(|| format!("reading {}", root.display()))?;
    anyhow::ensure!(
        metadata.is_dir(),
        "workspace is not a directory: {}",
        root.display()
    );
    let mut report = LintReport::default();
    for name in ["AGENTS.md", "CLAUDE.md", "GEMINI.md"] {
        let p = root.join(name);
        if fs::symlink_metadata(&p).is_ok() {
            check(&p, Category::Root, limits, &mut report)?;
        }
    }
    for dir in [
        ".squad/roles",
        "templates/devkit",
        ".squad/rules",
        ".squad/knowledge/pending",
    ] {
        let mut p = root.to_path_buf();
        let mut valid = true;
        for component in Path::new(dir).components() {
            p.push(component);
            match fs::symlink_metadata(&p) {
                Ok(m) if m.file_type().is_symlink() => {
                    if !report
                        .findings
                        .iter()
                        .any(|f| f.code == "symlink" && f.path == p.display().to_string())
                    {
                        report.add(
                            &p,
                            LintSeverity::Error,
                            "symlink",
                            "symlinks are not allowed",
                            None,
                        );
                    }
                    valid = false;
                    break;
                }
                Ok(m) if m.is_dir() => {}
                Ok(_) => {
                    valid = false;
                    break;
                }
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                    valid = false;
                    break;
                }
                Err(e) => return Err(e.into()),
            }
        }
        if !valid {
            continue;
        }
        for file in entries(&p)? {
            if file.extension().is_some_and(|e| e == "md") {
                let cat = if dir.contains("rules") || dir.contains("pending") {
                    Category::Knowledge
                } else {
                    category(&file)
                };
                check(&file, cat, limits, &mut report)?;
            }
        }
    }
    Ok(report)
}
fn walk(path: &Path, limits: &LintLimits, report: &mut LintReport) -> Result<()> {
    let meta = fs::symlink_metadata(path)?;
    if meta.file_type().is_symlink() {
        report.add(
            path,
            LintSeverity::Error,
            "symlink",
            "symlinks are not allowed",
            None,
        );
    } else if meta.is_dir() {
        for p in entries(path)? {
            walk(&p, limits, report)?;
        }
    } else if meta.is_file() {
        let cat = if path.extension().is_some_and(|e| e == "md") {
            category(path)
        } else {
            Category::Other
        };
        let start = report.findings.len();
        check(path, cat, limits, report)?;
        if meta.len() > limits.root_instruction_error as u64
            && !report.findings[start..]
                .iter()
                .any(|f| f.code == "size_error")
        {
            report.add(
                path,
                LintSeverity::Error,
                "size_error",
                &format!("file exceeds {} bytes", limits.root_instruction_error),
                Some(usize::try_from(meta.len()).unwrap_or(usize::MAX)),
            );
        }
    }
    Ok(())
}
pub fn lint_harness_path(path: &Path, limits: &LintLimits) -> Result<LintReport> {
    let meta = fs::symlink_metadata(path)?;
    let mut report = LintReport::default();
    if meta.is_dir() {
        walk(path, limits, &mut report)?;
        if report.checked_files == 0 {
            report.add(
                path,
                LintSeverity::Error,
                "empty_harness",
                "harness contains no files",
                None,
            );
        }
    } else if meta.file_type().is_symlink() {
        report.add(
            path,
            LintSeverity::Error,
            "symlink",
            "symlinks are not allowed",
            None,
        );
    } else {
        check(path, category(path), limits, &mut report)?;
        if meta.len() == 0 && !report.findings.iter().any(|f| f.code == "empty_role") {
            report.add(
                path,
                LintSeverity::Error,
                "empty_harness",
                "harness contains no files",
                None,
            );
        }
    }
    Ok(report)
}
