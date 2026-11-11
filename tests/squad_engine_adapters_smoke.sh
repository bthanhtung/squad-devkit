#!/usr/bin/env bash
# Engine adapter protocol (scripts/lib/squad-engine.sh, scripts/lib/engines/*.sh)
# and engine-specific monitor parsing. Runs under the system Bash 3.2 on macOS.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "Assertion failed at line ${BASH_LINENO[0]}" >&2; exit 1; }

# shellcheck source=../scripts/lib/squad-worker-model.sh
source "$root/scripts/lib/squad-worker-model.sh"
# shellcheck source=../scripts/lib/squad-engine.sh
source "$root/scripts/lib/squad-engine.sh"
require_command() { command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1" >&2; exit 1; }; }

# Every adapter loads and defines the four protocol functions.
for name in claude codex opencode grok agy ccr; do
  squad_engine_load "$name" || fail
  [[ "$squad_engine_loaded" == "$name" ]] || fail
  for function in check_deps build_command run_and_extract_report reported_models; do
    declare -F "engine_${name}_$function" >/dev/null || fail
  done
done

# Unknown names never reach source, including path tricks.
printf 'touch %q\n' "$tmp/sourced" >"$tmp/evil.sh"
for name in gemini '' "../../../../../../$tmp/evil" 'claude/../codex' 'CLAUDE'; do
  if squad_engine_load "$name" 2>"$tmp/error"; then fail; fi
  grep -q '^Unknown engine: .* (use claude, codex, opencode, grok, agy, or ccr)$' "$tmp/error" || fail
done
[[ ! -e "$tmp/sourced" ]] || fail
if squad_engine eval true 2>/dev/null; then fail; fi
# A missing protocol function is a load error.
(
  unset -f engine_grok_build_command engine_grok_run_and_extract_report engine_grok_reported_models
  squad_engine_directory="$tmp/engines"
  mkdir -p "$squad_engine_directory"
  printf 'engine_grok_check_deps() { :; }\n' >"$squad_engine_directory/grok.sh"
  if squad_engine_load grok 2>"$tmp/error"; then exit 1; fi
  grep -q 'does not define engine_grok_build_command' "$tmp/error"
) || fail

# Shared worker globals the adapters read.
mkdir -p "$tmp/bin" "$tmp/workspace/project"
workspace_root="$tmp/workspace"
engine_directory="$tmp/workspace/project"
log_file="$tmp/run.log"
output_directory="$tmp"
absolute_log="$tmp/run.log"
absolute_report="$tmp/run.md"
prompt='do the task'
model=opus
model_effort=""
model_arguments=(--model opus)
profile=""
keep_mcp=()
all_mcp=0
sandbox_mode=1
yolo=0
: >"$log_file"

# Claude: sandboxed shell, acceptEdits, strict MCP; YOLO and --no-sandbox switch both.
squad_engine_load claude
squad_engine build_command || fail
command_line="${engine_command[*]}"
[[ "$command_line" == "claude -p --model opus --strict-mcp-config --disable-slash-commands --no-session-persistence --tools Read,Edit,Write,Glob,Grep,Bash --permission-mode acceptEdits --settings "*'"autoAllowBashIfSandboxed":true'*"--add-dir $workspace_root --output-format stream-json --verbose do the task" ]] || fail
yolo=1 sandbox_mode=0 squad_engine build_command || fail
[[ "${engine_command[*]}" == *'--dangerously-skip-permissions --settings {"sandbox":{"enabled":false}}'* ]] || fail
[[ "${engine_command[*]}" != *--permission-mode* ]] || fail

# Codex: every configured MCP server except --mcp ones is disabled without copying
# credentials; a failed listing or a missing bearer token refuses the launch (3).
cat >"$tmp/bin/codex" <<EOF
#!/usr/bin/env bash
[[ "\$1 \$2 \$3" == 'mcp list --json' ]] || exit 9
[[ -z "\${CODEX_MCP_FAIL:-}" ]] || exit 1
printf '%s' '[{"name":"local","enabled":true,"transport":{"type":"stdio","command":"secret-cmd"}},
  {"name":"remote","enabled":true,"transport":{"type":"streamable_http","url":"https://x","bearer_token_env_var":"REMOTE_TOKEN"}},
  {"name":"other","transport":{"type":"sse"}},{"name":"off","enabled":false,"transport":{"type":"stdio"}}]'
EOF
chmod +x "$tmp/bin/codex"
PATH="$tmp/bin:$PATH"
squad_engine_load codex
squad_engine build_command || fail
command_line="${engine_command[*]}"
[[ "$command_line" == *'-c mcp_servers.local={enabled=false,command="false"}'* ]] || fail
[[ "$command_line" == *'-c mcp_servers.remote={enabled=false,url="http://127.0.0.1"}'* ]] || fail
[[ "$command_line" == *'-c mcp_servers.other.enabled=false'* ]] || fail
[[ "$command_line" != *mcp_servers.off* && "$command_line" != *secret-cmd* && "$command_line" != *https://x* ]] || fail
[[ "$command_line" == "codex exec --json --cd $engine_directory --ephemeral --skip-git-repo-check --sandbox workspace-write --add-dir $workspace_root "*"--model opus --output-last-message $absolute_report do the task" ]] || fail
keep_mcp=(remote)
if squad_engine build_command 2>"$tmp/error"; then fail; else [[ $? == 3 ]] || fail; fi
grep -q 'remote (needs REMOTE_TOKEN)' "$tmp/error" || fail
grep -q 'remote (needs REMOTE_TOKEN)' "$log_file" || fail
REMOTE_TOKEN=set squad_engine build_command || fail
[[ "${engine_command[*]}" != *mcp_servers.remote* ]] || fail
keep_mcp=()
if CODEX_MCP_FAIL=1 squad_engine build_command 2>"$tmp/error"; then fail; else [[ $? == 3 ]] || fail; fi
grep -q 'refusing an unfiltered worker launch' "$tmp/error" || fail
all_mcp=1 squad_engine build_command || fail
[[ "${engine_command[*]}" != *mcp_servers* ]] || fail
model_effort=high profile=deep yolo=1 squad_engine build_command || fail
[[ "${engine_command[*]}" == *'--profile deep --ephemeral --skip-git-repo-check --dangerously-bypass-approvals-and-sandbox'* ]] || fail
[[ "${engine_command[*]}" == *'--model opus -c model_reasoning_effort="high"'* ]] || fail
[[ "${model_arguments[*]}" == '--model opus' ]] || fail
engine_directory="$workspace_root" sandbox_mode=0 squad_engine build_command || fail
[[ "${engine_command[*]}" == *'--sandbox danger-full-access'* && "${engine_command[*]}" != *--add-dir* ]] || fail

# Grok and OpenCode print the report on stdout.
for name in grok opencode; do
  printf '#!/usr/bin/env bash\necho "report from %s $*"\necho diagnostics >&2\n' "$name" >"$tmp/bin/$name"
  chmod +x "$tmp/bin/$name"
  squad_engine_load "$name"
  squad_engine build_command || fail
  squad_engine run_and_extract_report || fail
  grep -q "^report from $name .*--model opus" "$absolute_report" || fail
  grep -q '^diagnostics$' "$absolute_log" || fail
  [[ -z "$(squad_engine reported_models "$absolute_log")" ]] || fail
done

# AGY: report from the terminal SUCCESS; stream rejection is logged, not reported.
cat >"$tmp/bin/agy" <<'EOF'
#!/usr/bin/env bash
echo '{"event":"step_update"}'
printf '{"event":"result","result":{"status":"%s","response":"agy report"}}\n' "${AGY_STATUS:-SUCCESS}"
EOF
chmod +x "$tmp/bin/agy"
squad_engine_load agy
model_effort=low squad_engine build_command || fail
[[ "${engine_command[*]}" == "agy -p do the task --mode accept-edits --output-format stream-json --effort low --model opus" ]] || fail
: >"$absolute_report"
squad_engine run_and_extract_report || fail
[[ "$(cat "$absolute_report")" == 'agy report' ]] || fail
: >"$absolute_report"
AGY_STATUS=FAILED squad_engine run_and_extract_report || fail
[[ ! -s "$absolute_report" ]] || fail
grep -q 'AGY stream rejected: terminal status FAILED' "$absolute_log" || fail

# Claude-shaped streams name their models; codex events do not.
printf '%s\n' '{"type":"assistant","message":{"model":"m-one"}}' '{"type":"result","result":"done","modelUsage":{"m-two":{}}}' >"$tmp/events"
for name in claude ccr agy; do
  squad_engine_load "$name"
  [[ "$(squad_engine reported_models "$tmp/events")" == m-one,m-two ]] || fail
  [[ "$(squad_worker_reported_models "$name" "$tmp/events")" == m-one,m-two ]] || fail
done
squad_engine_load codex
[[ -z "$(squad_engine reported_models "$tmp/events")" ]] || fail
cp "$tmp/events" "$absolute_log"
squad_engine_stream_report
[[ "$(cat "$absolute_report")" == done ]] || fail

# The worker CLI keeps its unknown-engine error and exit status.
if env -u SQUAD_MANAGER_ID -u SQUAD_DEVKIT_YOLO "$root/scripts/squad-worker.sh" w --engine ../claude --no-plan test --brief x 2>"$tmp/error"; then fail; else [[ $? == 2 ]] || fail; fi
[[ "$(cat "$tmp/error")" == 'Unknown engine: ../claude (use claude, codex, opencode, grok, agy, or ccr)' ]] || fail

# Monitor: each engine parses only its own stream format; no engine parses all.
mkdir -p "$tmp/mon/.squad/workers"
monitor_log="$tmp/mon/.squad/workers/run.log"
printf '%s\n' \
  '{"type":"item.completed","item":{"id":"1","type":"command_execution","command":"make","exit_code":0}}' \
  '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t","name":"Read","input":{"file_path":"a"}}]}}' \
  '{"event":"step_update","step_update":{"step_type":"tool","state":"DONE","tool_name":"read_file","tool_info":{"parameters":{"Path":"b"}}}}' \
  >"$monitor_log"
for case in codex:1 claude:1 ccr:1 agy:2 grok:0 opencode:0 :3; do
  name="${case%%:*}"
  printf 'worker=w\nengine=%s\nstate=completed\nstarted=1\nfinished=2\nlog=%s\n' "$name" "$monitor_log" >"$tmp/mon/.squad/workers/run.status"
  frame="$("$root/scripts/squad-worker-monitor.sh" "$tmp/mon/.squad/workers/run.status" --once)"
  [[ "$frame" == *" ${case#*:} "*call* ]] || { echo "monitor engine=$name" >&2; fail; }
done
printf 'worker=w\nengine=codex\nstate=completed\nstarted=1\nfinished=2\nlog=%s\n' "$monitor_log" >"$tmp/mon/.squad/workers/run.status"
frame="$("$root/scripts/squad-worker-monitor.sh" --all "$tmp/mon/.squad/workers" --once)"
[[ "$frame" == *w*codex* ]] || fail

echo 'PASS: engine adapters, validated dispatch, MCP filtering, and engine-specific monitor parsing'
