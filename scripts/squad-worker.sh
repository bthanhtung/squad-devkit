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
Usage: squad-worker <worker-id> --engine codex|ccr (--brief TEXT | --brief-file FILE)
                    [--role ROLE] [--title TITLE] [--profile PROFILE]
                    [--mcp NAME]... [--all-mcp] [--manager ID]

Run one on-demand worker for the squad manager, then exit. The worker joins the
squad, receives a structured task from the manager, works non-interactively,
completes the task with its final report, and leaves. The report is printed on
stdout and saved under .squad/workers/. Task records, reports, and logs go to the
manager's squad workspace (SQUAD_DEVKIT_WORKSPACE, or the nearest directory
with .squad/ above the current one).

  --engine codex   codex exec, sandboxed to the workspace (--profile, default: high)
  --engine ccr     Claude Code through claude-code-router (cheap model);
                   tools default to Read,Edit,Write,Glob,Grep, no shell
  --role ROLE      Role prompt from .squad/roles/ROLE.md (default: dev)
  --title TITLE    Task title (default: first line of the brief)
  --brief-file -   Read the brief from stdin
  --mcp NAME       codex only: keep this MCP server enabled (repeatable);
                   all others are disabled to keep the worker's context small
  --all-mcp        codex only: keep every configured MCP server
  --project DIR    Directory the worker works in (default: the squad workspace)
  --manager ID     Manager agent ID that owns the task (default: manager)

Environment: SQUAD_WORKER_CODEX_PROFILE (default profile),
SQUAD_WORKER_CCR_TOOLS (comma-separated tools for ccr workers).
EOF
}

worker_id=""
engine=""
role="dev"
title=""
brief=""
brief_file=""
profile="${SQUAD_WORKER_CODEX_PROFILE:-high}"
manager_id="${SQUAD_MANAGER_ID:-manager}"
project_directory=""
keep_mcp=()
all_mcp=0
while (( $# > 0 )); do
  case "$1" in
    --engine|--role|--title|--brief|--brief-file|--profile|--mcp|--manager|--project)
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
        --mcp) keep_mcp+=("$2") ;;
        --manager) manager_id="$2" ;;
        --project) project_directory="$2" ;;
      esac
      shift
      ;;
    --all-mcp) all_mcp=1 ;;
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

if [[ -z "$worker_id" || -z "$engine" ]]; then
  usage >&2
  exit 2
fi
if [[ "$engine" != codex && "$engine" != ccr ]]; then
  echo "Unknown engine: $engine (use codex or ccr)" >&2
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

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing command: $1" >&2
    exit 1
  fi
}
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
if [[ -n "${SQUAD_DEVKIT_WORKSPACE:-}" && -d "$SQUAD_DEVKIT_WORKSPACE/.squad" ]]; then
  workspace_root="$(cd "$SQUAD_DEVKIT_WORKSPACE" && pwd)"
else
  workspace_root="$PWD"
  while [[ ! -d "$workspace_root/.squad" ]]; do
    if [[ "$workspace_root" == / ]]; then
      echo "No .squad/ found above $PWD; run squad init or squad-devkit first" >&2
      exit 1
    fi
    workspace_root="$(dirname "$workspace_root")"
  done
fi
# squad commands run in the squad workspace; the engine runs in the project,
# which defaults to the workspace itself.
project_directory="${project_directory:-$workspace_root}"
cd "$workspace_root"

client=codex
if [[ "$engine" == ccr ]]; then
  client=claude
fi
join_output="$(squad join "$worker_id" --role "$role" --client "$client" --protocol-version 2)"
joined_id="$(printf '%s\n' "$join_output" | sed -n 's/.*Joined as \([^ ]*\) (role:.*/\1/p' | head -1)"
if [[ -z "$joined_id" ]]; then
  printf '%s\n' "$join_output" >&2
  echo "Could not join the squad as $worker_id" >&2
  exit 1
fi
worker_id="$joined_id"
status_file=""
leave_squad() {
  local exit_status=$?
  if [[ -n "$status_file" && -f "$status_file" ]] && grep -qx 'state=running' "$status_file"; then
    write_status failed "$exit_status"
  fi
  squad leave "$worker_id" >/dev/null 2>&1 || true
}
trap leave_squad EXIT

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
prompt="You are $worker_id, a $role worker in a squad led by $manager_id. You run once and non-interactively: nobody can answer questions, so make reasonable decisions within the brief.
${role_instructions:+
$role_instructions
}
## Task $task_id: $title

Project directory: $project_directory

$brief

## Rules
- Do only what the task asks and touch only the files it assigns you; other workers may be editing other files at the same time.
- Do not commit, push, or delete unrelated files.
- Use only the tools you were given. Never read credentials or tokens from configuration files; if a tool you need is missing, stop and report it.
- If something blocks you, stop and explain it in the report instead of guessing.
- Your final message is the report for $manager_id, at most 15 lines: result, files changed, verification you ran and its outcome, open issues."

output_directory=".squad/workers"
mkdir -p "$output_directory"
run_name="$worker_id-$(date +%Y%m%d-%H%M%S)"
report_file="$output_directory/$run_name.md"
log_file="$output_directory/$run_name.log"
status_file="$output_directory/$run_name.status"
started_at="$(date +%s)"
run_profile=""
[[ "$engine" == codex ]] && run_profile="$profile"

write_status() {
  local state="$1"
  local exit_status="${2:-}"
  local finished=""
  [[ "$state" != running ]] && finished="$(date +%s)"
  {
    printf 'worker=%s\nengine=%s\nprofile=%s\nrole=%s\n' "$worker_id" "$engine" "$run_profile" "$role"
    printf 'title=%s\ntask=%s\nstate=%s\n' "$(printf '%s' "$title" | tr '\n' ' ')" "$task_id" "$state"
    printf 'started=%s\nfinished=%s\nexit=%s\n' "$started_at" "$finished" "$exit_status"
    printf 'log=%s\nreport=%s\n' "$workspace_root/$log_file" "$workspace_root/$report_file"
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
    [[ -n "${SQUAD_WORKER_PANE_HOLD:-}" ]] &&
      printf 'export SQUAD_WORKER_PANE_HOLD=%q\n' "$SQUAD_WORKER_PANE_HOLD"
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
  local attempt
  for attempt in $(seq 1 40); do
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
  local attempt
  for attempt in $(seq 1 30); do
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

status=0
if [[ "$engine" == codex ]]; then
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
  if (( status == 0 )); then
    codex exec --json --cd "$project_directory" --profile "$profile" --ephemeral --skip-git-repo-check \
      --sandbox workspace-write ${mcp_arguments[@]+"${mcp_arguments[@]}"} \
      --output-last-message "$workspace_root/$report_file" "$prompt" </dev/null >"$log_file" 2>&1 || status=$?
  fi
else
  tools="${SQUAD_WORKER_CCR_TOOLS:-Read,Edit,Write,Glob,Grep}"
  if ensure_ccr_server; then
    (
      eval "$(ccr activate)"
      unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT
      report_file="$workspace_root/$report_file"
      log_file="$workspace_root/$log_file"
      cd "$project_directory"
      claude_arguments=(-p --strict-mcp-config --disable-slash-commands --no-session-persistence
        --tools "$tools" --allowedTools "$tools" --permission-mode acceptEdits)
      if command -v jq >/dev/null 2>&1; then
        claude "${claude_arguments[@]}" --output-format stream-json --verbose \
          "$prompt" </dev/null >"$log_file" 2>&1
        jq -R -r 'fromjson? | select(.type == "result") | .result // empty' "$log_file" >"$report_file"
      else
        claude "${claude_arguments[@]}" "$prompt" </dev/null >"$report_file" 2>"$log_file"
      fi
    ) || status=$?
  else
    status=1
  fi
fi

report=""
if [[ -s "$report_file" ]]; then
  report="$(cat "$report_file")"
fi
if (( status != 0 )) || [[ -z "${report//[[:space:]]/}" ]]; then
  (( status != 0 )) || status=1
  write_status failed "$status"
  message="$worker_id ($engine) failed on task $task_id with exit status $status. Log: $workspace_root/$log_file"
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
