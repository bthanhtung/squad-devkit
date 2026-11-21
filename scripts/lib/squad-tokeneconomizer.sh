#!/usr/bin/env bash
# Shared helper functions for optional bounded TokenEconomizer Codex integration.

if declare -F squad_te_pinned_commit >/dev/null 2>&1; then
  return 0 2>/dev/null || true
fi

_squad_te_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./squad-jq.sh
source "$_squad_te_lib_dir/squad-jq.sh"

SQUAD_TE_UPSTREAM_URL="https://github.com/microsoft/TokenEconomizer.git"
SQUAD_TE_PINNED_COMMIT="583fff78bf504b59d542f953c31e87d01d02ab42"
SQUAD_TE_UPSTREAM_LICENSE="Apache-2.0"
SQUAD_TE_MARKETPLACE_NAME="tokeneconomizer"
SQUAD_TE_PLUGIN_ID="tokeneconomizer@tokeneconomizer"
SQUAD_TE_CODEX_MIN_HOOKS="0.141.0"
SQUAD_TE_CODEX_MIN_TESTED="0.153.1"
SQUAD_TE_CODEX_MAX_TESTED="0.164.0"

squad_te_pinned_commit() { printf '%s\n' "$SQUAD_TE_PINNED_COMMIT"; }
squad_te_cache_dir() { printf '%s\n' "${SQUAD_TOKENECONOMIZER_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/squad-devkit/tokeneconomizer}"; }
squad_te_checkout_dir() { printf '%s/upstream\n' "$(squad_te_cache_dir)"; }
squad_te_ownership_file() { printf '%s/ownership.json\n' "$(squad_te_cache_dir)"; }
squad_te_codex_home() { printf '%s\n' "${CODEX_HOME:-$HOME/.codex}"; }
squad_te_state_home() { printf '%s\n' "${TOKENECONOMIZER_HOME:-$HOME/.tokeneconomizer}"; }

squad_te_validate_no_ctrl() {
  local value="${1:-}"
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* && "$value" != *$'\t'* ]]
}

# Returns 0 and prints the first devkit-managed path that is a symlink (including broken symlinks).
squad_te_symlink_target() {
  local path
  for path in "$(squad_te_cache_dir)" "$(squad_te_checkout_dir)" "$(squad_te_ownership_file)"; do
    if [[ -L "$path" ]]; then
      printf '%s\n' "$path"
      return 0
    fi
  done
  return 1
}

squad_te_realpath() {
  local path="${1:-}"
  [[ -n "$path" ]] || return 1
  local suffix="" cur="$path"
  while [[ ! -d "$cur" && "$cur" != "/" && "$cur" != "." ]]; do
    suffix="/$(basename "$cur")$suffix"
    cur="$(dirname "$cur")"
  done
  if [[ -d "$cur" ]]; then
    local base=""
    base="$(cd "$cur" 2>/dev/null && pwd -P)" || base="$cur"
    printf '%s%s\n' "${base%/}" "$suffix"
  else
    printf '%s\n' "$path"
  fi
}

squad_te_path_within_checkout() {
  local candidate="${1:-}" checkout="${2:-}"
  [[ -n "$candidate" && -n "$checkout" ]] || return 1
  local real_cand real_check
  real_cand="$(squad_te_realpath "$candidate")"
  real_check="$(squad_te_realpath "$checkout")"
  [[ "$real_cand" == "$real_check" || "$real_cand" == "$real_check/"* ]]
}

# Compare two X.Y.Z versions: prints -1, 0, or 1.
squad_te_semver_cmp() {
  local a1 a2 a3 b1 b2 b3
  IFS='.' read -r a1 a2 a3 <<<"$1"
  IFS='.' read -r b1 b2 b3 <<<"$2"
  local lhs=$(( 10#${a1:-0} * 1000000 + 10#${a2:-0} * 1000 + 10#${a3:-0} ))
  local rhs=$(( 10#${b1:-0} * 1000000 + 10#${b2:-0} * 1000 + 10#${b3:-0} ))
  if (( lhs < rhs )); then printf '%s\n' -1
  elif (( lhs > rhs )); then printf '%s\n' 1
  else printf '%s\n' 0
  fi
}

# Mirrors upstream plugin/scripts/te-hook Python selection (TE_PYTHON or python3..python >= 3.10).
# Sets SQUAD_TE_PYTHON_BIN, SQUAD_TE_PYTHON_VER, SQUAD_TE_PYTHON_STATUS (ok|too_old|missing|invalid_env).
squad_te_probe_python() {
  SQUAD_TE_PYTHON_BIN=""
  SQUAD_TE_PYTHON_VER=""
  SQUAD_TE_PYTHON_STATUS="missing"
  local probe='import sys; print("%d.%d.%d" % sys.version_info[:3]); sys.exit(0 if sys.version_info >= (3, 10) else 1)'
  local py out rc

  if [[ -n "${TE_PYTHON:-}" ]]; then
    if ! command -v "$TE_PYTHON" >/dev/null 2>&1 && [[ ! -x "$TE_PYTHON" ]]; then
      SQUAD_TE_PYTHON_STATUS="invalid_env"
      return 1
    fi
    rc=0
    out="$("$TE_PYTHON" -E -S -c "$probe" </dev/null 2>/dev/null)" || rc=$?
    SQUAD_TE_PYTHON_VER="$(printf '%s' "$out" | head -n 1)"
    if (( rc == 0 )); then
      SQUAD_TE_PYTHON_BIN="$TE_PYTHON"
      SQUAD_TE_PYTHON_STATUS="ok"
      return 0
    fi
    SQUAD_TE_PYTHON_STATUS="too_old"
    return 1
  fi

  local old_bin="" old_ver=""
  for py in python3 python3.15 python3.14 python3.13 python3.12 python3.11 python3.10 python; do
    command -v "$py" >/dev/null 2>&1 || continue
    rc=0
    out="$("$py" -E -S -c "$probe" </dev/null 2>/dev/null)" || rc=$?
    if (( rc == 0 )); then
      SQUAD_TE_PYTHON_BIN="$(command -v "$py")"
      SQUAD_TE_PYTHON_VER="$(printf '%s' "$out" | head -n 1)"
      SQUAD_TE_PYTHON_STATUS="ok"
      return 0
    elif (( rc == 1 )) && [[ -z "$old_bin" ]]; then
      old_bin="$(command -v "$py")"
      old_ver="$(printf '%s' "$out" | head -n 1)"
    fi
  done

  if [[ -n "$old_bin" ]]; then
    SQUAD_TE_PYTHON_BIN="$old_bin"
    SQUAD_TE_PYTHON_VER="$old_ver"
    SQUAD_TE_PYTHON_STATUS="too_old"
  fi
  return 1
}

# Probes Codex CLI. Mode "readonly" discovers the binary via PATH without executing
# codex (so status/doctor never create CODEX_HOME runtime artifacts); mode "introspect"
# checks codex --version and queries official plugin JSON list commands for mutations.
squad_te_probe_codex() {
  local mode="${1:-readonly}"
  SQUAD_TE_CODEX_BIN=""
  SQUAD_TE_CODEX_VER=""
  SQUAD_TE_CODEX_COMPAT="missing"
  SQUAD_TE_CODEX_REASON="codex CLI not found on PATH"
  SQUAD_TE_CODEX_PLUGINS_JSON='{"installed":[],"available":[]}'
  SQUAD_TE_CODEX_MKT_JSON='{"marketplaces":[]}'

  SQUAD_TE_CODEX_BIN="$(command -v codex 2>/dev/null)" || return 1

  if [[ "$mode" != "introspect" ]]; then
    SQUAD_TE_CODEX_VER="unprobed"
    SQUAD_TE_CODEX_COMPAT="unprobed"
    SQUAD_TE_CODEX_REASON="codex CLI found at $SQUAD_TE_CODEX_BIN (version/compatibility unprobed in read-only mode)"
    return 0
  fi

  local ver_out=""
  ver_out="$(codex --version 2>&1 || true)"
  if [[ "$ver_out" =~ codex-cli[[:space:]]+([0-9]+\.[0-9]+\.[0-9]+) ]]; then
    SQUAD_TE_CODEX_VER="${BASH_REMATCH[1]}"
  elif [[ "$ver_out" =~ ([0-9]+\.[0-9]+\.[0-9]+) ]]; then
    SQUAD_TE_CODEX_VER="${BASH_REMATCH[1]}"
  else
    SQUAD_TE_CODEX_COMPAT="unsupported"
    SQUAD_TE_CODEX_REASON="could not parse codex --version output"
    return 1
  fi

  if (( $(squad_te_semver_cmp "$SQUAD_TE_CODEX_VER" "$SQUAD_TE_CODEX_MIN_HOOKS") < 0 )); then
    SQUAD_TE_CODEX_COMPAT="unsupported"
    SQUAD_TE_CODEX_REASON="codex $SQUAD_TE_CODEX_VER < $SQUAD_TE_CODEX_MIN_HOOKS (hooks unsupported)"
    return 1
  fi

  if ! squad_has_jq; then
    SQUAD_TE_CODEX_COMPAT="unsupported"
    SQUAD_TE_CODEX_REASON="jq (or squad jq) required to probe codex plugin JSON"
    return 1
  fi

  local plugins_json="" mkt_json=""
  if ! plugins_json="$(codex plugin list --json 2>/dev/null)" ||
     ! printf '%s\n' "$plugins_json" | squad_jq -e 'type == "object" and (.installed | type == "array")' >/dev/null 2>&1; then
    SQUAD_TE_CODEX_COMPAT="unsupported"
    SQUAD_TE_CODEX_REASON="codex $SQUAD_TE_CODEX_VER failed or lacked expected 'codex plugin list --json' contract"
    return 1
  fi

  if ! mkt_json="$(codex plugin marketplace list --json 2>/dev/null)" ||
     ! printf '%s\n' "$mkt_json" | squad_jq -e 'type == "object" and (.marketplaces | type == "array")' >/dev/null 2>&1; then
    SQUAD_TE_CODEX_COMPAT="unsupported"
    SQUAD_TE_CODEX_REASON="codex $SQUAD_TE_CODEX_VER failed or lacked expected 'codex plugin marketplace list --json' contract"
    return 1
  fi

  SQUAD_TE_CODEX_PLUGINS_JSON="$plugins_json"
  SQUAD_TE_CODEX_MKT_JSON="$mkt_json"

  if (( $(squad_te_semver_cmp "$SQUAD_TE_CODEX_VER" "$SQUAD_TE_CODEX_MIN_TESTED") >= 0 )) &&
     (( $(squad_te_semver_cmp "$SQUAD_TE_CODEX_VER" "$SQUAD_TE_CODEX_MAX_TESTED") <= 0 )); then
    SQUAD_TE_CODEX_COMPAT="tested"
    SQUAD_TE_CODEX_REASON="codex $SQUAD_TE_CODEX_VER within upstream tested range ($SQUAD_TE_CODEX_MIN_TESTED..$SQUAD_TE_CODEX_MAX_TESTED)"
  elif (( $(squad_te_semver_cmp "$SQUAD_TE_CODEX_VER" "$SQUAD_TE_CODEX_MAX_TESTED") > 0 )); then
    SQUAD_TE_CODEX_COMPAT="experimental"
    SQUAD_TE_CODEX_REASON="codex $SQUAD_TE_CODEX_VER > upstream tested $SQUAD_TE_CODEX_MAX_TESTED (plugin CLI probed ok; hooks/transcript unverified)"
  else
    SQUAD_TE_CODEX_COMPAT="experimental"
    SQUAD_TE_CODEX_REASON="codex $SQUAD_TE_CODEX_VER < upstream tested $SQUAD_TE_CODEX_MIN_TESTED (experimental)"
  fi
  return 0
}

squad_te_checkout_clean() {
  local checkout="${1:-}"
  [[ -d "$checkout" && ! -L "$checkout" && -d "$checkout/.git" && ! -L "$checkout/.git" ]] || return 1
  command -v git >/dev/null 2>&1 || return 1
  GIT_OPTIONAL_LOCKS=0 git -C "$checkout" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  local st=""
  st="$(GIT_OPTIONAL_LOCKS=0 git -C "$checkout" status --porcelain --untracked-files=all 2>/dev/null || printf 'ERR')"
  [[ -z "$st" ]]
}

squad_te_checkout_valid() {
  local checkout="${1:-}" head_sha=""
  squad_te_checkout_clean "$checkout" || return 1
  head_sha="$(GIT_OPTIONAL_LOCKS=0 git -C "$checkout" rev-parse HEAD 2>/dev/null || true)"
  [[ "$head_sha" == "$SQUAD_TE_PINNED_COMMIT" ]] || return 1
  local rel
  for rel in \
    ".claude-plugin/marketplace.json" \
    "plugin/.codex-plugin/plugin.json" \
    "plugin/hooks/codex-hooks.json" \
    "plugin/scripts/te-hook" \
    "plugin/scripts/te_bootstrap.py" \
    "LICENSE"; do
    [[ -f "$checkout/$rel" && ! -L "$checkout/$rel" ]] || return 1
  done
  return 0
}

# Read documented sections from $CODEX_HOME/config.toml conservatively without mutating or calling codex plugin list.
squad_te_read_local_codex_config() {
  local cfg_file="$1"
  SQUAD_TE_CFG_MKT_PRESENT=0
  SQUAD_TE_CFG_MKT_SOURCE=""
  SQUAD_TE_CFG_PLUGIN_PRESENT=0
  SQUAD_TE_CFG_PLUGIN_ENABLED="unknown"
  [[ -f "$cfg_file" && ! -L "$cfg_file" ]] || return 0

  local parsed=""
  parsed="$(awk -v mkt="$SQUAD_TE_MARKETPLACE_NAME" -v pid="$SQUAD_TE_PLUGIN_ID" '
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    function unquote(s) {
      s = trim(s)
      if ((substr(s,1,1) == "\"" && substr(s,length(s),1) == "\"") ||
          (substr(s,1,1) == "\x27" && substr(s,length(s),1) == "\x27")) {
        return substr(s, 2, length(s)-2)
      }
      return s
    }
    /^[[:space:]]*($|#)/ { next }
    /^[[:space:]]*\[/ {
      sec = trim($0)
      if (sec ~ /^\[.*\][[:space:]]*(#.*)?$/) {
        sub(/[[:space:]]*#.*$/, "", sec)
        sec = trim(sec)
        in_mkt = (sec == "[marketplaces." mkt "]")
        in_plug = (sec == "[plugins.\"" pid "\"]" || sec == "[plugins.\x27" pid "\x27]")
        if (in_mkt) mkt_present = 1
        if (in_plug) plug_present = 1
      } else {
        in_mkt = 0; in_plug = 0
      }
      next
    }
    in_mkt && /^[[:space:]]*source[[:space:]]*=/ {
      val = $0; sub(/^[^=]*=/, "", val); val = trim(val)
      if (val ~ /^"[^"]*"([[:space:]]*#.*)?$/ || val ~ /^\x27[^\x27]*\x27([[:space:]]*#.*)?$/) {
        match(val, /^"[^"]*"|^\x27[^\x27]*\x27/)
        mkt_src = unquote(substr(val, RSTART, RLENGTH))
      }
    }
    in_plug && /^[[:space:]]*enabled[[:space:]]*=/ {
      val = $0; sub(/^[^=]*=/, "", val); sub(/[[:space:]]*#.*$/, "", val); val = trim(val)
      if (val == "true" || val == "false") plug_enabled = val
    }
    END {
      printf "mkt=%d\n", mkt_present + 0
      printf "mkt_src=%s\n", mkt_src
      printf "plug=%d\n", plug_present + 0
      printf "plug_enabled=%s\n", (plug_enabled == "" ? "unknown" : plug_enabled)
    }
  ' "$cfg_file" 2>/dev/null || true)"

  local line
  while IFS= read -r line; do
    case "$line" in
      mkt=*) SQUAD_TE_CFG_MKT_PRESENT="${line#mkt=}" ;;
      mkt_src=*) SQUAD_TE_CFG_MKT_SOURCE="${line#mkt_src=}" ;;
      plug=*) SQUAD_TE_CFG_PLUGIN_PRESENT="${line#plug=}" ;;
      plug_enabled=*) SQUAD_TE_CFG_PLUGIN_ENABLED="${line#plug_enabled=}" ;;
    esac
  done <<<"$parsed"
}

# Status inspection: "readonly" (default, for status/doctor) never runs codex plugin list;
# "introspect" (for install/disable/uninstall) queries official codex plugin list JSON.
squad_te_inspect_status() {
  local mode="${1:-readonly}"
  local checkout ownership_file codex_home
  checkout="$(squad_te_checkout_dir)"
  ownership_file="$(squad_te_ownership_file)"
  codex_home="$(squad_te_codex_home)"

  SQUAD_TE_STATE="absent"
  SQUAD_TE_STATE_DETAIL=""
  SQUAD_TE_SYMLINK_ERROR=""
  SQUAD_TE_OWNED=0
  SQUAD_TE_OWNERSHIP_MALFORMED=0
  SQUAD_TE_OWNERSHIP_MALFORMED_REASON=""
  SQUAD_TE_OWNERSHIP_HOME_MISMATCH=0
  SQUAD_TE_OWNERSHIP_CODEX_HOME=""
  SQUAD_TE_OWN_PLUGIN=0
  SQUAD_TE_OWN_MKT=0
  SQUAD_TE_OWNED_PIN=""
  SQUAD_TE_DISABLED_FLAG=0
  SQUAD_TE_CHECKOUT_EXISTS=0
  SQUAD_TE_CHECKOUT_CLEAN=0
  SQUAD_TE_CHECKOUT_SHA=""
  SQUAD_TE_CHECKOUT_VALID=0
  SQUAD_TE_PLUGIN_INSTALLED=0
  SQUAD_TE_PLUGIN_ENABLED=0
  SQUAD_TE_PLUGIN_SOURCE=""
  SQUAD_TE_MKT_REGISTERED=0
  SQUAD_TE_MKT_SOURCE=""
  SQUAD_TE_REGISTRATION_STATE="unknown"
  SQUAD_TE_CLI_INTROSPECTED=0

  local bad_link=""
  if bad_link="$(squad_te_symlink_target)"; then
    SQUAD_TE_SYMLINK_ERROR="$bad_link"
    SQUAD_TE_STATE="unsupported"
    SQUAD_TE_STATE_DETAIL="refusing symlink at devkit-managed path: $bad_link"
    squad_te_probe_python || true
    squad_te_probe_codex "$mode" || true
    return 0
  fi

  if [[ -e "$checkout" ]]; then
    SQUAD_TE_CHECKOUT_EXISTS=1
    if [[ -d "$checkout/.git" && ! -L "$checkout/.git" ]] && command -v git >/dev/null 2>&1; then
      SQUAD_TE_CHECKOUT_SHA="$(GIT_OPTIONAL_LOCKS=0 git -C "$checkout" rev-parse HEAD 2>/dev/null || true)"
    fi
    squad_te_checkout_clean "$checkout" && SQUAD_TE_CHECKOUT_CLEAN=1 || true
    squad_te_checkout_valid "$checkout" && SQUAD_TE_CHECKOUT_VALID=1 || true
  fi

  if [[ -e "$ownership_file" ]]; then
    if [[ -f "$ownership_file" ]] && squad_has_jq &&
       squad_jq -e 'type == "object" and .managed_by == "squad-devkit"' "$ownership_file" >/dev/null 2>&1; then
      local marker_codex_home="" canon_marker_home="" canon_codex_home=""
      if ! squad_jq -e '(.codex_home | type == "string") and (.codex_home | length > 0)' "$ownership_file" >/dev/null 2>&1; then
        SQUAD_TE_OWNERSHIP_MALFORMED=1
        SQUAD_TE_OWNERSHIP_MALFORMED_REASON="missing or invalid codex_home"
      else
        marker_codex_home="$(squad_jq -r '.codex_home' "$ownership_file" 2>/dev/null || true)"
        if [[ -z "$marker_codex_home" || "$marker_codex_home" != /* ]] ||
           ! squad_te_validate_no_ctrl "$marker_codex_home"; then
          SQUAD_TE_OWNERSHIP_MALFORMED=1
          SQUAD_TE_OWNERSHIP_MALFORMED_REASON="missing or invalid codex_home"
        else
          canon_marker_home="$(squad_te_realpath "$marker_codex_home" 2>/dev/null || true)"
          if [[ -z "$canon_marker_home" ]]; then
            SQUAD_TE_OWNERSHIP_MALFORMED=1
            SQUAD_TE_OWNERSHIP_MALFORMED_REASON="missing or invalid codex_home"
          elif squad_te_validate_no_ctrl "$codex_home"; then
            canon_codex_home="$(squad_te_realpath "$codex_home" 2>/dev/null || true)"
            if [[ -z "$canon_codex_home" || "$canon_marker_home" != "$canon_codex_home" ]]; then
              SQUAD_TE_OWNERSHIP_HOME_MISMATCH=1
              SQUAD_TE_OWNERSHIP_CODEX_HOME="$marker_codex_home"
            else
              SQUAD_TE_OWNED=1
              [[ "$(squad_jq -r '.plugin_added_by_devkit // false' "$ownership_file" 2>/dev/null || echo false)" == "true" ]] && SQUAD_TE_OWN_PLUGIN=1
              [[ "$(squad_jq -r '.marketplace_added_by_devkit // false' "$ownership_file" 2>/dev/null || echo false)" == "true" ]] && SQUAD_TE_OWN_MKT=1
              [[ "$(squad_jq -r '.disabled // false' "$ownership_file" 2>/dev/null || echo false)" == "true" ]] && SQUAD_TE_DISABLED_FLAG=1
              SQUAD_TE_OWNED_PIN="$(squad_jq -r '.pinned_commit // empty' "$ownership_file" 2>/dev/null || true)"
            fi
          fi
        fi
      fi
    else
      SQUAD_TE_OWNERSHIP_MALFORMED=1
    fi
  fi

  local effective_mode="$mode"
  if (( SQUAD_TE_OWNERSHIP_MALFORMED == 1 || SQUAD_TE_OWNERSHIP_HOME_MISMATCH == 1 )); then
    effective_mode="readonly"
  fi

  squad_te_probe_python || true
  squad_te_probe_codex "$effective_mode" || true

  if [[ "$effective_mode" == "introspect" ]] &&
     [[ "$SQUAD_TE_CODEX_COMPAT" == "tested" || "$SQUAD_TE_CODEX_COMPAT" == "experimental" ]] &&
     squad_has_jq; then
    SQUAD_TE_CLI_INTROSPECTED=1
    local plugin_row="" mkt_row=""
    plugin_row="$(printf '%s\n' "$SQUAD_TE_CODEX_PLUGINS_JSON" | squad_jq -c --arg pid "$SQUAD_TE_PLUGIN_ID" \
      '.installed[] | select(.pluginId == $pid)' 2>/dev/null | head -n 1 || true)"
    if [[ -n "$plugin_row" ]]; then
      SQUAD_TE_PLUGIN_INSTALLED=1
      if [[ "$(printf '%s\n' "$plugin_row" | squad_jq -r 'if has("enabled") then .enabled else true end' 2>/dev/null || echo true)" == "true" ]]; then
        SQUAD_TE_PLUGIN_ENABLED=1
      fi
      SQUAD_TE_PLUGIN_SOURCE="$(printf '%s\n' "$plugin_row" | squad_jq -r '.source.path // .marketplaceSource.source // empty' 2>/dev/null || true)"
    fi

    mkt_row="$(printf '%s\n' "$SQUAD_TE_CODEX_MKT_JSON" | squad_jq -c --arg m "$SQUAD_TE_MARKETPLACE_NAME" \
      '.marketplaces[] | select(.name == $m)' 2>/dev/null | head -n 1 || true)"
    if [[ -n "$mkt_row" ]]; then
      SQUAD_TE_MKT_REGISTERED=1
      SQUAD_TE_MKT_SOURCE="$(printf '%s\n' "$mkt_row" | squad_jq -r '.marketplaceSource.source // .root // empty' 2>/dev/null || true)"
    fi

    if (( SQUAD_TE_PLUGIN_INSTALLED == 1 )); then
      (( SQUAD_TE_PLUGIN_ENABLED == 1 )) && SQUAD_TE_REGISTRATION_STATE="enabled_via_cli" || SQUAD_TE_REGISTRATION_STATE="disabled_via_cli"
    else
      SQUAD_TE_REGISTRATION_STATE="absent_via_cli"
    fi
  else
    squad_te_read_local_codex_config "$codex_home/config.toml"
    SQUAD_TE_MKT_REGISTERED="$SQUAD_TE_CFG_MKT_PRESENT"
    SQUAD_TE_MKT_SOURCE="$SQUAD_TE_CFG_MKT_SOURCE"
    if (( SQUAD_TE_CFG_PLUGIN_PRESENT == 1 )); then
      SQUAD_TE_PLUGIN_INSTALLED=1
      if [[ "$SQUAD_TE_CFG_PLUGIN_ENABLED" == "true" ]]; then
        SQUAD_TE_PLUGIN_ENABLED=1
        SQUAD_TE_REGISTRATION_STATE="configured"
      elif [[ "$SQUAD_TE_CFG_PLUGIN_ENABLED" == "false" ]]; then
        SQUAD_TE_PLUGIN_ENABLED=0
        SQUAD_TE_REGISTRATION_STATE="disabled"
      else
        SQUAD_TE_REGISTRATION_STATE="unknown"
      fi
      [[ -n "$SQUAD_TE_MKT_SOURCE" ]] && SQUAD_TE_PLUGIN_SOURCE="$SQUAD_TE_MKT_SOURCE"
    elif (( SQUAD_TE_OWNED == 0 && SQUAD_TE_CFG_MKT_PRESENT == 0 )); then
      SQUAD_TE_REGISTRATION_STATE="absent"
    elif (( SQUAD_TE_DISABLED_FLAG == 1 || SQUAD_TE_OWN_PLUGIN == 0 )); then
      SQUAD_TE_REGISTRATION_STATE="disabled"
    else
      SQUAD_TE_REGISTRATION_STATE="unknown"
    fi
  fi

  local plugin_matches_devkit=0
  if [[ "$mode" == "introspect" ]]; then
    if (( SQUAD_TE_PLUGIN_INSTALLED == 1 && SQUAD_TE_OWNED == 1 )) &&
       squad_te_path_within_checkout "$SQUAD_TE_PLUGIN_SOURCE" "$checkout"; then
      plugin_matches_devkit=1
    fi
  else
    if (( SQUAD_TE_OWNED == 1 )); then
      if [[ -z "$SQUAD_TE_MKT_SOURCE" ]] || squad_te_path_within_checkout "$SQUAD_TE_MKT_SOURCE" "$checkout"; then
        plugin_matches_devkit=1
      fi
    fi
  fi

  if (( SQUAD_TE_OWNERSHIP_MALFORMED == 1 )); then
    SQUAD_TE_STATE="unsupported"
    if [[ -n "$SQUAD_TE_OWNERSHIP_MALFORMED_REASON" ]]; then
      SQUAD_TE_STATE_DETAIL="malformed devkit ownership marker at $ownership_file ($SQUAD_TE_OWNERSHIP_MALFORMED_REASON)"
    else
      SQUAD_TE_STATE_DETAIL="malformed devkit ownership marker at $ownership_file"
    fi
  elif ! squad_te_validate_no_ctrl "$codex_home"; then
    SQUAD_TE_STATE="unsupported"
    SQUAD_TE_STATE_DETAIL="invalid control characters in CODEX_HOME"
  elif (( SQUAD_TE_OWNERSHIP_HOME_MISMATCH == 1 )); then
    SQUAD_TE_STATE="unowned"
    SQUAD_TE_STATE_DETAIL="ownership marker at $ownership_file belongs to a different CODEX_HOME (${SQUAD_TE_OWNERSHIP_CODEX_HOME}); outside squad-devkit scope for $codex_home"
  elif (( SQUAD_TE_OWNED == 0 && SQUAD_TE_CHECKOUT_EXISTS == 0 && SQUAD_TE_PLUGIN_INSTALLED == 0 && SQUAD_TE_MKT_REGISTERED == 0 )); then
    SQUAD_TE_STATE="absent"
    SQUAD_TE_STATE_DETAIL="not installed; opt-in via squad-tokeneconomizer install"
  elif (( SQUAD_TE_PLUGIN_INSTALLED == 1 && plugin_matches_devkit == 0 )); then
    SQUAD_TE_STATE="unowned"
    SQUAD_TE_STATE_DETAIL="registered outside squad-devkit (${SQUAD_TE_PLUGIN_SOURCE:-unknown source}); devkit will not modify it"
  elif (( SQUAD_TE_MKT_REGISTERED == 1 )) &&
       { (( SQUAD_TE_OWNED == 0 )) || { [[ -n "$SQUAD_TE_MKT_SOURCE" ]] && ! squad_te_path_within_checkout "$SQUAD_TE_MKT_SOURCE" "$checkout"; }; }; then
    SQUAD_TE_STATE="unowned"
    SQUAD_TE_STATE_DETAIL="marketplace registered outside squad-devkit (${SQUAD_TE_MKT_SOURCE:-unknown source})"
  elif (( SQUAD_TE_OWNED == 0 && SQUAD_TE_CHECKOUT_EXISTS == 1 )); then
    SQUAD_TE_STATE="unowned"
    SQUAD_TE_STATE_DETAIL="unowned directory at $checkout (missing devkit ownership marker)"
  elif (( SQUAD_TE_DISABLED_FLAG == 1 )) && { [[ "$mode" != "introspect" ]] || (( SQUAD_TE_PLUGIN_INSTALLED == 0 )); }; then
    SQUAD_TE_STATE="disabled"
    SQUAD_TE_STATE_DETAIL="disabled; pinned checkout preserved at $checkout"
  elif (( SQUAD_TE_PLUGIN_INSTALLED == 1 && SQUAD_TE_PLUGIN_ENABLED == 0 )); then
    SQUAD_TE_STATE="disabled"
    SQUAD_TE_STATE_DETAIL="plugin registered in Codex but disabled"
  elif [[ "$SQUAD_TE_CODEX_COMPAT" == "missing" || "$SQUAD_TE_CODEX_COMPAT" == "unsupported" ]]; then
    SQUAD_TE_STATE="unsupported"
    SQUAD_TE_STATE_DETAIL="$SQUAD_TE_CODEX_REASON"
  elif [[ "$SQUAD_TE_PYTHON_STATUS" != "ok" ]]; then
    SQUAD_TE_STATE="unsupported"
    if [[ -n "$SQUAD_TE_PYTHON_VER" ]]; then
      SQUAD_TE_STATE_DETAIL="Python >= 3.10 required by TokenEconomizer (found $SQUAD_TE_PYTHON_VER; set TE_PYTHON)"
    else
      SQUAD_TE_STATE_DETAIL="Python >= 3.10 not found on PATH (set TE_PYTHON)"
    fi
  elif (( SQUAD_TE_CHECKOUT_VALID == 0 )); then
    SQUAD_TE_STATE="unsupported"
    if (( SQUAD_TE_CHECKOUT_EXISTS == 1 && SQUAD_TE_CHECKOUT_CLEAN == 0 )); then
      SQUAD_TE_STATE_DETAIL="pinned checkout is dirty or has untracked files at $checkout"
    else
      SQUAD_TE_STATE_DETAIL="pinned checkout invalid or commit mismatch at $checkout (got ${SQUAD_TE_CHECKOUT_SHA:-none}, expected $SQUAD_TE_PINNED_COMMIT)"
    fi
  elif [[ "$mode" == "introspect" ]] && (( SQUAD_TE_PLUGIN_INSTALLED == 0 )); then
    SQUAD_TE_STATE="disabled"
    SQUAD_TE_STATE_DETAIL="devkit checkout present at $checkout, plugin not registered in Codex"
  elif (( SQUAD_TE_OWN_PLUGIN == 0 )); then
    SQUAD_TE_STATE="disabled"
    SQUAD_TE_STATE_DETAIL="disabled; pinned checkout preserved at $checkout"
  else
    local reg_note=""
    if [[ "$SQUAD_TE_REGISTRATION_STATE" == "configured" ]]; then
      reg_note="local config entry present"
    elif [[ "$SQUAD_TE_REGISTRATION_STATE" == "enabled_via_cli" ]]; then
      reg_note="registered in Codex CLI"
    else
      reg_note="live Codex registration unknown in read-only mode"
    fi
    SQUAD_TE_STATE="registered_unverified"
    SQUAD_TE_STATE_DETAIL="$SQUAD_TE_CODEX_REASON; $reg_note; interactive Codex /hooks approval unverified"
  fi
  return 0
}

# Doctor output helper. Optional plugin must never make ordinary doctor fail.
squad_te_doctor_report() {
  squad_te_inspect_status readonly
  printf 'Optional Integrations:\n'
  case "$SQUAD_TE_STATE" in
    absent|disabled)
      printf '  [OPTIONAL] %-16s (%s)\n' "tokeneconomizer" "$SQUAD_TE_STATE_DETAIL"
      ;;
    registered_unverified)
      printf '  [INFO]     %-16s (registered, unverified: %s)\n' "tokeneconomizer" "$SQUAD_TE_STATE_DETAIL"
      printf '  [INFO]     %-16s interactive Codex managers may benefit after /hooks approval; ephemeral codex exec workers cannot do SessionEnd cross-session learning\n' "tokeneconomizer"
      ;;
    unsupported)
      printf '  [WARN]     %-16s (unsupported: %s)\n' "tokeneconomizer" "$SQUAD_TE_STATE_DETAIL"
      ;;
    unowned)
      printf '  [INFO]     %-16s (%s)\n' "tokeneconomizer" "$SQUAD_TE_STATE_DETAIL"
      ;;
  esac
  printf '\n'
  return 0
}
