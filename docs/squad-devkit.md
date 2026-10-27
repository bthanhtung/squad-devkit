# Local devkit: one manager with on-demand workers

`scripts/squad-devkit.sh` starts one interactive session as the project
**manager**: Claude Code by default, or another CLI you choose (see
[Choosing the manager](#choosing-the-manager)). The manager talks with you, researches, plans, and decides. When
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
- **No polling in the manager.** A Claude Code manager is notified when a
  background worker exits. Other managers block on one `squad receive --wait`
  until a worker reports, instead of polling in a loop.

## Install

You need macOS and `squad` (`brew install mco-org/tap/squad`). You also need at
least one manager CLI and, for workers, `codex` and/or `ccr`
(`@musistudio/claude-code-router`). Ghostty and tmux are optional backends.

```sh
/absolute/path/to/squad/scripts/install-devkit.sh
```

The installer links `squad-devkit`, `squad-worker`, and `squad-monitor` into
`~/.local/bin` (set `SQUAD_DEVKIT_BIN_DIR` for another directory). It then picks the manager as
described below and lists the worker engines it found.

Codex profiles are files named `$CODEX_HOME/<profile>.config.toml`, for example
`~/.codex/high.config.toml`. Workers use `high` unless told otherwise; set
`SQUAD_WORKER_CODEX_PROFILE` to change the default.

## How the manager works

The manager coordinates and does not write code. Its role
(`templates/devkit/manager-devkit.md`, installed as
`.squad/roles/manager-devkit.md`) tells it to:

1. Read the code it will change and the code that calls it.
2. Write a plan to `.squad/plans/<name>.md` with the goal, findings
   (`path:line`), decisions, tasks with disjoint file ownership, and acceptance
   checks.
3. Give each worker a complete brief: the goal, the files the worker owns, the
   exact changes, the steps, the acceptance criteria, the verification
   commands, and what is out of scope.
4. Verify each report against `git diff` and rerun the verification.
5. For each failed check, start a fix run with the same worker ID listing the
   defects. After two failed rounds, raise the profile, split the task, or ask
   you.
6. Run the full acceptance checks, optionally add a reviewer worker, and report
   to you with evidence.

The launcher runs the manager through `scripts/lib/squad-devkit-manager.sh`.
This wrapper:

- archives managers whose recorded process has exited (or, without a pid
  file, that were not seen for `SQUAD_DEVKIT_STALE_MINUTES`, default 30);
- joins as `manager`, records its pid in `.squad/managers/`, and exports
  `SQUAD_MANAGER_ID` so workers report to it;
- embeds the role file in the prompt;
- starts Claude Code with `--permission-mode auto` (set
  `SQUAD_DEVKIT_PERMISSION_MODE` to another mode, or to `default` to use your
  settings);
- leaves the squad when the CLI exits.

Workers record tasks in the manager's workspace (`SQUAD_DEVKIT_WORKSPACE`)
even when they work in another repository with `--project`.

## Choosing the manager

| CLI | Started as |
|---|---|
| `claude` (default) | `claude "<prompt>"` |
| `codex` | `codex "<prompt>"` |
| `agy` (Antigravity CLI) | `agy -i "<prompt>"` |
| `gemini` | `gemini -i "<prompt>"` |
| `grok` (Grok Build) | `grok "<prompt>"` |
| `opencode` | `opencode --prompt "<prompt>"` |

- If Claude Code is installed, it is the manager and nothing is asked.
- Otherwise the first run of `install-devkit.sh` or `squad-devkit` lists the
  installed CLIs and asks which one should manage. The answer is saved in
  `~/.config/squad-devkit/config` (set `SQUAD_DEVKIT_CONFIG` for another path)
  and reused from then on. If the saved CLI is later uninstalled, you are asked
  again.
- `squad-devkit --setup` chooses again at any time, including choosing another
  CLI while Claude Code is installed.
- `--manager CLI` or `SQUAD_DEVKIT_MANAGER=CLI` overrides the choice for one run.
- Non-interactive runs never ask. Without Claude Code or a saved choice, they
  use the first installed CLI from the table.

A Claude Code manager starts workers with `run_in_background` and is notified
when each one exits. Other managers start workers as detached shell jobs and
wait with a single `squad receive <id> --wait`, because every worker sends the
manager a squad message when it finishes or fails. The flags for `agy`,
`gemini`, `grok`, and `opencode` come from their documentation and have not
been tested by this repository.

## Run

```sh
squad-devkit                                  # from ~: general workspace; inside a repo: that repo
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

In a git repository the launcher leaves the working tree clean. `squad init`
normally appends guidance to `CLAUDE.md`, `AGENTS.md`, and `GEMINI.md` and adds
`.squad/` to `.gitignore`; the launcher restores those files and ignores
`.squad/` through `.git/info/exclude` instead. Set
`SQUAD_DEVKIT_KEEP_INIT_FILES=1` to keep squad's edits.

Without a project argument, the launcher uses the git repository containing the
current directory. Started from your home directory, it opens the manager in the
general workspace `~/.squad-devkit` (set `SQUAD_DEVKIT_GENERAL_WORKSPACE` for
another path). There:

- requests that need no repository, such as checking prod or staging logs,
  querying metrics, or writing a report, run their workers in the workspace, and
  reports go to `reports/`;
- for code changes, the manager finds the repositories involved and passes
  `--project <path>` to those workers.

An explicit home directory argument is still refused, unless
`SQUAD_DEVKIT_ALLOW_HOME=1` is set.

A single argument of three or more words that names no project is taken as the
objective, so `squad-devkit "check prod logs from 26/10 to 27/10"` works from
inside a project, or from your home directory in the general workspace.

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
| `--project DIR` | Repository the worker works in (default: the manager's workspace) |
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

## Watching workers

Every worker opens its own monitor pane next to the manager while it runs:

- **tmux** (`squad-devkit --tmux`, or a manager started inside tmux): the
  manager stays on the left and worker panes stack on the right
  (`main-vertical` layout). Focus stays on the manager.
- **Herdr**: the worker splits the manager's Herdr pane (`HERDR_PANE_ID`): the
  first worker goes to its right, later workers stack below the previous one,
  and focus stays on the manager. Herdr takes priority over Ghostty, so this
  also applies to Herdr running inside Ghostty.
- **Ghostty** (`squad-devkit` in a Ghostty terminal, or `--ghostty`): the
  launcher records the manager's terminal id. Splits follow the same layout,
  and focus returns to the manager.
- **Other terminals** (Terminal.app, iTerm2) get no automatic panes. Run
  `squad-monitor --all` in a spare window instead, or use `--tmux`.

Each pane refreshes every second:

```
dev-1 · codex (high) · role dev · ● RUNNING · 01:42
Task: Fix the off-by-one in src/pager.rs::page_count
Calls: 6 · failed: 1 · files changed: 2
Tokens: pending
──────────────────────────────────────────────
✗ cargo test pager  (exit 101)
✎ src/pager.rs
… running: cargo test pager
```

It shows commands (Codex) or tool calls and turns (CCR), failures, changed
files, and recent activity. Codex reports token usage when the run finishes.
claude-code-router does not report tokens, so CCR panes say so. When the run
ends, the pane shows the final state and the start of the report, and closes
when you press Enter. Set `SQUAD_WORKER_PANE_HOLD=<seconds>` to close it
automatically, or `SQUAD_WORKER_PANES=0` to open no panes.

`squad-monitor --all` shows one table of every run in `.squad/workers`
(worker, engine, role, state, elapsed time, calls, tokens, task). It works in
any terminal. Each run keeps `<id>-<time>.status`, `.log` (JSON events), and
`.md` (report) in that directory.

## Upgrading from the four-pane setup

The launcher no longer starts `dev-1`–`dev-3` panes. If a tmux session from the
old layout is still running, the launcher refuses to reuse it and prints the
`tmux kill-session` command; stop it once its work is saved. Role files that
lack the template line are kept as they are; replace them with the files in
`templates/devkit/` to get the new manager instructions.
