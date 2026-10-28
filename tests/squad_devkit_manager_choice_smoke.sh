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
temp_directory="$(mktemp -d /tmp/squad-devkit-manager-test.XXXXXX)"
trap 'rm -rf "$temp_directory"' EXIT
project_directory="$temp_directory/project"
test_bin="$temp_directory/bin"
mkdir -p "$project_directory" "$test_bin" "$temp_directory/home"
git init -q "$project_directory"

# Isolated PATH: only the fake CLIs created below, squad, and system tools.
ln -s "$(command -v squad)" "$test_bin/squad"
fake_cli() {
  printf '#!/usr/bin/env bash\nexit 0\n' >"$test_bin/$1"
  chmod +x "$test_bin/$1"
}
fake_cli codex
fake_cli agy
export PATH="$test_bin:/usr/bin:/bin"
export HOME="$temp_directory/home"
export SQUAD_DEVKIT_CONFIG="$temp_directory/config"
devkit="$repo_root/scripts/squad-devkit.sh"

choice="$(printf '9\n2\n' | SQUAD_DEVKIT_FORCE_PROMPT=1 "$devkit" "$project_directory" --dry-run 2>"$temp_directory/log")"
grep -q 'Claude Code is not installed. Choose the CLI that manages the squad:' "$temp_directory/log"
grep -q '1) codex' "$temp_directory/log"
grep -q '2) agy' "$temp_directory/log"
grep -q 'Enter a number from 1 to 2.' "$temp_directory/log"
[[ "$choice" == *'Manager: agy'* ]] || fail
[[ "$choice" == *"manager: $repo_root/scripts/lib/squad-devkit-manager.sh agy "* ]] || fail
[[ "$choice" == *"cli: $test_bin/agy -i INSTRUCTIONS"* ]] || fail
[[ "$choice" == *'You already joined the squad as {{MANAGER_ID}}'* ]] || fail
[[ "$choice" == *'squad receive {{MANAGER_ID}} --wait --timeout 900'* ]] || fail
[[ "$choice" == *'You are the {{MANAGER_LABEL}} manager'* ]] || fail
[[ "$(cat "$SQUAD_DEVKIT_CONFIG")" == 'manager=agy' ]] || fail

saved="$(SQUAD_DEVKIT_FORCE_PROMPT=1 "$devkit" "$project_directory" --dry-run </dev/null 2>"$temp_directory/log")"
[[ "$saved" == *'Manager: agy'* ]] || fail
[[ "$(cat "$temp_directory/log")" != *'Choose the CLI'* ]] || fail

fake_cli claude
[[ "$("$devkit" "$project_directory" --dry-run)" == *'Manager: agy'* ]] || fail
override="$("$devkit" "$project_directory" --manager claude --dry-run)"
[[ "$override" == *'Manager: claude'* ]] || fail
[[ "$override" == *"cli: $test_bin/claude --permission-mode auto --append-system-prompt INSTRUCTIONS"* ]] || fail
[[ "$(SQUAD_DEVKIT_PERMISSION_MODE=default "$devkit" "$project_directory" --manager claude --dry-run)" == *"cli: $test_bin/claude --append-system-prompt INSTRUCTIONS"* ]] || fail
[[ "$override" == *'run_in_background: true'* ]] || fail
[[ "$(cat "$SQUAD_DEVKIT_CONFIG")" == 'manager=agy' ]] || fail
codex_run="$(SQUAD_DEVKIT_MANAGER=codex "$devkit" "$project_directory" --dry-run)"
[[ "$codex_run" == *"cli: $test_bin/codex -c developer_instructions=\\'\\'\\'INSTRUCTIONS\\'\\'\\'"* ]] || fail
if "$devkit" "$project_directory" --manager cursor --dry-run 2>"$temp_directory/log"; then
  echo 'Expected an unknown manager to fail' >&2
  exit 1
fi
grep -q 'Unknown manager: cursor' "$temp_directory/log"

setup_output="$(printf 'codex\n' | SQUAD_DEVKIT_FORCE_PROMPT=1 "$devkit" --setup 2>"$temp_directory/log")"
grep -q '1) claude' "$temp_directory/log"
[[ "$setup_output" == *'Saved manager: codex'* ]] || fail
[[ "$(cat "$SQUAD_DEVKIT_CONFIG")" == 'manager=codex' ]] || fail

rm "$test_bin/codex" "$test_bin/claude"
fake_cli grok
reasked="$(printf '\n' | SQUAD_DEVKIT_FORCE_PROMPT=1 "$devkit" "$project_directory" --dry-run 2>"$temp_directory/log")"
grep -q "Saved manager 'codex' is no longer installed" "$temp_directory/log"
[[ "$reasked" == *'Manager: agy'* ]] || fail
rm "$SQUAD_DEVKIT_CONFIG"
noninteractive="$("$devkit" "$project_directory" --no-prompt --dry-run 2>"$temp_directory/log")"
[[ "$noninteractive" == *'Manager: agy'* ]] || fail
grep -q 'Claude Code is not installed; using agy as the manager.' "$temp_directory/log"
[[ "$noninteractive" == *'Installed worker engines, most trusted first: grok agy'* ]] || fail
[[ ! -e "$SQUAD_DEVKIT_CONFIG" ]] || fail

export SQUAD_DEVKIT_BIN_DIR="$temp_directory/bin-links"
install_output="$(printf '2\n' | SQUAD_DEVKIT_FORCE_PROMPT=1 "$repo_root/scripts/install-devkit.sh" 2>/dev/null)"
[[ "$(readlink "$SQUAD_DEVKIT_BIN_DIR/squad-devkit")" == "$repo_root/scripts/squad-devkit.sh" ]] || fail
[[ "$(readlink "$SQUAD_DEVKIT_BIN_DIR/squad-worker")" == "$repo_root/scripts/squad-worker.sh" ]] || fail
[[ "$install_output" == *'Manager: grok (Grok Build)'* ]] || fail
[[ "$install_output" == *'Workers (most trusted first): grok agy'* ]] || fail
[[ "$(cat "$SQUAD_DEVKIT_CONFIG")" == 'manager=grok' ]] || fail
fake_cli claude
rm "$SQUAD_DEVKIT_CONFIG"
install_output="$("$repo_root/scripts/install-devkit.sh" --no-prompt)"
[[ "$install_output" == *'Manager: claude (Claude Code)'* ]] || fail
[[ ! -e "$SQUAD_DEVKIT_CONFIG" ]] || fail
[[ "$install_output" != *'claude-hud'* ]] || fail
hud_config="$HOME/.claude/plugins/claude-hud/config.json"
mkdir -p "$(dirname "$hud_config")"
printf '{"display":{"sevenDayThreshold":50},"theme":"dark"}' >"$hud_config"
install_output="$("$repo_root/scripts/install-devkit.sh" --no-prompt)"
[[ "$install_output" == *'claude-hud: weekly quota and usage pace enabled'* ]] || fail
[[ "$(jq -c '[.display.sevenDayThreshold, .display.usagePace, .theme]' "$hud_config")" == '[50,true,"dark"]' ]] || fail
[[ "$("$repo_root/scripts/install-devkit.sh" --no-prompt)" == *'already configured'* ]] || fail
rm "$hud_config"
[[ "$("$repo_root/scripts/install-devkit.sh" --no-prompt --no-hud)" != *'claude-hud'* ]] || fail
[[ ! -e "$hud_config" ]] || fail
"$repo_root/scripts/install-devkit.sh" --no-prompt >/dev/null
[[ "$(jq -c '.display' "$hud_config")" == '{"sevenDayThreshold":0,"usagePace":true}' ]] || fail
[[ "$(readlink "$SQUAD_DEVKIT_BIN_DIR/squad-monitor")" == "$repo_root/scripts/squad-worker-monitor.sh" ]] || fail
rm -rf "$HOME/.claude"
# The manager wrapper archives dead managers, joins, embeds the role, and leaves on exit.
wrapper="$repo_root/scripts/lib/squad-devkit-manager.sh"
cat >"$test_bin/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s|%s\n' "$SQUAD_MANAGER_ID" "${*//$'\n'/\\n}" >>"$MANAGER_TEST_LOG"
squad agents >>"$MANAGER_TEST_LOG"
EOF
chmod +x "$test_bin/claude"
export MANAGER_TEST_LOG="$temp_directory/manager-log"
cd "$project_directory"
squad init >/dev/null
cp "$repo_root/templates/devkit/manager-devkit.md" .squad/roles/manager-devkit.md
mkdir -p .squad/managers
squad join manager --role manager-devkit >/dev/null
sleep 30 &
live_pid=$!
squad join manager-2 --role manager-devkit >/dev/null
printf '%s\n' "$live_pid" >.squad/managers/manager-2.pid
printf '999999\n' >.squad/managers/manager.pid
"$wrapper" claude 'Hello {{MANAGER_ID}}.'
grep -q '^manager|--permission-mode auto --append-system-prompt Hello manager\.\\n\\n## Your role (.squad/roles/manager-devkit.md)' "$MANAGER_TEST_LOG"
grep -q 'You do not write code' "$MANAGER_TEST_LOG"
[[ "$(grep -c 'squad-devkit template' "$MANAGER_TEST_LOG")" == 0 ]] || fail
grep -q '^  manager-2 (role: manager-devkit)' "$MANAGER_TEST_LOG"
[[ "$(squad agents)" != *'manager '* ]] || fail
[[ "$(squad agents)" == *'manager-2'* ]] || fail
[[ ! -e .squad/managers/manager.pid && -e .squad/managers/manager-2.pid ]] || fail
kill "$live_pid"
wait "$live_pid" 2>/dev/null || true
squad join manager-9 --role manager-devkit >/dev/null
rm .squad/managers/manager-2.pid
: >"$MANAGER_TEST_LOG"
SQUAD_DEVKIT_STALE_MINUTES=-1 "$wrapper" claude 'Again as {{MANAGER_ID}}.'
grep -q '^manager|' "$MANAGER_TEST_LOG"
[[ "$(grep -c 'manager-2\|manager-9' "$MANAGER_TEST_LOG")" == 0 ]] || fail
[[ -z "$(squad agents | grep manager || true)" ]] || fail
: >"$MANAGER_TEST_LOG"
"$wrapper" claude 'Rules for {{MANAGER_ID}}.' 'check prod logs'
grep -q '^manager|--permission-mode auto --append-system-prompt Rules for manager\..* check prod logs$' "$MANAGER_TEST_LOG"
cat >"$test_bin/codex" <<'EOF'
#!/usr/bin/env bash
printf 'codex-arg:%s\n' "$@" >>"$MANAGER_TEST_LOG"
EOF
chmod +x "$test_bin/codex"
: >"$MANAGER_TEST_LOG"
"$wrapper" codex $'Line one for {{MANAGER_ID}}.\nSay "hi".' 'check prod logs'
[[ "$(sed -n '1p' "$MANAGER_TEST_LOG")" == 'codex-arg:-c' ]] || fail
[[ "$(sed -n '2p' "$MANAGER_TEST_LOG")" == "codex-arg:developer_instructions='''Line one for manager." ]] || fail
grep -qx 'Say "hi".' "$MANAGER_TEST_LOG"
grep -qx 'codex-arg:check prod logs' "$MANAGER_TEST_LOG"
# A Claude Code usage limit hands the session to the fallback manager (codex).
cat >"$temp_directory/transcript.jsonl" <<'EOF'
{"type":"user","message":{"role":"user","content":"check prod logs for 26/10"}}
{"type":"assistant","message":{"content":[{"type":"text","text":"Plan written; starting logs-1."}]}}
EOF
cat >"$test_bin/claude" <<'EOF'
#!/usr/bin/env bash
settings=""
while (( $# > 0 )); do
  [[ "$1" == --settings ]] && settings="$2"
  shift
done
[[ -n "$settings" ]] && cp "$settings" "$MANAGER_TEST_LOG.settings"
hook=""
[[ -n "$settings" ]] && hook="$(jq -r '.hooks.StopFailure[0].hooks[0].command // empty' "$settings")"
if [[ -z "$hook" ]]; then
  echo 'claude without fallback hook' >>"$MANAGER_TEST_LOG"
  exit 0
fi
printf '{"error":"rate_limit","transcript_path":"%s"}' "$TRANSCRIPT" | eval "$hook"
sleep 30
echo 'claude was not stopped' >>"$MANAGER_TEST_LOG"
EOF
chmod +x "$test_bin/claude"
: >"$MANAGER_TEST_LOG"
TRANSCRIPT="$temp_directory/transcript.jsonl" SQUAD_DEVKIT_HANDOFF_DELAY=0.2 \
  "$wrapper" claude 'You are the {{MANAGER_LABEL}} manager ({{MANAGER_ID}}).' 'check prod logs' 2>"$temp_directory/handoff-log"
grep -q 'Handing over to Codex CLI as manager' "$temp_directory/handoff-log"
[[ "$(grep -c 'claude was not stopped' "$MANAGER_TEST_LOG")" == 0 ]] || fail
[[ "$(jq -r '.hooks.StopFailure[0].matcher' "$MANAGER_TEST_LOG.settings")" == 'rate_limit|billing_error' ]] || fail
grep -q "^codex-arg:developer_instructions='''You are the Codex CLI manager (manager)" "$MANAGER_TEST_LOG"
grep -q '^codex-arg:Claude Code, the previous manager of this squad, stopped because it hit a limit (rate_limit)' "$MANAGER_TEST_LOG"
grep -q '^\*\*user\*\*: check prod logs for 26/10' .squad/managers/manager.handoff.md
grep -q '^\*\*assistant\*\*: Plan written; starting logs-1.' .squad/managers/manager.handoff.md
grep -q '^## Squad tasks' .squad/managers/manager.handoff.md
[[ ! -e .squad/managers/manager.handoff.json && ! -e .squad/managers/manager.settings.json ]] || fail
[[ -z "$(squad agents | grep manager || true)" ]] || fail
: >"$MANAGER_TEST_LOG"
TRANSCRIPT="$temp_directory/transcript.jsonl" SQUAD_DEVKIT_FALLBACK_MANAGER=none \
  "$wrapper" claude 'No fallback.' 'check prod logs'
[[ "$(grep -c '^codex-arg:' "$MANAGER_TEST_LOG")" == 0 ]] || fail
grep -qx 'claude without fallback hook' "$MANAGER_TEST_LOG"
[[ "$(jq -r '.statusLine.command' "$MANAGER_TEST_LOG.settings")" == *'squad-worker-monitor.sh --savings '*' --text' ]] || fail
mkdir -p "$HOME/.claude"
printf '{"statusLine":{"type":"command","command":"node /x/claude-hud/statusline.mjs"}}' >"$HOME/.claude/settings.json"
SQUAD_DEVKIT_FALLBACK_MANAGER=none "$wrapper" claude 'No fallback.' 'check prod logs'
[[ "$(jq -r '.statusLine.command' "$MANAGER_TEST_LOG.settings")" == 'node /x/claude-hud/statusline.mjs --extra-cmd '*'squad-worker-monitor.sh'*'--savings'* ]] || fail
printf '{"statusLine":{"type":"command","command":"my-own-statusline"}}' >"$HOME/.claude/settings.json"
rm -f "$MANAGER_TEST_LOG.settings"
SQUAD_DEVKIT_FALLBACK_MANAGER=none "$wrapper" claude 'No fallback.' 'check prod logs'
[[ ! -e "$MANAGER_TEST_LOG.settings" ]] || fail
rm "$HOME/.claude/settings.json"
echo 'PASS: manager defaults to Claude Code, first-run choice is saved, overrides, setup, installer, and manager lifecycle'
