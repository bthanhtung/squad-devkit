#!/usr/bin/env bash
# Opens a squad worker's monitor next to the manager, in whatever terminal the
# manager runs in. Terminals with a split API get a pane beside the manager
# (the first worker to its right, later workers stacked below the previous
# one, focus kept on the manager): tmux, Orca, Herdr, WezTerm, Kitty, iTerm2,
# Ghostty, and Zellij (floating panes). Other terminals, such as macOS
# Terminal.app, GNOME Terminal, or Konsole, get one dashboard window per
# manager session running `squad-worker-monitor --all`.
#
# squad_open_monitor <command-script> <title> <workspace> <state-directory> <dashboard-script>
# SQUAD_WORKER_PANES=0 disables panes; SQUAD_WORKER_DASHBOARD=0 disables the
# dashboard window.

squad_panes_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$squad_panes_lib/squad-jq.sh"

# Serialise splits so parallel workers stack instead of splitting the same pane.
squad_panes_lock() {
  local lock="$1/${2:-.pane.lock}"
  for _ in $(seq 1 40); do
    mkdir "$lock" 2>/dev/null && return 0
    sleep 0.25
  done
  return 1
}

squad_panes_unlock() {
  rmdir "$1/${2:-.pane.lock}" 2>/dev/null || true
}

# Resolve one Orca build; never fall through to a different runtime.
squad_panes_orca_cli() {
  if [[ -n "${ORCA_CLI_COMMAND:-}" ]]; then
    printf '%s\n' "$ORCA_CLI_COMMAND"
  elif [[ -n "${ORCA_DEV_REPO_ROOT:-}" ]]; then
    printf 'orca-dev\n'
  elif [[ "$OSTYPE" == linux* && -z "${ORCA_PANE_KEY:-}" ]]; then
    printf 'orca-ide\n'
  else
    printf 'orca\n'
  fi
}

# Only the launcher resolves shell identity; workers inherit the frozen handle.
squad_panes_orca_manager() {
  local workspace="$1" cli
  if [[ -n "${SQUAD_DEVKIT_ORCA_TERMINAL:-}" ]]; then
    printf '%s\n' "$SQUAD_DEVKIT_ORCA_TERMINAL"
    return 0
  fi
  [[ -n "${ORCA_PANE_KEY:-}" ]] || return 0
  cli="$(squad_panes_orca_cli)"
  command -v "$cli" >/dev/null 2>&1 && squad_has_jq || return 0
  "$cli" terminal list --worktree "path:$workspace" --json 2>/dev/null |
    squad_jq -er --arg key "$ORCA_PANE_KEY" '
      select(.ok == true) | [.result.terminals[] |
        select((.tabId + ":" + .leafId) == $key) | .handle] |
      select(length == 1) | .[0] | select(type == "string" and length > 0)' 2>/dev/null || true
}

# Herdr TUI and the desktop app use different servers and terminal IDs.
squad_panes_herdr_kind() {
  if [[ -n "${HC_TERMINAL_ID:-}" ]]; then
    printf 'herdr_app\n'
  elif [[ "${HERDR_ENV:-}" == 1 ]]; then
    printf 'herdr\n'
  fi
}

squad_panes_herdr_app_manager() {
  [[ "$(squad_panes_herdr_kind)" == herdr_app ]] || return 0
  command -v herdr-app >/dev/null 2>&1 && squad_has_jq || return 0
  herdr-app ls 2>/dev/null |
    squad_jq -er --arg term "$HC_TERMINAL_ID" '
      [
        .spaces[]? as $space |
        $space.tabs[]? as $tab |
        $tab.terminals[]? |
        select(.terminal == $term) |
        {
          machine: $space.machine,
          tab: $tab.id,
          pane: .pane
        }
      ] |
      select(length == 1) | .[0] |
      select((.machine == null or .machine == "") and
        (.tab | type == "string" and length > 0) and
        (.pane | type == "string" and length > 0)) |
      .pane' 2>/dev/null || true
}

squad_panes_herdr_manager() {
  [[ "$(squad_panes_herdr_kind)" == herdr ]] || return 0
  command -v herdr >/dev/null 2>&1 && squad_has_jq || return 0
  if [[ -n "${HERDR_PANE_ID:-}" ]]; then
    printf '%s\n' "$HERDR_PANE_ID"
  else
    herdr pane current --current 2>/dev/null |
      squad_jq -er '.result.pane.pane_id | select(type == "string" and length > 0)' 2>/dev/null || true
  fi
}

squad_open_monitor() {
  # shellcheck disable=SC2034 # read by callers (squad-worker.sh)
  SQUAD_PANES_LAST_BACKEND="" SQUAD_PANES_LAST_CREATED="" SQUAD_PANES_LAST_FILE=""
  local command_script="$1" title="$2" workspace="$3" state="$4" dashboard_script="$5"
  local required="${6:-}"
  if [[ "${SQUAD_WORKER_PANES:-1}" == 0 ]]; then
    [[ "$required" != required ]] && return 0
    echo "squad-worker: split disabled; enable panes and use a supported terminal or tmux" >&2; return 1
  fi
  local osascript_command="${SQUAD_DEVKIT_OSASCRIPT:-osascript}"
  local backend="" manager=""
  if [[ -n "${TMUX:-}" && -n "${TMUX_PANE:-}" ]] && command -v tmux >/dev/null 2>&1; then
    backend=tmux; manager="$TMUX_PANE"
  elif [[ -n "${SQUAD_DEVKIT_ORCA_TERMINAL:-}" ]] &&
    command -v "$(squad_panes_orca_cli)" >/dev/null 2>&1 && squad_has_jq; then
    backend=orca; manager="$SQUAD_DEVKIT_ORCA_TERMINAL"
  elif [[ "$(squad_panes_herdr_kind)" == herdr_app ]]; then
    manager="$(squad_panes_herdr_app_manager)"
    if [[ -z "$manager" || "$manager" == *[[:space:]]* ]]; then
      echo "squad-worker: Herdr desktop terminal (${HC_TERMINAL_ID:-unknown}) could not be resolved to a unique local pane; fix the terminal or use tmux" >&2
      [[ "$required" != required ]] && return 0
      return 1
    fi
    backend=herdr_app
  elif [[ "$(squad_panes_herdr_kind)" == herdr ]]; then
    manager="$(squad_panes_herdr_manager)"
    [[ -n "$manager" ]] && backend=herdr
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

  if [[ "$backend" == zellij && "$required" == required ]]; then
    echo "squad-worker: Zellij cannot confirm a split; use tmux" >&2
    return 1
  fi
  if [[ -n "$backend" ]]; then
    if ! squad_panes_lock "$state"; then
      echo "squad-worker: timed out waiting for pane lock; check $state/.pane.lock" >&2
      return 1
    fi
    local last_file="$state/.$backend-${manager//[^A-Za-z0-9_-]/_}.last" previous="" created=""
    [[ -f "$last_file" ]] && previous="$(cat "$last_file")"
    local errfile="$state/.$backend.err" detail=""
    if ! created="$("squad_panes_$backend" "$manager" "$previous" "$command_script" "$title" "$workspace" "$state" 2>"$errfile")"; then created=""; fi
    [[ "$backend" != orca || ! -s "$errfile" ]] || detail="$(head -c 400 "$errfile" | tr -c '[:print:]\n' ' ' | tr '\n' ' ')"
    rm -f "$errfile"
    [[ "$created" != *[[:space:]]* ]] || created=""
    if [[ -n "$created" ]]; then
      printf '%s\n' "$created" >"$last_file"
      # shellcheck disable=SC2034 # read by callers (squad-worker.sh)
      SQUAD_PANES_LAST_BACKEND="$backend" SQUAD_PANES_LAST_CREATED="$created" SQUAD_PANES_LAST_FILE="$last_file"
    fi
    squad_panes_unlock "$state"
    [[ -n "$created" ]] && return 0
    if [[ "$required" == required ]]; then
      echo "squad-worker: $backend split failed or returned an invalid handle${detail:+ ($detail)}; fix the terminal or use tmux" >&2
      return 1
    fi
    # An unconfirmed Orca or Herdr desktop split may already be running; never open a duplicate.
    [[ "$backend" == orca || "$backend" == herdr_app ]] && return 0
  fi
  if [[ "$required" == required ]]; then
    echo "squad-worker: no supported split terminal; use tmux or a supported terminal" >&2
    return 1
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

# Print a bounded failure stage and cause (JSON error fields, else a short sanitized snippet) to stderr.
squad_panes_orca_fail() {
  local stage="$1" status="$2" output="$3" cause
  cause="$(printf '%s' "$output" | squad_jq -r 'select(type == "object") | .error | select(type == "object") | [.code, .message, .data.leafId] | map(select(type == "string")) | join(" ")' 2>/dev/null | head -c 200)" || cause=""
  [[ -n "$cause" ]] || cause="$(printf '%s' "$output" | head -c 120 | tr -c '[:print:]' ' ')"
  printf 'orca %s failed (exit %s): %s\n' "$stage" "$status" "${cause:-no output}" >&2
}

squad_panes_orca_close() {
  local handle="${1:-}" manager="${2:-}" cli
  [[ -n "$handle" && "$handle" != *[[:space:]]* && "$handle" != "$manager" && "$handle" != "${SQUAD_DEVKIT_ORCA_TERMINAL:-}" ]] || return 1
  cli="$(squad_panes_orca_cli)"
  command -v "$cli" >/dev/null 2>&1 || return 1
  "$cli" terminal close --terminal "$handle" --json >/dev/null 2>&1
}

squad_panes_orca_close_self() {
  local handle="${ORCA_TERMINAL_HANDLE:-}" cli
  [[ "${SQUAD_ORCA_CLOSE_ON_EXIT:-0}" == 1 && -n "$handle" && "$handle" != *[[:space:]]* && "$handle" != "${SQUAD_DEVKIT_ORCA_TERMINAL:-}" ]] || return 0
  cli="$(squad_panes_orca_cli)"
  command -v "$cli" >/dev/null 2>&1 || return 0
  if [[ "${SQUAD_ORCA_CLOSE_SYNC:-0}" == 1 ]]; then
    "$cli" terminal close --terminal "$handle" --json >/dev/null 2>&1 || true
  else
    (trap '' HUP; "$cli" terminal close --terminal "$handle" --json >/dev/null 2>&1) </dev/null >/dev/null 2>&1 &
  fi
  return 0
}

squad_panes_orca_record_handle() {
  local state="$1" manager="$2" handle="$3" title="${4:-}" file tmp
  [[ -n "$state" && -n "$manager" && -n "$handle" && "$handle" != *[[:space:]]* ]] || return 0
  file="$state/.orca-${manager//[^A-Za-z0-9_-]/_}.handles"
  tmp="$(mktemp "$file.XXXXXX")" || return 0
  [[ ! -f "$file" ]] || awk -F '\t' -v h="$handle" '$1 != h' "$file" >"$tmp"
  title="${title//$'\t'/ }"; title="${title//$'\n'/ }"; title="${title//$'\r'/ }"
  printf '%s\t%s\n' "$handle" "$title" >>"$tmp"
  tail -n 32 "$tmp" >"$tmp.tail" && mv -f "$tmp.tail" "$file"
  rm -f "$tmp" "$tmp.tail"
}

squad_panes_orca_forget_handle() {
  local state="$1" manager="$2" handle="$3" file tmp
  [[ -n "$state" && -n "$manager" && -n "$handle" ]] || return 0
  file="$state/.orca-${manager//[^A-Za-z0-9_-]/_}.handles"
  [[ -f "$file" ]] || return 0
  tmp="$(mktemp "$file.XXXXXX")" || return 0
  awk -F '\t' -v h="$handle" '$1 != h' "$file" >"$tmp"
  if [[ -s "$tmp" ]]; then mv -f "$tmp" "$file"; else rm -f "$tmp" "$file"; fi
}

squad_close_monitor_pane() {
  local backend="${1:-}" handle="${2:-}" manager="${3:-}" last_file="${4:-}" state="${5:-}" current
  [[ "$backend" == orca && -n "$handle" ]] || return 0
  squad_panes_orca_close "$handle" "$manager" || true
  if [[ -f "$last_file" ]]; then
    current="$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$last_file")"
    [[ "$current" != "$handle" ]] || rm -f "$last_file"
  fi
  [[ -z "$state" || -z "$manager" ]] || squad_panes_orca_forget_handle "$state" "$manager" "$handle"
  return 0
}

squad_panes_orca_reap_stale() {
  local manager="${1:-}" manager_tab="${2:-}" workspace="${3:-}" replace_title="${4:-}" state="${5:-}"
  local cli manager_worktree="" output="" file="" tmp="" handle="" recorded_title="" candidates=""
  SQUAD_PANES_REAPED=0 SQUAD_PANES_ORCA_CLOSED_HANDLES=""
  [[ -n "$manager" ]] || return 0
  cli="$(squad_panes_orca_cli)"
  command -v "$cli" >/dev/null 2>&1 && squad_has_jq || return 0
  if [[ -z "$manager_tab" ]]; then
    output="$("$cli" terminal show --terminal "$manager" --json 2>/dev/null || true)"
    manager_tab="$(printf '%s' "$output" | squad_jq -r 'select(.ok == true) | .result.terminal.tabId // empty' 2>/dev/null || true)"
    manager_worktree="$(printf '%s' "$output" | squad_jq -r 'select(.ok == true) | .result.terminal.worktreePath // empty' 2>/dev/null || true)"
  fi
  [[ -n "$manager_tab" ]] || return 0
  if [[ -n "$state" ]]; then
    file="$state/.orca-${manager//[^A-Za-z0-9_-]/_}.handles"
    if [[ -f "$file" ]]; then
      tmp="$(mktemp "$file.XXXXXX")" || return 0
      while IFS=$'\t' read -r handle recorded_title || [[ -n "$handle" ]]; do
        [[ -n "$handle" ]] || continue
        if [[ "$handle" == "$manager" || "$handle" == "${SQUAD_DEVKIT_ORCA_TERMINAL:-}" ]]; then
          printf '%s\t%s\n' "$handle" "$recorded_title" >>"$tmp"; continue
        fi
        output="$("$cli" terminal show --terminal "$handle" --json 2>/dev/null || true)"
        if ! printf '%s' "$output" | squad_jq -e '.ok == true' >/dev/null 2>&1; then
          if ! printf '%s' "$output" | squad_jq -e '.ok == false and (.error.code != "runtime_unavailable" and .error.code != "timeout")' >/dev/null 2>&1; then
            printf '%s\t%s\n' "$handle" "$recorded_title" >>"$tmp"
          fi
          continue
        fi
        if [[ $'\n'"$SQUAD_PANES_ORCA_CLOSED_HANDLES"$'\n' != *$'\n'"$handle"$'\n'* ]] &&
          printf '%s' "$output" | squad_jq -e --arg tab "$manager_tab" --arg title "$replace_title" --arg recorded "$recorded_title" '
            .result.terminal | .tabId == $tab and
            (.connected == false or .writable == false or .orphaned == true or
             (($title | startswith("squad · ")) and ($recorded == $title or .paneTitle == $title)) or
             ($title == "--reap-all-orchestration" and (($recorded | startswith("squad · ")) or ((.paneTitle // "") | startswith("squad · ")))))' >/dev/null 2>&1 &&
          squad_panes_orca_close "$handle" "$manager"; then
          SQUAD_PANES_REAPED=$((SQUAD_PANES_REAPED + 1))
          SQUAD_PANES_ORCA_CLOSED_HANDLES="${SQUAD_PANES_ORCA_CLOSED_HANDLES}${SQUAD_PANES_ORCA_CLOSED_HANDLES:+$'\n'}$handle"
        elif [[ $'\n'"$SQUAD_PANES_ORCA_CLOSED_HANDLES"$'\n' != *$'\n'"$handle"$'\n'* ]]; then
          printf '%s\t%s\n' "$handle" "$recorded_title" >>"$tmp"
        fi
      done <"$file"
      if [[ -s "$tmp" ]]; then mv -f "$tmp" "$file"; else rm -f "$tmp" "$file"; fi
    fi
  fi
  workspace="${manager_worktree:-$workspace}"
  [[ -n "$workspace" ]] || return 0
  output="$("$cli" terminal list --worktree "path:$workspace" --json 2>/dev/null || true)"
  candidates="$(printf '%s' "$output" | squad_jq -r --arg mgr "$manager" --arg tab "$manager_tab" --arg title "$replace_title" '
    select(.ok == true) | .result.terminals[]? |
    select(.handle != $mgr and .tabId == $tab and (.paneTitle | type == "string")) |
    select(((.connected == false or .writable == false or .orphaned == true) and
      ((.paneTitle | startswith("squad · ")) or .paneTitle == "squad split test" or (.paneTitle | endswith(" monitor")))) or
      (($title | startswith("squad · ")) and .paneTitle == $title) or
      ($title == "--reap-all-orchestration" and (.paneTitle | startswith("squad · ")))) |
    .handle | select(type == "string" and length > 0)' 2>/dev/null || true)"
  while IFS= read -r handle; do
    [[ -n "$handle" && $'\n'"$SQUAD_PANES_ORCA_CLOSED_HANDLES"$'\n' != *$'\n'"$handle"$'\n'* ]] || continue
    if squad_panes_orca_close "$handle" "$manager"; then
      SQUAD_PANES_REAPED=$((SQUAD_PANES_REAPED + 1))
      SQUAD_PANES_ORCA_CLOSED_HANDLES="${SQUAD_PANES_ORCA_CLOSED_HANDLES}${SQUAD_PANES_ORCA_CLOSED_HANDLES:+$'\n'}$handle"
      [[ -z "$state" ]] || squad_panes_orca_forget_handle "$state" "$manager" "$handle"
    fi
  done <<< "$candidates"
  return 0
}

squad_panes_orca() {
  local manager="$1" previous="$2" command_script="$3" title="$4" workspace="$5" state="${6:-}"
  local cli target="$1" direction=vertical output created manager_tab manager_worktree previous_tab command_text
  cli="$(squad_panes_orca_cli)"
  local rc=0
  output="$("$cli" terminal show --terminal "$manager" --json)" || rc=$?
  manager_tab="$(printf '%s' "$output" | squad_jq -er 'select(.ok == true) | .result.terminal.tabId | select(type == "string" and length > 0)' 2>/dev/null)" || manager_tab=""
  if [[ "$rc" != 0 || -z "$manager_tab" ]]; then squad_panes_orca_fail "manager show ($manager)" "$rc" "$output"; return 1; fi
  manager_worktree="$(printf '%s' "$output" | squad_jq -r '.result.terminal.worktreePath // empty' 2>/dev/null || true)"
  squad_panes_orca_reap_stale "$manager" "$manager_tab" "${manager_worktree:-$workspace}" "$title" "$state"
  if [[ -n "$previous" && "$previous" != "$manager" && $'\n'"$SQUAD_PANES_ORCA_CLOSED_HANDLES"$'\n' != *$'\n'"$previous"$'\n'* ]]; then
    output="$("$cli" terminal show --terminal "$previous" --json)" || output=""
    previous_tab="$(printf '%s' "$output" | squad_jq -er 'select(.ok == true and .result.terminal.connected == true and .result.terminal.writable == true and .result.terminal.orphaned != true) | .result.terminal.tabId' 2>/dev/null)" || previous_tab=""
    if [[ "$previous_tab" == "$manager_tab" ]]; then
      target="$previous"; direction=horizontal
    elif printf '%s' "$output" | squad_jq -e --arg tab "$manager_tab" 'select(.ok == true) | .result.terminal | .tabId == $tab and (.connected == false or .writable == false or .orphaned == true)' >/dev/null 2>&1; then
      if squad_panes_orca_close "$previous" "$manager"; then
        [[ -z "$state" ]] || squad_panes_orca_forget_handle "$state" "$manager" "$previous"
      fi
    fi
  fi
  # POSIX quoting also works when the terminal shell is not Bash.
  local quote="'\\''"
  local quoted_workspace="${workspace//\'/$quote}" quoted_script="${command_script//\'/$quote}"
  command_text="cd '$quoted_workspace' && exec '$quoted_script'"
  local split_status=0 stage="split ($target, $direction)" leaf
  output="$("$cli" terminal split --terminal "$target" --direction "$direction" --command "$command_text" --json)" || split_status=$?
  if [[ "$split_status" != 0 ]]; then
    # A timeout may already have created the pane: replay once with its leafId instead of splitting again.
    leaf="$(printf '%s' "$output" | squad_jq -er 'select(type == "object" and .ok == false) | .error | select(type == "object" and (.code == "timeout" or .code == "runtime_error")) | .data.leafId | select(type == "string" and test("^[A-Za-z0-9_.:-]+$"))' 2>/dev/null)" || leaf=""
    if [[ -n "$leaf" ]]; then
      stage="split replay ($target, $direction)"; split_status=0
      output="$("$cli" terminal split --terminal "$target" --direction "$direction" --command "$command_text" --retry-split "$leaf" --json)" || split_status=$?
    fi
  fi
  "$cli" terminal focus --terminal "$manager" --json >/dev/null 2>&1 || true
  if [[ "$split_status" != 0 ]]; then squad_panes_orca_fail "$stage" "$split_status" "$output"; return 1; fi
  created="$(printf '%s' "$output" | squad_jq -er 'select(.ok == true) | .result.split.handle | select(type == "string" and length > 0)' 2>/dev/null)" || created=""
  if [[ -z "$created" || "$created" == *[[:space:]]* ]]; then squad_panes_orca_fail "$stage response" 0 "$output"; return 1; fi
  "$cli" terminal set-pane-title --terminal "$created" --title "$title" --json >/dev/null 2>&1 || true
  [[ -z "$state" ]] || squad_panes_orca_record_handle "$state" "$manager" "$created" "$title"
  printf '%s\n' "$created"
}

squad_panes_herdr_app() {
  local manager="$1" previous="$2" command_script="$3" workspace="$5"
  local target="$1" direction=right inventory manager_tab argv_json output created_pane created_terminal
  inventory="$(herdr-app ls)" || return 1
  manager_tab="$(printf '%s' "$inventory" | squad_jq -er --arg term "${HC_TERMINAL_ID:-}" --arg mgr "$manager" '
    [
      .spaces[]? as $space |
      $space.tabs[]? as $tab |
      $tab.terminals[]? |
      select(if $term != "" then .terminal == $term else .pane == $mgr end) |
      {
        machine: $space.machine,
        tab: $tab.id,
        pane: .pane
      }
    ] |
    select(length == 1) | .[0] |
    select((.machine == null or .machine == "") and
      (.tab | type == "string" and length > 0) and
      .pane == $mgr) |
    .tab')" || return 1
  [[ "$manager_tab" != *[[:space:]]* ]] || return 1
  if [[ -n "$previous" && "$previous" != "$manager" ]]; then
    if printf '%s' "$inventory" | squad_jq -e --arg tab "$manager_tab" --arg prev "$previous" '
      [
        .spaces[]? |
        select(.machine == null or .machine == "") |
        .tabs[]? |
        select(.id == $tab) |
        .terminals[]? |
        select(.pane == $prev and (.terminal | type == "string" and length > 0))
      ] | length == 1' >/dev/null 2>&1; then
      target="$previous"; direction=down
    fi
  fi
  argv_json="$(squad_jq -cn --arg cwd "$workspace" --arg script "$command_script" \
    '["/bin/sh","-c","cd \"$1\" && exec \"$2\"","sh",$cwd,$script]')" || return 1
  local split_status=0
  output="$(herdr-app "do" pane.split --direction "$direction" --pane "$target" --argv "$argv_json")" || split_status=$?
  herdr-app "do" pane.focus --pane "$manager" >/dev/null 2>&1 || true
  # No fresh retry, even on malformed output or a transport timeout.
  [[ "$split_status" == 0 ]] || return 1
  created_pane="$(printf '%s' "$output" | squad_jq -er 'select(type == "object" and (.error == null)) | .pane | select(type == "string" and length > 0)')" || return 1
  created_terminal="$(printf '%s' "$output" | squad_jq -er 'select(type == "object" and (.error == null)) | .terminal | select(type == "string" and length > 0)')" || return 1
  [[ "$created_pane" != *[[:space:]]* && "$created_terminal" != *[[:space:]]* ]] || return 1
  [[ "$created_pane" != "$manager" && "$created_pane" != "$previous" ]] || return 1
  inventory="$(herdr-app ls)" || return 1
  printf '%s' "$inventory" | squad_jq -e --arg tab "$manager_tab" --arg mgr "$manager" \
    --arg pane "$created_pane" --arg term "$created_terminal" '
    [
      .spaces[]? |
      select(.machine == null or .machine == "") |
      .tabs[]? |
      select(.id == $tab)
    ] |
    select(length == 1) | .[0].terminals |
    ([.[]? | select(.pane == $mgr)] | length == 1) and
    ([.[]? | select(.pane == $pane and .terminal == $term)] | length == 1)' >/dev/null || return 1
  printf '%s\n' "$created_pane"
}

SQUAD_PANES_REAPED=0

squad_panes_herdr_reap_stale() {
  local manager_pane="${1:-}"
  SQUAD_PANES_REAPED=0
  [[ -n "$manager_pane" ]] || return 0
  command -v herdr >/dev/null 2>&1 && squad_has_jq || return 0

  local list_json="" candidate_panes=""
  list_json="$(herdr pane list 2>/dev/null || true)"
  [[ -n "$list_json" ]] || return 0

  candidate_panes="$(printf '%s\n' "$list_json" | squad_jq -r --arg mgr "$manager_pane" '
    (.result.panes // []) as $panes |
    ([$panes[]? | select(.pane_id == $mgr) | .tab_id | select(type == "string" and length > 0)][0]) as $tab |
    select($tab != null) |
    $panes[]? |
    select(.tab_id == $tab and
           .pane_id != $mgr and
           ((.label? | type == "string") and (.label | startswith("squad")))) |
    .pane_id
  ' 2>/dev/null || true)"

  [[ -n "$candidate_panes" ]] || return 0

  local pane_id="" pinfo=""
  while IFS= read -r pane_id; do
    [[ -n "$pane_id" ]] || continue
    pinfo="$(herdr pane process-info --pane "$pane_id" 2>/dev/null || true)"
    [[ -n "$pinfo" ]] || continue
    if printf '%s\n' "$pinfo" | squad_jq -e '
      .result.process_info as $pi |
      ($pi.foreground_processes | type == "array" and length == 1) and
      ($pi.foreground_processes[0] as $fg |
       $fg.pid != null and
       $fg.pid == $pi.shell_pid and
       (($fg.name // "" | sub("^-"; "")) as $name |
        ($name == "zsh" or $name == "bash" or $name == "sh" or $name == "fish")))
    ' >/dev/null 2>&1; then
      if herdr pane close "$pane_id" >/dev/null 2>&1; then
        SQUAD_PANES_REAPED=$((SQUAD_PANES_REAPED + 1))
      fi
    fi
  done <<< "$candidate_panes"

  return 0
}

squad_panes_herdr() {
  local manager="$1" previous="$2" command_script="$3" title="$4" workspace="$5" output="" created
  squad_panes_herdr_reap_stale "$manager"
  if [[ -n "$previous" ]]; then
    output="$(herdr pane split "$previous" --direction down --cwd "$workspace" --no-focus 2>/dev/null || true)"
  fi
  if [[ "$output" != *'"pane_id"'* ]]; then
    output="$(herdr pane split "$manager" --direction right --cwd "$workspace" --no-focus)" || return 1
  fi
  created="$(printf '%s' "$output" | squad_jq -er '.result.pane.pane_id | select(type == "string" and length > 0)')" || return 1
  [[ -n "$created" ]] || return 1
  herdr pane rename "$created" "$title" >/dev/null 2>&1 || true
  herdr pane run "$created" "exec $(printf '%q' "$command_script")" >/dev/null 2>&1 || return 1
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
