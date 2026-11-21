#!/usr/bin/env bash
set -euo pipefail
unset SQUAD_DEVKIT_WORKSPACE SQUAD_WORKTREE_WORKSPACE SQUAD_MANAGER_ID SQUAD_WORKER_REQUIRE_PLAN
unset TMUX TMUX_PANE HERDR_ENV HERDR_PANE_ID
repo="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d /tmp/squad-cost.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home" TERM_PROGRAM=test-terminal SQUAD_DEVKIT_NOTIFY=0
mkdir -p "$HOME" "$tmp/bin" "$tmp/ws"
export PATH="$repo/target/debug:$tmp/bin:$PATH"
cat >"$tmp/bin/claude" <<'ENGINE'
#!/usr/bin/env bash
if [[ -n "${FAKE_EVENT:-}" ]]; then
  printf '%s\n' "$FAKE_EVENT"
  if [[ "$FAKE_EVENT" != *'"type":"result"'* ]]; then echo '{"type":"result","result":"Done"}'; fi
else
echo '{"type":"result","usage":{"input_tokens":1000,"cache_read_input_tokens":500,"output_tokens":200},"result":"Done"}'
fi
ENGINE
chmod +x "$tmp/bin/claude"
cd "$tmp/ws"
squad init >/dev/null
cp "$repo/templates/devkit/dev.md" .squad/roles/dev.md
squad join manager --role manager-devkit --client claude --protocol-version 2 >/dev/null
worker="$repo/scripts/squad-worker.sh"
run() { "$worker" "$1" --engine claude --model test-model --no-worktree --no-plan test --brief test >"$tmp/out" 2>"$tmp/err"; }
status() { ls -t .squad/workers/"$1"-*.status | head -n 1; }
run unknown
grep -qx 'cost_status=unknown' "$(status unknown)"
printf '%s\n' '{"models":{"test-model":{"input":2,"cached_input":1,"output":10}}}' >.squad/prices.json
run estimated
grep -qx 'cost_status=estimated' "$(status estimated)"
grep -qx 'cost_usd=0.0045' "$(status estimated)"
FAKE_EVENT='{"type":"result","usage":{"input_tokens":1000,"output_tokens":200},"total_cost_usd":0.12345,"result":"Done"}' run reported
grep -qx 'cost_status=reported' "$(status reported)"
grep -qx 'cost_usd=0.1235' "$(status reported)"
printf '{' >.squad/prices.json
run invalid
grep -qx 'cost_status=unknown' "$(status invalid)"
grep -q 'invalid prices file' "$tmp/err"
"$repo/scripts/squad-devkit.sh" --stats >"$tmp/stats"
grep -Fq '$0.1280 (+2 unknown)' "$tmp/stats"
FAKE_EVENT='{"type":"turn.completed","usage":{"input_tokens":1000,"output_tokens":200,"reasoning_output_tokens":75}}' run codex-usage
grep -qx 'tokens_reasoning=75' "$(status codex-usage)"
echo 'PASS: cost accounting and stats'
