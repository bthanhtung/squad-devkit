#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmpdir="$(mktemp -d /tmp/squad-worker-validation.XXXXXX)"
trap 'rm -rf "$tmpdir"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
export HOME="$tmpdir/home"
mkdir -p "$HOME"
# Keep the caller's environment from changing the outcome of any case below.
unset SQUAD_DEVKIT_WORKERS SQUAD_DEVKIT_DISABLE_WORKERS SQUAD_DEVKIT_WORKSPACE \
  SQUAD_DEVKIT_CONFIG SQUAD_WORKER_SANDBOX SQUAD_WORKER_TIMEOUT SQUAD_WORKER_STALL
worker="$repo_root/scripts/squad-worker.sh"
devkit="$repo_root/scripts/squad-devkit.sh"

# expect_usage_error PATTERN CMD... : exit 2 and PATTERN on stderr.
expect_usage_error() {
  local pattern="$1" status=0
  shift
  "$@" >"$tmpdir/out" 2>&1 </dev/null || status=$?
  [[ "$status" == 2 ]] || { cat "$tmpdir/out" >&2; fail "$* exited $status, want 2"; }
  grep -q -- "$pattern" "$tmpdir/out" || { cat "$tmpdir/out" >&2; fail "$*: missing '$pattern'"; }
}

for id in ../evil 'a b' .hidden; do
  expect_usage_error "Invalid worker id: $id" "$worker" "$id" --engine agy --brief hi
done
for flag in --merge --discard --diff --stop; do
  expect_usage_error "Invalid worker id: ../evil" "$worker" "$flag" ../evil
done
expect_usage_error "at least 1" "$worker" w1 --engine agy --brief hi --timeout 0
expect_usage_error "Brief file not readable: $tmpdir/missing" "$worker" w1 --engine agy --brief-file "$tmpdir/missing"
expect_usage_error "mutually exclusive" "$worker" w1 --engine agy --brief hi --sandbox --no-sandbox
expect_usage_error "Unknown worker: bogus (use one of:" "$devkit" --dry-run --no-prompt --workers claude,bogus "$tmpdir"
expect_usage_error "Unknown worker: nope" "$devkit" --dry-run --no-prompt --disable-workers nope "$tmpdir"
expect_usage_error "Unknown worker: envbad" env SQUAD_DEVKIT_WORKERS=envbad "$devkit" --dry-run --no-prompt "$tmpdir"

# Edge cases below run from an empty directory with no .squad/ above it. A value
# that passes validation stops at "No .squad/ found"; a rejected one exits 2 first.
mkdir -p "$tmpdir/bin" "$tmpdir/empty" "$tmpdir/ws/.squad/workers" "$tmpdir/brief-dir"
for cli in squad agy codex claude; do
  printf '#!/usr/bin/env bash\nexit 0\n' >"$tmpdir/bin/$cli"
  chmod +x "$tmpdir/bin/$cli"
done
export PATH="$tmpdir/bin:$PATH"
cd "$tmpdir/empty"
no_workspace="No .squad/ found above"

# expect_exit STATUS PATTERN CMD... : exit STATUS and PATTERN on the combined output.
expect_exit() {
  local want="$1" pattern="$2" status=0
  shift 2
  "$@" >"$tmpdir/out" 2>&1 </dev/null || status=$?
  [[ "$status" == "$want" ]] || { cat "$tmpdir/out" >&2; fail "$* exited $status, want $want"; }
  grep -q -- "$pattern" "$tmpdir/out" || { cat "$tmpdir/out" >&2; fail "$*: missing '$pattern'"; }
}

# capture CMD... : run CMD; its exit status and output go to $captured_status and $captured_out.
capture() {
  captured_status=0
  captured_out="$("$@" 2>&1 </dev/null)" || captured_status=$?
}

# expect_engine ENGINE enabled|disabled : doctor output lists ENGINE with that state.
expect_engine() {
  grep -Eq "\[FOUND\] +$1 .*\[$2\]" <<<"$captured_out" || { echo "$captured_out" >&2; fail "$1 not $2"; }
}

# Worker ids start with a letter or digit, then letters, digits, '.', '_' or '-'.
for id in . .. a/b 'a;b' 'é1' _x; do
  expect_exit 2 "Invalid worker id: $id" "$worker" "$id" --engine agy --brief hi
done
for id in dev-1 a.b_c A9 "$(printf 'a%.0s' {1..200})"; do
  expect_exit 1 "$no_workspace" "$worker" "$id" --engine agy --brief hi
done

# --stop/--discard/--merge with "all" pass validation; merge/discard/stop reject traversal ids.
ws_env=(env SQUAD_DEVKIT_WORKSPACE="$tmpdir/ws")
expect_exit 0 "No running worker matches all." "${ws_env[@]}" "$worker" --stop all
expect_exit 0 "No unmerged worktrees." "${ws_env[@]}" "$worker" --discard all
expect_exit 0 "No unmerged worktrees." "${ws_env[@]}" "$worker" --merge all
expect_exit 2 "Invalid worker id: ../x" "${ws_env[@]}" "$worker" --merge ../x
expect_exit 2 "Invalid worker id: ../x" "${ws_env[@]}" "$worker" --discard ../x
expect_exit 2 "Invalid worker id: ." "${ws_env[@]}" "$worker" --stop .
expect_exit 2 "Missing value for --stop" "$worker" --stop ""

# --timeout must be a whole number of minutes, at least 1.
for timeout in 00 -1 1.5 ' 5'; do
  expect_exit 2 "at least 1" "$worker" w1 --engine agy --brief hi --timeout "$timeout"
done
expect_exit 1 "$no_workspace" "$worker" w1 --engine agy --brief hi --timeout 1
expect_exit 2 "take whole minutes" env SQUAD_WORKER_TIMEOUT=abc "$worker" w1 --engine agy --brief hi

# Brief sources: a directory is not a readable file; empty or blank briefs are rejected.
expect_exit 2 "Brief file not readable: $tmpdir/brief-dir" "$worker" w1 --engine agy --brief-file "$tmpdir/brief-dir"
: >"$tmpdir/empty.md"
printf ' \n\t\n' >"$tmpdir/blank.md"
expect_exit 2 "The brief is empty" "$worker" w1 --engine agy --brief-file "$tmpdir/empty.md"
expect_exit 2 "The brief is empty" "$worker" w1 --engine agy --brief-file "$tmpdir/blank.md"
expect_exit 2 "The brief is empty" "$worker" w1 --engine agy --brief-file -
expect_exit 2 "The brief is empty" "$worker" w1 --engine agy --brief '   '

# SQUAD_WORKER_SANDBOX is a default only: explicit flags still win, and both flags still conflict.
expect_exit 2 "mutually exclusive" env SQUAD_WORKER_SANDBOX=1 "$worker" w1 --engine agy --brief hi --sandbox --no-sandbox
expect_exit 1 "$no_workspace" env SQUAD_WORKER_SANDBOX=0 "$worker" w1 --engine agy --brief hi --sandbox
expect_exit 1 "$no_workspace" "$worker" w1 --engine agy --brief hi --no-sandbox

# Roles added with the ui-ux and security templates are accepted.
for role in ui-ux security; do
  expect_exit 1 "$no_workspace" "$worker" w1 --engine agy --brief hi --role "$role"
done

# --workers / --disable-workers lists: empty items are skipped, names are exact, unknown names exit 2.
capture "$devkit" --doctor --workers 'codex,,claude'
[[ "$captured_status" != 2 ]] || fail "--workers codex,,claude rejected: $captured_out"
expect_engine codex enabled
expect_engine claude enabled
expect_engine agy disabled

capture "$devkit" --doctor --workers 'codex,'
[[ "$captured_status" != 2 ]] || fail "--workers codex, rejected: $captured_out"
expect_engine codex enabled
expect_engine claude disabled

capture "$devkit" --doctor --workers ' codex'
[[ "$captured_status" != 2 ]] || fail "--workers ' codex' rejected: $captured_out"
expect_engine codex enabled
expect_engine claude disabled

capture "$devkit" --doctor --disable-workers 'codex,,'
[[ "$captured_status" != 2 ]] || fail "--disable-workers codex,, rejected: $captured_out"
expect_engine codex disabled
expect_engine claude enabled

expect_exit 2 "Unknown worker: CODEX" "$devkit" --doctor --workers CODEX
expect_exit 2 "Unknown worker: bogus" env SQUAD_DEVKIT_WORKERS=bogus "$devkit" --doctor
expect_exit 2 "Unknown worker: bogus" "$devkit" --doctor --disable-workers bogus

echo "PASS: squad-worker/devkit validation"
