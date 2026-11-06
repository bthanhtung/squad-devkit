#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
temp="$(mktemp -d /tmp/squad-routing.XXXXXX)"
trap 'rm -rf "$temp"' EXIT
mkdir -p "$temp/bin" "$temp/state"
export ROUTING_LOG="$temp/log"
for cli in herdr tmux orca; do
  cat >"$temp/bin/$cli" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$0 $*" >>"$ROUTING_LOG"
printf '{"result":{"pane":{"pane_id":"w1:p1"}}}\n'
FAKE
  chmod +x "$temp/bin/$cli"
done
export PATH="$temp/bin:$PATH"
unset TMUX TMUX_PANE SQUAD_DEVKIT_ORCA_TERMINAL HERDR_ENV HERDR_PANE_ID HC_TERMINAL_ID
unset ORCA_PANE_KEY ZELLIJ WEZTERM_PANE KITTY_WINDOW_ID ITERM_SESSION_ID SQUAD_DEVKIT_GHOSTTY_TERMINAL
source "$repo/scripts/lib/squad-panes.sh"
squad_panes_tmux() { echo tmux >>"$ROUTING_LOG"; echo tmux-created; }
squad_panes_orca() { echo orca >>"$ROUTING_LOG"; echo orca-created; }
squad_panes_herdr() { echo "herdr:$1" >>"$ROUTING_LOG"; echo herdr-created; }
squad_panes_dashboard() { echo dashboard >>"$ROUTING_LOG"; }
run() { : >"$ROUTING_LOG"; squad_open_monitor /tmp/monitor test "$temp" "$temp/state" /tmp/dashboard; }
export TERM_PROGRAM=Apple_Terminal HERDR_PANE_ID=stale
run
grep -qx dashboard "$ROUTING_LOG"
! grep -q herdr "$ROUTING_LOG"
export HERDR_ENV=1
unset HERDR_PANE_ID
run
grep -q 'pane current --current' "$ROUTING_LOG"
grep -qx herdr:w1:p1 "$ROUTING_LOG"
export HC_TERMINAL_ID=t7
run 2>"$temp/error"
grep -q 'Herdr app/core.*unavailable' "$temp/error"
[[ ! -s "$ROUTING_LOG" ]]
export TMUX=test TMUX_PANE=%1
run
grep -qx tmux "$ROUTING_LOG"
echo 'PASS: native, Herdr TUI, app/core and nested tmux routing'
