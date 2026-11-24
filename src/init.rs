use anyhow::{Context, Result};
use std::path::Path;

use crate::roles;
use crate::teams;

pub fn init_workspace(workspace: &Path) -> Result<()> {
    init_workspace_with_options(workspace, false)
}

pub fn init_workspace_with_options(workspace: &Path, refresh_roles: bool) -> Result<()> {
    let squad_dir = workspace.join(".squad");
    let roles_dir = squad_dir.join("roles");
    let teams_dir = squad_dir.join("teams");

    std::fs::create_dir_all(&roles_dir)
        .with_context(|| format!("failed to create {}", roles_dir.display()))?;
    std::fs::create_dir_all(&teams_dir)
        .with_context(|| format!("failed to create {}", teams_dir.display()))?;
    let sessions_dir = squad_dir.join("sessions");
    std::fs::create_dir_all(&sessions_dir)
        .with_context(|| format!("failed to create {}", sessions_dir.display()))?;

    // Write builtin role templates. Plain init is non-destructive; refresh rewrites builtins only.
    for role in roles::BUILTIN_ROLES {
        let path = roles_dir.join(format!("{role}.md"));
        if !path.exists() || refresh_roles {
            if let Some(content) = roles::default_role_prompt(role) {
                std::fs::write(&path, content)
                    .with_context(|| format!("failed to write {}", path.display()))?;
            }
        }
    }

    // Write builtin team templates (skip if already exist)
    for team_name in teams::BUILTIN_TEAMS {
        let path = teams_dir.join(format!("{team_name}.yaml"));
        if !path.exists() {
            if let Some(team) = teams::default_team(team_name) {
                let content = serde_yaml::to_string(&team)
                    .with_context(|| format!("failed to serialize team: {team_name}"))?;
                std::fs::write(&path, content)
                    .with_context(|| format!("failed to write {}", path.display()))?;
            }
        }
    }

    // Add .squad/ to .gitignore
    append_if_missing(workspace, ".gitignore", ".squad/")?;

    // Add squad instructions to agent config files
    let squad_section = SQUAD_AGENT_INSTRUCTIONS;
    let marker = "## Squad Collaboration";
    for filename in &["CLAUDE.md", "AGENTS.md", "GEMINI.md"] {
        append_section_if_missing(workspace, filename, marker, squad_section)?;
    }

    Ok(())
}

const SQUAD_AGENT_INSTRUCTIONS: &str = "\
## Squad Collaboration

This project uses squad for multi-agent collaboration. Run `squad help` for all commands and usage guide.\n";

fn append_if_missing(workspace: &Path, filename: &str, entry: &str) -> Result<()> {
    let path = workspace.join(filename);
    let needs_add = if path.exists() {
        let content = std::fs::read_to_string(&path)?;
        !content.lines().any(|line| line.trim() == entry)
    } else {
        true
    };
    if needs_add {
        use std::io::Write;
        let mut file = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&path)?;
        writeln!(file, "{entry}")?;
    }
    Ok(())
}

fn append_section_if_missing(
    workspace: &Path,
    filename: &str,
    marker: &str,
    content: &str,
) -> Result<()> {
    let path = workspace.join(filename);
    if path.exists() {
        let existing = std::fs::read_to_string(&path)?;
        if existing.contains(marker) {
            return Ok(());
        }
    }
    use std::io::Write;
    let mut file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)?;
    writeln!(file, "\n{content}")?;
    Ok(())
}

/// Returns false when an existing manifest was preserved.
pub fn init_harness(workspace: &Path, force: bool) -> Result<bool> {
    use crate::harness_config::{detect_default_harness, render_harness_toml};
    use std::io::Write;
    let path = workspace.join(".squad/harness.toml");
    std::fs::create_dir_all(workspace.join(".squad"))?;
    let mut options = std::fs::OpenOptions::new();
    options.write(true);
    if force {
        options.create(true).truncate(true);
    } else {
        options.create_new(true);
    }
    let mut file = match options.open(&path) {
        Ok(file) => file,
        Err(e) if !force && e.kind() == std::io::ErrorKind::AlreadyExists => return Ok(false),
        Err(e) => return Err(e).with_context(|| format!("failed to write {}", path.display())),
    };
    file.write_all(render_harness_toml(&detect_default_harness(workspace)).as_bytes())
        .with_context(|| format!("failed to write {}", path.display()))?;
    Ok(true)
}
