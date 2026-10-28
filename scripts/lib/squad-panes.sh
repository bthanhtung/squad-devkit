#!/usr/bin/env bash
# Opens a squad worker's monitor next to the manager, in whatever terminal the
# manager runs in. Terminals with a split API get a pane beside the manager
# (the first worker to its right, later workers stacked below the previous
# one, focus kept on the manager): tmux, Herdr, WezTerm, Kitty, iTerm2,
# Ghostty, and Zellij (floating panes). Other terminals, such as macOS
# Terminal.app, GNOME Terminal, or Konsole, get one dashboard window per
# manager session running `squad-worker-monitor --all`.
#
# squad_open_monitor <command-script> <title> <workspace> <state-directory> <dashboard-script>
# SQUAD_WORKER_PANES=0 disables panes; SQUAD_WORKER_DASHBOARD=0 disables the
# dashboard window.

squad_panes_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Serialise splits so parallel workers stack instead of splitting the same pane.
squad_panes_lock() {
  local lock="$1/.pane.lock"
  for _ in $(seq 1 40); do
    mkdir "$lock" 2>/dev/null && return 0
    sleep 0.25
  done
  return 0
}

squad_panes_unlock() {
  rmdir "$1/.pane.lock" 2>/dev/null || true
}

squad_open_monitor() {
  local command_script="$1" title="$2" workspace="$3" state="$4" dashboard_script="$5"
  [[ "${SQUAD_WORKER_PANES:-1}" != 0 ]] || return 0
  local osascript_command="${SQUAD_DEVKIT_OSASCRIPT:-osascript}"
  local backend="" manager=""
  if [[ -n "${TMUX:-}" && -n "${TMUX_PANE:-}" ]] && command -v tmux >/dev/null 2>&1; then
    backend=tmux; manager="$TMUX_PANE"
  elif [[ -n "${HERDR_PANE_ID:-}" ]] && command -v herdr >/dev/null 2>&1; then
    backend=herdr; manager="$HERDR_PANE_ID"
  elif [[ -n "${ZELLIJ:-}" ]] && command -v zellij >/dev/null 2>&1; then
    backend=zellij; manager="${ZELLIJ_SESSION_NAME:-zellij}"
  elif [[ -n "${WEZTERM_PANE:-}" ]] && command -v wezterm >/dev/null 2>&1; then
    backend=wezterm; manager="$WEZTERM_PANE"
  elif [[ -n "${KITTY_WINDOW_ID:-}" ]] && command -v kitten >/dev/null 2>&1; then
    backend=kitty; manager="$KITTY_WINDOW_ID"
  elif [[ -n "${ITERM_SESSION_ID:-}" ]] && command -v "$osascript_command" >/dev/null 2>&1; then
    backend=iterm; manager="${ITERM_SESSION_ID#*:}"
  elif [[ -n "${SQUAD_DEVKIT_GHOSTTY_TERMINAL:-}" ]] && command -v "$osascript_command" >/dev/null 2>&1; then
    backend=ghostty; manager="$SQUAD_DEVKIT_GHOSTTY_TERMINAL"
  fi

  if [[ -n "$backend" ]]; then
    squad_panes_lock "$state"
    local last_file="$state/.$backend-${manager//[^A-Za-z0-9_-]/_}.last" previous="" created=""
    [[ -f "$last_file" ]] && previous="$(cat "$last_file")"
    created="$("squad_panes_$backend" "$manager" "$previous" "$command_script" "$title" "$workspace" 2>/dev/null || true)"
    [[ -n "$created" ]] && printf '%s\n' "$created" >"$last_file"
    squad_panes_unlock "$state"
    [[ -n "$created" ]] && return 0
  fi
  squad_panes_dashboard "$dashboard_script" "$state"
}

squad_panes_tmux() {
  local manager="$1" command_script="$3" title="$4" workspace="$5" pane
  pane="$(tmux split-window -d -h -P -F '#{pane_id}' -t "$manager" -c "$workspace" "$command_script")" || return 1
  tmux select-pane -t "$pane" -T "$title" 2>/dev/null || true
  tmux select-layout -t "$manager" main-vertical 2>/dev/null || true
  printf '%s\n' "$pane"
}

squad_panes_herdr() {
  local manager="$1" previous="$2" command_script="$3" title="$4" workspace="$5" output="" created
  if [[ -n "$previous" ]]; then
    output="$(herdr pane split "$previous" --direction down --cwd "$workspace" 2>/dev/null || true)"
  fi
  if [[ "$output" != *'"pane_id"'* ]]; then
    output="$(herdr pane split "$manager" --direction right --cwd "$workspace")" || return 1
  fi
  created="$(printf '%s' "$output" | sed -n 's/.*"pane_id":"\([^"]*\)".*/\1/p')"
  [[ -n "$created" ]] || return 1
  herdr pane rename "$created" "$title" >/dev/null 2>&1 || true
  herdr pane run "$created" "exec $(printf '%q' "$command_script")" >/dev/null 2>&1 || true
  printf '%s\n' "$created"
}

squad_panes_wezterm() {
  local manager="$1" previous="$2" command_script="$3" workspace="$5" created=""
  if [[ -n "$previous" ]]; then
    created="$(wezterm cli split-pane --pane-id "$previous" --bottom --cwd "$workspace" -- "$command_script" 2>/dev/null || true)"
  fi
  if [[ -z "$created" ]]; then
    created="$(wezterm cli split-pane --pane-id "$manager" --right --percent 40 --cwd "$workspace" -- "$command_script")" || return 1
  fi
  wezterm cli activate-pane --pane-id "$manager" >/dev/null 2>&1 || true
  printf '%s\n' "$created"
}

squad_panes_kitty() {
  local manager="$1" previous="$2" command_script="$3" title="$4" workspace="$5" created=""
  if [[ -n "$previous" ]]; then
    created="$(kitten @ launch --keep-focus --match "id:$previous" --location=hsplit \
      --title "$title" --cwd "$workspace" "$command_script" 2>/dev/null || true)"
  fi
  if [[ -z "$created" ]]; then
    created="$(kitten @ launch --keep-focus --match "id:$manager" --location=vsplit \
      --title "$title" --cwd "$workspace" "$command_script")" || return 1
  fi
  printf '%s\n' "$created"
}

squad_panes_iterm() {
  "${SQUAD_DEVKIT_OSASCRIPT:-osascript}" "$squad_panes_lib/squad-worker-iterm.applescript" \
    "$1" "$2" "$(printf '%q' "$3")" "$4"
}

squad_panes_ghostty() {
  "${SQUAD_DEVKIT_OSASCRIPT:-osascript}" "$squad_panes_lib/squad-worker-ghostty.applescript" \
    "$1" "$2" "$5" "$3" "$4"
}

# Zellij runs commands only next to the focused pane, so workers open as
# floating panes (toggle them with Zellij's floating-pane key) instead.
squad_panes_zellij() {
  local command_script="$3" title="$4" workspace="$5"
  zellij run --floating --close-on-exit --name "$title" --cwd "$workspace" -- "$command_script" >/dev/null || return 1
  printf 'floating\n'
}

# One dashboard window per manager session for terminals without a split API.
squad_panes_dashboard() {
  local dashboard_script="$1" state="$2" marker
  [[ "${SQUAD_WORKER_DASHBOARD:-1}" != 0 && -n "$dashboard_script" ]] || return 0
  marker="$state/.dashboard-${SQUAD_DEVKIT_MANAGER_WRAPPER_PID:-$PPID}"
  [[ -e "$marker" ]] && return 0
  local osascript_command="${SQUAD_DEVKIT_OSASCRIPT:-osascript}" quoted
  quoted="$(printf '%q' "$dashboard_script")"
  case "${TERM_PROGRAM:-}" in
    Apple_Terminal)
      "$osascript_command" -e "tell application \"Terminal\" to do script \"exec $quoted\"" >/dev/null 2>&1 || return 0
      ;;
    *)
      [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]] || return 0
      if command -v x-terminal-emulator >/dev/null 2>&1; then
        x-terminal-emulator -e "$dashboard_script" >/dev/null 2>&1 &
      elif command -v gnome-terminal >/dev/null 2>&1; then
        gnome-terminal -- "$dashboard_script" >/dev/null 2>&1 &
      elif command -v konsole >/dev/null 2>&1; then
        konsole -e "$dashboard_script" >/dev/null 2>&1 &
      elif command -v xfce4-terminal >/dev/null 2>&1; then
        xfce4-terminal -e "$quoted" >/dev/null 2>&1 &
      elif command -v xterm >/dev/null 2>&1; then
        xterm -e "$dashboard_script" >/dev/null 2>&1 &
      else
        return 0
      fi
      ;;
  esac
  : >"$marker"
}
