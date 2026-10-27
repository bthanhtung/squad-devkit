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
With no project argument, an interactive terminal asks for a project name, a
path, or an empty line to use the current directory. Unknown names are asked
again instead of aborting. Set SQUAD_DEVKIT_NO_PROMPT=1, or pass --no-prompt,
to skip the question in scripts.
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
  --no-prompt   Skip the interactive project question (or set SQUAD_DEVKIT_NO_PROMPT)
  --dry-run     Show the manager command without changing the project
  --no-attach   tmux only: start the session in the background
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
    for match in "${matches[@]}"; do
      [[ "$match" == *"$suffix_filter" ]] && filtered+=("$match")
    done
    matches=("${filtered[@]}")
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

prompt_for_project() {
  local input=""
  local resolved=""
  while true; do
    printf 'Project name or path (Enter = current directory): ' >&2
    if ! IFS= read -r input; then
      printf '\nNo project entered; aborting.\n' >&2
      exit 1
    fi
    input="${input#"${input%%[![:space:]]*}"}"
    input="${input%"${input##*[![:space:]]}"}"
    if [[ -z "$input" ]]; then
      (cd "$PWD" && pwd -P)
      return 0
    fi
    if resolved="$(resolve_project_reference "$input")" &&
      resolved="$(resolve_project_directory "$resolved")"; then
      printf '%s\n' "$resolved"
      return 0
    fi
    printf 'Try another name or path (Ctrl-C to cancel).\n' >&2
  done
}

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
manager_client="$(resolve_manager "$manager_client" "$interactive")"

if [[ -z "$project_directory" ]]; then
  if (( interactive == 1 )); then
    project_directory="$(prompt_for_project)"
    printf 'Using project: %s\n' "$project_directory" >&2
  else
    project_directory="$PWD"
  fi
fi
project_directory="$(resolve_project_reference "$project_directory")"
project_directory="$(resolve_project_directory "$project_directory")"
if ! git -C "$project_directory" rev-parse --show-toplevel >/dev/null 2>&1; then
  printf 'Note: %s is not a git repository; squad init will create .squad/ there.\n' \
    "$project_directory" >&2
fi
project_directory="$(cd "$project_directory" && pwd -P)"
project_name="$(basename "$project_directory" | tr -cs '[:alnum:]' '-' | cut -c1-24)"
project_hash="$(printf '%s' "$project_directory" | cksum | awk '{print $1}')"
session_name="squad-devkit-${project_name}-${project_hash}"

require_command squad
worker_engines=()
for engine in codex ccr; do
  if command -v "$engine" >/dev/null 2>&1; then
    worker_engines+=("$engine")
  fi
done
if (( ${#worker_engines[@]} == 0 )); then
  echo "Note: neither codex nor ccr is installed; the manager will do the work itself." >&2
fi
if [[ "$backend" == tmux ]]; then
  require_command tmux
elif [[ "$backend" == ghostty ]]; then
  osascript_command="${SQUAD_DEVKIT_OSASCRIPT:-osascript}"
  require_command "$osascript_command"
fi

worker_command="$script_dir/squad-worker.sh"
join_command="squad join manager --role manager-devkit"
client_flag="$(squad_client_flag "$manager_client")"
if [[ -n "$client_flag" ]]; then
  join_command+=" --client $client_flag"
fi
join_command+=" --protocol-version 2"
if (( ${#worker_engines[@]} == 0 )); then
  worker_line="3. No worker engine is installed, so do the work yourself instead of starting squad-worker."
else
  worker_line="3. squad-worker is: $worker_command
   Installed worker engines: ${worker_engines[*]}"
  if [[ "$manager_client" == claude ]]; then
    worker_line+=$'\n'"   Start workers with run_in_background: true; you are notified when each one exits."
  else
    worker_line+=$'\n'"   Start each worker as a detached job: squad-worker ... >.squad/workers/<id>.out 2>&1 &
   Each worker messages you when it finishes. Wait with one command, squad receive <your ID> --wait --timeout 900, instead of polling or sleeping."
  fi
fi
manager_prompt="You are the $(manager_label "$manager_client") manager of this squad devkit, in an interactive session in this repository.

1. Run: $join_command
   If it joins under another ID, pass --manager <that ID> to every squad-worker run.
2. Follow the role instructions it prints (also in .squad/roles/manager-devkit.md).
$worker_line"
if [[ -n "$objective" ]]; then
  manager_prompt+=$'\n\n'"The human's objective is:

$objective

Start researching and planning now. Do not ask for the objective again unless it is genuinely ambiguous."
else
  manager_prompt+=$'\n\n'"No objective was supplied. Greet the human briefly and wait for their instruction in this chat."
fi
manager_command="$(manager_start_command "$manager_client" "$manager_prompt")"
manager_title="$(manager_label "$manager_client")"

if (( dry_run == 1 )); then
  printf 'Project: %s\nBackend: %s\nSession: %s\n' "$project_directory" "$backend" "$session_name"
  printf 'Manager: %s\n' "$manager_client"
  printf 'Objective: %s\n' "${objective:-<ask in chat>}"
  printf 'Workers: %s\n' "$worker_command"
  printf 'manager: %s\n' "$manager_command"
  exit 0
fi

template_marker='<!-- squad-devkit template'

prepare_project() {
  (cd "$project_directory" && squad init >/dev/null)
  local role=""
  local source=""
  local destination=""
  for role in manager-devkit dev tester reviewer; do
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

if [[ "$backend" == here ]]; then
  prepare_project
  cd "$project_directory"
  eval "exec $manager_command"
fi

if [[ "$backend" == ghostty ]]; then
  prepare_project
  launcher_directory="$(mktemp -d "${TMPDIR:-/tmp}/squad-devkit.XXXXXX")"
  manager_script="$launcher_directory/manager.sh"
  printf '#!/bin/bash\ncd %s || exit 1\nexport PATH=%s\nexec %s\n' \
    "$(shell_escape "$project_directory")" "$(shell_escape "$PATH")" "$manager_command" >"$manager_script"
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
