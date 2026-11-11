#!/usr/bin/env bash
# shellcheck disable=SC2154 # squad-worker.sh sets the globals adapters read.
# Engine adapters: scripts/lib/engines/<engine>.sh defines
#   engine_<engine>_check_deps              exit through require_command when a tool is missing
#   engine_<engine>_build_command           fill engine_command=(...); nonzero = do not run
#   engine_<engine>_run_and_extract_report  run engine_command; log to $absolute_log, report to $absolute_report
#   engine_<engine>_reported_models <log>   print the models the engine reported, comma-separated
# Adapters read squad-worker's globals (prompt, model, yolo, sandbox_mode, ...)
# and helpers (require_command); they are sourced only from this directory.
squad_engine_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/engines"
squad_engine_loaded=""

# Loads one adapter: squad_engine_load <engine>. The name is checked against a
# fixed list first, so it can never pick the file that gets sourced.
squad_engine_load() {
  local name="$1" function
  case "$name" in
    claude|codex|opencode|grok|agy|ccr) ;;
    *) echo "Unknown engine: $name (use claude, codex, opencode, grok, agy, or ccr)" >&2; return 2 ;;
  esac
  # shellcheck source=/dev/null
  source "$squad_engine_directory/$name.sh" || { echo "Could not load the $name engine adapter" >&2; return 2; }
  for function in check_deps build_command run_and_extract_report reported_models; do
    if ! declare -F "engine_${name}_$function" >/dev/null; then
      echo "Engine adapter $name does not define engine_${name}_$function" >&2
      return 2
    fi
  done
  squad_engine_loaded="$name"
}

# Calls a protocol function of the loaded adapter: squad_engine <function> [args].
squad_engine() {
  local function="$1"
  shift
  case "$function" in
    check_deps|build_command|run_and_extract_report|reported_models) ;;
    *) echo "Unknown engine function: $function" >&2; return 2 ;;
  esac
  [[ -n "$squad_engine_loaded" ]] || { echo 'No engine adapter loaded' >&2; return 2; }
  "engine_${squad_engine_loaded}_$function" "$@"
}

# Claude-shaped stream-json logs end with {type:result,result:<report>}.
squad_engine_stream_report() {
  jq -R -r 'fromjson? | select(.type == "result") | .result // empty' "$absolute_log" >"$absolute_report"
}

# Engines that read the report from the stream need jq; the failure goes to the log.
squad_engine_require_jq() {
  command -v jq >/dev/null 2>&1 && return 0
  echo "jq is required for the $squad_engine_loaded engine" | tee -a "$log_file" >&2
  return 1
}
