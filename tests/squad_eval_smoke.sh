#!/usr/bin/env bash
set -euo pipefail
unset SQUAD_DEVKIT_WORKSPACE SQUAD_WORKTREE_WORKSPACE SQUAD_MANAGER_ID
repo="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d /tmp/squad-eval.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home" SQUAD_DEVKIT_PROJECT_ROOT="$tmp/ws"
mkdir -p "$HOME" "$tmp/ws/.squad/workers"
devkit="$repo/scripts/squad-devkit.sh"
"$devkit" --eval >"$tmp/out"
grep -qx 'no runs' "$tmp/out"
now="$(date +%s)"
for worker in alpha beta gamma; do
  cat >"$tmp/ws/.squad/workers/$worker.status" <<STATUS
worker=$worker
attempt=1
loop_iter=1
loop_max=2
model_tier=fast
state=completed
verify=fail
gates=test:fail
started=$((now - 100))
finished=$((now - 90))
tokens_in=100
tokens_cached=0
tokens_out=20
cost_status=unknown
merged=
scope_violation=
STATUS
done
cat >"$tmp/ws/.squad/workers/alpha-final.status" <<STATUS
worker=alpha
attempt=2
loop_iter=2
loop_max=2
model_tier=fast
state=completed
verify=fail
gates=test:fail
started=$((now - 80))
finished=$((now - 70))
tokens_in=100
tokens_cached=0
tokens_out=20
cost_status=unknown
merged=
scope_violation=
STATUS
cat >"$tmp/ws/.squad/workers/legacy.status" <<STATUS
worker=legacy
attempt=3
model_tier=balanced
state=completed
verify=pass
started=$((now - 100))
finished=$((now - 90))
tokens_in=100
tokens_cached=90
tokens_out=20
cost_status=reported
cost_usd=0.1000
merged=yes
scope_violation=
STATUS
"$devkit" --eval >"$tmp/out"
grep -q 'WORKER.*TIER.*ATTEMPTS.*SCORE.*CONTROL.*LATENCY.*TOKENS.*RECOVERY.*DELIVERY.*COST' "$tmp/out"
grep -q 'Below threshold (70):' "$tmp/out"
grep -q 'use balanced' "$tmp/out"
grep -q 'how to run test locally' "$tmp/out"
grep -q 'unknown' "$tmp/out"
awk '$1 == "legacy" { if ($5 != 60) exit 1; found=1 } END { if (!found) exit 1 }' "$tmp/out"
awk '$1 == "alpha" { if ($4 != 75 || $5 != 70 || $8 != 70 || $9 != 25) exit 1; found=1 } END { if (!found) exit 1 }' "$tmp/out"
first="$(awk 'NR==2 {print $1}' "$tmp/out")"
[[ "$first" == alpha ]]
"$devkit" --eval legacy >"$tmp/out"
grep -q '^legacy ' "$tmp/out"
! grep -q '^alpha ' "$tmp/out"
grep -q '\$0.1000' "$tmp/out"
echo 'PASS: run evaluation'
