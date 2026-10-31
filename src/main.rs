use anyhow::{bail, Context, Result};
use chrono::TimeZone;
use fs2::FileExt;
use serde::Serialize;
use std::path::{Path, PathBuf};

const DEFAULT_WAIT_TIMEOUT_SECS: u64 = 3_600;

#[derive(Default)]
struct JoinOptions {
    role: Option<String>,
    client_type: Option<String>,
    protocol_version: Option<i64>,
}

/// Clients accepted by `squad join --client`.
const VALID_CLIENTS: [&str; 7] = [
    "claude", "codex", "gemini", "opencode", "grok", "agy", "ccr",
];

fn main() -> Result<()> {
    let mut args = std::env::args().skip(1);
    let command = args.next().unwrap_or_else(|| "help".to_string());

    match command.as_str() {
        "init" => cmd_init(args.collect()),
        "join" => {
            let id = args.next().unwrap_or_default();
            if id.is_empty() {
                bail!("Usage: squad join <id> [--role <role>] [--client <claude|codex|gemini|opencode|grok|agy|ccr>] [--protocol-version <n>]");
            }
            let options = parse_join_args(&id, args.collect())?;
            cmd_join(&id, &options)
        }
        "leave" => {
            let id = args.next().unwrap_or_default();
            if id.is_empty() {
                bail!("Usage: squad leave <id>");
            }
            cmd_leave(&id)
        }
        "agents" => {
            let (show_all, json) = parse_agents_args(args.collect())?;
            cmd_agents(show_all, json)
        }
        "send" => {
            let options = parse_send_args(args.collect())?;
            cmd_send(&options)
        }
        "receive" => {
            let id = args.next().unwrap_or_default();
            if id.is_empty() {
                bail!("Usage: squad receive <id> [--wait [--timeout <secs>]] [--json]");
            }
            let mut wait = false;
            let mut json = false;
            let mut timeout_secs: u64 = DEFAULT_WAIT_TIMEOUT_SECS;
            let mut timeout_provided = false;
            let extra: Vec<String> = args.collect();
            let mut i = 0;
            while i < extra.len() {
                match extra[i].as_str() {
                    "--wait" => {
                        wait = true;
                        i += 1;
                    }
                    "--timeout" => {
                        if let Some(val) = extra.get(i + 1) {
                            timeout_secs = val
                                .parse()
                                .with_context(|| format!("invalid --timeout value: {val}"))?;
                            timeout_provided = true;
                        } else {
                            bail!("--timeout requires a value");
                        }
                        i += 2;
                    }
                    "--json" => {
                        json = true;
                        i += 1;
                    }
                    flag => bail!("unknown receive flag: {flag}"),
                }
            }
            if timeout_provided && !wait {
                bail!("--timeout requires --wait");
            }
            cmd_receive(&id, wait, timeout_secs, json)
        }
        "task" => cmd_task(args.collect()),
        "pending" => cmd_pending(),
        "history" => {
            let options = parse_history_args(args.collect())?;
            cmd_history(&options)
        }
        "roles" => cmd_roles(),
        "teams" => cmd_teams(),
        "team" => {
            let name = args.next().unwrap_or_default();
            if name.is_empty() {
                bail!("Usage: squad team <name>");
            }
            cmd_team(&name)
        }
        "doctor" => cmd_doctor(),
        "setup" => {
            let target = args.next();
            cmd_setup(target.as_deref())
        }
        "clean" => cmd_clean(),
        "cleanup" => cmd_cleanup(),
        "help" | "--help" | "-h" => {
            print_usage();
            Ok(())
        }
        "--version" | "-V" => {
            println!("squad {}", env!("CARGO_PKG_VERSION"));
            Ok(())
        }
        // Treat unknown commands as role-based join: `squad cto` = `squad join cto --role cto`
        other => cmd_join(
            other,
            &JoinOptions {
                role: Some(other.to_string()),
                ..JoinOptions::default()
            },
        ),
    }
}

// --- Helpers ---

struct SendOptions {
    from: String,
    to: String,
    message: String,
    task_id: Option<String>,
    reply_to: Option<i64>,
}

fn parse_join_args(id: &str, args: Vec<String>) -> Result<JoinOptions> {
    let mut options = JoinOptions {
        role: Some(id.to_string()),
        ..JoinOptions::default()
    };
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--role" => {
                let value = args.get(i + 1).context("--role requires a value")?;
                if value.starts_with("--") {
                    bail!("--role requires a value");
                }
                options.role = Some(value.clone());
                i += 2;
            }
            "--client" => {
                let value = args.get(i + 1).context("--client requires a value")?;
                if value.starts_with("--") {
                    bail!("--client requires a value");
                }
                match value.as_str() {
                    v if VALID_CLIENTS.contains(&v) => options.client_type = Some(value.clone()),
                    _ => bail!("invalid --client value: {value}"),
                }
                i += 2;
            }
            "--protocol-version" => {
                let value = args
                    .get(i + 1)
                    .context("--protocol-version requires a value")?;
                if value.starts_with("--") {
                    bail!("--protocol-version requires a value");
                }
                options.protocol_version = Some(
                    value
                        .parse()
                        .with_context(|| format!("invalid --protocol-version value: {value}"))?,
                );
                i += 2;
            }
            flag => bail!("unknown join flag: {flag}"),
        }
    }
    Ok(options)
}

fn parse_agents_args(args: Vec<String>) -> Result<(bool, bool)> {
    let mut show_all = false;
    let mut json = false;
    for arg in args {
        match arg.as_str() {
            "--all" => show_all = true,
            "--json" => json = true,
            _ => bail!("Usage: squad agents [--all] [--json]"),
        }
    }
    Ok((show_all, json))
}

fn parse_send_args(args: Vec<String>) -> Result<SendOptions> {
    let mut task_id = None;
    let mut reply_to = None;
    let mut file_path = None;
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--task-id" => {
                let value = args.get(i + 1).context("--task-id requires a value")?;
                task_id = Some(value.clone());
                i += 2;
            }
            "--reply-to" => {
                let value = args
                    .get(i + 1)
                    .context("--reply-to requires a message id")?;
                reply_to = Some(
                    value
                        .parse()
                        .with_context(|| format!("invalid --reply-to value: {value}"))?,
                );
                i += 2;
            }
            "--file" => {
                let value = args.get(i + 1).context("--file requires a path or -")?;
                file_path = Some(value.clone());
                i += 2;
            }
            _ => break,
        }
    }

    let remaining = &args[i..];
    let usage = "Usage: squad send [--task-id <id>] [--reply-to <message-id>] <from> <to> <message>\n   or: squad send [--task-id <id>] [--reply-to <message-id>] --file <path-or-> <from> <to>";

    if let Some(path) = file_path {
        if remaining.len() != 2 {
            bail!("{usage}");
        }
        let message = read_send_content(&path)?;
        return Ok(SendOptions {
            from: remaining[0].clone(),
            to: remaining[1].clone(),
            message,
            task_id,
            reply_to,
        });
    }

    if remaining.len() < 3 {
        bail!("{usage}");
    }

    let message = remaining[2..].join(" ");
    if message.is_empty() {
        bail!("{usage}");
    }

    Ok(SendOptions {
        from: remaining[0].clone(),
        to: remaining[1].clone(),
        message,
        task_id,
        reply_to,
    })
}

#[derive(Default)]
struct TaskListOptions {
    assigned_to: Option<String>,
    status: Option<String>,
}

#[derive(Serialize)]
struct ReceiveEnvelope {
    id: i64,
    from: String,
    to: String,
    content: String,
    created_at: i64,
    read: bool,
    kind: String,
    task_id: Option<String>,
    reply_to: Option<i64>,
    task: Option<squad::tasks::TaskRecord>,
}

#[derive(Serialize)]
struct AgentEnvelope {
    id: String,
    role: String,
    joined_at: i64,
    last_seen: Option<i64>,
    status: String,
    archived_at: Option<i64>,
    client_type_raw: Option<String>,
    protocol_version_raw: Option<i64>,
    effective_client_type: String,
    effective_protocol_version: i64,
    supports_task_commands: bool,
    supports_json_receive: bool,
}

#[derive(Default)]
struct HistoryOptions {
    agent: Option<String>,
    from: Option<String>,
    to: Option<String>,
    since: Option<i64>,
}

fn parse_history_args(args: Vec<String>) -> Result<HistoryOptions> {
    let mut options = HistoryOptions::default();
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--from" => {
                let value = args.get(i + 1).context("--from requires an agent ID")?;
                options.from = Some(value.clone());
                i += 2;
            }
            "--to" => {
                let value = args.get(i + 1).context("--to requires an agent ID")?;
                options.to = Some(value.clone());
                i += 2;
            }
            "--since" => {
                let value = args
                    .get(i + 1)
                    .context("--since requires an RFC3339 timestamp or unix seconds")?;
                options.since = Some(parse_since(value)?);
                i += 2;
            }
            value if value.starts_with("--") => {
                bail!("unknown history flag: {value}");
            }
            value => {
                if options.agent.is_some() {
                    bail!("Usage: squad history [agent] [--from <id>] [--to <id>] [--since <RFC3339|unix-seconds>]");
                }
                options.agent = Some(value.to_string());
                i += 1;
            }
        }
    }
    Ok(options)
}

fn parse_since(value: &str) -> Result<i64> {
    if let Ok(ts) = value.parse::<i64>() {
        return Ok(ts);
    }
    let dt = chrono::DateTime::parse_from_rfc3339(value)
        .with_context(|| format!("invalid --since value: {value}"))?;
    Ok(dt.timestamp())
}

fn format_history_timestamp(timestamp: i64) -> String {
    chrono::Utc
        .timestamp_opt(timestamp, 0)
        .single()
        .map(|dt| dt.to_rfc3339_opts(chrono::SecondsFormat::Secs, true))
        .unwrap_or_else(|| timestamp.to_string())
}

fn format_history_entry(msg: &squad::store::MessageRecord) -> String {
    let marker = if msg.read { "  " } else { "* " };
    let prefix = format!(
        "{marker}[{}] {} -> {}: ",
        format_history_timestamp(msg.created_at),
        msg.from_agent,
        msg.to_agent
    );
    let mut lines = msg.content.lines();
    let first = lines.next().unwrap_or_default();
    let mut rendered = format!("{prefix}{first}");
    for line in lines {
        rendered.push('\n');
        rendered.push_str("  | ");
        rendered.push_str(line);
    }
    rendered
}

fn effective_client_type(agent: &squad::store::AgentRecord) -> &str {
    agent.client_type_raw.as_deref().unwrap_or("unknown")
}

fn effective_protocol_version(agent: &squad::store::AgentRecord) -> i64 {
    agent
        .protocol_version_raw
        .unwrap_or(squad::setup::DEFAULT_PROTOCOL_VERSION)
}

fn supports_capability(agent: &squad::store::AgentRecord) -> bool {
    effective_protocol_version(agent) >= 2
}

fn agent_envelope(agent: &squad::store::AgentRecord) -> AgentEnvelope {
    AgentEnvelope {
        id: agent.id.clone(),
        role: agent.role.clone(),
        joined_at: agent.joined_at,
        last_seen: agent.last_seen,
        status: agent.status.clone(),
        archived_at: agent.archived_at,
        client_type_raw: agent.client_type_raw.clone(),
        protocol_version_raw: agent.protocol_version_raw,
        effective_client_type: effective_client_type(agent).to_string(),
        effective_protocol_version: effective_protocol_version(agent),
        supports_task_commands: supports_capability(agent),
        supports_json_receive: supports_capability(agent),
    }
}

fn read_send_content(path: &str) -> Result<String> {
    let content = if path == "-" {
        let mut stdin = std::io::stdin();
        let mut content = String::new();
        use std::io::Read;
        stdin.read_to_string(&mut content)?;
        content
    } else {
        std::fs::read_to_string(path)
            .with_context(|| format!("failed to read message file: {path}"))?
    };
    if content.is_empty() {
        bail!("message content is empty");
    }
    Ok(content)
}

fn find_workspace() -> Result<PathBuf> {
    let mut dir = std::env::current_dir()?;
    loop {
        if dir.join(".squad").exists() {
            return Ok(dir);
        }
        if !dir.pop() {
            bail!("Not a squad workspace. Run 'squad init' first.");
        }
    }
}

fn open_store(workspace: &Path) -> Result<squad::store::Store> {
    let db_path = workspace.join(".squad").join("messages.db");
    squad::store::Store::open(&db_path)
}

fn ensure_agent_exists(store: &squad::store::Store, id: &str) -> Result<()> {
    store.require_active_agent(id)
}

fn sessions_dir(workspace: &Path) -> PathBuf {
    workspace.join(".squad").join("sessions")
}

/// Check if this agent's session is still valid. Returns Ok(()) if valid or if
/// no session tracking exists (backward compat). Errors with "Session replaced" if displaced.
fn check_session(workspace: &Path, store: &squad::store::Store, agent_id: &str) -> Result<()> {
    let token = store.get_session_token(agent_id)?;
    check_session_token(workspace, store, agent_id, token.as_deref())?;
    Ok(())
}

fn check_session_token(
    workspace: &Path,
    store: &squad::store::Store,
    agent_id: &str,
    expected_token: Option<&str>,
) -> Result<()> {
    store.require_active_agent(agent_id)?;
    let current_token = store.get_session_token(agent_id)?;
    if let Some(expected) = expected_token {
        match current_token.as_deref() {
            Some(current) if current == expected => {}
            Some(_) | None => bail!(
                "Session replaced. Another terminal joined as {agent_id}. \
                 Re-join with a different ID (e.g. squad join {agent_id}-2 --role <your-role>)."
            ),
        }
    }
    let sessions = sessions_dir(workspace);
    if let Some(token) = expected_token {
        squad::session::validate(&sessions, agent_id, token)?;
    }
    Ok(())
}

fn print_messages(
    store: &squad::store::Store,
    messages: &[squad::store::MessageRecord],
    receiver: Option<&str>,
) -> Result<()> {
    for msg in messages {
        if msg.kind == "task_assigned" {
            let task = msg
                .task_id
                .as_deref()
                .and_then(|task_id| store.get_task(task_id).transpose())
                .transpose()?;
            println!(
                "[task {}] queued from {}",
                msg.task_id.as_deref().unwrap_or("unknown"),
                msg.from_agent
            );
            println!("  Title: {}", msg.content);
            if let Some(task) = task {
                println!("  Body: {}", task.body);
                println!(
                    "  Assigned to: {}",
                    task.assigned_to.unwrap_or_else(|| "unassigned".to_string())
                );
                println!("  Status: {}", task.status);
            }
            if let Some(id) = receiver {
                if let Some(task_id) = &msg.task_id {
                    println!(
                        "  → Reply: squad send --task-id {task_id} {id} {} \"<your response>\"",
                        msg.from_agent
                    );
                }
            }
        } else {
            println!("[from {}] {}", msg.from_agent, msg.content);
            if let Some(id) = receiver {
                println!(
                    "  → Reply: squad send {id} {} \"<your response>\"",
                    msg.from_agent
                );
            }
        }
    }
    if let Some(id) = receiver {
        if !messages.is_empty() {
            println!(
                "  → After processing, run `squad receive {id} --wait` to continue listening."
            );
        }
    }
    Ok(())
}

fn json_messages(
    store: &squad::store::Store,
    messages: Vec<squad::store::MessageRecord>,
) -> Result<Vec<String>> {
    let mut envelopes = Vec::with_capacity(messages.len());
    for msg in messages {
        let task = if msg.kind == "task_assigned" {
            msg.task_id
                .as_deref()
                .and_then(|task_id| store.get_task(task_id).transpose())
                .transpose()?
        } else {
            None
        };
        envelopes.push(ReceiveEnvelope {
            id: msg.id,
            from: msg.from_agent,
            to: msg.to_agent,
            content: msg.content,
            created_at: msg.created_at,
            read: msg.read,
            kind: msg.kind,
            task_id: msg.task_id,
            reply_to: msg.reply_to,
            task,
        });
    }
    envelopes
        .into_iter()
        .map(|envelope| serde_json::to_string(&envelope).map_err(Into::into))
        .collect()
}

fn print_json_messages(
    store: &squad::store::Store,
    messages: Vec<squad::store::MessageRecord>,
) -> Result<()> {
    for line in json_messages(store, messages)? {
        println!("{line}");
    }
    Ok(())
}

// --- Commands ---

fn cmd_init(args: Vec<String>) -> Result<()> {
    let mut refresh_roles = false;
    for arg in args {
        match arg.as_str() {
            "--refresh-roles" => refresh_roles = true,
            _ => bail!("Usage: squad init [--refresh-roles]"),
        }
    }

    let workspace = std::env::current_dir()?;
    squad::init::init_workspace_with_options(&workspace, refresh_roles)?;
    println!("Initialized squad workspace.");

    // Auto-update outdated slash commands
    let updated = squad::setup::check_and_update_commands();
    if !updated.is_empty() {
        println!("Updated slash commands:");
        for (name, path) in &updated {
            println!("  {} → {}", name, path.display());
        }
    }
    Ok(())
}

fn cmd_join(id: &str, options: &JoinOptions) -> Result<()> {
    let workspace = find_workspace()?;
    let store = open_store(&workspace)?;
    let role = options.role.as_deref().unwrap_or(id);
    let (actual_id, token) = store.register_agent_unique_with_metadata(
        id,
        role,
        options.client_type.as_deref(),
        options.protocol_version,
    )?;
    store.touch_agent(&actual_id)?;
    squad::session::write_token(&sessions_dir(&workspace), &actual_id, &token)?;
    if actual_id != id {
        println!("ID '{id}' was taken. Joined as {actual_id} (role: {role}).");
    } else {
        println!("Joined as {actual_id} (role: {role}).");
    }

    match squad::roles::load_role(&workspace, role) {
        Ok(prompt) => {
            println!("\n=== Role Instructions ===\n{prompt}");
        }
        Err(_) => {
            println!("\nNo predefined template for \"{role}\". Interpret this role autonomously.");
            println!("Communicate using: squad send, squad receive, squad agents");
            println!("Tip: create .squad/roles/{role}.md to customize behavior.");
            let roles = squad::roles::list_roles(&workspace);
            println!("Predefined roles: {}", roles.join(", "));
        }
    }
    Ok(())
}

fn cmd_leave(id: &str) -> Result<()> {
    let workspace = find_workspace()?;
    let store = open_store(&workspace)?;
    store.unregister_agent(id)?;
    squad::session::delete_token(&sessions_dir(&workspace), id)?;
    println!("{id} archived from the squad. Unread work was preserved.");
    Ok(())
}

fn cmd_agents(show_all: bool, json: bool) -> Result<()> {
    let workspace = find_workspace()?;
    let store = open_store(&workspace)?;
    let agents = store.list_agents(show_all)?;
    if json {
        for agent in &agents {
            println!("{}", serde_json::to_string(&agent_envelope(agent))?);
        }
        return Ok(());
    }
    if agents.is_empty() {
        if show_all {
            println!("No agents found.");
        } else {
            println!("No agents online.");
        }
    } else {
        let now = chrono::Utc::now().timestamp();
        for agent in &agents {
            let status = if agent.status == "archived" {
                let suffix = agent
                    .archived_at
                    .map(|ts| format!(" at {}", format_history_timestamp(ts)))
                    .unwrap_or_default();
                format!("archived{suffix}")
            } else {
                match agent.last_seen {
                    Some(ts) => {
                        let ago = now - ts;
                        if ago < 60 {
                            format!("active ({}s ago)", ago)
                        } else if ago < 600 {
                            format!("idle ({}m ago)", ago / 60)
                        } else {
                            format!("stale ({}m ago)", ago / 60)
                        }
                    }
                    None => "unknown".to_string(),
                }
            };
            let capability_suffix = format!(
                " [client: {}, protocol: {}]",
                effective_client_type(agent),
                effective_protocol_version(agent)
            );
            println!(
                "  {} (role: {}) — {}{}",
                agent.id, agent.role, status, capability_suffix
            );
        }
    }
    Ok(())
}

fn cmd_send(options: &SendOptions) -> Result<()> {
    let workspace = find_workspace()?;
    let store = open_store(&workspace)?;
    let now = chrono::Utc::now().timestamp();
    ensure_agent_exists(&store, &options.from)?;
    check_session(&workspace, &store, &options.from)?;
    store.touch_agent(&options.from)?;
    if options.to == "@all" {
        if options.task_id.is_some() || options.reply_to.is_some() {
            bail!("task-linked send metadata is only supported for direct messages");
        }
        let recipients = store.broadcast_message(&options.from, &options.message)?;
        println!(
            "Broadcast to {} agents: {}",
            recipients.len(),
            recipients.join(", ")
        );
        if let Some(warning) = stale_broadcast_warning(&store.list_agents(false)?, &recipients, now)
        {
            println!("{warning}");
        }
    } else {
        store.send_message_checked_with_metadata(
            &options.from,
            &options.to,
            &options.message,
            options.task_id.as_deref(),
            options.reply_to,
        )?;
        println!("Sent to {}.", options.to);
        if let Some(agent) = store
            .list_agents(false)?
            .into_iter()
            .find(|agent| agent.id == options.to)
        {
            if let Some(warning) = stale_direct_warning(&agent, now) {
                println!("{warning}");
            }
        }
    }
    Ok(())
}

fn stale_minutes(last_seen: Option<i64>, now: i64) -> Option<i64> {
    let ago = now - last_seen?;
    if ago >= 600 {
        Some(ago / 60)
    } else {
        None
    }
}

fn stale_direct_warning(agent: &squad::store::AgentRecord, now: i64) -> Option<String> {
    let minutes = stale_minutes(agent.last_seen, now)?;
    Some(format!(
        "Warning: {} is stale (last seen {}m ago). Message was queued but may not be seen soon.",
        agent.id, minutes
    ))
}

fn stale_broadcast_warning(
    agents: &[squad::store::AgentRecord],
    recipients: &[String],
    now: i64,
) -> Option<String> {
    let stale: Vec<String> = agents
        .iter()
        .filter(|agent| recipients.iter().any(|recipient| recipient == &agent.id))
        .filter_map(|agent| {
            let minutes = stale_minutes(agent.last_seen, now)?;
            Some(format!("{} ({}m ago)", agent.id, minutes))
        })
        .collect();
    if stale.is_empty() {
        None
    } else {
        Some(format!("Warning: stale recipients: {}.", stale.join(", ")))
    }
}

fn cmd_receive(agent: &str, wait: bool, timeout_secs: u64, json: bool) -> Result<()> {
    let workspace = find_workspace()?;

    // Validate session at entry (catches displacement immediately)
    let store = open_store(&workspace)?;
    ensure_agent_exists(&store, agent)?;
    let session_token = store.get_session_token(agent)?;
    check_session(&workspace, &store, agent)?;
    store.touch_agent(agent)?;

    if wait {
        // Acquire exclusive file lock to prevent multiple concurrent receive --wait
        // processes from competing for the same agent's messages.
        let lock_dir = workspace.join("locks");
        std::fs::create_dir_all(&lock_dir)?;
        let lock_path = lock_dir.join(format!("{}.receive.lock", agent));
        let lock_file = std::fs::File::create(&lock_path)
            .with_context(|| format!("failed to create lock file: {}", lock_path.display()))?;
        if lock_file.try_lock_exclusive().is_err() {
            bail!(
                "Another `squad receive --wait` is already running for agent '{}'. \
                 Only one receive --wait per agent is allowed. Use `squad receive {}` \
                 (without --wait) for non-blocking polling.",
                agent,
                agent
            );
        }
        // Keep _lock_file alive for the duration of the wait loop (lock released on drop).
        let _lock_guard = lock_file;

        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(timeout_secs);
        let mut last_heartbeat = std::time::Instant::now();
        loop {
            let store = open_store(&workspace)?;

            // Re-check for displacement on each poll (~500ms)
            check_session_token(&workspace, &store, agent, session_token.as_deref())?;

            // Heartbeat: update last_seen every 30s so other agents know we're alive
            if last_heartbeat.elapsed() >= std::time::Duration::from_secs(30) {
                store.touch_agent(agent)?;
                last_heartbeat = std::time::Instant::now();
            }

            if store.has_unread_messages(agent)? {
                let messages = store.receive_messages(agent)?;
                if !messages.is_empty() {
                    if json {
                        print_json_messages(&store, messages)?;
                    } else {
                        print_messages(&store, &messages, Some(agent))?;
                    }
                    return Ok(());
                }
            }
            if std::time::Instant::now() > deadline {
                if json {
                    return Ok(());
                } else {
                    println!(
                        "No new messages (timed out after {timeout_secs}s). Run `squad receive {agent} --wait` to continue listening."
                    );
                }
                return Ok(());
            }
            std::thread::sleep(std::time::Duration::from_millis(500));
        }
    } else {
        let messages = store.receive_messages(agent)?;
        if messages.is_empty() {
            if json {
                return Ok(());
            } else {
                println!("No new messages. Run `squad receive {agent} --wait` to keep listening.");
            }
        } else {
            if json {
                print_json_messages(&store, messages)?;
            } else {
                print_messages(&store, &messages, Some(agent))?;
            }
        }
        Ok(())
    }
}

fn cmd_task(args: Vec<String>) -> Result<()> {
    let subcommand = args.first().map(String::as_str).unwrap_or_default();
    match subcommand {
        "create" => {
            if args.len() < 5 {
                bail!("Usage: squad task create <from> <to> --title <title> [--body <body>]");
            }
            let (title, body) = parse_task_create_args(&args[1..])?;
            cmd_task_create(&args[1], &args[2], &title, body.as_deref().unwrap_or(""))
        }
        "ack" => {
            if args.len() != 3 {
                bail!("Usage: squad task ack <agent> <task-id>");
            }
            cmd_task_ack(&args[1], &args[2])
        }
        "complete" => {
            if args.len() < 5 {
                bail!("Usage: squad task complete <agent> <task-id> --summary <text>");
            }
            let summary = parse_task_complete_args(&args[1..])?;
            cmd_task_complete(&args[1], &args[2], &summary)
        }
        "requeue" => {
            if args.len() != 2 && args.len() != 4 {
                bail!("Usage: squad task requeue <task-id> [--to <agent>]");
            }
            let assignee = match args.get(2).map(String::as_str) {
                Some("--to") => Some(args.get(3).context("--to requires an agent id")?.as_str()),
                Some(flag) => bail!("unknown task requeue flag: {flag}"),
                None => None,
            };
            cmd_task_requeue(&args[1], assignee)
        }
        "list" => cmd_task_list(parse_task_list_args(&args[1..])?),
        _ => bail!("Usage: squad task <create|ack|complete|requeue|list> ..."),
    }
}

fn parse_task_list_args(args: &[String]) -> Result<TaskListOptions> {
    let mut options = TaskListOptions::default();
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--agent" => {
                let value = args.get(i + 1).context("--agent requires an agent id")?;
                options.assigned_to = Some(value.clone());
                i += 2;
            }
            "--status" => {
                let value = args.get(i + 1).context("--status requires a value")?;
                options.status = Some(value.clone());
                i += 2;
            }
            flag => bail!("unknown task list flag: {flag}"),
        }
    }
    Ok(options)
}

fn parse_task_create_args(args: &[String]) -> Result<(String, Option<String>)> {
    let mut title = None;
    let mut body = None;
    let mut i = 2;
    while i < args.len() {
        match args[i].as_str() {
            "--title" => {
                let value = args.get(i + 1).context("--title requires a value")?;
                title = Some(value.clone());
                i += 2;
            }
            "--body" => {
                let value = args.get(i + 1).context("--body requires a value")?;
                body = Some(value.clone());
                i += 2;
            }
            flag => bail!("unknown task create flag: {flag}"),
        }
    }

    let title = title.context("--title is required")?;
    Ok((title, body))
}

fn parse_task_complete_args(args: &[String]) -> Result<String> {
    let mut summary = None;
    let mut i = 2;
    while i < args.len() {
        match args[i].as_str() {
            "--summary" => {
                let value = args.get(i + 1).context("--summary requires a value")?;
                summary = Some(value.clone());
                i += 2;
            }
            flag => bail!("unknown task complete flag: {flag}"),
        }
    }

    summary.context("--summary is required")
}

fn cmd_task_create(from: &str, to: &str, title: &str, body: &str) -> Result<()> {
    let workspace = find_workspace()?;
    let store = open_store(&workspace)?;
    ensure_agent_exists(&store, from)?;
    check_session(&workspace, &store, from)?;
    store.touch_agent(from)?;
    let task_id = store.create_task(from, to, title, body)?;
    println!("Created task {task_id} for {to}: {title}");
    Ok(())
}

fn cmd_task_ack(agent: &str, task_id: &str) -> Result<()> {
    let workspace = find_workspace()?;
    let store = open_store(&workspace)?;
    ensure_agent_exists(&store, agent)?;
    check_session(&workspace, &store, agent)?;
    store.touch_agent(agent)?;
    store.ack_task(agent, task_id)?;
    println!("Acked task {task_id}.");
    Ok(())
}

fn cmd_task_complete(agent: &str, task_id: &str, summary: &str) -> Result<()> {
    let workspace = find_workspace()?;
    let store = open_store(&workspace)?;
    ensure_agent_exists(&store, agent)?;
    check_session(&workspace, &store, agent)?;
    store.touch_agent(agent)?;
    store.complete_task(agent, task_id, summary)?;
    println!("Completed task {task_id}: {summary}");
    Ok(())
}

fn cmd_task_requeue(task_id: &str, assigned_to: Option<&str>) -> Result<()> {
    let workspace = find_workspace()?;
    let store = open_store(&workspace)?;
    store.requeue_task(task_id, assigned_to)?;
    match assigned_to {
        Some(agent) => println!("Requeued task {task_id} to {agent}."),
        None => println!("Requeued task {task_id}."),
    }
    Ok(())
}

fn cmd_task_list(options: TaskListOptions) -> Result<()> {
    let workspace = find_workspace()?;
    let store = open_store(&workspace)?;
    let tasks = store.list_tasks(options.assigned_to.as_deref(), options.status.as_deref())?;
    if tasks.is_empty() {
        println!("No tasks found.");
    } else {
        for task in tasks {
            println!("[task {}] {}", task.id, task.status,);
            println!(
                "  assigned_to: {}",
                task.assigned_to.unwrap_or_else(|| "unassigned".to_string())
            );
            println!(
                "  lease_owner: {}",
                task.lease_owner.unwrap_or_else(|| "unleased".to_string())
            );
            println!("  title: {}", task.title);
            println!("  created_by: {}", task.created_by);
            if task.body.contains('\n') {
                println!("  body:");
                for line in task.body.lines() {
                    println!("    {line}");
                }
            } else {
                println!("  body: {}", task.body);
            }
            if let Some(summary) = task.result_summary {
                println!("  result: {summary}");
            }
        }
    }
    Ok(())
}

fn cmd_pending() -> Result<()> {
    let workspace = find_workspace()?;
    let store = open_store(&workspace)?;
    let messages = store.pending_messages()?;
    if messages.is_empty() {
        println!("No pending messages.");
    } else {
        println!("Pending messages:");
        for msg in &messages {
            let preview: String = msg.content.chars().take(60).collect();
            let suffix = if msg.content.chars().count() > 60 {
                "..."
            } else {
                ""
            };
            println!(
                "  {} -> {}: {}{}",
                msg.from_agent, msg.to_agent, preview, suffix
            );
        }
    }
    Ok(())
}

fn cmd_history(options: &HistoryOptions) -> Result<()> {
    let workspace = find_workspace()?;
    let store = open_store(&workspace)?;
    let messages = store
        .all_messages(options.agent.as_deref())?
        .into_iter()
        .filter(|msg| {
            options
                .from
                .as_ref()
                .map(|from| msg.from_agent == *from)
                .unwrap_or(true)
        })
        .filter(|msg| {
            options
                .to
                .as_ref()
                .map(|to| msg.to_agent == *to)
                .unwrap_or(true)
        })
        .filter(|msg| {
            options
                .since
                .map(|since| msg.created_at >= since)
                .unwrap_or(true)
        })
        .collect::<Vec<_>>();
    if messages.is_empty() {
        println!("No message history.");
    } else {
        for msg in &messages {
            println!("{}", format_history_entry(msg));
        }
    }
    Ok(())
}

fn cmd_roles() -> Result<()> {
    let workspace = find_workspace()?;
    let roles = squad::roles::list_roles(&workspace);
    println!("Available roles:");
    for role in &roles {
        println!("  {role}");
    }
    Ok(())
}

fn cmd_teams() -> Result<()> {
    let workspace = find_workspace()?;
    let teams = squad::teams::list_teams(&workspace);
    println!("Available teams:");
    for team in &teams {
        println!("  {team}");
    }
    Ok(())
}

fn cmd_team(name: &str) -> Result<()> {
    let workspace = find_workspace()?;
    let team = squad::teams::load_team(&workspace, name)?;
    println!("Team: {}", team.name);
    println!("Roles:");
    for (role_id, role) in &team.roles {
        println!("  {role_id} (prompt: {})", role.prompt_file);
        println!("    → squad join {role_id} --role {}", role.prompt_file);
    }
    Ok(())
}

fn cmd_clean() -> Result<()> {
    let workspace = find_workspace()?;
    let db_path = workspace.join(".squad").join("messages.db");
    if db_path.exists() {
        std::fs::remove_file(&db_path)?;
    }
    // Also remove WAL and SHM files
    let wal = workspace.join(".squad").join("messages.db-wal");
    let shm = workspace.join(".squad").join("messages.db-shm");
    if wal.exists() {
        std::fs::remove_file(&wal)?;
    }
    if shm.exists() {
        std::fs::remove_file(&shm)?;
    }
    squad::session::delete_all(&workspace.join(".squad").join("sessions"))?;
    println!("Cleaned squad state.");
    Ok(())
}

fn cmd_cleanup() -> Result<()> {
    let removed = squad::setup::cleanup_commands();
    if removed.is_empty() {
        println!("No slash command files found to remove.");
    } else {
        for (name, path) in &removed {
            println!("  Removed {} → {}", name, path.display());
        }
        println!("Cleaned up {} slash command file(s).", removed.len());
    }
    Ok(())
}

fn cmd_doctor() -> Result<()> {
    let workspace = find_workspace()?;
    let store = open_store(&workspace)?;

    // 1. Template diagnostics
    let home = PathBuf::from(std::env::var("HOME").context("HOME not set")?);
    let installed_platforms: Vec<&squad::setup::Platform> = squad::setup::PLATFORMS
        .iter()
        .filter(|p| squad::setup::is_installed(p.binary))
        .collect();
    let template_diags =
        squad::setup::diagnose_templates_for_platforms(&installed_platforms, &home)?;
    for line in &template_diags {
        println!("{line}");
    }

    // 2. Archived agents with pending tasks
    let archived_pending = store.archived_agents_with_pending_tasks()?;
    if archived_pending.is_empty() {
        println!("OK: no archived agents with pending tasks");
    } else {
        for (agent_id, task_ids) in &archived_pending {
            println!(
                "WARN: archived agent {} has pending tasks: {}",
                agent_id,
                task_ids.join(", ")
            );
        }
    }

    // 3. Protocol compatibility for active agents
    let below_protocol = store.active_agents_below_protocol(
        squad::setup::SUPPORTED_PROTOCOL_VERSION,
        squad::setup::DEFAULT_PROTOCOL_VERSION,
    )?;
    if below_protocol.is_empty() {
        println!("OK: all agents meet protocol threshold");
    } else {
        for (agent_id, effective_version) in &below_protocol {
            println!(
                "WARN: {} has effective_protocol_version={}; task commands should fall back to send/receive",
                agent_id, effective_version
            );
        }
    }

    Ok(())
}

fn cmd_setup(target: Option<&str>) -> Result<()> {
    match target {
        Some("--list") => {
            println!("Supported platforms:");
            for p in squad::setup::PLATFORMS {
                let status = if squad::setup::is_installed(p.binary) {
                    "installed"
                } else {
                    "not found"
                };
                println!("  {} ({}: {})", p.name, p.binary, status);
            }
            Ok(())
        }
        Some(name) => {
            let platform = squad::setup::PLATFORMS
                .iter()
                .find(|p| p.name == name)
                .with_context(|| format!("unknown platform: {name}. Run 'squad setup --list'"))?;
            let path = squad::setup::install_for_platform(platform)?;
            println!("Installed squad for {} → {}", name, path.display());
            Ok(())
        }
        None => {
            println!("Detecting installed AI tools...");
            let results = squad::setup::run_setup();
            if results.is_empty() {
                println!("No supported AI tools found in PATH.");
                println!("Supported: claude, gemini, codex, opencode");
                return Ok(());
            }
            for (name, path, result) in &results {
                match result {
                    Ok(()) => println!("  {} → {}", name, path.display()),
                    Err(e) => println!("  {} — {}", name, e),
                }
            }
            let ok_count = results.iter().filter(|(_, _, r)| r.is_ok()).count();
            println!("Installed squad for {} tool(s).", ok_count);
            Ok(())
        }
    }
}

fn print_usage() {
    print!("{HELP_TEXT}");
}

const HELP_TEXT: &str = r#"squad — Multi-AI-agent terminal collaboration

COMMANDS
  squad init [--refresh-roles]              Initialize workspace (`--refresh-roles` rewrites builtin roles only)
  squad join <id> [--role <role>] [--client <claude|codex|gemini|opencode|grok|agy|ccr>] [--protocol-version <n>]
                                             Join as agent (role defaults to id; omitted metadata stays NULL)
  squad leave <id>                           Archive agent
  squad agents [--all] [--json]              List online agents (`--all` includes archived agents; `--json` emits one JSON object per line with raw/effective capability fields)
  squad send [--task-id <id>] [--reply-to <message-id>] <from> <to> <message>
                                             Send message (`squad send --file <path-or-> <from> <to>` reads from file/stdin)
  squad receive <id> [--wait] [--timeout N] [--json]
                                             Check inbox (`--wait` blocks until a message arrives, default 86400s; `--json` emits one JSON object per line)
  squad task create <from> <to> --title <title> [--body <body>]
                                             Create a structured task assignment
  squad task ack <agent> <task-id>           Acknowledge a queued task
  squad task complete <agent> <task-id> --summary <text>
                                             Complete an acked task with a result summary
  squad task requeue <task-id> [--to <agent>]
                                             Requeue a task, optionally to a new assignee
  squad task list [--agent <id>] [--status <status>]
                                             List tasks with optional filters
  squad pending                              Show all unread messages
  squad history [agent] [--from <id>] [--to <id>] [--since <RFC3339|unix-seconds>]
                                             Show messages with timestamps and optional filters
  squad roles                                List available roles
  squad teams                                List available teams
  squad team <name>                          Show team template
  squad doctor                                 Run compatibility diagnostics (read-only)
  squad setup [platform]                      Install /squad slash command for AI tools
  squad setup --list                         List supported platforms
  squad clean                                Clear all state
  squad cleanup                              Remove installed slash commands from all AI tools

QUICK START
  1. squad init                              Set up workspace
  2. squad join manager --role manager --client claude --protocol-version 2
                                             Join as manager in terminal 1
  3. squad join worker --role worker --client codex --protocol-version 2
                                             Join as worker in terminal 2
  4. squad task create manager worker --title "task" --body "details..."
                                             Manager assigns a structured task
  5. squad receive worker                     Worker checks once for tasks
  6. squad task ack worker <task-id>          Worker claims the task
  7. squad task complete worker <task-id> --summary "done..."
                                             Worker reports structured completion

HOW TO PARTICIPATE
  When told a role (e.g. "you are manager"), run:
  1. squad join <role> --role <role>          Register and read role instructions
                                             Optional: add `--client ... --protocol-version ...` to record capabilities
  2. Do your work as instructed by the role
  3. Prefer `squad task ...` when tracking assignment state matters
  4. Use `squad send` / `squad receive` as the fallback path for freeform coordination
  5. squad receive <your-id>                  Check once for next task or feedback

EXAMPLES
  squad task create manager worker --title "auth-module" --body "implement auth module with JWT"
  squad send --task-id <task-id> inspector worker "follow-up on edge cases"
  squad send manager @all "API contract updated, rebase your work"
  squad receive worker --json
  squad history worker --from manager --since 2024-01-02T00:00:00Z
"#;
