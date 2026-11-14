#!/usr/bin/env bash
# Smoke tests for scripts/squad-submanager.sh (hierarchy mode sub-manager driver).
# Runs under macOS system Bash 3.2 with fake engine and fake worker scripts.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
driver="$root/scripts/squad-submanager.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "Assertion failed at line ${BASH_LINENO[0]}: ${*:-}" >&2; exit 1; }

[[ -x "$driver" ]] || fail "driver is not executable"
[[ -f "$root/templates/devkit/sub-manager.md" ]] || fail "missing templates/devkit/sub-manager.md"

mkdir -p "$tmp/bin" "$tmp/home"
export HOME="$tmp/home"
export GIT_CONFIG_NOSYSTEM=1
export PATH="$tmp/bin:$PATH"

# Fake agy CLI: reads prompt after -p, tracks plan/review call counts in $FAKE_STATE_DIR,
# and emits native AGY stream-json with usage tokens.
cat >"$tmp/bin/agy" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
prompt=""
while (( $# > 0 )); do
  case "$1" in
    -p) prompt="$2"; shift 2 ;;
    *) shift ;;
  esac
done

state_dir="${FAKE_STATE_DIR:?}"
in_tok="${FAKE_AGY_IN_TOKENS:-100}"
out_tok="${FAKE_AGY_OUT_TOKENS:-50}"

if [[ "$prompt" == *"## Phase: plan"* ]]; then
  n=0
  [[ -f "$state_dir/plan_calls" ]] && n="$(cat "$state_dir/plan_calls")"
  n=$(( n + 1 ))
  printf '%s' "$n" >"$state_dir/plan_calls"
  printf '%s\n' "$prompt" >"$state_dir/plan_prompt_$n.txt"
  if [[ "$n" == 1 && -n "${FAKE_PLAN_RESPONSE_1:-}" ]]; then
    resp="$FAKE_PLAN_RESPONSE_1"
  elif [[ -n "${FAKE_PLAN_RESPONSE_2:-}" ]]; then
    resp="$FAKE_PLAN_RESPONSE_2"
  else
    resp="${FAKE_PLAN_RESPONSE:-}"
  fi
elif [[ "$prompt" == *"## Phase: review"* ]]; then
  n=0
  [[ -f "$state_dir/review_calls" ]] && n="$(cat "$state_dir/review_calls")"
  n=$(( n + 1 ))
  printf '%s' "$n" >"$state_dir/review_calls"
  printf '%s\n' "$prompt" >"$state_dir/review_prompt_$n.txt"
  if [[ "$n" == 1 && -n "${FAKE_REVIEW_RESPONSE_1:-}" ]]; then
    resp="$FAKE_REVIEW_RESPONSE_1"
  elif [[ -n "${FAKE_REVIEW_RESPONSE_2:-}" ]]; then
    resp="$FAKE_REVIEW_RESPONSE_2"
  else
    resp="${FAKE_REVIEW_RESPONSE:-}"
  fi
else
  echo "Unexpected prompt without phase header" >&2
  exit 1
fi

jq -cn --arg resp "$resp" --argjson in_t "$in_tok" --argjson out_t "$out_tok" \
  '{event:"result",result:{status:"SUCCESS",response:$resp,usage:{input_tokens:$in_t,output_tokens:$out_t}}}'
EOF
chmod +x "$tmp/bin/agy"

# Fake squad-worker: records arguments, writes a child report and status file,
# optionally edits a file in the project directory, and exits with configured status.
fake_worker="$tmp/bin/fake-squad-worker"
cat >"$fake_worker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state_dir="${FAKE_STATE_DIR:?}"
workspace="${SQUAD_SM_WORKSPACE:?}"

cid="$1"
shift
printf '%s %s\n' "$cid" "$*" >>"$state_dir/worker_calls.log"

n=0
[[ -f "$state_dir/worker_count_$cid" ]] && n="$(cat "$state_dir/worker_count_$cid")"
n=$(( n + 1 ))
printf '%s' "$n" >"$state_dir/worker_count_$cid"

project_dir=""
brief_file=""
engine="agy"
while (( $# > 0 )); do
  case "$1" in
    --project) project_dir="$2"; shift 2 ;;
    --brief-file) brief_file="$2"; shift 2 ;;
    --engine) engine="$2"; shift 2 ;;
    *) shift ;;
  esac
done

if [[ -n "$brief_file" && -f "$brief_file" ]]; then
  cp "$brief_file" "$state_dir/brief_${cid}_${n}.md"
fi

if [[ -n "$project_dir" && -d "$project_dir" ]]; then
  printf 'updated by %s run %s\n' "$cid" "$n" >"$project_dir/tracked.txt"
fi

workers_dir="$workspace/.squad/workers"
mkdir -p "$workers_dir"
rep_file="$workers_dir/${cid}-20261114-00000${n}.md"
status_file="$workers_dir/${cid}-20261114-00000${n}.status"

printf 'Child %s completed run %s.\nVerification: passed.\n' "$cid" "$n" >"$rep_file"

in_tok="${FAKE_WORKER_IN_TOKENS:-200}"
out_tok="${FAKE_WORKER_OUT_TOKENS:-100}"
child_state="completed"
exit_code=0
if [[ "${FAKE_WORKER_FAIL_ID:-}" == "$cid" && "$n" == 1 ]]; then
  child_state="failed"
  exit_code=1
fi

cat >"$status_file" <<STATUS
worker=$cid
parent=${SQUAD_SM_ID:-}
engine=$engine
state=$child_state
tokens_in=$in_tok
tokens_out=$out_tok
report=$rep_file
STATUS

printf '[%s · %s · task t] report: %s\n' "$cid" "$engine" "$rep_file"
exit "$exit_code"
EOF
chmod +x "$fake_worker"

# Helper to set up a clean test case environment.
setup_case() {
  local name="$1"
  case_dir="$tmp/$name"
  mkdir -p "$case_dir/workspace/.squad/workers" "$case_dir/worktree" "$case_dir/state"
  git -C "$case_dir/worktree" init -q
  git -C "$case_dir/worktree" config user.email "test@example.com"
  git -C "$case_dir/worktree" config user.name "Test"
  printf 'initial\n' >"$case_dir/worktree/tracked.txt"
  git -C "$case_dir/worktree" add tracked.txt
  git -C "$case_dir/worktree" commit -q -m "initial"

  cat >"$case_dir/prompt.md" <<'PROMPT'
## Task t-1: Implement API and tests
Files you own (change nothing else): src/api, tests/api
Implement the endpoints and tests.
PROMPT

  export FAKE_STATE_DIR="$case_dir/state"
  export SQUAD_SM_ID="sm-api"
  export SQUAD_SM_TASK="t-1"
  export SQUAD_SM_MANAGER="manager-1"
  export SQUAD_SM_WORKSPACE="$case_dir/workspace"
  export SQUAD_SM_DIR="$case_dir/worktree"
  export SQUAD_SM_PROMPT_FILE="$case_dir/prompt.md"
  export SQUAD_SM_LOG="$case_dir/workspace/.squad/workers/sm-api.log"
  export SQUAD_SM_REPORT="$case_dir/workspace/.squad/workers/sm-api.md"
  export SQUAD_SM_ENGINE="agy"
  export SQUAD_SM_MODEL="gemini-4-argon-high"
  export SQUAD_SM_PLAN="none"
  export SQUAD_SM_BUDGET="600000"
  export SQUAD_SM_MAX_CHILDREN="3"
  export SQUAD_SM_WORKER="$fake_worker"
  unset FAKE_PLAN_RESPONSE FAKE_PLAN_RESPONSE_1 FAKE_PLAN_RESPONSE_2 \
        FAKE_REVIEW_RESPONSE FAKE_REVIEW_RESPONSE_1 FAKE_REVIEW_RESPONSE_2 \
        FAKE_AGY_IN_TOKENS FAKE_AGY_OUT_TOKENS \
        FAKE_WORKER_IN_TOKENS FAKE_WORKER_OUT_TOKENS FAKE_WORKER_FAIL_ID || true
}

# 1. Happy path: 2 children, pass.
setup_case happy
export FAKE_PLAN_RESPONSE='Reasoning before JSON.
```json
{
  "children": [
    {"id":"api-1","role":"dev","engine":"agy","model":"gemini-3.8-flash-medium","owns":["src/api/handler.ts"],"brief":"Implement handler"},
    {"id":"api-2","role":"tester","engine":"agy","model":"gemini-3.8-flash-medium","owns":["tests/api/handler.test.ts"],"brief":"Test handler"}
  ],
  "notes": "split into dev and tester"
}
```'
export FAKE_REVIEW_RESPONSE='{"verdict":"pass","fixes":[],"summary":"Both children met acceptance criteria."}'

"$driver" >"$case_dir/stdout.txt" || { cat "$SQUAD_SM_REPORT" >&2 || true; fail "driver failed in happy case"; }
[[ -s "$SQUAD_SM_REPORT" ]] || fail "missing final report"
(( $(wc -l <"$SQUAD_SM_REPORT") <= 25 )) || fail "report exceeds 25 lines"
grep -q '^Verdict: pass$' "$SQUAD_SM_REPORT" || fail "expected Verdict: pass"
grep -q '| api-1 | agy | completed | 300 |' "$SQUAD_SM_REPORT" || fail "missing api-1 row"
grep -q '| api-2 | agy | completed | 300 |' "$SQUAD_SM_REPORT" || fail "missing api-2 row"
grep -q '^Budget: 900/600000 tokens$' "$SQUAD_SM_REPORT" || fail "unexpected budget total"
grep -q 'tracked.txt' "$SQUAD_SM_REPORT" || fail "expected diff --stat with tracked.txt"
# Worker calls have --parent, --no-worktree, --project SQUAD_SM_DIR, and never --merge.
grep -q '^api-1 .*--manager sm-api --parent sm-api --engine agy --model gemini-3.8-flash-medium --role dev --no-worktree --project '"$SQUAD_SM_DIR"' --no-plan sub-manager child --own src/api/handler.ts --brief-file ' "$FAKE_STATE_DIR/worker_calls.log" || fail "unexpected worker args for api-1"
grep -q '^api-2 .*--manager sm-api --parent sm-api --engine agy --model gemini-3.8-flash-medium --role tester --no-worktree --project '"$SQUAD_SM_DIR"' --no-plan sub-manager child --own tests/api/handler.test.ts --brief-file ' "$FAKE_STATE_DIR/worker_calls.log" || fail "unexpected worker args for api-2"
! grep -q -- '--merge' "$FAKE_STATE_DIR/worker_calls.log" || fail "driver must never pass --merge"
[[ "$(git -C "$SQUAD_SM_DIR" rev-list --count HEAD)" == 1 ]] || fail "driver must never git commit"

# 2. Fix path: first review returns fix for api-1, rerun api-1 once, second review returns pass.
setup_case fix_path
export FAKE_PLAN_RESPONSE='{"children":[
  {"id":"api-1","role":"dev","engine":"agy","model":"gemini-3.8-flash-medium","owns":["src/api/a.ts"],"brief":"Original brief A"},
  {"id":"api-2","role":"dev","engine":"agy","model":"gemini-3.8-flash-medium","owns":["tests/api/b.ts"],"brief":"Original brief B"}
],"notes":"ok"}'
export FAKE_REVIEW_RESPONSE_1='{"verdict":"fix","fixes":[{"id":"api-1","brief":"Handle empty input"}],"summary":"api-1 missed edge case"}'
export FAKE_REVIEW_RESPONSE_2='{"verdict":"pass","fixes":[],"summary":"Fixed on rerun"}'

"$driver" >/dev/null
grep -q '^Verdict: pass$' "$SQUAD_SM_REPORT" || fail "expected pass after fix round"
[[ "$(cat "$FAKE_STATE_DIR/worker_count_api-1")" == 2 ]] || fail "api-1 should run twice"
[[ "$(cat "$FAKE_STATE_DIR/worker_count_api-2")" == 1 ]] || fail "api-2 should run once"
grep -q 'Original brief A' "$FAKE_STATE_DIR/brief_api-1_2.md" || fail "rerun brief missing original brief"
grep -q '^## Fix$' "$FAKE_STATE_DIR/brief_api-1_2.md" || fail "rerun brief missing ## Fix header"
grep -q 'Handle empty input' "$FAKE_STATE_DIR/brief_api-1_2.md" || fail "rerun brief missing fix instructions"

# 2b. Second fix round is not rerun; reported as "needs root attention", exit 1.
setup_case fix_twice
export FAKE_PLAN_RESPONSE='{"children":[
  {"id":"api-1","role":"dev","engine":"agy","model":"gemini-3.8-flash-medium","owns":["src/api/a.ts"],"brief":"Original brief A"}
],"notes":"ok"}'
export FAKE_REVIEW_RESPONSE_1='{"verdict":"fix","fixes":[{"id":"api-1","brief":"Fix 1"}],"summary":"still broken"}'
export FAKE_REVIEW_RESPONSE_2='{"verdict":"fix","fixes":[{"id":"api-1","brief":"Fix 2"}],"summary":"still broken after fix"}'

if "$driver" >/dev/null 2>&1; then fail "expected exit 1 on second fix verdict"; fi
grep -q 'needs root attention' "$SQUAD_SM_REPORT" || fail "expected needs root attention in report"
[[ "$(cat "$FAKE_STATE_DIR/worker_count_api-1")" == 2 ]] || fail "only one fix round allowed"

# 3. Invalid JSON twice -> "plan rejected", exit 1.
setup_case invalid_json
export FAKE_PLAN_RESPONSE_1='not valid json at all'
export FAKE_PLAN_RESPONSE_2='{"children": "not-an-array"}'

if "$driver" >/dev/null 2>&1; then fail "expected exit 1 on invalid plan JSON twice"; fi
grep -q 'plan rejected' "$SQUAD_SM_REPORT" || fail "expected plan rejected in report"
[[ "$(cat "$FAKE_STATE_DIR/plan_calls")" == 2 ]] || fail "expected 2 plan turns (initial + 1 retry)"
grep -q '## Validation Errors' "$FAKE_STATE_DIR/plan_prompt_2.txt" || fail "retry prompt must include validation errors"
[[ ! -f "$FAKE_STATE_DIR/worker_calls.log" ]] || fail "no children should run when plan is rejected"

# 4. Ownership outside root's owned paths -> rejected.
setup_case outside_ownership
export FAKE_PLAN_RESPONSE='{"children":[
  {"id":"api-1","role":"dev","engine":"agy","model":"gemini-3.8-flash-medium","owns":["src/other/secret.ts"],"brief":"Touch outside scope"}
],"notes":"bad scope"}'

if "$driver" >/dev/null 2>&1; then fail "expected exit 1 on ownership violation"; fi
grep -q 'plan rejected' "$SQUAD_SM_REPORT" || fail "expected plan rejected for ownership violation"
grep -q 'outside root owned paths' "$SQUAD_SM_REPORT" || fail "expected outside root owned paths reason"
[[ ! -f "$FAKE_STATE_DIR/worker_calls.log" ]] || fail "no children should run on ownership violation"

# 5. Too many children -> rejected.
setup_case too_many_children
export SQUAD_SM_MAX_CHILDREN="2"
export FAKE_PLAN_RESPONSE='{"children":[
  {"id":"c1","role":"dev","engine":"agy","model":"gemini-3.8-flash-medium","owns":["src/api/1.ts"],"brief":"1"},
  {"id":"c2","role":"dev","engine":"agy","model":"gemini-3.8-flash-medium","owns":["src/api/2.ts"],"brief":"2"},
  {"id":"c3","role":"dev","engine":"agy","model":"gemini-3.8-flash-medium","owns":["src/api/3.ts"],"brief":"3"}
],"notes":"too many"}'

if "$driver" >/dev/null 2>&1; then fail "expected exit 1 on too many children"; fi
grep -q 'plan rejected' "$SQUAD_SM_REPORT" || fail "expected plan rejected for too many children"
grep -q 'too many children' "$SQUAD_SM_REPORT" || fail "expected too many children reason"

# 6. Budget small -> "budget reached", exit 1.
setup_case small_budget
export SQUAD_SM_BUDGET="500"
export FAKE_AGY_IN_TOKENS="200"
export FAKE_AGY_OUT_TOKENS="100"
export FAKE_WORKER_IN_TOKENS="150"
export FAKE_WORKER_OUT_TOKENS="100"
export FAKE_PLAN_RESPONSE='{"children":[
  {"id":"api-1","role":"dev","engine":"agy","model":"gemini-3.8-flash-medium","owns":["src/api/1.ts"],"brief":"work"}
],"notes":"ok"}'
export FAKE_REVIEW_RESPONSE='{"verdict":"pass","fixes":[],"summary":"ok"}'

# Plan turn uses 300 (< 500), child uses 250 -> total 550 >= 500 before review turn!
if "$driver" >/dev/null 2>&1; then fail "expected exit 1 when budget is reached"; fi
grep -q 'budget reached (550/500)' "$SQUAD_SM_REPORT" || fail "expected budget reached (550/500) in report"
[[ ! -f "$FAKE_STATE_DIR/review_calls" ]] || fail "review turn should not start after budget reached"

# 7. Missing required env var -> failure report and exit 1.
setup_case missing_env
unset SQUAD_SM_TASK
if "$driver" >/dev/null 2>&1; then fail "expected exit 1 when SQUAD_SM_TASK is missing"; fi
[[ -s "$SQUAD_SM_REPORT" ]] || fail "expected failure report to be written"
grep -q 'SQUAD_SM_TASK' "$SQUAD_SM_REPORT" || fail "expected missing variable name in failure report"

# 8. Invalid plan on first turn, valid on retry turn -> succeeds with pass.
setup_case retry_plan_succeeds
export FAKE_PLAN_RESPONSE_1='{"children":[]}'
export FAKE_PLAN_RESPONSE_2='{"children":[
  {"id":"api-1","role":"dev","engine":"agy","model":"gemini-3.8-flash-medium","owns":["src/api/ok.ts"],"brief":"Implement ok"}
],"notes":"fixed on retry"}'
export FAKE_REVIEW_RESPONSE='{"verdict":"pass","fixes":[],"summary":"ok"}'
"$driver" >/dev/null
[[ "$(cat "$FAKE_STATE_DIR/plan_calls")" == 2 ]] || fail "expected 2 plan turns"
grep -q '^Verdict: pass$' "$SQUAD_SM_REPORT" || fail "expected pass after plan retry"

# 9. Overlapping ownership, path traversal (..), and disallowed engine (claude without SQUAD_SM_ALLOW_CLAUDE=1) -> rejected.
setup_case bad_schema_cases
export FAKE_PLAN_RESPONSE_1='{"children":[
  {"id":"c1","role":"dev","engine":"agy","model":"gemini-3.8-flash-medium","owns":["src/api"],"brief":"dir"},
  {"id":"c2","role":"dev","engine":"agy","model":"gemini-3.8-flash-medium","owns":["src/api/sub.ts"],"brief":"sub"}
],"notes":"overlapping"}'
export FAKE_PLAN_RESPONSE_2='{"children":[
  {"id":"c1","role":"dev","engine":"claude","model":"haiku","owns":["src/api/../escape.ts"],"brief":"escape"}
],"notes":"bad engine and .."}'
if "$driver" >/dev/null 2>&1; then fail "expected exit 1 on overlapping/traversal/engine errors"; fi
grep -q 'overlapping ownership' "$FAKE_STATE_DIR/plan_prompt_2.txt" || fail "expected overlapping ownership error in retry prompt"
grep -q 'plan rejected' "$SQUAD_SM_REPORT" || fail "expected plan rejected"
grep -q 'disallowed engine claude' "$SQUAD_SM_REPORT" || fail "expected disallowed engine claude error"
grep -q 'must not contain \.\.' "$SQUAD_SM_REPORT" || fail "expected .. path error"

echo "PASS: squad-submanager smoke tests"
