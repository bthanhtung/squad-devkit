#!/usr/bin/env bash
set -euo pipefail
fail() { echo "Assertion failed at line ${BASH_LINENO[0]}" >&2; exit 1; }
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/squad-tools-smoke.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/project/.squad/workers"
export PATH="$tmp/bin:$PATH" TEST_ARGS="$tmp/args"
export HOME="$tmp/home" XDG_DATA_HOME="$tmp/home/.local/share"
unset TMUX TMUX_PANE SQUAD_DEVKIT_ORCA_TERMINAL ORCA_TERMINAL_HANDLE ORCA_PANE_KEY HC_TERMINAL_ID HERDR_ENV HERDR_PANE_ID WEZTERM_PANE KITTY_WINDOW_ID KITTY_LISTEN_ON ITERM_SESSION_ID SQUAD_DEVKIT_GHOSTTY_TERMINAL TERM_PROGRAM __CFBundleIdentifier SQUAD_DEVKIT_NOTIFY_BUNDLE_ID SQUAD_DEVKIT_NOTIFY_APP SQUAD_DEVKIT_NOTIFY_BACKEND ORCA_CLI_COMMAND ORCA_DEV_REPO_ROOT
mkdir -p "$HOME"
cat >"$tmp/bin/uname" <<'FAKE'
#!/usr/bin/env bash
echo "${TEST_OS:-Linux}"
FAKE
cat >"$tmp/bin/osascript" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$TEST_ARGS"
cat >/dev/null
exit "${TEST_FAIL:-0}"
FAKE
cat >"$tmp/bin/notify-send" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$TEST_ARGS"
exit "${TEST_FAIL:-0}"
FAKE
chmod +x "$tmp/bin/"*
source "$root/scripts/lib/squad-notify.sh"
body="$(printf '%s\n%s' "\"'\\\$(touch INJECTED)" "$(printf '%0200d' 0)")"
cd "$tmp/project"
for os in Darwin Linux; do
  export TEST_OS="$os"
  squad_notify title "$body"
  [[ ! -e INJECTED ]] || fail
  [[ "$(tail -n 1 "$TEST_ARGS" | wc -c | tr -d ' ')" == 201 ]] || fail
  grep -Fq '$(touch INJECTED)' "$TEST_ARGS" || fail
  rm "$TEST_ARGS"
  SQUAD_DEVKIT_NOTIFY=0 squad_notify title body
  [[ ! -e "$TEST_ARGS" ]] || fail
  TEST_FAIL=1 squad_notify title body || fail
done
# Capture the document path without consuming it, like a running app instance.
cat >"$tmp/bin/open" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$TEST_ARGS"
exit "${OPEN_FAIL:-0}"
FAKE
cat >"$tmp/bin/orca" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
chmod +x "$tmp/bin/open" "$tmp/bin/orca"
app="$XDG_DATA_HOME/squad-devkit/SquadNotifier.app"
mkdir -p "$app/Contents/MacOS"
touch "$app/Contents/MacOS/squad-notifier"
chmod +x "$app/Contents/MacOS/squad-notifier"
export TEST_OS=Darwin SQUAD_DEVKIT_WORKSPACE="$tmp/project" SQUAD_DEVKIT_ORCA_TERMINAL=terminal-1
squad_notify title "$body"
payload="$(tail -n 1 "$TEST_ARGS")"
[[ "$(sed -n '1p' "$TEST_ARGS")" == -g && "$(sed -n '2p' "$TEST_ARGS")" == -a && "$(sed -n '3p' "$TEST_ARGS")" == "$app" ]] || fail
[[ -f "$payload" && "$(stat -f '%Lp' "$payload" 2>/dev/null || stat -c '%a' "$payload")" == 600 ]] || fail
[[ "$(stat -f '%Lp' "$(dirname "$payload")" 2>/dev/null || stat -c '%a' "$(dirname "$payload")")" == 700 ]] || fail
python3 - "$payload" "$tmp" <<'PYTEST'
import json,sys
p=json.load(open(sys.argv[1])); t=sys.argv[2]
assert p['bundle_id']=='com.stablyai.orca' and p['backend']=='orca' and p['handle']=='terminal-1'
assert p['workspace']==t+'/project' and p['subtitle']=='project' and p['cli_path']==t+'/bin/orca'
assert p['body'].startswith('"\'\\$(touch INJECTED)')
PYTEST
TMUX='/tmp/socket,1,2' TMUX_PANE=%42 squad_notify title body
payload="$(tail -n 1 "$TEST_ARGS")"
python3 - "$payload" <<'PYTEST'
import json,sys
p=json.load(open(sys.argv[1])); assert (p['backend'],p['handle'],p['tmux_socket'])==('tmux','%42','/tmp/socket')
PYTEST
unset SQUAD_DEVKIT_ORCA_TERMINAL
KITTY_WINDOW_ID=42 KITTY_LISTEN_ON=unix:/tmp/kitty squad_notify title body
payload="$(tail -n 1 "$TEST_ARGS")"
python3 - "$payload" <<'PYTEST'
import json,sys
p=json.load(open(sys.argv[1])); assert (p['backend'],p['handle'],p['kitty_listen_on'])==('kitty','42','unix:/tmp/kitty')
PYTEST
SQUAD_DEVKIT_NOTIFY_BACKEND=osascript squad_notify title body
[[ "$(head -n 1 "$TEST_ARGS")" == - ]] || fail
rm -f "$XDG_DATA_HOME/squad-devkit/notify-spool/"*.squadnotify
OPEN_FAIL=1 squad_notify title body
[[ "$(head -n 1 "$TEST_ARGS")" == - ]] || fail
[[ -z "$(find "$XDG_DATA_HOME/squad-devkit/notify-spool" -name '*.squadnotify' -print)" ]] || fail
cat >"$tmp/bin/terminal-notifier" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$TEST_ARGS"
FAKE
chmod +x "$tmp/bin/terminal-notifier"
SQUAD_DEVKIT_NOTIFY_APP="$tmp/missing" TERM_PROGRAM=Orca squad_notify title body
grep -Fxq -- '-activate' "$TEST_ARGS" && grep -Fxq 'com.stablyai.orca' "$TEST_ARGS" && grep -Fxq -- '-title' "$TEST_ARGS" && grep -Fxq -- '-message' "$TEST_ARGS" || fail
rm "$tmp/bin/terminal-notifier"
if [[ "$(/usr/bin/uname -s 2>/dev/null || true)" == Darwin ]] && command -v swiftc >/dev/null 2>&1; then
  export SQUAD_DEVKIT_NOTIFY_APP="$tmp/real/SquadNotifier.app"
  bash "$root/scripts/lib/squad-notify-macos-build.sh"
  bash "$root/scripts/lib/squad-notify-macos-build.sh" | grep -q 'up to date' || fail
  command() { if [[ "$1" == -v && "${2:-}" == orca ]]; then printf '/usr/local/bin/orca\n'; else builtin command "$@"; fi; }
  SQUAD_DEVKIT_ORCA_TERMINAL=terminal-1 squad_notify title body
  unset -f command
  payload="$(tail -n 1 "$TEST_ARGS")"
  "$SQUAD_DEVKIT_NOTIFY_APP/Contents/MacOS/squad-notifier" --dry-run-click "$payload" >"$tmp/actions"
  python3 - "$tmp/actions" <<'PYTEST'
import json,sys
p=json.load(open(sys.argv[1])); assert p['bundle_id']=='com.stablyai.orca' and not p['warnings'] and p['commands'][0][1:3]==['terminal','focus']
PYTEST
  printf '%s\n' '{"title":"x","body":"x","cli_path":"/tmp/orca","handle":"--evil","bundle_id":"bad;id","backend":"orca"}' >"$tmp/hostile"
  "$SQUAD_DEVKIT_NOTIFY_APP/Contents/MacOS/squad-notifier" --dry-run-click "$tmp/hostile" >"$tmp/actions"
  python3 - "$tmp/actions" <<'PYTEST'
import json,sys
p=json.load(open(sys.argv[1])); assert not p['commands'] and p['warnings']
PYTEST
  unset SQUAD_DEVKIT_NOTIFY_APP
fi
unset SQUAD_DEVKIT_WORKSPACE

now=$(date +%s)
cat >.squad/workers/a.status <<EOF2
worker=a
engine=codex
model_tier=balanced
attempt=1
state=completed
verify=pass
started=$now
finished=$((now+10))
tokens_in=100
tokens_cached=20
tokens_out=30
EOF2
cat >.squad/workers/b.status <<EOF2
worker=a
engine=codex
model_tier=balanced
attempt=2
state=completed
started=$now
finished=$((now+20))
tokens_in=50
tokens_out=10
EOF2
cat >.squad/workers/c.status <<EOF2
worker=c
engine=claude
attempt=1
state=failed
verify=fail
started=$now
finished=$((now+4))
tokens_in=40
tokens_cached=10
tokens_out=5
EOF2
cat >.squad/workers/d.status <<EOF2
worker=d
engine=opencode
model_tier=fast
attempt=2
state=completed
started=$now
finished=$((now+2))
EOF2
out="$($root/scripts/squad-devkit.sh --stats)"
awk '$1=="codex" && $2=="balanced" { found=($3==2 && $4=="100.0%" && $5=="2.00" && $6==170 && $7=="15.0s") } END { exit !found }' <<<"$out" || fail
awk '$1=="claude" && $2=="-" { found=($3==1 && $4=="0.0%" && $5=="1.00" && $6==35 && $7=="4.0s") } END { exit !found }' <<<"$out" || fail
awk '$1=="opencode" && $2=="fast" { found=($4=="-") } END { exit !found }' <<<"$out" || fail
[[ "$(printf '%s\n' "$out" | awk 'NR>1 {print $1, $2}')" == "$(printf '%s\n' "$out" | awk 'NR>1 {print $1, $2}' | sort)" ]] || fail
mkdir -p nested/child
out="$(cd nested/child && "$root/scripts/squad-devkit.sh" --stats)"
awk '$1=="codex" && $2=="balanced" { found=1 } END { exit !found }' <<<"$out" || fail
mkdir -p "$tmp/empty"
SQUAD_DEVKIT_PROJECT_ROOT="$tmp/empty" "$root/scripts/squad-devkit.sh" --stats | grep -qx 'no runs' || fail
sed "s/started=$now/started=1/" .squad/workers/c.status >.squad/workers/old.status
out="$($root/scripts/squad-devkit.sh --stats --days 1)"
awk '$1=="claude" && $2=="-" && $3==1 { found=1 } END { exit !found }' <<<"$out" || fail
rm .squad/workers/*.status
[[ "$($root/scripts/squad-devkit.sh --stats)" == 'no runs' ]] || fail
cat >"$tmp/bin/tmux" <<'FAKE'
#!/usr/bin/env bash
if [[ "$1" == split-window ]]; then
  echo called >>"$TEST_ARGS"
  [[ "${TEST_FAIL:-0}" == 0 ]] || exit 1
  echo %42
fi
FAKE
chmod +x "$tmp/bin/tmux"
rm -f "$TEST_ARGS"
export TMUX=fake TMUX_PANE=%1
"$root/scripts/squad-devkit.sh" --doctor >"$tmp/doctor" 2>&1 || true
[[ ! -e "$TEST_ARGS" ]] || fail
"$root/scripts/squad-devkit.sh" --doctor --split-test >"$tmp/doctor" 2>&1 || true
grep -q 'split test opened' "$tmp/doctor" || fail
if TEST_FAIL=1 "$root/scripts/squad-devkit.sh" --doctor --split-test >"$tmp/doctor" 2>&1; then fail; fi
grep -q 'tmux split failed' "$tmp/doctor" || fail
echo 'devkit tools smoke passed'
