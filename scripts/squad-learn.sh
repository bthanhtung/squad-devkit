#!/usr/bin/env bash
# Shared functions are also used by squad-worker; sourcing never executes the CLI.
learn_hash() { shasum -a 256 | awk '{print $1}'; }
learn_get() { sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -n 1; }
learn_id() { [[ "$1" =~ ^[a-z0-9][a-z0-9-]*$ ]]; }
learn_init() {
  local root="$1" common config
  root="$(cd "$root" && pwd -P)" || return 1
  common="$(git -C "$root" rev-parse --git-common-dir 2>/dev/null || true)"
  if [[ -n "$common" ]]; then
    [[ "$common" == /* ]] || common="$root/$common"
    root="$(cd "$common/.." && pwd -P)" || return 1
  fi
  learn_root="$root"
  config="${SQUAD_DEVKIT_CONFIG:-$HOME/.config/squad-devkit}"
  mkdir -p "$config/knowledge" || return 1
  config="$(cd "$config/knowledge" && pwd -P)"
  case "$config/" in "$root/"*) echo 'Knowledge store must be outside the project and worktrees' >&2; return 1 ;; esac
  learn_base="$config/$(printf '%s' "$root" | learn_hash)"
  learn_store="$learn_base/approved"
  learn_pending="$root/.squad/knowledge/pending"
  learn_lock="$learn_base/.lock"
}
learn_lock_acquire() {
  local pid host timeout="${SQUAD_LEARN_LOCK_TIMEOUT:-60}" deadline local_host
  [[ "$timeout" =~ ^[0-9]+$ ]] || { echo 'SQUAD_LEARN_LOCK_TIMEOUT must be a non-negative integer' >&2; return 1; }
  deadline=$((SECONDS + 10#$timeout))
  local_host="$(hostname -s 2>/dev/null || uname -n)"
  mkdir -p "$learn_base" || return 1
  while ! mkdir "$learn_lock" 2>/dev/null; do
    pid="$(learn_get "$learn_lock/owner" pid || true)"
    host="$(learn_get "$learn_lock/owner" host || true)"
    if [[ "$host" == "$local_host" && "$pid" =~ ^[1-9][0-9]*$ ]] && ! kill -0 "$pid" 2>/dev/null; then
      if mkdir "$learn_lock/reclaim" 2>/dev/null; then
        if [[ "$(learn_get "$learn_lock/owner" pid || true)" == "$pid" && "$(learn_get "$learn_lock/owner" host || true)" == "$host" ]]; then
          rm -f "$learn_lock/owner"
          rmdir "$learn_lock/reclaim"
          if rmdir "$learn_lock" 2>/dev/null; then continue; fi
        fi
        rmdir "$learn_lock/reclaim" 2>/dev/null || true
      fi
    fi
    if (( SECONDS >= deadline )); then
      echo "Timed out after ${timeout}s waiting for knowledge store lock (another process or unknown host)" >&2
      return 1
    fi
    sleep 0.2
  done
  printf 'pid=%s\nhost=%s\nstart=%s\n' "$$" "$(hostname -s 2>/dev/null || uname -n)" "$(date +%s)" >"$learn_lock/owner"
}
learn_lock_release() {
  if [[ "$(learn_get "$learn_lock/owner" pid || true)" == "$$" ]]; then
    rm -f "$learn_lock/owner"
    rmdir "$learn_lock"
  fi
}
learn_safe_runs() {
  local file sandbox pid host expected actual
  while IFS= read -r file; do
    [[ -f "$file" ]] || continue
    sandbox="$(learn_get "$file" sandbox)"
    if [[ "$(learn_get "$file" yolo)" != 1 && ( "$sandbox" == workspace-write || "$sandbox" == read-only ) ]]; then continue; fi
    # Unknown old status formats cannot prove that an unsafe process is dead.
    [[ -n "$sandbox" ]] || { echo "Missing sandbox identity: $file" >&2; return 1; }
    host="$(learn_get "$file" host)"
    [[ "$host" == "$(hostname -s 2>/dev/null || uname -n)" ]] || { echo "Unknown worker host: $file" >&2; return 1; }
    pid="$(learn_get "$file" pid)"
    expected="$(learn_get "$file" process_started)"
    [[ "$pid" =~ ^[1-9][0-9]*$ && -n "$expected" ]] || { echo "Unknown wrapper identity: $file" >&2; return 1; }
    actual="$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null | awk '{$1=$1; print}' || true)"
    if [[ "$actual" == "$expected" ]] || "$learn_script_dir/squad-worker.sh" --engine-alive "$file"; then
      echo "Unsafe worker still alive or unknown: $file" >&2; return 1
    fi
  done < <(
    printf '%s\n' "$learn_root"/.squad/workers/*.status
    [[ ! -f "$learn_base/RUNS" ]] || cat "$learn_base/RUNS"
  )
}
learn_confirm() {
  local answer
  [[ -t 0 ]] || { echo 'This operation requires an interactive TTY' >&2; return 1; }
  printf '%s Type yes: ' "$1" >&2
  IFS= read -r answer
  [[ "$answer" == yes ]] || { echo 'Not confirmed' >&2; return 1; }
}
learn_sandbox_check() {
  if [[ -f "$learn_store/INDEX" && ( "$1" != workspace-write && "$1" != read-only || "$2" == 1 ) ]]; then
    echo 'Enabled knowledge requires a write sandbox; ask the human to run squad-learn disable' >&2
    return 1
  fi
}
learn_inject() {
  local owned="$1" id hash extra file paths glob path quoted size used=0 match
  learn_notes=""; learn_ids=""; learn_warnings=""
  [[ -n "$owned" ]] || return 0
  while IFS= read -r file; do
    [[ -f "$file" && ! -L "$file" ]] || continue
    paths="$(sed -n '1d; /^---$/q; s/^paths: //p' "$file")"
    match=0
    while IFS= read -r glob; do
      [[ -n "$glob" ]] || continue
      while IFS= read -r path; do
        # shellcheck disable=SC2053 # The paths field intentionally contains globs.
        [[ "$path" != $glob ]] || match=1
      done < <(printf '%s\n' "$owned" | tr ',' '\n' | sed 's/^ *//;s/ *$//')
    done < <(printf '%s\n' "$paths" | tr ',' '\n' | sed 's/^ *//;s/ *$//')
    (( match )) || continue
    quoted="$(LC_ALL=C tr -d '\000-\011\013-\037\177' <"$file" | sed 's/^/> /')"
    size="$(printf '%s\n' "$quoted" | wc -c | tr -d ' ')"
    (( used + size <= 2048 )) || continue
    used=$((used + size)); learn_notes+="$quoted"$'\n'; learn_ids+="${learn_ids:+,}rule:$(basename "$file" .md)"
  done < <(find "$learn_root/.squad/rules" -maxdepth 1 -type f -name '*.md' -print 2>/dev/null | LC_ALL=C sort)
  [[ -f "$learn_store/INDEX" ]] || return 0
  # Generated IDs sort by creation time; no untrusted filename reaches a command.
  while read -r id hash extra; do
    if ! learn_id "$id" || [[ ! "$hash" =~ ^[a-f0-9]{64}$ || -n "$extra" ]]; then
      learn_warnings+="Warning: invalid knowledge INDEX entry skipped"$'\n'; continue
    fi
    file="$learn_store/$id.md"
    if [[ ! -f "$file" || -L "$file" ]] || [[ "$(learn_hash <"$file")" != "$hash" ]]; then
      learn_warnings+="Warning: knowledge $id hash mismatch; skipped"$'\n'; continue
    fi
    paths="$(sed -n '1d; /^---$/q; s/^paths: //p' "$file")"
    match=0
    while IFS= read -r glob; do
      [[ -n "$glob" ]] || continue
      while IFS= read -r path; do
        # Deliberately use a shell pattern, never evaluate the note's text.
        # shellcheck disable=SC2053 # The paths field intentionally contains globs.
        [[ "$path" != $glob ]] || match=1
      done < <(printf '%s\n' "$owned" | tr ',' '\n' | sed 's/^ *//;s/ *$//')
    done < <(printf '%s\n' "$paths" | tr ',' '\n' | sed 's/^ *//;s/ *$//')
    (( match )) || continue
    quoted="$(LC_ALL=C tr -d '\000-\011\013-\037\177' <"$file" | sed 's/^/> /')"
    size="$(printf '%s\n' "$quoted" | wc -c | tr -d ' ')"
    (( used + size <= 2048 )) || continue
    used=$((used + size))
    learn_notes+="$quoted"$'\n'
    learn_ids+="${learn_ids:+,}$id"
  done < <(LC_ALL=C sort -r "$learn_store/INDEX")
}
learn_verify() {
  local json=0 stale=0 file paths glob found path id hash extra source_hash expected_hash matched_paths
  [[ "${1:-}" == --json ]] && json=1
  local -a issues=()
  while IFS= read -r file; do
    [[ -f "$file" && ! -L "$file" ]] || continue
    paths="$(sed -n '1d; /^---$/q; s/^paths: //p' "$file")"
    expected_hash="$(sed -n '2,/^---$/s/^source[s]*_sha256: *//p' "$file" | head -n 1)"
    matched_paths=""
    while IFS= read -r glob; do
      [[ -n "$glob" ]] || continue; found=0
      while IFS= read -r path; do
        # shellcheck disable=SC2053 # Glob is inert data matched against repo paths.
        if [[ "$path" == $glob ]]; then found=1; matched_paths+="$path"$'\n'; fi
      done < <(cd "$learn_root" && find . -type f -not -path './.git/*' -not -path './.squad/knowledge/*' -print | sed 's#^./##')
      if (( ! found )); then stale=1; issues+=("$(basename "$file"): $glob"); fi
    done < <(printf '%s\n' "$paths" | tr ',' '\n' | sed 's/^ *//;s/ *$//')
    if [[ -n "$expected_hash" ]]; then
      source_hash="$(while IFS= read -r path; do [[ -n "$path" ]] || continue; printf '%s\0' "$path"; cat "$learn_root/$path"; printf '\0'; done < <(printf '%s' "$matched_paths" | LC_ALL=C sort -u) | learn_hash)"
      if [[ "$expected_hash" != "$source_hash" ]]; then stale=1; issues+=("$(basename "$file"): stale (source changed)"); fi
    fi
  done < <(find "$learn_root/.squad/rules" -maxdepth 1 -type f -name '*.md' -print 2>/dev/null | LC_ALL=C sort; [[ -f "$learn_store/INDEX" ]] && while read -r id hash extra; do learn_id "$id" && [[ "$hash" =~ ^[a-f0-9]{64}$ && -z "$extra" ]] && printf '%s\n' "$learn_store/$id.md"; done <"$learn_store/INDEX")
  if (( json )); then printf '%s\n' "${issues[@]}" | python3 -c 'import json,sys; print(json.dumps([x.rstrip("\n") for x in sys.stdin if x.rstrip("\n")]))';
  elif (( stale )); then printf 'Stale rules: %s\n' "${issues[*]}"; else echo 'Rules are current'; fi
  (( ! stale ))
}
learn_main() {
  local command="${1:-}" id title="" paths="" input="" body tmp note disabled file source_file link_target staging
  [[ $# -eq 0 ]] || shift
  source_file="${BASH_SOURCE[0]}"
  while [[ -L "$source_file" ]]; do
    link_target="$(readlink "$source_file")"
    if [[ "$link_target" == /* ]]; then source_file="$link_target"
    else source_file="$(dirname "$source_file")/$link_target"; fi
  done
  learn_script_dir="$(cd "$(dirname "$source_file")" && pwd)"
  learn_init "${SQUAD_LEARN_PROJECT:-$PWD}"
  case "$command" in
    verify) [[ $# -le 1 && ( $# -eq 0 || "$1" == --json ) ]] || { echo 'Usage: squad-learn verify [--json]' >&2; return 2; }; learn_verify "${1:-}" ;;
    propose)
      while (( $# )); do
        [[ $# -ge 2 ]] || { echo 'Missing option value' >&2; return 2; }
        case "$1" in --title) title="$2" ;; --paths) paths="$2" ;; --file) input="$2" ;; *) echo "Unknown option: $1" >&2; return 2 ;; esac
        shift 2
      done
      [[ -n "$title" && -n "$paths" && "$title$paths" != *$'\n'* && "$title$paths" != *$'\r'* ]] || { echo 'Single-line title and paths required' >&2; return 2; }
      mkdir -p "$learn_pending"
      tmp="$(mktemp "$learn_pending/.proposal.XXXXXX")"
      if [[ -n "$input" ]]; then body="$(head -c 2049 "$input")"; else body="$(head -c 2049)"; fi
      printf -- '---\ntitle: %s\npaths: %s\nby: %s\n---\n%s\n' "$title" "$paths" "${SQUAD_WORKER_ID:-worker}" "$body" >"$tmp"
      if (( $(wc -c <"$tmp") > 2048 )); then rm -f "$tmp"; echo 'Note exceeds 2048 bytes' >&2; return 2; fi
      id="$(date -u +%Y%m%d%H%M%S)-$(basename "$tmp" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')"
      mv "$tmp" "$learn_pending/$id.md"
      printf '%s\n' "$id"
      ;;
    list)
      for file in "$learn_pending"/*.md "$learn_store"/*.md; do
        [[ ! -f "$file" ]] || printf '%s %s\n' "$(basename "$(dirname "$file")")" "$(basename "$file" .md)"
      done
      ;;
    show|reject|approve)
      [[ $# -eq 1 ]] && learn_id "$1" || { echo 'Invalid note ID' >&2; return 2; }
      id="$1"; note="$learn_pending/$id.md"
      if [[ "$command" == show ]]; then
        [[ -f "$note" ]] || note="$learn_store/$id.md"
        cat "$note"; return
      fi
      [[ -f "$note" && ! -L "$note" ]] || { echo 'Pending note not found' >&2; return 1; }
      if [[ "$command" == reject ]]; then rm "$note"; return; fi
      [[ -t 0 ]] || { echo 'Approval requires an interactive TTY' >&2; return 1; }
      learn_lock_acquire
      trap learn_lock_release EXIT
      learn_safe_runs
      # Snapshot worker-writable proposals before showing what will be approved.
      tmp="$(mktemp "$learn_base/.approve.XXXXXX")"
      head -c 2049 "$note" >"$tmp"
      cat "$tmp"
      learn_confirm 'Approve this note?'
      (( $(wc -c <"$tmp") <= 2048 )) || { echo 'Note exceeds 2048 bytes' >&2; return 1; }
      # Approval must not silently re-enable archived notes.
      mkdir -p "$learn_store"
      cp "$tmp" "$learn_store/$id.md"
      chmod 444 "$learn_store/$id.md"
      printf '%s %s\n' "$id" "$(learn_hash <"$learn_store/$id.md")" >>"$learn_store/INDEX"
      rm "$tmp" "$note"
      ;;
    disable|enable)
      [[ $# -eq 0 && -t 0 ]] || { echo 'Operation requires an interactive TTY and no arguments' >&2; return 1; }
      learn_lock_acquire
      trap learn_lock_release EXIT
      if [[ "$command" == disable ]]; then
        learn_confirm 'Disable knowledge?'
        [[ -d "$learn_store" ]] || return 0
        disabled="$learn_base/disabled-$(date -u +%Y%m%d%H%M%S)-$$"
        mv "$learn_store" "$disabled"
        rm -f "$disabled/INDEX"
      else
        learn_safe_runs
        [[ ! -f "$learn_store/INDEX" ]] || { echo 'Knowledge already enabled' >&2; return 1; }
        disabled="$(find "$learn_base" -maxdepth 1 -type d -name 'disabled-*' | LC_ALL=C sort -r | head -n 1)"
        [[ -n "$disabled" ]] || { echo 'No disabled knowledge to enable' >&2; return 1; }
        staging="$(mktemp -d "$learn_base/.enable.XXXXXX")"
        for note in "$disabled"/*.md; do
          [[ -f "$note" && ! -L "$note" ]] || continue
          id="$(basename "$note" .md)"; learn_id "$id" || continue
          cat "$note"
          learn_confirm "Re-approve $id?"
          (( $(wc -c <"$note") <= 2048 )) || { echo 'Note exceeds 2048 bytes' >&2; return 1; }
          cp "$note" "$staging/$id.md"
          chmod 444 "$staging/$id.md"
        done
        : >"$staging/INDEX"
        for note in "$staging"/*.md; do
          [[ -f "$note" && ! -L "$note" ]] || continue
          printf '%s %s\n' "$(basename "$note" .md)" "$(learn_hash <"$note")" >>"$staging/INDEX"
        done
        [[ ! -d "$learn_store" ]] || rmdir "$learn_store"
        mv "$staging" "$learn_store"
      fi
      ;;
    *) echo 'Usage: squad-learn propose --title T --paths GLOBS [--file F] | list | show ID | reject ID | approve ID | enable | disable | verify [--json]' >&2; return 2 ;;
  esac
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  learn_main "$@"
fi
