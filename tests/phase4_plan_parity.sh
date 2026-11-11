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
# Supported command failures must not be hidden by successful legacy parsing.
mkdir "$tmp/bin"
cat >"$tmp/bin/squad" <<'FAKE'
#!/bin/bash
[[ "$1" == help ]] && { echo '  squad plan validate'; exit 0; }
echo supported-error >&2
exit 23
FAKE
chmod +x "$tmp/bin/squad"
status=0
PATH="$tmp/bin:$PATH" plan_shared_context "$tmp/p.md" >"$tmp/new" 2>"$tmp/err" || status=$?
[[ "$status" == 23 && ! -s "$tmp/new" ]]
grep -q supported-error "$tmp/err"
printf 'phase4_plan_parity: ok\n'
