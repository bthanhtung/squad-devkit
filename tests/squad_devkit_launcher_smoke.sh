#!/usr/bin/env bash
set -euo pipefail
unset HC_TERMINAL_ID HC_TERMINAL_SOCKET HC_SCOPE
# Fixtures must not inherit the invoking squad session.
unset SQUAD_DEVKIT_ORCA_TERMINAL ORCA_PANE_KEY ORCA_CLI_COMMAND ORCA_DEV_REPO_ROOT
unset SQUAD_DEVKIT_WORKSPACE SQUAD_WORKTREE_WORKSPACE SQUAD_MANAGER_ID SQUAD_DEVKIT_YOLO
# Name the failing command, so CI logs show where a test stopped.
trap 'echo "Failed at line $LINENO: $BASH_COMMAND" >&2' ERR

# bash 3.2 (macOS) does not exit on a failed [[ ]] under set -e.
fail() {
  echo "Assertion failed at line ${BASH_LINENO[0]}" >&2
  exit 1
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temp_directory="$(mktemp -d /tmp/squad-devkit-test.XXXXXX)"
project_directory="$temp_directory/demo project"
test_bin="$temp_directory/bin"
session_name=""
export TMUX_TMPDIR="$temp_directory/tmux"
unset TMUX
cleanup() {
  if [[ -n "$session_name" ]]; then
    tmux kill-session -t "$session_name" 2>/dev/null || true
  fi
  tmux kill-server 2>/dev/null || true
  rm -rf "$temp_directory"
}
trap cleanup EXIT

mkdir -p "$project_directory" "$test_bin" "$temp_directory/home" "$temp_directory/tmux"
git init -q "$project_directory"

cat >"$test_bin/claude" <<'EOF'
#!/usr/bin/env bash
printf 'claude:%s\n' "${*//$'\n'/\\n}" >>"$DEVKIT_TEST_LOG"
sleep 30
EOF
cat >"$test_bin/codex" <<'EOF'
#!/usr/bin/env bash
echo 'ERROR: the launcher must not start Codex workers' >>"$DEVKIT_TEST_LOG"
exit 1
EOF
cat >"$test_bin/ccr" <<'EOF'
#!/usr/bin/env bash
echo 'ERROR: the launcher must not start CCR workers' >>"$DEVKIT_TEST_LOG"
exit 1
EOF
chmod +x "$test_bin/claude" "$test_bin/codex" "$test_bin/ccr"
export HOME="$temp_directory/home"
# Isolate from the machine's config: CI runners set XDG_CONFIG_HOME.
export XDG_CONFIG_HOME="$HOME/.config"
export CODEX_HOME="$HOME/.codex"
export SQUAD_DEVKIT_PROJECT_ROOT="$temp_directory"
export PATH="$test_bin:$PATH"
export DEVKIT_TEST_LOG="$temp_directory/invocations"
export SQUAD_DEVKIT_BACKEND=tmux
export TERM_PROGRAM=test-terminal
unset SQUAD_DEVKIT_GHOSTTY_TERMINAL

dry_run="$(cd "$project_directory" && "$repo_root/scripts/squad-devkit.sh" --dry-run)"
[[ "$dry_run" == *'manager:'* && "$dry_run" == *"Workers: $repo_root/scripts/squad-worker.sh"* ]] || fail
[[ "$dry_run" != *'dev-1:'* && "$dry_run" != *'--profile max'* ]] || fail
[[ ! -d "$project_directory/.squad" ]] || fail
filtered="$(cd "$project_directory" && SQUAD_WORKER_CODEX_MODEL_STRONG=enabled-choice SQUAD_WORKER_CLAUDE_MODEL_STRONG=disabled-choice "$repo_root/scripts/squad-devkit.sh" --dry-run --workers codex)"
[[ "$filtered" == *enabled-choice* && "$filtered" != *disabled-choice* && "$filtered" == *unverified* ]] || fail
# Saved partial mappings retain effort and do not emit unmapped tiers.
cat >"$test_bin/agy" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$test_bin/agy"
mkdir -p "$project_directory/.squad"
cat >"$project_directory/.squad/worker-models.json" <<'JSON'
{"version":1,"engines":{"agy":{"fast":{"model":"fast-model"}},"codex":{"strong":{"model":"strong-model","effort":"high"}}}}
JSON
catalog_forward="$(cd "$project_directory" && "$repo_root/scripts/squad-devkit.sh" --dry-run --manager codex --workers agy,codex 2>/dev/null)"
catalog_reverse="$(cd "$project_directory" && "$repo_root/scripts/squad-devkit.sh" --dry-run --manager codex --workers codex,agy 2>/dev/null)"
[[ "$catalog_forward" == *'agy: fast=fast-model'* ]] || fail
[[ "$catalog_forward" == *'codex: strong=strong-model (effort high)'* ]] || fail
# Catalog order follows the order given to --workers.
[[ "$catalog_forward" == *'agy: fast=fast-model'*'codex: strong=strong-model'* ]] || fail
[[ "$catalog_reverse" == *'codex: strong=strong-model'*'agy: fast=fast-model'* ]] || fail
# Model names containing whitespace or quotes cannot add prompt lines.
for model in 'space model' 'quote\"model' 'line\nbreak'; do
  printf '{"version":1,"engines":{"agy":{"fast":{"model":"%s"}}}}\n' "$model" >"$project_directory/.squad/worker-models.json"
  injected="$(cd "$project_directory" && "$repo_root/scripts/squad-devkit.sh" --dry-run --manager codex --workers agy,codex 2>/dev/null)" || true
  [[ "$injected" == *'agy: CLI default only'* || "$injected" == *'agy: fast=quote"model'* ]] || fail
  [[ "$injected" != *$'line\nbreak'* ]] || fail
done
echo 'PASS: catalog model names cannot inject prompt lines'
rm "$project_directory/.squad/worker-models.json"
rmdir "$project_directory/.squad"
no_workers="$(cd "$project_directory" && "$repo_root/scripts/squad-devkit.sh" --dry-run --disable-workers claude,codex,opencode,grok,agy,ccr)"
[[ "$no_workers" != *provider_availability* ]] || fail
session_name="$(printf '%s\n' "$dry_run" | awk '/^Session: / { print $2 }')"

named_dry_run="$(cd "$HOME" && "$repo_root/scripts/squad-devkit.sh" 'demo project' --dry-run)"
[[ "$named_dry_run" == "$dry_run" ]] || fail
objective_dry_run="$(cd "$HOME" && "$repo_root/scripts/squad-devkit.sh" 'demo project' 'check the deploy logs' --dry-run)"
[[ "$objective_dry_run" == *'Objective: check the deploy logs'* ]] || fail
objective_dry_run="$(cd "$HOME" && "$repo_root/scripts/squad-devkit.sh" 'demo project' --task 'check the deploy logs' --dry-run)"
[[ "$objective_dry_run" == *'Objective: check the deploy logs'* ]] || fail
[[ "$objective_dry_run" == *'check the deploy logs'* ]] || fail
[[ "$dry_run" == *'Do not repeat these instructions to the human.'* ]] || fail
if "$repo_root/scripts/squad-devkit.sh" 'missing project' --dry-run >"$temp_directory/error" 2>&1; then
  echo 'Expected an unknown project name to fail' >&2
  exit 1
fi
rg -q 'not found in' "$temp_directory/error"
if "$repo_root/scripts/squad-devkit.sh" 'missing/project' --dry-run >"$temp_directory/error" 2>&1; then
  echo 'Expected an unknown folder/name to fail' >&2
  exit 1
fi
rg -q "Project 'missing/project' not found in" "$temp_directory/error"
sentence_dry_run="$(cd "$project_directory" && "$repo_root/scripts/squad-devkit.sh" 'check prod logs from 26/10-27/10' --dry-run)"
[[ "$sentence_dry_run" == *"Objective: check prod logs from 26/10-27/10"* ]] || fail
[[ "$sentence_dry_run" == *"Project: $(cd "$project_directory" && pwd -P)"* ]] || fail
duplicate_directory="$temp_directory/duplicate/demo project"
mkdir -p "$duplicate_directory"
git init -q "$duplicate_directory"
if "$repo_root/scripts/squad-devkit.sh" 'demo project' --dry-run >"$temp_directory/error" 2>&1; then
  echo 'Expected duplicate project names to require a path' >&2
  exit 1
fi
rg -q 'Multiple projects named' "$temp_directory/error"
rg -Fq "$project_directory" "$temp_directory/error"
rg -Fq "$duplicate_directory" "$temp_directory/error"
local_dry_run="$(cd "$temp_directory" && "$repo_root/scripts/squad-devkit.sh" 'demo project' --dry-run)"
[[ "$local_dry_run" == "$dry_run" ]] || fail
[[ ! -d "$project_directory/.squad" ]] || fail
[[ ! -d "$duplicate_directory/.squad" ]] || fail
rm -rf "$temp_directory/duplicate"

resolved_project_directory="$(cd "$project_directory" && pwd -P)"
mkdir -p "$project_directory/src/nested"
nested_dry_run="$(cd "$project_directory/src/nested" && "$repo_root/scripts/squad-devkit.sh" --dry-run)"
[[ "$nested_dry_run" == *"Project: $resolved_project_directory"* ]] || fail
[[ "$nested_dry_run" != *'Mode: general workspace'* ]] || fail
[[ "$nested_dry_run" == *'pass --project <path> to have one work in another repository'* ]] || fail
plain_directory="$temp_directory/plain project"
mkdir -p "$plain_directory"
resolved_plain_directory="$(cd "$plain_directory" && pwd -P)"
plain_dry_run="$(cd "$plain_directory" && "$repo_root/scripts/squad-devkit.sh" --dry-run 2>"$temp_directory/plain-log")"
[[ "$plain_dry_run" == *"Project: $resolved_plain_directory"* ]] || fail
rg -q 'is not a git repository; squad init will create .squad/' "$temp_directory/plain-log"
general_dry_run="$(cd "$HOME" && "$repo_root/scripts/squad-devkit.sh" --dry-run)"
[[ "$general_dry_run" == *"Project: $HOME/.squad-devkit"* ]] || fail
[[ "$general_dry_run" == *'Mode: general workspace'* ]] || fail
[[ "$general_dry_run" == *'You are in the general squad workspace'*'Run those workers here without --project'*'pass --project <repository path> to those squad-worker runs'* ]] || fail
[[ ! -e "$HOME/.squad-devkit" ]] || fail
general_objective="$(cd "$HOME" && "$repo_root/scripts/squad-devkit.sh" 'check prod logs from 26/10-27/10' --dry-run)"
[[ "$general_objective" == *'Mode: general workspace'*'Objective: check prod logs from 26/10-27/10'* ]] || fail
if "$repo_root/scripts/squad-devkit.sh" "$HOME" --dry-run >/dev/null 2>"$temp_directory/home-log"; then
  echo 'Expected the home directory to be refused as a project' >&2
  exit 1
fi
rg -q 'Refusing to use your home directory' "$temp_directory/home-log"
[[ "$(SQUAD_DEVKIT_ALLOW_HOME=1 "$repo_root/scripts/squad-devkit.sh" "$HOME" --dry-run)" == *"Project: $(cd "$HOME" && pwd -P)"* ]] || fail
list_output="$("$repo_root/scripts/squad-devkit.sh" --list)"
[[ "$list_output" == *'Projects found in:'* ]] || fail
[[ "$list_output" == *"demo project"* ]] || fail
[[ "$list_output" == *"$resolved_project_directory"* ]] || fail

printf '# Demo rules\n' >"$project_directory/CLAUDE.md"
printf 'node_modules/\n' >"$project_directory/.gitignore"
(cd "$project_directory" && git add CLAUDE.md .gitignore && git -c user.name=t -c user.email=t@t commit -qm init)
(cd "$HOME" && "$repo_root/scripts/squad-devkit.sh" 'demo project' --no-attach)
[[ "$(cat "$project_directory/CLAUDE.md")" == '# Demo rules' ]] || fail
[[ "$(cat "$project_directory/.gitignore")" == 'node_modules/' ]] || fail
[[ ! -e "$project_directory/AGENTS.md" && ! -e "$project_directory/GEMINI.md" ]] || fail
grep -qx '.squad/' "$project_directory/.git/info/exclude"
[[ -z "$(cd "$project_directory" && git status --porcelain)" ]] || fail
for attempt in {1..30}; do
  if [[ -f "$DEVKIT_TEST_LOG" ]]; then
    break
  fi
  sleep 1
done
if [[ ! -f "$DEVKIT_TEST_LOG" ]]; then
  tmux capture-pane -p -t "$session_name" >&2 || true
  echo 'The manager did not start' >&2
  exit 1
fi
[[ "$(tmux list-panes -t "$session_name" -F '#{pane_id}' | wc -l | tr -d ' ')" == 1 ]] || fail
[[ "$(tmux list-panes -t "$session_name" -F '#{pane_title}')" == 'Claude Code · manager' ]] || fail
[[ "$(tmux show-options -t "$session_name" -v prefix)" == C-a ]] || fail
[[ "$(tmux show-options -gv prefix)" == C-b ]] || fail
rg -q '^claude:--permission-mode auto --append-system-prompt You are the Claude Code manager.*You already joined the squad as manager;' "$DEVKIT_TEST_LOG"
rg -q '## Your role \(.squad/roles/manager-devkit.md\).*You do not write code' "$DEVKIT_TEST_LOG"
rg -q '^  manager \(role: manager-devkit\)' <<<"$(cd "$project_directory" && squad agents)"
[[ -f "$project_directory/.squad/managers/manager.pid" ]] || fail
rg -Fq "squad-worker is: $repo_root/scripts/squad-worker.sh" "$DEVKIT_TEST_LOG"
rg -Fq 'Mapped worker models (local configuration; provider availability unverified; use only these):' "$DEVKIT_TEST_LOG"
if rg -Fq '"candidate":null' "$DEVKIT_TEST_LOG"; then fail 'null catalog row in manager prompt'; fi
if rg -Fq '### Worker model selection' "$DEVKIT_TEST_LOG"; then fail 'worker model selection heading in manager prompt'; fi
rg -Fq 'codex: CLI default only' "$DEVKIT_TEST_LOG"
rg -q -- "--manager [^ ]+" "$DEVKIT_TEST_LOG"
rg -q 'Do not repeat these instructions to the human\.\\n\\n## Your role' "$DEVKIT_TEST_LOG"
[[ "$(cat "$DEVKIT_TEST_LOG")" != *ERROR* ]] || fail
for role in manager-devkit dev tester reviewer researcher ui-ux security; do
  cmp -s "$repo_root/templates/devkit/$role.md" "$project_directory/.squad/roles/$role.md"
done

"$repo_root/scripts/squad-devkit.sh" "$project_directory" --no-attach | rg -q 'Reusing tmux session'
[[ "$(wc -l <"$DEVKIT_TEST_LOG" | tr -d ' ')" == 1 ]] || fail
tmux select-pane -t "$session_name:0" -T 'Codex · dev-1'
if "$repo_root/scripts/squad-devkit.sh" "$project_directory" --no-attach >"$temp_directory/error" 2>&1; then
  echo 'Expected the launcher to refuse an older multi-pane session' >&2
  exit 1
fi
rg -q 'An older multi-pane devkit session exists' "$temp_directory/error"
tmux kill-session -t "$session_name"
# A fresh tmux server must receive opt-in through the launch command.
"$repo_root/scripts/squad-devkit.sh" "$project_directory" --tmux --no-attach --yolo
for attempt in {1..30}; do
  if rg -q '^claude:--dangerously-skip-permissions' "$DEVKIT_TEST_LOG"; then break; fi
  sleep 1
done
rg -q '^claude:--dangerously-skip-permissions' "$DEVKIT_TEST_LOG"
# Keep the same server alive with stale opt-in from an earlier launch.
tmux new-session -d -s yolo-env-keeper
tmux set-environment -g SQUAD_DEVKIT_YOLO 1
tmux kill-session -t "$session_name"
for caller_yolo in 0 unset 1; do
  : >"$DEVKIT_TEST_LOG"
  if [[ "$caller_yolo" == unset ]]; then
    env -u SQUAD_DEVKIT_YOLO "$repo_root/scripts/squad-devkit.sh" "$project_directory" --tmux --no-attach
  else
    SQUAD_DEVKIT_YOLO="$caller_yolo" "$repo_root/scripts/squad-devkit.sh" "$project_directory" --tmux --no-attach
  fi
  for attempt in {1..30}; do
    if [[ -s "$DEVKIT_TEST_LOG" ]]; then break; fi
    sleep 1
  done
  if [[ "$caller_yolo" == 1 ]]; then
    rg -q '^claude:--dangerously-skip-permissions' "$DEVKIT_TEST_LOG"
  else
    rg -q '^claude:--permission-mode auto ' "$DEVKIT_TEST_LOG"
    [[ "$(cat "$DEVKIT_TEST_LOG")" != *--dangerously-skip-permissions* ]] || fail
  fi
  tmux kill-session -t "$session_name"
done
tmux kill-session -t yolo-env-keeper

printf '<!-- squad-devkit template: old\nold manager role\n' >"$project_directory/.squad/roles/manager-devkit.md"
printf 'my own dev role\n' >"$project_directory/.squad/roles/dev.md"
cat >"$test_bin/claude" <<'EOF'
#!/usr/bin/env bash
printf 'here:%s:%s:%s\n' "$PWD" "${SQUAD_DEVKIT_GHOSTTY_TERMINAL:-none}" "${*//$'\n'/\\n}" >>"$DEVKIT_TEST_LOG"
EOF
printf '#!/usr/bin/env bash\necho GHOSTTY-7\n' >"$test_bin/osascript-id"
chmod +x "$test_bin/osascript-id"
(cd "$HOME" && TERM_PROGRAM=ghostty SQUAD_DEVKIT_OSASCRIPT="$test_bin/osascript-id" \
  "$repo_root/scripts/squad-devkit.sh" "$project_directory" --here 'check the deploy logs' 2>"$temp_directory/here-log")
rg -Fq "here:$resolved_project_directory:GHOSTTY-7:" "$DEVKIT_TEST_LOG"
rg -q '^here:.*You already joined the squad as manager;' "$DEVKIT_TEST_LOG"
[[ "$(cd "$project_directory" && squad agents)" != *'manager'* ]] || fail
[[ ! -e "$project_directory/.squad/managers/manager.pid" ]] || fail
rg -q "^here:.*--append-system-prompt You are the Claude Code manager.* check the deploy logs$" "$DEVKIT_TEST_LOG"
cmp -s "$repo_root/templates/devkit/manager-devkit.md" "$project_directory/.squad/roles/manager-devkit.md"
[[ "$(cat "$project_directory/.squad/roles/dev.md")" == 'my own dev role' ]] || fail
rg -q 'keeping customized .*/dev.md' "$temp_directory/here-log"

# Orca captures this shell's exact pane, never the active/unrelated terminal.
cat >"$test_bin/orca-fake" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$DEVKIT_ORCA_LOG"
[[ "$1 $2" == 'terminal list' ]] || exit 1
printf '{"ok":true,"result":{"terminals":[{"handle":"unrelated","tabId":"other","leafId":"leaf"},{"handle":"manager-handle","tabId":"tab","leafId":"leaf"}]}}\n'
EOF
chmod +x "$test_bin/orca-fake"
export DEVKIT_ORCA_LOG="$temp_directory/orca-log"
cat >"$test_bin/claude" <<'EOF'
#!/usr/bin/env bash
printf 'orca-manager:%s\n' "${SQUAD_DEVKIT_ORCA_TERMINAL:-none}" >>"$DEVKIT_TEST_LOG"
EOF
(cd "$project_directory" && ORCA_PANE_KEY=tab:leaf ORCA_CLI_COMMAND="$test_bin/orca-fake" \
  "$repo_root/scripts/squad-devkit.sh" --here)
rg -q '^orca-manager:manager-handle$' "$DEVKIT_TEST_LOG"
rg -Fq "terminal list --worktree path:$resolved_project_directory --json" "$DEVKIT_ORCA_LOG"
(cd "$project_directory" && ORCA_PANE_KEY=missing:leaf ORCA_CLI_COMMAND="$test_bin/orca-fake" \
  "$repo_root/scripts/squad-devkit.sh" --here)
rg -q '^orca-manager:none$' "$DEVKIT_TEST_LOG"
: >"$DEVKIT_ORCA_LOG"
(cd "$project_directory" && SQUAD_DEVKIT_ORCA_TERMINAL=explicit-manager ORCA_PANE_KEY=tab:leaf \
  ORCA_CLI_COMMAND="$test_bin/orca-fake" "$repo_root/scripts/squad-devkit.sh" --here)
rg -q '^orca-manager:explicit-manager$' "$DEVKIT_TEST_LOG"
[[ ! -s "$DEVKIT_ORCA_LOG" ]] || fail

orca_doctor="$(ORCA_PANE_KEY=tab:leaf ORCA_CLI_COMMAND="$test_bin/orca-fake" "$repo_root/scripts/squad-devkit.sh" --doctor)"
[[ "$orca_doctor" == *'Orca split-pane (explicit manager terminal)'* ]] || fail
# Restore the manager fixture used by the remaining launcher checks.
cat >"$test_bin/claude" <<'EOF'
#!/usr/bin/env bash
printf 'here:%s:%s:%s\n' "$PWD" "${SQUAD_DEVKIT_GHOSTTY_TERMINAL:-none}" "${*//$'\n'/\\n}" >>"$DEVKIT_TEST_LOG"
EOF

cat >"$test_bin/osascript" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$DEVKIT_OSASCRIPT_LOG"
EOF
chmod +x "$test_bin/osascript"
export DEVKIT_OSASCRIPT_LOG="$temp_directory/ghostty-args"
export SQUAD_DEVKIT_OSASCRIPT="$test_bin/osascript"
export TMPDIR="$temp_directory"
ghostty_dry_run="$("$repo_root/scripts/squad-devkit.sh" "$project_directory" --ghostty --dry-run)"
[[ "$ghostty_dry_run" == *'Backend: ghostty'* ]] || fail
"$repo_root/scripts/squad-devkit.sh" "$project_directory" --ghostty
[[ "$(wc -l <"$DEVKIT_OSASCRIPT_LOG" | tr -d ' ')" == 4 ]] || fail
[[ "$(sed -n '4p' "$DEVKIT_OSASCRIPT_LOG")" == 'Claude Code · manager' ]] || fail
[[ "$(sed -n '2p' "$DEVKIT_OSASCRIPT_LOG")" == "$resolved_project_directory" ]] || fail
manager_script="$(sed -n '3p' "$DEVKIT_OSASCRIPT_LOG")"
[[ -x "$manager_script" ]] || fail
rg -Fq 'lib/squad-devkit-manager.sh' "$manager_script"
rg -Fq 'Do not repeat these instructions to the human.' "$manager_script"
rg -Fq 'export SQUAD_DEVKIT_GHOSTTY_TERMINAL="$(osascript -e' "$manager_script"
bash -n "$manager_script"
# The generated Ghostty script carries opt-in even without terminal inheritance.
"$repo_root/scripts/squad-devkit.sh" "$project_directory" --ghostty --yolo
manager_script="$(sed -n '3p' "$DEVKIT_OSASCRIPT_LOG")"
rg -Fq 'exec env SQUAD_DEVKIT_YOLO=1 ' "$manager_script"
# A real wrapper process passes session opt-in to its fake manager child.
"$repo_root/scripts/squad-devkit.sh" "$project_directory" --here --yolo
rg -q '^here:.*--dangerously-skip-permissions' "$DEVKIT_TEST_LOG"
doctor_dir="$temp_directory/doctor-check"
mkdir -p "$doctor_dir"
doctor_out="$("$repo_root/scripts/squad-devkit.sh" --doctor)"
[[ "$doctor_out" == *"=== squad-devkit doctor ==="* ]] || fail
[[ "$doctor_out" == *"Core Tools:"* ]] || fail
[[ "$doctor_out" == *"Manager CLI:"* ]] || fail
[[ "$doctor_out" == *"Worker Engines:"* ]] || fail
[[ "$doctor_out" == *"Terminal & Monitor Support:"* ]] || fail
[[ "$doctor_out" == *"Result: Environment ready for squad-devkit."* ]] || fail
[[ ! -d "$doctor_dir/.squad" ]] || fail

# Test doctor exit failure when required tools missing
PATH="$test_bin:/bin:/usr/bin" "$repo_root/scripts/squad-devkit.sh" --doctor >"$temp_directory/doc-fail.log" 2>&1 && fail || true
grep -q 'Result: Environment missing required tools.' "$temp_directory/doc-fail.log" || fail

echo 'PASS: name lookup, manager-only launch (here, tmux, Ghostty), session reuse, and role refresh'
