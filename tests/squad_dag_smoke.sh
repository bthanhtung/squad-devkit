#!/usr/bin/env bash
set -euo pipefail
unset SQUAD_DEVKIT_WORKSPACE SQUAD_WORKTREE_WORKSPACE SQUAD_MANAGER_ID
repo="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d /tmp/squad-dag.XXXXXX)"
trap 'rc=$?; if (( rc )); then [[ ! -f out ]] || cat out >&2; fi; rm -rf "$tmp"' EXIT
source "$repo/scripts/lib/squad-plan.sh"
source "$repo/scripts/lib/squad-dag.sh"
mkdir -p "$tmp/.squad/workers"
cd "$tmp"
cat >plan.md <<'PLAN'
## Tasks
- a (codex strong, dev): first. Files: a.txt. Depends on: none. Verify: `true`
- b (codex fast, dev): second. Files: b.txt. Depends on: a.
PLAN
status_get() { sed -n "s/^$2=//p" "$1" | tail -n 1; }
reconcile_status() { :; }
cat >worker <<'WORKER'
#!/usr/bin/env bash
set -eu
if [[ "$1" == --merge ]]; then
  echo merge >>calls
  [[ "${REFUSE:-0}" == 0 ]] || exit 1
  echo merged=yes >>".squad/workers/$2.status"
  exit
fi
id="$1"; shift
printf '%s\n' "$@" >"$id.args"
plan= hash=
while (( $# )); do
  case "$1" in --plan) plan="$2";; esac
  shift
done
source "$REPO/scripts/lib/squad-plan.sh"
hash="$(plan_task_entry "$plan" "$id" | shasum -a 256 | awk '{print $1}')"
echo "$id start" >>calls
sleep "${DELAY:-0}"
printf 'engine=codex\nworker=%s\nplan=%s\nplan_task=%s\nplan_task_sha256=%s\nstate=%s\nverify=pass\ndag_attempt=%s\n' "$id" "$plan" "$id" "$hash" "${RESULT:-completed}" "${SQUAD_DAG_ATTEMPT:-}" >".squad/workers/$id.status"
echo "$id end" >>calls
WORKER
chmod +x worker
export REPO="$repo"
worker="$tmp/worker"
run() { squad_dag_run "$worker" "$@" >out 2>&1; }
expect() { local wanted="$1"; shift; local rc=0; run "$@" || rc=$?; [[ "$rc" == "$wanted" ]] || { cat out; exit 1; }; }
expect 3 --run-plan plan.md --manager mgr --dry-run
grep -q 'a.*ready.*codex strong' out
grep -q 'b.*blocked by a' out
expect 3 --run-plan plan.md --manager mgr
[[ $(grep -c 'a start' calls) == 1 ]]
grep -qx -- '--own' a.args
grep -qx 'a.txt' a.args
grep -qx 'true' a.args
! grep -q merge calls
expect 3 --run-plan plan.md --manager mgr
[[ $(grep -c 'a start' calls) == 1 ]]
expect 0 --run-plan plan.md --manager mgr --merge-if-green
expect 0 --run-plan plan.md --manager mgr
sed 's/first/changed/' plan.md >new; mv new plan.md
expect 3 --run-plan plan.md --manager mgr
grep -q 'task a changed since its run' out
expect 0 --run-plan plan.md --manager mgr --retry a --merge-if-green
for kind in duplicate unknown cycle tier; do
  case "$kind" in
    duplicate) printf '## Tasks\n- x (codex strong, dev): x. Files: x. Depends on: none.\n- x (codex strong, dev): x. Files: x. Depends on: none.\n' >bad;;
    unknown) printf '## Tasks\n- x (codex strong, dev): x. Files: x. Depends on: absent.\n' >bad;;
    cycle) printf '## Tasks\n- x (codex strong, dev): x. Files: x. Depends on: x.\n' >bad;;
    tier) printf '## Tasks\n- x (codex, dev): x. Files: x. Depends on: none.\n' >bad;;
  esac
  expect 2 --run-plan bad --manager mgr
done
# Independent tasks run together, within the job limit, then finish later waves.
rm -f .squad/workers/*.status .squad/messages.db* calls
cat >parallel.md <<'PLAN'
## Tasks
- p (codex strong, dev): p. Files: p. Depends on: none. Verify: `true`
- q (codex strong, dev): q. Files: q. Depends on: none. Verify: `true`
- r (codex strong, dev): r. Files: r. Depends on: none. Verify: `true`
PLAN
export DELAY=0.3
expect 3 --run-plan parallel.md --manager mgr --jobs 2
[[ $(head -n 2 calls | grep -c start) == 2 ]]
[[ $(grep -c start calls) == 3 ]]
awk '$2=="start" {active++; if(active>2) exit 1} $2=="end" {active--} END {if(active) exit 1}' calls
unset DELAY
rm -f .squad/workers/*.status .squad/messages.db* calls
expect 3 --run-plan parallel.md --manager mgr --jobs 1 --max-launches 1
[[ $(grep -c start calls) == 1 ]]
# A failed root is terminal, blocks its dependent, and requires explicit retry.
rm -f .squad/workers/*.status .squad/messages.db* calls
export RESULT=failed
expect 3 --run-plan plan.md --manager mgr --merge-if-green
expect 3 --run-plan plan.md --manager mgr
[[ $(grep -c start calls) == 1 ]]
grep -q 'b / blocked by a' out
expect 3 --run-plan plan.md --manager mgr --retry a
[[ $(grep -c start calls) == 2 ]]
unset RESULT
# Running and terminal verification states are never silently relaunched.
for state in running lost stopped; do
  printf 'state=%s\n' "$state" >>.squad/workers/a.status
  expect 3 --run-plan plan.md --manager mgr
  [[ $(grep -c start calls) == 2 ]]
done
for verify in fail timeout; do
  printf 'state=completed\nverify=%s\n' "$verify" >>.squad/workers/a.status
  expect 3 --run-plan plan.md --manager mgr
  [[ $(grep -c start calls) == 2 ]]
done
# Merge refusal stops the dependent, and never requests a review override.
rm -f .squad/workers/*.status .squad/messages.db* calls
export REFUSE=1
expect 3 --run-plan plan.md --manager mgr --merge-if-green
! grep -q 'b start' calls
grep -q 'Waiting on manager' out
unset REFUSE
# Same task IDs in another plan cannot satisfy this plan.
cp plan.md other.md
expect 3 --run-plan other.md --manager mgr
[[ $(grep -c 'a start' calls) == 2 ]]
# A live runner excludes a second invocation. Foreign locks stay untouched;
# a provably dead local owner can be reclaimed.
rm -f .squad/workers/*.status .squad/messages.db* calls
export DELAY=2
run --run-plan parallel.md --manager mgr --jobs 1 &
runner=$!
for ((n=0;n<100;n++)); do [[ -f calls ]] && break; sleep 0.05; done
rc=0
squad_dag_run "$worker" --run-plan parallel.md --manager mgr >second 2>&1 || rc=$?
[[ "$rc" == 3 ]]
grep -q 'Another runner' second
wait "$runner" || [[ "$?" == 3 ]]
unset DELAY
if [[ "${SQUAD_RUST_DISABLE:-0}" == 1 ]]; then
lock=".squad/run-plan/$(printf '%s' "$tmp/parallel.md" | shasum -a 256 | awk '{print $1}').lock"
mkdir "$lock"
printf 'pid=99999999\nhost=foreign.invalid\nstarted=1\n' >"$lock/owner"
expect 3 --run-plan parallel.md --manager mgr --dry-run
[[ -d "$lock" ]]
printf 'pid=99999999\nhost=%s\nstarted=1\n' "$(hostname -s)" >"$lock/owner"
expect 3 --run-plan parallel.md --manager mgr --dry-run
[[ ! -d "$lock" ]]
fi
# Exercise the public command and real status writer with an isolated fake engine.
unset SQUAD_DEVKIT_MANAGER_WRAPPER_PID SQUAD_WORKER_REQUIRE_PLAN TMUX TMUX_PANE HERDR_ENV HERDR_PANE_ID
export HOME="$tmp/home" TERM_PROGRAM=test-terminal SQUAD_DEVKIT_NOTIFY=0
export SQUAD_WORKER_PANES=0 SQUAD_WORKER_DASHBOARD=0 SQUAD_WORKER_VIEW=orchestration SQUAD_WORKER_WORKTREE=0
mkdir -p "$HOME" "$tmp/bin" "$tmp/integration"
export PATH="$tmp/bin:$PATH"
cat >"$tmp/bin/claude" <<'ENGINE'
#!/usr/bin/env bash
echo '{"type":"result","result":"Done"}'
ENGINE
chmod +x "$tmp/bin/claude"
cd "$tmp/integration"
squad init >/dev/null
cp "$repo/templates/devkit/dev.md" .squad/roles/dev.md
squad join manager --role manager-devkit --client claude --protocol-version 2 >/dev/null
# A synthetic live monitor marker prevents any terminal split.
mkdir -p .squad/workers
printf '%s\n' "$$" >.squad/workers/.orchestration-m-manager.pid
cat >plan.md <<'PLAN'
# DAG integration
## Triage
- Risk: low
- Complexity: low
- squad-route: {"configured":false}
## Goal
Test dispatch.
## Tasks
- integration (claude strong, dev): exercise normal launcher. Files: tracked.txt. Depends on: none. Verify: `true`
- integration-two (claude strong, dev): second launcher. Files: two.txt. Depends on: none. Verify: `true`
- integration-three (claude strong, dev): third launcher. Files: three.txt. Depends on: none. Verify: `true`
## Acceptance
- Done.
PLAN
worker="$repo/scripts/squad-worker.sh"
rc=0
"$worker" --run-plan plan.md --manager manager --dry-run >out 2>&1 || rc=$?
[[ "$rc" == 3 ]]
grep -q 'integration / ready / claude strong' out
rc=0
"$worker" --run-plan plan.md --manager manager --jobs 3 >out 2>&1 || rc=$?
[[ "$rc" == 3 ]]
file="$(grep -l -x 'plan_task=integration' .squad/workers/integration-*.status | head -n 1)"
grep -qx 'state=completed' "$file"
grep -qx 'plan_task=integration' "$file"
hash="$(plan_task_entry "$PWD/plan.md" integration | shasum -a 256 | awk '{print $1}')"
grep -qx "plan_task_sha256=$hash" "$file"
for id in integration integration-two integration-three; do
  grep -qx 'state=completed' .squad/workers/$id-*.status
done
if [[ "${SQUAD_RUST_DISABLE:-0}" != 1 ]]; then
  cd "$(pwd -P)"
  printf 'retained payload\n' >payload.txt
  squad artifact publish --plan plan.md --task integration --attempt "$(status_get "$file" dag_attempt)" --root "$PWD" payload.txt
  squad artifact fetch --plan plan.md --from integration --dest "$PWD/consumer-artifacts"
  [[ "$(cat consumer-artifacts/payload.txt)" == 'retained payload' ]]
  [[ "$(stat -f '%Sp' consumer-artifacts/payload.txt 2>/dev/null || stat -c '%A' consumer-artifacts/payload.txt)" != *w* ]]
  if squad artifact publish --plan plan.md --task integration --attempt traversal --root "$PWD" ../payload.txt >out 2>&1; then
    echo 'Traversal publish unexpectedly succeeded' >&2; exit 1
  fi
  chmod u+w consumer-artifacts
fi
echo 'PASS: DAG runner'
