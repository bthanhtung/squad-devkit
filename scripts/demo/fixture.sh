#!/usr/bin/env bash
set -euo pipefail

export LC_ALL="${LC_ALL:-en_US.UTF-8}"

usage() {
  cat <<'EOF'
Usage: fixture.sh [--fake-clis] <dir>

Build a self-contained demo workspace under <dir> with fixture worker statuses,
logs, history, and fake CLI binaries, then print environment exports to eval.
EOF
}

fake_clis_only=0
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi
if [[ "${1:-}" == "--fake-clis" ]]; then
  fake_clis_only=1
  shift
fi

if (( $# < 1 )) || [[ -z "${1:-}" ]]; then
  usage >&2
  exit 2
fi

demo_dir="$1"
mkdir -p "$demo_dir"
demo_dir="$(cd "$demo_dir" && pwd -P)"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$script_dir/../.." && pwd -P)"

# Create isolated fake CLIs (claude, opencode, agy, squad) + basic utilities in <dir>/bin
# so `squad-devkit --setup` detects a deterministic set of engines.
setup_fake_clis() {
  local bin_dir="$1"
  mkdir -p "$bin_dir"
  local tool tool_path
  for tool in bash sh env dirname cksum cut head tail cat mkdir sed awk grep wc tr sort find date readlink basename mv rm ln chmod sleep clear tput stty jq git perl; do
    if tool_path="$(command -v "$tool" 2>/dev/null)"; then
      ln -sf "$tool_path" "$bin_dir/$tool"
    fi
  done

  local cli
  for cli in squad claude opencode agy; do
    cat > "$bin_dir/$cli" <<MOCK
#!/usr/bin/env bash
if [[ "\$*" == *"--version"* ]]; then
  echo "$cli version 1.0.0"
  exit 0
fi
if [[ "$cli \${1:-}" == "squad help" ]]; then
  echo "--client <claude|codex|gemini|opencode|grok|agy|ccr>"
  exit 0
fi
exit 0
MOCK
    chmod +x "$bin_dir/$cli"
  done

  ln -sf "$repo_root/scripts/squad-devkit.sh" "$bin_dir/squad-devkit"
  ln -sf "$repo_root/scripts/squad-orchestration.sh" "$bin_dir/squad-orchestration.sh"
  ln -sf "$repo_root/scripts/squad-worker-monitor.sh" "$bin_dir/squad-worker-monitor.sh"
}

setup_fake_clis "$demo_dir/bin"

if (( fake_clis_only == 1 )); then
  printf 'export PATH=%q\n' "$demo_dir/bin"
  printf 'export SQUAD_DEVKIT_CONFIG=%q\n' "$demo_dir/config"
  printf 'export SQUAD_DEVKIT_FORCE_PROMPT=1\n'
  printf 'unset SQUAD_DEVKIT_MANAGER_WRAPPER_PID\n'
  exit 0
fi

ws_dir="$demo_dir/ws"
workers_dir="$ws_dir/.squad/workers"
worktrees_dir="$ws_dir/.squad/worktrees"
plans_dir="/tmp/demo/ws/.squad/plans"
mkdir -p "$workers_dir" "$worktrees_dir/dev-1" "$worktrees_dir/dev-2" "$worktrees_dir/sm-api"

now="$(date +%s)"
since=$(( now - 300 ))

# Start live sleep processes for running workers (with stdout/stderr closed so $(...) does not block).
pids=()
start_live_pid() {
  sleep 600 >/dev/null 2>&1 &
  local p=$!
  pids+=("$p")
  REPLY="$p"
}

start_live_pid; pid_dev1="$REPLY"
start_live_pid; pid_test1="$REPLY"
start_live_pid; pid_smapi="$REPLY"
start_live_pid; pid_api1="$REPLY"

# Completed/failed workers use a deterministic non-running PID.
done_pid="${pids[0]}"

# ==============================================================================
# Plan 1: checkout-flow
#   manager -> dev-1 (agy, gemini-3.8-flash-medium, running)
#   manager -> dev-2 (opencode, deepseek-v4-pro, completed, round 2)
#   manager -> test-1 (agy, flash, asking: latest message is a QUESTION)
# ==============================================================================

cat > "$workers_dir/dev-1.log" <<'EOF'
{"event":"init","init":{"model":"gemini-3.8-flash-medium"}}
{"event":"step_update","step_update":{"step_type":"tool","state":"DONE","tool_name":"read_file","tool_info":{"parameters":{"Path":"src/checkout/cart.ts"}}}}
{"event":"step_update","step_update":{"step_type":"tool","state":"DONE","tool_name":"replace_file_content","tool_info":{"parameters":{"Path":"src/checkout/cart.ts"}}}}
{"event":"step_update","step_update":{"step_type":"tool","state":"DONE","tool_name":"write_to_file","tool_info":{"parameters":{"Path":"src/checkout/discount.ts"}}}}
{"event":"step_update","step_update":{"step_type":"tool","state":"DONE","tool_name":"run_command","tool_info":{"parameters":{"CommandLine":"npm test -- src/checkout/cart.test.ts"},"output":"PASS src/checkout/cart.test.ts (8 passed in 0.9s)"}}}
{"event":"result","result":{"num_turns":3,"usage":{"input_tokens":18400,"cache_read_input_tokens":6200,"output_tokens":4100}}}
{"event":"step_update","step_update":{"step_type":"tool","state":"ACTIVE","tool_name":"run_command","tool_info":{"parameters":{"CommandLine":"npm run typecheck"}}}}
EOF

cat > "$workers_dir/dev-1.status" <<EOF
worker=dev-1
engine=agy
model=gemini-3.8-flash-medium
requested_model=gemini-3.8-flash-medium
model_source=flag
actual_model=gemini-3.8-flash-medium
configured_model=gemini-3.8-flash-medium
configured_model_source=agy-init
role=dev
title=Implement cart totals and discount validation
state=running
pid=$pid_dev1
started=$(( now - 84 ))
tokens_in=18400
tokens_cached=6200
tokens_out=4100
worktree=$worktrees_dir/dev-1
log=$workers_dir/dev-1.log
report=$workers_dir/dev-1.report
plan=$plans_dir/checkout-flow.md
EOF

cat > "$workers_dir/dev-2-1.log" <<'EOF'
{"type":"tool_use","part":{"tool":"edit","state":{"status":"completed","input":{"filePath":"src/checkout/session.ts"}}}}
{"type":"step_finish","part":{"tokens":{"input":12000,"output":5000,"reasoning":0,"cache":{"read":4000,"write":0}}}}
EOF

cat > "$workers_dir/dev-2-1.status" <<EOF
worker=dev-2
engine=opencode
model=deepseek-v4-pro
requested_model=deepseek-v4-pro
model_source=flag
actual_model=unknown
role=dev
title=Implement checkout session handler (round 1)
state=completed
pid=$done_pid
started=$(( now - 210 ))
finished=$(( now - 150 ))
tokens_in=12000
tokens_out=5000
worktree=$worktrees_dir/dev-2
log=$workers_dir/dev-2-1.log
plan=$plans_dir/checkout-flow.md
EOF

cat > "$workers_dir/dev-2-2.log" <<'EOF'
{"type":"tool_use","part":{"tool":"edit","state":{"status":"completed","input":{"filePath":"src/checkout/session.ts"}}}}
{"type":"tool_use","part":{"tool":"shell","state":{"status":"completed","input":{"command":"npm test -- src/checkout/session.test.ts"},"output":"PASS src/checkout/session.test.ts (5 passed)","metadata":{"metadata":{"exit":0}}}}}
{"type":"step_finish","part":{"tokens":{"input":24000,"output":11000,"reasoning":0,"cache":{"read":8000,"write":0}}}}
EOF

cat > "$workers_dir/dev-2-2.status" <<EOF
worker=dev-2
engine=opencode
model=deepseek-v4-pro
requested_model=deepseek-v4-pro
model_source=flag
actual_model=deepseek-v4-pro
role=dev
title=Add retry backoff on gateway 502
state=completed
pid=$done_pid
started=$(( now - 135 ))
finished=$(( now - 38 ))
tokens_in=24000
tokens_out=11000
worktree=$worktrees_dir/dev-2
log=$workers_dir/dev-2-2.log
plan=$plans_dir/checkout-flow.md
EOF

cat > "$workers_dir/test-1.log" <<'EOF'
{"event":"init","init":{"model":"gemini-3.8-flash"}}
{"event":"step_update","step_update":{"step_type":"tool","state":"DONE","tool_name":"read_file","tool_info":{"parameters":{"Path":"tests/checkout.spec.ts"}}}}
{"event":"result","result":{"num_turns":1,"usage":{"input_tokens":9200,"cache_read_input_tokens":3000,"output_tokens":2800}}}
EOF

cat > "$workers_dir/test-1.status" <<EOF
worker=test-1
engine=agy
model=gemini-3.8-flash
requested_model=gemini-3.8-flash
model_source=flag
actual_model=gemini-3.8-flash
configured_model=gemini-3.8-flash
configured_model_source=agy-init
role=tester
title=Integration tests for promo codes
state=running
pid=$pid_test1
started=$(( now - 25 ))
tokens_in=9200
tokens_out=2800
log=$workers_dir/test-1.log
plan=$plans_dir/checkout-flow.md
EOF

# ==============================================================================
# Plan 2: payments-api
#   sub-manager sm-api (agy, gemini-4-argon-high, running, depth=1)
#   children api-1 (running, parent=sm-api, depth=2), api-2 (completed, parent=sm-api, depth=2)
#   failed reviewer rev-1
# ==============================================================================

cat > "$workers_dir/sm-api.log" <<'EOF'
{"event":"init","init":{"model":"gemini-4-argon-high"}}
{"event":"step_update","step_update":{"step_type":"tool","state":"DONE","tool_name":"read_file","tool_info":{"parameters":{"Path":"src/payments/index.ts"}}}}
{"event":"result","result":{"num_turns":2,"usage":{"input_tokens":16000,"cache_read_input_tokens":5000,"output_tokens":6000}}}
EOF

cat > "$workers_dir/sm-api.status" <<EOF
worker=sm-api
engine=agy
model=gemini-4-argon-high
requested_model=gemini-4-argon-high
model_source=flag
actual_model=gemini-4-argon-high
configured_model=gemini-4-argon-high
configured_model_source=agy-init
role=sub-manager
title=Coordinate payments API endpoints and webhook verification
state=running
pid=$pid_smapi
started=$(( now - 145 ))
tokens_in=16000
tokens_out=6000
parent=
depth=1
budget_tokens=600000
max_children=3
worktree=$worktrees_dir/sm-api
log=$workers_dir/sm-api.log
plan=$plans_dir/payments-api.md
EOF

cat > "$workers_dir/api-1.log" <<'EOF'
{"event":"init","init":{"model":"gemini-3.8-flash-medium"}}
{"event":"step_update","step_update":{"step_type":"tool","state":"DONE","tool_name":"write_to_file","tool_info":{"parameters":{"Path":"src/payments/webhook.ts"}}}}
{"event":"result","result":{"num_turns":2,"usage":{"input_tokens":14000,"cache_read_input_tokens":4000,"output_tokens":5500}}}
EOF

cat > "$workers_dir/api-1.status" <<EOF
worker=api-1
engine=agy
model=gemini-3.8-flash-medium
requested_model=gemini-3.8-flash-medium
model_source=flag
actual_model=gemini-3.8-flash-medium
configured_model=gemini-3.8-flash-medium
configured_model_source=agy-init
role=dev
title=Implement HMAC webhook signature verification
state=running
pid=$pid_api1
started=$(( now - 96 ))
tokens_in=14000
tokens_out=5500
parent=sm-api
depth=2
log=$workers_dir/api-1.log
plan=$plans_dir/payments-api.md
EOF

cat > "$workers_dir/api-2.log" <<'EOF'
{"event":"init","init":{"model":"gemini-3.8-flash-medium"}}
{"event":"step_update","step_update":{"step_type":"tool","state":"DONE","tool_name":"replace_file_content","tool_info":{"parameters":{"Path":"src/payments/charges.ts"}}}}
{"event":"result","result":{"num_turns":2,"usage":{"input_tokens":19000,"cache_read_input_tokens":6000,"output_tokens":7500}}}
EOF

cat > "$workers_dir/api-2.status" <<EOF
worker=api-2
engine=agy
model=gemini-3.8-flash-medium
requested_model=gemini-3.8-flash-medium
model_source=flag
actual_model=gemini-3.8-flash-medium
configured_model=gemini-3.8-flash-medium
configured_model_source=agy-init
role=dev
title=Add idempotency keys to POST /v1/charges
state=completed
pid=$done_pid
started=$(( now - 130 ))
finished=$(( now - 48 ))
tokens_in=19000
tokens_out=7500
parent=sm-api
depth=2
log=$workers_dir/api-2.log
plan=$plans_dir/payments-api.md
EOF

cat > "$workers_dir/rev-1.log" <<'EOF'
{"type":"assistant","message":{"model":"claude-haiku-4-5","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"npm run lint"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","is_error":true,"content":"src/payments/webhook.ts:42:5 error: unexpected token"}}]}}
{"type":"result","num_turns":1,"usage":{"input_tokens":6200,"output_tokens":900}}
EOF

cat > "$workers_dir/rev-1.status" <<EOF
worker=rev-1
engine=claude
model=claude-haiku-4-5
requested_model=haiku
model_source=builtin
actual_model=claude-haiku-4-5
role=reviewer
title=Security review for payment webhooks
state=failed
reason=command failed
exit=1
pid=$done_pid
started=$(( now - 75 ))
finished=$(( now - 30 ))
tokens_in=6200
tokens_out=900
log=$workers_dir/rev-1.log
plan=$plans_dir/payments-api.md
EOF

# ==============================================================================
# History file in `squad history` format
# ==============================================================================
cat > "$demo_dir/history.txt" <<'EOF'
  [2026-11-14T09:01:10Z] manager -> sm-api: ## Goal Coordinate payments-api endpoints and webhook verification
  [2026-11-14T09:01:25Z] sm-api -> api-2: ## Goal Add idempotency keys to POST /v1/charges
  [2026-11-14T09:01:40Z] manager -> dev-2: ## Goal Implement checkout session handler in /tmp/demo/ws
  [2026-11-14T09:02:05Z] dev-2 -> manager: QUESTION from dev-2: Retry on 502 from payment gateway?
  [2026-11-14T09:02:18Z] manager -> dev-2: ANSWER from manager: Yes, exponential backoff up to 3 attempts
  [2026-11-14T09:02:45Z] api-2 -> sm-api: api-2 (agy) completed task 4a9c: idempotency keys verified
  [2026-11-14T09:03:00Z] sm-api -> api-1: ## Goal Implement HMAC webhook signature verification
  [2026-11-14T09:03:15Z] manager -> dev-1: ## Goal Implement cart totals and discount validation in /tmp/demo/ws
  [2026-11-14T09:03:40Z] dev-2 -> manager: dev-2 (opencode) completed task 8b1d: round 2 retry backoff passing
  [2026-11-14T09:03:55Z] rev-1 -> manager: rev-1 (claude) failed: lint check exited with code 1
  [2026-11-14T09:04:10Z] test-1 -> manager: QUESTION from test-1: Should expired promo codes return 422 or 400?
EOF

cat > "$demo_dir/manager-pane.sh" <<'EOF'
#!/usr/bin/env bash
printf '\033[1;35mmanager\033[0m · claude (claude-opus-4-7) · view: panes\n'
printf '\033[2mPlan: .squad/plans/checkout-flow.md\033[0m\n'
printf '\033[2m──────────────────────────────────────────────────────\033[0m\n\n'
printf '\033[1muser>\033[0m Add cart discount validation and 502 retry.\n\n'
printf '\033[1;35mmanager>\033[0m Triaged (moderate, 2 independent files).\n'
printf '\033[1;35mmanager>\033[0m starting dev-1 (agy) and dev-2 (opencode)…\n\n'
printf '  \033[33m●\033[0m dev-1  agy · gemini-3.8-flash-medium   running\n'
printf '  \033[32m✓\033[0m dev-2  opencode · deepseek-v4-pro      completed\n\n'
printf '\033[1;35mmanager>\033[0m dev-2 round 2 passed 5/5 session tests.\n'
printf '\033[1;35mmanager>\033[0m waiting on dev-1 typecheck before merge…\n'
exec sleep 600
EOF
chmod +x "$demo_dir/manager-pane.sh"

cat > "$demo_dir/cleanup.sh" <<EOF
#!/usr/bin/env bash
kill ${pids[*]} 2>/dev/null || true
rm -rf $(printf '%q' "$demo_dir")
EOF
chmod +x "$demo_dir/cleanup.sh"

printf 'unset SQUAD_DEVKIT_MANAGER_WRAPPER_PID\n'
printf 'export SQUAD_ORCHESTRATION_HISTORY_CMD=%q\n' "cat $demo_dir/history.txt"
printf 'export SQUAD_DEVKIT_SESSION_START=%q\n' "$since"
printf 'export SQUAD_MANAGER_ID=manager\n'
printf 'export SQUAD_ORCHESTRATION_FLOW_LINES=4\n'
printf 'export DEMO_PIDS=%q\n' "${pids[*]}"
printf '# cleanup: kill %s 2>/dev/null; rm -rf %q\n' "${pids[*]}" "$demo_dir"
