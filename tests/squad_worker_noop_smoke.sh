#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
squad_bin="$(command -v squad)"
tmpdir="$(mktemp -d /tmp/squad-worker-noop.XXXXXX)"
trap 'rm -rf "$tmpdir"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
mkdir -p "$tmpdir/bin" "$tmpdir/home" "$tmpdir/project"
ln -s "$squad_bin" "$tmpdir/bin/squad"
cat > "$tmpdir/bin/agy" <<'ENGINE'
#!/usr/bin/env bash
printf 'PASS: no files changed.\n'
exit "${NOOP_ENGINE_EXIT:-0}"
ENGINE
chmod +x "$tmpdir/bin/agy"
export HOME="$tmpdir/home" PATH="$tmpdir/bin:$PATH"
export SQUAD_DEVKIT_WORKSPACE="$tmpdir/project" SQUAD_WORKER_PANES=0
unset SQUAD_MANAGER_ID
cd "$tmpdir/project"
git init -q
git -c user.name=test -c user.email=test@example.invalid commit -q --allow-empty -m fixture
squad init >/dev/null
squad join manager --role manager --client codex --protocol-version 2 >/dev/null
worker="$repo_root/scripts/squad-worker.sh"
status=0
"$worker" noop --engine agy --worktree --brief 'Report success without changing files' > "$tmpdir/output" 2>&1 || status=$?
if [[ "$status" != 0 ]]; then
  cat "$tmpdir/output" >&2
  fail "successful no-op worker exited $status"
fi
status_file=(.squad/workers/noop-*.status)
[[ "${#status_file[@]}" == 1 && -f "${status_file[0]}" ]] || fail 'missing worker status'
grep -qx 'state=completed' "${status_file[0]}" || fail 'no-op worker not completed'
grep -qx 'exit=0' "${status_file[0]}" || fail 'no-op worker exit not zero'
patch_file=(.squad/workers/noop-*.patch)
[[ "${#patch_file[@]}" == 1 && -f "${patch_file[0]}" && ! -s "${patch_file[0]}" ]] || fail 'expected empty patch'
grep -q '0 changed file(s)' "$tmpdir/output" || fail 'missing zero-change report'
"$worker" --discard noop >/dev/null
status=0
NOOP_ENGINE_EXIT=3 "$worker" noop-failed --engine agy --worktree --brief 'Fail without changing files' > "$tmpdir/output" 2>&1 || status=$?
[[ "$status" == 3 ]] || fail "failed no-op worker returned $status instead of 3"
status_file=(.squad/workers/noop-failed-*.status)
[[ "${#status_file[@]}" == 1 && -f "${status_file[0]}" ]] || fail 'missing failed worker status'
grep -qx 'state=failed' "${status_file[0]}" || fail 'failed no-op worker not failed'
grep -qx 'exit=3' "${status_file[0]}" || fail 'failed engine exit was masked'
"$worker" --discard noop-failed >/dev/null
printf 'PASS: no-op worktree workers preserve success and failure\n'
