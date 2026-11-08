#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
temp="$(mktemp -d /tmp/squad-orca-panes.XXXXXX)"
trap 'rm -rf "$temp"' EXIT
mkdir -p "$temp/state"
export FAKE_LOG="$temp/log"
cli="$temp/orca-fake"
cat >"$cli" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_LOG"
[[ -z "${FAKE_WARN:-}" ]] || echo CLI-warning >&2
case "$2" in
  show)
    if [[ "$4" == "${FAKE_BAD_SHOW:-}" ]]; then printf '{"ok":false,"error":{"code":"terminal_handle_stale","message":"stale"}}\n'; exit 1; fi
    if [[ "$4" == prev1 ]]; then printf '{"ok":true,"result":{"terminal":{%s"tabId":"tab1"}}}\n' "${FAKE_PREV_FLAGS-\"connected\":true,\"writable\":true,\"orphaned\":false,}"; exit 0; fi
    printf '{"ok":true,"result":{"terminal":{"connected":true,"writable":true,"orphaned":false,"tabId":"tab1"}}}\n' ;;
  split)
    case "${FAKE_SPLIT:-ok}" in
      ok) printf '{"ok":true,"result":{"split":{"handle":"term_new"}}}\n' ;;
      error) printf '{"ok":false,"error":{"code":"runtime_unavailable","message":"no renderer SECRET-LISTING"}}\n'; exit 1 ;;
      timeout)
        if [[ "$*" == *"--retry-split leaf9 "* ]]; then printf '{"ok":true,"result":{"split":{"handle":"term_replayed"}}}\n'; exit 0; fi
        printf '{"ok":false,"error":{"code":"timeout","message":"slow","data":{"leafId":"leaf9"}}}\n'; exit 1 ;;
      timeout_fail) printf '{"ok":false,"error":{"code":"timeout","message":"slow","data":{"leafId":"leaf9"}}}\n'; exit 1 ;;
      noleaf) printf '{"ok":false,"error":{"code":"timeout","message":"slow"}}\n'; exit 1 ;;
      nullleaf) printf '{"ok":false,"error":{"code":"timeout","data":{"leafId":null}}}\n'; exit 1 ;;
      unsafeleaf) printf '{"ok":false,"error":{"code":"timeout","data":{"leafId":"a b;x"}}}\n'; exit 1 ;;
      okfalse0) printf '{"ok":true,"error":{"code":"timeout","data":{"leafId":"leaf9"}}}\n'; exit 1 ;;
      malformed_fail) printf 'not json leaf9\n'; exit 1 ;;
      nohandle) printf '{"ok":true,"result":{"split":{}}}\n' ;;
      badjson) printf 'not json\n' ;;
      space) printf '{"ok":true,"result":{"split":{"handle":"a b"}}}\n' ;;
    esac ;;
esac
FAKE
chmod +x "$cli"
export ORCA_CLI_COMMAND="$cli" SQUAD_DEVKIT_ORCA_TERMINAL=mgr SQUAD_WORKER_PANES=1
unset TMUX TMUX_PANE
source "$repo/scripts/lib/squad-panes.sh"
fail() { echo "FAIL: $*" >&2; cat "$FAKE_LOG" >&2; exit 1; }
run() { : >"$FAKE_LOG"; rm -f "$temp/state"/.orca*; squad_open_monitor /bin/true t /ws "$temp/state" /bin/true required 2>&1; }

out="$(run)" || fail "success should pass"
[[ "$(grep -c ' split ' "$FAKE_LOG")" == 1 ]] || fail "one split"
grep -q 'terminal focus --terminal mgr' "$FAKE_LOG" || fail "manager refocus"
[[ "$(cat "$temp/state"/.orca-mgr.last)" == term_new ]] || fail "last handle"

# command error: stage and cause surfaced, one split, manager refocused, no listing leak beyond bounded cause
out="$(FAKE_SPLIT=error run)" && fail "split error should fail"
[[ "$out" == *"orca split (mgr, vertical) failed (exit 1): runtime_unavailable no renderer"* ]] || fail "split error cause: $out"
[[ "$(grep -c ' split ' "$FAKE_LOG")" == 1 ]] || fail "no duplicate after error"
grep -q 'terminal focus --terminal mgr' "$FAKE_LOG" || fail "refocus after error"

# timeout with leafId: exactly one fresh split, then one replay of the same args plus --retry-split
out="$(FAKE_SPLIT=timeout run)" || fail "timeout replay should succeed: $out"
[[ "$(grep -c ' split ' "$FAKE_LOG")" == 2 ]] || fail "one split + one replay"
first="$(grep ' split ' "$FAKE_LOG" | sed -n 1p)"; second="$(grep ' split ' "$FAKE_LOG" | sed -n 2p)"
[[ "$second" == "$first --retry-split leaf9 --json" || "${second% --json}" == "${first% --json} --retry-split leaf9" ]] || fail "replay args: $second"
[[ "$(cat "$temp/state"/.orca-mgr.last)" == term_replayed ]] || fail "replayed handle"
[[ "$(grep -n 'terminal focus' "$FAKE_LOG" | tail -1 | cut -d: -f1)" -gt "$(grep -n ' split ' "$FAKE_LOG" | tail -1 | cut -d: -f1)" ]] || fail "focus after replay"

# replay failure: stops after 2 splits, stage names the replay
out="$(FAKE_SPLIT=timeout_fail run)" && fail "replay failure should fail"
[[ "$out" == *"orca split replay (mgr, vertical) failed (exit 1): timeout slow leaf9"* ]] || fail "replay stage: $out"
[[ "$(grep -c ' split ' "$FAKE_LOG")" == 2 ]] || fail "no third split"
grep -q 'terminal focus --terminal mgr' "$FAKE_LOG" || fail "refocus after replay failure"

# no replay without a valid leafId / error envelope
for mode in noleaf nullleaf unsafeleaf okfalse0 malformed_fail; do
  out="$(FAKE_SPLIT=$mode run)" && fail "$mode should fail"
  [[ "$out" == *"orca split (mgr, vertical) failed"* ]] || fail "$mode stage: $out"
  [[ "$(grep -c ' split ' "$FAKE_LOG")" == 1 ]] || fail "replay after $mode"
done
FAKE_SPLIT=error run >/dev/null && fail "error"; [[ "$(grep -c ' split ' "$FAKE_LOG")" == 1 ]] || fail "replay after unrelated error"

# CLI stderr warnings must not break JSON parsing on success
out="$(FAKE_WARN=1 run)" || fail "warnings must not fail success: $out"
[[ "$(cat "$temp/state"/.orca-mgr.last)" == term_new ]] || fail "handle with warnings"
: >"$FAKE_LOG"; printf 'prev1\n' >"$temp/state/.orca-mgr.last"
FAKE_WARN=1 squad_open_monitor /bin/true t /ws "$temp/state" /bin/true required >/dev/null 2>&1 || fail "warning with previous show"
grep -q 'split --terminal prev1 --direction horizontal' "$FAKE_LOG" || fail "previous target with warnings"
# real failures still rejected with warnings present
FAKE_WARN=1 FAKE_SPLIT=error run >/dev/null && fail "failure with warnings"
FAKE_WARN=1 FAKE_BAD_SHOW=mgr run >/dev/null && fail "stale with warnings"

for mode in nohandle badjson space; do
  out="$(FAKE_SPLIT=$mode run)" && fail "$mode should fail"
  [[ "$out" == *"orca split (mgr, vertical) response failed"* ]] || fail "$mode stage: $out"
  [[ "$(grep -c ' split ' "$FAKE_LOG")" == 1 ]] || fail "no duplicate after $mode"
done

# stale manager: explicit failure, no split attempted
out="$(FAKE_BAD_SHOW=mgr run)" && fail "stale manager should fail"
[[ "$out" == *"orca manager show (mgr) failed (exit 1): terminal_handle_stale stale"* ]] || fail "stale: $out"
grep -q ' split ' "$FAKE_LOG" && fail "split despite stale manager"

# previous pane in same tab is reused (horizontal); workspace independent of worktree mode
: >"$FAKE_LOG"; printf 'prev1\n' >"$temp/state/.orca-mgr.last"
squad_open_monitor /bin/true t /elsewhere "$temp/state" /bin/true required >/dev/null || fail "prev split"
grep -q 'split --terminal prev1 --direction horizontal --command cd '"'"'/elsewhere'"'" "$FAKE_LOG" || fail "prev target/workspace"

# dead/unknown-liveness previous in the same tab: fall back to one manager vertical split, cache the new handle
for flags in '"connected":false,"writable":false,"orphaned":true,' '"connected":false,"writable":true,"orphaned":false,' \
  '"connected":true,"writable":false,"orphaned":false,' '"connected":true,"writable":true,"orphaned":true,' '' '"writable":true,"orphaned":false,' '"connected":true,"orphaned":false,'; do
  : >"$FAKE_LOG"; printf 'prev1\n' >"$temp/state/.orca-mgr.last"
  FAKE_PREV_FLAGS="$flags" squad_open_monitor /bin/true t /ws "$temp/state" /bin/true required >/dev/null 2>&1 || fail "fallback for [$flags]"
  [[ "$(grep -c ' split ' "$FAKE_LOG")" == 1 ]] || fail "one split for [$flags]"
  grep -q 'split --terminal mgr --direction vertical' "$FAKE_LOG" || fail "manager vertical for [$flags]"
  grep -q 'split --terminal prev1' "$FAKE_LOG" && fail "split on dead previous [$flags]"
  [[ "$(cat "$temp/state"/.orca-mgr.last)" == term_new ]] || fail "cache for [$flags]"
done
# absent orphaned with affirmative connected/writable still reuses the previous pane
: >"$FAKE_LOG"; printf 'prev1\n' >"$temp/state/.orca-mgr.last"
FAKE_PREV_FLAGS='"connected":true,"writable":true,' squad_open_monitor /bin/true t /ws "$temp/state" /bin/true required >/dev/null 2>&1 || fail "absent orphaned"
grep -q 'split --terminal prev1 --direction horizontal' "$FAKE_LOG" || fail "absent orphaned reuses previous"
echo "squad orca panes regression ok"
