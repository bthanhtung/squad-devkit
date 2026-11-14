#!/usr/bin/env bash
set -euo pipefail

source_file="${BASH_SOURCE[0]}"
while [[ -L "$source_file" ]]; do
  source_directory="$(cd "$(dirname "$source_file")" && pwd)"
  link_target="$(readlink "$source_file")"
  if [[ "$link_target" == /* ]]; then
    source_file="$link_target"
  else
    source_file="$source_directory/$link_target"
  fi
done
script_dir="$(cd "$(dirname "$source_file")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing command: $1" >&2
    return 1
  fi
}

fail_early() {
  local msg="$1"
  if [[ -n "${SQUAD_SM_REPORT:-}" ]]; then
    mkdir -p "$(dirname "$SQUAD_SM_REPORT")" 2>/dev/null || true
    {
      printf 'Verdict: failed\n'
      printf 'Summary: %s\n' "$msg"
      printf 'Open issues: %s\n' "$msg"
    } >"$SQUAD_SM_REPORT"
  fi
  if [[ -n "${SQUAD_SM_LOG:-}" ]]; then
    mkdir -p "$(dirname "$SQUAD_SM_LOG")" 2>/dev/null || true
    printf 'squad-submanager: %s\n' "$msg" >>"$SQUAD_SM_LOG"
  fi
  printf 'squad-submanager: %s\n' "$msg" >&2
  exit 1
}

for required_var in \
  SQUAD_SM_ID SQUAD_SM_TASK SQUAD_SM_MANAGER SQUAD_SM_WORKSPACE \
  SQUAD_SM_DIR SQUAD_SM_PROMPT_FILE SQUAD_SM_LOG SQUAD_SM_REPORT \
  SQUAD_SM_ENGINE SQUAD_SM_MODEL SQUAD_SM_PLAN SQUAD_SM_BUDGET \
  SQUAD_SM_MAX_CHILDREN SQUAD_SM_WORKER; do
  if [[ -z "${!required_var:-}" ]]; then
    fail_early "missing required environment variable $required_var"
  fi
done

command -v jq >/dev/null 2>&1 || fail_early "missing required command: jq"
[[ -f "$SQUAD_SM_PROMPT_FILE" && -r "$SQUAD_SM_PROMPT_FILE" ]] || fail_early "prompt file not readable: $SQUAD_SM_PROMPT_FILE"
[[ -d "$SQUAD_SM_DIR" ]] || fail_early "sub-manager worktree directory does not exist: $SQUAD_SM_DIR"
[[ -d "$SQUAD_SM_WORKSPACE" ]] || fail_early "workspace directory does not exist: $SQUAD_SM_WORKSPACE"
[[ -x "$SQUAD_SM_WORKER" ]] || fail_early "worker script not executable: $SQUAD_SM_WORKER"
[[ "$SQUAD_SM_BUDGET" =~ ^[1-9][0-9]*$ ]] || fail_early "SQUAD_SM_BUDGET must be a positive integer: $SQUAD_SM_BUDGET"
[[ "$SQUAD_SM_MAX_CHILDREN" =~ ^[1-9][0-9]*$ ]] || fail_early "SQUAD_SM_MAX_CHILDREN must be a positive integer: $SQUAD_SM_MAX_CHILDREN"

case "$SQUAD_SM_ENGINE" in
  agy|claude|codex) ;;
  *) fail_early "unsupported SQUAD_SM_ENGINE: $SQUAD_SM_ENGINE (expected agy, claude, or codex)" ;;
esac

# shellcheck source=lib/squad-worker-model.sh
source "$script_dir/lib/squad-worker-model.sh"
# shellcheck source=lib/squad-engine.sh
source "$script_dir/lib/squad-engine.sh"

squad_engine_load "$SQUAD_SM_ENGINE" || fail_early "could not load engine adapter: $SQUAD_SM_ENGINE"
squad_engine check_deps || fail_early "missing engine dependencies for $SQUAD_SM_ENGINE"

mkdir -p "$(dirname "$SQUAD_SM_LOG")" "$(dirname "$SQUAD_SM_REPORT")" "$SQUAD_SM_WORKSPACE/.squad/workers"
touch "$SQUAD_SM_LOG"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

role_file="$repo_root/templates/devkit/sub-manager.md"
if [[ ! -f "$role_file" && -f "$SQUAD_SM_WORKSPACE/.squad/roles/sub-manager.md" ]]; then
  role_file="$SQUAD_SM_WORKSPACE/.squad/roles/sub-manager.md"
fi
[[ -f "$role_file" ]] || fail_early "missing role file: $role_file"
role_instructions="$(grep -v '^<!-- squad-devkit template' "$role_file")"
root_prompt="$(cat "$SQUAD_SM_PROMPT_FILE")"

root_owned="$(sed -n 's/^Files you own (change nothing else):[[:space:]]*//p' "$SQUAD_SM_PROMPT_FILE" | head -n 1)"

child_ids=()

child_meta_file() {
  printf '%s/child-%s.json' "$tmp_dir" "$1"
}

child_meta() {
  local cid="$1" field="$2" mfile
  mfile="$(child_meta_file "$cid")"
  [[ -f "$mfile" ]] || return 0
  jq -r --arg f "$field" '.[$f] // empty' "$mfile" 2>/dev/null || true
}

child_state_file() {
  printf '%s/child-%s.state' "$tmp_dir" "$1"
}

child_report_path_file() {
  printf '%s/child-%s.report' "$tmp_dir" "$1"
}

# Latest status file for a child in $SQUAD_SM_WORKSPACE/.squad/workers.
latest_child_status() {
  local cid="$1" workers_dir="$SQUAD_SM_WORKSPACE/.squad/workers"
  [[ -d "$workers_dir" ]] || return 0
  ls -t "$workers_dir/$cid-"*.status "$workers_dir/$cid.status" 2>/dev/null | head -n 1 || true
}

child_state() {
  local cid="$1" sfile st="" state_record
  sfile="$(latest_child_status "$cid")"
  if [[ -n "$sfile" && -f "$sfile" ]]; then
    st="$(sed -n 's/^state=//p' "$sfile" 2>/dev/null | tail -n 1)"
  fi
  if [[ -z "$st" ]]; then
    state_record="$(child_state_file "$cid")"
    [[ -f "$state_record" ]] && st="$(cat "$state_record")"
  fi
  printf '%s' "${st:-unknown}"
}

sm_turn_tokens() {
  [[ -s "$SQUAD_SM_LOG" ]] || { printf '0'; return 0; }
  local count
  count="$(jq -R -r -s '
    [split("\n")[] | fromjson? | select(type == "object")
     | if .event == "result" then (.result.usage // .usage // empty)
       elif .type == "result" or .type == "turn.completed" then (.usage // empty)
       else empty end
     | select(type == "object")
     | ((.input_tokens // 0) + (.output_tokens // 0))]
    | add // 0' "$SQUAD_SM_LOG" 2>/dev/null || echo 0)"
  [[ "$count" =~ ^[0-9]+$ ]] || count=0
  printf '%s' "$count"
}

child_tokens() {
  local cid="$1" total=0 sfile wkr tin tout
  local workers_dir="$SQUAD_SM_WORKSPACE/.squad/workers"
  [[ -d "$workers_dir" ]] || { printf '0'; return 0; }
  for sfile in "$workers_dir/$cid.status" "$workers_dir/$cid-"*.status; do
    [[ -f "$sfile" ]] || continue
    wkr="$(sed -n 's/^worker=//p' "$sfile" 2>/dev/null | tail -n 1)"
    if [[ -n "$wkr" && "$wkr" != "$cid" ]]; then
      continue
    fi
    tin="$(sed -n 's/^tokens_in=//p' "$sfile" 2>/dev/null | tail -n 1)"
    tout="$(sed -n 's/^tokens_out=//p' "$sfile" 2>/dev/null | tail -n 1)"
    [[ "$tin" =~ ^[0-9]+$ ]] || tin=0
    [[ "$tout" =~ ^[0-9]+$ ]] || tout=0
    total=$(( total + tin + tout ))
  done
  printf '%s' "$total"
}

total_tokens() {
  local sum cid ctok
  sum="$(sm_turn_tokens)"
  for cid in ${child_ids[@]+"${child_ids[@]}"}; do
    ctok="$(child_tokens "$cid")"
    sum=$(( sum + ctok ))
  done
  printf '%s' "$sum"
}

write_final_report() {
  local final_verdict="$1"
  local final_summary="$2"
  local open_issues="${3:-none}"
  local used diff_stat diff_compact cid ceng cstate ctok line_count
  used="$(total_tokens)"
  final_summary="$(printf '%s' "$final_summary" | tr '\r\n' '  ')"
  open_issues="$(printf '%s' "$open_issues" | tr '\r\n' '  ')"
  diff_stat="$(git -C "$SQUAD_SM_DIR" diff --stat 2>/dev/null || true)"
  if [[ -z "${diff_stat//[[:space:]]/}" ]]; then
    diff_compact="none"
  else
    line_count="$(printf '%s\n' "$diff_stat" | wc -l | tr -d ' ')"
    if (( line_count <= 5 )); then
      diff_compact="$diff_stat"
    else
      diff_compact="$(printf '%s\n' "$diff_stat" | head -n 4)"$'\n'"$(printf '%s\n' "$diff_stat" | tail -n 1)"
    fi
  fi
  {
    printf 'Verdict: %s\n' "$final_verdict"
    printf 'Summary: %s\n' "$final_summary"
    printf 'Budget: %s/%s tokens\n' "$used" "$SQUAD_SM_BUDGET"
    printf 'Children:\n'
    printf '| id | engine | state | tokens |\n'
    printf '| --- | --- | --- | --- |\n'
    if (( ${#child_ids[@]} == 0 )); then
      printf '| none | - | - | 0 |\n'
    else
      for cid in "${child_ids[@]}"; do
        ceng="$(child_meta "$cid" engine)"
        cstate="$(child_state "$cid")"
        ctok="$(child_tokens "$cid")"
        printf '| %s | %s | %s | %s |\n' "$cid" "$ceng" "$cstate" "$ctok"
      done
    fi
    printf 'Files changed:\n%s\n' "$diff_compact"
    printf 'Open issues: %s\n' "$open_issues"
  } | head -n 25 >"$SQUAD_SM_REPORT"
  cat "$SQUAD_SM_REPORT"
}

check_budget() {
  local used
  used="$(total_tokens)"
  if (( used >= SQUAD_SM_BUDGET )); then
    write_final_report "budget reached ($used/$SQUAD_SM_BUDGET)" \
      "budget reached ($used/$SQUAD_SM_BUDGET)" \
      "budget reached ($used/$SQUAD_SM_BUDGET)"
    exit 1
  fi
}

turn_counter=0
run_turn() {
  local turn_prompt="$1"
  local out_report="$2"
  check_budget
  turn_counter=$(( turn_counter + 1 ))
  local turn_log="$tmp_dir/turn-$turn_counter.log"
  local turn_rep="$tmp_dir/turn-$turn_counter.md"
  : >"$turn_log"
  : >"$turn_rep"

  # Globals read by scripts/lib/engines/*.sh
  # shellcheck disable=SC2034
  prompt="$turn_prompt"
  # shellcheck disable=SC2034
  model="$SQUAD_SM_MODEL"
  # shellcheck disable=SC2034
  model_effort="${SQUAD_SM_MODEL_EFFORT:-}"
  # shellcheck disable=SC2034
  model_arguments=(--model "$SQUAD_SM_MODEL")
  # shellcheck disable=SC2034
  yolo="${SQUAD_DEVKIT_YOLO:-0}"
  # shellcheck disable=SC2034
  sandbox_mode="${SQUAD_WORKER_SANDBOX:-1}"
  # shellcheck disable=SC2034
  [[ "$yolo" != 1 ]] || sandbox_mode=0
  # shellcheck disable=SC2034
  plan_path="$SQUAD_SM_PLAN"
  # shellcheck disable=SC2034
  workspace_root="$SQUAD_SM_WORKSPACE"
  # shellcheck disable=SC2034
  engine_directory="$SQUAD_SM_DIR"
  # shellcheck disable=SC2034
  profile="${SQUAD_WORKER_CODEX_PROFILE:-}"
  # shellcheck disable=SC2034
  keep_mcp=()
  # shellcheck disable=SC2034
  all_mcp=0
  # shellcheck disable=SC2034
  log_file="$turn_log"
  # shellcheck disable=SC2034
  output_directory="$tmp_dir"
  # shellcheck disable=SC2034
  absolute_log="$turn_log"
  # shellcheck disable=SC2034
  absolute_report="$turn_rep"
  # shellcheck disable=SC2034
  engine_command=()

  local rc=0
  squad_engine build_command || rc=$?
  if (( rc == 0 )); then
    (
      cd "$SQUAD_SM_DIR"
      unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT
      squad_engine run_and_extract_report
    ) || rc=$?
  fi
  if [[ -s "$turn_log" ]]; then
    cat "$turn_log" >>"$SQUAD_SM_LOG"
  fi
  if (( rc != 0 )) || [[ ! -s "$turn_rep" ]]; then
    return 1
  fi
  cp "$turn_rep" "$out_report"
  return 0
}

extract_last_json() {
  local file="$1"
  [[ -s "$file" ]] || return 1
  awk '
    {
      line = $0
      if (line ~ /^```/) next
      n = length(line)
      for (i = 1; i <= n; i++) {
        c = substr(line, i, 1)
        if (depth == 0) {
          if (c == "{") {
            depth = 1
            buf = "{"
            in_str = 0
            esc = 0
          }
          continue
        }
        buf = buf c
        if (esc) {
          esc = 0
          continue
        }
        if (in_str) {
          if (c == "\\") esc = 1
          else if (c == "\"") in_str = 0
          continue
        }
        if (c == "\"") {
          in_str = 1
        } else if (c == "{") {
          depth++
        } else if (c == "}") {
          depth--
          if (depth == 0) {
            print buf
            buf = ""
          }
        }
      }
      if (depth > 0) buf = buf " "
    }
  ' "$file" | jq -R -s -c '
    [split("\n")[] | select(length > 0) | fromjson? | select(type == "object")]
    | if length == 0 then empty else .[-1] end' 2>/dev/null
}

paths_overlap() {
  local a="${1%/}" b="${2%/}"
  [[ -n "$a" && -n "$b" ]] || return 1
  # shellcheck disable=SC2053
  if [[ "$a" == "$b" || "$a" == $b || "$b" == $a || "$a" == $b/* || "$b" == $a/* ]]; then
    return 0
  fi
  return 1
}

path_in_root_owned() {
  local file="${1%/}" pattern
  local patterns=()
  IFS=',' read -r -a patterns <<<"$2"
  for pattern in ${patterns[@]+"${patterns[@]}"}; do
    pattern="${pattern#"${pattern%%[![:space:]]*}"}"
    pattern="${pattern%"${pattern##*[![:space:]]}"}"
    pattern="${pattern%/}"
    [[ -n "$pattern" ]] || continue
    # shellcheck disable=SC2053
    if [[ "$file" == $pattern || "$file" == $pattern/* ]]; then
      return 0
    fi
  done
  return 1
}

validate_plan_json() {
  local json="$1"
  if [[ -z "$json" ]]; then
    printf 'no valid JSON object found in plan turn output\n'
    return 1
  fi
  local allow_claude="${SQUAD_SM_ALLOW_CLAUDE:-0}"
  local jq_errors
  jq_errors="$(printf '%s\n' "$json" | jq -r \
    --argjson max_children "$SQUAD_SM_MAX_CHILDREN" \
    --argjson allow_claude "$([[ "$allow_claude" == 1 ]] && echo true || echo false)" '
    def errs:
      if (type != "object") or ((.children | type) != "array") then
        ["top-level object must contain a children array"]
      elif (.children | length) < 1 then
        ["children array must contain at least 1 child"]
      elif (.children | length) > $max_children then
        ["too many children: \(.children | length) exceeds max_children (\($max_children))"]
      else
        [
          (if ([.children[].id // ""] | length) != ([.children[].id // ""] | unique | length) then
            "duplicate child ids"
           else empty end),
          (.children | to_entries[] | .key as $idx | .value as $c |
            (if (($c.id | type) != "string") or (($c.id | test("^[A-Za-z0-9][A-Za-z0-9._-]*$")) | not) then
              "child[\($idx)]: invalid id \($c.id // "null")"
             else empty end),
            (if (($c.role | type) != "string") or (($c.role | IN("dev","tester","researcher","docs")) | not) then
              "child[\($idx)]: invalid role \($c.role // "null") (allowed: dev, tester, researcher, docs)"
             else empty end),
            (($c.engine // "agy") as $eng |
             if (($eng | type) != "string") or
                (($eng | IN("agy","opencode")) | not) and ((($eng == "claude") and $allow_claude) | not) then
              "child[\($idx)]: disallowed engine \($eng)"
             else empty end),
            (($c.model // "gemini-3.8-flash-medium") as $mdl |
             if (($mdl | type) != "string") or ($mdl | length) == 0 or ($mdl | startswith("-")) or ($mdl | test("[\\s\\p{Cc}]")) then
              "child[\($idx)]: invalid model \($mdl | tostring)"
             else empty end),
            (if (($c.brief | type) != "string") or (($c.brief | test("\\S")) | not) then
              "child[\($idx)]: brief must be a non-empty string"
             else empty end),
            (if (($c.owns | type) != "array") or (($c.owns | length) < 1) then
              "child[\($idx)]: owns must be a non-empty array of relative paths"
             else
              ($c.owns[] |
                if (type != "string") or (length == 0) then
                  "child[\($idx)]: owns contains an empty or non-string path"
                elif startswith("/") then
                  "child[\($idx)]: owns path \(.) must be relative, not absolute"
                elif (contains("..") or . == "." or . == "./") then
                  "child[\($idx)]: owns path \(.) must not contain .."
                else empty end)
             end)
          )
        ]
      end;
    errs | join("; ")
  ' 2>/dev/null || echo "failed to parse plan JSON")"

  if [[ -n "$jq_errors" ]]; then
    printf '%s\n' "$jq_errors"
    return 1
  fi

  # Check disjoint owns across children and root_owned boundaries.
  local count i j p1 p2 cid1 cid2
  local all_Child_ids=()
  local all_owns=()
  local errors=()

  count="$(printf '%s\n' "$json" | jq -r '.children | length')"
  for ((i = 0; i < count; i++)); do
    cid1="$(printf '%s\n' "$json" | jq -r ".children[$i].id")"
    while IFS= read -r p1; do
      [[ -n "$p1" ]] || continue
      if [[ -n "$root_owned" ]] && ! path_in_root_owned "$p1" "$root_owned"; then
        errors+=("child $cid1 owns '$p1' outside root owned paths ($root_owned)")
      fi
      for ((j = 0; j < ${#all_owns[@]}; j++)); do
        cid2="${all_Child_ids[j]}"
        p2="${all_owns[j]}"
        if [[ "$cid1" != "$cid2" ]] && paths_overlap "$p1" "$p2"; then
          errors+=("overlapping ownership between $cid1 ($p1) and $cid2 ($p2)")
        fi
      done
      all_Child_ids+=("$cid1")
      all_owns+=("$p1")
    done < <(printf '%s\n' "$json" | jq -r ".children[$i].owns[]")
  done

  if (( ${#errors[@]} > 0 )); then
    local joined="" err
    for err in "${errors[@]}"; do
      joined="${joined:+$joined; }$err"
    done
    printf '%s\n' "$joined"
    return 1
  fi
  return 0
}

allowed_engines_label="agy, opencode"
if [[ "${SQUAD_SM_ALLOW_CLAUDE:-0}" == 1 ]]; then
  allowed_engines_label="agy, opencode, claude"
fi

build_plan_prompt() {
  local validation_feedback="${1:-}"
  cat <<EOF
$role_instructions

## Phase: plan

### Limits and Allowed Configuration
- Maximum children: $SQUAD_SM_MAX_CHILDREN
- Allowed roles: dev, tester, researcher, docs
- Allowed engines: $allowed_engines_label
- Default child engine/model: agy / gemini-3.8-flash-medium (use gemini-4-argon-high only for deep reasoning)
- Branch token budget: $SQUAD_SM_BUDGET
${root_owned:+- Root owned paths (every child owns path must be inside these): $root_owned}

### Root Task Prompt
$root_prompt
${validation_feedback:+
## Validation Errors from Previous Plan Attempt
Fix the following errors and output a valid plan JSON object:
$validation_feedback}
EOF
}

# Step 1: Plan turn (with at most 1 retry on validation failure).
plan_report="$tmp_dir/plan-report.md"
plan_json=""
plan_errors=""

if run_turn "$(build_plan_prompt)" "$plan_report"; then
  plan_json="$(extract_last_json "$plan_report" || true)"
  if ! plan_errors="$(validate_plan_json "$plan_json")"; then
    plan_json=""
  fi
else
  plan_errors="plan turn failed to produce a report"
fi

if [[ -z "$plan_json" ]]; then
  if run_turn "$(build_plan_prompt "$plan_errors")" "$plan_report"; then
    plan_json="$(extract_last_json "$plan_report" || true)"
    if ! plan_errors="$(validate_plan_json "$plan_json")"; then
      plan_json=""
    fi
  else
    plan_errors="${plan_errors:+$plan_errors; }retry plan turn failed to produce a report"
  fi
fi

if [[ -z "$plan_json" ]]; then
  write_final_report "plan rejected: $plan_errors" \
    "plan rejected: $plan_errors" \
    "$plan_errors"
  exit 1
fi

# Normalize defaults in plan_json and store per-child metadata.
plan_json="$(printf '%s\n' "$plan_json" | jq -c '
  .children |= map(
    .engine = (.engine // "agy") |
    .model = (.model // "gemini-3.8-flash-medium")
  )')"

children_count="$(printf '%s\n' "$plan_json" | jq -r '.children | length')"
for ((i = 0; i < children_count; i++)); do
  cid="$(printf '%s\n' "$plan_json" | jq -r ".children[$i].id")"
  child_ids+=("$cid")
  printf '%s\n' "$plan_json" | jq -c ".children[$i]" >"$(child_meta_file "$cid")"
  printf 'pending' >"$(child_state_file "$cid")"
done

# Step 2: Run a list of children in parallel.
# Usage: run_children_batch <mode: initial|fix> <cid1> [cid2 ...]
run_children_batch() {
  local mode="$1"
  shift
  local batch_ids=("$@")
  check_budget

  local pids=()
  local cid ceng cmdl crole cbrief fix_brief brief_file own_path
  local cmd=()

  for cid in "${batch_ids[@]}"; do
    ceng="$(child_meta "$cid" engine)"
    cmdl="$(child_meta "$cid" model)"
    crole="$(child_meta "$cid" role)"
    cbrief="$(child_meta "$cid" brief)"
    if [[ "$mode" == "fix" && -f "$tmp_dir/fix-$cid.brief" ]]; then
      fix_brief="$(cat "$tmp_dir/fix-$cid.brief")"
      cbrief="$cbrief"$'\n\n## Fix\n'"$fix_brief"
    fi
    brief_file="$tmp_dir/brief-$cid-$mode.md"
    printf '%s\n' "$cbrief" >"$brief_file"

    cmd=(
      "$SQUAD_SM_WORKER" "$cid"
      --manager "$SQUAD_SM_ID"
      --parent "$SQUAD_SM_ID"
      --engine "$ceng"
      --model "$cmdl"
      --role "$crole"
      --no-worktree
      --project "$SQUAD_SM_DIR"
    )
    if [[ -n "$SQUAD_SM_PLAN" && "$SQUAD_SM_PLAN" != "none" ]]; then
      cmd+=(--plan "$SQUAD_SM_PLAN")
    else
      cmd+=(--no-plan "sub-manager child")
    fi
    while IFS= read -r own_path; do
      [[ -n "$own_path" ]] || continue
      cmd+=(--own "$own_path")
    done < <(jq -r '.owns[]' "$(child_meta_file "$cid")")
    cmd+=(--brief-file "$brief_file")

    "${cmd[@]}" >"$tmp_dir/worker-$cid-$mode.out" 2>"$tmp_dir/worker-$cid-$mode.err" &
    pids+=("$!")
  done

  local idx pid rc newest_rep sfile st
  for ((idx = 0; idx < ${#batch_ids[@]}; idx++)); do
    cid="${batch_ids[idx]}"
    pid="${pids[idx]}"
    rc=0
    wait "$pid" || rc=$?

    newest_rep="$(ls -t "$SQUAD_SM_WORKSPACE/.squad/workers/$cid-"*.md "$SQUAD_SM_WORKSPACE/.squad/workers/$cid.md" 2>/dev/null | head -n 1 || true)"
    if [[ -z "$newest_rep" && -s "$tmp_dir/worker-$cid-$mode.out" ]]; then
      newest_rep="$(sed -n 's/.*report: \([^[:space:]]*\).*/\1/p' "$tmp_dir/worker-$cid-$mode.out" | tail -n 1)"
    fi
    if [[ -n "$newest_rep" && -f "$newest_rep" ]]; then
      printf '%s' "$newest_rep" >"$(child_report_path_file "$cid")"
    elif [[ -s "$tmp_dir/worker-$cid-$mode.out" ]]; then
      cp "$tmp_dir/worker-$cid-$mode.out" "$tmp_dir/fallback-$cid.md"
      printf '%s' "$tmp_dir/fallback-$cid.md" >"$(child_report_path_file "$cid")"
    fi

    sfile="$(latest_child_status "$cid")"
    st=""
    if [[ -n "$sfile" && -f "$sfile" ]]; then
      st="$(sed -n 's/^state=//p' "$sfile" 2>/dev/null | tail -n 1)"
    fi
    if [[ -z "$st" ]]; then
      if (( rc == 0 )); then st="completed"; else st="failed"; fi
    fi
    printf '%s' "$st" >"$(child_state_file "$cid")"
  done
}

run_children_batch initial "${child_ids[@]}"

# Step 3: Review turn.
build_review_prompt() {
  local cid rep_ptr rep_snippet st diff_stat
  diff_stat="$(git -C "$SQUAD_SM_DIR" diff --stat 2>/dev/null || true)"
  cat <<EOF
$role_instructions

## Phase: review

### Plan JSON
$plan_json

### Git Diff Stat
${diff_stat:-no changes}

### Child States and Reports (first 40 lines each)
EOF
  for cid in "${child_ids[@]}"; do
    st="$(child_state "$cid")"
    rep_ptr="$(child_report_path_file "$cid")"
    rep_snippet="(no report)"
    if [[ -f "$rep_ptr" && -f "$(cat "$rep_ptr")" ]]; then
      rep_snippet="$(head -n 40 "$(cat "$rep_ptr")")"
    fi
    printf '\n#### Child %s (state: %s)\n%s\n' "$cid" "$st" "$rep_snippet"
  done
}

validate_review_json() {
  local json="$1"
  [[ -n "$json" ]] || return 1
  printf '%s\n' "$json" | jq -e '
    type == "object" and
    (.verdict == "pass" or .verdict == "fix") and
    (if .verdict == "fix" then
      (.fixes | type) == "array" and (.fixes | length) >= 1 and
      all(.fixes[]; (type == "object") and ((.id | type) == "string") and ((.brief | type) == "string") and (.brief | test("\\S")))
     else true end)
  ' >/dev/null 2>&1
}

review_report="$tmp_dir/review-1.md"
if ! run_turn "$(build_review_prompt)" "$review_report"; then
  write_final_report "failed" "review turn failed to produce a report" "review turn failed"
  exit 1
fi

review_json="$(extract_last_json "$review_report" || true)"
if ! validate_review_json "$review_json"; then
  write_final_report "failed" "invalid review verdict JSON" "review turn returned invalid JSON"
  exit 1
fi

verdict="$(printf '%s\n' "$review_json" | jq -r '.verdict')"
summary="$(printf '%s\n' "$review_json" | jq -r '.summary // ""')"

# Step 4: At most one fix round when verdict == fix.
if [[ "$verdict" == "fix" ]]; then
  fix_ids=()
  fix_count="$(printf '%s\n' "$review_json" | jq -r '.fixes | length')"
  for ((i = 0; i < fix_count; i++)); do
    fid="$(printf '%s\n' "$review_json" | jq -r ".fixes[$i].id")"
    fbrief="$(printf '%s\n' "$review_json" | jq -r ".fixes[$i].brief")"
    if [[ ! -f "$(child_meta_file "$fid")" ]]; then
      write_final_report "failed" "review requested fix for unknown child $fid" "unknown child $fid in fixes"
      exit 1
    fi
    printf '%s\n' "$fbrief" >"$tmp_dir/fix-$fid.brief"
    # Avoid duplicate IDs in batch_ids if listed twice
    already=0
    for existing in ${fix_ids[@]+"${fix_ids[@]}"}; do
      [[ "$existing" == "$fid" ]] && already=1
    done
    (( already == 1 )) || fix_ids+=("$fid")
  done

  run_children_batch fix "${fix_ids[@]}"

  review_report_2="$tmp_dir/review-2.md"
  if ! run_turn "$(build_review_prompt)" "$review_report_2"; then
    write_final_report "failed" "second review turn failed to produce a report" "second review turn failed"
    exit 1
  fi
  review_json_2="$(extract_last_json "$review_report_2" || true)"
  if ! validate_review_json "$review_json_2"; then
    write_final_report "failed" "invalid second review verdict JSON" "second review turn returned invalid JSON"
    exit 1
  fi
  verdict="$(printf '%s\n' "$review_json_2" | jq -r '.verdict')"
  summary="$(printf '%s\n' "$review_json_2" | jq -r '.summary // ""')"

  if [[ "$verdict" == "fix" ]]; then
    open_fixes="$(printf '%s\n' "$review_json_2" | jq -r '[.fixes[] | "\(.id): \(.brief)"] | join("; ")')"
    write_final_report "needs root attention" \
      "${summary:-children still need fixes after one fix round}" \
      "${open_fixes:-needs root attention}"
    exit 1
  fi
fi

# Step 6: Final report on pass.
write_final_report "pass" "${summary:-all children completed and passed review}" "none"
exit 0
