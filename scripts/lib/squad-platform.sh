#!/usr/bin/env bash
# Shared platform probes for the Bash entry points.

squad_os_kind() {
  if [[ ${SQUAD_DEVKIT_OS_OVERRIDE+x} ]]; then
    printf '%s\n' "$SQUAD_DEVKIT_OS_OVERRIDE"
    return
  fi
  case "$(uname -s)" in
    Darwin) echo macos ;;
    Linux)
      if [[ -n "${WSL_DISTRO_NAME:-}${WSL_INTEROP:-}" ]] ||
        grep -qE '[Mm]icrosoft|[Ww][Ss][Ll]' /proc/version 2>/dev/null; then
        echo wsl
      else
        echo linux
      fi ;;
    MINGW*|MSYS*|CYGWIN*) echo windows ;;
    *) echo unknown ;;
  esac
}

squad_is_macos() { [[ "$(squad_os_kind)" == macos ]]; }
squad_is_linux() { [[ "$(squad_os_kind)" == linux ]]; }
squad_is_wsl() { [[ "$(squad_os_kind)" == wsl ]]; }
squad_is_windows() { [[ "$(squad_os_kind)" == windows ]]; }

squad_sha256_stdin() {
  local result
  if command -v sha256sum >/dev/null 2>&1; then
    result="$(sha256sum)" || return 1
  elif command -v shasum >/dev/null 2>&1; then
    result="$(shasum -a 256)" || return 1
  else
    result="$(python3 -c '
import hashlib, sys
digest = hashlib.sha256()
for block in iter(lambda: sys.stdin.buffer.read(65536), b""):
    digest.update(block)
print(digest.hexdigest())
')" || return 1
  fi
  result="${result%%[[:space:]]*}"
  [[ "$result" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s\n' "$result"
}

squad_sha256_file() { squad_sha256_stdin <"$1"; }

squad_file_mtime() {
  local value
  if { value="$(stat -c %Y -- "$1" 2>/dev/null)" && [[ "$value" =~ ^-?[0-9]+$ ]]; } ||
    { value="$(stat -f %m -- "$1" 2>/dev/null)" && [[ "$value" =~ ^-?[0-9]+$ ]]; }; then
    printf '%s\n' "$value"
  else
    return 1
  fi
}

squad_win_path() {
  case "$(squad_os_kind)" in
    windows) if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; return; fi ;;
    wsl) if command -v wslpath >/dev/null 2>&1; then wslpath -w "$1"; return; fi ;;
  esac
  printf '%s\n' "$1"
}

squad_find_git_bash() {
  local path
  if [[ -n "${SQUAD_DEVKIT_GIT_BASH:-}" ]]; then
    printf '%s\n' "$SQUAD_DEVKIT_GIT_BASH"
    return
  fi
  path="${BASH:-$(command -v bash 2>/dev/null || true)}"
  [[ -n "$path" ]] || return 1
  squad_win_path "$path"
}

squad_win_pid() {
  local pid="$1" path value
  if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && squad_is_windows; then
    path="${SQUAD_DEVKIT_PROC_DIR:-/proc}/$pid/winpid"
    if [[ -r "$path" ]] && value="$(cat "$path" 2>/dev/null)"; then
      value="${value%$'\r'}"
      if [[ "$value" =~ ^[[:space:]]*([0-9]+)[[:space:]]*$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
      fi
    fi
  fi
}

squad_wt_escape() {
  local value
  value="$(printf '%s' "$1" | LC_ALL=C tr -d '[:cntrl:]')"
  printf '%s\n' "${value//;/\\;}"
}

squad_find_wt() {
  local path
  if [[ -n "${SQUAD_DEVKIT_WT:-}" ]]; then command -v "$SQUAD_DEVKIT_WT"; return; fi
  command -v wt.exe || command -v wt || {
    squad_is_wsl || return 1
    for path in /mnt/c/Users/*/AppData/Local/Microsoft/WindowsApps/wt.exe; do
      if [[ -f "$path" && -r "$path" && -x "$path" ]]; then printf '%s\n' "$path"; return; fi
    done
    return 1
  }
}

squad_find_powershell() {
  local path=/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe
  if [[ -n "${SQUAD_DEVKIT_POWERSHELL:-}" ]]; then command -v "$SQUAD_DEVKIT_POWERSHELL"; return; fi
  command -v powershell.exe || command -v pwsh.exe || {
    squad_is_wsl && [[ -x "$path" ]] && printf '%s\n' "$path"
  }
}

squad_pid_alive() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]] && { kill -0 "$1" 2>/dev/null || [[ -d "/proc/$1" ]]; }
}

squad_monitor_pid_alive() {
  local pid="${1:-}" path value tasklist_cmd
  pid="${pid%$'\r'}"
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  squad_pid_alive "$pid" && return 0
  squad_is_windows || return 1
  for path in "${SQUAD_DEVKIT_PROC_DIR:-/proc}"/[0-9]*/winpid; do
    if [[ -r "$path" ]] && value="$(cat "$path" 2>/dev/null)" &&
      [[ "$value" =~ ^[[:space:]]*${pid}[[:space:]]*$ ]]; then
      return 0
    fi
  done
  tasklist_cmd="$(command -v "${SQUAD_DEVKIT_TASKLIST:-tasklist.exe}")" || return 1
  value="$(MSYS2_ARG_CONV_EXCL='*' "$tasklist_cmd" /FI "PID eq $pid" /FO CSV /NH)" || return 1
  [[ "$value" == *",\"$pid\","* ]]
}

# A failed probe cannot prove that a lock owner has gone away.
squad_pid_missing() {
  local pid="$1" table
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  if table="$(ps -axo pid= 2>/dev/null)"; then
    awk -v pid="$pid" '$1 == pid {found=1} END {exit found}' <<<"$table"
  elif squad_is_windows && table="$(ps -ef 2>/dev/null || ps -f 2>/dev/null)"; then
    awk -v pid="$pid" 'NR == 1 {for (i=1; i<=NF; i++) if ($i=="PID") p=i; next}
      p && $p == pid {found=1} END {exit (!p || found)}' <<<"$table"
  else
    return 1
  fi
}

squad_pid_command() {
  local pid="$1" value
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  if { value="$(ps -p "$pid" -o command= 2>/dev/null)" && [[ -n "$value" ]]; } ||
    { value="$(ps -p "$pid" -o args= 2>/dev/null)" && [[ -n "$value" ]]; }; then
    printf '%s\n' "$value"
  elif [[ -r "/proc/$pid/cmdline" ]]; then
    tr '\000' ' ' <"/proc/$pid/cmdline"
  else
    ps -p "$pid"
  fi
}

squad_pid_started() {
  LC_ALL=C ps -p "$1" -o lstart= 2>/dev/null | awk 'NF {$1=$1; print}'
}

squad_pid_children() {
  local pid="$1" table file parent result
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  if command -v pgrep >/dev/null 2>&1 && result="$(pgrep -P "$pid" 2>/dev/null)"; then
    printf '%s\n' "$result"
  elif table="$(ps -axo pid=,ppid= 2>/dev/null)"; then
    awk -v pid="$pid" '$2 == pid {print $1}' <<<"$table"
  else
    {
      for file in "${SQUAD_DEVKIT_PROC_DIR:-/proc}"/[0-9]*/ppid; do
        [[ -r "$file" ]] || continue
        if read -r parent <"$file" && [[ "$parent" == "$pid" ]]; then
          result="${file%/ppid}"; printf '%s\n' "${result##*/}"
        fi
      done
      if table="$(ps -ef 2>/dev/null || ps -f 2>/dev/null)"; then
        awk -v pid="$pid" 'NR == 1 {for (i=1; i<=NF; i++) {if ($i=="PID") p=i; if ($i=="PPID") pp=i}; next}
          p && pp && $pp==pid && $p ~ /^[1-9][0-9]*$/ {print $p}' <<<"$table"
      fi
    } | awk '!seen[$0]++'
  fi
}

squad_kill_children() {
  local pid="$1" sig="${2:-TERM}" child
  [[ "$pid" =~ ^[1-9][0-9]*$ && "$sig" =~ ^[A-Z0-9]+$ ]] || return 1
  if command -v pkill >/dev/null 2>&1 && pkill "-$sig" -P "$pid" 2>/dev/null; then return 0; fi
  while IFS= read -r child; do
    [[ "$child" =~ ^[1-9][0-9]*$ ]] || continue
    kill "-$sig" "$child" 2>/dev/null || true
  done < <(squad_pid_children "$pid")
}
