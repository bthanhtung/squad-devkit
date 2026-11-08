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
                    [--timeout MINUTES] [--manager ID] [--sandbox | --no-sandbox]
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
  codex    codex exec, sandboxed to the project (--profile, default: CLI configuration)
  opencode OpenCode headless (experimental)
  grok     Grok Build headless (experimental)
  agy      Antigravity CLI headless (experimental)
  ccr      Claude Code through claude-code-router: cheap model, file tools only

Options:
  --role ROLE        Role prompt from .squad/roles/ROLE.md (default: dev)
  --title TITLE      Task title (default: first line of the brief)
  --brief-file -     Read the brief from stdin
  --project DIR      Directory the worker works in (default: the squad workspace)
  --profile NAME     codex profile (default: CLI configuration)
  --models           Print local model candidates as JSON; optional --engine/--project filters
  --model-tier TIER  fast|balanced|strong; requires a mapping (Claude aliases available)
  --model NAME       Model override (except CCR; router selects its model)
  --mcp NAME         codex only: keep this MCP server enabled (repeatable);
                     all others are disabled to keep the worker's context small
  --all-mcp          codex only: keep every configured MCP server
  --timeout MINUTES  Stop the run after this long (default 45)
  --worktree         Work in an isolated git worktree (default in git repositories,
                     except for the reviewer, researcher and security roles)
  --no-worktree      Work directly in the project directory
  --yolo             Bypass permissions and sandbox (claude, codex, agy only;
                     inherited from SQUAD_DEVKIT_YOLO=1)
  --sandbox          Run shell commands in engine sandbox (default)
  --no-sandbox       Disable engine sandbox
  --manager ID       Manager agent ID that owns the task (default: manager)
  --list             Show worker runs that are still running
  --stop ID|all      Stop a running worker (or all of them); it reports to the manager
  --merge ID         Apply a worker's worktree changes to the project (three-way;
                     conflicts are left as markers) and remove the worktree
  --diff ID          Print a worker's worktree changes as a patch (changes are kept)
  --discard ID|all   Remove a worker's worktree and branch without applying them

Environment: SQUAD_WORKER_CODEX_PROFILE, SQUAD_WORKER_CLAUDE_MODEL,
SQUAD_WORKER_CLAUDE_TOOLS, SQUAD_WORKER_CLAUDE_ALLOWED_TOOLS (optional scoped
Bash allow rules), SQUAD_WORKER_CLAUDE_PERMISSION_MODE (default
acceptEdits, shell sandboxed), SQUAD_WORKER_CCR_TOOLS, SQUAD_WORKER_TIMEOUT (minutes),
SQUAD_WORKER_STALL (minutes without log output before a run counts as stuck,
default 10), SQUAD_WORKER_PANES=0, SQUAD_WORKER_PANE_HOLD (seconds a finished
monitor pane stays open, default 60), SQUAD_WORKER_WORKTREE (auto, 1, or 0),
SQUAD_WORKER_SANDBOX (1 or 0).
EOF
}

worker_id=""
engine=""
role="dev"
title=""
brief=""
brief_file=""
profile="${SQUAD_WORKER_CODEX_PROFILE:-}"
model=""
model_source=""
model_tier=""
models=0
catalog_incompatible=0
manager_id="${SQUAD_MANAGER_ID:-manager}"
required_split=0
[[ -z "${SQUAD_MANAGER_ID:-}" ]] || required_split=1
project_directory=""
timeout_minutes="${SQUAD_WORKER_TIMEOUT:-45}"
stall_minutes="${SQUAD_WORKER_STALL:-10}"
keep_mcp=()
all_mcp=0
action=run
stop_target=""
worktree_mode="${SQUAD_WORKER_WORKTREE:-auto}"
sandbox_mode="${SQUAD_WORKER_SANDBOX:-1}"
sandbox_flag_set=""
yolo="${SQUAD_DEVKIT_YOLO:-0}"
id_pattern='^[A-Za-z0-9][A-Za-z0-9._-]*$'
while (( $# > 0 )); do
  case "$1" in --models|--engine|--project) ;; *) catalog_incompatible=1 ;; esac
  case "$1" in
    --engine|--role|--title|--brief|--brief-file|--profile|--model|--model-tier|--mcp|--manager|--project|--timeout|--stop|--merge|--discard|--diff)
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
        --model-tier) model_tier="$2" ;;
        --mcp) keep_mcp+=("$2") ;;
        --manager) manager_id="$2"; required_split=1 ;;
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
    --yolo) yolo=1 ;;
    --sandbox) sandbox_mode=1; sandbox_flag_set+=s ;;
    --no-sandbox) sandbox_mode=0; sandbox_flag_set+=n ;;
    --models) models=1 ;;
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

source "$script_dir/lib/squad-worker-model.sh"

if (( models == 1 )); then
  if [[ -n "$project_directory" && ! -d "$project_directory" ]]; then
    echo "Project directory does not exist: $project_directory" >&2; exit 2
  fi
  if (( catalog_incompatible == 1 )); then
    echo '--models accepts only --engine and --project filters' >&2; exit 2
  fi
  catalog_engines=()
  if [[ -n "$engine" ]]; then
    catalog_engines=("$engine")
  else
    for candidate_engine in claude codex opencode grok agy ccr; do
      command -v "$candidate_engine" >/dev/null 2>&1 && catalog_engines+=("$candidate_engine")
    done
  fi
  squad_worker_model_catalog ${catalog_engines[@]+"${catalog_engines[@]}"}
  exit $?
fi


status_get() {
  sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -n 1
}

# A failed kill probe can mean permission denied; only a successful process
# table snapshot proves absence. Start time prevents signalling a reused PID.
reconcile_status() {
  local file="$1" pid expected actual table reason="" tmp
  [[ "$(status_get "$file" state)" == running ]] || return 0
  pid="$(status_get "$file" pid)"
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 0
  table="$(LC_ALL=C ps -axo pid=,lstart=,stat= 2>/dev/null)" || return 0
  actual="$(printf '%s\n' "$table" | awk -v pid="$pid" '$1 == pid { $1=""; sub(/^ +/, ""); print; exit }')"
  expected="$(status_get "$file" process_started)"
  if [[ -z "$actual" ]]; then
    reason="worker process disappeared; exit status unavailable"
  elif [[ -n "$expected" && "$actual" != "$expected "* ]]; then
    reason="worker PID was reused; exit status unavailable"
  elif [[ "$actual" == *" Z"* ]]; then
    reason="worker process is a zombie; exit status unavailable"
  fi
  [[ -n "$reason" ]] || return 0
  tmp="$(mktemp "$file.reconcile.XXXXXX")"
  awk '!/^(state|reason|finished|exit)=/' "$file" >"$tmp"
  printf 'state=lost\nreason=%s; report may be incomplete\nfinished=%s\nexit=\n' "$reason" "$(date +%s)" >>"$tmp"
  if [[ "$(status_get "$file" state)" == running ]]; then mv "$tmp" "$file"; else rm -f "$tmp"; fi
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

if [[ "$action" =~ ^(stop|merge|discard|diff)$ ]] &&
  [[ "$stop_target" != all || "$action" == diff ]] && [[ ! "$stop_target" =~ $id_pattern ]]; then
  echo "Invalid worker id: $stop_target" >&2
  exit 2
fi
if [[ "$action" == list || "$action" == stop ]]; then
  require_command squad
  workspace_root="$(find_workspace)"
  export SQUAD_WORKTREE_WORKSPACE="$workspace_root"
  cd "$workspace_root"
  found=0
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    reconcile_status "$file"
    [[ "$(status_get "$file" state)" == running ]] || continue
    id="$(status_get "$file" worker)"
    pid="$(status_get "$file" pid)"
    if [[ "$action" == list ]]; then
      printf '%-12s %-7s %-10s pid %-7s %s\n' "$id" "$(status_get "$file" engine)" \
        "$(status_get "$file" role)" "${pid:-?}" "$(status_get "$file" title)"
      squad_worker_model_label "$file"; printf '\n'
      found=1
    elif [[ "$stop_target" == all || "$stop_target" == "$id" ]]; then
      if [[ -n "$pid" ]] && kill -TERM "$pid" 2>/dev/null; then
        echo "Stopping $id (pid $pid)."
      else
        reconcile_status "$file"
        echo "$id could not be stopped; state=$(status_get "$file" state)."
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
if [[ ! "$worker_id" =~ $id_pattern ]]; then
  echo "Invalid worker id: $worker_id" >&2
  exit 2
fi
if [[ ! "$role" =~ $id_pattern ]]; then
  echo "Invalid role: $role" >&2
  exit 2
fi
if [[ "$sandbox_flag_set" == *s* && "$sandbox_flag_set" == *n* ]]; then
  echo "--sandbox and --no-sandbox are mutually exclusive" >&2
  exit 2
fi
case "$yolo" in
  0|1) ;;
  *) echo 'SQUAD_DEVKIT_YOLO must be 0 or 1' >&2; exit 2 ;;
esac
if [[ "$yolo" == 1 ]]; then
  case "$engine" in
    claude|codex|agy) ;;
    *) echo 'YOLO supports only claude, codex, and agy' >&2; exit 2 ;;
  esac
  if [[ "${SQUAD_WORKER_SANDBOX:-}" == 1 || "$sandbox_flag_set" == *s* ]]; then
    echo 'YOLO and --sandbox (or SQUAD_WORKER_SANDBOX=1) are mutually exclusive' >&2
    exit 2
  fi
  sandbox_mode=0
fi
case "$engine" in
  claude|codex|opencode|grok|agy|ccr) ;;
  *) echo "Unknown engine: $engine (use claude, codex, opencode, grok, agy, or ccr)" >&2; exit 2 ;;
esac
if [[ ! "$timeout_minutes" =~ ^[0-9]+$ || "$timeout_minutes" =~ ^0+$ || ! "$stall_minutes" =~ ^[0-9]+$ ]]; then
  echo "--timeout (at least 1) and SQUAD_WORKER_STALL take whole minutes" >&2
  exit 2
fi
squad_worker_select_model
model_arguments=()
[[ -z "$model" ]] || model_arguments=(--model "$model")

if [[ -n "$brief_file" ]]; then
  if [[ "$brief_file" == - ]]; then
    brief="$(cat)"
  else
    [[ -f "$brief_file" && -r "$brief_file" ]] || { echo "Brief file not readable: $brief_file" >&2; exit 2; }
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
[[ "$engine" != codex ]] || require_command jq
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

# Join under the engine's own client type. squad builds from mco-org (the
# documented install) accept only claude, codex, gemini, and opencode, so on
# "invalid --client value" fall back to the closest of those.
client="$engine"
if ! join_output="$(squad join "$worker_id" --role "$role" --client "$client" --protocol-version 2 2>&1)"; then
  if [[ "$join_output" != *'invalid --client value'* ]]; then
    printf '%s\n' "$join_output" >&2
    exit 1
  fi
  case "$engine" in
    ccr) client=claude ;;
    *) client=codex ;;
  esac
  join_output="$(squad join "$worker_id" --role "$role" --client "$client" --protocol-version 2)"
fi
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
    stop_reason="${stop_reason:-wrapper exited before finalization (exit $exit_status)}"
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
# reviewer, researcher and security roles. Fix rounds reuse an unmerged worktree.
engine_directory="$project_directory"
repository_root=""
worktree_path=""
worktree_base_commit=""
use_worktree=0
case "$worktree_mode" in
  1) use_worktree=1 ;;
  0) ;;
  *) [[ "$role" != reviewer && "$role" != researcher && "$role" != security ]] && use_worktree=1 ;;
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
else
  echo "Note: no .squad/roles/$role.md; $worker_id runs without role instructions." >&2
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
process_started="$(LC_ALL=C ps -p "$$" -o lstart= | awk '{$1=$1; print}' || true)"
run_profile=""
[[ "$engine" == codex ]] && run_profile="$profile"
actual_model=unknown
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
    printf 'model_tier=%s\n' "$model_tier"
    printf 'requested_model=%s\nmodel_source=%s\nactual_model=%s\n' "$model" "$model_source" "$actual_model"
    printf 'title=%s\ntask=%s\nstate=%s\nreason=%s\n' \
      "$(printf '%s' "$title" | tr '\n' ' ')" "$task_id" "$state" "${failure_reason:-$stop_reason}"
    printf 'process_started=%s\n' "$process_started"
    printf 'pid=%s\nstarted=%s\nfinished=%s\nexit=%s\n' "$$" "$started_at" "$finished" "$exit_status"
    printf 'tokens_in=%s\ntokens_cached=%s\ntokens_out=%s\n' "$tokens_in" "$tokens_cached" "$tokens_out"
    printf 'project=%s\nlog=%s\nreport=%s\n' "$project_directory" \
      "$workspace_root/$log_file" "$workspace_root/$report_file"
    printf 'repository=%s\nworktree=%s\nbase=%s\npatch=%s\n' "$repository_root" "$worktree_path" \
      "$worktree_base_commit" "${patch_file:+$workspace_root/$patch_file}"
  } >"$status_file.tmp"
  mv "$status_file.tmp" "$status_file"
}
: >"$log_file"
: >"$report_file"
write_status running
printf 'squad-worker: %s (%s) %s\n' "$worker_id" "$engine" "$(squad_worker_model_label "$status_file")" >&2

# Live monitor for this run beside the manager (see lib/squad-panes.sh).
open_monitor_pane() {
  local pane_script="$output_directory/$run_name.monitor.sh"
  local dashboard_script="$output_directory/dashboard.sh"
  local ready_file
  ready_file="$(mktemp "$workspace_root/$output_directory/.monitor-ready.XXXXXXXX")" || return 1
  rm -f "$ready_file"
  # Pane shells start from the terminal, not from this process, so pass settings explicitly.
  {
    printf '#!/bin/bash\n'
    printf 'export SQUAD_WORKER_PANE_HOLD=%q\n' "${SQUAD_WORKER_PANE_HOLD:-60}"
    if (( required_split == 1 )); then
      printf 'export SQUAD_WORKER_MONITOR_READY=%q\n' "$ready_file"
    fi
    printf 'exec %q %q\n' "$script_dir/squad-worker-monitor.sh" "$workspace_root/$status_file"
  } >"$pane_script"
  printf '#!/bin/bash\nexec %q --all %q\n' "$script_dir/squad-worker-monitor.sh" \
    "$workspace_root/$output_directory" >"$dashboard_script"
  chmod +x "$pane_script" "$dashboard_script"
  squad_open_monitor "$workspace_root/$pane_script" "$worker_id · $engine" "$workspace_root" \
    "$workspace_root/$output_directory" "$workspace_root/$dashboard_script" "$([[ "$required_split" == 1 ]] && printf required)" || return 1
  (( required_split == 1 )) || return 0
  local monitor_pid=""
  for _ in $(seq 1 40); do
    if [[ -f "$ready_file" ]]; then
      IFS= read -r monitor_pid <"$ready_file" || true
      if [[ "$monitor_pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$monitor_pid" 2>/dev/null; then
        rm -f "$ready_file"; return 0
      fi
    fi
    sleep 0.25
  done
  rm -f "$ready_file"
  echo "squad-worker: monitor did not render or exited; fix the terminal or use tmux" >&2
  return 1
}
if ! failure_reason="$(open_monitor_pane 2>&1)"; then
  failure_reason="${failure_reason:-required monitor split failed; fix the terminal or use tmux}"
  failure_reason="$(printf '%s' "$failure_reason" | tr '\r\n' '  ')"
  write_status failed 1
  message="$worker_id ($engine) failed on task $task_id: $failure_reason"
  squad send --task-id "$task_id" "$worker_id" "$manager_id" "$message" >/dev/null || true
  echo "$message" >&2
  exit 1
fi

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
    mcp_json="$(codex mcp list --json 2>>"$log_file")" || status=3
    if ! printf '%s\n' "$mcp_json" | jq -e 'type == "array"' >/dev/null 2>&1; then
      echo "Could not list Codex MCP servers; refusing an unfiltered worker launch." | tee -a "$log_file" >&2
      status=3
      mcp_json='[]'
    fi
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
      configured_servers="$(printf '%s\n' "$mcp_json" | jq -r '
        .[] | select(.enabled != false) | [.name, .transport.type // ""] | @tsv' 2>/dev/null || true)"
      while IFS=$'\t' read -r server transport; do
        [[ -n "$server" ]] || continue
        if [[ " ${keep_mcp[*]:-} " == *" $server "* ]]; then
          continue
        fi
        # Plugin servers need a transport even when disabled; never copy credentials.
        case "$transport" in
          stdio) mcp_arguments+=(-c "mcp_servers.$server={enabled=false,command=\"false\"}") ;;
          streamable_http) mcp_arguments+=(-c "mcp_servers.$server={enabled=false,url=\"http://127.0.0.1\"}") ;;
          *) mcp_arguments+=(-c "mcp_servers.$server.enabled=false") ;;
        esac
      done <<<"$configured_servers"
    fi
    add_directory=()
    [[ "$engine_directory" != "$workspace_root" ]] && add_directory=(--add-dir "$workspace_root")
    sandbox_arguments=(--sandbox workspace-write)
    if [[ "$sandbox_mode" == 0 ]]; then
      sandbox_arguments=(--sandbox danger-full-access)
    fi
    if [[ "$yolo" == 1 ]]; then
      sandbox_arguments=(--dangerously-bypass-approvals-and-sandbox)
    fi
    profile_arguments=()
    [[ -z "$profile" ]] || profile_arguments=(--profile "$profile")
    [[ -z "$model_effort" ]] || model_arguments+=(-c "model_reasoning_effort=\"$model_effort\"")
    engine_command=(codex exec --json --cd "$engine_directory" ${profile_arguments[@]+"${profile_arguments[@]}"} --ephemeral
      --skip-git-repo-check ${sandbox_arguments[@]+"${sandbox_arguments[@]}"} ${add_directory[@]+"${add_directory[@]}"}
      ${mcp_arguments[@]+"${mcp_arguments[@]}"} ${model_arguments[@]+"${model_arguments[@]}"} --output-last-message "$absolute_report" "$prompt")
    ;;
  claude)
    # Six core tools keep the prompt small. Edits are accepted in the project;
    # shell commands run inside Claude Code's sandbox by default, and can be
    # disabled with --no-sandbox or SQUAD_WORKER_SANDBOX=0.
    claude_settings='{"sandbox":{"enabled":true,"autoAllowBashIfSandboxed":true}}'
    if [[ "$sandbox_mode" == 0 ]]; then
      claude_settings='{"sandbox":{"enabled":false}}'
    fi
    claude_allowed_tools=()
    if [[ -n "${SQUAD_WORKER_CLAUDE_ALLOWED_TOOLS:-}" ]]; then
      claude_allowed_tools=(--allowedTools "$SQUAD_WORKER_CLAUDE_ALLOWED_TOOLS")
    fi
    permission_arguments=(--permission-mode "${SQUAD_WORKER_CLAUDE_PERMISSION_MODE:-acceptEdits}")
    [[ "$yolo" == 1 ]] && permission_arguments=(--dangerously-skip-permissions)
    engine_command=(claude -p --model "$model" --strict-mcp-config --disable-slash-commands
      --no-session-persistence --tools "${SQUAD_WORKER_CLAUDE_TOOLS:-Read,Edit,Write,Glob,Grep,Bash}"
      "${permission_arguments[@]}"
      ${claude_allowed_tools[@]+"${claude_allowed_tools[@]}"} --settings "$claude_settings"
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
    engine_command=(agy -p "$prompt" --mode accept-edits --output-format stream-json)
    [[ "$yolo" == 1 ]] && engine_command+=(--dangerously-skip-permissions)
    [[ -z "$model_effort" ]] || engine_command+=(--effort "$model_effort")
    [[ -n "$model" ]] && engine_command+=(--model "$model")
    ;;
  opencode)
    engine_command=(opencode run "$prompt")
    [[ -n "$model" ]] && engine_command+=(--model "$model")
    ;;
esac

# Native AGY streams end with {event:result,result:{status,response}} and may
# interleave plain diagnostics (ignored); accept only one valid terminal SUCCESS. Claude-
# shaped and plain-text output stay supported. Damaged or
# non-object JSON is never plaintext.
agy_extract_report() {
  local verdict
  verdict="$(jq -R -s -r '
    [split("\n")[] | select(test("\\S")) | sub("^\\s+";"") | sub("\\s+$";"") | . as $s | (try {v: fromjson} catch null) as $p
     | if $p == null then (if $s | test("^[{\\[]") then {bad: true} elif $s | test("^root agent idle; waiting for ") then {} else {text: true} end)
       elif ($p.v | type) == "object" then {o: $p.v} else {bad: true} end] as $l
    | [$l[] | .o // empty] as $objs
    | if any($l[]; .bad) then "damaged JSON in stream"
      elif any($objs[]; has("event")) then
        [$objs[] | select(.event == "result")] as $r
        | if any($objs[]; .event == "error" or has("error")) then "stream contains an error event"
          elif ($r | length) != 1 then "expected exactly one terminal result, found \($r | length)"
          elif ($objs[-1].event != "result") then "events follow the terminal result"
          elif ($r[0].result.status // "") != "SUCCESS" then "terminal status \($r[0].result.status // "missing")"
          elif (($r[0].result.response | type) != "string") or (($r[0].result.response | test("\\S")) | not) then "terminal SUCCESS has no response"
          else "ok:" + $r[0].result.response end
      elif any($objs[]; .type == "result") then
        ([$objs[] | select(.type == "result") | .result // empty] | join("\n")) as $t
        | if $t == "" then "result has no text" else "ok:" + $t end
      elif ($objs | length) > 0 then "no result event in stream"
      elif any($l[]; .text) then "plain:" else "no report in stream" end' "$absolute_log" 2>/dev/null || echo 'unparseable stream')"
  case "$verdict" in
    ok:*) printf '%s\n' "${verdict#ok:}" >"$absolute_report" ;;
    plain:) cp "$absolute_log" "$absolute_report" ;;
    *) printf '\nsquad-worker: AGY stream rejected: %s\n' "$verdict" >>"$absolute_log" ;;
  esac
}

run_engine() {
  cd "$engine_directory"
  unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT
  case "$engine" in
    ccr)
      eval "$(ccr activate 2>/dev/null)"
      "${engine_command[@]}" </dev/null >"$absolute_log" 2>&1 || return $?
      jq -R -r 'fromjson? | select(.type == "result") | .result // empty' "$absolute_log" >"$absolute_report"
      ;;
    claude)
      "${engine_command[@]}" </dev/null >"$absolute_log" 2>&1 || return $?
      jq -R -r 'fromjson? | select(.type == "result") | .result // empty' "$absolute_log" >"$absolute_report"
      ;;
    agy)
      "${engine_command[@]}" </dev/null >"$absolute_log" 2>&1 || return $?
      agy_extract_report
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
  if [[ "$engine" == ccr || "$engine" == claude || "$engine" == agy ]] && ! command -v jq >/dev/null 2>&1; then
    echo "jq is required for the $engine engine" | tee -a "$log_file" >&2
    status=1
  fi
fi
timeout_seconds="${SQUAD_WORKER_TIMEOUT_SECONDS:-$(( timeout_minutes * 60 ))}"
stall_seconds="${SQUAD_WORKER_STALL_SECONDS:-$(( stall_minutes * 60 ))}"
if (( status == 0 )); then
  run_engine &
  engine_pid=$!
  # Watchdog: stop runs that exceed the time limit or stop producing output,
  # so a stuck worker reports back instead of leaving its pane pending.
  model_log_size=-1
  while kill -0 "$engine_pid" 2>/dev/null; do
    sleep 1
    current_log_size="$(wc -c <"$log_file")"
    if [[ "$current_log_size" != "$model_log_size" ]]; then
      model_log_size="$current_log_size"
      reported_model="$(squad_worker_reported_models "$engine" "$log_file")"
      if [[ -n "$reported_model" && "$reported_model" != "$actual_model" ]]; then
        actual_model="$reported_model"
        write_status running
      fi
    fi
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

reported_model="$(squad_worker_reported_models "$engine" "$log_file")"
[[ -z "$reported_model" ]] || actual_model="$reported_model"

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
  changed_files=0
  if [[ -s "$patch_file" ]]; then
    changed_files="$(git apply --numstat "$patch_file" 2>/dev/null | wc -l | tr -d ' ')"
  fi
  worktree_note="Worktree: $changed_files changed file(s) in $worktree_path (branch squad/$worker_id). Review: git -C $worktree_path diff $worktree_base_commit. Merge: squad-worker --merge $worker_id. Discard: squad-worker --discard $worker_id."
fi

report=""
if [[ -s "$report_file" ]]; then
  report="$(cat "$report_file")"
fi
if (( status != 0 )) || [[ -z "${report//[[:space:]]/}" ]]; then
  if [[ -z "${report//[[:space:]]/}" ]]; then
    failure_reason="${stop_reason:-worker returned no report (engine exit $status)}"
  fi
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
