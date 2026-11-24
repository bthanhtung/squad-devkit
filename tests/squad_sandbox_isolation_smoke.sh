#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/work" "$tmp/runtime"
printf secret >"$tmp/secret"
ln -s "$tmp/secret" "$tmp/work/escape"
squad sandbox exec --worktree "$tmp/work" --run-tmp "$tmp/runtime" --profile strict -- /bin/sh -c 'echo ok >inside; echo ok >"$TMPDIR/inside"'
test -f "$tmp/work/inside"
test -f "$tmp/runtime/inside"
if squad sandbox exec --worktree "$tmp/work" --profile strict -- /bin/cat "$tmp/secret"; then
  echo 'FAIL strict outside read allowed' >&2; exit 1
fi
if squad sandbox exec --worktree "$tmp/work" --profile strict -- /bin/cat "$tmp/work/escape"; then
  echo 'FAIL strict symlink escape allowed' >&2; exit 1
fi
for profile in strict workspace; do
  if squad sandbox exec --worktree "$tmp/work" --profile "$profile" -- /bin/sh -c 'echo bad >"$1"' sh "$tmp/outside"; then
    echo "FAIL $profile outside write allowed" >&2; exit 1
  fi
  test ! -e "$tmp/outside"
done
if squad sandbox exec --worktree "$tmp/work" --profile strict --readonly -- /bin/sh -c 'echo bad >readonly'; then
  echo 'FAIL readonly write allowed' >&2; exit 1
fi
squad sandbox exec --worktree "$tmp/work" --profile off -- /bin/sh -c 'echo ok >"$1"' sh "$tmp/direct"
test -f "$tmp/direct"
if rg -- '--add-dir' "$repo/scripts/lib/engines/claude.sh" "$repo/scripts/lib/engines/codex.sh"; then
  echo 'FAIL parent add-dir remains' >&2; exit 1
fi
echo 'PASS sandbox isolation'
