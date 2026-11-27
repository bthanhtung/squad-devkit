#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# Exercise the production helpers without launching an engine or a monitor.
source "$root/scripts/lib/squad-plan.sh"
action=""
run_plan_command=0
SQUAD_RUST_DISABLE=1
eval "$(sed -n '/^status_get() {/,/^# Status files of runs/{ /^# Status files of runs/d; p; }' "$root/scripts/squad-worker.sh")"
file="$tmp/run.status"
printf 'host=%s\nstate=running\npid=999999999\nexit=\n' "$worker_host" >"$file"
reconcile_status "$file"
[[ "$(status_get "$file" state)" == lost ]] || exit 1
[[ "$(status_get "$file" reason)" == *'exit status unavailable'* ]] || exit 1
[[ -n "$(status_get "$file" finished)" && -z "$(status_get "$file" exit)" ]] || exit 1
printf 'host=%s\nstate=running\npid=%s\n' "$worker_host" "$$" >"$file"
reconcile_status "$file"
[[ "$(status_get "$file" state)" == running ]] || exit 1
printf 'process_started=%s\n' "$(LC_ALL=C command ps -p "$$" -o lstart= | awk '{$1=$1; print}')" >>"$file"
reconcile_status "$file"
[[ "$(status_get "$file" state)" == running ]] || exit 1
printf 'process_started=wrong identity\n' >>"$file"
reconcile_status "$file"
[[ "$(status_get "$file" reason)" == *'PID was reused'* ]] || exit 1
printf 'host=%s\nstate=completed\npid=999999999\nexit=0\n' "$worker_host" >"$file"
reconcile_status "$file"
[[ "$(status_get "$file" state)" == completed && "$(status_get "$file" exit)" == 0 ]] || exit 1
# Process-table failure must preserve an unverified live state.
ps() { return 1; }
printf 'host=%s\nstate=running\npid=999999999\n' "$worker_host" >"$file"
reconcile_status "$file"
[[ "$(status_get "$file" state)" == running ]] || exit 1
echo 'worker status regression: ok'
