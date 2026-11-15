#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${TEST_SIGHUP_RESET:-}" ]] && command -v perl >/dev/null 2>&1; then
  export TEST_SIGHUP_RESET=1
  exec perl -e '$SIG{HUP} = "DEFAULT"; exec @ARGV' -- "$0" "$@"
fi

export LC_ALL="${LC_ALL:-en_US.UTF-8}"
# The suite must not depend on the manager session that runs it.
unset SQUAD_MANAGER_ID SQUAD_AGENT_ID SQUAD_DEVKIT_WORKSPACE SQUAD_WORKTREE_WORKSPACE SQUAD_DEVKIT_YOLO \
  SQUAD_DEVKIT_MANAGER_WRAPPER_PID SQUAD_DEVKIT_SESSION_START SQUAD_DEVKIT_MANAGER_CLIENT SQUAD_ORCHESTRATION_LAYOUT

root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/squad-orch.XXXXXX")"
tmp="$(cd "$tmp" && pwd -P)"
live_pid=""
non_tty_pid=""
cleanup() {
  if [[ -n "${live_pid:-}" ]]; then
    kill "$live_pid" 2>/dev/null || true
    wait "$live_pid" 2>/dev/null || true
  fi
  if [[ -n "${non_tty_pid:-}" ]]; then
    kill "$non_tty_pid" 2>/dev/null || true
    wait "$non_tty_pid" 2>/dev/null || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT

workers_dir="$tmp/.squad/workers"
mkdir -p "$workers_dir"

now="$(date +%s)"
since=$(( now - 600 ))

# Find a dead PID for the lost worker fixture
dead_pid=99999
while kill -0 "$dead_pid" 2>/dev/null; do
  dead_pid=$(( dead_pid + 1 ))
done

# Fixture 1: Plan A, dev-1 round 1 (completed)
cat > "$workers_dir/dev-1-1.status" <<EOF
worker=dev-1
engine=opencode
model=opencode-go/deepseek-v4-pro
role=dev
title=Initial implementation
state=completed
pid=$$
started=$(( now - 300 ))
finished=$(( now - 260 ))
tokens_in=20000
tokens_out=40000
plan=/path/to/setup-wizard.md
EOF

# Fixture 2: Plan A, dev-1 round 2 (running with alive pid=$$)
cat > "$workers_dir/dev-1-2.status" <<EOF
worker=dev-1
engine=opencode
model=opencode-go/deepseek-v4-pro
role=dev
title=Fixing issues
state=running
pid=$$
started=$(( now - 252 ))
tokens_in=50000
tokens_out=90000
plan=/path/to/setup-wizard.md
EOF

# Existing worktree directory for REVIEW column test
wt_review_dir="$tmp/worktree-test-1"
mkdir -p "$wt_review_dir"

# Fixture 3: Plan A, test-1 (completed, with existing worktree -> REVIEW)
cat > "$workers_dir/test-1.status" <<EOF
worker=test-1
engine=agy
model=google/gemini-3.8-flash
role=tester
title=Run test suite
state=completed
pid=$$
started=$(( now - 70 ))
finished=$(( now - 7 ))
tokens_in=15000
tokens_out=5000
worktree=$wt_review_dir
plan=/path/to/setup-wizard.md
EOF

# Fixture 3b: Plan A, dev-2 (running round 1, latest message is QUESTION -> asking)
cat > "$workers_dir/dev-2.status" <<EOF
worker=dev-2
engine=agy
model=gemini-4-argon-high
role=dev
title=UI styling
state=running
pid=$$
started=$(( now - 63 ))
tokens_in=10000
tokens_out=5000
plan=/path/to/setup-wizard.md
EOF

# Fixture 3c: Plan A, done-1 (completed, no worktree -> DONE)
cat > "$workers_dir/done-1.status" <<EOF
worker=done-1
engine=opencode
model=deepseek/deepseek-v4
role=dev
title=Cleanup
state=completed
pid=$$
started=$(( now - 50 ))
finished=$(( now - 30 ))
tokens_in=5000
tokens_out=2000
worktree=
plan=/path/to/setup-wizard.md
EOF

# Fixture 4: No plan, r-1 (failed)
cat > "$workers_dir/r-1.status" <<EOF
worker=r-1
engine=claude
model=claude-sonnet-5-5
role=reviewer
title=Code review
state=failed
pid=$$
started=$(( now - 20 ))
finished=$(( now - 10 ))
tokens_in=0
tokens_out=0
plan=
EOF

# Fixture 5: No plan, lost-1 (running state with dead PID -> lost)
cat > "$workers_dir/lost-1.status" <<EOF
worker=lost-1
engine=codex
model=gpt-5
role=dev
title=Crashed worker
state=running
pid=$dead_pid
started=$(( now - 15 ))
plan=
EOF

# Fixture 6: Old run before since (started < since, must NOT appear)
cat > "$workers_dir/old-1.status" <<EOF
worker=old-worker
engine=codex
model=gpt-4
role=dev
title=Old session worker
state=completed
pid=$$
started=$(( since - 200 ))
finished=$(( since - 100 ))
plan=/path/to/old-plan.md
EOF

# History test hook: multi-line message, QUESTION, ANSWER, completed task (done), and unanswered QUESTION from dev-2
export SQUAD_ORCHESTRATION_HISTORY_CMD='cat <<EOF
* [2026-11-14T07:01:00Z] manager-4 -> dev-1: ## Goal
This is a multi-line continuation line.
Another continuation line that should be ignored.
* [2026-11-14T07:05:00Z] dev-1 -> manager-4: QUESTION from dev-1: Two brief requirements break
* [2026-11-14T07:06:00Z] manager-4 -> dev-1: ANSWER from manager-4: Option b is preferred
* [2026-11-14T07:09:00Z] dev-1 -> manager-4: dev-1 (opencode) completed task 7bfb
* [2026-11-14T07:10:00Z] dev-2 -> manager-4: QUESTION from dev-2: Need layout confirmation
EOF'

assert_max_width() {
  local text="$1" max_w="$2" label="$3"
  local line char_count
  while IFS= read -r line; do
    char_count="$(printf '%s' "$line" | wc -m | tr -d ' ')"
    if (( char_count > max_w )); then
      echo "FAIL ($label): line exceeds $max_w characters ($char_count): '$line'" >&2
      exit 1
    fi
  done <<< "$text"
}

assert_utf8() {
  local text="$1" label="$2"
  printf '%s\n' "$text" > "$tmp/utf8.in"
  if ! iconv -f UTF-8 -t UTF-8 "$tmp/utf8.in" > "$tmp/utf8.out" 2> "$tmp/utf8.err"; then
    echo "FAIL ($label): output is not valid UTF-8: $(cat "$tmp/utf8.err")" >&2
    exit 1
  fi
}

# ==============================================================================
# A. Default layout (--once) is graph
# ==============================================================================
graph_output="$(COLUMNS=80 "$root/scripts/squad-orchestration.sh" --once --since "$since" "$workers_dir")"

echo "=== Default (graph) output under COLUMNS=80 ==="
printf '%s\n' "$graph_output"
echo "==============================================="

grep -q "● manager-4  ·  plan setup-wizard  ·  ●2 running ✓2 ✗2" <<< "$graph_output" || { echo "FAIL: graph header missing plan/counts" >&2; exit 1; }
grep -q "│ manager-4 " <<< "$graph_output" || { echo "FAIL: graph missing manager node" >&2; exit 1; }
grep -q "╭─" <<< "$graph_output" || { echo "FAIL: graph missing rounded top border" >&2; exit 1; }
grep -q "╰─" <<< "$graph_output" || { echo "FAIL: graph missing rounded bottom border" >&2; exit 1; }
# Numbered stage nodes in start order: dev-1 (oldest) .. done-1 (newest) of the active plan
n=0
for wid in dev-1 test-1 dev-2 done-1; do
  n=$(( n + 1 ))
  grep -q "│ 0${n} ${wid} " <<< "$graph_output" || { echo "FAIL: graph missing numbered node '0${n} ${wid}'" >&2; exit 1; }
done
grep -q "─ask─*▶" <<< "$graph_output" || { echo "FAIL: graph missing edge label 'ask'" >&2; exit 1; }
grep -q "─done─*▶" <<< "$graph_output" || { echo "FAIL: graph missing edge label 'done'" >&2; exit 1; }
grep -q "│ ? waiting " <<< "$graph_output" || { echo "FAIL: graph missing '? waiting' chip" >&2; exit 1; }
grep -q "│ ✓ done " <<< "$graph_output" || { echo "FAIL: graph missing '✓ done' chip" >&2; exit 1; }
grep -q "│ ● running " <<< "$graph_output" || { echo "FAIL: graph missing '● running' chip" >&2; exit 1; }
grep -q "│ tester · " <<< "$graph_output" || { echo "FAIL: graph missing 'role · model' line" >&2; exit 1; }
grep -q "^Waiting on you" <<< "$graph_output" || { echo "FAIL: graph missing 'Waiting on you' group" >&2; exit 1; }
grep -q "^? dev-2  Need layout confirmation" <<< "$graph_output" || { echo "FAIL: waiting group missing dev-2 question" >&2; exit 1; }
grep -q "^Outcomes  ✓ " <<< "$graph_output" || { echo "FAIL: graph missing Outcomes line" >&2; exit 1; }
grep -q "^Outcomes  ✓ done-1 test-1$" <<< "$graph_output" || { echo "FAIL: Outcomes must list only the displayed plan's workers" >&2; exit 1; }
grep -q "^Conversation" <<< "$graph_output" || { echo "FAIL: graph missing Conversation panel" >&2; exit 1; }
if grep -q "Flow (latest" <<< "$graph_output"; then
  echo "FAIL: Conversation must replace 'Flow (latest N)' in graph layout" >&2
  exit 1
fi
grep -q 'dev-1  brief "This is a multi-line continuation line."' <<< "$graph_output" || { echo "FAIL: Conversation missing dev-1 brief title (first line after ## Goal)" >&2; exit 1; }
graph_wide="$(COLUMNS=120 "$root/scripts/squad-orchestration.sh" --once --since "$since" "$workers_dir")"
grep -q 'dev-1  brief "This is a multi-line continuation line." · last done 07:09' <<< "$graph_wide" || {
  echo "FAIL: Conversation missing dev-1 summary line at COLUMNS=120" >&2
  printf '%s\n' "$graph_wide" >&2
  exit 1
}
assert_max_width "$graph_wide" 120 "graph COLUMNS=120"
# Fan-out layout: branches from a trunk, never an edge out of a worker node
grep -q "├" <<< "$graph_output" || { echo "FAIL: graph missing fan-out branch '├'" >&2; exit 1; }
grep -q "└─done─*▶" <<< "$graph_output" || { echo "FAIL: graph missing last branch '└─done───▶'" >&2; exit 1; }
if grep -qE '│ [a-z-]+ · [^│]*│─' <<< "$graph_output$graph_wide"; then
  echo "FAIL: an edge leaves a worker node (workers must not be chained)" >&2
  exit 1
fi
if grep -qE '(brief|fix|done|ask|answer) "(Goal|Selection)' <<< "$graph_output"; then
  echo "FAIL: Conversation shows a heading-only title" >&2
  exit 1
fi
if grep -qE '## Goal|7bfb|completed task' <<< "$graph_output"; then
  echo "FAIL: Conversation leaked '## Goal', a task id or a report line" >&2
  exit 1
fi
[[ "$(grep -c '^History  ' <<< "$graph_output")" == 1 ]] || { echo "FAIL: expected exactly one History line" >&2; exit 1; }
grep -q "^History  1 earlier plan · ✓0 ✗2" <<< "$graph_output" || { echo "FAIL: History line summary wrong" >&2; exit 1; }
assert_utf8 "$graph_output" "graph COLUMNS=80"
legacy_cards="$(COLUMNS=80 "$root/scripts/squad-orchestration.sh" --layout cards --once --since "$since" "$workers_dir")"
grep -q "▲ QUESTION" <<< "$legacy_cards" || { echo "FAIL: graph missing edge label '▲ QUESTION'" >&2; exit 1; }
grep -q "│ ? waiting " <<< "$legacy_cards" || { echo "FAIL: graph missing '? waiting ' in box" >&2; exit 1; }
grep -q "│ 4-argon-high   │" <<< "$legacy_cards" || { echo "FAIL: graph missing short_model '4-argon-high'" >&2; exit 1; }
grep -q "│ deepseek-v4-p… │" <<< "$legacy_cards" || { echo "FAIL: graph missing short_model 'deepseek-v4-p…'" >&2; exit 1; }
grep -q "│ sonnet-5-5     │" <<< "$legacy_cards" || { echo "FAIL: graph missing short_model 'sonnet-5-5'" >&2; exit 1; }
if grep -q "\\[g\\]raph" <<< "$graph_output"; then
  echo "FAIL: --once header should drop interactive key hints" >&2
  exit 1
fi
if grep -q $'\033' <<< "$graph_output"; then
  echo "FAIL: ANSI escape characters found in graph --once output" >&2
  exit 1
fi
assert_max_width "$graph_output" 80 "graph COLUMNS=80"

# ==============================================================================
# B. --layout tree --once still passes all old tree assertions
# ==============================================================================
output="$(COLUMNS=80 "$root/scripts/squad-orchestration.sh" --layout tree --once --since "$since" "$workers_dir")"

echo "=== Tree output under COLUMNS=80 ==="
printf '%s\n' "$output"
echo "===================================="

# 1. Plan headings
grep -q "Plan setup-wizard" <<< "$output" || { echo "FAIL: missing 'Plan setup-wizard'" >&2; exit 1; }
grep -q "Plan (no plan)" <<< "$output" || { echo "FAIL: missing 'Plan (no plan)'" >&2; exit 1; }

# 2. Tree lines
grep -q "├─▶" <<< "$output" || { echo "FAIL: missing tree branch '├─▶'" >&2; exit 1; }
grep -q "└─▶" <<< "$output" || { echo "FAIL: missing tree branch '└─▶'" >&2; exit 1; }

# 3. Round 2 for dev-1
grep -q "round 2" <<< "$output" || { echo "FAIL: missing 'round 2'" >&2; exit 1; }

# 4. Lost worker
grep -q "lost" <<< "$output" || { echo "FAIL: missing 'lost'" >&2; exit 1; }

# 5. Hidden old run (started < --since)
if grep -q "old-worker" <<< "$output"; then
  echo "FAIL: old-worker appeared in output despite started < --since" >&2
  exit 1
fi
if grep -q "old-plan" <<< "$output"; then
  echo "FAIL: old-plan appeared in output despite started < --since" >&2
  exit 1
fi

# 6. Flow arrows with QUESTION / ANSWER / done
grep -q "──QUESTION──▶" <<< "$output" || { echo "FAIL: missing '──QUESTION──▶'" >&2; exit 1; }
grep -q "──ANSWER──▶" <<< "$output" || { echo "FAIL: missing '──ANSWER──▶'" >&2; exit 1; }
grep -q "──done──▶" <<< "$output" || { echo "FAIL: missing '──done──▶'" >&2; exit 1; }

# 7. No escape chars in --once output
if grep -q $'\033' <<< "$output"; then
  echo "FAIL: ANSI escape characters found in --once output" >&2
  exit 1
fi

# 8. Every line <= 80 characters with COLUMNS=80 (count characters, not bytes)
assert_max_width "$output" 80 "tree COLUMNS=80"

# ==============================================================================
# C. --layout pipeline --once and SQUAD_ORCHESTRATION_LAYOUT=pipeline
# ==============================================================================
pipeline_output="$(COLUMNS=80 "$root/scripts/squad-orchestration.sh" --layout pipeline --once --since "$since" "$workers_dir")"

echo "=== Pipeline output under COLUMNS=80 ==="
printf '%s\n' "$pipeline_output"
echo "========================================"

grep -E "RUNNING.*──▶.*FIX.*──▶.*REVIEW.*──▶.*DONE.*──▶.*FAILED" <<< "$pipeline_output" >/dev/null || {
  echo "FAIL: pipeline missing column headers RUNNING..FAILED with ──▶" >&2
  exit 1
}

# Extract the pipeline section between the top rule and the Flow rule
pipeline_body="$(awk '
  /^RUNNING/ { in_pipe=1; next }
  in_pipe && /^─/ { exit }
  in_pipe { print }
' <<< "$pipeline_output")"

col_running=""
col_fix=""
col_review=""
col_done=""
col_failed=""
while IFS= read -r pline; do
  [[ -n "$pline" ]] || continue
  col_running+="${pline:0:14}"$'\n'
  col_fix+="${pline:16:14}"$'\n'
  col_review+="${pline:32:14}"$'\n'
  col_done+="${pline:48:14}"$'\n'
  col_failed+="${pline:64:14}"$'\n'
done <<< "$pipeline_body"

grep -q "dev-2" <<< "$col_running" || { echo "FAIL: expected dev-2 under RUNNING column, got: $col_running" >&2; exit 1; }
grep -q "dev-1" <<< "$col_fix" || { echo "FAIL: expected round-2 running dev-1 under FIX column, got: $col_fix" >&2; exit 1; }
grep -q "test-1" <<< "$col_review" || { echo "FAIL: expected completed worker with worktree (test-1) under REVIEW column, got: $col_review" >&2; exit 1; }
grep -q "done-1" <<< "$col_done" || { echo "FAIL: expected completed worker without worktree (done-1) under DONE column, got: $col_done" >&2; exit 1; }
grep -q "r-1" <<< "$col_failed" || { echo "FAIL: expected failed worker (r-1) under FAILED column, got: $col_failed" >&2; exit 1; }
grep -q "lost-1" <<< "$col_failed" || { echo "FAIL: expected lost worker (lost-1) under FAILED column, got: $col_failed" >&2; exit 1; }

assert_max_width "$pipeline_output" 80 "pipeline COLUMNS=80"

# SQUAD_ORCHESTRATION_LAYOUT=pipeline selects pipeline
env_pipe_out="$(COLUMNS=80 SQUAD_ORCHESTRATION_LAYOUT=pipeline "$root/scripts/squad-orchestration.sh" --once --since "$since" "$workers_dir")"
grep -E "RUNNING.*──▶.*FIX.*──▶.*REVIEW.*──▶.*DONE.*──▶.*FAILED" <<< "$env_pipe_out" >/dev/null || {
  echo "FAIL: SQUAD_ORCHESTRATION_LAYOUT=pipeline did not select pipeline layout" >&2
  exit 1
}

# ==============================================================================
# D. Invalid options and --layout bogus exit 2
# ==============================================================================
# 9. --bogus exits 2
set +e
"$root/scripts/squad-orchestration.sh" --bogus >/dev/null 2>&1
status_bogus=$?
"$root/scripts/squad-orchestration.sh" --layout bogus --once "$workers_dir" >/dev/null 2>&1
status_layout_bogus=$?
SQUAD_ORCHESTRATION_LAYOUT=bogus "$root/scripts/squad-orchestration.sh" --once "$workers_dir" >/dev/null 2>&1
status_env_bogus=$?
set -e
if [[ $status_bogus -ne 2 ]]; then
  echo "FAIL: expected --bogus to exit 2, got $status_bogus" >&2
  exit 1
fi
if [[ $status_layout_bogus -ne 2 ]]; then
  echo "FAIL: expected --layout bogus to exit 2, got $status_layout_bogus" >&2
  exit 1
fi
if [[ $status_env_bogus -ne 2 ]]; then
  echo "FAIL: expected SQUAD_ORCHESTRATION_LAYOUT=bogus to exit 2, got $status_env_bogus" >&2
  exit 1
fi

# ==============================================================================
# E. Width checks: COLUMNS=80 and COLUMNS=60 for all layouts; COLUMNS=18 fallback
# ==============================================================================
for lay in graph pipeline tree; do
  for cols in 80 60; do
    w_out="$(COLUMNS="$cols" "$root/scripts/squad-orchestration.sh" --layout "$lay" --once --since "$since" "$workers_dir")"
    assert_max_width "$w_out" "$cols" "$lay COLUMNS=$cols"
  done
done

narrow_graph="$(COLUMNS=18 "$root/scripts/squad-orchestration.sh" --layout graph --once --since "$since" "$workers_dir")"
assert_max_width "$narrow_graph" 18 "graph fallback COLUMNS=18"
grep -q "├─▶" <<< "$narrow_graph" || { echo "FAIL: COLUMNS=18 graph did not fall back to tree" >&2; exit 1; }
if grep -q "┌─" <<< "$narrow_graph"; then
  echo "FAIL: COLUMNS=18 graph rendered box borders instead of falling back to tree" >&2
  exit 1
fi

# ==============================================================================
# F. Six workers in one plan with COLUMNS=80 -> compacts to 1 row + "+2 earlier"
# ==============================================================================
six_dir="$tmp/six/.squad/workers"
mkdir -p "$six_dir"
for idx in 1 2 3 4 5 6; do
  cat > "$six_dir/w-${idx}.status" <<EOF
worker=w-${idx}
engine=agy
model=google/gemini-3.8-flash
role=dev
title=Task ${idx}
state=running
pid=$$
started=$(( now - 100 + idx ))
plan=/path/to/six-plan.md
EOF
done

six_out="$(COLUMNS=80 "$root/scripts/squad-orchestration.sh" --layout graph --once --since "$since" "$six_dir")"
assert_max_width "$six_out" 80 "six workers graph COLUMNS=80"
for idx in 1 2 3 4 5 6; do
  grep -q "│ 0${idx} w-${idx} " <<< "$six_out" || { echo "FAIL: missing numbered node 0${idx} w-${idx} in 6-worker graph" >&2; exit 1; }
done
# Fan-out: one vertical trunk, each worker on its own branch
grep -q "┬─brief" <<< "$six_out" || { echo "FAIL: 6 workers should fan out from the manager trunk" >&2; exit 1; }
[[ "$(grep -c '├─brief' <<< "$six_out")" == 4 ]] || { echo "FAIL: expected 4 middle branches '├─brief'" >&2; exit 1; }
grep -q "└─brief" <<< "$six_out" || { echo "FAIL: last branch should be '└─'" >&2; exit 1; }
# Short pane: earliest rows are folded into "… N earlier"
six_short="$(LINES=14 COLUMNS=80 "$root/scripts/squad-orchestration.sh" --layout graph --once --since "$since" "$six_dir")"
assert_max_width "$six_short" 80 "six workers graph LINES=14"
grep -q "… [0-9]* earlier" <<< "$six_short" || { echo "FAIL: LINES=14 should fold earlier rows into '… N earlier'" >&2; exit 1; }
[[ "$(wc -l <<< "$six_short" | tr -d ' ')" -le 14 ]] || { echo "FAIL: LINES=14 render taller than 14 lines" >&2; exit 1; }

# 10. Failing history command still renders
failing_out="$(SQUAD_ORCHESTRATION_HISTORY_CMD="exit 1" "$root/scripts/squad-orchestration.sh" --once --since "$since" "$workers_dir")"
grep -q "plan setup-wizard" <<< "$failing_out" || { echo "FAIL: rendering failed with failing history command" >&2; exit 1; }

# 11. Workspace directory starting with .squad- (e.g. $tmp/.squad-ws/.squad/workers)
# and relative WORKERS_DIR from the workspace root.
ws_special="$tmp/.squad-ws"
mkdir -p "$ws_special/.squad/workers"
cat > "$ws_special/.squad/workers/long-1.status" <<EOF
worker=w-1
engine=opencode
model=opencode-go/a-very-long-model-name-for-testing-width-v1
role=dev
title=Long model name worker
state=completed
pid=$$
started=$(( now - 50 ))
finished=$(( now - 10 ))
plan=/path/to/special-plan.md
EOF

pwd_out_file="$tmp/history_pwd.txt"
special_output="$(
  cd "$ws_special"
  SQUAD_ORCHESTRATION_HISTORY_CMD="pwd > '$pwd_out_file'; echo '[2026-11-14T07:15:00Z] manager-4 -> w-1: hello special'" \
    COLUMNS=120 "$root/scripts/squad-orchestration.sh" --layout tree --once --since "$since" ".squad/workers"
)"

# Assert header contains .squad-ws
grep -q "· .squad-ws ·" <<< "$special_output" || {
  echo "FAIL: expected header to contain '.squad-ws', got:" >&2
  echo "$special_output" >&2
  exit 1
}

# Assert Flow section is present
grep -q "Flow (latest" <<< "$special_output" || {
  echo "FAIL: expected Flow section in .squad-ws run" >&2
  exit 1
}

# Assert HISTORY_CMD ran in the workspace root
if [[ ! -f "$pwd_out_file" ]] || [[ "$(cat "$pwd_out_file")" != "$ws_special" ]]; then
  echo "FAIL: HISTORY_CMD did not run in workspace root $ws_special (was: '$(cat "$pwd_out_file" 2>/dev/null || true)')" >&2
  exit 1
fi

# Assert row with long model has at least two spaces before the state icon
# Long model row should look like: ... opencode · a-very-long-model-name-…  ✓ completed ...
grep -E "opencode · [^[:space:]]+[[:space:]]{2,}✓ completed" <<< "$special_output" || {
  echo "FAIL: row for long model did not preserve at least two spaces before state icon:" >&2
  echo "$special_output" >&2
  exit 1
}

# Assert no "0 tok" in the header when no tokens
grep -q "tok" <<< "$special_output" && {
  echo "FAIL: expected no tokens in header when workers have no tokens, got:" >&2
  echo "$special_output" >&2
  exit 1
}

# ==============================================================================
# H. Height & Compaction (20 workers across 4 plans, LINES=30 COLUMNS=100)
# ==============================================================================
twenty_dir="$tmp/twenty/.squad/workers"
mkdir -p "$twenty_dir"
for idx in $(seq 1 20); do
  p_num=$(( (idx - 1) % 4 + 1 ))
  w_state="completed"
  w_fin="finished=$(( now - 50 + idx ))"
  if (( idx == 1 )); then
    w_state="running"
    w_fin=""
  elif (( idx == 5 || idx == 9 )); then
    w_state="failed"
  fi
  cat > "$twenty_dir/w-${idx}.status" <<EOF
worker=w-${idx}
engine=opencode
model=deepseek/deepseek-v4
role=dev
state=${w_state}
pid=$$
started=$(( now - 200 + idx ))
${w_fin}
tokens_in=1000
tokens_out=2000
plan=/path/to/plan-${p_num}.md
EOF
done

for lay in graph pipeline tree; do
  h_out="$(LINES=30 COLUMNS=100 "$root/scripts/squad-orchestration.sh" --layout "$lay" --once --since "$since" "$twenty_dir")"
  assert_max_width "$h_out" 100 "20-workers $lay COLUMNS=100"
  h_lines="$(wc -l <<< "$h_out" | tr -d ' ')"
  if (( h_lines > 30 )); then
    echo "FAIL ($lay): expected at most 30 lines under LINES=30, got $h_lines:" >&2
    echo "$h_out" >&2
    exit 1
  fi
  if [[ "$lay" == "graph" ]]; then
    grep -q "^History  3 earlier plans · ✓15 ✗0" <<< "$h_out" || {
      echo "FAIL (graph): expected one History line for 3 earlier plans:" >&2
      echo "$h_out" >&2
      exit 1
    }
    continue
  fi
  grep -q "▸ Plan" <<< "$h_out" || {
    echo "FAIL ($lay): expected collapsed '▸ Plan' line in 20-worker 4-plan output:" >&2
    echo "$h_out" >&2
    exit 1
  }
  grep -E "\+[0-9]+ (earlier|more)" <<< "$h_out" >/dev/null || {
    echo "FAIL ($lay): expected '+N earlier/more' summary in 20-worker output:" >&2
    echo "$h_out" >&2
    exit 1
  }
done

# ==============================================================================
# I. Animation & Colour (FORCE_COLOR, FRAME=0 vs FRAME=1, NO_COLOR)
# ==============================================================================
anim_f0="$(
  COLUMNS=80 SQUAD_ORCHESTRATION_FORCE_COLOR=1 SQUAD_ORCHESTRATION_FRAME=0 \
    "$root/scripts/squad-orchestration.sh" --layout graph --once --since "$since" "$workers_dir"
)"
anim_f1="$(
  COLUMNS=80 SQUAD_ORCHESTRATION_FORCE_COLOR=1 SQUAD_ORCHESTRATION_FRAME=1 \
    "$root/scripts/squad-orchestration.sh" --layout graph --once --since "$since" "$workers_dir"
)"

grep -q $'\033' <<< "$anim_f0" || { echo "FAIL: expected ESC sequences with SQUAD_ORCHESTRATION_FORCE_COLOR=1" >&2; exit 1; }
grep -E '[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]' <<< "$anim_f0" >/dev/null || { echo "FAIL: expected braille spinner in frame 0" >&2; exit 1; }
grep -E '[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]' <<< "$anim_f1" >/dev/null || { echo "FAIL: expected braille spinner in frame 1" >&2; exit 1; }
if [[ "$anim_f0" == "$anim_f1" ]]; then
  echo "FAIL: expected frame 0 and frame 1 to differ under SQUAD_ORCHESTRATION_FORCE_COLOR=1" >&2
  exit 1
fi

no_color_out="$(
  COLUMNS=80 NO_COLOR=1 \
    "$root/scripts/squad-orchestration.sh" --layout graph --once --since "$since" "$workers_dir"
)"
if grep -q $'\033' <<< "$no_color_out"; then
  echo "FAIL: expected no ESC sequences when NO_COLOR=1 and FORCE_COLOR is unset" >&2
  exit 1
fi

# Verify no literal quotes around running count in header (with or without colour)
for hdr_check in "$(head -n 1 <<< "$graph_output")" "$(head -n 1 <<< "$anim_f0")"; do
  if [[ "$hdr_check" == *'"'* ]]; then
    echo "FAIL: literal quote found in header: $hdr_check" >&2
    exit 1
  fi
done

# ==============================================================================
# J. Header part-dropping at COLUMNS=80 with 42 done / 11 failed counts
# ==============================================================================
hdr_dir="$tmp/hdr/.squad/workers"
mkdir -p "$hdr_dir"
cat > "$hdr_dir/r-run.status" <<EOF
worker=r-run
engine=agy
model=gemini-3.8-flash
role=dev
state=running
pid=$$
started=$(( now - 30 ))
tokens_in=50000
tokens_out=25000
plan=/path/to/plan-a.md
EOF
for idx in $(seq 1 42); do
  cat > "$hdr_dir/d-${idx}.status" <<EOF
worker=d-${idx}
engine=agy
model=gemini-3.8-flash
role=dev
state=completed
pid=$$
started=$(( now - 200 + idx ))
finished=$(( now - 100 + idx ))
tokens_in=1000
tokens_out=1000
plan=/path/to/plan-a.md
EOF
done
for idx in $(seq 1 11); do
  cat > "$hdr_dir/f-${idx}.status" <<EOF
worker=f-${idx}
engine=agy
model=gemini-3.8-flash
role=dev
state=failed
pid=$$
started=$(( now - 150 + idx ))
finished=$(( now - 50 + idx ))
plan=/path/to/plan-a.md
EOF
done

hdr80_out="$(COLUMNS=80 "$root/scripts/squad-orchestration.sh" --layout graph --once --since "$since" "$hdr_dir")"
assert_max_width "$hdr80_out" 80 "header 42 done 11 failed COLUMNS=80"
hdr80_line="$(head -n 1 <<< "$hdr80_out")"
if [[ "$hdr80_line" == *'"'* ]]; then
  echo "FAIL: header contains literal quote: $hdr80_line" >&2
  exit 1
fi
grep -q "●1 running ✓42 ✗11" <<< "$hdr80_line" || {
  echo "FAIL: header cut counts at COLUMNS=80: '$hdr80_line'" >&2
  exit 1
}

# ==============================================================================
# K. Hierarchy: sub-manager sm-a (2 children, one running) + plain worker
# ==============================================================================
hier_dir="$tmp/hier/.squad/workers"
mkdir -p "$hier_dir"
cat > "$hier_dir/sm-a.status" <<EOF
worker=sm-a
engine=agy
model=gemini-4-argon-high
role=sub-manager
state=running
pid=$$
started=$(( now - 120 ))
tokens_in=10000
tokens_out=5000
parent=
depth=1
budget_tokens=600000
max_children=3
plan=/path/to/china-campaign.md
EOF
cat > "$hier_dir/api-1.status" <<EOF
worker=api-1
engine=agy
model=gemini-3.8-flash-medium
role=dev
state=completed
pid=$$
started=$(( now - 100 ))
finished=$(( now - 60 ))
tokens_in=12000
tokens_out=8000
parent=sm-a
depth=2
plan=/path/to/china-campaign.md
EOF
cat > "$hier_dir/api-2.status" <<EOF
worker=api-2
engine=agy
model=gemini-3.8-flash-medium
role=dev
state=running
pid=$$
started=$(( now - 90 ))
tokens_in=6000
tokens_out=4000
parent=sm-a
depth=2
plan=/path/to/china-campaign.md
EOF
cat > "$hier_dir/dev-12.status" <<EOF
worker=dev-12
engine=opencode
model=deepseek/deepseek-v4
role=dev
state=completed
pid=$$
started=$(( now - 110 ))
finished=$(( now - 20 ))
tokens_in=5000
tokens_out=5000
parent=
depth=1
plan=/path/to/china-campaign.md
EOF
cat > "$hier_dir/dev-11.status" <<EOF
worker=dev-11
engine=opencode
model=deepseek/deepseek-v4
role=dev
state=completed
pid=$$
started=$(( now - 80 ))
finished=$(( now - 50 ))
tokens_in=3000
tokens_out=2000
parent=
depth=1
plan=/path/to/second-plan.md
EOF

hier_hist='cat <<EOF
* [2026-11-14T07:01:00Z] manager-4 -> sm-a: Delegate API branch
* [2026-11-14T07:02:00Z] sm-a -> api-1: Build endpoints
* [2026-11-14T07:03:00Z] api-1 -> sm-a: api-1 completed task 10
* [2026-11-14T07:04:00Z] sm-a -> api-2: Add validation
* [2026-11-14T07:05:00Z] api-2 -> sm-a: QUESTION from api-2: Which schema?
EOF'

hier_graph="$(
  SQUAD_ORCHESTRATION_HISTORY_CMD="$hier_hist" \
    COLUMNS=80 "$root/scripts/squad-orchestration.sh" --layout graph --once --since "$since" "$hier_dir"
)"
echo "=== Hierarchy root graph ==="
printf '%s\n' "$hier_graph"
echo "============================"
assert_max_width "$hier_graph" 80 "hierarchy root graph COLUMNS=80"
grep -q "│ 01 sm-a " <<< "$hier_graph" || { echo "FAIL: root graph missing sub-manager node '01 sm-a'" >&2; exit 1; }
grep -q "│ sub-mgr · " <<< "$hier_graph" || { echo "FAIL: root graph missing 'sub-mgr · model' line" >&2; exit 1; }
grep -q "│ 02 dev-12 " <<< "$hier_graph" || { echo "FAIL: root graph missing plain worker '02 dev-12'" >&2; exit 1; }
# Children are an indented mini-row under their sub-manager, not boxes
grep -q "^[ │]*└ 01 api-1 · ✓" <<< "$hier_graph" || { echo "FAIL: root graph missing child mini-row '└ 01 api-1 · ✓'" >&2; exit 1; }
grep -q "^[ │]*└ 02 api-2 · ?" <<< "$hier_graph" || { echo "FAIL: root graph missing child mini-row '└ 02 api-2 · ?'" >&2; exit 1; }
if grep -q "│ 0[0-9] api-" <<< "$hier_graph"; then
  echo "FAIL: children must not be drawn as boxes at root level" >&2
  exit 1
fi
# A sub-manager's chat with its children stays out of its own Conversation line
if grep -q "sm-a .*fix → done" <<< "$hier_graph"; then
  echo "FAIL: sm-a Conversation line mixes in its children's messages" >&2
  exit 1
fi

# Zoomed graph with --root sm-a --once
hier_zoom="$(
  SQUAD_ORCHESTRATION_HISTORY_CMD="$hier_hist" \
    COLUMNS=80 "$root/scripts/squad-orchestration.sh" --layout graph --root sm-a --once --since "$since" "$hier_dir"
)"
echo "=== Hierarchy zoomed graph (--root sm-a) ==="
printf '%s\n' "$hier_zoom"
echo "============================================"
assert_max_width "$hier_zoom" 80 "hierarchy zoomed graph COLUMNS=80"
grep -q "manager-4 › sm-a" <<< "$hier_zoom" || { echo "FAIL: zoomed graph missing breadcrumb 'manager-4 › sm-a'" >&2; exit 1; }
grep -q "╔" <<< "$hier_zoom" || { echo "FAIL: zoomed graph missing double-border top box for sm-a" >&2; exit 1; }
grep -q "│ api-1 " <<< "$hier_zoom" || { echo "FAIL: zoomed graph missing child box 'api-1'" >&2; exit 1; }
grep -q "│ api-2 " <<< "$hier_zoom" || { echo "FAIL: zoomed graph missing child box 'api-2'" >&2; exit 1; }
grep -q "▲ QUESTION" <<< "$hier_zoom" || { echo "FAIL: zoomed graph missing child edge '▲ QUESTION'" >&2; exit 1; }

# Hierarchy tree layout: nests children under sm-a with extra indent
hier_tree="$(
  SQUAD_ORCHESTRATION_HISTORY_CMD="$hier_hist" \
    COLUMNS=80 "$root/scripts/squad-orchestration.sh" --layout tree --once --since "$since" "$hier_dir"
)"
echo "=== Hierarchy tree ==="
printf '%s\n' "$hier_tree"
echo "======================"
assert_max_width "$hier_tree" 80 "hierarchy tree COLUMNS=80"
grep -E "^   [├└]─▶ sm-a " <<< "$hier_tree" >/dev/null || { echo "FAIL: tree missing depth-1 sm-a row" >&2; exit 1; }
grep -E "^      ├─▶ api-1 " <<< "$hier_tree" >/dev/null || { echo "FAIL: tree did not nest api-1 under sm-a" >&2; exit 1; }
grep -E "^      └─▶ api-2 " <<< "$hier_tree" >/dev/null || { echo "FAIL: tree did not nest api-2 under sm-a" >&2; exit 1; }

# Hierarchy pipeline layout: shows sm-a›, orders newest first, preserves worker id when truncating long plan name
hier_pipe="$(
  SQUAD_ORCHESTRATION_HISTORY_CMD="$hier_hist" \
    COLUMNS=80 "$root/scripts/squad-orchestration.sh" --layout pipeline --once --since "$since" "$hier_dir"
)"
echo "=== Hierarchy pipeline ==="
printf '%s\n' "$hier_pipe"
echo "=========================="
assert_max_width "$hier_pipe" 80 "hierarchy pipeline COLUMNS=80"
grep -q "sm-a›api-1" <<< "$hier_pipe" || { echo "FAIL: pipeline missing 'sm-a›api-1'" >&2; exit 1; }
grep -q "sm-a›api-2" <<< "$hier_pipe" || { echo "FAIL: pipeline missing 'sm-a›api-2'" >&2; exit 1; }
grep -q "china-…/dev-12" <<< "$hier_pipe" || { echo "FAIL: pipeline did not preserve worker id 'dev-12' when truncating plan 'china-campaign'" >&2; exit 1; }

# Verify pipeline DONE column orders newest finished first:
# dev-12 (finished now-20) must appear before dev-11 (finished now-50, even though started later) and api-1 (finished now-60)
done_line_dev12="$(grep -n "dev-12" <<< "$hier_pipe" | head -n 1 | cut -d: -f1)"
done_line_dev11="$(grep -n "dev-11" <<< "$hier_pipe" | head -n 1 | cut -d: -f1)"
done_line_api1="$(grep -n "sm-a›api-1" <<< "$hier_pipe" | head -n 1 | cut -d: -f1)"
if [[ -z "$done_line_dev12" || -z "$done_line_dev11" || -z "$done_line_api1" ]] || \
   ! (( done_line_dev12 < done_line_dev11 && done_line_dev11 < done_line_api1 )); then
  echo "FAIL: pipeline DONE column not ordered newest-finished first (lines: dev-12=$done_line_dev12, dev-11=$done_line_dev11, api-1=$done_line_api1)" >&2
  exit 1
fi

# ==============================================================================
# L. Layout switch in one process (graph -> tree), tree last-child branch, and
#    consistent completed colour on truncated rows
# ==============================================================================
switch_tree="$(
  SQUAD_ORCHESTRATION_NOW="$now" \
  SQUAD_ORCHESTRATION_HISTORY_CMD="$hier_hist" \
  SQUAD_ORCHESTRATION_FORCE_COLOR=1 \
  SQUAD_ORCHESTRATION_FRAME=1 \
  SQUAD_ORCHESTRATION_SWITCH_LAYOUT=tree \
  COLUMNS=80 \
    "$root/scripts/squad-orchestration.sh" --layout graph --once --since "$since" "$hier_dir"
)"
direct_tree="$(
  SQUAD_ORCHESTRATION_NOW="$now" \
  SQUAD_ORCHESTRATION_HISTORY_CMD="$hier_hist" \
  SQUAD_ORCHESTRATION_FORCE_COLOR=1 \
  SQUAD_ORCHESTRATION_FRAME=1 \
  COLUMNS=80 \
    "$root/scripts/squad-orchestration.sh" --layout tree --once --since "$since" "$hier_dir"
)"
if [[ "$switch_tree" != "$direct_tree" ]]; then
  echo "FAIL: graph->tree switch in one process differed from direct tree render" >&2
  exit 1
fi
if grep -q "─▶.*────" <<< "$switch_tree"; then
  echo "FAIL: tree row after layout switch was corrupted by horizontal rule" >&2
  exit 1
fi
# In second-plan, dev-11 is the only child under manager -> must use └─▶
grep -E "^   └─▶ dev-11 " <<< "$hier_tree" >/dev/null || {
  echo "FAIL: single child dev-11 under manager did not use └─▶" >&2
  exit 1
}
# When height budget hides trailing workers (+1 earlier), last visible child under manager still uses └─▶
compact_hier_tree="$(
  SQUAD_ORCHESTRATION_HISTORY_CMD="$hier_hist" \
  LINES=16 COLUMNS=80 \
    "$root/scripts/squad-orchestration.sh" --layout tree --once --since "$since" "$hier_dir"
)"
grep -E "^   └─▶ sm-a " <<< "$compact_hier_tree" >/dev/null || {
  echo "FAIL: sm-a as only visible depth-1 child under manager did not use └─▶:" >&2
  echo "$compact_hier_tree" >&2
  exit 1
}

# Long completed row with round 2 at COLUMNS=80 must still colour '✓ completed'
cat > "$hier_dir/dev-12-2.status" <<EOF
worker=dev-12
engine=opencode
model=deepseek-v4-pro
role=dev
state=completed
pid=$$
started=$(( now - 40 ))
finished=$(( now - 15 ))
tokens_in=20000
tokens_out=15000
parent=
depth=1
plan=/path/to/china-campaign.md
EOF
color_tree_80="$(
  SQUAD_ORCHESTRATION_HISTORY_CMD="$hier_hist" \
  SQUAD_ORCHESTRATION_FORCE_COLOR=1 \
  SQUAD_ORCHESTRATION_FRAME=1 \
  COLUMNS=80 \
    "$root/scripts/squad-orchestration.sh" --layout tree --once --since "$since" "$hier_dir"
)"
dev12_line="$(grep "dev-12" <<< "$color_tree_80" | head -n 1)"
api1_line="$(grep "api-1" <<< "$color_tree_80" | head -n 1)"
grep -q $'\033\[.*✓ completed' <<< "$dev12_line" || {
  echo "FAIL: dev-12 (round 2, truncated at COLUMNS=80) missing completed colour: $dev12_line" >&2
  exit 1
}
grep -q $'\033\[.*✓ completed' <<< "$api1_line" || {
  echo "FAIL: api-1 missing completed colour: $api1_line" >&2
  exit 1
}

# Verify terminal_columns / terminal_lines read real PTY size (120x34) when COLUMNS/LINES are unset
if command -v python3 >/dev/null 2>&1; then
  pty_tree_120="$(
    python3 - "$root/scripts/squad-orchestration.sh" "$since" "$hier_dir" "$hier_hist" <<'PYEOF'
import pty, os, fcntl, termios, struct, subprocess, sys
script, since, hier_dir, hier_hist = sys.argv[1:5]
master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 34, 120, 1100, 650))
env = os.environ.copy()
env.pop("COLUMNS", None)
env.pop("LINES", None)
env["SQUAD_ORCHESTRATION_HISTORY_CMD"] = hier_hist
p = subprocess.Popen(
    ["bash", script, "--layout", "tree", "--once", "--since", since, hier_dir],
    stdin=slave, stdout=slave, stderr=slave, close_fds=True, env=env
)
os.close(slave)
out = b""
while True:
    try:
        d = os.read(master, 65536)
        if not d:
            break
        out += d
    except OSError:
        break
p.wait()
os.close(master)
sys.stdout.write(out.decode("utf-8", errors="replace").replace("\r\n", "\n"))
PYEOF
  )" || pty_tree_120="SKIP"
  if [[ "$pty_tree_120" == "SKIP" ]]; then
    echo "SKIP: no PTY available (sandboxed run); skipping real-terminal-size check" >&2
  else
    grep -q "round 2" <<< "$pty_tree_120" || {
      echo "FAIL: PTY 120x34 with unset COLUMNS cut 'round 2':" >&2
      echo "$pty_tree_120" >&2
      exit 1
    }
  fi
fi

# Verify non-TTY output without SQUAD_ORCHESTRATION_LIVE exits by itself within 5 s (no --once)
non_tty_out="$tmp/non_tty_render.log"
(
  unset SQUAD_ORCHESTRATION_LIVE || true
  "$root/scripts/squad-orchestration.sh" "$workers_dir" >"$non_tty_out" 2>&1 &
  echo "$!" >"$tmp/non_tty.pid"
)
non_tty_pid="$(cat "$tmp/non_tty.pid")"

exited=0
deadline=$(( $(date +%s) + 5 ))
while (( $(date +%s) < deadline )); do
  if ! kill -0 "$non_tty_pid" 2>/dev/null; then
    exited=1
    break
  fi
  sleep 0.05
done

if (( exited == 0 )); then
  echo "FAIL: non-TTY orchestration view without SQUAD_ORCHESTRATION_LIVE did not exit within 5 s" >&2
  kill -9 "$non_tty_pid" 2>/dev/null || true
  exit 1
fi
wait "$non_tty_pid" 2>/dev/null || true
non_tty_pid=""

grep -q "● manager-4" "$non_tty_out" || {
  echo "FAIL: non-TTY one-shot output missing header" >&2
  exit 1
}

# Verify live renderer SIGHUP in-place reload:
# Start renderer live in background on fixture, verify output, send SIGHUP,
# verify same PID is alive and output shows reload / second header, then kill.
live_out="$tmp/live_renderer_hup.log"
(
  set -m
  SQUAD_ORCHESTRATION_LIVE=1 \
  SQUAD_ORCHESTRATION_ANIMATE=0 \
  SQUAD_ORCHESTRATION_INTERVAL=1 \
  SQUAD_ORCHESTRATION_FPS=10 \
  SQUAD_DEVKIT_MANAGER_WRAPPER_PID="$$" \
  "$root/scripts/squad-orchestration.sh" "$workers_dir" >"$live_out" 2>&1 &
  echo "$!" >"$tmp/live_renderer.pid"
)
live_pid="$(cat "$tmp/live_renderer.pid")"

# Wait until output appears
deadline=$(( $(date +%s) + 4 ))
while (( $(date +%s) < deadline )); do
  if [[ -s "$live_out" ]] && grep -q "● manager-4" "$live_out"; then
    break
  fi
  sleep 0.05
done

grep -q "● manager-4" "$live_out" || {
  echo "FAIL: live renderer did not produce header within timeout" >&2
  kill -9 "$live_pid" 2>/dev/null || true
  exit 1
}

initial_headers="$(grep -c "● manager-4" "$live_out" || true)"
initial_size="$(wc -c <"$live_out" | tr -d " ")"

kill -HUP "$live_pid"

reloaded=0
hup_deadline=$(( $(date +%s) + 4 ))
while (( $(date +%s) < hup_deadline )); do
  if ! kill -0 "$live_pid" 2>/dev/null; then
    echo "FAIL: live renderer PID $live_pid died after SIGHUP" >&2
    exit 1
  fi
  headers_now="$(grep -c "● manager-4" "$live_out" || true)"
  size_now="$(wc -c <"$live_out" | tr -d " ")"
  if (( headers_now > initial_headers || size_now > initial_size )); then
    reloaded=1
    break
  fi
  sleep 0.05
done

(( reloaded == 1 )) || {
  echo "FAIL: live renderer output did not grow / show second header after SIGHUP" >&2
  kill -9 "$live_pid" 2>/dev/null || true
  exit 1
}

# Verify process is still alive under the exact same PID
kill -0 "$live_pid" 2>/dev/null || {
  echo "FAIL: live renderer PID $live_pid exited unexpectedly" >&2
  exit 1
}

kill "$live_pid" 2>/dev/null || true
wait "$live_pid" 2>/dev/null || true
live_pid=""

# ==============================================================================
# M. Richer worker cards: activity, stale, waiting+age, live tokens, verify FAIL,
#    merged/unmerged/discarded, scope!, model_tier, round reason, wide cards,
#    and old-format status file compatibility
# ==============================================================================
cards_dir="$tmp/cards/.squad/workers"
mkdir -p "$cards_dir"
cards_now=1763200000
cards_since=$(( cards_now - 3600 ))

# Helper to set deterministic file mtime via python3 or touch -t
set_mtime() {
  local path="$1" epoch="$2"
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "import os; os.utime('$path', ($epoch, $epoch))"
  else
    local stamp
    stamp="$(date -r "$epoch" '+%Y%m%d%H%M.%S' 2>/dev/null || date -d "@$epoch" '+%Y%m%d%H%M.%S')"
    touch -t "$stamp" "$path"
  fi
}

# Logs for running workers
log_act="$tmp/cards/act.log"
log_stale="$tmp/cards/stale.log"
: > "$log_act"
: > "$log_stale"
set_mtime "$log_act" $(( cards_now - 18 ))
set_mtime "$log_stale" $(( cards_now - 185 ))

# Worktrees for completed workers
wt_unmerged="$tmp/cards/wt-unmerged"
wt_merged="$tmp/cards/wt-merged"
mkdir -p "$wt_unmerged" "$wt_merged"

# Worker 1: running, .live sidecar with live tokens + activity, fresh log, round 2 (prev verify=fail)
cat > "$cards_dir/c-act-1.status" <<EOF
worker=c-act
engine=agy
model=google/gemini-3.8-flash
model_tier=fast
role=dev
state=completed
verify=fail
pid=$$
started=$(( cards_now - 400 ))
finished=$(( cards_now - 300 ))
tokens_in=1000
tokens_out=500
plan=/path/to/cards-plan.md
EOF
cat > "$cards_dir/c-act-2.status" <<EOF
worker=c-act
engine=agy
model=google/gemini-3.8-flash
model_tier=fast
role=dev
state=running
pid=$$
started=$(( cards_now - 100 ))
log=$log_act
plan=/path/to/cards-plan.md
EOF
cat > "$cards_dir/c-act-2.live" <<EOF
tokens_in=32000
tokens_cached=5000
tokens_out=11000
activity=Edit src/auth.rs
updated=$(( cards_now - 18 ))
EOF

# Worker 2: running, stale log (> 120s), round 2 (prev scope_violation)
cat > "$cards_dir/c-stale-1.status" <<EOF
worker=c-stale
engine=codex
model=gpt-5
model_tier=balanced
role=dev
state=completed
scope_violation=README.md
pid=$$
started=$(( cards_now - 500 ))
finished=$(( cards_now - 420 ))
plan=/path/to/cards-plan.md
EOF
cat > "$cards_dir/c-stale-2.status" <<EOF
worker=c-stale
engine=codex
model=gpt-5
model_tier=balanced
role=dev
state=running
pid=$$
started=$(( cards_now - 240 ))
log=$log_stale
plan=/path/to/cards-plan.md
EOF

# Worker 3: running, unanswered QUESTION -> waiting with age (195s = 3m15s)
cat > "$cards_dir/c-wait.status" <<EOF
worker=c-wait
engine=claude
model=claude-sonnet-5-5
model_tier=strong
role=dev
state=running
pid=$$
started=$(( cards_now - 250 ))
tokens_in=1000
tokens_out=1000
plan=/path/to/cards-plan.md
EOF

# Worker 4: completed with verify=fail, scope_violation, unmerged worktree
cat > "$cards_dir/c-vfail.status" <<EOF
worker=c-vfail
engine=opencode
model=deepseek/deepseek-v4
model_tier=balanced
role=dev
state=completed
verify=fail
scope_violation=src/extra.rs
worktree=$wt_unmerged
pid=$$
started=$(( cards_now - 180 ))
finished=$(( cards_now - 60 ))
tokens_in=8000
tokens_out=4000
plan=/path/to/cards-plan.md
EOF

# Plan 2 workers: merged, discarded, old-format, plus round reasons failed/stopped
cat > "$cards_dir/c-merged-1.status" <<EOF
worker=c-merged
engine=agy
model=gemini-4-argon-high
model_tier=strong
role=dev
state=failed
pid=$$
started=$(( cards_now - 600 ))
finished=$(( cards_now - 550 ))
plan=/path/to/cards-two.md
EOF
cat > "$cards_dir/c-merged-2.status" <<EOF
worker=c-merged
engine=agy
model=gemini-4-argon-high
model_tier=strong
role=dev
state=completed
verify=pass
merged=$(( cards_now - 50 ))
worktree=$wt_merged
pid=$$
started=$(( cards_now - 500 ))
finished=$(( cards_now - 400 ))
tokens_in=15000
tokens_out=5000
plan=/path/to/cards-two.md
EOF

cat > "$cards_dir/c-disc-1.status" <<EOF
worker=c-disc
engine=codex
model=gpt-5
model_tier=fast
role=dev
state=stopped
pid=$$
started=$(( cards_now - 480 ))
finished=$(( cards_now - 460 ))
plan=/path/to/cards-two.md
EOF
cat > "$cards_dir/c-disc-2.status" <<EOF
worker=c-disc
engine=codex
model=gpt-5
model_tier=fast
role=dev
state=completed
verify=timeout
discarded=$(( cards_now - 30 ))
pid=$$
started=$(( cards_now - 450 ))
finished=$(( cards_now - 380 ))
tokens_in=4000
tokens_out=2000
plan=/path/to/cards-two.md
EOF

# Old-format status file with NONE of the new keys
cat > "$cards_dir/c-legacy.status" <<EOF
worker=c-legacy
engine=opencode
model=deepseek/deepseek-v4
role=dev
state=completed
pid=$$
started=$(( cards_now - 350 ))
finished=$(( cards_now - 310 ))
tokens_in=2000
tokens_out=1000
plan=/path/to/cards-two.md
EOF

# Question timestamp: cards_now - 195 = 1763199805 -> 2025-11-15T09:43:25Z
q_iso="$(date -r $(( cards_now - 195 )) -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -d "@$(( cards_now - 195 ))" -u +%Y-%m-%dT%H:%M:%SZ)"
cards_hist="cat <<EOF
* [${q_iso}] c-wait -> manager-4: QUESTION from c-wait: Need approval
EOF"

# Wide graph output (COLUMNS=136 -> inner_w=28, content_w=26)
cards_wide="$(
  SQUAD_ORCHESTRATION_NOW="$cards_now" \
  SQUAD_ORCHESTRATION_STALE_SECS=120 \
  SQUAD_ORCHESTRATION_HISTORY_CMD="$cards_hist" \
  COLUMNS=136 LINES=50 \
    "$root/scripts/squad-orchestration.sh" --layout cards --once --since "$cards_since" "$cards_dir"
)"
echo "=== Richer cards graph (COLUMNS=136) ==="
printf '%s\n' "$cards_wide"
echo "========================================"

if grep -q $'\033' <<< "$cards_wide"; then
  echo "FAIL: ESC sequence found in cards_wide --once output" >&2
  exit 1
fi
assert_max_width "$cards_wide" 136 "richer cards graph COLUMNS=136"

# Verify wide card grew up to inner_w=28 (box border = 28 dashes)
grep -q "┌────────────────────────────┐" <<< "$cards_wide" || {
  echo "FAIL: wide graph at COLUMNS=136 did not grow card inner width to 28" >&2
  exit 1
}

# Verify all 5 items in wide graph output
grep -q "⚠ 2 verify" <<< "$(head -n 1 <<< "$cards_wide")" || { echo "FAIL: header missing '⚠ 2 verify'" >&2; exit 1; }
grep -q "Edit src/auth.rs" <<< "$cards_wide" || { echo "FAIL: missing live activity 'Edit src/auth.rs'" >&2; exit 1; }
grep -q "18s · Edit src/auth.rs" <<< "$cards_wide" || { echo "FAIL: missing output age + activity '18s · Edit src/auth.rs'" >&2; exit 1; }
grep -q "43k" <<< "$cards_wide" || { echo "FAIL: missing live token total '43k' for c-act" >&2; exit 1; }
grep -q "r2 verify fail" <<< "$cards_wide" || { echo "FAIL: missing round reason 'r2 verify fail'" >&2; exit 1; }
grep -q "stale 3m05s" <<< "$cards_wide" || { echo "FAIL: missing 'stale 3m05s' for c-stale" >&2; exit 1; }
grep -q "r2 scope" <<< "$cards_wide" || { echo "FAIL: missing round reason 'r2 scope'" >&2; exit 1; }
grep -q "? waiting 3m15s" <<< "$cards_wide" || { echo "FAIL: missing '? waiting 3m15s' for c-wait" >&2; exit 1; }
grep -q "✗ verify FAIL" <<< "$cards_wide" || { echo "FAIL: missing '✗ verify FAIL' for c-vfail/c-disc" >&2; exit 1; }
grep -q "scope! · unmerged" <<< "$cards_wide" || { echo "FAIL: missing 'scope! · unmerged' for c-vfail" >&2; exit 1; }
grep -q "merged" <<< "$cards_wide" || { echo "FAIL: missing 'merged' for c-merged" >&2; exit 1; }
grep -q "r2 failed" <<< "$cards_wide" || { echo "FAIL: missing round reason 'r2 failed'" >&2; exit 1; }
grep -q "discarded" <<< "$cards_wide" || { echo "FAIL: missing 'discarded' for c-disc" >&2; exit 1; }
grep -q "r2 stopped" <<< "$cards_wide" || { echo "FAIL: missing round reason 'r2 stopped'" >&2; exit 1; }
grep -q "gemini-3.8-flash · fast" <<< "$cards_wide" || { echo "FAIL: missing tier 'fast' on c-act" >&2; exit 1; }
grep -q "gpt-5 · balanced" <<< "$cards_wide" || { echo "FAIL: missing tier 'balanced' on c-stale" >&2; exit 1; }
grep -q "sonnet-5-5 · strong" <<< "$cards_wide" || { echo "FAIL: missing tier 'strong' on c-wait" >&2; exit 1; }
grep -q "c-legacy" <<< "$cards_wide" || { echo "FAIL: missing old-format c-legacy card" >&2; exit 1; }

# Verify header keeps '⚠ 2 verify' even when narrower (COLUMNS=80 drops optional parts before count segment)
cards_hdr80="$(
  SQUAD_ORCHESTRATION_NOW="$cards_now" \
  SQUAD_ORCHESTRATION_HISTORY_CMD="$cards_hist" \
  COLUMNS=80 LINES=50 \
    "$root/scripts/squad-orchestration.sh" --layout cards --once --since "$cards_since" "$cards_dir"
)"
assert_max_width "$cards_hdr80" 80 "richer cards graph COLUMNS=80"
grep -q "⚠ 2 verify" <<< "$(head -n 1 <<< "$cards_hdr80")" || {
  echo "FAIL: COLUMNS=80 header dropped '⚠ 2 verify': $(head -n 1 <<< "$cards_hdr80")" >&2
  exit 1
}

# Verify COLUMNS=60 and COLUMNS=18 width invariants with richer cards
for c_cols in 60 18; do
  c_narrow="$(
    SQUAD_ORCHESTRATION_NOW="$cards_now" \
    SQUAD_ORCHESTRATION_HISTORY_CMD="$cards_hist" \
    COLUMNS="$c_cols" LINES=50 \
      "$root/scripts/squad-orchestration.sh" --layout cards --once --since "$cards_since" "$cards_dir"
  )"
  assert_max_width "$c_narrow" "$c_cols" "richer cards graph COLUMNS=$c_cols"
done

# Verify colour output: stale uses warning colour (208/1;31), verify FAIL uses failed colour (not completed green)
cards_color="$(
  SQUAD_ORCHESTRATION_NOW="$cards_now" \
  SQUAD_ORCHESTRATION_FORCE_COLOR=1 \
  SQUAD_ORCHESTRATION_FRAME=1 \
  SQUAD_ORCHESTRATION_HISTORY_CMD="$cards_hist" \
  COLUMNS=136 LINES=50 \
    "$root/scripts/squad-orchestration.sh" --layout cards --once --since "$cards_since" "$cards_dir"
)"
if grep -qE $'\033\\[(38;5;78|32)m[^\033]*verify FAIL' <<< "$cards_color"; then
  echo "FAIL: verify FAIL rendered with completed green colour" >&2
  exit 1
fi
grep -E $'\033\\[(38;5;203|31)m[^\033]*verify FAIL' <<< "$cards_color" >/dev/null || {
  echo "FAIL: verify FAIL missing failed colour" >&2
  exit 1
}
grep -E $'\033\\[(38;5;208|1;31)m[^\033]*stale 3m05s' <<< "$cards_color" >/dev/null || {
  echo "FAIL: stale missing warning colour" >&2
  exit 1
}

# Verify tree and pipeline views show the new state words and facts
cards_tree="$(
  SQUAD_ORCHESTRATION_NOW="$cards_now" \
  SQUAD_ORCHESTRATION_HISTORY_CMD="$cards_hist" \
  COLUMNS=140 LINES=50 \
    "$root/scripts/squad-orchestration.sh" --layout tree --once --since "$cards_since" "$cards_dir"
)"
assert_max_width "$cards_tree" 140 "richer cards tree COLUMNS=140"
for word in "stale 3m05s" "waiting 3m15s" "verify FAIL" "merged" "discarded" "unmerged" "scope!" "Edit src/auth.rs" "43k tok" "round 2 (verify fail)" "fast" "balanced" "strong"; do
  grep -q "$word" <<< "$cards_tree" || {
    echo "FAIL: tree missing '$word'" >&2
    echo "$cards_tree" >&2
    exit 1
  }
done

cards_pipe="$(
  SQUAD_ORCHESTRATION_NOW="$cards_now" \
  SQUAD_ORCHESTRATION_HISTORY_CMD="$cards_hist" \
  COLUMNS=260 LINES=50 \
    "$root/scripts/squad-orchestration.sh" --layout pipeline --once --since "$cards_since" "$cards_dir"
)"
assert_max_width "$cards_pipe" 260 "richer cards pipeline COLUMNS=260"
for word in "stale 3m05s" "waiting 3m15s" "verify FAIL" "merged" "discarded" "unmerged" "scope!" "Edit src/auth.rs" "43k" "r2:verify fail" "fast" "balanced" "strong"; do
  grep -q "$word" <<< "$cards_pipe" || {
    echo "FAIL: pipeline missing '$word'" >&2
    echo "$cards_pipe" >&2
    exit 1
  }
done

# Flow filters, multiline boundaries, pins, plan progress and expansion.
flow_dir="$tmp/flow/.squad/workers"
mkdir -p "$flow_dir"
cat > "$tmp/flow/plan.md" <<'EOF'
## Tasks
### Wave 1
- prose is not a task
- flow-1 (codex, strong): First. Files: a. Depends on: none.
- flow-2 (codex, strong): Second. Files: b. Depends on: flow-1.
- pending-3 (agy, balanced): Third. Files: c. Depends on: flow-2.
## Acceptance
- unrelated (text): outside Tasks
EOF
for idx in 1 2; do
  cat > "$flow_dir/flow-$idx.status" <<EOF
worker=flow-$idx
engine=codex
model=gpt-5
state=running
pid=$$
started=$(( now - 30 + idx ))
plan=plan.md
tokens=$(( idx * 1000 ))
EOF
done
cat > "$tmp/flow/history" <<'EOF'
[2026-11-14T07:00:00Z] flow-1 -> manager-4: QUESTION: PINNED choose a layout with enough room to show this complete long question
  continuation-tail
[2026-11-14T07:01:00Z] flow-2 -> manager-4: QUESTION: CLEARED old question
[2026-11-14T07:02:00Z] manager-4 -> flow-2: ANSWER: accepted
[2026-11-14T07:03:00Z] flow-2 -> manager-4: completed task recent-one
[2026-11-14T07:04:00Z] flow-2 -> manager-4: worker failed FAILURE-marker
[2026-11-14T07:05:00Z] flow-2 -> manager-4: completed task recent-two
[2026-11-14T07:06:00Z] flow-2 -> manager-4: completed task recent-three
EOF
flow_render() {
  SQUAD_ORCHESTRATION_HISTORY_CMD='cat history' COLUMNS="${flow_cols:-80}" LINES=60 \
    "$root/scripts/squad-orchestration.sh" --layout cards --once --since "$since" "$@" "$flow_dir"
}
if flow_render --flow-filter invalid >/dev/null 2>&1; then
  echo "FAIL: invalid Flow filter accepted" >&2
  exit 1
else
  [[ "$?" == 2 ]]
fi
flow_all="$(flow_render)"
flow_only="$(flow_render --flow-filter questions)"
flow_fail="$(flow_render --flow-filter failures)"
grep -q 'PINNED' <<< "$flow_all"
grep -q 'continuation-tail' <<< "$flow_only"
grep -q 'ANSWER' <<< "$flow_only"
! grep -q 'FAILURE-marker' <<< "$flow_only"
grep -q 'FAILURE-marker' <<< "$flow_fail"
! grep -q 'PINNED' <<< "$flow_fail"
! grep -q 'CLEARED' <<< "$flow_all"
grep -q '0/3 tasks · 3k tok' <<< "$flow_all"
grep -q 'pending-3 · pending · after flow-2' <<< "$flow_all"
grep -q 'flow-2 after flow-1' <<< "$flow_all"
! grep -q 'unrelated' <<< "$flow_all"
for flow_layout in tree pipeline; do
  flow_other="$(flow_render --layout "$flow_layout")"
  grep -q '0/3 tasks · 3k tok' <<< "$flow_other"
  grep -q 'pending-3' <<< "$flow_other"
  grep -q 'after flow-' <<< "$flow_other"
done
mv "$tmp/flow/plan.md" "$tmp/flow/saved-plan.md"
flow_missing="$(flow_render)"
grep -q 'Plan plan' <<< "$flow_missing"
! grep -q 'pending-3' <<< "$flow_missing"
printf '## Tasks\n- old prose without metadata\n' > "$tmp/flow/plan.md"
! grep -q '/1 tasks' <<< "$(flow_render)"
mv "$tmp/flow/saved-plan.md" "$tmp/flow/plan.md"
for flow_cols in 80 60 18; do
  flow_narrow="$(flow_render --flow-filter questions)"
  assert_max_width "$flow_narrow" "$flow_cols" "Flow wrapping COLUMNS=$flow_cols"
  [[ "$flow_narrow" != *$'\033'* ]]
done
flow_cols=80
printf 'state=completed\nfinished=%s\n' "$now" >> "$flow_dir/flow-2.status"
grep -q '1/3 tasks' <<< "$(flow_render)"
printf '[2026-11-14T07:07:00Z] manager-4 -> flow-1: ANSWER: resolved\n' >> "$tmp/flow/history"
! grep -q 'PINNED' <<< "$(flow_render)"
# Both controls use the existing once-mode key simulation.
flow_switched="$(SQUAD_ORCHESTRATION_SWITCH_LAYOUT=v,v flow_render)"
grep -q 'failures' <<< "$flow_switched"
six_expanded="$(SQUAD_ORCHESTRATION_SWITCH_LAYOUT=e COLUMNS=80 LINES=60 \
  "$root/scripts/squad-orchestration.sh" --layout cards --once --since "$since" "$six_dir")"
! grep -q '+2 earlier' <<< "$six_expanded"
for idx in 1 2 3 4 5 6; do grep -q "w-$idx" <<< "$six_expanded"; done
# ==============================================================================
# M. Manager scope (strict), --all-managers and the lifecycle flow chart
# ==============================================================================
scope_dir="$tmp/scope/.squad/workers"
mkdir -p "$scope_dir"

write_scope_worker() {
  # name role manager state started-offset finished-offset plan [parent]
  local name="$1" role="$2" mgr="$3" st="$4" s_off="$5" f_off="$6" plan="$7" parent="${8:-}"
  {
    echo "worker=$name"
    echo "engine=opencode"
    echo "model=opencode-go/deepseek-v4-pro"
    echo "role=$role"
    [[ -z "$mgr" ]] || echo "manager=$mgr"
    [[ -z "$parent" ]] || echo "parent=$parent"
    echo "state=$st"
    echo "pid=$$"
    echo "started=$(( now - s_off ))"
    [[ -z "$f_off" ]] || echo "finished=$(( now - f_off ))"
    echo "tokens_in=10000"
    echo "tokens_out=20000"
    echo "plan=$plan"
  } > "$scope_dir/$name.status"
}

# m-a: a-2 failed, a-3 done, sm (sub-manager with child), a-1 running and asking; older plan p0
write_scope_worker a-2 dev m-a failed 200 150 /path/to/p1.md
write_scope_worker a-3 dev m-a completed 120 80 /path/to/p1.md
write_scope_worker sm sub-manager m-a running 110 "" /path/to/p1.md
write_scope_worker a-1 dev m-a running 100 "" /path/to/p1.md
write_scope_worker sm-child dev sm completed 90 50 /path/to/p1.md sm
write_scope_worker a-old dev m-a completed 500 450 /path/to/p0.md
# m-b: another session sharing the directory
write_scope_worker b-1 dev m-b running 95 "" /path/to/p1.md
# legacy status file without a manager= key
write_scope_worker legacy-1 dev "" completed 70 30 /path/to/p1.md

scope_hist='cat <<HEOF
* [2026-11-14T07:01:00Z] m-a -> a-1: ## Goal
Add CSV export
Second line of the brief.
* [2026-11-14T07:02:00Z] m-a -> a-2: brief a-2
* [2026-11-14T07:03:00Z] m-a -> a-3: # Fix the importer 7c1f2f0e-5b6a-4d3c-9e8f-0a1b2c3d4e5f
* [2026-11-14T07:04:00Z] m-b -> b-1: ## Goal
B private brief
* [2026-11-14T07:05:00Z] m-a -> sm: brief sm
* [2026-11-14T07:06:00Z] sm -> sm-child: brief sm-child
* [2026-11-14T07:07:00Z] sm-child -> sm: sm-child done
* [2026-11-14T07:08:00Z] a-3 -> m-a: a-3 (opencode) completed task 7c1f2f0e-5b6a-4d3c-9e8f-0a1b2c3d4e5f
* [2026-11-14T07:09:00Z] a-2 -> m-a: a-2 (opencode) failed: lint
* [2026-11-14T07:10:00Z] a-1 -> m-a: QUESTION from a-1: which delimiter? Comma or tab
* [2026-11-14T07:11:00Z] m-x -> legacy-1: legacy secret brief
* [2026-11-14T07:12:00Z] b-1 -> m-b: QUESTION from b-1: other manager question
HEOF'

run_scope() {
  # cols [env VAR=val ...] -- args
  local cols="$1"
  shift
  SQUAD_ORCHESTRATION_HISTORY_CMD="$scope_hist" COLUMNS="$cols" \
    "$root/scripts/squad-orchestration.sh" "$@" --once --since "$since" "$scope_dir"
}

# 1. SQUAD_MANAGER_ID=m-a: strict scope
for cols in 80 120; do
  ma_out="$(SQUAD_MANAGER_ID=m-a run_scope "$cols")"
  echo "=== Scope m-a lifecycle (COLUMNS=$cols) ==="
  printf '%s\n' "$ma_out"
  echo "==========================================="

  assert_max_width "$ma_out" "$cols" "m-a COLUMNS=$cols"
  assert_utf8 "$ma_out" "m-a COLUMNS=$cols"
  if grep -q $'\033' <<< "$ma_out"; then
    echo "FAIL: escape codes in --once output (m-a COLUMNS=$cols)" >&2
    exit 1
  fi

  grep -q "^● m-a  ·  plan p1  ·  " <<< "$ma_out" || { echo "FAIL: m-a header missing manager/plan" >&2; exit 1; }
  n=0
  for wid in a-2 a-3 sm a-1; do
    n=$(( n + 1 ))
    grep -q "│ 0${n} ${wid} " <<< "$ma_out" || { echo "FAIL: m-a view missing node '0${n} ${wid}' (COLUMNS=$cols)" >&2; exit 1; }
  done
  [[ "$(grep -c '│ m-a ' <<< "$ma_out")" == 1 ]] || { echo "FAIL: expected exactly one m-a manager node" >&2; exit 1; }

  # m-b, legacy rows and their messages are excluded
  if grep -qE 'b-1|legacy|m-b|B private brief|other manager question|secret' <<< "$ma_out"; then
    echo "FAIL: m-a view leaked m-b / legacy rows or messages (COLUMNS=$cols)" >&2
    exit 1
  fi

  # Edge verbs, waiting group, sub-manager mini-row, outcomes
  grep -q "─failed─*▶" <<< "$ma_out" || { echo "FAIL: missing failed edge for a-2" >&2; exit 1; }
  grep -q "─done─*▶" <<< "$ma_out" || { echo "FAIL: missing done edge for a-3" >&2; exit 1; }
  grep -q "─ask─*▶" <<< "$ma_out" || { echo "FAIL: missing ask edge for a-1" >&2; exit 1; }
  grep -q "^Waiting on you (1)" <<< "$ma_out" || { echo "FAIL: missing 'Waiting on you' group" >&2; exit 1; }
  grep -qE "^\? a-1  which delimiter\? Comma or tab  · " <<< "$ma_out" || { echo "FAIL: waiting line missing a-1 question" >&2; exit 1; }
  grep -q "^[ │]*└ 01 sm-child · ✓" <<< "$ma_out" || { echo "FAIL: missing sub-manager child mini-row" >&2; exit 1; }
  grep -q "^Outcomes  ✓ a-3 sm-child   ✗ a-2" <<< "$ma_out" || { echo "FAIL: Outcomes line wrong" >&2; exit 1; }

  # Conversation: brief title not "## Goal", no UUID, no report text
  grep -q "^Conversation" <<< "$ma_out" || { echo "FAIL: missing Conversation panel" >&2; exit 1; }
  grep -q 'a-1  *brief "Add CSV export"' <<< "$ma_out" || { echo "FAIL: Conversation missing brief title 'Add CSV export'" >&2; exit 1; }
  if grep -qE '## Goal|7c1f2f0e|completed task' <<< "$ma_out"; then
    echo "FAIL: Conversation leaked '## Goal', a UUID or a report line" >&2
    exit 1
  fi
  grep -q 'sm-child  *brief ".*" · fix×1 · last fix ' <<< "$ma_out" || { echo "FAIL: Conversation missing 'fix×N' for a multi-round worker" >&2; exit 1; }
  grep -q 'a-3  *brief "Fix the importer" · last done ' <<< "$ma_out" || { echo "FAIL: Conversation a-3 line wrong" >&2; exit 1; }

  # Older plans collapse to exactly one line
  [[ "$(grep -c '^History  ' <<< "$ma_out")" == 1 ]] || { echo "FAIL: expected exactly one History line" >&2; exit 1; }
  grep -q "^History  1 earlier plan · ✓1 ✗0" <<< "$ma_out" || { echo "FAIL: History summary wrong" >&2; exit 1; }
done

# Sidecar metadata survives filtering raw workers down to a different manager.
printf 'model_tier=strong\n' >> "$scope_dir/b-1.status"
cat > "$scope_dir/b-1.live" <<'EOF'
tokens_in=40000
tokens_out=3000
activity=SCOPED-live-activity
EOF
scoped_live="$(SQUAD_MANAGER_ID=m-b run_scope 136 --layout cards)"
grep -q 'SCOPED-live-activity' <<< "$scoped_live"
grep -q '43k' <<< "$scoped_live"
grep -q 'strong' <<< "$scoped_live"

# Alternate layouts retain manager grouping and strict scope with richer fields.
for alt_layout in cards tree; do
  grouped="$(SQUAD_MANAGER_ID=m-a LINES=100 run_scope 120 --all-managers --layout "$alt_layout")"
  grep -q '^Manager m-a$' <<< "$grouped"
  grep -q '^Manager m-b$' <<< "$grouped"
  assert_max_width "$grouped" 120 "grouped $alt_layout"
  scoped="$(SQUAD_MANAGER_ID=m-a run_scope 120 --layout "$alt_layout")"
  if grep -qE 'b-1|legacy|m-b|B private brief|secret' <<< "$scoped"; then
    echo "FAIL: $alt_layout leaked another manager" >&2
    exit 1
  fi
done

# Focus (present) mode: diagram + waiting group only
focus_out="$(SQUAD_MANAGER_ID=m-a run_scope 120 --focus)"
echo "=== Focus (COLUMNS=120) ==="
printf '%s\n' "$focus_out"
echo "==========================="
assert_max_width "$focus_out" 120 "m-a focus COLUMNS=120"
grep -q "│ 01 a-2 " <<< "$focus_out" || { echo "FAIL: focus view missing main lane" >&2; exit 1; }
grep -q "^Waiting on you" <<< "$focus_out" || { echo "FAIL: focus view missing waiting group" >&2; exit 1; }
if grep -qE '^Conversation|^History|^Outcomes' <<< "$focus_out"; then
  echo "FAIL: focus view must hide Conversation, Outcomes and History" >&2
  exit 1
fi

# Colour mode keeps the exact visible layout and has valid UTF-8
color_out="$(SQUAD_ORCHESTRATION_FORCE_COLOR=1 SQUAD_MANAGER_ID=m-a run_scope 80)"
assert_utf8 "$color_out" "m-a colour"
if grep -q '@@' <<< "$color_out"; then
  echo "FAIL: unsubstituted animation placeholder in coloured output" >&2
  exit 1
fi

# 2. --all-managers shows everything grouped per manager (legacy under the inferred manager)
all_out="$(run_scope 120 --all-managers)"
echo "=== All-managers lifecycle (COLUMNS=120) ==="
printf '%s\n' "$all_out"
echo "============================================"
assert_max_width "$all_out" 120 "all-managers COLUMNS=120"
grep -q "all managers (2)" <<< "$all_out" || { echo "FAIL: header missing 'all managers (2)'" >&2; exit 1; }
grep -q "│ a-1 \|│ 04 a-1 " <<< "$all_out" || { echo "FAIL: all-managers missing a-1" >&2; exit 1; }
grep -q "│ 01 b-1 " <<< "$all_out" || { echo "FAIL: all-managers missing b-1" >&2; exit 1; }
grep -q "legacy-1" <<< "$all_out" || { echo "FAIL: all-managers should show legacy rows" >&2; exit 1; }
[[ "$(grep -cE '│ (m-a|m-b) ' <<< "$all_out")" == 2 ]] || { echo "FAIL: expected one manager node per manager" >&2; exit 1; }
grep -q "^▸ m-a · plan p1" <<< "$all_out" || { echo "FAIL: missing per-manager group label for m-a" >&2; exit 1; }
grep -q "^▸ m-b · plan p1" <<< "$all_out" || { echo "FAIL: missing per-manager group label for m-b" >&2; exit 1; }

# 3. Tree and pipeline apply the same strict scope
for lay in tree pipeline; do
  lay_out="$(SQUAD_MANAGER_ID=m-a run_scope 100 --layout "$lay")"
  if grep -qE "b-1|legacy-1" <<< "$lay_out"; then
    echo "FAIL: $lay layout for m-a leaked b-1 / legacy-1" >&2
    exit 1
  fi
  grep -q "a-1" <<< "$lay_out" || { echo "FAIL: $lay layout missing a-1" >&2; exit 1; }
done

# 4. Without a known manager id the legacy files stay visible (backward compatible)
legacy_out="$(run_scope 120 --layout tree)"
grep -q "legacy-1" <<< "$legacy_out" || { echo "FAIL: legacy rows should show when no manager id is known" >&2; exit 1; }

# ==============================================================================
# S. Auto-close when squad is idle
# ==============================================================================
autoclose_dir="$tmp/autoclose_workers"
mkdir -p "$autoclose_dir"
ac_now="$(date +%s)"
cat > "$autoclose_dir/w-1.status" <<EOF
worker=w-1
manager=m-auto
engine=opencode
model=deepseek-v4-pro
role=dev
state=completed
started=$(( ac_now - 60 ))
finished=$(( ac_now - 20 ))
plan=/path/to/plan-auto.md
EOF

# 1. --once output unchanged (no countdown text)
once_out="$(SQUAD_MANAGER_ID=m-auto "$root/scripts/squad-orchestration.sh" --once "$autoclose_dir")"
if grep -qE "closing in|All done · closing" <<< "$once_out"; then
  echo "FAIL: --once output contained countdown text" >&2
  exit 1
fi

# 2. Fixture where all workers are completed, SQUAD_ORCHESTRATION_HOLD=1:
#    live process exits within ~4 s with status 0, and a marker file containing its pid is removed.
ac_out_1="$tmp/autoclose_1.log"
SQUAD_ORCHESTRATION_LIVE=1 \
SQUAD_ORCHESTRATION_HOLD=1 \
SQUAD_ORCHESTRATION_INTERVAL=1 \
SQUAD_ORCHESTRATION_FPS=10 \
SQUAD_MANAGER_ID=m-auto \
SQUAD_DEVKIT_MANAGER_WRAPPER_PID="$$" \
  "$root/scripts/squad-orchestration.sh" "$autoclose_dir" >"$ac_out_1" 2>&1 &
ac_pid_1="$!"
echo "$ac_pid_1" > "$autoclose_dir/.orchestration-m-m_auto.pid"

ac_exited_1=0
ac_deadline_1=$(( $(date +%s) + 5 ))
while (( $(date +%s) < ac_deadline_1 )); do
  if ! kill -0 "$ac_pid_1" 2>/dev/null; then
    ac_exited_1=1
    break
  fi
  sleep 0.1
done

if (( ac_exited_1 == 0 )); then
  echo "FAIL: live process with SQUAD_ORCHESTRATION_HOLD=1 did not exit within ~4 s" >&2
  kill -9 "$ac_pid_1" 2>/dev/null || true
  exit 1
fi

ac_status_1=0
wait "$ac_pid_1" || ac_status_1=$?
if (( ac_status_1 != 0 )); then
  echo "FAIL: live process auto-close exited with status $ac_status_1, expected 0" >&2
  cat "$ac_out_1" >&2
  exit 1
fi

if [[ -f "$autoclose_dir/.orchestration-m-m_auto.pid" ]]; then
  echo "FAIL: marker file was not removed on auto-close" >&2
  exit 1
fi

# 3. Same with one worker state=running (pid = a live pid such as test's $$):
#    still alive after 3 s; then kill it.
cat > "$autoclose_dir/w-running.status" <<EOF
worker=w-running
manager=m-auto
engine=opencode
model=deepseek-v4-pro
role=dev
state=running
pid=$$
started=$(( ac_now - 30 ))
plan=/path/to/plan-auto.md
EOF

ac_out_run="$tmp/autoclose_run.log"
SQUAD_ORCHESTRATION_LIVE=1 \
SQUAD_ORCHESTRATION_HOLD=1 \
SQUAD_ORCHESTRATION_INTERVAL=1 \
SQUAD_ORCHESTRATION_FPS=10 \
SQUAD_MANAGER_ID=m-auto \
SQUAD_DEVKIT_MANAGER_WRAPPER_PID="$$" \
  "$root/scripts/squad-orchestration.sh" "$autoclose_dir" >"$ac_out_run" 2>&1 &
ac_pid_run="$!"

sleep 3
if ! kill -0 "$ac_pid_run" 2>/dev/null; then
  echo "FAIL: live process with running worker unexpectedly exited" >&2
  exit 1
fi
kill "$ac_pid_run" 2>/dev/null || true
wait "$ac_pid_run" 2>/dev/null || true
rm -f "$autoclose_dir/w-running.status"

# 4. SQUAD_ORCHESTRATION_HOLD=0 → still alive after 3 s.
ac_out_zero="$tmp/autoclose_zero.log"
SQUAD_ORCHESTRATION_LIVE=1 \
SQUAD_ORCHESTRATION_HOLD=0 \
SQUAD_ORCHESTRATION_INTERVAL=1 \
SQUAD_ORCHESTRATION_FPS=10 \
SQUAD_MANAGER_ID=m-auto \
SQUAD_DEVKIT_MANAGER_WRAPPER_PID="$$" \
  "$root/scripts/squad-orchestration.sh" "$autoclose_dir" >"$ac_out_zero" 2>&1 &
ac_pid_zero="$!"

sleep 3
if ! kill -0 "$ac_pid_zero" 2>/dev/null; then
  echo "FAIL: live process with SQUAD_ORCHESTRATION_HOLD=0 unexpectedly exited" >&2
  exit 1
fi
kill "$ac_pid_zero" 2>/dev/null || true
wait "$ac_pid_zero" 2>/dev/null || true

# 5. During countdown, write a new status with state=running → no exit.
ac_out_dyn="$tmp/autoclose_dyn.log"
SQUAD_ORCHESTRATION_LIVE=1 \
SQUAD_ORCHESTRATION_HOLD=3 \
SQUAD_ORCHESTRATION_INTERVAL=1 \
SQUAD_ORCHESTRATION_FPS=10 \
SQUAD_MANAGER_ID=m-auto \
SQUAD_DEVKIT_MANAGER_WRAPPER_PID="$$" \
  "$root/scripts/squad-orchestration.sh" "$autoclose_dir" >"$ac_out_dyn" 2>&1 &
ac_pid_dyn="$!"

sleep 1
cat > "$autoclose_dir/w-new.status" <<EOF
worker=w-new
manager=m-auto
engine=opencode
model=deepseek-v4-pro
role=dev
state=running
pid=$$
started=$(date +%s)
plan=/path/to/plan-auto.md
EOF

sleep 3
if ! kill -0 "$ac_pid_dyn" 2>/dev/null; then
  echo "FAIL: live process exited despite worker becoming running during countdown" >&2
  exit 1
fi
kill "$ac_pid_dyn" 2>/dev/null || true
wait "$ac_pid_dyn" 2>/dev/null || true
rm -f "$autoclose_dir/w-new.status"

# 6. Fixture dir with only another manager's status files (manager=m-other, completed),
#    SQUAD_MANAGER_ID=m-x, SQUAD_ORCHESTRATION_HOLD=1, live mode → process exits 0 within ~4 s.
ac_empty_dir="$tmp/autoclose_empty"
mkdir -p "$ac_empty_dir"
cat > "$ac_empty_dir/w-other.status" <<EOF
worker=w-other
manager=m-other
engine=opencode
model=deepseek-v4-pro
role=dev
state=completed
started=$(( $(date +%s) - 60 ))
finished=$(( $(date +%s) - 20 ))
plan=/path/to/plan-other.md
EOF

ac_out_empty="$tmp/autoclose_empty.log"
COLUMNS=100 \
SQUAD_ORCHESTRATION_LIVE=1 \
SQUAD_ORCHESTRATION_HOLD=1 \
SQUAD_ORCHESTRATION_INTERVAL=1 \
SQUAD_ORCHESTRATION_FPS=10 \
SQUAD_MANAGER_ID=m-x \
SQUAD_DEVKIT_MANAGER_WRAPPER_PID="$$" \
  "$root/scripts/squad-orchestration.sh" "$ac_empty_dir" >"$ac_out_empty" 2>&1 &
ac_pid_empty="$!"
echo "$ac_pid_empty" > "$ac_empty_dir/.orchestration-m-m_x.pid"

ac_exited_empty=0
ac_deadline_empty=$(( $(date +%s) + 5 ))
while (( $(date +%s) < ac_deadline_empty )); do
  if ! kill -0 "$ac_pid_empty" 2>/dev/null; then
    ac_exited_empty=1
    break
  fi
  sleep 0.1
done

if (( ac_exited_empty == 0 )); then
  echo "FAIL: empty-scope live process with SQUAD_ORCHESTRATION_HOLD=1 did not exit within ~4 s" >&2
  kill -9 "$ac_pid_empty" 2>/dev/null || true
  exit 1
fi

ac_status_empty=0
wait "$ac_pid_empty" || ac_status_empty=$?
if (( ac_status_empty != 0 )); then
  echo "FAIL: empty-scope live process auto-close exited with status $ac_status_empty, expected 0" >&2
  cat "$ac_out_empty" >&2
  exit 1
fi

if [[ -f "$ac_empty_dir/.orchestration-m-m_x.pid" ]]; then
  echo "FAIL: marker file was not removed on empty-scope auto-close" >&2
  exit 1
fi

if ! grep -q "Nothing running · closing in" "$ac_out_empty"; then
  echo "FAIL: empty-scope footer text did not include 'Nothing running · closing in'" >&2
  cat "$ac_out_empty" >&2
  exit 1
fi

# Source the panel's definitions without entering either event loop.
panel_harness="$tmp/panel-harness.sh"
sed '/^# One-shot execution mode/,$d' "$root/scripts/squad-orchestration.sh" >"$panel_harness"
# Resolve libraries from the real script while keeping all test files temporary.
sed "s|^source_file=.*|source_file='$root/scripts/squad-orchestration.sh'|" "$panel_harness" >"$panel_harness.tmp"
mv "$panel_harness.tmp" "$panel_harness"
cat >>"$panel_harness" <<'PANEL_TEST'
load_data
selection_sync
first="$selected_id"
[[ -n "$first" ]]
panel_key k
[[ "$selected_id" == "$first" ]]
panel_key j
selection_sync
second="$selected_id"
[[ "$second" != "$first" ]]
load_data
selection_sync
[[ "$selected_id" == "$second" ]]
panel_key j
[[ "$selected_id" == "$second" ]]
cycle_flow_filter
selection_sync
[[ "$selected_id" == "$second" ]]
selected_id=removed
selection_sync
[[ "$selected_id" == "$first" ]]
zoom_target=missing
selection_sync
[[ -z "$selected_id" && "$selected_index" == -1 ]]
zoom_target=""
selection_sync
panel_key i
for width in 80 60 18; do
  COLUMNS="$width"
  build_frame_templates
  render_cached_frame 0
  [[ "$REPLY" != *$'\033'* ]]
  while IFS= read -r line; do (( ${#line} <= width )); done <<<"$REPLY"
done
zoom_target="$selected_id"
panel_key esc
[[ "$details_open" == 0 && -n "$zoom_target" ]]
panel_key esc
[[ -z "$zoom_target" ]]
panel_key d
[[ "$action_message" == 'Actions disabled in --once' ]]
# Stub only external effects; production dispatch still passes canonical argv.
once=0
script_dir="$TEST_ACTION_DIR"
export TEST_ACTION_LOG TEST_ACTION_DIR
panel_key s
panel_key n
[[ ! -e "$TEST_ACTION_LOG" ]]
panel_key s
panel_key y
[[ "$(cat "$TEST_ACTION_LOG")" == "--stop $selected_id" ]]
selected_id=all
stop_pending=all
panel_key y
[[ "$action_message" == 'Invalid worker ID' ]]
selection_sync
squad_open_monitor() {
  [[ "$6" == required && "$2" == "$selected_id monitor" ]]
  grep -F -- "${W_STATUS_FILE[$selected_index]}" "$1" >/dev/null
  return 1
}
panel_key m
[[ "$action_message" == 'Monitor split failed' ]]
panel_key r
[[ "$action_message" == 'Report unavailable' ]]
report_path="$TEST_ACTION_DIR/report with spaces"
printf 'hostile $(touch %s)\033[31m\n' "$TEST_ACTION_DIR/executed" >"$report_path"
printf '\nreport=%s\n' "$report_path" >>"${W_STATUS_FILE[$selected_index]}"
export TEST_PAGER_LOG="$TEST_ACTION_DIR/paged"
PAGER="$TEST_ACTION_DIR/pager with spaces"
cat >"$PAGER" <<'PAGER_STUB'
#!/bin/bash
cat >"$TEST_PAGER_LOG"
PAGER_STUB
chmod +x "$PAGER"
page_selected r
[[ -s "$TEST_PAGER_LOG" && ! -e "$TEST_ACTION_DIR/executed" ]]
[[ "$(cat "$TEST_PAGER_LOG")" != *$'\033'* ]]
mkdir -p "$TEST_ACTION_DIR/worktree with spaces"
W_WORKTREE[$selected_index]="$TEST_ACTION_DIR/worktree with spaces"
cat >"$TEST_ACTION_DIR/git" <<'GIT_STUB'
#!/bin/bash
printf '%s\n' "$@" >"$TEST_ACTION_DIR/git-args"
printf 'selected diff\n'
GIT_STUB
chmod +x "$TEST_ACTION_DIR/git"
PATH="$TEST_ACTION_DIR:$PATH" page_selected d
[[ "$(cat "$TEST_PAGER_LOG")" == 'selected diff' ]]
grep -Fx -- "$TEST_ACTION_DIR/worktree with spaces" "$TEST_ACTION_DIR/git-args" >/dev/null
# New questions notify once, initial history and subsequent replay do not.
question_seen=(); questions_initialized=0
H_TS=(old); H_FROM=(worker); H_TO=(manager); H_TYPE=(QUESTION); H_BODY=('QUESTION old')
notifications=0
squad_notify() { notifications=$(( notifications + 1 )); }
notify_questions
[[ "$notifications" == 0 ]]
H_TS[1]="$notification_start"; H_FROM[1]=worker; H_TO[1]=manager; H_TYPE[1]=QUESTION; H_BODY[1]='QUESTION new'
notify_questions
notify_questions
[[ "$notifications" == 1 ]]
PANEL_TEST
mkdir -p "$tmp/actions" "$tmp/interaction"
cat >"$tmp/actions/squad-worker.sh" <<'ACTION_STUB'
#!/bin/bash
printf '%s %s' "$1" "$2" >"$TEST_ACTION_LOG"
ACTION_STUB
chmod +x "$tmp/actions/squad-worker.sh"
for id in alpha beta; do
  cat >"$tmp/interaction/$id.status" <<EOF_STATUS
worker=$id
started=$now
state=completed
model=\$(touch $tmp/hostile)
report=$tmp/missing report
plan=$tmp/missing plan
EOF_STATUS
done
TEST_ACTION_DIR="$tmp/actions" TEST_ACTION_LOG="$tmp/action.log" \
  bash "$panel_harness" --once "$tmp/interaction"
[[ ! -e "$tmp/hostile" ]]
for width in 80 60 18; do
  detail_out="$(COLUMNS="$width" SQUAD_ORCHESTRATION_SWITCH_LAYOUT=j,i \
    "$root/scripts/squad-orchestration.sh" --once "$tmp/interaction")"
  assert_max_width "$detail_out" "$width" "details COLUMNS=$width"
  [[ "$detail_out" != *$'\033'* ]]
done

echo "PASS: squad_orchestration_smoke"
