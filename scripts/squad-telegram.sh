#!/usr/bin/env bash
# Telegram remote daemon: one bot controls every running squad-devkit manager.
# Usage: squad-telegram.sh setup | start | stop | status | run
#
# Security model: only the paired private chat is served; everything else is
# dropped without a reply. Phone text is stripped of control characters and
# escape sequences, then typed into the manager's pane with herdr or tmux, always
# as separate argv elements (never through eval or sh -c). The bot token only
# travels on curl's stdin, and the log holds event kinds and labels, never
# message bodies, the token or the chat id.
set -euo pipefail

source_file="${BASH_SOURCE[0]}"
while [[ -L "$source_file" ]]; do
  source_directory="$(cd "$(dirname "$source_file")" && pwd)"
  link_target="$(readlink "$source_file")"
  if [[ "$link_target" == /* ]]; then source_file="$link_target"; else source_file="$source_directory/$link_target"; fi
done
script_dir="$(cd "$(dirname "$source_file")" && pwd)"
self="$script_dir/$(basename "$source_file")"
# shellcheck source=lib/squad-telegram-spool.sh
source "$script_dir/lib/squad-telegram-spool.sh"

state_dir="$(tg_state_dir)"
config_file="$(tg_config_file)"
pid_file="$state_dir/daemon.pid"
log_file="$state_dir/daemon.log"
token=""
chat_id=""
TG_RESP=""
TG_CODE=0   # HTTP status of the last call; 0 when curl itself failed
TG_SENT=0   # chunks the last send_msg delivered
lock_held=0

usage() {
  cat <<'EOF'
Usage: squad-telegram setup | start | stop | status | run

  setup   Ask for the bot token, pair this laptop with your Telegram chat
  start   Run the daemon in the background
  stop    Stop the background daemon
  status  Show whether it runs, whether it is paired, and the live managers
  run     Run the daemon in the foreground
EOF
}

ensure_state_dir() {
  (umask 077 && mkdir -p "$state_dir") || exit 1
  chmod 700 "$state_dir" 2>/dev/null || true
}

log() {
  [[ -d "$state_dir" ]] || return 0
  (umask 077 && printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$log_file") 2>/dev/null || true
}

cfg_get() {
  { sed -nE "s/^(export[[:space:]]+)?$1=//p" "$config_file" 2>/dev/null || true; } | tail -n 1 | tr -d "\"'"
}

# ---------------------------------------------------------------- Bot API

# tg_api METHOD [JSON_BODY]: sets TG_RESP to the response body; returns 0 only
# on HTTP 200 with "ok": true. The URL (token) and the body go to curl on stdin
# as a config, so neither shows in ps. Errors are not logged: curl's own message
# is dropped.
tg_api() {
  local method="$1" body="${2:-}" cfg out code
  cfg="$(printf 'url = "https://api.telegram.org/bot%s/%s"\n' "$token" "$method")"
  if [[ -n "$body" ]]; then
    body="$(printf '%s' "$body" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
    cfg="$cfg"$'\nheader = "Content-Type: application/json"\ndata-binary = "'"$body"'"'
  fi
  TG_RESP=""
  TG_CODE=0
  out="$(printf '%s\n' "$cfg" | curl -sS --max-time 35 -K - -w $'\n%{http_code}' 2>/dev/null)" || return 1
  code="${out##*$'\n'}"
  TG_RESP="${out%$'\n'*}"
  [[ "$code" =~ ^[0-9]{3}$ ]] && TG_CODE="$code"
  [[ "$code" == 200 ]] || return 1
  [[ "$(printf '%s' "$TG_RESP" | squad_jq -r '.ok // false' 2>/dev/null)" == true ]]
}

# send_msg HEADER_LABEL PREFIX TEXT [MAP_LABEL]: HTML message(s) to the paired
# chat, split below Telegram's 4096-character limit. Each sent message id is
# remembered with MAP_LABEL so a reply to it can be routed.
send_msg() {
  local header="$1" prefix="$2" text="$3" map_label="${4:-}" body message_id ok=0
  TG_SENT=0
  while IFS= read -r body; do
    [[ -n "$body" ]] || continue
    if tg_api sendMessage "$body"; then
      ok=1
      TG_SENT=$((TG_SENT + 1))
      if [[ -n "$map_label" ]]; then
        message_id="$(printf '%s' "$TG_RESP" | squad_jq -r '.result.message_id // empty')"
        [[ "$message_id" =~ ^[0-9]+$ ]] && remember_message "$message_id" "$map_label"
      fi
    else
      return 1
    fi
  done < <(squad_jq -nrc --arg chat "$chat_id" --arg label "$header" --arg prefix "$prefix" --arg text "$text" '
    def esc: gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;");
    def chunks($n):
      if length <= $n then [.]
      else (.[0:$n] | sub("&[a-z]*$"; "")) as $c | [$c] + (.[($c | length):] | chunks($n)) end;
    (if $label == "" then "" else "<b>" + ($label | esc) + "</b>\n" end)
      + (if $prefix == "" then "" else ($prefix | esc) + " " end)
      + ($text | esc)
    | chunks(4000)[]
    | {chat_id: $chat, text: ., parse_mode: "HTML", disable_web_page_preview: true}')
  ((ok == 1))
}

reply() { send_msg "" "" "$1" "${2:-}" || log "send-failed reply"; }

remember_message() {
  local file="$state_dir/msgmap"
  printf '%s\t%s\n' "$1" "$2" >>"$file"
  if (($(wc -l <"$file") > 200)); then
    tail -n 200 "$file" >"$file.tmp" && mv "$file.tmp" "$file"
  fi
}

# ---------------------------------------------------------------- managers

managers=()   # compact registry JSON, live and not excluded
load_managers() {
  local line workspace
  managers=()
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    workspace="$(printf '%s' "$line" | squad_jq -r '.workspace // ""')"
    tg_workspace_excluded "$workspace" && continue
    managers+=("$line")
  done < <(tg_registry_list)
}

jf() { printf '%s' "$1" | squad_jq -r "$2" 2>/dev/null; }

# Runs a command with output captured, giving up after $1 seconds.
run_limited() {
  local limit="$1" out i pid
  shift
  out="$(mktemp "$state_dir/.run.XXXXXX")" || return 1
  "$@" >"$out" 2>/dev/null </dev/null &
  pid=$!
  for ((i = 0; i < limit * 10; i++)); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  cat "$out"
  rm -f "$out"
}

cmd_list() {
  local n=0 entry label kind workspace pid workers text="" listing=""
  load_managers
  if ((${#managers[@]} == 0)); then
    reply "No managers running. Start squad-devkit inside herdr or tmux."
    return
  fi
  for entry in "${managers[@]}"; do
    n=$((n + 1))
    label="$(jf "$entry" .label)"
    kind="$(jf "$entry" .pane.kind)"
    workspace="$(jf "$entry" .workspace)"
    pid="$(jf "$entry" .pid)"
    listing="$listing$pid"$'\t'"$label"$'\n'
    [[ "$kind" != none ]] || kind="not reachable"
    workers="$(run_limited 5 bash -c 'cd "$1" && "$2" --list' _ "$workspace" "$script_dir/squad-worker.sh" |
      head -n 5 | tr -d '\000-\010\013-\037\177' | cut -c 1-200 || true)"
    text="$text$n. $label [$kind]"$'\n'
    if [[ -n "$workers" ]]; then
      text="$text$(printf '%s\n' "$workers" | sed 's/^/    /')"$'\n'
    fi
  done
  printf '%s' "$listing" >"$state_dir/lastlist"
  reply "$text"
  log "list managers=$n"
}

# resolve_target TARGET [exact]: sets `found` to the live manager's JSON; replies
# and returns 1 when TARGET is unknown or ambiguous. Numbers refer to the last
# /list. Prefix matching is for /to only: with "exact" (reply routing) the label
# must match in full, so a dead proj/manager-1 never reaches proj/manager-10.
found=""
resolve_target() {
  local target="$1" mode="${2:-}" pid entry matches=0 exact=0 label hit="" exact_hit=""
  found=""
  load_managers
  if [[ "$mode" != exact && "$target" =~ ^[0-9]+$ ]]; then
    pid="$(sed -n "${target}p" "$state_dir/lastlist" 2>/dev/null | cut -f1)"
    if [[ -z "$pid" ]]; then
      reply "Unknown number. Send /list first."
      return 1
    fi
    for entry in ${managers[@]+"${managers[@]}"}; do
      [[ "$(jf "$entry" .pid)" == "$pid" ]] && { found="$entry"; return 0; }
    done
    reply "That manager is gone. Send /list."
    return 1
  fi
  for entry in ${managers[@]+"${managers[@]}"}; do
    label="$(jf "$entry" .label)"
    if [[ "$label" == "$target" ]]; then
      exact=$((exact + 1))
      exact_hit="$entry"
    elif [[ "$mode" != exact && "$label" == "$target"* ]]; then
      matches=$((matches + 1))
      hit="$entry"
    fi
  done
  if ((exact == 1)); then
    found="$exact_hit"
  elif [[ "$mode" == exact && $exact -eq 0 ]]; then
    reply "$target is no longer running."
    return 1
  elif ((exact > 1 || (exact == 0 && matches > 1))); then
    reply "More than one manager matches. Use the number from /list."
    return 1
  elif ((matches == 1)); then
    found="$hit"
  else
    reply "No manager matches. Send /list."
    return 1
  fi
}

# deliver MANAGER_JSON TEXT: types TEXT into the manager's pane.
deliver() {
  local entry="$1" text="$2" label kind id socket pid
  label="$(jf "$entry" .label)"
  kind="$(jf "$entry" .pane.kind)"
  id="$(jf "$entry" .pane.id)"
  socket="$(jf "$entry" .pane.socket)"
  pid="$(jf "$entry" .pid)"
  if [[ "$kind" == none ]]; then
    reply "$label is not reachable: start squad-devkit inside herdr or tmux"
    return 1
  fi
  [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null || { reply "$label is no longer running."; return 1; }
  # A bare answer to a prompt ("1", "y", "no") goes in as typed, so a permission
  # prompt accepts it; everything else is marked as coming from Telegram.
  local payload="[telegram] $text"
  [[ "$text" =~ ^([1-9]|y|n|yes|no|Y|N)$ ]] && payload="$text"
  case "$kind" in
    herdr)
      if [[ ! "$id" =~ ^[A-Za-z0-9._:-]+$ || "$id" == -* ]]; then reply "$label has an invalid pane."; return 1; fi
      herdr pane send-text "$id" "$payload" >/dev/null 2>&1 &&
        herdr pane send-keys "$id" Enter >/dev/null 2>&1 || { reply "Could not send to $label."; return 1; }
      ;;
    tmux)
      if [[ ! "$id" =~ ^%[0-9]+$ ]]; then reply "$label has an invalid pane."; return 1; fi
      local tmux_args=()
      [[ -z "$socket" ]] || tmux_args=(-S "$socket")
      tmux ${tmux_args[@]+"${tmux_args[@]}"} send-keys -t "$id" -l "$payload" >/dev/null 2>&1 &&
        tmux ${tmux_args[@]+"${tmux_args[@]}"} send-keys -t "$id" Enter >/dev/null 2>&1 || { reply "Could not send to $label."; return 1; }
      ;;
    *) reply "$label has an unknown pane kind."; return 1 ;;
  esac
  log "inject kind=$kind label=$label"
  reply "→ $label" "$label"
}

# ---------------------------------------------------------------- inbound

cmd_help() {
  reply "/list: show the managers and their workers
/to <n|label> <text>: send text to a manager and make it current
text: goes to the current manager
reply to a bot message: goes to that message's manager
/help: this list"
}

# handle_text TEXT REPLY_TO_ID REPLY_TO_IS_BOT
handle_text() {
  local raw="$1" reply_to="$2" reply_bot="$3" text cmd rest target label entry current candidate
  if (($(printf '%s' "$raw" | squad_jq -Rrs 'length') > 2000)); then
    reply "Message too long (max 2000 characters)."
    return
  fi
  text="$(tg_sanitize "$raw" 2000)"
  text="${text//$'\n'/ }"
  text="${text#"${text%%[![:space:]]*}"}"
  text="${text%"${text##*[![:space:]]}"}"
  [[ -n "$text" ]] || return 0
  if [[ "$text" == /* ]]; then
    cmd="${text%% *}"
    rest=""
    [[ "$text" == *" "* ]] && rest="${text#* }"
    cmd="${cmd%%@*}"
    case "$cmd" in
      /list) cmd_list ;;
      /help | /start) cmd_help ;;
      /to)
        target="${rest%% *}"
        text=""
        [[ "$rest" == *" "* ]] && text="${rest#* }"
        text="${text#"${text%%[![:space:]]*}"}"
        if [[ -z "$target" || -z "$text" ]]; then
          reply "Usage: /to <n|label> <text>"
        elif resolve_target "$target"; then
          printf '%s\n' "$(jf "$found" .pid)" >"$state_dir/current"
          deliver "$found" "$text" || true
        fi
        ;;
      *) reply "Unknown command. Send /help." ;;
    esac
    return
  fi
  if [[ -n "$reply_to" ]]; then
    label="$(awk -F '\t' -v id="$reply_to" '$1 == id { l = $2 } END { print l }' "$state_dir/msgmap" 2>/dev/null || true)"
    if [[ -n "$label" ]]; then
      resolve_target "$label" exact && { deliver "$found" "$text" || true; }
      return
    elif [[ "$reply_bot" == true ]]; then
      reply "I don't know which manager that message came from. Use /to."
      return
    fi
  fi
  current="$(cat "$state_dir/current" 2>/dev/null || true)"
  load_managers
  entry=""
  for candidate in ${managers[@]+"${managers[@]}"}; do
    [[ "$current" =~ ^[0-9]+$ && "$(jf "$candidate" .pid)" == "$current" ]] && entry="$candidate"
  done
  if [[ -z "$entry" ]]; then
    reply "No manager selected. Send /list, then /to <n> <text>."
    return
  fi
  deliver "$entry" "$text" || true
}

# process_updates RESPONSE_JSON: only the paired private chat is served.
process_updates() {
  local response="$1" max update fields text reply_to reply_bot
  max="$(printf '%s' "$response" | squad_jq -r '[.result[]?.update_id] | max // empty')"
  [[ "$max" =~ ^[0-9]+$ ]] || return 0
  # Advance first: an update is handled at most once, even after a crash.
  if ! { printf '%s\n' "$((max + 1))" >"$state_dir/offset.tmp" && mv "$state_dir/offset.tmp" "$state_dir/offset"; } 2>/dev/null; then
    log "offset-write-failed"
    return 1
  fi
  while IFS= read -r update; do
    [[ -n "$update" ]] || continue
    fields="$(printf '%s' "$update" | squad_jq -r --arg chat "$chat_id" '
      select((.message.chat.id | tostring) == $chat and .message.chat.type == "private"
        and (.message.from.id | tostring) == $chat and (.message.text | type) == "string")
      | .message | [(.reply_to_message.message_id // ""), (.reply_to_message.from.is_bot // false)] | @tsv')"
    if [[ -z "$fields" ]]; then
      log "dropped-update"
      continue
    fi
    reply_to="${fields%%$'\t'*}"
    reply_bot="${fields#*$'\t'}"
    text="$(printf '%s' "$update" | squad_jq -r '.message.text')"
    [[ "$reply_to" =~ ^[0-9]*$ ]] || reply_to=""
    handle_text "$text" "$reply_to" "$reply_bot"
  done < <(printf '%s' "$response" | squad_jq -c '.result[]?')
}

# ---------------------------------------------------------------- outbound

flush_outbox() {
  local dir="$state_dir/outbox" file label kind text prefix tries n sent=0
  [[ -d "$dir" ]] || return 0
  for file in "$dir"/*.json; do
    [[ -f "$file" ]] || continue
    ((sent < 20)) || break
    if ! label="$(squad_jq -er '.label | strings' "$file" 2>/dev/null)" ||
      ! kind="$(squad_jq -er '.kind | strings' "$file" 2>/dev/null)" ||
      ! text="$(squad_jq -er '.text | strings' "$file" 2>/dev/null)"; then
      log "outbox-bad-file"
      rm -f "$file"
      continue
    fi
    case "$kind" in
      reply) prefix="" ;;
      waiting) prefix="⏳ waiting:" ;;
      worker) prefix="🔧" ;;
      *) rm -f "$file"; continue ;;
    esac
    if send_msg "$label" "$prefix" "$text" "$label"; then
      rm -f "$file" "$dir/.tries-${file##*/}.n"
      sent=$((sent + 1))
      log "sent kind=$kind label=$label"
    else
      log "send-failed kind=$kind label=$label http=$TG_CODE"
      tries="$dir/.tries-${file##*/}.n"
      if [[ "$TG_CODE" =~ ^4[0-9][0-9]$ && "$TG_CODE" != 429 ]]; then
        # Telegram will never accept this message: drop it, do not block the queue.
        log "dropped-rejected kind=$kind label=$label"
        rm -f "$file" "$tries"
        continue
      fi
      if ((TG_SENT > 0)); then
        # Some chunks went out; a retry repeats them, so give up after 3 tries.
        n="$(cat "$tries" 2>/dev/null || true)"
        [[ "$n" =~ ^[0-9]+$ ]] || n=0
        n=$((n + 1))
        if ((n >= 3)); then
          log "dropped-partial kind=$kind label=$label"
          rm -f "$file" "$tries"
          continue
        fi
        printf '%s\n' "$n" >"$tries"
      fi
      return 1
    fi
  done
  return 0
}

# ---------------------------------------------------------------- run

load_credentials() {
  token="$(cfg_get TELEGRAM_BOT_TOKEN)"
  chat_id="$(cfg_get TELEGRAM_CHAT_ID)"
  [[ "$token" =~ ^[0-9]+:[A-Za-z0-9_-]+$ && "$chat_id" =~ ^-?[0-9]+$ ]]
}

poll_once() {
  local offset=0 body wait_s=25
  # Queued messages are waiting: poll briefly so they go out within seconds.
  if compgen -G "$state_dir/outbox/*.json" >/dev/null; then wait_s=1; fi
  [[ ! -f "$state_dir/offset" ]] || offset="$(cat "$state_dir/offset" 2>/dev/null || echo 0)"
  [[ "$offset" =~ ^[0-9]+$ ]] || offset=0
  body="$(squad_jq -nc --argjson offset "$offset" --argjson timeout "$wait_s" '{offset: $offset, timeout: $timeout, allowed_updates: ["message"]}')"
  tg_api getUpdates "$body" || return 1
  process_updates "$TG_RESP"
}

daemon_alive() {
  local pid
  pid="$(cat "$pid_file" 2>/dev/null || true)"
  [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null &&
    [[ "$(ps -p "$pid" -o command= 2>/dev/null)" == *"squad-telegram.sh run"* ]]
}

cleanup_pid() {
  [[ "$(cat "$pid_file" 2>/dev/null)" != "$$" ]] || rm -f "$pid_file"
  ((lock_held == 0)) || rmdir "$state_dir/daemon.lock" 2>/dev/null || true
}

# take_lock: mkdir is atomic, so two daemons can never both pass. A lock whose
# owner is gone is stale; wait briefly first, as the owner may be mid-start.
take_lock() {
  local i
  for ((i = 0; i < 12; i++)); do
    if mkdir "$state_dir/daemon.lock" 2>/dev/null; then
      lock_held=1
      return 0
    fi
    daemon_alive && return 1
    sleep 0.1
  done
  rmdir "$state_dir/daemon.lock" 2>/dev/null || true
  if mkdir "$state_dir/daemon.lock" 2>/dev/null; then
    lock_held=1
    return 0
  fi
  return 1
}

cmd_run() {
  ensure_state_dir
  if ! load_credentials; then
    echo "Not paired. Run: squad-devkit telegram setup" >&2
    exit 1
  fi
  if [[ "${SQUAD_TELEGRAM_ONCE:-}" != 1 ]]; then
    trap cleanup_pid EXIT
    if ! take_lock; then
      echo "Already running (pid $(cat "$pid_file" 2>/dev/null || echo '?'))"
      exit 0
    fi
    (umask 077 && printf '%s\n' "$$" >"$pid_file")
  fi
  (umask 077 && touch "$log_file")
  log "daemon-start"
  local backoff=0
  while true; do
    if poll_once; then
      backoff=0
    else
      log "poll-failed"
      if [[ "${SQUAD_TELEGRAM_ONCE:-}" != 1 ]]; then
        if ((backoff == 0)); then backoff=5; else backoff=30; fi
        sleep "$backoff"
      fi
    fi
    flush_outbox || true
    [[ "${SQUAD_TELEGRAM_ONCE:-}" != 1 ]] || break
  done
}

cmd_start() {
  ensure_state_dir
  if daemon_alive; then
    echo "Already running (pid $(cat "$pid_file"))"
    return 0
  fi
  (umask 077 && touch "$log_file")
  (trap '' HUP; exec bash "$self" run >>"$log_file" 2>&1 </dev/null) &
  disown 2>/dev/null || true
  local i
  for ((i = 0; i < 30; i++)); do
    if daemon_alive; then
      echo "Started (pid $(cat "$pid_file"))"
      return 0
    fi
    sleep 0.1
  done
  echo "Could not start; see $log_file" >&2
  return 1
}

cmd_stop() {
  local pid i
  if ! daemon_alive; then
    rm -f "$pid_file"
    rmdir "$state_dir/daemon.lock" 2>/dev/null || true
    echo "Not running"
    return 0
  fi
  pid="$(cat "$pid_file")"
  kill "$pid" 2>/dev/null || true
  for ((i = 0; i < 50; i++)); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
  rm -f "$pid_file"
  rmdir "$state_dir/daemon.lock" 2>/dev/null || true
  echo "Stopped"
}

cmd_status() {
  local entry
  if daemon_alive; then echo "daemon: running (pid $(cat "$pid_file"))"; else echo "daemon: stopped"; fi
  if tg_configured; then echo "paired: yes"; else echo "paired: no"; fi
  echo "managers:"
  load_managers
  for entry in ${managers[@]+"${managers[@]}"}; do
    printf '  %s\n' "$(jf "$entry" .label)"
  done
  return 0
}

# ---------------------------------------------------------------- setup

cmd_setup() {
  local code timeout deadline now wait_s body response update_id fields paired_chat="" wrong=0 name existing_exclude
  ensure_state_dir
  if daemon_alive; then
    echo "The daemon is running: stop the daemon first (squad-devkit telegram stop)." >&2
    return 1
  fi
  if [[ "${SQUAD_TELEGRAM_TOKEN_STDIN:-}" == 1 ]]; then
    IFS= read -r token || true
  else
    printf 'Bot token from BotFather (input is hidden): '
    IFS= read -rs token || true
    printf '\n'
  fi
  if [[ ! "$token" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]; then
    echo "That does not look like a bot token." >&2
    return 1
  fi
  if ! tg_api getMe; then
    echo "Telegram rejected the token (or the network is down)." >&2
    return 1
  fi
  name="$(printf '%s' "$TG_RESP" | squad_jq -r '.result.username // empty')"
  # SQUAD_TELEGRAM_TEST_CODE is test-only: it fixes the pairing code, and is
  # ignored unless SQUAD_TELEGRAM_TESTING=1 is set too.
  code=""
  [[ "${SQUAD_TELEGRAM_TESTING:-}" != 1 ]] || code="${SQUAD_TELEGRAM_TEST_CODE:-}"
  [[ "$code" =~ ^[0-9]{6}$ ]] || code="$(printf '%06d' $(($(od -An -N4 -tu4 /dev/urandom | tr -d ' ') % 1000000)))"
  echo "Bot ${name:+@$name }accepted."
  echo "Pairing code: $code"
  echo "Open a private chat with the bot in Telegram and send exactly this code."
  timeout="${SQUAD_TELEGRAM_PAIR_TIMEOUT:-300}"
  [[ "$timeout" =~ ^[0-9]+$ ]] || timeout=300
  deadline=$(($(date +%s) + timeout))
  offset=0
  # Skip what was queued before setup began: offset -1 returns only the newest
  # update and confirms the older ones, so an old message cannot pair.
  if ! tg_api getUpdates '{"offset":-1,"timeout":0,"allowed_updates":["message"]}'; then
    echo "Could not reach Telegram." >&2
    return 1
  fi
  update_id="$(printf '%s' "$TG_RESP" | squad_jq -r '[.result[]?.update_id] | max // empty')"
  [[ ! "$update_id" =~ ^[0-9]+$ ]] || offset=$((update_id + 1))
  while true; do
    now="$(date +%s)"
    ((now < deadline)) || break
    wait_s=$((deadline - now))
    ((wait_s <= 25)) || wait_s=25
    body="$(squad_jq -nc --argjson offset "$offset" --argjson timeout "$wait_s" '{offset: $offset, timeout: $timeout, allowed_updates: ["message"]}')"
    if ! tg_api getUpdates "$body"; then
      sleep 2
      continue
    fi
    response="$TG_RESP"
    while IFS= read -r update; do
      [[ -n "$update" ]] || continue
      update_id="$(printf '%s' "$update" | squad_jq -r '.update_id')"
      [[ "$update_id" =~ ^[0-9]+$ ]] && offset=$((update_id + 1))
      # Private chats only; the text must be exactly the code.
      fields="$(printf '%s' "$update" | squad_jq -r '
        select(.message.chat.type == "private" and (.message.from.id | tostring) == (.message.chat.id | tostring)
          and (.message.text | type) == "string") | [(.message.chat.id | tostring), .message.text] | @tsv')"
      [[ -n "$fields" ]] || continue
      if [[ "${fields#*$'\t'}" == "$code" && "${fields%%$'\t'*}" =~ ^[0-9]+$ ]]; then
        paired_chat="${fields%%$'\t'*}"
        break
      fi
      wrong=$((wrong + 1))
      if ((wrong > 10)); then
        echo "Too many wrong codes; pairing stopped. Run setup again." >&2
        return 1
      fi
    done < <(printf '%s' "$response" | squad_jq -c '.result[]?')
    [[ -z "$paired_chat" ]] || break
  done
  if [[ -z "$paired_chat" ]]; then
    echo "Timed out: nothing saved." >&2
    return 1
  fi
  existing_exclude="$(cfg_get TELEGRAM_EXCLUDE)"
  mkdir -p "$(dirname "$config_file")"
  chmod 700 "$(dirname "$config_file")" 2>/dev/null || true
  (
    umask 077
    {
      printf 'TELEGRAM_BOT_TOKEN=%s\n' "$token"
      printf 'TELEGRAM_CHAT_ID=%s\n' "$paired_chat"
      [[ -z "$existing_exclude" ]] || printf 'TELEGRAM_EXCLUDE=%s\n' "$existing_exclude"
    } >"$config_file.tmp"
    mv "$config_file.tmp" "$config_file"
  )
  chmod 600 "$config_file"
  printf '%s\n' "$offset" >"$state_dir/offset"
  chat_id="$paired_chat"
  send_msg "" "" "Paired" >/dev/null 2>&1 || true
  echo "Paired. Next: squad-devkit telegram start"
}

case "${1:-}" in
  setup) cmd_setup ;;
  start) cmd_start ;;
  stop) cmd_stop ;;
  status) cmd_status ;;
  run) cmd_run ;;
  -h | --help | help) usage ;;
  *) usage >&2; exit 2 ;;
esac
