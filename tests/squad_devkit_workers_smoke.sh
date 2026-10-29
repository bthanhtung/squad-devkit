#!/usr/bin/env bash
set -euo pipefail

tmpdir=$(mktemp -d /tmp/squad-test-workers.XXXXXX)
trap 'rm -rf "$tmpdir"' EXIT

export PATH="$tmpdir/bin:$PATH"
mkdir -p "$tmpdir/bin" "$tmpdir/home/.config/squad-devkit"
export HOME="$tmpdir/home"

# Create mock CLI binaries
for cli in squad git jq tmux claude codex agy ccr grok; do
  cat << MOCK > "$tmpdir/bin/$cli"
#!/usr/bin/env bash
if [[ "\$*" == *"--version"* ]]; then echo "$cli version 1.0.0"; fi
exit 0
MOCK
  chmod +x "$tmpdir/bin/$cli"
done

SCRIPT_DIR="$(cd "$(dirname "$0")/../scripts" && pwd)"
DEVKIT="$SCRIPT_DIR/squad-devkit.sh"

echo "=== Test 1: Default (all installed worker engines enabled) ==="
out=$("$DEVKIT" --doctor)
echo "$out" | grep -q "claude.*\[enabled\]"
echo "$out" | grep -q "codex.*\[enabled\]"
echo "$out" | grep -q "agy.*\[enabled\]"
echo "$out" | grep -q "ccr.*\[enabled\]"
echo "$out" | grep -q "grok.*\[enabled\]"
echo "PASS: Test 1"

echo "=== Test 2: CLI flag --workers agy ==="
out=$("$DEVKIT" --doctor --workers agy)
echo "$out" | grep -q "agy.*\[enabled\]"
echo "$out" | grep -q "claude.*\[disabled\]"
echo "$out" | grep -q "codex.*\[disabled\]"
echo "PASS: Test 2"

echo "=== Test 3: CLI flag --disable-workers claude,ccr ==="
out=$("$DEVKIT" --doctor --disable-workers claude,ccr)
echo "$out" | grep -q "claude.*\[disabled\]"
echo "$out" | grep -q "ccr.*\[disabled\]"
echo "$out" | grep -q "codex.*\[enabled\]"
echo "$out" | grep -q "agy.*\[enabled\]"
echo "PASS: Test 3"

echo "=== Test 4: Config file precedence ==="
cat << CFG > "$HOME/.config/squad-devkit/config"
manager=codex
workers=agy,codex
disabled_workers=codex
CFG
out=$("$DEVKIT" --doctor)
echo "$out" | grep -q "Active default manager: codex"
echo "$out" | grep -q "agy.*\[enabled\]"
echo "$out" | grep -q "codex.*\[disabled\]"
echo "$out" | grep -q "claude.*\[disabled\]"
echo "PASS: Test 4"

echo "=== Test 5: Env var overrides config file ==="
out=$(SQUAD_DEVKIT_WORKERS="claude" "$DEVKIT" --doctor)
echo "$out" | grep -q "claude.*\[enabled\]"
echo "$out" | grep -q "agy.*\[disabled\]"
echo "PASS: Test 5"

echo "=== Test 6: CLI flags override env var and config ==="
out=$(SQUAD_DEVKIT_WORKERS="claude" "$DEVKIT" --doctor --workers grok)
echo "$out" | grep -q "grok.*\[enabled\]"
echo "$out" | grep -q "claude.*\[disabled\]"
echo "PASS: Test 6"

echo "=== Test 7: Dry-run worker prompt verification ==="
# Check worker line generated for manager in dry-run
mkdir -p "$tmpdir/proj"
cd "$tmpdir/proj"
git init -q
out=$("$DEVKIT" --dry-run --manager codex --workers agy --disable-workers claude,ccr)
echo "$out"
echo "$out" | grep -q "Installed worker engines, most trusted first: agy"
echo "PASS: Test 7"

echo "ALL WORKER TESTS PASSED!"
