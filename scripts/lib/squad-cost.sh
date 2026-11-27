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

squad_cost_update_prices() {
  local target="" global_mode=0 url="${SQUAD_PRICES_URL:-https://openrouter.ai/api/v1/models}"
  local from_file="" dry_run=0 no_fetch=0
  local overrides_json="{}"
  while (( $# > 0 )); do
    case "$1" in
      --target)
        (( $# >= 2 )) && [[ -n "$2" ]] || { echo "Missing value for --target" >&2; return 2; }
        target="$2"; shift ;;
      --global) global_mode=1 ;;
      --url)
        (( $# >= 2 )) && [[ -n "$2" ]] || { echo "Missing value for --url" >&2; return 2; }
        url="$2"; shift ;;
      --from-file)
        (( $# >= 2 )) && [[ -n "$2" ]] || { echo "Missing value for --from-file" >&2; return 2; }
        from_file="$2"; shift ;;
      --no-fetch) no_fetch=1 ;;
      --dry-run) dry_run=1 ;;
      --set)
        (( $# >= 2 )) && [[ -n "$2" ]] || { echo "Missing value for --set" >&2; return 2; }
        local spec="$2" model_key rates in_rate cached_rate out_rate
        if [[ "$spec" != *=* ]]; then
          echo "Invalid --set format (use MODEL=INPUT,CACHED,OUTPUT): $spec" >&2
          return 2
        fi
        model_key="${spec%%=*}"
        rates="${spec#*=}"
        IFS=',' read -r in_rate cached_rate out_rate <<<"$rates"
        if [[ -z "$model_key" || "$model_key" == *[[:space:][:cntrl:]]* ]] ||
           [[ ! "${in_rate:-}" =~ ^[0-9]+([.][0-9]+)?$ ]] ||
           [[ ! "${cached_rate:-}" =~ ^[0-9]+([.][0-9]+)?$ ]] ||
           [[ ! "${out_rate:-}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
          echo "Invalid --set value (use MODEL=INPUT,CACHED,OUTPUT with non-negative numbers): $spec" >&2
          return 2
        fi
        overrides_json="$(squad_jq -cn --argjson base "$overrides_json" --arg m "$model_key" \
          --argjson i "$in_rate" --argjson c "$cached_rate" --argjson o "$out_rate" \
          '$base + {($m): {input: $i, cached_input: $c, output: $o}}')" || return 1
        shift ;;
      *) echo "Unknown option for update-prices: $1" >&2; return 2 ;;
    esac
    shift
  done

  if (( global_mode )); then
    target="${HOME:?HOME is not set}/.squad/prices.json"
  elif [[ -z "$target" ]]; then
    target="${project_directory:-$PWD}/.squad/prices.json"
  fi

  local existing_models="{}"
  if [[ -f "$target" ]]; then
    existing_models="$(squad_jq -c 'if (.models | type) == "object" then .models else {} end' "$target" 2>/dev/null || printf '{}')"
  fi

  local fetched_models="{}" source_label="manual" raw_file="" cleanup_raw=0
  if (( no_fetch == 0 )); then
    if [[ -n "$from_file" ]]; then
      [[ -r "$from_file" ]] || { echo "Cannot read prices file: $from_file" >&2; return 1; }
      raw_file="$from_file"
      source_label="file:$from_file"
    else
      command -v curl >/dev/null 2>&1 || { echo "Missing command: curl (use --from-file or --no-fetch)" >&2; return 1; }
      raw_file="$(mktemp "${TMPDIR:-/tmp}/squad-prices-raw.XXXXXX")"
      cleanup_raw=1
      if ! curl -fsSL --max-time 20 "$url" -o "$raw_file"; then
        rm -f "$raw_file"
        echo "Failed to fetch prices from $url" >&2
        return 1
      fi
      source_label="$url"
    fi

    fetched_models="$(squad_jq -c '
      def clean_rate($v): (($v * 1000000000000 | round) / 1000000);
      if (.models | type) == "object" then
        .models | to_entries | map(
          select((.value | type) == "object" and
            ([.value.input, .value.cached_input, .value.output] | all(type == "number" and . >= 0)))
        ) | from_entries
      elif (.data | type) == "array" then
        .data | map(
          select((.id | type) == "string" and (.id | contains(":batch") | not) and (.pricing | type) == "object") |
          (.pricing.prompt | tonumber? // -1) as $in |
          (.pricing.completion | tonumber? // -1) as $out |
          ((.pricing.input_cache_read // "0") | tonumber? // 0) as $cached |
          select($in >= 0 and $out >= 0 and $cached >= 0) |
          {
            id: .id,
            val: {
              input: clean_rate($in),
              cached_input: clean_rate($cached),
              output: clean_rate($out)
            }
          }
        ) | reduce .[] as $item ({};
          .[$item.id] = $item.val |
          if ($item.id | contains("/")) and ($item.id | contains(":") | not) then
            .[($item.id | split("/") | .[1])] //= $item.val
          else . end
        ) |
        (if .["claude-haiku-5.5"] then . + {"haiku": .["claude-haiku-5.5"], "claude-haiku-5-5": .["claude-haiku-5.5"]} else . end) |
        (if .["claude-sonnet-5.5"] then . + {"sonnet": .["claude-sonnet-5.5"], "claude-sonnet-5-5": .["claude-sonnet-5.5"]} else . end) |
        (if .["claude-opus-5.5"] then . + {"opus": .["claude-opus-5.5"], "claude-opus-5-5": .["claude-opus-5.5"]} else . end) |
        (if .["gemini-4-hydrogen"] then . + {"gemini-4-hydrogen-low": .["gemini-4-hydrogen"], "gemini-4-hydrogen-high": .["gemini-4-hydrogen"]} else . end) |
        (if .["gemini-3.8-flash"] then . + {"gemini-3.8-flash-low": .["gemini-3.8-flash"]} else . end)
      else
        error("unsupported prices catalog format")
      end
    ' "$raw_file")" || {
      (( cleanup_raw )) && rm -f "$raw_file"
      echo "Invalid prices catalog from $source_label" >&2
      return 1
    }
    (( cleanup_raw )) && rm -f "$raw_file"
  fi

  local updated_at final_json model_count
  updated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  final_json="$(squad_jq -n \
    --arg comment "Per-model API pricing in USD per million tokens." \
    --arg updated_at "$updated_at" \
    --arg source "$source_label" \
    --argjson existing "$existing_models" \
    --argjson fetched "$fetched_models" \
    --argjson overrides "$overrides_json" \
    '{
      _comment: $comment,
      _updated_at: $updated_at,
      _source: $source,
      models: ($existing + $fetched + $overrides)
    }')" || return 1

  model_count="$(printf '%s\n' "$final_json" | squad_jq -r '.models | length')"
  if (( dry_run )); then
    printf '%s\n' "$final_json"
    return 0
  fi

  local target_dir tmp_file
  target_dir="$(dirname "$target")"
  mkdir -p "$target_dir"
  tmp_file="$(mktemp "$target_dir/.prices.json.XXXXXX")"
  printf '%s\n' "$final_json" >"$tmp_file"
  if ! squad_jq -e '(.models | type) == "object"' "$tmp_file" >/dev/null 2>&1; then
    rm -f "$tmp_file"
    echo "Failed to validate generated prices file" >&2
    return 1
  fi
  mv -f "$tmp_file" "$target"
  printf 'Updated %s (%s models, source: %s)\n' "$target" "$model_count" "$source_label"
}
