#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$root/target/debug:$PATH"
export SQUAD_DEVKIT_SESSION_START=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/.squad/workers"
cat >"$tmp/.squad/workers/legacy.status" <<EOF_STATUS
worker=legacy
engine=codex
role=dev
state=completed
started=1
finished=2
tokens_in=12
tokens_out=3
requested_model=model-r
model_source=flag
actual_model=model-a
EOF_STATUS
# Historical files import without a migration job; empty fields remain aligned.
label="$("$root/scripts/squad-worker-monitor.sh" --savings "$tmp" --text)"
[[ "$label" == 'squad saved 15 tok' ]]
frame="$("$root/scripts/squad-worker-monitor.sh" --all "$tmp/.squad/workers" --once)"
[[ "$frame" == *legacy*completed*'15'* && "$frame" == *'requested=model-r source=flag actual=model-a'* ]]
# The SQLite table keeps live call/token metrics from logs using native parsing.
printf '{"type":"item.completed","item":{"type":"command_execution","exit_code":0}}\n{"type":"turn.completed","usage":{"input_tokens":40,"output_tokens":2}}\n' >"$tmp/run.log"
printf 'log=%s\n' "$tmp/run.log" >>"$tmp/.squad/workers/legacy.status"
squad run list --json --workspace "$tmp" --directory "$tmp/.squad/workers" --metrics | jq -e '.[0].metrics.calls == 1 and .[0].metrics.tokens_in == 40 and .[0].metrics.tokens_out == 2' >/dev/null
frame="$("$root/scripts/squad-worker-monitor.sh" --all "$tmp/.squad/workers" --once)"
[[ "$frame" == *'42'* ]]
# Deleting a status file must not erase indexed history.
rm "$tmp/.squad/workers/legacy.status"
[[ "$("$root/scripts/squad-worker-monitor.sh" --savings "$tmp" --text)" == "$label" ]]
printf 'worker=new\nengine=claude\nstate=completed\nstarted=3\nfinished=4\ntokens_in=4\ntokens_out=6\n' >"$tmp/.squad/workers/new.status"
[[ "$("$root/scripts/squad-worker-monitor.sh" --savings "$tmp" --text)" == 'squad saved 15 tok · claude workers 10' ]]
# Old-binary fallback does not invoke unsupported commands.
mkdir "$tmp/bin"
cat >"$tmp/bin/squad" <<'EOF_OLD'
#!/bin/bash
[[ "$1" == help ]] && { echo 'Usage: squad init'; exit 0; }
echo 'unsupported command invoked' >&2
exit 99
EOF_OLD
chmod +x "$tmp/bin/squad"
[[ "$(PATH="$tmp/bin:$PATH" "$root/scripts/squad-worker-monitor.sh" --savings "$tmp" --text)" == 'squad saved 0 tok · claude workers 10' ]]


# Reconciliation must update both persistent representations.
source "$root/scripts/lib/squad-plan.sh"
sed -n '/^status_get() {/,/^# Status files of runs/{ /^# Status files of runs/d; p; }' "$root/scripts/squad-worker.sh" >"$tmp/helpers.sh"
source "$tmp/helpers.sh"
printf 'worker=lost-worker\nengine=codex\nstate=running\npid=999999999\n' >"$tmp/.squad/workers/lost.status"
squad_record_status "$tmp/.squad/workers/lost.status"
reconcile_status "$tmp/.squad/workers/lost.status"
squad run list --json --workspace "$tmp" | jq -e 'any(.run_name == "lost" and .state == "lost")' >/dev/null
# Database failure is visible and cannot destroy the authoritative status file.
mkdir -p "$tmp/broken/.squad/workers"
printf 'not a database' >"$tmp/broken/.squad/messages.db"
printf 'worker=w\nengine=codex\nstate=completed\n' >"$tmp/broken/.squad/workers/run.status"
squad_record_status "$tmp/broken/.squad/workers/run.status" 2>"$tmp/db-error"
grep -q 'could not index status in SQLite' "$tmp/db-error"
grep -qx 'state=completed' "$tmp/broken/.squad/workers/run.status"
# Native --all metrics select the same engine-specific stream formats as the live monitor.
mkdir -p "$tmp/metrics/.squad/workers"
cat >"$tmp/metrics/events.log" <<'EVENTS'
{"type":"item.completed","item":{"type":"command_execution"}}
{"type":"turn.completed","usage":{"input_tokens":40,"output_tokens":2}}
{"type":"assistant","message":{"content":[{"type":"tool_use"}]}}
{"type":"result","usage":{"input_tokens":10,"cache_read_input_tokens":1,"cache_creation_input_tokens":2,"output_tokens":3}}
{"event":"step_update","step_update":{"step_type":"tool","state":"DONE"}}
{"event":"result","result":{"usage":{"input_tokens":20,"cache_read_tokens":5,"output_tokens":7}}}
EVENTS
for spec in codex:1:40:2 claude:1:13:3 agy:2:38:10 unknown:3:78:12; do
  IFS=: read -r engine calls input output <<<"$spec"
  printf 'worker=w\nengine=%s\nstate=completed\nlog=%s\n' "$engine" "$tmp/metrics/events.log" >"$tmp/metrics/.squad/workers/run.status"
  squad run record --workspace "$tmp/metrics" --status-file "$tmp/metrics/.squad/workers/run.status"
  squad run list --json --workspace "$tmp/metrics" --metrics | jq -e --argjson calls "$calls" --argjson input "$input" --argjson output "$output" '.[0].metrics | .calls == $calls and .tokens_in == $input and .tokens_out == $output' >/dev/null
done
printf 'phase4_runs_smoke: ok\n'
