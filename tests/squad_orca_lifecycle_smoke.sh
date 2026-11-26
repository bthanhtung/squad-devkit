#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
temp="$(mktemp -d "${TMPDIR:-/tmp}/squad-orca-lifecycle.XXXXXX")"
trap 'rm -rf "$temp"' EXIT
mkdir -p "$temp/home" "$temp/bin" "$temp/project/.squad/workers"
export HOME="$temp/home" TMPDIR="$temp" FAKE_LOG="$temp/log" ORCA_CLI_COMMAND="$temp/bin/orca"
export SQUAD_DEVKIT_SKIP_SQUAD=1 SQUAD_DEVKIT_ORCA_TERMINAL=mgr SQUAD_ORCA_CLOSE_SYNC=1 SQUAD_WORKER_PANES=1 SQUAD_DEVKIT_NOTIFY=0
unset TMUX TMUX_PANE HERDR_ENV HERDR_PANE_ID SQUAD_DEVKIT_YOLO SQUAD_MANAGER_ID SQUAD_DEVKIT_MANAGER_WRAPPER_PID
cat >"$ORCA_CLI_COMMAND" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_LOG"
case "$2" in
  list) if [[ -n "${FAKE_LIST:-}" ]]; then cat "$FAKE_LIST"; else printf '{"ok":true,"result":{"terminals":[{"handle":"mgr","tabId":"tab"}]}}\n'; fi ;;
  show) printf '{"ok":true,"result":{"terminal":{"tabId":"tab","connected":true,"writable":true,"orphaned":false}}}\n' ;;
  split) printf '{"ok":true,"result":{"split":{"handle":"term_new"}}}\n' ;;
  *) printf '{"ok":true}\n' ;;
esac
FAKE
chmod +x "$ORCA_CLI_COMMAND"
cat >"$temp/bin/squad" <<'FAKE'
#!/usr/bin/env bash
case "$1 $2" in
  'join '*) printf 'Joined as %s (role: dev)\n' "$2" ;;
  'task create') echo 'Created task task-1 for worker' ;;
esac
FAKE
chmod +x "$temp/bin/squad"
cat >"$temp/bin/grok" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
chmod +x "$temp/bin/grok"
export PATH="$temp/bin:$PATH" SQUAD_DEVKIT_WORKSPACE="$temp/project"
fail() { printf 'FAIL: %s\n' "$*" >&2; cat "$FAKE_LOG" >&2; exit 1; }
touch "$temp/run.log"
printf 'state=completed\nworker=test\nengine=grok\nlog=%s\n' "$temp/run.log" >"$temp/status"
for handle in term_mon mgr; do
  : >"$FAKE_LOG"
  ORCA_TERMINAL_HANDLE="$handle" SQUAD_ORCA_CLOSE_ON_EXIT=1 SQUAD_WORKER_PANE_HOLD=0 bash "$repo/scripts/squad-worker-monitor.sh" "$temp/status" >/dev/null
  if [[ "$handle" == mgr ]]; then
    ! grep -q 'terminal close' "$FAKE_LOG" || fail 'manager monitor closed'
  else
    grep -q 'terminal close --terminal term_mon' "$FAKE_LOG" || fail 'monitor did not close'
  fi
done
: >"$FAKE_LOG"
ORCA_TERMINAL_HANDLE=term_mon SQUAD_ORCA_CLOSE_ON_EXIT=0 SQUAD_WORKER_PANE_HOLD=0 bash "$repo/scripts/squad-worker-monitor.sh" "$temp/status" >/dev/null
! grep -q 'terminal close' "$FAKE_LOG" || fail 'opt-out monitor closed'
for view in orchestration panes; do
  : >"$FAKE_LOG"
  if (cd "$temp/project" && SQUAD_MANAGER_ID=boss SQUAD_WORKER_VIEW="$view" SQUAD_WORKER_MONITOR_WAIT_TICKS=2 bash "$repo/scripts/squad-worker.sh" test --engine grok --no-plan test --no-worktree --brief test </dev/null) >"$temp/out" 2>&1; then fail "$view timeout succeeded"; fi
  grep -q 'monitor did not render or exited' "$temp/out" || { cat "$temp/out" >&2; fail "$view timeout message"; }
  grep -q 'terminal close --terminal term_new' "$FAKE_LOG" || fail "$view timeout close"
  [[ ! -e "$temp/project/.squad/workers/.orca-mgr.last" && ! -e "$temp/project/.squad/workers/.orca-mgr.handles" ]] || fail "$view timeout cache"
done
for handle in term_child mgr; do
  : >"$FAKE_LOG"
  ORCA_TERMINAL_HANDLE="$handle" SQUAD_ORCA_CLOSE_ON_EXIT=1 SQUAD_ORCHESTRATION_LIVE=1 SQUAD_DEVKIT_MANAGER_WRAPPER_PID=99999999 bash "$repo/scripts/squad-orchestration.sh" "$temp/project/.squad/workers" </dev/null >/dev/null
  if [[ "$handle" == mgr ]]; then
    ! grep -q 'terminal close' "$FAKE_LOG" || fail 'orchestration closed manager'
  else
    grep -q 'terminal close --terminal term_child' "$FAKE_LOG" || fail 'orchestration did not close'
  fi
done
 : >"$FAKE_LOG"
ORCA_TERMINAL_HANDLE=term_child SQUAD_ORCA_CLOSE_ON_EXIT=1 SQUAD_ORCHESTRATION_LIVE=1 SQUAD_WORKER_MONITOR_READY="$temp/ready" bash "$repo/scripts/squad-orchestration.sh" "$temp/project/.squad/workers" </dev/null >"$temp/orch.out" 2>&1 &
orch_pid=$!
for _ in $(seq 1 100); do [[ -f "$temp/ready" ]] && break; sleep 0.1; done
[[ -f "$temp/ready" ]] || { kill "$orch_pid" 2>/dev/null || true; fail 'orchestration readiness'; }
kill -HUP "$orch_pid"
sleep 1
! grep -q 'terminal close' "$FAKE_LOG" || fail 'HUP closed pane'
kill -TERM "$orch_pid"
wait "$orch_pid" 2>/dev/null || true
[[ "$(grep -c 'terminal close --terminal term_child' "$FAKE_LOG")" == 1 ]] || fail 'orchestration final close'
git -C "$temp/project" init -q
cat >"$temp/list.json" <<'JSON'
{"ok":true,"result":{"terminals":[{"handle":"mgr","tabId":"tab","paneTitle":"manager"},{"handle":"stale","tabId":"tab","paneTitle":"squad · manager-4","connected":false},{"handle":"user","tabId":"tab","paneTitle":"shell","connected":false},{"handle":"other","tabId":"other","paneTitle":"squad · manager-4","connected":false}]}}
JSON
cat >"$temp/bin/pgrep" <<'FAKE'
#!/usr/bin/env bash
exit 1
FAKE
chmod +x "$temp/bin/pgrep"
: >"$FAKE_LOG"
reload_out="$(cd "$temp/project" && FAKE_LIST="$temp/list.json" bash "$repo/scripts/squad-devkit.sh" reload 2>&1)" || { printf '%s\n' "$reload_out" >&2; fail 'reload failed'; }
[[ "$reload_out" == *'stale squad panes closed'* ]] || fail 'reload count'
grep -q 'terminal close --terminal stale' "$FAKE_LOG" || fail 'reload stale pane'
! grep -Eq 'terminal close --terminal (mgr|user|other)' "$FAKE_LOG" || fail 'reload closed unrelated pane'
: >"$FAKE_LOG"
output="$(cd "$temp/project" && bash "$repo/scripts/squad-devkit.sh" --doctor --split-test 2>&1)" || fail 'doctor failed'
[[ "$output" == *'split test opened'* ]] || fail 'doctor output'
command_line="$(sed -n 's/^.* --command //p' "$FAKE_LOG" | head -n 1)"
test_script="$(find "$temp" -name test.sh -print | head -n 1)"
[[ -n "$command_line" && -n "$test_script" ]] || fail 'doctor script missing'
: >"$FAKE_LOG"
ORCA_TERMINAL_HANDLE=term_test bash "$test_script" >/dev/null
grep -q 'terminal close --terminal term_test' "$FAKE_LOG" || fail 'doctor pane not closed'
[[ ! -e "$test_script" ]] || fail 'doctor directory not removed'
 : >"$FAKE_LOG"
output="$(cd "$temp/project" && bash "$repo/scripts/squad-devkit.sh" --doctor --split-test 2>&1)" || fail 'second doctor failed'
test_script="$(find "$temp" -name test.sh -print | head -n 1)"
[[ -n "$test_script" ]] || fail 'second doctor script missing'
: >"$FAKE_LOG"
ORCA_TERMINAL_HANDLE=mgr bash "$test_script" >/dev/null
! grep -q 'terminal close' "$FAKE_LOG" || fail 'doctor closed manager'
printf 'squad orca lifecycle smoke ok\n'
