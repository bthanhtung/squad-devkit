#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/lib/squad-tmux-launcher-helpers.sh"
source "$script_dir/lib/squad-devkit-agents.sh"

usage() {
  cat <<'EOF'
Usage: install-devkit.sh [--manager CLI] [--no-prompt] [--no-hud]

Link squad-devkit, squad-worker, and squad-monitor into ~/.local/bin (or SQUAD_DEVKIT_BIN_DIR)
and choose the manager CLI. Claude Code is the default when installed; without
it, the installer asks which installed CLI should manage and saves the answer.
Re-run it, or run squad-devkit --setup, to change the choice.

If the claude-hud status line plugin is installed, the installer also turns on
its weekly quota and usage-pace display (display.sevenDayThreshold = 0,
display.usagePace = true) unless you already set those keys; --no-hud skips it.
The manager's status line then shows the weekly quota next to the squad label.
EOF
}

manager_client=""
no_prompt=0
configure_hud=1
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
    --no-hud) configure_hud=0 ;;
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
ln -sfn "$script_dir/squad-worker-monitor.sh" "$bin_directory/squad-monitor"
printf 'Linked squad-devkit, squad-worker, and squad-monitor into %s\n' "$bin_directory"
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
for engine in claude codex opencode grok agy ccr; do
  if command -v "$engine" >/dev/null 2>&1; then
    worker_engines+=("$engine")
  fi
done
if (( ${#worker_engines[@]} == 0 )); then
  echo 'Workers: none (install claude, codex, opencode, grok, agy, or ccr; until then the manager does the work itself)'
else
  printf 'Workers (most trusted first): %s\n' "${worker_engines[*]}"
fi
hud_config="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/claude-hud/config.json"
if (( configure_hud == 1 )) && [[ -d "$(dirname "$hud_config")" ]] && command -v jq >/dev/null 2>&1; then
  current="$(cat "$hud_config" 2>/dev/null || echo '{}')"
  if updated="$(jq '.display = ({sevenDayThreshold: 0, usagePace: true} + (.display // {}))' <<<"$current" 2>/dev/null)"; then
    if [[ "$(jq -c . <<<"$current" 2>/dev/null)" != "$(jq -c . <<<"$updated")" ]]; then
      printf '%s\n' "$updated" >"$hud_config.tmp" && mv "$hud_config.tmp" "$hud_config"
      echo "claude-hud: weekly quota and usage pace enabled ($hud_config)"
    else
      echo 'claude-hud: weekly quota display already configured'
    fi
  fi
fi
echo 'Start with: squad-devkit [project] [objective]'
