#!/usr/bin/env bash
set -euo pipefail

trap 'echo "Failed at line $LINENO: $BASH_COMMAND" >&2' ERR

fail() {
  echo "Assertion failed at line ${BASH_LINENO[0]}: $*" >&2
  exit 1
}

passed=0
pass() {
  passed=$((passed + 1))
  printf 'ok %d - %s\n' "$passed" "$1"
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/squad-scout-smoke.XXXXXX")" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT

unset TMUX TMUX_PANE SQUAD_DEVKIT_GHOSTTY_TERMINAL SQUAD_MANAGER_ID SQUAD_DEVKIT_WORKSPACE \
  SQUAD_WORKTREE_WORKSPACE SQUAD_DEVKIT_BACKEND SQUAD_DEVKIT_MANAGER SQUAD_DEVKIT_WORKERS \
  SQUAD_DEVKIT_DISABLE_WORKERS SQUAD_DEVKIT_PROJECT_ROOT SQUAD_DEVKIT_ALLOW_HOME SQUAD_DEVKIT_TASK \
  SQUAD_DEVKIT_NO_PROMPT SQUAD_DEVKIT_YOLO SQUAD_WORKER_REQUIRE_PLAN SQUAD_WORKER_VIEW \
  SQUAD_WORKER_SCOUT_ENGINE SQUAD_WORKER_SCOUT_MODEL SQUAD_WORKER_SCOUT_TIMEOUT SQUAD_WORKER_TIMEOUT \
  SQUAD_WORKER_CLAUDE_MODEL SQUAD_WORKER_CLAUDE_MODEL_FAST SQUAD_WORKER_CODEX_MODEL \
  SQUAD_WORKER_CODEX_MODEL_FAST SQUAD_WORKER_OPENCODE_MODEL SQUAD_WORKER_OPENCODE_MODEL_FAST \
  SQUAD_WORKER_GROK_MODEL SQUAD_WORKER_GROK_MODEL_FAST SQUAD_WORKER_CLAUDE_TOOLS \
  HERDR_PANE_ID HERDR_ENV HERDR_SOCKET_PATH HC_TERMINAL_ID HC_TERMINAL_SOCKET HC_SCOPE \
  WEZTERM_PANE KITTY_WINDOW_ID ITERM_SESSION_ID ZELLIJ ZELLIJ_SESSION_NAME DISPLAY WAYLAND_DISPLAY

export HOME="$tmp/home"
export XDG_CONFIG_HOME="$HOME/.config"
export SQUAD_DEVKIT_CONFIG="$HOME/.config/squad-devkit/config"
export TERM_PROGRAM=test-terminal
export SQUAD_DEVKIT_NOTIFY=0
mkdir -p "$HOME/.config/squad-devkit" "$tmp/bin" "$tmp/ws"

# Fake engines and minimal tools so tests run offline with zero model calls.
export TEST_CALL_LOG="$tmp/calls.log"
cat >"$tmp/bin/claude" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == --version ]]; then echo 'claude 1.0.0'; exit 0; fi
printf 'claude:%s\n' "${*//$'\n'/\\n}" >>"$TEST_CALL_LOG"
printf '%s\n' '{"type":"assistant","message":{"model":"claude-haiku-fake","content":[]}}'
printf '%s\n' '{"type":"result","result":"Scout findings from claude."}'
EOF
cat >"$tmp/bin/codex" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == --version ]]; then echo 'codex 1.0.0'; exit 0; fi
if [[ "${1:-} ${2:-}" == 'mcp list' ]]; then echo '[]'; exit 0; fi
printf 'codex:%s\n' "${*//$'\n'/\\n}" >>"$TEST_CALL_LOG"
while (( $# > 0 )); do
  if [[ "$1" == --output-last-message ]]; then printf 'Scout findings from codex.\n' >"$2"; fi
  shift
done
EOF
cat >"$tmp/bin/opencode" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == --version ]]; then echo 'opencode 1.0.0'; exit 0; fi
printf 'opencode:%s\n' "${*//$'\n'/\\n}" >>"$TEST_CALL_LOG"
printf '%s\n' '{"type":"text","part":{"messageID":"m1","type":"text","text":"Scout findings from opencode."}}'
EOF
cat >"$tmp/bin/grok" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == --version ]]; then echo 'grok 1.0.0'; exit 0; fi
printf 'grok:%s\n' "${*//$'\n'/\\n}" >>"$TEST_CALL_LOG"
echo 'Scout findings from grok.'
EOF
cat >"$tmp/bin/ccr" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == --version ]]; then echo 'ccr 1.0.0'; exit 0; fi
if [[ "${1:-}" == activate ]]; then echo 'export CCR_ACTIVE=1'; exit 0; fi
EOF
cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$tmp/bin/herdr" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-} ${2:-}" == 'pane split' ]]; then
  printf '{"result":{"pane":{"pane_id":"w1:p2","focused":false}}}\n'
elif [[ "${1:-} ${2:-}" == 'pane run' ]]; then
  bash -c "$4" >/dev/null 2>&1 &
fi
EOF
chmod +x "$tmp/bin/"*

export PATH="$repo_root/target/debug:$tmp/bin:$PATH"
export HERDR_ENV=1 HERDR_PANE_ID=w1:pM SQUAD_WORKER_PANE_HOLD=0 SQUAD_WORKER_VIEW=panes

worker="$repo_root/scripts/squad-worker.sh"
devkit="$repo_root/scripts/squad-devkit.sh"

# Git repo fixture inside workspace.
repo="$tmp/ws/repo"
mkdir -p "$repo"
git -C "$repo" init -q -b main
echo 'fn main() {}' >"$repo/main.rs"
git -C "$repo" add -A
git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm init

cd "$repo"
squad init >/dev/null
cp "$repo_root/templates/devkit/"*.md .squad/roles/
squad join manager --role manager-devkit --client claude --protocol-version 2 >/dev/null
mkdir -p .squad/plans

cat >.squad/plans/bad.md <<'EOF'
# Broken Plan
## Triage
- Risk: low
EOF

cat >.squad/plans/high.md <<'EOF'
# High Risk Plan

## Triage
- Risk: high
- Complexity: high
- squad-route: not configured

## Goal
Change auth.

## Perspectives
- Principal engineer: a
- Engineering manager: b
- Technical lead: c
- QA/QC: d
- End user: e

## Tasks
- dev-1: update auth

## Acceptance
- Tests pass.
EOF

last_status() { ls -t .squad/workers/"$1"-*.status | head -n 1; }
status_get() { sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -n 1; }
expect_exit() {
  local want="$1" pattern="$2" status=0
  shift 2
  "$@" >"$tmp/out" 2>"$tmp/err" </dev/null || status=$?
  [[ "$status" == "$want" ]] || {
    echo "STDOUT:"; cat "$tmp/out"
    echo "STDERR:"; cat "$tmp/err"
    fail "$* exited $status, want $want"
  }
  grep -Eq -- "$pattern" "$tmp/err" || grep -Eq -- "$pattern" "$tmp/out" || {
    echo "STDOUT:"; cat "$tmp/out"
    echo "STDERR:"; cat "$tmp/err"
    fail "$*: missing '$pattern'"
  }
}

# --- 1. Pre-plan manager-context launch & non-scout plan gate ----------------
: >"$TEST_CALL_LOG"
SQUAD_MANAGER_ID=manager "$worker" scout-1 --role scout --brief 'Find auth files' >"$tmp/out" 2>"$tmp/err" </dev/null ||
  { cat "$tmp/err" >&2; fail "pre-plan scout failed"; }
st="$(last_status scout-1)"
[[ "$(status_get "$st" plan)" == none ]] || fail "expected plan=none"
[[ -z "$(status_get "$st" plan_override)" ]] || fail "expected empty plan_override"
[[ -z "$(status_get "$st" worktree)" && -z "$(status_get "$st" repository)" ]] || fail "scout must not use worktree"
grep -qx 'Plan: none (read-only scout)' "$tmp/out" || fail "missing read-only scout report header"
grep -qx 'Plan: none (read-only scout)' "$(status_get "$st" report)" || fail "missing read-only scout report file header"
pass 'pre-plan scout runs in manager context without --plan or worktree'

for non_scout in dev researcher reviewer; do
  expect_exit 2 'a plan is required in manager context' \
    env SQUAD_MANAGER_ID=manager "$worker" "req-$non_scout" --engine codex --role "$non_scout" --brief 'x'
done
pass 'non-scout roles still require --plan in manager context'

expect_exit 2 'is incomplete:' \
  env SQUAD_MANAGER_ID=manager "$worker" scout-bad-plan --role scout --plan .squad/plans/bad.md --brief 'x'
expect_exit 2 'high-risk plans require --model-tier strong' \
  env SQUAD_MANAGER_ID=manager "$worker" scout-high-plan --role scout --engine codex --plan .squad/plans/high.md --brief 'x'
pass 'explicit --plan on scout still validates plan and enforces high-risk tier floor'

# --- 2. Auto-selection priority order when --engine is omitted ----------------
# Priority A: explicit env SQUAD_WORKER_SCOUT_ENGINE + SQUAD_WORKER_SCOUT_MODEL
: >"$TEST_CALL_LOG"
SQUAD_MANAGER_ID=manager SQUAD_WORKER_SCOUT_ENGINE=opencode SQUAD_WORKER_SCOUT_MODEL=luna \
  "$worker" s-env --role scout --brief 'Locate routes' >"$tmp/out" </dev/null
st="$(last_status s-env)"
[[ "$(status_get "$st" engine)" == opencode ]] || fail "expected opencode from scout-env"
[[ "$(status_get "$st" model)" == luna ]] || fail "expected model=luna from scout-env"
[[ "$(status_get "$st" model_source)" == scout-env ]] || fail "expected model_source=scout-env"
call="$(grep '^opencode:' "$TEST_CALL_LOG" | tail -n 1)"
[[ "$call" == *'--agent plan'* && "$call" == *'--model luna'* ]] || fail "opencode missing --agent plan / --model luna: $call"
pass 'SQUAD_WORKER_SCOUT_ENGINE/MODEL selects opencode:luna with --agent plan and scout-env provenance'

# Priority B: saved config scout_engine + scout_model (including colons in model ID)
cat >"$SQUAD_DEVKIT_CONFIG" <<'CFG'
scout_engine=opencode
scout_model=openrouter:luna:free
CFG
: >"$TEST_CALL_LOG"
SQUAD_MANAGER_ID=manager "$worker" s-cfg --role scout --brief 'Locate models' >"$tmp/out" </dev/null
st="$(last_status s-cfg)"
[[ "$(status_get "$st" engine)" == opencode ]] || fail "expected opencode from scout-config"
[[ "$(status_get "$st" model)" == 'openrouter:luna:free' ]] || fail "colon model damaged: $(status_get "$st" model)"
[[ "$(status_get "$st" model_source)" == scout-config ]] || fail "expected model_source=scout-config"
call="$(grep '^opencode:' "$TEST_CALL_LOG" | tail -n 1)"
[[ "$call" == *'--model openrouter:luna:free'* && "$call" == *'--agent plan'* ]] || fail "opencode config call unexpected: $call"
rm -f "$SQUAD_DEVKIT_CONFIG"
pass 'config scout_engine/scout_model preserves colons and records scout-config provenance'

# Priority C: explicit (non-builtin) fast tier mapping wins over built-in claude haiku
: >"$TEST_CALL_LOG"
SQUAD_MANAGER_ID=manager SQUAD_WORKER_OPENCODE_MODEL_FAST=luna \
  "$worker" s-fast-env --role scout --brief 'Search handlers' >"$tmp/out" </dev/null
st="$(last_status s-fast-env)"
[[ "$(status_get "$st" engine)" == opencode ]] || fail "expected opencode fast env"
[[ "$(status_get "$st" model)" == luna ]] || fail "expected fast=luna"
[[ "$(status_get "$st" model_tier)" == fast ]] || fail "expected model_tier=fast"
[[ "$(status_get "$st" model_source)" == tier-environment ]] || fail "expected tier-environment"

cat >.squad/worker-models.json <<'JSON'
{"version":1,"engines":{"codex":{"fast":{"model":"gpt-5-mini-fast","effort":"low"}}}}
JSON
: >"$TEST_CALL_LOG"
SQUAD_MANAGER_ID=manager "$worker" s-fast-saved --role scout --brief 'Search handlers' >"$tmp/out" </dev/null
st="$(last_status s-fast-saved)"
[[ "$(status_get "$st" engine)" == codex ]] || fail "expected codex fast saved"
[[ "$(status_get "$st" model)" == gpt-5-mini-fast ]] || fail "expected gpt-5-mini-fast"
[[ "$(status_get "$st" model_tier)" == fast ]] || fail "expected model_tier=fast"
[[ "$(status_get "$st" model_source)" == saved ]] || fail "expected saved"
call="$(grep '^codex:' "$TEST_CALL_LOG" | tail -n 1)"
[[ "$call" == *'--sandbox read-only'* && "$call" == *'--model gpt-5-mini-fast'* && "$call" == *'model_reasoning_effort="low"'* ]] || fail "codex saved fast call unexpected: $call"
rm -f .squad/worker-models.json
pass 'explicit fast tier mappings (env and saved) win over built-in claude haiku'

# Priority D: configured ccr wins over built-in claude haiku when no explicit fast mapping exists
mkdir -p "$HOME/.claude-code-router"
echo '{"PORT":3456}' >"$HOME/.claude-code-router/config.json"
: >"$TEST_CALL_LOG"
SQUAD_MANAGER_ID=manager "$worker" s-ccr --role scout --brief 'Inspect router config' >"$tmp/out" </dev/null
st="$(last_status s-ccr)"
[[ "$(status_get "$st" engine)" == ccr ]] || fail "expected ccr when router config exists"
[[ "$(status_get "$st" model_source)" == router-default ]] || fail "expected router-default"
call="$(grep '^claude:' "$TEST_CALL_LOG" | tail -n 1)"
[[ "$call" == *'--tools Read,Glob,Grep'* && "$call" == *'--allowedTools Read,Glob,Grep'* ]] || fail "ccr scout call unexpected: $call"
rm -rf "$HOME/.claude-code-router"
pass 'configured ccr wins over built-in claude haiku when no explicit fast tier is set'

# Priority E: claude built-in fast (haiku) with Read,Glob,Grep only and no squad-ask in prompt
: >"$TEST_CALL_LOG"
SQUAD_MANAGER_ID=manager "$worker" s-claude --role scout --brief 'Find tests' >"$tmp/out" </dev/null
st="$(last_status s-claude)"
[[ "$(status_get "$st" engine)" == claude ]] || fail "expected claude built-in fallback"
[[ "$(status_get "$st" model)" == haiku ]] || fail "expected haiku"
[[ "$(status_get "$st" model_tier)" == fast ]] || fail "expected fast"
[[ "$(status_get "$st" model_source)" == builtin ]] || fail "expected builtin"
call="$(grep '^claude:' "$TEST_CALL_LOG" | tail -n 1)"
[[ "$call" == *'--tools Read,Glob,Grep --permission-mode'* ]] || fail "claude scout tools unexpected: $call"
tools_arg="$(printf '%s\n' "$call" | sed -n 's/.*--tools \([^ ]*\) .*/\1/p')"
[[ "$tools_arg" == Read,Glob,Grep ]] || fail "claude scout must only get Read,Glob,Grep, got: $tools_arg"
[[ "$call" != *squad-ask* ]] || fail "claude scout without Bash must not mention squad-ask"
pass 'claude built-in fast picks haiku with Read,Glob,Grep and no squad-ask'

# Priority F: codex fallback when claude and other preferred engines are disabled and unmapped
: >"$TEST_CALL_LOG"
SQUAD_MANAGER_ID=manager SQUAD_DEVKIT_WORKERS=codex "$worker" s-codex-fallback --role scout --brief 'Find structs' >"$tmp/out" </dev/null
st="$(last_status s-codex-fallback)"
[[ "$(status_get "$st" engine)" == codex ]] || fail "expected codex fallback"
[[ "$(status_get "$st" model_source)" == cli-default ]] || fail "expected cli-default"
call="$(grep '^codex:' "$TEST_CALL_LOG" | tail -n 1)"
[[ "$call" == *'--sandbox read-only'* ]] || fail "codex fallback missing --sandbox read-only: $call"
pass 'disabled claude falls back to codex cli-default with --sandbox read-only'

# --- 3. Explicit --engine override with --role scout --------------------------
cat >"$SQUAD_DEVKIT_CONFIG" <<'CFG'
scout_engine=opencode
scout_model=luna
CFG
: >"$TEST_CALL_LOG"
SQUAD_MANAGER_ID=manager "$worker" s-override-claude --role scout --engine claude --brief 'Check main' >"$tmp/out" </dev/null
st="$(last_status s-override-claude)"
[[ "$(status_get "$st" engine)" == claude ]] || fail "expected claude"
[[ "$(status_get "$st" model)" == haiku ]] || fail "expected haiku (no luna leak)"
[[ "$(status_get "$st" model_tier)" == fast ]] || fail "expected fast"
[[ "$(status_get "$st" model)" != luna ]] || fail "opencode scout_model leaked to claude"

# Explicit --engine codex uses saved fast+effort when present, else cli-default without error
cat >.squad/worker-models.json <<'JSON'
{"version":1,"engines":{"codex":{"fast":{"model":"codex-fast","effort":"minimal"}}}}
JSON
: >"$TEST_CALL_LOG"
SQUAD_MANAGER_ID=manager "$worker" s-override-codex-mapped --role scout --engine codex --brief 'Check main' >"$tmp/out" </dev/null
st="$(last_status s-override-codex-mapped)"
[[ "$(status_get "$st" model)" == codex-fast ]] || fail "expected codex-fast"
call="$(grep '^codex:' "$TEST_CALL_LOG" | tail -n 1)"
[[ "$call" == *'model_reasoning_effort="minimal"'* ]] || fail "expected effort=minimal: $call"
rm -f .squad/worker-models.json

: >"$TEST_CALL_LOG"
SQUAD_MANAGER_ID=manager "$worker" s-override-codex-unmapped --role scout --engine codex --brief 'Check main' >"$tmp/out" </dev/null
st="$(last_status s-override-codex-unmapped)"
[[ "$(status_get "$st" engine)" == codex ]] || fail "expected codex"
[[ "$(status_get "$st" model_source)" == cli-default ]] || fail "expected cli-default when codex fast unmapped"
rm -f "$SQUAD_DEVKIT_CONFIG"
pass 'explicit --engine on scout never leaks configured model from another engine and handles mapped/unmapped codex'

# --- 4. Validation, --scout, --doctor, --dry-run, and scout timeout -----------
expect_exit 2 'SQUAD_WORKER_SCOUT_MODEL requires SQUAD_WORKER_SCOUT_ENGINE' \
  env SQUAD_WORKER_SCOUT_MODEL=luna "$worker" bad-env --role scout --brief 'x'
expect_exit 2 'SQUAD_WORKER_SCOUT_MODEL requires SQUAD_WORKER_SCOUT_ENGINE' \
  env SQUAD_WORKER_SCOUT_MODEL=luna "$devkit" --dry-run

for bad_scout in 'ccr:luna' 'agy' 'bogus' 'claude:' 'opencode:-bad'; do
  expect_exit 2 'scout|Scout|agy' "$devkit" --scout "$bad_scout" --dry-run
done
expect_exit 2 'disabled by worker settings' "$devkit" --scout codex --workers claude --dry-run
pass 'validation rejects orphan scout model, invalid --scout specs, and disabled --scout engines'

cat >"$SQUAD_DEVKIT_CONFIG" <<'CFG'
scout_engine=opencode
scout_model=luna
CFG
dry_override="$("$devkit" "$repo" --scout claude --dry-run 2>"$tmp/err")"
grep -q 'Scout worker (read-only, no --plan needed): --role scout --engine claude --model-tier fast (haiku)' <<<"$dry_override" ||
  fail "missing claude scout guidance: $dry_override"
grep -q 'SQUAD_WORKER_SCOUT_ENGINE=claude' <<<"$dry_override" || fail "missing SQUAD_WORKER_SCOUT_ENGINE=claude"
grep -q 'SQUAD_WORKER_SCOUT_MODEL=' <<<"$dry_override" || fail "missing empty SQUAD_WORKER_SCOUT_MODEL="
if grep -q 'SQUAD_WORKER_SCOUT_MODEL=luna' <<<"$dry_override"; then fail "luna leaked into dry-run env override"; fi

cat >"$SQUAD_DEVKIT_CONFIG" <<'CFG'
scout_engine=opencode
CFG
dry_fallback="$("$devkit" "$repo" --workers claude --dry-run 2>"$tmp/err")"
grep -q "Note: ignoring unavailable/disabled scout_engine 'opencode' in config; auto-selecting scout engine." "$tmp/err" ||
  fail "missing config fallback note: $(cat "$tmp/err")"
grep -q 'Scout worker (read-only, no --plan needed): --role scout --engine claude --model-tier fast (haiku)' <<<"$dry_fallback" ||
  fail "missing fallback scout guidance: $dry_fallback"
rm -f "$SQUAD_DEVKIT_CONFIG"
pass 'squad-devkit --scout overrides config cleanly and unavailable config scout falls back with note'

doc_out="$("$devkit" --doctor)"
grep -q '  Default scout: claude (fast=haiku, source: auto-builtin)' <<<"$doc_out" ||
  fail "doctor missing Default scout line: $doc_out"
dry_default="$("$devkit" "$repo" --dry-run 2>/dev/null)"
grep -q 'Scout worker (read-only, no --plan needed): --role scout --engine claude --model-tier fast (haiku)' <<<"$dry_default" ||
  fail "dry-run missing Scout worker prompt line"
pass '--doctor and --dry-run surface the resolved scout worker'

# Scout timeout default (10m) and SQUAD_WORKER_SCOUT_TIMEOUT validation.
expect_exit 2 'at least 1' \
  env SQUAD_WORKER_SCOUT_TIMEOUT=0 SQUAD_MANAGER_ID=manager "$worker" s-to-bad --role scout --brief 'x'
SQUAD_WORKER_SCOUT_TIMEOUT=0 "$worker" dev-to-ok --engine codex --no-worktree --brief 'x' >"$tmp/out" </dev/null
pass 'SQUAD_WORKER_SCOUT_TIMEOUT applies only to scout runs'

printf 'PASS: %d scout checks passed\n' "$passed"
