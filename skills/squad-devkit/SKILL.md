---
name: squad-devkit
description: Delegate coding, testing, review, research, or log/report work to on-demand AI workers (Claude, Codex, OpenCode, Grok, Antigravity, or a cheap ccr model) that run in parallel in isolated git worktrees, then review and merge their changes. Use when the user wants to split work across workers, run squad-devkit or squad-worker, check worker status, merge or discard a worker's worktree, or save tokens by offloading work from the current session.
---

# squad-devkit

squad-devkit (https://github.com/bthanhtung/squad-devkit) runs one manager and
on-demand workers. Workers start only when given a task and exit when done; in
a git repository each editing worker gets its own worktree and branch
(`squad/<id>`), so parallel workers never overwrite each other.

Check the environment first when anything looks wrong: `squad-devkit --doctor`.

## Start a dedicated manager session

For a large or multi-step request, suggest that the human open a new terminal:

```sh
squad-devkit                         # from ~: general workspace; in a repo: that repo
squad-devkit my-repo "add rate limiting to the public API"
```

The manager plans, delegates, verifies, and merges on its own.

## Delegate from this session

To hand off work without leaving the current session, act as a light manager in
the general workspace `~/.squad-devkit`, which keeps squad files out of the
user's repositories:

```sh
mkdir -p ~/.squad-devkit && cd ~/.squad-devkit && squad init >/dev/null
squad join manager --role manager-devkit --protocol-version 2   # prints the joined ID
export SQUAD_DEVKIT_WORKSPACE="$HOME/.squad-devkit" SQUAD_MANAGER_ID=<joined ID>
```

Then start each worker as a background command (in Claude Code with
`run_in_background: true`; you are notified with its report when it exits),
and start independent workers together:

```sh
squad-worker dev-1 --engine codex --role dev --project /path/to/repo --plan .squad/plans/<name>.md --brief-file - <<'BRIEF'
Goal, files the worker owns, exact changes, acceptance criteria,
the verification command, and what is out of scope.
BRIEF
```

Workers see only the brief, so make it complete.

## Plans and approvals

- Every worker run needs `--plan .squad/plans/<name>.md`, validated: sections
  Triage, Goal, Perspectives, Tasks, Acceptance; Triage lines `Risk`,
  `Complexity` (low|moderate|high) and `squad-route`
  (`not configured` is fine; the installer links `squad-route`); all five
  perspective labels. Copy `templates/devkit/plan.md.example`. Show the human
  the plan summary before starting workers.
- Small follow-ups: add a `## Follow-up: <name>` section to the existing plan.
  `--no-plan "<reason>"` is only for genuine emergencies; the reason is
  recorded in the status file and report.
- Commit and push only after the human approves and you record
  `- commit: <repo>` / `- push: <repo>` under `## Approvals`, preferably with
  the absolute path (`- push: /abs/path/to/repo`); a bare basename matches
  every repo with that name. Remove these
  lines when the work is done; approvals do not expire. The Claude manager
  guard hook blocks them without it, and blocks Edit/Write outside `.squad/`,
  `$CLAUDE_CONFIG_DIR/projects/` (memory), temp dirs, and
  `SQUAD_DEVKIT_GUARD_ALLOW`; never other project paths. A wrapped commit or
  push that cannot be verified is denied: run plain `git -C <repo> ...`.
  `SQUAD_DEVKIT_GUARD=0` disables the guard (logged human decision only). It
  does not catch shell writes (`sed -i`, redirects): never use them on project
  files. Read the reviewer's verdict before merging: `completed` means it ran,
  not that it approved.
- New or empty repos: `squad-worker --clone <url>` or `--init` with
  `--project`, not your own git; repos with no commits run in place.
  `.claude/` is excluded automatically.
- Browser, dashboard, and DNS actions go in `## Manual ops` of the plan. When done, run
`squad leave <joined ID>` from `~/.squad-devkit`.

## Choose the worker

Pick the cheapest worker that can do the task well. Trust, highest first:
claude > codex > opencode > grok, agy > ccr.

| Task | Options |
|---|---|
| Must be right first time (high risk or complexity) | `--engine claude` (`--model haiku` by default, `sonnet` for complex work, `opus` for the hardest) |
| Normal implementation, debugging, tests; anything needing a shell or MCP | `--engine codex` (`--profile medium` for mechanical work; `--mcp NAME` to enable one MCP server) |
| Low-risk work or a second opinion (experimental) | `--engine opencode`, `grok`, or `agy` |
| Docs and small exact edits | `--engine ccr` (cheap, file tools only, no shell) |

Roles: `--role dev|tester|reviewer|researcher` (reviewers and researchers read
the project directly instead of using a worktree). `--project <path>` points a
worker at a repository; omit it for log checks and reports in the workspace.

## Review, merge, and housekeeping

```sh
squad-worker --list                  # running workers and unmerged worktrees
squad-worker --diff dev-1            # review a worker's changes
squad-worker --merge dev-1           # apply them, uncommitted, with a three-way merge
squad-worker --discard dev-1         # or drop them
squad-worker --stop dev-1            # stop a running worker (or --stop all)
squad-monitor --all                  # live table of every run in any terminal
```

A report is a claim, not proof: read the diff and rerun the verification
before merging. Merge one worker at a time. Conflicts leave standard markers
in the listed files. `--merge` refuses high-risk plans or sensitive patches
(auth, secret, token, `.env`, `_headers`, `netlify.toml`, `vercel.json`,
security paths; CSP, Authorization, API-key, private-key lines) without a newer
reviewer run on the same plan; `--override-review "<reason>"` records an
override in the plan. High-risk pushes also need `- review: <repo>`. Never commit or push without the human's approval.
Workers that fail, time out, or stall report back instead of hanging; rerun
or reassign their task.

Reference: `squad-devkit --help`, `squad-worker --help`, and
`docs/squad-devkit.md` in the squad-devkit repository.
