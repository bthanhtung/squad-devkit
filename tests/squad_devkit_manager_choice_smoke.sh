#!/usr/bin/env bash
set -euo pipefail

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
[[ "$choice" == *"cli: $test_bin/agy -i PROMPT"* ]] || fail
[[ "$choice" == *'You already joined the squad as {{MANAGER_ID}}'* ]] || fail
[[ "$choice" == *'squad receive {{MANAGER_ID}} --wait --timeout 900'* ]] || fail
[[ "$choice" == *'You are the Antigravity CLI manager'* ]] || fail
[[ "$(cat "$SQUAD_DEVKIT_CONFIG")" == 'manager=agy' ]] || fail

saved="$(SQUAD_DEVKIT_FORCE_PROMPT=1 "$devkit" "$project_directory" --dry-run </dev/null 2>"$temp_directory/log")"
[[ "$saved" == *'Manager: agy'* ]] || fail
[[ "$(cat "$temp_directory/log")" != *'Choose the CLI'* ]] || fail

fake_cli claude
[[ "$("$devkit" "$project_directory" --dry-run)" == *'Manager: agy'* ]] || fail
override="$("$devkit" "$project_directory" --manager claude --dry-run)"
[[ "$override" == *'Manager: claude'* ]] || fail
[[ "$override" == *"cli: $test_bin/claude --permission-mode auto PROMPT"* ]] || fail
[[ "$(SQUAD_DEVKIT_PERMISSION_MODE=default "$devkit" "$project_directory" --manager claude --dry-run)" == *"cli: $test_bin/claude PROMPT"* ]] || fail
[[ "$override" == *'run_in_background: true'* ]] || fail
[[ "$(cat "$SQUAD_DEVKIT_CONFIG")" == 'manager=agy' ]] || fail
codex_run="$(SQUAD_DEVKIT_MANAGER=codex "$devkit" "$project_directory" --dry-run)"
[[ "$codex_run" == *"cli: $test_bin/codex PROMPT"* ]] || fail
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
grep -q 'neither codex nor ccr is installed' "$temp_directory/log"
[[ "$noninteractive" == *'No worker engine is installed'* ]] || fail
[[ ! -e "$SQUAD_DEVKIT_CONFIG" ]] || fail

export SQUAD_DEVKIT_BIN_DIR="$temp_directory/bin-links"
install_output="$(printf '2\n' | SQUAD_DEVKIT_FORCE_PROMPT=1 "$repo_root/scripts/install-devkit.sh" 2>/dev/null)"
[[ "$(readlink "$SQUAD_DEVKIT_BIN_DIR/squad-devkit")" == "$repo_root/scripts/squad-devkit.sh" ]] || fail
[[ "$(readlink "$SQUAD_DEVKIT_BIN_DIR/squad-worker")" == "$repo_root/scripts/squad-worker.sh" ]] || fail
[[ "$install_output" == *'Manager: grok (Grok Build)'* ]] || fail
[[ "$install_output" == *'Workers: none'* ]] || fail
[[ "$(cat "$SQUAD_DEVKIT_CONFIG")" == 'manager=grok' ]] || fail
fake_cli claude
rm "$SQUAD_DEVKIT_CONFIG"
install_output="$("$repo_root/scripts/install-devkit.sh" --no-prompt)"
[[ "$install_output" == *'Manager: claude (Claude Code)'* ]] || fail
[[ ! -e "$SQUAD_DEVKIT_CONFIG" ]] || fail
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
grep -q '^manager|--permission-mode auto Hello manager\.\\n\\n## Your role (.squad/roles/manager-devkit.md)' "$MANAGER_TEST_LOG"
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
echo 'PASS: manager defaults to Claude Code, first-run choice is saved, overrides, setup, installer, and manager lifecycle'
