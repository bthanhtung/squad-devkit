#!/usr/bin/env bash
# Sourced by callers; notifications are best effort.
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
  body="$(printf '%s' "${2:-}" | LC_ALL=C tr -d '[:cntrl:]' | cut -c 1-200)"
  if [[ "$(uname -s)" == Darwin ]]; then
    local notify_backend="${SQUAD_DEVKIT_NOTIFY_BACKEND:-auto}"
    local app_path="${SQUAD_DEVKIT_NOTIFY_APP:-${XDG_DATA_HOME:-$HOME/.local/share}/squad-devkit/SquadNotifier.app}"
    local workspace subtitle bundle_id app_name="" backend="" handle="" tmux_socket="" cli_path="" kitty_listen_on="" orca_cmd
    workspace="$(printf '%s' "${SQUAD_DEVKIT_WORKSPACE:-}" | LC_ALL=C tr -d '[:cntrl:]')"
    subtitle="${workspace##*/}"
    bundle_id="${SQUAD_DEVKIT_NOTIFY_BUNDLE_ID:-${__CFBundleIdentifier:-}}"
    if [[ "${TERM_PROGRAM:-}" == Orca || -n "${SQUAD_DEVKIT_ORCA_TERMINAL:-}${ORCA_TERMINAL_HANDLE:-}${ORCA_PANE_KEY:-}" ]]; then
      app_name=Orca; bundle_id="${bundle_id:-com.stablyai.orca}"
    elif [[ "${TERM_PROGRAM:-}" == Herdr || -n "${HC_TERMINAL_ID:-}" ]]; then
      app_name=Herdr; bundle_id="${bundle_id:-dev.herdr.app}"
    elif [[ "${TERM_PROGRAM:-}" == ghostty || -n "${SQUAD_DEVKIT_GHOSTTY_TERMINAL:-}" ]]; then
      app_name=Ghostty; bundle_id="${bundle_id:-com.mitchellh.ghostty}"
    elif [[ "${TERM_PROGRAM:-}" == iTerm.app || -n "${ITERM_SESSION_ID:-}" ]]; then
      app_name=iTerm; bundle_id="${bundle_id:-com.googlecode.iterm2}"
    elif [[ "${TERM_PROGRAM:-}" == WezTerm || -n "${WEZTERM_PANE:-}" ]]; then
      app_name=WezTerm; bundle_id="${bundle_id:-com.github.wez.wezterm}"
    elif [[ "${TERM_PROGRAM:-}" == kitty || -n "${KITTY_WINDOW_ID:-}" ]]; then
      app_name=kitty; bundle_id="${bundle_id:-net.kovidgoyal.kitty}"
    else
      case "${TERM_PROGRAM:-}" in
        Apple_Terminal) app_name=Terminal; bundle_id="${bundle_id:-com.apple.Terminal}" ;;
        vscode) app_name='Visual Studio Code'; bundle_id="${bundle_id:-com.microsoft.VSCode}" ;;
        WarpTerminal) app_name=Warp; bundle_id="${bundle_id:-dev.warp.Warp-Stable}" ;;
      esac
    fi
    if [[ -n "${TMUX:-}" && -n "${TMUX_PANE:-}" ]]; then
      backend=tmux; handle="$TMUX_PANE"; tmux_socket="${TMUX%%,*}"; cli_path="$(command -v tmux 2>/dev/null || true)"
    elif [[ -n "${SQUAD_DEVKIT_ORCA_TERMINAL:-}${ORCA_TERMINAL_HANDLE:-}${ORCA_PANE_KEY:-}" ]]; then
      backend=orca; handle="${SQUAD_DEVKIT_ORCA_TERMINAL:-${ORCA_TERMINAL_HANDLE:-}}"
      orca_cmd="${ORCA_CLI_COMMAND:-}"; if [[ -z "$orca_cmd" ]]; then if [[ -n "${ORCA_DEV_REPO_ROOT:-}" ]]; then orca_cmd=orca-dev; else orca_cmd=orca; fi; fi
      cli_path="$(command -v "$orca_cmd" 2>/dev/null || true)"
    elif [[ -n "${HC_TERMINAL_ID:-}" ]]; then
      backend=herdr_app; handle="${SQUAD_DEVKIT_HERDR_PANE:-${HERDR_PANE_ID:-}}"; cli_path="$(command -v herdr-app 2>/dev/null || true)"
    elif [[ "${HERDR_ENV:-}" == 1 && -n "${HERDR_PANE_ID:-}" ]]; then
      backend=herdr; handle="$HERDR_PANE_ID"; cli_path="$(command -v herdr 2>/dev/null || true)"
    elif [[ -n "${WEZTERM_PANE:-}" ]]; then
      backend=wezterm; handle="$WEZTERM_PANE"; cli_path="$(command -v wezterm 2>/dev/null || true)"
    elif [[ -n "${KITTY_WINDOW_ID:-}" ]]; then
      backend=kitty; handle="$KITTY_WINDOW_ID"; kitty_listen_on="${KITTY_LISTEN_ON:-}"; cli_path="$(command -v kitten 2>/dev/null || true)"
    elif [[ -n "${ITERM_SESSION_ID:-}" ]]; then
      backend=iterm; handle="${ITERM_SESSION_ID#*:}"; cli_path=/usr/bin/osascript
    elif [[ -n "${SQUAD_DEVKIT_GHOSTTY_TERMINAL:-}" || "${TERM_PROGRAM:-}" == ghostty ]]; then
      backend=ghostty; handle="${SQUAD_DEVKIT_GHOSTTY_TERMINAL:-}"
    elif [[ -n "$bundle_id$app_name" ]]; then backend=app
    fi
    if [[ "$notify_backend" == auto || "$notify_backend" == app ]]; then
      local spool_dir tmp_file="" payload_file="" key value first
      local -a payload_values=("$title" "$subtitle" "$body" "$bundle_id" "$app_name" "$backend" "$handle" "$tmux_socket" "$cli_path" "$workspace" "$kitty_listen_on")
      spool_dir="${XDG_DATA_HOME:-$HOME/.local/share}/squad-devkit/notify-spool"
      if [[ -x "$app_path/Contents/MacOS/squad-notifier" ]] && command -v open >/dev/null 2>&1 &&
        mkdir -p "$spool_dir" && chmod 700 "$spool_dir"; then
        find "$spool_dir" -maxdepth 1 -type f -name '*.squadnotify' -mmin +5 -delete 2>/dev/null || true
        tmp_file="$(umask 077 && mktemp "$spool_dir/notify.XXXXXXXX")" || tmp_file=""
        if [[ -n "$tmp_file" ]]; then
          if { printf '{'; first=1
            for key in title subtitle body bundle_id app_name backend handle tmux_socket cli_path workspace kitty_listen_on; do
              value="${payload_values[0]}"; payload_values=("${payload_values[@]:1}"); if (( first )); then first=0; else printf ','; fi
              printf '"%s":' "$key"; squad_notify_json "$value"
            done
            printf '}\n'
          } >"$tmp_file" && mv "$tmp_file" "$tmp_file.squadnotify"; then
            payload_file="$tmp_file.squadnotify"
            if open -g -a "$app_path" "$payload_file" >/dev/null 2>&1; then return 0; fi
            rm -f "$payload_file" || true
          else rm -f "$tmp_file" || true
          fi
        fi
      fi
    fi
    if [[ "$notify_backend" == auto || "$notify_backend" == terminal-notifier ]] && command -v terminal-notifier >/dev/null 2>&1; then
      local -a tn_args=(-title "$title" -message "$body")
      [[ -z "$subtitle" ]] || tn_args+=(-subtitle "$subtitle")
      [[ -z "$bundle_id" ]] || tn_args+=(-activate "$bundle_id")
      if terminal-notifier "${tn_args[@]}" >/dev/null 2>&1; then return 0; fi
    fi
    if [[ "$notify_backend" == auto || "$notify_backend" == osascript ]] && command -v osascript >/dev/null 2>&1; then
    osascript - "$title" "$body" >/dev/null 2>&1 <<'APPLESCRIPT' || true
on run argv
  display notification (item 2 of argv) with title (item 1 of argv)
end run
APPLESCRIPT
    fi
  elif [[ "$(uname -s)" == Linux ]] && command -v notify-send >/dev/null 2>&1; then
    notify-send -- "$title" "$body" >/dev/null 2>&1 || true
  fi
  return 0
}
