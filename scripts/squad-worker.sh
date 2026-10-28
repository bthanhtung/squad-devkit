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

usage() {
  cat <<'EOF'
Usage: squad-worker <worker-id> --engine ENGINE (--brief TEXT | --brief-file FILE)
                    [--role ROLE] [--title TITLE] [--project DIR]
                    [--profile PROFILE] [--model MODEL] [--mcp NAME]... [--all-mcp]
                    [--timeout MINUTES] [--manager ID]
       squad-worker --list
       squad-worker --stop <worker-id|all>

Run one on-demand worker for the squad manager, then exit. The worker joins the
squad, receives a structured task from the manager, works non-interactively,
completes the task with its report, and leaves. The report is printed on
stdout and saved under .squad/workers/ in the manager's squad workspace
(SQUAD_DEVKIT_WORKSPACE, or the nearest directory with .squad/ above here).

Engines, most trusted first:
  claude   Claude Code (your Anthropic plan; --model haiku by default,
           sonnet for complex or high-risk work, opus for the hardest)
  codex    codex exec, sandboxed to the project (--profile, default: high)
  grok     Grok Build headless (experimental)
  agy      Antigravity CLI headless (experimental)
  ccr      Claude Code through claude-code-router: cheap model, file tools only

Options:
  --role ROLE        Role prompt from .squad/roles/ROLE.md (default: dev)
  --title TITLE      Task title (default: first line of the brief)
  --brief-file -     Read the brief from stdin
  --project DIR      Directory the worker works in (default: the squad workspace)
  --profile NAME     codex profile (default: high)
  --model NAME       Model for claude, grok, or agy
  --mcp NAME         codex only: keep this MCP server enabled (repeatable);
                     all others are disabled to keep the worker's context small
  --all-mcp          codex only: keep every configured MCP server
  --timeout MINUTES  Stop the run after this long (default 45)
  --manager ID       Manager agent ID that owns the task (default: manager)
  --list             Show worker runs that are still running
  --stop ID|all      Stop a running worker (or all of them); it reports to the manager

Environment: SQUAD_WORKER_CODEX_PROFILE, SQUAD_WORKER_CLAUDE_MODEL,
SQUAD_WORKER_CLAUDE_TOOLS, SQUAD_WORKER_CLAUDE_PERMISSION_MODE (default
acceptEdits, shell sandboxed), SQUAD_WORKER_CCR_TOOLS, SQUAD_WORKER_TIMEOUT (minutes),
SQUAD_WORKER_STALL (minutes without log output before a run counts as stuck,
default 10), SQUAD_WORKER_PANES=0, SQUAD_WORKER_PANE_HOLD (seconds a finished
monitor pane stays open, default 60).
EOF
}

worker_id=""
engine=""
role="dev"
title=""
brief=""
brief_file=""
profile="${SQUAD_WORKER_CODEX_PROFILE:-high}"
model=""
manager_id="${SQUAD_MANAGER_ID:-manager}"
project_directory=""
timeout_minutes="${SQUAD_WORKER_TIMEOUT:-45}"
stall_minutes="${SQUAD_WORKER_STALL:-10}"
keep_mcp=()
all_mcp=0
action=run
stop_target=""
while (( $# > 0 )); do
  case "$1" in
    --engine|--role|--title|--brief|--brief-file|--profile|--model|--mcp|--manager|--project|--timeout|--stop)
      if (( $# < 2 )) || [[ -z "$2" ]]; then
        echo "Missing value for $1" >&2
        exit 2
      fi
      case "$1" in
        --engine) engine="$2" ;;
        --role) role="$2" ;;
        --title) title="$2" ;;
        --brief) brief="$2" ;;
        --brief-file) brief_file="$2" ;;
        --profile) profile="$2" ;;
        --model) model="$2" ;;
        --mcp) keep_mcp+=("$2") ;;
        --manager) manager_id="$2" ;;
        --project) project_directory="$2" ;;
        --timeout) timeout_minutes="$2" ;;
        --stop) action=stop; stop_target="$2" ;;
      esac
      shift
      ;;
    --all-mcp) all_mcp=1 ;;
    --list) action=list ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)
      if [[ -n "$worker_id" ]]; then
        echo "Only one worker ID is allowed" >&2
        exit 2
      fi
      worker_id="$1"
      ;;
  esac
  shift
done

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing command: $1" >&2
    exit 1
  fi
}

find_workspace() {
  if [[ -n "${SQUAD_DEVKIT_WORKSPACE:-}" && -d "$SQUAD_DEVKIT_WORKSPACE/.squad" ]]; then
    (cd "$SQUAD_DEVKIT_WORKSPACE" && pwd)
    return 0
  fi
  local directory="$PWD"
  while [[ ! -d "$directory/.squad" ]]; do
    if [[ "$directory" == / ]]; then
      echo "No .squad/ found above $PWD; run squad init or squad-devkit first" >&2
      return 1
    fi
    directory="$(dirname "$directory")"
  done
  printf '%s\n' "$directory"
}

status_get() {
  sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -n 1
}

# Status files of runs that are still running, newest first.
running_status_files() {
  local file
  while IFS= read -r file; do
    [[ "$(status_get "$file" state)" == running ]] && printf '%s\n' "$file"
  done < <(ls -t .squad/workers/*.status 2>/dev/null)
  return 0
}

if [[ "$action" == list || "$action" == stop ]]; then
  require_command squad
  workspace_root="$(find_workspace)"
  cd "$workspace_root"
  found=0
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    id="$(status_get "$file" worker)"
    pid="$(status_get "$file" pid)"
    if [[ "$action" == list ]]; then
      printf '%-12s %-7s %-10s pid %-7s %s\n' "$id" "$(status_get "$file" engine)" \
        "$(status_get "$file" role)" "${pid:-?}" "$(status_get "$file" title)"
      found=1
    elif [[ "$stop_target" == all || "$stop_target" == "$id" ]]; then
      if [[ -n "$pid" ]] && kill -TERM "$pid" 2>/dev/null; then
        echo "Stopping $id (pid $pid)."
      else
        printf 'state=lost\n' >>"$file"
        echo "$id was not running any more; marked lost."
      fi
      found=1
    fi
  done < <(running_status_files)
  if (( found == 0 )); then
    if [[ "$action" == list ]]; then
      echo "No running workers."
    else
      echo "No running worker matches $stop_target."
    fi
  fi
  exit 0
fi

if [[ -z "$worker_id" || -z "$engine" ]]; then
  usage >&2
  exit 2
fi
case "$engine" in
  claude|codex|grok|agy|ccr) ;;
  *) echo "Unknown engine: $engine (use claude, codex, grok, agy, or ccr)" >&2; exit 2 ;;
esac
if [[ ! "$timeout_minutes" =~ ^[0-9]+$ || ! "$stall_minutes" =~ ^[0-9]+$ ]]; then
  echo "--timeout and SQUAD_WORKER_STALL take whole minutes" >&2
  exit 2
fi
if [[ -n "$brief_file" ]]; then
  if [[ "$brief_file" == - ]]; then
    brief="$(cat)"
  else
    brief="$(cat "$brief_file")"
  fi
fi
if [[ -z "${brief//[[:space:]]/}" ]]; then
  echo "The brief is empty; pass --brief or --brief-file" >&2
  exit 2
fi
if [[ -z "$title" ]]; then
  title="$(printf '%s\n' "$brief" | sed -n '/[^[:space:]]/{p;q;}' | cut -c1-80)"
fi

require_command squad
require_command "$engine"
if [[ "$engine" == ccr ]]; then
  require_command claude
  require_command curl
fi

if [[ -n "$project_directory" ]]; then
  if [[ ! -d "$project_directory" ]]; then
    echo "Project directory does not exist: $project_directory" >&2
    exit 2
  fi
  project_directory="$(cd "$project_directory" && pwd)"
fi
workspace_root="$(find_workspace)"
# squad commands run in the squad workspace; the engine runs in the project,
# which defaults to the workspace itself.
project_directory="${project_directory:-$workspace_root}"
cd "$workspace_root"

client=codex
[[ "$engine" == claude || "$engine" == ccr ]] && client=claude
join_output="$(squad join "$worker_id" --role "$role" --client "$client" --protocol-version 2)"
joined_id="$(printf '%s\n' "$join_output" | sed -n 's/.*Joined as \([^ ]*\) (role:.*/\1/p' | head -1)"
if [[ -z "$joined_id" ]]; then
  printf '%s\n' "$join_output" >&2
  echo "Could not join the squad as $worker_id" >&2
  exit 1
fi
worker_id="$joined_id"

status_file=""
engine_pid=""
stop_reason=""
finish_run() {
  local exit_status=$?
  if [[ -n "$engine_pid" ]] && kill -0 "$engine_pid" 2>/dev/null; then
    pkill -TERM -P "$engine_pid" 2>/dev/null || true
    kill -TERM "$engine_pid" 2>/dev/null || true
  fi
  if [[ -n "$status_file" && -f "$status_file" ]] && grep -qx 'state=running' "$status_file"; then
    write_status failed "$exit_status"
  fi
  squad leave "$worker_id" >/dev/null 2>&1 || true
}
trap finish_run EXIT
# --stop sends TERM: stop the engine, record it, and tell the manager.
on_stop() {
  stop_reason="stopped by request"
  if [[ -n "$engine_pid" ]]; then
    pkill -TERM -P "$engine_pid" 2>/dev/null || true
    kill -TERM "$engine_pid" 2>/dev/null || true
  else
    exit 143
  fi
}
trap on_stop TERM INT

create_output="$(squad task create "$manager_id" "$worker_id" --title "$title" --body "$brief")"
task_id="$(printf '%s\n' "$create_output" | sed -n 's/^Created task \([^ ]*\) for .*/\1/p')"
if [[ -z "$task_id" ]]; then
  printf '%s\n' "$create_output" >&2
  echo "Could not create the task for $worker_id" >&2
  exit 1
fi
squad task ack "$worker_id" "$task_id" >/dev/null
squad receive "$worker_id" >/dev/null || true

role_instructions=""
if [[ -f ".squad/roles/$role.md" ]]; then
  role_instructions="$(grep -v '^<!-- squad-devkit template' ".squad/roles/$role.md")"
fi
ask_command="$(printf '%q --from %q --workspace %q' "$script_dir/squad-ask.sh" "$worker_id" "$workspace_root")"
if [[ "$engine" == ccr ]]; then
  questions="- You have no shell, so you cannot ask questions: decide within the brief and list your assumptions in the report."
else
  questions="- If the brief is ambiguous or you find a better technical approach, ask before guessing: \`$ask_command --to $manager_id \"your question\"\` waits for the answer (up to 5 minutes). Ask another worker the same way (\`squad agents\` in $workspace_root lists them).
- Between major steps, run \`$ask_command --check\` and answer other workers' questions with \`$ask_command --reply <id> \"answer\"\`."
fi
prompt="You are $worker_id, a $role worker in a squad led by $manager_id. You run once, without a human at the keyboard.
${role_instructions:+
$role_instructions
}
## Task $task_id: $title

Project directory: $project_directory

$brief

## Rules
- Do only what the task asks and touch only the files it assigns you; other workers may be editing other files at the same time.
- Hold the bar of a senior engineer at a top technology company: secure by default (no secrets in code, validate input, least privilege), efficient, simple to maintain and extend, consistent with the surrounding code, and accessible, platform-consistent UI (Apple Human Interface Guidelines, Material Design) when the task has UI.
$questions
- Do not commit, push, or delete unrelated files.
- Use only the tools you were given. Never read credentials or tokens from configuration files; if a tool you need is missing, stop and report it.
- If something blocks you, stop and explain it in the report instead of guessing.
- Your final message is the report for $manager_id, at most 15 lines: result, files changed, verification you ran and its outcome, assumptions, open issues."

output_directory=".squad/workers"
mkdir -p "$output_directory"
run_name="$worker_id-$(date +%Y%m%d-%H%M%S)"
report_file="$output_directory/$run_name.md"
log_file="$output_directory/$run_name.log"
status_file="$output_directory/$run_name.status"
started_at="$(date +%s)"
run_profile=""
[[ "$engine" == codex ]] && run_profile="$profile"
if [[ "$engine" == claude ]]; then
  model="${model:-${SQUAD_WORKER_CLAUDE_MODEL:-haiku}}"
fi
tokens_in=""
tokens_cached=""
tokens_out=""

write_status() {
  local state="$1"
  local exit_status="${2:-}"
  local finished=""
  [[ "$state" != running ]] && finished="$(date +%s)"
  {
    printf 'worker=%s\nengine=%s\nprofile=%s\nmodel=%s\nrole=%s\n' \
      "$worker_id" "$engine" "$run_profile" "$model" "$role"
    printf 'title=%s\ntask=%s\nstate=%s\nreason=%s\n' \
      "$(printf '%s' "$title" | tr '\n' ' ')" "$task_id" "$state" "$stop_reason"
    printf 'pid=%s\nstarted=%s\nfinished=%s\nexit=%s\n' "$$" "$started_at" "$finished" "$exit_status"
    printf 'tokens_in=%s\ntokens_cached=%s\ntokens_out=%s\n' "$tokens_in" "$tokens_cached" "$tokens_out"
    printf 'project=%s\nlog=%s\nreport=%s\n' "$project_directory" \
      "$workspace_root/$log_file" "$workspace_root/$report_file"
  } >"$status_file.tmp"
  mv "$status_file.tmp" "$status_file"
}
write_status running

# Opens a live monitor pane for this run next to the manager: a tmux split when
# the manager runs in tmux, a Herdr split inside Herdr, or a Ghostty split when
# squad-devkit recorded the manager's Ghostty terminal. SQUAD_WORKER_PANES=0
# disables it.
open_monitor_pane() {
  [[ "${SQUAD_WORKER_PANES:-1}" != 0 ]] || return 0
  local pane_script="$output_directory/$run_name.monitor.sh"
  # Pane shells start from the terminal, not from this process, so pass settings explicitly.
  {
    printf '#!/bin/bash\n'
    printf 'export SQUAD_WORKER_PANE_HOLD=%q\n' "${SQUAD_WORKER_PANE_HOLD:-60}"
    printf 'exec %q %q\n' "$script_dir/squad-worker-monitor.sh" "$workspace_root/$status_file"
  } >"$pane_script"
  chmod +x "$pane_script"
  local title="$worker_id · $engine"
  if [[ -n "${TMUX:-}" && -n "${TMUX_PANE:-}" ]] && command -v tmux >/dev/null 2>&1; then
    local pane
    pane="$(tmux split-window -d -h -P -F '#{pane_id}' -t "$TMUX_PANE" -c "$workspace_root" \
      "$workspace_root/$pane_script" 2>/dev/null)" || return 0
    tmux select-pane -t "$pane" -T "$title" 2>/dev/null || true
    tmux select-layout -t "$TMUX_PANE" main-vertical 2>/dev/null || true
    return 0
  fi
  local backend="" manager_pane=""
  local osascript_command="${SQUAD_DEVKIT_OSASCRIPT:-osascript}"
  if [[ -n "${HERDR_PANE_ID:-}" ]] && command -v herdr >/dev/null 2>&1; then
    backend=herdr
    manager_pane="$HERDR_PANE_ID"
  elif [[ -n "${SQUAD_DEVKIT_GHOSTTY_TERMINAL:-}" ]] && command -v "$osascript_command" >/dev/null 2>&1; then
    backend=ghostty
    manager_pane="$SQUAD_DEVKIT_GHOSTTY_TERMINAL"
  else
    return 0
  fi
  # Serialise splits so parallel workers stack instead of splitting the same pane.
  local lock="$output_directory/.pane.lock"
  for _ in $(seq 1 40); do
    mkdir "$lock" 2>/dev/null && break
    sleep 0.25
  done
  local last_file="$output_directory/.$backend-${manager_pane//[^A-Za-z0-9_-]/_}.last"
  local previous=""
  [[ -f "$last_file" ]] && previous="$(cat "$last_file")"
  local created=""
  if [[ "$backend" == herdr ]]; then
    # The first worker splits right of the manager; later ones stack below the previous worker.
    local split_output=""
    if [[ -n "$previous" ]]; then
      split_output="$(herdr pane split "$previous" --direction down --cwd "$workspace_root" 2>/dev/null || true)"
    fi
    if [[ "$split_output" != *'"pane_id"'* ]]; then
      split_output="$(herdr pane split "$manager_pane" --direction right --cwd "$workspace_root" 2>/dev/null || true)"
    fi
    created="$(printf '%s' "$split_output" | sed -n 's/.*"pane_id":"\([^"]*\)".*/\1/p')"
    if [[ -n "$created" ]]; then
      herdr pane rename "$created" "$title" >/dev/null 2>&1 || true
      herdr pane run "$created" "exec $(printf '%q' "$workspace_root/$pane_script")" >/dev/null 2>&1 || true
    fi
  else
    created="$("$osascript_command" "$script_dir/lib/squad-worker-ghostty.applescript" \
      "$manager_pane" "$previous" "$workspace_root" "$workspace_root/$pane_script" "$title" 2>/dev/null || true)"
  fi
  [[ -n "$created" ]] && printf '%s\n' "$created" >"$last_file"
  rmdir "$lock" 2>/dev/null || true
  return 0
}
open_monitor_pane

ensure_ccr_server() {
  local port
  port="$(sed -n 's/.*"PORT"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' \
    "$HOME/.claude-code-router/config.json" 2>/dev/null | head -1)"
  port="${port:-3456}"
  if curl -s -o /dev/null "http://127.0.0.1:$port/"; then
    return 0
  fi
  nohup ccr start >>"$output_directory/ccr-server.log" 2>&1 &
  for _ in $(seq 1 30); do
    if curl -s -o /dev/null "http://127.0.0.1:$port/"; then
      return 0
    fi
    sleep 1
  done
  echo "claude-code-router did not start on port $port; see $output_directory/ccr-server.log" >>"$log_file"
  return 1
}

# Codex silently drops an MCP server whose bearer-token variable is unset, and
# the worker then improvises around the missing tool. Fail fast instead.
missing_mcp_tokens() {
  local mcp_json="$1" server variable
  for server in ${keep_mcp[@]+"${keep_mcp[@]}"}; do
    variable="$(printf '%s' "$mcp_json" | jq -r --arg name "$server" \
      '.[] | select(.name == $name) | .transport.bearer_token_env_var // empty' 2>/dev/null || true)"
    if [[ -n "$variable" && -z "${!variable:-}" ]]; then
      printf '%s (needs %s)\n' "$server" "$variable"
    fi
  done
}

# Each engine reads the prompt and writes its final report to $report_file and
# its activity (JSON events where the engine supports them) to $log_file.
absolute_report="$workspace_root/$report_file"
absolute_log="$workspace_root/$log_file"
streams_log=1
engine_command=()
status=0
case "$engine" in
  codex)
    mcp_json="$(codex mcp list --json 2>/dev/null || true)"
    missing=""
    if command -v jq >/dev/null 2>&1; then
      missing="$(missing_mcp_tokens "$mcp_json")"
    fi
    if [[ -n "$missing" ]]; then
      {
        echo "MCP servers requested with --mcp are missing their token environment variables:"
        printf '%s\n' "$missing" | sed 's/^/  /'
        echo "Export them in the shell that starts the manager (for example from ~/.zshrc)."
      } | tee -a "$log_file" >&2
      status=3
    fi
    mcp_arguments=()
    if (( all_mcp == 0 )); then
      configured_servers="$(printf '%s\n' "$mcp_json" |
        sed -n 's/^    "name": "\([^"]*\)",$/\1/p' || true)"
      while IFS= read -r server; do
        [[ -n "$server" ]] || continue
        if [[ " ${keep_mcp[*]:-} " == *" $server "* ]]; then
          continue
        fi
        mcp_arguments+=(-c "mcp_servers.$server.enabled=false")
      done <<<"$configured_servers"
    fi
    add_directory=()
    [[ "$project_directory" != "$workspace_root" ]] && add_directory=(--add-dir "$workspace_root")
    engine_command=(codex exec --json --cd "$project_directory" --profile "$profile" --ephemeral
      --skip-git-repo-check --sandbox workspace-write ${add_directory[@]+"${add_directory[@]}"}
      ${mcp_arguments[@]+"${mcp_arguments[@]}"} --output-last-message "$absolute_report" "$prompt")
    ;;
  claude)
    # Six core tools keep the prompt small. Edits are accepted in the project;
    # shell commands run only inside Claude Code's sandbox, and are denied
    # (and reported) where the sandbox is unavailable.
    engine_command=(claude -p --model "$model" --strict-mcp-config --disable-slash-commands
      --no-session-persistence --tools "${SQUAD_WORKER_CLAUDE_TOOLS:-Read,Edit,Write,Glob,Grep,Bash}"
      --permission-mode "${SQUAD_WORKER_CLAUDE_PERMISSION_MODE:-acceptEdits}"
      --settings '{"sandbox":{"enabled":true,"autoAllowBashIfSandboxed":true}}'
      --add-dir "$workspace_root" --output-format stream-json --verbose "$prompt")
    ;;
  ccr)
    tools="${SQUAD_WORKER_CCR_TOOLS:-Read,Edit,Write,Glob,Grep}"
    ensure_ccr_server || status=1
    engine_command=(claude -p --strict-mcp-config --disable-slash-commands --no-session-persistence
      --tools "$tools" --allowedTools "$tools" --permission-mode acceptEdits
      --output-format stream-json --verbose "$prompt")
    ;;
  grok)
    streams_log=0
    engine_command=(grok -p "$prompt" --always-approve --cwd "$project_directory")
    [[ -n "$model" ]] && engine_command+=(--model "$model")
    ;;
  agy)
    streams_log=0
    engine_command=(agy -p "$prompt" --mode accept-edits)
    [[ -n "$model" ]] && engine_command+=(--model "$model")
    ;;
esac

run_engine() {
  cd "$project_directory"
  unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT
  case "$engine" in
    ccr)
      eval "$(ccr activate)"
      "${engine_command[@]}" </dev/null >"$absolute_log" 2>&1
      jq -R -r 'fromjson? | select(.type == "result") | .result // empty' "$absolute_log" >"$absolute_report"
      ;;
    claude)
      "${engine_command[@]}" </dev/null >"$absolute_log" 2>&1
      jq -R -r 'fromjson? | select(.type == "result") | .result // empty' "$absolute_log" >"$absolute_report"
      ;;
    codex) "${engine_command[@]}" </dev/null >"$absolute_log" 2>&1 ;;
    *) "${engine_command[@]}" </dev/null >"$absolute_report" 2>"$absolute_log" ;;
  esac
}

file_age() {
  local modified
  # GNU stat first: on Linux, BSD-style `stat -f` succeeds with other output.
  modified="$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0)"
  printf '%d' $(( $(date +%s) - modified ))
}

if (( status == 0 )); then
  if [[ "$engine" == ccr || "$engine" == claude ]] && ! command -v jq >/dev/null 2>&1; then
    echo "jq is required for the $engine engine" | tee -a "$log_file" >&2
    status=1
  fi
fi
timeout_seconds="${SQUAD_WORKER_TIMEOUT_SECONDS:-$(( timeout_minutes * 60 ))}"
stall_seconds="${SQUAD_WORKER_STALL_SECONDS:-$(( stall_minutes * 60 ))}"
if (( status == 0 )); then
  : >"$log_file"
  run_engine &
  engine_pid=$!
  # Watchdog: stop runs that exceed the time limit or stop producing output,
  # so a stuck worker reports back instead of leaving its pane pending.
  while kill -0 "$engine_pid" 2>/dev/null; do
    sleep 1
    if (( $(date +%s) - started_at > timeout_seconds )); then
      stop_reason="timed out after $(( timeout_seconds / 60 ))m"
    elif (( streams_log == 1 && stall_seconds > 0 )) && [[ -f "$log_file" ]] &&
      (( $(file_age "$log_file") > stall_seconds )); then
      stop_reason="no output for $(( stall_seconds / 60 ))m"
    fi
    if [[ -n "$stop_reason" ]]; then
      pkill -TERM -P "$engine_pid" 2>/dev/null || true
      kill -TERM "$engine_pid" 2>/dev/null || true
      break
    fi
  done
  wait "$engine_pid" 2>/dev/null || status=$?
  engine_pid=""
  if [[ -n "$stop_reason" ]]; then
    status=124
    printf '\nsquad-worker: %s\n' "$stop_reason" >>"$log_file"
  fi
fi

# Token usage, summed from the engine's JSON events, for the monitor and the
# savings summary.
if command -v jq >/dev/null 2>&1 && [[ -s "$log_file" ]]; then
  usage_line="$(jq -R -r -s '
    [split("\n")[] | fromjson? | select(type == "object")
     | (select(.type == "turn.completed") | .usage), (select(.type == "result") | .usage // empty)]
    | if length == 0 then "" else
      [ (map((.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0)) | add),
        (map(.cached_input_tokens // .cache_read_input_tokens // 0) | add),
        (map(.output_tokens // 0) | add) ] | map(tostring) | join(" ") end' "$log_file" 2>/dev/null || true)"
  if [[ -n "$usage_line" ]]; then
    read -r tokens_in tokens_cached tokens_out <<<"$usage_line"
  fi
fi

report=""
if [[ -s "$report_file" ]]; then
  report="$(cat "$report_file")"
fi
if (( status != 0 )) || [[ -z "${report//[[:space:]]/}" ]]; then
  (( status != 0 )) || status=1
  state=failed
  [[ "$stop_reason" == "stopped by request" ]] && state=stopped
  write_status "$state" "$status"
  message="$worker_id ($engine) ${stop_reason:-failed} on task $task_id (exit status $status). Log: $workspace_root/$log_file. Reassign or rerun the task."
  squad send --task-id "$task_id" "$worker_id" "$manager_id" "$message" >/dev/null || true
  echo "$message" >&2
  tail -n 20 "$log_file" >&2 2>/dev/null || true
  exit "$status"
fi

write_status completed 0
squad task complete "$worker_id" "$task_id" --summary "$(printf '%s' "$report" | cut -c1-4000)" >/dev/null
squad send --task-id "$task_id" "$worker_id" "$manager_id" \
  "$worker_id ($engine) completed task $task_id. Report: $workspace_root/$report_file" >/dev/null || true
printf '[%s · %s · task %s] report: %s\n\n%s\n' \
  "$worker_id" "$engine" "$task_id" "$workspace_root/$report_file" "$report"
