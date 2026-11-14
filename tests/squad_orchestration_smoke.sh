#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${TEST_SIGHUP_RESET:-}" ]] && command -v perl >/dev/null 2>&1; then
  export TEST_SIGHUP_RESET=1
  exec perl -e '$SIG{HUP} = "DEFAULT"; exec @ARGV' -- "$0" "$@"
fi

export LC_ALL="${LC_ALL:-en_US.UTF-8}"

root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
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

# ==============================================================================
# A. Default layout (--once) is graph
# ==============================================================================
graph_output="$(COLUMNS=80 "$root/scripts/squad-orchestration.sh" --once --since "$since" "$workers_dir")"

echo "=== Default (graph) output under COLUMNS=80 ==="
printf '%s\n' "$graph_output"
echo "==============================================="

grep -q "Plan setup-wizard" <<< "$graph_output" || { echo "FAIL: graph missing 'Plan setup-wizard'" >&2; exit 1; }
grep -q "Plan (no plan)" <<< "$graph_output" || { echo "FAIL: graph missing 'Plan (no plan)'" >&2; exit 1; }
grep -q "│   manager-4    │" <<< "$graph_output" || { echo "FAIL: graph missing centred manager box '│   manager-4    │'" >&2; exit 1; }
grep -q "┌─" <<< "$graph_output" || { echo "FAIL: graph missing top box border '┌─'" >&2; exit 1; }
grep -q "└─" <<< "$graph_output" || { echo "FAIL: graph missing bottom box border '└─'" >&2; exit 1; }
for wid in dev-1 dev-2 test-1 done-1 r-1 lost-1; do
  grep -q "│ ${wid} " <<< "$graph_output" || { echo "FAIL: graph missing worker box for '$wid'" >&2; exit 1; }
done
grep -q "▲ QUESTION" <<< "$graph_output" || { echo "FAIL: graph missing edge label '▲ QUESTION'" >&2; exit 1; }
grep -q "│ ? asking" <<< "$graph_output" || { echo "FAIL: graph missing '? asking' in box" >&2; exit 1; }
grep -q "│ 4-argon-high   │" <<< "$graph_output" || { echo "FAIL: graph missing short_model '4-argon-high'" >&2; exit 1; }
grep -q "│ deepseek-v4-p… │" <<< "$graph_output" || { echo "FAIL: graph missing short_model 'deepseek-v4-p…'" >&2; exit 1; }
grep -q "│ sonnet-5-5     │" <<< "$graph_output" || { echo "FAIL: graph missing short_model 'sonnet-5-5'" >&2; exit 1; }
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
box_row_count="$(grep -c '^┌' <<< "$six_out" || true)"
if [[ "$box_row_count" -ne 1 ]]; then
  echo "FAIL: expected 6 workers in one plan at COLUMNS=80 to compact to 1 row of boxes, got $box_row_count rows:" >&2
  echo "$six_out" >&2
  exit 1
fi
for idx in 1 2 3 4; do
  grep -q "│ w-${idx} " <<< "$six_out" || { echo "FAIL: missing worker box w-${idx} in 6-worker graph" >&2; exit 1; }
done
grep -q "+2 earlier" <<< "$six_out" || { echo "FAIL: missing '+2 earlier' summary line in 6-worker graph" >&2; exit 1; }

# 10. Failing history command still renders
failing_out="$(SQUAD_ORCHESTRATION_HISTORY_CMD="exit 1" "$root/scripts/squad-orchestration.sh" --once --since "$since" "$workers_dir")"
grep -q "Plan setup-wizard" <<< "$failing_out" || { echo "FAIL: rendering failed with failing history command" >&2; exit 1; }

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
grep -q "squad orchestration · .squad-ws ·" <<< "$special_output" || {
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
# G. Exact Alignment (3 workers in graph --once)
# ==============================================================================
align_dir="$tmp/align/.squad/workers"
mkdir -p "$align_dir"
for idx in 1 2 3; do
  cat > "$align_dir/a-${idx}.status" <<EOF
worker=a-${idx}
engine=agy
model=google/gemini-3.8-flash
role=dev
state=$( (( idx == 1 )) && echo running || echo completed )
pid=$$
started=$(( now - 90 + idx ))
$( (( idx > 1 )) && echo "finished=$(( now - 10 + idx ))" || true )
plan=/path/to/align-plan.md
EOF
done

align_out="$(
  SQUAD_ORCHESTRATION_HISTORY_CMD="cat <<'HEOF'
* [2026-11-14T07:01:00Z] manager-4 -> a-1: brief msg
* [2026-11-14T07:02:00Z] a-2 -> manager-4: QUESTION from a-2: clarify
* [2026-11-14T07:03:00Z] a-3 -> manager-4: a-3 completed task 123
HEOF" \
  COLUMNS=80 "$root/scripts/squad-orchestration.sh" --layout graph --once --since "$since" "$align_dir"
)"

mgr_bot_line=""
bus_line=""
edge_line=""
box_top_line=""
prev_type=""
while IFS= read -r aline; do
  if [[ "$aline" =~ ^[[:space:]]*└.*┬.*┘$ ]]; then
    mgr_bot_line="$aline"
    prev_type="mgr_bot"
  elif [[ "$prev_type" == "mgr_bot" ]]; then
    bus_line="$aline"
    prev_type="bus"
  elif [[ "$prev_type" == "bus" ]]; then
    edge_line="$aline"
    prev_type="edge"
  elif [[ "$prev_type" == "edge" ]]; then
    box_top_line="$aline"
    break
  fi
done <<< "$align_out"

if [[ -z "$mgr_bot_line" || -z "$bus_line" || -z "$edge_line" || -z "$box_top_line" ]]; then
  echo "FAIL: could not extract alignment lines from 3-worker graph:" >&2
  echo "$align_out" >&2
  exit 1
fi

# Find manager stem column (0-based character index)
mgr_stem_col=-1
for (( ci = 0; ci < ${#mgr_bot_line}; ci++ )); do
  if [[ "${mgr_bot_line:$ci:1}" == "┬" ]]; then
    mgr_stem_col="$ci"
    break
  fi
done
if (( mgr_stem_col < 0 )); then
  echo "FAIL: manager stem '┬' not found on '$mgr_bot_line'" >&2
  exit 1
fi
bus_at_stem="${bus_line:$mgr_stem_col:1}"
if [[ "$bus_at_stem" != "┴" && "$bus_at_stem" != "┼" ]]; then
  echo "FAIL: bus char at manager stem col $mgr_stem_col is '$bus_at_stem' (expected '┴' or '┼')" >&2
  echo "mgr_bot: $mgr_bot_line" >&2
  echo "bus    : $bus_line" >&2
  exit 1
fi

# Find each worker box top '┴' column and verify bus junction and edge arrow match
worker_junctions=0
for (( ci = 0; ci < ${#box_top_line}; ci++ )); do
  if [[ "${box_top_line:$ci:1}" == "┴" ]]; then
    worker_junctions=$(( worker_junctions + 1 ))
    bus_ch="${bus_line:$ci:1}"
    edge_ch="${edge_line:$ci:1}"
    case "$bus_ch" in
      ┌|┬|┐|┼) ;;
      *)
        echo "FAIL: worker $worker_junctions at col $ci has bus char '$bus_ch' instead of junction (┌/┬/┐/┼)" >&2
        exit 1
        ;;
    esac
    case "$edge_ch" in
      ▲|▼) ;;
      *)
        echo "FAIL: worker $worker_junctions at col $ci has edge char '$edge_ch' instead of arrow (▲/▼)" >&2
        echo "bus    : $bus_line" >&2
        echo "edge   : $edge_line" >&2
        echo "box_top: $box_top_line" >&2
        exit 1
        ;;
    esac
  fi
done
if (( worker_junctions != 3 )); then
  echo "FAIL: expected 3 worker '┴' box top junctions, found $worker_junctions" >&2
  exit 1
fi

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
grep -q "● 1 running  ✓ 42 done  ✗ 11 failed" <<< "$hdr80_line" || {
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
grep -q "╔" <<< "$hier_graph" || { echo "FAIL: root graph missing double border '╔'" >&2; exit 1; }
grep -q "╚" <<< "$hier_graph" || { echo "FAIL: root graph missing double border '╚'" >&2; exit 1; }
grep -q "\\[1\\] sm-a" <<< "$hier_graph" || { echo "FAIL: root graph missing '[1] sm-a'" >&2; exit 1; }
grep -q "1/2 kids" <<< "$hier_graph" || { echo "FAIL: root graph missing '1/2 kids'" >&2; exit 1; }
grep -q "45k" <<< "$hier_graph" || { echo "FAIL: root graph missing branch token total '45k'" >&2; exit 1; }
grep -q "dev-12" <<< "$hier_graph" || { echo "FAIL: root graph missing plain worker 'dev-12'" >&2; exit 1; }
# Children must NOT appear in boxes at root level (exclude Flow section)
hier_graph_diag="$(awk '/^─/ && ++r == 2 { exit } r == 1 { print }' <<< "$hier_graph")"
if grep -qE "api-1|api-2" <<< "$hier_graph_diag"; then
  echo "FAIL: root graph diagram should not draw child ids api-1 or api-2:" >&2
  echo "$hier_graph_diag" >&2
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
  )"
  grep -q "round 2" <<< "$pty_tree_120" || {
    echo "FAIL: PTY 120x34 with unset COLUMNS cut 'round 2':" >&2
    echo "$pty_tree_120" >&2
    exit 1
  }
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

grep -q "squad orchestration" "$non_tty_out" || {
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
  if [[ -s "$live_out" ]] && grep -q "squad orchestration" "$live_out"; then
    break
  fi
  sleep 0.05
done

grep -q "squad orchestration" "$live_out" || {
  echo "FAIL: live renderer did not produce header within timeout" >&2
  kill -9 "$live_pid" 2>/dev/null || true
  exit 1
}

initial_headers="$(grep -c "squad orchestration" "$live_out" || true)"
initial_size="$(wc -c <"$live_out" | tr -d " ")"

kill -HUP "$live_pid"

reloaded=0
hup_deadline=$(( $(date +%s) + 4 ))
while (( $(date +%s) < hup_deadline )); do
  if ! kill -0 "$live_pid" 2>/dev/null; then
    echo "FAIL: live renderer PID $live_pid died after SIGHUP" >&2
    exit 1
  fi
  headers_now="$(grep -c "squad orchestration" "$live_out" || true)"
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

echo "PASS: squad_orchestration_smoke"
