#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$root/scripts/lib/squad-platform.sh"
fail() { echo "Platform smoke failed at line ${BASH_LINENO[0]}" >&2; exit 1; }
[[ "$(SQUAD_DEVKIT_OS_OVERRIDE=windows squad_os_kind)" == windows ]] || fail

tmp="$(mktemp -d)"
worker_pid=''
parent_pid=''
cleanup() {
  if [[ -n "$worker_pid" ]]; then kill -TERM "$worker_pid" 2>/dev/null || true; wait "$worker_pid" || true; fi
  if [[ -n "$parent_pid" ]]; then
    squad_kill_children "$parent_pid"
    kill -TERM "$parent_pid" 2>/dev/null || true
    wait "$parent_pid" || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT
trap 'echo "Failed at line $LINENO: $BASH_COMMAND" >&2' ERR
unset SQUAD_DEVKIT_OS_OVERRIDE WSL_DISTRO_NAME WSL_INTEROP SQUAD_DEVKIT_NOTIFY_BACKEND
unset SQUAD_DEVKIT_WORKSPACE SQUAD_WORKTREE_WORKSPACE SQUAD_DEVKIT_MANAGER_WRAPPER_PID SQUAD_DEVKIT_SESSION_START
unset SQUAD_AGENT_ID SQUAD_DEVKIT_YOLO SQUAD_WORKER_VIEW SQUAD_WORKER_REQUIRE_PLAN SQUAD_WORKER_CODEX_PROFILE
unset TMUX TMUX_PANE HC_TERMINAL_ID HERDR_ENV HERDR_PANE_ID ZELLIJ WEZTERM_PANE KITTY_WINDOW_ID ITERM_SESSION_ID
unset SQUAD_DEVKIT_ORCA_TERMINAL SQUAD_DEVKIT_GHOSTTY_TERMINAL ORCA_PANE_KEY ORCA_CLI_COMMAND
mkdir -p "$tmp/bin" "$tmp/hash" "$tmp/empty" "$tmp/state" "$tmp/home" "$tmp/project/.squad"
export HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/home/.config"
export SQUAD_DEVKIT_NOTIFY=1 TEST_CAPTURE="$tmp/captured" TEST_READY="$tmp/ready"
export TEST_EXECUTED="$tmp/unexpected"
export PATH="$tmp/bin:$PATH"

export SQUAD_DEVKIT_PROC_DIR="$tmp/proc"
mkdir -p "$SQUAD_DEVKIT_PROC_DIR/123"
printf ' 456 \r\n' >"$SQUAD_DEVKIT_PROC_DIR/123/winpid"
[[ "$(SQUAD_DEVKIT_OS_OVERRIDE=windows squad_win_pid 123)" == 456 ]] || fail
[[ -z "$(SQUAD_DEVKIT_OS_OVERRIDE=windows squad_win_pid 999)" ]] || fail
for os in linux macos; do
  [[ -z "$(SQUAD_DEVKIT_OS_OVERRIDE="$os" squad_win_pid 123)" ]] || fail
done

(
  export SQUAD_DEVKIT_OS_OVERRIDE=windows SQUAD_DEVKIT_TASKLIST="$tmp/bin/tasklist.exe"
  cat >"$SQUAD_DEVKIT_TASKLIST" <<'EOF'
#!/usr/bin/env bash
[[ "$MSYS2_ARG_CONV_EXCL" == '*' && "$1" == /FI && "$3" == /FO && "$4" == CSV && "$5" == /NH ]] || exit 1
case "$2" in
  'PID eq 987654321') printf '"python.exe","987654321","Console","1","24,000 K"\r\n' ;;
  *) printf '%s\r\n' 'INFO: No tasks are running which match the specified criteria.' ;;
esac
EOF
  chmod +x "$SQUAD_DEVKIT_TASKLIST"
  squad_monitor_pid_alive 456 || fail
  squad_monitor_pid_alive $'456\r' || fail
  squad_monitor_pid_alive 987654321 || fail
  if squad_monitor_pid_alive 987654322 || squad_monitor_pid_alive 0; then fail; fi
)

(
  uname() { printf '%s\n' "$kernel"; }
  grep() { [[ "${microsoft_kernel:-0}" == 1 ]]; }
  kernel=Darwin; [[ "$(squad_os_kind)" == macos ]] || fail
  for kernel in MINGW64_NT MSYS_NT CYGWIN_NT; do
    [[ "$(squad_os_kind)" == windows ]] || fail
  done
  kernel=Linux; [[ "$(squad_os_kind)" == linux ]] || fail
  [[ "$(WSL_INTEROP=present squad_os_kind)" == wsl ]] || fail
  [[ "$(WSL_DISTRO_NAME=Ubuntu squad_os_kind)" == wsl ]] || fail
  [[ "$(microsoft_kernel=1 squad_os_kind)" == wsl ]] || fail
  [[ "$(SQUAD_DEVKIT_OS_OVERRIDE=macos squad_os_kind)" == macos ]] || fail
  kernel=FreeBSD; [[ "$(squad_os_kind)" == unknown ]] || fail
)

printf abc >"$tmp/file ; with spaces"
digest=ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
empty_digest=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
if python3 -c 'import hashlib' >/dev/null 2>&1; then
  python_path="$(command -v python3)"
else
  python_path="$(command -v python)"
fi
hash_path="$(command -v sha256sum || command -v gsha256sum || true)"
if [[ -z "$hash_path" ]]; then
  # macOS may only ship shasum. Exercise the sha256sum interface in an isolated PATH.
  shasum_path="$(command -v shasum)"
  printf '#!/bin/bash\nexec %q -a 256\n' "$shasum_path" >"$tmp/hash/sha256sum"
else
  printf '#!/bin/bash\nexec %q\n' "$hash_path" >"$tmp/hash/sha256sum"
fi
printf '#!/bin/bash\nexec %q "$@"\n' "$python_path" >"$tmp/hash/python3"
chmod +x "$tmp/hash/"*
for backend in sha256sum python3; do
  [[ "$backend" != python3 ]] || rm "$tmp/hash/sha256sum"
  (
    PATH="$tmp/hash:$tmp/empty"
    ! command -v shasum || fail
    [[ "$(squad_sha256_stdin </dev/null)" == "$empty_digest" ]] || fail
    [[ "$(printf abc | squad_sha256_stdin)" == "$digest" ]] || fail
    [[ "$(squad_sha256_file "$tmp/file ; with spaces")" == "$digest" ]] || fail
  )
done
mtime="$(squad_file_mtime "$tmp/file ; with spaces")"
[[ "$mtime" =~ ^[0-9]+$ ]] || fail
if squad_file_mtime "$tmp/absent"; then fail; fi

source "$root/scripts/lib/squad-panes.sh"
source "$root/scripts/lib/squad-notify.sh"
cat >"$tmp/bin/wt-test" <<'FAKE'
#!/bin/bash
printf '%s\n' "$@" >"$TEST_CAPTURE"
if [[ "${TEST_CRLF_READY:-0}" == 1 ]]; then
  for arg; do
    arg="${arg#C:}"
    arg="${arg//\\//}"
    arg="${arg//\\;/;}"
    if [[ -f "$arg" ]]; then
      ready_export="$(sed -n '/^export SQUAD_WORKER_MONITOR_READY=/p' "$arg")"
      eval "$ready_export"
      printf '%s\r\n' "$TEST_MONITOR_PID" >"$SQUAD_WORKER_MONITOR_READY"
    fi
  done
fi
FAKE
cat >"$tmp/bin/cygpath" <<'FAKE'
#!/bin/bash
[[ "$1" == -w ]] && printf 'C:%s\n' "${2//\//\\}"
FAKE
cat >"$tmp/bin/powershell-test" <<'FAKE'
#!/bin/bash
[[ $# == 4 && "$1 $2 $3" == "-NoProfile -NonInteractive -Command" ]] || exit 1
printf '%s' "$4" >"$TEST_CAPTURE.command"
cat >"$TEST_CAPTURE"
FAKE
cat >"$tmp/bin/notify-send" <<'FAKE'
#!/bin/bash
printf '%s\n' "$@" >"$TEST_CAPTURE"
FAKE
cat >"$tmp/bin/powershell-fail" <<'FAKE'
#!/bin/bash
exit 1
FAKE
cat >"$tmp/bin/calc" <<'FAKE'
#!/bin/bash
: >"$TEST_EXECUTED"
FAKE
chmod +x "$tmp/bin/"*
export SQUAD_DEVKIT_WT="$tmp/bin/wt-test" SQUAD_DEVKIT_POWERSHELL="$tmp/bin/powershell-test"
export WT_SESSION=test-session SQUAD_WORKER_HEADLESS=0 SQUAD_WORKER_PANES=1 SQUAD_WORKER_DASHBOARD=1
title=$'work \t; monitor'
workspace='/workspace with spaces; project'
pane_script='/workspace with spaces; project/monitor ; command.sh'
escaped_title='work \; monitor'
escaped_script='/workspace with spaces\; project/monitor \; command.sh'
unset SQUAD_DEVKIT_GIT_BASH
long_body="$(printf '%0200d' 0)"
long_body="${long_body//0/a}"
for os in windows wsl; do
  export SQUAD_DEVKIT_OS_OVERRIDE="$os"
  unset WSL_DISTRO_NAME
  if [[ "$os" == wsl ]]; then
    export WSL_DISTRO_NAME=Smoke
    terminal_args=(--title "$escaped_title" -- wsl.exe -d Smoke --cd '/workspace with spaces\; project' -- bash "$escaped_script")
  else
    terminal_args=(-d 'C:\workspace with spaces\; project' --title "$escaped_title" -- "C:${BASH//\//\\}" "$escaped_script")
    SQUAD_DEVKIT_GIT_BASH='D:\Git; Tools\bin\bash.exe' squad_panes_wt "$WT_SESSION" '' "$pane_script" "$title" "$workspace" >/dev/null
    printf '%s\n' -w 0 split-pane -d 'C:\workspace with spaces\; project' --title "$escaped_title" -- \
      'D:\Git\; Tools\bin\bash.exe' "$escaped_script" | diff - "$TEST_CAPTURE"
  fi
  [[ "$(squad_panes_wt "$WT_SESSION" '' "$pane_script" "$title" "$workspace")" == wt-test-session ]] || fail
  printf '%s\n' -w 0 split-pane "${terminal_args[@]}" | diff - "$TEST_CAPTURE"
  squad_open_monitor "$pane_script" "$title" "$workspace" "$tmp/state" '' required
  printf '%s\n' -w 0 split-pane "${terminal_args[@]}" | diff - "$TEST_CAPTURE"
  dashboard_args=("${terminal_args[@]}")
  if [[ "$os" == wsl ]]; then dashboard_args[1]='squad workers'; else dashboard_args[3]='squad workers'; fi
  squad_panes_dashboard "$pane_script" "$tmp/state" "$workspace"
  printf '%s\n' -w 0 new-tab "${dashboard_args[@]}" | diff - "$TEST_CAPTURE"
  rm "$tmp/state"/.dashboard-*
  if [[ "$os" == wsl ]]; then
    unset WSL_DISTRO_NAME
    squad_panes_wt "$WT_SESSION" '' "$pane_script" "$title" "$workspace" >/dev/null
    printf '%s\n' -w 0 split-pane --title "$escaped_title" -- wsl.exe \
      --cd '/workspace with spaces\; project' -- bash "$escaped_script" | diff - "$TEST_CAPTURE"
  fi

  attack=$'$(calc) " \' <xml>& ; café'
  squad_notify "$attack" "body: $attack"
  "$python_path" -c '
import json, sys
from pathlib import Path
payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert payload == {"title": sys.argv[2], "body": "body: " + sys.argv[2]}
' "$TEST_CAPTURE" "$attack"
  grep -Fq '[Console]::In.ReadToEnd()' "$TEST_CAPTURE.command"
  grep -Fq '[System.Security.SecurityElement]::Escape($d.title)' "$TEST_CAPTURE.command"
  grep -Fq '[System.Security.SecurityElement]::Escape($d.body)' "$TEST_CAPTURE.command"
  grep -Fq 'catch { exit 1 }' "$TEST_CAPTURE.command"
  if grep -Fq -- "$attack" "$TEST_CAPTURE.command"; then fail; fi
  [[ ! -e "$TEST_EXECUTED" ]] || fail
  squad_notify title "${long_body}overflow"
  printf '{"title":"title","body":"%s"}\n' "$long_body" | diff - "$TEST_CAPTURE"
  if [[ "$os" == windows ]]; then
    LC_ALL=C squad_notify title "${long_body:0:199}"$'\t\303\251z'
    "$python_path" -c '
import json, sys
from pathlib import Path
payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert payload["body"] == "a" * 199 + "\u00e9"
' "$TEST_CAPTURE"
  fi
done
SQUAD_DEVKIT_OS_OVERRIDE=linux squad_notify title body
printf '%s\n' -- title body | diff - "$TEST_CAPTURE"

SQUAD_DEVKIT_OS_OVERRIDE=wsl SQUAD_DEVKIT_POWERSHELL="$tmp/bin/powershell-fail" \
  squad_notify 'WSL title' 'fallback body'
printf '%s\n' -- 'WSL title' 'fallback body' | diff - "$TEST_CAPTURE"
SQUAD_DEVKIT_OS_OVERRIDE=wsl SQUAD_DEVKIT_POWERSHELL="$tmp/bin/nonexistent-powershell.exe" \
  squad_notify 'WSL discovery title' 'discovery fallback body'
printf '%s\n' -- 'WSL discovery title' 'discovery fallback body' | diff - "$TEST_CAPTURE"

clean_workers="$tmp/clean/.squad/workers"
mkdir -p "$clean_workers"
printf 'state=running\r\npid=%s\r\n' "$$" >"$clean_workers/live.status"
touch "$clean_workers/live.log"
"$root/scripts/lib/squad-devkit-clean.sh" "$tmp/clean" --quiet --all
[[ -f "$clean_workers/live.status" && -f "$clean_workers/live.log" ]] || fail

# The process table can repeat a /proc child and contain additional children.
(
  export SQUAD_DEVKIT_PROC_DIR="$tmp/children-proc"
  mkdir -p "$SQUAD_DEVKIT_PROC_DIR/"{100,101}
  printf '99\n' >"$SQUAD_DEVKIT_PROC_DIR/100/ppid"
  printf '99\n' >"$SQUAD_DEVKIT_PROC_DIR/101/ppid"
  pgrep() { return 1; }
  ps() {
    [[ "$1" == -ef ]] || return 1
    printf 'PID PPID COMMAND\n101 99 sleep\n102 99 sleep\n'
  }
  [[ "$(squad_pid_children 99)" == $'100\n101\n102' ]] || fail
)
echo 'PASS: combined and deduplicated child PIDs'

unset SQUAD_DEVKIT_PROC_DIR
bash -c 'sleep 30 & echo "$!" >"$1"; wait "$!"' parent "$tmp/child" 2>/dev/null &
parent_pid=$!
for ((i=0; i<100; i++)); do [[ ! -s "$tmp/child" ]] || break; sleep 0.05; done
sleep_pid="$(cat "$tmp/child")"
squad_pid_alive "$sleep_pid" || fail
[[ "$(squad_pid_command "$sleep_pid")" == *sleep* ]] || fail
children="$(squad_pid_children "$parent_pid")"
grep -qx "$sleep_pid" <<<"$children"
(
  # Git Bash ps rejects POSIX -o fields and prints its own full-table headers.
  pgrep() { return 1; }
  pkill() { return 1; }
  ps() {
    case "$1" in
      -axo) return 1 ;;
      -ef) printf 'PID PPID PGID WINPID TTY UID STIME COMMAND\n%s %s 1 1 ? 1 00:00 sleep\n' "$sleep_pid" "$parent_pid" ;;
      *) return 1 ;;
    esac
  }
  children="$(squad_pid_children "$parent_pid")"
  grep -qx "$sleep_pid" <<<"$children"
  if SQUAD_DEVKIT_OS_OVERRIDE=windows squad_pid_missing "$sleep_pid"; then fail; fi
  SQUAD_DEVKIT_OS_OVERRIDE=windows squad_pid_missing 99999999 || fail
  squad_kill_children "$parent_pid"
)
for ((i=0; i<100; i++)); do
  squad_pid_alive "$sleep_pid" || break
  sleep 0.05
done
if squad_pid_alive "$sleep_pid"; then fail; fi
wait "$parent_pid" 2>/dev/null || true
parent_pid=''

cat >"$tmp/bin/squad" <<'FAKE'
#!/bin/bash
case "${1:-} ${2:-}" in
  'join '*) printf 'Joined as %s (role: dev)\n' "$2" ;;
  'task create') echo 'Created task task-1 for worker' ;;
esac
FAKE
cat >"$tmp/bin/codex" <<'FAKE'
#!/bin/bash
[[ "${1:-} ${2:-}" != 'mcp list' ]] || { echo '[]'; exit 0; }
if [[ "${TEST_SLOW:-0}" == 1 ]]; then
  : >"$TEST_READY"
  exec sleep 30
fi
while (( $# )); do
  if [[ "$1" == --output-last-message ]]; then
    printf 'Done. Verification: ok.\n' >"$2"
    exit 0
  fi
  shift
done
FAKE
TEST_REAL_PS="$(command -v ps)"
export TEST_REAL_PS
cat >"$tmp/bin/ps" <<'FAKE'
#!/bin/bash
for arg; do
  case "$arg" in -axo|-o) exit 1 ;; esac
done
exec "$TEST_REAL_PS" "$@"
FAKE
chmod +x "$tmp/bin/squad" "$tmp/bin/codex" "$tmp/bin/ps"
export SQUAD_WORKER_HEADLESS=1 SQUAD_WORKER_PANES=0 SQUAD_DEVKIT_NOTIFY=0 SQUAD_WORKER_DETACHED=1
export SQUAD_DEVKIT_OS_OVERRIDE=windows SQUAD_RUST_DISABLE=1
cd "$tmp/project"
worker="$root/scripts/squad-worker.sh"
args=(--manager manager --engine codex --no-plan 'platform smoke' --no-worktree --brief 'platform smoke')
TEST_CRLF_READY=1 TEST_MONITOR_PID=$$ SQUAD_WORKER_HEADLESS=0 SQUAD_WORKER_PANES=1 SQUAD_WORKER_VIEW=orchestration \
  "$worker" crlf "${args[@]}" >"$tmp/crlf.log" 2>&1 || { cat "$tmp/crlf.log" >&2; fail; }
marker="$(find .squad/workers -name '.orchestration-*.pid' -print -quit)"
[[ -n "$marker" ]] || { cat "$tmp/crlf.log" >&2; fail; }
IFS= read -r monitor_pid <"$marker"
[[ "$monitor_pid" =~ ^[1-9][0-9]*$ ]] || fail
TEST_SLOW=1 "$worker" lifecycle "${args[@]}" >"$tmp/worker.log" 2>&1 &
worker_pid=$!
for ((i=0; i<200; i++)); do
  [[ ! -e "$TEST_READY" ]] || break
  squad_pid_alive "$worker_pid" || break
  sleep 0.05
done
[[ -e "$TEST_READY" ]] || { cat "$tmp/worker.log" >&2; fail; }
"$worker" --list >"$tmp/list"
grep -q '^lifecycle ' "$tmp/list"
"$worker" --stop lifecycle >"$tmp/stop"
grep -q '^Stopping lifecycle ' "$tmp/stop"
if wait "$worker_pid"; then fail; fi
worker_pid=''
grep -qx 'state=stopped' .squad/workers/lifecycle-*.status
"$worker" --list >"$tmp/list"
grep -qx 'No running workers.' "$tmp/list"

for os in macos linux wsl windows; do
  SQUAD_DEVKIT_OS_OVERRIDE="$os" "$root/scripts/squad-devkit.sh" --doctor --manager codex >"$tmp/doctor" 2>&1 || true
  grep -qx "OS kind: $os" "$tmp/doctor"
  case "$os" in
    linux|wsl)
      grep -q '  notify-send: ' "$tmp/doctor"
      ;;
  esac
  case "$os" in
    wsl|windows)
      grep -q '  Windows Terminal (wt.exe): .*wt-test' "$tmp/doctor"
      grep -q '  PowerShell toast backend: .*powershell-test' "$tmp/doctor"
      ;;
  esac
done
echo 'PASS: cross-platform Bash runtime'
