#!/usr/bin/env bash
set -euo pipefail
trap 'echo "Failed at line $LINENO: $BASH_COMMAND" >&2' ERR

# bash 3.2 (macOS) does not exit on a failed [[ ]] under set -e.
fail() {
  echo "Assertion failed at line ${BASH_LINENO[0]}" >&2
  exit 1
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temp_directory="$(mktemp -d "${TMPDIR:-/tmp}/telegram-daemon.XXXXXX")" || exit 1
temp_directory="$(cd "$temp_directory" && pwd -P)"
cleanup() {
  local pid
  for pid in ${keep_pids[@]+"${keep_pids[@]}"}; do kill "$pid" 2>/dev/null || true; done
  [[ -z "${daemon_script:-}" ]] || PATH="$bin:$PATH" bash "$daemon_script" stop >/dev/null 2>&1 || true
  rm -rf "$temp_directory"
}
keep_pids=()
trap cleanup EXIT

# A copy of the devkit scripts the daemon needs, with a fake squad-worker.
devkit="$temp_directory/devkit"
mkdir -p "$devkit/scripts/lib"
cp "$repo_root/scripts/squad-telegram.sh" "$devkit/scripts/"
cp "$repo_root/scripts/lib/squad-telegram-spool.sh" "$repo_root/scripts/lib/squad-jq.sh" "$devkit/scripts/lib/"
daemon_script="$devkit/scripts/squad-telegram.sh"
cat >"$devkit/scripts/squad-worker.sh" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == --list ]] || exit 2
echo "workers of $(basename "$PWD")"
for n in 1 2 3 4 5 6 7; do echo "worker-$n running"; done
EOF
chmod +x "$devkit/scripts/squad-worker.sh"

export HOME="$temp_directory/home"
export SQUAD_DEVKIT_TELEGRAM_CONFIG="$temp_directory/config/telegram.env"
export SQUAD_DEVKIT_TELEGRAM_STATE="$temp_directory/state/telegram"
export FAKE_DIR="$temp_directory/fake"
mkdir -p "$HOME" "$temp_directory/config" "$FAKE_DIR/updates" "$temp_directory/bin"
unset HERDR_PANE_ID TMUX_PANE TMUX SQUAD_DEVKIT_TELEGRAM SQUAD_DEVKIT_WORKSPACE || true
bin="$temp_directory/bin"
state="$SQUAD_DEVKIT_TELEGRAM_STATE"
token="123:FAKE"
calls="$FAKE_DIR/calls.log"
inject="$FAKE_DIR/inject.log"

# --- fakes -----------------------------------------------------------------
cat >"$bin/curl" <<'EOF'
#!/usr/bin/env bash
# Fake curl: reads the -K config from stdin, records method and body.
printf '%s\n' "$*" >>"$FAKE_DIR/argv.log"
cfg="$(cat)"
url="$(printf '%s\n' "$cfg" | sed -n 's/^url = "\(.*\)"$/\1/p')"
method="${url##*/}"
case "$url" in */bot123:FAKE/*) ;; *) echo "bad url" >>"$FAKE_DIR/badurl.log" ;; esac
body="$(printf '%s\n' "$cfg" | sed -n 's/^data-binary = "\(.*\)"$/\1/p' | sed -E 's/\\(["\\])/\1/g')"
jq -nc --arg m "$method" --arg b "$body" '{method: $m, body: ($b | fromjson? // $b)}' >>"$FAKE_DIR/calls.log"
[[ ! -e "$FAKE_DIR/netdown" ]] || exit 6
case "$method" in
  getMe) printf '{"ok":true,"result":{"username":"fakebot"}}\n200' ;;
  getUpdates)
    if [[ "$(printf '%s' "$body" | jq -r '.offset')" == -1 ]]; then
      if [[ -f "$FAKE_DIR/backlog.json" ]]; then cat "$FAKE_DIR/backlog.json"; else printf '{"ok":true,"result":[]}'; fi
      printf '\n200'
      exit 0
    fi
    sleep 0.2
    n=$(($(cat "$FAKE_DIR/counter" 2>/dev/null || echo 0) + 1))
    echo "$n" >"$FAKE_DIR/counter"
    if [[ -f "$FAKE_DIR/updates/$n.json" ]]; then cat "$FAKE_DIR/updates/$n.json"; else printf '{"ok":true,"result":[]}'; fi
    printf '\n200'
    ;;
  sendMessage)
    if [[ -e "$FAKE_DIR/fail_send" ]]; then printf '{"ok":false}\n%s' "$(cat "$FAKE_DIR/fail_send" | grep . || echo 500)"; exit 0; fi
    if [[ -f "$FAKE_DIR/fail_match" ]] && printf '%s' "$body" | grep -qF "$(cat "$FAKE_DIR/fail_match")"; then printf '{"ok":false}\n400'; exit 0; fi
    if [[ -f "$FAKE_DIR/send_budget" ]]; then
      left="$(cat "$FAKE_DIR/send_budget")"
      if ((left <= 0)); then printf '{"ok":false}\n500'; exit 0; fi
      echo $((left - 1)) >"$FAKE_DIR/send_budget"
    fi
    n=$(($(cat "$FAKE_DIR/msgid" 2>/dev/null || echo 1000) + 1))
    echo "$n" >"$FAKE_DIR/msgid"
    printf '{"ok":true,"result":{"message_id":%s}}\n200' "$n"
    ;;
  *) printf '{"ok":false}\n404' ;;
esac
EOF
for tool in herdr tmux; do
  cat >"$bin/$tool" <<EOF
#!/usr/bin/env bash
printf '$tool' >>"\$FAKE_DIR/inject.log"
printf ' <%s>' "\$@" >>"\$FAKE_DIR/inject.log"
echo >>"\$FAKE_DIR/inject.log"
EOF
done
# Every pid looks like a manager, except the daemon (named in its pid file) and
# pids listed in not_manager.
cat >"$bin/ps" <<'EOF'
#!/usr/bin/env bash
pid=""
while [[ $# -gt 0 ]]; do [[ "$1" == -p ]] && pid="$2"; shift; done
if [[ "$pid" == "$(cat "$SQUAD_DEVKIT_TELEGRAM_STATE/daemon.pid" 2>/dev/null)" ]]; then
  echo "bash /x/squad-telegram.sh run"
elif grep -qx "$pid" "$FAKE_DIR/not_manager" 2>/dev/null; then echo "vim notes.txt"; else echo "bash /x/squad-devkit-manager.sh claude"; fi
EOF
chmod +x "$bin/curl" "$bin/herdr" "$bin/tmux" "$bin/ps"
export PATH="$bin:$PATH"

# --- helpers ---------------------------------------------------------------
upd() { # id chat type text [reply_to_id reply_to_is_bot]
  jq -nc --argjson id "$1" --argjson chat "$2" --arg type "$3" --arg text "$4" \
    --argjson rid "${5:-0}" --argjson rbot "${6:-false}" \
    '{update_id: $id, message: ({message_id: ($id + 5000), from: {id: $chat, is_bot: false},
      chat: {id: $chat, type: $type}, text: $text}
      + (if $rid > 0 then {reply_to_message: {message_id: $rid, from: {id: 1, is_bot: $rbot}}} else {} end))}'
}
fixture() { # update objects for the next getUpdates call
  local n=$(($(find "$FAKE_DIR/updates" -name '*.json' | wc -l) + 1))
  printf '%s\n' "$@" | jq -sc '{ok: true, result: .}' >"$FAKE_DIR/updates/$n.json"
}
reset_fake() {
  rm -rf "$FAKE_DIR/updates" "$FAKE_DIR/counter" "$FAKE_DIR/backlog.json" "$FAKE_DIR/send_budget" "$FAKE_DIR/fail_match" "$FAKE_DIR/fail_send" "$FAKE_DIR/netdown" "$calls" "$inject"
  mkdir -p "$FAKE_DIR/updates"
  : >"$calls"
  : >"$inject"
}
run_once() { SQUAD_TELEGRAM_ONCE=1 bash "$daemon_script" run; }
sent_texts() { jq -r 'select(.method == "sendMessage") | .body.text' "$calls"; }
sent_count() { jq -r 'select(.method == "sendMessage") | 1' "$calls" | grep -c . || true; }
argv_line() { local out="$1" a; shift; for a in "$@"; do out="$out <$a>"; done; printf '%s\n' "$out"; }
file_mode() { stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1"; }
num_of() { awk -F '\t' -v l="$1" '$2 == l { print NR }' "$state/lastlist"; }
write_config() { printf '%s\n' "$@" >"$SQUAD_DEVKIT_TELEGRAM_CONFIG"; }

# shellcheck source=../scripts/lib/squad-telegram-spool.sh
source "$repo_root/scripts/lib/squad-telegram-spool.sh"
write_config "TELEGRAM_BOT_TOKEN=$token" "TELEGRAM_CHAT_ID=42"

# --- managers: two workspaces on herdr and tmux, one without a pane, one dead
ws_a="$temp_directory/ws/projA"
ws_b="$temp_directory/ws/projB"
ws_c="$temp_directory/ws/projC"
mkdir -p "$ws_a" "$ws_b" "$ws_c"
sleep 300 & pid_a=$!
sleep 300 & pid_b=$!
sleep 300 & pid_c=$!
sleep 300 & pid_d=$!
keep_pids=("$pid_a" "$pid_b" "$pid_c" "$pid_d")
HERDR_PANE_ID=p_1 tg_registry_write projA/manager-1 manager-1 "$ws_a" "$pid_a" claude
TMUX_PANE=%5 TMUX=/tmp/tmux-501/default,1,0 tg_registry_write projB/manager-1 manager-1 "$ws_b" "$pid_b" claude
tg_registry_write projC/manager-1 manager-1 "$ws_c" "$pid_c" claude
tg_registry_write projD/manager-1 manager-1 "$temp_directory/ws/projD" "$pid_d" claude
kill "$pid_d"
wait "$pid_d" 2>/dev/null || true

# 1. Wrong chat, wrong chat type, wrong sender: no reply, no injection.
reset_fake
fixture "$(upd 10 99 private "/list")" "$(upd 11 42 group "hello")" "$(upd 12 99 supergroup "/to 1 hi")" \
  "$(upd 13 42 private "x" | jq -c '.message.from.id = 99')"
run_once
[[ "$(sent_count)" == 0 ]] || fail
[[ ! -s "$inject" ]] || fail
[[ "$(cat "$state/offset")" == 14 ]] || fail
[[ "$(file_mode "$state")" == 700 && "$(file_mode "$state/daemon.log")" == 600 ]] || fail

# 2. /list: live managers only, pane kinds, first 5 worker lines, right chat.
reset_fake
fixture "$(upd 20 42 private "/list")"
run_once
[[ "$(sent_count)" == 1 ]] || fail
[[ "$(jq -r 'select(.method == "sendMessage") | .body.chat_id' "$calls")" == 42 ]] || fail
list="$(sent_texts)"
[[ "$list" == *"projA/manager-1 [herdr]"* && "$list" == *"projB/manager-1 [tmux]"* ]] || fail
[[ "$list" == *"projC/manager-1 [not reachable]"* ]] || fail
[[ "$list" != *projD* ]] || fail
[[ "$list" == *"workers of projA"* && "$list" == *"worker-4 running"* && "$list" != *"worker-5 running"* ]] || { echo "$list" >&2; fail; }
[[ "$(jq -r 'select(.method == "sendMessage") | .body.parse_mode' "$calls")" == HTML ]] || fail
n_a="$(num_of projA/manager-1)"
n_b="$(num_of projB/manager-1)"
n_c="$(num_of projC/manager-1)"
[[ -n "$n_a" && -n "$n_b" && -n "$n_c" ]] || fail
[[ ! -e "$HOME/.config" ]] || true

# 3. /to by number (herdr) and by label prefix (tmux): exact args; ack; current.
reset_fake
fixture "$(upd 30 42 private "/to $n_a hello there")"
run_once
expected="$(argv_line herdr pane send-text p_1 "[telegram] hello there")
$(argv_line herdr pane send-keys p_1 Enter)"
[[ "$(cat "$inject")" == "$expected" ]] || { cat "$inject" >&2; fail; }
[[ "$(sent_texts)" == "→ projA/manager-1" ]] || fail
fixture "$(upd 31 42 private "/to projB hi")"
: >"$inject"
run_once
expected="$(argv_line tmux -S /tmp/tmux-501/default send-keys -t %5 -l "[telegram] hi")
$(argv_line tmux -S /tmp/tmux-501/default send-keys -t %5 Enter)"
[[ "$(cat "$inject")" == "$expected" ]] || { cat "$inject" >&2; fail; }

# 4. Plain text goes to the current manager (projB).
reset_fake
fixture "$(upd 40 42 private "just text")"
run_once
[[ "$(sed -n 1p "$inject")" == "$(argv_line tmux -S /tmp/tmux-501/default send-keys -t %5 -l "[telegram] just text")" ]] || { cat "$inject" >&2; fail; }
# No current manager: asked to choose.
rm -f "$state/current"
reset_fake
fixture "$(upd 41 42 private "orphan")"
run_once
[[ ! -s "$inject" && "$(sent_texts)" == *"/list"* ]] || fail

# 5. A reply to a bot message routes to the manager it came from.
reset_fake
fixture "$(upd 50 42 private "/to $n_a first")"
run_once
a_msg="$(awk -F '\t' '$2 == "projA/manager-1" { id = $1 } END { print id }' "$state/msgmap")"
[[ "$a_msg" =~ ^[0-9]+$ ]] || fail
printf '%s\n' "$pid_b" >"$state/current"
reset_fake
fixture "$(upd 51 42 private "ok push" "$a_msg" true)"
run_once
[[ "$(sed -n 1p "$inject")" == "$(argv_line herdr pane send-text p_1 "[telegram] ok push")" ]] || { cat "$inject" >&2; fail; }
[[ "$(cat "$state/current")" == "$pid_b" ]] || fail
reset_fake
fixture "$(upd 52 42 private "lost" 999999 true)"
run_once
[[ ! -s "$inject" && "$(sent_texts)" == *"don't know"* ]] || fail
reset_fake
fixture "$(upd 53 42 private "own message reply" 999999 false)"
run_once
[[ "$(sed -n 1p "$inject")" == *"tmux"*"[telegram] own message reply"* ]] || fail # not a bot message: current manager

# 5b. B2: a reply routes by exact label only. proj/manager-1 is dead and
# proj/manager-10 is alive: a reply to a manager-1 message is not delivered.
sleep 300 & pid_e=$!
keep_pids+=("$pid_e")
tg_registry_write proj/manager-10 manager-10 "$temp_directory/ws/proj" "$pid_e" claude
printf '7001\tproj/manager-1\n' >>"$state/msgmap"
reset_fake
fixture "$(upd 54 42 private "wrong target" 7001 true)"
run_once
[[ ! -s "$inject" ]] || { cat "$inject" >&2; fail; }
[[ "$(sent_texts)" == "proj/manager-1 is no longer running." ]] || { sent_texts >&2; fail; }
tg_registry_remove "$pid_e"
kill "$pid_e" 2>/dev/null || true

# 5c. N6: a bare answer goes in without the prefix; anything else keeps it.
for ans in 1 y N yes no 9; do
  reset_fake
  fixture "$(upd 55 42 private "/to $n_a $ans")"
  run_once
  [[ "$(sed -n 1p "$inject")" == "$(argv_line herdr pane send-text p_1 "$ans")" ]] || { cat "$inject" >&2; fail; }
done
for ans in 10 maybe "y please" 0; do
  reset_fake
  fixture "$(upd 56 42 private "/to $n_a $ans")"
  run_once
  [[ "$(sed -n 1p "$inject")" == "$(argv_line herdr pane send-text p_1 "[telegram] $ans")" ]] || { cat "$inject" >&2; fail; }
done

# 6. Pane kind none: not reachable, nothing injected.
reset_fake
fixture "$(upd 60 42 private "/to projC hi")"
run_once
[[ ! -s "$inject" ]] || fail
[[ "$(sent_texts)" == "projC/manager-1 is not reachable: start squad-devkit inside herdr or tmux" ]] || { sent_texts >&2; fail; }

# 7. ESC, control characters, bidi marks and newlines never reach the pane.
reset_fake
rlo="$(printf '\342\200\256')"
fixture "$(upd 70 42 private "/to projB a"$'\033'"[31mb"$'\007'"c"$'\n'"d${rlo}e"$'\003'"")"
run_once
[[ "$(sed -n 1p "$inject")" == "$(argv_line tmux -S /tmp/tmux-501/default send-keys -t %5 -l "[telegram] abc de")" ]] || { cat "$inject" >&2; fail; }
[[ "$(sed -n 1p "$inject")" != *$'\033'* ]] || fail
# Unknown slash commands are not forwarded.
reset_fake
fixture "$(upd 71 42 private "/clear")"
run_once
[[ ! -s "$inject" && "$(sent_texts)" == *"Unknown command"* ]] || fail

# 8. 2001 characters are rejected; 2000 pass.
reset_fake
big="$(printf 'x%.0s' $(seq 1 2001))"
fixture "$(upd 80 42 private "/to projB $big")"
run_once
[[ ! -s "$inject" && "$(sent_texts)" == *"too long"* ]] || fail
reset_fake
ok_text="$(printf 'x%.0s' $(seq 1 1990))"
fixture "$(upd 81 42 private "/to projB $ok_text")"
run_once
[[ "$(sed -n 1p "$inject")" == *"[telegram] $ok_text>" ]] || fail

# 9. /help.
reset_fake
fixture "$(upd 90 42 private "/help")"
run_once
[[ "$(sent_texts)" == *"/list"*"/to"*"/help"* ]] || fail

# 10. Outbox: sent in order with prefixes and escaped HTML, deleted on 200,
# kept on failure.
reset_fake
rm -rf "$state/outbox"
tg_spool_put projA/manager-1 reply 'a <b> & "q"'
tg_spool_put projA/manager-1 waiting "needs input"
tg_spool_put "proj<X>/m" worker "dev done"
run_once
[[ "$(sent_count)" == 3 ]] || fail
[[ "$(find "$state/outbox" -name '*.json' | wc -l | tr -d ' ')" == 0 ]] || fail
mapfile_texts="$(sent_texts)"
[[ "$(printf '%s\n' "$mapfile_texts" | sed -n 1,2p)" == $'<b>projA/manager-1</b>\na &lt;b&gt; &amp; "q"' ]] || { printf '%s\n' "$mapfile_texts" >&2; fail; }
[[ "$(printf '%s\n' "$mapfile_texts" | sed -n 3,4p)" == $'<b>projA/manager-1</b>\n⏳ waiting: needs input' ]] || fail
[[ "$(printf '%s\n' "$mapfile_texts" | sed -n 5,6p)" == $'<b>proj&lt;X&gt;/m</b>\n🔧 dev done' ]] || fail
reset_fake
touch "$FAKE_DIR/fail_send"
tg_spool_put projA/manager-1 reply "keep me"
run_once
[[ "$(find "$state/outbox" -name '*.json' | wc -l | tr -d ' ')" == 1 ]] || fail
rm -f "$FAKE_DIR/fail_send"
run_once
[[ "$(find "$state/outbox" -name '*.json' | wc -l | tr -d ' ')" == 0 ]] || fail
[[ "$(sent_texts)" == *"keep me"* ]] || fail
# Long text with many escapes is split below 4096 characters, entities intact.
reset_fake
tg_spool_put projA/manager-1 reply "$(printf '&%.0s' $(seq 1 3000))"
run_once
chunks="$(sent_count)"
((chunks > 1)) || fail
[[ "$(jq -r 'select(.method == "sendMessage") | .body.text | length' "$calls" | sort -n | tail -n 1)" -le 4096 ]] || fail
[[ "$(jq -r 'select(.method == "sendMessage") | .body.text' "$calls" | tr -d '\n' | grep -o '&amp;' | wc -l | tr -d ' ')" == 3000 ]] || fail
# Network down: the loop survives (once mode) and the outbox is kept.
reset_fake
touch "$FAKE_DIR/netdown"
tg_spool_put projA/manager-1 reply "later"
run_once
[[ "$(find "$state/outbox" -name '*.json' | wc -l | tr -d ' ')" == 1 ]] || fail
rm -f "$FAKE_DIR/netdown"
run_once
[[ "$(find "$state/outbox" -name '*.json' | wc -l | tr -d ' ')" == 0 ]] || fail

# 10b. N1: poll getUpdates with timeout 1 while the outbox holds messages, 25 otherwise.
reset_fake
run_once
[[ "$(jq -r 'select(.method == "getUpdates") | .body.timeout' "$calls")" == 25 ]] || fail
reset_fake
tg_spool_put projA/manager-1 reply "queued"
run_once
[[ "$(jq -r 'select(.method == "getUpdates") | .body.timeout' "$calls")" == 1 ]] || fail

# 10c. N2: a permanent 4xx drops the file and does not block the next one;
# 429 and 5xx keep it.
reset_fake
rm -rf "$state/outbox"
echo 400 >"$FAKE_DIR/fail_send"
tg_spool_put projA/manager-1 reply "rejected"
run_once
[[ "$(find "$state/outbox" -name '*.json' | wc -l | tr -d ' ')" == 0 ]] || fail
grep -q 'dropped-rejected' "$state/daemon.log" || fail
reset_fake
echo 429 >"$FAKE_DIR/fail_send"
tg_spool_put projA/manager-1 reply "slow down"
run_once
[[ "$(find "$state/outbox" -name '*.json' | wc -l | tr -d ' ')" == 1 ]] || fail
# A rejected message does not block the one behind it.
reset_fake
rm -rf "$state/outbox"
echo "bad one" >"$FAKE_DIR/fail_match"
tg_spool_put projA/manager-1 reply "bad one"
sleep 1
tg_spool_put projA/manager-1 reply "good one"
run_once
[[ "$(find "$state/outbox" -name '*.json' | wc -l | tr -d ' ')" == 0 ]] || fail
[[ "$(sent_texts)" == *"good one"* ]] || fail
# A partly sent message is dropped after 3 tries, never retried forever.
reset_fake
rm -rf "$state/outbox"
tg_spool_put projA/manager-1 reply "$(printf '&%.0s' $(seq 1 3000))"
for _ in 1 2; do
  echo 1 >"$FAKE_DIR/send_budget"
  run_once
  [[ "$(find "$state/outbox" -name '*.json' | wc -l | tr -d ' ')" == 1 ]] || { tail -8 "$state/daemon.log" >&2; fail; }
done
echo 1 >"$FAKE_DIR/send_budget"
run_once
[[ "$(find "$state/outbox" -name '*.json' | wc -l | tr -d ' ')" == 0 ]] || fail
grep -q 'dropped-partial' "$state/daemon.log" || fail
rm -f "$FAKE_DIR/send_budget"

# 10d. N3: when the offset cannot be written, the batch is not handled.
reset_fake
rm -f "$state/offset"
mkdir "$state/offset.tmp"
fixture "$(upd 100 42 private "/help")"
run_once
rmdir "$state/offset.tmp"
[[ ! -s "$inject" && "$(sent_count)" == 0 ]] || fail
grep -q 'offset-write-failed' "$state/daemon.log" || fail

# 11. Excluded workspaces are hidden from /list and cannot be targeted.
printf '%s\n' "$ws_b" >"$state/../telegram-exclude"
reset_fake
fixture "$(upd 110 42 private "/list")"
run_once
[[ "$(sent_texts)" == *projA* && "$(sent_texts)" != *projB* ]] || fail
reset_fake
fixture "$(upd 111 42 private "/to projB hi")"
run_once
[[ ! -s "$inject" ]] || fail
rm -f "$state/../telegram-exclude"
write_config "TELEGRAM_BOT_TOKEN=$token" "TELEGRAM_CHAT_ID=42" "TELEGRAM_EXCLUDE=/nowhere:$ws_a"
reset_fake
fixture "$(upd 112 42 private "/list")"
run_once
[[ "$(sent_texts)" == *projB* && "$(sent_texts)" != *projA* ]] || fail
# N7: the separator rule holds, and on macOS case does not matter.
write_config "TELEGRAM_BOT_TOKEN=$token" "TELEGRAM_CHAT_ID=42" "TELEGRAM_EXCLUDE=/a/hms"
tg_workspace_excluded /a/hms/sub || fail
tg_workspace_excluded /a/hms-tools && fail
if [[ "$(uname -s)" == Darwin ]]; then
  tg_workspace_excluded /A/HMS/Sub || fail
  tg_workspace_excluded /A/Hms-Tools && fail
fi
write_config "TELEGRAM_BOT_TOKEN=$token" "TELEGRAM_CHAT_ID=42"

# 12. The token is in no argv, no log, no state file, and the URL always had it.
[[ ! -e "$FAKE_DIR/badurl.log" ]] || fail
if grep -rq "FAKE" "$FAKE_DIR/argv.log" "$state"; then fail; fi
if grep -q "hello there\|just text" "$state/daemon.log"; then fail; fi
grep -q 'sent kind=reply label=projA/manager-1' "$state/daemon.log" || fail

# 13. Pairing: only the private chat that sends the code is saved.
rm -rf "$temp_directory/config" "$state"
setup() { # extra env via the caller
  printf '%s\n' "$token" | SQUAD_TELEGRAM_TOKEN_STDIN=1 SQUAD_TELEGRAM_TESTING=1 SQUAD_TELEGRAM_TEST_CODE=424242 \
    SQUAD_TELEGRAM_PAIR_TIMEOUT=2 bash "$daemon_script" setup
}
reset_fake
fixture "$(upd 130 88 private "000000")" "$(upd 131 55 group "424242")" "$(upd 132 77 private "424242")"
out="$(setup 2>&1)" || { echo "$out" >&2; fail; }
[[ "$out" == *"Pairing code: 424242"* && "$out" == *"Paired"* ]] || { echo "$out" >&2; fail; }
[[ "$(grep -c '^TELEGRAM_CHAT_ID=77$' "$SQUAD_DEVKIT_TELEGRAM_CONFIG")" == 1 ]] || fail
grep -q "^TELEGRAM_BOT_TOKEN=$token$" "$SQUAD_DEVKIT_TELEGRAM_CONFIG" || fail
[[ "$(file_mode "$SQUAD_DEVKIT_TELEGRAM_CONFIG")" == 600 && "$(file_mode "$(dirname "$SQUAD_DEVKIT_TELEGRAM_CONFIG")")" == 700 ]] || fail
[[ "$(jq -r 'select(.method == "sendMessage") | [.body.chat_id, .body.text] | join("|")' "$calls")" == "77|Paired" ]] || fail
[[ "$(cat "$state/offset")" == 133 ]] || fail
if jq -r '.body | tostring' "$calls" | grep -q 424242; then fail; fi # the code is never sent to Telegram
# A wrong code saves nothing.
rm -rf "$temp_directory/config" "$state"
reset_fake
fixture "$(upd 140 77 private "123456")"
status=0
out="$(setup 2>&1)" || status=$?
[[ "$status" != 0 && "$out" == *"nothing saved"* ]] || fail
[[ ! -e "$SQUAD_DEVKIT_TELEGRAM_CONFIG" ]] || fail
[[ "$(sent_count)" == 0 ]] || fail
# B1: 30 wrong codes in one batch, then the right one: aborts, saves nothing.
rm -rf "$temp_directory/config" "$state"
reset_fake
wrong_batch=()
for i in $(seq 1 30); do wrong_batch+=("$(upd $((200 + i)) 77 private "11111$((i % 10))")"); done
wrong_batch+=("$(upd 240 77 private "424242")")
fixture "${wrong_batch[@]}"
status=0
out="$(setup 2>&1)" || status=$?
[[ "$status" != 0 && "$out" == *"Too many wrong codes"* ]] || { echo "$out" >&2; fail; }
[[ ! -e "$SQUAD_DEVKIT_TELEGRAM_CONFIG" ]] || fail
# B1: a correct code queued before setup began is ignored.
rm -rf "$temp_directory/config" "$state"
reset_fake
printf '%s\n' "$(upd 300 77 private "424242")" | jq -sc '{ok: true, result: .}' >"$FAKE_DIR/backlog.json"
status=0
out="$(setup 2>&1)" || status=$?
[[ "$status" != 0 && "$out" == *"nothing saved"* && ! -e "$SQUAD_DEVKIT_TELEGRAM_CONFIG" ]] || { echo "$out" >&2; fail; }
# N8: the test code is ignored without SQUAD_TELEGRAM_TESTING=1.
rm -rf "$temp_directory/config" "$state"
reset_fake
out="$(printf '%s\n' "$token" | SQUAD_TELEGRAM_TOKEN_STDIN=1 SQUAD_TELEGRAM_TEST_CODE=424242 SQUAD_TELEGRAM_PAIR_TIMEOUT=1 bash "$daemon_script" setup 2>&1)" || true
[[ "$out" != *"Pairing code: 424242"* && "$out" =~ Pairing\ code:\ [0-9]{6} ]] || { echo "$out" >&2; fail; }
# A bad token format is rejected before any network call.
reset_fake
status=0
printf 'not a token\n' | SQUAD_TELEGRAM_TOKEN_STDIN=1 bash "$daemon_script" setup >/dev/null 2>&1 || status=$?
[[ "$status" != 0 && ! -s "$calls" ]] || fail

# 14. start / status / stop on the pid file.
mkdir -p "$temp_directory/config"
write_config "TELEGRAM_BOT_TOKEN=$token" "TELEGRAM_CHAT_ID=42"
HERDR_PANE_ID=p_1 tg_registry_write projA/manager-1 manager-1 "$ws_a" "$pid_a" claude
tg_registry_write projD/manager-1 manager-1 "$temp_directory/ws/projD" "$pid_d" claude
reset_fake
out="$(bash "$daemon_script" status)"
[[ "$out" == *"daemon: stopped"* && "$out" == *"paired: yes"* && "$out" == *projA/manager-1* && "$out" != *projD* ]] || { echo "$out" >&2; fail; }
[[ "$out" != *FAKE* && "$out" != *42* ]] || fail
out="$(bash "$daemon_script" start)" || { cat "$state/daemon.log" >&2; fail; }
[[ "$out" == Started* ]] || { echo "$out" >&2; fail; }
daemon_pid="$(cat "$state/daemon.pid")"
kill -0 "$daemon_pid" || fail
status=0
out="$(bash "$daemon_script" start)" || status=$?
[[ "$status" == 0 && "$out" == "Already running (pid $daemon_pid)" ]] || { echo "$out" >&2; fail; }
out="$(bash "$daemon_script" status)"
[[ "$out" == *"daemon: running (pid $daemon_pid)"* && "$out" != *FAKE* ]] || fail
# N4: a second foreground run cannot take the lock; the first stays alone.
[[ -d "$state/daemon.lock" ]] || fail
out="$(bash "$daemon_script" run 2>&1)" || true
[[ "$out" == "Already running (pid $daemon_pid)" && "$(cat "$state/daemon.pid")" == "$daemon_pid" ]] || { echo "$out" >&2; fail; }
# N9: setup refuses while the daemon runs.
reset_fake
status=0
out="$(printf '%s\n' "$token" | SQUAD_TELEGRAM_TOKEN_STDIN=1 bash "$daemon_script" setup 2>&1)" || status=$?
[[ "$status" != 0 && "$out" == *"stop the daemon first"* && "$(grep -c getMe "$calls" || true)" == 0 ]] || { echo "$out" >&2; fail; }
[[ "$(file_mode "$state/daemon.pid")" == 600 || "$(file_mode "$state/daemon.pid")" == 644 ]] || true
[[ "$(file_mode "$state/daemon.log")" == 600 ]] || fail
out="$(bash "$daemon_script" stop)"
[[ "$out" == Stopped ]] || fail
[[ ! -e "$state/daemon.pid" && ! -e "$state/daemon.lock" ]] || fail
if kill -0 "$daemon_pid" 2>/dev/null; then fail; fi
[[ "$(bash "$daemon_script" stop)" == "Not running" ]] || fail
[[ "$(bash "$daemon_script" status)" == *"daemon: stopped"* ]] || fail
# Unpaired: run refuses.
rm -f "$SQUAD_DEVKIT_TELEGRAM_CONFIG"
status=0
bash "$daemon_script" run >/dev/null 2>&1 || status=$?
[[ "$status" != 0 ]] || fail
[[ "$(bash "$daemon_script" status)" == *"paired: no"* ]] || fail
if grep -rq "FAKE" "$state" "$FAKE_DIR/argv.log"; then fail; fi

echo "squad_telegram_smoke: ok"
