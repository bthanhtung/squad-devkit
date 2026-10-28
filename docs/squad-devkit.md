# Local devkit: one manager with on-demand workers

`scripts/squad-devkit.sh` starts one interactive session as the project
**manager**: Claude Code by default, or another CLI you choose (see
[Choosing the manager](#choosing-the-manager)). The manager talks with you, researches, plans, and decides. When
work should be delegated, it starts **on-demand workers** with
`scripts/squad-worker.sh`:

- **Claude** (`claude -p`) for work that must be right the first time. Haiku by
  default for well-specified tasks, sonnet for complex or high-risk changes,
  opus for the hardest problems; fix rounds move up one model before moving to
  another engine.
- **Codex** (`codex exec`, sandboxed to the project) for implementation, tests,
  debugging, and anything that needs a shell or MCP servers.
- **Grok** and **Antigravity** (`grok -p`, `agy -p`, experimental) for low-risk
  work or a second opinion.
- **CCR** (Claude Code through claude-code-router, on the cheap model configured
  in `~/.claude-code-router/config.json`) for docs and small exact edits. CCR
  workers have file tools only, with no shell.

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

1. Triage the request: workstream (code, debug, infra, security, docs,
   research), risk, complexity, and whether a human must decide. With
   `squad-route` configured, it also records the router's advisory answer.
2. Read the code it will change and the code that calls it.
3. Plan from five perspectives (principal engineer, engineering manager,
   technical lead, QA, end user) and write `.squad/plans/<name>.md` with the
   triage, goal, findings (`path:line`), decisions, tasks with disjoint file
   ownership, and acceptance checks.
4. Pick each worker by trust and cost: `claude` > `codex` > `grok`, `agy` >
   `ccr`, matching the task's risk and complexity.
5. Give each worker a complete brief: the goal, the files the worker owns, the
   exact changes, the steps, the acceptance criteria, the verification
   commands, and what is out of scope.
6. Keep one background inbox listener (`squad receive <id> --wait`) while
   workers run, and answer their questions.
7. Verify each report against `git diff` and rerun the verification.
8. For each failed check, start a fix run with the same worker ID listing the
   defects. After two failed rounds, move up the trust order, split the task,
   or ask you.
9. Stop workers that are no longer needed, run the full acceptance checks,
   add a reviewer for high-risk changes, and report to you with evidence.

The launcher runs the manager through `scripts/lib/squad-devkit-manager.sh`.
This wrapper:

- archives managers whose recorded process has exited (or, without a pid
  file, that were not seen for `SQUAD_DEVKIT_STALE_MINUTES`, default 30);
- joins as `manager`, records its pid in `.squad/managers/`, and exports
  `SQUAD_MANAGER_ID` so workers report to it;
- passes the launcher's instructions and the role file as a system prompt
  (`--append-system-prompt` for Claude Code, `developer_instructions` for
  Codex), so the chat shows only your request; `agy`, `gemini`, `grok`, and
  `opencode` still receive them as the first message;
- starts Claude Code with `--permission-mode auto` (set
  `SQUAD_DEVKIT_PERMISSION_MODE` to another mode, or to `default` to use your
  settings);
- leaves the squad when the CLI exits.

### Fallback when Claude Code runs out

When Claude Code is the manager and `codex` is installed, the wrapper starts it
with a `StopFailure` hook (`--settings`). When a turn ends with `rate_limit` or
`billing_error`, meaning the account hit its usage or billing limit, the hook
stops Claude Code and the wrapper:

1. writes `.squad/managers/<id>.handoff.md` with the recent conversation from
   the Claude Code transcript and `squad task list`;
2. starts Codex in the same terminal as the manager, with the same squad ID, so
   workers keep reporting to it;
3. tells Codex to read the handoff, `.squad/plans/`, and the task list, rerun
   unfinished tasks, and continue.

Workers that Claude Code started in the background may stop with it; Codex
reruns their tasks. Set `SQUAD_DEVKIT_FALLBACK_MANAGER` to another CLI, or to
`none` to disable the fallback. `SQUAD_DEVKIT_FALLBACK_ON` changes which errors
trigger it (default `rate_limit|billing_error`).

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
| `--engine claude\|codex\|grok\|agy\|ccr` | Worker engine (required) |
| `--role ROLE` | Role prompt from `.squad/roles/ROLE.md` (default `dev`) |
| `--brief TEXT`, `--brief-file FILE\|-` | Self-contained task description (required) |
| `--title TITLE` | Task title (default: first line of the brief) |
| `--profile NAME` | Codex profile (default `high`) |
| `--model NAME` | Model for claude (default `haiku`; `sonnet`, `opus`), grok, or agy |
| `--timeout MINUTES` | Stop the run after this long (default 45) |
| `--mcp NAME`, `--all-mcp` | Codex: keep one or all MCP servers enabled |
| `--project DIR` | Repository the worker works in (default: the manager's workspace) |
| `--manager ID` | Manager agent ID (default `manager`) |
| `--list` | Show running workers |
| `--stop ID\|all` | Stop a running worker, which reports to the manager |
| `--worktree`, `--no-worktree` | Force or skip the isolated git worktree |
| `--merge ID` | Apply a worker's worktree changes (three-way, uncommitted) and remove it |
| `--discard ID\|all` | Remove a worker's worktree and branch without applying them |

The report is printed on stdout and saved to `.squad/workers/<id>-<time>.md`,
with the engine log and a `.status` file (state, pid, tokens) beside it.
`squad task list` shows every task with its summary. A worker that fails, runs
past its time limit, or produces no output for `SQUAD_WORKER_STALL` minutes
(default 10) is stopped, tells the manager what happened, and exits non-zero,
so the manager can rerun or reassign the task.

### Worktrees

In a git repository each editing worker runs in its own worktree,
`<workspace>/.squad/worktrees/<repository>-<hash>/<id>` on branch `squad/<id>`,
so parallel workers never overwrite each other. `.squad/` is listed in
`.git/info/exclude`, so nothing shows up in `git status`. (Worktrees do not
live inside `.git`, because agents treat files there as sensitive and refuse to
edit them.)

- **Start**: the worktree begins from a snapshot of your working tree, tracked
  and untracked files minus ignored ones, taken with a temporary index so your
  index and files are untouched. A fix round with the same worker ID continues
  in the same worktree until it is merged or discarded.
- **Finish**: the worker's changes are committed to `squad/<id>` and saved as
  `.squad/workers/<id>-<time>.patch`; the report gives the review command
  (`git -C <worktree> diff <base>`) and the merge command.
- **Merge**: `squad-worker --merge <id>` applies the changes to the project
  with a three-way merge through a temporary index, leaves them uncommitted,
  and removes the worktree and branch. Conflicts keep standard markers in the
  listed files and keep the worktree until `--discard`.
- **Choose**: reviewers and researchers read the project directly;
  `--worktree` forces isolation, `--no-worktree` edits in place, and
  `SQUAD_WORKER_WORKTREE=0` turns isolation off.

Housekeeping never removes runs whose worktree is still unmerged.

### Questions between workers

Workers with a shell (claude, codex, grok, agy) can talk to the squad while they
run, through `scripts/squad-ask.sh`, whose exact command is in their prompt:

```sh
squad-ask --from dev-1 --workspace <ws> --to manager "Should the retry be per request or per batch?"
squad-ask --from dev-1 --workspace <ws> --check                 # unread messages
squad-ask --from dev-1 --workspace <ws> --reply test-1 "Use fixtures/v2."
```

`--to` waits up to five minutes (`--timeout`) for the answer; without one, the
worker continues with its best judgment and states the assumption in its
report. The manager keeps a background inbox listener while workers run, so
questions reach it promptly.

CCR workers use the tools in `SQUAD_WORKER_CCR_TOOLS` (default
`Read,Edit,Write,Glob,Grep`). The worker starts the router if it isn't
listening, then runs `claude -p` with the environment from `ccr activate`. It
bypasses `ccr code`, whose running-service check can report a live router as
stopped and then time out.

Parallel workers share the repository, so the manager must give each worker
files that no other running worker edits. Workers never commit. The manager asks
you before commits, pushes, or destructive actions.

## Optional advisory router

`scripts/squad-route.sh` adapts typed-decision routing for the manager. With
`SQUAD_DEVKIT_ROUTER_URL` set, the manager sends a short redacted digest of the
task and receives the workstream, risk, complexity, whether a human must decide,
and a confidence score. The answer is advisory (shadow mode): it is recorded in
the plan, and it is accepted only at confidence 0.85 or higher, with no human
decision needed and risk below high. It never authorizes destructive actions,
security decisions, or deployments.

| Variable | Meaning |
|---|---|
| `SQUAD_DEVKIT_ROUTER_URL` | Endpoint that accepts `{model, state, questions}` |
| `SQUAD_DEVKIT_ROUTER_MODEL` | Model name sent in the request |
| `SQUAD_DEVKIT_ROUTER_KEY_ENV` | Variable holding the bearer token (default `SQUAD_DEVKIT_ROUTER_KEY`) |
| `SQUAD_DEVKIT_ROUTER_MIN_CONFIDENCE` | Acceptance threshold (default `0.85`) |

## Status line and savings

When Claude Code is the manager, the session gets a status line through
`--settings`:

- with [claude-hud](https://github.com/jarrodwatts/claude-hud), claude-hud's
  line plus the squad label through `--extra-cmd`, so you see the weekly quota
  next to the squad (the installer turns on `display.sevenDayThreshold = 0` and
  `display.usagePace = true` unless you set them);
- without a status line, the squad label alone;
- with another custom status line, nothing changes.

The label reads `squad 2 running · saved 1.2M tok`: the tokens that workers on
other engines processed instead of Claude during this session, plus the tokens
of any Claude workers. Set `SQUAD_DEVKIT_STATUSLINE=0` to turn it off.

## Housekeeping

Each launch prunes finished worker runs older than `SQUAD_DEVKIT_RETENTION_DAYS`
(default 7) and then removes the oldest finished runs while `.squad/workers`
exceeds `SQUAD_DEVKIT_MAX_MB` (default 200). Running workers, plans, and reports
outside `.squad/workers` are never removed. `squad-devkit --clean` prunes on
demand, and `squad-devkit --clean-all` removes every finished run.

## Watching workers

Every worker opens a live monitor next to the manager while it runs. The first
worker opens to the manager's right, later workers stack below the previous one,
and focus stays on the manager. squad-devkit uses the terminal the manager runs
in (`scripts/lib/squad-panes.sh`), checked in this order:

| Terminal | Detected by | How the monitor opens |
|---|---|---|
| tmux | `TMUX_PANE` | `split-window`, `main-vertical` layout (`squad-devkit --tmux` works in any terminal) |
| Herdr | `HERDR_PANE_ID` | `herdr pane split` |
| Zellij | `ZELLIJ` | `zellij run --floating` (Zellij only splits the focused pane, so workers float; toggle them with Zellij's floating-pane key) |
| WezTerm | `WEZTERM_PANE` | `wezterm cli split-pane`, then focus returns to the manager |
| Kitty | `KITTY_WINDOW_ID` | `kitten @ launch --keep-focus` (needs `allow_remote_control yes`; best with the `splits` layout) |
| iTerm2 | `ITERM_SESSION_ID` | AppleScript `split vertically/horizontally` |
| Ghostty | terminal id recorded by `squad-devkit` | AppleScript `split` |
| Anything else | | one dashboard window per manager session running `squad-monitor --all` |

The dashboard covers terminals without a split API: macOS Terminal.app (opened
with AppleScript), and on Linux desktops the first of `x-terminal-emulator`,
`gnome-terminal`, `konsole`, `xfce4-terminal`, or `xterm`. It also catches a
split that fails, such as Kitty without remote control. Over SSH or with no
desktop, no window opens: run `squad-monitor --all` yourself, or start the
manager with `squad-devkit --tmux`. `SQUAD_WORKER_PANES=0` turns monitors off
and `SQUAD_WORKER_DASHBOARD=0` turns off only the dashboard window.

tmux, Herdr, and Ghostty are tested end to end; the WezTerm, Kitty, iTerm2,
Zellij, and dashboard paths follow each terminal's documented API and are
covered by tests with stand-in commands.

A pane never redraws the whole screen, so it does not flicker. The header
prints once, each event is appended as it happens, and only the bottom status
line is rewritten in place:

```
dev-1 · codex (high) · role dev
Task: Fix the off-by-one in src/pager.rs::page_count
Branch: squad/dev-1 (isolated worktree)
──────────────────────────────────────────────
✗ cargo test pager  (exit 101)
✎ src/pager.rs
✓ cargo test pager
● RUNNING 01:42 · 3 calls · 1 failed · 1 file changed · … cargo clippy
```

Events are coloured by kind: commands that pass (✓) or fail (✗), file changes
(✎), tool and MCP calls (→, ⚙), and the worker's messages (»). The status line
shows elapsed time, calls, failures, changed files, turns, and the command in
progress. When the run ends, the pane prints a summary
(`✓ COMPLETED in 01:58 · 4 calls · 1 failed · 1 file changed · tokens in 39,760 (cached 7,424) · out 106`),
the merge command for worktree runs, and the start of the report, then counts
down and closes 60 seconds later (Enter closes it at once). Codex reports
tokens when the run finishes; claude-code-router does not report them. Set
`SQUAD_WORKER_PANE_HOLD=<seconds>` to change the delay, or
`SQUAD_WORKER_PANES=0` to open no panes. A run whose worker process ended
without updating its status shows as LOST.

`squad-monitor --all` shows one table of every run in `.squad/workers`
(worker, engine, role, state, elapsed time, calls, tokens, task), redrawn in
place every two seconds with synchronized output, so it does not flicker
either. It works in any terminal. Each run keeps `<id>-<time>.status`, `.log` (JSON events), and
`.md` (report) in that directory.

## Upgrading from the four-pane setup

The launcher no longer starts `dev-1`–`dev-3` panes. If a tmux session from the
old layout is still running, the launcher refuses to reuse it and prints the
`tmux kill-session` command; stop it once its work is saved. Role files that
lack the template line are kept as they are; replace them with the files in
`templates/devkit/` to get the new manager instructions.
