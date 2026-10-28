# Changelog

All notable changes to squad-devkit are documented here. The `squad` CLI
itself follows the upstream [mco-org/squad](https://github.com/mco-org/squad)
releases.

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
- `squad-ask`: workers question the manager or each other while they run.
- Monitor panes for each worker in Herdr, tmux, or Ghostty, and
  `squad-monitor --all` for a table of runs.
- Status line: claude-hud's weekly quota plus the squad label (running workers,
  tokens offloaded from Claude); the installer enables the weekly-quota display.
- Fallback: when Claude Code hits its usage or billing limit, a Codex manager
  takes over the session with a handoff of the recent conversation and tasks.
- `squad-route`: optional advisory triage through a typed-decision router.
- Housekeeping: automatic pruning of old worker runs, `--clean`, `--clean-all`.
- Installer, documentation, contribution and security guides, and CI for the
  devkit scripts (shellcheck and smoke tests on Linux and macOS).

### Fixed
- `cli_test` built `PATH` with `:` on Windows, which hid the fake binaries the
  `squad doctor` test relies on.
