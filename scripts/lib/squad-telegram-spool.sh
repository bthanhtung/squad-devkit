#!/usr/bin/env bash
# Telegram remote, laptop side: the outbox spool and the manager registry.
# Sourced; defines functions only. The daemon reads what these write.
# Nothing here touches the network, and nothing here prints the bot token.

_tg_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=squad-jq.sh
source "$_tg_lib_dir/squad-jq.sh"

tg_config_file() {
  printf '%s\n' "${SQUAD_DEVKIT_TELEGRAM_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/squad-devkit/telegram.env}"
}

tg_state_dir() {
  printf '%s\n' "${SQUAD_DEVKIT_TELEGRAM_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/squad-devkit/telegram}"
}

# True when the config holds a non-empty token and chat id. The file is
# parsed with grep, never sourced, so nothing in it is executed.
tg_configured() {
  local file
  file="$(tg_config_file)"
  [[ -f "$file" ]] || return 1
  grep -Eq "^(export[[:space:]]+)?TELEGRAM_BOT_TOKEN=[\"']?[^\"'[:space:]]" "$file" 2>/dev/null || return 1
  grep -Eq "^(export[[:space:]]+)?TELEGRAM_CHAT_ID=[\"']?[^\"'[:space:]]" "$file" 2>/dev/null || return 1
  return 0
}

_tg_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# tg_workspace_excluded PATH: true when PATH is, or is inside, a path prefix
# listed in telegram-exclude next to the state directory (one per line) or in a
# TELEGRAM_EXCLUDE= line of the config. Both accept colon-separated absolute
# paths; symlinks are compared by their resolved path too.
tg_workspace_excluded() {
  local path="${1:-}" file prefixes="" line prefix real_path real_prefix
  [[ -n "$path" ]] || return 1
  file="$(dirname "$(tg_state_dir)")/telegram-exclude"
  if [[ -f "$file" ]]; then
    prefixes="$(grep -Ev '^[[:space:]]*(#|$)' "$file" 2>/dev/null || true)"
  fi
  file="$(tg_config_file)"
  if [[ -f "$file" ]]; then
    line="$(sed -nE 's/^(export[[:space:]]+)?TELEGRAM_EXCLUDE=//p' "$file" 2>/dev/null | tail -n 1 | tr -d "\"'")"
    prefixes="$prefixes"$'\n'"$line"
  fi
  [[ -n "${prefixes//[[:space:]]/}" ]] || return 1
  real_path="$(cd "$path" 2>/dev/null && pwd -P)" || real_path="$path"
  # macOS volumes are case-insensitive: compare in lowercase there.
  local fold=0
  [[ "$(uname -s 2>/dev/null)" != Darwin ]] || fold=1
  ((fold == 0)) || { path="$(_tg_lower "$path")"; real_path="$(_tg_lower "$real_path")"; }
  while IFS= read -r prefix; do
    [[ "$prefix" == /* ]] || continue
    prefix="${prefix%/}"
    real_prefix="$(cd "${prefix:-/}" 2>/dev/null && pwd -P)" || real_prefix="$prefix"
    real_prefix="${real_prefix%/}"
    if ((fold == 1)); then prefix="$(_tg_lower "$prefix")"; real_prefix="$(_tg_lower "$real_prefix")"; fi
    if [[ "$path" == "$prefix" || "$path" == "$prefix"/* || "$real_path" == "$prefix" || "$real_path" == "$prefix"/* ||
      "$path" == "$real_prefix" || "$path" == "$real_prefix"/* || "$real_path" == "$real_prefix" || "$real_path" == "$real_prefix"/* ]]; then
      return 0
    fi
  done < <(printf '%s\n' "$prefixes" | tr ':' '\n')
  return 1
}

# Enabled when configured, not switched off with SQUAD_DEVKIT_TELEGRAM=0, and
# the current workspace is not excluded.
tg_enabled() {
  [[ "${SQUAD_DEVKIT_TELEGRAM:-}" != 0 ]] || return 1
  tg_configured || return 1
  ! tg_workspace_excluded "${SQUAD_DEVKIT_WORKSPACE:-$PWD}"
}

# Prints TEXT without escape sequences or control characters (newline is
# kept), cut to MAX characters with a trailing ellipsis.
tg_sanitize() {
  local max="${2:-3500}" esc bel
  [[ "$max" =~ ^[0-9]+$ ]] || max=3500
  esc=$'\033'
  bel=$'\007'
  printf '%s' "${1:-}" |
    LC_ALL=C sed -E \
      -e "s#${esc}\][^${bel}${esc}]*(${bel}|${esc}\\\\)##g" \
      -e "s#${esc}\[[0-9;?<=>]*[ -/]*[@-~]##g" \
      -e "s#${esc}[@-_]##g" |
    LC_ALL=C tr -d '\000-\011\013-\037\177' |
    squad_jq -Rrs --argjson max "$max" '
      gsub("[\u0080-\u009f  ‪-‮⁦-⁩]"; "")
      | if length > $max then .[0:$max] + "…" else . end'
}

_tg_spool_seq=0

# tg_spool_put LABEL KIND TEXT: queue one message for the daemon. Files are
# named <epoch>-<pid>-<counter>-<random>.json, so they sort in send order.
tg_spool_put() {
  tg_enabled || return 0
  local label="${1:-}" kind="${2:-}" text="${3:-}" dir name tmp target files
  case "$kind" in reply | waiting | worker) ;; *) return 1 ;; esac
  label="$(tg_sanitize "$label" 200)"
  label="${label//$'\n'/ }"
  text="$(tg_sanitize "$text")"
  [[ -n "$text" ]] || return 0
  dir="$(tg_state_dir)/outbox"
  _tg_spool_seq=$((_tg_spool_seq + 1))
  name="$(date +%s)-$$-$(printf '%06d' "$_tg_spool_seq")"
  (
    umask 077
    mkdir -p "$dir" || exit 1
    chmod 700 "$dir" 2>/dev/null || true
    tmp="$dir/.$name.tmp"
    if ! squad_jq -n --arg label "$label" --arg kind "$kind" --arg text "$text" --argjson ts "$(date +%s)" \
      '{label: $label, kind: $kind, text: $text, ts: $ts}' >"$tmp" 2>/dev/null; then
      rm -f "$tmp"
      exit 1
    fi
    # mv -n never overwrites; if the name is taken, retry once with a new one.
    target="$dir/$name-$RANDOM.json"
    mv -n "$tmp" "$target"
    if [[ -e "$tmp" ]]; then
      target="$dir/$name-$RANDOM$RANDOM.json"
      mv -n "$tmp" "$target"
    fi
    if [[ -e "$tmp" ]]; then
      rm -f "$tmp"
      exit 1
    fi
    # Cap the spool: drop the oldest files beyond 500.
    files=("$dir"/*.json)
    if ((${#files[@]} > 500)); then
      rm -f -- "${files[@]:0:${#files[@]}-500}"
    fi
  )
}

tg_registry_dir() {
  printf '%s/managers\n' "$(tg_state_dir)"
}

# tg_registry_write LABEL MANAGER_ID WORKSPACE PID CLIENT
tg_registry_write() {
  tg_enabled || return 0
  local label="${1:-}" manager_id="${2:-}" workspace="${3:-}" pid="${4:-}" client="${5:-}"
  local kind=none pane_id="" socket="" dir tmp
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  label="$(tg_sanitize "$label" 200)"
  label="${label//$'\n'/ }"
  if [[ -n "${HERDR_PANE_ID:-}" ]]; then
    kind=herdr
    pane_id="$HERDR_PANE_ID"
    [[ "$pane_id" =~ ^[A-Za-z0-9._:-]+$ ]] || { kind=none; pane_id=""; }
  elif [[ -n "${TMUX_PANE:-}" ]]; then
    kind=tmux
    pane_id="$TMUX_PANE"
    socket="${TMUX:-}"
    socket="${socket%%,*}"
    [[ "$pane_id" =~ ^%[0-9]+$ ]] || { kind=none; pane_id=""; socket=""; }
  fi
  dir="$(tg_registry_dir)"
  (
    umask 077
    mkdir -p "$dir" || exit 1
    chmod 700 "$dir" 2>/dev/null || true
    tmp="$dir/.$pid.json.tmp"
    if squad_jq -n --arg label "$label" --arg manager_id "$manager_id" --arg workspace "$workspace" \
      --argjson pid "$pid" --arg client "$client" --arg kind "$kind" --arg id "$pane_id" \
      --arg socket "$socket" --argjson started "$(date +%s)" \
      '{label: $label, manager_id: $manager_id, workspace: $workspace, pid: $pid, client: $client,
        pane: {kind: $kind, id: $id, socket: $socket}, started: $started}' >"$tmp" 2>/dev/null; then
      mv "$tmp" "$dir/$pid.json"
    else
      rm -f "$tmp"
      exit 1
    fi
  )
}

tg_registry_remove() {
  [[ "${1:-}" =~ ^[0-9]+$ ]] || return 1
  rm -f "$(tg_registry_dir)/$1.json"
}

# One compact JSON object per live manager; entries whose pid is dead, or was
# reused by another program (its command is not squad-devkit-manager), are deleted.
tg_registry_list() {
  local dir file pid
  dir="$(tg_registry_dir)"
  [[ -d "$dir" ]] || return 0
  for file in "$dir"/*.json; do
    [[ -f "$file" ]] || continue
    pid="$(basename "$file" .json)"
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null &&
      [[ "$(ps -p "$pid" -o command= 2>/dev/null)" == *squad-devkit-manager* ]]; then
      squad_jq -c . "$file" 2>/dev/null || rm -f "$file"
    else
      rm -f "$file"
    fi
  done
  return 0
}
