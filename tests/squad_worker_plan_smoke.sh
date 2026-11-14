#!/usr/bin/env bash
# Plan library, the --plan gate, repo bootstrap flags and the --merge review gate.
# A stub engine stands in for every real one; nothing touches the network.
set -euo pipefail
unset HC_TERMINAL_ID SQUAD_DEVKIT_WORKSPACE SQUAD_WORKTREE_WORKSPACE SQUAD_MANAGER_ID SQUAD_DEVKIT_YOLO \
  SQUAD_WORKER_REQUIRE_PLAN
unset TMUX TMUX_PANE SQUAD_DEVKIT_GHOSTTY_TERMINAL HERDR_PANE_ID HERDR_ENV HERDR_SOCKET_PATH \
  WEZTERM_PANE KITTY_WINDOW_ID ITERM_SESSION_ID ZELLIJ ZELLIJ_SESSION_NAME DISPLAY WAYLAND_DISPLAY
export TERM_PROGRAM=test-terminal
trap 'echo "Failed at line $LINENO: $BASH_COMMAND" >&2' ERR

fail() {
  echo "Assertion failed at line ${BASH_LINENO[0]}: $*" >&2
  exit 1
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/squad-worker-plan.XXXXXX")" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"
export XDG_CONFIG_HOME="$HOME/.config"
mkdir -p "$HOME" "$tmp/bin"

# shellcheck source=../scripts/lib/squad-plan.sh
source "$repo_root/scripts/lib/squad-plan.sh"

write_plan() { # write_plan FILE [RISK]
  cat >"$1" <<EOF
# Plan

## Triage
- Risk: ${2:-low}
- Complexity: Moderate
- squad-route: dev worker

## Goal
Ship the thing.

## Perspectives
- Principal engineer: simple.
- Engineering manager: on time.
- Technical lead: fits the codebase.
- QA/QC: tested.
- End user: works.

## Tasks
1. Do it.

## Acceptance
- It works.

## Approvals
- commit: myrepo — ok
- push: *

## Follow-up: later
Anything.
EOF
}

# --- 1. squad-plan.sh ---------------------------------------------------------
plan="$tmp/plan.md"
write_plan "$plan" Low
[[ -z "$(plan_validate "$plan")" ]] || fail "valid plan reported problems"
plan_validate "$plan" >/dev/null || fail "valid plan returned nonzero"
[[ "$(plan_field "$plan" risk)" == low ]] || fail risk
[[ "$(plan_field "$plan" complexity)" == moderate ]] || fail complexity
# Values may carry trailing text: only the first word counts.
trailing="$tmp/trailing.md"
write_plan "$trailing" low
sed -e 's/^- Risk: .*/- Risk: Moderate. The guard hook is optional (one revert)./' \
  -e 's/^- Complexity: .*/- Complexity: high — touches several files/' "$trailing" >"$trailing.new"
mv "$trailing.new" "$trailing"
[[ -z "$(plan_validate "$trailing")" ]] || fail "validate rejects triage values with trailing text"
[[ "$(plan_field "$trailing" risk)" == moderate ]] || fail "risk with trailing text"
[[ "$(plan_field "$trailing" complexity)" == high ]] || fail "complexity with trailing text"
plan_approves "$plan" commit myrepo || fail "exact approval"
plan_approves "$plan" push anything || fail "wildcard approval"
! plan_approves "$plan" commit other || fail "unexpected approval"
! plan_approves "$plan" review myrepo || fail "unexpected review approval"
! plan_approves "$tmp/missing.md" commit myrepo || fail "missing file approved"

out="$(plan_validate "$tmp/missing.md" || true)"
[[ "$out" == "file not found: $tmp/missing.md" ]] || fail "$out"

expect_missing() { # expect_missing SED-EXPRESSION EXPECTED-LINE
  sed "$1" "$plan" >"$tmp/broken.md"
  local result status=0
  result="$(plan_validate "$tmp/broken.md")" || status=$?
  [[ "$status" == 1 ]] || fail "$2: status $status"
  [[ "$result" == *"$2"* ]] || fail "$2 not in: $result"
}
for section in Goal Perspectives Tasks Acceptance Triage; do
  expect_missing "s/^## $section\$/## Renamed/" "missing section: ## $section"
done
expect_missing 's/^- Risk: .*/- Risk: severe/' 'missing triage line: - Risk: low|moderate|high'
expect_missing '/^- Complexity:/d' 'missing triage line: - Complexity: low|moderate|high'
expect_missing 's/^- squad-route:.*/- squad-route:/' 'missing triage line: - squad-route'
for label in 'Principal engineer' 'Engineering manager' 'Technical lead' 'QA/QC' 'End user'; do
  expect_missing "/^- $(printf '%s' "$label" | sed 's#/#\\/#g'):/d" "missing perspective: $label"
done
# Headings and labels match case-insensitively.
sed -e 's/^## Goal/## GOAL/' -e 's/^- Risk:/- risk:/' "$plan" >"$tmp/case.md"
[[ -z "$(plan_validate "$tmp/case.md")" ]] || fail "case-insensitive match"

mkdir -p "$tmp/plans/nested"
write_plan "$tmp/plans/a.md"
sed -e 's/^- commit: myrepo.*/- commit: other-repo/' -e 's/^- push: \*/- review: myrepo/' "$plan" >"$tmp/plans/a.md"
cp "$plan" "$tmp/plans/b.md"
cp "$plan" "$tmp/plans/nested/c.md"
[[ "$(plan_find_approval "$tmp/plans" commit myrepo)" == "$tmp/plans/b.md" ]] || fail "find_approval b"
[[ "$(plan_find_approval "$tmp/plans" review myrepo)" == "$tmp/plans/a.md" ]] || fail "find_approval a"
! plan_find_approval "$tmp/plans" commit nothing-matches >/dev/null || fail "find_approval none"
# The newest approving plan wins, not the first by name.
mkdir -p "$tmp/mtime"
write_plan "$tmp/mtime/b-old.md" low
write_plan "$tmp/mtime/a-new.md" high
sed -i.bak -e 's/^- push: \*/- push: r/' "$tmp/mtime/b-old.md" "$tmp/mtime/a-new.md"
rm -f "$tmp"/mtime/*.bak
touch -t 202001010000 "$tmp/mtime/b-old.md"
[[ "$(plan_find_approval "$tmp/mtime" push r)" == "$tmp/mtime/a-new.md" ]] || fail "find_approval newest"
# plan_list_approvals prints every approving plan, newest first.
[[ "$(plan_list_approvals "$tmp/mtime" push r | paste -sd ' ' -)" == "$tmp/mtime/a-new.md $tmp/mtime/b-old.md" ]] ||
  fail "list_approvals"
! plan_list_approvals "$tmp/mtime" push nothing >/dev/null || fail "list_approvals none"
# An absolute path approves the repository at that physical top level only.
mkdir -p "$tmp/abs/app" "$tmp/abs/other/app"
ln -s "$tmp/abs/app" "$tmp/abs/link"
sed "s#^- push: \\*#- push: $tmp/abs/link/#" "$plan" >"$tmp/abs/plan.md"
plan_approves "$tmp/abs/plan.md" push app "$tmp/abs/app" || fail "absolute approval"
! plan_approves "$tmp/abs/plan.md" push app "$tmp/abs/other/app" || fail "absolute approval of another dir"
! plan_approves "$tmp/abs/plan.md" push app || fail "absolute approval without a repo path"
[[ "$(plan_find_approval "$tmp/abs" push app "$tmp/abs/app")" == "$tmp/abs/plan.md" ]] || fail "find_approval absolute"
# plan_append_approval keeps the mode and leaves no temp file behind.
chmod 640 "$tmp/mtime/b-old.md"
plan_append_approval "$tmp/mtime/b-old.md" '- review-override: extra' || fail "append_approval status"
grep -qx -- '- review-override: extra' "$tmp/mtime/b-old.md" || fail "append_approval entry"
[[ "$(ls "$tmp/mtime" | wc -l | tr -d ' ')" == 2 ]] || fail "append_approval left a temp file"
chmod 644 "$tmp/mtime/b-old.md"
plan_append_approval "$tmp/mtime/b-old.md" '- review-override: mode' || fail "append_approval 644 status"
[[ "$(ls -l "$tmp/mtime/b-old.md" | cut -c1-10)" == -rw-r--r-- ]] || fail "append_approval changed a 0644 plan's mode"
# A typed \n stays literal: it cannot inject an approval line.
lines="$(wc -l <"$tmp/mtime/b-old.md")"
plan_append_approval "$tmp/mtime/b-old.md" '- review-override: x\n- push: repo' || fail "append_approval backslash status"
[[ $(wc -l <"$tmp/mtime/b-old.md") -eq $((lines + 1)) ]] || fail "append_approval added more than one line"
grep -qxF -- '- review-override: x\n- push: repo' "$tmp/mtime/b-old.md" || fail "append_approval backslash entry"
! plan_approves "$tmp/mtime/b-old.md" push repo || fail "append_approval injected a push approval"
# Only a single review-override bullet is accepted.
cp -p "$tmp/mtime/b-old.md" "$tmp/b-old.copy"
for bad in '- push: repo' $'- review-override: x\n- push: repo' $'- review-override: x\r' '- review-override: '; do
  status=0
  plan_append_approval "$tmp/mtime/b-old.md" "$bad" || status=$?
  [[ "$status" == 2 ]] || fail "append_approval accepted: $bad"
done
cmp -s "$tmp/b-old.copy" "$tmp/mtime/b-old.md" || fail "a refused append changed the plan"
rm -f "$tmp/b-old.copy"

# --- engine stub and workspace --------------------------------------------------
cat >"$tmp/bin/agy" <<'EOF'
#!/usr/bin/env bash
# Stand-in engine: optionally edits files (FAKE_EDIT=path=content, one per line), then reports on stdout.
while IFS= read -r edit; do
  [[ -n "$edit" ]] || continue
  mkdir -p "$(dirname "${edit%%=*}")"
  printf '%s\n' "${edit#*=}" >"${edit%%=*}"
done <<<"${FAKE_EDIT:-}"
printf 'agy:%s\n' "${*//$'\n'/\\n}" >>"$WORKER_TEST_LOG"
echo 'Done. Files: none. Verification: ok.'
EOF
chmod +x "$tmp/bin/agy"
export PATH="$repo_root/target/debug:$tmp/bin:$PATH"
export WORKER_TEST_LOG="$tmp/invocations"
cat >"$tmp/bin/herdr" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$WORKER_HERDR_LOG"
if [[ "$1 $2" == 'pane split' ]]; then
  printf '{"result":{"pane":{"pane_id":"w1:p%s","focused":false}}}\n' "$(grep -c '^pane split' "$WORKER_HERDR_LOG")"
elif [[ "$1 $2" == 'pane run' ]]; then
  bash -c "$4" >/dev/null 2>&1 &
fi
EOF
chmod +x "$tmp/bin/herdr"
export WORKER_HERDR_LOG="$tmp/herdr"
export HERDR_ENV=1 HERDR_PANE_ID=w1:pM SQUAD_WORKER_PANE_HOLD=0
worker="$repo_root/scripts/squad-worker.sh"
git_q() { git -c user.name=t -c user.email=t@t "$@"; }

mkdir "$tmp/ws"
cd "$tmp/ws"
squad init >/dev/null
cp "$repo_root/templates/devkit/dev.md" .squad/roles/dev.md
squad join manager --role manager-devkit --client claude --protocol-version 2 >/dev/null
mkdir -p .squad/plans
write_plan .squad/plans/ok.md Low
write_plan .squad/plans/risky.md High

# expect_exit STATUS PATTERN CMD...
expect_exit() {
  local want="$1" pattern="$2" status=0
  shift 2
  "$@" >"$tmp/out" 2>&1 </dev/null || status=$?
  [[ "$status" == "$want" ]] || { cat "$tmp/out" >&2; fail "$* exited $status, want $want"; }
  grep -q -- "$pattern" "$tmp/out" || { cat "$tmp/out" >&2; fail "$*: missing '$pattern'"; }
}

# --- 2. plan gate -------------------------------------------------------------------
export SQUAD_MANAGER_ID=manager
expect_exit 2 'a plan is required in manager context' \
  "$worker" g-1 --engine agy --no-worktree --brief 'x'
unset SQUAD_MANAGER_ID
expect_exit 2 'a plan is required in manager context' \
  "$worker" g-2 --engine agy --no-worktree --manager lead --brief 'x'
expect_exit 2 'a plan is required in manager context' \
  env SQUAD_WORKER_REQUIRE_PLAN=1 "$worker" g-3 --engine agy --no-worktree --brief 'x'
sed '/^## Goal/,/^$/d' .squad/plans/ok.md >.squad/plans/bad.md
expect_exit 2 "plan $tmp/ws/.squad/plans/bad.md is incomplete:" \
  env SQUAD_MANAGER_ID=manager "$worker" g-4 --engine agy --no-worktree --plan .squad/plans/bad.md --brief 'x'
grep -q '^  missing section: ## Goal$' "$tmp/out" || fail "missing item not listed"
# Outside manager context a given plan is still validated.
expect_exit 2 'is incomplete:' "$worker" g-5 --engine agy --no-worktree --plan .squad/plans/bad.md --brief 'x'
expect_exit 2 'file not found' "$worker" g-5 --engine agy --no-worktree --plan .squad/plans/none.md --brief 'x'
expect_exit 2 'mutually exclusive' \
  "$worker" g-6 --engine agy --no-worktree --plan .squad/plans/ok.md --no-plan why --brief 'x'
expect_exit 2 'Missing value for --no-plan' "$worker" g-7 --engine agy --no-worktree --brief 'x' --no-plan
expect_exit 2 'Missing value for --no-plan' "$worker" g-7 --engine agy --no-worktree --no-plan '' --brief 'x'
expect_exit 2 '--override-review only applies to --merge' \
  "$worker" g-7 --engine agy --override-review why --brief 'x'
expect_exit 2 '--clone needs --project' "$worker" g-7 --engine agy --clone /nowhere --brief 'x'
# SQUAD_WORKER_REQUIRE_PLAN=0 lifts the requirement even with a manager.
SQUAD_MANAGER_ID=manager SQUAD_WORKER_REQUIRE_PLAN=0 "$worker" g-8 --engine agy --no-worktree --brief 'x' >"$tmp/out" 2>&1 ||
  { cat "$tmp/out" >&2; fail "REQUIRE_PLAN=0 run failed"; }
grep -q '^Plan: none' "$tmp/out" || fail "no-plan report header"

# --- 3. status, report and brief record the plan -----------------------------------------------------
last_status() { ls -t .squad/workers/"$1"-*.status | head -n 1; }
SQUAD_MANAGER_ID=manager "$worker" p-1 --engine agy --no-worktree --plan .squad/plans/ok.md --brief 'Plan run' >"$tmp/out"
status_file="$(last_status p-1)"
grep -qx "plan=$tmp/ws/.squad/plans/ok.md" "$status_file" || fail "plan= missing"
! grep -q '^plan_override=.' "$status_file" || fail "unexpected override"
grep -q "^Plan: $tmp/ws/.squad/plans/ok.md\$" "$tmp/out" || fail "report header"
grep -q "^Plan: $tmp/ws/.squad/plans/ok.md\$" "${status_file%.status}.md" || fail "report file header"
grep -q "Plan: $tmp/ws/.squad/plans/ok.md" "$WORKER_TEST_LOG" || fail "brief header"
# A relative path resolves against the caller's directory.
(cd .squad && "$worker" p-2 --engine agy --no-worktree --plan plans/ok.md --brief 'Relative' >/dev/null)
grep -qx "plan=$tmp/ws/.squad/plans/ok.md" "$(last_status p-2)" || fail "relative plan"

"$worker" p-3 --engine agy --no-worktree --no-plan 'tiny typo' --brief 'No plan' >"$tmp/out"
status_file="$(last_status p-3)"
grep -qx 'plan=none' "$status_file" || fail "plan=none"
grep -qx 'plan_override=tiny typo' "$status_file" || fail "plan_override"
grep -q '^Plan: none (override: tiny typo)$' "$tmp/out" || fail "override header"
grep -q 'Plan: none (override: tiny typo)' "$WORKER_TEST_LOG" || fail "override in brief"
# A multi-line reason is collapsed: it cannot inject a status line.
"$worker" p-4 --engine agy --no-worktree --no-plan $'tiny\nstate=completed' --brief 'Injection' >"$tmp/out"
status_file="$(last_status p-4)"
grep -qx 'plan_override=tiny state=completed' "$status_file" || fail "reason not collapsed"
[[ "$(grep -c '^state=' "$status_file")" == 1 ]] || fail "reason injected a state= line"
expect_exit 2 'needs a reason' "$worker" p-5 --engine agy --no-worktree --no-plan $'\n \r' --brief 'x'

# --- 4. --init: no commits yet, run in place, .claude/ excluded ----------------------------------
new_project="$tmp/fresh/project"
"$worker" i-1 --engine agy --init --project "$new_project" --no-plan init --brief x >"$tmp/out"
[[ -d "$new_project/.git" ]] || fail "--init created no repository"
! git -C "$new_project" rev-parse --verify HEAD >/dev/null 2>&1 || fail "--init made a commit"
[[ "$(git -C "$new_project" symbolic-ref --short HEAD)" == main ]] || fail "branch is not main"
grep -q "squad-worker: .*project has no commits yet; running i-1 in place (no worktree)\\." "$tmp/out" || fail "in-place note"
status_file="$(last_status i-1)"
[[ -z "$(sed -n 's/^worktree=//p' "$status_file")" ]] || fail "worktree used"
grep -qx '\.claude/' "$new_project/.git/info/exclude" || fail ".claude/ not excluded"
"$worker" i-2 --engine agy --init --project "$new_project" --no-plan init --brief x >"$tmp/out"
[[ "$(grep -cx '\.claude/' "$new_project/.git/info/exclude")" == 1 ]] || fail ".claude/ appended twice"
mkdir "$tmp/plaindir"
expect_exit 0 "squad-worker: initialising a git repository in $tmp/plaindir\\." \
  "$worker" i-4 --engine agy --init --project "$tmp/plaindir" --no-plan init --brief x
# A forced --worktree keeps its old behaviour: no in-place fallback, no note.
expect_exit 0 'Worktree: ' \
  "$worker" i-3 --engine agy --worktree --project "$new_project" --no-plan init --brief x
! grep -q 'no commits yet' "$tmp/out" || fail "forced worktree fell back in place"
"$worker" --discard i-3 --project "$new_project" >/dev/null
# --clone: clones when missing, ignores an existing directory.
git_q init -q -b main "$tmp/origin"
echo one >"$tmp/origin/a.txt"
git -C "$tmp/origin" add -A
git_q -C "$tmp/origin" commit -qm init
"$worker" c-1 --engine agy --clone "$tmp/origin" --project "$tmp/cloned" --no-worktree --no-plan clone --brief 'x' >"$tmp/out"
[[ -f "$tmp/cloned/a.txt" ]] || fail "--clone did not clone"
"$worker" c-2 --engine agy --clone "$tmp/origin" --project "$tmp/cloned" --no-worktree --no-plan clone --brief 'x' >"$tmp/out"
grep -q 'already exists; ignoring --clone' "$tmp/out" || fail "--clone note"

# --- 5. merge gate -------------------------------------------------------------------------------------------
repo="$tmp/myrepo"
git_q init -q -b main "$repo"
mkdir -p "$repo/src"
printf '[build]\n' >"$repo/netlify.toml"
echo base >"$repo/src/app.txt"
git -C "$repo" add -A
git_q -C "$repo" commit -qm init

run_edit() { # run_edit ID PLAN EDIT [ROLE]
  local tier_args=()
  [[ "$2" != .squad/plans/risky.md ]] || tier_args=(--tier-reason test)
  FAKE_EDIT="$3" "$worker" "$1" --engine agy --worktree --project "$repo" --plan "$2" ${tier_args[@]+"${tier_args[@]}"} \
    ${4:+--role "$4"} --brief 'Edit' >/dev/null
}
# Sensitive path, low-risk plan: refused, then overridden.
run_edit m-1 .squad/plans/ok.md "netlify.toml=[headers]"
expect_exit 3 'merging m-1 needs a review: patch touches netlify.toml' "$worker" --merge m-1
grep -q 'Run a reviewer with --plan' "$tmp/out" || fail "refusal advice"
[[ -d "$(sed -n 's/^worktree=//p' "$(last_status m-1)")" ]] || fail "worktree removed on refusal"
[[ "$(cat "$repo/netlify.toml")" == '[build]' ]] || fail "refused merge changed the repo"
expect_exit 0 'review override for m-1: accepted risk' "$worker" --merge m-1 --override-review 'accepted risk'
grep -q '\[headers\]' "$repo/netlify.toml" || fail "override did not merge"
grep -Eq "^- review-override: m-1 — accepted risk \([0-9]{4}-[0-9]{2}-[0-9]{2}\)\$" .squad/plans/ok.md || fail "override not recorded"
# The new bullet lands inside the Approvals section, before the next heading.
awk '/^## Approvals/{a=1;next} /^## /{a=0} a&&/review-override/{found=1} END{exit found?0:1}' .squad/plans/ok.md ||
  fail "override outside Approvals"
git -C "$repo" checkout -q -- netlify.toml

# Plan risk high: refused until a reviewer on the same plan finishes later.
run_edit m-2 .squad/plans/risky.md "src/app.txt=changed"
expect_exit 3 'needs a review: plan risk is high' "$worker" --merge m-2
sleep 1
write_plan .squad/plans/other.md Low
"$worker" r-1 --engine agy --role reviewer --project "$repo" --plan .squad/plans/other.md --brief 'Review' >/dev/null
expect_exit 3 'needs a review' "$worker" --merge m-2   # reviewed a different plan
"$worker" r-2 --engine agy --role reviewer --project "$repo" --plan .squad/plans/risky.md --tier-reason test --brief 'Review' >/dev/null
expect_exit 0 'Merged m-2' "$worker" --merge m-2
[[ "$(cat "$repo/src/app.txt")" == changed ]] || fail "reviewed merge did not apply"
git -C "$repo" checkout -q -- src/app.txt

# Low-risk plan, ordinary patch: merges with no review. The .claude/ settings never travel.
run_edit m-3 .squad/plans/ok.md "src/app.txt=plain"
wt="$(sed -n 's/^worktree=//p' "$(last_status m-3)")"
mkdir -p "$wt/.claude"
echo '{}' >"$wt/.claude/settings.local.json"
git -C "$wt" add -f .claude
git_q -C "$wt" commit -qm 'force-added settings'
expect_exit 0 'Merged m-3' "$worker" --merge m-3
[[ "$(cat "$repo/src/app.txt")" == plain ]] || fail "plain merge"
[[ ! -e "$repo/.claude" ]] || fail ".claude travelled with the patch"
git -C "$repo" checkout -q -- src/app.txt

# No plan and a plain patch merges as before; a secret-looking line needs a review.
FAKE_EDIT="src/app.txt=ok" "$worker" m-4 --engine agy --worktree --project "$repo" --no-plan t --brief 'Edit' >/dev/null
expect_exit 0 'Merged m-4' "$worker" --merge m-4
git -C "$repo" checkout -q -- src/app.txt
FAKE_EDIT="src/app.sh=Content-Security-Policy: default-src 'self'" \
  "$worker" m-5 --engine agy --worktree --project "$repo" --no-plan t --brief 'Edit' >/dev/null
expect_exit 3 'patch changes a Content-Security-Policy line' "$worker" --merge m-5
grep -q 'rerun the worker with --plan' "$tmp/out" || fail "no-plan gate advice"
"$worker" --discard m-5 >/dev/null

# A shell script with a Content-Security-Policy line is still sensitive.
FAKE_EDIT="scripts/serve.sh=echo 'Content-Security-Policy: none'" \
  "$worker" m-6 --engine agy --worktree --project "$repo" --plan .squad/plans/ok.md --brief 'Edit' >/dev/null
expect_exit 3 'patch changes a Content-Security-Policy line' "$worker" --merge m-6
"$worker" --discard m-6 >/dev/null
# Documentation is never sensitive, whatever it says; neither is src/authors.js.
FAKE_EDIT=$'docs/x.md=Authorization header and api key\nCHANGELOG.md=Authorization: api key' \
  "$worker" m-7 --engine agy --worktree --project "$repo" --plan .squad/plans/ok.md --brief 'Edit' >/dev/null
expect_exit 0 'Merged m-7' "$worker" --merge m-7
FAKE_EDIT="src/authors.js=module.exports = []" \
  "$worker" m-8 --engine agy --worktree --project "$repo" --plan .squad/plans/ok.md --brief 'Edit' >/dev/null
expect_exit 0 'Merged m-8' "$worker" --merge m-8
FAKE_EDIT="src/auth/login.js=x" \
  "$worker" m-9 --engine agy --worktree --project "$repo" --plan .squad/plans/ok.md --brief 'Edit' >/dev/null
expect_exit 3 'patch touches src/auth/login.js' "$worker" --merge m-9
"$worker" --discard m-9 >/dev/null

# A Content-Security-Policy line in a .txt is flagged now (.txt is no longer a doc).
FAKE_EDIT="src/app.txt=Content-Security-Policy: default-src 'self'" \
  "$worker" m-10 --engine agy --worktree --project "$repo" --plan .squad/plans/ok.md --brief 'Edit' >/dev/null
expect_exit 3 'patch changes a Content-Security-Policy line' "$worker" --merge m-10
"$worker" --discard m-10 >/dev/null
# ...but the same line in a Markdown doc merges.
FAKE_EDIT="docs/x.md=Content-Security-Policy: default-src 'self'" \
  "$worker" m-10b --engine agy --worktree --project "$repo" --plan .squad/plans/ok.md --brief 'Edit' >/dev/null
expect_exit 0 'Merged m-10b' "$worker" --merge m-10b

# Sensitive paths and private keys are flagged in every file, docs included.
probe=0
for edit in "src/auth-guard.ts=x" "src/authService.ts=x" "app/auth_middleware.py=x" "lib/oauth2.ts=x" \
  "docs/.env=x" "secrets.txt=x" "credentials.txt=x" "private_key.txt=x" "README.sh=Authorization: Bearer x" "license-check.js=api_key=1" \
  "notes.txt=-----BEGIN RSA PRIVATE KEY-----" "docs/key.md=-----BEGIN RSA PRIVATE KEY-----"; do
  probe=$((probe + 1))
  FAKE_EDIT="$edit" \
    "$worker" "pr-$probe" --engine agy --worktree --project "$repo" --plan .squad/plans/ok.md --brief 'Edit' >/dev/null
  expect_exit 3 'patch ' "$worker" --merge "pr-$probe"
  "$worker" --discard "pr-$probe" >/dev/null
done

# The status lookup is exact: worker n-1's plan is not worker n's plan.
FAKE_EDIT="netlify.toml=[headers]" \
  "$worker" n --engine agy --worktree --project "$repo" --no-plan t --brief 'Edit' >/dev/null
sleep 1
FAKE_EDIT="src/other.txt=y" \
  "$worker" n-1 --engine agy --worktree --project "$repo" --plan .squad/plans/ok.md --brief 'Edit' >/dev/null
expect_exit 3 'n has no plan' "$worker" --merge n
"$worker" --discard n >/dev/null
"$worker" --discard n-1 >/dev/null

# --- 6. structured reviewer verdict ----------------------------------------------------------------------
# A reviewer that asks for changes blocks the merge; a later approving one lifts it.
run_edit v-1 .squad/plans/risky.md "src/app.txt=verdict"
sleep 1
cat >"$tmp/bin/agy" <<'EOF'
#!/usr/bin/env bash
while IFS= read -r edit; do
  [[ -n "$edit" ]] || continue
  mkdir -p "$(dirname "${edit%%=*}")"
  printf '%s\n' "${edit#*=}" >"${edit%%=*}"
done <<<"${FAKE_EDIT:-}"
printf 'agy:%s\n' "${*//$'\n'/\\n}" >>"$WORKER_TEST_LOG"
printf '%s\n' "${FAKE_REPORT:-Done. Files: none. Verification: ok.}"
EOF
chmod +x "$tmp/bin/agy"
FAKE_REPORT=$'src/app.txt:1 injection\nVERDICT: CHANGES_REQUESTED' \
  "$worker" vr-1 --engine agy --role reviewer --project "$repo" --plan .squad/plans/risky.md --tier-reason test --brief 'Review' >/dev/null
grep -qx 'verdict=changes_requested' "$(last_status vr-1)" || fail "changes_requested verdict not recorded"
expect_exit 3 'blocked: reviewer vr-1 .* requested changes' "$worker" --merge v-1
sleep 1
FAKE_REPORT=$'no issues found\nVERDICT: APPROVED' \
  "$worker" vr-2 --engine agy --role reviewer --project "$repo" --plan .squad/plans/risky.md --tier-reason test --brief 'Review' >/dev/null
grep -qx 'verdict=approved' "$(last_status vr-2)" || fail "approved verdict not recorded"
# A newer rejection supersedes the approval, even if the approval status was touched later.
sleep 1
FAKE_REPORT=$'still needs fixes\nVERDICT: CHANGES_REQUESTED' \
  "$worker" vr-latest --engine agy --role reviewer --project "$repo" --plan .squad/plans/risky.md --tier-reason test --brief 'Review' >/dev/null
touch "$(last_status vr-2)"
expect_exit 3 'blocked: reviewer vr-latest .* requested changes' "$worker" --merge v-1
sleep 1
FAKE_REPORT=$'fixed\nVERDICT: APPROVED' \
  "$worker" vr-final --engine agy --role reviewer --project "$repo" --plan .squad/plans/risky.md --tier-reason test --brief 'Review' >/dev/null
expect_exit 0 'Merged v-1' "$worker" --merge v-1
git -C "$repo" checkout -q -- src/app.txt
# A reviewer without a verdict line keeps the old behaviour (counts as a review) and is marked missing.
run_edit v-2 .squad/plans/risky.md "src/app.txt=legacy"
sleep 1
"$worker" vr-3 --engine agy --role reviewer --project "$repo" --plan .squad/plans/risky.md --tier-reason test --brief 'Review' >/dev/null
grep -qx 'verdict=missing' "$(last_status vr-3)" || fail "missing verdict not recorded"
expect_exit 0 'Merged v-2' "$worker" --merge v-2
git -C "$repo" checkout -q -- src/app.txt
# Non-reviewer roles record no verdict.
! grep -q '^verdict=.' "$(last_status v-1)" || fail "dev worker recorded a verdict"
# --override-review lifts a changes_requested block.
run_edit v-3 .squad/plans/risky.md "src/app.txt=forced"
sleep 1
FAKE_REPORT=$'bad\nVERDICT: CHANGES_REQUESTED' \
  "$worker" vr-4 --engine agy --role reviewer --project "$repo" --plan .squad/plans/risky.md --tier-reason test --brief 'Review' >/dev/null
expect_exit 3 'requested changes' "$worker" --merge v-3
expect_exit 0 'review override for v-3: ship it' "$worker" --merge v-3 --override-review 'ship it'
git -C "$repo" checkout -q -- src/app.txt

# --- 7. --own scope gate ---------------------------------------------------------------------------------
FAKE_EDIT=$'src/app.txt=owned\nsrc/other.txt=stray' \
  "$worker" o-1 --engine agy --worktree --project "$repo" --plan .squad/plans/ok.md --own 'src/app.txt' --brief 'Edit' >"$tmp/out"
grep -qx 'owned=src/app.txt' "$(last_status o-1)" || fail "owned= not recorded"
grep -qx 'scope_violation=src/other.txt' "$(last_status o-1)" || fail "scope violation not recorded"
grep -q 'Scope violation (outside --own): src/other.txt' "$tmp/out" || fail "scope violation not reported"
grep -q 'Files you own (change nothing else): src/app.txt' "$WORKER_TEST_LOG" || fail "owned files missing from the prompt"
expect_exit 3 'outside its --own scope: src/other.txt' "$worker" --merge o-1
[[ "$(cat "$repo/src/app.txt")" == base ]] || fail "refused scope merge changed the repo"
expect_exit 0 'scope override for o-1' "$worker" --merge o-1 --override-review 'known stray file'
git -C "$repo" checkout -q -- src/app.txt
rm -f "$repo/src/other.txt"
# Directories, globs and several --own flags all cover their files.
FAKE_EDIT=$'src/deep/a.txt=1\nsrc/b.js=2\ndocs/c.md=3' \
  "$worker" o-2 --engine agy --worktree --project "$repo" --plan .squad/plans/ok.md --own 'src/deep/' --own 'src/*.js,docs' --brief 'Edit' >/dev/null
[[ -z "$(sed -n 's/^scope_violation=//p' "$(last_status o-2)")" ]] || fail "owned directory/glob flagged"
expect_exit 0 'Merged o-2' "$worker" --merge o-2
git -C "$repo" reset -q --hard
git -C "$repo" clean -qfd

# Pending edits must be checked at merge time, not just against saved status.
FAKE_EDIT='src/app.txt=owned' \
  "$worker" o-3 --engine agy --worktree --project "$repo" --plan .squad/plans/ok.md --own src/app.txt --brief Edit >/dev/null
wt="$(sed -n 's/^worktree=//p' "$(last_status o-3)")"
echo stray >"$wt/src/pending.txt"
expect_exit 3 'outside its --own scope: src/pending.txt' "$worker" --merge o-3
[[ ! -e "$repo/src/pending.txt" ]] || fail "pending scope violation merged"
# Removing the stray change makes the actual patch eligible again.
rm "$wt/src/pending.txt"
expect_exit 0 'Merged o-3' "$worker" --merge o-3
git -C "$repo" reset -q --hard

# A rename into an owned destination still deletes an unowned source.
cat >>"$tmp/bin/agy" <<'EOF'
if [[ -n "${FAKE_RENAME:-}" ]]; then mv src/app.txt src/moved.txt; fi
EOF
FAKE_RENAME=1 "$worker" o-4 --engine agy --worktree --project "$repo" --plan .squad/plans/ok.md --own src/moved.txt --brief Edit >/dev/null
grep -qx 'scope_violation=src/app.txt' "$(last_status o-4)" || fail "rename source not recorded"
expect_exit 3 'outside its --own scope: src/app.txt' "$worker" --merge o-4
"$worker" --discard o-4 >/dev/null

# A fix after capture cannot hide an unowned path in the captured patch.
FAKE_EDIT='src/app.txt=owned' \
  "$worker" o-5 --engine agy --worktree --project "$repo" --plan .squad/plans/ok.md --own src/app.txt --brief Edit >/dev/null
wt="$(sed -n 's/^worktree=//p' "$(last_status o-5)")"
CAPTURE_FIX_WORKTREE="$wt"
CAPTURE_FIX_HEAD="$(git -C "$wt" rev-parse HEAD)"
REAL_GIT="$(command -v git)"
export CAPTURE_FIX_WORKTREE CAPTURE_FIX_HEAD REAL_GIT
echo stray >"$wt/src/captured.txt"
cat >"$tmp/bin/git" <<'EOF'
#!/usr/bin/env bash
"$REAL_GIT" "$@" || exit $?
if [[ "$*" == *' diff --binary '* && "$2" == "$CAPTURE_FIX_WORKTREE" ]]; then
  "$REAL_GIT" -C "$CAPTURE_FIX_WORKTREE" reset -q --hard "$CAPTURE_FIX_HEAD"
fi
EOF
chmod +x "$tmp/bin/git"
expect_exit 3 'outside its --own scope: src/captured.txt' "$worker" --merge o-5
[[ ! -e "$repo/src/captured.txt" ]] || fail "captured scope violation merged"
rm "$tmp/bin/git"
unset CAPTURE_FIX_WORKTREE CAPTURE_FIX_HEAD REAL_GIT
"$worker" --discard o-5 >/dev/null

# Git's quoted display form must not replace the actual filename in scope checks.
odd_path=$'src/odd\t"é" file.txt'
FAKE_EDIT="$odd_path=odd" \
  "$worker" o-6 --engine agy --worktree --project "$repo" --plan .squad/plans/ok.md --own "$odd_path" --brief Edit >/dev/null
expect_exit 0 'Merged o-6' "$worker" --merge o-6
[[ -f "$repo/$odd_path" ]] || fail "odd filename was not preserved"
rm "$repo/$odd_path"

# Newlines cannot be represented by the scope checker's line-based protocol.
FAKE_EDIT='src/app.txt=owned' \
  "$worker" o-7 --engine agy --worktree --project "$repo" --plan .squad/plans/ok.md --own src/ --brief Edit >/dev/null
wt="$(sed -n 's/^worktree=//p' "$(last_status o-7)")"
printf stray >"$wt/"$'src/line\nbreak.txt'
expect_exit 3 'cannot check ownership for o-7' "$worker" --merge o-7
[[ ! -e "$repo/"$'src/line\nbreak.txt' ]] || fail "unsupported filename merged"
"$worker" --discard o-7 >/dev/null

# --- 8. shared plan context --------------------------------------------------------------------------------
cat >.squad/plans/ctx.md <<'EOF'
# Ctx plan

## Triage
- Risk: low
- Complexity: low
- squad-route: not configured

## Goal
GOAL-MARKER ship it.

## Findings
- `src/app.txt:1` FINDING-MARKER

## Perspectives
- Principal engineer: a.
- Engineering manager: b.
- Technical lead: c.
- QA/QC: d.
- End user: e.

## Decisions
- DECISION-MARKER keep it small.

## Tasks
- TASK-MARKER-OTHER-WORKER

## Acceptance
- ok

## Approvals
- push: APPROVAL-MARKER
EOF
printf 'COMPANION-MARKER\n' >.squad/plans/ctx.context.md
: >"$WORKER_TEST_LOG"
"$worker" x-1 --engine agy --no-worktree --plan .squad/plans/ctx.md --brief 'Do x' >/dev/null
for marker in GOAL-MARKER FINDING-MARKER DECISION-MARKER COMPANION-MARKER; do
  grep -q "$marker" "$WORKER_TEST_LOG" || fail "$marker missing from the worker prompt"
done
for marker in TASK-MARKER-OTHER-WORKER APPROVAL-MARKER; do
  ! grep -q "$marker" "$WORKER_TEST_LOG" || fail "$marker leaked into the worker prompt"
done
: >"$WORKER_TEST_LOG"
"$worker" x-2 --engine agy --no-worktree --plan .squad/plans/ctx.md --no-plan-context --brief 'Do x' >/dev/null
! grep -q 'GOAL-MARKER' "$WORKER_TEST_LOG" || fail "--no-plan-context still added the context"
# The companion file is bounded.
head -c 400 /dev/zero | tr '\0' 'z' >.squad/plans/ctx.context.md
: >"$WORKER_TEST_LOG"
SQUAD_WORKER_MAX_CONTEXT_BYTES=50 "$worker" x-3 --engine agy --no-worktree --plan .squad/plans/ctx.md --brief 'Do x' >/dev/null
! grep -q 'zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz' "$WORKER_TEST_LOG" || fail "companion context not bounded"

echo 'PASS: plan library, plan gate, repo bootstrap, merge review gate, reviewer verdict, --own scope and plan context'
