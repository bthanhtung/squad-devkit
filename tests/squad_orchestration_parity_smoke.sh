#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/orch-parity.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
# Keep the baseline next to its libraries without writing into the source tree.
mkdir -p "$tmp/scripts" "$tmp/frozen/.squad/workers"
cp -R "$root/scripts/lib" "$tmp/scripts/lib"
git -C "$root" show 80c377b:scripts/squad-orchestration.sh > "$tmp/scripts/base.sh"
if [[ -n "${SQUAD_ORCHESTRATION_PARITY_FIXTURE:-}" ]]; then
  cp -R "$SQUAD_ORCHESTRATION_PARITY_FIXTURE/." "$tmp/frozen/"
else
  cat > "$tmp/frozen/plan.md" <<'PLAN'
## Tasks:
- dev-0 (codex, dev): parent
- dev-1 (codex, dev): work. Depends on: dev-0 (parent), dev-2.
- pending (claude, dev): later. Depends on: dev-1; note
## Other
- ignored (codex): outside tasks
PLAN
  for n in 0 1 2 3 4 5 6 7; do
    printf 'worker=dev-%s\nstarted=%s\nstate=running\npid=%s\nrole=dev\nparent=%s\nplan=%s\n' "$n" "$((100+n))" "$$" "$([[ "$n" != 0 ]] && echo dev-0 || true)" "$tmp/frozen/plan.md" > "$tmp/frozen/.squad/workers/dev-$n.status"
  done
  printf '[2026-11-20T00:00:00Z] manager -> dev-0: brief\n[2026-11-20T00:01:00Z] dev-1 -> dev-0: QUESTION: ready?\n  continuation\n[2026-11-20T00:02:00Z] dev-0 -> dev-1: ANSWER: yes\n' > "$tmp/frozen/history"
fi
unset SQUAD_MANAGER_ID SQUAD_DEVKIT_MANAGER_WRAPPER_PID SQUAD_DEVKIT_SESSION_START SQUAD_ORCHESTRATION_LAYOUT
export SQUAD_ORCHESTRATION_HISTORY_CMD='cat history' SQUAD_ORCHESTRATION_NOW=1795180000 SQUAD_ORCHESTRATION_FRAME=0
for layout in list graph cards tree pipeline; do
  for width in 80 140; do
    COLUMNS="$width" /bin/bash "$tmp/scripts/base.sh" --once --layout "$layout" "$tmp/frozen/.squad/workers" > "$tmp/base"
    COLUMNS="$width" /bin/bash "$root/scripts/squad-orchestration.sh" --once --layout "$layout" "$tmp/frozen/.squad/workers" > "$tmp/new"
    cmp "$tmp/base" "$tmp/new" || { echo "FAIL: parity $layout/$width" >&2; exit 1; }
  done
done
echo 'squad orchestration parity smoke: OK'
