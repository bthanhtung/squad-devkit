#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/.squad/workers" "$tmp/bin"
log="$tmp/.squad/workers/run.log"
status="$tmp/.squad/workers/run.status"
printf 'worker=w\nengine=codex\nrole=dev\nstate=completed\nstarted=1\nfinished=2\nlog=%s\n' "$log" >"$status"
cat >"$log" <<'EVENTS'
{"type":"item.completed","item":{"type":"reasoning","text":"PRIVATE_THINKING"}}
{"type":"item.completed","item":{"type":"agent_message","text":"Public progress\u001b[31m"}}
{"type":"item.completed","item":{"type":"command_execution","command":"make test","exit_code":0,"aggregated_output":"Tests passed"}}
{"type":"item.completed","item":{"type":"reasoning","text":"PRIVATE_LAST"}}
{"type":"item.completed"
EVENTS
cat >"$tmp/bin/squad" <<'SCRIPT'
#!/usr/bin/env bash
if [[ "$1" == help ]]; then echo '  squad run list'; exit; fi
jq -n --arg log "$TEST_LOG" '[{worker_id:"w",engine:"codex",state:"completed",details:{role:"dev",started:"1",finished:"2",log:$log},metrics:{calls:1,tokens_in:2,tokens_out:3}}]'
SCRIPT
chmod +x "$tmp/bin/squad"
export TEST_LOG="$log"
for mode in one indexed fallback; do
  case "$mode" in
    one) frame="$("$root/scripts/squad-worker-monitor.sh" "$status" --once)" ;;
    indexed) frame="$(PATH="$tmp/bin:$PATH" "$root/scripts/squad-worker-monitor.sh" --all "$tmp/.squad/workers" --once)" ;;
    fallback) frame="$(PATH="/usr/bin:/bin:/opt/homebrew/bin" "$root/scripts/squad-worker-monitor.sh" --all "$tmp/.squad/workers" --once)" ;;
  esac
  [[ "$frame" != *PRIVATE* && "$frame" != *$'\033'* ]] || { echo "private or control data: $mode" >&2; exit 1; }
  if [[ "$mode" == indexed ]]; then [[ "$frame" == *' 5  '* ]]; fi
  [[ "$frame" == *'make test'* ]] || { echo "missing activity: $mode" >&2; exit 1; }
  if [[ "$mode" == one ]]; then [[ "$frame" == *'Public progress'* && "$frame" == *'Tests passed'* ]]; fi
done
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"PRIVATE"},{"type":"text","text":"Claude progress"}]}}' >"$log"
printf 'worker=w\nengine=claude\nstate=completed\nstarted=1\nfinished=2\nlog=%s\n' "$log" >"$status"
frame="$("$root/scripts/squad-worker-monitor.sh" "$status" --once)"
[[ "$frame" == *'Claude progress'* && "$frame" != *PRIVATE* ]]
printf '%s\n' '{"event":"result","result":{"response":"AGY public result"}}' >"$log"
printf 'worker=w\nengine=agy\nstate=completed\nstarted=1\nfinished=2\nlog=%s\n' "$log" >"$status"
frame="$("$root/scripts/squad-worker-monitor.sh" "$status" --once)"
[[ "$frame" == *'AGY public result'* ]]
printf '#!/bin/sh\nexit 1\n' >"$tmp/bin/jq"
chmod +x "$tmp/bin/jq"
frame="$(PATH="$tmp/bin:$PATH" "$root/scripts/squad-worker-monitor.sh" "$status" --once)"
[[ "$frame" != *'AGY public result'* && "$frame" != *'response'* ]]
echo 'PASS: public worker progress'
