#!/usr/bin/env bash
set -euo pipefail
unset SQUAD_DEVKIT_WORKSPACE SQUAD_WORKTREE_WORKSPACE SQUAD_MANAGER_ID SQUAD_WORKER_REQUIRE_PLAN
unset TMUX TMUX_PANE HERDR_ENV HERDR_PANE_ID SQUAD_LOOP_ITER SQUAD_LOOP_FAILURE_SIGNATURE
repo="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d /tmp/squad-transactional.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home" TERM_PROGRAM=test-terminal SQUAD_DEVKIT_NOTIFY=0
export PATH="$repo/target/debug:$tmp/bin:$PATH"
mkdir -p "$HOME" "$tmp/bin" "$tmp/ws"
cat >"$tmp/bin/claude" <<'ENGINE'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$PROMPT_LOG"
echo '{"type":"result","result":"Done"}'
ENGINE
chmod +x "$tmp/bin/claude"
export PROMPT_LOG="$tmp/prompts"
cd "$tmp/ws"
squad init >/dev/null
cp "$repo/templates/devkit/dev.md" .squad/roles/dev.md
squad join manager --role manager-devkit --client claude --protocol-version 2 >/dev/null
worker="$repo/scripts/squad-worker.sh"
if "$worker" repeated --engine claude --model test-model --no-worktree --no-plan test --brief test --loop 5 --headless \
  --gate 'bad=echo "error: deterministic failure"; exit 7' >"$tmp/out" 2>"$tmp/err"; then exit 1; else [[ $? == 1 ]]; fi
latest="$(ls -t .squad/workers/repeated-*.status | head -n 1)"
grep -qx "state=failed" "$latest"
grep -qx "exit=1" "$latest"
grep -q '"event":"failed"' "${latest%.status}.events.jsonl"
squad history --from repeated --to manager > "$tmp/history"
grep -q "identical failure signature repeated" "$tmp/history"
grep -q 'identical failure signature repeated; stopping loop early' "$tmp/err"
[[ $(find .squad/workers -name 'repeated-*.status' | wc -l | tr -d ' ') == 2 ]]
grep -q '^## Previous loop failure$' "$PROMPT_LOG"
grep -q '^Gate: bad$' "$PROMPT_LOG"
grep -q '^Exit code: 7$' "$PROMPT_LOG"
grep -q '^Diff stat:$' "$PROMPT_LOG"
grep -q 'error: deterministic failure' "$PROMPT_LOG"
# Exercise the shell bridge and the disabled-Rust fallback against an actual patch.
git init -q
git config user.name test
git config user.email test@example.invalid
echo base > file
git add file
git commit -qm base
echo worker > file
git diff --binary > "$tmp/change.patch"
git checkout -- file
# shellcheck source=scripts/lib/squad-worktree.sh
source "$repo/scripts/lib/squad-worktree.sh"
mkdir -p .squad
printf "version = 1\n[gates]\npost_merge = ['touch leaked; exit 5']\n" > .squad/harness.toml
if worktree_apply "$PWD" "$tmp/change.patch" > "$tmp/merge-out"; then exit 1; fi
grep -q '^merge_state=rolled_back_verify_fail$' "$tmp/merge-out"
grep -qx base file
[[ ! -e leaked ]]
SQUAD_RUST_DISABLE=1 worktree_apply "$PWD" "$tmp/change.patch" > "$tmp/merge-out"
grep -qx worker file
export SQUAD_WORKTREE_WORKSPACE="$(pwd -P)"
merge_tree="$(worktree_create "$(pwd -P)" invalid-harness)"
echo changed > "$merge_tree/file"
printf 'invalid' > .squad/harness.toml
if "$worker" --merge invalid-harness > "$tmp/invalid-out" 2> "$tmp/invalid-err"; then exit 1; fi
if grep -q 'resolve the markers' "$tmp/invalid-err"; then exit 1; fi
grep -q 'merge failed or aborted cleanly; working tree unchanged' "$tmp/invalid-err"
grep -qx worker file
[[ -d "$merge_tree" ]]
echo 'PASS: transactional merge bridge and structured loop early stop'
