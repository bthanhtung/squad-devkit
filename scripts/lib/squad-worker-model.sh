#!/usr/bin/env bash
# Find project-local selections first, then the orchestration workspace.
# JSON is parsed as data only; never eval/source a saved selection.
squad_worker_saved_selection() {
  local directory file start
  for start in "${project_directory:-$PWD}" "${SQUAD_DEVKIT_WORKSPACE:-${SQUAD_WORKTREE_WORKSPACE:-${workspace_root:-$PWD}}}"; do
    [[ -d "$start" ]] || continue
    directory="$(cd "$start" && pwd)"
    while :; do
      file="$directory/.squad/worker-models.json"
      if [[ -e "$file" ]]; then
        command -v jq >/dev/null 2>&1 || { echo 'Missing command: jq' >&2; return 2; }
        jq -r --arg engine "$engine" --arg tier "$model_tier" '
          def model: type == "string" and length > 0 and length <= 256
            and (startswith("-") | not) and (test("[\\s\\p{Cc}]") | not);
          def effort: type == "string" and test("^(none|minimal|low|medium|high|xhigh|max)$");
          if .version != 1 or (.engines | type) != "object" then error("invalid config")
          else .engines[$engine][$tier] end
          | if . == null then empty
            elif (.model | model) and
              (.effort == null or (($engine == "codex" or $engine == "agy") and (.effort | effort)))
            then .model + "\t" + (.effort // "")
            else error("invalid selection") end' "$file" 2>/dev/null
        local result=$?
        if [[ "$result" != 0 ]]; then
          echo "Invalid worker models in $file; run squad config workers" >&2
          return 2
        fi
        return 0
      fi
      [[ "$directory" != / ]] || break
      directory="$(dirname "$directory")"
    done
  done
}

# Selection is independent of profiles; an engine report is separate evidence.
squad_worker_select_model() {
  local key value saved
  model_effort=""
  case "${model_tier:-}" in
    ''|fast|balanced|strong) ;;
    *) echo 'Unknown model tier: use fast, balanced, or strong' >&2; return 2 ;;
  esac
  if [[ "$engine" == ccr && -n "${model_tier:-}" ]]; then
    echo 'CCR model tiers are unsupported; configure the router default or choose another engine' >&2
    return 2
  fi
  model_source=flag
  if [[ -z "$model" && -n "${model_tier:-}" ]]; then
    key="SQUAD_WORKER_$(printf '%s' "$engine" | tr '[:lower:]' '[:upper:]')_MODEL_$(printf '%s' "$model_tier" | tr '[:lower:]' '[:upper:]')"
    model="${!key:-}"
    model_source="tier-environment"
    if [[ -z "$model" && "$model_tier" == balanced ]]; then
      value="SQUAD_WORKER_$(printf '%s' "$engine" | tr '[:lower:]' '[:upper:]')_MODEL"
      model="${!value:-}"
      model_source=environment
    fi
    if [[ -z "$model" ]]; then
      saved="$(squad_worker_saved_selection)" || return $?
      if [[ -n "$saved" ]]; then
        model="${saved%%$'\t'*}"
        model_effort="${saved#*$'\t'}"
        model_source=saved
      fi
    fi
    if [[ -z "$model" && "$engine" == claude ]]; then
      case "$model_tier" in fast) model=haiku ;; balanced) model=sonnet ;; strong) model=opus ;; esac
      model_source=builtin
    fi
    if [[ -z "$model" ]]; then
      echo "Missing model mapping: set $key or run squad config workers or pass --model NAME (no tier downgrade)" >&2
      return 2
    fi
  fi
  if [[ -z "$model" ]]; then
    key="SQUAD_WORKER_$(printf '%s' "$engine" | tr '[:lower:]' '[:upper:]')_MODEL"
    value="${!key:-}"
    model="$value"
    model_source=environment
    if [[ -z "$model" ]]; then
      model_source=cli-default
      if [[ "$engine" == claude ]]; then model=haiku; model_source=builtin; fi
      [[ "$engine" != ccr ]] || model_source=router-default
    fi
  fi
  if [[ "$model" == *[[:cntrl:]]* ]]; then
    echo 'Model must not contain control characters' >&2
    return 2
  fi
  if [[ "$engine" == ccr && -n "$model" ]]; then
    echo "CCR $model_source model overrides are unsupported: configure the router default, or use --engine claude --model instead" >&2
    return 2
  fi
}

# Kept for callers without an engine adapter; adapters call squad_worker_stream_models.
squad_worker_reported_models() {
  local engine="$1" log="$2"
  [[ "$engine" == claude || "$engine" == ccr || "$engine" == agy ]] || return 0
  squad_worker_stream_models "$log"
}

# Models named in a Claude-shaped stream-json log (claude, ccr, agy).
squad_worker_stream_models() {
  local log="$1"
  [[ -s "$log" ]] && command -v jq >/dev/null 2>&1 || return 0
  # Only documented structured Claude fields, never prompt text or router config.
  jq -Rrs '
    [split("\n")[] | fromjson? | select(type == "object")
      | (select(.type == "assistant") | .message.model),
        (select(.type == "result") | (.modelUsage // {} | keys[]))
      | select(type == "string" and length > 0)
      | select(explode | all(. >= 32 and (. < 127 or . > 159)))]
    | unique | join(",")' "$log" 2>/dev/null || true
}

squad_worker_agy_configured_model() {
  local log="$1"
  [[ -s "$log" ]] && command -v jq >/dev/null 2>&1 || return 0
  jq -Rrs '[split("\n")[] | fromjson? | select(type == "object" and .event == "init" and (.init | type) == "object")
    | .init.model | select(type == "string" and length > 0 and length <= 256)
    | select(test("[\\s\\p{Cc}]") | not)] | first // empty' "$log" 2>/dev/null || true
}

squad_worker_model_label() {
  local file="$1" requested actual source profile tier configured configured_source engine
  requested="$(status_get "$file" requested_model)"
  [[ -n "$requested" ]] || requested="$(status_get "$file" model)"
  source="$(status_get "$file" model_source)"
  actual="$(status_get "$file" actual_model)"
  engine="$(status_get "$file" engine)"
  profile="$(status_get "$file" profile)"
  tier="$(status_get "$file" model_tier)"
  printf 'requested=%s source=%s actual=%s' "${requested:-default}" "${source:-unknown}" "${actual:-unknown}"
  if [[ "$engine" == agy ]]; then
    configured="$(status_get "$file" configured_model)"
    configured_source="$(status_get "$file" configured_model_source)"
    printf ' configured=%s configured_source=%s' "${configured:-unknown}" "${configured_source:-unknown}"
  fi
  [[ -z "$tier" ]] || printf ' tier=%s' "$tier"
  [[ -z "$profile" ]] || printf ' profile=%s' "$profile"
  return 0
}

# Local candidates only: never invokes a provider or inspects credentials.
squad_worker_model_catalog() {
  local engine model model_source model_tier model_effort installed error candidate key value
  command -v jq >/dev/null 2>&1 || { echo 'Missing command: jq' >&2; return 1; }
  for engine in "$@"; do
    case "$engine" in
      claude|codex|opencode|grok|agy|ccr) ;;
      *) echo 'Unknown catalog engine (use claude, codex, opencode, grok, agy, or ccr)' >&2; return 2 ;;
    esac
  done
  for engine in "$@"; do
    for model_tier in '' _FAST _BALANCED _STRONG; do
      key="SQUAD_WORKER_$(printf '%s' "$engine" | tr '[:lower:]' '[:upper:]')_MODEL$model_tier"
      value="${!key:-}"
      if [[ "$value" == *[[:cntrl:]]* ]]; then
        echo "Model must not contain control characters ($key)" >&2; return 2
      fi
    done
  done
  for engine in "$@"; do
    installed=false
    command -v "$engine" >/dev/null 2>&1 && installed=true
    for model_tier in '' fast balanced strong; do
      model=''; model_source=''; model_effort=''
      if error="$(squad_worker_select_model 2>&1)"; then
        squad_worker_select_model || return
        candidate="$model"
      else
        candidate=''; model_source=unresolved
      fi
      jq -cn --arg engine "$engine" --arg tier "$model_tier" --arg candidate "$candidate" \
        --arg effort "${model_effort:-}" --arg source "$model_source" --arg error "$error" --argjson installed "$installed" \
        '{engine:$engine,installed:$installed,tier:$tier,candidate:($candidate|if . == "" then null else . end),source:$source,effort:($effort|if . == "" then null else . end),provider_availability:"unverified",error:($error|if . == "" then null else . end)}'
    done
  done | jq -s '.'
}
