# Changelog

All notable changes to squad-devkit are documented here. The `squad` CLI
itself follows the upstream [mco-org/squad](https://github.com/mco-org/squad)
releases.

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
