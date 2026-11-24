use squad::teams::{default_team, list_teams, load_team, BUILTIN_TEAMS};
use std::fs;
use tempfile::TempDir;

#[test]
fn test_builtin_teams_exist() {
    assert!(BUILTIN_TEAMS.contains(&"dev"));
}

#[test]
fn test_default_dev_team() {
    let team = default_team("dev").unwrap();
    assert_eq!(team.name, "dev");
    assert!(team.roles.contains_key("manager"));
    assert!(team.roles.contains_key("worker"));
    assert!(team.roles.contains_key("inspector"));
}

#[test]
fn test_load_builtin_team() {
    let tmp = TempDir::new().unwrap();
    let team = load_team(tmp.path(), "dev").unwrap();
    assert_eq!(team.name, "dev");
    assert_eq!(team.roles.len(), 3);
}

#[test]
fn test_load_custom_team_from_disk() {
    let tmp = TempDir::new().unwrap();
    let teams_dir = tmp.path().join(".squad").join("teams");
    fs::create_dir_all(&teams_dir).unwrap();
    fs::write(
        teams_dir.join("frontend.yaml"),
        "name: frontend\nroles:\n  designer:\n    prompt_file: designer\n  developer:\n    prompt_file: worker\n",
    )
    .unwrap();

    let team = load_team(tmp.path(), "frontend").unwrap();
    assert_eq!(team.name, "frontend");
    assert_eq!(team.roles.len(), 2);
    assert!(team.roles.contains_key("designer"));
}

#[test]
fn test_load_custom_team_from_yml() {
    let tmp = TempDir::new().unwrap();
    let teams_dir = tmp.path().join(".squad").join("teams");
    fs::create_dir_all(&teams_dir).unwrap();
    fs::write(
        teams_dir.join("qa.yml"),
        "name: qa\nroles:\n  tester:\n    prompt_file: tester\n",
    )
    .unwrap();

    let team = load_team(tmp.path(), "qa").unwrap();
    assert_eq!(team.name, "qa");
    assert!(team.roles.contains_key("tester"));
}

#[test]
fn test_yaml_preferred_over_yml() {
    let tmp = TempDir::new().unwrap();
    let teams_dir = tmp.path().join(".squad").join("teams");
    fs::create_dir_all(&teams_dir).unwrap();
    fs::write(
        teams_dir.join("x.yaml"),
        "name: yaml-team\nroles:\n  yaml_role:\n    prompt_file: yaml\n",
    )
    .unwrap();
    fs::write(
        teams_dir.join("x.yml"),
        "name: yml-team\nroles:\n  yml_role:\n    prompt_file: yml\n",
    )
    .unwrap();

    let team = load_team(tmp.path(), "x").unwrap();
    assert_eq!(team.name, "yaml-team");
    assert!(team.roles.contains_key("yaml_role"));
    assert!(!team.roles.contains_key("yml_role"));
}

#[test]
fn test_custom_team_overrides_builtin() {
    let tmp = TempDir::new().unwrap();
    let teams_dir = tmp.path().join(".squad").join("teams");
    fs::create_dir_all(&teams_dir).unwrap();
    fs::write(
        teams_dir.join("dev.yaml"),
        "name: dev\nroles:\n  lead:\n    prompt_file: manager\n",
    )
    .unwrap();

    let team = load_team(tmp.path(), "dev").unwrap();
    assert_eq!(team.roles.len(), 1);
    assert!(team.roles.contains_key("lead"));
}

#[test]
fn test_unknown_team_fails() {
    let tmp = TempDir::new().unwrap();
    let result = load_team(tmp.path(), "nonexistent");
    assert!(result.is_err());
    assert!(result.unwrap_err().to_string().contains("unknown team"));
}

#[test]
fn test_list_teams_includes_custom() {
    let tmp = TempDir::new().unwrap();
    let teams_dir = tmp.path().join(".squad").join("teams");
    fs::create_dir_all(&teams_dir).unwrap();
    fs::write(
        teams_dir.join("frontend.yaml"),
        "name: frontend\nroles: {}\n",
    )
    .unwrap();

    let teams = list_teams(tmp.path());
    assert!(teams.contains(&"dev".to_string()));
    assert!(teams.contains(&"frontend".to_string()));
}
