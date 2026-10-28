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
