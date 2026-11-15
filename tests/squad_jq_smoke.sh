#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# (a) build and prepend target/debug to PATH
cargo build -q
export PATH="$repo_root/target/debug:$PATH"

# Verify squad binary is the one from target/debug
[[ "$(command -v squad)" == "$repo_root/target/debug/squad" ]] || {
  echo "Expected target/debug/squad on PATH, got: $(command -v squad)" >&2
  exit 1
}

# (b) check squad jq output and exit codes for each flag
# Must work outside any squad workspace (e.g. in /tmp)
tmp="$(mktemp -d /tmp/squad-jq-test.XXXXXX)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

# Default pretty printing (2-space indent)
out="$(squad jq '.' <<< '{"b":2,"a":1}')"
expected="$(printf '{\n  "b": 2,\n  "a": 1\n}')"
[[ "$out" == "$expected" ]] || { echo "pretty printing failed: $out" >&2; exit 1; }

# -c / --compact-output
[[ "$(squad jq -c '.' <<< '{"b":2,"a":1}')" == '{"b":2,"a":1}' ]]
[[ "$(squad jq --compact-output '.' <<< '{"b":2,"a":1}')" == '{"b":2,"a":1}' ]]

# -r / --raw-output
[[ "$(squad jq -r '.foo' <<< '{"foo":"bar"}')" == "bar" ]]
[[ "$(squad jq --raw-output '.foo' <<< '{"foo":"bar"}')" == "bar" ]]
# Non-string under -r remains json
[[ "$(squad jq -r '.n' <<< '{"n":42}')" == "42" ]]

# -n / --null-input
[[ "$(squad jq -n '1 + 2')" == "3" ]]
[[ "$(squad jq --null-input '1 + 2')" == "3" ]]

# -R / --raw-input
printf 'line1\nline2\n' | squad jq -R -c '.' > "$tmp/raw.out"
[[ "$(cat "$tmp/raw.out")" == "$(printf '"line1"\n"line2"')" ]]
printf 'line1\n' | squad jq --raw-input -r '.' > "$tmp/raw2.out"
[[ "$(cat "$tmp/raw2.out")" == "line1" ]]

# -s / --slurp
printf '1\n2\n3\n' | squad jq -s -c '.' > "$tmp/slurp.out"
[[ "$(cat "$tmp/slurp.out")" == "[1,2,3]" ]]
printf '1\n2\n3\n' | squad jq --slurp -c '.' > "$tmp/slurp2.out"
[[ "$(cat "$tmp/slurp2.out")" == "[1,2,3]" ]]

# -e / --exit-status
# 0 on truthy
squad jq -e '.' <<< 'true' >/dev/null
squad jq --exit-status '.' <<< '{"a":1}' >/dev/null

# 1 on false or null
rc=0; squad jq -e '.' <<< 'false' >/dev/null || rc=$?
[[ "$rc" == 1 ]] || { echo "expected exit 1 on false, got $rc" >&2; exit 1; }
rc=0; squad jq --exit-status '.' <<< 'null' >/dev/null || rc=$?
[[ "$rc" == 1 ]] || { echo "expected exit 1 on null, got $rc" >&2; exit 1; }

# 4 when no output produced
rc=0; squad jq -e 'empty' <<< '1' >/dev/null || rc=$?
[[ "$rc" == 4 ]] || { echo "expected exit 4 on empty output, got $rc" >&2; exit 1; }
rc=0; squad jq --exit-status 'empty' <<< '1' >/dev/null || rc=$?
[[ "$rc" == 4 ]] || { echo "expected exit 4 on empty output, got $rc" >&2; exit 1; }

# without -e, false/null/empty exit 0
squad jq '.' <<< 'false' >/dev/null
squad jq '.' <<< 'null' >/dev/null
squad jq 'empty' <<< '1' >/dev/null

# 5 on parse or compile error
rc=0; squad jq '.' <<< 'bad json' >/dev/null 2>"$tmp/err.log" || rc=$?
[[ "$rc" == 5 ]] || { echo "expected exit 5 on json parse error, got $rc" >&2; exit 1; }
[[ -s "$tmp/err.log" ]] || { echo "expected stderr message on parse error" >&2; exit 1; }

rc=0; squad jq 'invalid [[' <<< '{}' >/dev/null 2>"$tmp/err.log" || rc=$?
[[ "$rc" == 5 ]] || { echo "expected exit 5 on filter compile error, got $rc" >&2; exit 1; }
[[ -s "$tmp/err.log" ]] || { echo "expected stderr message on compile error" >&2; exit 1; }

# 2 on usage errors
rc=0; squad jq --unknown-flag '.' <<< '{}' >/dev/null 2>"$tmp/err.log" || rc=$?
[[ "$rc" == 2 ]] || { echo "expected exit 2 on unknown flag, got $rc" >&2; exit 1; }

rc=0; squad jq 2>"$tmp/err.log" || rc=$?
[[ "$rc" == 2 ]] || { echo "expected exit 2 on missing filter, got $rc" >&2; exit 1; }

rc=0; squad jq -n --argjson x 'bad' '.' >/dev/null 2>"$tmp/err.log" || rc=$?
[[ "$rc" == 2 ]] || { echo "expected exit 2 on invalid argjson, got $rc" >&2; exit 1; }

# --arg NAME VALUE
[[ "$(squad jq -n -r --arg myname "Alice" '$myname')" == "Alice" ]]

# --argjson NAME JSON
[[ "$(squad jq -n -c --argjson obj '{"k":"v"}' '$obj.k')" == '"v"' ]]

# --args and $ARGS.positional
out="$(squad jq -n -c --args '$ARGS.positional' "first" "second" "third")"
[[ "$out" == '["first","second","third"]' ]]

# $ARGS.named
out="$(squad jq -n -c --arg a "1" --argjson b '2' '$ARGS.named')"
[[ "$out" == '{"a":"1","b":2}' ]]

# Combined short flags
# -er
squad jq -er '.ok' <<< '{"ok":true}' >/dev/null
rc=0; squad jq -er '.ok' <<< '{"ok":false}' >/dev/null || rc=$?
[[ "$rc" == 1 ]]
# -cn
[[ "$(squad jq -cn '{a:1}')" == '{"a":1}' ]]
# -nc
[[ "$(squad jq -nc '{b:2}')" == '{"b":2}' ]]
# -Rrs
printf 'foo\nbar\n' | squad jq -Rrs '.' > "$tmp/rrs.out"
[[ "$(cat "$tmp/rrs.out")" == "$(printf 'foo\nbar\n\n')" ]]

# Outside squad workspace check (no .squad dir)
(
  cd "$tmp"
  squad jq -n '1 + 1' >/dev/null
)

echo "PASS: squad jq unit flag verification"

# (c) squad-jq probe: fake squad on PATH that fails for 'jq'
(
  fake_bin="$tmp/fake-squad-bin"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/squad" << 'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "jq" ]]; then
  mkdir -p .squad/sessions
  exit 1
fi
exit 0
EOF
  chmod +x "$fake_bin/squad"

  export PATH="$fake_bin:$PATH"
  export SQUAD_DEVKIT_NO_SYSTEM_JQ=1

  # Verify fake squad is first on PATH and fails on jq
  [[ "$(command -v squad)" == "$fake_bin/squad" ]]
  rc=0; squad jq -n 1 >/dev/null 2>&1 || rc=$?
  [[ "$rc" == 1 ]]

  # Run squad_jq from a dir containing .squad/ and assert that .squad/sessions was NOT created there
  test_work_dir="$tmp/workspace_with_squad"
  mkdir -p "$test_work_dir/.squad"

  (
    cd "$test_work_dir"
    # Source squad-jq.sh and test that squad_jq works through the real built binary
    # shellcheck disable=SC1090
    source "$repo_root/scripts/lib/squad-jq.sh"
    squad_has_jq
    [[ "$(squad_bin)" == "$repo_root/target/debug/squad" ]]
    out="$(squad_jq -n '1 + 1')"
    [[ "$out" == "2" ]]

    [[ ! -e "$test_work_dir/.squad/sessions" ]] || {
      echo "FAIL: .squad/sessions was created in workspace" >&2
      exit 1
    }
  )
)

# With system jq present, sourcing the lib must spawn no squad process
(
  fake_bin="$tmp/fake-squad-no-spawn"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/squad" << 'EOF'
#!/usr/bin/env bash
echo "squad invoked unexpectedly during sourcing" >&2
exit 1
EOF
  chmod +x "$fake_bin/squad"
  (
    export PATH="$fake_bin:$PATH"
    unset SQUAD_DEVKIT_NO_SYSTEM_JQ
    # shellcheck disable=SC1090
    source "$repo_root/scripts/lib/squad-jq.sh"
    out="$(squad_jq -n '2 + 3')"
    [[ "$out" == "5" ]]
  )
)

# Test error when neither jq nor squad with jq is available
(
  err_tmp="$tmp/no-jq-bin"
  mkdir -p "$err_tmp/scripts/lib"
  cp "$repo_root/scripts/lib/squad-jq.sh" "$err_tmp/scripts/lib/"
  (
    export HOME="$err_tmp"
    export PATH="/usr/bin:/bin"
    export SQUAD_DEVKIT_NO_SYSTEM_JQ=1
    # shellcheck disable=SC1090
    source "$err_tmp/scripts/lib/squad-jq.sh"
    ! squad_has_jq
    rc=0
    err="$(squad_jq -n 1 2>&1)" || rc=$?
    [[ "$rc" == 127 ]]
    [[ "$err" == *"squad-devkit: jq not found and no squad binary with 'squad jq'; run scripts/install-devkit.sh"* ]]
  )
)

echo "PASS: squad_jq fallback probe past broken squad on PATH"

# (d) with SQUAD_DEVKIT_NO_SYSTEM_JQ=1, run existing suites
export SQUAD_DEVKIT_NO_SYSTEM_JQ=1

echo "Running tests/squad_herdr_panes_regression.sh..."
bash "$repo_root/tests/squad_herdr_panes_regression.sh"

echo "Running tests/squad_worker_model_smoke.sh..."
bash "$repo_root/tests/squad_worker_model_smoke.sh"

echo "Running tests/squad_submanager_smoke.sh..."
bash "$repo_root/tests/squad_submanager_smoke.sh"

echo "Running tests/squad_worker_smoke.sh..."
bash "$repo_root/tests/squad_worker_smoke.sh"

echo "Running tests/squad_orchestration_smoke.sh..."
bash "$repo_root/tests/squad_orchestration_smoke.sh"

echo "PASS: all JSON test suites passed with SQUAD_DEVKIT_NO_SYSTEM_JQ=1"
