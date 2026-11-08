# Changelog

All notable changes to squad-devkit are documented here. The `squad` CLI
itself follows the upstream [mco-org/squad](https://github.com/mco-org/squad)
releases.

## [Unreleased]

### Added
- Add session-only `--yolo` for Claude, Codex, and AGY managers/workers, with explicit backend/fallback inheritance and sandbox conflict checks.

## [1.0.2] - 2026-11-02

### Added
- Optional `ui-ux` and `security` worker roles; the default team stays manager plus dev, and `security` runs read-only without a worktree.

### Changed
- squad-devkit is now licensed under GPL-3.0. Code from the upstream `squad`
  CLI keeps its MIT license, kept in `LICENSES/MIT-squad.txt`.
- README now covers squad-devkit only and adds Linux install steps and an FAQ;
  the upstream `squad` CLI reference moved to `docs/squad-cli.md` (Chinese:
  `docs/squad-cli.zh-CN.md`).
- CONTRIBUTING lists exactly the checks CI runs.
- `squad-worker --diff <id>` prints a worker's worktree changes without merging.

### Added
- A `squad-devkit` skill for Claude Code and Codex (`skills/squad-devkit/`),
  linked by the installer into `~/.claude/skills` and `~/.codex/skills`, so any
  session can delegate work to workers, review, and merge (`--no-skill` skips it).
- `opencode` worker engine (experimental), between codex and grok in the trust order.
- `squad-devkit --doctor` checks the core tools, manager and worker CLIs, and
  monitor pane support.
- `--workers` / `--disable-workers` (or `SQUAD_DEVKIT_WORKERS`,
  `SQUAD_DEVKIT_DISABLE_WORKERS`, `workers=` / `disabled_workers=` in the config)
  choose which worker engines the manager may use.
- Bash and zsh completions in `scripts/completions/`.
- `--sandbox` / `--no-sandbox` (and `SQUAD_WORKER_SANDBOX=0|1`) to toggle engine sandboxing for Codex (`workspace-write` vs `danger-full-access`) and Claude Code workers.

### Fixed
- Workers fall back to a client type that older `squad` builds accept
  (`ccr` → `claude`, `grok`/`agy` → `codex`) when `squad join` rejects
  `--client <engine>`. With the documented Homebrew `squad` 0.7.6, ccr, grok,
  and agy workers otherwise failed to join.
- Worktrees on paths that go through a symlink (such as `/tmp`) now add
  `.squad/` to `.git/info/exclude`, so merging no longer warns about an
  embedded git repository.
- Worker runs with no file changes finalize without Git exit 128.
- Codex MCP filtering handles plugin transports without invalid configuration;
  Claude workers accept optional scoped `SQUAD_WORKER_CLAUDE_ALLOWED_TOOLS` rules.
- Zsh completion suggests worker engines after `--workers` and `--disable-workers`.
- `squad join --client` accepts `grok`, `agy`, and `ccr`; workers now record
  their own engine as `client_type` (previously `codex`/`claude`).
- The stall watchdog also covers engines that print their report on stdout
  (`grok`, `agy`), so a silent run no longer waits for the full timeout.

### Removed
- Upstream planning notes (`docs/superpowers/`) and the Homebrew tap copy
  (`docs/homebrew-tap/`).

## [1.0.1] - 2026-10-28

### Changed
- Worker monitor panes no longer redraw the whole screen every second, which
  made them flicker. The header prints once, events are appended as they
  happen (coloured by kind), and only the status line is rewritten in place.
  A finished run shows a one-line summary, the merge command, and the report,
  then counts down before closing (Enter closes it at once).
- `squad-monitor --all` redraws its table in place with synchronized output
  and a hidden cursor.

### Fixed
- The monitor no longer stops after the task line when the terminal has no
  UTF-8 locale (for example over SSH or in CI).

## [1.0.0] - 2026-10-28

First public release of squad-devkit.

### Added
- `squad-devkit`: starts one manager (Claude Code by default; Codex, Antigravity,
  Gemini, Grok, or OpenCode when chosen) in the current terminal, a new Ghostty
  window, or tmux. From the home directory it uses the general workspace
  `~/.squad-devkit`, so tasks such as log checks and reports need no project.
- Manager role: triage (workstream, risk, complexity, needs-human), planning from
  five perspectives, trust-based worker selection, verification of every report,
  and fix loops until the acceptance criteria pass.
- `squad-worker`: on-demand workers on `claude` (haiku by default, sonnet or opus
  by choice), `codex`, `grok`, `agy`, or `ccr`
  with roles, `--project`, MCP filtering, time limits, stall detection,
  `--list`, and `--stop`.
- Isolated git worktrees: in a git repository each editing worker works on its
  own branch (`squad/<id>`) from a snapshot of the working tree; the manager
  reviews the diff and runs `squad-worker --merge` (three-way, uncommitted) or
  `--discard`.
- `squad-ask`: workers question the manager or each other while they run.
- Monitor panes for each worker in tmux, Herdr, Zellij, WezTerm, Kitty, iTerm2,
  or Ghostty; one dashboard window in other terminals (macOS Terminal.app,
  GNOME Terminal, Konsole, xterm); `squad-monitor --all` for a table of runs.
- Status line: claude-hud's weekly quota plus the squad label (running workers,
  tokens offloaded from Claude); the installer enables the weekly-quota display.
- Fallback: when Claude Code hits its usage or billing limit, a Codex manager
  takes over the session with a handoff of the recent conversation and tasks.
- `squad-route`: optional advisory triage through a typed-decision router.
- Housekeeping: automatic pruning of old worker runs, `--clean`, `--clean-all`.
- Installer, documentation, demo, contribution and security guides, code of
  conduct, issue and pull request templates, CI for the devkit scripts
  (shellcheck and smoke tests on Linux and macOS), and a release workflow for
  `v*` tags.

### Changed
- The upstream squad CLI release workflow now runs on `squad-v*` tags; the
  upstream website and Homebrew formula are no longer part of this repository.

### Fixed
- `cli_test` built `PATH` with `:` on Windows, which hid the fake binaries the
  `squad doctor` test relies on.
