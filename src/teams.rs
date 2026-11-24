use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::Path;

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct TeamConfig {
    pub name: String,
    pub roles: BTreeMap<String, TeamRole>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct TeamRole {
    pub prompt_file: String,
}

pub const BUILTIN_TEAMS: &[&str] = &["dev"];

pub fn default_team(name: &str) -> Option<TeamConfig> {
    match name {
        "dev" => {
            let mut roles = BTreeMap::new();
            roles.insert(
                "manager".to_string(),
                TeamRole {
                    prompt_file: "manager".to_string(),
                },
            );
            roles.insert(
                "worker".to_string(),
                TeamRole {
                    prompt_file: "worker".to_string(),
                },
            );
            roles.insert(
                "inspector".to_string(),
                TeamRole {
                    prompt_file: "inspector".to_string(),
                },
            );
            Some(TeamConfig {
                name: "dev".to_string(),
                roles,
            })
        }
        _ => None,
    }
}

pub fn load_team(workspace: &Path, name: &str) -> Result<TeamConfig> {
    let teams_dir = workspace.join(".squad").join("teams");
    let yaml_path = teams_dir.join(format!("{name}.yaml"));
    let custom_path = if yaml_path.exists() {
        yaml_path
    } else {
        teams_dir.join(format!("{name}.yml"))
    };
    if custom_path.exists() {
        let content = std::fs::read_to_string(&custom_path)
            .with_context(|| format!("failed to read team: {}", custom_path.display()))?;
        let config: TeamConfig = serde_yaml::from_str(&content)
            .with_context(|| format!("failed to parse team: {}", custom_path.display()))?;
        return Ok(config);
    }
    default_team(name).with_context(|| {
        format!(
            "unknown team: {name}. Available: {}",
            BUILTIN_TEAMS.join(", ")
        )
    })
}

pub fn list_teams(workspace: &Path) -> Vec<String> {
    let mut teams: Vec<String> = BUILTIN_TEAMS.iter().map(|s| s.to_string()).collect();
    let custom_dir = workspace.join(".squad").join("teams");
    if let Ok(entries) = std::fs::read_dir(&custom_dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().is_some_and(|e| e == "yaml" || e == "yml") {
                if let Some(name) = path.file_stem() {
                    let name = name.to_string_lossy().to_string();
                    if !teams.contains(&name) {
                        teams.push(name);
                    }
                }
            }
        }
    }
    teams.sort();
    teams
}
