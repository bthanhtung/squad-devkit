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

# Summarises a codex --json or claude stream-json log as tab-separated
# metrics on the first line, then one activity line per event.
summarise_log() {
  local log="$1"
  local root="${log%/.squad/workers/*}/"
  if [[ ! -s "$log" ]] || ! command -v jq >/dev/null 2>&1; then
    printf '\t\t\t\t\t\t\n'
    [[ -s "$log" ]] && tail -n 40 "$log"
    return 0
  fi
  jq -R -r -s --arg root "$root" '
    def short: tostring | split($root) | join("") | gsub("[\r\n]+"; " ") | .[0:160];
    def cmd: tostring | sub("^/bin/(ba|z)?sh -l?c "; "") | short;
    [split("\n")[] | fromjson? | select(type == "object")] as $events
    | [$events[] | select(.type == "item.completed") | .item] as $done
    | [$events[] | select(.type == "item.started") | .item] as $started
    | ([$done[] | .id]) as $done_ids
    | [$events[] | select(.type == "assistant") | .message.content[]? | select(.type == "tool_use")] as $tools
    | [$events[] | select(.type == "user") | .message.content[]? | select(.type == "tool_result" and .is_error == true)] as $tool_errors
    | ([$events[] | select(.type == "turn.completed") | .usage]
       + [$events[] | select(.type == "result") | .usage | select(. != null)]) as $usage
    | [
        ([$done[] | select(.type == "command_execution" or .type == "mcp_tool_call")] | length) + ($tools | length),
        ([$done[] | select((.type == "command_execution" and .exit_code != 0) or (.type == "mcp_tool_call" and .status != "completed"))] | length) + ($tool_errors | length),
        ([$done[] | select(.type == "file_change") | .changes[]?] | length)
          + ([$tools[] | select(.name == "Edit" or .name == "Write")] | length),
        ([$usage[] | (.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0)] | add // ""),
        ([$usage[] | (.cached_input_tokens // .cache_read_input_tokens // 0)] | add // ""),
        ([$usage[] | .output_tokens // 0] | add // ""),
        ([$events[] | select(.type == "result") | .num_turns] | last // "")
      ] | map(tostring) | join("\t"),
    ( $events[]
      | if .type == "item.completed" then .item
          | if .type == "command_execution" then
              (if .exit_code == 0 then "✓ " else "✗ " end) + (.command | cmd) + (if .exit_code == 0 then "" else "  (exit \(.exit_code))" end)
            elif .type == "mcp_tool_call" then
              (if .status == "completed" then "⚙ " else "✗ " end) + "\(.server)/\(.tool)"
            elif .type == "file_change" then "✎ " + ([.changes[]? | .path] | join(", ") | short)
            elif .type == "agent_message" then "» " + (.text | short)
            elif .type == "error" then "! " + (.message | short)
            else empty end
        elif .type == "assistant" then .message.content[]?
          | if .type == "tool_use" then
              "→ " + .name + " " + ((.input.file_path // .input.path // .input.pattern // .input.command // "") | short)
            elif .type == "text" and (.text | length) > 0 then "» " + (.text | short)
            else empty end
        elif .type == "user" then .message.content[]?
          | select(.type == "tool_result" and .is_error == true) | "✗ tool error: " + (.content | short)
        else empty end ),
    ( [$started[] | select(.type == "command_execution") | select(.id as $id | $done_ids | index($id) | not)]
      | last | select(. != null) | "… running: " + (.command | cmd) )
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
print_activity() {
  local line="$1" width color=""
  width=$(( $(terminal_columns) - 1 ))
  case "$line" in
    "✓ "*) color="$green" ;;
    "✗ "*) color="$red" ;;
    "! "*) color="$yellow" ;;
    "⚙ "*|"→ "*|"✎ "*) color="$cyan" ;;
  esac
  printf '%s%s%s\n' "$color" "${line:0:$width}" "$reset"
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
  [[ -n "$worktree" ]] && printf '%sBranch:%s squad/%s (isolated worktree)\n' "$dim" "$reset" "$worker"
  rule

  local printed=0 last_size=-1 size summary="" running_command="" state
  local calls="" failures="" files="" tokens_in="" tokens_cached="" tokens_out="" turns=""
  local status_shown=0 line index
  while true; do
    state="$(effective_state "$file")"
    size="$(file_size "$log")"
    if [[ "$size" != "$last_size" || "$state" != running ]]; then
      last_size="$size"
      summary="$(summarise_log "$log")"
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

# Redraws the table in place (cursor home, clear each line) inside a
# synchronized update, so the dashboard never flashes.
render_all() {
  local directory="$1" columns frame="" file found=0
  columns="$(terminal_columns)"
  frame+="$(printf '%s%-12s %-14s %-10s %-13s %8s %8s %12s  %s%s' "$bold" \
    WORKER ENGINE ROLE STATE ELAPSED CALLS TOKENS TASK "$reset")"$'\n'
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    found=1
    local engine profile state metrics calls tokens_in tokens_out tokens="-"
    engine="$(status_get "$file" engine)"
    profile="$(status_get "$file" profile)"
    state="$(effective_state "$file")"
    metrics="$(summarise_log "$(status_get "$file" log)")"
    metrics="${metrics%%$'\n'*}"
    IFS=$'\t' read -r calls _ _ tokens_in _ tokens_out _ <<<"$metrics" || true
    [[ "$engine" == codex && -n "$profile" ]] && engine="codex/$profile"
    [[ -n "$tokens_in$tokens_out" ]] && tokens="$(format_count $(( ${tokens_in:-0} + ${tokens_out:-0} )))"
    frame+="$(printf '%-12s %-14s %-10s %-13s %8s %8s %12s  %s' \
      "$(status_get "$file" worker)" "$engine" "$(status_get "$file" role)" "$state" \
      "$(format_duration "$(elapsed_seconds "$file")")" "${calls:-0}" "$tokens" \
      "$(status_get "$file" title | cut -c1-$(( columns > 90 ? columns - 90 : 10 )))")"$'\n'
  done < <(ls -t "$directory"/*.status 2>/dev/null)
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
