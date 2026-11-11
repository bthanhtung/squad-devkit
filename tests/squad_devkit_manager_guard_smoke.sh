#!/usr/bin/env bash
set -euo pipefail
# Name the failing command, so CI logs show where a test stopped.
trap 'echo "Failed at line $LINENO: $BASH_COMMAND" >&2' ERR

# bash 3.2 (macOS) does not exit on a failed [[ ]] under set -e.
fail() {
  echo "Assertion failed at line ${BASH_LINENO[0]}" >&2
  exit 1
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
guard="$repo_root/scripts/lib/squad-devkit-manager-guard.sh"
# The guard always allows /tmp and $TMPDIR, so the test project lives elsewhere.
temp_directory="$(mktemp -d "$repo_root/.guard-test.XXXXXX")" || exit 1
[[ -d "$temp_directory" && "$temp_directory" != "$repo_root" ]] || exit 1
temp_directory="$(cd "$temp_directory" && pwd -P)"
export GIT_CEILING_DIRECTORIES="$temp_directory"
# A second project and a link directory under the system temp root, which the guard allows.
temp_root="$(mktemp -d "${TMPDIR:-/tmp}/guard-smoke.XXXXXX")" || exit 1
temp_root="$(cd "$temp_root" && pwd -P)"
trap 'rm -rf "$temp_directory" "$temp_root"' EXIT
project="$temp_directory/project"
repo_a="$temp_directory/repo-a"
plans="$project/.squad/plans"
mkdir -p "$plans" "$project/src"
git init -q --template= "$repo_a"
git -C "$repo_a" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init

# Run the guard on a hook payload; sets $out and $err.
run_guard() {
  out="$(printf '%s' "$1" | "$guard" "${guard_project:-$project}" 2>"$temp_directory/err")"
  err="$(cat "$temp_directory/err")"
  if [[ "${PHASE4_GUARD_PARITY:-0}" == 1 ]]; then
    local legacy
    legacy="$(printf '%s' "$1" | SQUAD_RUST_DISABLE=1 "$guard" "${guard_project:-$project}" 2>"$temp_directory/legacy.err")"
    [[ "$(printf '%s' "$legacy" | jq -S -c .)" == "$(printf '%s' "$out" | jq -S -c .)" ]] || {
      printf 'guard parity mismatch: %s\nlegacy: %s\nrust: %s\n' "$1" "$legacy" "$out" >&2
      fail
    }
  fi
}
edit_payload() { jq -nc --arg tool "$1" --arg path "$2" --arg cwd "${3:-$project}" '{cwd: $cwd, hook_event_name: "PreToolUse", tool_name: $tool, tool_input: {file_path: $path}}'; }
bash_payload() { jq -nc --arg command "$1" --arg cwd "${2:-$project}" '{cwd: $cwd, hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: $command}}'; }
expect_deny() { run_guard "$1"; [[ "$out" == *'"permissionDecision":"deny"'* ]] || { echo "expected deny: $1" >&2; fail; }; }
expect_allow() { run_guard "$1"; [[ -z "$out" ]] || { echo "expected allow: $1 -> $out" >&2; fail; }; }

write_plan() { # <file> <risk> [approval bullets...]
  local file="$plans/$1" risk="$2"
  shift 2
  {
    printf '## Triage\n- Risk: %s\n- Complexity: low\n- squad-route: not configured\n\n## Goal\nx\n\n' "$risk"
    printf '## Perspectives\n- Principal engineer: a\n- Engineering manager: b\n- Technical lead: c\n- QA/QC: d\n- End user: e\n\n'
    printf '## Tasks\n- T1\n\n## Acceptance\n- ok\n'
    if [[ $# -gt 0 ]]; then
      printf '\n## Approvals\n'
      printf '%s\n' "$@"
    fi
  } >"$file"
}

# File edits.
expect_deny "$(edit_payload Write src/x.rs)"
[[ "$out" == *'Manager does not edit project files'* ]] || fail
expect_deny "$(edit_payload Edit "$project/src/x.rs")"
expect_deny "$(edit_payload NotebookEdit "$project/src/n.ipynb")"
expect_allow "$(edit_payload Write "$plans/a.md")"
expect_allow "$(edit_payload Edit /tmp/squad-guard-anything.txt)"
expect_allow "$(edit_payload Write "$project/.squad/../.squad/notes.md")"
expect_deny "$(edit_payload Write "$project/.squad/../src/y")"
expect_deny "$(edit_payload Write "$project/.squadx/z")"
expect_deny "$(edit_payload Write /tmpx/z)"
expect_deny "$(edit_payload Write "$repo_a/file")"
(
  export SQUAD_DEVKIT_GUARD_ALLOW="/nonexistent-a:$repo_a"
  expect_allow "$(edit_payload Write "$repo_a/file")"
) || fail
(
  export SQUAD_DEVKIT_GUARD_ALLOW="$repo_a"
  expect_deny "$(edit_payload Write "$repo_a-evil/file")"
) || fail

# The project is never editable through the allow-list, even under a temp root.
(
  guard_project="$temp_root/proj"
  mkdir -p "$guard_project/.squad/plans" "$guard_project/src"
  export SQUAD_DEVKIT_GUARD_ALLOW="$guard_project"
  expect_deny "$(edit_payload Write "$guard_project/src/x")"
  expect_deny "$(edit_payload Write "$guard_project/x")"
  expect_allow "$(edit_payload Write "$guard_project/.squad/plans/a.md")"
) || fail

# Claude config: only projects/ (auto-memory) is editable, not settings.json.
(
  export CLAUDE_CONFIG_DIR="$temp_directory/claude"
  mkdir -p "$CLAUDE_CONFIG_DIR/projects"
  expect_deny "$(edit_payload Write "$CLAUDE_CONFIG_DIR/settings.json")"
  expect_allow "$(edit_payload Write "$CLAUDE_CONFIG_DIR/projects/x/memory/m.md")"
) || fail

# Globs are not expanded; symlinks are followed before `..` is collapsed.
mkdir -p "$temp_root/globdir"
expect_allow "$(edit_payload Write "$temp_root/*/x")"
[[ -z "$err" ]] || fail
expect_allow "$(edit_payload Write "$temp_root/glob?ir/[a]")"
expect_deny "$(edit_payload Write "$project/src/*/x")"
[[ "$out" == *'src/*/x'* ]] || fail
ln -s "$project/src/a.js" "$temp_root/link"
ln -s "$project/src" "$temp_root/dirlink"
ln -s ../globdir "$temp_root/rellink"
expect_deny "$(edit_payload Write "$temp_root/link")"
expect_deny "$(edit_payload Write "$temp_root/dirlink/a.js")"
expect_deny "$(edit_payload Write "$temp_root/dirlink/../x")"
expect_allow "$(edit_payload Write "$temp_root/rellink/f")"

# git push.
expect_deny "$(bash_payload "git -C $repo_a push")"
[[ "$out" == *'needs a human approval'* ]] || fail
write_plan p.md moderate '- push: repo-a'
expect_allow "$(bash_payload "git -C $repo_a push origin main")"
expect_allow "$(bash_payload "FOO=1 command git -C $repo_a -c x=y push")"
expect_deny "$(bash_payload "git -C $repo_a commit -m x")"
write_plan p.md high '- push: repo-a'
expect_deny "$(bash_payload "git -C $repo_a push")"
[[ "$out" == *'needs \"- review: repo-a\"'* ]] || fail
write_plan p.md high '- push: repo-a' '- review: repo-a'
expect_allow "$(bash_payload "git -C $repo_a push")"

# git commit after cd, and gh pr merge.
rm "$plans/p.md"
expect_deny "$(bash_payload "cd $repo_a && git commit -m x")"
expect_deny "$(bash_payload "cd $repo_a; gh pr merge 1")"
write_plan p.md low '- commit: *'
expect_allow "$(bash_payload "cd $repo_a && git commit -m x")"
expect_deny "$(bash_payload "cd $repo_a && gh pr merge 1")"

# Fail closed on commands the structured parse cannot follow (cwd = repo-a).
rm "$plans/p.md"
unverified_denied() {
  expect_deny "$(bash_payload "$1" "$repo_a")"
  [[ "$out" == *'Could not verify'* ]] || { echo "wrong reason: $1 -> $out" >&2; fail; }
}
unverified_denied "bash -c \"git -C $repo_a push\""
unverified_denied "sh -c 'git push'"
unverified_denied 'xargs git push'
unverified_denied 'eval git push'
expect_deny "$(bash_payload 'echo $(git push)' "$repo_a")"
expect_deny "$(bash_payload 'echo `git push`' "$repo_a")"
expect_deny "$(bash_payload "(cd $repo_a && git push)" "$repo_a")"
expect_deny "$(bash_payload 'sudo git push' "$repo_a")"
expect_deny "$(bash_payload 'if true; then git push; fi' "$repo_a")"
expect_deny "$(bash_payload 'git push &' "$repo_a")"
expect_deny "$(bash_payload 'env -i git push' "$repo_a")"
unverified_denied 'env -C / git push'
unverified_denied 'git -C "$(pwd)" push'
unverified_denied 'bash -c "git commit -m x"'
unverified_denied 'bash -c "gh pr merge 1"'
unverified_denied 'git status; bash -c "git push"'
expect_deny "$(bash_payload 'git push' "$repo_a")"
(
  export HOME="$repo_a"
  expect_deny "$(bash_payload 'cd ~ && git push' "$repo_a")"
)
(
  cd "$temp_root"
  expect_deny "$(bash_payload 'bash -c "git push"' "$temp_root")"
  [[ "$out" == *'Could not verify'* ]] || fail
)
write_plan p.md moderate '- push: repo-a'
expect_allow "$(bash_payload 'bash -c "git push"' "$repo_a")"
expect_allow "$(bash_payload "git -C $repo_a push" "$repo_a")"
expect_deny "$(bash_payload 'bash -c "git commit -m x"' "$repo_a")"
expect_allow "$(bash_payload 'git log --grep=push' "$repo_a")"
expect_allow "$(bash_payload 'git status' "$repo_a")"
expect_allow "$(bash_payload 'ls' "$repo_a")"

# An explicit target never falls back to the approved cwd (repo-a); repo-b is unapproved.
repo_b="$temp_directory/repo-b"
git init -q --template= "$repo_b"
nl=$'\n'
target_denied() { # <command> [<cwd>]
  expect_deny "$(bash_payload "$1" "${2:-$repo_a}")"
  [[ "$out" == *'Could not verify the target repository of '* ]] || { echo "wrong reason: $1 -> $out" >&2; fail; }
}
expect_deny "$(bash_payload "/usr/bin/git -C $repo_b push" "$repo_a")"
[[ "$out" == *'needs a human approval'* ]] || fail
expect_allow "$(bash_payload "/usr/bin/git -C $repo_a push" "$project")"
expect_deny "$(bash_payload "git --git-dir $repo_b/.git push" "$repo_a")"
expect_deny "$(bash_payload "git --git-dir=$repo_b/.git push" "$repo_a")"
expect_deny "$(bash_payload "GIT_DIR=$repo_b/.git git push" "$repo_a")"
expect_deny "$(bash_payload "env GIT_DIR=$repo_b/.git git push" "$repo_a")"
expect_deny "$(bash_payload "GIT_DIR=$repo_b/.git gh pr merge 1" "$repo_a")"
expect_allow "$(bash_payload "git --git-dir=$repo_a/.git push" "$project")"
expect_allow "$(bash_payload "GIT_DIR=$repo_a/.git git --work-tree $repo_a push" "$project")"
target_denied 'cd $OTHER && git push'
target_denied 'git -C $OTHER push'
target_denied 'git -C "$(echo /x)" push'
target_denied 'git --git-dir="$D" push'
target_denied 'GIT_DIR=$D git push'
target_denied 'git --work-tree=`pwd` push'
target_denied 'git -C ~nobody push'
target_denied 'cd - && git push'
target_denied "git -C $temp_directory/missing push"
target_denied "git --git-dir=$temp_directory/repo-* push"
target_denied "git --git-dir=$project push"
target_denied 'git --git-dir push'
target_denied "pushd $repo_a; popd; git push"
target_denied 'gh pr merge 1 -R owner/other'
target_denied 'env -C / git push'
target_denied "env -u UNUSED -C $repo_b bash -c 'git push'"
# Wrappers keep the cwd fallback only when they name no other target.
expect_allow "$(bash_payload 'eval git push' "$repo_a")"
expect_allow "$(bash_payload 'xargs git push' "$repo_a")"
target_denied "bash -c 'cd /x && git push'"
target_denied "bash -c 'true;cd /x && git push'"
target_denied "bash -c 'git -C \$X push'"
target_denied "sh -c 'GIT_DIR=$repo_b/.git git push'"
target_denied "zsh -c 'git --git-dir=$repo_b/.git push'"
target_denied "cd $repo_b; bash -c 'git push'"
target_denied "bash -c 'gh pr merge 1 --repo o/r'"
# A subshell's cd does not outlive it (cwd = repo-b, unapproved).
expect_deny "$(bash_payload "(cd $repo_a); git push" "$repo_b")"
expect_deny "$(bash_payload "(cd $repo_a && git push); git push" "$repo_b")"
expect_allow "$(bash_payload "(cd $repo_a && git push)" "$repo_b")"
expect_allow "$(bash_payload "cd $repo_a && (git push)" "$repo_b")"
target_denied 'git log --format=")"; git push'
# Backslash-newline joins the line.
expect_deny "$(bash_payload "git \\${nl}push" "$repo_b")"
expect_deny "$(bash_payload "git -C $repo_b \\${nl}push" "$repo_a")"
expect_allow "$(bash_payload "git -C $repo_a \\${nl}push" "$repo_b")"
# GIT_DIR / GIT_WORK_TREE set by an earlier segment.
expect_deny "$(bash_payload "export GIT_DIR=$repo_b/.git; git push" "$repo_a")"
expect_allow "$(bash_payload "export GIT_DIR=$repo_a/.git; git push" "$repo_b")"
target_denied 'export GIT_DIR=$X; git push'
target_denied 'export GIT_WORK_TREE=$X; git commit -m x'
expect_deny "$(bash_payload "GIT_DIR=$repo_b/.git; git push" "$repo_a")"
expect_allow "$(bash_payload "export GIT_DIR=$repo_b/.git; unset GIT_DIR; git push" "$repo_a")"
expect_deny "$(bash_payload "(export GIT_DIR=$repo_a/.git); git push" "$repo_b")"
expect_deny "$(bash_payload "export GIT_DIR=$repo_a/.git; env -u GIT_DIR git push" "$repo_b")"
rm "$plans/p.md"

# Absolute-path approvals; every approving high-risk plan needs a review.
write_plan p.md moderate "- push: $repo_a"
expect_allow "$(bash_payload "git -C $repo_a push")"
write_plan p.md moderate "- push: $repo_b"
expect_deny "$(bash_payload "git -C $repo_a push")"
[[ "$out" == *"- push: $repo_a"* ]] || fail
write_plan old.md high '- push: repo-a'
touch -t 202001010000 "$plans/old.md"
write_plan new.md low "- push: $repo_a"
expect_deny "$(bash_payload "git -C $repo_a push")"
[[ "$out" == *'high-risk plan old.md'* ]] || fail
write_plan old.md high '- push: repo-a' "- review: $repo_a"
expect_allow "$(bash_payload "git -C $repo_a push")"
rm "$plans/p.md" "$plans/old.md" "$plans/new.md"

# Non-UTF8 plan bytes must never turn a missing approval into an internal-error allow.
printf '## Approvals\n- unrelated: x\377\n' >"$plans/non-utf8.md"
expect_deny "$(bash_payload "git -C $repo_a push")"
rm "$plans/non-utf8.md"

# Unrelated commands and a directory that is not a git repository.
expect_allow "$(bash_payload 'ls -la')"
expect_allow "$(bash_payload 'git status')"
expect_allow "$(bash_payload "cd $project && git push")"

# Disabled, and fail open.
SQUAD_DEVKIT_GUARD=0 run_guard "$(edit_payload Write src/x.rs)"
[[ -z "$out" ]] || fail
status=0
run_guard 'not json' || status=$?
[[ -z "$out" && "$status" == 0 && "$err" == *squad-devkit-manager-guard* ]] || fail
expect_allow '{"tool_name":"Read","tool_input":{"file_path":"src/x.rs"}}'

# Manager settings: a fake claude copies the --settings file it is given.
bin="$temp_directory/bin"
manager_project="$temp_directory/manager-project"
mkdir -p "$bin" "$temp_directory/home" "$manager_project"
git init -q --template= "$manager_project"
ln -s "$(command -v squad)" "$bin/squad"
cat >"$bin/claude" <<EOF
#!/usr/bin/env bash
while [[ \$# -gt 0 ]]; do
  [[ "\$1" == --settings ]] && cp "\$2" "$temp_directory/settings.json"
  shift
done
EOF
chmod +x "$bin/claude"
run_manager() {
  (
    cd "$manager_project"
    env -u SQUAD_MANAGER_ID -u SQUAD_DEVKIT_ROUTER_URL -u SQUAD_DEVKIT_GUARD -u SQUAD_DEVKIT_YOLO \
      PATH="$bin:/usr/bin:/bin:$(dirname "$(command -v jq)")" HOME="$temp_directory/home" \
      SQUAD_DEVKIT_FALLBACK_MANAGER=none SQUAD_DEVKIT_STATUSLINE=0 "$@" \
      "$repo_root/scripts/lib/squad-devkit-manager.sh" claude instructions hello 2>"$temp_directory/manager.err"
  )
}
run_manager
hook="$(jq -r '.hooks.PreToolUse[0] | .matcher + " " + .hooks[0].command' "$temp_directory/settings.json")"
[[ "$hook" == "Edit|Write|MultiEdit|NotebookEdit|Bash "*squad-devkit-manager-guard.sh* ]] || fail
[[ "$hook" == *manager-project* ]] || fail
grep -q 'squad-route is not configured' "$temp_directory/manager.err" || fail
rm -f "$temp_directory/settings.json"
run_manager SQUAD_DEVKIT_GUARD=0 SQUAD_DEVKIT_ROUTER_URL=http://localhost:1
[[ ! -e "$temp_directory/settings.json" ]] || fail
if grep -q 'squad-route is not configured' "$temp_directory/manager.err"; then fail; fi

echo "squad_devkit_manager_guard_smoke: ok"
