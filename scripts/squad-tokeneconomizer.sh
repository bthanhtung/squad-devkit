#!/usr/bin/env bash
set -euo pipefail

source_file="${BASH_SOURCE[0]}"
while [[ -L "$source_file" ]]; do
  source_directory="$(cd "$(dirname "$source_file")" && pwd)"
  link_target="$(readlink "$source_file")"
  if [[ "$link_target" == /* ]]; then
    source_file="$link_target"
  else
    source_file="$source_directory/$link_target"
  fi
done
script_dir="$(cd "$(dirname "$source_file")" && pwd)"
# shellcheck source=./lib/squad-tokeneconomizer.sh
source "$script_dir/lib/squad-tokeneconomizer.sh"

usage() {
  cat <<EOF
Usage: squad-tokeneconomizer <command> [options]

Manage the optional, experimental TokenEconomizer plugin integration for Codex.
Upstream: $SQUAD_TE_UPSTREAM_URL
License:  $SQUAD_TE_UPSTREAM_LICENSE
Pinned:   $SQUAD_TE_PINNED_COMMIT

Commands:
  install [--repo PATH]
      Clone/fetch the pinned upstream commit into the devkit cache directory,
      verify the commit SHA, clean git tree, and plugin files, and register the
      local marketplace and plugin via 'codex plugin marketplace add' and
      'codex plugin add' (also refreshing cached plugin files on pin changes
      or disabled registrations). Never modifies global TokenEconomizer config.
      Pass --repo PATH to set missing repo-scoped defaults
      (microskills=envfacts, toolprune=propose, loopguard=on) without
      overwriting existing preferences.

  status [--json]
      Read-only inspection of ownership, pinned checkout, Codex CLI PATH
      presence (version/compatibility left unprobed to avoid executing Codex),
      Python >= 3.10 availability, local Codex config (if present), and known
      limits. Never executes 'codex', performs no network calls, and performs
      no file or config mutations.

  disable
      Remove only the devkit-owned Codex plugin registration while keeping the
      pinned checkout, ownership marker, and learned data intact. Fails and
      retains the ownership marker if Codex CLI is missing or cannot probe
      plugin state.

  uninstall
      Remove only the devkit-owned Codex plugin registration, devkit-owned
      marketplace entry (when unshared), and devkit cache checkout. Preserves
      shared marketplaces (along with their checkout and ownership marker),
      user-owned plugins/marketplaces/config, and learned data under
      \$TOKENECONOMIZER_HOME (~/.tokeneconomizer).

  help, -h, --help
      Show this help text.

Known limitations with squad-devkit:
  - Interactive Codex manager sessions may benefit once hooks are approved via
    /hooks -> Trust all and continue. Status always reports registered_unverified
    until Codex-specific runtime hook evidence exists.
  - squad-worker runs Codex with --ephemeral (no disk rollout persistence), so
    ephemeral worker cross-session learning (SessionEnd microskills/toolprune/usage
    folding) is unavailable.
  - Upstream documents Codex $SQUAD_TE_CODEX_MIN_TESTED..$SQUAD_TE_CODEX_MAX_TESTED; newer Codex releases are
    experimental/unverified. Python >= 3.10 (or TE_PYTHON) is required.
EOF
}

require_tool() {
  local tool="$1"
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing required command: $tool" >&2
    return 1
  fi
}

require_no_symlinks() {
  local bad_link=""
  if bad_link="$(squad_te_symlink_target)"; then
    echo "Refusing symlink at devkit-managed path: $bad_link" >&2
    return 1
  fi
}

# Sets SQUAD_TE_PREF_TO_SET and SQUAD_TE_PREF_RETAINED for missing repo-scoped defaults.
collect_missing_preferences() {
  local cfg_file="$1"
  SQUAD_TE_PREF_TO_SET=()
  SQUAD_TE_PREF_RETAINED=()

  if [[ -L "$cfg_file" ]]; then
    echo "Refusing symlinked config file: $cfg_file" >&2
    return 1
  fi
  if [[ -e "$cfg_file" && ! -f "$cfg_file" ]]; then
    echo "Refusing non-regular config file: $cfg_file" >&2
    return 1
  fi
  if [[ -f "$cfg_file" ]]; then
    if ! squad_jq -e 'type == "object"' "$cfg_file" >/dev/null 2>&1; then
      echo "Refusing to modify malformed JSON config: $cfg_file" >&2
      return 1
    fi
  fi

  local key alias desired existing=""
  local specs=(
    "microskills:inject:envfacts"
    "toolprune:untool:propose"
    "loopguard:spiral:on"
  )
  local spec
  for spec in "${specs[@]}"; do
    IFS=':' read -r key alias desired <<<"$spec"
    existing=""
    if [[ -f "$cfg_file" ]]; then
      existing="$(squad_jq -r --arg k "$key" --arg a "$alias" '
        if has($k) then ($k + "=" + (.[$k] | tostring))
        elif has($a) then ($a + "=" + (.[$a] | tostring))
        else empty end
      ' "$cfg_file" 2>/dev/null || true)"
    fi
    if [[ -n "$existing" ]]; then
      SQUAD_TE_PREF_RETAINED+=("$existing")
    else
      SQUAD_TE_PREF_TO_SET+=("${key}=${desired}")
    fi
  done
  return 0
}

apply_scoped_preferences() {
  local repo_dir="$1" checkout="$2" python_bin="$3"
  local te_bootstrap="$checkout/plugin/scripts/te_bootstrap.py"
  if [[ ! -f "$te_bootstrap" ]]; then
    echo "Missing TokenEconomizer bootstrap script: $te_bootstrap" >&2
    return 1
  fi

  local status_json state_dir repo_cfg
  status_json="$("$python_bin" "$te_bootstrap" cli --host codex --cwd "$repo_dir" status --json)" || return 1
  state_dir="$(printf '%s\n' "$status_json" | squad_jq -r '.state // empty')" || return 1
  if [[ -z "$state_dir" ]] || ! squad_te_validate_no_ctrl "$state_dir"; then
    echo "Could not resolve TokenEconomizer state directory for $repo_dir" >&2
    return 1
  fi
  repo_cfg="$(dirname "$state_dir")/config.json"

  collect_missing_preferences "$repo_cfg" || return 1
  if (( ${#SQUAD_TE_PREF_RETAINED[@]} > 0 )); then
    printf 'Retained existing repo preferences (%s): %s\n' "$repo_cfg" "${SQUAD_TE_PREF_RETAINED[*]}"
  fi
  if (( ${#SQUAD_TE_PREF_TO_SET[@]} > 0 )); then
    "$python_bin" "$te_bootstrap" cli --host codex --cwd "$repo_dir" config set "${SQUAD_TE_PREF_TO_SET[@]}" >/dev/null || return 1
    printf 'Applied repo-scoped preferences (%s): %s\n' "$repo_cfg" "${SQUAD_TE_PREF_TO_SET[*]}"
  fi
}

write_ownership_file() {
  local ownership_file="$1" checkout="$2" codex_home="$3" mkt_owned="$4" plugin_owned="$5" disabled="$6"
  local pin_sha="${7:-$SQUAD_TE_PINNED_COMMIT}"
  require_no_symlinks || return 1

  local cache_dir installed_at tmp_file
  cache_dir="$(dirname "$ownership_file")"
  mkdir -p "$cache_dir"
  installed_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  tmp_file="$ownership_file.tmp.$$"

  if ! squad_jq -n \
    --arg url "$SQUAD_TE_UPSTREAM_URL" \
    --arg lic "$SQUAD_TE_UPSTREAM_LICENSE" \
    --arg pin "$pin_sha" \
    --arg checkout "$checkout" \
    --arg mkt "$SQUAD_TE_MARKETPLACE_NAME" \
    --arg pid "$SQUAD_TE_PLUGIN_ID" \
    --arg chome "$codex_home" \
    --arg ts "$installed_at" \
    --argjson mkt_owned "$mkt_owned" \
    --argjson plugin_owned "$plugin_owned" \
    --argjson disabled "$disabled" \
    '{
      schema_version: 1,
      managed_by: "squad-devkit",
      upstream_repo: $url,
      upstream_license: $lic,
      pinned_commit: $pin,
      checkout_dir: $checkout,
      marketplace_name: $mkt,
      marketplace_added_by_devkit: $mkt_owned,
      plugin_id: $pid,
      plugin_added_by_devkit: $plugin_owned,
      disabled: $disabled,
      codex_home: $chome,
      installed_at: $ts
    }' >"$tmp_file"; then
    rm -f "$tmp_file"
    return 1
  fi
  mv "$tmp_file" "$ownership_file"
}

_te_child_pid=""
run_cancellable() {
  local out_file="$1"
  shift
  local rc=0
  "$@" >"$out_file" 2>&1 &
  _te_child_pid=$!
  wait "$_te_child_pid" || rc=$?
  _te_child_pid=""
  return "$rc"
}

cmd_install() {
  local repo_scope=""
  while (( $# > 0 )); do
    case "$1" in
      --repo)
        if (( $# < 2 )) || [[ -z "$2" ]]; then
          echo "Missing value for --repo" >&2
          return 2
        fi
        repo_scope="$2"
        shift
        ;;
      --repo=*)
        repo_scope="${1#*=}"
        if [[ -z "$repo_scope" ]]; then
          echo "Missing value for --repo" >&2
          return 2
        fi
        ;;
      -h|--help) usage; return 0 ;;
      *) echo "Unknown install option: $1" >&2; return 2 ;;
    esac
    shift
  done

  if [[ -n "$repo_scope" ]]; then
    if ! squad_te_validate_no_ctrl "$repo_scope" || [[ ! -d "$repo_scope" ]]; then
      echo "Invalid --repo directory: $repo_scope" >&2
      return 2
    fi
    repo_scope="$(squad_te_realpath "$repo_scope")"
  fi

  require_tool git || return 1
  require_tool codex || return 1
  if ! squad_has_jq; then
    echo "Missing required command: jq (or squad jq)" >&2
    return 1
  fi

  local cache_dir checkout ownership_file codex_home source_url="$SQUAD_TE_UPSTREAM_URL"
  cache_dir="$(squad_te_cache_dir)"
  checkout="$(squad_te_checkout_dir)"
  ownership_file="$(squad_te_ownership_file)"
  codex_home="$(squad_te_codex_home)"

  if ! squad_te_validate_no_ctrl "$cache_dir" || ! squad_te_validate_no_ctrl "$codex_home"; then
    echo "Invalid control characters in cache or CODEX_HOME path" >&2
    return 1
  fi
  if [[ "$codex_home" != /* ]]; then
    codex_home="$(squad_te_realpath "$codex_home")" || return 1
  fi

  require_no_symlinks || return 1

  squad_te_inspect_status introspect

  if (( SQUAD_TE_OWNERSHIP_MALFORMED == 1 )); then
    echo "Refusing to overwrite malformed ownership marker: $ownership_file" >&2
    return 1
  fi

  if (( SQUAD_TE_OWNERSHIP_HOME_MISMATCH == 1 )); then
    echo "Refusing to modify ownership marker belonging to a different CODEX_HOME (${SQUAD_TE_OWNERSHIP_CODEX_HOME}) at $ownership_file (outside squad-devkit scope for $codex_home)" >&2
    return 1
  fi

  if [[ "$SQUAD_TE_PYTHON_STATUS" != "ok" ]]; then
    case "$SQUAD_TE_PYTHON_STATUS" in
      invalid_env)
        echo "TE_PYTHON is not executable: ${TE_PYTHON:-}" >&2
        ;;
      too_old)
        echo "Python >= 3.10 is required by TokenEconomizer (found ${SQUAD_TE_PYTHON_VER:-older}); install Python 3.10+ or set TE_PYTHON=/path/to/python3.10+" >&2
        ;;
      *)
        echo "Python >= 3.10 is required by TokenEconomizer (none found on PATH); install Python 3.10+ or set TE_PYTHON=/path/to/python3.10+" >&2
        ;;
    esac
    return 1
  fi

  if [[ "$SQUAD_TE_CODEX_COMPAT" == "missing" || "$SQUAD_TE_CODEX_COMPAT" == "unsupported" ]]; then
    echo "Codex compatibility check failed: $SQUAD_TE_CODEX_REASON" >&2
    return 1
  fi

  if [[ -e "$checkout" || -L "$checkout" ]] && (( SQUAD_TE_OWNED == 0 )); then
    echo "Refusing to overwrite unowned directory at $checkout (missing $ownership_file)" >&2
    return 1
  fi

  local mkt_already_devkit=0
  if (( SQUAD_TE_MKT_REGISTERED == 1 )); then
    if [[ -n "$SQUAD_TE_MKT_SOURCE" ]] && squad_te_path_within_checkout "$SQUAD_TE_MKT_SOURCE" "$checkout"; then
      mkt_already_devkit=1
    else
      echo "Refusing to overwrite existing user-owned Codex marketplace '$SQUAD_TE_MARKETPLACE_NAME' (${SQUAD_TE_MKT_SOURCE:-unknown})" >&2
      return 1
    fi
  fi

  local plugin_already_devkit=0
  if (( SQUAD_TE_PLUGIN_INSTALLED == 1 )); then
    if (( SQUAD_TE_OWNED == 1 )) && [[ -n "$SQUAD_TE_PLUGIN_SOURCE" ]] && squad_te_path_within_checkout "$SQUAD_TE_PLUGIN_SOURCE" "$checkout"; then
      plugin_already_devkit=1
    else
      echo "Refusing to overwrite existing user-owned Codex plugin '$SQUAD_TE_PLUGIN_ID' (${SQUAD_TE_PLUGIN_SOURCE:-unknown})" >&2
      return 1
    fi
  fi

  if (( SQUAD_TE_CHECKOUT_EXISTS == 1 && SQUAD_TE_CHECKOUT_CLEAN == 0 )); then
    echo "Refusing to overwrite dirty or untracked checkout at $checkout; clean or run squad-tokeneconomizer uninstall first" >&2
    return 1
  fi

  local stage_dir="" backup_checkout="" cmd_out_file=""
  local created_checkout_now=0 moving_checkout=0
  local added_mkt_now=0 attempting_mkt_add=0
  local added_plugin_now=0 attempting_plugin_add=0

  rollback_install() {
    if [[ -n "$_te_child_pid" ]]; then
      kill -TERM "$_te_child_pid" 2>/dev/null || true
      wait "$_te_child_pid" 2>/dev/null || true
      _te_child_pid=""
    fi
    if (( plugin_already_devkit == 0 )) && (( added_plugin_now == 1 || attempting_plugin_add == 1 )); then
      codex plugin remove "$SQUAD_TE_PLUGIN_ID" --json >/dev/null 2>&1 || true
    fi
    if (( mkt_already_devkit == 0 )) && (( added_mkt_now == 1 || attempting_mkt_add == 1 )); then
      codex plugin marketplace remove "$SQUAD_TE_MARKETPLACE_NAME" --json >/dev/null 2>&1 || true
    fi
    if (( created_checkout_now == 1 )) || (( moving_checkout == 1 )); then
      if [[ -d "$checkout" && ! -L "$checkout" ]]; then
        rm -rf "${checkout:?}"
      fi
    fi
    if [[ -n "$backup_checkout" && -d "$backup_checkout" && ! -e "$checkout" && ! -L "$checkout" ]]; then
      if mv "$backup_checkout" "$checkout" 2>/dev/null && (( plugin_already_devkit == 1 && added_plugin_now == 1 )); then
        codex plugin add "$SQUAD_TE_PLUGIN_ID" --json >/dev/null 2>&1 || true
      fi
    fi
    if [[ -n "$stage_dir" && -d "$stage_dir" && ! -L "$stage_dir" ]]; then
      rm -rf "${stage_dir:?}"
    fi
    if [[ -n "$cmd_out_file" ]]; then
      rm -f "$cmd_out_file"
    fi
    rm -f "$ownership_file.tmp.$$"
    if (( SQUAD_TE_OWNED == 0 )) && [[ ! -e "$ownership_file" && ! -L "$ownership_file" ]]; then
      rmdir "$cache_dir" 2>/dev/null || true
    fi
  }

  on_install_signal() {
    local code="${1:-130}"
    trap '' INT TERM
    rollback_install
    echo "Interrupted; rolled back incomplete TokenEconomizer setup." >&2
    exit "$code"
  }

  trap 'on_install_signal 130' INT
  trap 'on_install_signal 143' TERM

  if (( SQUAD_TE_CHECKOUT_VALID == 1 )); then
    echo "Using existing pinned TokenEconomizer checkout ($SQUAD_TE_PINNED_COMMIT) at $checkout"
  else
    mkdir -p "$cache_dir"
    stage_dir="$cache_dir/upstream.staging.$$"
    cmd_out_file="$cache_dir/.cmd.out.$$"
    rm -rf "${stage_dir:?}"

    if ! run_cancellable "$cmd_out_file" git init -q "$stage_dir" ||
       ! run_cancellable "$cmd_out_file" git -C "$stage_dir" remote add origin "$source_url" ||
       ! run_cancellable "$cmd_out_file" git -C "$stage_dir" fetch -q --depth 1 origin "$SQUAD_TE_PINNED_COMMIT" ||
       ! run_cancellable "$cmd_out_file" git -C "$stage_dir" checkout -q --detach FETCH_HEAD; then
      [[ -s "$cmd_out_file" ]] && cat "$cmd_out_file" >&2
      echo "Failed to fetch pinned TokenEconomizer commit $SQUAD_TE_PINNED_COMMIT from $source_url" >&2
      trap - INT TERM
      rollback_install
      return 1
    fi
    rm -f "$cmd_out_file"
    cmd_out_file=""

    if ! squad_te_checkout_valid "$stage_dir"; then
      local got_sha=""
      got_sha="$(git -C "$stage_dir" rev-parse HEAD 2>/dev/null || true)"
      echo "Fetched TokenEconomizer checkout failed verification (HEAD=${got_sha:-none}, expected $SQUAD_TE_PINNED_COMMIT)" >&2
      trap - INT TERM
      rollback_install
      return 1
    fi

    if [[ -e "$checkout" ]]; then
      backup_checkout="$cache_dir/upstream.backup.$$"
      rm -rf "${backup_checkout:?}"
      if ! mv "$checkout" "$backup_checkout"; then
        trap - INT TERM
        rollback_install
        return 1
      fi
    fi

    moving_checkout=1
    if ! mv "$stage_dir" "$checkout"; then
      trap - INT TERM
      rollback_install
      return 1
    fi
    created_checkout_now=1
    moving_checkout=0
    stage_dir=""
  fi

  local mkt_owned=false plugin_owned=false
  (( SQUAD_TE_OWN_MKT == 1 )) && mkt_owned=true
  (( SQUAD_TE_OWN_PLUGIN == 1 )) && plugin_owned=true

  mkdir -p "$cache_dir"
  cmd_out_file="$cache_dir/.cmd.out.$$"

  if (( mkt_already_devkit == 0 )); then
    attempting_mkt_add=1
    if ! run_cancellable "$cmd_out_file" codex plugin marketplace add "$checkout" --json; then
      local mkt_out=""
      mkt_out="$(cat "$cmd_out_file" 2>/dev/null || true)"
      echo "Failed to register Codex marketplace from $checkout: $mkt_out" >&2
      trap - INT TERM
      rollback_install
      return 1
    fi
    attempting_mkt_add=0
    added_mkt_now=1
    mkt_owned=true
  fi

  local need_plugin_add=0
  if (( plugin_already_devkit == 0 || created_checkout_now == 1 || SQUAD_TE_PLUGIN_ENABLED == 0 || SQUAD_TE_DISABLED_FLAG == 1 )) ||
     [[ "$SQUAD_TE_OWNED_PIN" != "$SQUAD_TE_PINNED_COMMIT" ]]; then
    need_plugin_add=1
  fi

  if (( need_plugin_add == 1 )); then
    attempting_plugin_add=1
    if ! run_cancellable "$cmd_out_file" codex plugin add "$SQUAD_TE_PLUGIN_ID" --json; then
      local plug_out=""
      plug_out="$(cat "$cmd_out_file" 2>/dev/null || true)"
      echo "Failed to install Codex plugin $SQUAD_TE_PLUGIN_ID: $plug_out" >&2
      trap - INT TERM
      rollback_install
      return 1
    fi
    attempting_plugin_add=0
    added_plugin_now=1
    plugin_owned=true
  fi
  rm -f "$cmd_out_file"
  cmd_out_file=""

  if ! write_ownership_file "$ownership_file" "$checkout" "$codex_home" "$mkt_owned" "$plugin_owned" false "$SQUAD_TE_PINNED_COMMIT"; then
    echo "Failed to write devkit ownership marker at $ownership_file" >&2
    trap - INT TERM
    rollback_install
    return 1
  fi

  if [[ -n "$backup_checkout" && -d "$backup_checkout" && ! -L "$backup_checkout" ]]; then
    rm -rf "${backup_checkout:?}"
  fi
  trap - INT TERM

  if [[ -n "$repo_scope" ]]; then
    apply_scoped_preferences "$repo_scope" "$checkout" "$SQUAD_TE_PYTHON_BIN" || return 1
  fi

  printf 'TokenEconomizer installed (pin %s, license %s).\n' "$SQUAD_TE_PINNED_COMMIT" "$SQUAD_TE_UPSTREAM_LICENSE"
  printf 'Checkout:   %s\n' "$checkout"
  printf 'Codex CLI:  %s (%s)\n' "$SQUAD_TE_CODEX_VER" "$SQUAD_TE_CODEX_COMPAT"
  if [[ -z "$repo_scope" ]]; then
    printf 'Config:     global %s/config.json left untouched (pass --repo PATH for repo-scoped defaults).\n' "$(squad_te_state_home)"
  fi
  printf 'Next step:  start an interactive codex session in your repo and approve /hooks -> Trust all and continue.\n'
  printf 'Limit:      interactive managers may benefit; ephemeral codex exec worker cross-session learning is unavailable.\n'
  return 0
}

cmd_status() {
  local json_out=0
  while (( $# > 0 )); do
    case "$1" in
      --json) json_out=1 ;;
      -h|--help) usage; return 0 ;;
      *) echo "Unknown status option: $1" >&2; return 2 ;;
    esac
    shift
  done

  squad_te_inspect_status readonly

  local checkout ownership_file state_home global_cfg global_cfg_summary="absent"
  checkout="$(squad_te_checkout_dir)"
  ownership_file="$(squad_te_ownership_file)"
  state_home="$(squad_te_state_home)"
  global_cfg="$state_home/config.json"

  if [[ -f "$global_cfg" && ! -L "$global_cfg" ]] && squad_has_jq; then
    if squad_jq -e 'type == "object"' "$global_cfg" >/dev/null 2>&1; then
      global_cfg_summary="$(squad_jq -r '[
        (if has("microskills") then "microskills=" + (.microskills|tostring) else empty end),
        (if has("toolprune") then "toolprune=" + (.toolprune|tostring) else empty end),
        (if has("loopguard") then "loopguard=" + (.loopguard|tostring) else empty end)
      ] | if length == 0 then "present (no mechanism overrides)" else join(", ") end' "$global_cfg" 2>/dev/null || echo "present")"
    else
      global_cfg_summary="present (malformed JSON)"
    fi
  fi

  local plugin_installed_json="null" plugin_enabled_json="null" mkt_registered_json="null"
  case "$SQUAD_TE_REGISTRATION_STATE" in
    configured)
      plugin_installed_json="true"
      plugin_enabled_json="true"
      mkt_registered_json="$([[ "$SQUAD_TE_MKT_REGISTERED" == 1 ]] && echo true || echo null)"
      ;;
    disabled)
      if (( SQUAD_TE_CFG_PLUGIN_PRESENT == 1 )); then
        plugin_installed_json="true"
        plugin_enabled_json="false"
      else
        plugin_installed_json="false"
        plugin_enabled_json="false"
      fi
      mkt_registered_json="$([[ "$SQUAD_TE_MKT_REGISTERED" == 1 ]] && echo true || echo null)"
      ;;
    absent)
      plugin_installed_json="false"
      plugin_enabled_json="false"
      mkt_registered_json="false"
      ;;
  esac

  if (( json_out == 1 )); then
    if ! squad_has_jq; then
      echo "jq (or squad jq) required for --json output" >&2
      return 1
    fi
    squad_jq -n \
      --arg state "$SQUAD_TE_STATE" \
      --arg detail "$SQUAD_TE_STATE_DETAIL" \
      --arg upstream "$SQUAD_TE_UPSTREAM_URL" \
      --arg license "$SQUAD_TE_UPSTREAM_LICENSE" \
      --arg pin "$SQUAD_TE_PINNED_COMMIT" \
      --arg checkout "$checkout" \
      --arg checkout_sha "$SQUAD_TE_CHECKOUT_SHA" \
      --arg ownership_file "$ownership_file" \
      --arg codex_path "${SQUAD_TE_CODEX_BIN:-}" \
      --arg codex_ver "${SQUAD_TE_CODEX_VER:-}" \
      --arg codex_compat "$SQUAD_TE_CODEX_COMPAT" \
      --arg codex_reason "$SQUAD_TE_CODEX_REASON" \
      --arg py_status "$SQUAD_TE_PYTHON_STATUS" \
      --arg py_ver "${SQUAD_TE_PYTHON_VER:-}" \
      --arg reg_state "$SQUAD_TE_REGISTRATION_STATE" \
      --arg plugin_src "${SQUAD_TE_PLUGIN_SOURCE:-}" \
      --arg mkt_src "${SQUAD_TE_MKT_SOURCE:-}" \
      --arg global_cfg "$global_cfg_summary" \
      --argjson owned "$SQUAD_TE_OWNED" \
      --argjson checkout_valid "$SQUAD_TE_CHECKOUT_VALID" \
      --argjson plugin_installed "$plugin_installed_json" \
      --argjson plugin_enabled "$plugin_enabled_json" \
      --argjson mkt_registered "$mkt_registered_json" \
      '{
        state: $state,
        detail: $detail,
        owned_by_devkit: ($owned == 1),
        upstream_repo: $upstream,
        upstream_license: $license,
        pinned_commit: $pin,
        checkout_dir: $checkout,
        checkout_commit: $checkout_sha,
        checkout_valid: ($checkout_valid == 1),
        ownership_file: $ownership_file,
        codex_path: $codex_path,
        codex_version: $codex_ver,
        codex_compatibility: $codex_compat,
        codex_reason: $codex_reason,
        codex_cli_introspected: false,
        python_status: $py_status,
        python_version: $py_ver,
        registration_state: $reg_state,
        plugin_installed: $plugin_installed,
        plugin_enabled: $plugin_enabled,
        plugin_source: $plugin_src,
        marketplace_registered: $mkt_registered,
        marketplace_source: $mkt_src,
        global_config: $global_cfg,
        ephemeral_exec_compatible: false,
        worktree_identity_canonicalized: true
      }'
    return 0
  fi

  printf 'TokenEconomizer status: %s\n' "$SQUAD_TE_STATE"
  printf '  detail:       %s\n' "$SQUAD_TE_STATE_DETAIL"
  printf '  upstream:     %s (%s)\n' "$SQUAD_TE_UPSTREAM_URL" "$SQUAD_TE_UPSTREAM_LICENSE"
  printf '  pinned sha:   %s\n' "$SQUAD_TE_PINNED_COMMIT"
  printf '  checkout:     %s (%s)\n' "$checkout" "${SQUAD_TE_CHECKOUT_SHA:-absent}"
  printf '  ownership:    %s (devkit-owned=%s)\n' "$ownership_file" "$([[ "$SQUAD_TE_OWNED" == 1 ]] && echo yes || echo no)"
  if [[ -n "$SQUAD_TE_CODEX_BIN" && "$SQUAD_TE_CODEX_COMPAT" == "unprobed" ]]; then
    printf '  codex:        unprobed (%s)\n' "$SQUAD_TE_CODEX_REASON"
  else
    printf '  codex:        %s (%s; %s)\n' "${SQUAD_TE_CODEX_VER:-missing}" "$SQUAD_TE_CODEX_COMPAT" "$SQUAD_TE_CODEX_REASON"
  fi
  printf '  python:       %s (%s)\n' "$SQUAD_TE_PYTHON_STATUS" "${SQUAD_TE_PYTHON_VER:-none}"
  printf '  registration: %s (read-only; codex plugin list not queried)\n' "$SQUAD_TE_REGISTRATION_STATE"
  printf '  global cfg:   %s (%s)\n' "$global_cfg" "$global_cfg_summary"
  printf '  ephemeral:    codex exec --ephemeral skips disk rollouts (ephemeral worker cross-session learning unavailable; interactive managers may benefit after /hooks approval)\n'
  printf '  worktrees:    canonicalized by origin remote or git common dir in upstream TokenEconomizer\n'
  return 0
}

cmd_disable() {
  if (( $# > 0 )); then
    case "$1" in
      -h|--help) usage; return 0 ;;
      *) echo "Unknown disable option: $1" >&2; return 2 ;;
    esac
  fi

  if ! squad_te_validate_no_ctrl "$(squad_te_cache_dir)" || ! squad_te_validate_no_ctrl "$(squad_te_codex_home)"; then
    echo "Invalid control characters in cache or CODEX_HOME path" >&2
    return 1
  fi
  require_no_symlinks || return 1
  squad_te_inspect_status introspect
  local checkout ownership_file codex_home
  checkout="$(squad_te_checkout_dir)"
  ownership_file="$(squad_te_ownership_file)"
  codex_home="$(squad_te_codex_home)"

  if (( SQUAD_TE_OWNERSHIP_MALFORMED == 1 )); then
    echo "Refusing to modify state with malformed ownership marker: $ownership_file" >&2
    return 1
  fi

  if (( SQUAD_TE_OWNERSHIP_HOME_MISMATCH == 1 )); then
    echo "Refusing to disable: ownership marker at $ownership_file belongs to a different CODEX_HOME (${SQUAD_TE_OWNERSHIP_CODEX_HOME}) (outside squad-devkit scope for $codex_home)" >&2
    return 1
  fi

  if [[ "$SQUAD_TE_STATE" == "unowned" ]] && (( SQUAD_TE_PLUGIN_INSTALLED == 1 )); then
    echo "Refusing to disable user-owned plugin '$SQUAD_TE_PLUGIN_ID' (${SQUAD_TE_PLUGIN_SOURCE:-unknown})." >&2
    return 1
  fi

  if (( SQUAD_TE_OWNED == 1 )) && [[ "$SQUAD_TE_CODEX_COMPAT" == "missing" || "$SQUAD_TE_CODEX_COMPAT" == "unsupported" ]]; then
    echo "Cannot disable devkit-managed TokenEconomizer plugin: $SQUAD_TE_CODEX_REASON (ownership marker retained)" >&2
    return 1
  fi

  if (( SQUAD_TE_OWNED == 0 && SQUAD_TE_PLUGIN_INSTALLED == 0 )); then
    echo "TokenEconomizer is not installed by squad-devkit; nothing to disable."
    return 0
  fi

  if (( SQUAD_TE_PLUGIN_INSTALLED == 1 )); then
    if (( SQUAD_TE_OWN_PLUGIN == 0 )) || ! squad_te_path_within_checkout "$SQUAD_TE_PLUGIN_SOURCE" "$checkout"; then
      echo "Refusing to disable plugin not owned by squad-devkit (${SQUAD_TE_PLUGIN_SOURCE:-unknown})" >&2
      return 1
    fi
    if ! codex plugin remove "$SQUAD_TE_PLUGIN_ID" --json >/dev/null 2>&1; then
      echo "Failed to remove Codex plugin $SQUAD_TE_PLUGIN_ID (ownership marker retained)" >&2
      return 1
    fi
  fi

  local mkt_owned=false
  if (( SQUAD_TE_OWN_MKT == 1 )); then
    mkt_owned=true
  fi
  write_ownership_file "$ownership_file" "$checkout" "$codex_home" "$mkt_owned" false true "${SQUAD_TE_OWNED_PIN:-$SQUAD_TE_PINNED_COMMIT}" || return 1

  printf 'Disabled devkit-managed TokenEconomizer plugin.\n'
  printf 'Preserved pinned checkout (%s) and learned data (%s).\n' "$checkout" "$(squad_te_state_home)"
  return 0
}

cmd_uninstall() {
  if (( $# > 0 )); then
    case "$1" in
      -h|--help) usage; return 0 ;;
      *) echo "Unknown uninstall option: $1" >&2; return 2 ;;
    esac
  fi

  if ! squad_te_validate_no_ctrl "$(squad_te_cache_dir)" || ! squad_te_validate_no_ctrl "$(squad_te_codex_home)"; then
    echo "Invalid control characters in cache or CODEX_HOME path" >&2
    return 1
  fi
  require_no_symlinks || return 1
  squad_te_inspect_status introspect
  local cache_dir checkout ownership_file codex_home state_home
  cache_dir="$(squad_te_cache_dir)"
  checkout="$(squad_te_checkout_dir)"
  ownership_file="$(squad_te_ownership_file)"
  codex_home="$(squad_te_codex_home)"
  state_home="$(squad_te_state_home)"

  if (( SQUAD_TE_OWNERSHIP_MALFORMED == 1 )); then
    echo "Refusing blanket deletion: malformed ownership marker at $ownership_file" >&2
    return 1
  fi

  if (( SQUAD_TE_OWNERSHIP_HOME_MISMATCH == 1 )); then
    echo "Refusing to uninstall: ownership marker at $ownership_file belongs to a different CODEX_HOME (${SQUAD_TE_OWNERSHIP_CODEX_HOME}) (outside squad-devkit scope for $codex_home)" >&2
    return 1
  fi

  if (( SQUAD_TE_OWNED == 0 )); then
    if (( SQUAD_TE_PLUGIN_INSTALLED == 1 || SQUAD_TE_MKT_REGISTERED == 1 || SQUAD_TE_CHECKOUT_EXISTS == 1 )); then
      echo "No devkit-managed TokenEconomizer installation found; preserved user-owned state."
    else
      echo "TokenEconomizer is not installed by squad-devkit."
    fi
    return 0
  fi

  if [[ "$SQUAD_TE_CODEX_COMPAT" == "missing" || "$SQUAD_TE_CODEX_COMPAT" == "unsupported" ]]; then
    echo "Cannot cleanly verify or unregister devkit-owned Codex entries: $SQUAD_TE_CODEX_REASON" >&2
    return 1
  fi

  local removed_plugin_now=0 mkt_owned=false
  (( SQUAD_TE_OWN_MKT == 1 )) && mkt_owned=true

  if (( SQUAD_TE_PLUGIN_INSTALLED == 1 )); then
    if (( SQUAD_TE_OWN_PLUGIN == 1 )) && squad_te_path_within_checkout "$SQUAD_TE_PLUGIN_SOURCE" "$checkout"; then
      if ! codex plugin remove "$SQUAD_TE_PLUGIN_ID" --json >/dev/null 2>&1; then
        echo "Failed to remove devkit-owned Codex plugin $SQUAD_TE_PLUGIN_ID" >&2
        return 1
      fi
      removed_plugin_now=1
    else
      printf 'Preserved user-owned Codex plugin %s (%s).\n' "$SQUAD_TE_PLUGIN_ID" "${SQUAD_TE_PLUGIN_SOURCE:-unknown}"
    fi
  fi

  local preserve_checkout=0
  if (( SQUAD_TE_MKT_REGISTERED == 1 )); then
    local remaining_json="" other_plugins=""
    if ! remaining_json="$(codex plugin list --json 2>/dev/null)" ||
       ! printf '%s\n' "$remaining_json" | squad_jq -e 'type == "object" and (.installed | type == "array")' >/dev/null 2>&1; then
      if (( removed_plugin_now == 1 )); then
        write_ownership_file "$ownership_file" "$checkout" "$codex_home" "$mkt_owned" false true "${SQUAD_TE_OWNED_PIN:-$SQUAD_TE_PINNED_COMMIT}" || true
      fi
      echo "Failed to query Codex plugins during uninstall; preserving marketplace, checkout, and ownership." >&2
      return 1
    fi
    other_plugins="$(printf '%s\n' "$remaining_json" | squad_jq --arg m "$SQUAD_TE_MARKETPLACE_NAME" \
      '[.installed[] | select(.marketplaceName == $m)] | length')"

    local preserved_mkt=0
    if (( SQUAD_TE_OWN_MKT == 1 )) && [[ "$other_plugins" == "0" ]] &&
       squad_te_path_within_checkout "$SQUAD_TE_MKT_SOURCE" "$checkout"; then
      if ! codex plugin marketplace remove "$SQUAD_TE_MARKETPLACE_NAME" --json >/dev/null 2>&1; then
        if (( removed_plugin_now == 1 )); then
          write_ownership_file "$ownership_file" "$checkout" "$codex_home" true false true "${SQUAD_TE_OWNED_PIN:-$SQUAD_TE_PINNED_COMMIT}" || true
        fi
        echo "Failed to remove devkit-owned Codex marketplace $SQUAD_TE_MARKETPLACE_NAME; preserving checkout and ownership." >&2
        return 1
      fi
    else
      preserved_mkt=1
      printf 'Preserved Codex marketplace %s (%s).\n' "$SQUAD_TE_MARKETPLACE_NAME" "${SQUAD_TE_MKT_SOURCE:-shared/user-owned}"
    fi

    if (( preserved_mkt == 1 )) && [[ -n "$SQUAD_TE_MKT_SOURCE" ]] &&
       squad_te_path_within_checkout "$SQUAD_TE_MKT_SOURCE" "$checkout"; then
      preserve_checkout=1
    fi
  fi

  if (( preserve_checkout == 1 )); then
    if (( removed_plugin_now == 1 )); then
      write_ownership_file "$ownership_file" "$checkout" "$codex_home" "$mkt_owned" false true "${SQUAD_TE_OWNED_PIN:-$SQUAD_TE_PINNED_COMMIT}" || return 1
    fi
    printf 'Preserved shared checkout (%s) and ownership marker (%s) referenced by Codex marketplace %s.\n' \
      "$checkout" "$ownership_file" "$SQUAD_TE_MARKETPLACE_NAME"
    printf 'Preserved learned data and config under %s.\n' "$state_home"
    return 0
  fi

  local leftover
  for leftover in "$cache_dir"/upstream.staging.* "$cache_dir"/upstream.backup.*; do
    if [[ -d "$leftover" && ! -L "$leftover" ]]; then
      rm -rf "${leftover:?}"
    fi
  done
  if [[ -d "$checkout" && ! -L "$checkout" ]]; then
    rm -rf "${checkout:?}"
  fi
  if [[ -f "$ownership_file" && ! -L "$ownership_file" ]]; then
    rm -f "$ownership_file"
  fi
  rmdir "$cache_dir" 2>/dev/null || true

  printf 'Uninstalled devkit-managed TokenEconomizer checkout and registration.\n'
  printf 'Preserved learned data and config under %s.\n' "$state_home"
  return 0
}

subcommand="${1:-help}"
if (( $# > 0 )); then
  shift
fi

case "$subcommand" in
  install) cmd_install "$@" ;;
  status) cmd_status "$@" ;;
  disable) cmd_disable "$@" ;;
  uninstall) cmd_uninstall "$@" ;;
  help|-h|--help) usage ;;
  *)
    echo "Unknown command: $subcommand" >&2
    usage >&2
    exit 2
    ;;
esac
