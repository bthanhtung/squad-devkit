#!/usr/bin/env bash
# shellcheck disable=SC2154 # squad-worker.sh sets the globals adapters read.
# OpenCode headless, JSON mode: the run log is JSONL and the report is the
# text of the last assistant message (see lib/squad-engine.sh).

engine_opencode_check_deps() {
  require_command opencode
}

engine_opencode_build_command() {
  engine_command=(opencode run --format json "$prompt")
  [[ -z "$model" ]] || engine_command+=(--model "$model")
  squad_engine_require_jq
}

engine_opencode_run_and_extract_report() {
  "${engine_command[@]}" </dev/null >"$absolute_log" 2>&1 || return $?
  jq -R -r -s '[split("\n")[] | fromjson? | select(type=="object" and .type=="text") | .part] as $t
    | if ($t|length)==0 then "" else ($t|last|.messageID) as $m | [$t[] | select(.messageID==$m) | .text] | join("\n") end' \
    "$absolute_log" >"$absolute_report"
}

engine_opencode_reported_models() {
  :
}
