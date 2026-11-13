#!/usr/bin/env bash
set -euo pipefail

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/squad-test-wizard.XXXXXX")
trap '/bin/rm -rf "$tmpdir"' EXIT

mkdir -p "$tmpdir/bin" "$tmpdir/home/.config/squad-devkit"
export HOME="$tmpdir/home"
# Isolate from the machine's config: CI runners set XDG_CONFIG_HOME.
export XDG_CONFIG_HOME="$HOME/.config"
export SQUAD_DEVKIT_CONFIG="$HOME/.config/squad-devkit/config"
unset SQUAD_DEVKIT_WORKERS SQUAD_DEVKIT_DISABLE_WORKERS SQUAD_DEVKIT_MANAGER SQUAD_DEVKIT_FORCE_PROMPT SQUAD_DEVKIT_WORKSPACE SQUAD_WORKTREE_WORKSPACE HC_TERMINAL_ID HC_TERMINAL_SOCKET HC_SCOPE HERDR_ENV HERDR_PANE_ID
# Only explicitly selected utilities and fake CLIs are visible to the launcher.
for tool in bash dirname cksum cut head tail cat mkdir sed awk grep wc tr sort find date readlink basename mv rm ln; do
  ln -s "$(command -v "$tool")" "$tmpdir/bin/$tool"
done
real_jq=$(command -v jq)
real_git=$(command -v git)
ln -s "$real_jq" "$tmpdir/bin/jq"
ln -s "$real_git" "$tmpdir/bin/git"
export PATH="$tmpdir/bin"
fail() { echo "FAIL: $*" >&2; exit 1; }

# Fake manager/worker CLIs (claude, opencode, agy) and a fake squad that prints
# help containing agy, mirroring tests/squad_devkit_workers_smoke.sh.
for cli in squad claude opencode agy; do
  cat << MOCK > "$tmpdir/bin/$cli"
#!/usr/bin/env bash
if [[ "\$*" == *"--version"* ]]; then echo "$cli version 1.0.0"; fi
if [[ "$cli \$1" == "squad help" ]]; then echo "--client <claude|codex|gemini|opencode|grok|agy|ccr>"; fi
exit 0
MOCK
  /bin/chmod +x "$tmpdir/bin/$cli"
done

SCRIPT_DIR="$(cd "$(dirname "$0")/../scripts" && pwd)"
DEVKIT="$SCRIPT_DIR/squad-devkit.sh"

echo "=== Test 1: Default setup shows roles and saves setup_mode=default ==="
out="$(printf '1\n\n' | SQUAD_DEVKIT_FORCE_PROMPT=1 "$DEVKIT" --setup 2>&1)"
grep -q 'Default (recommended)' <<<"$out" || fail "missing Default option: $out"
grep -q 'Must be right first time' <<<"$out" || fail "missing claude role: $out"
grep -q 'Normal implementation, debugging, tests' <<<"$out" || fail "missing codex role: $out"
grep -q 'Docs, comments, small exact edits' <<<"$out" || fail "missing ccr role: $out"
grep -q 'Manager: claude (Claude Code) - plans, delegates, verifies; does not write code' <<<"$out" || fail "missing manager line: $out"
grep -qx 'manager=claude' "$SQUAD_DEVKIT_CONFIG" || fail "config missing manager=claude"
grep -qx 'setup_mode=default' "$SQUAD_DEVKIT_CONFIG" || fail "config missing setup_mode=default"
if grep -q '^workers=' "$SQUAD_DEVKIT_CONFIG"; then fail "default setup must not write workers="; fi
echo "PASS: Test 1"

echo "=== Test 2: Custom setup saves typed worker order and drives the launcher ==="
rm -f "$SQUAD_DEVKIT_CONFIG"
out="$(printf '2\n1\n3,2\ny\n' | SQUAD_DEVKIT_FORCE_PROMPT=1 "$DEVKIT" --setup 2>&1)"
grep -q 'Personal custom' <<<"$out" || fail "missing Personal custom option: $out"
grep -qx 'manager=claude' "$SQUAD_DEVKIT_CONFIG" || fail "config missing manager=claude"
grep -qx 'workers=agy,opencode' "$SQUAD_DEVKIT_CONFIG" || fail "config missing workers=agy,opencode: $(cat "$SQUAD_DEVKIT_CONFIG")"
grep -qx 'setup_mode=custom' "$SQUAD_DEVKIT_CONFIG" || fail "config missing setup_mode=custom"
mkdir -p "$tmpdir/proj"
git -C "$tmpdir/proj" init -q
dry="$("$DEVKIT" "$tmpdir/proj" --dry-run 2>/dev/null)"
grep -q 'in the order the human chose' <<<"$dry" || fail "missing custom order label: $dry"
grep -q 'agy opencode' <<<"$dry" || fail "missing agy opencode order: $dry"
echo "PASS: Test 2"

echo "=== Test 3: Invalid worker input re-prompts ==="
rm -f "$SQUAD_DEVKIT_CONFIG"
out="$(printf '2\n1\n9\nopencode,opencode\n2\ny\n' | SQUAD_DEVKIT_FORCE_PROMPT=1 "$DEVKIT" --setup 2>&1)"
grep -q 'No such worker number: 9' <<<"$out" || fail "missing out-of-range message: $out"
grep -q 'Duplicate worker: opencode' <<<"$out" || fail "missing duplicate message: $out"
grep -qx 'workers=opencode' "$SQUAD_DEVKIT_CONFIG" || fail "config missing workers=opencode: $(cat "$SQUAD_DEVKIT_CONFIG")"
echo "PASS: Test 3"

echo "=== Test 4: Declining at the confirm leaves the config unchanged ==="
printf 'manager=agy\n' > "$SQUAD_DEVKIT_CONFIG"
status=0
out="$(printf '1\nn\n' | SQUAD_DEVKIT_FORCE_PROMPT=1 "$DEVKIT" --setup 2>&1)" || status=$?
[[ "$status" == 1 ]] || fail "decline should exit 1, got $status"
[[ "$(cat "$SQUAD_DEVKIT_CONFIG")" == 'manager=agy' ]] || fail "config changed on decline: $(cat "$SQUAD_DEVKIT_CONFIG")"
echo "PASS: Test 4"

echo "=== Test 5: EOF mid-wizard exits non-zero and writes nothing ==="
rm -f "$SQUAD_DEVKIT_CONFIG"
status=0
out="$(printf '2\n' | SQUAD_DEVKIT_FORCE_PROMPT=1 "$DEVKIT" --setup 2>&1)" || status=$?
[[ "$status" != 0 ]] || fail "EOF should exit non-zero"
[[ ! -e "$SQUAD_DEVKIT_CONFIG" ]] || fail "EOF must not write config: $(cat "$SQUAD_DEVKIT_CONFIG")"
echo "PASS: Test 5"

echo "=== Test 6: non-TTY without FORCE_PROMPT exits 2 ==="
status=0
out="$("$DEVKIT" --setup </dev/null 2>&1)" || status=$?
[[ "$status" == 2 ]] || fail "non-TTY setup should exit 2, got $status"
grep -q 'needs an interactive terminal' <<<"$out" || fail "missing interactive-terminal message: $out"
echo "PASS: Test 6"

echo "=== Test 7: installer follows the saved workers order (custom) ==="
printf 'manager=claude\nworkers=agy,opencode\nsetup_mode=custom\n' > "$SQUAD_DEVKIT_CONFIG"
out="$("$SCRIPT_DIR/install-devkit.sh" --no-prompt 2>/dev/null)"
grep -q 'Workers (in the order you chose): agy opencode' <<<"$out" || fail "missing custom-order workers line: $out"
if grep -q 'Workers (in the order you chose): .*claude' <<<"$out"; then fail "workers line must not list claude: $out"; fi
echo "PASS: Test 7"

echo "ALL SETUP WIZARD TESTS PASSED!"
