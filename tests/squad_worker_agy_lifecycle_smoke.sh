#!/usr/bin/env bash
# Native AGY stream lifecycle: terminal SUCCESS + exit 0 completes; everything else fails.
set -euo pipefail
unset HC_TERMINAL_ID HC_TERMINAL_SOCKET HC_SCOPE SQUAD_WORKER_PANES SQUAD_WORKER_PANE_HOLD
unset SQUAD_DEVKIT_ORCA_TERMINAL ORCA_PANE_KEY ORCA_CLI_COMMAND ORCA_DEV_REPO_ROOT
unset SQUAD_DEVKIT_WORKSPACE SQUAD_WORKTREE_WORKSPACE SQUAD_MANAGER_ID SQUAD_DEVKIT_YOLO
unset TMUX TMUX_PANE HERDR_PANE_ID HERDR_ENV HERDR_SOCKET_PATH WEZTERM_PANE KITTY_WINDOW_ID \
  ITERM_SESSION_ID ZELLIJ ZELLIJ_SESSION_NAME DISPLAY WAYLAND_DISPLAY SQUAD_DEVKIT_GHOSTTY_TERMINAL
trap 'echo "Failed at line $LINENO: $BASH_COMMAND" >&2' ERR
fail() { echo "Assertion failed at line ${BASH_LINENO[0]}" >&2; exit 1; }

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temp_directory="$(mktemp -d /tmp/squad-agy-lifecycle.XXXXXX)"
trap 'rm -rf "$temp_directory"' EXIT
export TERM_PROGRAM=test-terminal SQUAD_WORKER_PANES=0
mkdir -p "$temp_directory/project" "$temp_directory/bin" "$temp_directory/home"

# Fake agy: prints $FAKE_STREAM (a file, as-is) and exits $FAKE_EXIT.
cat >"$temp_directory/bin/agy" <<'EOS'
#!/usr/bin/env bash
cat "$FAKE_STREAM"
[[ -z "${FAKE_HANG:-}" ]] || sleep 30
exit "${FAKE_EXIT:-0}"
EOS
chmod +x "$temp_directory/bin/agy"
export HOME="$temp_directory/home"
export PATH="$repo_root/target/debug:$temp_directory/bin:$PATH"
cd "$temp_directory/project"
squad init >/dev/null
cp "$repo_root/templates/devkit/dev.md" .squad/roles/dev.md
squad join manager --role manager-devkit --client claude --protocol-version 2 >/dev/null
worker="$repo_root/scripts/squad-worker.sh"
monitor="$repo_root/scripts/squad-worker-monitor.sh"

init='{"event":"init","init":{"model":"never-actual-evidence"}}'
ok='{"event":"result","result":{"status":"SUCCESS","response":"All done. Verification: ok."}}'
idle='root agent idle; waiting for 1 background task(s) to finish'
# run <name> <exit> <expected state> <expected worker exit> [stream lines...]
run() {
  local name="$1" code="$2" state="$3" wexit="$4" rc=0; shift 4
  printf '%s\n' "$@" >"$temp_directory/stream"
  FAKE_STREAM="$temp_directory/stream" FAKE_EXIT="$code" "$worker" "$name" --engine agy --no-worktree \
    --brief "Lifecycle $name" >"$temp_directory/out" 2>&1 || rc=$?
  [[ "$rc" == "$wexit" ]] || { cat "$temp_directory/out" >&2; fail; }
  local sf; sf="$(ls .squad/workers/"$name"-*.status)"
  grep -qx "state=$state" "$sf" || { cat "$sf" >&2; fail; }
  grep -qx "exit=$wexit" "$sf" || fail
  [[ "$("$monitor" "$sf" --once)" == *"$(printf '%s' "$state" | tr '[:lower:]' '[:upper:]')"* ]] || fail
  local lf inbox; lf=(.squad/workers/"$name"-*.log)
  inbox="$(squad receive manager 2>&1)"
  [[ "$inbox" == *"$name"* ]] || { echo "$inbox" >&2; fail; }
  if [[ "$state" == completed ]]; then
    grep -q 'All done' .squad/workers/"$name"-*.md || fail
    [[ "$inbox" == *"completed task"* && "$inbox" != *"failed on task"* && "$inbox" != *"stopped by request"* ]] || { echo "$inbox" >&2; fail; }
    ! grep -q 'AGY stream rejected' "${lf[0]}" || fail
  else
    [[ "$inbox" == *"on task"*"(exit status $wexit)"* && "$inbox" != *"completed task"* ]] || { echo "$inbox" >&2; fail; }
    # Parser-level rejections (engine exit 0) must say why in the log.
    if [[ "$code" == 0 && "$state" == failed ]]; then
      grep -q 'AGY stream rejected' "${lf[0]}" || fail
    fi
  fi
}

run native-ok 0 completed 0 "$init" "$idle" "$ok"
run native-exit1 1 failed 1 "$init" "$ok"
run native-error0 0 failed 1 "$init" '{"event":"error","error":{"message":"boom"}}'
run native-error1 1 failed 1 "$init" '{"event":"error","error":{"message":"boom"}}'
run native-failstatus 0 failed 1 "$init" '{"event":"result","result":{"status":"FAILED","response":"nope"}}'
run native-empty 0 failed 1 "$init" '{"event":"result","result":{"status":"SUCCESS","response":"  "}}'
run native-nonstring 0 failed 1 "$init" '{"event":"result","result":{"status":"SUCCESS","response":{"a":1}}}'
run native-missing 0 failed 1 "$init" "$idle"
run native-truncated 0 failed 1 "$init" '{"event":"result","result":{"status":"SUCCESS","resp'
run native-malformed 0 failed 1 "$init" "$ok" '{"event":'
run native-duplicate 0 failed 1 "$init" "$ok" "$ok"
run native-trailing 0 failed 1 "$init" "$ok" '{"event":"error","error":"late"}'
run native-after 0 failed 1 "$init" "$ok" '{"event":"step_update","step_update":{}}'
run legacy-claude 0 completed 0 '{"type":"result","result":"All done. legacy"}'
run legacy-plain 0 completed 0 'All done. plain text'
run native-ws-malformed 0 failed 1 "$init" "$ok" '  {broken'
run native-array 0 failed 1 "$init" "$ok" '[1,2]'
run native-ws-array 0 failed 1 "$init" '  [{"event":"result"}]' "$ok"
run legacy-null 0 failed 1 'null'
run legacy-array 0 failed 1 '[]'
run legacy-scalar 0 failed 1 '123'
run native-null 0 failed 1 "$init" "$ok" 'null'
run diag-only 0 failed 1 "$idle"
run legacy-damaged 0 failed 1 '{"type":"result","result":"All d'
grep -q 'AGY stream rejected' .squad/workers/native-truncated-*.log || fail
grep -q 'damaged JSON' .squad/workers/native-ws-malformed-*.log || fail
grep -q 'damaged JSON' .squad/workers/native-array-*.log || fail
grep -q 'terminal status FAILED' .squad/workers/native-failstatus-*.log || fail

# Real supplied log replayed through the fake engine (artifact is only read).
real="$repo_root/.squad/workers/herdr-accept-1-20261106-212338.log"
if [[ -f "$real" ]]; then
  cp "$real" "$temp_directory/stream"
  FAKE_STREAM="$temp_directory/stream" "$worker" real-ok --engine agy --no-worktree --brief real >/dev/null 2>&1
  grep -qx 'state=completed' .squad/workers/real-ok-*.status || fail
  FAKE_STREAM="$temp_directory/stream" FAKE_EXIT=1 "$worker" real-exit1 --engine agy --no-worktree --brief real >/dev/null 2>&1 && fail
  grep -qx 'state=failed' .squad/workers/real-exit1-*.status || fail
fi

squad receive manager >/dev/null 2>&1 || true
# Terminal SUCCESS followed by a hang is still a timeout failure.
printf '%s\n' "$init" "$ok" >"$temp_directory/stream"
FAKE_STREAM="$temp_directory/stream" FAKE_HANG=1 SQUAD_WORKER_TIMEOUT_SECONDS=2 "$worker" native-hang \
  --engine agy --no-worktree --brief hang >/dev/null 2>&1 && fail
grep -qx 'state=failed' .squad/workers/native-hang-*.status || fail
grep -qx 'exit=124' .squad/workers/native-hang-*.status || fail
[[ "$("$monitor" "$(ls .squad/workers/native-hang-*.status)" --once)" == *FAILED* ]] || fail
inbox="$(squad receive manager 2>&1)"
[[ "$inbox" == *native-hang*"timed out"*"(exit status 124)"* && "$inbox" != *"completed task"* ]] || { echo "$inbox" >&2; fail; }

# Explicit stop after terminal SUCCESS: stopped (not completed), monitor STOPPED.
FAKE_STREAM="$temp_directory/stream" FAKE_HANG=1 "$worker" native-stop --engine agy --no-worktree \
  --brief stop >/dev/null 2>&1 &
stop_pid=$!
for _ in $(seq 1 50); do
  grep -qs 'All done' .squad/workers/native-stop-*.log && break
  sleep 0.2
done
grep -qs 'All done' .squad/workers/native-stop-*.log || fail
"$worker" --stop native-stop >/dev/null
stop_rc=0; wait "$stop_pid" || stop_rc=$?
sf="$(ls .squad/workers/native-stop-*.status)"
grep -qx 'state=stopped' "$sf" || { cat "$sf" >&2; fail; }
grep -qx "exit=$stop_rc" "$sf" || { cat "$sf" >&2; fail; }
[[ "$stop_rc" != 0 ]] || fail
[[ "$("$monitor" "$sf" --once)" == *STOPPED* ]] || fail
inbox="$(squad receive manager 2>&1)"
[[ "$inbox" == *native-stop*"stopped by request"* && "$inbox" != *"completed task"* ]] || { echo "$inbox" >&2; fail; }

echo 'PASS: AGY native stream lifecycle'
