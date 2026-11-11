#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# Exercise the production helpers without launching an engine or a monitor.
source "$root/scripts/lib/squad-plan.sh"
eval "$(sed -n '/^status_get() {/,/^# Status files of runs/{ /^# Status files of runs/d; p; }' "$root/scripts/squad-worker.sh")"
file="$tmp/run.status"
printf 'state=running\npid=999999999\nexit=\n' >"$file"
reconcile_status "$file"
[[ "$(status_get "$file" state)" == lost ]]
[[ "$(status_get "$file" reason)" == *'exit status unavailable'* ]]
[[ -n "$(status_get "$file" finished)" && -z "$(status_get "$file" exit)" ]]
printf 'state=running\npid=%s\n' "$$" >"$file"
reconcile_status "$file"
[[ "$(status_get "$file" state)" == running ]]
printf 'process_started=%s\n' "$(LC_ALL=C command ps -p "$$" -o lstart= | awk '{$1=$1; print}')" >>"$file"
reconcile_status "$file"
[[ "$(status_get "$file" state)" == running ]]
printf 'process_started=wrong identity\n' >>"$file"
reconcile_status "$file"
[[ "$(status_get "$file" reason)" == *'PID was reused'* ]]
printf 'state=completed\npid=999999999\nexit=0\n' >"$file"
reconcile_status "$file"
[[ "$(status_get "$file" state)" == completed && "$(status_get "$file" exit)" == 0 ]]
# Process-table failure must preserve an unverified live state.
ps() { return 1; }
printf 'state=running\npid=999999999\n' >"$file"
reconcile_status "$file"
[[ "$(status_get "$file" state)" == running ]]
echo 'worker status regression: ok'
