#!/usr/bin/env bash
set -euo pipefail
unset HC_TERMINAL_ID HC_TERMINAL_SOCKET HC_SCOPE SQUAD_WORKER_PANES SQUAD_WORKER_PANE_HOLD
# Fixtures must not inherit the invoking squad session.
unset SQUAD_DEVKIT_ORCA_TERMINAL ORCA_PANE_KEY ORCA_CLI_COMMAND ORCA_DEV_REPO_ROOT
unset SQUAD_DEVKIT_WORKSPACE SQUAD_WORKTREE_WORKSPACE SQUAD_MANAGER_ID SQUAD_DEVKIT_YOLO SQUAD_WORKER_CODEX_PROFILE
# Name the failing command, so CI logs show where a test stopped.
trap 'echo "Failed at line $LINENO: $BASH_COMMAND" >&2' ERR

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
unset TMUX TMUX_PANE SQUAD_DEVKIT_GHOSTTY_TERMINAL HERDR_PANE_ID HERDR_ENV HERDR_SOCKET_PATH \
  WEZTERM_PANE KITTY_WINDOW_ID ITERM_SESSION_ID ZELLIJ ZELLIJ_SESSION_NAME DISPLAY WAYLAND_DISPLAY
export TERM_PROGRAM=test-terminal
mkdir -p "$TMUX_TMPDIR"
project_directory="$temp_directory/project"
test_bin="$temp_directory/bin"
mkdir -p "$project_directory/src" "$test_bin" "$temp_directory/home"

cat >"$test_bin/codex" <<'EOF'
#!/usr/bin/env bash
if [[ "$1 $2" == 'mcp list' ]]; then
  if [[ -n "${FAKE_MCP_INVALID:-}" ]]; then echo 'invalid config' >&2; exit 1; fi
  if [[ -n "${FAKE_MCP_TRANSPORTS:-}" ]]; then
    printf '%s\n' '[{"name":"disabled-plugin","enabled":false,"transport":{"type":"stdio"}},{"name":"stdio-plugin","enabled":true,"transport":{"type":"stdio"}},{"name":"http-plugin","enabled":true,"transport":{"type":"streamable_http"}}]'
    exit 0
  fi
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
[[ -z "${FAKE_MODEL_EVENT:-}" ]] || printf '%s\n' "$FAKE_MODEL_EVENT"
work_directory=""
while (( $# > 0 )); do
  [[ "$1" == --cd ]] && work_directory="$2"
  if [[ "$1" == --output-last-message ]]; then
    printf 'Fixed add(). Files: calc.py. Verification: ok.\n' >"$2"
  fi
  shift
done
if [[ -n "${FAKE_CODEX_EDIT:-}" && -n "$work_directory" ]]; then
  printf '%s\n' "${FAKE_CODEX_EDIT#*=}" >"$work_directory/${FAKE_CODEX_EDIT%%=*}"
fi
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
[[ -z "${FAKE_MODEL_EVENT:-}" ]] || printf '%s\n' "$FAKE_MODEL_EVENT"
echo '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"README.md"}}]}}'
echo '{"type":"result","num_turns":2,"usage":{"input_tokens":1200,"output_tokens":80},"result":"Wrote README.md. Verification: re-read the file."}'
EOF
cat >"$test_bin/curl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$test_bin/grok" <<'EOF'
#!/usr/bin/env bash
# Stand-in non-streaming engine: the report goes to stdout.
echo $$ > "$WORKER_TEST_LOG.pid"
printf 'grok:%s\n' "${*//$'\n'/\\n}" >> "$WORKER_TEST_LOG"
if [[ -n "${FAKE_PLAIN_BEATS:-}" ]]; then
  for _ in $(seq "$FAKE_PLAIN_BEATS"); do echo 'progress'; sleep 1; done
fi
if [[ -n "${FAKE_PLAIN_SLEEP:-}" ]]; then sleep "$FAKE_PLAIN_SLEEP"; fi
if [[ -n "${FAKE_AGY_JSON:-}" ]]; then
  if [[ -n "${FAKE_AGY_INIT:-}" ]]; then
    printf '{"event":"init","init":{"model":"%s"}}\n' "$FAKE_AGY_INIT"
    echo '{"event":"step_update"}'
    echo '{"event":"result","result":{"status":"SUCCESS","response":"Done. Verification: ok."}}'
  else
    echo '{"type":"assistant","message":{"model":"agy-reported"}}'
    echo '{"type":"result","result":"Done. Verification: ok."}'
  fi
else
  echo 'Done. Files: none. Verification: ok.'
fi
EOF
sed 's/^printf .grok:/printf '"'"'agy:/' "$test_bin/grok" >"$test_bin/agy"
sed 's/^printf .grok:/printf '"'"'gemini:/' "$test_bin/grok" >"$test_bin/gemini"
cat >"$test_bin/opencode" <<'EOF'
#!/usr/bin/env bash
# Stand-in OpenCode JSON mode: one text part then a step_finish with tokens.
echo $$ > "$WORKER_TEST_LOG.pid"
printf 'opencode:%s\n' "${*//$'\n'/\\n}" >> "$WORKER_TEST_LOG"
if [[ -n "${FAKE_PLAIN_BEATS:-}" ]]; then
  for _ in $(seq "$FAKE_PLAIN_BEATS"); do echo 'progress'; sleep 1; done
fi
if [[ -n "${FAKE_PLAIN_SLEEP:-}" ]]; then sleep "$FAKE_PLAIN_SLEEP"; fi
echo '{"type":"step_start","timestamp":1,"sessionID":"s","part":{"messageID":"m1","type":"step-start"}}'
echo '{"type":"text","timestamp":2,"sessionID":"s","part":{"messageID":"m1","type":"text","text":"Done. Files: none. Verification: ok."}}'
echo '{"type":"step_finish","timestamp":3,"sessionID":"s","part":{"messageID":"m1","type":"step-finish","reason":"stop","cost":0,"tokens":{"input":9088,"output":3,"reasoning":0,"cache":{"read":1664,"write":0}}}}'
EOF
chmod +x "$test_bin"/*
export HOME="$temp_directory/home"
export PATH="$repo_root/target/debug:$test_bin:$PATH"
export WORKER_TEST_LOG="$temp_directory/invocations"

cd "$project_directory"
squad init >/dev/null
cp "$repo_root/templates/devkit/dev.md" .squad/roles/dev.md
squad join manager --role manager-devkit --client claude --protocol-version 2 >/dev/null
worker="$repo_root/scripts/squad-worker.sh"

# Model selection crosses the CLI boundary, not just the status display.
for engine in codex claude opencode grok agy; do
  key="SQUAD_WORKER_$(printf '%s' "$engine" | tr '[:lower:]' '[:upper:]')_MODEL"
  for selection in override environment default; do
    expected=env-choice
    opts=()
    case "$selection" in
      override) opts=(--model explicit-choice); expected=explicit-choice ;;
      default) expected=''; [[ "$engine" != claude ]] || expected=haiku ;;
    esac
    value=env-choice; [[ "$selection" != default ]] || value=''
    id="model-$engine-$selection"
    env "$key=$value" FAKE_MODEL_EVENT='{"type":"assistant","message":{"model":"observed-model"}}' \
      "$worker" "$id" --engine "$engine" --no-worktree ${opts[@]+"${opts[@]}"} --brief 'Model check' >/dev/null 2>"$temp_directory/model-stderr"
    sf="$(ls .squad/workers/"$id"-*.status)"
    grep -qx "requested_model=$expected" "$sf"
    grep -q 'requested=' "$temp_directory/model-stderr"
    call="$(grep "^$engine:" "$WORKER_TEST_LOG" | tail -n 1)"
    if [[ -n "$expected" ]]; then [[ "$call" == *"--model $expected"* ]] || fail
    else [[ "$call" != *'--model '* ]] || fail; fi
    actual=unknown; [[ "$engine" != claude ]] || actual=observed-model
    grep -qx "actual_model=$actual" "$sf"
    if [[ "$engine" == agy ]]; then
      grep -qx 'configured_model=unknown' "$sf"
      grep -qx 'configured_model_source=unknown' "$sf"
    fi
  done
done
# Saved effort is forwarded only when that selection wins.
cat > .squad/worker-models.json <<'JSON'
{"version":1,"engines":{"codex":{"strong":{"model":"saved-code","effort":"high"}},"agy":{"strong":{"model":"saved-agy","effort":"low"}}}}
JSON
"$worker" saved-code --engine codex --model-tier strong --no-worktree --brief check >/dev/null
[[ "$(grep '^codex:' "$WORKER_TEST_LOG" | tail -n 1)" == *'--model saved-code -c model_reasoning_effort="high"'* ]] || fail
[[ "$(grep '^codex:' "$WORKER_TEST_LOG" | tail -n 1)" != *'--profile '* ]] || fail
"$worker" saved-agy --engine agy --model-tier strong --no-worktree --brief check >/dev/null
[[ "$(grep '^agy:' "$WORKER_TEST_LOG" | tail -n 1)" == *'--effort low --model saved-agy'* ]] || fail
grep -qx 'configured_model=unknown' .squad/workers/saved-agy-*.status
grep -qx 'configured_model_source=unknown' .squad/workers/saved-agy-*.status
SQUAD_WORKER_CODEX_PROFILE=custom "$worker" saved-profile --engine codex --model-tier strong --no-worktree --brief check >/dev/null
[[ "$(grep '^codex:' "$WORKER_TEST_LOG" | tail -n 1)" == *'--profile custom'* ]] || fail
"$worker" flag-profile --engine codex --profile chosen --model explicit --model-tier strong --no-worktree --brief check >/dev/null
[[ "$(grep '^codex:' "$WORKER_TEST_LOG" | tail -n 1)" == *'--profile chosen'* ]] || fail
[[ "$(grep '^codex:' "$WORKER_TEST_LOG" | tail -n 1)" != *'model_reasoning_effort'* ]] || fail
rm .squad/worker-models.json
SQUAD_WORKER_CODEX_MODEL_STRONG=tier-choice "$worker" tier-codex --engine codex --model-tier strong --no-worktree --brief '--models' >/dev/null
grep -qx 'model_tier=strong' .squad/workers/tier-codex-*.status
grep -qx 'requested_model=tier-choice' .squad/workers/tier-codex-*.status
FAKE_AGY_JSON=1 "$worker" model-agy-json --engine agy --no-worktree --brief 'AGY JSON' >/dev/null
grep -qx 'actual_model=agy-reported' .squad/workers/model-agy-json-*.status
grep -qx 'configured_model=unknown' .squad/workers/model-agy-json-*.status
grep -qx 'configured_model_source=unknown' .squad/workers/model-agy-json-*.status
FAKE_AGY_JSON=1 FAKE_AGY_INIT=agy-native-model "$worker" model-agy-init --engine agy --no-worktree --brief 'AGY init' >/dev/null
grep -qx 'actual_model=unknown' .squad/workers/model-agy-init-*.status
grep -qx 'configured_model=agy-native-model' .squad/workers/model-agy-init-*.status
grep -qx 'configured_model_source=agy-init' .squad/workers/model-agy-init-*.status
if "$worker" model-ccr --engine ccr --model explicit --brief check >/dev/null 2>"$temp_directory/model-stderr"; then fail; fi
grep -q 'router' "$temp_directory/model-stderr"
if SQUAD_WORKER_CCR_MODEL=env "$worker" model-ccr-env --engine ccr --brief check >/dev/null 2>&1; then fail; fi
if "$worker" model-bad --engine codex --model $'bad\nstate=completed' --brief check >/dev/null 2>&1; then fail; fi
: >"$WORKER_TEST_LOG"

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
[[ "$codex_call" == *"exec --json --cd $PWD --ephemeral --skip-git-repo-check --sandbox workspace-write"* ]] || fail
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
grep -qx 'profile=' "$dev_one_status"
grep -qx 'title=Fix add() in calc.py' "$dev_one_status"
monitor_frame="$("$repo_root/scripts/squad-worker-monitor.sh" "$dev_one_status" --once)"
[[ "$monitor_frame" == *'dev-1'*'codex'*'COMPLETED'* ]] || fail
[[ "$monitor_frame" == *'Fixed add(). Files: calc.py. Verification: ok.'* ]] || fail
[[ "$monitor_frame" == *'dev-1 · codex · role dev'*'Task: Fix add() in calc.py'* ]] || fail
[[ "$("$repo_root/scripts/squad-worker-monitor.sh" --all --once)" == *'dev-1'*'codex'*'completed'* ]] || fail
[[ ! -e .squad/workers/.pane.lock ]] || fail
grep -q 'dev-1 (codex) completed task .* Report: .*/.squad/workers/dev-1-' <<<"$(squad receive manager)"

"$worker" dev-ns --engine codex --no-sandbox --brief 'No sandbox codex' >/dev/null
codex_ns_call="$(grep '^codex:' "$WORKER_TEST_LOG" | tail -n 1)"
[[ "$codex_ns_call" == *"exec --json --cd $PWD --ephemeral --skip-git-repo-check --sandbox danger-full-access"* ]] || fail

SQUAD_WORKER_SANDBOX=0 "$worker" dev-env-ns --engine codex --brief 'Env no sandbox codex' >/dev/null
codex_env_ns_call="$(grep '^codex:' "$WORKER_TEST_LOG" | tail -n 1)"
[[ "$codex_env_ns_call" == *"exec --json --cd $PWD --ephemeral --skip-git-repo-check --sandbox danger-full-access"* ]] || fail

ccr_output="$("$worker" doc-1 --engine ccr --role writer --title 'Write README' \
  --brief 'Create README.md. Files you own: README.md')"
[[ "$ccr_output" == '[doc-1 · ccr · task '*'Wrote README.md. Verification: re-read the file.'* ]] || fail
ccr_call="$(grep '^claude:' "$WORKER_TEST_LOG")"
[[ "$ccr_call" == 'claude:http://127.0.0.1:3456:-p --strict-mcp-config --disable-slash-commands'* ]] || fail
[[ "$ccr_call" == *'--tools Read,Edit,Write,Glob,Grep --allowedTools Read,Edit,Write,Glob,Grep --permission-mode acceptEdits'* ]] || fail
[[ "$ccr_call" == *'## Task '*': Write README'* ]] || fail
[[ "$ccr_call" == *'--output-format stream-json --verbose'* ]] || fail
ccr_frame="$("$repo_root/scripts/squad-worker-monitor.sh" "$(ls .squad/workers/doc-1-*.status)" --once)"
[[ "$ccr_frame" == *'✓ COMPLETED in '*' · 1 tool call · 0 failed · 1 file changed · 2 turns · tokens in 1,200 · out 80'* ]] || fail
[[ "$ccr_frame" != *$'\033'* ]] || fail
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
grep -q "^codex:exec --json --cd $resolved_other --ephemeral" "$WORKER_TEST_LOG"
grep -q "Working directory: $resolved_other" "$WORKER_TEST_LOG"
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
HERDR_ENV=1 HERDR_PANE_ID=w1:pM SQUAD_DEVKIT_GHOSTTY_TERMINAL=MANAGER-TERMINAL "$worker" herd-1 --engine codex --brief 'Herdr pane' >/dev/null
HERDR_ENV=1 HERDR_PANE_ID=w1:pM "$worker" herd-2 --engine codex --brief 'Herdr stacked pane' >/dev/null
grep -qx "pane split w1:pM --direction right --cwd $PWD --no-focus" "$WORKER_HERDR_LOG"
grep -qx 'pane rename w1:p1 herd-1 · codex' "$WORKER_HERDR_LOG"
grep -q '^pane run w1:p1 exec .*/\.squad/workers/herd-1-.*\.monitor\.sh$' "$WORKER_HERDR_LOG"
grep -qx "pane split w1:p1 --direction down --cwd $PWD --no-focus" "$WORKER_HERDR_LOG"
grep -qx 'pane rename w1:p2 herd-2 · codex' "$WORKER_HERDR_LOG"
[[ ! -e "$WORKER_OSASCRIPT_LOG" ]] || fail
printf 'gone\n' >.squad/workers/.herdr-w1_pM.last
HERDR_ENV=1 HERDR_PANE_ID=w1:pM "$worker" herd-3 --engine codex --brief 'Previous pane closed' >/dev/null
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
status=0
FAKE_MCP_INVALID=1 "$worker" plugins-invalid --engine codex --brief 'Must not launch unfiltered' \
  >/dev/null 2>"$temp_directory/error" || status=$?
[[ "$status" == 3 ]] || fail
[[ "$(grep -c 'Must not launch unfiltered' "$WORKER_TEST_LOG")" == 0 ]] || fail
grep -q 'refusing an unfiltered worker launch' "$temp_directory/error"

# Plugin MCP entries must remain valid without starting or leaking their transports.
FAKE_MCP_TRANSPORTS=1 "$worker" plugins-1 --engine codex --brief 'Plugin filtering' >/dev/null
plugin_call="$(grep '^codex:' "$WORKER_TEST_LOG" | tail -n 1)"
[[ "$plugin_call" == *'mcp_servers.stdio-plugin={enabled=false,command="false"}'* ]] || fail
[[ "$plugin_call" == *'mcp_servers.http-plugin={enabled=false,url="http://127.0.0.1"}'* ]] || fail
[[ "$plugin_call" != *'mcp_servers.disabled-plugin'* ]] || fail
FAKE_MCP_TRANSPORTS=1 "$worker" plugins-2 --engine codex --mcp stdio-plugin --brief 'Keep requested plugin' >/dev/null
plugin_call="$(grep '^codex:' "$WORKER_TEST_LOG" | tail -n 1)"
[[ "$plugin_call" != *'mcp_servers.stdio-plugin'* && "$plugin_call" == *'mcp_servers.http-plugin='* ]] || fail
FAKE_MCP_TRANSPORTS=1 "$worker" plugins-3 --engine codex --all-mcp --brief 'Keep all plugins' >/dev/null
[[ "$(grep '^codex:' "$WORKER_TEST_LOG" | tail -n 1)" != *'mcp_servers.'* ]] || fail

# claude engine: model, auto permissions, workspace access, tokens from stream-json.
"$worker" lead-1 --engine claude --brief 'High-stakes change. Files you own: core.py' >/dev/null
claude_call="$(grep '^claude:' "$WORKER_TEST_LOG" | tail -n 1)"
[[ "$claude_call" == *'-p --model haiku --strict-mcp-config --disable-slash-commands --no-session-persistence --tools Read,Edit,Write,Glob,Grep,Bash --permission-mode acceptEdits --settings {"sandbox":{"enabled":true,"autoAllowBashIfSandboxed":true}} --add-dir '*'--output-format stream-json --verbose'* ]] || fail
[[ "$claude_call" == *'squad-ask.sh --from lead-1 --workspace '*'--to manager'* ]] || fail
lead_status="$(ls .squad/workers/lead-1-*.status)"
grep -qx 'model=haiku' "$lead_status"
SQUAD_WORKER_CLAUDE_ALLOWED_TOOLS='Bash(bash tests/squad_completions_smoke.sh)' \
  "$worker" lead-scoped --engine claude --brief 'Run authorized test' >/dev/null
claude_scoped_call="$(grep '^claude:' "$WORKER_TEST_LOG" | tail -n 1)"
[[ "$claude_scoped_call" == *'--allowedTools Bash(bash tests/squad_completions_smoke.sh)'* ]] || fail
[[ "$claude_scoped_call" == *'"enabled":true,"autoAllowBashIfSandboxed":true'* ]] || fail
[[ "$claude_scoped_call" != *'bypassPermissions'* && "$claude_scoped_call" != *'dangerously-skip-permissions'* ]] || fail

"$worker" lead-2 --engine claude --model opus --brief 'Hardest design. Files you own: design.md' >/dev/null
grep -qx 'model=opus' .squad/workers/lead-2-*.status
[[ "$(grep '^claude:' "$WORKER_TEST_LOG" | tail -n 1)" == *'-p --model opus '* ]] || fail
grep -qx 'tokens_in=1200' "$lead_status"
grep -qx 'tokens_out=80' "$lead_status"
grep -qx 'state=completed' "$lead_status"
[[ "$(grep -c 'cannot ask questions' "$WORKER_TEST_LOG")" -ge 1 ]] || fail

"$worker" lead-ns --engine claude --no-sandbox --brief 'No sandbox claude' >/dev/null
claude_ns_call="$(grep '^claude:' "$WORKER_TEST_LOG" | tail -n 1)"
[[ "$claude_ns_call" == *'--settings {"sandbox":{"enabled":false}}'* ]] || fail

SQUAD_WORKER_SANDBOX=0 "$worker" lead-env-ns --engine claude --brief 'Env no sandbox claude' >/dev/null
claude_env_ns_call="$(grep '^claude:' "$WORKER_TEST_LOG" | tail -n 1)"
[[ "$claude_env_ns_call" == *'--settings {"sandbox":{"enabled":false}}'* ]] || fail

# opencode engine: JSON mode, report from the final assistant text, and token
# accounting that separates fresh input from cache reads.
"$worker" oc-1 --engine opencode --brief 'Opencode task' >/dev/null
oc_call="$(grep '^opencode:' "$WORKER_TEST_LOG" | tail -n 1)"
[[ "$oc_call" == *'run --format json'* ]] || fail
oc_status="$(ls .squad/workers/oc-1-*.status)"
grep -qx 'engine=opencode' "$oc_status"
grep -qx 'tokens_in=10752' "$oc_status"
grep -qx 'tokens_cached=1664' "$oc_status"
grep -qx 'tokens_out=3' "$oc_status"
grep -qx 'state=completed' "$oc_status"
grep -q 'Done. Files: none. Verification: ok.' .squad/workers/oc-1-*.md
oc_frame="$("$repo_root/scripts/squad-worker-monitor.sh" "$oc_status" --once)"
[[ "$oc_frame" == *'tokens in 10,752 (cached 1,664) · out 3'* ]] || fail
[[ "$oc_frame" == *'» Done. Files: none. Verification: ok.'* ]] || fail

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
# Worktrees: each worker edits its own git worktree; the project stays untouched
# until the manager merges.
repo="$temp_directory/repo"
mkdir -p "$repo"
git -C "$repo" init -q
printf 'one\ntwo\nthree\n' >"$repo/app.txt"
git -C "$repo" add -A
git -C "$repo" -c user.name=t -c user.email=t@t commit -qm init
printf 'one\ntwo (uncommitted)\nthree\n' >"$repo/app.txt"
printf 'draft\n' >"$repo/notes.txt"
repo_status="$(git -C "$repo" status --porcelain)"
FAKE_CODEX_EDIT='feature.txt=from wt-1' "$worker" wt-1 --engine codex --project "$repo" \
  --brief 'Add feature.txt' >"$temp_directory/wt-output"
wt_path="$(ls -d "$PWD"/.squad/worktrees/repo-*/wt-1)"
[[ -f "$wt_path/feature.txt" && ! -e "$repo/feature.txt" ]] || fail
[[ "$(cat "$wt_path/app.txt")" == $'one\ntwo (uncommitted)\nthree' && -f "$wt_path/notes.txt" ]] || fail
[[ "$(git -C "$repo" status --porcelain)" == "$repo_status" ]] || fail
grep -q "codex:exec --json --cd $wt_path " "$WORKER_TEST_LOG"
grep -q "This is your own git worktree of $(git -C "$repo" rev-parse --show-toplevel)" "$WORKER_TEST_LOG"
grep -q 'Worktree: 1 changed file(s) in .*Merge: squad-worker --merge wt-1' "$temp_directory/wt-output"
wt_status="$(ls .squad/workers/wt-1-*.status)"
grep -q "^worktree=$wt_path$" "$wt_status"
grep -q '^patch=.*wt-1-.*\.patch$' "$wt_status"
[[ "$("$worker" --list)" == *'Unmerged worktrees'*'wt-1'* ]] || fail
FAKE_CODEX_EDIT='feature.txt=from wt-1, fixed' "$worker" wt-1 --engine codex --project "$repo" \
  --brief 'Fix feature.txt' >/dev/null
[[ "$(cat "$wt_path/feature.txt")" == 'from wt-1, fixed' ]] || fail
# --diff previews a worktree without consuming it.
diff_one="$("$worker" --diff wt-1)"
[[ "$diff_one" == *'+++ b/feature.txt'*'+from wt-1, fixed'* ]] || fail
[[ "$("$worker" --diff wt-1)" == "$diff_one" ]] || fail
[[ -d "$wt_path" && "$(git -C "$repo" status --porcelain)" == "$repo_status" ]] || fail
status=0
"$worker" --diff nobody >"$temp_directory/diff-out" 2>"$temp_directory/diff-error" || status=$?
[[ "$status" == 1 && ! -s "$temp_directory/diff-out" ]] || fail
grep -q 'No worktree for nobody' "$temp_directory/diff-error"
for bad in '../x' 'a b' '..' 'all'; do
  status=0
  "$worker" --diff "$bad" >/dev/null 2>&1 || status=$?
  [[ "$status" != 0 ]] || fail
done
status=0
"$worker" --diff >/dev/null 2>&1 || status=$?
[[ "$status" == 2 ]] || fail
[[ "$("$worker" --merge wt-1)" == *'Merged wt-1 into '*'(1 files, uncommitted)'* ]] || fail
[[ "$(cat "$repo/feature.txt")" == 'from wt-1, fixed' && ! -d "$wt_path" ]] || fail
[[ "$(git -C "$repo" diff --cached --name-only)" == '' ]] || fail
[[ -z "$(git -C "$repo" branch --list 'squad/*')" ]] || fail

# Parallel edits to the same line merge with conflict markers.
FAKE_CODEX_EDIT='app.txt=one
two by wt-2
three' "$worker" wt-2 --engine codex --project "$repo" --brief 'Edit line two' >/dev/null
printf 'one\ntwo by human\nthree\n' >"$repo/app.txt"
status=0
"$worker" --merge wt-2 >/dev/null 2>"$temp_directory/merge-error" || status=$?
[[ "$status" == 1 ]] || fail
grep -q 'with conflicts; resolve the markers in:' "$temp_directory/merge-error"
grep -q '^  app.txt$' "$temp_directory/merge-error"
grep -q '^<<<<<<< ' "$repo/app.txt"
[[ -d "$(dirname "$wt_path")/wt-2" ]] || fail
[[ "$("$worker" --discard wt-2)" == *'Discarded wt-2'* ]] || fail
[[ "$("$worker" --merge wt-2 2>&1 || true)" == *'No worktree for wt-2'* ]] || fail

# Reviewers read the project directly; --no-worktree does the same for any role.
"$worker" rev-1 --engine codex --role reviewer --project "$repo" --brief 'Review app.txt' >/dev/null
grep -q "codex:exec --json --cd $(cd "$repo" && pwd) " "$WORKER_TEST_LOG"
[[ -z "$(grep '^worktree=' .squad/workers/rev-1-*.status | cut -d= -f2)" ]] || fail
"$worker" sec-1 --engine codex --role security --project "$repo" --brief 'Audit app.txt' >/dev/null
[[ -z "$(grep '^worktree=' .squad/workers/sec-1-*.status | cut -d= -f2)" ]] || fail
"$worker" plain-1 --engine codex --no-worktree --project "$repo" --brief 'In place' >/dev/null
[[ -z "$(grep '^worktree=' .squad/workers/plain-1-*.status | cut -d= -f2)" ]] || fail
status=0
"$worker" nogit-1 --engine codex --worktree --project "$other_project" --brief 'x' >/dev/null 2>"$temp_directory/error" || status=$?
[[ "$status" == 2 ]] && grep -q -- '--worktree needs a git repository' "$temp_directory/error" || fail
# Orca tests use only a fake CLI; never discover or mutate the real desktop.
(
  source "$repo_root/scripts/lib/squad-panes.sh"
  export ORCA_CLI_COMMAND="$test_bin/orca-fake" ORCA_TEST_LOG="$temp_directory/orca.log"
  cat >"$ORCA_CLI_COMMAND" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$ORCA_TEST_LOG"
case "$2" in
  list) printf '{"ok":true,"result":{"terminals":[{"handle":"manager","tabId":"tab","leafId":"leaf"},{"handle":"unrelated","tabId":"other","leafId":"leaf"}]}}\n' ;;
  show)
    [[ "$4" != stale ]] || exit 1
    [[ "$4" != unrelated ]] || { echo '{"ok":true,"result":{"terminal":{"tabId":"other"}}}'; exit 0; }
    printf '{"ok":true,"result":{"terminal":{"handle":"%s","connected":true,"writable":true,"orphaned":false,"tabId":"tab"}}}\n' "$4" ;;
  split)
    printf '%s' "$8" >"$ORCA_TEST_LOG.command"
    [[ "${ORCA_TEST_MALFORMED:-0}" != 1 ]] || { echo '{"ok":true,"result":{"split":{"handle":null}}}'; exit 0; }
    [[ "${ORCA_TEST_TIMEOUT:-0}" != 1 ]] || { echo '{"ok":false,"error":{"code":"runtime_error","data":{"leafId":"pending"}}}'; exit 1; }
    echo '{"ok":true,"result":{"split":{"handle":"worker-pane","tabId":"tab"}}}' ;;
esac
EOF
  chmod +x "$ORCA_CLI_COMMAND"
  mkdir -p "$temp_directory/orca-state"
  unset TMUX TMUX_PANE HERDR_PANE_ID
  export ORCA_PANE_KEY=tab:leaf
  [[ "$(squad_panes_orca_manager "$PWD")" == manager ]] || fail
  export ORCA_PANE_KEY=missing:leaf
  [[ -z "$(squad_panes_orca_manager "$PWD")" ]] || fail
  export SQUAD_DEVKIT_ORCA_TERMINAL=manager
  mkdir -p "$temp_directory/workspace 'quoted'"
  printf '#!/bin/sh\nprintf quoted-ok\n' >"$temp_directory/worker 'quoted' script"
  chmod +x "$temp_directory/worker 'quoted' script"
  squad_open_monitor "$temp_directory/worker 'quoted' script" 'worker · codex' "$temp_directory/workspace 'quoted'" "$temp_directory/orca-state" ''
  [[ "$(bash -c "$(cat "$ORCA_TEST_LOG.command")")" == quoted-ok ]] || fail
  squad_open_monitor /tmp/next 'next · codex' "$PWD" "$temp_directory/orca-state" ''
  grep -q '^terminal split --terminal manager --direction vertical --command ' "$ORCA_TEST_LOG"
  grep -q '^terminal split --terminal worker-pane --direction horizontal --command ' "$ORCA_TEST_LOG"
  grep -q '^terminal set-pane-title --terminal worker-pane --title worker · codex --json$' "$ORCA_TEST_LOG"
  grep -q '^terminal focus --terminal manager --json$' "$ORCA_TEST_LOG"
  printf 'unrelated\n' >"$temp_directory/orca-state/.orca-manager.last"
  : >"$ORCA_TEST_LOG"
  squad_open_monitor /tmp/next next "$PWD" "$temp_directory/orca-state" ''
  grep -q '^terminal split --terminal manager --direction vertical ' "$ORCA_TEST_LOG"
  printf 'stale\n' >"$temp_directory/orca-state/.orca-manager.last"
  : >"$ORCA_TEST_LOG"
  squad_open_monitor /tmp/next next "$PWD" "$temp_directory/orca-state" ''
  grep -q '^terminal split --terminal manager --direction vertical ' "$ORCA_TEST_LOG"
  : >"$ORCA_TEST_LOG"
  osascript_orca_test() { echo dashboard >>"$ORCA_TEST_LOG"; }
  TERM_PROGRAM=Apple_Terminal SQUAD_DEVKIT_OSASCRIPT=osascript_orca_test ORCA_TEST_TIMEOUT=1 \
    squad_open_monitor /tmp/next next "$PWD" "$temp_directory/orca-state" /tmp/dashboard
  [[ "$(grep -c '^terminal split ' "$ORCA_TEST_LOG")" == 2 ]] || fail
  [[ "$(grep '^terminal split ' "$ORCA_TEST_LOG" | sed -n 2p)" == *'--retry-split pending'* ]] || fail
  ! grep -q dashboard "$ORCA_TEST_LOG" || fail
  [[ "$(cat "$temp_directory/orca-state/.orca-manager.last")" == worker-pane ]] || fail
  : >"$ORCA_TEST_LOG"
  ORCA_TEST_MALFORMED=1 squad_open_monitor /tmp/next next "$PWD" "$temp_directory/orca-state" ''
  [[ "$(cat "$temp_directory/orca-state/.orca-manager.last")" == worker-pane ]] || fail
  : >"$ORCA_TEST_LOG"
  SQUAD_DEVKIT_ORCA_TERMINAL=stale squad_open_monitor /tmp/next next "$PWD" "$temp_directory/orca-state" ''
  ! grep -q '^terminal split ' "$ORCA_TEST_LOG" || fail
  : >"$ORCA_TEST_LOG"
  tmux() { printf 'tmux-pane\n'; }
  TMUX=fake TMUX_PANE=%1 squad_open_monitor /tmp/next next "$PWD" "$temp_directory/orca-state" ''
  [[ ! -s "$ORCA_TEST_LOG" ]] || fail
  unset -f tmux
  unset SQUAD_DEVKIT_ORCA_TERMINAL
  squad_open_monitor /tmp/next next "$PWD" "$temp_directory/orca-state" ''
  [[ ! -s "$ORCA_TEST_LOG" ]] || fail
  export SQUAD_DEVKIT_ORCA_TERMINAL=manager
  ORCA_CLI_COMMAND=missing-orca squad_open_monitor /tmp/next next "$PWD" "$temp_directory/orca-state" ''
  [[ ! -s "$ORCA_TEST_LOG" ]] || fail
)
# Other terminals: split APIs where they exist, otherwise one dashboard window.
export PANES_LOG="$temp_directory/panes"
for tool in wezterm kitten zellij x-terminal-emulator; do
  cat >"$test_bin/$tool" <<EOF
#!/usr/bin/env bash
printf '$tool %s\n' "\$*" >>"\$PANES_LOG"
[[ -n "\${FAKE_PANE_FAIL:-}" ]] && exit 1
[[ "$tool" == wezterm && "\$2" == split-pane ]] && echo 7\$(grep -c split-pane "\$PANES_LOG")
[[ "$tool" == kitten ]] && echo 9\$(grep -c 'kitten @ launch' "\$PANES_LOG")
exit 0
EOF
  chmod +x "$test_bin/$tool"
done
WEZTERM_PANE=3 "$worker" wez-1 --engine codex --no-worktree --brief 'WezTerm pane' >/dev/null
WEZTERM_PANE=3 "$worker" wez-2 --engine codex --no-worktree --brief 'WezTerm stacked' >/dev/null
grep -q '^wezterm cli split-pane --pane-id 3 --right --percent 40 --cwd .* -- .*wez-1-.*\.monitor\.sh$' "$PANES_LOG"
grep -q '^wezterm cli activate-pane --pane-id 3$' "$PANES_LOG"
grep -q '^wezterm cli split-pane --pane-id 71 --bottom --cwd .* -- .*wez-2-.*\.monitor\.sh$' "$PANES_LOG"
KITTY_WINDOW_ID=5 "$worker" kit-1 --engine codex --no-worktree --brief 'Kitty pane' >/dev/null
KITTY_WINDOW_ID=5 "$worker" kit-2 --engine codex --no-worktree --brief 'Kitty stacked' >/dev/null
grep -q '^kitten @ launch --keep-focus --match id:5 --location=vsplit --title kit-1 · codex --cwd ' "$PANES_LOG"
grep -q '^kitten @ launch --keep-focus --match id:91 --location=hsplit --title kit-2 · codex ' "$PANES_LOG"
ZELLIJ=0 ZELLIJ_SESSION_NAME=main "$worker" zel-1 --engine codex --no-worktree --brief 'Zellij pane' >/dev/null
grep -q '^zellij run --floating --close-on-exit --name zel-1 · codex --cwd .* -- .*zel-1-.*\.monitor\.sh$' "$PANES_LOG"
cat >"$test_bin/osascript" <<'EOF'
#!/usr/bin/env bash
printf 'osascript %s\n' "$*" >>"$PANES_LOG"
[[ "$1" == *iterm.applescript ]] && echo "ITERM-NEW"
exit 0
EOF
chmod +x "$test_bin/osascript"
ITERM_SESSION_ID=w0t0p0:MANAGER-UUID "$worker" it-1 --engine codex --no-worktree --brief 'iTerm pane' >/dev/null
ITERM_SESSION_ID=w0t0p0:MANAGER-UUID "$worker" it-2 --engine codex --no-worktree --brief 'iTerm stacked' >/dev/null
grep -q '^osascript .*squad-worker-iterm.applescript MANAGER-UUID  .*it-1-.*monitor.sh it-1 · codex$' "$PANES_LOG"
grep -q '^osascript .*squad-worker-iterm.applescript MANAGER-UUID ITERM-NEW .*it-2-.*monitor.sh it-2 · codex$' "$PANES_LOG"
# Terminal.app has no split API: one dashboard window per manager session.
: >"$PANES_LOG"
TERM_PROGRAM=Apple_Terminal SQUAD_DEVKIT_MANAGER_WRAPPER_PID=4242 "$worker" app-1 --engine codex --no-worktree --brief 'Terminal.app' >/dev/null
TERM_PROGRAM=Apple_Terminal SQUAD_DEVKIT_MANAGER_WRAPPER_PID=4242 "$worker" app-2 --engine codex --no-worktree --brief 'Terminal.app again' >/dev/null
[[ "$(grep -c 'tell application "Terminal" to do script' "$PANES_LOG")" == 1 ]] || fail
grep -q 'do script "exec .*dashboard.sh"' "$PANES_LOG"
grep -q 'squad-worker-monitor.sh --all ' .squad/workers/dashboard.sh
# Kitty without remote control, and Linux desktops, fall back to the dashboard.
: >"$PANES_LOG"
rm -f .squad/workers/.dashboard-*
KITTY_WINDOW_ID=5 FAKE_PANE_FAIL=1 DISPLAY=:0 SQUAD_DEVKIT_MANAGER_WRAPPER_PID=4343 \
  "$worker" kit-3 --engine codex --no-worktree --brief 'No remote control' >/dev/null
grep -q '^kitten @ launch' "$PANES_LOG"
for _ in 1 2 3 4 5; do grep -q '^x-terminal-emulator -e .*dashboard.sh$' "$PANES_LOG" && break; sleep 0.2; done
grep -q '^x-terminal-emulator -e .*dashboard.sh$' "$PANES_LOG"
: >"$PANES_LOG"
SQUAD_WORKER_DASHBOARD=0 DISPLAY=:0 SQUAD_DEVKIT_MANAGER_WRAPPER_PID=4444 \
  "$worker" none-1 --engine codex --no-worktree --brief 'No dashboard' >/dev/null
[[ ! -s "$PANES_LOG" ]] || fail
rm "$test_bin/wezterm" "$test_bin/kitten" "$test_bin/zellij" "$test_bin/x-terminal-emulator"
# The live monitor never clears the screen: it appends activity and rewrites
# only its status line, so panes do not flicker.
flicker="$temp_directory/flicker"
mkdir -p "$flicker"
: >"$flicker/run.log"
printf 'worker=live-1\nengine=codex\nprofile=high\nrole=dev\ntitle=Live run\ntask=t-live\nstate=running\npid=%s\nstarted=%s\nlog=%s\nreport=%s\n' \
  "$$" "$(date +%s)" "$flicker/run.log" "$flicker/run.md" >"$flicker/run.status"
(
  sleep 1.2
  echo '{"type":"item.completed","item":{"id":"1","type":"command_execution","command":"make test","exit_code":0}}' >>"$flicker/run.log"
  sleep 1.2
  printf 'All good.\n' >"$flicker/run.md"
  printf 'state=completed\nfinished=%s\n' "$(date +%s)" >>"$flicker/run.status"
) &
monitor_command="SQUAD_WORKER_PANE_HOLD=1 COLUMNS=80 $repo_root/scripts/squad-worker-monitor.sh $flicker/run.status"
if script --version >/dev/null 2>&1; then
  script -q -c "$monitor_command" "$flicker/tty" </dev/null >/dev/null 2>&1
else
  script -q "$flicker/tty" bash -c "$monitor_command" </dev/null >/dev/null 2>&1
fi
wait
# Exactly one clear, at start-up; after that only the status line is rewritten.
[[ "$(LC_ALL=C grep -o "$(printf '\033\\[2J')" "$flicker/tty" | wc -l | tr -d ' ')" == 1 ]] || fail
visible="$(LC_ALL=C sed -e "s/$(printf '\033')\\[[0-9;?]*[A-Za-z]//g" "$flicker/tty")"
[[ "$visible" == *'● RUNNING '*'✓ make test'*'✓ COMPLETED in '*'1 call · 0 failed'*'All good.'* ]] || fail

# After a merge the worktree is gone, so --diff reports it.
[[ "$("$worker" --diff wt-1 2>&1 || true)" == *'No worktree for wt-1'* ]] || fail

# Every engine joins the squad under its own client type, or under the closest
# client an older squad accepts (squad 0.7.6 knows claude, codex, gemini,
# opencode only).
probe_workspace="$temp_directory/client-probe"
mkdir -p "$probe_workspace"
(cd "$probe_workspace" && squad init >/dev/null)
for engine in grok agy ccr claude codex opencode; do
  expected="$engine"
  if ! (cd "$probe_workspace" && squad join "probe-$engine" --client "$engine" >/dev/null 2>&1); then
    case "$engine" in
      ccr) expected=claude ;;
      *) expected=codex ;;
    esac
  fi
  "$worker" "cl-$engine" --engine "$engine" --no-worktree --brief "Client $engine" >/dev/null 2>&1 || true
  [[ "$(sqlite3 .squad/messages.db "SELECT client_type FROM agents WHERE id LIKE 'cl-$engine%'" | head -n 1)" == "$expected" ]] || fail
done
[[ "$("$worker" w --engine gemini --brief x 2>&1 || true)" == *'Unknown engine'* ]] || fail
[[ "$("$worker" w --engine bogus --brief x 2>&1 || true)" == *'Unknown engine'* ]] || fail

# The stall watchdog also covers engines that print the report on stdout.
for engine in grok agy; do
  status=0
  FAKE_PLAIN_SLEEP=31 SQUAD_WORKER_STALL_SECONDS=2 "$worker" "stall-$engine" --engine "$engine" --no-worktree \
    --brief 'Silent' >/dev/null 2>"$temp_directory/error" || status=$?
  [[ "$status" == 124 ]] || fail
  grep -q "stall-$engine ($engine) no output" "$temp_directory/error"
  grep -qx 'state=failed' .squad/workers/stall-$engine-*.status
  sleep 1
  ! kill -0 "$(cat "$WORKER_TEST_LOG.pid")" 2>/dev/null || fail
done
# Steady output keeps a non-streaming engine alive past the stall limit.
FAKE_PLAIN_BEATS=5 SQUAD_WORKER_STALL_SECONDS=3 "$worker" beat-1 --engine agy --no-worktree \
  --brief 'Chatty' >/dev/null 2>&1
grep -qx 'state=completed' .squad/workers/beat-1-*.status
# SQUAD_WORKER_STALL_SECONDS=0 disables the watchdog.
FAKE_PLAIN_SLEEP=4 SQUAD_WORKER_STALL_SECONDS=0 "$worker" nostall-1 --engine grok --no-worktree \
  --brief 'Quiet' >/dev/null 2>&1
grep -qx 'state=completed' .squad/workers/nostall-1-*.status
# The overall timeout still wins.
status=0
FAKE_PLAIN_SLEEP=30 SQUAD_WORKER_TIMEOUT_SECONDS=2 "$worker" to-1 --engine grok --no-worktree \
  --brief 'Too long' >/dev/null 2>"$temp_directory/error" || status=$?
[[ "$status" == 124 ]] || fail
grep -q 'to-1 (grok) timed out' "$temp_directory/error"
# Only fake engines run with bypass flags; inheritance and standalone opt-in agree.
for engine in claude codex agy; do
  for opt_in in flag inherited; do
    : >"$WORKER_TEST_LOG"
    if [[ "$opt_in" == flag ]]; then
      "$worker" "yolo-$engine-$opt_in" --engine "$engine" --no-worktree --yolo --brief 'Check opt-in' >/dev/null
    else
      SQUAD_DEVKIT_YOLO=1 "$worker" "yolo-$engine-$opt_in" --engine "$engine" --no-worktree --brief 'Check inheritance' >/dev/null
    fi
    call="$(grep "^$engine:" "$WORKER_TEST_LOG")"
    case "$engine" in
      codex) [[ "$call" == *'--dangerously-bypass-approvals-and-sandbox'* && "$call" != *'--sandbox '* ]] || fail ;;
      claude) [[ "$call" == *'--dangerously-skip-permissions'* && "$call" == *'"enabled":false'* && "$call" != *'--permission-mode '* ]] || fail ;;
      agy) [[ "$call" == *'--dangerously-skip-permissions'* && "$call" != *'--sandbox '* ]] || fail ;;
    esac
  done
done
if SQUAD_DEVKIT_YOLO=true "$worker" yolo-invalid --engine codex --brief test > /dev/null 2>"$temp_directory/error"; then fail; fi
grep -q 'SQUAD_DEVKIT_YOLO must be 0 or 1' "$temp_directory/error"
for opts in '--yolo --sandbox' '--sandbox --yolo' '--yolo --sandbox --no-sandbox'; do
  if "$worker" yolo-conflict --engine codex $opts --brief test >/dev/null 2>&1; then fail; fi
done
if SQUAD_DEVKIT_YOLO=1 "$worker" yolo-conflict --engine codex --sandbox --brief test >/dev/null 2>&1; then fail; fi
if SQUAD_WORKER_SANDBOX=1 "$worker" yolo-conflict --engine claude --yolo --brief test >/dev/null 2>&1; then fail; fi
for engine in grok opencode ccr; do
  if "$worker" yolo-unsupported --engine "$engine" --yolo --brief test >/dev/null 2>&1; then fail; fi
done

bash "$repo_root/tests/squad_worker_agy_lifecycle_smoke.sh"

echo 'PASS: squad-worker engines, worktrees, panes in every terminal, flicker-free monitor, MCP filtering, task lifecycle, watchdog, stop, questions, and failure reporting'
