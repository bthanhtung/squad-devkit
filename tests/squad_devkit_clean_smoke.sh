#!/usr/bin/env bash
set -euo pipefail

# bash 3.2 (macOS) does not exit on a failed [[ ]] under set -e.
fail() {
  echo "Assertion failed at line ${BASH_LINENO[0]}" >&2
  exit 1
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temp_directory="$(mktemp -d /tmp/squad-devkit-clean-test.XXXXXX)"
trap 'rm -rf "$temp_directory"' EXIT
workspace="$temp_directory/workspace"
workers="$workspace/.squad/workers"
mkdir -p "$workers" "$workspace/.squad/plans" "$workspace/reports"
clean="$repo_root/scripts/lib/squad-devkit-clean.sh"
now="$(date +%s)"

make_run() {
  local name="$1" state="$2" started="$3" pid="${4:-}"
  printf 'worker=%s\nstate=%s\nstarted=%s\npid=%s\n' "$name" "$state" "$started" "$pid" >"$workers/$name.status"
  printf 'log\n' >"$workers/$name.log"
  printf 'report\n' >"$workers/$name.md"
  printf '#!/bin/bash\n' >"$workers/$name.monitor.sh"
}

make_run old-done completed $(( now - 30 * 86400 ))
make_run recent-done completed $(( now - 3600 ))
make_run old-running running $(( now - 30 * 86400 )) "$$"
make_run old-lost running $(( now - 30 * 86400 )) 999999
printf 'keep\n' >"$workspace/.squad/plans/plan.md"
printf 'keep\n' >"$workspace/reports/report.html"

"$clean" "$workspace" --quiet 2>"$temp_directory/log"
[[ ! -e "$workers/old-done.status" && ! -e "$workers/old-done.log" && ! -e "$workers/old-done.md" ]] || fail
[[ ! -e "$workers/old-lost.status" ]] || fail
[[ -e "$workers/recent-done.status" && -e "$workers/recent-done.md" ]] || fail
[[ -e "$workers/old-running.status" ]] || fail
[[ -e "$workspace/.squad/plans/plan.md" && -e "$workspace/reports/report.html" ]] || fail
grep -q 'removed 2 finished worker run' "$temp_directory/log"

"$clean" "$workspace" --quiet 2>"$temp_directory/log"
[[ ! -s "$temp_directory/log" ]] || fail

# The size cap removes the oldest finished runs first.
make_run big-older completed $(( now - 600 ))
sleep 1
make_run big-newer completed $(( now - 300 ))
dd if=/dev/zero of="$workers/big-older.log" bs=1024 count=1500 2>/dev/null
dd if=/dev/zero of="$workers/big-newer.log" bs=1024 count=600 2>/dev/null
SQUAD_DEVKIT_MAX_MB=1 "$clean" "$workspace" --quiet 2>/dev/null
[[ ! -e "$workers/big-older.status" ]] || fail
[[ -e "$workers/old-running.status" ]] || fail

"$clean" "$workspace" --all 2>"$temp_directory/log"
[[ -z "$(ls "$workers"/*.status 2>/dev/null | grep -v old-running || true)" ]] || fail
[[ -e "$workers/old-running.status" ]] || fail
grep -q 'removed' "$temp_directory/log"

# squad-devkit --clean prunes by retention; --clean-all removes every finished run.
project="$temp_directory/project"
mkdir -p "$project/.squad/workers"
git init -q "$project"
workers="$project/.squad/workers"
make_run p-old completed $(( now - 30 * 86400 ))
make_run p-new completed $(( now - 60 ))
"$repo_root/scripts/squad-devkit.sh" "$project" --clean 2>/dev/null
[[ ! -e "$workers/p-old.status" && -e "$workers/p-new.status" ]] || fail
"$repo_root/scripts/squad-devkit.sh" "$project" --clean-all 2>/dev/null
[[ ! -e "$workers/p-new.status" ]] || fail
echo 'PASS: retention, size cap, running and lost runs, and squad-devkit --clean/--clean-all'
