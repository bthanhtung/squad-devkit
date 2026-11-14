#!/usr/bin/env bash
set -euo pipefail

unset HC_TERMINAL_ID HC_TERMINAL_SOCKET HC_SCOPE SQUAD_WORKER_PANES SQUAD_WORKER_PANE_HOLD
unset SQUAD_DEVKIT_ORCA_TERMINAL ORCA_PANE_KEY ORCA_CLI_COMMAND ORCA_DEV_REPO_ROOT
unset SQUAD_DEVKIT_WORKSPACE SQUAD_WORKTREE_WORKSPACE SQUAD_MANAGER_ID SQUAD_DEVKIT_YOLO SQUAD_WORKER_CODEX_PROFILE
unset SQUAD_DEVKIT_MANAGER_WRAPPER_PID SQUAD_DEVKIT_SESSION_START SQUAD_WORKER_VIEW
unset TMUX TMUX_PANE SQUAD_DEVKIT_GHOSTTY_TERMINAL HERDR_PANE_ID HERDR_ENV HERDR_SOCKET_PATH \
  WEZTERM_PANE KITTY_WINDOW_ID ITERM_SESSION_ID ZELLIJ ZELLIJ_SESSION_NAME DISPLAY WAYLAND_DISPLAY
export TERM_PROGRAM=test-terminal

trap 'echo "Failed at line $LINENO: $BASH_COMMAND" >&2' ERR

fail() {
  echo "Assertion failed at line ${BASH_LINENO[0]}" >&2
  exit 1
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temp_directory="$(mktemp -d /tmp/squad-worker-parent-test.XXXXXX)"
cleanup() {
  rm -rf "$temp_directory"
}
trap cleanup EXIT

cp -R "$repo_root/scripts" "$temp_directory/scripts"
cp -R "$repo_root/templates" "$temp_directory/templates"
worker="$temp_directory/scripts/squad-worker.sh"

project_directory="$temp_directory/project"
test_bin="$temp_directory/bin"
mkdir -p "$project_directory/.squad/roles" "$test_bin" "$temp_directory/home"
export HOME="$temp_directory/home"
export PATH="$test_bin:$PATH"

git -C "$project_directory" init -q
printf 'init\n' >"$project_directory/README.md"
git -C "$project_directory" add README.md
git -C "$project_directory" -c user.name=test -c user.email=test@example.com commit -qm "initial commit"
cp "$repo_root/templates/devkit/dev.md" "$project_directory/.squad/roles/dev.md"

cat >"$test_bin/squad" <<'EOF'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  'join '*) printf 'Joined as %s (role: dev)\n' "$2" ;;
  'task create') echo 'Created task task-101 for worker' ;;
  'help '*) echo '--client <claude|codex|gemini|opencode|grok|agy|ccr>' ;;
  '--version '*) echo 'squad 0.7.6' ;;
esac
exit 0
EOF

cat >"$test_bin/grok" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
  echo "grok 1.0"
  exit 0
fi
echo "Done. Verification: ok."
EOF

cat >"$test_bin/agy" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
  echo "agy 1.0"
  exit 0
fi
echo '{"type":"result","result":"Done. Verification: ok."}'
EOF

chmod +x "$test_bin/squad" "$test_bin/grok" "$test_bin/agy"

cd "$project_directory"

# 1. Depth 1 without parent
"$worker" root-dev --engine grok --no-worktree --brief "Root worker task" >/dev/null
root_status="$(ls -t .squad/workers/root-dev-*.status | head -n 1)"
grep -qx 'parent=' "$root_status"
grep -qx 'depth=1' "$root_status"
grep -qx 'budget_tokens=' "$root_status"
grep -qx 'max_children=' "$root_status"

# 2. Child of a depth-1 worker gets depth 2 and parent recorded
"$worker" child-dev --engine grok --parent root-dev --no-worktree --brief "Child worker task" >/dev/null
child_status="$(ls -t .squad/workers/child-dev-*.status | head -n 1)"
grep -qx 'parent=root-dev' "$child_status"
grep -qx 'depth=2' "$child_status"

# 2b. Fix round of child-dev without --parent reuses parent from previous status
sleep 1
"$worker" child-dev --engine grok --no-worktree --brief "Child worker fix round" >/dev/null
child_fix_status="$(ls -t .squad/workers/child-dev-*.status | head -n 1)"
[[ "$child_fix_status" != "$child_status" ]] || fail
grep -qx 'parent=root-dev' "$child_fix_status"
grep -qx 'depth=2' "$child_fix_status"

# 3. Grandchild (parent depth 2) exits 2 with "hierarchy depth limit is 2"
status=0
"$worker" grand-dev --engine grok --parent child-dev --no-worktree --brief "Grandchild task" \
  >/dev/null 2>"$temp_directory/err" || status=$?
[[ "$status" == 2 ]] || fail
grep -q 'hierarchy depth limit is 2' "$temp_directory/err"

# 4. --role sub-manager --parent x exits 2 with "sub-managers cannot be nested"
status=0
"$worker" nested-sm --engine agy --role sub-manager --parent root-dev --no-worktree --brief "Nested sub-manager" \
  >/dev/null 2>"$temp_directory/err" || status=$?
[[ "$status" == 2 ]] || fail
grep -q 'sub-managers cannot be nested' "$temp_directory/err"

# 5. --budget-tokens / --max-children without --role sub-manager exits 2
status=0
"$worker" bad-budget --engine grok --budget-tokens 500000 --no-worktree --brief "Bad budget" \
  >/dev/null 2>"$temp_directory/err" || status=$?
[[ "$status" == 2 ]] || fail
grep -q -- '--budget-tokens/--max-children need --role sub-manager' "$temp_directory/err"

status=0
"$worker" bad-children --engine grok --max-children 2 --no-worktree --brief "Bad max children" \
  >/dev/null 2>"$temp_directory/err" || status=$?
[[ "$status" == 2 ]] || fail
grep -q -- '--budget-tokens/--max-children need --role sub-manager' "$temp_directory/err"

# 5b. Sub-manager with non-JSON engine exits 2
status=0
"$worker" bad-sm-engine --engine grok --role sub-manager --no-worktree --brief "Bad engine" \
  >/dev/null 2>"$temp_directory/err" || status=$?
[[ "$status" == 2 ]] || fail

# 6. Sub-manager with stub scripts/squad-submanager.sh
env_dump="$temp_directory/sm_env_names.txt"
prompt_copy="$temp_directory/sm_prompt_copy.txt"
cat >"$temp_directory/scripts/squad-submanager.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
env | sed -n 's/^\(SQUAD_SM_[A-Z_]*\)=.*/\1/p' | sort >"$env_dump"
[[ -f "\$SQUAD_SM_PROMPT_FILE" ]] && cp "\$SQUAD_SM_PROMPT_FILE" "$prompt_copy"
printf '{"type":"result","usage":{"input_tokens":400,"output_tokens":100}}\n' >>"\$SQUAD_SM_LOG"
printf 'stub report\n' >"\$SQUAD_SM_REPORT"
exit 0
EOF
chmod +x "$temp_directory/scripts/squad-submanager.sh"

sm_out="$("$worker" sm-1 --engine agy --model gemini-4-argon-high --role sub-manager --brief "Delegate area A")"
[[ "$sm_out" == *'stub report'* ]] || fail
sm_status="$(ls -t .squad/workers/sm-1-*.status | head -n 1)"
grep -qx 'state=completed' "$sm_status"
grep -qx 'role=sub-manager' "$sm_status"
grep -qx 'parent=' "$sm_status"
grep -qx 'depth=1' "$sm_status"
grep -qx 'budget_tokens=600000' "$sm_status"
grep -qx 'max_children=3' "$sm_status"
# Sub-manager uses a worktree by default like dev
[[ -n "$(grep '^worktree=' "$sm_status" | cut -d= -f2-)" ]] || fail
# Prompt file existed during run and was removed after run
[[ -s "$prompt_copy" ]] || fail
! ls .squad/workers/sm-1-*.prompt >/dev/null 2>&1 || fail
# Report file ends with "stub report"
grep -qx 'stub report' "$(grep '^report=' "$sm_status" | cut -d= -f2-)"
# Verify all 14 SQUAD_SM_* env vars were exported
for var_name in \
  SQUAD_SM_ID \
  SQUAD_SM_TASK \
  SQUAD_SM_MANAGER \
  SQUAD_SM_WORKSPACE \
  SQUAD_SM_DIR \
  SQUAD_SM_PROMPT_FILE \
  SQUAD_SM_LOG \
  SQUAD_SM_REPORT \
  SQUAD_SM_ENGINE \
  SQUAD_SM_MODEL \
  SQUAD_SM_PLAN \
  SQUAD_SM_BUDGET \
  SQUAD_SM_MAX_CHILDREN \
  SQUAD_SM_WORKER; do
  grep -qx "$var_name" "$env_dump" || fail
done

# 7. Missing sub-manager driver -> run fails with reason "sub-manager driver missing"
rm -f "$temp_directory/scripts/squad-submanager.sh"
status=0
"$worker" sm-missing --engine agy --role sub-manager --no-worktree --brief "Missing driver" \
  >/dev/null 2>"$temp_directory/err" || status=$?
[[ "$status" != 0 ]] || fail
missing_status="$(ls -t .squad/workers/sm-missing-*.status | head -n 1)"
grep -qx 'state=failed' "$missing_status"
grep -qx 'reason=sub-manager driver missing' "$missing_status"

# 8. --tree and --tree --json with fixture status files
tree_ws="$temp_directory/tree-ws"
mkdir -p "$tree_ws/.squad/workers"
cat >"$tree_ws/.squad/workers/sm-alpha-20261114-100000.status" <<'EOF'
worker=sm-alpha
role=sub-manager
engine=agy
state=completed
started=1000
tokens_in=1000
tokens_out=500
parent=
depth=1
budget_tokens=600000
max_children=3
EOF
cat >"$tree_ws/.squad/workers/child-a1-20261114-100100.status" <<'EOF'
worker=child-a1
role=dev
engine=agy
state=completed
started=1010
tokens_in=2000
tokens_out=300
parent=sm-alpha
depth=2
EOF
cat >"$tree_ws/.squad/workers/child-a2-20261114-100200.status" <<'EOF'
worker=child-a2
role=dev
engine=codex
state=completed
started=1020
tokens_in=700
tokens_out=100
parent=sm-alpha
depth=2
EOF
cat >"$tree_ws/.squad/workers/solo-1-20261114-090000.status" <<'EOF'
worker=solo-1
role=dev
engine=claude
state=completed
started=500
tokens_in=400
tokens_out=100
parent=
depth=1
EOF

tree_json="$(cd "$tree_ws" && "$worker" --tree --json)"
[[ "$(jq -r '.[] | select(.id=="sm-alpha") | "\(.parent):\(.depth):\(.tokens):\(.branch_tokens)"' <<<"$tree_json")" == ":1:1500:4600" ]] || fail
[[ "$(jq -r '.[] | select(.id=="child-a1") | "\(.parent):\(.depth):\(.tokens):\(.branch_tokens)"' <<<"$tree_json")" == "sm-alpha:2:2300:2300" ]] || fail
[[ "$(jq -r '.[] | select(.id=="child-a2") | "\(.parent):\(.depth):\(.tokens):\(.branch_tokens)"' <<<"$tree_json")" == "sm-alpha:2:800:800" ]] || fail
[[ "$(jq -r '.[] | select(.id=="solo-1") | "\(.parent):\(.depth):\(.tokens):\(.branch_tokens)"' <<<"$tree_json")" == ":1:500:500" ]] || fail

tree_text="$(cd "$tree_ws" && SQUAD_MANAGER_ID=manager-4 "$worker" --tree)"
[[ "$tree_text" == $'manager-4\n'* ]] || fail
[[ "$tree_text" == *'└─ sm-alpha  sub-manager  agy  completed  1500  branch 4600'* ]] || fail
[[ "$tree_text" == *'  └─ child-a1  dev  agy  completed  2300'* ]] || fail

# SQUAD_DEVKIT_SESSION_START filters out older runs (solo-1 started=500 < 900)
filtered_json="$(cd "$tree_ws" && SQUAD_DEVKIT_SESSION_START=900 "$worker" --tree --json)"
[[ "$(jq 'length' <<<"$filtered_json")" == 3 ]] || fail

echo "PASS: squad-worker hierarchy metadata, sub-manager dispatch, and --tree"
