#!/usr/bin/env bash
# shellcheck disable=SC2154 # squad-worker.sh sets the globals adapters read.
# Claude Code (see lib/squad-engine.sh for the adapter protocol).

engine_claude_check_deps() {
  require_command claude
}

engine_claude_build_command() {
  # Six core tools keep the prompt small. Edits are accepted in the project;
  # shell commands run inside Claude Code's sandbox by default, and can be
  # disabled with --no-sandbox or SQUAD_WORKER_SANDBOX=0.
  local claude_settings='{"sandbox":{"enabled":true,"autoAllowBashIfSandboxed":true}}'
  if [[ "$sandbox_mode" == 0 ]]; then
    claude_settings='{"sandbox":{"enabled":false}}'
  fi
  local claude_allowed_tools=()
  if [[ -n "${SQUAD_WORKER_CLAUDE_ALLOWED_TOOLS:-}" ]]; then
    claude_allowed_tools=(--allowedTools "$SQUAD_WORKER_CLAUDE_ALLOWED_TOOLS")
  fi
  local permission_arguments=(--permission-mode "${SQUAD_WORKER_CLAUDE_PERMISSION_MODE:-acceptEdits}")
  [[ "$yolo" != 1 ]] || permission_arguments=(--dangerously-skip-permissions)
  engine_command=(claude -p --model "$model" --strict-mcp-config --disable-slash-commands
    --no-session-persistence --tools "${SQUAD_WORKER_CLAUDE_TOOLS:-Read,Edit,Write,Glob,Grep,Bash}"
    "${permission_arguments[@]}"
    ${claude_allowed_tools[@]+"${claude_allowed_tools[@]}"} --settings "$claude_settings"
    --add-dir "$workspace_root" --output-format stream-json --verbose "$prompt")
  squad_engine_require_jq
}

engine_claude_run_and_extract_report() {
  "${engine_command[@]}" </dev/null >"$absolute_log" 2>&1 || return $?
  squad_engine_stream_report
}

engine_claude_reported_models() {
  squad_worker_stream_models "$1"
}
