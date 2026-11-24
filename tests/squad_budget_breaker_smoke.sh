#!/usr/bin/env bash
set -euo pipefail
unset SQUAD_DEVKIT_YOLO SQUAD_WORKER_SANDBOX SQUAD_RUST_DISABLE SQUAD_SANDBOX_PROFILE
unset SQUAD_DEVKIT_WORKSPACE SQUAD_WORKTREE_WORKSPACE SQUAD_MANAGER_ID SQUAD_WORKER_REQUIRE_PLAN
unset TMUX TMUX_PANE HERDR_ENV HERDR_PANE_ID SQUAD_BUDGET_USED_TOKENS SQUAD_BUDGET_USED_USD
repo="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home" TERM_PROGRAM=test-terminal SQUAD_DEVKIT_NOTIFY=0 SQUAD_WORKER_HEADLESS=1
mkdir -p "$HOME" "$tmp/bin" "$tmp/ws"
export PATH="$repo/target/debug:$tmp/bin:$PATH"
cat >"$tmp/bin/claude" <<'ENGINE'
#!/usr/bin/env bash
case "$BUDGET_FIXTURE" in
  hard)
    echo '{"type":"assistant","message":{"id":"one","usage":{"input_tokens":200,"output_tokens":20}}}'
    sleep 20
    touch "$BUDGET_SENTINEL"
    ;;
  soft) echo '{"type":"result","usage":{"input_tokens":10,"output_tokens":2},"total_cost_usd":2,"result":"Done"}' ;;
  retry) echo '{"type":"result","usage":{"input_tokens":10,"output_tokens":0},"result":"Done"}' ;;
  *) echo '{"type":"result","result":"Done"}' ;;
esac
ENGINE
chmod +x "$tmp/bin/claude"
cd "$tmp/ws"
squad init >/dev/null
cp "$repo/templates/devkit/dev.md" .squad/roles/dev.md
squad join manager --role manager-devkit --client claude --protocol-version 2 >/dev/null
export BUDGET_SENTINEL="$tmp/not-killed"
run() {
  BUDGET_FIXTURE="$1" "$repo/scripts/squad-worker.sh" "$1" --engine claude --model test-model --no-worktree --no-plan test --brief test "${@:2}" >"$tmp/out" 2>"$tmp/err"
}
status() { ls -t .squad/workers/"$1"-*.status | head -n 1; }
if run hard --budget-tokens 100; then echo 'FAIL hard limit succeeded' >&2; exit 1; fi
grep -qx 'budget_exceeded=1' "$(status hard)"
grep -qx 'budget_mode=hard' "$(status hard)"
test ! -e "$BUDGET_SENTINEL"
if run soft --budget-usd 1; then echo 'FAIL soft limit succeeded' >&2; exit 1; fi
grep -qx 'budget_exceeded=1' "$(status soft)"
grep -qx 'budget_mode=soft' "$(status soft)"
run unknown --budget-usd 1 --budget-tokens 100
grep -qx 'budget_exceeded=0' "$(status unknown)"
# Usage in the same loop chain counts toward the next loop iteration's budget.
cat >.squad/workers/retry-20200101-000000.status <<'STATUS'
worker=retry
plan_task=retry-task
attempt=1
loop_iter=1
tokens_in=95
tokens_out=0
cost_usd=0
STATUS
if SQUAD_LOOP_ITER=2 BUDGET_FIXTURE=retry "$repo/scripts/squad-worker.sh" retry --engine claude --model test-model --no-worktree --no-plan test --plan-task retry-task --brief test --budget-tokens 100 >"$tmp/out" 2>"$tmp/err"; then echo 'FAIL retry total ignored' >&2; exit 1; fi
grep -qx 'budget_exceeded=1' "$(status retry)"
# Multi-iteration chains include each earlier loop iteration in the budget.
cat >.squad/workers/loop-20200101-000000.status <<'STATUS'
worker=loop
plan_task=loop-task
attempt=1
loop_iter=1
tokens_in=50
tokens_out=0
cost_usd=0
STATUS
cat >.squad/workers/loop-20200101-000001.status <<'STATUS'
worker=loop
plan_task=loop-task
attempt=1
loop_iter=2
tokens_in=45
tokens_out=0
cost_usd=0
STATUS
if SQUAD_LOOP_ITER=3 BUDGET_FIXTURE=retry "$repo/scripts/squad-worker.sh" loop --engine claude --model test-model --no-worktree --no-plan test --plan-task loop-task --brief test --budget-tokens 100 >"$tmp/out" 2>"$tmp/err"; then echo 'FAIL loop total ignored' >&2; exit 1; fi
grep -qx 'budget_exceeded=1' "$(status loop)"
# A fresh invocation with the same worker and plan task starts with no prior spend.
run retry --no-plan test --plan-task retry-task --budget-tokens 100
grep -qx 'budget_exceeded=0' "$(status retry)"
run gate --verify "echo forbidden >'$tmp/gate-outside'" || true
grep -qx 'verify=fail' "$(status gate)" || { cat "$(status gate)" "$tmp/err" .squad/workers/gate-*.verify.log >&2; exit 1; }
test ! -e "$tmp/gate-outside"
echo 'PASS budget breaker' 
