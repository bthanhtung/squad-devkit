#!/usr/bin/env bash
set -euo pipefail
unset SQUAD_DEVKIT_WORKSPACE SQUAD_WORKTREE_WORKSPACE SQUAD_MANAGER_ID SQUAD_WORKER_REQUIRE_PLAN
unset TMUX TMUX_PANE HERDR_ENV HERDR_PANE_ID
repo="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d /tmp/squad-loop.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home" TERM_PROGRAM=test-terminal SQUAD_DEVKIT_NOTIFY=0
mkdir -p "$HOME" "$tmp/bin" "$tmp/ws"
export PATH="$repo/target/debug:$tmp/bin:$PATH"
cat >"$tmp/bin/claude" <<'ENGINE'
#!/usr/bin/env bash
[[ -z "${CHANGE_FILE:-}" ]] || echo changed > tracked.txt
echo '{"type":"result","result":"Done"}'
ENGINE
chmod +x "$tmp/bin/claude"
cd "$tmp/ws"
squad init >/dev/null
cp "$repo/templates/devkit/dev.md" .squad/roles/dev.md
squad join manager --role manager-devkit --client claude --protocol-version 2 >/dev/null
worker="$repo/scripts/squad-worker.sh"
run() { "$worker" "$@" --engine claude --model test-model --no-worktree --no-plan test --brief test >"$tmp/out" 2>"$tmp/err"; }
status() { ls -t .squad/workers/"$1"-*.status | head -n 1; }
run loop --loop 3 --gate "first=n=\$(cat '$tmp/ws/.loop-count' 2>/dev/null || echo 0); n=\$((n+1)); echo \$n > '$tmp/ws/.loop-count'; test \$n -ge 2" --gate "second=echo yes > '$tmp/ws/.loop-second'"
grep -qx 'loop_iter=2' "$(status loop)"
grep -qx 'gates=first:pass,second:pass' "$(status loop)"
[[ -f "$tmp/ws/.loop-second" ]]
run exhausted --loop 2 --gate 'bad=false' --gate "later=touch '$tmp/ws/.loop-never'"
grep -qx 'gates=bad:fail,later:skipped' "$(status exhausted)"
[[ ! -e "$tmp/ws/.loop-never" ]]
rm -f "$tmp/ws/.loop-count" "$tmp/ws/.loop-second"
export SQUAD_WORKER_CLAUDE_MODEL_BALANCED=balanced-test
"$worker" escalate --engine claude --model test-model --model-tier fast --no-worktree --no-plan test --brief test --loop 2 --retry-escalate --gate 'bad=false' >"$tmp/out" 2>"$tmp/err"
[[ $(find .squad/workers -name 'escalate-*.status' | wc -l | tr -d ' ') == 3 ]]
[[ $(grep -l '^loop_iter=' .squad/workers/escalate-*.status | wc -l | tr -d ' ') == 2 ]]
grep -qx 'model_tier=balanced' "$(status escalate)"
for id in loop exhausted escalate; do
  [[ $(squad history --from "$id" --to manager | grep -c "$id (claude) completed task") == 1 ]]
  tasks="$(squad task list --agent "$id")"
  if grep -qE "\] (queued|acked)$" <<<"$tasks"; then exit 1; fi
done
git init -q
git config user.email test@example.invalid
git config user.name test
echo initial > tracked.txt
git add tracked.txt
git commit -qm initial
CHANGE_FILE=1 "$worker" mergefail --engine claude --model test-model --worktree --no-plan test --brief test --gate 'bad=false' >"$tmp/out" 2>"$tmp/err"
grep -qx 'gates=bad:fail' "$(status mergefail)"
grep -qx 'verify=fail' "$(status mergefail)"
if "$worker" --merge mergefail >"$tmp/out" 2>"$tmp/err"; then exit 1; fi
grep -q 'verification failed or timed out' "$tmp/err"
run artifact --expect-file missing
grep -qx 'verify=fail' "$(status artifact)"
grep -qx 'expect_files=missing:missing' "$(status artifact)"
run legacy --verify true
grep -qx 'verify=pass' "$(status legacy)"
if run invalid --loop 6 --gate 'x=true'; then exit 1; fi
if run invalid --loop 2; then exit 1; fi
echo 'PASS: worker loop and gates'
