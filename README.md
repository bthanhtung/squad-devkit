<h1 align="center">squad-devkit</h1>

<p align="center"><strong>One manager agent. On-demand workers. Fewer tokens.</strong></p>

<p align="center">
  <a href="https://github.com/bthanhtung/squad-devkit/actions/workflows/ci.yml"><img src="https://github.com/bthanhtung/squad-devkit/actions/workflows/ci.yml/badge.svg" alt="CI" /></a>
  <a href="https://github.com/bthanhtung/squad-devkit/releases"><img src="https://img.shields.io/github/v/release/bthanhtung/squad-devkit?style=flat-square" alt="Release" /></a>
  <a href="./LICENSE"><img src="https://img.shields.io/badge/License-MIT-22c55e?style=flat-square" alt="License: MIT" /></a>
  <img src="https://img.shields.io/badge/platform-macOS%20%7C%20Linux-7c3aed?style=flat-square" alt="macOS and Linux" />
</p>

squad-devkit turns one terminal into an engineering team. You talk to a single
manager agent (Claude Code by default). The manager triages the request, plans
it, gives each task to the most cost-effective worker that can do it well
(Claude, Codex, Grok, Antigravity, or a cheap local model), verifies every
result, and sends back anything that is wrong. Workers start only when there is
work and stop when they are done, so idle agents cost nothing.

```
┌──────────────────────────────┬─────────────────────────────┐
│ Claude Code · manager        │ dev-1 · codex (high)        │
│                              │ ● RUNNING · 01:42           │
│ > add rate limiting to the   │ Calls: 6 · failed: 0        │
│   public API                 ├─────────────────────────────┤
│                              │ review-1 · claude (sonnet)  │
│ Plan: 3 tasks · dev-1 codex  │ ✓ COMPLETED · 00:58         │
│ test-1 codex · review-1 ...  ├─────────────────────────────┤
│ ─────────────────────────────│ docs-1 · ccr                │
│ weekly 41% · squad saved 1.2M│ ✓ COMPLETED · 00:12         │
└──────────────────────────────┴─────────────────────────────┘
```

**Contents:** [Highlights](#highlights) · [Install](#install) ·
[Usage](#usage) · [Workers](#workers) · [Monitor and savings](#monitor-and-savings) ·
[Configuration](#configuration) · [Security](#security) ·
[Contributing](#contributing) · [Credits](#credits) ·
[squad CLI reference](#squad-cli-reference)

## Highlights

- **Plans like a senior team.** Every request is triaged (workstream, risk,
  complexity, whether a human must decide) and planned from five perspectives:
  principal engineer, engineering manager, technical lead, QA, and end user.
- **Right worker for the job.** Workers are chosen by trust and cost:
  `claude` > `codex` > `grok`, `agy` > `ccr`. Claude workers use the smallest
  model that fits (haiku by default, sonnet or opus when needed).
- **The manager owns the outcome.** Reports are checked against `git diff` and
  re-run verification; defects go back to the same worker with `path:line`
  detail, moving up a model or engine if a fix fails twice.
- **Workers can push back.** A worker can question the manager or another
  worker (`squad-ask`) when the brief is ambiguous or there is a better approach.
- **Isolated by default.** In a git repository every editing worker gets its
  own worktree and branch, so parallel workers never overwrite each other; the
  manager reviews each diff and merges it with a three-way merge.
- **Nothing hangs.** Workers have a time limit and stall detection; failures
  report to the manager, which re-runs or reassigns the task.
- **Live visibility.** Each worker opens a monitor pane beside the manager in
  tmux, Herdr, Zellij, WezTerm, Kitty, iTerm2, or Ghostty; other terminals
  (macOS Terminal.app, GNOME Terminal, Konsole, ...) get one live dashboard window. With claude-hud, the manager's status line shows your weekly quota
  and the tokens the squad saved.
- **Lean by design.** Instructions live in the system prompt, workers start with
  MCP servers off, old run data is pruned automatically, and a Codex manager
  takes over if Claude Code hits its usage limit.

## Install

Requirements: macOS or Linux, [`squad`](#squad-cli-reference), `jq`, one manager
CLI (`claude`, `codex`, `agy`, `gemini`, `grok`, or `opencode`), and at least one
worker engine (`claude`, `codex`, `grok`, `agy`, or `ccr` from
[claude-code-router](https://github.com/musistudio/claude-code-router)).
Monitor panes work in tmux, Herdr, Zellij, WezTerm, Kitty, iTerm2, and Ghostty;
any other terminal gets a dashboard window.

```bash
brew install mco-org/tap/squad jq
git clone https://github.com/bthanhtung/squad-devkit.git
squad-devkit/scripts/install-devkit.sh
```

The installer links `squad-devkit`, `squad-worker`, and `squad-monitor` into
`~/.local/bin`, picks the manager (Claude Code if installed, otherwise it asks
which installed CLI to use), lists the worker engines it found, and, when
claude-hud is installed, turns on its weekly-quota and usage-pace display.
Run `squad-devkit --setup` to choose another manager later.

## Usage

```bash
squad-devkit                                          # from ~: general workspace; in a repo: that repo
squad-devkit "check prod error logs since 18:00 and write a report"
squad-devkit my-service "add rate limiting to the public API"
squad-devkit my-service --tmux                        # or --ghostty for a new window
squad-devkit --version
```

Describe the work in the chat. The manager investigates, writes a plan to
`.squad/plans/`, starts workers in parallel, answers their questions, verifies
their results, and reports back with evidence. From your home directory it runs
in the general workspace `~/.squad-devkit`, where requests such as log checks
and reports need no repository; for code changes it finds the repositories
involved. In git repositories the launcher leaves the working tree clean.

## Workers

The manager runs workers for you; you can also run them yourself:

```bash
squad-worker dev-1 --engine codex --role dev --brief-file brief.md
squad-worker review-1 --engine claude --model sonnet --role reviewer --brief "Review git diff for src/api/"
squad-worker logs-1 --engine codex --role researcher --mcp grafana-logs --brief "..."
squad-worker --list                 # running workers and unmerged worktrees
squad-worker --merge dev-1          # apply dev-1's worktree changes (uncommitted)
squad-worker --discard dev-1        # or drop them
squad-worker --stop dev-1           # or --stop all
```

| Engine | Trust | Use for |
|---|---|---|
| `claude` | highest | Work that must be right the first time; `haiku` by default, `sonnet` for complex or high-risk work, `opus` for the hardest |
| `codex` | high | Normal implementation, debugging, and tests; the only engine with MCP access |
| `grok`, `agy` | medium | Low-risk implementation or a second opinion (experimental) |
| `ccr` | basic | Docs and small exact edits; cheap model, file tools only |

Roles: `dev`, `tester`, `reviewer`, `researcher`, or any name; a role with a file
in `.squad/roles/` gets that prompt. Use `--project <path>` to work in another
repository.

In a git repository, editing workers run in their own worktree under
`.squad/worktrees/` on branch `squad/<id>`, started from a snapshot of
your working tree (including uncommitted and new files). Your files and index
stay untouched until `--merge`, which applies the changes uncommitted with a
three-way merge and leaves conflict markers if two workers changed the same
lines. Reviewers and researchers read the project directly; `--no-worktree`
does the same for any role.

## Monitor and savings

Each worker pane shows its state, elapsed time, calls, failures, changed files,
tokens, and recent activity, then closes itself 60 seconds after the run ends.
In terminals without a split API (macOS Terminal.app, GNOME Terminal, Konsole,
xterm), the first worker of a session opens one dashboard window with every run
instead; over SSH, run `squad-monitor --all` or use `squad-devkit --tmux`.
`squad-monitor --all` shows every run as a table in any terminal. With
claude-hud, the manager's status line adds the squad label, for example
`squad 2 running · saved 1.2M tok`: the tokens that workers on other engines
processed instead of Claude during this session.

## Configuration

| Variable | Default | Purpose |
|---|---|---|
| `SQUAD_DEVKIT_MANAGER` | saved choice, else `claude` | Manager CLI for a run (`--manager`) |
| `SQUAD_DEVKIT_PERMISSION_MODE` | `auto` | Claude Code permission mode for the manager |
| `SQUAD_DEVKIT_FALLBACK_MANAGER` | `codex` | Manager that takes over when Claude Code hits a limit (`none` disables) |
| `SQUAD_DEVKIT_RETENTION_DAYS` | `7` | Days to keep finished worker runs |
| `SQUAD_DEVKIT_MAX_MB` | `200` | Size cap for `.squad/workers` |
| `SQUAD_DEVKIT_STATUSLINE` | `1` | `0` turns off the squad status-line label |
| `SQUAD_WORKER_CLAUDE_MODEL` | `haiku` | Default model for Claude workers |
| `SQUAD_WORKER_CODEX_PROFILE` | `high` | Default Codex profile for workers |
| `SQUAD_WORKER_TIMEOUT` / `SQUAD_WORKER_STALL` | `45` / `10` | Minutes before a run is stopped / counted as stuck |
| `SQUAD_WORKER_PANE_HOLD` | `60` | Seconds a finished monitor pane stays open |
| `SQUAD_DEVKIT_ROUTER_URL` | unset | Optional advisory triage router for `squad-route` |

`squad-devkit --clean` prunes old worker runs on demand and `--clean-all`
removes every finished run. Full reference:
[docs/squad-devkit.md](./docs/squad-devkit.md).

## Security

Codex workers run sandboxed to the project, Claude workers accept edits and run
shell commands only inside Claude Code's sandbox, and ccr workers get file tools
only. squad-devkit never stores credentials, and worker prompts forbid reading
them from configuration files. See [SECURITY.md](./SECURITY.md) for details and
how to report a vulnerability.

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](./CONTRIBUTING.md) for the
development setup and the checks CI runs, and [CHANGELOG.md](./CHANGELOG.md)
for release notes.

## Credits

squad-devkit is built by [TungDaDev](https://github.com/bthanhtung) on
[squad](https://github.com/mco-org/squad) by mco-org, which provides the SQLite
message bus, task records, and the `squad` CLI. Both are released under the
[MIT License](./LICENSE).

---

## squad CLI reference

The rest of this document is the reference for the underlying `squad` CLI,
from the upstream project ([简体中文](./README.zh-CN.md)).

### Install

```bash
# Homebrew (macOS)
brew install mco-org/tap/squad

# Windows (GitHub Releases)
# 1. Download squad-x86_64-pc-windows-msvc.zip
# 2. Extract squad.exe to a folder like C:\Tools\squad
# 3. Add that folder to PATH

# Or download another prebuilt binary from GitHub Releases
# https://github.com/mco-org/squad/releases

# Or build from source
cargo install --git https://github.com/mco-org/squad.git
```

### Quick Start

```bash
# Install /squad slash command for your AI tools
squad setup

# Initialize workspace in your project
squad init

# In any AI CLI terminal — just use the slash command
/squad manager      # terminal 1
/squad worker       # terminal 2
/squad inspector    # terminal 3
```

That's it. Each agent joins, reads its role instructions, and enters a work loop that checks for messages. The manager breaks down your goal and assigns tasks to workers.

### Optional tmux Launcher

For Unix-like environments that already use Claude Code, this repo also ships an optional helper script:

```bash
scripts/squad-tmux-launch.sh /path/to/project --dry-run
```

It can:
- read project-local launcher config from `.squad/launcher.yaml`
- read a task brief from `.squad/run-task.md`
- generate manager / inspector prompt files under `.squad/quickstart/`
- start a tiled `tmux` session and inject `/squad` commands into Claude panes
- optionally create an isolated git worktree before launching agents

Requirements:
- `tmux`
- `ruby` (used to parse `launcher.yaml`)
- `claude`

This launcher is intentionally separate from the core Rust CLI. Treat it as optional automation for people who want a repeatable multi-terminal workflow.

### Usage Flow

```
You (human)
  │
  ├── Terminal 1: /squad manager
  │     Manager joins, asks you for the goal,
  │     breaks it into tasks, assigns to workers.
  │
  ├── Terminal 2: /squad worker
  │     Worker joins, checks for tasks via squad receive,
  │     executes assigned work, reports back.
  │
  └── Terminal 3: /squad worker
        Auto-assigned as worker-2 (ID conflict resolved automatically).
        Same behavior — checks, executes, reports.
```

Multiple agents with the same role get unique IDs automatically (`worker`, `worker-2`, `worker-3`).

### Commands

| Command | Description |
|---------|-------------|
| `squad init [--refresh-roles]` | Initialize workspace, create `.squad/`, add `.squad/` to `.gitignore`, and append squad guidance to `CLAUDE.md`, `AGENTS.md`, and `GEMINI.md` if missing. `--refresh-roles` rewrites only builtin `manager`/`worker`/`inspector` files under `.squad/roles/`. |
| `squad join <id> [--role <role>] [--client <claude\|gemini\|codex\|opencode>] [--protocol-version <n>]` | Join as agent (auto-suffixes if ID is taken; omitted capability metadata stays `NULL`) |
| `squad leave <id>` | Archive agent and preserve unread work |
| `squad agents [--all] [--json]` | List online agents (`--json` emits one JSON object per line including raw/effective capability fields and protocol-derived support booleans) |
| `squad send [--task-id <id>] [--reply-to <message-id>] <from> <to> <message>` | Send a note (`@all` to broadcast, or `squad send [flags] --file <path-or-> <from> <to>` to read from file/stdin) |
| `squad receive <id> [--wait] [--timeout N] [--json]` | Check inbox (`--wait` blocks until a message arrives; `--json` emits one JSON object per line) |
| `squad task create <from> <to> --title <title> [--body <body>]` | Create a structured task assignment |
| `squad task ack <agent> <task-id>` | Claim a queued task |
| `squad task complete <agent> <task-id> --summary <text>` | Mark an acked task complete with a summary |
| `squad task requeue <task-id> [--to <agent>]` | Put a task back into the queue, optionally to a new assignee |
| `squad task list [--agent <id>] [--status <status>]` | List tasks with optional filters |
| `squad pending` | Show all unread messages |
| `squad history [agent] [--from <id>] [--to <id>] [--since <RFC3339\|unix-seconds>]` | Show timestamped message history with optional filters |
| `squad roles` | List available roles |
| `squad teams` | List available teams |
| `squad team <name>` | Show team template |
| `squad setup [platform]` | Install `/squad` slash command for AI tools |
| `squad setup --list` | List supported platforms and status |
| `squad clean` | Clear all state |

### Setup

Install the `/squad` slash command for your AI tools:

```bash
squad setup           # auto-detect and install for all found tools
squad setup claude    # install only for Claude Code
squad setup --list    # show supported platforms
```

Supported platforms:

| Platform | Binary | Command location |
|----------|--------|-----------------|
| Claude Code | `claude` | `~/.claude/commands/squad.md` |
| Gemini CLI | `gemini` | `~/.gemini/commands/squad.toml` |
| Codex CLI | `codex` | `~/.codex/skills/squad/SKILL.md` |
| OpenCode | `opencode` | `~/.config/opencode/commands/squad.md` |

Once installed, use `/squad <role>` (or `$squad <role>` in Codex) in any project where `squad init` has been run. Generated slash templates automatically join with their platform client type and the current supported protocol version.

`squad init` does more than create `.squad/`: it also appends `.squad/` to `.gitignore` and adds a short squad collaboration section to `CLAUDE.md`, `AGENTS.md`, and `GEMINI.md` when those files do not already contain one. Existing builtin role files stay untouched unless you run `squad init --refresh-roles`.

### How It Works

Agents communicate through a shared SQLite database (`.squad/messages.db`). Each agent runs in its own terminal and uses CLI commands to send and receive messages.

```
Terminal 1 (manager)          Terminal 2 (worker)          Terminal 3 (worker-2)
┌─────────────────────┐      ┌─────────────────────┐      ┌─────────────────────┐
│ /squad manager       │      │ /squad worker        │      │ /squad worker        │
│                      │      │ (auto-ID: worker)    │      │ (auto-ID: worker-2)  │
│                      │      │                      │      │                      │
│ squad task create    │─────>│ squad receive worker │      │                      │
│   manager worker     │      │                      │      │                      │
│   "task-a" "details" │      │                      │      │                      │
│                      │      │                      │      │                      │
│ squad task create    │──────────────────────────────────>│ squad receive         │
│   manager worker-2   │      │                      │      │   worker-2           │
│   "task-b" "details" │      │                      │      │                      │
│                      │      │                      │      │                      │
│ squad receive manager│<─────│ squad task complete  │      │                      │
│                      │      │   worker <task-id>   │      │                      │
│                      │      │   "done A"           │      │                      │
│                      │      │                      │      │                      │
│                      │<──────────────────────────────────│ squad task complete   │
│                      │      │                      │      │   worker-2 <task-id> │
│                      │      │                      │      │   "done B"           │
└─────────────────────┘      └─────────────────────┘      └─────────────────────┘
```

All messages flow through SQLite — no daemon, no sockets, no background processes.

#### Message Flow

Agents should prefer `squad task ...` when assignment state matters, and keep `squad send` / `squad receive` as the fallback path for freeform coordination. Agents use `squad receive --wait` to block until messages arrive:

```
Agent joins
  → squad receive <id> --wait          ← blocks until a message arrives
  → receives task from manager
  → squad task ack <id> <task-id>
  → executes the task
  → squad task complete <id> <task-id> --summary "done: summary..."
  → squad receive <id> --wait          ← blocks again for next message
```

`squad receive <id>` (without `--wait`) checks once and returns immediately, useful for scripting or manual checks.

#### ID Auto-Suffix

When multiple agents join with the same ID, squad automatically assigns unique IDs:

```bash
squad join worker --role worker --client codex --protocol-version 2
# → Joined as worker

squad join worker --role worker --client opencode --protocol-version 2
# → ID 'worker' was taken. Joined as worker-2
```

This is handled server-side (atomic `INSERT OR IGNORE`), so even simultaneous joins from different terminals are safe.

### Agent Capability Metadata

`squad join` can optionally record agent capability metadata:

```bash
squad join worker --role worker --client codex --protocol-version 2
```

- If `--client` or `--protocol-version` is omitted, the database stores `NULL`.
- `squad agents` shows client/protocol details in human-readable output using the effective fallback view, so legacy rows appear as `client: unknown, protocol: 1`.
- `squad agents --json` exposes `client_type_raw`, `protocol_version_raw`, `effective_client_type`, `effective_protocol_version`, `supports_task_commands`, and `supports_json_receive`.
- In the current phase, `supports_task_commands` and `supports_json_receive` are both derived from the effective protocol version, with support enabled at protocol `>= 2`.

### Role Templates

Roles are `.md` files in `.squad/roles/` that define agent behavior. Three are built in:

- **manager** — breaks down goals, assigns tasks, coordinates review
- **worker** — executes tasks, reports results
- **inspector** — reviews code, sends PASS/FAIL verdicts

Create custom roles by adding `.md` files to `.squad/roles/`:

```bash
echo "You are a database specialist..." > .squad/roles/dba.md
squad join db-expert --role dba
```

If the builtin role templates in `.squad/roles/` drift from the bundled defaults, run `squad init --refresh-roles` to refresh only `manager.md`, `worker.md`, and `inspector.md`. Custom role files are left untouched.

### Team Templates

Teams are YAML files in `.squad/teams/` that define which roles are needed:

```yaml
# .squad/teams/dev.yaml
name: dev
roles:
  manager:
    prompt_file: manager
  worker:
    prompt_file: worker
  inspector:
    prompt_file: inspector
```

View a team's setup instructions:

```bash
squad team dev
```

### Broadcast

Send a message to all agents at once:

```bash
squad task create manager worker --title "auth-module" --body "implement auth module with JWT"
squad task ack worker <task-id>
squad task complete worker <task-id> --summary "JWT auth shipped"
squad send --task-id <task-id> inspector worker "please handle follow-up edge cases"
squad receive worker --json
squad send manager @all "API contract changed, update your implementations"
```

### Requirements

- Rust 1.77+ (for building)
- macOS or Linux

### License

MIT
