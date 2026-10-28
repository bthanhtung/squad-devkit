#!/usr/bin/env bash
# Removes squad-devkit's own leftovers from a squad workspace: finished worker
# runs (status, log, report, monitor script) older than the retention period,
# then the oldest finished runs while .squad/workers exceeds the size limit,
# plus old manager handoff notes and an oversized router log. Running workers,
# plans, and anything outside .squad/ are never touched.
# Usage: squad-devkit-clean.sh <workspace> [--quiet] [--all]
#   --all  remove every finished run regardless of age
# Environment: SQUAD_DEVKIT_RETENTION_DAYS (default 7),
#              SQUAD_DEVKIT_MAX_MB (default 200)
set -euo pipefail

workspace="$1"
shift
quiet=0
remove_all=0
for argument in "$@"; do
  case "$argument" in
    --quiet) quiet=1 ;;
    --all) remove_all=1 ;;
    *) echo "Unknown option: $argument" >&2; exit 2 ;;
  esac
done
workers="$workspace/.squad/workers"
[[ -d "$workers" ]] || exit 0

retention_days="${SQUAD_DEVKIT_RETENTION_DAYS:-7}"
max_kilobytes=$(( ${SQUAD_DEVKIT_MAX_MB:-200} * 1024 ))
cutoff=$(( $(date +%s) - retention_days * 86400 ))
removed=0

status_value() {
  sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -n 1
}

is_running() {
  local pid
  pid="$(status_value "$1" pid)"
  [[ "$(status_value "$1" state)" == running && -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

remove_run() {
  local base="${1%.status}"
  rm -f "$base.status" "$base.log" "$base.md" "$base.monitor.sh" "$base.out"
  removed=$(( removed + 1 ))
}

finished_runs_oldest_first() {
  local file
  while IFS= read -r file; do
    is_running "$file" || printf '%s\n' "$file"
  done < <(ls -tr "$workers"/*.status 2>/dev/null)
  return 0
}

while IFS= read -r file; do
  [[ -n "$file" ]] || continue
  started="$(status_value "$file" started)"
  if (( remove_all == 1 )) || (( ${started:-0} < cutoff )); then
    remove_run "$file"
  fi
done < <(finished_runs_oldest_first)

while (( $(du -sk "$workers" | cut -f 1) > max_kilobytes )); do
  oldest="$(finished_runs_oldest_first | head -n 1 || true)"
  [[ -n "$oldest" ]] || break
  remove_run "$oldest"
done

find "$workspace/.squad/managers" -name '*.handoff.md' -mtime +"$retention_days" -delete 2>/dev/null || true
router_log="$workers/ccr-server.log"
if [[ -f "$router_log" ]] && (( $(du -sk "$router_log" | cut -f 1) > 10240 )); then
  tail -n 2000 "$router_log" >"$router_log.tmp" && mv "$router_log.tmp" "$router_log"
fi

if (( quiet == 0 || removed > 0 )); then
  printf 'squad-devkit: removed %d finished worker run(s) from %s (%s now).\n' \
    "$removed" "$workers" "$(du -sh "$workers" | cut -f 1 | tr -d ' ')" >&2
fi
