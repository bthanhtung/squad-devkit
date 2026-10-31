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
source "$script_dir/lib/squad-worktree.sh"
source "$script_dir/lib/squad-panes.sh"

usage() {
  cat <<'EOF'
Usage: squad-worker <worker-id> --engine ENGINE (--brief TEXT | --brief-file FILE)
                    [--role ROLE] [--title TITLE] [--project DIR]
                    [--profile PROFILE] [--model MODEL] [--mcp NAME]... [--all-mcp]
                    [--timeout MINUTES] [--manager ID]
       squad-worker --list
       squad-worker --stop <worker-id|all>
       squad-worker --merge <worker-id> [--project DIR]
       squad-worker --diff <worker-id> [--project DIR]
       squad-worker --discard <worker-id|all> [--project DIR]

Run one on-demand worker for the squad manager, then exit. The worker joins the
squad, receives a structured task from the manager, works non-interactively,
completes the task with its report, and leaves. The report is printed on
stdout and saved under .squad/workers/ in the manager's squad workspace
(SQUAD_DEVKIT_WORKSPACE, or the nearest directory with .squad/ above here).

Engines, most trusted first:
  claude   Claude Code (your Anthropic plan; --model haiku by default,
           sonnet for complex or high-risk work, opus for the hardest)
  codex    codex exec, sandboxed to the project (--profile, default: high)
  opencode OpenCode headless (experimental)
  grok     Grok Build headless (experimental)
  agy      Antigravity CLI headless (experimental)
  ccr      Claude Code through claude-code-router: cheap model, file tools only

Options:
  --role ROLE        Role prompt from .squad/roles/ROLE.md (default: dev)
  --title TITLE      Task title (default: first line of the brief)
  --brief-file -     Read the brief from stdin
  --project DIR      Directory the worker works in (default: the squad workspace)
  --profile NAME     codex profile (default: high)
  --model NAME       Model for claude, opencode, grok, or agy
  --mcp NAME         codex only: keep this MCP server enabled (repeatable);
                     all others are disabled to keep the worker's context small
  --all-mcp          codex only: keep every configured MCP server
  --timeout MINUTES  Stop the run after this long (default 45)
  --worktree         Work in an isolated git worktree (default in git repositories,
                     except for the reviewer and researcher roles)
  --no-worktree      Work directly in the project directory
  --manager ID       Manager agent ID that owns the task (default: manager)
  --list             Show worker runs that are still running
  --stop ID|all      Stop a running worker (or all of them); it reports to the manager
  --merge ID         Apply a worker's worktree changes to the project (three-way;
                     conflicts are left as markers) and remove the worktree
  --diff ID          Print a worker's worktree changes as a patch (changes are kept)
  --discard ID|all   Remove a worker's worktree and branch without applying them

Environment: SQUAD_WORKER_CODEX_PROFILE, SQUAD_WORKER_CLAUDE_MODEL,
SQUAD_WORKER_CLAUDE_TOOLS, SQUAD_WORKER_CLAUDE_PERMISSION_MODE (default
acceptEdits, shell sandboxed), SQUAD_WORKER_CCR_TOOLS, SQUAD_WORKER_TIMEOUT (minutes),
SQUAD_WORKER_STALL (minutes without log output before a run counts as stuck,
default 10), SQUAD_WORKER_PANES=0, SQUAD_WORKER_PANE_HOLD (seconds a finished
monitor pane stays open, default 60), SQUAD_WORKER_WORKTREE (auto, 1, or 0).
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
worktree_mode="${SQUAD_WORKER_WORKTREE:-auto}"
while (( $# > 0 )); do
  case "$1" in
    --engine|--role|--title|--brief|--brief-file|--profile|--model|--mcp|--manager|--project|--timeout|--stop|--merge|--discard|--diff)
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
        --merge) action=merge; stop_target="$2" ;;
        --discard) action=discard; stop_target="$2" ;;
        --diff) action="diff"; stop_target="$2" ;;
      esac
      shift
      ;;
    --all-mcp) all_mcp=1 ;;
    --worktree) worktree_mode=1 ;;
    --no-worktree) worktree_mode=0 ;;
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

# The newest status file of a worker's runs that used a worktree.
latest_status_with_worktree() {
  local file
  while IFS= read -r file; do
    [[ -n "$(status_get "$file" worktree)" ]] && { printf '%s\n' "$file"; return 0; }
  done < <(ls -t .squad/workers/"$1"-*.status 2>/dev/null)
  return 0
}

# "  <id>  <worktree path>" for each worker worktree that still exists.
unmerged_worktrees() {
  local file id path seen=" "
  while IFS= read -r file; do
    id="$(status_get "$file" worker)"
    path="$(status_get "$file" worktree)"
    [[ -n "$path" && -d "$path" && "$seen" != *" $id "* ]] || continue
    seen+="$id "
    printf '  %s  %s\n' "$id" "$path"
  done < <(ls -t .squad/workers/*.status 2>/dev/null)
  return 0
}

if [[ "$action" == list || "$action" == stop ]]; then
  require_command squad
  workspace_root="$(find_workspace)"
  export SQUAD_WORKTREE_WORKSPACE="$workspace_root"
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
  if [[ "$action" == list ]]; then
    unmerged="$(unmerged_worktrees)"
    if [[ -n "$unmerged" ]]; then
      echo "Unmerged worktrees (squad-worker --merge <id> or --discard <id>):"
      printf '%s\n' "$unmerged"
    fi
  fi
  exit 0
fi

if [[ "$action" == merge || "$action" == discard || "$action" == diff ]]; then
  require_command git
  workspace_root="$(find_workspace)"
  export SQUAD_WORKTREE_WORKSPACE="$workspace_root"
  cd "$workspace_root"
  targets=()
  if [[ "$action" == diff ]] &&
    { [[ ! "$stop_target" =~ ^[A-Za-z0-9._-]+$ ]] || [[ "$stop_target" == . || "$stop_target" == .. ]]; }; then
    echo "Invalid worker ID for --diff: $stop_target" >&2
    exit 2
  fi
  if [[ "$stop_target" == all && "$action" != diff ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] && targets+=("${line%% *}")
    done < <(unmerged_worktrees | sed 's/^  //')
  else
    targets=("$stop_target")
  fi
  (( ${#targets[@]} > 0 )) || { echo "No unmerged worktrees."; exit 0; }
  exit_status=0
  for target in "${targets[@]}"; do
    root=""
    if [[ -n "$project_directory" ]]; then
      root="$(worktree_repository_root "$project_directory" || true)"
    else
      status_path="$(latest_status_with_worktree "$target")"
      [[ -n "$status_path" ]] && root="$(status_get "$status_path" repository)"
    fi
    home="$( [[ -n "$root" ]] && worktree_home "$root" 2>/dev/null || true)"
    if [[ -z "$root" || -z "$home" || ! -d "$home/$target" ]]; then
      echo "No worktree for $target${project_directory:+ in $project_directory}." >&2
      exit_status=1
      continue
    fi
    if [[ "$action" == diff ]]; then
      worktree_commit "$home/$target" "$target: pending changes" >/dev/null 2>&1 || true
      worktree_patch "$root" "$target" || exit_status=1
      continue
    fi
    if [[ "$action" == discard ]]; then
      worktree_remove "$root" "$target"
      echo "Discarded $target's worktree and branch squad/$target."
      continue
    fi
    worktree_commit "$home/$target" "$target: pending changes" >/dev/null 2>&1 || true
    patch_file="$(mktemp)"
    worktree_patch "$root" "$target" >"$patch_file"
    if [[ ! -s "$patch_file" ]]; then
      worktree_remove "$root" "$target"
      echo "$target made no changes; removed its worktree."
    elif apply_output="$(worktree_apply "$root" "$patch_file")"; then
      worktree_remove "$root" "$target"
      echo "Merged $target into $root ($(git apply --numstat "$patch_file" | wc -l | tr -d ' ') files, uncommitted). Worktree removed."
    else
      conflicted="$(printf '%s\n' "$apply_output" | sed -n "s/^Applied patch to '\(.*\)' with conflicts\.$/\1/p")"
      echo "Merged $target into $root with conflicts; resolve the markers in:" >&2
      printf '  %s\n' $conflicted >&2
      echo "The worktree stays at $home/$target until you run squad-worker --discard $target." >&2
      exit_status=1
    fi
    rm -f "$patch_file"
  done
  exit "$exit_status"
fi

if [[ -z "$worker_id" || -z "$engine" ]]; then
  usage >&2
  exit 2
fi
case "$engine" in
  claude|codex|opencode|grok|agy|ccr) ;;
  *) echo "Unknown engine: $engine (use claude, codex, opencode, grok, agy, or ccr)" >&2; exit 2 ;;
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
export SQUAD_WORKTREE_WORKSPACE="$workspace_root"
# squad commands run in the squad workspace; the engine runs in the project,
# which defaults to the workspace itself.
project_directory="${project_directory:-$workspace_root}"
cd "$workspace_root"

client="$engine"
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

# Isolated worktree: by default in git repositories, except for the read-only
# reviewer and researcher roles. Fix rounds reuse an unmerged worktree.
engine_directory="$project_directory"
repository_root=""
worktree_path=""
worktree_base_commit=""
use_worktree=0
case "$worktree_mode" in
  1) use_worktree=1 ;;
  0) ;;
  *) [[ "$role" != reviewer && "$role" != researcher ]] && use_worktree=1 ;;
esac
if (( use_worktree == 1 )); then
  repository_root="$(worktree_repository_root "$project_directory" || true)"
  if [[ -z "$repository_root" ]]; then
    if [[ "$worktree_mode" == 1 ]]; then
      echo "--worktree needs a git repository: $project_directory" >&2
      exit 2
    fi
  elif worktree_path="$(worktree_create "$repository_root" "$worker_id")"; then
    worktree_base_commit="$(worktree_base "$repository_root" "$worker_id")"
    prefix="$(git -C "$project_directory" rev-parse --show-prefix)"
    engine_directory="$worktree_path${prefix:+/${prefix%/}}"
  else
    echo "Could not create a worktree for $worker_id in $repository_root" >&2
    exit 1
  fi
fi

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

Working directory: $engine_directory${worktree_path:+
This is your own git worktree of $repository_root, isolated from other workers. The manager reviews and merges your changes, so do not commit, push, or switch branches.}

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
patch_file=""

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
    printf 'repository=%s\nworktree=%s\nbase=%s\npatch=%s\n' "$repository_root" "$worktree_path" \
      "$worktree_base_commit" "${patch_file:+$workspace_root/$patch_file}"
  } >"$status_file.tmp"
  mv "$status_file.tmp" "$status_file"
}
write_status running

# Live monitor for this run beside the manager (see lib/squad-panes.sh).
open_monitor_pane() {
  local pane_script="$output_directory/$run_name.monitor.sh"
  local dashboard_script="$output_directory/dashboard.sh"
  # Pane shells start from the terminal, not from this process, so pass settings explicitly.
  {
    printf '#!/bin/bash\n'
    printf 'export SQUAD_WORKER_PANE_HOLD=%q\n' "${SQUAD_WORKER_PANE_HOLD:-60}"
    printf 'exec %q %q\n' "$script_dir/squad-worker-monitor.sh" "$workspace_root/$status_file"
  } >"$pane_script"
  printf '#!/bin/bash\nexec %q --all %q\n' "$script_dir/squad-worker-monitor.sh" \
    "$workspace_root/$output_directory" >"$dashboard_script"
  chmod +x "$pane_script" "$dashboard_script"
  squad_open_monitor "$workspace_root/$pane_script" "$worker_id · $engine" "$workspace_root" \
    "$workspace_root/$output_directory" "$workspace_root/$dashboard_script"
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
    [[ "$engine_directory" != "$workspace_root" ]] && add_directory=(--add-dir "$workspace_root")
    engine_command=(codex exec --json --cd "$engine_directory" --profile "$profile" --ephemeral
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
    engine_command=(grok -p "$prompt" --always-approve --cwd "$engine_directory")
    [[ -n "$model" ]] && engine_command+=(--model "$model")
    ;;
  agy)
    engine_command=(agy -p "$prompt" --mode accept-edits)
    [[ -n "$model" ]] && engine_command+=(--model "$model")
    ;;
  opencode)
    engine_command=(opencode run "$prompt")
    [[ -n "$model" ]] && engine_command+=(--model "$model")
    ;;
esac

run_engine() {
  cd "$engine_directory"
  unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT
  case "$engine" in
    ccr)
      eval "$(ccr activate 2>/dev/null)"
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

# Seconds since the engine last wrote to its log or, for engines that print the
# report on stdout (streams_log=0), to its report.
output_age() {
  local age newest
  newest="$(file_age "$log_file")"
  if [[ -f "$report_file" ]]; then
    age="$(file_age "$report_file")"
    (( age < newest )) && newest="$age"
  fi
  printf '%d' "$newest"
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
  : >"$report_file"
  run_engine &
  engine_pid=$!
  # Watchdog: stop runs that exceed the time limit or stop producing output,
  # so a stuck worker reports back instead of leaving its pane pending.
  while kill -0 "$engine_pid" 2>/dev/null; do
    sleep 1
    if (( $(date +%s) - started_at > timeout_seconds )); then
      stop_reason="timed out after $(( timeout_seconds / 60 ))m"
    elif (( stall_seconds > 0 )) && (( $(output_age) > stall_seconds )); then
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

# Keep the worker's changes on its branch and as a patch for review and merge.
worktree_note=""
if [[ -n "$worktree_path" ]]; then
  worktree_commit "$worktree_path" "$worker_id: $title" >/dev/null 2>&1 || true
  patch_file="$output_directory/$run_name.patch"
  worktree_patch "$repository_root" "$worker_id" >"$patch_file" 2>/dev/null || true
  changed_files="$(git apply --numstat "$patch_file" 2>/dev/null | wc -l | tr -d ' ')"
  worktree_note="Worktree: $changed_files changed file(s) in $worktree_path (branch squad/$worker_id). Review: git -C $worktree_path diff $worktree_base_commit. Merge: squad-worker --merge $worker_id. Discard: squad-worker --discard $worker_id."
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
  "$worker_id ($engine) completed task $task_id. Report: $workspace_root/$report_file${worktree_note:+ $worktree_note}" >/dev/null || true
printf '[%s · %s · task %s] report: %s\n%s\n%s\n' \
  "$worker_id" "$engine" "$task_id" "$workspace_root/$report_file" "${worktree_note:+$worktree_note
}" "$report"
