# Acceptance matrix

| Capability | Test script | What it covers | Live-only gaps |
|---|---|---|---|
| Run cost parsing and estimation | `tests/squad_cost_smoke.sh` | Reported, estimated, and unknown costs; token fields and price configuration | Real engine cost reporting and current provider prices |
| Plan snapshots and change notes | `tests/squad_worker_plan_smoke.sh` | Snapshot path/hash, retry attempt note, task plan validation | Real engine run behavior |
| Squad Deck and Needs you | `tests/squad_deck_smoke.sh`; `claude plugin test mods/squad-deck` | Status-file UI and deck helpers, including `needsYou` | Claude Code's live mod rendering |
| Gate loops | `tests/squad_worker_loop_smoke.sh` | Gate retries, loop limits, and expected-file checks | Real engine repair quality |
| Run evaluation | `tests/squad_eval_smoke.sh` | Weighted dimensions, threshold, and suggestions | Meaningfulness of scores on a real team workload |
| DAG plan execution | `tests/squad_dag_smoke.sh` | Task grammar, dependencies, dry run, retries, launch limits | Real Orca/tmux panes and engine launches |
| Approved team knowledge | `tests/squad_learn_smoke.sh` | Proposal, approval, path matching, lock and sandbox rules | Real malicious same-user processes; the store is not a security boundary against them |
| Worker recovery | `tests/squad_worker_recovery_smoke.sh` | Resume eligibility and host/engine ownership states | Cross-host process liveness |
| Orchestration view | `tests/squad_orchestration_smoke.sh`; `tests/squad_orchestration_keys_smoke.py` | Rendered states and keyboard controls | Live terminal rendering and pane mutations |

`squad_scout_smoke` and `squad_worker_plan_smoke` can fail when Orca pane splits
fail because of the environment. They pass under tmux or with `ORCA_*`
environment variables cleared. Codex sandbox write denial also requires a live
Codex run to verify.
