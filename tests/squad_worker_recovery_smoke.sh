#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d /tmp/squad-recovery.XXXXXX)"
trap 'rc=$?; if (( rc != 0 )); then cat "$tmp/err" >&2; fi; rm -rf "$tmp"' EXIT
worker="$repo/scripts/squad-worker.sh"
printf 'engine_pid=%s\nengine_pgid=99999999\nengine_started=wrong time\n' "$$" >"$tmp/reused.status"
if "$worker" --engine-alive "$tmp/reused.status"; then echo 'reused PID considered alive' >&2; exit 1; fi
printf 'engine_pid=%s\nengine_pgid=99999999\n' "$$" >"$tmp/missing.status"
"$worker" --engine-alive "$tmp/missing.status"
"$worker" --engine-alive "$tmp/nonexistent.status"
printf 'engine_pid=%s\nengine_pgid=99999999\nengine_started=%s\n' "$$" "$(LC_ALL=C ps -p "$$" -o lstart= | awk '{$1=$1; print}')" >"$tmp/current.status"
"$worker" --engine-alive "$tmp/current.status"
mkdir -p "$tmp/failed-ps"
printf '#!/bin/sh\nexit 1\n' >"$tmp/failed-ps/ps"
chmod +x "$tmp/failed-ps/ps"
PATH="$tmp/failed-ps:$PATH" "$worker" --engine-alive "$tmp/reused.status"
echo 'PASS: recovery liveness' 
unset SQUAD_DEVKIT_WORKSPACE SQUAD_WORKTREE_WORKSPACE SQUAD_MANAGER_ID SQUAD_WORKER_REQUIRE_PLAN
unset TMUX TMUX_PANE HERDR_ENV HERDR_PANE_ID
export HOME="$tmp/home" TERM_PROGRAM=test-terminal SQUAD_DEVKIT_NOTIFY=0 SQUAD_WORKER_PANES=0 SQUAD_WORKER_VIEW=orchestration
mkdir -p "$HOME" "$tmp/bin" "$tmp/ws"
export PATH="$tmp/bin:$PATH"
cat >"$tmp/bin/claude" <<'ENGINE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$RECOVERY_LAUNCHES"
printf 'changed\n' >> tracked.txt
sleep "${RECOVERY_SLEEP:-2}"
echo '{"type":"result","result":"Done"}'
ENGINE
chmod +x "$tmp/bin/claude"
export RECOVERY_LAUNCHES="$tmp/launches"
cd "$tmp/ws"
squad init >/dev/null
cp "$repo/templates/devkit/dev.md" .squad/roles/dev.md
squad join manager --role manager-devkit --client claude --protocol-version 2 >/dev/null
git init -q
git config user.email test@example.invalid
git config user.name test
printf initial > tracked.txt
git add tracked.txt
git commit -qm initial
mkdir -p .squad/plans
cat > .squad/plans/recovery.md <<'PLAN'
# Recovery
## Triage
- Risk: low
- Complexity: low
- squad-route: {"configured":false}
## Goal
Resume.
## Acceptance
- true
## Tasks
- recover (claude, dev): test. Files: tracked.txt.
PLAN
SQUAD_WORKER_DETACHED=1 "$worker" recover --engine claude --model test-model --model-tier strong --worktree --plan .squad/plans/recovery.md --plan-task recover --own tracked.txt --verify true --gate $'first=true\ntrue' --gate second=true --expect-file tracked.txt --loop 2 --brief 'original recovery brief' >"$tmp/out" 2>"$tmp/err"
latest() { ls -t .squad/workers/recover-*.status | head -n 1; }
get() { sed -n "s/^$2=//p" "$1" | tail -n 1; }
set_key() {
  local file="$1" key="$2" value="$3"
  awk -v key="$key" 'index($0,key "=") != 1' "$file" >"$tmp/status"
  printf '%s=%s\n' "$key" "$value" >>"$tmp/status"
  mv "$tmp/status" "$file"
}
original="$(latest)"
# The engine group must exclude unrelated live processes in the wrapper group.
[[ "$(get "$original" engine_pgid)" == "$(get "$original" engine_pid)" ]]
[[ "$(get "$original" engine_pgid)" != "$(ps -p "$$" -o pgid= | awk '{$1=$1; print}')" ]]
if "$worker" --engine-alive "$original"; then echo 'dead engine group considered alive' >&2; exit 1; fi
worktree="$(get "$original" worktree)"
[[ -d "$worktree" ]]
[[ -s "${original%.status}.brief.md" ]]
grep -qx 'sandbox=workspace-write' "$original"
# Synthesize a dead wrapper; keep a real engine process alive in another group.
perl -MPOSIX -e 'POSIX::setsid(); exec "sleep", "60"' &
alive_pid=$!
trap 'rc=$?; if (( rc != 0 )); then cat "$tmp/err" >&2; fi; kill "$alive_pid" 2>/dev/null || true; rm -rf "$tmp"' EXIT
sleep 1
set_key "$original" state running
set_key "$original" pid 99999999
set_key "$original" engine_pid "$alive_pid"
set_key "$original" engine_pgid "$(ps -p "$alive_pid" -o pgid= | awk '{$1=$1; print}')"
set_key "$original" engine_started "$(LC_ALL=C ps -p "$alive_pid" -o lstart= | awk '{$1=$1; print}')"
"$worker" --list >"$tmp/list"
grep -qx 'state=lost' "$original"
if "$worker" --resume recover >"$tmp/out" 2>"$tmp/err"; then exit 1; fi
grep -q 'squad-worker --stop recover' "$tmp/err"
kill -9 "$alive_pid"
wait "$alive_pid" 2>/dev/null || true
cp .squad/plans/recovery.md "$tmp/original-plan"
sed 's/test. Files/changed. Files/' "$tmp/original-plan" >.squad/plans/recovery.md
if "$worker" --resume recover >"$tmp/out" 2>"$tmp/err"; then echo 'changed task resumed' >&2; exit 1; fi
grep -q 'task recover changed since its run; use squad-worker --run-plan' "$tmp/err"
cp "$tmp/original-plan" .squad/plans/recovery.md
"$worker" --resume recover >"$tmp/out" 2>"$tmp/err"
resumed="$(latest)"
grep -qx 'verify=pass' "$resumed"
grep -qx 'state=completed' "$resumed"
[[ "$resumed" != "$original" ]]
for key in model model_tier owned verify_command_hex plan project worktree sandbox_enabled gates expect_files loop_max; do
  [[ "$(get "$original" "$key")" == "$(get "$resumed" "$key")" ]]
done
grep -q 'Previous run was interrupted' "${resumed%.status}.brief.md"
grep -q 'original recovery brief' "${resumed%.status}.brief.md"
# Foreign and legacy status ownership remains untouched and visible as unknown.
set_key "$resumed" state running
set_key "$resumed" host foreign-host
"$worker" --list >"$tmp/list"
grep -q 'ownership=unknown' "$tmp/list"
grep -qx 'state=running' "$resumed"
if "$worker" --resume recover >"$tmp/out" 2>"$tmp/err"; then exit 1; fi
set_key "$resumed" host ''
"$worker" --list >"$tmp/list"
grep -q 'ownership=unknown' "$tmp/list"
if "$worker" --resume recover >"$tmp/out" 2>"$tmp/err"; then exit 1; fi
# Reused wrapper PID reconciles to lost; missing engine timestamp blocks resume.
set_key "$resumed" host "$(hostname -s 2>/dev/null || uname -n)"
set_key "$resumed" pid "$$"
set_key "$resumed" process_started 'old identity'
set_key "$resumed" engine_pid 99999999
set_key "$resumed" engine_pgid 99999999
set_key "$resumed" engine_started ''
"$worker" --list >"$tmp/list"
grep -qx 'state=lost' "$resumed"
if "$worker" --resume recover >"$tmp/out" 2>"$tmp/err"; then exit 1; fi
set_key "$resumed" engine_started 'old identity'
# A foreign claim is never reclaimed; a dead local claim can be reclaimed.
claim=.squad/workers/.resume-recover.lock
mkdir "$claim"
printf 'pid=99999999\nhost=foreign-host\nstarted=1\n' >"$claim/owner"
if "$worker" --resume recover >"$tmp/out" 2>"$tmp/err"; then exit 1; fi
grep -q 'resume already in progress' "$tmp/err"
printf 'pid=99999999\nhost=%s\nstarted=1\n' "$(hostname -s 2>/dev/null || uname -n)" >"$claim/owner"
# Simultaneous resumes must produce one engine launch, even after prompt cleanup.
before="$(wc -l <"$RECOVERY_LAUNCHES")"
"$worker" --resume recover >"$tmp/one.out" 2>"$tmp/one.err" &
one=$!
"$worker" --resume recover >"$tmp/two.out" 2>"$tmp/two.err" &
two=$!
one_rc=0; two_rc=0
wait "$one" || one_rc=$?
wait "$two" || two_rc=$?
[[ $((one_rc + two_rc)) -gt 0 ]]
[[ "$one_rc" == 0 || "$two_rc" == 0 ]]
[[ $(wc -l <"$RECOVERY_LAUNCHES") -eq $((before + 1)) ]]
# Stop must terminate the dedicated engine group while this wrapper-group peer lives.
RECOVERY_SLEEP=30 SQUAD_WORKER_DETACHED=1 "$worker" stop-engine --engine claude --model test-model --model-tier strong --no-worktree --no-plan 'stop fixture' --brief stop >"$tmp/stop.out" 2>"$tmp/err" &
stop_pid=$!
stop_status=""
for ((n=0;n<200;n++)); do
  for file in .squad/workers/stop-engine-*.status; do
    [[ -f "$file" ]] || continue
    [[ -n "$(get "$file" engine_started)" ]] && stop_status="$file"
  done
  [[ -z "$stop_status" ]] || break
  sleep 0.05
done
if [[ -z "$stop_status" ]]; then kill -TERM "$stop_pid"; wait "$stop_pid" || true; echo 'engine did not start' >&2; exit 1; fi
"$worker" --engine-alive "$stop_status"
"$worker" --stop stop-engine >"$tmp/stop-result"
stop_rc=0
wait "$stop_pid" || stop_rc=$?
[[ "$stop_rc" != 0 ]]
grep -qx 'state=stopped' "$stop_status"
if "$worker" --engine-alive "$stop_status"; then echo 'stopped engine survived' >&2; exit 1; fi
kill -0 "$$"
echo 'PASS: worker recovery and dedicated engine group stop'
