use anyhow::{Context, Result};
use rusqlite::{params, params_from_iter, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use std::path::Path;

use crate::tasks::TaskRecord;

const DEFAULT_MESSAGE_KIND: &str = "note";
const TASK_ASSIGNED_KIND: &str = "task_assigned";
const TASK_STATUS_QUEUED: &str = "queued";
const TASK_STATUS_ACKED: &str = "acked";
const TASK_STATUS_COMPLETED: &str = "completed";
const TASK_LEASE_SECS: i64 = 15 * 60;

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct AgentRecord {
    pub id: String,
    pub role: String,
    pub joined_at: i64,
    pub last_seen: Option<i64>,
    pub status: String,
    pub archived_at: Option<i64>,
    pub client_type_raw: Option<String>,
    pub protocol_version_raw: Option<i64>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct MessageRecord {
    pub id: i64,
    pub from_agent: String,
    pub to_agent: String,
    pub content: String,
    pub created_at: i64,
    pub read: bool,
    pub kind: String,
    pub task_id: Option<String>,
    pub reply_to: Option<i64>,
}

pub struct Store {
    pub(crate) conn: Connection,
}

impl Store {
    pub fn open(path: &Path) -> Result<Self> {
        let conn = Connection::open(path)
            .with_context(|| format!("failed to open database: {}", path.display()))?;
        conn.busy_timeout(std::time::Duration::from_secs(5))?;
        // Concurrent first opens can return BUSY while enabling WAL without invoking its handler.
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        loop {
            match conn.execute_batch("PRAGMA journal_mode=WAL;") {
                Ok(()) => break,
                Err(error)
                    if matches!(
                        error.sqlite_error_code(),
                        Some(
                            rusqlite::ErrorCode::DatabaseBusy | rusqlite::ErrorCode::DatabaseLocked
                        )
                    ) && std::time::Instant::now() < deadline =>
                {
                    std::thread::sleep(std::time::Duration::from_millis(10));
                }
                Err(error) => return Err(error).context("failed to configure database journal"),
            }
        }
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS agents (
                id TEXT PRIMARY KEY,
                role TEXT NOT NULL,
                joined_at INTEGER NOT NULL,
                session_token TEXT,
                last_seen INTEGER,
                status TEXT NOT NULL DEFAULT 'active',
                archived_at INTEGER,
                client_type TEXT,
                protocol_version INTEGER
             );
             CREATE TABLE IF NOT EXISTS messages (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  from_agent TEXT NOT NULL,
                 to_agent TEXT NOT NULL,
                 content TEXT NOT NULL,
                 created_at INTEGER NOT NULL,
                 read INTEGER NOT NULL DEFAULT 0
             );
             CREATE TABLE IF NOT EXISTS worker_runs (
                 workspace TEXT NOT NULL,
                 run_name TEXT NOT NULL,
                 worker_id TEXT NOT NULL,
                 engine TEXT NOT NULL,
                 state TEXT NOT NULL,
                 verdict TEXT,
                 tokens_in INTEGER CHECK(tokens_in >= 0),
                 tokens_cached INTEGER CHECK(tokens_cached >= 0),
                 tokens_out INTEGER CHECK(tokens_out >= 0),
                 worktree TEXT,
                 status_file TEXT NOT NULL,
                 status_mtime TEXT NOT NULL,
                 status_size INTEGER NOT NULL,
                 details TEXT NOT NULL,
                 PRIMARY KEY (workspace, run_name)
             );
             CREATE TABLE IF NOT EXISTS tasks (
                 id TEXT PRIMARY KEY,
                 title TEXT NOT NULL,
                 body TEXT NOT NULL,
                 created_by TEXT NOT NULL,
                 assigned_to TEXT,
                 status TEXT NOT NULL,
                 lease_owner TEXT,
                 lease_expires_at INTEGER,
                 result_summary TEXT,
                 created_at INTEGER NOT NULL,
                 updated_at INTEGER NOT NULL,
                 completed_at INTEGER
             );",
        )
        .context("failed to initialize database schema")?;
        // Migrations: add columns if missing (existing DBs)
        let _ = conn.execute_batch("ALTER TABLE agents ADD COLUMN session_token TEXT;");
        let _ = conn.execute_batch("ALTER TABLE agents ADD COLUMN last_seen INTEGER;");
        let _ = conn
            .execute_batch("ALTER TABLE agents ADD COLUMN status TEXT NOT NULL DEFAULT 'active';");
        let _ = conn.execute_batch("ALTER TABLE agents ADD COLUMN archived_at INTEGER;");
        let _ = conn.execute_batch("ALTER TABLE agents ADD COLUMN client_type TEXT;");
        let _ = conn.execute_batch("ALTER TABLE agents ADD COLUMN protocol_version INTEGER;");
        let _ = conn
            .execute_batch("ALTER TABLE messages ADD COLUMN kind TEXT NOT NULL DEFAULT 'note';");
        let _ = conn.execute_batch("ALTER TABLE messages ADD COLUMN task_id TEXT;");
        let _ = conn.execute_batch("ALTER TABLE messages ADD COLUMN reply_to INTEGER;");
        let _ = conn.execute(
            "UPDATE agents SET status = 'active' WHERE status IS NULL OR status = ''",
            [],
        );
        let _ = conn.execute(
            "UPDATE messages SET kind = ?1 WHERE kind IS NULL OR kind = ''",
            [DEFAULT_MESSAGE_KIND],
        );
        Ok(Self { conn })
    }

    pub fn register_agent(&self, id: &str, role: &str) -> Result<String> {
        self.register_agent_with_metadata(id, role, None, None)
    }

    pub fn register_agent_with_metadata(
        &self,
        id: &str,
        role: &str,
        client_type: Option<&str>,
        protocol_version: Option<i64>,
    ) -> Result<String> {
        let now = chrono::Utc::now().timestamp();
        let token = uuid::Uuid::new_v4().to_string();
        self.conn.execute(
            "INSERT OR REPLACE INTO agents (
                id, role, joined_at, session_token, status, archived_at, client_type, protocol_version
             ) VALUES (?1, ?2, ?3, ?4, 'active', NULL, ?5, ?6)",
            rusqlite::params![id, role, now, token, client_type, protocol_version],
        )?;
        Ok(token)
    }

    /// Register with automatic ID suffixing if the requested ID is taken.
    /// Returns (actual_id, session_token).
    pub fn register_agent_unique(
        &self,
        requested_id: &str,
        role: &str,
    ) -> Result<(String, String)> {
        self.register_agent_unique_with_metadata(requested_id, role, None, None)
    }

    pub fn register_agent_unique_with_metadata(
        &self,
        requested_id: &str,
        role: &str,
        client_type: Option<&str>,
        protocol_version: Option<i64>,
    ) -> Result<(String, String)> {
        let now = chrono::Utc::now().timestamp();
        let candidates = std::iter::once(requested_id.to_string())
            .chain((2..=99).map(|i| format!("{}-{}", requested_id, i)));
        for candidate in candidates {
            let token = uuid::Uuid::new_v4().to_string();
            let reactivated = self.conn.execute(
                "UPDATE agents
                 SET role = ?2, joined_at = ?3, session_token = ?4, status = 'active', archived_at = NULL,
                     client_type = ?5, protocol_version = ?6
                 WHERE id = ?1 AND status = 'archived'",
                rusqlite::params![candidate, role, now, token, client_type, protocol_version],
            )?;
            if reactivated > 0 {
                return Ok((candidate, token));
            }

            let inserted = self.conn.execute(
                "INSERT OR IGNORE INTO agents (
                    id, role, joined_at, session_token, status, archived_at, client_type, protocol_version
                 ) VALUES (?1, ?2, ?3, ?4, 'active', NULL, ?5, ?6)",
                rusqlite::params![candidate, role, now, token, client_type, protocol_version],
            )?;
            if inserted > 0 {
                return Ok((candidate, token));
            }
        }
        anyhow::bail!("Too many agents with base ID '{}'", requested_id);
    }

    pub fn get_session_token(&self, id: &str) -> Result<Option<String>> {
        let token: Option<String> = self
            .conn
            .query_row(
                "SELECT session_token FROM agents WHERE id = ?1",
                [id],
                |row| row.get(0),
            )
            .optional()?;
        Ok(token)
    }

    fn agent_status(&self, id: &str) -> Result<Option<String>> {
        let status = self
            .conn
            .query_row("SELECT status FROM agents WHERE id = ?1", [id], |row| {
                row.get(0)
            })
            .optional()?;
        Ok(status)
    }

    pub fn unregister_agent(&self, id: &str) -> Result<()> {
        let now = chrono::Utc::now().timestamp();
        let updated = self.conn.execute(
            "UPDATE agents
             SET status = 'archived', archived_at = ?2
             WHERE id = ?1 AND status = 'active'",
            rusqlite::params![id, now],
        )?;
        if updated == 1 {
            return Ok(());
        }

        match self.agent_status(id)?.as_deref() {
            Some("archived") => {
                anyhow::bail!("{id} is archived. Re-join with `squad join {id}` to reactivate it.")
            }
            Some(_) | None => {
                let names = self.agent_names()?;
                anyhow::bail!("{id} does not exist. Online agents: {}", names.join(", "))
            }
        }
    }

    pub fn list_agents(&self, include_archived: bool) -> Result<Vec<AgentRecord>> {
        let sql = if include_archived {
            "SELECT id, role, joined_at, last_seen, status, archived_at, client_type, protocol_version FROM agents ORDER BY joined_at"
        } else {
            "SELECT id, role, joined_at, last_seen, status, archived_at, client_type, protocol_version FROM agents WHERE status = 'active' ORDER BY joined_at"
        };
        let mut stmt = self.conn.prepare(sql)?;
        let agents = stmt
            .query_map([], |row| {
                Ok(AgentRecord {
                    id: row.get(0)?,
                    role: row.get(1)?,
                    joined_at: row.get(2)?,
                    last_seen: row.get(3)?,
                    status: row.get(4)?,
                    archived_at: row.get(5)?,
                    client_type_raw: row.get(6)?,
                    protocol_version_raw: row.get(7)?,
                })
            })?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(agents)
    }

    /// Update last_seen timestamp for an agent.
    pub fn touch_agent(&self, id: &str) -> Result<()> {
        self.require_active_agent(id)?;
        let now = chrono::Utc::now().timestamp();
        self.conn.execute(
            "UPDATE agents SET last_seen = ?1 WHERE id = ?2",
            rusqlite::params![now, id],
        )?;
        Ok(())
    }

    pub fn agent_exists(&self, id: &str) -> Result<bool> {
        let exists: bool = self.conn.query_row(
            "SELECT COUNT(*) > 0 FROM agents WHERE id = ?1 AND status = 'active'",
            [id],
            |row| row.get(0),
        )?;
        Ok(exists)
    }

    pub fn require_active_agent(&self, id: &str) -> Result<()> {
        match self.agent_status(id)?.as_deref() {
            Some("active") => Ok(()),
            Some("archived") => {
                anyhow::bail!("{id} is archived. Re-join with `squad join {id}` to reactivate it.")
            }
            Some(_) | None => {
                let names = self.agent_names()?;
                anyhow::bail!("{id} does not exist. Online agents: {}", names.join(", "))
            }
        }
    }

    fn agent_names(&self) -> Result<Vec<String>> {
        let mut stmt = self
            .conn
            .prepare("SELECT id FROM agents WHERE status = 'active' ORDER BY id")?;
        let names = stmt
            .query_map([], |row| row.get(0))?
            .collect::<Result<Vec<String>, _>>()?;
        Ok(names)
    }

    pub fn send_message(&self, from: &str, to: &str, content: &str) -> Result<()> {
        self.send_message_envelope(from, to, content, DEFAULT_MESSAGE_KIND, None, None)
    }

    fn send_message_envelope(
        &self,
        from: &str,
        to: &str,
        content: &str,
        kind: &str,
        task_id: Option<&str>,
        reply_to: Option<i64>,
    ) -> Result<()> {
        let now = chrono::Utc::now().timestamp();
        self.conn.execute(
            "INSERT INTO messages (from_agent, to_agent, content, created_at, read, kind, task_id, reply_to)
             VALUES (?1, ?2, ?3, ?4, 0, ?5, ?6, ?7)",
            params![from, to, content, now, kind, task_id, reply_to],
        )?;
        Ok(())
    }

    pub fn send_message_checked(&self, from: &str, to: &str, content: &str) -> Result<()> {
        self.require_active_agent(to)?;
        self.send_message(from, to, content)
    }

    pub fn send_message_checked_with_metadata(
        &self,
        from: &str,
        to: &str,
        content: &str,
        task_id: Option<&str>,
        reply_to: Option<i64>,
    ) -> Result<()> {
        self.require_active_agent(to)?;
        self.send_message_envelope(from, to, content, DEFAULT_MESSAGE_KIND, task_id, reply_to)
    }

    /// Broadcast a message to all agents except the sender.
    pub fn broadcast_message(&self, from: &str, content: &str) -> Result<Vec<String>> {
        let agents = self.agent_names()?;
        let recipients: Vec<_> = agents.into_iter().filter(|a| a != from).collect();
        for to in &recipients {
            self.send_message(from, to, content)?;
        }
        Ok(recipients)
    }

    /// Atomically read and mark messages as read using a transaction.
    pub fn receive_messages(&self, agent_id: &str) -> Result<Vec<MessageRecord>> {
        self.require_active_agent(agent_id)?;
        let tx = self.conn.unchecked_transaction()?;
        let mut stmt = tx.prepare(
            "SELECT id, from_agent, to_agent, content, created_at, read, kind, task_id, reply_to
             FROM messages WHERE to_agent = ?1 AND read = 0 ORDER BY created_at, id",
        )?;
        let messages: Vec<MessageRecord> = stmt
            .query_map([agent_id], |row| {
                Ok(MessageRecord {
                    id: row.get(0)?,
                    from_agent: row.get(1)?,
                    to_agent: row.get(2)?,
                    content: row.get(3)?,
                    created_at: row.get(4)?,
                    read: row.get(5)?,
                    kind: row.get(6)?,
                    task_id: row.get(7)?,
                    reply_to: row.get(8)?,
                })
            })?
            .collect::<Result<Vec<_>, _>>()?;
        drop(stmt);

        if !messages.is_empty() {
            let ids: Vec<i64> = messages.iter().map(|msg| msg.id).collect();
            let placeholders = std::iter::repeat_n("?", ids.len())
                .collect::<Vec<_>>()
                .join(", ");
            let sql =
                format!("UPDATE messages SET read = 1 WHERE read = 0 AND id IN ({placeholders})");
            tx.execute(&sql, params_from_iter(ids))?;
        }
        tx.commit()?;
        Ok(messages)
    }

    /// Check if there are unread messages for an agent (used by --wait).
    pub fn has_unread_messages(&self, agent_id: &str) -> Result<bool> {
        self.require_active_agent(agent_id)?;
        let has: bool = self.conn.query_row(
            "SELECT COUNT(*) > 0 FROM messages WHERE to_agent = ?1 AND read = 0",
            [agent_id],
            |row| row.get(0),
        )?;
        Ok(has)
    }

    pub fn pending_messages(&self) -> Result<Vec<MessageRecord>> {
        let mut stmt = self.conn.prepare(
            "SELECT id, from_agent, to_agent, content, created_at, read, kind, task_id, reply_to
             FROM messages WHERE read = 0 ORDER BY created_at, id",
        )?;
        let messages = stmt
            .query_map([], |row| {
                Ok(MessageRecord {
                    id: row.get(0)?,
                    from_agent: row.get(1)?,
                    to_agent: row.get(2)?,
                    content: row.get(3)?,
                    created_at: row.get(4)?,
                    read: row.get(5)?,
                    kind: row.get(6)?,
                    task_id: row.get(7)?,
                    reply_to: row.get(8)?,
                })
            })?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(messages)
    }

    /// All messages (including read), optionally filtered by agent.
    pub fn all_messages(&self, agent_id: Option<&str>) -> Result<Vec<MessageRecord>> {
        fn map_row(row: &rusqlite::Row) -> rusqlite::Result<MessageRecord> {
            Ok(MessageRecord {
                id: row.get(0)?,
                from_agent: row.get(1)?,
                to_agent: row.get(2)?,
                content: row.get(3)?,
                created_at: row.get(4)?,
                read: row.get(5)?,
                kind: row.get(6)?,
                task_id: row.get(7)?,
                reply_to: row.get(8)?,
            })
        }

        let messages = match agent_id {
            Some(id) => {
                let mut stmt = self.conn.prepare(
                    "SELECT id, from_agent, to_agent, content, created_at, read, kind, task_id, reply_to
                     FROM messages WHERE from_agent = ?1 OR to_agent = ?1 ORDER BY created_at, id",
                )?;
                let rows = stmt
                    .query_map([id], map_row)?
                    .collect::<Result<Vec<_>, _>>()?;
                rows
            }
            None => {
                let mut stmt = self.conn.prepare(
                    "SELECT id, from_agent, to_agent, content, created_at, read, kind, task_id, reply_to
                     FROM messages ORDER BY created_at, id",
                )?;
                let rows = stmt
                    .query_map([], map_row)?
                    .collect::<Result<Vec<_>, _>>()?;
                rows
            }
        };
        Ok(messages)
    }

    pub fn create_task(
        &self,
        created_by: &str,
        assigned_to: &str,
        title: &str,
        body: &str,
    ) -> Result<String> {
        let now = chrono::Utc::now().timestamp();
        let task_id = uuid::Uuid::new_v4().to_string();
        let tx = self.conn.unchecked_transaction()?;
        let inserted = tx.execute(
            "INSERT INTO tasks (
                 id, title, body, created_by, assigned_to, status,
                 lease_owner, lease_expires_at, result_summary,
                 created_at, updated_at, completed_at
             )
             SELECT ?1, ?2, ?3, creator.id, assignee.id, ?4,
                    NULL, NULL, NULL, ?5, ?5, NULL
             FROM agents AS creator
             JOIN agents AS assignee
               ON assignee.id = ?7
              AND assignee.status = 'active'
             WHERE creator.id = ?6
               AND creator.status = 'active'",
            params![
                task_id,
                title,
                body,
                TASK_STATUS_QUEUED,
                now,
                created_by,
                assigned_to,
            ],
        )?;
        if inserted != 1 {
            let created_by_status: Option<String> = tx
                .query_row(
                    "SELECT status FROM agents WHERE id = ?1",
                    [created_by],
                    |row| row.get(0),
                )
                .optional()?;
            match created_by_status.as_deref() {
                Some("active") => {}
                Some("archived") => {
                    anyhow::bail!(
                        "{created_by} is archived. Re-join with `squad join {created_by}` to reactivate it."
                    )
                }
                Some(_) | None => {
                    let names = self.agent_names()?;
                    anyhow::bail!(
                        "{created_by} does not exist. Online agents: {}",
                        names.join(", ")
                    )
                }
            }

            let assigned_to_status: Option<String> = tx
                .query_row(
                    "SELECT status FROM agents WHERE id = ?1",
                    [assigned_to],
                    |row| row.get(0),
                )
                .optional()?;
            match assigned_to_status.as_deref() {
                Some("active") => anyhow::bail!("failed to create task for {assigned_to}"),
                Some("archived") => {
                    anyhow::bail!(
                        "{assigned_to} is archived. Re-join with `squad join {assigned_to}` to reactivate it."
                    )
                }
                Some(_) | None => {
                    let names = self.agent_names()?;
                    anyhow::bail!(
                        "{assigned_to} does not exist. Online agents: {}",
                        names.join(", ")
                    )
                }
            }
        }
        tx.execute(
            "INSERT INTO messages (from_agent, to_agent, content, created_at, read, kind, task_id, reply_to)
             VALUES (?1, ?2, ?3, ?4, 0, ?5, ?6, NULL)",
            params![
                created_by,
                assigned_to,
                title,
                now,
                TASK_ASSIGNED_KIND,
                task_id.as_str(),
            ],
        )?;
        tx.commit()?;
        Ok(task_id)
    }

    pub fn get_task(&self, task_id: &str) -> Result<Option<TaskRecord>> {
        let task = self
            .conn
            .query_row(
                "SELECT id, title, body, created_by, assigned_to, status, lease_owner,
                        lease_expires_at, result_summary, created_at, updated_at, completed_at
                 FROM tasks WHERE id = ?1",
                [task_id],
                map_task_row,
            )
            .optional()?;
        Ok(task)
    }

    pub fn list_tasks(
        &self,
        assigned_to: Option<&str>,
        status: Option<&str>,
    ) -> Result<Vec<TaskRecord>> {
        let tasks = match (assigned_to, status) {
            (Some(agent), Some(status)) => {
                let mut stmt = self.conn.prepare(
                    "SELECT id, title, body, created_by, assigned_to, status, lease_owner,
                            lease_expires_at, result_summary, created_at, updated_at, completed_at
                     FROM tasks
                     WHERE assigned_to = ?1 AND status = ?2
                     ORDER BY created_at, title, id",
                )?;
                let rows = stmt
                    .query_map(params![agent, status], map_task_row)?
                    .collect::<Result<Vec<_>, _>>()?;
                rows
            }
            (Some(agent), None) => {
                let mut stmt = self.conn.prepare(
                    "SELECT id, title, body, created_by, assigned_to, status, lease_owner,
                            lease_expires_at, result_summary, created_at, updated_at, completed_at
                     FROM tasks
                     WHERE assigned_to = ?1
                     ORDER BY created_at, title, id",
                )?;
                let rows = stmt
                    .query_map([agent], map_task_row)?
                    .collect::<Result<Vec<_>, _>>()?;
                rows
            }
            (None, Some(status)) => {
                let mut stmt = self.conn.prepare(
                    "SELECT id, title, body, created_by, assigned_to, status, lease_owner,
                            lease_expires_at, result_summary, created_at, updated_at, completed_at
                     FROM tasks
                     WHERE status = ?1
                     ORDER BY created_at, title, id",
                )?;
                let rows = stmt
                    .query_map([status], map_task_row)?
                    .collect::<Result<Vec<_>, _>>()?;
                rows
            }
            (None, None) => {
                let mut stmt = self.conn.prepare(
                    "SELECT id, title, body, created_by, assigned_to, status, lease_owner,
                            lease_expires_at, result_summary, created_at, updated_at, completed_at
                     FROM tasks
                     ORDER BY created_at, title, id",
                )?;
                let rows = stmt
                    .query_map([], map_task_row)?
                    .collect::<Result<Vec<_>, _>>()?;
                rows
            }
        };
        Ok(tasks)
    }

    pub fn ack_task(&self, agent_id: &str, task_id: &str) -> Result<()> {
        self.require_active_agent(agent_id)?;
        let task = self.require_task(task_id)?;
        if task.status != TASK_STATUS_QUEUED {
            anyhow::bail!("task {task_id} is not queued");
        }
        if task.assigned_to.as_deref() != Some(agent_id) {
            anyhow::bail!("task {task_id} is not assigned to {agent_id}");
        }

        let now = chrono::Utc::now().timestamp();
        let lease_expires_at = now + TASK_LEASE_SECS;
        let updated = self.conn.execute(
            "UPDATE tasks
             SET status = ?1, lease_owner = ?2, lease_expires_at = ?3, updated_at = ?4
             WHERE id = ?5 AND status = ?6 AND assigned_to = ?2",
            params![
                TASK_STATUS_ACKED,
                agent_id,
                lease_expires_at,
                now,
                task_id,
                TASK_STATUS_QUEUED,
            ],
        )?;
        ensure_task_updated(updated, task_id)?;
        Ok(())
    }

    pub fn complete_task(&self, agent_id: &str, task_id: &str, result_summary: &str) -> Result<()> {
        self.require_active_agent(agent_id)?;
        let task = self.require_task(task_id)?;
        if task.status != TASK_STATUS_ACKED {
            anyhow::bail!("task {task_id} is not acked");
        }
        if task.lease_owner.as_deref() != Some(agent_id) {
            anyhow::bail!("task {task_id} is not leased by {agent_id}");
        }

        let now = chrono::Utc::now().timestamp();
        let updated = self.conn.execute(
            "UPDATE tasks
             SET status = ?1, result_summary = ?2, completed_at = ?3, updated_at = ?3
             WHERE id = ?4 AND status = ?5 AND lease_owner = ?6",
            params![
                TASK_STATUS_COMPLETED,
                result_summary,
                now,
                task_id,
                TASK_STATUS_ACKED,
                agent_id,
            ],
        )?;
        ensure_task_updated(updated, task_id)?;
        Ok(())
    }

    pub fn requeue_task(&self, task_id: &str, new_assignee: Option<&str>) -> Result<()> {
        let task = self.require_task(task_id)?;
        if let Some(agent_id) = new_assignee {
            self.require_active_agent(agent_id)?;
        }

        let now = chrono::Utc::now().timestamp();
        let updated = self.conn.execute(
            "UPDATE tasks
             SET assigned_to = ?1,
                 status = ?2,
                 lease_owner = NULL,
                 lease_expires_at = NULL,
                 result_summary = NULL,
                 completed_at = NULL,
                 updated_at = ?3
             WHERE id = ?4
               AND status = ?5
               AND assigned_to IS ?6
               AND lease_owner IS ?7
               AND lease_expires_at IS ?8
               AND completed_at IS ?9
               AND result_summary IS ?10",
            params![
                new_assignee,
                TASK_STATUS_QUEUED,
                now,
                task_id,
                task.status,
                task.assigned_to,
                task.lease_owner,
                task.lease_expires_at,
                task.completed_at,
                task.result_summary,
            ],
        )?;
        ensure_task_updated(updated, task_id)?;
        Ok(())
    }

    fn require_task(&self, task_id: &str) -> Result<TaskRecord> {
        self.get_task(task_id)?
            .with_context(|| format!("task {task_id} does not exist"))
    }

    /// Return archived agents that still have pending tasks (queued or acked).
    /// Each entry is (agent_id, vec_of_task_ids), sorted by agent_id.
    pub fn archived_agents_with_pending_tasks(&self) -> Result<Vec<(String, Vec<String>)>> {
        let mut stmt = self.conn.prepare(
            "SELECT a.id, t.id
             FROM agents a
             JOIN tasks t ON (t.assigned_to = a.id OR t.lease_owner = a.id)
             WHERE a.status = 'archived'
               AND t.status IN ('queued', 'acked')
             ORDER BY a.id, t.rowid",
        )?;
        let rows = stmt
            .query_map([], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })?
            .collect::<Result<Vec<_>, _>>()?;

        let mut result: Vec<(String, Vec<String>)> = Vec::new();
        for (agent_id, task_id) in rows {
            if let Some(last) = result.last_mut() {
                if last.0 == agent_id {
                    last.1.push(task_id);
                    continue;
                }
            }
            result.push((agent_id, vec![task_id]));
        }
        Ok(result)
    }

    /// Return active agents whose effective protocol version is below the threshold.
    /// Each entry is (agent_id, effective_version), sorted by agent_id.
    pub fn active_agents_below_protocol(
        &self,
        threshold: i64,
        default_version: i64,
    ) -> Result<Vec<(String, i64)>> {
        let mut stmt = self.conn.prepare(
            "SELECT id, protocol_version
             FROM agents
             WHERE status = 'active'
             ORDER BY id",
        )?;
        let rows = stmt
            .query_map([], |row| {
                let id: String = row.get(0)?;
                let pv: Option<i64> = row.get(1)?;
                Ok((id, pv))
            })?
            .collect::<Result<Vec<_>, _>>()?;

        Ok(rows
            .into_iter()
            .filter_map(|(id, pv)| {
                let effective = pv.unwrap_or(default_version);
                if effective < threshold {
                    Some((id, effective))
                } else {
                    None
                }
            })
            .collect())
    }
}

fn map_task_row(row: &rusqlite::Row) -> rusqlite::Result<TaskRecord> {
    Ok(TaskRecord {
        id: row.get(0)?,
        title: row.get(1)?,
        body: row.get(2)?,
        created_by: row.get(3)?,
        assigned_to: row.get(4)?,
        status: row.get(5)?,
        lease_owner: row.get(6)?,
        lease_expires_at: row.get(7)?,
        result_summary: row.get(8)?,
        created_at: row.get(9)?,
        updated_at: row.get(10)?,
        completed_at: row.get(11)?,
    })
}

fn ensure_task_updated(updated: usize, task_id: &str) -> Result<()> {
    if updated == 1 {
        Ok(())
    } else {
        anyhow::bail!("stale task state for {task_id}")
    }
}
