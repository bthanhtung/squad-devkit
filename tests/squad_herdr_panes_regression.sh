#!/usr/bin/env bash
set -euo pipefail
unset HC_TERMINAL_ID HC_TERMINAL_SOCKET HC_SCOPE
repo="$(cd "$(dirname "$0")/.." && pwd)"
temp="$(mktemp -d /tmp/squad-herdr-panes.XXXXXX)"
trap 'rm -rf "$temp"' EXIT
mkdir -p "$temp/bin" "$temp/state"
export HERDR_TEST_LOG="$temp/log"
export HERDR_TEMP="$temp"
cat >"$temp/bin/herdr" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$HERDR_TEST_LOG"
case "$1 $2" in
  'pane current')
    [[ "${FAIL_CURRENT:-0}" != 1 ]] || exit 1
    printf '{"result":{"pane":{"pane_id":"w1:p1"}}}\n' ;;
  'pane split') printf '{\n "result": {"pane": {"pane_id": "w1:p2"}}\n}\n' ;;
  'pane list')
    if [[ -f "${HERDR_TEMP:-}/pane-list.json" ]]; then
      cat "${HERDR_TEMP:-}/pane-list.json"
    else
      printf '{"result":{"panes":[]}}\n'
    fi ;;
  'pane process-info')
    pane_id=""
    prev=""
    for arg in "$@"; do
      if [[ "$prev" == "--pane" ]]; then
        pane_id="$arg"
        break
      fi
      prev="$arg"
    done
    fixture="${HERDR_TEMP:-}/pinfo-${pane_id}.json"
    if [[ -n "$pane_id" && -f "$fixture" ]]; then
      cat "$fixture"
    else
      printf '{"result":{}}\n'
    fi ;;
  'pane close')
    exit 0 ;;
esac
FAKE
chmod +x "$temp/bin/herdr"
export PATH="$temp/bin:$PATH"
unset TMUX TMUX_PANE SQUAD_DEVKIT_ORCA_TERMINAL HERDR_PANE_ID
export HERDR_ENV=1

cat >"$temp/pane-list.json" <<'EOF'
{
  "result": {
    "panes": [
      {"pane_id": "w1:p1", "tab_id": "t1", "label": "manager"},
      {"pane_id": "w1:p3", "tab_id": "t1", "label": "squad orchestration"},
      {"pane_id": "w1:p4", "tab_id": "t1", "label": "squad orchestration"},
      {"pane_id": "w1:p5", "tab_id": "t1"},
      {"pane_id": "w1:p6", "tab_id": "t2", "label": "squad orchestration"}
    ]
  }
}
EOF

cat >"$temp/pinfo-w1:p3.json" <<'EOF'
{
  "result": {
    "process_info": {
      "foreground_processes": [{"argv": ["-zsh"], "name": "zsh", "pid": 1290}],
      "shell_pid": 1290
    }
  }
}
EOF

cat >"$temp/pinfo-w1:p4.json" <<'EOF'
{
  "result": {
    "process_info": {
      "foreground_processes": [{"argv": ["bash", "squad-orchestration.sh"], "name": "squad-orchestration.sh", "pid": 1300}],
      "shell_pid": 1290
    }
  }
}
EOF

cat >"$temp/pinfo-w1:p5.json" <<'EOF'
{
  "result": {
    "process_info": {
      "foreground_processes": [{"argv": ["-zsh"], "name": "zsh", "pid": 1295}],
      "shell_pid": 1295
    }
  }
}
EOF

cat >"$temp/pinfo-w1:p6.json" <<'EOF'
{
  "result": {
    "process_info": {
      "foreground_processes": [{"argv": ["-zsh"], "name": "zsh", "pid": 1296}],
      "shell_pid": 1296
    }
  }
}
EOF

source "$repo/scripts/lib/squad-panes.sh"
squad_panes_dashboard() { echo dashboard >>"$HERDR_TEST_LOG"; }
squad_open_monitor /tmp/monitor.sh 'test worker' "$temp" "$temp/state" /tmp/dashboard.sh
grep -qx 'pane current --current' "$HERDR_TEST_LOG"
grep -qx "pane split w1:p1 --direction right --cwd $temp --no-focus" "$HERDR_TEST_LOG"
grep -qx 'pane run w1:p2 exec /tmp/monitor.sh' "$HERDR_TEST_LOG"
grep -qx 'pane close w1:p3' "$HERDR_TEST_LOG"
[[ "$(grep -c '^pane close' "$HERDR_TEST_LOG")" -eq 1 ]]
[[ "${SQUAD_PANES_REAPED:-0}" -eq 1 ]]
[[ "$(cat "$temp/state/.herdr-w1_p1.last")" == w1:p2 ]]
: >"$HERDR_TEST_LOG"
export HERDR_PANE_ID=w1:p1
squad_open_monitor /tmp/monitor.sh 'test worker' "$temp" "$temp/state" /tmp/dashboard.sh
! grep -q 'pane current' "$HERDR_TEST_LOG"
grep -qx "pane split w1:p2 --direction down --cwd $temp --no-focus" "$HERDR_TEST_LOG"
: >"$HERDR_TEST_LOG"
unset HERDR_PANE_ID
export FAIL_CURRENT=1
squad_open_monitor /tmp/monitor.sh 'test worker' "$temp" "$temp/state" /tmp/dashboard.sh
! grep -q 'pane split' "$HERDR_TEST_LOG"
grep -qx dashboard "$HERDR_TEST_LOG"

# Empty or missing pane list fixture does not break or close anything
: >"$HERDR_TEST_LOG"
echo '{"result":{"panes":[]}}' >"$temp/pane-list.json"
SQUAD_PANES_REAPED=0
squad_panes_herdr_reap_stale w1:p1
[[ "$SQUAD_PANES_REAPED" -eq 0 ]]
! grep -q 'pane close' "$HERDR_TEST_LOG"

: >"$HERDR_TEST_LOG"
: >"$temp/pane-list.json"
squad_panes_herdr_reap_stale w1:p1
[[ "$SQUAD_PANES_REAPED" -eq 0 ]]
! grep -q 'pane close' "$HERDR_TEST_LOG"

: >"$HERDR_TEST_LOG"
rm -f "$temp/pane-list.json"
squad_panes_herdr_reap_stale w1:p1
[[ "$SQUAD_PANES_REAPED" -eq 0 ]]
! grep -q 'pane close' "$HERDR_TEST_LOG"

echo 'PASS: Herdr caller resolution, JSON parsing, focus and unresolved caller'
