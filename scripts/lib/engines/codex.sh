#!/usr/bin/env bash
# shellcheck disable=SC2154 # squad-worker.sh sets the globals adapters read.
# codex exec, sandboxed to the project, with every MCP server not named by --mcp
# disabled (see lib/squad-engine.sh for the adapter protocol).

engine_codex_check_deps() {
  require_command codex
  require_command jq
}

# Codex silently drops an MCP server whose bearer-token variable is unset, and
# the worker then improvises around the missing tool. Fail fast instead.
missing_mcp_tokens() {
  local mcp_json="$1" server variable
  for server in ${keep_mcp[@]+"${keep_mcp[@]}"}; do
    variable="$(printf '%s' "$mcp_json" | jq -r --arg name "$server" \
      '.[] | select(.name == $name) | .transport.bearer_token_env_var // empty' 2>/dev/null || true)"
    if [[ -n "$variable" && -z "${!variable:-}" ]]; then
      printf '%s (needs %s)\n' "$server" "$variable"
    fi
  done
}

# Returns 3 (and logs why) when the MCP servers cannot be filtered safely.
engine_codex_build_command() {
  local result=0 mcp_json missing="" configured_servers server transport
  mcp_json="$(codex mcp list --json 2>>"$log_file")" || result=3
  if ! printf '%s\n' "$mcp_json" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "Could not list Codex MCP servers; refusing an unfiltered worker launch." | tee -a "$log_file" >&2
    result=3
    mcp_json='[]'
  fi
  if command -v jq >/dev/null 2>&1; then
    missing="$(missing_mcp_tokens "$mcp_json")"
  fi
  if [[ -n "$missing" ]]; then
    {
      echo "MCP servers requested with --mcp are missing their token environment variables:"
      printf '%s\n' "$missing" | sed 's/^/  /'
      echo "Export them in the shell that starts the manager (for example from ~/.zshrc)."
    } | tee -a "$log_file" >&2
    result=3
  fi
  local mcp_arguments=()
  if (( all_mcp == 0 )); then
    configured_servers="$(printf '%s\n' "$mcp_json" | jq -r '
      .[] | select(.enabled != false) | [.name, .transport.type // ""] | @tsv' 2>/dev/null || true)"
    while IFS=$'\t' read -r server transport; do
      [[ -n "$server" ]] || continue
      if [[ " ${keep_mcp[*]:-} " == *" $server "* ]]; then
        continue
      fi
      # Plugin servers need a transport even when disabled; never copy credentials.
      case "$transport" in
        stdio) mcp_arguments+=(-c "mcp_servers.$server={enabled=false,command=\"false\"}") ;;
        streamable_http) mcp_arguments+=(-c "mcp_servers.$server={enabled=false,url=\"http://127.0.0.1\"}") ;;
        *) mcp_arguments+=(-c "mcp_servers.$server.enabled=false") ;;
      esac
    done <<<"$configured_servers"
  fi
  local add_directory=()
  [[ "$engine_directory" == "$workspace_root" ]] || add_directory=(--add-dir "$workspace_root")
  local sandbox_arguments=(--sandbox workspace-write)
  if [[ "$sandbox_mode" == 0 ]]; then
    sandbox_arguments=(--sandbox danger-full-access)
  fi
  if [[ "$yolo" == 1 ]]; then
    sandbox_arguments=(--dangerously-bypass-approvals-and-sandbox)
  fi
  local profile_arguments=()
  [[ -z "$profile" ]] || profile_arguments=(--profile "$profile")
  local codex_model_arguments=(${model_arguments[@]+"${model_arguments[@]}"})
  [[ -z "$model_effort" ]] || codex_model_arguments+=(-c "model_reasoning_effort=\"$model_effort\"")
  engine_command=(codex exec --json --cd "$engine_directory" ${profile_arguments[@]+"${profile_arguments[@]}"} --ephemeral
    --skip-git-repo-check ${sandbox_arguments[@]+"${sandbox_arguments[@]}"} ${add_directory[@]+"${add_directory[@]}"}
    ${mcp_arguments[@]+"${mcp_arguments[@]}"} ${codex_model_arguments[@]+"${codex_model_arguments[@]}"}
    --output-last-message "$absolute_report" "$prompt")
  return "$result"
}

engine_codex_run_and_extract_report() {
  "${engine_command[@]}" </dev/null >"$absolute_log" 2>&1
}

# codex --json events do not name the model.
engine_codex_reported_models() {
  :
}
