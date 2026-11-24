use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use std::{collections::HashSet, path::Path};

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
pub struct HarnessConfig {
    pub version: u32,
    pub gates: GatesConfig,
    pub policy: PolicyConfig,
    pub budgets: BudgetsConfig,
    pub sandbox: SandboxConfig,
}
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Default)]
pub struct GatesConfig {
    pub pre_merge: Vec<String>,
    pub post_merge: Vec<String>,
}
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Default)]
pub struct PolicyConfig {
    pub protected_paths: Vec<String>,
    pub require_review_paths: Vec<String>,
    pub max_diff_lines: Option<u64>,
}
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Default)]
pub struct BudgetsConfig {
    pub worker_max_tokens: Option<u64>,
    pub worker_max_usd: Option<f64>,
    pub plan_max_usd: Option<f64>,
}
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Default)]
pub struct SandboxConfig {
    pub profile: SandboxProfile,
    pub network: NetworkPolicy,
}
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Default)]
#[serde(rename_all = "lowercase")]
pub enum SandboxProfile {
    Strict,
    #[default]
    Workspace,
    Off,
}
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Default)]
#[serde(rename_all = "lowercase")]
pub enum NetworkPolicy {
    #[default]
    Deny,
    Allow,
}

impl Default for HarnessConfig {
    fn default() -> Self {
        Self {
            version: 1,
            gates: GatesConfig::default(),
            policy: PolicyConfig::default(),
            budgets: BudgetsConfig::default(),
            sandbox: SandboxConfig::default(),
        }
    }
}

struct Parser {
    chars: Vec<char>,
    pos: usize,
    line: usize,
}
impl Parser {
    fn peek(&self) -> Option<char> {
        self.chars.get(self.pos).copied()
    }
    fn take(&mut self) -> Option<char> {
        let c = self.peek()?;
        self.pos += 1;
        if c == '\n' {
            self.line += 1;
        }
        Some(c)
    }
    fn space(&mut self, multiline: bool) {
        loop {
            while matches!(self.peek(), Some(' ' | '\t' | '\r'))
                || (multiline && self.peek() == Some('\n'))
            {
                self.take();
            }
            if self.peek() == Some('#') {
                while !matches!(self.peek(), None | Some('\n')) {
                    self.take();
                }
            } else {
                break;
            }
        }
    }
    fn expect(&mut self, c: char) -> Result<()> {
        if self.take() != Some(c) {
            bail!("expected {c:?}");
        }
        Ok(())
    }
    fn name(&mut self) -> Result<String> {
        let mut s = String::new();
        while self
            .peek()
            .is_some_and(|c| c.is_ascii_alphanumeric() || c == '_')
        {
            s.push(self.take().unwrap());
        }
        if s.is_empty() {
            bail!("expected name");
        }
        Ok(s)
    }
    fn string(&mut self) -> Result<String> {
        let quote = self.take().context("expected string")?;
        if quote != '"' && quote != '\'' {
            bail!("expected quoted string");
        }
        let mut s = String::new();
        loop {
            let c = self.take().context("unterminated string")?;
            if c == quote {
                return Ok(s);
            }
            if c.is_control() && c != '\t' {
                bail!("control character in string");
            }
            if c == '\\' && quote == '"' {
                let escaped = match self.take().context("incomplete escape")? {
                    '"' => '"',
                    '\\' => '\\',
                    'b' => '\u{8}',
                    't' => '\t',
                    'n' => '\n',
                    'f' => '\u{c}',
                    'r' => '\r',
                    c @ ('u' | 'U') => {
                        let n = if c == 'u' { 4 } else { 8 };
                        let mut value = 0u32;
                        for _ in 0..n {
                            value = value.checked_mul(16).context("invalid unicode escape")?
                                + self
                                    .take()
                                    .and_then(|c| c.to_digit(16))
                                    .context("invalid unicode escape")?;
                        }
                        char::from_u32(value).context("invalid unicode scalar")?
                    }
                    _ => bail!("invalid escape"),
                };
                if escaped == '\0'
                    || (escaped.is_control()
                        && !matches!(escaped, '\t' | '\n' | '\r' | '\u{8}' | '\u{c}'))
                {
                    bail!("control character in escape");
                }
                s.push(escaped);
            } else {
                s.push(c);
            }
        }
    }
    fn array(&mut self) -> Result<Vec<String>> {
        self.expect('[')?;
        self.space(true);
        let mut values = Vec::new();
        if self.peek() == Some(']') {
            self.take();
            return Ok(values);
        }
        loop {
            values.push(self.string()?);
            self.space(true);
            match self.take() {
                Some(']') => return Ok(values),
                Some(',') => {
                    self.space(true);
                    if self.peek() == Some(']') {
                        self.take();
                        return Ok(values);
                    }
                }
                _ => bail!("expected comma or closing bracket"),
            }
        }
    }
    fn number(&mut self) -> Result<String> {
        let mut s = String::new();
        while self.peek().is_some_and(|c| !c.is_whitespace() && c != '#') {
            s.push(self.take().unwrap());
        }
        if s.is_empty() {
            bail!("expected number");
        }
        let bytes = s.as_bytes();
        for (i, &b) in bytes.iter().enumerate() {
            if b == b'_'
                && (i == 0
                    || i + 1 == bytes.len()
                    || !bytes[i - 1].is_ascii_digit()
                    || !bytes[i + 1].is_ascii_digit())
            {
                bail!("digit separator must be between ASCII digits");
            }
        }
        Ok(s.replace('_', ""))
    }
    fn integer(&mut self) -> Result<u64> {
        let s = self.number()?;
        if !s.bytes().all(|b| b.is_ascii_digit()) || (s.len() > 1 && s.starts_with('0')) {
            bail!("expected non-negative decimal integer");
        }
        s.parse().context("integer out of range")
    }
    fn float(&mut self) -> Result<f64> {
        let s = self.number()?;
        // Validate decimal grammar before parsing: Rust also accepts non-TOML floats.
        let unsigned = s.strip_prefix('+').unwrap_or(&s);
        let mut exponent = unsigned.split(['e', 'E']);
        let mantissa = exponent.next().unwrap();
        let exp = exponent.next();
        if exponent.next().is_some() {
            bail!("invalid float");
        }
        if let Some(e) = exp {
            let e = e.strip_prefix(['+', '-']).unwrap_or(e);
            if e.is_empty() || !e.bytes().all(|b| b.is_ascii_digit()) {
                bail!("invalid exponent");
            }
        }
        let mut parts = mantissa.split('.');
        let whole = parts.next().unwrap();
        let fraction = parts.next();
        if whole.is_empty()
            || !whole.bytes().all(|b| b.is_ascii_digit())
            || (whole.len() > 1 && whole.starts_with('0'))
            || parts.next().is_some()
            || fraction.is_some_and(|v| v.is_empty() || !v.bytes().all(|b| b.is_ascii_digit()))
        {
            bail!("invalid positive decimal float");
        }
        let value: f64 = s.parse().context("invalid float")?;
        if !value.is_finite() || value <= 0.0 {
            bail!("expected positive finite float");
        }
        Ok(value)
    }
    fn document(&mut self) -> Result<HarnessConfig> {
        let mut config = HarnessConfig::default();
        let mut section = String::new();
        let mut sections = HashSet::new();
        let mut keys = HashSet::new();
        loop {
            self.space(true);
            if self.peek().is_none() {
                break;
            }
            if self.peek() == Some('[') {
                self.take();
                section = self.name()?;
                if !matches!(section.as_str(), "gates" | "policy" | "budgets" | "sandbox") {
                    bail!("unknown section {section}");
                }
                if !sections.insert(section.clone()) {
                    bail!("duplicate section {section}");
                }
                self.expect(']')?;
            } else {
                let key = self.name()?;
                if !keys.insert((section.clone(), key.clone())) {
                    bail!("duplicate key {key}");
                }
                self.space(false);
                self.expect('=')?;
                self.space(false);
                match (section.as_str(), key.as_str()) {
                    ("", "version") => {
                        if self.integer()? != 1 {
                            bail!("version must be 1");
                        }
                    }
                    ("gates", "pre_merge") => config.gates.pre_merge = self.array()?,
                    ("gates", "post_merge") => config.gates.post_merge = self.array()?,
                    ("policy", "protected_paths") => {
                        config.policy.protected_paths = self.array()?
                    }
                    ("policy", "require_review_paths") => {
                        config.policy.require_review_paths = self.array()?
                    }
                    ("policy", "max_diff_lines") => {
                        config.policy.max_diff_lines = Some(self.integer()?)
                    }
                    ("budgets", "worker_max_tokens") => {
                        config.budgets.worker_max_tokens = Some(self.integer()?)
                    }
                    ("budgets", "worker_max_usd") => {
                        config.budgets.worker_max_usd = Some(self.float()?)
                    }
                    ("budgets", "plan_max_usd") => {
                        config.budgets.plan_max_usd = Some(self.float()?)
                    }
                    ("sandbox", "profile") => {
                        config.sandbox.profile = match self.string()?.as_str() {
                            "strict" => SandboxProfile::Strict,
                            "workspace" => SandboxProfile::Workspace,
                            "off" => SandboxProfile::Off,
                            _ => bail!("invalid sandbox profile"),
                        }
                    }
                    ("sandbox", "network") => {
                        config.sandbox.network = match self.string()?.as_str() {
                            "deny" => NetworkPolicy::Deny,
                            "allow" => NetworkPolicy::Allow,
                            _ => bail!("invalid network policy"),
                        }
                    }
                    _ => bail!("unknown key {key} in section {section:?}"),
                }
            }
            self.space(false);
            if self.peek().is_some() && self.peek() != Some('\n') {
                bail!("unexpected trailing syntax");
            }
        }
        if !keys.contains(&(String::new(), "version".to_owned())) {
            bail!("missing version");
        }
        Ok(config)
    }
}

pub fn parse_harness_toml(text: &str) -> Result<HarnessConfig> {
    for (line, text) in text.split('\n').enumerate() {
        if text
            .chars()
            .any(|c| c.is_control() && !matches!(c, '\t' | '\r'))
        {
            bail!("line {}: invalid control character", line + 1);
        }
    }
    let mut parser = Parser {
        chars: text.chars().collect(),
        pos: 0,
        line: 1,
    };
    parser
        .document()
        .map_err(|e| anyhow::anyhow!("line {}: {e}", parser.line))
}

pub fn load_harness_config(repo_root: &Path) -> Result<Option<HarnessConfig>> {
    let path = repo_root.join(".squad/harness.toml");
    match std::fs::read_to_string(&path) {
        Ok(text) => parse_harness_toml(&text)
            .with_context(|| format!("invalid {}", path.display()))
            .map(Some),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e).with_context(|| format!("failed to read {}", path.display())),
    }
}

pub fn detect_default_harness(repo_root: &Path) -> HarnessConfig {
    let mut c = HarnessConfig::default();
    if repo_root.join("Cargo.toml").is_file() {
        c.gates
            .pre_merge
            .push("cargo clippy --all-targets -- -D warnings".into());
        c.gates.post_merge.push("cargo test --all".into());
    }
    for (detected, command) in [
        (repo_root.join("package.json").is_file(), "npm test"),
        (
            repo_root.join("pyproject.toml").is_file() || repo_root.join("pytest.ini").is_file(),
            "pytest",
        ),
        (repo_root.join("go.mod").is_file(), "go test ./..."),
    ] {
        if detected {
            c.gates.pre_merge.push(command.into());
            c.gates.post_merge.push(command.into());
        }
    }
    c.policy.require_review_paths = vec![
        ".github/**".into(),
        "**/migrations/**".into(),
        "**/auth/**".into(),
    ];
    c
}

pub fn render_harness_toml(c: &HarnessConfig) -> String {
    fn array(v: &[String]) -> String {
        serde_json::to_string(v).expect("string array serialization")
    }
    let mut text = format!("version = {}\n\n[gates]\npre_merge = {}\npost_merge = {}\n\n[policy]\nprotected_paths = {}\nrequire_review_paths = {}\n",
        c.version, array(&c.gates.pre_merge), array(&c.gates.post_merge),
        array(&c.policy.protected_paths), array(&c.policy.require_review_paths));
    if let Some(v) = c.policy.max_diff_lines {
        text.push_str(&format!("max_diff_lines = {v}\n"));
    }
    text.push_str("\n[budgets]\n");
    if let Some(v) = c.budgets.worker_max_tokens {
        text.push_str(&format!("worker_max_tokens = {v}\n"));
    }
    if let Some(v) = c.budgets.worker_max_usd {
        text.push_str(&format!("worker_max_usd = {v}\n"));
    }
    if let Some(v) = c.budgets.plan_max_usd {
        text.push_str(&format!("plan_max_usd = {v}\n"));
    }
    text.push_str(&format!(
        "\n[sandbox]\nprofile = {}\nnetwork = {}\n",
        serde_json::to_string(&c.sandbox.profile).unwrap(),
        serde_json::to_string(&c.sandbox.network).unwrap()
    ));
    text
}
