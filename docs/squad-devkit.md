# Local devkit: Claude manager with on-demand workers

`scripts/squad-devkit.sh` starts one Claude Code session as the project
**manager**. The manager talks with you, researches, plans, and decides. When
work should be delegated, it starts **on-demand workers** with
`scripts/squad-worker.sh`:

- **Codex** (`codex exec`, sandboxed to the workspace) for implementation, tests,
  and anything that needs a shell.
- **CCR** (Claude Code through claude-code-router, on the cheap model configured in
  `~/.claude-code-router/config.json`) for docs, simple edits from an exact spec,
  and summaries. CCR workers have file tools only, with no shell.

A worker joins the squad, receives a structured task from the manager, runs once
without interaction, completes the task with its report, and leaves. The manager
starts workers as background commands, so it can keep talking with you and is
notified when each one finishes. The manager also chooses each worker's role
(`dev`, `tester`, `reviewer`, or any other name) and its engine or profile.

## Why this saves tokens

- **No idle cost.** The earlier setup kept three Codex sessions polling
  `squad receive`. Each poll resent the whole context, so three developers used
  about 1M tokens before receiving any work. On-demand workers cost nothing
  until they start.
- **Small worker context.** Codex workers start with every MCP server disabled
  unless the manager asks for one (`--mcp NAME`). A trivial edit costs about
  18k tokens instead of 52–98k. CCR workers skip MCP servers and skills.
- **Right-sized models.** The default Codex profile is `high`. The manager picks
  `medium` for mechanical work, `max` only for hard problems, and CCR for cheap
  tasks.
- **No polling in the manager.** Background workers notify the manager when they
  exit, so the manager never needs `squad receive --wait`.

## Install

macOS, with `squad`, `claude`, and `codex` installed. `ccr`
(`@musistudio/claude-code-router`) is optional and is needed only for CCR
workers. Ghostty and tmux are optional backends.

```sh
ln -s /absolute/path/to/squad/scripts/squad-devkit.sh ~/.local/bin/squad-devkit
ln -s /absolute/path/to/squad/scripts/squad-worker.sh ~/.local/bin/squad-worker
```

Codex profiles are files named `$CODEX_HOME/<profile>.config.toml`, for example
`~/.codex/high.config.toml`. Workers use `high` unless told otherwise; set
`SQUAD_WORKER_CODEX_PROFILE` to change the default.

## Run

```sh
squad-devkit                                  # asks for a project (Enter = current directory)
squad-devkit my-project                       # name lookup under ~/Workspace and other roots
squad-devkit my-project 'fix the failing login test'
squad-devkit my-project --task '-v flag is ignored'
squad-devkit --list                           # discoverable git projects
squad-devkit my-project --ghostty             # new Ghostty window instead of this terminal
squad-devkit my-project --tmux [--no-attach]  # tmux session; re-running attaches
squad-devkit my-project --dry-run             # print the manager command only
```

By default the manager runs in the current terminal, so it works in any
terminal app. Set `SQUAD_DEVKIT_BACKEND=here|ghostty|tmux` to change the default.
`SQUAD_DEVKIT_TASK` supplies an objective when you don't pass one.

Project resolution is unchanged. Existing paths win. Names match git repository
directories under `~/Workspace` (up to eight levels), then `~/Projects`,
`~/Developer`, `~/code`, and `~/src`; set `SQUAD_DEVKIT_PROJECT_ROOT` to search
elsewhere. A `folder/name` reference matches trailing path segments. Duplicate
names list every match. A directory that is not a git repository is accepted, and
`squad init` creates `.squad/` there.

Each launch runs `squad init` and installs the role prompts `manager-devkit`,
`dev`, `tester`, and `reviewer` into `.squad/roles/`. Role files that still
start with the `<!-- squad-devkit template` line are refreshed from
`templates/devkit/`. Delete that line to keep your own edits; the launcher then
only prints a note when the template changes.

## Workers

The manager runs workers like this; you can also run them yourself from the
project:

```sh
squad-worker dev-1 --engine codex --role dev --brief-file - <<'BRIEF'
Fix the off-by-one in src/pager.rs::page_count.
Files you own: src/pager.rs, tests/pager_test.rs.
Verify: cargo test pager
BRIEF

squad-worker doc-1 --engine ccr --role dev --brief 'Document the --json flag in README.md. Files you own: README.md'
squad-worker test-1 --engine codex --profile medium --role tester --brief-file brief.md
squad-worker logs-1 --engine codex --role researcher --mcp grafana-logs --brief '...'
```

| Option | Meaning |
|---|---|
| `--engine codex\|ccr` | Worker engine (required) |
| `--role ROLE` | Role prompt from `.squad/roles/ROLE.md` (default `dev`) |
| `--brief TEXT`, `--brief-file FILE\|-` | Self-contained task description (required) |
| `--title TITLE` | Task title (default: first line of the brief) |
| `--profile NAME` | Codex profile (default `high`) |
| `--mcp NAME`, `--all-mcp` | Codex: keep one or all MCP servers enabled |
| `--manager ID` | Manager agent ID (default `manager`) |

The report is printed on stdout and saved to `.squad/workers/<id>-<time>.md`,
with the engine log beside it. `squad task list` shows every task with its
summary. If a worker fails, it sends the manager a message with the log path
and exits non-zero.

CCR workers use the tools in `SQUAD_WORKER_CCR_TOOLS` (default
`Read,Edit,Write,Glob,Grep`). The worker starts the router if it isn't
listening, then runs `claude -p` with the environment from `ccr activate`. It
bypasses `ccr code`, whose running-service check can report a live router as
stopped and then time out.

Parallel workers share the repository, so the manager must give each worker
files that no other running worker edits. Workers never commit. The manager asks
you before commits, pushes, or destructive actions.

## Upgrading from the four-pane setup

The launcher no longer starts `dev-1`–`dev-3` panes. If a tmux session from the
old layout is still running, the launcher refuses to reuse it and prints the
`tmux kill-session` command; stop it once its work is saved. Role files that
lack the template line are kept as they are; replace them with the files in
`templates/devkit/` to get the new manager instructions.
