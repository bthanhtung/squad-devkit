#!/usr/bin/env bash
# Sourced by callers; notifications are best effort.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/squad-platform.sh"
squad_notify_json() {
  local value
  value="$(printf '%s' "$1" | LC_ALL=C tr -d '[:cntrl:]')"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}

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
  body="$(
    export LC_ALL=C
    body="$(printf '%s' "${2:-}" | tr -d '\000-\037\177')"
    if [[ "$body" == *[$'\200'-$'\377']* ]]; then
      if command -v python3 >/dev/null 2>&1 &&
        printf '%s' "$body" | python3 -c '
import sys
body = sys.stdin.buffer.read().decode("utf-8", errors="replace")
sys.stdout.buffer.write(body[:200].encode("utf-8"))
' 2>/dev/null; then
        exit 0
      fi
      utf8_locale="$(LC_ALL=C locale -a 2>/dev/null | awk 'tolower($0) ~ /utf-?8$/ {print; exit}')"
      if [[ -n "$utf8_locale" ]]; then
        export LC_ALL="$utf8_locale"
        printf '%s' "${body:0:200}"
      else
        # shortcut: ASCII only without Python or a UTF-8 locale, use a UTF-8 locale to retain non-ASCII text.
        tr -d '\200-\377' <<<"${body:0:200}"
      fi
    else
      printf '%s' "${body:0:200}"
    fi
  )"
  local os ps_cmd
  os="$(squad_os_kind)"
  if [[ "$os" == windows || "$os" == wsl || "${SQUAD_DEVKIT_NOTIFY_BACKEND:-}" == powershell ]] &&
    ps_cmd="$(squad_find_powershell)"; then
    if printf '{"title":%s,"body":%s}\n' "$(squad_notify_json "$title")" "$(squad_notify_json "$body")" |
      MSYS2_ARG_CONV_EXCL='*' "$ps_cmd" -NoProfile -NonInteractive -Command '
        try {
          [Console]::InputEncoding = [System.Text.Encoding]::UTF8
          $d = [Console]::In.ReadToEnd() | ConvertFrom-Json
          $title = [System.Security.SecurityElement]::Escape($d.title)
          $body = [System.Security.SecurityElement]::Escape($d.body)
          $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType=WindowsRuntime]
          $xml = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType=WindowsRuntime]::new()
          $xml.LoadXml("<toast><visual><binding template=`"ToastGeneric`"><text>$title</text><text>$body</text></binding></visual></toast>")
          $toast = [Windows.UI.Notifications.ToastNotification, Windows.UI.Notifications, ContentType=WindowsRuntime]::new($xml)
          [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe").Show($toast)
        } catch { exit 1 }
      ' >/dev/null 2>&1; then
      return 0
    fi
  elif [[ "$os" == macos ]] && command -v terminal-notifier >/dev/null 2>&1 &&
    terminal-notifier -title "$title" -message "$body" >/dev/null 2>&1; then
    return 0
  elif [[ "$os" == macos ]] && command -v osascript >/dev/null 2>&1; then
    osascript - "$title" "$body" >/dev/null 2>&1 <<'APPLESCRIPT' || true
on run argv
  display notification (item 2 of argv) with title (item 1 of argv)
end run
APPLESCRIPT
  fi
  if [[ "$os" == linux || "$os" == wsl ]] && command -v notify-send >/dev/null 2>&1; then
    notify-send -- "$title" "$body" >/dev/null 2>&1 || true
  fi
  return 0
}
