#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: squad-worker <worker-id> --engine codex|ccr (--brief TEXT | --brief-file FILE)
                    [--role ROLE] [--title TITLE] [--profile PROFILE]
                    [--mcp NAME]... [--all-mcp] [--manager ID]

Run one on-demand worker for the squad manager, then exit. The worker joins the
squad, receives a structured task from the manager, works non-interactively,
completes the task with its final report, and leaves. The report is printed on
stdout and saved under .squad/workers/. Run it from the project root (or any
directory below it that contains .squad/).

  --engine codex   codex exec, sandboxed to the workspace (--profile, default: high)
  --engine ccr     Claude Code through claude-code-router (cheap model);
                   tools default to Read,Edit,Write,Glob,Grep, no shell
  --role ROLE      Role prompt from .squad/roles/ROLE.md (default: dev)
  --title TITLE    Task title (default: first line of the brief)
  --brief-file -   Read the brief from stdin
  --mcp NAME       codex only: keep this MCP server enabled (repeatable);
                   all others are disabled to keep the worker's context small
  --all-mcp        codex only: keep every configured MCP server
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
keep_mcp=()
all_mcp=0
while (( $# > 0 )); do
  case "$1" in
    --engine|--role|--title|--brief|--brief-file|--profile|--mcp|--manager)
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

workspace_root="$PWD"
while [[ ! -d "$workspace_root/.squad" ]]; do
  if [[ "$workspace_root" == / ]]; then
    echo "No .squad/ found above $PWD; run squad init or squad-devkit first" >&2
    exit 1
  fi
  workspace_root="$(dirname "$workspace_root")"
done
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
leave_squad() {
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

$brief

## Rules
- Do only what the task asks and touch only the files it assigns you; other workers may be editing other files at the same time.
- Do not commit, push, or delete unrelated files.
- If something blocks you, stop and explain it in the report instead of guessing.
- Your final message is the report for $manager_id, at most 15 lines: result, files changed, verification you ran and its outcome, open issues."

output_directory=".squad/workers"
mkdir -p "$output_directory"
run_name="$worker_id-$(date +%Y%m%d-%H%M%S)"
report_file="$output_directory/$run_name.md"
log_file="$output_directory/$run_name.log"

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
  echo "claude-code-router did not start on port $port; see $output_directory/ccr-server.log" >&2
  return 1
}

status=0
if [[ "$engine" == codex ]]; then
  mcp_arguments=()
  if (( all_mcp == 0 )); then
    configured_servers="$(codex mcp list --json 2>/dev/null |
      sed -n 's/^    "name": "\([^"]*\)",$/\1/p' || true)"
    while IFS= read -r server; do
      [[ -n "$server" ]] || continue
      if [[ " ${keep_mcp[*]:-} " == *" $server "* ]]; then
        continue
      fi
      mcp_arguments+=(-c "mcp_servers.$server.enabled=false")
    done <<<"$configured_servers"
  fi
  codex exec --profile "$profile" --ephemeral --skip-git-repo-check \
    --sandbox workspace-write ${mcp_arguments[@]+"${mcp_arguments[@]}"} \
    --output-last-message "$report_file" "$prompt" </dev/null >"$log_file" 2>&1 || status=$?
else
  tools="${SQUAD_WORKER_CCR_TOOLS:-Read,Edit,Write,Glob,Grep}"
  if ensure_ccr_server; then
    (
      eval "$(ccr activate)"
      unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT
      claude -p --strict-mcp-config --disable-slash-commands --no-session-persistence \
        --tools "$tools" --allowedTools "$tools" --permission-mode acceptEdits \
        "$prompt" </dev/null >"$report_file" 2>"$log_file"
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
  message="$worker_id ($engine) failed on task $task_id with exit status $status. Log: $workspace_root/$log_file"
  squad send --task-id "$task_id" "$worker_id" "$manager_id" "$message" >/dev/null || true
  echo "$message" >&2
  tail -n 20 "$log_file" >&2 2>/dev/null || true
  exit "$(( status == 0 ? 1 : status ))"
fi

squad task complete "$worker_id" "$task_id" --summary "$(printf '%s' "$report" | cut -c1-4000)" >/dev/null
printf '[%s · %s · task %s] report: %s\n\n%s\n' \
  "$worker_id" "$engine" "$task_id" "$workspace_root/$report_file" "$report"
