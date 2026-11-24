#!/usr/bin/env bash
set -euo pipefail
export SQUAD_WORKER_VIEW=panes SQUAD_DEVKIT_NOTIFY=0
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

unset SQUAD_WORKER_HEADLESS TERM_PROGRAM
unset SQUAD_DEVKIT_WORKSPACE SQUAD_WORKTREE_WORKSPACE SQUAD_MANAGER_ID SQUAD_DEVKIT_YOLO
unset TMUX TMUX_PANE SQUAD_DEVKIT_ORCA_TERMINAL ORCA_PANE_KEY ORCA_CLI_COMMAND ORCA_DEV_REPO_ROOT
unset HERDR_ENV HERDR_PANE_ID HERDR_SOCKET_PATH HC_TERMINAL_ID HC_TERMINAL_SOCKET HC_SCOPE SQUAD_WORKER_PANE_HOLD ZELLIJ ZELLIJ_SESSION_NAME
unset WEZTERM_PANE KITTY_WINDOW_ID ITERM_SESSION_ID SQUAD_DEVKIT_GHOSTTY_TERMINAL DISPLAY WAYLAND_DISPLAY
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
echo called >>"$TEST_ENGINE"
[[ -z "${TEST_ENGINE_FAIL:-}" ]] || exit 3
echo report
FAKE
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH" TEST_MESSAGES="$tmp/messages" TEST_ENGINE="$tmp/engine"
cd "$tmp/project"
for mode in flag env; do
  args=(--manager boss)
  unset SQUAD_MANAGER_ID SQUAD_WORKER_HEADLESS
  if [[ "$mode" == flag ]]; then
    args+=(--headless)
  else
    args=()
    export SQUAD_MANAGER_ID=boss SQUAD_WORKER_HEADLESS=1
  fi
  SQUAD_WORKER_PANES=0 "$root/scripts/squad-worker.sh" "$mode" --engine grok --no-plan "headless smoke" --no-worktree --brief test --verify true ${args[@]+"${args[@]}"} </dev/null >"$tmp/out" 2>&1 || { cat "$tmp/out" >&2; exit 1; }
  status=(.squad/workers/"$mode"-*.status)
  grep -qx 'headless=1' "${status[0]}"
  grep -qx 'state=completed' "${status[0]}"
  events="${status[0]%.status}.events.jsonl"
  jq -se 'map(.event) == ["started", "verify", "completed"] and all(.[]; has("timestamp") and has("worker") and has("engine") and has("state") and has("exit_code"))' "$events" >/dev/null
  for ready in .squad/workers/.monitor-ready.*; do [[ ! -e "$ready" ]]; done
done
unset SQUAD_WORKER_HEADLESS SQUAD_MANAGER_ID
for mode in flag env; do
  status=(.squad/workers/"$mode"-*.status)
  args=()
  if [[ "$mode" == env ]]; then
    sed 's/^headless=1$/headless=0/' "${status[0]}" >"$tmp/status"
    mv "$tmp/status" "${status[0]}"
    args+=(--headless)
  fi
  sed 's/^state=completed$/state=lost/' "${status[0]}" >"$tmp/status"
  mv "$tmp/status" "${status[0]}"
  SQUAD_MANAGER_ID=boss SQUAD_WORKER_PANES=0 "$root/scripts/squad-worker.sh" --resume "$mode" ${args[@]+"${args[@]}"} </dev/null >"$tmp/out" 2>&1 || { cat "$tmp/out" >&2; exit 1; }
  resumed="$(ls -t .squad/workers/"$mode"-*.status | head -n 1)"
  grep -qx 'headless=1' "$resumed"
  grep -qx 'state=completed' "$resumed"
done
for ci in true 1; do
  if CI="$ci" "$root/scripts/squad-worker.sh" "pane-$ci" --manager boss --engine grok --no-plan "headless smoke" --no-worktree --brief test </dev/null >"$tmp/out" 2>&1; then
    echo 'manager ran without explicit headless or a split terminal' >&2; exit 1
  fi
  grep -qx 'state=failed' .squad/workers/"pane-$ci"-*.status
done
if TEST_ENGINE_FAIL=1 "$root/scripts/squad-worker.sh" failed --headless --manager boss --engine grok --no-plan "headless smoke" --no-worktree --brief test </dev/null >"$tmp/out" 2>&1; then
  echo 'failing engine unexpectedly succeeded' >&2; exit 1
fi
jq -se 'map(.event) == ["started", "failed"] and .[-1].exit_code == 3' .squad/workers/failed-*.events.jsonl >/dev/null
echo 'headless smoke passed'
