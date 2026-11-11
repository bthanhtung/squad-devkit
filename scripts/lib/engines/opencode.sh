#!/usr/bin/env bash
# shellcheck disable=SC2154 # squad-worker.sh sets the globals adapters read.
# OpenCode headless: prints the report on stdout (see lib/squad-engine.sh).

engine_opencode_check_deps() {
  require_command opencode
}

engine_opencode_build_command() {
  engine_command=(opencode run "$prompt")
  [[ -z "$model" ]] || engine_command+=(--model "$model")
}

engine_opencode_run_and_extract_report() {
  "${engine_command[@]}" </dev/null >"$absolute_report" 2>"$absolute_log"
}

engine_opencode_reported_models() {
  :
}
