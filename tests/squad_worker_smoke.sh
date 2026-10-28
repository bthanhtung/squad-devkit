#!/usr/bin/env bash
set -euo pipefail

# bash 3.2 (macOS) does not exit on a failed [[ ]] under set -e.
fail() {
  echo "Assertion failed at line ${BASH_LINENO[0]}" >&2
  exit 1
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temp_directory="$(mktemp -d /tmp/squad-worker-test.XXXXXX)"
export TMUX_TMPDIR="$temp_directory/tmux"
cleanup() {
  tmux kill-server 2>/dev/null || true
  rm -rf "$temp_directory"
}
trap cleanup EXIT
unset TMUX TMUX_PANE SQUAD_DEVKIT_GHOSTTY_TERMINAL HERDR_PANE_ID HERDR_ENV HERDR_SOCKET_PATH
mkdir -p "$TMUX_TMPDIR"
project_directory="$temp_directory/project"
test_bin="$temp_directory/bin"
mkdir -p "$project_directory/src" "$test_bin" "$temp_directory/home"

cat >"$test_bin/codex" <<'EOF'
#!/usr/bin/env bash
if [[ "$1 $2" == 'mcp list' ]]; then
  printf '[\n  {\n    "name": "figma",\n    "enabled": true,\n    "transport": {"bearer_token_env_var": "FAKE_FIGMA_TOKEN"}\n  },\n  {\n    "name": "sentry",\n    "enabled": true\n  }\n]\n'
  exit 0
fi
printf 'codex:%s\n' "${*//$'\n'/\\n}" >>"$WORKER_TEST_LOG"
if [[ -n "${FAKE_CODEX_SLEEP:-}" ]]; then
  sleep "$FAKE_CODEX_SLEEP"
fi
if [[ -n "${FAKE_CODEX_FAIL:-}" ]]; then
  echo 'model error' >&2
  exit 3
fi
while (( $# > 0 )); do
  if [[ "$1" == --output-last-message ]]; then
    printf 'Fixed add(). Files: calc.py. Verification: ok.\n' >"$2"
  fi
  shift
done
EOF
cat >"$test_bin/ccr" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == activate ]]; then
  echo 'export ANTHROPIC_BASE_URL="http://127.0.0.1:3456"'
fi
EOF
cat >"$test_bin/claude" <<'EOF'
#!/usr/bin/env bash
printf 'claude:%s:%s\n' "$ANTHROPIC_BASE_URL" "${*//$'\n'/\\n}" >>"$WORKER_TEST_LOG"
printf 'claude-pwd:%s\n' "$PWD" >>"$WORKER_TEST_LOG"
echo '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"README.md"}}]}}'
echo '{"type":"result","num_turns":2,"usage":{"input_tokens":1200,"output_tokens":80},"result":"Wrote README.md. Verification: re-read the file."}'
EOF
cat >"$test_bin/curl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$test_bin"/*
export HOME="$temp_directory/home"
export PATH="$test_bin:$PATH"
export WORKER_TEST_LOG="$temp_directory/invocations"

cd "$project_directory"
squad init >/dev/null
cp "$repo_root/templates/devkit/dev.md" .squad/roles/dev.md
squad join manager --role manager-devkit --client claude --protocol-version 2 >/dev/null
worker="$repo_root/scripts/squad-worker.sh"

if "$worker" dev-1 --engine codex >/dev/null 2>"$temp_directory/error"; then
  echo 'Expected an empty brief to fail' >&2
  exit 1
fi
grep -q 'The brief is empty' "$temp_directory/error"

codex_output="$(cd src && printf 'Fix add() in calc.py\nFiles you own: calc.py\n' |
  "$worker" dev-1 --engine codex --mcp sentry --brief-file -)"
[[ "$codex_output" == '[dev-1 · codex · task '* ]] || fail
[[ "$codex_output" == *'Fixed add(). Files: calc.py. Verification: ok.'* ]] || fail
codex_call="$(grep '^codex:' "$WORKER_TEST_LOG")"
[[ "$codex_call" == *"exec --json --cd $PWD --profile high --ephemeral --skip-git-repo-check --sandbox workspace-write"* ]] || fail
[[ "$codex_call" == *'-c mcp_servers.figma.enabled=false'* ]] || fail
[[ "$codex_call" != *'mcp_servers.sentry'* ]] || fail
[[ "$codex_call" == *'You are dev-1, a dev worker in a squad led by manager.'* ]] || fail
[[ "$codex_call" == *'Role: developer.'* && "$codex_call" != *'squad-devkit template'* ]] || fail
[[ "$codex_call" == *'## Task '*': Fix add() in calc.py'* ]] || fail
grep -q 'assigned_to: dev-1' <<<"$(squad task list --status completed)"
[[ "$(squad agents)" != *'dev-1 '* ]] || fail
ls .squad/workers/dev-1-*.md >/dev/null
dev_one_status="$(ls .squad/workers/dev-1-*.status)"
grep -qx 'state=completed' "$dev_one_status"
grep -qx 'exit=0' "$dev_one_status"
grep -qx 'profile=high' "$dev_one_status"
grep -qx 'title=Fix add() in calc.py' "$dev_one_status"
monitor_frame="$("$repo_root/scripts/squad-worker-monitor.sh" "$dev_one_status" --once)"
[[ "$monitor_frame" == *'dev-1'*'codex (high)'*'COMPLETED'* ]] || fail
[[ "$monitor_frame" == *'Fixed add(). Files: calc.py. Verification: ok.'* ]] || fail
[[ "$("$repo_root/scripts/squad-worker-monitor.sh" --all --once)" == *'dev-1'*'codex/high'*'completed'* ]] || fail
[[ ! -e .squad/workers/.pane.lock ]] || fail
grep -q 'dev-1 (codex) completed task .* Report: .*/.squad/workers/dev-1-' <<<"$(squad receive manager)"

ccr_output="$("$worker" doc-1 --engine ccr --role writer --title 'Write README' \
  --brief 'Create README.md. Files you own: README.md')"
[[ "$ccr_output" == '[doc-1 · ccr · task '*'Wrote README.md. Verification: re-read the file.'* ]] || fail
ccr_call="$(grep '^claude:' "$WORKER_TEST_LOG")"
[[ "$ccr_call" == 'claude:http://127.0.0.1:3456:-p --strict-mcp-config --disable-slash-commands'* ]] || fail
[[ "$ccr_call" == *'--tools Read,Edit,Write,Glob,Grep --allowedTools Read,Edit,Write,Glob,Grep --permission-mode acceptEdits'* ]] || fail
[[ "$ccr_call" == *'## Task '*': Write README'* ]] || fail
[[ "$ccr_call" == *'--output-format stream-json --verbose'* ]] || fail
ccr_frame="$("$repo_root/scripts/squad-worker-monitor.sh" "$(ls .squad/workers/doc-1-*.status)" --once)"
[[ "$ccr_frame" == *'Tool calls: 1'*'files changed: 1'*'turns: 2'* ]] || fail
[[ "$ccr_frame" == *'Tokens: in 1,200 · out 80'* ]] || fail
[[ "$ccr_frame" == *'→ Write README.md'* ]] || fail
grep -q 'assigned_to: doc-1' <<<"$(squad task list --status completed)"

status=0
FAKE_CODEX_FAIL=1 "$worker" dev-2 --engine codex --profile medium --brief 'Break things' \
  >/dev/null 2>"$temp_directory/error" || status=$?
[[ "$status" == 3 ]] || fail
grep -q 'dev-2 (codex) failed on task .* (exit status 3)' "$temp_directory/error"
grep -q -- '--profile medium' "$WORKER_TEST_LOG"
grep -q 'dev-2 (codex) failed' <<<"$(squad receive manager)"
grep -qx 'state=failed' .squad/workers/dev-2-*.status
grep -qx 'exit=3' .squad/workers/dev-2-*.status

status=0
"$worker" mcp-1 --engine codex --mcp figma --brief 'Needs figma' >/dev/null 2>"$temp_directory/error" || status=$?
[[ "$status" == 3 ]] || fail
grep -q 'figma (needs FAKE_FIGMA_TOKEN)' "$temp_directory/error"
grep -qx 'state=failed' .squad/workers/mcp-1-*.status
[[ "$(grep -c 'Needs figma' "$WORKER_TEST_LOG")" == 0 ]] || fail
FAKE_FIGMA_TOKEN=secret "$worker" mcp-2 --engine codex --mcp figma --brief 'Has figma token' >/dev/null
grep -q 'Has figma token' "$WORKER_TEST_LOG"
grep -q 'Never read credentials or tokens from configuration files' "$WORKER_TEST_LOG"

other_project="$temp_directory/other project"
mkdir -p "$other_project"
resolved_other="$(cd "$other_project" && pwd)"
(cd "$temp_directory" && SQUAD_DEVKIT_WORKSPACE="$project_directory" \
  "$worker" far-1 --engine codex --project "$other_project" --brief 'Work elsewhere' >/dev/null)
grep -q "^codex:exec --json --cd $resolved_other --profile high" "$WORKER_TEST_LOG"
grep -q "Project directory: $resolved_other" "$WORKER_TEST_LOG"
grep -q 'assigned_to: far-1' <<<"$(squad task list --status completed)"
ls .squad/workers/far-1-*.md >/dev/null
[[ ! -e "$other_project/.squad" ]] || fail
"$worker" far-2 --engine ccr --project "$other_project" --brief 'Edit elsewhere. Files you own: notes.md' >/dev/null
grep -qx "claude-pwd:$resolved_other" "$WORKER_TEST_LOG"
if "$worker" far-3 --engine codex --project "$temp_directory/missing" --brief 'Nowhere' >/dev/null 2>"$temp_directory/error"; then
  echo 'Expected a missing --project directory to fail' >&2
  exit 1
fi
grep -q 'Project directory does not exist' "$temp_directory/error"

cat >"$test_bin/osascript" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >>"$WORKER_OSASCRIPT_LOG"
printf 'pane-%s\n' "$(grep -c '^MANAGER-TERMINAL$' "$WORKER_OSASCRIPT_LOG")"
EOF
chmod +x "$test_bin/osascript"
export WORKER_OSASCRIPT_LOG="$temp_directory/osascript"
SQUAD_DEVKIT_GHOSTTY_TERMINAL=MANAGER-TERMINAL "$worker" ghost-1 --engine codex --brief 'First pane' >/dev/null
SQUAD_DEVKIT_GHOSTTY_TERMINAL=MANAGER-TERMINAL "$worker" ghost-2 --engine codex --brief 'Second pane' >/dev/null
[[ "$(sed -n '1p' "$WORKER_OSASCRIPT_LOG")" == "$repo_root/scripts/lib/squad-worker-ghostty.applescript" ]] || fail
[[ "$(sed -n '2p' "$WORKER_OSASCRIPT_LOG")" == MANAGER-TERMINAL ]] || fail
[[ -z "$(sed -n '3p' "$WORKER_OSASCRIPT_LOG")" ]] || fail
[[ "$(sed -n '4p' "$WORKER_OSASCRIPT_LOG")" == "$(pwd -P)" || "$(sed -n '4p' "$WORKER_OSASCRIPT_LOG")" == "$PWD" ]] || fail
pane_script="$(sed -n '5p' "$WORKER_OSASCRIPT_LOG")"
[[ -x "$pane_script" ]] || fail
grep -q 'squad-worker-monitor.sh .*ghost-1-.*\.status' "$pane_script"
grep -qx "export SQUAD_WORKER_PANE_HOLD=60" "$pane_script"
[[ "$(sed -n '6p' "$WORKER_OSASCRIPT_LOG")" == 'ghost-1 · codex' ]] || fail
[[ "$(sed -n '9p' "$WORKER_OSASCRIPT_LOG")" == pane-1 ]] || fail
[[ "$(sed -n '12p' "$WORKER_OSASCRIPT_LOG")" == 'ghost-2 · codex' ]] || fail
[[ "$(cat .squad/workers/.ghostty-MANAGER-TERMINAL.last)" == pane-2 ]] || fail
rm "$WORKER_OSASCRIPT_LOG"
SQUAD_WORKER_PANES=0 SQUAD_DEVKIT_GHOSTTY_TERMINAL=MANAGER-TERMINAL "$worker" ghost-3 --engine codex --brief 'No pane' >/dev/null
[[ ! -e "$WORKER_OSASCRIPT_LOG" ]] || fail

cat >"$test_bin/herdr" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$WORKER_HERDR_LOG"
if [[ "$1 $2" == 'pane split' ]]; then
  if [[ "$3" == gone ]]; then
    echo '{"error":{"code":"pane_not_found"}}'
  else
    printf '{"result":{"pane":{"pane_id":"w1:p%s","focused":false}}}\n' "$(grep -c '^pane split' "$WORKER_HERDR_LOG")"
  fi
fi
EOF
chmod +x "$test_bin/herdr"
export WORKER_HERDR_LOG="$temp_directory/herdr"
HERDR_PANE_ID=w1:pM SQUAD_DEVKIT_GHOSTTY_TERMINAL=MANAGER-TERMINAL "$worker" herd-1 --engine codex --brief 'Herdr pane' >/dev/null
HERDR_PANE_ID=w1:pM "$worker" herd-2 --engine codex --brief 'Herdr stacked pane' >/dev/null
grep -qx "pane split w1:pM --direction right --cwd $PWD" "$WORKER_HERDR_LOG"
grep -qx 'pane rename w1:p1 herd-1 · codex' "$WORKER_HERDR_LOG"
grep -q '^pane run w1:p1 exec .*/\.squad/workers/herd-1-.*\.monitor\.sh$' "$WORKER_HERDR_LOG"
grep -qx "pane split w1:p1 --direction down --cwd $PWD" "$WORKER_HERDR_LOG"
grep -qx 'pane rename w1:p2 herd-2 · codex' "$WORKER_HERDR_LOG"
[[ ! -e "$WORKER_OSASCRIPT_LOG" ]] || fail
printf 'gone\n' >.squad/workers/.herdr-w1_pM.last
HERDR_PANE_ID=w1:pM "$worker" herd-3 --engine codex --brief 'Previous pane closed' >/dev/null
[[ "$(grep -c "^pane split w1:pM --direction right" "$WORKER_HERDR_LOG")" == 2 ]] || fail
[[ "$(cat .squad/workers/.herdr-w1_pM.last)" == w1:p4 ]] || fail

tmux new-session -d -s workers -x 200 -y 50 'sleep 120'
manager_pane="$(tmux list-panes -t workers -F '#{pane_id}')"
tmux_value="$(tmux display-message -p -t workers '#{socket_path},#{pid},0')"
TMUX="$tmux_value" TMUX_PANE="$manager_pane" SQUAD_WORKER_PANE_HOLD=60 \
  "$worker" tmux-1 --engine codex --brief 'Tmux pane' >/dev/null
TMUX="$tmux_value" TMUX_PANE="$manager_pane" SQUAD_WORKER_PANE_HOLD=60 \
  "$worker" tmux-2 --engine ccr --brief 'Second tmux pane. Files you own: notes.md' >/dev/null
[[ "$(tmux list-panes -t workers -F '#{pane_id}' | wc -l | tr -d ' ')" == 3 ]] || fail
tmux list-panes -t workers -F '#{pane_title}' | grep -qx 'tmux-1 · codex'
tmux list-panes -t workers -F '#{pane_title}' | grep -qx 'tmux-2 · ccr'
[[ "$(tmux display-message -p -t workers '#{window_layout}')" != '' ]] || fail
sleep 2
worker_pane="$(tmux list-panes -t workers -F '#{pane_id} #{pane_title}' | awk '/tmux-1/ { print $1 }')"
tmux capture-pane -p -t "$worker_pane" | grep -q 'COMPLETED'
grep -qx 'export SQUAD_WORKER_PANE_HOLD=60' .squad/workers/tmux-1-*.monitor.sh
[[ "$(squad agents)" != *'dev-2 '* ]] || fail
# claude engine: model, auto permissions, workspace access, tokens from stream-json.
"$worker" lead-1 --engine claude --brief 'High-stakes change. Files you own: core.py' >/dev/null
claude_call="$(grep '^claude:' "$WORKER_TEST_LOG" | tail -n 1)"
[[ "$claude_call" == *'-p --model haiku --strict-mcp-config --disable-slash-commands --no-session-persistence --tools Read,Edit,Write,Glob,Grep,Bash --permission-mode acceptEdits --settings {"sandbox":{"enabled":true,"autoAllowBashIfSandboxed":true}} --add-dir '*'--output-format stream-json --verbose'* ]] || fail
[[ "$claude_call" == *'squad-ask.sh --from lead-1 --workspace '*'--to manager'* ]] || fail
lead_status="$(ls .squad/workers/lead-1-*.status)"
grep -qx 'model=haiku' "$lead_status"
"$worker" lead-2 --engine claude --model opus --brief 'Hardest design. Files you own: design.md' >/dev/null
grep -qx 'model=opus' .squad/workers/lead-2-*.status
[[ "$(grep '^claude:' "$WORKER_TEST_LOG" | tail -n 1)" == *'-p --model opus '* ]] || fail
grep -qx 'tokens_in=1200' "$lead_status"
grep -qx 'tokens_out=80' "$lead_status"
grep -qx 'state=completed' "$lead_status"
[[ "$(grep -c 'cannot ask questions' "$WORKER_TEST_LOG")" -ge 1 ]] || fail

# A run that stops producing output is stopped and reported instead of hanging.
status=0
FAKE_CODEX_SLEEP=20 SQUAD_WORKER_STALL_SECONDS=2 "$worker" slow-1 --engine codex --brief 'Hang' \
  >/dev/null 2>"$temp_directory/error" || status=$?
[[ "$status" == 124 ]] || fail
grep -q 'slow-1 (codex) no output for 0m on task' "$temp_directory/error"
grep -qx 'state=failed' .squad/workers/slow-1-*.status
grep -q 'slow-1 (codex) no output' <<<"$(squad receive manager)"
status=0
FAKE_CODEX_SLEEP=20 SQUAD_WORKER_TIMEOUT_SECONDS=2 "$worker" slow-2 --engine codex --brief 'Too long' \
  >/dev/null 2>"$temp_directory/error" || status=$?
[[ "$status" == 124 ]] || fail
grep -q 'slow-2 (codex) timed out' "$temp_directory/error"

# --list and --stop let the manager see and stop running workers.
FAKE_CODEX_SLEEP=30 SQUAD_WORKER_STALL_SECONDS=0 "$worker" long-1 --engine codex --brief 'Long task' \
  >/dev/null 2>"$temp_directory/stop-error" &
long_pid=$!
for attempt in {1..20}; do
  [[ "$("$worker" --list)" == *'long-1'* ]] && break
  sleep 0.5
done
[[ "$("$worker" --list)" == *'long-1'*'codex'*'Long task'* ]] || fail
[[ "$("$worker" --stop long-1)" == *'Stopping long-1'* ]] || fail
status=0
wait "$long_pid" || status=$?
[[ "$status" != 0 ]] || fail
grep -qx 'state=stopped' .squad/workers/long-1-*.status
grep -qx 'reason=stopped by request' .squad/workers/long-1-*.status
[[ "$("$worker" --list)" == 'No running workers.' ]] || fail
[[ "$("$worker" --stop nobody)" == 'No running worker matches nobody.' ]] || fail

# squad-ask: a worker asks the manager and gets the answer.
squad join asker --role dev >/dev/null
(sleep 1; squad send manager asker 'Use the v2 API.' >/dev/null) &
answer="$("$repo_root/scripts/squad-ask.sh" --from asker --workspace "$PWD" --to manager --timeout 10 'Which API version?')"
[[ "$answer" == *'Use the v2 API.'* ]] || fail
grep -q 'QUESTION from asker' <<<"$(squad receive manager)"
no_answer="$("$repo_root/scripts/squad-ask.sh" --from asker --workspace "$PWD" --to manager --timeout 1 'Still there?')"
[[ "$no_answer" == *'No answer from manager within 1s'* ]] || fail
squad send manager asker 'FYI' >/dev/null
[[ "$("$repo_root/scripts/squad-ask.sh" --from asker --workspace "$PWD" --check)" == *'FYI'* ]] || fail
[[ "$("$repo_root/scripts/squad-ask.sh" --from asker --workspace "$PWD" --reply manager 'Done.')" == 'Sent to manager.' ]] || fail
squad leave asker >/dev/null
echo 'PASS: squad-worker engines, MCP filtering, task lifecycle, watchdog, stop, questions, and failure reporting'
