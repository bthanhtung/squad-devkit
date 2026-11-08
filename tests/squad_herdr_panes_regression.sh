#!/usr/bin/env bash
set -euo pipefail
unset HC_TERMINAL_ID HC_TERMINAL_SOCKET HC_SCOPE
repo="$(cd "$(dirname "$0")/.." && pwd)"
temp="$(mktemp -d /tmp/squad-herdr-panes.XXXXXX)"
trap 'rm -rf "$temp"' EXIT
mkdir -p "$temp/bin" "$temp/state"
export HERDR_TEST_LOG="$temp/log"
cat >"$temp/bin/herdr" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$HERDR_TEST_LOG"
case "$1 $2" in
  'pane current')
    [[ "${FAIL_CURRENT:-0}" != 1 ]] || exit 1
    printf '{"result":{"pane":{"pane_id":"w1:p1"}}}\n' ;;
  'pane split') printf '{\n "result": {"pane": {"pane_id": "w1:p2"}}\n}\n' ;;
esac
FAKE
chmod +x "$temp/bin/herdr"
export PATH="$temp/bin:$PATH"
unset TMUX TMUX_PANE SQUAD_DEVKIT_ORCA_TERMINAL HERDR_PANE_ID
export HERDR_ENV=1
source "$repo/scripts/lib/squad-panes.sh"
squad_panes_dashboard() { echo dashboard >>"$HERDR_TEST_LOG"; }
squad_open_monitor /tmp/monitor.sh 'test worker' "$temp" "$temp/state" /tmp/dashboard.sh
grep -qx 'pane current --current' "$HERDR_TEST_LOG"
grep -qx "pane split w1:p1 --direction right --cwd $temp --no-focus" "$HERDR_TEST_LOG"
grep -qx 'pane run w1:p2 exec /tmp/monitor.sh' "$HERDR_TEST_LOG"
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
echo 'PASS: Herdr caller resolution, JSON parsing, focus and unresolved caller'
