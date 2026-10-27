#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temp_directory="$(mktemp -d /tmp/squad-worker-test.XXXXXX)"
trap 'rm -rf "$temp_directory"' EXIT
project_directory="$temp_directory/project"
test_bin="$temp_directory/bin"
mkdir -p "$project_directory/src" "$test_bin" "$temp_directory/home"

cat >"$test_bin/codex" <<'EOF'
#!/usr/bin/env bash
if [[ "$1 $2" == 'mcp list' ]]; then
  printf '[\n  {\n    "name": "figma",\n    "enabled": true\n  },\n  {\n    "name": "sentry",\n    "enabled": true\n  }\n]\n'
  exit 0
fi
printf 'codex:%s\n' "${*//$'\n'/\\n}" >>"$WORKER_TEST_LOG"
if [[ -n "${FAKE_CODEX_FAIL:-}" ]]; then
  echo 'model error' >&2
  exit 3
fi
while (( $# > 0 )); do
  if [[ "$1" == --output-last-message ]]; then
    printf 'Fixed add(). Files: calc.py. Verification: ok.\n' >"$2"
  fi
  shift
done
EOF
cat >"$test_bin/ccr" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == activate ]]; then
  echo 'export ANTHROPIC_BASE_URL="http://127.0.0.1:3456"'
fi
EOF
cat >"$test_bin/claude" <<'EOF'
#!/usr/bin/env bash
printf 'claude:%s:%s\n' "$ANTHROPIC_BASE_URL" "${*//$'\n'/\\n}" >>"$WORKER_TEST_LOG"
echo 'Wrote README.md. Verification: re-read the file.'
EOF
cat >"$test_bin/curl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$test_bin"/*
export HOME="$temp_directory/home"
export PATH="$test_bin:$PATH"
export WORKER_TEST_LOG="$temp_directory/invocations"

cd "$project_directory"
squad init >/dev/null
cp "$repo_root/templates/devkit/dev.md" .squad/roles/dev.md
squad join manager --role manager-devkit --client claude --protocol-version 2 >/dev/null
worker="$repo_root/scripts/squad-worker.sh"

if "$worker" dev-1 --engine codex >/dev/null 2>"$temp_directory/error"; then
  echo 'Expected an empty brief to fail' >&2
  exit 1
fi
grep -q 'The brief is empty' "$temp_directory/error"

codex_output="$(cd src && printf 'Fix add() in calc.py\nFiles you own: calc.py\n' |
  "$worker" dev-1 --engine codex --mcp sentry --brief-file -)"
[[ "$codex_output" == '[dev-1 · codex · task '* ]]
[[ "$codex_output" == *'Fixed add(). Files: calc.py. Verification: ok.'* ]]
codex_call="$(grep '^codex:' "$WORKER_TEST_LOG")"
[[ "$codex_call" == *'exec --profile high --ephemeral --skip-git-repo-check --sandbox workspace-write'* ]]
[[ "$codex_call" == *'-c mcp_servers.figma.enabled=false'* ]]
[[ "$codex_call" != *'mcp_servers.sentry'* ]]
[[ "$codex_call" == *'You are dev-1, a dev worker in a squad led by manager.'* ]]
[[ "$codex_call" == *'Role: developer.'* && "$codex_call" != *'squad-devkit template'* ]]
[[ "$codex_call" == *'## Task '*': Fix add() in calc.py'* ]]
squad task list --status completed | grep -q 'assigned_to: dev-1'
[[ "$(squad agents)" != *'dev-1 '* ]]
ls .squad/workers/dev-1-*.md >/dev/null

ccr_output="$("$worker" doc-1 --engine ccr --role writer --title 'Write README' \
  --brief 'Create README.md. Files you own: README.md')"
[[ "$ccr_output" == '[doc-1 · ccr · task '*'Wrote README.md. Verification: re-read the file.'* ]]
ccr_call="$(grep '^claude:' "$WORKER_TEST_LOG")"
[[ "$ccr_call" == 'claude:http://127.0.0.1:3456:-p --strict-mcp-config --disable-slash-commands'* ]]
[[ "$ccr_call" == *'--tools Read,Edit,Write,Glob,Grep --allowedTools Read,Edit,Write,Glob,Grep --permission-mode acceptEdits'* ]]
[[ "$ccr_call" == *'## Task '*': Write README'* ]]
squad task list --status completed | grep -q 'assigned_to: doc-1'

status=0
FAKE_CODEX_FAIL=1 "$worker" dev-2 --engine codex --profile medium --brief 'Break things' \
  >/dev/null 2>"$temp_directory/error" || status=$?
[[ "$status" == 3 ]]
grep -q 'dev-2 (codex) failed on task .* with exit status 3' "$temp_directory/error"
grep -q -- '--profile medium' "$WORKER_TEST_LOG"
squad receive manager | grep -q 'dev-2 (codex) failed'
[[ "$(squad agents)" != *'dev-2 '* ]]
echo 'PASS: squad-worker codex/ccr runs, MCP filtering, task lifecycle, and failure reporting'
