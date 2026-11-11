#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: squad-worker-monitor <status-file> [--once]
       squad-worker-monitor --all [directory] [--once]
       squad-worker-monitor --savings [workspace] [--text]

Show one squad-worker run live: state, elapsed time, commands or tool calls,
failures, changed files, tokens, and recent activity. squad-worker opens this
in a split pane next to the manager. With --all, show a table of every run in
.squad/workers (or the given directory), refreshed every two seconds.
--once prints a single frame and exits. --savings prints a one-line status
label as JSON for claude-hud --extra-cmd (plain text with --text): running
workers and the tokens that workers on other engines processed instead of
Claude (since SQUAD_DEVKIT_SESSION_START when set).

Environment: SQUAD_WORKER_PANE_HOLD=N closes a finished run's pane after N
seconds (default: wait for Enter).
EOF
}

status_file=""
all=0
all_directory=""
once=0
savings=0
text=0
while (( $# > 0 )); do
  case "$1" in
    --all) all=1 ;;
    --savings) savings=1; all=1 ;;
    --text) text=1 ;;
    --once) once=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)
      if (( all == 1 )); then
        all_directory="$1"
      else
        status_file="$1"
      fi
      ;;
  esac
  shift
done

source_file="${BASH_SOURCE[0]}"
while [[ -L "$source_file" ]]; do
  source_directory="$(cd "$(dirname "$source_file")" && pwd)"
  link_target="$(readlink "$source_file")"
  if [[ "$link_target" == /* ]]; then source_file="$link_target"
  else source_file="$source_directory/$link_target"; fi
done
source "$(cd "$(dirname "$source_file")" && pwd)/lib/squad-worker-model.sh"
# shellcheck source=lib/squad-plan.sh
source "$(cd "$(dirname "$source_file")" && pwd)/lib/squad-plan.sh"

status_get() {
  sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -n 1
}

# The recorded state, or "lost" when a run still marked running has no process.
effective_state() {
  local state pid
  state="$(status_get "$1" state)"
  pid="$(status_get "$1" pid)"
  if [[ "$state" == running && -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; then
    state=lost
  fi
  printf '%s' "$state"
}

human_count() {
  local value="${1:-0}"
  if (( value >= 1000000 )); then
    printf '%d.%dM' $(( value / 1000000 )) $(( value % 1000000 / 100000 ))
  elif (( value >= 1000 )); then
    printf '%dk' $(( value / 1000 ))
  else
    printf '%d' "$value"
  fi
}

format_duration() {
  local seconds="$1"
  if (( seconds >= 3600 )); then
    printf '%dh%02dm' $((seconds / 3600)) $((seconds % 3600 / 60))
  else
    printf '%02d:%02d' $((seconds / 60)) $((seconds % 60))
  fi
}

format_count() {
  local digits="$1"
  local grouped=""
  while (( ${#digits} > 3 )); do
    grouped=",${digits: -3}$grouped"
    digits="${digits:0:${#digits}-3}"
  done
  printf '%s%s' "$digits" "$grouped"
}

elapsed_seconds() {
  local started finished
  started="$(status_get "$1" started)"
  finished="$(status_get "$1" finished)"
  [[ -n "$started" ]] || { printf '0'; return; }
  printf '%d' $(( ${finished:-$(date +%s)} - started ))
}

# Summarises a codex --json, claude stream-json, or agy stream-json log as tab-separated
# metrics on the first line, then one activity line per event: summarise_log <log> [engine].
# Only the engine's own stream format is parsed; an unknown engine (older status
# files) tries all of them.
summarise_log() {
  local log="$1" engine="${2:-}"
  local root="${log%/.squad/workers/*}/"
  local codex=false claude=false agy=false
  case "$engine" in
    codex) codex=true ;;
    claude|ccr) claude=true ;;
    agy) claude=true agy=true ;;
    grok|opencode) ;;
    *) codex=true claude=true agy=true ;;
  esac
  if [[ ! -s "$log" ]] || ! command -v jq >/dev/null 2>&1; then
    printf '\t\t\t\t\t\t\n'
    [[ -s "$log" ]] && tail -n 40 "$log"
    return 0
  fi
  jq -R -r -s --arg root "$root" --argjson codex "$codex" --argjson claude "$claude" --argjson agy "$agy" '
    def short: tostring | split($root) | join("") | gsub("[\r\n]+"; " ") | .[0:160];
    def cmd: tostring | sub("^/bin/(ba|z)?sh -l?c "; "") | short;
    def clean_out:
      split("\n")
      | map(gsub("\r"; ""))
      | map(select(length > 0
          and (startswith("Command exited with code") | not)
          and (startswith("Command output:") | not)
          and (startswith("Reading additional input") | not)
          and (startswith("The tool\u0027s output was truncated") | not)))
      | first // "";
    def out_line:
      if . != null and . != "" then
        (clean_out | if length > 0 then "\t  ↳ " + short else "" end)
      else "" end;

    [split("\n")[] | fromjson? | select(type == "object")] as $events
    | (if $codex then [$events[] | select(.type == "item.completed") | .item] else [] end) as $done
    | (if $codex then [$events[] | select(.type == "item.started") | .item] else [] end) as $started
    | ([$done[] | .id]) as $done_ids
    | (if $claude then [$events[] | select(.type == "assistant") | .message.content[]? | select(.type == "tool_use")] else [] end) as $tools
    | (if $claude then [$events[] | select(.type == "user") | .message.content[]? | select(.type == "tool_result" and .is_error == true)] else [] end) as $tool_errors
    | (if $claude then reduce $events[] as $e ({};
        if $e.type == "user" then
          reduce ($e.message.content[]? | select(.type == "tool_result")) as $tr (.;
            .[$tr.tool_use_id] = $tr
          )
        else . end
      ) else {} end) as $claude_results
    | (if $agy then [$events[] | select(.event == "step_update" and .step_update.step_type == "tool" and .step_update.state == "DONE") | .step_update] else [] end) as $agy_tools
    | (if $agy then [$events[] | select(.event == "step_update" and .step_update.step_type == "tool" and .step_update.state == "ACTIVE") | .step_update] else [] end) as $agy_active_tools
    | [$agy_tools[] | select((.tool_info.output // "") | test("exit code [1-9]|status FAILED|failed"; "i"))] as $agy_tool_errors
    | ((if $codex then [$events[] | select(.type == "turn.completed") | .usage] else [] end)
       + (if $claude then [$events[] | select(.type == "result") | .usage | select(. != null)] else [] end)
       + (if $agy then [$events[] | select(.event == "result") | .result.usage | select(. != null)] else [] end)) as $usage
    | [
        ([$done[] | select(.type == "command_execution" or .type == "mcp_tool_call")] | length) + ($tools | length) + ($agy_tools | length),
        ([$done[] | select((.type == "command_execution" and .exit_code != 0) or (.type == "mcp_tool_call" and .status != "completed"))] | length) + ($tool_errors | length) + ($agy_tool_errors | length),
        ([$done[] | select(.type == "file_change") | .changes[]?] | length)
          + ([$tools[] | select(.name == "Edit" or .name == "Write")] | length)
          + ([$agy_tools[] | select(.tool_name == "write_to_file" or .tool_name == "replace_file_content" or .tool_name == "multi_replace_file_content" or .tool_name == "notebook_edit")] | length),
        ([$usage[] | (.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_tokens // 0)] | add // ""),
        ([$usage[] | (.cached_input_tokens // .cache_read_input_tokens // .cache_read_tokens // 0)] | add // ""),
        ([$usage[] | .output_tokens // 0] | add // ""),
        ((if $claude then [$events[] | select(.type == "result") | .num_turns] else [] end)
          + (if $agy then [$events[] | select(.event == "result") | .result.num_turns] else [] end) | last // "")
      ] | map(tostring) | join("\t"),
    ( $events[]
      | if $codex and .type == "item.completed" then .item
          | if .type == "command_execution" then
              (if .exit_code == 0 then "✓ " else "✗ " end) + (.command | cmd) + (if .exit_code == 0 then "" else "  (exit \(.exit_code))" end)
              + (.aggregated_output | out_line)
            elif .type == "mcp_tool_call" then
              (if .status == "completed" then "⚙ " else "✗ " end) + "\(.server)/\(.tool)"
            elif .type == "file_change" then "✎ " + ([.changes[]? | .path] | join(", ") | short)
            elif .type == "agent_message" then "» " + (.text | short)
            elif .type == "error" then "! " + (.message | short)
            else empty end
        elif $claude and .type == "assistant" then .message.content[]?
          | if .type == "tool_use" then
              (if .id != null and $claude_results[.id].is_error == true then "✗ " else "→ " end)
              + .name + " " + ((.input.file_path // .input.path // .input.pattern // .input.command // "") | short)
              + (if .id != null then ($claude_results[.id].content | out_line) else "" end)
            elif .type == "text" and (.text | length) > 0 then "» " + (.text | short)
            else empty end
        elif $claude and .type == "user" then .message.content[]?
          | if .type == "tool_result" and .is_error == true then
              "✗ tool error: " + (.content | short)
            else empty end
        elif $agy and .event == "step_update" and .step_update.step_type == "tool" and .step_update.state == "DONE" then
          .step_update |
          (if .tool_name == "read_file" then
            "✓ read " + (.tool_info.parameters.Path // "" | short)
           elif .tool_name == "run_command" then
            "✓ " + (.tool_info.parameters.CommandLine // "" | cmd)
           elif .tool_name == "write_to_file" or .tool_name == "replace_file_content" or .tool_name == "multi_replace_file_content" or .tool_name == "notebook_edit" then
            "✎ " + (.tool_info.parameters.Path // "" | short)
           else
            "⚙ " + .tool_name + " " + ((.tool_info.parameters | tostring) | short)
           end)
          + (.tool_info.output | out_line)
        elif $agy and .event == "error" then "! " + (.error.message // .error | short)
        else empty end ),
    ( [$started[] | select(.type == "command_execution") | select(.id as $id | $done_ids | index($id) | not)]
      | last | select(. != null) | "… running: " + (.command | cmd) ),
    ( [$agy_active_tools[] | select(.tool_name != null)]
      | last | select(. != null) | "… running: " + (.tool_name + " " + ((.tool_info.parameters.CommandLine // .tool_info.parameters.Path // "") | short)) )
  ' "$log" 2>/dev/null || { printf '\t\t\t\t\t\t\n'; tail -n 40 "$log"; }
}

# Styles only when writing to a terminal.
if [[ -t 1 ]] && (( once == 0 )); then
  bold=$'\033[1m' dim=$'\033[2m' green=$'\033[32m' red=$'\033[31m'
  yellow=$'\033[33m' cyan=$'\033[36m' reset=$'\033[0m' clear_line=$'\r\033[2K'
else
  bold='' dim='' green='' red='' yellow='' cyan='' reset='' clear_line=''
fi

terminal_columns() {
  local columns="${COLUMNS:-}"
  [[ -n "$columns" ]] || columns="$(tput cols 2>/dev/null || echo 100)"
  (( columns > 20 )) || columns=100
  printf '%d' "$columns"
}

# Pure bash, so it works without a UTF-8 locale (tr would reject the multibyte rule character).
rule() {
  local line
  printf -v line '%*s' "$(terminal_columns)" ''
  printf '%s%s%s\n' "$dim" "${line// /─}" "$reset"
}

file_size() {
  wc -c <"$1" 2>/dev/null | tr -d ' ' || echo 0
}

# Prints one activity line, coloured by its marker and cut to the pane width.
# If an output/result preview is present after a tab, it prints indented and dimmed.
print_activity() {
  local line="$1" width color="" tab main detail
  tab="$(printf '\t')"
  width=$(( $(terminal_columns) - 1 ))
  if [[ "$line" == *"$tab"* ]]; then
    main="${line%%${tab}*}"
    detail="${line#*${tab}}"
  else
    main="$line"
    detail=""
  fi
  case "$main" in
    "✓ "*) color="$green" ;;
    "✗ "*) color="$red" ;;
    "! "*) color="$yellow" ;;
    "⚙ "*|"→ "*|"✎ "*) color="$cyan" ;;
  esac
  printf '%s%s%s\n' "$color" "${main:0:$width}" "$reset"
  if [[ -n "$detail" ]]; then
    printf '%s%s%s\n' "$dim" "${detail:0:$width}" "$reset"
  fi
}

count_label() {
  local count="${1:-0}" singular="$2" plural="$3"
  if [[ "$count" == 1 ]]; then
    printf '%s %s' "$count" "$singular"
  else
    printf '%s %s' "$count" "$plural"
  fi
}

# "calls · failed · files · turns · tokens" for the status and summary lines.
metrics_label() {
  local engine="$1" state="$2" calls="$3" failures="$4" files="$5" turns="$6"
  local tokens_in="$7" tokens_cached="$8" tokens_out="$9" label call_word="call" call_words="calls"
  [[ "$engine" == ccr ]] && call_word="tool call" && call_words="tool calls"
  label="$(count_label "${calls:-0}" "$call_word" "$call_words") · ${failures:-0} failed · $(count_label "${files:-0}" "file changed" "files changed")"
  [[ -n "$turns" ]] && label+=" · $(count_label "$turns" turn turns)"
  if [[ -n "$tokens_in$tokens_out" && "${tokens_in:-0}${tokens_out:-0}" != 00 ]]; then
    label+=" · tokens in $(format_count "${tokens_in:-0}")"
    [[ -n "$tokens_cached" && "$tokens_cached" != 0 ]] && label+=" (cached $(format_count "$tokens_cached"))"
    label+=" · out $(format_count "${tokens_out:-0}")"
  elif [[ "$state" != running && "$engine" == ccr ]]; then
    label+=" · tokens n/a (router)"
  fi
  printf '%s' "$label"
}

state_label() {
  local state="$1" reason="$2" exit_status="$3"
  case "$state" in
    running) printf '%s● RUNNING%s' "$yellow" "$reset" ;;
    completed) printf '%s✓ COMPLETED%s' "$green" "$reset" ;;
    failed) printf '%s✗ FAILED%s%s (exit %s)' "$red" "$reset" "${reason:+: $reason}" "${exit_status:-?}" ;;
    stopped) printf '%s■ STOPPED%s%s' "$yellow" "$reset" "${reason:+: $reason}" ;;
    lost) printf '%s? LOST%s: the worker process ended without a report' "$red" "$reset" ;;
    *) printf '%s' "${state:-?}" ;;
  esac
}

# Follows one run without redrawing the screen: the header prints once,
# activity is appended as it happens, and only the last line (the status) is
# rewritten in place. A finished run gets a summary, the merge hint, and the
# start of the report.
watch_run() {
  local file="$1"
  local worker engine profile model role title task log report worktree engine_label
  worker="$(status_get "$file" worker)"
  engine="$(status_get "$file" engine)"
  profile="$(status_get "$file" profile)"
  model="$(status_get "$file" model)"
  role="$(status_get "$file" role)"
  title="$(status_get "$file" title)"
  task="$(status_get "$file" task)"
  log="$(status_get "$file" log)"
  report="$(status_get "$file" report)"
  worktree="$(status_get "$file" worktree)"
  engine_label="$engine"
  [[ "$engine" == codex && -n "$profile" ]] && engine_label="codex ($profile)"
  [[ "$engine" != codex && -n "$model" ]] && engine_label="$engine ($model)"

  printf '%s%s%s · %s · role %s\n' "$bold" "$worker" "$reset" "$engine_label" "${role:-dev}"
  printf '%sTask:%s %s\n' "$dim" "$reset" "${title:0:$(( $(terminal_columns) - 7 ))}"
  squad_worker_model_label "$file"; printf '\n'
  [[ -n "$worktree" ]] && printf '%sBranch:%s squad/%s (isolated worktree)\n' "$dim" "$reset" "$worker"
  rule
  printf '%s in %s\n' "$(state_label "$(effective_state "$file")" "$(status_get "$file" reason)" "$(status_get "$file" exit)")" "$(format_duration "$(elapsed_seconds "$file")")"
  if (( once == 0 )) && [[ -n "${SQUAD_WORKER_MONITOR_READY:-}" ]]; then
    printf '%s\n' "$$" >"$SQUAD_WORKER_MONITOR_READY"
  fi

  local printed=0 last_size=-1 size summary="" running_command="" state
  local calls="" failures="" files="" tokens_in="" tokens_cached="" tokens_out="" turns=""
  local status_shown=0 line index model_label last_model_label
  last_model_label="$(squad_worker_model_label "$file")"
  while true; do
    model_label="$(squad_worker_model_label "$file")"
    if [[ "$model_label" != "$last_model_label" ]]; then
      (( status_shown == 1 )) && printf '%s' "$clear_line" && status_shown=0
      printf '%s\n' "$model_label"
      last_model_label="$model_label"
    fi
    state="$(effective_state "$file")"
    size="$(file_size "$log")"
    if [[ "$size" != "$last_size" || "$state" != running ]]; then
      last_size="$size"
      summary="$(summarise_log "$log" "$engine")"
      IFS=$'\t' read -r calls failures files tokens_in tokens_cached tokens_out turns <<<"${summary%%$'\n'*}" || true
      running_command=""
      index=0
      while IFS= read -r line; do
        index=$(( index + 1 ))
        (( index == 1 )) && continue
        if [[ "$line" == "… running: "* ]]; then
          running_command="${line#… running: }"
          continue
        fi
        if (( index - 1 > printed )); then
          (( status_shown == 1 )) && printf '%s' "$clear_line" && status_shown=0
          print_activity "$line"
          printed=$(( index - 1 ))
        fi
      done <<<"$summary"
    fi
    if [[ "$state" != running ]] || (( once == 1 )); then
      break
    fi
    local status_text
    status_text="● RUNNING $(format_duration "$(elapsed_seconds "$file")") · $(metrics_label "$engine" running \
      "$calls" "$failures" "$files" "$turns" "$tokens_in" "$tokens_cached" "$tokens_out")"
    [[ -n "$running_command" ]] && status_text+=" · … $running_command"
    status_text="${status_text:0:$(( $(terminal_columns) - 1 ))}"
    printf '%s%s%s%s' "$clear_line" "$yellow" "$status_text" "$reset"
    status_shown=1
    sleep 1
  done
  (( status_shown == 1 )) && printf '%s' "$clear_line"

  rule
  printf '%s in %s · %s\n' "$(state_label "$state" "$(status_get "$file" reason)" "$(status_get "$file" exit)")" \
    "$(format_duration "$(elapsed_seconds "$file")")" \
    "$(metrics_label "$engine" "$state" "$calls" "$failures" "$files" "$turns" "$tokens_in" "$tokens_cached" "$tokens_out")"
  if [[ "$state" == running ]]; then
    return 0
  fi
  if [[ "$state" == completed && -n "$worktree" && -d "$worktree" ]]; then
    printf '%sMerge:%s squad-worker --merge %s %s(or --discard %s)%s\n' "$dim" "$reset" "$worker" "$dim" "$worker" "$reset"
  fi
  if [[ -s "$report" ]]; then
    rule
    head -n "${SQUAD_MONITOR_REPORT_LINES:-15}" "$report"
  elif [[ "$state" != completed ]]; then
    printf '%sLog:%s %s\n' "$dim" "$reset" "$log"
  fi
  [[ -n "$task" ]] && printf '%stask %s%s\n' "$dim" "$task" "$reset"
  return 0
}

# One native directory scan imports changed legacy files; one query reads all runs.
# A failed supported query is visible, then the legacy view remains available.
indexed_runs() {
  local directory="$1" workspace
  command -v jq >/dev/null 2>&1 && squad_supports run || return 1
  [[ -d "$directory" ]] || return 1
  directory="$(cd "$directory" && pwd -P)" || return 1
  workspace="$(dirname "$(dirname "$directory")")"
  [[ -d "$workspace/.squad" ]] || return 1
  squad run list --json --workspace "$workspace" --directory "$directory" "${@:2}"
}

render_indexed() {
  local rows="$1" columns="$2" worker engine role state started finished pid tokens title profile requested model_source actual tier calls
  local elapsed now
  now="$(date +%s)"
  while IFS='|' read -r worker engine role state started finished pid tokens title profile requested model_source actual tier calls; do
    [[ -n "$worker" ]] || continue
    if [[ "$state" == running && -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; then state=lost; fi
    elapsed=$(( ${finished:-$now} - ${started:-$now} ))
    [[ "$engine" == codex && -n "$profile" ]] && engine="codex/$profile"
    frame+="$(printf '%-12s %-14s %-10s %-13s %8s %8s %12s  %s' \
      "$worker" "$engine" "$role" "$state" "$(format_duration "$elapsed")" "${calls:-0}" \
      "$([[ "$tokens" == null ]] && printf '-' || format_count "$tokens")" \
      "${title:0:$(( columns > 90 ? columns - 90 : 10 ))}")"$'\n'
    frame+="requested=${requested:-default} source=${model_source:-unknown} actual=${actual:-unknown}"
    [[ -z "$tier" ]] || frame+=" tier=$tier"
    [[ -z "$profile" ]] || frame+=" profile=$profile"
    frame+=$'\n'
    found=1
  done < <(printf '%s' "$rows" | jq -r '.[] | [ .worker_id, .engine, .details.role, .state,
    .details.started, .details.finished, .details.pid,
    (if (.metrics.tokens_in // .tokens_in) == null and (.metrics.tokens_out // .tokens_out) == null then "null" else ((.metrics.tokens_in // .tokens_in // 0) + (.metrics.tokens_out // .tokens_out // 0) | tostring) end),
    .details.title, .details.profile, (.details.requested_model // .details.model), .details.model_source, .details.actual_model, .details.model_tier, (.metrics.calls // 0) ]
    | map((. // "") | tostring | gsub("[|\\r\\n]"; " ")) | join("|")')
}

# Redraws the table in place (cursor home, clear each line) inside a
# synchronized update, so the dashboard never flashes.
render_all() {
  local directory="$1" columns frame="" file found=0 rows
  columns="$(terminal_columns)"
  frame+="$(printf '%s%-12s %-14s %-10s %-13s %8s %8s %12s  %s%s' "$bold" \
    WORKER ENGINE ROLE STATE ELAPSED CALLS TOKENS TASK "$reset")"$'\n'
  if rows="$(indexed_runs "$directory" --metrics)"; then
    render_indexed "$rows" "$columns"
  else
    while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    found=1
    local engine profile state metrics calls tokens_in tokens_out tokens="-"
    engine="$(status_get "$file" engine)"
    profile="$(status_get "$file" profile)"
    state="$(effective_state "$file")"
    metrics="$(summarise_log "$(status_get "$file" log)" "$engine")"
    metrics="${metrics%%$'\n'*}"
    IFS=$'\t' read -r calls _ _ tokens_in _ tokens_out _ <<<"$metrics" || true
    [[ "$engine" == codex && -n "$profile" ]] && engine="codex/$profile"
    [[ -n "$tokens_in$tokens_out" ]] && tokens="$(format_count $(( ${tokens_in:-0} + ${tokens_out:-0} )))"
    frame+="$(printf '%-12s %-14s %-10s %-13s %8s %8s %12s  %s' \
      "$(status_get "$file" worker)" "$engine" "$(status_get "$file" role)" "$state" \
      "$(format_duration "$(elapsed_seconds "$file")")" "${calls:-0}" "$tokens" \
      "$(status_get "$file" title | cut -c1-$(( columns > 90 ? columns - 90 : 10 )))")"$'\n'
    frame+="$(squad_worker_model_label "$file")"$'\n'
    done < <(ls -t "$directory"/*.status 2>/dev/null)
  fi
  (( found == 1 )) || frame+="No worker runs in $directory yet."$'\n'
  if (( once == 1 )) || [[ ! -t 1 ]]; then
    printf '%s' "$frame"
    return 0
  fi
  printf '\033[?2026h\033[H%s\033[J\033[?2026l' "${frame//$'\n'/$'\033[K\n'}"
}

# One status-line label: running workers and tokens offloaded from Claude.
print_savings() {
  local directory="$1/.squad/workers"
  local since="${SQUAD_DEVKIT_SESSION_START:-0}"
  local running=0 offloaded=0 claude_tokens=0 runs=0 file engine started total tokens_in tokens_out
  local rows indexed_state indexed_pid indexed_engine indexed_total
  if rows="$(indexed_runs "$directory")"; then
    while IFS='|' read -r indexed_state indexed_pid indexed_engine indexed_total; do
      [[ -n "$indexed_state" ]] || continue
      runs=$(( runs + 1 ))
      if [[ "$indexed_state" == running ]]; then
        if [[ -z "$indexed_pid" ]] || kill -0 "$indexed_pid" 2>/dev/null; then running=$(( running + 1 )); fi
      fi
      if [[ "$indexed_engine" == claude ]]; then claude_tokens=$(( claude_tokens + indexed_total ));
      else offloaded=$(( offloaded + indexed_total )); fi
    done < <(printf '%s' "$rows" | jq -r --argjson since "$since" '.[] | select((.details.started // "0" | if . == "" then "0" else . end | tonumber) >= $since)
      | [.state, .details.pid, .engine, ((.tokens_in // 0) + (.tokens_out // 0))]
      | map((. // "") | tostring | gsub("[|\\r\\n]"; " ")) | join("|")')
  else
    for file in "$directory"/*.status; do
    [[ -f "$file" ]] || continue
    started="$(status_get "$file" started)"
    (( ${started:-0} >= since )) || continue
    runs=$(( runs + 1 ))
    [[ "$(effective_state "$file")" == running ]] && running=$(( running + 1 ))
    engine="$(status_get "$file" engine)"
    tokens_in="$(status_get "$file" tokens_in)"
    tokens_out="$(status_get "$file" tokens_out)"
    total=$(( ${tokens_in:-0} + ${tokens_out:-0} ))
    if [[ "$engine" == claude ]]; then
      claude_tokens=$(( claude_tokens + total ))
    else
      offloaded=$(( offloaded + total ))
    fi
    done
  fi
  local label="squad"
  if (( runs == 0 )); then
    label+=" idle"
  else
    (( running > 0 )) && label+=" ${running} running ·"
    label+=" saved $(human_count "$offloaded") tok"
    (( claude_tokens > 0 )) && label+=" · claude workers $(human_count "$claude_tokens")"
  fi
  if (( text == 1 )); then
    printf '%s\n' "$label"
  else
    printf '{"label":"%s"}\n' "$label"
  fi
}

if (( savings == 1 )); then
  print_savings "${all_directory:-.}"
  exit 0
fi

if (( all == 1 )); then
  directory="${all_directory:-.squad/workers}"
  if (( once == 0 )) && [[ -t 1 ]]; then
    printf '\033[?25l\033[2J'
    trap 'printf "\033[?25h"' EXIT
    trap 'exit 0' INT TERM
  fi
  while true; do
    render_all "$directory"
    (( once == 1 )) && exit 0
    sleep 2
  done
fi

if [[ -z "$status_file" ]]; then
  usage >&2
  exit 2
fi
for _ in $(seq 1 20); do
  [[ -f "$status_file" ]] && break
  sleep 0.25
done
# Start from a clean pane (some terminals echo the command that opened it);
# this is the only full clear, so nothing flickers afterwards.
if (( once == 0 )) && [[ -t 1 ]]; then
  printf '\033[H\033[2J'
fi
watch_run "$status_file"
(( once == 1 )) && exit 0
hold="${SQUAD_WORKER_PANE_HOLD:-}"
if [[ "$hold" =~ ^[0-9]+$ ]]; then
  for (( remaining = hold; remaining > 0; remaining-- )); do
    printf '%s%sClosing in %ds · press Enter to close now%s' "$clear_line" "$dim" "$remaining" "$reset"
    read -r -t 1 _ 2>/dev/null && break
  done
  printf '%s' "$clear_line"
else
  printf '\n%sPress Enter to close this pane.%s' "$dim" "$reset"
  read -r _ || true
fi
