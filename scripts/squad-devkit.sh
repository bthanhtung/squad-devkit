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
source "$script_dir/lib/squad-panes.sh"
source "$script_dir/lib/squad-jq.sh"
# shellcheck source=lib/squad-worker-model.sh
source "$script_dir/lib/squad-worker-model.sh"
source "$script_dir/lib/squad-tokeneconomizer.sh"

devkit_version="1.0.2"

usage() {
  cat <<'EOF'
Usage: squad-devkit [project-name-or-directory] [objective] [--task objective]
                    [--manager CLI] [--workers LIST] [--scout ENGINE[:MODEL]]
                    [--disable-workers LIST] [--view MODE] [--setup] [--doctor] [--list] [--ghostty] [--tmux]
                    [--update] [--reload] [--dry-run] [--no-attach] [--no-prompt]
       squad-devkit update|reload|restart [project-name-or-directory]
       squad-devkit telegram setup|start|stop|status|run

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
  --setup       Detect installed AI CLIs and choose the manager, workers and their order, then exit
  --workers LIST          Only enable these worker engines (comma list of claude,codex,opencode,grok,ccr)
                          (or SQUAD_DEVKIT_WORKERS, or workers= in the config file)
  --disable-workers LIST  Exclude these worker engines
                          (or SQUAD_DEVKIT_DISABLE_WORKERS, or disabled_workers=)
  --scout ENGINE[:MODEL]  Default cheap read-only scout worker (or SQUAD_WORKER_SCOUT_ENGINE /
                          SQUAD_WORKER_SCOUT_MODEL, or scout_engine= / scout_model= in config)
  --view MODE   How worker progress is shown: orchestration (one live flow view, default) or panes (one split per worker); or SQUAD_WORKER_VIEW / view= in the config file
  --doctor      Diagnose environment: core tools, manager, worker engines, optional integrations, and multiplexer/panes
  --split-test  With --doctor, open and verify a monitor split
  --stats       Show run statistics for the last 30 days (--days N)
  --eval [RUN]  Score finished worker runs for the last 30 days (--days N)
  --update-prices
                Update .squad/prices.json from OpenRouter API (or --from-file / --url / --set / --global)
  --ghostty     Open the manager in a new Ghostty window instead of this terminal
  --tmux        Run the manager in a tmux session; re-running attaches to it
                (or set SQUAD_DEVKIT_BACKEND=here|ghostty|tmux)
  --task TEXT   Objective for the manager; supports spaces when quoted
  --list        List the git projects found on this machine and exit
  --clean       Prune finished worker runs (logs, reports) in the project's squad
                workspace older than SQUAD_DEVKIT_RETENTION_DAYS (7) or beyond
                SQUAD_DEVKIT_MAX_MB (200), then exit; every launch does this too
  --clean-all   Remove every finished worker run, then exit
  update, --update
                Pull the latest squad-devkit (--ff-only) and reload the session in place
  reload, restart, --reload
                Refresh roles, command links, and orchestration views, and print updated manager instructions
  --no-prompt   Skip the first-run manager question (or set SQUAD_DEVKIT_NO_PROMPT)
  --yolo        Bypass engine permissions and sandbox for Claude/Codex/AGY managers
                and their workers (session only; SQUAD_DEVKIT_YOLO=1)
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
doctor=0
split_test=0
stats=0
eval_runs=0
update_prices=0
update_prices_args=()
stats_days=30
devkit_action=""
seen_positional=0
reload_passthrough_args=()
caller_worker_view="${SQUAD_WORKER_VIEW:-}"
manager_client="${SQUAD_DEVKIT_MANAGER:-}"
workers_opt="${SQUAD_DEVKIT_WORKERS:-}"
workers_cli=0
disable_workers_opt="${SQUAD_DEVKIT_DISABLE_WORKERS:-}"
scout_cli=0
scout_opt=""
scout_engine_opt=""
scout_model_opt=""
scout_source=""
parsed_scout_engine=""
parsed_scout_model=""
scout_resolved_engine=""
scout_resolved_model=""
scout_resolved_source=""
scout_resolved_error=""
view_opt="${SQUAD_WORKER_VIEW:-}"
view_source=""
[[ -z "$view_opt" ]] || view_source="env"
backend="${SQUAD_DEVKIT_BACKEND:-here}"
# `squad-devkit telegram ...` hands the rest of the arguments to the daemon.
if [[ "${1:-}" == telegram && ! -d telegram ]]; then
  shift
  exec "$script_dir/squad-telegram.sh" "$@"
fi
while (( $# > 0 )); do
  case "$1" in
    --here) backend=here; reload_passthrough_args+=("$1") ;;
    --tmux) backend=tmux; reload_passthrough_args+=("$1") ;;
    --ghostty) backend=ghostty; reload_passthrough_args+=("$1") ;;
    --yolo) export SQUAD_DEVKIT_YOLO=1; reload_passthrough_args+=("$1") ;;
    --dry-run) dry_run=1; reload_passthrough_args+=("$1") ;;
    --no-attach) no_attach=1; reload_passthrough_args+=("$1") ;;
    --no-prompt) no_prompt=1; reload_passthrough_args+=("$1") ;;
    --list) list_projects=1; reload_passthrough_args+=("$1") ;;
    --clean) clean_only=1; reload_passthrough_args+=("$1") ;;
    --clean-all) clean_only=2; reload_passthrough_args+=("$1") ;;
    --setup) setup=1; reload_passthrough_args+=("$1") ;;
    --stats) stats=1 ;;
    --eval) eval_runs=1 ;;
    --update-prices) update_prices=1 ;;
    --url|--from-file|--set|--target)
      if (( $# < 2 )) || [[ -z "$2" ]]; then echo "Missing value for $1" >&2; exit 2; fi
      update_prices_args+=("$1" "$2"); shift ;;
    --global|--no-fetch)
      update_prices_args+=("$1") ;;
    --split-test) split_test=1 ;;
    --days)
      if (( $# < 2 )) || [[ ! "$2" =~ ^[0-9]+$ ]] || (( ${#2} > 5 )); then echo "Invalid --days value" >&2; exit 2; fi
      stats_days="$2"; shift ;;
    --doctor) doctor=1; reload_passthrough_args+=("$1") ;;
    --update) devkit_action=update ;;
    --reload) devkit_action=reload ;;
    --manager)
      if (( $# < 2 )) || [[ -z "$2" ]]; then
        echo "Missing value for $1" >&2
        exit 2
      fi
      manager_client="$2"
      reload_passthrough_args+=("$1" "$2")
      shift
      ;;
    --manager=*) manager_client="${1#*=}"; reload_passthrough_args+=("$1") ;;
    --workers|--disable-workers)
      if (( $# < 2 )) || [[ -z "$2" ]]; then
        echo "Missing value for $1" >&2
        exit 2
      fi
      if [[ "$1" == --workers ]]; then workers_opt="$2"; else disable_workers_opt="$2"; fi
      workers_cli=1
      reload_passthrough_args+=("$1" "$2")
      shift
      ;;
    --workers=*) workers_opt="${1#*=}"; workers_cli=1; reload_passthrough_args+=("$1") ;;
    --disable-workers=*) disable_workers_opt="${1#*=}"; workers_cli=1; reload_passthrough_args+=("$1") ;;
    --scout)
      if (( $# < 2 )) || [[ -z "$2" ]]; then
        echo "Missing value for $1" >&2
        exit 2
      fi
      scout_opt="$2"
      scout_cli=1
      reload_passthrough_args+=("$1" "$2")
      shift
      ;;
    --scout=*)
      scout_opt="${1#*=}"
      if [[ -z "$scout_opt" ]]; then
        echo "Missing value for --scout" >&2
        exit 2
      fi
      scout_cli=1
      reload_passthrough_args+=("$1")
      ;;
    --view)
      if (( $# < 2 )) || [[ -z "$2" ]]; then
        echo "Missing value for $1" >&2
        exit 2
      fi
      view_opt="$2"
      view_source=flag
      reload_passthrough_args+=("$1" "$2")
      shift
      ;;
    --view=*)
      view_opt="${1#*=}"
      if [[ -z "$view_opt" ]]; then
        echo "Missing value for --view" >&2
        exit 2
      fi
      view_source=flag
      reload_passthrough_args+=("$1")
      ;;
    --task|--prompt)
      if (( $# < 2 )) || [[ -z "$2" ]]; then
        echo "Missing value for $1" >&2
        exit 2
      fi
      objective="$2"
      reload_passthrough_args+=("$1" "$2")
      shift
      ;;
    --task=*|--prompt=*) objective="${1#*=}"; reload_passthrough_args+=("$1") ;;
    -h|--help) usage; exit 0 ;;
    --version) printf 'squad-devkit %s\n' "$devkit_version"; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)
      if (( seen_positional == 0 && ! eval_runs )) && [[ -z "$devkit_action" && ! -d "$1" ]] &&
        [[ "$1" == update || "$1" == reload || "$1" == restart ]]; then
        if [[ "$1" == update ]]; then
          devkit_action=update
        else
          devkit_action=reload
        fi
        seen_positional=1
      elif [[ -n "$project_directory" ]]; then
        if [[ -n "$objective" ]]; then
          echo "Only one objective is allowed" >&2
          exit 2
        fi
        objective="$1"
        seen_positional=1
        reload_passthrough_args+=("$1")
      else
        project_directory="$1"
        seen_positional=1
        reload_passthrough_args+=("$1")
      fi
      ;;
  esac
  shift
done
if [[ "$devkit_action" == update ]]; then
  devkit_repo_root="${SQUAD_DEVKIT_REPO_ROOT:-$(cd "$script_dir/.." && pwd)}"
  update_dirty=0
  if [[ ! -d "$devkit_repo_root" ]] || ! git -C "$devkit_repo_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf 'not a git checkout; skipping pull\n'
  elif [[ -n "$(git -C "$devkit_repo_root" status --porcelain 2>/dev/null)" ]]; then
    printf 'devkit repo has local changes; not pulling\n'
    update_dirty=1
  else
    old_sha="$(git -C "$devkit_repo_root" rev-parse --short HEAD)"
    if ! pull_out="$(git -C "$devkit_repo_root" pull --ff-only 2>&1)"; then
      printf '%s\n' "$pull_out" >&2
      exit 1
    fi
    new_sha="$(git -C "$devkit_repo_root" rev-parse --short HEAD)"
    if [[ "$old_sha" == "$new_sha" ]]; then
      printf 'already up to date\n'
    else
      printf 'pulled %s..%s\n' "$old_sha" "$new_sha"
    fi
  fi
  if (( update_dirty == 1 )); then
    "$script_dir/squad-devkit.sh" --reload ${reload_passthrough_args[@]+"${reload_passthrough_args[@]}"}
    exit 1
  fi
  exec "$script_dir/squad-devkit.sh" --reload ${reload_passthrough_args[@]+"${reload_passthrough_args[@]}"}
fi
if [[ "$backend" != here && "$backend" != ghostty && "$backend" != tmux ]]; then
  echo "Unknown backend: $backend (use here, ghostty, or tmux)" >&2
  exit 2
fi
if [[ -z "$view_opt" ]]; then
  view_opt="$(devkit_config_get view)"
  if [[ -n "$view_opt" ]]; then
    view_source=config
  else
    view_opt=orchestration
    view_source=default
  fi
fi
case "$view_opt" in
  orchestration|panes) ;;
  *) echo 'SQUAD_WORKER_VIEW must be orchestration or panes' >&2; exit 2 ;;
esac
export SQUAD_WORKER_VIEW="$view_opt"
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

get_tool_version() {
  local tool="$1"
  local ver=""
  case "$tool" in
    squad)
      ver="$("$tool" --version 2>&1 | head -n 1 || true)"
      ;;
    git)
      ver="$("$tool" --version 2>&1 | head -n 1 || true)"
      ;;
    jq)
      ver="$("$tool" --version 2>&1 | head -n 1 || true)"
      ;;
    curl)
      ver="$("$tool" --version 2>&1 | head -n 1 || true)"
      ;;
    tmux)
      ver="$("$tool" -V 2>&1 | head -n 1 || true)"
      ;;
    claude|codex|agy|gemini|grok|opencode|ccr)
      ver="$("$tool" --version 2>&1 | head -n 1 || true)"
      ;;
    *)
      ver=""
      ;;
  esac
  # Trim if too long or redundant
  printf '%s' "$ver"
}

# True when $2 is in the comma/space separated list $1.
in_list() {
  local item
  for item in ${1//,/ }; do
    [[ "$item" == "$2" ]] && return 0
  done
  return 1
}

# Worker enable/disable: CLI flag > env var > config file. An empty allow-list
# means every engine is allowed; the disable list always wins.
worker_enabled() {
  local allow="$workers_opt" deny="$disable_workers_opt"
  [[ -n "$allow" ]] || allow="$(drop_agy_worker "$(devkit_config_get workers)")"
  [[ -n "$deny" ]] || deny="$(drop_agy_worker "$(devkit_config_get disabled_workers)")"
  if [[ -n "$allow" ]] && ! in_list "$allow" "$1"; then return 1; fi
  if [[ -n "$deny" ]] && in_list "$deny" "$1"; then return 1; fi
  return 0
}

run_doctor() {
  local status=0
  local tool path ver
  printf '=== squad-devkit doctor ===\n\n'

  printf 'Core Tools:\n'
  for tool in squad git jq curl tmux; do
    if [[ "$tool" == jq ]]; then
      if [[ "${SQUAD_DEVKIT_NO_SYSTEM_JQ:-0}" != 1 ]] && command -v jq >/dev/null 2>&1; then
        path="$(command -v jq)"
        ver="$(get_tool_version jq)"
        if [[ -n "$ver" ]]; then
          printf '  [OK]      %-8s %s (%s)\n' "$tool" "$path" "$ver"
        else
          printf '  [OK]      %-8s %s\n' "$tool" "$path"
        fi
      elif squad_has_jq; then
        path="$(squad_bin)"
        printf '  [OK]      %-8s %s (squad jq)\n' "$tool" "$path"
      else
        printf '  [MISSING] %-8s (required)\n' "$tool"
        status=1
      fi
    elif path="$(command -v "$tool" 2>/dev/null)"; then
      ver="$(get_tool_version "$tool")"
      if [[ -n "$ver" ]]; then
        printf '  [OK]      %-8s %s (%s)\n' "$tool" "$path" "$ver"
      else
        printf '  [OK]      %-8s %s\n' "$tool" "$path"
      fi
    else
      local is_required=0
      if [[ "$tool" == squad || "$tool" == git ]]; then
        is_required=1
      fi
      if (( is_required == 1 )); then
        printf '  [MISSING] %-8s (required)\n' "$tool"
        status=1
      else
        printf '  [OPTIONAL] %-7s (not found)\n' "$tool"
      fi
    fi
  done
  # Upstream squad rejects --client agy/grok/ccr; those workers and the agy
  # manager fall back to a client it accepts, so this is worth knowing but not an error.
  if command -v squad >/dev/null 2>&1 && ! squad help 2>&1 | grep -q 'agy'; then
    printf '  [INFO]    squad is the upstream build: ccr joins as claude, grok and an agy manager as codex. ./install.sh keeps their own names.\n'
  fi
  printf '\n'

  printf 'Manager CLI:\n'
  local saved_manager=""
  local default_mgr=""
  saved_manager="$(devkit_config_get manager)"
  local installed_managers=()
  local mgr
  # manager_clients is defined in lib/squad-devkit-agents.sh
  # shellcheck disable=SC2154
  for mgr in "${manager_clients[@]}"; do
    if path="$(command -v "$mgr" 2>/dev/null)"; then
      installed_managers+=("$mgr")
      ver="$(get_tool_version "$mgr")"
      local label
      label="$(manager_label "$mgr")"
      local note=""
      if [[ "$mgr" == "$saved_manager" ]]; then
        note=" [saved default]"
      fi
      if [[ -n "$ver" ]]; then
        printf '  [OK]      %-10s %s (%s)%s\n' "$mgr" "$path" "$label, $ver" "$note"
      else
        printf '  [OK]      %-10s %s (%s)%s\n' "$mgr" "$path" "$label" "$note"
      fi
    fi
  done

  if (( ${#installed_managers[@]} == 0 )); then
    printf '  [MISSING] No manager CLI installed (claude, codex, agy, gemini, grok, opencode)\n'
    status=1
  else
    if [[ -n "$saved_manager" ]]; then
      default_mgr="$saved_manager"
    elif command -v claude >/dev/null 2>&1; then
      default_mgr="claude"
    else
      default_mgr="${installed_managers[0]}"
    fi
    printf '  Active default manager: %s (%s)\n' "$default_mgr" "$(manager_label "$default_mgr")"
  fi
  # The squad deck mod (a live worker dashboard) rides on Claude Code only.
  local deck_reason
  if deck_reason="$(deck_plugin_check "$(command -v claude 2>/dev/null || true)")"; then
    printf '  Deck: on (%s)\n' "$deck_reason"
  else
    printf '  Deck: off (%s)\n' "$deck_reason"
  fi
  printf '\n'

  printf 'Worker Engines:\n'
  printf '  Setup mode: %s\n' "${setup_mode:-not set}"
  local engines_found=0
  local eng seen=""
  local order=()
  if [[ -n "$workers_opt" ]]; then
    for eng in ${workers_opt//,/ }; do
      order+=("$eng")
    done
  else
    # shellcheck disable=SC2154 # worker_engine_order is defined in lib/squad-devkit-agents.sh
    order=("${worker_engine_order[@]}")
  fi
  # Enabled engines first, in the effective order (allow-list order when set,
  # otherwise the built-in trust order).
  local doctor_enabled_engines=()
  for eng in "${order[@]}"; do
    if path="$(command -v "$eng" 2>/dev/null)" && worker_enabled "$eng"; then
      ver="$(get_tool_version "$eng")"
      if [[ -n "$ver" ]]; then
        printf '  [FOUND]   %-8s %s (%s) [enabled]\n' "$eng" "$path" "$ver"
      else
        printf '  [FOUND]   %-8s %s [enabled]\n' "$eng" "$path"
      fi
      engines_found=$((engines_found + 1))
      doctor_enabled_engines+=("$eng")
      seen+=" $eng "
    fi
  done
  # Installed-but-disabled and not-installed engines, in trust order.
  # shellcheck disable=SC2154 # worker_engine_order is defined in lib/squad-devkit-agents.sh
  for eng in "${worker_engine_order[@]}"; do
    case " $seen " in *" $eng "*) continue ;; esac
    if path="$(command -v "$eng" 2>/dev/null)"; then
      ver="$(get_tool_version "$eng")"
      if [[ -n "$ver" ]]; then
        printf '  [FOUND]   %-8s %s (%s) [disabled]\n' "$eng" "$path" "$ver"
      else
        printf '  [FOUND]   %-8s %s [disabled]\n' "$eng" "$path"
      fi
    else
      printf '  [-]       %-8s (not installed)\n' "$eng"
    fi
  done
  if (( engines_found == 0 )); then
    printf '  Note: No worker engines found. Manager will work without sub-workers.\n'
  fi
  if [[ -n "$scout_engine_opt" ]] && { ! command -v "$scout_engine_opt" >/dev/null 2>&1 || ! worker_enabled "$scout_engine_opt"; }; then
    local scout_unavail_reason="not installed"
    ! worker_enabled "$scout_engine_opt" && scout_unavail_reason="disabled"
    printf '  Default scout: %s [unavailable: %s]\n' "$scout_engine_opt" "$scout_unavail_reason"
  elif squad_worker_resolve_scout_target "$scout_engine_opt" "$scout_model_opt" ${doctor_enabled_engines[@]+"${doctor_enabled_engines[@]}"}; then
    local scout_desc=""
    case "$scout_resolved_source" in
      configured) scout_desc="$scout_resolved_model" ;;
      configured-fast|auto-fast|auto-builtin) scout_desc="fast=$scout_resolved_model" ;;
      configured-router|auto-ccr) scout_desc="router default" ;;
      *) scout_desc="CLI default" ;;
    esac
    printf '  Default scout: %s (%s, source: %s)\n' "$scout_resolved_engine" "$scout_desc" "${scout_source:-$scout_resolved_source}"
  else
    printf '  Default scout: none (no enabled worker engines)\n'
  fi
  printf '\n'

  squad_te_doctor_report

  printf 'Terminal & Monitor Support:\n'
  local term_prog="${TERM_PROGRAM:-unknown}"
  printf '  TERM_PROGRAM: %s\n' "$term_prog"
  local osascript_cmd="${SQUAD_DEVKIT_OSASCRIPT:-osascript}"
  local pane_support="dashboard window (fallback)"
  local SQUAD_DEVKIT_ORCA_TERMINAL="${SQUAD_DEVKIT_ORCA_TERMINAL:-}"

  if [[ -n "${TMUX:-}" && -n "${TMUX_PANE:-}" ]] && command -v tmux >/dev/null 2>&1; then
    pane_support="tmux split-pane"
  elif SQUAD_DEVKIT_ORCA_TERMINAL="$(squad_panes_orca_manager "$PWD")" && [[ -n "$SQUAD_DEVKIT_ORCA_TERMINAL" ]] &&
    command -v "$(squad_panes_orca_cli)" >/dev/null 2>&1 && squad_has_jq; then
    pane_support="Orca split-pane (explicit manager terminal)"
  elif [[ "$(squad_panes_herdr_kind)" == herdr_app ]]; then
    if [[ -n "$(squad_panes_herdr_app_manager)" ]]; then
      pane_support="Herdr desktop split-pane (explicit manager terminal)"
    else
      pane_support="Herdr desktop (monitor split unavailable: manager terminal not resolved)"
    fi
  elif [[ -n "$(squad_panes_herdr_manager)" ]]; then
    pane_support="herdr split-pane (TUI)"
  elif [[ -n "${ZELLIJ:-}" ]] && command -v zellij >/dev/null 2>&1; then
    pane_support="zellij floating pane"
  elif [[ -n "${WEZTERM_PANE:-}" ]] && command -v wezterm >/dev/null 2>&1; then
    pane_support="wezterm split-pane"
  elif [[ -n "${KITTY_WINDOW_ID:-}" ]] && command -v kitten >/dev/null 2>&1; then
    pane_support="kitty split-window"
  elif [[ -n "${ITERM_SESSION_ID:-}" ]] && command -v "$osascript_cmd" >/dev/null 2>&1; then
    pane_support="iTerm2 split-pane (AppleScript)"
  elif [[ -n "${SQUAD_DEVKIT_GHOSTTY_TERMINAL:-}" ]] && command -v "$osascript_cmd" >/dev/null 2>&1; then
    pane_support="Ghostty split-pane (AppleScript)"
  elif [[ -z "${TMUX:-}" && "$term_prog" == "ghostty" ]] && command -v "$osascript_cmd" >/dev/null 2>&1; then
    pane_support="Ghostty (splits supported on launch)"
  fi
  printf '  Monitor pane mode: %s\n' "$pane_support"
  printf '  View: %s (%s)\n' "$view_opt" "$view_source"
  if (( split_test )); then
    local split_dir split_error
    split_dir="$(mktemp -d)"
    printf '#!/usr/bin/env bash\nprintf "squad split test OK\\n"\nsleep 2\nrm -rf -- "%s"\n' "$split_dir" >"$split_dir/test.sh"
    chmod +x "$split_dir/test.sh"
    if split_error="$(squad_open_monitor "$split_dir/test.sh" 'squad split test' "$PWD" "$split_dir" '' required 2>&1)"; then
      printf '  [OK]      split test opened\n'
    else
      printf '  [FAIL]    split test: %s\n' "$split_error"
      rm -rf "$split_dir"
      status=1
    fi
  else
    printf '  Hint: use --doctor --split-test to test a monitor split.\n'
  fi

  printf '\nResult: '
  if (( status == 0 )); then
    printf 'Environment ready for squad-devkit.\n'
  else
    printf 'Environment missing required tools.\n'
  fi
  return "$status"
}

if (( split_test && ! doctor )); then echo '--split-test requires --doctor' >&2; exit 2; fi
if (( update_prices )); then
  source "$script_dir/lib/squad-cost.sh"
  if (( dry_run )); then
    update_prices_args+=(--dry-run)
  fi
  squad_cost_update_prices ${update_prices_args[@]+"${update_prices_args[@]}"}
  exit $?
fi
if (( eval_runs )); then
  if [[ -n "$objective" ]]; then echo "Only one run name is allowed" >&2; exit 2; fi
  source "$script_dir/lib/squad-eval.sh"
  squad_eval "$stats_days" "$project_directory"
  exit $?
fi
if (( stats )); then
  cutoff=$(( $(date +%s) - 10#$stats_days * 86400 ))
  stats_workspace="${SQUAD_DEVKIT_PROJECT_ROOT:-}"
  if [[ -z "$stats_workspace" ]]; then
    stats_workspace="$PWD"
    while [[ "$stats_workspace" != / && ! -d "$stats_workspace/.squad" ]]; do
      stats_workspace="$(dirname "$stats_workspace")"
    done
    [[ -d "$stats_workspace/.squad" ]] || stats_workspace="$PWD"
  fi
  status_files=()
  for status_file in "$stats_workspace"/.squad/workers/*.status; do
    [[ -f "$status_file" ]] && status_files+=("$status_file")
  done
  if (( ${#status_files[@]} == 0 )); then echo "no runs"; exit 0; fi
  awk -v cutoff="$cutoff" '
    FNR == 1 { if (NR > 1) record(); split("", v) }
    { pos=index($0,"="); if (pos) v[substr($0,1,pos-1)]=substr($0,pos+1) }
    END { if (NR) record(); if (!total) { print "no runs"; exit }
      print "ENGINE   TIER       RUNS FIRST_PASS AVG_ROUNDS TOKENS AVG_DURATION COST"
      for (k in count) keys[++n]=k
      for (i=2; i<=n; i++) { key=keys[i]; j=i-1; while (j>0 && keys[j]>key) { keys[j+1]=keys[j]; j-- } keys[j+1]=key }
      for (i=1; i<=n; i++) { k=keys[i]; fp=first[k] ? sprintf("%.1f%%", pass[k]*100/first[k]) : "-"; cost=known[k] ? sprintf("$%.4f", costs[k]) : "unknown"; if (known[k] && unknown[k]) cost=cost sprintf(" (+%d unknown)", unknown[k]); printf "%-8s %-10s %4d %10s %10.2f %6.0f %11.1fs %s\n", engine[k], tier[k], count[k], fp, count[k]/workers[k], tokens[k], durations[k] ? seconds[k]/durations[k] : 0, cost }
    }
    function record(  k,w) {
      if (v["started"] !~ /^[0-9]+$/ || v["started"]+0 < cutoff) return
      engine[k=(v["engine"] == "" ? "-" : v["engine"]) SUBSEP (v["model_tier"] == "" ? "-" : v["model_tier"])] = (v["engine"] == "" ? "-" : v["engine"])
      tier[k]=v["model_tier"] == "" ? "-" : v["model_tier"]
      count[k]++; total++; w=k SUBSEP v["worker"]; if (!seen[w]++) workers[k]++
      if (v["attempt"] == "1") { first[k]++; if (v["state"] == "completed" && v["verify"] != "fail" && v["verify"] != "timeout") pass[k]++ }
      if (v["cost_status"] ~ /^(reported|estimated)$/ && v["cost_usd"] ~ /^[0-9]+([.][0-9]+)?$/) { known[k]++; costs[k]+=v["cost_usd"] } else unknown[k]++
      tokens[k]+=(v["tokens_in"]+0)-(v["tokens_cached"]+0)+(v["tokens_out"]+0)
      if (v["finished"] ~ /^[0-9]+$/ && v["finished"]+0 >= v["started"]+0) { seconds[k]+=v["finished"]-v["started"]; durations[k]++ }
    }
  ' "${status_files[@]}"
  exit 0
fi

if (( list_projects == 1 )); then
  printf 'Projects found in: %s\n' "$(search_roots_display)"
  print_projects
  exit 0
fi

# Validate and dedupe worker lists (flag > env > config) before any use.
known_workers="claude codex opencode grok ccr"
agy_worker_message='agy can no longer run as a worker: Antigravity blocks CLI calls from other AI agents. Use opencode, codex, claude, grok or ccr.'
# Prints a worker list without agy (no note); used where the list is only read.
drop_agy_worker() {
  local item out=""
  for item in ${1//,/ }; do
    [[ "$item" == agy ]] || out="${out:+$out,}$item"
  done
  printf '%s' "$out"
}
# normalize_worker_list LIST NAME: agy on the command line is an error; from the
# saved config or the environment it is dropped with one note.
normalize_worker_list() {
  local item out="" kept
  if [[ " ${1//,/ } " == *" agy "* ]]; then
    if (( workers_cli == 1 )); then
      echo "$agy_worker_message" >&2
      exit 2
    fi
    kept="$(drop_agy_worker "$1")"
    echo "Note: ignoring agy in ${2:-workers}: Antigravity blocks CLI calls from other AI agents, so it cannot be a worker." >&2
    set -- "$kept" "${2:-}"
  fi
  for item in ${1//,/ }; do
    [[ " $known_workers " == *" $item "* ]] || {
      echo "Unknown worker: $item (use one of: ${known_workers// /, })" >&2
      exit 2
    }
    in_list "$out" "$item" || out="${out:+$out,}$item"
  done
  printf '%s' "$out"
}
# Remember whether the allow-list came from the flag/env (as opposed to the
# saved config), so the manager prompt can describe a custom saved order.
workers_from_flag=0
if [[ -n "$workers_opt" ]]; then
  workers_from_flag=1
fi
workers_opt="$(normalize_worker_list "${workers_opt:-$(devkit_config_get workers)}" workers)" || exit 2
disable_workers_opt="$(normalize_worker_list "${disable_workers_opt:-$(devkit_config_get disabled_workers)}" disabled_workers)" || exit 2
setup_mode="$(devkit_config_get setup_mode)"

if (( scout_cli == 1 )); then
  squad_worker_parse_scout_spec "$scout_opt" || exit 2
  scout_engine_opt="$parsed_scout_engine"
  scout_model_opt="$parsed_scout_model"
  scout_source="flag"
  if ! worker_enabled "$scout_engine_opt"; then
    echo "Scout engine '$scout_engine_opt' is disabled by worker settings" >&2
    exit 2
  fi
elif [[ -n "${SQUAD_WORKER_SCOUT_ENGINE:-}" ]]; then
  if [[ "$SQUAD_WORKER_SCOUT_ENGINE" == *:* ]]; then
    echo "Unknown scout engine: $SQUAD_WORKER_SCOUT_ENGINE (use claude, codex, opencode, grok, or ccr)" >&2
    exit 2
  fi
  squad_worker_parse_scout_spec "$SQUAD_WORKER_SCOUT_ENGINE${SQUAD_WORKER_SCOUT_MODEL:+:$SQUAD_WORKER_SCOUT_MODEL}" || exit 2
  scout_engine_opt="$parsed_scout_engine"
  scout_model_opt="$parsed_scout_model"
  scout_source="env"
  if ! worker_enabled "$scout_engine_opt"; then
    echo "Scout engine '$scout_engine_opt' is disabled by worker settings" >&2
    exit 2
  fi
elif [[ -n "${SQUAD_WORKER_SCOUT_MODEL:-}" ]]; then
  echo 'SQUAD_WORKER_SCOUT_MODEL requires SQUAD_WORKER_SCOUT_ENGINE' >&2
  exit 2
else
  cfg_scout_engine="$(devkit_config_get scout_engine)"
  cfg_scout_model="$(devkit_config_get scout_model)"
  if [[ -z "$cfg_scout_engine" && -n "$cfg_scout_model" ]]; then
    echo 'scout_model in config requires scout_engine' >&2
    exit 2
  fi
  if [[ -n "$cfg_scout_engine" ]]; then
    if [[ "$cfg_scout_engine" == *:* ]]; then
      echo "Unknown scout engine: $cfg_scout_engine (use claude, codex, opencode, grok, or ccr)" >&2
      exit 2
    fi
    squad_worker_parse_scout_spec "$cfg_scout_engine${cfg_scout_model:+:$cfg_scout_model}" || exit 2
    scout_engine_opt="$parsed_scout_engine"
    scout_model_opt="$parsed_scout_model"
    scout_source="config"
  fi
fi

interactive=0
if [[ -z "$devkit_action" ]] && (( no_prompt == 0 )) && { [[ -t 0 ]] || is_truthy "${SQUAD_DEVKIT_FORCE_PROMPT:-}"; }; then
  interactive=1
fi

if (( doctor == 1 )); then
  run_doctor
  exit $?
fi

if (( setup == 1 )); then
  if [[ ! -t 0 ]] && ! is_truthy "${SQUAD_DEVKIT_FORCE_PROMPT:-}"; then
    printf 'squad-devkit --setup needs an interactive terminal\n' >&2
    exit 2
  fi
  run_setup_wizard
  exit $?
fi
# Cleaning needs no manager, so it works where no manager CLI is installed.
if (( clean_only == 0 )); then
  manager_client="$(resolve_manager "$manager_client" "$interactive")"
  validate_yolo_client "$manager_client"
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
  if [[ -z "$devkit_action" ]] && ! git -C "$project_directory" rev-parse --show-toplevel >/dev/null 2>&1; then
    printf 'Note: %s is not a git repository; squad init will create .squad/ there.\n' \
      "$project_directory" >&2
  fi
  project_directory="$(cd "$project_directory" && pwd -P)"
  if [[ "$project_directory" == "$(cd "$HOME" && pwd -P)" ]] && ! is_truthy "${SQUAD_DEVKIT_ALLOW_HOME:-}"; then
    echo "Refusing to use your home directory as the project; pass a project name or path." >&2
    exit 1
  fi
  general_ws_candidate="${SQUAD_DEVKIT_GENERAL_WORKSPACE:-$HOME/.squad-devkit}"
  if [[ -d "$general_ws_candidate" && "$project_directory" == "$(cd "$general_ws_candidate" && pwd -P)" ]]; then
    general_workspace=1
  fi
fi
project_name="$(basename "$project_directory" | tr -cs '[:alnum:]' '-' | cut -c1-24)"
project_hash="$(printf '%s' "$project_directory" | cksum | awk '{print $1}')"
session_name="squad-devkit-${project_name}-${project_hash}"

require_command squad
worker_engines=()
# Worker engines in the effective allow-list order when one is set (so the
# manager prefers them in the order the human chose), otherwise the built-in
# trust order (claude > codex > opencode > grok > ccr).
if [[ -n "$workers_opt" ]]; then
  for engine in ${workers_opt//,/ }; do
    if command -v "$engine" >/dev/null 2>&1 && worker_enabled "$engine"; then
      worker_engines+=("$engine")
    fi
  done
else
  # shellcheck disable=SC2154 # worker_engine_order is defined in lib/squad-devkit-agents.sh
  for engine in "${worker_engine_order[@]}"; do
    if command -v "$engine" >/dev/null 2>&1 && worker_enabled "$engine"; then
      worker_engines+=("$engine")
    fi
  done
fi
if (( ${#worker_engines[@]} == 0 && clean_only == 0 )); then
  echo "Note: no worker engine (claude, codex, opencode, grok, ccr) is installed; the manager will do the work itself." >&2
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

worker_command="$script_dir/squad-worker.sh"
template_marker='<!-- squad-devkit template'

build_manager_prompt() {
  local worker_line=""
  local worker_catalog=""
  local missing_mapping=""
  local worker_order_line=""
  local prompt=""
  local eff_scout_engine="$scout_engine_opt"
  local eff_scout_model="$scout_model_opt"
  local scout_guidance=""
  if [[ -n "$eff_scout_engine" ]] && { ! command -v "$eff_scout_engine" >/dev/null 2>&1 || ! worker_enabled "$eff_scout_engine"; }; then
    if [[ "$scout_source" == flag || "$scout_source" == env ]]; then
      echo "Scout engine not installed: $eff_scout_engine" >&2
      return 2
    fi
    if (( ${#worker_engines[@]} > 0 )); then
      echo "Note: ignoring unavailable/disabled scout_engine '$eff_scout_engine' in config; auto-selecting scout engine." >&2
    fi
    eff_scout_engine=""
    eff_scout_model=""
  fi
  if (( ${#worker_engines[@]} == 0 )); then
    worker_line="No worker engine is installed, so do the work yourself instead of starting squad-worker."
  else
    worker_catalog="$(squad_worker_model_catalog "${worker_engines[@]}")" || return $?
    while IFS= read -r missing_mapping; do
      [[ -z "$missing_mapping" ]] || printf 'Worker models: %s; run squad config workers, then squad-worker --models.\n' "$missing_mapping" >&2
    done < <(printf '%s' "$worker_catalog" | squad_jq -r '.[] | select(.installed and .tier != "" and .source == "unresolved" and .engine != "ccr") | "\(.engine) \(.tier): set SQUAD_WORKER_\(.engine | ascii_upcase)_MODEL_\(.tier | ascii_upcase)"')
    worker_order_line="Installed worker engines, most trusted first: ${worker_engines[*]}"
    if [[ "$setup_mode" == custom && "$workers_from_flag" == 0 && -n "$workers_opt" ]]; then
      worker_order_line="Installed worker engines, in the order the human chose (prefer earlier ones): ${worker_engines[*]}"
    fi
    if squad_worker_resolve_scout_target "$eff_scout_engine" "$eff_scout_model" "${worker_engines[@]}"; then
      scout_guidance="$(squad_worker_format_scout_guidance)"
    elif [[ -n "${scout_resolved_error:-}" ]]; then
      echo "$scout_resolved_error" >&2
      return 2
    fi
    worker_line="squad-worker is: $worker_command
Always pass --manager <your manager ID> (given at the end of these instructions) on every worker launch; do not rely on inherited environment variables.
$worker_order_line
Mapped worker models (local configuration; provider availability unverified; use only these):
$(printf '%s' "$worker_catalog" | squad_jq -r '
  (reduce .[].engine as $engine ([]; if index($engine) then . else . + [$engine] end)) as $order
  | . as $rows
  | $order[] as $engine
  | [$rows[] | select(.engine == $engine and .tier != "" and .candidate != null)
      | if .effort != null then "\(.tier)=\(.candidate) (effort \(.effort))" else "\(.tier)=\(.candidate)" end]
  | if length == 0 then "\($engine): CLI default only" else "\($engine): " + join(", ") end')
Scout worker (read-only, no --plan needed): $scout_guidance
In Claude Code, start workers with run_in_background: true; you are notified when each one exits. In other CLIs, start each worker as a detached job (squad-worker ... >.squad/workers/<id>.out 2>&1 &); each worker messages you when it finishes, so wait with one command, squad receive <your manager ID> --wait --timeout 900, instead of polling or sleeping."
  fi
  if [[ -n "${SQUAD_DEVKIT_ROUTER_URL:-}" ]]; then
    worker_line+=$'\n'"squad-route is configured: $script_dir/squad-route.sh \"<redacted digest>\""
  fi
  prompt="You are the {{MANAGER_LABEL}} manager of this squad devkit, in an interactive session in this repository. You have already joined the squad; workers report to you automatically.
$worker_line"
  if (( general_workspace == 1 )); then
    prompt+=$'\n\n'"You are in the general squad workspace ($project_directory), not inside a project. Many requests need no repository: checking logs or metrics (prod, staging), querying data, and writing reports. Run those workers here without --project, give them the MCP servers they need, and save reports under reports/ in this workspace. When a request changes or inspects code, work out which repositories it involves (they live under ~/Workspace; $script_dir/squad-devkit.sh --list lists them) and pass --project <repository path> to those squad-worker runs. Keep plans in .squad/plans/ here. Ask the human only when the repository is genuinely unclear."
  else
    prompt+=$'\n\n'"Workers work in this repository by default; pass --project <path> to have one work in another repository."
  fi
  prompt+=$'\n\n'"The human's messages in the chat are their requests. When a message gives you work, start investigating and planning right away, without asking for the objective again unless it is genuinely ambiguous. Do not repeat these instructions to the human."
  printf '%s' "$prompt"
}

refresh_project_roles() {
  local target_project="${1:-$project_directory}"
  local role=""
  local source=""
  local destination=""
  mkdir -p "$target_project/.squad/roles"
  for role in manager-devkit manager-hierarchy dev tester reviewer researcher scout ui-ux security sub-manager; do
    source="$script_dir/../templates/devkit/$role.md"
    destination="$target_project/.squad/roles/$role.md"
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

run_reload() {
  refresh_project_roles "$project_directory"
  printf 'roles refreshed (%s/.squad/roles)\n' "$project_directory"

  local install_out=""
  if install_out="$("$script_dir/install-devkit.sh" --no-prompt --no-hud 2>&1)"; then
    printf 'links refreshed\n'
  else
    printf '%s\n' "$install_out" >&2
    return 1
  fi

  local view_count=0
  local pid=""
  local uid="${UID:-}"
  if [[ -z "$uid" ]]; then
    if command -v id >/dev/null 2>&1; then
      uid="$(id -u)"
    elif [[ -x /usr/bin/id ]]; then
      uid="$(/usr/bin/id -u)"
    fi
  fi
  local pgrep_bin="pgrep"
  if ! command -v pgrep >/dev/null 2>&1 && [[ -x /usr/bin/pgrep ]]; then
    pgrep_bin="/usr/bin/pgrep"
  fi
  if command -v "$pgrep_bin" >/dev/null 2>&1 || [[ -x "$pgrep_bin" ]]; then
    while IFS= read -r pid; do
      [[ -n "$pid" && "$pid" != "$$" ]] || continue
      if kill -HUP "$pid" 2>/dev/null; then
        view_count=$((view_count + 1))
      fi
    done < <("$pgrep_bin" -u "$uid" -f 'squad-orchestration\.sh' 2>/dev/null || true)
  fi
  printf '%d orchestration views reloaded\n' "$view_count"

  if [[ -n "${HERDR_PANE_ID:-}" ]]; then
    # shellcheck source=/dev/null
    source "$script_dir/lib/squad-panes.sh"
    squad_panes_herdr_reap_stale "$HERDR_PANE_ID"
    if [[ "${SQUAD_PANES_REAPED:-0}" -gt 0 ]]; then
      printf '%d stale squad panes closed\n' "$SQUAD_PANES_REAPED"
    fi
  fi

  local prompt=""
  prompt="$(build_manager_prompt)" || return $?
  local mgr_id="${SQUAD_MANAGER_ID:-manager}"
  local instructions=""
  instructions="$(build_manager_instructions "$manager_client" "$prompt" "$mgr_id" "$project_directory")"
  printf 'Follow these instructions from now on; they replace the squad-devkit instructions given at session start.\n'
  printf '## Updated squad-devkit manager instructions (replace the earlier ones)\n\n'
  printf '%s\n' "$instructions"

  local cfg_view=""
  cfg_view="$(devkit_config_get view)"
  local effective_cfg_view="${cfg_view:-orchestration}"
  if [[ -n "$caller_worker_view" && "$caller_worker_view" != "$effective_cfg_view" ]]; then
    printf '\nNote: session env SQUAD_WORKER_VIEW=%s differs from config view=%s (squad-worker reads config when SQUAD_WORKER_VIEW is unset).\n' \
      "$caller_worker_view" "$effective_cfg_view"
  fi
}

if [[ "$devkit_action" == reload ]]; then
  run_reload
  exit 0
fi

if [[ "$backend" == tmux ]]; then
  require_command tmux
elif [[ "$backend" == ghostty ]]; then
  osascript_command="${SQUAD_DEVKIT_OSASCRIPT:-osascript}"
  require_command "$osascript_command"
fi

manager_prompt="$(build_manager_prompt)" || exit $?
manager_command="$(shell_join "$script_dir/lib/squad-devkit-manager.sh" "$manager_client" "$manager_prompt" "$objective")"
manager_env_args=("SQUAD_DEVKIT_YOLO=${SQUAD_DEVKIT_YOLO:-0}" "SQUAD_WORKER_VIEW=$view_opt")
if [[ "$scout_source" == flag || "$scout_source" == env ]]; then
  manager_env_args+=("SQUAD_WORKER_SCOUT_ENGINE=$scout_engine_opt" "SQUAD_WORKER_SCOUT_MODEL=$scout_model_opt")
fi
manager_command="$(shell_join env "${manager_env_args[@]}") $manager_command"
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
  refresh_project_roles "$project_directory"
}

# squad-worker splits worker monitor panes next to this Ghostty terminal.
ghostty_focused_terminal='tell application "Ghostty" to get id of focused terminal of selected tab of front window'

if [[ "$backend" == here ]]; then
  prepare_project
  cd "$project_directory"
  if [[ -z "${TMUX:-}" ]]; then
    SQUAD_DEVKIT_ORCA_TERMINAL="$(squad_panes_orca_manager "$project_directory")"
    export SQUAD_DEVKIT_ORCA_TERMINAL
  fi
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
