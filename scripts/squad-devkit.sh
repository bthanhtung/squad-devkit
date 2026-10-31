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
source "$script_dir/lib/squad-tmux-launcher-helpers.sh"
source "$script_dir/lib/squad-devkit-agents.sh"

devkit_version="1.0.1"

usage() {
  cat <<'EOF'
Usage: squad-devkit [project-name-or-directory] [objective] [--task objective]
                    [--manager CLI] [--setup] [--list] [--ghostty] [--tmux]
                    [--dry-run] [--no-attach] [--no-prompt]

Start a manager (Claude Code by default) for a project in the current terminal.
The manager plans and starts on-demand Codex or CCR workers with squad-worker
when work needs delegating; no worker runs, or costs tokens, while idle.
If Claude Code is not installed, the first run asks which installed CLI
(codex, agy, gemini, grok, opencode) should manage, and remembers the answer.
Defaults to the git repository containing the current directory. Pass a project
name to search ~/Workspace (up to 8 levels), or a directory to launch from anywhere. Existing
directories take priority; duplicate names require an explicit path.
Set SQUAD_DEVKIT_PROJECT_ROOT to search a different workspace directory.
With no project argument it uses the repository containing the current
directory. Started from your home directory, it opens the manager in the
general workspace (~/.squad-devkit): describe the work in the chat and the
manager finds the repositories involved.
Pass an objective after the project, or with --task, to start planning immediately.
Without an objective the manager opens an interactive chat and asks for one first.

  --manager CLI Manager CLI for this run: claude, codex, agy, gemini, grok, or
                opencode (or set SQUAD_DEVKIT_MANAGER)
  --setup       Choose and save the default manager CLI, then exit
  --ghostty     Open the manager in a new Ghostty window instead of this terminal
  --tmux        Run the manager in a tmux session; re-running attaches to it
                (or set SQUAD_DEVKIT_BACKEND=here|ghostty|tmux)
  --task TEXT   Objective for the manager; supports spaces when quoted
  --list        List the git projects found on this machine and exit
  --clean       Prune finished worker runs (logs, reports) in the project's squad
                workspace older than SQUAD_DEVKIT_RETENTION_DAYS (7) or beyond
                SQUAD_DEVKIT_MAX_MB (200), then exit; every launch does this too
  --clean-all   Remove every finished worker run, then exit
  --no-prompt   Skip the first-run manager question (or set SQUAD_DEVKIT_NO_PROMPT)
  --dry-run     Show the manager command without changing the project
  --no-attach   tmux only: start the session in the background
  --version     Print the squad-devkit version
EOF
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing command: $1" >&2
    exit 1
  fi
}

project_directory=""
objective=""
no_prompt=0
list_projects=0
clean_only=0
if is_truthy "${SQUAD_DEVKIT_NO_PROMPT:-}"; then
  no_prompt=1
fi
dry_run=0
no_attach=0
setup=0
manager_client="${SQUAD_DEVKIT_MANAGER:-}"
backend="${SQUAD_DEVKIT_BACKEND:-here}"
while (( $# > 0 )); do
  case "$1" in
    --here) backend=here ;;
    --tmux) backend=tmux ;;
    --ghostty) backend=ghostty ;;
    --dry-run) dry_run=1 ;;
    --no-attach) no_attach=1 ;;
    --no-prompt) no_prompt=1 ;;
    --list) list_projects=1 ;;
    --clean) clean_only=1 ;;
    --clean-all) clean_only=2 ;;
    --setup) setup=1 ;;
    --manager)
      if (( $# < 2 )) || [[ -z "$2" ]]; then
        echo "Missing value for $1" >&2
        exit 2
      fi
      manager_client="$2"
      shift
      ;;
    --manager=*) manager_client="${1#*=}" ;;
    --task|--prompt)
      if (( $# < 2 )) || [[ -z "$2" ]]; then
        echo "Missing value for $1" >&2
        exit 2
      fi
      objective="$2"
      shift
      ;;
    --task=*|--prompt=*) objective="${1#*=}" ;;
    -h|--help) usage; exit 0 ;;
    --version) printf 'squad-devkit %s\n' "$devkit_version"; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)
      if [[ -n "$project_directory" ]]; then
        if [[ -n "$objective" ]]; then
          echo "Only one objective is allowed" >&2
          exit 2
        fi
        objective="$1"
      else
        project_directory="$1"
      fi
      ;;
  esac
  shift
done
if [[ "$backend" != here && "$backend" != ghostty && "$backend" != tmux ]]; then
  echo "Unknown backend: $backend (use here, ghostty, or tmux)" >&2
  exit 2
fi
if [[ -z "$objective" && -n "${SQUAD_DEVKIT_TASK:-}" ]]; then
  objective="$SQUAD_DEVKIT_TASK"
fi

search_roots() {
  if [[ -n "${SQUAD_DEVKIT_PROJECT_ROOT:-}" ]]; then
    printf '%s\n' "$SQUAD_DEVKIT_PROJECT_ROOT"
    return 0
  fi
  local root=""
  for root in "$HOME/Workspace" "$HOME/Projects" "$HOME/Developer" "$HOME/code" "$HOME/src"; do
    [[ -d "$root" ]] && printf '%s\n' "$root"
  done
  return 0
}

search_roots_display() {
  local root=""
  local joined=""
  while IFS= read -r root; do
    [[ -n "$root" ]] || continue
    if [[ -n "$joined" ]]; then
      joined+=", "
    fi
    joined+="$root"
  done < <(search_roots)
  printf '%s' "${joined:-$HOME/Workspace}"
}

find_project_matches() {
  local requested_name="$1"
  local root=""
  local marker=""
  local candidate=""
  local resolved=""
  local seen=""
  while IFS= read -r root; do
    [[ -n "$root" && -d "$root" ]] || continue
    while IFS= read -r marker; do
      [[ -n "$marker" ]] || continue
      candidate="$(dirname "$marker")"
      [[ "$(basename "$candidate")" == "$requested_name" ]] || continue
      git -C "$candidate" rev-parse --show-toplevel >/dev/null 2>&1 || continue
      resolved="$(cd "$candidate" && pwd -P)"
      case ":$seen:" in
        *":$resolved:"*) continue ;;
      esac
      seen+=":$resolved"
      printf '%s\n' "$resolved"
    done < <(find "$root" -maxdepth 8 \
      -type d \( -name node_modules -o -name .next -o -name .gradle \
        -o -name target -o -name build -o -name dist -o -name .cache \) -prune \
      -o -name .git \( -type d -o -type f \) -print -prune 2>/dev/null)
  done < <(search_roots)
}

resolve_project_reference() {
  local reference="$1"
  # The user typed a literal tilde; expand it ourselves.
  # shellcheck disable=SC2088
  if [[ "$reference" == "~" ]]; then
    reference="$HOME"
  elif [[ "$reference" == "~/"* ]]; then
    reference="$HOME/${reference#\~/}"
  fi
  local matches=()
  local filtered=()
  local match=""
  if [[ -d "$reference" ]]; then
    printf '%s\n' "$reference"
    return 0
  fi
  local search_name="$reference"
  local suffix_filter=""
  if [[ "$reference" == */* ]]; then
    if [[ "$reference" == /* ]]; then
      echo "Project directory does not exist: $reference" >&2
      return 1
    fi
    search_name="${reference##*/}"
    suffix_filter="/$reference"
  fi
  while IFS= read -r match; do
    [[ -n "$match" ]] && matches+=("$match")
  done < <(find_project_matches "$search_name")
  if [[ -n "$suffix_filter" ]]; then
    for match in ${matches[@]+"${matches[@]}"}; do
      [[ "$match" == *"$suffix_filter" ]] && filtered+=("$match")
    done
    matches=(${filtered[@]+"${filtered[@]}"})
  fi
  case "${#matches[@]}" in
    0)
      echo "Project '$reference' not found in: $(search_roots_display)" >&2
      return 1
      ;;
    1) printf '%s\n' "${matches[0]}" ;;
    *)
      echo "Multiple projects named '$reference'. Pass one of these paths:" >&2
      printf '  %s\n' "${matches[@]}" >&2
      return 1
      ;;
  esac
}

resolve_project_directory() {
  local candidate="$1"
  local toplevel=""
  if [[ ! -d "$candidate" ]]; then
    echo "Project directory does not exist: $candidate" >&2
    return 1
  fi
  if ! toplevel="$(git -C "$candidate" rev-parse --show-toplevel 2>/dev/null)"; then
    (cd "$candidate" && pwd -P)
    return 0
  fi
  (cd "$toplevel" && pwd -P)
}

print_projects() {
  local root=""
  local marker=""
  local candidate=""
  local resolved=""
  local seen=""
  {
    while IFS= read -r root; do
      [[ -n "$root" && -d "$root" ]] || continue
      while IFS= read -r marker; do
        [[ -n "$marker" ]] || continue
        candidate="$(dirname "$marker")"
        git -C "$candidate" rev-parse --show-toplevel >/dev/null 2>&1 || continue
        resolved="$(cd "$candidate" && pwd -P)"
        case ":$seen:" in
          *":$resolved:"*) continue ;;
        esac
        seen+=":$resolved"
        printf '%s\t%s\n' "$(basename "$resolved")" "$resolved"
      done < <(find "$root" -maxdepth 8 \
        -type d \( -name node_modules -o -name .next -o -name .gradle \
          -o -name target -o -name build -o -name dist -o -name .cache \) -prune \
        -o -name .git \( -type d -o -type f \) -print -prune 2>/dev/null)
    done < <(search_roots)
  } | LC_ALL=C sort -u
}

# A single argument of three or more words that names no project is the
# objective, not a project: squad-devkit "check the deploy logs".
if [[ -n "$project_directory" && -z "$objective" ]] &&
  (( $(printf '%s' "$project_directory" | wc -w) >= 3 )) &&
  ! resolve_project_reference "$project_directory" >/dev/null 2>&1; then
  objective="$project_directory"
  project_directory=""
fi

if (( list_projects == 1 )); then
  printf 'Projects found in: %s\n' "$(search_roots_display)"
  print_projects
  exit 0
fi

interactive=0
if (( no_prompt == 0 )) && { [[ -t 0 ]] || is_truthy "${SQUAD_DEVKIT_FORCE_PROMPT:-}"; }; then
  interactive=1
fi

if (( setup == 1 )); then
  manager_client="$(prompt_for_manager 'Choose the CLI that manages the squad (1 is the default):')"
  save_manager "$manager_client"
  printf 'Saved manager: %s (%s)\n' "$manager_client" "$(devkit_config_file)"
  exit 0
fi
# Cleaning needs no manager, so it works where no manager CLI is installed.
if (( clean_only == 0 )); then
  manager_client="$(resolve_manager "$manager_client" "$interactive")"
fi

# Without a project argument, use the repository containing the current
# directory. From the home directory, start in the general workspace instead:
# the manager works out which projects a request involves.
general_workspace=0
if [[ -z "$project_directory" && "$(pwd -P)" == "$(cd "$HOME" && pwd -P)" ]] &&
  ! is_truthy "${SQUAD_DEVKIT_ALLOW_HOME:-}"; then
  general_workspace=1
  project_directory="${SQUAD_DEVKIT_GENERAL_WORKSPACE:-$HOME/.squad-devkit}"
  if (( dry_run == 0 )); then
    mkdir -p "$project_directory"
  fi
else
  project_directory="$(resolve_project_reference "${project_directory:-$PWD}")"
  project_directory="$(resolve_project_directory "$project_directory")"
  if ! git -C "$project_directory" rev-parse --show-toplevel >/dev/null 2>&1; then
    printf 'Note: %s is not a git repository; squad init will create .squad/ there.\n' \
      "$project_directory" >&2
  fi
  project_directory="$(cd "$project_directory" && pwd -P)"
  if [[ "$project_directory" == "$(cd "$HOME" && pwd -P)" ]] && ! is_truthy "${SQUAD_DEVKIT_ALLOW_HOME:-}"; then
    echo "Refusing to use your home directory as the project; pass a project name or path." >&2
    exit 1
  fi
fi
project_name="$(basename "$project_directory" | tr -cs '[:alnum:]' '-' | cut -c1-24)"
project_hash="$(printf '%s' "$project_directory" | cksum | awk '{print $1}')"
session_name="squad-devkit-${project_name}-${project_hash}"

require_command squad
worker_engines=()
# Worker engines in trust order: claude > codex > opencode > grok, agy > ccr.
for engine in claude codex opencode grok agy ccr; do
  if command -v "$engine" >/dev/null 2>&1; then
    worker_engines+=("$engine")
  fi
done
if (( ${#worker_engines[@]} == 0 && clean_only == 0 )); then
  echo "Note: no worker engine (claude, codex, opencode, grok, agy, ccr) is installed; the manager will do the work itself." >&2
fi
if (( clean_only > 0 )); then
  if [[ -d "$project_directory/.squad" ]]; then
    clean_arguments=()
    (( clean_only == 2 )) && clean_arguments=(--all)
    "$script_dir/lib/squad-devkit-clean.sh" "$project_directory" ${clean_arguments[@]+"${clean_arguments[@]}"}
  else
    echo "No squad workspace in $project_directory; nothing to clean." >&2
  fi
  exit 0
fi
if [[ "$backend" == tmux ]]; then
  require_command tmux
elif [[ "$backend" == ghostty ]]; then
  osascript_command="${SQUAD_DEVKIT_OSASCRIPT:-osascript}"
  require_command "$osascript_command"
fi

worker_command="$script_dir/squad-worker.sh"
if (( ${#worker_engines[@]} == 0 )); then
  worker_line="No worker engine is installed, so do the work yourself instead of starting squad-worker."
else
  worker_line="squad-worker is: $worker_command
Installed worker engines, most trusted first: ${worker_engines[*]}
In Claude Code, start workers with run_in_background: true; you are notified when each one exits. In other CLIs, start each worker as a detached job (squad-worker ... >.squad/workers/<id>.out 2>&1 &); each worker messages you when it finishes, so wait with one command, squad receive {{MANAGER_ID}} --wait --timeout 900, instead of polling or sleeping."
fi
if [[ -n "${SQUAD_DEVKIT_ROUTER_URL:-}" ]]; then
  worker_line+=$'\n'"squad-route is configured: $script_dir/squad-route.sh \"<redacted digest>\""
fi
manager_prompt="You are the {{MANAGER_LABEL}} manager of this squad devkit, in an interactive session in this repository. You already joined the squad as {{MANAGER_ID}}; workers report to you automatically.
$worker_line"
if (( general_workspace == 1 )); then
  manager_prompt+=$'\n\n'"You are in the general squad workspace ($project_directory), not inside a project. Many requests need no repository: checking logs or metrics (prod, staging), querying data, and writing reports. Run those workers here without --project, give them the MCP servers they need, and save reports under reports/ in this workspace. When a request changes or inspects code, work out which repositories it involves (they live under ~/Workspace; $script_dir/squad-devkit.sh --list lists them) and pass --project <repository path> to those squad-worker runs. Keep plans in .squad/plans/ here. Ask the human only when the repository is genuinely unclear."
else
  manager_prompt+=$'\n\n'"Workers work in this repository by default; pass --project <path> to have one work in another repository."
fi
manager_prompt+=$'\n\n'"The human's messages in the chat are their requests. When a message gives you work, start investigating and planning right away, without asking for the objective again unless it is genuinely ambiguous. Do not repeat these instructions to the human."
manager_command="$(shell_join "$script_dir/lib/squad-devkit-manager.sh" "$manager_client" "$manager_prompt" "$objective")"
manager_title="$(manager_label "$manager_client")"

if (( dry_run == 1 )); then
  printf 'Project: %s\nBackend: %s\nSession: %s\n' "$project_directory" "$backend" "$session_name"
  if (( general_workspace == 1 )); then
    printf 'Mode: general workspace\n'
  fi
  printf 'Manager: %s\n' "$manager_client"
  printf 'Objective: %s\n' "${objective:-<ask in chat>}"
  printf 'Workers: %s\n' "$worker_command"
  printf 'manager: %s\n' "$manager_command"
  printf 'cli: %s\n' "$(manager_start_command "$manager_client" INSTRUCTIONS "${objective:+MESSAGE}")"
  exit 0
fi

template_marker='<!-- squad-devkit template'

# squad init appends guidance to CLAUDE.md, AGENTS.md, and GEMINI.md and adds
# .squad/ to .gitignore. In a git repository, keep those files as they were and
# ignore .squad/ through .git/info/exclude instead, so launching never dirties
# the working tree. SQUAD_DEVKIT_KEEP_INIT_FILES=1 keeps squad's edits.
squad_init_project() {
  if is_truthy "${SQUAD_DEVKIT_KEEP_INIT_FILES:-}" ||
    ! git -C "$project_directory" rev-parse --show-toplevel >/dev/null 2>&1; then
    (cd "$project_directory" && squad init >/dev/null)
    return 0
  fi
  local snapshot_directory file
  snapshot_directory="$(mktemp -d "${TMPDIR:-/tmp}/squad-devkit-init.XXXXXX")"
  for file in CLAUDE.md AGENTS.md GEMINI.md .gitignore; do
    if [[ -e "$project_directory/$file" ]]; then
      cp -p "$project_directory/$file" "$snapshot_directory/$file"
    fi
  done
  (cd "$project_directory" && squad init >/dev/null)
  for file in CLAUDE.md AGENTS.md GEMINI.md .gitignore; do
    if [[ -e "$snapshot_directory/$file" ]]; then
      cmp -s "$snapshot_directory/$file" "$project_directory/$file" ||
        cp -p "$snapshot_directory/$file" "$project_directory/$file"
    else
      rm -f "$project_directory/$file"
    fi
  done
  rm -rf "$snapshot_directory"
  local exclude_file
  exclude_file="$(cd "$project_directory" && git rev-parse --git-path info/exclude)"
  [[ "$exclude_file" == /* ]] || exclude_file="$project_directory/$exclude_file"
  mkdir -p "$(dirname "$exclude_file")"
  if ! grep -qxE '/?\.squad/?' "$exclude_file" 2>/dev/null; then
    printf '.squad/\n' >>"$exclude_file"
  fi
}

prepare_project() {
  squad_init_project
  "$script_dir/lib/squad-devkit-clean.sh" "$project_directory" --quiet || true
  local role=""
  local source=""
  local destination=""
  for role in manager-devkit dev tester reviewer researcher; do
    source="$script_dir/../templates/devkit/$role.md"
    destination="$project_directory/.squad/roles/$role.md"
    if [[ ! -e "$destination" ]]; then
      cp "$source" "$destination"
    elif cmp -s "$source" "$destination"; then
      continue
    elif [[ "$(head -n 1 "$destination")" == "$template_marker"* ]]; then
      cp "$source" "$destination"
    else
      printf 'Note: keeping customized %s; compare it with %s\n' "$destination" "$source" >&2
    fi
  done
}

# squad-worker splits worker monitor panes next to this Ghostty terminal.
ghostty_focused_terminal='tell application "Ghostty" to get id of focused terminal of selected tab of front window'

if [[ "$backend" == here ]]; then
  prepare_project
  cd "$project_directory"
  if [[ -z "${TMUX:-}" && "${TERM_PROGRAM:-}" == ghostty ]] &&
    command -v "${SQUAD_DEVKIT_OSASCRIPT:-osascript}" >/dev/null 2>&1; then
    SQUAD_DEVKIT_GHOSTTY_TERMINAL="$("${SQUAD_DEVKIT_OSASCRIPT:-osascript}" -e "$ghostty_focused_terminal" 2>/dev/null || true)"
    export SQUAD_DEVKIT_GHOSTTY_TERMINAL
  fi
  eval "exec $manager_command"
fi

if [[ "$backend" == ghostty ]]; then
  prepare_project
  launcher_directory="$(mktemp -d "${TMPDIR:-/tmp}/squad-devkit.XXXXXX")"
  manager_script="$launcher_directory/manager.sh"
  printf '#!/bin/bash\ncd %s || exit 1\nexport PATH=%s\nexport SQUAD_DEVKIT_GHOSTTY_TERMINAL="$(osascript -e %s 2>/dev/null)"\nexec %s\n' \
    "$(shell_escape "$project_directory")" "$(shell_escape "$PATH")" \
    "$(shell_escape "$ghostty_focused_terminal")" "$manager_command" >"$manager_script"
  chmod +x "$manager_script"
  "$osascript_command" "$script_dir/lib/squad-devkit-ghostty.applescript" \
    "$project_directory" "$manager_script" "$manager_title · manager"
  printf 'Opened Ghostty window with the %s manager for %s.\n' "$manager_title" "$project_directory"
  exit 0
fi

attach_session() {
  tmux set-option -t "$session_name" prefix C-a >/dev/null
  tmux set-option -t "$session_name" mouse on >/dev/null
  if (( no_attach == 0 )); then
    if [[ -n "${TMUX:-}" ]]; then
      tmux switch-client -t "$session_name"
    else
      tmux attach-session -t "$session_name"
    fi
  fi
}

if tmux has-session -t "$session_name" 2>/dev/null; then
  pane_titles="$(tmux list-panes -t "$session_name:0" -F '#{pane_title}')"
  if [[ "$pane_titles" == *'CCR · helper'* || "$pane_titles" == *'Codex · dev-'* ]]; then
    echo "An older multi-pane devkit session exists. Stop it explicitly with: tmux kill-session -t $session_name" >&2
    exit 1
  fi
  echo "Reusing tmux session: $session_name"
  attach_session
  exit 0
fi

prepare_project

manager_pane="$(tmux new-session -d -P -F '#{pane_id}' -s "$session_name" -n squad \
  "$(printf 'cd %s && exec env %s %s' "$(shell_escape "$project_directory")" \
    "$(shell_escape "PATH=$PATH")" "$manager_command")")"
tmux set-window-option -t "$session_name:0" remain-on-exit on
tmux select-pane -t "$manager_pane" -T "$manager_title · manager"

printf 'Started %s for %s (%s manager).\n' "$session_name" "$project_directory" "$manager_title"
printf 'Attach later: tmux attach -t %s\n' "$session_name"
attach_session
