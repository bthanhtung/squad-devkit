#!/usr/bin/env bash
# squad-jq.sh - Shared jq wrapper for squad-devkit

if declare -F squad_jq >/dev/null 2>&1; then
  return 0 2>/dev/null || true
fi

_squad_jq_repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

_squad_jq_probe() {
  local candidates=()
  local p
  while IFS= read -r p; do
    [[ -n "$p" ]] && candidates+=("$p")
  done < <(type -a -p squad 2>/dev/null || true)

  if [[ -n "${HOME:-}" && -x "${HOME}/.local/bin/squad" ]]; then
    local already_in=0
    for p in "${candidates[@]}"; do
      if [[ "$p" == "${HOME}/.local/bin/squad" ]]; then
        already_in=1
        break
      fi
    done
    if (( already_in == 0 )); then
      candidates+=("${HOME}/.local/bin/squad")
    fi
  fi

  if (( ${#candidates[@]} == 0 )); then
    candidates+=(
      "${_squad_jq_repo_dir}/target/release/squad"
      "${_squad_jq_repo_dir}/target/debug/squad"
    )
  fi

  local c
  for c in "${candidates[@]}"; do
    if [[ -x "$c" ]] && (cd / && "$c" jq -n 1) >/dev/null 2>&1; then
      SQUAD_JQ_BIN="$c"
      return 0
    fi
  done
  SQUAD_JQ_BIN=""
  return 1
}

squad_bin() {
  if [[ -z "${SQUAD_JQ_BIN+x}" ]]; then
    _squad_jq_probe || true
  fi
  if [[ -n "$SQUAD_JQ_BIN" ]]; then
    printf '%s\n' "$SQUAD_JQ_BIN"
    return 0
  fi
  return 1
}

squad_has_jq() {
  if [[ "${SQUAD_DEVKIT_NO_SYSTEM_JQ:-0}" != 1 ]] && command -v jq >/dev/null 2>&1; then
    return 0
  fi
  if [[ -z "${SQUAD_JQ_BIN+x}" ]]; then
    _squad_jq_probe || true
  fi
  [[ -n "$SQUAD_JQ_BIN" ]]
}

squad_jq() {
  if [[ "${SQUAD_DEVKIT_NO_SYSTEM_JQ:-0}" != 1 ]] && command -v jq >/dev/null 2>&1; then
    jq "$@"
    return $?
  fi
  if [[ -z "${SQUAD_JQ_BIN+x}" ]]; then
    _squad_jq_probe || true
  fi
  if [[ -n "$SQUAD_JQ_BIN" ]]; then
    "$SQUAD_JQ_BIN" jq "$@"
  else
    printf '%s\n' "squad-devkit: jq not found and no squad binary with 'squad jq'; run scripts/install-devkit.sh" >&2
    return 127
  fi
}
