#!/usr/bin/env bash
set -euo pipefail
# Fixtures must not inherit the invoking squad session.
unset SQUAD_DEVKIT_WORKSPACE SQUAD_WORKTREE_WORKSPACE SQUAD_MANAGER_ID SQUAD_DEVKIT_YOLO SQUAD_DEVKIT_DECK HC_TERMINAL_ID HC_TERMINAL_SOCKET HC_SCOPE HERDR_ENV HERDR_PANE_ID
unset CODEX_HOME CLAUDE_CONFIG_DIR
# Name the failing command, so CI logs show where a test stopped.
trap 'echo "Failed at line $LINENO: $BASH_COMMAND" >&2' ERR

# bash 3.2 (macOS) does not exit on a failed [[ ]] under set -e.
fail() {
  echo "Assertion failed at line ${BASH_LINENO[0]}" >&2
  exit 1
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
real_claude="$(command -v claude 2>/dev/null || true)"
temp_directory="$(mktemp -d "${TMPDIR:-/tmp}/squad-deck-test.XXXXXX")"
trap 'rm -rf "$temp_directory"' EXIT
project_directory="$temp_directory/project"
test_bin="$temp_directory/bin"
mkdir -p "$project_directory" "$test_bin" "$temp_directory/home"
git init -q "$project_directory"

# Isolated PATH: only the fake CLIs created below, squad, and system tools.
ln -s "$(command -v squad)" "$test_bin/squad"
export PATH="$test_bin:/usr/bin:/bin"
export HOME="$temp_directory/home"
export SQUAD_DEVKIT_CONFIG="$temp_directory/config"
devkit="$repo_root/scripts/squad-devkit.sh"
deck_flag="--plugin-dir $repo_root/mods/squad-deck"

# A fake CLI that prints the version it is given for --version.
fake_cli() {
  printf '#!/usr/bin/env bash\n[[ "${1:-}" == --version ]] && echo %q\nexit 0\n' "${2:-}" >"$test_bin/$1"
  chmod +x "$test_bin/$1"
}
launch() {
  "$devkit" "$project_directory" --manager "$1" --dry-run
}

# The mod is added for a recent Claude Code.
fake_cli claude '2.1.328 (Claude Code)'
[[ "$(launch claude)" == *"$deck_flag"* ]] || fail

# Exactly at the minimum, and with a longer minor number.
fake_cli claude '2.1.289 (Claude Code)'
[[ "$(launch claude)" == *"$deck_flag"* ]] || fail
fake_cli claude '2.10.0 (Claude Code)'
[[ "$(launch claude)" == *"$deck_flag"* ]] || fail

# Too old.
fake_cli claude '2.1.200 (Claude Code)'
[[ "$(launch claude)" != *'--plugin-dir'* ]] || fail
fake_cli claude '2.1.288 (Claude Code)'
[[ "$(launch claude)" != *'--plugin-dir'* ]] || fail

# A version that cannot be parsed skips the flag.
fake_cli claude 'unknown build'
[[ "$(launch claude)" != *'--plugin-dir'* ]] || fail
fake_cli claude ''
[[ "$(launch claude)" != *'--plugin-dir'* ]] || fail

# Opt-outs: the environment and the config file.
fake_cli claude '2.1.328 (Claude Code)'
[[ "$(SQUAD_DEVKIT_DECK=0 "$devkit" "$project_directory" --manager claude --dry-run)" != *'--plugin-dir'* ]] || fail
[[ "$(SQUAD_DEVKIT_DECK=1 "$devkit" "$project_directory" --manager claude --dry-run)" == *"$deck_flag"* ]] || fail
printf 'deck=off\n' >"$SQUAD_DEVKIT_CONFIG"
[[ "$(launch claude)" != *'--plugin-dir'* ]] || fail
printf 'deck=on\n' >"$SQUAD_DEVKIT_CONFIG"
[[ "$(launch claude)" == *"$deck_flag"* ]] || fail
rm "$SQUAD_DEVKIT_CONFIG"

# Doctor says which way it went.
doctor="$("$devkit" --doctor 2>&1 || true)"
[[ "$doctor" == *'Deck: on (mods/squad-deck, Claude Code 2.1.328)'* ]] || fail
[[ "$(SQUAD_DEVKIT_DECK=0 "$devkit" --doctor 2>&1 || true)" == *'Deck: off (SQUAD_DEVKIT_DECK=0)'* ]] || fail
fake_cli claude '2.1.200 (Claude Code)'
[[ "$("$devkit" --doctor 2>&1 || true)" == *'Deck: off (Claude Code 2.1.200 is older than 2.1.289)'* ]] || fail
printf 'deck=off\n' >"$SQUAD_DEVKIT_CONFIG"
[[ "$("$devkit" --doctor 2>&1 || true)" == *'Deck: off (deck=off in config)'* ]] || fail
rm "$SQUAD_DEVKIT_CONFIG"

# Installed as a plugin: it loads by itself, so no --plugin-dir (it would load twice).
fake_cli claude '2.1.328 (Claude Code)'
mkdir -p "$HOME/.claude/plugins"
installed_file="$HOME/.claude/plugins/installed_plugins.json"
printf '{"version":2,"plugins":{"other@market":[{"scope":"user"}],"squad-deck@squad-devkit":[{"scope":"user"}]}}\n' >"$installed_file"
[[ "$(launch claude)" != *'--plugin-dir'* ]] || fail
[[ "$("$devkit" --doctor 2>&1 || true)" == *'Deck: on (installed plugin squad-deck@squad-devkit)'* ]] || fail
# A config directory without it: back to --plugin-dir.
mkdir -p "$temp_directory/other-config/plugins"
printf '{"version":2,"plugins":{"other@market":[{"scope":"user"}]}}\n' >"$temp_directory/other-config/plugins/installed_plugins.json"
[[ "$(CLAUDE_CONFIG_DIR="$temp_directory/other-config" launch claude)" == *"$deck_flag"* ]] || fail
# An installed plugin does not override an opt-out.
[[ "$(SQUAD_DEVKIT_DECK=0 "$devkit" "$project_directory" --manager claude --dry-run)" != *'--plugin-dir'* ]] || fail
: >"$installed_file"
[[ "$(launch claude)" == *"$deck_flag"* ]] || fail

# Only the claude manager gets the mod.
rm "$test_bin/claude"
fake_cli codex '2.1.328'
[[ "$(launch codex)" != *'--plugin-dir'* ]] || fail

# The mod itself validates, when the real claude binary is available.
if [[ -n "$real_claude" ]]; then
  PATH="$(dirname "$real_claude"):/usr/bin:/bin" "$real_claude" plugin validate "$repo_root/mods/squad-deck" >/dev/null || fail
else
  echo 'skip: claude is not installed, plugin validate not run'
fi

echo OK
