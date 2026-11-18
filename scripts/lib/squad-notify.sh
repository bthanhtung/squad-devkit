#!/usr/bin/env bash
# Sourced by callers; notifications are best effort.
squad_notify() {
  # Phone copy for the Telegram remote; a no-op unless it is set up.
  if [[ -n "${SQUAD_DEVKIT_WORKSPACE:-}" ]]; then
    declare -F tg_spool_put >/dev/null 2>&1 ||
      source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/squad-telegram-spool.sh" 2>/dev/null || true
    tg_spool_put "${SQUAD_DEVKIT_WORKSPACE##*/}/${SQUAD_MANAGER_ID:-manager}" worker "${1:-}: ${2:-}" 2>/dev/null || true
  fi
  [[ "${SQUAD_DEVKIT_NOTIFY:-1}" != 0 ]] || return 0
  local title body
  title="$(printf '%s' "${1:-}" | LC_ALL=C tr -d '[:cntrl:]')"
  body="$(printf '%s' "${2:-}" | LC_ALL=C tr -d '[:cntrl:]' | cut -c 1-200)"
  if [[ "$(uname -s)" == Darwin ]] && command -v osascript >/dev/null 2>&1; then
    osascript - "$title" "$body" >/dev/null 2>&1 <<'APPLESCRIPT' || true
on run argv
  display notification (item 2 of argv) with title (item 1 of argv)
end run
APPLESCRIPT
  elif [[ "$(uname -s)" == Linux ]] && command -v notify-send >/dev/null 2>&1; then
    notify-send -- "$title" "$body" >/dev/null 2>&1 || true
  fi
  return 0
}
