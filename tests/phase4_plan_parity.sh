#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$root/target/debug:$PATH"
source "$root/scripts/lib/squad-plan.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
for file in "$root"/.squad/plans/*.md "$root"/templates/devkit/plan.md.example; do
  [[ -f "$file" ]] || continue
  old_status=0 new_status=0
  SQUAD_RUST_DISABLE=1 plan_validate "$file" >"$tmp/old" || old_status=$?
  plan_validate "$file" >"$tmp/new" || new_status=$?
  diff -u "$tmp/old" "$tmp/new"
  [[ "$old_status" == "$new_status" ]]
  SQUAD_RUST_DISABLE=1 plan_shared_context "$file" >"$tmp/old"
  plan_shared_context "$file" >"$tmp/new"
  diff -u "$tmp/old" "$tmp/new"
done


# Quick plans relax only the missing Perspectives section, in both validators.
for spec in 'low low 0' 'moderate high 1' 'low moderate 1' 'low low 1'; do
  read -r risk complexity expected <<<"$spec"
  printf '## Triage\n- Risk: %s\n- Complexity: %s\n- squad-route: dev\n## Goal\nShip\n## Tasks\n- dev: implement\n## Acceptance\n- Works\n' "$risk" "$complexity" >"$tmp/quick.md"
  if [[ "$spec" == 'low low 1' ]]; then
    printf '## Perspectives\n- End user: works\n' >>"$tmp/quick.md"
  fi
  old_status=0 new_status=0
  SQUAD_RUST_DISABLE=1 plan_validate "$tmp/quick.md" >"$tmp/old" || old_status=$?
  plan_validate "$tmp/quick.md" >"$tmp/new" || new_status=$?
  diff -u "$tmp/old" "$tmp/new"
  [[ "$old_status" == "$expected" && "$new_status" == "$expected" ]]
done


cat >"$tmp/p.md" <<'PLAN'
## Goal

first

## FINDINGS:
second
## Decisions
third
## Approvals
- push: *
PLAN
printf 'éabcdef' >"$tmp/p.context.md"
SQUAD_WORKER_MAX_CONTEXT_BYTES=1 SQUAD_RUST_DISABLE=1 plan_shared_context "$tmp/p.md" >"$tmp/old"
SQUAD_WORKER_MAX_CONTEXT_BYTES=1 plan_shared_context "$tmp/p.md" >"$tmp/new"
diff -u "$tmp/old" "$tmp/new"
# Every byte boundary must keep valid UTF-8 and match the Rust output.
printf 'Việt🙂\n' >"$tmp/p.context.md"
for limit in {0..14}; do
  SQUAD_WORKER_MAX_CONTEXT_BYTES="$limit" SQUAD_RUST_DISABLE=1 plan_shared_context "$tmp/p.md" >"$tmp/old"
  SQUAD_WORKER_MAX_CONTEXT_BYTES="$limit" plan_shared_context "$tmp/p.md" >"$tmp/new"
  diff -u "$tmp/old" "$tmp/new"
  python3 - "$tmp/new" <<'PYTHON'
import sys
with open(sys.argv[1], encoding='utf-8') as output:
    output.read()
PYTHON
done
cat >"$tmp/tasks.md" <<'PLAN'
- outside: ignored
## Tasks
- one (codex high, developer): Ship
  nested detail
### two (claude low, reviewer): Review
  - nested bullet
- empty:
- duplicate: first
### duplicate: second
## Acceptance
- one: ignored
PLAN
for helper in plan_task plan_task_entry; do
  for id in one two empty missing duplicate outside; do
    old_status=0 new_status=0
    SQUAD_RUST_DISABLE=1 "$helper" "$tmp/tasks.md" "$id" >"$tmp/old" || old_status=$?
    "$helper" "$tmp/tasks.md" "$id" >"$tmp/new" || new_status=$?
    diff -u "$tmp/old" "$tmp/new"
    [[ "$old_status" == "$new_status" ]]
    case "$id" in missing|duplicate|outside) [[ "$new_status" == 1 ]] ;; esac
  done
done
# Preserve trailing section blanks, literal backslashes, and file modes.
for content in $'## Goal\nShip\n' $'## APPROVALS: \n- push: repo\n \t\n\n## Tasks\n- one: Ship\n' $'## Approvals\n' ''; do
  printf '%s' "$content" >"$tmp/approval-old.md"
  cp "$tmp/approval-old.md" "$tmp/approval-new.md"
  chmod 640 "$tmp/approval-old.md" "$tmp/approval-new.md"
  for line in '- review-override: reason with literal \n' '- plan-review-override: approved'; do
    SQUAD_RUST_DISABLE=1 plan_append_approval "$tmp/approval-old.md" "$line"
    plan_append_approval "$tmp/approval-new.md" "$line"
    diff -u "$tmp/approval-old.md" "$tmp/approval-new.md"
    python3 - "$tmp/approval-new.md" <<'PYTHON'
import os, stat, sys
assert stat.S_IMODE(os.stat(sys.argv[1]).st_mode) == 0o640
PYTHON
  done
  for line in '- push: *' '- review-override: ' $'- review-override: reason\n- push: *' $'- plan-review-override: bad\r'; do
    old_status=0 new_status=0
    cp "$tmp/approval-new.md" "$tmp/before"
    SQUAD_RUST_DISABLE=1 plan_append_approval "$tmp/approval-old.md" "$line" || old_status=$?
    plan_append_approval "$tmp/approval-new.md" "$line" || new_status=$?
    [[ "$old_status" == 2 && "$new_status" == 2 ]]
    diff -u "$tmp/before" "$tmp/approval-new.md"
    diff -u "$tmp/approval-old.md" "$tmp/approval-new.md"
  done
done
# Physical-path approvals and output ordering.
mkdir "$tmp/repo" "$tmp/plans"
ln -s "$tmp/repo" "$tmp/link"
printf '## Approvals\n- push: %s\n' "$tmp/link" >"$tmp/plans/approved.md"
SQUAD_RUST_DISABLE=1 plan_list_approvals "$tmp/plans" push repo "$tmp/repo" >"$tmp/old"
plan_list_approvals "$tmp/plans" push repo "$tmp/repo" >"$tmp/new"
diff -u "$tmp/old" "$tmp/new"
# Exercise production patch parser and Rust on the same rename/doc/secret cases.
sed -n '/^sensitive_reasons() {/,/^}/p' "$root/scripts/squad-worker.sh" >"$tmp/helpers.sh"
source "$tmp/helpers.sh"
cat >"$tmp/change.patch" <<'PATCH'
diff --git a/docs/security.md b/docs/security.md
+Authorization: docs are exempt
+-----BEGIN RSA PRIVATE KEY-----
diff --git a/src/a.rs b/src/oauth.rs
+API_KEY=placeholder
+Content-Security-Policy: test
-authorization: example
diff --git a/name b/tokens.md b/name b/tokens.md
+example
PATCH
SQUAD_RUST_DISABLE=1 sensitive_reasons "$tmp/change.patch" >"$tmp/old"
sensitive_reasons "$tmp/change.patch" >"$tmp/new"
diff -u "$tmp/old" "$tmp/new"
# CRLF records retain the shell parser's treatment of carriage returns.
printf '## Approvals\n- push: repo\r\n' >"$tmp/plans/crlf.md"
old_status=0 new_status=0
SQUAD_RUST_DISABLE=1 plan_list_approvals "$tmp/plans" push repo >"$tmp/old" || old_status=$?
plan_list_approvals "$tmp/plans" push repo >"$tmp/new" || new_status=$?
diff -u "$tmp/old" "$tmp/new"
[[ "$old_status" == "$new_status" ]]
# Older binaries advertise plan but lack the three new subcommands.
mkdir "$tmp/old-bin"
cat >"$tmp/old-bin/squad" <<'FAKE'
#!/bin/bash
if [[ "$1" == help ]]; then echo '  squad plan validate'; exit 0; fi
if [[ "$#" == 1 && "$1" == plan ]]; then
  echo 'Usage: squad plan validate|context|check-patch' >&2
  echo probe >>"$PLAN_PROBE_LOG"
  exit 1
fi
case "${2:-}" in task|task-entry|append-approval) exit 23 ;; esac
exec "$PLAN_REAL_SQUAD" "$@"
FAKE
chmod +x "$tmp/old-bin/squad"
(
  PLAN_REAL_SQUAD="$(command -v squad)"
  export PLAN_REAL_SQUAD PLAN_PROBE_LOG="$tmp/probes"
  export PATH="$tmp/old-bin:$PATH"
  for helper in plan_task plan_task_entry; do
    SQUAD_RUST_DISABLE=1 "$helper" "$tmp/tasks.md" one >"$tmp/old"
    "$helper" "$tmp/tasks.md" one >"$tmp/new"
    diff -u "$tmp/old" "$tmp/new"
  done
  cp "$tmp/p.md" "$tmp/legacy-approval.md"
  plan_append_approval "$tmp/legacy-approval.md" '- review-override: legacy'
  grep -qx -- '- review-override: legacy' "$tmp/legacy-approval.md"
  [[ "$(wc -l <"$tmp/probes")" -eq 1 ]]
  bash "$root/tests/squad_worker_plan_smoke.sh"
)
# Supported command failures must not be hidden by successful legacy parsing.
mkdir "$tmp/bin"
cat >"$tmp/bin/squad" <<'FAKE'
#!/bin/bash
[[ "$1" == help ]] && { echo '  squad plan validate'; exit 0; }
[[ "$#" == 1 && "$1" == plan ]] && { echo 'Usage: squad plan append-approval' >&2; exit 1; }
echo supported-error >&2
exit 23
FAKE
chmod +x "$tmp/bin/squad"
for helper in plan_shared_context plan_task plan_task_entry plan_append_approval; do
  status=0
  PATH="$tmp/bin:$PATH" "$helper" "$tmp/p.md" '- review-override: test' >"$tmp/new" 2>"$tmp/err" || status=$?
  [[ "$status" == 23 && ! -s "$tmp/new" ]]
  grep -q supported-error "$tmp/err"
done
printf 'phase4_plan_parity: ok\n'
