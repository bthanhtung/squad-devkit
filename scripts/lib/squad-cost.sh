#!/usr/bin/env bash
# Prices follow the same project, workspace, then home lookup as worker models.
squad_cost_prices() {
  local start directory file index=0
  for start in "${project_directory:-$PWD}" "${SQUAD_DEVKIT_WORKSPACE:-${SQUAD_WORKTREE_WORKSPACE:-${workspace_root:-$PWD}}}" "${HOME:-}"; do
    index=$((index + 1))
    [[ -d "$start" ]] || continue
    directory="$(cd "$start" && pwd)"
    while :; do
      file="$directory/.squad/prices.json"
      if [[ -e "$file" ]]; then printf '%s\n' "$file"; return; fi
      [[ "$index" != 3 && "$directory" != / ]] || break
      directory="$(dirname "$directory")"
    done
  done
}

squad_cost_estimate() {
  local file="$1" model_name="$2" input="$3" cached="$4" output="$5"
  [[ "$input" =~ ^[0-9]+$ && "$cached" =~ ^[0-9]+$ && "$output" =~ ^[0-9]+$ ]] || return 1
  # Input includes cached tokens, which are billed at the cached rate instead.
  # shellcheck disable=SC2016
  squad_jq -er --arg model "$model_name" --argjson input "$input" --argjson cached "$cached" --argjson output "$output" '
    .models[$model] | select(type == "object") |
    select([.input, .cached_input, .output] | all(type == "number" and . >= 0)) |
    select($input >= $cached) |
    (($input - $cached) * .input + $cached * .cached_input + $output * .output) / 1000000' "$file" 2>/dev/null
}
