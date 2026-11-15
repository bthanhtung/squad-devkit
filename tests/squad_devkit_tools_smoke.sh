#!/usr/bin/env bash
set -euo pipefail
fail() { echo "Assertion failed at line ${BASH_LINENO[0]}" >&2; exit 1; }
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/project/.squad/workers"
export PATH="$tmp/bin:$PATH" TEST_ARGS="$tmp/args"
cat >"$tmp/bin/uname" <<'FAKE'
#!/usr/bin/env bash
echo "${TEST_OS:-Linux}"
FAKE
cat >"$tmp/bin/osascript" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$TEST_ARGS"
cat >/dev/null
exit "${TEST_FAIL:-0}"
FAKE
cp "$tmp/bin/osascript" "$tmp/bin/notify-send"
chmod +x "$tmp/bin/"*
source "$root/scripts/lib/squad-notify.sh"
body="$(printf '%s\n%s' "\"'\\\$(touch INJECTED)" "$(printf '%0200d' 0)")"
cd "$tmp/project"
for os in Darwin Linux; do
  export TEST_OS="$os"
  squad_notify title "$body"
  [[ ! -e INJECTED ]] || fail
  [[ "$(tail -n 1 "$TEST_ARGS" | wc -c | tr -d ' ')" == 201 ]] || fail
  grep -Fq '$(touch INJECTED)' "$TEST_ARGS" || fail
  rm "$TEST_ARGS"
  SQUAD_DEVKIT_NOTIFY=0 squad_notify title body
  [[ ! -e "$TEST_ARGS" ]] || fail
  TEST_FAIL=1 squad_notify title body || fail
done
now=$(date +%s)
cat >.squad/workers/a.status <<EOF2
worker=a
engine=codex
model_tier=balanced
attempt=1
state=completed
verify=pass
started=$now
finished=$((now+10))
tokens_in=100
tokens_cached=20
tokens_out=30
EOF2
cat >.squad/workers/b.status <<EOF2
worker=a
engine=codex
model_tier=balanced
attempt=2
state=completed
started=$now
finished=$((now+20))
tokens_in=50
tokens_out=10
EOF2
cat >.squad/workers/c.status <<EOF2
worker=c
engine=claude
attempt=1
state=failed
verify=fail
started=$now
finished=$((now+4))
tokens_in=40
tokens_cached=10
tokens_out=5
EOF2
cat >.squad/workers/d.status <<EOF2
worker=d
engine=opencode
model_tier=fast
attempt=2
state=completed
started=$now
finished=$((now+2))
EOF2
out="$($root/scripts/squad-devkit.sh --stats)"
awk '$1=="codex" && $2=="balanced" { found=($3==2 && $4=="100.0%" && $5=="2.00" && $6==170 && $7=="15.0s") } END { exit !found }' <<<"$out" || fail
awk '$1=="claude" && $2=="-" { found=($3==1 && $4=="0.0%" && $5=="1.00" && $6==35 && $7=="4.0s") } END { exit !found }' <<<"$out" || fail
awk '$1=="opencode" && $2=="fast" { found=($4=="-") } END { exit !found }' <<<"$out" || fail
[[ "$(printf '%s\n' "$out" | awk 'NR>1 {print $1, $2}')" == "$(printf '%s\n' "$out" | awk 'NR>1 {print $1, $2}' | sort)" ]] || fail
mkdir -p nested/child
out="$(cd nested/child && "$root/scripts/squad-devkit.sh" --stats)"
awk '$1=="codex" && $2=="balanced" { found=1 } END { exit !found }' <<<"$out" || fail
mkdir -p "$tmp/empty"
SQUAD_DEVKIT_PROJECT_ROOT="$tmp/empty" "$root/scripts/squad-devkit.sh" --stats | grep -qx 'no runs' || fail
sed "s/started=$now/started=1/" .squad/workers/c.status >.squad/workers/old.status
out="$($root/scripts/squad-devkit.sh --stats --days 1)"
awk '$1=="claude" && $2=="-" && $3==1 { found=1 } END { exit !found }' <<<"$out" || fail
rm .squad/workers/*.status
[[ "$($root/scripts/squad-devkit.sh --stats)" == 'no runs' ]] || fail
cat >"$tmp/bin/tmux" <<'FAKE'
#!/usr/bin/env bash
if [[ "$1" == split-window ]]; then
  echo called >>"$TEST_ARGS"
  [[ "${TEST_FAIL:-0}" == 0 ]] || exit 1
  echo %42
fi
FAKE
chmod +x "$tmp/bin/tmux"
rm -f "$TEST_ARGS"
export TMUX=fake TMUX_PANE=%1
"$root/scripts/squad-devkit.sh" --doctor >"$tmp/doctor" 2>&1 || true
[[ ! -e "$TEST_ARGS" ]] || fail
"$root/scripts/squad-devkit.sh" --doctor --split-test >"$tmp/doctor" 2>&1 || true
grep -q 'split test opened' "$tmp/doctor" || fail
if TEST_FAIL=1 "$root/scripts/squad-devkit.sh" --doctor --split-test >"$tmp/doctor" 2>&1; then fail; fi
grep -q 'tmux split failed' "$tmp/doctor" || fail
echo 'devkit tools smoke passed'
