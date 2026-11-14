#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
stub_pids="$tmp/stub-pids"
cleanup() {
  if [[ -f "$stub_pids" ]]; then
    while IFS= read -r pid; do
      [[ -n "$pid" ]] || continue
      pkill -9 -P "$pid" 2>/dev/null || true
      kill -9 "$pid" 2>/dev/null || true
    done <"$stub_pids"
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT

unset SQUAD_DEVKIT_WORKSPACE SQUAD_WORKTREE_WORKSPACE SQUAD_MANAGER_ID SQUAD_DEVKIT_YOLO SQUAD_WORKER_VIEW
unset SQUAD_DEVKIT_MANAGER_WRAPPER_PID SQUAD_DEVKIT_SESSION_START SQUAD_WORKER_PANES SQUAD_WORKER_PANE_HOLD
unset TMUX TMUX_PANE SQUAD_DEVKIT_ORCA_TERMINAL ORCA_PANE_KEY ORCA_CLI_COMMAND ORCA_DEV_REPO_ROOT
unset HERDR_ENV HERDR_PANE_ID HERDR_SOCKET_PATH HC_TERMINAL_ID HC_TERMINAL_SOCKET HC_SCOPE ZELLIJ ZELLIJ_SESSION_NAME
unset WEZTERM_PANE KITTY_WINDOW_ID ITERM_SESSION_ID SQUAD_DEVKIT_GHOSTTY_TERMINAL DISPLAY WAYLAND_DISPLAY

cp -R "$root/scripts" "$tmp/scripts"
cp -R "$root/templates" "$tmp/templates"
cat >"$tmp/scripts/squad-orchestration.sh" <<'STUB'
#!/usr/bin/env bash
if [[ -n "${SQUAD_WORKER_MONITOR_READY:-}" ]]; then
  printf '%s\n' "$$" >"$SQUAD_WORKER_MONITOR_READY"
fi
sleep 60
STUB
chmod +x "$tmp/scripts/squad-orchestration.sh"

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
    "$script" </dev/null >/dev/null 2>&1 &
    bg_pid=$!
    printf '%s\n' "$bg_pid" >>"$TEST_STUB_PIDS"
    printf '%%%s\n' "$(wc -l <"$TEST_SPLITS" | tr -d ' ')"
    ;;
  select-pane)
    printf '%s\n' "$*" >>"$TEST_TITLES"
    ;;
esac
FAKE
for cli in claude codex agy gemini opencode ccr; do
  cat >"$tmp/bin/$cli" <<FAKE
#!/usr/bin/env bash
echo "$cli 1.0"
FAKE
done
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH"
export TEST_SPLITS="$tmp/splits"
export TEST_TITLES="$tmp/titles"
export TEST_STUB_PIDS="$stub_pids"

cd "$tmp/project"
export TMUX=fake TMUX_PANE=%1
export SQUAD_DEVKIT_MANAGER_WRAPPER_PID="$$"
export SQUAD_DEVKIT_SESSION_START=1700000000

# (a) SQUAD_WORKER_VIEW=orchestration: two worker runs with the same wrapper PID
# open exactly one split and marker holds a live PID.
: >"$TEST_SPLITS"
: >"$TEST_TITLES"
SQUAD_WORKER_VIEW=orchestration "$tmp/scripts/squad-worker.sh" orch-1 \
  --engine grok --manager boss --no-plan "orchestration smoke" --no-worktree --brief "first task" >"$tmp/out1" 2>&1
marker="$tmp/project/.squad/workers/.orchestration-$$.pid"
[[ -f "$marker" ]]
marker_pid="$(cat "$marker")"
[[ "$marker_pid" =~ ^[1-9][0-9]*$ ]]
kill -0 "$marker_pid" 2>/dev/null
printf '%s\n' "$marker_pid" >>"$TEST_STUB_PIDS"
[[ "$(wc -l <"$TEST_SPLITS" | tr -d ' ')" == 1 ]]
grep -q 'squad orchestration' "$TEST_TITLES"
grep -q 'export SQUAD_DEVKIT_MANAGER_WRAPPER_PID=' "$tmp/project/.squad/workers/orchestration.sh"
grep -q 'export SQUAD_DEVKIT_SESSION_START=' "$tmp/project/.squad/workers/orchestration.sh"
grep -q 'export SQUAD_MANAGER_ID=' "$tmp/project/.squad/workers/orchestration.sh"
! grep -q 'SQUAD_WORKER_PANE_HOLD' "$tmp/project/.squad/workers/orchestration.sh"

SQUAD_WORKER_VIEW=orchestration "$tmp/scripts/squad-worker.sh" orch-2 \
  --engine grok --manager boss --no-plan "orchestration smoke" --no-worktree --brief "second task" >"$tmp/out2" 2>&1
[[ "$(wc -l <"$TEST_SPLITS" | tr -d ' ')" == 1 ]]
[[ "$(cat "$marker")" == "$marker_pid" ]]
kill -0 "$marker_pid" 2>/dev/null

# (b) SQUAD_WORKER_VIEW=orchestration-branches: root + one extra split per parent even with 2 children;
# plain orchestration opens 1 split even when children have --parent.
rm -f "$marker" "$tmp/project/.squad/workers/.orchestration-branch-"*
: >"$TEST_SPLITS"
: >"$TEST_TITLES"
cat >"$tmp/project/.squad/workers/sm-api-20261114-100000.status" <<'EOF'
worker=sm-api
engine=agy
model=gemini-4-argon-high
role=sub-manager
state=running
started=1700000001
parent=
depth=1
budget_tokens=600000
max_children=3
EOF
SQUAD_WORKER_VIEW=orchestration-branches "$tmp/scripts/squad-worker.sh" child-1 \
  --engine grok --manager sm-api --parent sm-api --no-plan "branch smoke" --no-worktree --brief "child one" >"$tmp/out-b1" 2>&1
SQUAD_WORKER_VIEW=orchestration-branches "$tmp/scripts/squad-worker.sh" child-2 \
  --engine grok --manager sm-api --parent sm-api --no-plan "branch smoke" --no-worktree --brief "child two" >"$tmp/out-b2" 2>&1
[[ "$(wc -l <"$TEST_SPLITS" | tr -d ' ')" == 2 ]]
branch_marker="$tmp/project/.squad/workers/.orchestration-branch-sm-api.pid"
[[ -f "$branch_marker" ]]
branch_pid="$(cat "$branch_marker")"
[[ "$branch_pid" =~ ^[1-9][0-9]*$ ]]
kill -0 "$branch_pid" 2>/dev/null
printf '%s\n' "$branch_pid" >>"$TEST_STUB_PIDS"
grep -q -- '--root sm-api' "$tmp/project/.squad/workers/orchestration-branch-sm-api.sh"

# Plain orchestration with --parent opens 1 split (no branch pane).
rm -f "$marker" "$branch_marker"
: >"$TEST_SPLITS"
SQUAD_WORKER_VIEW=orchestration "$tmp/scripts/squad-worker.sh" child-3 \
  --engine grok --manager sm-api --parent sm-api --no-plan "plain orch parent" --no-worktree --brief "child three" >"$tmp/out-b3" 2>&1
[[ "$(wc -l <"$TEST_SPLITS" | tr -d ' ')" == 1 ]]
[[ ! -f "$branch_marker" ]]

# (b2) SQUAD_WORKER_VIEW=panes: one split per run.
: >"$TEST_SPLITS"
export SQUAD_WORKER_PANE_HOLD=1
SQUAD_WORKER_VIEW=panes "$tmp/scripts/squad-worker.sh" pane-1 \
  --engine grok --manager boss --no-plan "panes smoke" --no-worktree --brief "pane one" >"$tmp/out3" 2>&1
SQUAD_WORKER_VIEW=panes "$tmp/scripts/squad-worker.sh" pane-2 \
  --engine grok --manager boss --no-plan "panes smoke" --no-worktree --brief "pane two" >"$tmp/out4" 2>&1
[[ "$(wc -l <"$TEST_SPLITS" | tr -d ' ')" == 2 ]]

# (c) SQUAD_WORKER_VIEW=bogus: exit 2 with the validation message.
status=0
SQUAD_WORKER_VIEW=bogus "$tmp/scripts/squad-worker.sh" bogus-1 \
  --engine grok --manager boss --no-plan "bogus smoke" --no-worktree --brief "bad view" >"$tmp/bogus-out" 2>&1 || status=$?
[[ "$status" == 2 ]]
grep -q 'SQUAD_WORKER_VIEW must be orchestration or panes' "$tmp/bogus-out"

# (d) squad-devkit.sh --dry-run --view panes works, --view bogus exits 2, and --doctor reports view & source.
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

# Dashboard fallback in orchestration mode opens orchestration.sh instead of dashboard.sh.
cat >"$tmp/bin/osascript" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TEST_OSASCRIPT"
FAKE
chmod +x "$tmp/bin/osascript"
export TEST_OSASCRIPT="$tmp/osascript"
unset TMUX TMUX_PANE SQUAD_MANAGER_ID
rm -f "$marker" "$tmp/project/.squad/workers/.dashboard-"* "$tmp/project/.squad/workers/".*.last
TERM_PROGRAM=Apple_Terminal SQUAD_DEVKIT_OSASCRIPT="$tmp/bin/osascript" SQUAD_WORKER_VIEW=orchestration \
  "$tmp/scripts/squad-worker.sh" dash-1 --engine grok --no-plan "dash smoke" --no-worktree --brief "dash task" >"$tmp/out-dash" 2>&1
grep -q 'orchestration\.sh' "$TEST_OSASCRIPT"
! grep -q 'dashboard\.sh' "$TEST_OSASCRIPT"

# (e) View resolution fallback:
# 1. SQUAD_WORKER_VIEW unset, SQUAD_MANAGER_ID set, temp config without view -> orchestration behaviour
export TMUX=fake TMUX_PANE=%1
export SQUAD_DEVKIT_MANAGER_WRAPPER_PID="$$"
export SQUAD_MANAGER_ID="boss"
unset SQUAD_WORKER_VIEW
rm -f "$SQUAD_DEVKIT_CONFIG"
rm -f "$marker"
: >"$TEST_SPLITS"
: >"$TEST_TITLES"
"$tmp/scripts/squad-worker.sh" fb-orch-1 \
  --engine grok --manager boss --no-plan "fallback orch smoke" --no-worktree --brief "fb orch" >"$tmp/out-fb-orch" 2>&1
[[ -f "$marker" ]]
fb_marker_pid="$(cat "$marker")"
printf '%s\n' "$fb_marker_pid" >>"$TEST_STUB_PIDS"
kill -0 "$fb_marker_pid" 2>/dev/null
kill "$fb_marker_pid" 2>/dev/null || true
rm -f "$marker"
[[ "$(wc -l <"$TEST_SPLITS" | tr -d ' ')" == 1 ]]
grep -q 'squad orchestration' "$TEST_TITLES"

# 2. Config view=panes with SQUAD_WORKER_VIEW unset -> panes
printf 'view=panes\n' >"$SQUAD_DEVKIT_CONFIG"
: >"$TEST_SPLITS"
: >"$TEST_TITLES"
export SQUAD_WORKER_PANE_HOLD=1
"$tmp/scripts/squad-worker.sh" fb-pane-1 \
  --engine grok --manager boss --no-plan "fallback pane smoke" --no-worktree --brief "fb pane" >"$tmp/out-fb-pane" 2>&1
[[ ! -f "$marker" ]]
[[ "$(wc -l <"$TEST_SPLITS" | tr -d ' ')" == 1 ]]
! grep -q 'squad orchestration' "$TEST_TITLES"

# 3. Env overrides config:
# (a) Config view=panes, env SQUAD_WORKER_VIEW=orchestration -> orchestration
: >"$TEST_SPLITS"
: >"$TEST_TITLES"
SQUAD_WORKER_VIEW=orchestration "$tmp/scripts/squad-worker.sh" fb-env-orch \
  --engine grok --manager boss --no-plan "env override smoke" --no-worktree --brief "env orch" >"$tmp/out-fb-env-orch" 2>&1
[[ -f "$marker" ]]
fb_override_pid="$(cat "$marker")"
printf '%s\n' "$fb_override_pid" >>"$TEST_STUB_PIDS"
kill -0 "$fb_override_pid" 2>/dev/null
kill "$fb_override_pid" 2>/dev/null || true
rm -f "$marker"
[[ "$(wc -l <"$TEST_SPLITS" | tr -d ' ')" == 1 ]]
grep -q 'squad orchestration' "$TEST_TITLES"

# (b) Config view=orchestration, env SQUAD_WORKER_VIEW=panes -> panes
printf 'view=orchestration\n' >"$SQUAD_DEVKIT_CONFIG"
: >"$TEST_SPLITS"
: >"$TEST_TITLES"
SQUAD_WORKER_VIEW=panes "$tmp/scripts/squad-worker.sh" fb-env-pane \
  --engine grok --manager boss --no-plan "env override pane" --no-worktree --brief "env pane" >"$tmp/out-fb-env-pane" 2>&1
[[ ! -f "$marker" ]]
[[ "$(wc -l <"$TEST_SPLITS" | tr -d ' ')" == 1 ]]
! grep -q 'squad orchestration' "$TEST_TITLES"
rm -f "$SQUAD_DEVKIT_CONFIG"

