# Security policy

## Reporting a vulnerability

Please report vulnerabilities privately through
[GitHub security advisories](https://github.com/bthanhtung/squad-devkit/security/advisories/new)
rather than in a public issue. Include the affected version or commit, steps to
reproduce, and the impact. You will get an acknowledgement within a few days,
and a fix or mitigation plan once the report is confirmed.

## How squad-devkit handles trust and data

- **Permissions.** The manager runs Claude Code in `auto` permission mode
  (`SQUAD_DEVKIT_PERMISSION_MODE` changes it). Codex workers run in the
  `workspace-write` sandbox, limited to the project and the squad workspace.
  Claude workers get six core tools, accept file edits, and run shell commands
  only inside Claude Code's sandbox (denied where the sandbox is unavailable);
  ccr workers get file tools only.
  Review what you delegate as you would review a teammate's change.
- **Credentials.** squad-devkit never stores tokens. MCP servers read their
  tokens from your environment; a worker whose server lacks its token fails
  fast instead of looking for credentials elsewhere, and worker prompts forbid
  reading secrets from configuration files.
- **Local data.** Plans, task records, worker logs, and reports stay in
  `.squad/` inside the workspace. In git repositories `.squad/` is excluded
  through `.git/info/exclude`, so it is never committed. Old worker runs are
  pruned automatically (`SQUAD_DEVKIT_RETENTION_DAYS`, `SQUAD_DEVKIT_MAX_MB`).
- **Optional router.** `squad-route` sends a short redacted task digest to the
  endpoint in `SQUAD_DEVKIT_ROUTER_URL`, only when you configure it. Its answer
  is advisory and never authorizes destructive actions.
- **Status line.** For claude-hud users, the manager session enables
  claude-hud's `--extra-cmd` (`CLAUDE_HUD_ALLOW_EXTRA_CMD=1`) only to run
  squad-devkit's own savings command.

### Opt-in YOLO sessions

`squad-devkit --yolo --manager codex` starts a session with native engine
permission bypass; workers started by that manager inherit it. Claude, Codex,
and AGY are supported. `squad-worker dev-1 --engine claude --yolo --brief "Run the checks"`
opts in a single worker independently. Without opt-in, existing behavior is unchanged.

The session boolean `SQUAD_DEVKIT_YOLO=1` carries opt-in through here, tmux,
Ghostty, and manager fallback; `0` disables inheritance. It is never saved to
configuration. Unsupported engines reject YOLO. YOLO conflicts with worker
`--sandbox` and `SQUAD_WORKER_SANDBOX=1`; omit YOLO to use sandboxing.
Claude uses `--dangerously-skip-permissions` with session sandboxing disabled,
Codex uses `--dangerously-bypass-approvals-and-sandbox`, and AGY uses
`--dangerously-skip-permissions` without `--sandbox`.

Use only in an environment you trust: this bypasses engine permission checks
and engine sandboxing, not OS/admin restrictions. Conversational instructions
are not permission controls. No global settings or role instructions change.
An existing tmux session keeps its original mode; exit it before changing modes.
