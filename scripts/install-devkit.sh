#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/lib/squad-tmux-launcher-helpers.sh"
source "$script_dir/lib/squad-devkit-agents.sh"

usage() {
  cat <<'EOF'
Usage: install-devkit.sh [--manager CLI] [--no-prompt]

Link squad-devkit and squad-worker into ~/.local/bin (or SQUAD_DEVKIT_BIN_DIR)
and choose the manager CLI. Claude Code is the default when installed; without
it, the installer asks which installed CLI should manage and saves the answer.
Re-run it, or run squad-devkit --setup, to change the choice.
EOF
}

manager_client=""
no_prompt=0
while (( $# > 0 )); do
  case "$1" in
    --manager)
      if (( $# < 2 )) || [[ -z "$2" ]]; then
        echo "Missing value for $1" >&2
        exit 2
      fi
      manager_client="$2"
      shift
      ;;
    --manager=*) manager_client="${1#*=}" ;;
    --no-prompt) no_prompt=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if ! command -v squad >/dev/null 2>&1; then
  echo "Missing command: squad (install it with: brew install mco-org/tap/squad)" >&2
  exit 1
fi

bin_directory="${SQUAD_DEVKIT_BIN_DIR:-$HOME/.local/bin}"
mkdir -p "$bin_directory"
ln -sfn "$script_dir/squad-devkit.sh" "$bin_directory/squad-devkit"
ln -sfn "$script_dir/squad-worker.sh" "$bin_directory/squad-worker"
printf 'Linked squad-devkit and squad-worker into %s\n' "$bin_directory"
case ":$PATH:" in
  *":$bin_directory:"*) ;;
  *) printf 'Add %s to your PATH to run them from any terminal.\n' "$bin_directory" ;;
esac

interactive=0
if (( no_prompt == 0 )) && { [[ -t 0 ]] || is_truthy "${SQUAD_DEVKIT_FORCE_PROMPT:-}"; }; then
  interactive=1
fi
if [[ -n "$manager_client" ]]; then
  manager_client="$(resolve_manager "$manager_client" "$interactive")"
  save_manager "$manager_client"
else
  manager_client="$(resolve_manager "" "$interactive")"
fi
printf 'Manager: %s (%s)\n' "$manager_client" "$(manager_label "$manager_client")"

worker_engines=()
for engine in codex ccr; do
  if command -v "$engine" >/dev/null 2>&1; then
    worker_engines+=("$engine")
  fi
done
if (( ${#worker_engines[@]} == 0 )); then
  echo 'Workers: none (install codex or ccr; until then the manager does the work itself)'
else
  printf 'Workers: %s\n' "${worker_engines[*]}"
fi
echo 'Start with: squad-devkit [project] [objective]'
