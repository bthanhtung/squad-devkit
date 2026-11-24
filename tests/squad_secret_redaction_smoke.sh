#!/usr/bin/env bash
set -euo pipefail
actual="$(printf 'Authorization: Bearer fixture-secret-value\nOPENAI_API_KEY=sk-fixture-12345678901234567890\nplain text\n' | squad redact)"
[[ "$actual" == *'plain text'* && "$actual" != *fixture-secret-value* && "$actual" != *sk-fixture* ]]
actual="$(printf 'value=fixture-env-secret\n' | OPENAI_API_KEY=fixture-env-secret squad redact)"
[[ "$actual" == *'[REDACTED]'* && "$actual" != *fixture-env-secret* ]]
actual="$(printf '2026-11-24 API_KEY=fixture-credential-value\npassword=fixture-one Authorization: Bearer tok123\nAPI_KEY=first PASSWORD=second\n' | squad redact)"
[[ "$actual" == '2026-11-24 API_KEY=[REDACTED]
password=[REDACTED] Authorization: Bearer [REDACTED]
API_KEY=[REDACTED] PASSWORD=[REDACTED]' ]]

unset SQUAD_DEVKIT_WORKSPACE SQUAD_WORKTREE_WORKSPACE SQUAD_MANAGER_ID SQUAD_WORKER_REQUIRE_PLAN
unset TMUX TMUX_PANE HERDR_ENV HERDR_PANE_ID
repo="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d /tmp/squad-redaction.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home" TERM_PROGRAM=test-terminal SQUAD_DEVKIT_NOTIFY=0
mkdir -p "$HOME" "$tmp/bin" "$tmp/ws"
export PATH="$repo/target/debug:$tmp/bin:$PATH" REDACTION_PROMPTS="$tmp/prompts"
cat >"$tmp/bin/claude" <<'ENGINE'
#!/usr/bin/env bash
printf '%s\n' "${@: -1}" >>"$REDACTION_PROMPTS"
echo '{"type":"result","result":"Done"}'
ENGINE
chmod +x "$tmp/bin/claude"
cd "$tmp/ws"
squad init >/dev/null
cp "$repo/templates/devkit/dev.md" .squad/roles/dev.md
squad join manager --role manager-devkit --client claude --protocol-version 2 >/dev/null
"$repo/scripts/squad-worker.sh" redaction --engine claude --model test-model --no-worktree --no-plan test --brief test --loop 2 --gate 'leak=printf "API_KEY=fixture-leak\n"; false' >"$tmp/out" 2>"$tmp/err"
grep -q 'Previous loop failure' "$REDACTION_PROMPTS"
grep -q 'API_KEY=\[REDACTED\]' "$REDACTION_PROMPTS"
! grep -q 'fixture-leak' "$REDACTION_PROMPTS"
echo 'squad_secret_redaction_smoke: ok'
