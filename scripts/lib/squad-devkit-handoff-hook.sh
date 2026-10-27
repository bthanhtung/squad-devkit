#!/usr/bin/env bash
# Claude Code StopFailure hook installed by squad-devkit-manager.sh. When a
# turn ends because the account hit its usage or billing limit, it saves the
# hook input (error, transcript path) and stops the Claude Code process, so
# the manager wrapper can hand the session to the fallback manager.
# Usage: squad-devkit-handoff-hook.sh <marker-file>
set -euo pipefail

marker="$1"
cat >"$marker.tmp"
mv "$marker.tmp" "$marker"

# The Claude Code process is the ancestor whose parent is the manager wrapper.
wrapper_pid="${SQUAD_DEVKIT_MANAGER_WRAPPER_PID:-}"
[[ -n "$wrapper_pid" ]] || exit 0
process="$PPID"
while [[ -n "$process" && "$process" -gt 1 ]]; do
  parent="$(ps -o ppid= -p "$process" 2>/dev/null | tr -d ' ')"
  if [[ "$parent" == "$wrapper_pid" ]]; then
    # Let Claude Code finish printing the error before it stops.
    (sleep "${SQUAD_DEVKIT_HANDOFF_DELAY:-2}"; kill -TERM "$process" 2>/dev/null) >/dev/null 2>&1 &
    exit 0
  fi
  process="$parent"
done
exit 0
