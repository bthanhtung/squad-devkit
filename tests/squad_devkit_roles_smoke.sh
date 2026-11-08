#!/usr/bin/env bash
set -euo pipefail
# Name the failing command, so CI logs show where a test stopped.
trap 'echo "Failed at line $LINENO: $BASH_COMMAND" >&2' ERR

# bash 3.2 (macOS) does not exit on a failed [[ ]] under set -e.
fail() {
  echo "Assertion failed at line ${BASH_LINENO[0]}" >&2
  exit 1
}
passed=0
pass() {
  passed=$((passed + 1))
  printf 'ok %d - %s\n' "$passed" "$1"
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temp_directory="$(mktemp -d /tmp/squad-devkit-roles.XXXXXX)"
cleanup() {
  rm -rf "$temp_directory"
}
trap cleanup EXIT
unset TMUX TMUX_PANE SQUAD_DEVKIT_GHOSTTY_TERMINAL SQUAD_MANAGER_ID SQUAD_DEVKIT_WORKSPACE \
  SQUAD_DEVKIT_BACKEND SQUAD_DEVKIT_MANAGER SQUAD_DEVKIT_WORKERS SQUAD_DEVKIT_DISABLE_WORKERS \
  SQUAD_DEVKIT_PROJECT_ROOT SQUAD_DEVKIT_ALLOW_HOME SQUAD_DEVKIT_TASK SQUAD_DEVKIT_NO_PROMPT \
  HERDR_PANE_ID HERDR_ENV HERDR_SOCKET_PATH HC_TERMINAL_ID HC_TERMINAL_SOCKET HC_SCOPE WEZTERM_PANE KITTY_WINDOW_ID ITERM_SESSION_ID \
  ZELLIJ ZELLIJ_SESSION_NAME DISPLAY WAYLAND_DISPLAY
export TERM_PROGRAM=test-terminal SQUAD_WORKER_PANES=0 SQUAD_WORKER_DASHBOARD=0

# The seven roles the launcher copies, in the order the copy loop runs them.
expected_roles="$(printf '%s\n' dev manager-devkit researcher reviewer security tester ui-ux | LC_ALL=C sort)"
template_marker='<!-- squad-devkit template'

# Fake engines only: claude starts the manager, codex runs workers. Neither calls a model.
test_bin="$temp_directory/bin"
export ROLES_TEST_LOG="$temp_directory/invocations"
mkdir -p "$test_bin" "$temp_directory/home"
cat >"$test_bin/claude" <<'EOF'
#!/usr/bin/env bash
printf 'claude:%s\n' "${*//$'\n'/\\n}" >>"$ROLES_TEST_LOG"
EOF
cat >"$test_bin/codex" <<'EOF'
#!/usr/bin/env bash
if [[ "$1 $2" == 'mcp list' ]]; then
  echo '[]'
  exit 0
fi
printf 'codex:%s\n' "${*//$'\n'/\\n}" >>"$ROLES_TEST_LOG"
while (( $# > 0 )); do
  if [[ "$1" == --output-last-message ]]; then printf 'Done.\n' >"$2"; fi
  shift
done
EOF
chmod +x "$test_bin/claude" "$test_bin/codex"
export HOME="$temp_directory/home" PATH="$test_bin:$PATH"
# Isolate from the machine's config: CI runners set XDG_CONFIG_HOME.
export XDG_CONFIG_HOME="$HOME/.config"

project_directory="$temp_directory/project"
mkdir -p "$project_directory"
git init -q "$project_directory"
git -C "$project_directory" -c user.name=test -c user.email=test@example.invalid commit -q --allow-empty -m fixture
resolved_project="$(cd "$project_directory" && pwd -P)"
roles_directory="$project_directory/.squad/roles"
engine_log="$ROLES_TEST_LOG"

# Runs the real launcher in the "here" backend; the fake claude exits at once.
launch() {
  local status=0
  (cd "$temp_directory" && "$repo_root/scripts/squad-devkit.sh" "$project_directory" --here --no-prompt --manager claude \
    >"$temp_directory/launch-stdout" 2>"$temp_directory/launch-stderr") || status=$?
  if [[ "$status" != 0 ]]; then
    cat "$temp_directory/launch-stderr" >&2
    fail "launch exited $status"
  fi
}

# Control: a dry run prints the plan and changes nothing.
"$repo_root/scripts/squad-devkit.sh" "$project_directory" --here --no-prompt --dry-run >"$temp_directory/dry-run" 2>&1
grep -q '^manager: ' "$temp_directory/dry-run" || fail
[[ ! -e "$project_directory/.squad" ]] || fail
pass 'dry run prints the manager command and creates no .squad'

# Fresh project: prepare_project copies all seven role templates.
launch
while IFS= read -r role; do
  cmp -s "$repo_root/templates/devkit/$role.md" "$roles_directory/$role.md" || fail "$role.md not copied"
done <<<"$expected_roles"
pass 'fresh project gets all seven role templates copied verbatim'
[[ "$(cat "$temp_directory/launch-stderr")" != *'keeping customized'* ]] || fail
pass 'fresh launch prints no customized-role note'

# The manager prompt carries the manager-devkit role, including the team policy.
policy='the default team is you plus `dev` workers; add `ui-ux` only when the task touches UI/UX or the human asks for it, and `security` only for auth, secrets, input handling'
grep -qF "$policy" "$repo_root/templates/devkit/manager-devkit.md" || fail
grep -qF "$policy" "$roles_directory/manager-devkit.md" || fail
grep -qF "$policy" "$engine_log" || fail
pass 'manager-devkit: default team is manager plus dev, ui-ux and security opt-in, in template and launched prompt'

# Templates: exactly the seven roles, each marked, and every one is in the copy loop.
template_roles="$(for file in "$repo_root"/templates/devkit/*.md; do basename "$file" .md; done | LC_ALL=C sort)"
[[ "$template_roles" == "$expected_roles" ]] || fail "templates/devkit has: $template_roles"
pass 'templates/devkit contains exactly the seven expected role files'
for file in "$repo_root"/templates/devkit/*.md; do
  [[ "$(head -n 1 "$file")" == "$template_marker"* ]] || fail "$file does not start with the template marker"
done
pass 'every templates/devkit file starts with the template marker line'
[[ "$(grep -c 'for role in' "$repo_root/scripts/squad-devkit.sh")" == 1 ]] || fail
loop_roles="$(grep -o 'for role in [^;]*' "$repo_root/scripts/squad-devkit.sh" | sed 's/^for role in //' | tr ' ' '\n' | LC_ALL=C sort)"
[[ "$loop_roles" == "$template_roles" ]] || fail "copy loop has: $loop_roles"
pass 'the prepare_project copy loop lists every template and no orphan'

# Re-running changes nothing and prints no note.
cp -R "$roles_directory" "$temp_directory/roles-before"
launch
diff -r "$temp_directory/roles-before" "$roles_directory" >/dev/null || fail 'second launch changed the roles'
[[ "$(cat "$temp_directory/launch-stderr")" != *'keeping customized'* ]] || fail
pass 'a re-run is idempotent'

# A stale template-marked file is refreshed; a customized file (no marker) is kept.
printf '%s old version\nstale developer rules\n' "$template_marker" >"$roles_directory/dev.md"
printf 'my own tester rules\n' >"$roles_directory/tester.md"
launch
cmp -s "$repo_root/templates/devkit/dev.md" "$roles_directory/dev.md" || fail 'stale dev.md not refreshed'
pass 'a template-marked stale file is refreshed'
[[ "$(cat "$roles_directory/tester.md")" == 'my own tester rules' ]] || fail 'customized tester.md overwritten'
pass 'a customized file (marker removed) is kept byte for byte'
grep -qF "Note: keeping customized $resolved_project/.squad/roles/tester.md; compare it with " "$temp_directory/launch-stderr" || fail
grep -qF 'templates/devkit/tester.md' "$temp_directory/launch-stderr" || fail
[[ "$(grep -c 'keeping customized' "$temp_directory/launch-stderr")" == 1 ]] || fail
pass 'the keeping-customized note names only the customized file'

# Completions: the --role list matches the copy loop, in bash and in zsh.
bash_roles="$(
  source "$repo_root/scripts/completions/squad-devkit.bash"
  COMP_WORDS=(squad-worker worker-1 --role '')
  COMP_CWORD=3
  COMPREPLY=()
  _squad_worker
  printf '%s\n' "${COMPREPLY[@]}" | LC_ALL=C sort
)"
[[ "$bash_roles" == "$expected_roles" ]] || fail "bash --role completion: $bash_roles"
pass 'bash completion offers exactly the seven roles for squad-worker --role'
zsh_roles="$(sed -n "s/.*'--role\[Role prompt\]:role:(\([^)]*\))'.*/\1/p" "$repo_root/scripts/completions/_squad-devkit" |
  tr ' ' '\n' | LC_ALL=C sort)"
[[ "$zsh_roles" == "$expected_roles" ]] || fail "zsh --role completion: $zsh_roles"
pass 'zsh completion offers exactly the seven roles for squad-worker --role'

# Workers: security, reviewer, and researcher run in place; no worktree.
# The launcher leaves "manager" on exit (racy to rejoin), so the workers report to "lead".
# Run every squad command inside the temp project: its database must not be the repo's.
cd "$project_directory"
[[ "$(pwd -P)" == "$resolved_project" ]] || fail
squad join manager --role manager-devkit --client codex --protocol-version 2 >/dev/null
worker="$repo_root/scripts/squad-worker.sh"
run_worker() {
  local id="$1" role="$2" brief="$3"
  "$worker" "$id" --engine codex --no-plan "roles smoke" --role "$role" --brief "$brief" >"$temp_directory/worker-$id.out" 2>&1 </dev/null ||
    { cat "$temp_directory/worker-$id.out" >&2; fail "worker $id exited non-zero"; }
}
last_codex_call() {
  grep '^codex:' "$engine_log" | tail -n 1
}
status_of() {
  ls "$project_directory/.squad/workers/$1-"*.status
}

# check_in_place ID ROLE_TEXT: the run had no worktree and its prompt has the role text.
check_in_place() {
  local status_file call
  status_file="$(status_of "$1")"
  grep -qx 'worktree=' "$status_file" || fail
  grep -qx 'repository=' "$status_file" || fail
  call="$(last_codex_call)"
  [[ "$call" == *"$2"* && "$call" == *"--cd $project_directory "* ]] || fail
  [[ "$call" != *'squad-devkit template'* ]] || fail
}
run_worker sec-1 security 'Audit the auth module'
grep -qx 'role=security' "$(status_of sec-1)" || fail
check_in_place sec-1 'Role: security reviewer.'
run_worker rev-1 reviewer 'Review app.txt'
grep -qx 'role=reviewer' "$(status_of rev-1)" || fail
check_in_place rev-1 'Role: reviewer.'
run_worker res-1 researcher 'Count the TODO markers'
grep -qx 'role=researcher' "$(status_of res-1)" || fail
check_in_place res-1 'Role: researcher.'
[[ -z "$(ls -A "$project_directory/.squad/worktrees" 2>/dev/null || true)" ]] || fail 'read-only roles created a worktree'
pass 'security, reviewer, and researcher run in the project with no worktree'

# Workers: ui-ux, dev, and tester each get their own worktree.
run_worker ui-1 ui-ux 'Polish the settings screen'
status_file="$(status_of ui-1)"
wt="$(sed -n 's/^worktree=//p' "$status_file")"
[[ -n "$wt" && -d "$wt" && "$wt" == */.squad/worktrees/*/ui-1 ]] || fail
call="$(last_codex_call)"
[[ "$call" == *"--cd $wt "* && "$call" == *'Role: UI/UX designer-developer.'* ]] || fail
[[ "$call" != *'squad-devkit template'* ]] || fail

run_worker dev-1 dev 'Fix add() in calc.py'
status_file="$(status_of dev-1)"
wt="$(sed -n 's/^worktree=//p' "$status_file")"
[[ -n "$wt" && -d "$wt" && "$wt" == */.squad/worktrees/*/dev-1 ]] || fail
call="$(last_codex_call)"
[[ "$call" == *"--cd $wt "* && "$call" == *'Role: developer.'* ]] || fail
pass 'ui-ux and dev workers get their own git worktree and their role prompt'

# The tester role was customized above, so the worker prompt must carry the customized text.
run_worker test-1 tester 'Cover add()'
status_file="$(status_of test-1)"
wt="$(sed -n 's/^worktree=//p' "$status_file")"
[[ -n "$wt" && -d "$wt" && "$wt" == */.squad/worktrees/*/test-1 ]] || fail
call="$(last_codex_call)"
[[ "$call" == *"--cd $wt "* ]] || fail
[[ "$call" == *'my own tester rules'* && "$call" != *'Role: tester.'* ]] || fail
[[ "$call" != *'squad-devkit template'* ]] || fail
pass 'tester worker gets a worktree and the customized .squad/roles/tester.md'

printf 'PASS: %d squad-devkit role checks (templates, prepare_project, completions, squad-worker roles)\n' "$passed"
