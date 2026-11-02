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
squad-worker dev-1 --engine codex --project /path/to/repo --brief-file - <<'BRIEF'
Goal, files the worker owns, exact changes, acceptance criteria,
the verification command, and what is out of scope.
BRIEF
```

Workers see only the brief, so make it complete. When done, run
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
in the listed files. Never commit or push without the human's approval.
Workers that fail, time out, or stall report back instead of hanging; rerun
or reassign their task.

Reference: `squad-devkit --help`, `squad-worker --help`, and
`docs/squad-devkit.md` in the squad-devkit repository.
