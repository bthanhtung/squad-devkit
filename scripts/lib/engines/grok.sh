#!/usr/bin/env bash
# shellcheck disable=SC2154 # squad-worker.sh sets the globals adapters read.
# Grok Build headless: prints the report on stdout (see lib/squad-engine.sh).

engine_grok_check_deps() {
  require_command grok
}

engine_grok_build_command() {
  engine_command=(grok -p "$prompt" --always-approve --cwd "$engine_directory")
  [[ -z "$model" ]] || engine_command+=(--model "$model")
}

engine_grok_run_and_extract_report() {
  "${engine_command[@]}" </dev/null >"$absolute_report" 2>"$absolute_log"
}

engine_grok_reported_models() {
  :
}
