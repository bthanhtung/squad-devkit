#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: squad-worker-monitor <status-file> [--once]
       squad-worker-monitor --all [directory] [--once]

Show one squad-worker run live: state, elapsed time, commands or tool calls,
failures, changed files, tokens, and recent activity. squad-worker opens this
in a split pane next to the manager. With --all, show a table of every run in
.squad/workers (or the given directory), refreshed every two seconds.
--once prints a single frame and exits.

Environment: SQUAD_WORKER_PANE_HOLD=N closes a finished run's pane after N
seconds (default: wait for Enter).
EOF
}

status_file=""
all=0
all_directory=""
once=0
while (( $# > 0 )); do
  case "$1" in
    --all) all=1 ;;
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
        ([$done[] | select(.type == "command_execution")] | length) + ($tools | length),
        ([$done[] | select(.type == "command_execution" and .exit_code != 0)] | length) + ($tool_errors | length),
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

render_run() {
  local file="$1"
  local rows="${LINES:-$(tput lines 2>/dev/null || echo 30)}"
  local columns="${COLUMNS:-$(tput cols 2>/dev/null || echo 100)}"
  local worker engine profile role title task state log report exit_status
  worker="$(status_get "$file" worker)"
  engine="$(status_get "$file" engine)"
  profile="$(status_get "$file" profile)"
  role="$(status_get "$file" role)"
  title="$(status_get "$file" title)"
  task="$(status_get "$file" task)"
  state="$(status_get "$file" state)"
  log="$(status_get "$file" log)"
  report="$(status_get "$file" report)"
  exit_status="$(status_get "$file" exit)"
  local summary metrics
  summary="$(summarise_log "$log")"
  metrics="$(printf '%s\n' "$summary" | head -n 1)"
  local calls failures files tokens_in tokens_cached tokens_out turns
  IFS=$'\t' read -r calls failures files tokens_in tokens_cached tokens_out turns <<<"$metrics" || true

  local engine_label="$engine"
  [[ "$engine" == codex && -n "$profile" ]] && engine_label="codex ($profile)"
  local state_label
  case "$state" in
    running) state_label="● RUNNING" ;;
    completed) state_label="✓ COMPLETED" ;;
    failed) state_label="✗ FAILED (exit ${exit_status:-?})" ;;
    *) state_label="${state:-?}" ;;
  esac
  local call_label="Commands"
  [[ "$engine" == ccr ]] && call_label="Tool calls"
  local token_label="pending"
  if [[ -n "$tokens_in$tokens_out" ]]; then
    token_label="in $(format_count "${tokens_in:-0}")"
    [[ -n "$tokens_cached" && "$tokens_cached" != 0 ]] && token_label+=" (cached $(format_count "$tokens_cached"))"
    token_label+=" · out $(format_count "${tokens_out:-0}")"
  elif [[ "$state" != running ]]; then
    token_label="n/a"
  fi
  if [[ "$engine" == ccr && "${tokens_in:-0}" == 0 && "${tokens_out:-0}" == 0 && "$state" != running ]]; then
    token_label="not reported by the router"
  fi

  printf '\033[H\033[2J'
  printf '\033[1m%s\033[0m · %s · role %s · %s · %s\n' \
    "$worker" "$engine_label" "${role:-dev}" "$state_label" "$(format_duration "$(elapsed_seconds "$file")")"
  printf 'Task: %s\n' "$(printf '%s' "$title" | cut -c1-$((columns - 6)))"
  printf '%s: %s · failed: %s · files changed: %s%s\n' \
    "$call_label" "${calls:-0}" "${failures:-0}" "${files:-0}" "${turns:+ · turns: $turns}"
  printf 'Tokens: %s\n' "$token_label"
  printf '%*s\n' "$columns" '' | tr ' ' '─'
  local body_rows=$(( rows - 8 ))
  (( body_rows < 3 )) && body_rows=3
  if [[ "$state" == running ]]; then
    printf '%s\n' "$summary" | tail -n +2 | tail -n "$body_rows" | cut -c1-"$columns"
  else
    printf '%s\n' "$summary" | tail -n +2 | tail -n $(( body_rows / 2 )) | cut -c1-"$columns"
    printf '%*s\n' "$columns" '' | tr ' ' '─'
    if [[ -s "$report" ]]; then
      head -n $(( body_rows / 2 - 1 )) "$report" | cut -c1-"$columns"
    else
      printf 'No report. Log: %s\n' "$log"
    fi
  fi
  [[ -n "$task" ]] && printf '\033[2mtask %s\033[0m\n' "$task"
  return 0
}

render_all() {
  local directory="$1"
  local columns="${COLUMNS:-$(tput cols 2>/dev/null || echo 100)}"
  printf '\033[H\033[2J'
  printf '\033[1m%-12s %-14s %-10s %-13s %8s %8s %12s  %s\033[0m\n' \
    WORKER ENGINE ROLE STATE ELAPSED CALLS TOKENS TASK
  local file found=0
  for file in $(ls -t "$directory"/*.status 2>/dev/null); do
    found=1
    local engine profile state metrics calls tokens_in tokens_out
    engine="$(status_get "$file" engine)"
    profile="$(status_get "$file" profile)"
    state="$(status_get "$file" state)"
    metrics="$(summarise_log "$(status_get "$file" log)" | head -n 1)"
    IFS=$'\t' read -r calls _ _ tokens_in _ tokens_out _ <<<"$metrics" || true
    [[ "$engine" == codex && -n "$profile" ]] && engine="codex/$profile"
    local tokens="-"
    [[ -n "$tokens_in$tokens_out" ]] && tokens="$(format_count $(( ${tokens_in:-0} + ${tokens_out:-0} )))"
    printf '%-12s %-14s %-10s %-13s %8s %8s %12s  %s\n' \
      "$(status_get "$file" worker)" "$engine" "$(status_get "$file" role)" "$state" \
      "$(format_duration "$(elapsed_seconds "$file")")" "${calls:-0}" "$tokens" \
      "$(status_get "$file" title | cut -c1-$(( columns > 90 ? columns - 90 : 10 )))"
  done
  (( found == 1 )) || printf 'No worker runs in %s yet.\n' "$directory"
  return 0
}

if (( all == 1 )); then
  directory="${all_directory:-.squad/workers}"
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
for attempt in $(seq 1 20); do
  [[ -f "$status_file" ]] && break
  sleep 0.25
done
while true; do
  render_run "$status_file"
  (( once == 1 )) && exit 0
  [[ "$(status_get "$status_file" state)" == running ]] || break
  sleep 1
done
if [[ -n "${SQUAD_WORKER_PANE_HOLD:-}" ]]; then
  sleep "$SQUAD_WORKER_PANE_HOLD"
else
  printf '\nPress Enter to close this pane.'
  read -r _ || true
fi
