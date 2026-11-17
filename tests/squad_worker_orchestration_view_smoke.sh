#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

unset SQUAD_DEVKIT_WORKSPACE SQUAD_WORKTREE_WORKSPACE SQUAD_MANAGER_ID SQUAD_DEVKIT_YOLO SQUAD_WORKER_VIEW
unset SQUAD_DEVKIT_MANAGER_WRAPPER_PID SQUAD_DEVKIT_SESSION_START SQUAD_WORKER_PANES SQUAD_WORKER_PANE_HOLD
unset TMUX TMUX_PANE SQUAD_DEVKIT_ORCA_TERMINAL ORCA_PANE_KEY ORCA_CLI_COMMAND ORCA_DEV_REPO_ROOT
unset HERDR_ENV HERDR_PANE_ID HERDR_SOCKET_PATH HC_TERMINAL_ID HC_TERMINAL_SOCKET HC_SCOPE ZELLIJ ZELLIJ_SESSION_NAME
unset WEZTERM_PANE KITTY_WINDOW_ID ITERM_SESSION_ID SQUAD_DEVKIT_GHOSTTY_TERMINAL DISPLAY WAYLAND_DISPLAY

export TERM_PROGRAM=test-terminal
export TEST_PID="$$"

cp -R "$root/scripts" "$tmp/scripts"
cp -R "$root/templates" "$tmp/templates"

cat >"$tmp/scripts/squad-orchestration.sh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$tmp/scripts/squad-orchestration.sh"

cat >"$tmp/scripts/squad-submanager.sh" <<'SMEOF'
#!/usr/bin/env bash
printf '{"type":"result","usage":{"input_tokens":400,"output_tokens":100}}\n' >>"$SQUAD_SM_LOG"
printf 'stub report\n' >"$SQUAD_SM_REPORT"
exit 0
SMEOF
chmod +x "$tmp/scripts/squad-submanager.sh"

mkdir -p "$tmp/bin" "$tmp/home/.config/squad-devkit" "$tmp/project/.squad"
export HOME="$tmp/home"
export XDG_CONFIG_HOME="$HOME/.config"
export SQUAD_DEVKIT_CONFIG="$HOME/.config/squad-devkit/config"
git init -q "$tmp/project"

cat >"$tmp/bin/squad" <<'FAKE'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  'join '*) printf 'Joined as %s (role: dev)\n' "$2" ;;
  'task create') echo 'Created task task-1 for worker' ;;
  'help '*) echo '--client <claude|codex|gemini|opencode|grok|agy|ccr>' ;;
  '--version '*) echo 'squad 0.7.6' ;;
esac
FAKE
cat >"$tmp/bin/grok" <<'FAKE'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
  echo "grok 1.0"
  exit 0
fi
echo report
FAKE
cat >"$tmp/bin/tmux" <<'FAKE'
#!/usr/bin/env bash
case "${1:-}" in
  -V) echo "tmux 3.4" ;;
  split-window)
    printf '%s\n' "$*" >>"$TEST_SPLITS"
    script="${@: -1}"
    if [[ -f "$script" ]]; then
      ready="$(sed -n 's/^export SQUAD_WORKER_MONITOR_READY=//p' "$script")"
      if [[ -n "$ready" ]]; then
        printf '%s\n' "${TEST_PID:-$PPID}" >"$ready"
      fi
    fi
    echo "%1"
    ;;
  select-pane|select-layout)
    [[ "${1:-}" == select-pane ]] && printf '%s\n' "$*" >>"$TEST_TITLES"
    exit 0
    ;;
esac
exit 0
FAKE
for cli in claude codex gemini opencode ccr; do
  cat >"$tmp/bin/$cli" <<FAKE
#!/usr/bin/env bash
echo "$cli 1.0"
FAKE
done
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH"
export TEST_SPLITS="$tmp/splits"
export TEST_TITLES="$tmp/titles"

cd "$tmp/project"
export TMUX=fake TMUX_PANE=%1

# 1. SQUAD_MANAGER_ID unset, --manager m-a, 3 workers -> exactly 1 split-window call; status files have manager=m-a.
unset SQUAD_MANAGER_ID SQUAD_DEVKIT_MANAGER_WRAPPER_PID SQUAD_WORKER_VIEW
: >"$TEST_SPLITS"
: >"$TEST_TITLES"
rm -rf "$tmp/project/.squad/workers"
"$tmp/scripts/squad-worker.sh" ma-1 --engine grok --manager m-a --no-plan "test1" --no-worktree --brief "ma-1 task" >/dev/null
"$tmp/scripts/squad-worker.sh" ma-2 --engine grok --manager m-a --no-plan "test1" --no-worktree --brief "ma-2 task" >/dev/null
"$tmp/scripts/squad-worker.sh" ma-3 --engine grok --manager m-a --no-plan "test1" --no-worktree --brief "ma-3 task" >/dev/null

[[ "$(wc -l <"$TEST_SPLITS" | tr -d ' ')" == 1 ]]
marker_ma="$tmp/project/.squad/workers/.orchestration-m-m-a.pid"
[[ -f "$marker_ma" ]]
[[ "$(cat "$marker_ma")" == "$TEST_PID" ]]
grep -q 'squad · m-a' "$TEST_TITLES"
ma1_status="$(ls -t "$tmp/project/.squad/workers"/ma-1-*.status | head -n 1)"
ma2_status="$(ls -t "$tmp/project/.squad/workers"/ma-2-*.status | head -n 1)"
ma3_status="$(ls -t "$tmp/project/.squad/workers"/ma-3-*.status | head -n 1)"
grep -qx 'manager=m-a' "$ma1_status"
grep -qx 'manager=m-a' "$ma2_status"
grep -qx 'manager=m-a' "$ma3_status"

# 2. Two managers m-a and m-b in the same workspace -> 2 split calls total, two distinct markers and launchers.
# m-a already launched workers above (1 split, marker .orchestration-m-m-a.pid).
# Now m-b launches workers in the same workspace:
"$tmp/scripts/squad-worker.sh" mb-1 --engine grok --manager m-b --no-plan "test2" --no-worktree --brief "mb-1 task" >/dev/null
marker_mb="$tmp/project/.squad/workers/.orchestration-m-m-b.pid"
[[ -f "$marker_mb" ]]
[[ "$marker_ma" != "$marker_mb" ]]
[[ "$(wc -l <"$TEST_SPLITS" | tr -d ' ')" == 2 ]]
grep -q 'squad · m-b' "$TEST_TITLES"
"$tmp/scripts/squad-worker.sh" mb-2 --engine grok --manager m-b --no-plan "test2" --no-worktree --brief "mb-2 task" >/dev/null
[[ "$(wc -l <"$TEST_SPLITS" | tr -d ' ')" == 2 ]]

# Distinct launcher files for m-a and m-b embedding their respective SQUAD_MANAGER_ID
launcher_ma="$tmp/project/.squad/workers/orchestration-m-m-a.sh"
launcher_mb="$tmp/project/.squad/workers/orchestration-m-m-b.sh"
[[ -f "$launcher_ma" ]]
[[ -f "$launcher_mb" ]]
[[ "$launcher_ma" != "$launcher_mb" ]]
grep -qE 'export SQUAD_MANAGER_ID=['"'"'"]?m-a['"'"'"]?' "$launcher_ma"
grep -qE 'export SQUAD_MANAGER_ID=['"'"'"]?m-b['"'"'"]?' "$launcher_mb"

# 3. SQUAD_WORKER_VIEW=orchestration-branches with a parent sub-manager and a child -> still 1 split per manager.
rm -rf "$tmp/project/.squad/workers"
: >"$TEST_SPLITS"
: >"$TEST_TITLES"
export SQUAD_WORKER_VIEW=orchestration-branches
"$tmp/scripts/squad-worker.sh" sm-1 --engine claude --role sub-manager --manager m-a --no-plan "test3" --no-worktree --brief "sub-manager task" >/dev/null
[[ "$(wc -l <"$TEST_SPLITS" | tr -d ' ')" == 1 ]]
[[ -f "$tmp/project/.squad/workers/.orchestration-m-m-a.pid" ]]
[[ -f "$tmp/project/.squad/workers/orchestration-m-m-a.sh" ]]

# Child of sub-manager reuses m-a's live marker without a new split:
"$tmp/scripts/squad-worker.sh" child-1 --engine grok --manager sm-1 --parent sm-1 --no-plan "test3 child" --no-worktree --brief "child task" >/dev/null
[[ "$(wc -l <"$TEST_SPLITS" | tr -d ' ')" == 1 ]]
# Confirm no .orchestration-branch-* marker was created
[[ -z "$(ls "$tmp/project/.squad/workers"/.orchestration-branch-* 2>/dev/null)" ]]

# Child launched when manager marker is not live -> launcher exports SQUAD_MANAGER_ID=m-a
rm -f "$tmp/project/.squad/workers/.orchestration-m-m-a.pid"
rm -f "$tmp/project/.squad/workers/orchestration-m-m-a.sh"
unset SQUAD_MANAGER_ID
"$tmp/scripts/squad-worker.sh" child-2 --engine grok --manager sm-1 --parent sm-1 --no-plan "test3 child2" --no-worktree --brief "child2 task" >/dev/null
[[ -f "$tmp/project/.squad/workers/orchestration-m-m-a.sh" ]]
grep -qE 'export SQUAD_MANAGER_ID=['"'"'"]?m-a['"'"'"]?' "$tmp/project/.squad/workers/orchestration-m-m-a.sh"

# Child launched with SQUAD_MANAGER_ID=sm-1 in env -> still resolves and exports root manager m-a
rm -f "$tmp/project/.squad/workers/.orchestration-m-m-a.pid"
rm -f "$tmp/project/.squad/workers/orchestration-m-m-a.sh"
SQUAD_MANAGER_ID=sm-1 "$tmp/scripts/squad-worker.sh" child-3 --engine grok --manager sm-1 --parent sm-1 --no-plan "test3 child3" --no-worktree --brief "child3 task" >/dev/null
[[ -f "$tmp/project/.squad/workers/orchestration-m-m-a.sh" ]]
grep -qE 'export SQUAD_MANAGER_ID=['"'"'"]?m-a['"'"'"]?' "$tmp/project/.squad/workers/orchestration-m-m-a.sh"

# 4. SQUAD_WORKER_VIEW=panes -> one split per worker (unchanged).
rm -rf "$tmp/project/.squad/workers"
: >"$TEST_SPLITS"
export SQUAD_WORKER_VIEW=panes
export SQUAD_WORKER_PANE_HOLD=1
"$tmp/scripts/squad-worker.sh" p1 --engine grok --manager m-a --no-plan "test4" --no-worktree --brief "p1 task" >/dev/null
[[ "$(wc -l <"$TEST_SPLITS" | tr -d ' ')" == 1 ]]
"$tmp/scripts/squad-worker.sh" p2 --engine grok --manager m-a --no-plan "test4" --no-worktree --brief "p2 task" >/dev/null
[[ "$(wc -l <"$TEST_SPLITS" | tr -d ' ')" == 2 ]]
"$tmp/scripts/squad-worker.sh" p3 --engine grok --manager m-a --no-plan "test4" --no-worktree --brief "p3 task" >/dev/null
[[ "$(wc -l <"$TEST_SPLITS" | tr -d ' ')" == 3 ]]

# 5. SQUAD_DEVKIT_MANAGER_WRAPPER_PID set -> marker is .orchestration-<wrapper pid>.pid
rm -rf "$tmp/project/.squad/workers"
: >"$TEST_SPLITS"
: >"$TEST_TITLES"
unset SQUAD_WORKER_VIEW
export SQUAD_DEVKIT_MANAGER_WRAPPER_PID="$$"
export SQUAD_DEVKIT_SESSION_START=1700000000
"$tmp/scripts/squad-worker.sh" orch-w1 --engine grok --manager boss --no-plan "wrapper test" --no-worktree --brief "w1 task" >/dev/null
marker_wrapper="$tmp/project/.squad/workers/.orchestration-$$.pid"
[[ -f "$marker_wrapper" ]]
[[ "$(wc -l <"$TEST_SPLITS" | tr -d ' ')" == 1 ]]
grep -q 'squad · boss' "$TEST_TITLES"
grep -q 'export SQUAD_DEVKIT_MANAGER_WRAPPER_PID=' "$tmp/project/.squad/workers/orchestration-$$.sh"
grep -q 'export SQUAD_DEVKIT_SESSION_START=' "$tmp/project/.squad/workers/orchestration-$$.sh"
grep -q 'export SQUAD_MANAGER_ID=' "$tmp/project/.squad/workers/orchestration-$$.sh"
! grep -q 'SQUAD_WORKER_PANE_HOLD' "$tmp/project/.squad/workers/orchestration-$$.sh"

"$tmp/scripts/squad-worker.sh" orch-w2 --engine grok --manager boss --no-plan "wrapper test" --no-worktree --brief "w2 task" >/dev/null
[[ "$(wc -l <"$TEST_SPLITS" | tr -d ' ')" == 1 ]]
unset SQUAD_DEVKIT_MANAGER_WRAPPER_PID SQUAD_DEVKIT_SESSION_START

# 6. SQUAD_WORKER_VIEW=bogus: exit 2 with the validation message.
status=0
SQUAD_WORKER_VIEW=bogus "$tmp/scripts/squad-worker.sh" bogus-1 \
  --engine grok --manager boss --no-plan "bogus smoke" --no-worktree --brief "bad view" >"$tmp/bogus-out" 2>&1 || status=$?
[[ "$status" == 2 ]]
grep -q 'SQUAD_WORKER_VIEW must be orchestration or panes' "$tmp/bogus-out"

# 7. squad-devkit.sh --dry-run and --doctor report view & source.
"$tmp/scripts/squad-devkit.sh" "$tmp/project" --dry-run --manager grok --view panes >"$tmp/devkit-ok" 2>&1
grep '^manager:' "$tmp/devkit-ok" | grep -q 'SQUAD_WORKER_VIEW=panes'
"$tmp/scripts/squad-devkit.sh" "$tmp/project" --dry-run --manager grok >"$tmp/devkit-default" 2>&1
grep '^manager:' "$tmp/devkit-default" | grep -q 'SQUAD_WORKER_VIEW=orchestration'
"$tmp/scripts/squad-devkit.sh" --dry-run --manager grok --view=orchestration >"$tmp/devkit-eq" 2>&1
status=0
"$tmp/scripts/squad-devkit.sh" --dry-run --manager grok --view bogus >"$tmp/devkit-bad" 2>&1 || status=$?
[[ "$status" == 2 ]]
grep -q 'SQUAD_WORKER_VIEW must be orchestration or panes' "$tmp/devkit-bad"

doctor_default="$("$tmp/scripts/squad-devkit.sh" --doctor)"
grep -q '  View: orchestration (default)' <<<"$doctor_default"
doctor_flag="$("$tmp/scripts/squad-devkit.sh" --doctor --view panes)"
grep -q '  View: panes (flag)' <<<"$doctor_flag"
doctor_env="$(SQUAD_WORKER_VIEW=panes "$tmp/scripts/squad-devkit.sh" --doctor)"
grep -q '  View: panes (env)' <<<"$doctor_env"
printf 'view=panes\n' >"$SQUAD_DEVKIT_CONFIG"
doctor_cfg="$("$tmp/scripts/squad-devkit.sh" --doctor)"
grep -q '  View: panes (config)' <<<"$doctor_cfg"
rm -f "$SQUAD_DEVKIT_CONFIG"

# 8. Dashboard fallback in orchestration mode opens orchestration-m-manager.sh instead of dashboard.sh.
cat >"$tmp/bin/osascript" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TEST_OSASCRIPT"
FAKE
chmod +x "$tmp/bin/osascript"
export TEST_OSASCRIPT="$tmp/osascript"
unset TMUX TMUX_PANE SQUAD_MANAGER_ID
rm -rf "$tmp/project/.squad/workers"
TERM_PROGRAM=Apple_Terminal SQUAD_DEVKIT_OSASCRIPT="$tmp/bin/osascript" SQUAD_WORKER_VIEW=orchestration \
  "$tmp/scripts/squad-worker.sh" dash-1 --engine grok --no-plan "dash smoke" --no-worktree --brief "dash task" >"$tmp/out-dash" 2>&1
grep -q 'orchestration-m-manager\.sh' "$TEST_OSASCRIPT"
! grep -q 'dashboard\.sh' "$TEST_OSASCRIPT"

# 9. View resolution fallbacks:
# (a) SQUAD_WORKER_VIEW unset, SQUAD_MANAGER_ID set, temp config without view -> orchestration
export TMUX=fake TMUX_PANE=%1
export SQUAD_DEVKIT_MANAGER_WRAPPER_PID="$$"
export SQUAD_MANAGER_ID="boss"
unset SQUAD_WORKER_VIEW
rm -f "$SQUAD_DEVKIT_CONFIG"
rm -rf "$tmp/project/.squad/workers"
: >"$TEST_SPLITS"
: >"$TEST_TITLES"
"$tmp/scripts/squad-worker.sh" fb-orch-1 \
  --engine grok --manager boss --no-plan "fallback orch smoke" --no-worktree --brief "fb orch" >"$tmp/out-fb-orch" 2>&1
[[ -f "$marker_wrapper" ]]
[[ "$(wc -l <"$TEST_SPLITS" | tr -d ' ')" == 1 ]]
grep -q 'squad · boss' "$TEST_TITLES"

# (b) Config view=panes with SQUAD_WORKER_VIEW unset -> panes
printf 'view=panes\n' >"$SQUAD_DEVKIT_CONFIG"
: >"$TEST_SPLITS"
: >"$TEST_TITLES"
rm -rf "$tmp/project/.squad/workers"
export SQUAD_WORKER_PANE_HOLD=1
"$tmp/scripts/squad-worker.sh" fb-pane-1 \
  --engine grok --manager boss --no-plan "fallback pane smoke" --no-worktree --brief "fb pane" >"$tmp/out-fb-pane" 2>&1
[[ ! -f "$marker_wrapper" ]]
[[ "$(wc -l <"$TEST_SPLITS" | tr -d ' ')" == 1 ]]
! grep -q 'squad · ' "$TEST_TITLES"

# (c) Env overrides config:
# Config view=panes, env SQUAD_WORKER_VIEW=orchestration -> orchestration
: >"$TEST_SPLITS"
: >"$TEST_TITLES"
rm -rf "$tmp/project/.squad/workers"
SQUAD_WORKER_VIEW=orchestration "$tmp/scripts/squad-worker.sh" fb-env-orch \
  --engine grok --manager boss --no-plan "env override smoke" --no-worktree --brief "env orch" >"$tmp/out-fb-env-orch" 2>&1
[[ -f "$marker_wrapper" ]]
[[ "$(wc -l <"$TEST_SPLITS" | tr -d ' ')" == 1 ]]
grep -q 'squad · boss' "$TEST_TITLES"

# Config view=orchestration, env SQUAD_WORKER_VIEW=panes -> panes
printf 'view=orchestration\n' >"$SQUAD_DEVKIT_CONFIG"
: >"$TEST_SPLITS"
: >"$TEST_TITLES"
rm -rf "$tmp/project/.squad/workers"
SQUAD_WORKER_VIEW=panes "$tmp/scripts/squad-worker.sh" fb-env-pane \
  --engine grok --manager boss --no-plan "env override pane" --no-worktree --brief "env pane" >"$tmp/out-fb-env-pane" 2>&1
[[ ! -f "$marker_wrapper" ]]
[[ "$(wc -l <"$TEST_SPLITS" | tr -d ' ')" == 1 ]]
! grep -q 'squad · ' "$TEST_TITLES"
rm -f "$SQUAD_DEVKIT_CONFIG"

# (d) --parent without SQUAD_MANAGER_ID defaults to orchestration
unset SQUAD_MANAGER_ID SQUAD_DEVKIT_MANAGER_WRAPPER_PID SQUAD_WORKER_VIEW
rm -rf "$tmp/project/.squad/workers"
: >"$TEST_SPLITS"
: >"$TEST_TITLES"
"$tmp/scripts/squad-worker.sh" root-w --engine grok --no-plan "t" --no-worktree --brief "root task" >/dev/null
# root-w without manager or parent gets panes:
[[ "$(wc -l <"$TEST_SPLITS" | tr -d ' ')" == 1 ]]
! grep -q 'squad · ' "$TEST_TITLES"

# child with --parent defaults to orchestration:
"$tmp/scripts/squad-worker.sh" child-w --engine grok --parent root-w --no-plan "t" --no-worktree --brief "child task" >/dev/null
grep -q 'squad · manager' "$TEST_TITLES"
[[ -f "$tmp/project/.squad/workers/.orchestration-m-manager.pid" ]]
[[ -f "$tmp/project/.squad/workers/orchestration-m-manager.sh" ]]

echo "PASS: squad_worker_orchestration_view_smoke"
