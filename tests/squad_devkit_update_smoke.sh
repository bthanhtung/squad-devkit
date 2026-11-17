#!/usr/bin/env bash
set -euo pipefail

# Non-interactive bash cannot trap SIGHUP when its parent process set SIGHUP to
# SIG_IGN (e.g. backgrounded agent/CI runners). Restore SIG_DFL once if needed.
if [[ -z "$(trap ':' HUP; trap -p HUP)" ]] && command -v perl >/dev/null 2>&1; then
  exec perl -e '$SIG{HUP} = "DEFAULT"; exec @ARGV' "$BASH" "$0" "$@"
fi

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/squad-test-update.XXXXXX")"
dummy_pid=""
cleanup() {
  if [[ -n "$dummy_pid" ]]; then
    kill "$dummy_pid" 2>/dev/null || true
    wait "$dummy_pid" 2>/dev/null || true
  fi
  /bin/rm -rf "$tmpdir"
}
trap cleanup EXIT

mkdir -p "$tmpdir/bin" "$tmpdir/home/.config/squad-devkit" "$tmpdir/bin-links"
export HOME="$tmpdir/home"
export XDG_CONFIG_HOME="$HOME/.config"
export SQUAD_DEVKIT_CONFIG="$HOME/.config/squad-devkit/config"
export SQUAD_DEVKIT_BIN_DIR="$tmpdir/bin-links"
unset SQUAD_DEVKIT_WORKERS SQUAD_DEVKIT_DISABLE_WORKERS SQUAD_DEVKIT_MANAGER \
  SQUAD_DEVKIT_FORCE_PROMPT SQUAD_DEVKIT_WORKSPACE SQUAD_WORKTREE_WORKSPACE \
  SQUAD_MANAGER_ID SQUAD_WORKER_VIEW SQUAD_DEVKIT_YOLO SQUAD_DEVKIT_REPO_ROOT \
  HC_TERMINAL_ID HC_TERMINAL_SOCKET HC_SCOPE HERDR_ENV HERDR_PANE_ID \
  CODEX_HOME CLAUDE_CONFIG_DIR

for tool in bash dirname cksum cut head tail cat mkdir sed awk grep wc tr sort find date readlink basename mv rm ln cp cmp sleep id chmod; do
  if command -v "$tool" >/dev/null 2>&1; then
    ln -s "$(command -v "$tool")" "$tmpdir/bin/$tool"
  fi
done
ln -s "$(command -v jq)" "$tmpdir/bin/jq"
ln -s "$(command -v git)" "$tmpdir/bin/git"

# Shim pgrep so reload only ever sees the test's own dummy view, never real ones.
export TEST_ORCH_PID_FILE="$tmpdir/orch.pid"
cat <<'PGREP_SHIM' >"$tmpdir/bin/pgrep"
#!/usr/bin/env bash
if [[ "$*" == *"squad-orchestration"* && -f "${TEST_ORCH_PID_FILE:-}" ]]; then
  pid="$(cat "$TEST_ORCH_PID_FILE")"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    printf '%s\n' "$pid"
    exit 0
  fi
fi
exit 1
PGREP_SHIM
chmod +x "$tmpdir/bin/pgrep"

export PATH="$tmpdir/bin"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# Fake manager/worker CLIs and squad.
for cli in squad claude codex opencode grok; do
  cat <<MOCK >"$tmpdir/bin/$cli"
#!/usr/bin/env bash
if [[ "\$*" == *"--version"* ]]; then echo "$cli version 1.0.0"; fi
if [[ "$cli \$1" == "squad help" ]]; then echo "--client <claude|codex|gemini|opencode|grok|agy|ccr>"; fi
exit 0
MOCK
  chmod +x "$tmpdir/bin/$cli"
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEVKIT="$SCRIPT_DIR/squad-devkit.sh"

echo "=== Test 1: reload in a temp project refreshes roles, links, and prints manager instructions ==="
proj="$tmpdir/proj"
mkdir -p "$proj"
git -C "$proj" init -q
mkdir -p "$proj/.squad/roles"
printf '<!-- squad-devkit template: old -->\nstale manager role\n' >"$proj/.squad/roles/manager-devkit.md"
printf 'manager=claude\nworkers=grok,opencode\nsetup_mode=custom\nview=orchestration\n' >"$SQUAD_DEVKIT_CONFIG"

out="$(cd "$proj" && SQUAD_MANAGER_ID=manager-4 SQUAD_WORKER_VIEW=panes "$DEVKIT" reload)"
cmp -s "$REPO_ROOT/templates/devkit/manager-devkit.md" "$proj/.squad/roles/manager-devkit.md" ||
  fail "manager-devkit.md was not refreshed"
[[ "$(readlink "$SQUAD_DEVKIT_BIN_DIR/squad-devkit")" == "$SCRIPT_DIR/squad-devkit.sh" ]] ||
  fail "squad-devkit link was not created in SQUAD_DEVKIT_BIN_DIR"
grep -q '^roles refreshed ' <<<"$out" || fail "missing roles refreshed line: $out"
grep -qx 'links refreshed' <<<"$out" || fail "missing links refreshed line: $out"
grep -qx '0 orchestration views reloaded' <<<"$out" || fail "expected 0 orchestration views reloaded: $out"
grep -qx 'Follow these instructions from now on; they replace the squad-devkit instructions given at session start\.' <<<"$out" ||
  fail "missing replacement preamble line: $out"
grep -qx '## Updated squad-devkit manager instructions (replace the earlier ones)' <<<"$out" ||
  fail "missing updated instructions heading: $out"
grep -q 'You are the Claude Code manager of this squad devkit' <<<"$out" ||
  fail "missing manager label in instructions: $out"
grep -q 'You already joined the squad as manager-4;' <<<"$out" ||
  fail "MANAGER_ID was not replaced with manager-4: $out"
grep -q 'Always pass --manager manager-4 on every worker launch' <<<"$out" ||
  fail "worker launch MANAGER_ID was not replaced: $out"
grep -q 'Installed worker engines, in the order the human chose (prefer earlier ones): grok opencode' <<<"$out" ||
  fail "missing configured worker order grok opencode: $out"
grep -q '## Your role (.squad/roles/manager-devkit.md)' <<<"$out" ||
  fail "missing role section heading: $out"
grep -q 'You do not write code\.' <<<"$out" ||
  fail "missing role file body: $out"
grep -q 'squad-devkit update' <<<"$out" ||
  fail "missing update/reload line from manager-devkit.md: $out"
if grep -q '{{MANAGER_ID}}\|{{MANAGER_LABEL}}' <<<"$out"; then
  fail "unreplaced template placeholders in output: $out"
fi
grep -q 'Note: session env SQUAD_WORKER_VIEW=panes differs from config view=orchestration' <<<"$out" ||
  fail "missing env vs config note: $out"
echo "PASS: Test 1"

echo "=== Test 2: reload HUPs running squad-orchestration.sh process and reports 1 view ==="
hup_file="$tmpdir/hup.log"
rm -f "$hup_file"
bash -c "trap 'echo hup >>\"$hup_file\"' HUP; while :; do sleep 0.1; done" squad-orchestration.sh &
dummy_pid=$!
printf '%s\n' "$dummy_pid" >"$TEST_ORCH_PID_FILE"
sleep 0.2

out="$(cd "$proj" && "$DEVKIT" --reload)"
grep -qx '1 orchestration views reloaded' <<<"$out" ||
  fail "expected 1 orchestration views reloaded, got: $out"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [[ -s "$hup_file" ]] && break
  sleep 0.1
done
kill "$dummy_pid" 2>/dev/null || true
wait "$dummy_pid" 2>/dev/null || true
dummy_pid=""
rm -f "$TEST_ORCH_PID_FILE"
[[ -f "$hup_file" && "$(cat "$hup_file")" == "hup" ]] ||
  fail "dummy squad-orchestration.sh process did not receive SIGHUP"
echo "PASS: Test 2"

echo "=== Test 3: restart word behaves like reload; reload directory in cwd becomes project path ==="
out_restart="$(cd "$proj" && "$DEVKIT" restart)"
grep -qx '## Updated squad-devkit manager instructions (replace the earlier ones)' <<<"$out_restart" ||
  fail "restart did not behave like reload: $out_restart"

cwd_with_dir="$tmpdir/cwd-with-reload"
mkdir -p "$cwd_with_dir/reload"
git -C "$cwd_with_dir/reload" init -q
dry_dir="$(cd "$cwd_with_dir" && "$DEVKIT" reload --dry-run)"
resolved_reload_dir="$(cd "$cwd_with_dir/reload" && pwd -P)"
grep -qx "Project: $resolved_reload_dir" <<<"$dry_dir" ||
  fail "expected directory named reload in cwd to be treated as project path, got: $dry_dir"
if grep -q 'Updated squad-devkit manager instructions' <<<"$dry_dir"; then
  fail "reload directory should not trigger reload subcommand: $dry_dir"
fi
echo "PASS: Test 3"

echo "=== Test 4: update pulls fast-forward commits and handles dirty worktree ==="
origin="$tmpdir/origin.git"
work_src="$tmpdir/work-src"
clone="$tmpdir/devkit-clone"
git init -q --bare "$origin"
git clone -q "$origin" "$work_src"
git -C "$work_src" config user.name "Test"
git -C "$work_src" config user.email "test@example.com"
printf 'v1\n' >"$work_src/file.txt"
git -C "$work_src" add file.txt
git -C "$work_src" commit -q -m "initial"
git -C "$work_src" push -q origin HEAD
old_sha="$(git -C "$work_src" rev-parse --short HEAD)"

git clone -q "$origin" "$clone"
git -C "$clone" config user.name "Test"
git -C "$clone" config user.email "test@example.com"

printf 'v2\n' >"$work_src/file.txt"
git -C "$work_src" commit -q -am "second"
git -C "$work_src" push -q origin HEAD
new_sha="$(git -C "$work_src" rev-parse --short HEAD)"

out_up="$(cd "$proj" && SQUAD_DEVKIT_REPO_ROOT="$clone" "$DEVKIT" update)"
grep -qx "pulled ${old_sha}..${new_sha}" <<<"$out_up" ||
  fail "expected pulled ${old_sha}..${new_sha}, got: $out_up"
grep -qx '## Updated squad-devkit manager instructions (replace the earlier ones)' <<<"$out_up" ||
  fail "missing reload heading after update: $out_up"

out_uptodate="$(cd "$proj" && SQUAD_DEVKIT_REPO_ROOT="$clone" "$DEVKIT" --update)"
grep -qx 'already up to date' <<<"$out_uptodate" ||
  fail "expected already up to date, got: $out_uptodate"

# Dirty clone: skip pull, still reload, exit 1
printf 'dirty\n' >>"$clone/file.txt"
status=0
out_dirty="$(cd "$proj" && SQUAD_DEVKIT_REPO_ROOT="$clone" "$DEVKIT" update 2>&1)" || status=$?
[[ "$status" == 1 ]] || fail "dirty update should exit 1, got $status"
grep -qx 'devkit repo has local changes; not pulling' <<<"$out_dirty" ||
  fail "missing local changes message: $out_dirty"
grep -qx '## Updated squad-devkit manager instructions (replace the earlier ones)' <<<"$out_dirty" ||
  fail "dirty update must still print reload heading: $out_dirty"
echo "PASS: Test 4"

echo "=== Test 5: launcher --dry-run manager prompt keeps its key lines after refactor ==="
dry_out="$(SQUAD_MANAGER_ID=manager-9 "$DEVKIT" "$proj" --dry-run)"
grep -q 'You are the {{MANAGER_LABEL}} manager of this squad devkit' <<<"$dry_out" ||
  fail "dry-run missing {{MANAGER_LABEL}} template line: $dry_out"
grep -q 'You already joined the squad as {{MANAGER_ID}}; workers report to you automatically\.' <<<"$dry_out" ||
  fail "dry-run missing {{MANAGER_ID}} template line: $dry_out"
grep -q 'Always pass --manager {{MANAGER_ID}} on every worker launch' <<<"$dry_out" ||
  fail "dry-run missing worker launch line: $dry_out"
grep -q 'squad receive {{MANAGER_ID}} --wait --timeout 900' <<<"$dry_out" ||
  fail "dry-run missing squad receive line: $dry_out"
grep -q 'Installed worker engines, in the order the human chose (prefer earlier ones): grok opencode' <<<"$dry_out" ||
  fail "dry-run missing worker order line: $dry_out"
grep -q 'Workers work in this repository by default; pass --project <path> to have one work in another repository\.' <<<"$dry_out" ||
  fail "dry-run missing repository line: $dry_out"
echo "PASS: Test 5"

echo "=== Test 6: non-git repo root skips pull; completions include update/reload/restart ==="
non_git="$tmpdir/non-git-root"
mkdir -p "$non_git"
out_nongit="$(cd "$proj" && SQUAD_DEVKIT_REPO_ROOT="$non_git" "$DEVKIT" update)"
grep -qx 'not a git checkout; skipping pull' <<<"$out_nongit" ||
  fail "expected not a git checkout message: $out_nongit"
grep -qx '## Updated squad-devkit manager instructions (replace the earlier ones)' <<<"$out_nongit" ||
  fail "expected reload heading after non-git update: $out_nongit"

(
  # shellcheck source=../scripts/completions/squad-devkit.bash
  source "$REPO_ROOT/scripts/completions/squad-devkit.bash"
  COMP_WORDS=(squad-devkit --up)
  COMP_CWORD=1
  COMPREPLY=()
  _squad_devkit
  [[ "${COMPREPLY[*]}" == "--update" ]] || fail "bash completion missing --update: ${COMPREPLY[*]}"
  COMP_WORDS=(squad-devkit --rel)
  COMP_CWORD=1
  COMPREPLY=()
  _squad_devkit
  [[ "${COMPREPLY[*]}" == "--reload" ]] || fail "bash completion missing --reload: ${COMPREPLY[*]}"
  COMP_WORDS=(squad-devkit re)
  COMP_CWORD=1
  COMPREPLY=()
  _squad_devkit
  [[ " ${COMPREPLY[*]} " == *" reload "* && " ${COMPREPLY[*]} " == *" restart "* ]] ||
    fail "bash completion missing reload/restart words: ${COMPREPLY[*]}"
)
echo "PASS: Test 6"

echo "ALL UPDATE & RELOAD TESTS PASSED!"
