#!/usr/bin/env bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/squad-jq.sh"
# Find project-local selections first, then the orchestration workspace.
# JSON is parsed as data only; never eval/source a saved selection.
squad_worker_saved_selection() {
  local directory file start index=0
  for start in "${project_directory:-$PWD}" "${SQUAD_DEVKIT_WORKSPACE:-${SQUAD_WORKTREE_WORKSPACE:-${workspace_root:-$PWD}}}" "${HOME:-}"; do
    index=$((index + 1))
    [[ -d "$start" ]] || continue
    directory="$(cd "$start" && pwd)"
    while :; do
      file="$directory/.squad/worker-models.json"
      if [[ -e "$file" ]]; then
        squad_has_jq || { echo 'Missing command: jq' >&2; return 2; }
        squad_jq -r --arg engine "$engine" --arg tier "$model_tier" '
          def model: type == "string" and length > 0 and length <= 256
            and (startswith("-") | not) and (test("[\\s\\p{Cc}]") | not);
          def effort: type == "string" and test("^(none|minimal|low|medium|high|xhigh|max)$");
          if .version != 1 or (.engines | type) != "object" then error("invalid config")
          else .engines[$engine][$tier] end
          | if . == null then empty
            elif (.model | model) and
              (.effort == null or ($engine == "codex" and (.effort | effort)))
            then .model + "\t" + (.effort // "")
            else error("invalid selection") end' "$file" 2>/dev/null
        local result=$?
        if [[ "$result" != 0 ]]; then
          echo "Invalid worker models in $file; run squad config workers" >&2
          return 2
        fi
        return 0
      fi
      [[ "$index" != 3 && "$directory" != / ]] || break
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
  [[ "$engine" == claude || "$engine" == ccr ]] || return 0
  squad_worker_stream_models "$log"
}

# Models named in a Claude-shaped stream-json log (claude, ccr).
squad_worker_stream_models() {
  local log="$1"
  [[ -s "$log" ]] && squad_has_jq || return 0
  # Only documented structured Claude fields, never prompt text or router config.
  squad_jq -Rrs '
    [split("\n")[] | fromjson? | select(type == "object")
      | (select(.type == "assistant") | .message.model),
        (select(.type == "result") | (.modelUsage // {} | keys[]))
      | select(type == "string" and length > 0)
      | select(explode | all(. >= 32 and (. < 127 or . > 159)))]
    | unique | join(",")' "$log" 2>/dev/null || true
}

squad_worker_model_label() {
  local file="$1" requested actual source profile tier engine
  requested="$(status_get "$file" requested_model)"
  [[ -n "$requested" ]] || requested="$(status_get "$file" model)"
  source="$(status_get "$file" model_source)"
  actual="$(status_get "$file" actual_model)"
  engine="$(status_get "$file" engine)"
  profile="$(status_get "$file" profile)"
  tier="$(status_get "$file" model_tier)"
  printf 'requested=%s source=%s actual=%s' "${requested:-default}" "${source:-unknown}" "${actual:-unknown}"
  [[ -z "$tier" ]] || printf ' tier=%s' "$tier"
  [[ -z "$profile" ]] || printf ' profile=%s' "$profile"
  return 0
}

# Local candidates only: never invokes a provider or inspects credentials.
squad_worker_model_catalog() {
  local engine model model_source model_tier model_effort installed error candidate key value
  squad_has_jq || { echo 'Missing command: jq' >&2; return 1; }
  for engine in "$@"; do
    case "$engine" in
      claude|codex|opencode|grok|ccr) ;;
      *) echo 'Unknown catalog engine (use claude, codex, opencode, grok, or ccr)' >&2; return 2 ;;
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
      squad_jq -cn --arg engine "$engine" --arg tier "$model_tier" --arg candidate "$candidate" \
        --arg effort "${model_effort:-}" --arg source "$model_source" --arg error "$error" --argjson installed "$installed" \
        '{engine:$engine,installed:$installed,tier:$tier,candidate:($candidate|if . == "" then null else . end),source:$source,effort:($effort|if . == "" then null else . end),provider_availability:"unverified",error:($error|if . == "" then null else . end)}'
    done
  done | squad_jq -s '.'
}

# Resolve in a subshell so an explicit model cannot mask a missing higher mapping.
squad_worker_next_tier() (
  case "${model_tier:-}" in
    fast) model_tier=balanced ;;
    balanced) model_tier=strong ;;
    *) return 1 ;;
  esac
  model=""
  squad_worker_select_model || return 1
  printf '%s\n' "$model_tier"
)

squad_worker_validate_model_value() {
  local value="${1:-}" label="${2:-model}"
  if [[ -z "$value" ]] || (( ${#value} > 256 )) || [[ "$value" == -* || "$value" == *[[:cntrl:][:space:]]* ]]; then
    echo "Invalid $label: must be 1-256 non-whitespace characters and not start with '-'" >&2
    return 2
  fi
}

# Parses ENGINE or ENGINE:MODEL on the first ':' only so model IDs containing ':'
# (e.g. opencode:openrouter/luna:free) stay intact. Sets parsed_scout_engine and
# parsed_scout_model.
squad_worker_parse_scout_spec() {
  local spec="${1:-}"
  parsed_scout_engine=""
  parsed_scout_model=""
  if [[ -z "$spec" ]]; then
    echo 'Missing scout engine (use claude, codex, opencode, grok, or ccr)' >&2
    return 2
  fi
  if [[ "$spec" == *:* ]]; then
    parsed_scout_engine="${spec%%:*}"
    parsed_scout_model="${spec#*:}"
    if [[ -z "$parsed_scout_model" ]]; then
      echo "Scout spec '$spec' has empty model after ':'" >&2
      return 2
    fi
  else
    parsed_scout_engine="$spec"
  fi
  if [[ "$parsed_scout_engine" == agy ]]; then
    echo 'agy can no longer run as a worker: Antigravity blocks CLI calls from other AI agents. Use opencode, codex, claude, grok or ccr.' >&2
    return 2
  fi
  case "$parsed_scout_engine" in
    claude|codex|opencode|grok|ccr) ;;
    *) echo "Unknown scout engine: $parsed_scout_engine (use claude, codex, opencode, grok, or ccr)" >&2; return 2 ;;
  esac
  if [[ -n "$parsed_scout_model" ]]; then
    squad_worker_validate_model_value "$parsed_scout_model" "scout model" || return 2
    if [[ "$parsed_scout_engine" == ccr ]]; then
      echo 'CCR scout model overrides are unsupported: configure the router default, or choose another scout engine' >&2
      return 2
    fi
  fi
}

# Probes whether an engine's `fast` tier resolves cleanly. Uses \037 so Bash 3.2
# IFS reading does not collapse empty fields.
squad_worker_probe_fast_tier() (
  engine="$1"
  model=""
  model_tier="fast"
  model_effort=""
  squad_worker_select_model >/dev/null 2>&1 || exit 1
  printf '%s\037%s\n' "$model" "$model_source"
)

_squad_engine_in_list() {
  local needle="$1" item
  shift
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

# Resolves the read-only scout target (engine + optional tier/model) without
# running any model calls. Sets scout_resolved_engine, scout_resolved_tier,
# scout_resolved_model, scout_resolved_source, and scout_resolved_error.
# shellcheck disable=SC2034 # Globals read by sourcing scripts (squad-worker.sh, squad-devkit.sh).
squad_worker_resolve_scout_target() {
  local explicit_engine="${1:-}" explicit_model="${2:-}"
  shift 2 || true
  scout_resolved_engine=""
  scout_resolved_tier=""
  scout_resolved_model=""
  scout_resolved_source=""
  scout_resolved_error=""

  local probe_out="" fast_model="" fast_source="" eng="" err=""
  if [[ -n "$explicit_engine" ]]; then
    if [[ -n "$explicit_model" && "$explicit_engine" == *:* ]]; then
      scout_resolved_error="Unknown scout engine: $explicit_engine (use claude, codex, opencode, grok, or ccr)"
      return 2
    fi
    local spec="$explicit_engine"
    [[ -z "$explicit_model" ]] || spec="$explicit_engine:$explicit_model"
    if ! err="$(squad_worker_parse_scout_spec "$spec" 2>&1)"; then
      scout_resolved_error="$err"
      return 2
    fi
    squad_worker_parse_scout_spec "$spec" >/dev/null 2>&1
    explicit_engine="$parsed_scout_engine"
    explicit_model="$parsed_scout_model"
    if ! command -v "$explicit_engine" >/dev/null 2>&1; then
      scout_resolved_error="Scout engine not installed: $explicit_engine"
      return 1
    fi
    if [[ -n "$explicit_model" ]]; then
      scout_resolved_engine="$explicit_engine"
      scout_resolved_model="$explicit_model"
      scout_resolved_source="configured"
      return 0
    fi
    if [[ "$explicit_engine" == ccr ]]; then
      scout_resolved_engine="ccr"
      scout_resolved_source="configured-router"
      return 0
    fi
    if probe_out="$(squad_worker_probe_fast_tier "$explicit_engine")"; then
      IFS=$'\037' read -r fast_model fast_source <<<"$probe_out"
      scout_resolved_engine="$explicit_engine"
      scout_resolved_tier="fast"
      scout_resolved_model="$fast_model"
      scout_resolved_source="configured-fast"
      return 0
    fi
    scout_resolved_engine="$explicit_engine"
    scout_resolved_source="configured-default"
    return 0
  fi

  if [[ -n "$explicit_model" ]]; then
    scout_resolved_error="Scout model requires a scout engine (set SQUAD_WORKER_SCOUT_ENGINE or scout_engine)"
    return 2
  fi

  # Priority 1: explicit (non-builtin) fast tier in cheap-first order.
  for eng in opencode codex claude grok; do
    _squad_engine_in_list "$eng" "$@" || continue
    if probe_out="$(squad_worker_probe_fast_tier "$eng")"; then
      IFS=$'\037' read -r fast_model fast_source <<<"$probe_out"
      if [[ "$fast_source" != builtin ]]; then
        scout_resolved_engine="$eng"
        scout_resolved_tier="fast"
        scout_resolved_model="$fast_model"
        scout_resolved_source="auto-fast"
        return 0
      fi
    fi
  done

  # Priority 2: configured ccr router (file tools only).
  if _squad_engine_in_list ccr "$@" && [[ -f "${HOME:-}/.claude-code-router/config.json" ]]; then
    scout_resolved_engine="ccr"
    scout_resolved_source="auto-ccr"
    return 0
  fi

  # Priority 3: claude built-in fast (haiku, restricted to Read,Glob,Grep).
  if _squad_engine_in_list claude "$@"; then
    scout_resolved_engine="claude"
    scout_resolved_tier="fast"
    scout_resolved_model="haiku"
    scout_resolved_source="auto-builtin"
    return 0
  fi

  # Priority 4: first available enabled installed engine.
  for eng in opencode codex ccr grok; do
    if _squad_engine_in_list "$eng" "$@"; then
      scout_resolved_engine="$eng"
      scout_resolved_source="auto-default"
      return 0
    fi
  done

  scout_resolved_error="No enabled worker engine available for scout"
  return 1
}

squad_worker_format_scout_guidance() {
  case "${scout_resolved_source:-}" in
    configured)
      printf -- '--role scout --engine %s --model %s' \
        "$scout_resolved_engine" "$scout_resolved_model"
      ;;
    configured-fast|auto-fast|auto-builtin)
      printf -- '--role scout --engine %s --model-tier fast (%s)' \
        "$scout_resolved_engine" "$scout_resolved_model"
      ;;
    configured-router|auto-ccr)
      printf -- '--role scout --engine ccr (router default)'
      ;;
    configured-default|auto-default)
      printf -- '--role scout --engine %s (CLI default)' \
        "$scout_resolved_engine"
      ;;
    *)
      printf -- '--role scout'
      ;;
  esac
}
