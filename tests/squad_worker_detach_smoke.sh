#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
launcher_pid=''
worker_pid=''
cleanup() {
  [[ -z "$launcher_pid" ]] || kill -KILL -- "-$launcher_pid" 2>/dev/null || true
  [[ -z "$worker_pid" ]] || kill -KILL -- "-$worker_pid" 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT
trap 'echo "Failed at line $LINENO: $BASH_COMMAND" >&2' ERR
unset SQUAD_DEVKIT_WORKSPACE SQUAD_WORKTREE_WORKSPACE SQUAD_MANAGER_ID SQUAD_DEVKIT_YOLO
unset SQUAD_WORKER_DETACHED SQUAD_WORKER_CODEX_PROFILE
export SQUAD_WORKER_PANES=0 SQUAD_WORKER_DASHBOARD=0
mkdir -p "$tmp/bin" "$tmp/project/.squad"
cat >"$tmp/bin/squad" <<'FAKE'
#!/usr/bin/env bash
case "$1 $2" in
  'join '*) printf 'Joined as %s (role: dev)\n' "$2" ;;
  'task create') echo 'Created task task-1 for worker' ;;
esac
FAKE
cat >"$tmp/bin/codex" <<'FAKE'
#!/usr/bin/env bash
[[ "$1 $2" != 'mcp list' ]] || { echo '[]'; exit 0; }
: >"$TEST_READY"
sleep 5
while (( $# > 0 )); do
  if [[ "$1" == --output-last-message ]]; then
    printf 'Done. Verification: ok.\n' >"$2"
  fi
  shift
done
FAKE
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH"
cd "$tmp/project"
for mode in detached inherited; do
  export TEST_READY="$tmp/$mode.ready"
  if [[ "$mode" == inherited ]]; then export SQUAD_WORKER_DETACHED=1; fi
  # The launcher is a session leader; its background worker initially shares its group.
  perl -MPOSIX -e 'POSIX::setsid() >= 0 or die "setsid: $!"; exec @ARGV or die "exec: $!"' -- \
    bash -c '"$1" "$2" --engine codex --no-plan "detach smoke" --no-worktree --brief test >"$3/out" 2>&1 & echo $! >"$3/pid"; sleep 30' \
    launcher "$root/scripts/squad-worker.sh" "$mode" "$tmp" &
  launcher_pid=$!
  for ((i=0; i<100; i++)); do
    [[ ! -e "$TEST_READY" ]] || break
    sleep 0.1
  done
  [[ -e "$TEST_READY" ]] || { cat "$tmp/out" >&2; exit 1; }
  worker_pid="$(cat "$tmp/pid")"
  status_file=(.squad/workers/"$mode"-*.status)
  grep -qx "pid=$worker_pid" "${status_file[0]}"
  kill -KILL -- "-$launcher_pid"
  wait "$launcher_pid" 2>/dev/null || true
  launcher_pid=''
  if [[ "$mode" == inherited ]]; then
    # A killed orphan can briefly remain a zombie, so check liveness via ps too.
    for ((i=0; i<50; i++)); do
      state="$(ps -o stat= -p "$worker_pid" 2>/dev/null || true)"
      [[ -n "$state" && "$state" != *Z* ]] || break
      sleep 0.1
    done
    [[ -z "$state" || "$state" == *Z* ]] || { echo 'Negative control survived' >&2; exit 1; }
    if grep -qx 'state=completed' "${status_file[0]}"; then
      echo 'Negative control unexpectedly completed' >&2; exit 1
    fi
  else
    kill -0 "$worker_pid"
    for ((i=0; i<150; i++)); do
      grep -qx 'state=completed' "${status_file[0]}" && break
      sleep 0.1
    done
    grep -qx 'state=completed' "${status_file[0]}"
    grep -q 'Done. Verification: ok.' .squad/workers/"$mode"-*.md
  fi
  worker_pid=''
done
echo 'PASS: detached worker survives launcher group SIGKILL; negative control dies'
