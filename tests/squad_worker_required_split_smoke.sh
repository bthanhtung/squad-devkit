#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'if [[ -n "${TMUX_TMPDIR:-}" && "$TMUX_TMPDIR" == "$tmp/tmux" ]]; then tmux kill-server 2>/dev/null || true; fi; rm -rf "$tmp"' EXIT
source "$root/scripts/lib/squad-panes.sh"
unset SQUAD_DEVKIT_WORKSPACE SQUAD_WORKTREE_WORKSPACE SQUAD_MANAGER_ID SQUAD_DEVKIT_YOLO
unset TMUX TMUX_PANE SQUAD_DEVKIT_ORCA_TERMINAL ORCA_PANE_KEY ORCA_CLI_COMMAND ORCA_DEV_REPO_ROOT
unset HERDR_ENV HERDR_PANE_ID HERDR_SOCKET_PATH HC_TERMINAL_ID HC_TERMINAL_SOCKET HC_SCOPE SQUAD_WORKER_PANE_HOLD ZELLIJ ZELLIJ_SESSION_NAME
unset WEZTERM_PANE KITTY_WINDOW_ID ITERM_SESSION_ID SQUAD_DEVKIT_GHOSTTY_TERMINAL DISPLAY WAYLAND_DISPLAY
mkdir -p "$tmp/state"
if SQUAD_WORKER_PANES=0 squad_open_monitor /tmp/monitor test "$tmp" "$tmp/state" '' required; then
  echo 'required split accepted disabled panes' >&2; exit 1
fi
if squad_open_monitor /tmp/monitor test "$tmp" "$tmp/state" '' required; then
  echo 'required split accepted no backend' >&2; exit 1
fi
mkdir -p "$tmp/bin" "$tmp/project/.squad"
cat >"$tmp/bin/squad" <<'FAKE'
#!/usr/bin/env bash
case "$1 $2" in
  'join '*) printf 'Joined as %s (role: dev)\n' "$2" ;;
  'task create') echo 'Created task task-1 for worker' ;;
  send*) printf '%s\n' "$*" >>"$TEST_MESSAGES" ;;
esac
FAKE
cat >"$tmp/bin/grok" <<'FAKE'
#!/usr/bin/env bash
if [[ -n "${TMUX:-}" ]]; then
  pane="$(tmux list-panes -F '#{pane_id}' | grep -v -F "$TMUX_PANE")"
  tmux capture-pane -p -t "$pane" >"$TEST_FRAME_AT_ENGINE"
fi
echo called >>"$TEST_ENGINE"
[[ -z "${TEST_ENGINE_FAIL:-}" ]] || exit 3
echo report
FAKE
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH" TEST_MESSAGES="$tmp/messages" TEST_ENGINE="$tmp/engine" TEST_FRAME_AT_ENGINE="$tmp/frame-at-engine"
cd "$tmp/project"
for detection in flag env; do
  args=()
  if [[ "$detection" == flag ]]; then args=(--manager boss); unset SQUAD_MANAGER_ID; else export SQUAD_MANAGER_ID=boss; fi
  if "$root/scripts/squad-worker.sh" "$detection" --engine grok --no-plan "split smoke" --no-worktree --brief test ${args[@]+"${args[@]}"} >"$tmp/out" 2>&1; then
    echo "manager $detection ran without split" >&2; exit 1
  fi
  [[ ! -e "$TEST_ENGINE" ]]
  grep -qx 'state=failed' .squad/workers/"$detection"-*.status
  grep -q 'no supported split terminal' "$TEST_MESSAGES"
done
# Deterministic split failures. Fake sleep bounds readiness and lock waits without
# changing the production timeouts; normal tests never inherit native terminals.
mkdir -p "$tmp/fakes"
cat >"$tmp/fakes/sleep" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
cat >"$tmp/fakes/mktemp" <<'FAKE'
#!/usr/bin/env bash
file="$(/usr/bin/mktemp "$@")" || exit 1
case "$file" in
  */.monitor-ready.*)
    [[ "${FAKE_SPLIT:-}" == never ]] || printf '%s\n' "$PPID" >"$file"
    ;;
esac
printf '%s\n' "$file"
FAKE
cat >"$tmp/fakes/tmux" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  split-window)
    case "$FAKE_SPLIT" in
      error) exit 1 ;;
      empty) exit 0 ;;
      malformed) echo 'bad handle' ;;
      *)
        script="${@: -1}"
        ready="$(sed -n 's/^export SQUAD_WORKER_MONITOR_READY=//p' "$script")"
        case "$FAKE_SPLIT" in
          invalid) echo invalid >"$ready" ;;
          dead) echo 99999999 >"$ready" ;;
          zero) echo 0 >"$ready" ;;
        esac
        echo %42 ;;
    esac ;;
esac
FAKE
cat >"$tmp/fakes/orca-fake" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TEST_BACKEND"
case "$1 $2" in
  'terminal show') echo '{"ok":true,"result":{"terminal":{"connected":true,"writable":true,"orphaned":false,"tabId":"tab"}}}' ;;
  'terminal split') echo '{"ok":true,"result":{}}' ;;
esac
FAKE
cat >"$tmp/fakes/herdr" <<'FAKE'
#!/usr/bin/env bash
case "$1 $2" in
  'pane split') echo '{"result":{"pane":{"pane_id":"w1:p2"}}}' ;;
  'pane run') exit 1 ;;
esac
FAKE
cat >"$tmp/fakes/herdr-app" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TEST_BACKEND"
case "${1:-} ${2:-}" in
  'ls ')
    if [[ -f "$TEST_BACKEND.split_recorded" ]]; then
      echo '{"spaces":[{"id":"sp1","machine":null,"tabs":[{"id":"tb1","terminals":[{"terminal":"t20","pane":"p1f8d0be7d420eec418e499686fe6bd35"},{"terminal":"t21","pane":"p21"}]}]}]}'
    else
      echo '{"spaces":[{"id":"sp1","machine":null,"tabs":[{"id":"tb1","terminals":[{"terminal":"t20","pane":"p1f8d0be7d420eec418e499686fe6bd35"}]}]}]}'
    fi
    ;;
  'do pane.split')
    case "${FAKE_HERDR_APP:-ok}" in
      split_error) echo '{"error":"boom"}'; exit 1 ;;
      unrecorded) echo '{"pane":"p21","terminal":"t21"}' ;;
      ok) : >"$TEST_BACKEND.split_recorded"; echo '{"pane":"p21","terminal":"t21"}' ;;
    esac
    ;;
  'do pane.focus') echo '{"pane":"p1f8d0be7d420eec418e499686fe6bd35"}' ;;
esac
FAKE
chmod +x "$tmp/fakes/"*
export TEST_BACKEND="$tmp/backend"
real_path="$PATH"
export PATH="$tmp/fakes:$PATH"
check_failure() {
  local name="$1" reason="$2"
  rm -f "$TEST_ENGINE" "$TEST_MESSAGES"
  if "$root/scripts/squad-worker.sh" "$name" --engine grok --manager boss --no-plan "split smoke" --no-worktree --brief test >"$tmp/out" 2>&1; then
    echo "$name unexpectedly succeeded" >&2; exit 1
  fi
  [[ ! -e "$TEST_ENGINE" ]]
  grep -qx 'state=failed' .squad/workers/"$name"-*.status
  grep -q "$reason" "$TEST_MESSAGES"
}
export TMUX=fake TMUX_PANE=%1
SQUAD_WORKER_PANES=0 check_failure disabled 'split disabled'
for mode in error empty malformed; do
  export FAKE_SPLIT="$mode"
  check_failure "split-$mode" 'split failed or returned an invalid handle'
done
for mode in never invalid dead zero; do
  export FAKE_SPLIT="$mode"
  check_failure "ready-$mode" 'monitor did not render or exited'
done
mkdir .squad/workers/.pane.lock
check_failure lock 'timed out waiting for pane lock'
rmdir .squad/workers/.pane.lock
unset TMUX TMUX_PANE
export SQUAD_DEVKIT_ORCA_TERMINAL=manager ORCA_CLI_COMMAND=orca-fake
check_failure orca 'split failed or returned an invalid handle'
[[ "$(grep -c 'terminal split' "$TEST_BACKEND")" == 1 ]]
! grep -q dashboard "$TEST_BACKEND"
unset SQUAD_DEVKIT_ORCA_TERMINAL ORCA_CLI_COMMAND
export HERDR_ENV=1 HERDR_PANE_ID=w1:p1
check_failure herdr-run 'split failed or returned an invalid handle'
unset HERDR_ENV HERDR_PANE_ID FAKE_SPLIT
: >"$TEST_BACKEND"
export HC_TERMINAL_ID=missing
check_failure herdr-app-missing 'Herdr desktop terminal (missing) could not be resolved'
! grep -q 'pane.split' "$TEST_BACKEND"
export HC_TERMINAL_ID=t20
for mode in split_error unrecorded; do
  : >"$TEST_BACKEND"
  rm -f "$TEST_BACKEND.split_recorded"
  export FAKE_HERDR_APP="$mode"
  check_failure "herdr-app-$mode" 'herdr_app split failed or returned an invalid handle'
  [[ "$(grep -c '^do pane.split ' "$TEST_BACKEND")" == 1 ]]
done
: >"$TEST_BACKEND"
rm -f "$TEST_BACKEND.split_recorded"
export FAKE_HERDR_APP=ok FAKE_SPLIT=never
check_failure herdr-app-ready 'monitor did not render or exited'
unset HC_TERMINAL_ID FAKE_HERDR_APP FAKE_SPLIT
rm -f "$TEST_BACKEND.split_recorded"
export PATH="$real_path"
# Isolated tmux server: the real monitor must render before the fake engine runs.
unset SQUAD_MANAGER_ID
export TMUX_TMPDIR="$tmp/tmux"
mkdir -p "$TMUX_TMPDIR"
tmux new-session -d -x 160 -y 50 -s split-test
TMUX="$(tmux display-message -p '#{socket_path},#{pid},0')"
export TMUX
TMUX_PANE="$(tmux display-message -p '#{pane_id}')"
export TMUX_PANE
manager_pane="$TMUX_PANE"
export SQUAD_WORKER_PANE_HOLD=20
"$root/scripts/squad-worker.sh" visible --engine grok --manager boss --no-plan "split smoke" --no-worktree --brief 'Visible task' >"$tmp/out" 2>&1
[[ -s "$TEST_ENGINE" ]]
grep -q RUNNING "$TEST_FRAME_AT_ENGINE"
grep -q 'Visible task' "$TEST_FRAME_AT_ENGINE"
worker_pane="$(tmux list-panes -F '#{pane_id}' | grep -v -F "$manager_pane")"
sleep 2
tmux capture-pane -p -t "$worker_pane" >"$tmp/frame"
grep -q 'visible' "$tmp/frame" || { cat "$tmp/frame" >&2; exit 1; }
grep -q 'Visible task' "$tmp/frame"
grep -q 'COMPLETED' "$tmp/frame"
[[ "$(tmux display-message -p '#{pane_id}')" == "$manager_pane" ]]
# A quiet worker has already rendered RUNNING above; failure must remain visible.
export TEST_ENGINE_FAIL=1
if "$root/scripts/squad-worker.sh" failed-visible --engine grok --manager boss --no-plan "split smoke" --no-worktree --brief 'Failing task' >"$tmp/out" 2>&1; then
  echo 'failing engine unexpectedly succeeded' >&2; exit 1
fi
failed_pane="$(tmux list-panes -F '#{pane_id} #{pane_title}' | awk '/failed-visible/ {print $1}')"
sleep 2
tmux capture-pane -p -t "$failed_pane" >"$tmp/failed-frame"
grep -q FAILED "$tmp/failed-frame"
grep -q 'Failing task' "$tmp/failed-frame"
tmux kill-server
