#!/usr/bin/env bash
set -euo pipefail
# Background jobs share the launcher's process group, which CLIs kill when their command ends.
# Start a separate session; exec keeps the PID used by notifications and status files.
if [[ -z "${SQUAD_WORKER_DETACHED:-}" && ! -t 1 ]] && command -v perl >/dev/null 2>&1; then
  export SQUAD_WORKER_DETACHED=1
  exec perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV or die "exec: $!\n"' -- "$0" "$@"
fi

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
# shellcheck source=lib/squad-plan.sh
source "$script_dir/lib/squad-plan.sh"
# shellcheck source=lib/squad-engine.sh
source "$script_dir/lib/squad-engine.sh"

usage() {
  cat <<'EOF'
Usage: squad-worker <worker-id> --engine ENGINE (--brief TEXT | --brief-file FILE)
                    [--role ROLE] [--title TITLE] [--project DIR]
                    [--profile PROFILE] [--model MODEL] [--mcp NAME]... [--all-mcp]
                    [--timeout MINUTES] [--manager ID] [--sandbox | --no-sandbox]
                    [--plan FILE | --no-plan "REASON"] [--clone URL] [--init]
                    [--own PATHS] [--no-plan-context]
       squad-worker --list
       squad-worker --stop <worker-id|all>
       squad-worker --merge <worker-id> [--project DIR] [--override-review "REASON"]
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
  --plan FILE        Plan the work follows (see templates/devkit/plan.md.example);
                     validated, recorded in the status file and the report. Required
                     in manager context (--manager, SQUAD_MANAGER_ID, or
                     SQUAD_WORKER_REQUIRE_PLAN=1; SQUAD_WORKER_REQUIRE_PLAN=0 disables)
  --no-plan REASON   Run without a plan and record why (excludes --plan)
  --no-plan-context  Do not add the plan's Goal, Findings and Decisions (and an optional
                     <plan>.context.md) to the worker's prompt
  --own PATHS        Comma-separated files, directories or globs this worker may change
                     (repeatable). Changes elsewhere are recorded as scope_violation and
                     --merge refuses them unless --override-review is given
  --clone URL        git clone URL into --project first, if that directory is missing
  --init             Create --project if missing and git init it (no commits);
                     a repository without commits runs in place, without a worktree
  --override-review REASON
                     With --merge: merge despite a missing review of a high-risk or
                     sensitive patch; the reason is recorded in the plan
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
manager_flag_set=""
plan_argument=""
no_plan_reason=""
clone_url=""
init_project=0
override_review=""
owned_paths=""
no_plan_context=0
verdict=""
scope_violation=""
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
# Collapses a free-text reason to one trimmed line of at most 200 characters and
# prints it: one_line_reason <flag> <text>. Returns 1 when nothing is left.
one_line_reason() {
  local text
  text="$(printf '%s' "$2" | tr '\r\n' '  ' | awk '{ gsub(/^[ \t]+|[ \t]+$/, ""); print substr($0, 1, 200) }')"
  if [[ -z "$text" ]]; then
    echo "$1 needs a reason" >&2
    return 1
  fi
  printf '%s' "$text"
}
while (( $# > 0 )); do
  case "$1" in --models|--engine|--project) ;; *) catalog_incompatible=1 ;; esac
  case "$1" in
    --engine|--role|--title|--brief|--brief-file|--profile|--model|--model-tier|--mcp|--manager|--project|--timeout|--stop|--merge|--discard|--diff|--plan|--no-plan|--clone|--override-review|--own)
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
        --manager) manager_id="$2"; required_split=1; manager_flag_set=1 ;;
        --plan) plan_argument="$2" ;;
        --no-plan) no_plan_reason="$(one_line_reason --no-plan "$2")" || exit 2 ;;
        --clone) clone_url="$2" ;;
        --own) owned_paths="${owned_paths:+$owned_paths,}$2" ;;
        --override-review) override_review="$(one_line_reason --override-review "$2")" || exit 2 ;;
        --project) project_directory="$2" ;;
        --timeout) timeout_minutes="$2" ;;
        --stop) action=stop; stop_target="$2" ;;
        --merge) action=merge; stop_target="$2" ;;
        --discard) action=discard; stop_target="$2" ;;
        --diff) action="diff"; stop_target="$2" ;;
      esac
      shift
      ;;
    --all-mcp)
      # shellcheck disable=SC2034 # read by lib/engines/*.sh
      all_mcp=1 ;;
    --init) init_project=1 ;;
    --no-plan-context) no_plan_context=1 ;;
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

if [[ -n "$override_review" && "$action" != merge ]]; then
  echo "--override-review only applies to --merge" >&2
  exit 2
fi

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
  if [[ "$(status_get "$file" state)" == running ]]; then
    mv "$tmp" "$file"
    squad_record_status "$file"
  else rm -f "$tmp"; fi
}

# Status files of runs that are still running, newest first.
running_status_files() {
  local file
  while IFS= read -r file; do
    [[ "$(status_get "$file" state)" == running ]] && printf '%s\n' "$file"
  done < <(ls -t .squad/workers/*.status 2>/dev/null)
  return 0
}

# Status files of one worker's runs, newest first. Names are <id>-YYYYMMDD-HHMMSS.status,
# so the id match is exact (`dev` does not match `dev-1-...`).
worker_status_files() {
  local d='[0-9]'
  ls -t .squad/workers/"$1"-$d$d$d$d$d$d$d$d-$d$d$d$d$d$d.status 2>/dev/null
  return 0
}

# The newest status file of a worker's runs that used a worktree.
latest_status_with_worktree() {
  local file
  while IFS= read -r file; do
    [[ -n "$(status_get "$file" worktree)" ]] && { printf '%s\n' "$file"; return 0; }
  done < <(worker_status_files "$1")
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

# Why a patch needs a review before it is merged, one reason per line. The patch is
# read per file. Only *.md, *.mdx and *.rst count as documentation: they skip the
# security-folder and content checks, but secret-looking paths and private keys are
# checked in every file. Both sides of a rename are checked.
sensitive_reasons() {
  if squad_supports plan; then squad plan check-patch "$@"; return $?; fi
  awk '
    function is_doc(path,   lower) {
      lower = tolower(path)
      return lower ~ /\.(md|mdx|rst)$/
    }
    function path_sensitive(path, doc,   lower, n, parts, i, stem) {
      lower = tolower(path)
      if (lower ~ /secret|credential|password|private[_-]key/) return 1
      if (lower ~ /token(s)?([^a-z]|$)/) return 1
      if (lower ~ /_headers|netlify\.toml|vercel\.json/) return 1
      if (!doc && lower ~ /security/) return 1
      n = split(lower, parts, "/")
      for (i = 1; i <= n; i++) {
        if (parts[i] == ".env" || parts[i] ~ /^\.env\./) return 1
        stem = parts[i]
        sub(/\..*$/, "", stem)
        if (stem ~ /^o?auth/ && stem !~ /^author/) return 1
      }
      return 0
    }
    function report(path) {
      if (path in seen) return
      seen[path] = 1
      if (path_sensitive(path, is_doc(path))) print "patch touches " path
    }
    /^diff --git / {
      rest = $0
      sub(/^diff --git /, "", rest)
      gsub(/"/, "", rest)
      len = length(rest)
      a = ""
      b = ""
      if (len % 2 == 1) {
        half = (len - 5) / 2
        if (half > 0 && substr(rest, 1, 2) == "a/" && substr(rest, half + 3, 3) == " b/" &&
            substr(rest, 3, half) == substr(rest, half + 6)) {
          a = substr(rest, 3, half)
          b = a
        }
      }
      if (a == "") {
        # A rename (or an unusual header): split at the first " b/".
        i = index(rest, " b/")
        if (i > 0) {
          a = substr(rest, 1, i - 1)
          sub(/^a\//, "", a)
          b = substr(rest, i + 3)
        } else {
          a = rest
          b = rest
        }
      }
      report(a)
      if (b != a) report(b)
      doc = is_doc(a) && is_doc(b)
      next
    }
    $0 !~ /^[+-]/ || $0 ~ /^(\+\+\+|---)/ { next }
    {
      low = tolower($0)
      if ($0 ~ /BEGIN [A-Za-z ]*PRIVATE KEY/ && !pk++) print "patch changes a private key"
      if (doc) next
      if (low ~ /content-security-policy/ && !csp++) print "patch changes a Content-Security-Policy line"
      if (low ~ /authorization/ && !authz++) print "patch changes an Authorization line"
      if (low ~ /api[_-]?key/ && !apikey++) print "patch changes an API key line"
    }
  ' "$1"
}

# Prints the files from stdin (one per line) that no --own pattern covers.
# A pattern matches a path exactly, as a glob, or as a directory prefix:
# scope_violations <comma-separated patterns> < file-list.
scope_violations() {
  local file pattern ok
  local patterns=()
  IFS=',' read -r -a patterns <<<"$1"
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    ok=0
    for pattern in ${patterns[@]+"${patterns[@]}"}; do
      pattern="${pattern#"${pattern%%[![:space:]]*}"}"
      pattern="${pattern%"${pattern##*[![:space:]]}"}"
      pattern="${pattern%/}"
      [[ -n "$pattern" ]] || continue
      # shellcheck disable=SC2053 # the pattern is deliberately a glob
      if [[ "$file" == $pattern || "$file" == $pattern/* ]]; then ok=1; break; fi
    done
    (( ok == 1 )) || printf '%s\n' "$file"
  done
  return 0
}

# True when another worker with role reviewer finished the same plan after the
# target's last finish: review_exists <target status file> <plan>. A reviewer whose
# verdict is changes_requested never counts; the newest such reviewer is left in
# $review_blocker so the gate can say why. A reviewer without a verdict (older
# runs, or a report that omits it) still counts, as before.
review_exists() {
  local target_status="$1" plan="$2" target_finished file finished state verdict newest=0 latest=""
  review_blocker=""
  # A worker without a real plan cannot be reviewed against one.
  [[ -n "$plan" && "$plan" != none ]] || return 1
  target_finished="$(status_get "$target_status" finished)"
  target_finished="${target_finished:-0}"
  while IFS= read -r file; do
    [[ "$(status_get "$file" role)" == reviewer ]] || continue
    [[ "$(status_get "$file" worker)" != "$(status_get "$target_status" worker)" ]] || continue
    [[ "$(status_get "$file" plan)" == "$plan" ]] || continue
    state="$(status_get "$file" state)"
    [[ "$state" == "completed" || "$state" == "done" ]] || continue
    finished="$(status_get "$file" finished)"
    if [[ "$finished" =~ ^[0-9]+$ ]] && (( finished > target_finished )); then
      if (( finished > newest )); then
        newest="$finished"
        latest="$file"
      elif (( finished == newest )) && [[ "$(status_get "$file" verdict)" == changes_requested ]]; then
        latest="$file"
      fi
    fi
  done < <(ls -t .squad/workers/*.status 2>/dev/null)
  [[ -n "$latest" ]] || return 1
  verdict="$(status_get "$latest" verdict)"
  if [[ "$verdict" == changes_requested ]]; then
    review_blocker="$(status_get "$latest" worker) ($(status_get "$latest" report))"
    return 1
  fi
  return 0
}

# Returns 1 for a high-risk plan's or sensitive patch without a review, or for
# changes outside --own, unless --override-review was given:
# review_gate <target> <patch file>.
review_gate() {
  local target="$1" patch="$2" file plan="" reasons="" sensitive scope="" owned="" paths record path
  file="$(worker_status_files "$target" | head -n 1)"
  [[ -z "$file" ]] || plan="$(status_get "$file" plan)"
  [[ -z "$file" ]] || owned="$(status_get "$file" owned)"
  if [[ -n "$owned" ]]; then
    # Parse the captured no-renames patch, never the worker's mutable HEAD.
    if ! paths="$(
      set -o pipefail
      git apply --numstat -z -- "$patch" | while IFS= read -r -d '' record; do
        path="${record#*$'\t'}"
        path="${path#*$'\t'}"
        # Scope input is line-delimited; reject paths it cannot represent safely.
        if [[ -z "$path" || "$path" == *$'\n'* || "$path" == *$'\r'* ]]; then
          echo "unsupported filename in ownership check" >&2
          exit 1
        fi
        printf '%s\n' "$path"
      done
    )"; then
      echo "squad-worker: cannot check ownership for $target." >&2
      return 1
    fi
    scope="$(printf '%s\n' "$paths" | scope_violations "$owned" | paste -sd ',' -)"
  fi
  if [[ -n "$scope" ]]; then
    if [[ -n "$override_review" ]]; then
      echo "squad-worker: scope override for $target ($scope): $override_review"
      if [[ -n "$plan" && "$plan" != none && -f "$plan" ]]; then
        plan_append_approval "$plan" "- review-override: $target — scope: $override_review ($(date +%Y-%m-%d))"
      fi
    else
      echo "squad-worker: merging $target blocked: it changed files outside its --own scope: $scope. Discard those changes with a fix round, or pass --override-review \"<reason>\"." >&2
      return 1
    fi
  fi
  if [[ -n "$plan" && "$plan" != none && -f "$plan" && "$(plan_field "$plan" risk)" == high ]]; then
    reasons="plan risk is high"
  fi
  sensitive="$(sensitive_reasons "$patch" | paste -sd ';' - | sed 's/;/; /g')"
  reasons="${reasons:+$reasons; }$sensitive"
  reasons="${reasons%; }"
  [[ -n "$reasons" ]] || return 0
  if [[ -n "$file" ]] && review_exists "$file" "$plan"; then
    return 0
  fi
  if [[ -n "$override_review" ]]; then
    echo "squad-worker: review override for $target: $override_review"
    if [[ -n "$plan" && "$plan" != none && -f "$plan" ]]; then
      plan_append_approval "$plan" "- review-override: $target — $override_review ($(date +%Y-%m-%d))"
    fi
    return 0
  fi
  if [[ -n "${review_blocker:-}" ]]; then
    echo "squad-worker: merging $target blocked: reviewer $review_blocker requested changes. Fix the issues and rerun the reviewer on the same plan, or pass --override-review \"<reason>\"." >&2
    return 1
  fi
  if [[ -z "$plan" || "$plan" == none ]]; then
    echo "squad-worker: merging $target needs a review: $reasons. $target has no plan, so a reviewer cannot satisfy the gate: rerun the worker with --plan <plan>, or pass --override-review \"<reason>\"." >&2
    return 1
  fi
  echo "squad-worker: merging $target needs a review: $reasons. Run a reviewer with --plan $plan, or pass --override-review \"<reason>\"." >&2
  return 1
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
    elif ! review_gate "$target" "$patch_file"; then
      exit_status=3
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
  # shellcheck disable=SC2034 # read by lib/engines/*.sh
  sandbox_mode=0
fi
if [[ -n "$plan_argument" && -n "$no_plan_reason" ]]; then
  echo "--plan and --no-plan are mutually exclusive" >&2
  exit 2
fi
if [[ -n "$no_plan_reason" && -z "${no_plan_reason//[[:space:]]/}" ]]; then
  echo "--no-plan needs a reason" >&2
  exit 2
fi
if [[ -n "$clone_url" && -z "$project_directory" ]]; then
  echo "--clone needs --project" >&2
  exit 2
fi
# Manager context: a plan is required unless SQUAD_WORKER_REQUIRE_PLAN=0.
manager_context=0
if [[ -n "$manager_flag_set" || -n "${SQUAD_MANAGER_ID:-}" || "${SQUAD_WORKER_REQUIRE_PLAN:-}" == 1 ]]; then
  manager_context=1
fi
[[ "${SQUAD_WORKER_REQUIRE_PLAN:-}" != 0 ]] || manager_context=0
if (( manager_context == 1 )) && [[ -z "$plan_argument" && -z "$no_plan_reason" ]]; then
  echo 'squad-worker: a plan is required in manager context. Pass --plan .squad/plans/<name>.md (see templates/devkit/plan.md.example) or --no-plan "<reason>".' >&2
  exit 2
fi
plan_path=none
plan_line="Plan: none (override: ${no_plan_reason:-no plan given})"
if [[ -n "$plan_argument" ]]; then
  plan_directory="$(cd "$(dirname "$plan_argument")" 2>/dev/null && pwd || true)"
  plan_path="${plan_directory:-$(dirname "$plan_argument")}/$(basename "$plan_argument")"
  if ! plan_problems="$(plan_validate "$plan_path")"; then
    {
      echo "squad-worker: plan $plan_path is incomplete:"
      printf '%s\n' "$plan_problems" | sed 's/^/  /'
    } >&2
    exit 2
  fi
  plan_line="Plan: $plan_path"
fi
plan_context=""
if [[ "$plan_path" != none ]] && (( no_plan_context == 0 )); then
  plan_context="$(plan_shared_context "$plan_path")"
fi
squad_engine_load "$engine" || exit 2
if [[ ! "$timeout_minutes" =~ ^[0-9]+$ || "$timeout_minutes" =~ ^0+$ || ! "$stall_minutes" =~ ^[0-9]+$ ]]; then
  echo "--timeout (at least 1) and SQUAD_WORKER_STALL take whole minutes" >&2
  exit 2
fi
squad_worker_select_model
model_arguments=()
# shellcheck disable=SC2034 # read by lib/engines/*.sh
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
squad_engine check_deps

if [[ -n "$clone_url" ]]; then
  if [[ -d "$project_directory" ]]; then
    echo "squad-worker: $project_directory already exists; ignoring --clone."
  else
    require_command git
    GIT_ALLOW_PROTOCOL="${GIT_ALLOW_PROTOCOL:-file:git:http:https:ssh}" \
      git clone -- "$clone_url" "$project_directory" || exit 1
  fi
fi
if (( init_project == 1 )) && [[ -n "$project_directory" ]]; then
  require_command git
  project_existed=0
  [[ ! -d "$project_directory" ]] || project_existed=1
  mkdir -p "$project_directory"
  if ! git -C "$project_directory" rev-parse --git-dir >/dev/null 2>&1; then
    (( project_existed == 0 )) || echo "squad-worker: initialising a git repository in $project_directory."
    git -C "$project_directory" init -q -b main 2>/dev/null || {
      git -C "$project_directory" init -q
      git -C "$project_directory" symbolic-ref HEAD refs/heads/main
    }
  fi
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
  elif [[ "$worktree_mode" != 1 ]] && ! git -C "$repository_root" rev-parse -q --verify HEAD >/dev/null 2>&1; then
    echo "squad-worker: $project_directory has no commits yet; running $worker_id in place (no worktree)."
    repository_root=""
  elif worktree_path="$(worktree_create "$repository_root" "$worker_id")"; then
    worktree_base_commit="$(worktree_base "$repository_root" "$worker_id")"
    prefix="$(git -C "$project_directory" rev-parse --show-prefix)"
    engine_directory="$worktree_path${prefix:+/${prefix%/}}"
  else
    echo "Could not create a worktree for $worker_id in $repository_root" >&2
    exit 1
  fi
fi

# Agent settings under .claude/ stay out of the repository's status.
worktree_exclude_claude "$engine_directory"

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
# shellcheck disable=SC2034 # read by lib/engines/*.sh
prompt="You are $worker_id, a $role worker in a squad led by $manager_id. You run once, without a human at the keyboard.
${role_instructions:+
$role_instructions
}
## Task $task_id: $title

Working directory: $engine_directory${worktree_path:+
This is your own git worktree of $repository_root, isolated from other workers. The manager reviews and merges your changes, so do not commit, push, or switch branches.}

$plan_line
${plan_context:+
## Shared plan context (Goal, Findings and Decisions from the plan)
$plan_context}${owned_paths:+
Files you own (change nothing else): $owned_paths
}
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
configured_model=unknown
configured_model_source=unknown
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
    if [[ "$engine" == agy ]]; then
      printf 'configured_model=%s\nconfigured_model_source=%s\n' "$configured_model" "$configured_model_source"
    fi
    printf 'title=%s\ntask=%s\nstate=%s\nreason=%s\n' \
      "$(printf '%s' "$title" | tr '\n' ' ')" "$task_id" "$state" "${failure_reason:-$stop_reason}"
    printf 'process_started=%s\n' "$process_started"
    printf 'pid=%s\nstarted=%s\nfinished=%s\nexit=%s\n' "$$" "$started_at" "$finished" "$exit_status"
    printf 'tokens_in=%s\ntokens_cached=%s\ntokens_out=%s\n' "$tokens_in" "$tokens_cached" "$tokens_out"
    printf 'verdict=%s\nowned=%s\nscope_violation=%s\n' "$verdict" "$owned_paths" "$scope_violation"
    printf 'project=%s\nlog=%s\nreport=%s\n' "$project_directory" \
      "$workspace_root/$log_file" "$workspace_root/$report_file"
    printf 'repository=%s\nworktree=%s\nbase=%s\npatch=%s\n' "$repository_root" "$worktree_path" \
      "$worktree_base_commit" "${patch_file:+$workspace_root/$patch_file}"
    if [[ "$plan_path" == none ]]; then
      printf 'plan=none\nplan_override=%s\n' "$no_plan_reason"
    else
      printf 'plan=%s\n' "$plan_path"
    fi
  } >"$status_file.tmp"
  mv "$status_file.tmp" "$status_file"
  squad_record_status "$status_file"
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

# Each engine reads the prompt and writes its final report to $report_file and
# its activity (JSON events where the engine supports them) to $log_file.
# shellcheck disable=SC2034 # read by lib/engines/*.sh
absolute_report="$workspace_root/$report_file"
# shellcheck disable=SC2034 # read by lib/engines/*.sh
absolute_log="$workspace_root/$log_file"
# shellcheck disable=SC2034 # read by lib/engines/*.sh
engine_command=()
status=0
squad_engine build_command || status=$?

run_engine() {
  cd "$engine_directory"
  unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT
  squad_engine run_and_extract_report
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
      reported_model="$(squad_engine reported_models "$log_file")"
      model_changed=0
      if [[ -n "$reported_model" && "$reported_model" != "$actual_model" ]]; then
        actual_model="$reported_model"
        model_changed=1
      fi
      if [[ "$engine" == agy ]]; then
        reported_configured="$(squad_worker_agy_configured_model "$log_file")"
        if [[ -n "$reported_configured" && ( "$reported_configured" != "$configured_model" || "$configured_model_source" != agy-init ) ]]; then
          configured_model="$reported_configured"
          configured_model_source=agy-init
          model_changed=1
        fi
      fi
      [[ "$model_changed" == 0 ]] || write_status running
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

reported_model="$(squad_engine reported_models "$log_file")"
[[ -z "$reported_model" ]] || actual_model="$reported_model"
if [[ "$engine" == agy ]]; then
  reported_configured="$(squad_worker_agy_configured_model "$log_file")"
  if [[ -n "$reported_configured" ]]; then
    configured_model="$reported_configured"
    configured_model_source=agy-init
  fi
fi

# Token usage, summed from the engine's JSON events, for the monitor and the
# savings summary.
if command -v jq >/dev/null 2>&1 && [[ -s "$log_file" ]]; then
  usage_line="$(jq -R -r -s '
    [split("\n")[] | fromjson? | select(type == "object")
     | (select(.type == "turn.completed") | .usage), (select(.type == "result") | .usage // empty),
       (select(.type == "step_finish") | .part.tokens // empty)]
    | map(if has("input_tokens") then
        {in: ((.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0)),
         cached: (.cached_input_tokens // .cache_read_input_tokens // 0),
         out: (.output_tokens // 0)}
      else
        {in: ((.input // 0) + (.cache.read // 0) + (.cache.write // 0)),
         cached: (.cache.read // 0),
         out: ((.output // 0) + (.reasoning // 0))}
      end)
    | if length == 0 then "" else
      [ (map(.in) | add), (map(.cached) | add), (map(.out) | add) ] | map(tostring) | join(" ") end' "$log_file" 2>/dev/null || true)"
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
  if [[ -n "$owned_paths" ]]; then
    scope_violation="$(git -C "$worktree_path" diff --no-renames --name-only "$worktree_base_commit" HEAD -- . ':(exclude).claude' ':(exclude,glob)**/.claude/**' 2>/dev/null |
      scope_violations "$owned_paths" | paste -sd ',' -)"
    [[ -z "$scope_violation" ]] || worktree_note+=" Scope violation (outside --own): $scope_violation."
  fi
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

if [[ "$role" == reviewer || "$role" == security ]]; then
  verdict_line="$(printf '%s\n' "$report" | grep -iE '^[[:space:]*`_]*VERDICT:[[:space:]]*(APPROVED|CHANGES_REQUESTED)' | tail -n 1 | tr '[:lower:]' '[:upper:]' || true)"
  case "$verdict_line" in
    *CHANGES_REQUESTED*) verdict=changes_requested ;;
    *APPROVED*) verdict=approved ;;
    *) verdict=missing ;;
  esac
fi
write_status completed 0
report="$plan_line

$report"
printf '%s\n' "$report" >"$report_file"
squad task complete "$worker_id" "$task_id" --summary "$(printf '%s' "$report" | cut -c1-4000)" >/dev/null
squad send --task-id "$task_id" "$worker_id" "$manager_id" \
  "$worker_id ($engine) completed task $task_id. Report: $workspace_root/$report_file${worktree_note:+ $worktree_note}" >/dev/null || true
printf '[%s · %s · task %s] report: %s\n%s\n%s\n' \
  "$worker_id" "$engine" "$task_id" "$workspace_root/$report_file" "${worktree_note:+$worktree_note
}" "$report"
