#!/usr/bin/env bash
set -euo pipefail
trap 'echo "Failed at line $LINENO: $BASH_COMMAND" >&2' ERR

# bash 3.2 (macOS) does not exit on a failed [[ ]] under set -e.
fail() {
  echo "Assertion failed at line ${BASH_LINENO[0]}" >&2
  exit 1
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
spool_lib="$repo_root/scripts/lib/squad-telegram-spool.sh"
hook="$repo_root/scripts/lib/squad-telegram-hook.sh"
temp_directory="$(mktemp -d "${TMPDIR:-/tmp}/telegram-smoke.XXXXXX")" || exit 1
temp_directory="$(cd "$temp_directory" && pwd -P)"
trap 'rm -rf "$temp_directory"' EXIT

export SQUAD_DEVKIT_TELEGRAM_CONFIG="$temp_directory/config/telegram.env"
export SQUAD_DEVKIT_TELEGRAM_STATE="$temp_directory/state"
export HOME="$temp_directory/home"
mkdir -p "$HOME" "$temp_directory/config"
unset HERDR_PANE_ID TMUX_PANE TMUX || true
token="123:FAKE"

# A fake ps: every pid looks like a squad-devkit manager unless it is listed in
# $not_manager_file (a program that reused the pid).
fake_bin="$temp_directory/fakebin"
not_manager_file="$temp_directory/not_manager"
export NOT_MANAGER_FILE="$not_manager_file"
mkdir -p "$fake_bin"
cat >"$fake_bin/ps" <<'EOF'
#!/usr/bin/env bash
pid=""
while [[ $# -gt 0 ]]; do [[ "$1" == -p ]] && pid="$2"; shift; done
if grep -qx "$pid" "$NOT_MANAGER_FILE" 2>/dev/null; then echo "vim notes.txt"; else echo "bash /x/squad-devkit-manager.sh claude"; fi
EOF
chmod +x "$fake_bin/ps"
export PATH="$fake_bin:$PATH"

write_config() { printf '%s\n' "$@" >"$SQUAD_DEVKIT_TELEGRAM_CONFIG"; }
file_mode() { stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1"; }
outbox() { find "$SQUAD_DEVKIT_TELEGRAM_STATE/outbox" -maxdepth 1 -name '*.json' ! -name '.*' -exec basename {} \; 2>/dev/null; }
outbox_count() { outbox | grep -c . || true; }

# shellcheck source=../scripts/lib/squad-telegram-spool.sh
source "$spool_lib"

# Enabled only with a token and a chat id.
tg_enabled && fail
write_config "TELEGRAM_BOT_TOKEN=$token"
tg_enabled && fail
write_config "TELEGRAM_BOT_TOKEN=$token" "TELEGRAM_CHAT_ID="
tg_enabled && fail
write_config "TELEGRAM_BOT_TOKEN=" "TELEGRAM_CHAT_ID=42"
tg_enabled && fail
write_config "TELEGRAM_BOT_TOKEN=$token" "TELEGRAM_CHAT_ID=42"
tg_enabled || fail

# Disabled: nothing is written.
rm -f "$SQUAD_DEVKIT_TELEGRAM_CONFIG"
tg_spool_put proj/m reply "hello"
tg_registry_write proj/m m "$PWD" $$ claude
[[ ! -e "$SQUAD_DEVKIT_TELEGRAM_STATE" ]] || fail
write_config "TELEGRAM_BOT_TOKEN=$token" "TELEGRAM_CHAT_ID=42"

# tg_sanitize.
esc=$'\033'
out="$(tg_sanitize "a${esc}[31mred${esc}[0m"$'\r'"b"$'\a'$'\n'"c")"
[[ "$out" == $'aredb\nc' ]] || { printf 'sanitize: %q\n' "$out" >&2; fail; }
out="$(tg_sanitize "x${esc}]0;title"$'\a'"y")"
[[ "$out" == xy ]] || { printf 'osc: %q\n' "$out" >&2; fail; }
out="$(tg_sanitize "abcdefghij" 5)"
[[ "$out" == "abcde…" ]] || fail
out="$(tg_sanitize "$(printf 'x%.0s' $(seq 1 4000))")"
[[ "${#out}" -le 3501 && "$out" == *… ]] || fail
out="$(tg_sanitize "short" 5)"
[[ "$out" == short ]] || fail

# tg_spool_put: valid JSON, quotes and newlines round-trip, modes.
text=$'say "hi"\nsecond line \\ done'
tg_spool_put proj/m1 reply "$text"
[[ "$(outbox_count)" == 1 ]] || fail
file="$SQUAD_DEVKIT_TELEGRAM_STATE/outbox/$(outbox)"
[[ "$(jq -r .label "$file")" == proj/m1 && "$(jq -r .kind "$file")" == reply ]] || fail
[[ "$(jq -r .text "$file")" == "$text" ]] || fail
[[ "$(jq -r '.ts | type' "$file")" == number ]] || fail
[[ "$(file_mode "$SQUAD_DEVKIT_TELEGRAM_STATE/outbox")" == 700 ]] || fail
[[ "$(file_mode "$file")" == 600 ]] || fail
[[ "$(basename "$file")" =~ ^[0-9]+-[0-9]+-[0-9]{6}-[0-9]+\.json$ ]] || fail
tg_spool_put proj/m1 bogus "x" && fail
tg_spool_put proj/m1 reply "" || fail
[[ "$(outbox_count)" == 1 ]] || fail

# The token never shows in any function output.
all_output="$( {
  tg_config_file; tg_state_dir; tg_registry_dir
  tg_enabled
  tg_sanitize "text"
  tg_spool_put a/b worker "done"
  tg_registry_write a/b m "$PWD" $$ claude
  tg_registry_list
  tg_registry_remove $$
} 2>&1 )"
[[ "$all_output" != *"$token"* && "$all_output" != *FAKE* ]] || fail
grep -rq "FAKE" "$SQUAD_DEVKIT_TELEGRAM_STATE" && fail

# Registry: pane detection, mode, and pruning of dead pids.
reg="$(tg_registry_dir)"
tg_registry_write proj/m1 m1 /work/proj $$ claude
[[ "$(file_mode "$reg/$$.json")" == 600 ]] || fail
[[ "$(jq -c '[.label,.manager_id,.workspace,.pid,.client,.pane.kind,.pane.id,.pane.socket]' "$reg/$$.json")" \
  == '["proj/m1","m1","/work/proj",'$$',"claude","none","",""]' ]] || fail
[[ "$(jq -r '.started | type' "$reg/$$.json")" == number ]] || fail
HERDR_PANE_ID=p_7 TMUX_PANE=%3 tg_registry_write proj/m1 m1 /work/proj $$ claude
[[ "$(jq -c '[.pane.kind,.pane.id,.pane.socket]' "$reg/$$.json")" == '["herdr","p_7",""]' ]] || fail
TMUX_PANE=%3 TMUX=/tmp/tmux-1/default,123,0 tg_registry_write proj/m1 m1 /work/proj $$ claude
[[ "$(jq -c '[.pane.kind,.pane.id,.pane.socket]' "$reg/$$.json")" == '["tmux","%3","/tmp/tmux-1/default"]' ]] || fail
tg_registry_write bad m /w notanumber claude && fail
sleep 30 &
dead_pid=$!
tg_registry_write proj/m2 m2 /work/other "$dead_pid" claude
[[ "$(tg_registry_list | wc -l | tr -d ' ')" == 2 ]] || fail
kill "$dead_pid"
wait "$dead_pid" 2>/dev/null || true
list="$(tg_registry_list)"
[[ "$(printf '%s\n' "$list" | wc -l | tr -d ' ')" == 1 ]] || fail
[[ "$(printf '%s' "$list" | jq -r .label)" == proj/m1 ]] || fail
[[ ! -e "$reg/$dead_pid.json" ]] || fail
tg_registry_remove $$
[[ ! -e "$reg/$$.json" ]] || fail

# Hooks.
rm -rf "$SQUAD_DEVKIT_TELEGRAM_STATE/outbox"
transcript="$temp_directory/transcript.jsonl"
{
  jq -nc '{type:"user",message:{content:"do it"}}'
  jq -nc '{type:"assistant",message:{content:[{type:"text",text:"first answer"}]}}'
  jq -nc '{type:"user",message:{content:"more"}}'
  jq -nc '{type:"assistant",message:{content:[{type:"text",text:"last \"answer\""},{type:"text",text:"line two"}]}}'
  # A sub-agent (sidechain) entry after the answer must not be sent instead.
  jq -nc '{type:"assistant",isSidechain:true,message:{content:[{type:"text",text:"sub-agent chatter"}]}}'
} >"$transcript"
hook_out="$(jq -nc --arg t "$transcript" '{transcript_path:$t}' | "$hook" stop proj/m1)"
[[ -z "$hook_out" ]] || fail
[[ "$(outbox_count)" == 1 ]] || fail
file="$SQUAD_DEVKIT_TELEGRAM_STATE/outbox/$(outbox)"
[[ "$(jq -r .kind "$file")" == reply && "$(jq -r .label "$file")" == proj/m1 ]] || fail
[[ "$(jq -r .text "$file")" == $'last "answer"\nline two' ]] || fail
rm -f "$SQUAD_DEVKIT_TELEGRAM_STATE"/outbox/*.json
# R6: when the turn's final assistant entry has no text, nothing is sent and an
# older reply is not resent. A tool_result "user" entry is not a new prompt.
{
  jq -nc '{type:"user",message:{content:"do it"}}'
  jq -nc '{type:"assistant",message:{content:[{type:"text",text:"older reply"}]}}'
  jq -nc '{type:"user",message:{content:"next"}}'
  jq -nc '{type:"assistant",message:{content:[{type:"text",text:"working on it"}]}}'
  jq -nc '{type:"user",message:{content:[{type:"tool_result",content:"ok"}]}}'
  jq -nc '{type:"assistant",message:{content:[{type:"tool_use",name:"Bash"}]}}'
} >"$transcript"
jq -nc --arg t "$transcript" '{transcript_path:$t}' | "$hook" stop proj/m1
[[ "$(outbox_count)" == 0 ]] || fail
{
  jq -nc '{type:"user",message:{content:"do it"}}'
  jq -nc '{type:"assistant",message:{content:[{type:"text",text:"older reply"}]}}'
  jq -nc '{type:"user",message:{content:[{type:"text",text:"new prompt"}]}}'
  jq -nc '{type:"assistant",message:{content:[{type:"tool_use",name:"Bash"}]}}'
} >"$transcript"
jq -nc --arg t "$transcript" '{transcript_path:$t}' | "$hook" stop proj/m1
[[ "$(outbox_count)" == 0 ]] || fail
# Only the last 40 lines are read, and a long turn still yields its final text.
{
  jq -nc '{type:"user",message:{content:"big job"}}'
  for i in $(seq 1 60); do jq -nc --arg i "$i" '{type:"assistant",message:{content:[{type:"text",text:("step " + $i)}]}}'; done
} >"$transcript"
jq -nc --arg t "$transcript" '{transcript_path:$t}' | "$hook" stop proj/m1
[[ "$(jq -r .text "$SQUAD_DEVKIT_TELEGRAM_STATE/outbox/$(outbox)")" == "step 60" ]] || fail
rm -f "$SQUAD_DEVKIT_TELEGRAM_STATE"/outbox/*.json
hook_out="$(jq -nc '{message:"Claude needs your permission to use Bash"}' | "$hook" notification proj/m1)"
[[ -z "$hook_out" ]] || fail
file="$SQUAD_DEVKIT_TELEGRAM_STATE/outbox/$(outbox)"
[[ "$(jq -r .kind "$file")" == waiting ]] || fail
[[ "$(jq -r .text "$file")" == 'Claude needs your permission to use Bash' ]] || fail
rm -f "$SQUAD_DEVKIT_TELEGRAM_STATE"/outbox/*.json
# Bad input still exits 0 and spools nothing.
status=0
hook_out="$(printf 'not json' | "$hook" stop proj/m1)" || status=$?
[[ "$status" == 0 && -z "$hook_out" && "$(outbox_count)" == 0 ]] || fail
jq -nc '{transcript_path:"/nonexistent"}' | "$hook" stop proj/m1 || fail
printf '{}' | "$hook" notification proj/m1 || fail
[[ "$(outbox_count)" == 0 ]] || fail

# Disabled hooks exit 0, print nothing and spool nothing.
rm -f "$SQUAD_DEVKIT_TELEGRAM_CONFIG"
rm -rf "$SQUAD_DEVKIT_TELEGRAM_STATE"
status=0
hook_out="$(jq -nc --arg t "$transcript" '{transcript_path:$t}' | "$hook" stop proj/m1 2>&1)" || status=$?
[[ "$status" == 0 && -z "$hook_out" ]] || fail
hook_out="$(jq -nc '{message:"x"}' | "$hook" notification proj/m1 2>&1)" || status=$?
[[ "$status" == 0 && -z "$hook_out" && ! -e "$SQUAD_DEVKIT_TELEGRAM_STATE" ]] || fail

# squad_notify queues a worker message (desktop notifications off).
# shellcheck source=../scripts/lib/squad-notify.sh
source "$repo_root/scripts/lib/squad-notify.sh"
SQUAD_DEVKIT_NOTIFY=0 SQUAD_DEVKIT_WORKSPACE=/work/proj SQUAD_MANAGER_ID=manager-2 squad_notify "Worker done" "dev finished"
[[ "$(outbox_count)" == 0 ]] || fail
write_config "TELEGRAM_BOT_TOKEN=$token" "TELEGRAM_CHAT_ID=42"
SQUAD_DEVKIT_NOTIFY=0 SQUAD_DEVKIT_WORKSPACE=/work/proj SQUAD_MANAGER_ID=manager-2 squad_notify "Worker done" "dev finished"
file="$SQUAD_DEVKIT_TELEGRAM_STATE/outbox/$(outbox)"
[[ "$(jq -r '[.label,.kind,.text] | join("|")' "$file")" == 'proj/manager-2|worker|Worker done: dev finished' ]] || fail
rm -rf "$SQUAD_DEVKIT_TELEGRAM_STATE"

# R1: labels are single-line; bidi controls and line separators are stripped.
bidi="$(printf '\342\200\256')"
isolate="$(printf '\342\201\246')"
lsep="$(printf '\342\200\250')"
out="$(tg_sanitize "a${bidi}b${lsep}c${isolate}d")"
[[ "$out" == abcd ]] || fail
tg_spool_put $'proj\nevil/m'"$bidi" reply "x"
[[ "$(jq -r .label "$SQUAD_DEVKIT_TELEGRAM_STATE/outbox/$(outbox)")" == "proj evil/m" ]] || fail
tg_registry_write $'a\nb/m' m /w $$ claude
[[ "$(jq -r .label "$(tg_registry_dir)/$$.json")" == "a b/m" ]] || fail
tg_registry_remove $$

# R2: pane ids are validated; anything odd becomes kind none.
pane_of() { jq -c '[.pane.kind,.pane.id,.pane.socket]' "$(tg_registry_dir)/$$.json"; }
HERDR_PANE_ID='p 1;rm -rf' tg_registry_write l m /w $$ claude
[[ "$(pane_of)" == '["none","",""]' ]] || fail
HERDR_PANE_ID='$(touch x)' tg_registry_write l m /w $$ claude
[[ "$(pane_of)" == '["none","",""]' ]] || fail
TMUX_PANE='%1;ls' TMUX=/tmp/s,1,0 tg_registry_write l m /w $$ claude
[[ "$(pane_of)" == '["none","",""]' ]] || fail
TMUX_PANE='%x' tg_registry_write l m /w $$ claude
[[ "$(pane_of)" == '["none","",""]' ]] || fail
HERDR_PANE_ID='w1:2.p-3' tg_registry_write l m /w $$ claude
[[ "$(pane_of)" == '["herdr","w1:2.p-3",""]' ]] || fail
TMUX_PANE='%12' TMUX=/tmp/s,1,0 tg_registry_write l m /w $$ claude
[[ "$(pane_of)" == '["tmux","%12","/tmp/s"]' ]] || fail
tg_registry_remove $$

# R3: a reused pid (not a squad-devkit-manager) is dropped from the registry.
sleep 30 &
reused=$!
tg_registry_write proj/reused m /w "$reused" claude
[[ "$(tg_registry_list | wc -l | tr -d ' ')" == 1 ]] || fail
printf '%s\n' "$reused" >"$not_manager_file"
[[ "$(tg_registry_list | wc -l | tr -d ' ')" == 0 ]] || fail
[[ ! -e "$(tg_registry_dir)/$reused.json" ]] || fail
: >"$not_manager_file"
kill "$reused" 2>/dev/null || true
wait "$reused" 2>/dev/null || true

# R4: outbox names are unique and sort in send order.
rm -rf "$SQUAD_DEVKIT_TELEGRAM_STATE/outbox"
for i in $(seq 1 30); do tg_spool_put proj/m reply "msg $i"; done
[[ "$(outbox_count)" == 30 ]] || fail
order="$(for f in $(outbox | LC_ALL=C sort); do jq -r .text "$SQUAD_DEVKIT_TELEGRAM_STATE/outbox/$f"; done | tr '\n' ',')"
[[ "$order" == "$(for i in $(seq 1 30); do printf 'msg %s,' "$i"; done)" ]] || fail
[[ -z "$(find "$SQUAD_DEVKIT_TELEGRAM_STATE/outbox" -name '.*.tmp')" ]] || fail

# R5: the outbox is capped at 500 files, oldest dropped first.
rm -rf "$SQUAD_DEVKIT_TELEGRAM_STATE/outbox"
mkdir -p "$SQUAD_DEVKIT_TELEGRAM_STATE/outbox"
for i in $(seq 1 520); do : >"$SQUAD_DEVKIT_TELEGRAM_STATE/outbox/0-1-$(printf '%06d' "$i")-1.json"; done
tg_spool_put proj/m reply "newest"
[[ "$(outbox_count)" == 500 ]] || fail
[[ ! -e "$SQUAD_DEVKIT_TELEGRAM_STATE/outbox/0-1-000021-1.json" && -e "$SQUAD_DEVKIT_TELEGRAM_STATE/outbox/0-1-000022-1.json" ]] || fail
newest_count=0
for f in "$SQUAD_DEVKIT_TELEGRAM_STATE"/outbox/*.json; do
  [[ "$(jq -r '.text? // empty' "$f" 2>/dev/null)" == newest ]] && newest_count=$((newest_count + 1))
done
[[ "$newest_count" == 1 ]] || fail
rm -rf "$SQUAD_DEVKIT_TELEGRAM_STATE"

# R7: opt-outs. SQUAD_DEVKIT_TELEGRAM=0 turns everything off.
SQUAD_DEVKIT_TELEGRAM=0 tg_enabled && fail
SQUAD_DEVKIT_TELEGRAM=0 tg_spool_put proj/m reply "off"
[[ ! -e "$SQUAD_DEVKIT_TELEGRAM_STATE" ]] || fail
tg_enabled || fail
# A path-prefix list: the exclude file, one prefix per line (colons also work).
exclude_file="$(dirname "$SQUAD_DEVKIT_TELEGRAM_STATE")/telegram-exclude"
printf '# clients\n/work/client\n/other/a:/other/b/\n' >"$exclude_file"
SQUAD_DEVKIT_WORKSPACE=/work/client tg_enabled && fail
SQUAD_DEVKIT_WORKSPACE=/work/client/app/sub tg_enabled && fail
SQUAD_DEVKIT_WORKSPACE=/other/b/x tg_enabled && fail
SQUAD_DEVKIT_WORKSPACE=/work/clientele tg_enabled || fail
SQUAD_DEVKIT_WORKSPACE=/work/mine tg_enabled || fail
pwd_workspace="$temp_directory/pwd-ws"
mkdir -p "$pwd_workspace"
(cd "$pwd_workspace" && SQUAD_DEVKIT_WORKSPACE='' tg_enabled) || fail
printf '%s\n' "$pwd_workspace" >>"$exclude_file"
(cd "$pwd_workspace" && unset SQUAD_DEVKIT_WORKSPACE && tg_enabled) && fail # PWD is the fallback
rm -f "$exclude_file"
# The same list in the config as TELEGRAM_EXCLUDE (colon-separated).
write_config "TELEGRAM_BOT_TOKEN=$token" "TELEGRAM_CHAT_ID=42" "TELEGRAM_EXCLUDE=/nowhere:/work/client"
SQUAD_DEVKIT_WORKSPACE=/work/client/x tg_enabled && fail
SQUAD_DEVKIT_WORKSPACE=/work/mine tg_enabled || fail
# An excluded workspace: no outbox, no registry, no worker copy, no hook output.
SQUAD_DEVKIT_WORKSPACE=/work/client tg_spool_put proj/m reply "secret"
SQUAD_DEVKIT_WORKSPACE=/work/client tg_registry_write proj/m m /work/client $$ claude
SQUAD_DEVKIT_WORKSPACE=/work/client SQUAD_MANAGER_ID=m SQUAD_DEVKIT_NOTIFY=0 squad_notify "Worker done" "client code"
jq -nc --arg t "$transcript" '{transcript_path:$t}' | SQUAD_DEVKIT_WORKSPACE=/work/client "$hook" stop proj/m
jq -nc '{message:"x"}' | SQUAD_DEVKIT_WORKSPACE=/work/client "$hook" notification proj/m
[[ ! -e "$SQUAD_DEVKIT_TELEGRAM_STATE" ]] || fail
write_config "TELEGRAM_BOT_TOKEN=$token" "TELEGRAM_CHAT_ID=42"
rm -rf "$SQUAD_DEVKIT_TELEGRAM_STATE"

# Manager wrapper: a fake claude copies the --settings file it is given.
bin="$temp_directory/bin"
project="$temp_directory/project"
mkdir -p "$bin" "$project"
git init -q --template= "$project"
ln -s "$(command -v squad)" "$bin/squad"
cat >"$bin/claude" <<EOF
#!/usr/bin/env bash
while [[ \$# -gt 0 ]]; do
  [[ "\$1" == --settings ]] && cp "\$2" "$temp_directory/settings.json"
  shift
done
EOF
chmod +x "$bin/claude"
run_manager() {
  rm -f "$temp_directory/settings.json"
  (
    cd "$project"
    env -u SQUAD_MANAGER_ID -u SQUAD_DEVKIT_GUARD -u SQUAD_DEVKIT_YOLO \
      PATH="$bin:/usr/bin:/bin:$(dirname "$(command -v jq)")" \
      SQUAD_DEVKIT_FALLBACK_MANAGER=none SQUAD_DEVKIT_STATUSLINE=0 SQUAD_DEVKIT_ROUTER_URL=http://localhost:1 \
      "$repo_root/scripts/lib/squad-devkit-manager.sh" claude instructions hello 2>"$temp_directory/manager.err"
  )
}

# Telegram off: the same settings as before, no Stop or Notification hooks.
rm -f "$SQUAD_DEVKIT_TELEGRAM_CONFIG"
run_manager
[[ "$(jq -c '.hooks | keys' "$temp_directory/settings.json")" == '["PreToolUse"]' ]] || fail
[[ ! -e "$SQUAD_DEVKIT_TELEGRAM_STATE" ]] || fail

# Telegram on: Stop and Notification are added next to PreToolUse, and the
# registry entry is removed again when the manager exits.
write_config "TELEGRAM_BOT_TOKEN=$token" "TELEGRAM_CHAT_ID=42"
run_manager
[[ "$(jq -c '.hooks | keys' "$temp_directory/settings.json")" == '["Notification","PreToolUse","Stop"]' ]] || fail
stop_command="$(jq -r '.hooks.Stop[0].hooks[0].command' "$temp_directory/settings.json")"
[[ "$stop_command" == *squad-telegram-hook.sh*stop*project/* ]] || { echo "$stop_command" >&2; fail; }
[[ "$(jq -c '[.hooks.Stop[0].hooks[0].timeout, .hooks.Notification[0].hooks[0].timeout]' "$temp_directory/settings.json")" == '[10,10]' ]] || fail
[[ "$(jq -r '.hooks.Notification[0].hooks[0].command' "$temp_directory/settings.json")" == *squad-telegram-hook.sh*notification* ]] || fail
[[ "$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$temp_directory/settings.json")" == *squad-devkit-manager-guard.sh* ]] || fail
[[ "$(tg_registry_list | wc -l | tr -d ' ')" == 0 ]] || fail
grep -rq "FAKE" "$SQUAD_DEVKIT_TELEGRAM_STATE" 2>/dev/null && fail

echo "squad_telegram_hook_smoke: ok"
