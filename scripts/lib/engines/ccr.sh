#!/usr/bin/env bash
# shellcheck disable=SC2154 # squad-worker.sh sets the globals adapters read.
# Claude Code through claude-code-router: file tools only, the router picks the
# model (see lib/squad-engine.sh for the adapter protocol).

engine_ccr_check_deps() {
  require_command ccr
  require_command claude
  require_command curl
}

ensure_ccr_server() {
  local port
  port="$(sed -n 's/.*"PORT"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' \
    "$HOME/.claude-code-router/config.json" 2>/dev/null | head -1)"
  port="${port:-3456}"
  if curl -s -o /dev/null "http://127.0.0.1:$port/"; then
    return 0
  fi
  nohup ccr start >>"$output_directory/ccr-server.log" 2>&1 &
  for _ in $(seq 1 30); do
    if curl -s -o /dev/null "http://127.0.0.1:$port/"; then
      return 0
    fi
    sleep 1
  done
  echo "claude-code-router did not start on port $port; see $output_directory/ccr-server.log" >>"$log_file"
  return 1
}

engine_ccr_build_command() {
  local tools="${SQUAD_WORKER_CCR_TOOLS:-Read,Edit,Write,Glob,Grep}"
  engine_command=(claude -p --strict-mcp-config --disable-slash-commands --no-session-persistence
    --tools "$tools" --allowedTools "$tools" --permission-mode acceptEdits
    --output-format stream-json --verbose "$prompt")
  ensure_ccr_server || return 1
  squad_engine_require_jq
}

engine_ccr_run_and_extract_report() {
  eval "$(ccr activate 2>/dev/null)"
  "${engine_command[@]}" </dev/null >"$absolute_log" 2>&1 || return $?
  squad_engine_stream_report
}

engine_ccr_reported_models() {
  squad_worker_stream_models "$1"
}
