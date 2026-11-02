#!/usr/bin/env bash
set -euo pipefail

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/squad-test-workers.XXXXXX")
trap '/bin/rm -rf "$tmpdir"' EXIT

mkdir -p "$tmpdir/bin" "$tmpdir/home/.config/squad-devkit"
export HOME="$tmpdir/home"
# Isolate from the machine's config: CI runners set XDG_CONFIG_HOME.
export XDG_CONFIG_HOME="$HOME/.config"
export SQUAD_DEVKIT_CONFIG="$HOME/.config/squad-devkit/config"
unset SQUAD_DEVKIT_WORKERS SQUAD_DEVKIT_DISABLE_WORKERS SQUAD_DEVKIT_MANAGER
# Only explicitly selected utilities and fake CLIs are visible to the launcher.
for tool in bash dirname cksum cut head tail cat mkdir sed awk grep wc tr sort find date readlink basename; do
  ln -s "$(command -v "$tool")" "$tmpdir/bin/$tool"
done
real_git=$(command -v git)
ln -s "$real_git" "$tmpdir/bin/git"
export PATH="$tmpdir/bin"
fail() { echo "FAIL: $*" >&2; exit 1; }

# Create mock CLI binaries
for cli in squad jq tmux claude codex agy ccr grok; do
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

echo "=== Test 1: Default (all installed worker engines enabled) ==="
out=$("$DEVKIT" --doctor)
grep -q "claude.*\[enabled\]" <<<"$out" || fail "unexpected output: $out"
grep -q "codex.*\[enabled\]" <<<"$out" || fail "unexpected output: $out"
grep -q "agy.*\[enabled\]" <<<"$out" || fail "unexpected output: $out"
grep -q "ccr.*\[enabled\]" <<<"$out" || fail "unexpected output: $out"
grep -q "grok.*\[enabled\]" <<<"$out" || fail "unexpected output: $out"
echo "PASS: Test 1"

echo "=== Test 2: CLI flag --workers agy ==="
out=$("$DEVKIT" --doctor --workers agy)
grep -q "agy.*\[enabled\]" <<<"$out" || fail "unexpected output: $out"
grep -q "claude.*\[disabled\]" <<<"$out" || fail "unexpected output: $out"
grep -q "codex.*\[disabled\]" <<<"$out" || fail "unexpected output: $out"
echo "PASS: Test 2"

echo "=== Test 3: CLI flag --disable-workers claude,ccr ==="
out=$("$DEVKIT" --doctor --disable-workers claude,ccr)
grep -q "claude.*\[disabled\]" <<<"$out" || fail "unexpected output: $out"
grep -q "ccr.*\[disabled\]" <<<"$out" || fail "unexpected output: $out"
grep -q "codex.*\[enabled\]" <<<"$out" || fail "unexpected output: $out"
grep -q "agy.*\[enabled\]" <<<"$out" || fail "unexpected output: $out"
echo "PASS: Test 3"

echo "=== Test 4: Config file precedence ==="
cat << CFG > "$HOME/.config/squad-devkit/config"
manager=codex
workers=agy,codex
disabled_workers=codex
CFG
out=$("$DEVKIT" --doctor)
grep -q "Active default manager: codex" <<<"$out" || fail "unexpected output: $out"
grep -q "agy.*\[enabled\]" <<<"$out" || fail "unexpected output: $out"
grep -q "codex.*\[disabled\]" <<<"$out" || fail "unexpected output: $out"
grep -q "claude.*\[disabled\]" <<<"$out" || fail "unexpected output: $out"
echo "PASS: Test 4"

echo "=== Test 5: Env var overrides config file ==="
out=$(SQUAD_DEVKIT_WORKERS="claude" "$DEVKIT" --doctor)
grep -q "claude.*\[enabled\]" <<<"$out" || fail "unexpected output: $out"
grep -q "agy.*\[disabled\]" <<<"$out" || fail "unexpected output: $out"
echo "PASS: Test 5"

echo "=== Test 6: CLI flags override env var and config ==="
out=$(SQUAD_DEVKIT_WORKERS="claude" "$DEVKIT" --doctor --workers grok)
grep -q "grok.*\[enabled\]" <<<"$out" || fail "unexpected output: $out"
grep -q "claude.*\[disabled\]" <<<"$out" || fail "unexpected output: $out"
echo "PASS: Test 6"

echo "=== Test 7: Dry-run worker prompt verification ==="
# Check worker line generated for manager in dry-run
mkdir -p "$tmpdir/proj"
cd "$tmpdir/proj"
git init -q
[[ -d .git ]] || fail "git fixture was not initialized"
out=$("$DEVKIT" --dry-run --manager codex --workers agy --disable-workers claude,ccr)
echo "$out"
grep -q "Installed worker engines, most trusted first: agy" <<<"$out" || fail "unexpected output: $out"
echo "PASS: Test 7"

# Missing required tools must make doctor fail even when managers are installed.
for tool in squad git jq; do
  /bin/mv "$tmpdir/bin/$tool" "$tmpdir/$tool"
  status=0
  out=$("$DEVKIT" --doctor 2>&1) || status=$?
  /bin/mv "$tmpdir/$tool" "$tmpdir/bin/$tool"
  [[ "$status" == 1 ]] || fail "missing $tool returned $status"
  grep -q "\[MISSING\].*$tool.*(required)" <<<"$out" || fail "missing $tool diagnostic"
done

out=$("$DEVKIT" --doctor --disable-workers claude,codex,opencode,grok,agy,ccr)
grep -q 'Manager will work without sub-workers' <<<"$out" || fail "all-disabled diagnostic"
if grep -q '\[enabled\]' <<<"$out"; then fail "disabled worker enabled"; fi

# Unknown names are rejected.
status=0
"$DEVKIT" --doctor --workers unknown-engine >/dev/null 2>&1 || status=$?
[[ "$status" == 2 ]] || fail "unknown worker must exit 2"

out=$(SQUAD_DEVKIT_DISABLE_WORKERS=agy "$DEVKIT" --doctor --workers agy,codex --disable-workers codex)
grep -q 'agy.*\[enabled\]' <<<"$out" || fail "CLI deny must override environment"
grep -q 'codex.*\[disabled\]' <<<"$out" || fail "deny must win over allow"
out=$(SQUAD_DEVKIT_DISABLE_WORKERS=agy "$DEVKIT" --doctor --workers agy,codex)
grep -q 'agy.*\[disabled\]' <<<"$out" || fail "environment deny must apply"
grep -q 'codex.*\[enabled\]' <<<"$out" || fail "environment deny must override config"
echo "ALL WORKER TESTS PASSED!"
