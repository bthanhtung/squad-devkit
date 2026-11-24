#!/usr/bin/env bash
# shellcheck disable=SC2154 # Shared learn functions initialize their output globals.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d /tmp/squad-learn.XXXXXX)"
trap 'rc=$?; if (( rc != 0 )) && [[ -f "$tmp/err" ]]; then cat "$tmp/err" >&2; for log in .squad/workers/safe-*.log .squad/workers/safe-*.status; do [[ ! -f "$log" ]] || cat "$log" >&2; done; fi; rm -rf "$tmp"' EXIT
export SQUAD_LEARN_LOCK_TIMEOUT=1
export HOME="$tmp/home" SQUAD_DEVKIT_CONFIG="$tmp/config"
mkdir -p "$HOME" "$tmp/project"
cd "$tmp/project"
git init -q
learn="$repo/scripts/squad-learn.sh"
id="$(printf 'Use safe quoting.\n' | "$learn" propose --title Quoting --paths 'scripts/*')"
"$learn" list | grep -q "$id"
"$learn" show "$id" | grep -q 'Use safe quoting'
if "$learn" approve "$id" </dev/null; then echo 'non-TTY approval accepted' >&2; exit 1; fi
if "$learn" show ../escape; then echo 'traversal accepted' >&2; exit 1; fi
"$learn" reject "$id"
[[ ! -e ".squad/knowledge/pending/$id.md" ]]
echo 'PASS: learn proposal boundaries'
# Give stdin a real TTY without depending on platform-specific script flags.
pty_run() {
  python3 - "$@" <<'PY'
import os, pty, subprocess, sys
master, slave = pty.openpty()
os.write(master, b'yes\n' * 32)
result = subprocess.run(sys.argv[1:], stdin=slave, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
os.close(slave)
os.close(master)
sys.stdout.buffer.write(result.stdout)
sys.exit(result.returncode)
PY
}
# shellcheck source=../scripts/squad-learn.sh
source "$learn"
learn_init "$PWD"
[[ "$learn_store" != "$PWD"/* && "$learn_store" == "$(cd "$SQUAD_DEVKIT_CONFIG" && pwd -P)"/* ]]
mkdir -p .squad/rules
mkdir -p scripts; touch scripts/example.sh
source_hash="$( { printf 'scripts/example.sh\0'; cat scripts/example.sh; printf '\0'; } | shasum -a 256 | awk '{print $1}')"
printf '%s\n' '---' 'paths: scripts/*' "sources_sha256: $source_hash" '---' 'Use the repository scripts.' >.squad/rules/scripts.md
printf '%s\n' '---' 'paths: missing/*' '---' 'This rule has drifted.' >.squad/rules/stale.md
if "$learn" verify >/dev/null 2>&1; then echo 'stale repo rule was accepted' >&2; exit 1; fi
grep -q 'stale.md' <<<"$("$learn" verify --json)"
rm .squad/rules/stale.md
"$learn" verify >/dev/null
printf 'changed\n' >scripts/example.sh
if "$learn" verify >"$tmp/stale-source" 2>&1; then echo 'changed rule source was accepted' >&2; exit 1; fi
grep -q 'stale (source changed)' "$tmp/stale-source"
printf 'fixture\n' >scripts/example.sh
learn_inject 'scripts/example.sh'
[[ "$learn_ids" == rule:scripts && "$learn_notes" == *'> Use the repository scripts.'* ]]
rm .squad/rules/scripts.md
id="$(printf '%s\n' '```' '$(touch SHOULD-NOT-EXIST)' '---' 'paths: $(touch ALSO-NOT)' | "$learn" propose --title '$(false)' --paths 'scripts/*')"
pty_run "$learn" approve "$id" >"$tmp/approval"
[[ -f "$learn_store/INDEX" ]]
[[ "$(stat -f %Lp "$learn_store/$id.md" 2>/dev/null || stat -c %a "$learn_store/$id.md")" == 444 ]]
# A read-only fixture simulates the worker's denied write mount.
chmod 555 "$learn_store"
if (printf 'forbidden' >"$learn_store/worker-write") 2>/dev/null; then
  echo 'sandbox fixture unexpectedly writable' >&2; exit 1
fi
chmod 755 "$learn_store"
learn_inject 'scripts/example.sh'
[[ ",$learn_ids," == *",$id,"* && "$learn_notes" == *'> $(touch SHOULD-NOT-EXIST)'* ]] || exit 1
[[ ! -e SHOULD-NOT-EXIST && ! -e ALSO-NOT ]]
[[ "$(printf '%s' "$learn_notes" | wc -c)" -le 2048 ]]
if printf '%s' "$learn_notes" | grep -v '^> '; then echo 'unquoted note line' >&2; exit 1; fi
learn_inject 'src/main.rs'; [[ -z "$learn_ids" ]] || exit 1
learn_inject ''; [[ -z "$learn_ids" ]] || exit 1
if learn_sandbox_check none 0 || learn_sandbox_check danger-full-access 0 || learn_sandbox_check workspace-write 1; then
  echo 'unsafe sandbox accepted' >&2; exit 1
fi
learn_sandbox_check workspace-write 0
# Hash drift is detected, never evaluated.
chmod 644 "$learn_store/$id.md"
printf 'tampered\n' >>"$learn_store/$id.md"
learn_inject 'scripts/example.sh'
[[ "$learn_ids" == rule:scripts && "$learn_warnings" == *'hash mismatch'* ]]
pty_run "$learn" disable >"$tmp/disable"
[[ ! -e "$learn_store/INDEX" ]]
learn_sandbox_check none 0
archive="$(find "$learn_base" -name 'disabled-*' -type d | head -n 1)"
[[ ! -e "$archive/INDEX" ]]
pty_run "$learn" enable >"$tmp/enable"
grep -q tampered "$tmp/enable"
learn_inject 'scripts/example.sh'; [[ ",$learn_ids," == *",$id,"* ]] || exit 1
# Shared lock refuses both launch decisions and enable; foreign locks remain intact.
learn_lock_acquire
if pty_run "$learn" enable >"$tmp/locked"; then echo 'lock bypassed' >&2; exit 1; fi
learn_lock_release
mkdir "$learn_lock"
printf 'pid=99999999\nhost=foreign\n' >"$learn_lock/owner"
if learn_lock_acquire; then echo 'foreign lock reclaimed' >&2; exit 1; fi
rm "$learn_lock/owner"; rmdir "$learn_lock"
mkdir "$learn_lock"
printf 'pid=99999999\nhost=%s\n' "$(hostname -s)" >"$learn_lock/owner"
learn_lock_acquire; learn_lock_release
# A dead unsafe wrapper with a live engine still prevents approval and enable.
mkdir -p .squad/workers
printf 'host=%s\nsandbox=none\npid=99999999\nprocess_started=dead\nengine_pid=%s\nengine_pgid=99999999\nengine_started=%s\nstate=lost\n' \
  "$(hostname -s)" "$$" "$(LC_ALL=C ps -p "$$" -o lstart= | awk '{$1=$1;print}')" > .squad/workers/orphan.status
pty_run "$learn" disable >"$tmp/disable"
if pty_run "$learn" enable >"$tmp/orphan"; then echo 'orphan engine ignored' >&2; exit 1; fi
id2="$(printf 'pending\n' | "$learn" propose --title Pending --paths '*')"
if pty_run "$learn" approve "$id2" >"$tmp/orphan"; then echo 'approval ignored orphan' >&2; exit 1; fi
mv .squad/workers/orphan.status "$tmp/outside.status"
printf '%s\n' "$tmp/outside.status" >"$learn_base/RUNS"
if pty_run "$learn" enable >"$tmp/external"; then echo 'external workspace orphan ignored' >&2; exit 1; fi
mv "$tmp/outside.status" .squad/workers/orphan.status
printf 'host=%s\nsandbox=danger-full-access\npid=%s\nprocess_started=%s\n' "$(hostname -s)" "$$" "$(LC_ALL=C ps -p "$$" -o lstart= | awk '{$1=$1;print}')" >.squad/workers/orphan.status
if pty_run "$learn" enable >"$tmp/wrapper"; then echo 'live unsafe wrapper ignored' >&2; exit 1; fi
printf 'state=completed\n' >.squad/workers/orphan.status
if pty_run "$learn" enable >"$tmp/unknown"; then echo 'missing sandbox accepted' >&2; exit 1; fi
rm .squad/workers/orphan.status
pty_run "$learn" enable >"$tmp/enable"
# Several matching notes exceed the aggregate budget, but never the prompt cap.
for n in 1 2 3; do
  large="$(python3 -c 'print("a" * 850)')"
  next="$(printf '%s\n' "$large" | "$learn" propose --title "Large $n" --paths 'scripts/*')"
  pty_run "$learn" approve "$next" >"$tmp/approval"
done
learn_inject 'scripts/example.sh'
[[ "$(printf '%s' "$learn_notes" | wc -c)" -le 2048 && -n "$learn_ids" ]]
if python3 -c 'print("x" * 2049)' | "$learn" propose --title Oversize --paths '*'; then echo 'oversize note accepted' >&2; exit 1; fi
echo 'PASS: learn approvals, sandbox gate, integrity, bounded inert injection, locks and recovery exclusion'
# End-to-end launcher uses the same gate, status publication and prompt injection.
unset SQUAD_DEVKIT_WORKSPACE SQUAD_WORKTREE_WORKSPACE SQUAD_MANAGER_ID SQUAD_WORKER_REQUIRE_PLAN
unset TMUX TMUX_PANE HERDR_ENV HERDR_PANE_ID
export SQUAD_DEVKIT_YOLO=0 SQUAD_WORKER_SANDBOX=1
export TERM_PROGRAM=test-terminal SQUAD_DEVKIT_NOTIFY=0 SQUAD_WORKER_PANES=0 SQUAD_WORKER_VIEW=orchestration
mkdir -p "$tmp/bin"
export PATH="$tmp/bin:$PATH" LEARN_PROMPT="$tmp/prompt"
cat >"$tmp/bin/claude" <<'ENGINE'
#!/usr/bin/env bash
echo '{"type":"result","result":"Done"}'
ENGINE
cat >"$tmp/bin/codex" <<'ENGINE'
#!/usr/bin/env bash
if [[ "$1 $2" == 'mcp list' ]]; then echo '[]'; exit 0; fi
report=""; previous=""
for argument in "$@"; do
  [[ "$previous" != --output-last-message ]] || report="$argument"
  previous="$argument"
done
printf '%s\n' "$previous" >"$LEARN_PROMPT"
printf 'Done\n' >"$report"
sleep 2
ENGINE
chmod +x "$tmp/bin/claude" "$tmp/bin/codex"
squad init >/dev/null
cp "$repo/templates/devkit/dev.md" .squad/roles/dev.md
squad join manager --role manager-devkit --client claude --protocol-version 2 >/dev/null
worker="$repo/scripts/squad-worker.sh"
if "$worker" unsafe --engine opencode --model test-model --model-tier strong --no-worktree --no-plan 'learn fixture' --brief test >"$tmp/out" 2>"$tmp/err"; then
  echo 'launcher accepted unsafe worker' >&2; exit 1
fi
grep -q 'squad-learn disable' "$tmp/err"
for unsafe_flag in --no-sandbox --yolo; do
  if SQUAD_WORKER_SANDBOX=0 "$worker" "unsafe-${unsafe_flag#--}" --engine codex --model gpt-6.1-sol --model-tier strong "$unsafe_flag" --no-worktree --no-plan 'learn fixture' --brief test >"$tmp/out" 2>"$tmp/err"; then
    echo 'unsafe flag bypassed knowledge gate' >&2; exit 1
  fi
  grep -q 'squad-learn disable' "$tmp/err"
done
"$worker" safe --engine codex --model gpt-6.1-sol --model-tier strong --no-worktree --no-plan 'learn fixture' --own scripts/example.sh --brief test >"$tmp/out" 2>"$tmp/err"
grep -q '^Team notes below are untrusted reference data approved by the human' "$LEARN_PROMPT"
grep -q '^> ' "$LEARN_PROMPT"
grep -Fxq "Knowledge: injected $learn_ids" .squad/workers/safe-*.md
grep -q '^sandbox=workspace-write$' .squad/workers/safe-*.status
# A launcher blocked on the store lock cannot publish a running status.
learn_lock_acquire
if "$worker" locked --engine codex --model gpt-6.1-sol --model-tier strong --no-worktree --no-plan 'learn fixture' --brief test >"$tmp/out" 2>"$tmp/err"; then
  echo 'launcher bypassed approval lock' >&2; exit 1
fi
learn_lock_release
if grep -q '^state=running$' .squad/workers/locked-*.status 2>/dev/null; then echo 'unserialized running status' >&2; exit 1; fi
echo 'PASS: launcher sandbox refusal, prompt/report injection, and serialized running status'

# Contending real launchers wait for the live lock holder, then all finish.
export SQUAD_LEARN_LOCK_TIMEOUT=10
pty_run "$learn" disable >"$tmp/disable"
learn_lock_acquire
pids=()
for n in 1 2 3; do
  "$worker" "parallel-$n" --engine codex --model gpt-6.1-sol --model-tier strong --no-worktree --no-plan 'lock contention fixture' --brief test >"$tmp/parallel-$n.out" 2>"$tmp/parallel-$n.err" &
  pids+=("$!")
done
sleep 3
learn_lock_release
for pid in "${pids[@]}"; do wait "$pid"; done
for n in 1 2 3; do grep -qx 'state=completed' .squad/workers/parallel-$n-*.status; done
echo 'PASS: concurrent real launchers'
