#!/usr/bin/env bash
# Isolated fake-CLI smoke test for scripts/squad-tokeneconomizer.sh and doctor integration.
set -euo pipefail

unset HC_TERMINAL_ID HC_TERMINAL_SOCKET HC_SCOPE
unset SQUAD_DEVKIT_ORCA_TERMINAL ORCA_PANE_KEY ORCA_CLI_COMMAND ORCA_DEV_REPO_ROOT
unset SQUAD_DEVKIT_WORKSPACE SQUAD_WORKTREE_WORKSPACE SQUAD_MANAGER_ID SQUAD_DEVKIT_YOLO
unset CODEX_HOME CLAUDE_CONFIG_DIR TE_PYTHON TOKENECONOMIZER_HOME
unset SQUAD_TOKENECONOMIZER_CACHE_DIR

trap 'echo "Failed at line $LINENO: $BASH_COMMAND" >&2' ERR

fail() {
  echo "Assertion failed at line ${BASH_LINENO[0]}" >&2
  exit 1
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temp_dir="$(mktemp -d /tmp/squad-te-smoke.XXXXXX)"
cleanup() {
  rm -rf "$temp_dir"
}
trap cleanup EXIT

pinned_sha="583fff78bf504b59d542f953c31e87d01d02ab42"
upstream_url="https://github.com/microsoft/TokenEconomizer.git"

# Regression fixture: place a sentinel claude on incoming PATH before isolation setup
# so symlink population and stub creation are always tested against a preexisting claude.
sentinel_dir="$temp_dir/sentinel_bin"
sentinel_claude="$sentinel_dir/claude"
sentinel_expected="$temp_dir/sentinel_claude.expected"
mkdir -p "$sentinel_dir"
cat >"$sentinel_claude" <<'EOF'
#!/usr/bin/env bash
echo "SENTINEL_CLAUDE_MUST_NOT_BE_MODIFIED_OR_EXECUTED" >&2
exit 99
EOF
chmod +x "$sentinel_claude"
cp "$sentinel_claude" "$sentinel_expected"

# Capture real Python before stubbing PATH so INT tests can restore SIG_DFL under backgrounded runners.
real_python="$(command -v python3 || command -v python || true)"

# Build minimal PATH without real or sentinel codex/claude/python/git shadowing fake tools.
base_path="$temp_dir/base_bin"
mkdir -p "$base_path"
incoming_path="$sentinel_dir:$PATH"
IFS=':' read -r -a path_dirs <<< "$incoming_path"
for dir in "${path_dirs[@]}"; do
  [[ -d "$dir" ]] || continue
  for bin in "$dir"/*; do
    [[ -x "$bin" && ! -d "$bin" ]] || continue
    name="$(basename "$bin")"
    case "$name" in
      codex|claude|python|python3|python3.*|git) continue ;;
    esac
    if [[ ! -e "$base_path/$name" && ! -L "$base_path/$name" ]]; then
      ln -s "$bin" "$base_path/$name"
    fi
  done
done
for stub_name in codex claude python python3 git; do
  [[ ! -e "$base_path/$stub_name" && ! -L "$base_path/$stub_name" ]] || fail
done

write_fake_claude() {
  local target_bin="$1"
  cat >"$target_bin/claude" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then echo "2.1.0"; fi
exit 0
EOF
  chmod +x "$target_bin/claude"
  [[ -f "$target_bin/claude" && ! -L "$target_bin/claude" && -x "$target_bin/claude" ]] || fail
}

write_fake_python() {
  local ver="$1"
  local target="${2:-$FAKE_BIN_DIR/python3}"
  mkdir -p "$(dirname "$target")"
  cat >"$target" <<EOF
#!/usr/bin/env bash
set -euo pipefail
ver="$ver"
if [[ "\${1:-}" == "-E" && "\${2:-}" == "-S" && "\${3:-}" == "-c" ]]; then
  echo "\$ver"
  maj="\${ver%%.*}"
  rest="\${ver#*.}"
  min="\${rest%%.*}"
  if (( 10#\$maj > 3 || (10#\$maj == 3 && 10#\$min >= 10) )); then
    exit 0
  fi
  exit 1
fi
if [[ "\${1:-}" == *"te_bootstrap.py" && "\${2:-}" == "cli" ]]; then
  if [[ "\${FAKE_PY_TRIPWIRE_BOOTSTRAP:-0}" == "1" ]]; then
    echo "TRIPWIRE: python te_bootstrap.py invoked unexpectedly" >&2
    exit 97
  fi
  shift 2
  cwd=""
  global=0
  sub=""
  pairs=()
  while (( \$# > 0 )); do
    case "\$1" in
      --host) shift ;;
      --cwd) cwd="\$2"; shift ;;
      --global) global=1 ;;
      status|config|set|--json)
        if [[ "\$1" == "status" || "\$1" == "config" ]]; then sub="\$1"; fi
        ;;
      *=*) pairs+=("\$1") ;;
    esac
    shift
  done
  if [[ "\$sub" == "status" ]]; then
    state_dir="\$TOKENECONOMIZER_HOME/repos/demo-repo-123/codex"
    printf '{"state":"%s"}\n' "\$state_dir"
    exit 0
  fi
  if [[ "\$sub" == "config" ]]; then
    if (( global == 1 )); then
      cfg_file="\$TOKENECONOMIZER_HOME/config.json"
    else
      cfg_file="\$TOKENECONOMIZER_HOME/repos/demo-repo-123/config.json"
    fi
    mkdir -p "\$(dirname "\$cfg_file")"
    if [[ ! -f "\$cfg_file" ]]; then echo '{}' >"\$cfg_file"; fi
    for kv in "\${pairs[@]}"; do
      k="\${kv%%=*}"
      v="\${kv#*=}"
      if [[ "\$k" == "loopguard" && "\$v" == "on" ]]; then v="nudge"; fi
      tmp="\$cfg_file.tmp.\$\$"
      jq --arg k "\$k" --arg v "\$v" '.[\$k] = \$v' "\$cfg_file" >"\$tmp" && mv "\$tmp" "\$cfg_file"
    done
    exit 0
  fi
fi
exit 1
EOF
  chmod +x "$target"
}

write_fake_git() {
  local target="${1:-$FAKE_BIN_DIR/git}"
  mkdir -p "$(dirname "$target")"
  cat >"$target" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FAKE_GIT_LOG"
repo_dir=""
if [[ "${1:-}" == "-C" ]]; then
  repo_dir="$2"
  shift 2
fi
cmd="${1:-}"
shift || true
if [[ "${FAKE_GIT_TRIPWIRE_NET:-0}" == "1" ]]; then
  case "$cmd" in
    fetch|clone|remote|ls-remote|pull|push)
      echo "TRIPWIRE: git $cmd invoked unexpectedly" >&2
      exit 97
      ;;
  esac
fi
case "$cmd" in
  init)
    target=""
    for a in "$@"; do
      case "$a" in -*) ;; *) target="$a" ;; esac
    done
    mkdir -p "$target/.git"
    exit 0
    ;;
  remote)
    exit 0
    ;;
  fetch)
    if [[ "${FAKE_GIT_FAIL:-0}" == "1" ]]; then exit 1; fi
    sha=""
    for a in "$@"; do sha="$a"; done
    printf '%s\n' "${FAKE_GIT_OVERRIDE_SHA:-$sha}" >"$repo_dir/.git/HEAD_SHA"
    exit 0
    ;;
  checkout)
    mkdir -p "$repo_dir/.claude-plugin" "$repo_dir/plugin/.codex-plugin" "$repo_dir/plugin/hooks" "$repo_dir/plugin/scripts"
    printf '{"name":"tokeneconomizer"}\n' >"$repo_dir/.claude-plugin/marketplace.json"
    printf '{"name":"tokeneconomizer","version":"0.1.0"}\n' >"$repo_dir/plugin/.codex-plugin/plugin.json"
    printf '{"hooks":{}}\n' >"$repo_dir/plugin/hooks/codex-hooks.json"
    printf '#!/bin/sh\necho "{}"\n' >"$repo_dir/plugin/scripts/te-hook"
    printf '# stub\n' >"$repo_dir/plugin/scripts/te_bootstrap.py"
    printf 'Apache License 2.0\n' >"$repo_dir/LICENSE"
    if [[ -f "$repo_dir/.git/HEAD_SHA" ]]; then
      cat "$repo_dir/.git/HEAD_SHA" >"$repo_dir/plugin/pin.txt"
    fi
    exit 0
    ;;
  status)
    if [[ -f "$repo_dir/.git/DIRTY" ]]; then
      echo " M LICENSE"
      exit 0
    fi
    # Report any unexpected untracked file inside repo_dir.
    while IFS= read -r f; do
      rel="${f#"$repo_dir/"}"
      case "$rel" in
        .git|.git/*|.claude-plugin/marketplace.json|plugin/.codex-plugin/plugin.json|plugin/hooks/codex-hooks.json|plugin/scripts/te-hook|plugin/scripts/te_bootstrap.py|plugin/pin.txt|LICENSE) ;;
        *) echo "?? $rel" ;;
      esac
    done < <(find "$repo_dir" -mindepth 1 \( -type f -o -type l \) 2>/dev/null)
    exit 0
    ;;
  rev-parse)
    if [[ "${1:-}" == "--is-inside-work-tree" ]]; then
      [[ -d "${repo_dir:-.}/.git" ]] && exit 0
      exit 128
    fi
    if [[ "${1:-}" == "--show-toplevel" ]]; then
      if [[ -d "${repo_dir:-.}/.git" ]]; then
        (cd "${repo_dir:-.}" && pwd -P)
        exit 0
      fi
      exit 128
    fi
    if [[ "${1:-}" == "--git-path" ]]; then
      echo ".git/${2:-}"
      exit 0
    fi
    if [[ -f "$repo_dir/.git/HEAD_SHA" ]]; then
      cat "$repo_dir/.git/HEAD_SHA"
      exit 0
    fi
    exit 1
    ;;
esac
exit 0
EOF
  chmod +x "$target"
}

write_fake_codex() {
  local target="${1:-$FAKE_BIN_DIR/codex}"
  mkdir -p "$(dirname "$target")"
  cat >"$target" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FAKE_CODEX_LOG"
mkdir -p "$FAKE_STATE"
mkt_file="$FAKE_STATE/marketplaces.json"
plug_file="$FAKE_STATE/plugins.json"
list_count_file="$FAKE_STATE/list_count"
[[ -f "$mkt_file" ]] || echo '{"marketplaces":[]}' >"$mkt_file"
[[ -f "$plug_file" ]] || echo '{"installed":[],"available":[]}' >"$plug_file"

sync_config_toml() {
  mkdir -p "$CODEX_HOME"
  local cfg="$CODEX_HOME/config.toml"
  : >"$cfg"
  jq -r '.marketplaces[] | "[marketplaces.\(.name)]\nsource_type = \"local\"\nsource = \"\(.marketplaceSource.source)\"\n"' "$mkt_file" >>"$cfg"
  jq -r '.installed[] | "[plugins.\"\(.pluginId)\"]\nenabled = \(.enabled)\n"' "$plug_file" >>"$cfg"
}

if [[ "${FAKE_CODEX_TRIPWIRE_ANY:-0}" == "1" ]]; then
  echo "TRIPWIRE: codex $* invoked unexpectedly" >&2
  if [[ -n "${FAKE_TRIPWIRE_FILE:-}" ]]; then
    printf 'codex %s\n' "$*" >>"$FAKE_TRIPWIRE_FILE"
  fi
  exit 97
fi

if [[ "${1:-}" == "--version" ]]; then
  if [[ "${FAKE_CODEX_WARN_PREFIX:-0}" == "1" ]]; then
    echo "WARNING: ignoring experimental setting 1.2.3" >&2
  fi
  if [[ -n "${FAKE_CODEX_RAW_VERSION:-}" ]]; then
    printf '%s\n' "$FAKE_CODEX_RAW_VERSION"
  else
    echo "codex-cli ${FAKE_CODEX_VER:-0.169.0}"
  fi
  exit 0
fi

if [[ "${1:-}" == "plugin" ]]; then
  if [[ "${FAKE_CODEX_TRIPWIRE_PLUGIN:-0}" == "1" ]]; then
    echo "TRIPWIRE: codex plugin $* invoked unexpectedly" >&2
    exit 97
  fi
  shift
  sub="${1:-}"
  shift || true
  case "$sub" in
    list)
      c=0
      [[ -f "$list_count_file" ]] && c="$(cat "$list_count_file")"
      c=$((c + 1))
      printf '%s\n' "$c" >"$list_count_file"
      if [[ "${FAKE_CODEX_PLUGIN_JSON_FAIL:-0}" == "1" ]] ||
         { [[ -n "${FAKE_CODEX_LIST_FAIL_ON_CALL:-}" ]] && (( c == FAKE_CODEX_LIST_FAIL_ON_CALL )); }; then
        echo "plugin list failed" >&2
        exit 2
      fi
      if [[ -n "${FAKE_CODEX_PLUGIN_RAW_OUT:-}" ]] &&
         { [[ -z "${FAKE_CODEX_PLUGIN_RAW_CALL:-}" ]] || (( c == FAKE_CODEX_PLUGIN_RAW_CALL )); }; then
        printf '%s\n' "$FAKE_CODEX_PLUGIN_RAW_OUT"
        exit 0
      fi
      cat "$plug_file"
      exit 0
      ;;
    add)
      if [[ "${FAKE_CODEX_ADD_FAIL:-0}" == "1" ]]; then
        echo "plugin add failed" >&2
        exit 1
      fi
      pid="${1:-}"
      mkt_src="$(jq -r '.marketplaces[] | select(.name == "tokeneconomizer") | .marketplaceSource.source // ""' "$mkt_file" | head -n 1)"
      if [[ -n "$mkt_src" && -f "$mkt_src/plugin/pin.txt" ]]; then
        mkdir -p "$CODEX_HOME/plugins/cache/tokeneconomizer/tokeneconomizer/0.1.0"
        cp "$mkt_src/plugin/pin.txt" "$CODEX_HOME/plugins/cache/tokeneconomizer/tokeneconomizer/0.1.0/pin.txt"
      fi
      tmp="$plug_file.tmp.$$"
      jq --arg pid "$pid" --arg psrc "$mkt_src/plugin" --arg msrc "$mkt_src" '
        .installed = ([.installed[] | select(.pluginId != $pid)] + [{
          pluginId: $pid,
          name: "tokeneconomizer",
          marketplaceName: "tokeneconomizer",
          version: "0.1.0",
          installed: true,
          enabled: true,
          source: {source: "local", path: $psrc},
          marketplaceSource: {sourceType: "local", source: $msrc}
        }])
      ' "$plug_file" >"$tmp" && mv "$tmp" "$plug_file"
      sync_config_toml
      if [[ -n "${FAKE_CODEX_SIGNAL_ON_ADD:-}" ]]; then
        kill "-${FAKE_CODEX_SIGNAL_ON_ADD}" "$PPID" 2>/dev/null || true
        sleep 2
      fi
      echo '{"pluginId":"tokeneconomizer@tokeneconomizer"}'
      exit 0
      ;;
    remove)
      if [[ "${FAKE_CODEX_RM_FAIL:-0}" == "1" ]]; then exit 1; fi
      pid="${1:-}"
      tmp="$plug_file.tmp.$$"
      jq --arg pid "$pid" '.installed = [.installed[] | select(.pluginId != $pid)]' "$plug_file" >"$tmp" && mv "$tmp" "$plug_file"
      rm -rf "$CODEX_HOME/plugins/cache/tokeneconomizer/tokeneconomizer" 2>/dev/null || true
      sync_config_toml
      echo '{"pluginId":"tokeneconomizer@tokeneconomizer"}'
      exit 0
      ;;
    marketplace)
      msub="${1:-}"
      shift || true
      case "$msub" in
        list)
          if [[ "${FAKE_CODEX_MKT_JSON_FAIL:-0}" == "1" ]]; then exit 2; fi
          if [[ -n "${FAKE_CODEX_MKT_RAW_OUT:-}" ]]; then
            printf '%s\n' "$FAKE_CODEX_MKT_RAW_OUT"
            exit 0
          fi
          cat "$mkt_file"
          exit 0
          ;;
        add)
          if [[ "${FAKE_CODEX_MKT_ADD_FAIL:-0}" == "1" ]]; then
            echo "marketplace add failed" >&2
            exit 1
          fi
          src="${1:-}"
          src_real="$(cd "$src" 2>/dev/null && pwd -P || printf '%s' "$src")"
          tmp="$mkt_file.tmp.$$"
          jq --arg src "$src_real" '
            .marketplaces = ([.marketplaces[] | select(.name != "tokeneconomizer")] + [{
              name: "tokeneconomizer",
              root: $src,
              marketplaceSource: {sourceType: "local", source: $src}
            }])
          ' "$mkt_file" >"$tmp" && mv "$tmp" "$mkt_file"
          sync_config_toml
          printf '{"marketplaceName":"tokeneconomizer","installedRoot":"%s"}\n' "$src_real"
          exit 0
          ;;
        remove)
          if [[ "${FAKE_CODEX_MKT_RM_FAIL:-0}" == "1" ]]; then
            echo "marketplace remove failed" >&2
            exit 1
          fi
          mname="${1:-}"
          tmp="$mkt_file.tmp.$$"
          jq --arg m "$mname" '.marketplaces = [.marketplaces[] | select(.name != $m)]' "$mkt_file" >"$tmp" && mv "$tmp" "$mkt_file"
          sync_config_toml
          echo '{"marketplaceName":"tokeneconomizer","installedRoot":null}'
          exit 0
          ;;
      esac
      ;;
  esac
fi
exit 1
EOF
  chmod +x "$target"
}

run_with_default_sigint() {
  if [[ -n "$real_python" ]]; then
    "$real_python" -c 'import os, signal, sys; signal.signal(signal.SIGINT, signal.SIG_DFL); os.execvp(sys.argv[1], sys.argv[1:])' "$@"
  elif command -v perl >/dev/null 2>&1; then
    perl -e '$SIG{INT} = "DEFAULT"; exec { $ARGV[0] } @ARGV or exit 127' -- "$@"
  else
    fail
  fi
}

file_sha256() {
  local f="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$f" | awk '{print $1}'
  else
    sha256sum "$f" | awk '{print $1}'
  fi
}

snapshot_trees() {
  local root_dir
  for root_dir in "$@"; do
    printf 'ROOT:%s\n' "$root_dir"
    if [[ -L "$root_dir" ]]; then
      printf 'SYMLINK:%s->%s\n' "$root_dir" "$(readlink "$root_dir")"
    elif [[ -e "$root_dir" ]]; then
      while IFS= read -r entry; do
        if [[ -L "$entry" ]]; then
          printf 'L:%s->%s\n' "$entry" "$(readlink "$entry")"
        elif [[ -d "$entry" ]]; then
          printf 'D:%s\n' "$entry"
        elif [[ -f "$entry" ]]; then
          printf 'F:%s:%s\n' "$entry" "$(file_sha256 "$entry")"
        else
          printf 'O:%s\n' "$entry"
        fi
      done < <(find "$root_dir" 2>/dev/null | LC_ALL=C sort)
    else
      printf 'ABSENT:%s\n' "$root_dir"
    fi
  done
}

te_cmd="$repo_root/scripts/squad-tokeneconomizer.sh"
devkit_cmd="$repo_root/scripts/squad-devkit.sh"

# Test tracking counters
orig_total=0
orig_pass=0
orig_fail=0
new_total=0
new_pass=0
new_fail=0

run_case() {
  local kind="$1"
  local name="$2"
  local fn="$3"
  local case_log="$temp_dir/case_${kind}_${name}.log"
  local rc=0

  set +e
  (
    set -euo pipefail
    trap 'echo "Assertion failed at line $LINENO: $BASH_COMMAND" >&2' ERR
    "$fn"
  ) >"$case_log" 2>&1
  rc=$?
  set -e

  if [[ "$kind" == "original" ]]; then
    orig_total=$((orig_total + 1))
    if (( rc == 0 )); then
      orig_pass=$((orig_pass + 1))
      printf '[PASS] [%s] %s\n' "$kind" "$name"
    else
      orig_fail=$((orig_fail + 1))
      printf '[FAIL] [%s] %s (exit %d)\n' "$kind" "$name" "$rc"
      sed 's/^/  | /' "$case_log"
    fi
  else
    new_total=$((new_total + 1))
    if (( rc == 0 )); then
      new_pass=$((new_pass + 1))
      printf '[PASS] [%s] %s\n' "$kind" "$name"
    else
      new_fail=$((new_fail + 1))
      printf '[FAIL] [%s] %s (exit %d)\n' "$kind" "$name" "$rc"
      sed 's/^/  | /' "$case_log"
    fi
  fi
}

setup_case_env() {
  local name="$1"
  local suffix="${2:-}"
  case_root="$temp_dir/env_${name}"
  export HOME="$case_root/home${suffix}"
  export XDG_CACHE_HOME="$case_root/cache${suffix}"
  export XDG_CONFIG_HOME="$case_root/config${suffix}"
  export CODEX_HOME="$case_root/codex_home${suffix}"
  export TOKENECONOMIZER_HOME="$case_root/te_home${suffix}"
  export FAKE_BIN_DIR="$case_root/bin"
  export FAKE_STATE="$case_root/fake_state"
  export FAKE_GIT_LOG="$case_root/git.log"
  export FAKE_CODEX_LOG="$case_root/codex.log"
  unset SQUAD_TOKENECONOMIZER_CACHE_DIR TE_PYTHON
  unset FAKE_CODEX_WARN_PREFIX FAKE_CODEX_RAW_VERSION FAKE_CODEX_VER
  unset FAKE_CODEX_TRIPWIRE_ANY FAKE_TRIPWIRE_FILE
  unset FAKE_CODEX_TRIPWIRE_PLUGIN FAKE_CODEX_PLUGIN_JSON_FAIL FAKE_CODEX_LIST_FAIL_ON_CALL
  unset FAKE_CODEX_PLUGIN_RAW_OUT FAKE_CODEX_PLUGIN_RAW_CALL
  unset FAKE_CODEX_ADD_FAIL FAKE_CODEX_SIGNAL_ON_ADD FAKE_CODEX_RM_FAIL
  unset FAKE_CODEX_MKT_JSON_FAIL FAKE_CODEX_MKT_RAW_OUT FAKE_CODEX_MKT_ADD_FAIL FAKE_CODEX_MKT_RM_FAIL
  unset FAKE_GIT_TRIPWIRE_NET FAKE_GIT_FAIL FAKE_GIT_OVERRIDE_SHA
  unset FAKE_PY_TRIPWIRE_BOOTSTRAP

  mkdir -p "$HOME" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME" "$CODEX_HOME" "$FAKE_BIN_DIR" "$FAKE_STATE"
  write_fake_claude "$FAKE_BIN_DIR"
  write_fake_git "$FAKE_BIN_DIR/git"
  write_fake_codex "$FAKE_BIN_DIR/codex"
  write_fake_python "3.12.2" "$FAKE_BIN_DIR/python3"
  export PATH="$FAKE_BIN_DIR:$base_path"
  [[ "$(command -v claude)" == "$FAKE_BIN_DIR/claude" ]] || fail
  cache_dir="$XDG_CACHE_HOME/squad-devkit/tokeneconomizer"
  : >"$FAKE_GIT_LOG"
  : >"$FAKE_CODEX_LOG"
}

# ==============================================================================
# ORIGINAL GROUPS (1..9 + sentinel regression; preserved assertions & sequence)
# ==============================================================================
orig_root="$temp_dir/orig"
export HOME="$orig_root/home"
export XDG_CACHE_HOME="$orig_root/cache"
export XDG_CONFIG_HOME="$orig_root/config"
export CODEX_HOME="$orig_root/codex_home"
export TOKENECONOMIZER_HOME="$orig_root/te_home"
export FAKE_BIN_DIR="$orig_root/bin"
export FAKE_STATE="$orig_root/fake_state"
export FAKE_GIT_LOG="$orig_root/git.log"
export FAKE_CODEX_LOG="$orig_root/codex.log"
mkdir -p "$HOME" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME" "$CODEX_HOME" "$FAKE_BIN_DIR" "$FAKE_STATE"
write_fake_claude "$FAKE_BIN_DIR"
export PATH="$FAKE_BIN_DIR:$base_path"
[[ "$(command -v claude)" == "$FAKE_BIN_DIR/claude" ]] || fail
cache_dir="$XDG_CACHE_HOME/squad-devkit/tokeneconomizer"

orig_01_help_contract() {
  local help_out
  help_out="$("$te_cmd" --help)"
  [[ "$help_out" == *"$pinned_sha"* ]] || fail
  [[ "$help_out" == *"Apache-2.0"* ]] || fail
  [[ "$help_out" == *"--ephemeral"* ]] || fail
}

orig_02_readonly_absent_and_doctor() {
  write_fake_git
  write_fake_codex
  write_fake_python "3.12.2"
  : >"$FAKE_CODEX_LOG"
  local status_absent doctor_absent
  status_absent="$("$te_cmd" status --json)"
  [[ "$(jq -r '.state' <<<"$status_absent")" == "absent" ]] || fail
  [[ "$(jq -r '.codex_cli_introspected' <<<"$status_absent")" == "false" ]] || fail
  [[ "$(jq -r '.registration_state' <<<"$status_absent")" == "absent" ]] || fail
  [[ ! -e "$cache_dir" ]] || fail
  [[ ! -e "$TOKENECONOMIZER_HOME" ]] || fail
  [[ ! -s "$FAKE_GIT_LOG" ]] || fail
  ! grep -q "plugin list" "$FAKE_CODEX_LOG" || fail
  ! grep -q "marketplace list" "$FAKE_CODEX_LOG" || fail

  : >"$FAKE_CODEX_LOG"
  doctor_absent="$("$devkit_cmd" --doctor)"
  [[ "$doctor_absent" == *"[OPTIONAL] tokeneconomizer"* ]] || fail
  [[ "$doctor_absent" == *"Result: Environment ready for squad-devkit."* ]] || fail
  ! grep -q "plugin list" "$FAKE_CODEX_LOG" || fail
  ! grep -q "marketplace list" "$FAKE_CODEX_LOG" || fail
}

orig_03_dependency_and_version_failures() {
  rm -f "$FAKE_BIN_DIR/codex"
  if "$te_cmd" install >"$orig_root/err" 2>&1; then fail; fi
  grep -qi "codex" "$orig_root/err" || fail
  [[ ! -e "$cache_dir" ]] || fail

  write_fake_codex
  write_fake_python "3.9.6"
  if "$te_cmd" install >"$orig_root/err" 2>&1; then fail; fi
  grep -q "3.10" "$orig_root/err" || fail
  grep -q "TE_PYTHON" "$orig_root/err" || fail
  [[ ! -e "$cache_dir" ]] || fail

  write_fake_python "3.12.2"
  if FAKE_CODEX_VER="0.135.0" "$te_cmd" install >"$orig_root/err" 2>&1; then fail; fi
  grep -q "0.141.0" "$orig_root/err" || fail
  [[ ! -e "$cache_dir" ]] || fail

  if FAKE_CODEX_PLUGIN_JSON_FAIL=1 "$te_cmd" install >"$orig_root/err" 2>&1; then fail; fi
  grep -q "codex plugin list --json" "$orig_root/err" || fail
  [[ ! -e "$cache_dir" ]] || fail
}

orig_04_rollback_and_signals() {
  if FAKE_GIT_OVERRIDE_SHA="deadbeef00000000000000000000000000000000" "$te_cmd" install >"$orig_root/err" 2>&1; then fail; fi
  grep -q "$pinned_sha" "$orig_root/err" || fail
  [[ ! -e "$cache_dir/upstream" ]] || fail
  [[ ! -e "$cache_dir/ownership.json" ]] || fail

  if FAKE_CODEX_ADD_FAIL=1 "$te_cmd" install >"$orig_root/err" 2>&1; then fail; fi
  [[ ! -e "$cache_dir/upstream" ]] || fail
  [[ ! -e "$cache_dir/ownership.json" ]] || fail
  [[ "$(jq '.marketplaces | length' "$FAKE_STATE/marketplaces.json")" == "0" ]] || fail

  if FAKE_CODEX_SIGNAL_ON_ADD=TERM "$te_cmd" install >"$orig_root/err" 2>&1; then fail; fi
  [[ ! -e "$cache_dir/upstream" && ! -L "$cache_dir/upstream" ]] || fail
  [[ ! -e "$cache_dir/ownership.json" ]] || fail
  [[ ! -e "$cache_dir" ]] || fail
  [[ "$(jq '.marketplaces | length' "$FAKE_STATE/marketplaces.json")" == "0" ]] || fail
  [[ "$(jq '.installed | length' "$FAKE_STATE/plugins.json")" == "0" ]] || fail

  local int_rc=0
  FAKE_CODEX_SIGNAL_ON_ADD=INT run_with_default_sigint "$te_cmd" install >"$orig_root/err" 2>&1 || int_rc=$?
  [[ "$int_rc" == "130" ]] || fail
  grep -q "Interrupted; rolled back incomplete TokenEconomizer setup." "$orig_root/err" || fail
  [[ ! -e "$cache_dir/upstream" && ! -L "$cache_dir/upstream" ]] || fail
  [[ ! -e "$cache_dir/ownership.json" ]] || fail
  [[ ! -e "$cache_dir" ]] || fail
  [[ "$(jq '.marketplaces | length' "$FAKE_STATE/marketplaces.json")" == "0" ]] || fail
  [[ "$(jq '.installed | length' "$FAKE_STATE/plugins.json")" == "0" ]] || fail
}

orig_05_install_status_doctor_idempotent() {
  : >"$FAKE_GIT_LOG"
  local install_out status_unverified doctor_unverified status_cfg_absent status_tested doctor_tested status_unsup doctor_unsup
  install_out="$("$te_cmd" install)"
  [[ "$install_out" == *"$pinned_sha"* ]] || fail
  grep -Fq "remote add origin $upstream_url" "$FAKE_GIT_LOG" || fail
  grep -Fq "fetch -q --depth 1 origin $pinned_sha" "$FAKE_GIT_LOG" || fail
  [[ -f "$cache_dir/ownership.json" ]] || fail
  [[ "$(jq -r '.pinned_commit' "$cache_dir/ownership.json")" == "$pinned_sha" ]] || fail
  [[ ! -e "$TOKENECONOMIZER_HOME/config.json" ]] || fail
  [[ "$(cat "$CODEX_HOME/plugins/cache/tokeneconomizer/tokeneconomizer/0.1.0/pin.txt")" == "$pinned_sha" ]] || fail

  : >"$FAKE_GIT_LOG"
  : >"$FAKE_CODEX_LOG"
  status_unverified="$(FAKE_CODEX_WARN_PREFIX=1 "$te_cmd" status --json)"
  [[ "$(jq -r '.codex_version' <<<"$status_unverified")" == "unprobed" ]] || fail
  [[ "$(jq -r '.codex_compatibility' <<<"$status_unverified")" == "unprobed" ]] || fail
  [[ "$(jq -r '.codex_path' <<<"$status_unverified")" == "$FAKE_BIN_DIR/codex" ]] || fail
  [[ "$(jq -r '.codex_reason' <<<"$status_unverified")" == *"version/compatibility unprobed"* ]] || fail
  [[ "$(jq -r '.state' <<<"$status_unverified")" == "registered_unverified" ]] || fail
  [[ "$(jq -r '.codex_cli_introspected' <<<"$status_unverified")" == "false" ]] || fail
  [[ "$(jq -r '.registration_state' <<<"$status_unverified")" == "configured" ]] || fail
  [[ "$(jq -r '.owned_by_devkit' <<<"$status_unverified")" == "true" ]] || fail
  [[ "$(jq -r '.ephemeral_exec_compatible' <<<"$status_unverified")" == "false" ]] || fail
  [[ "$(jq -r '.worktree_identity_canonicalized' <<<"$status_unverified")" == "true" ]] || fail
  ! grep -q "fetch" "$FAKE_GIT_LOG" || fail
  ! grep -q "plugin list" "$FAKE_CODEX_LOG" || fail
  ! grep -q "marketplace list" "$FAKE_CODEX_LOG" || fail
  ! grep -q "add" "$FAKE_CODEX_LOG" || fail

  : >"$FAKE_CODEX_LOG"
  doctor_unverified="$("$devkit_cmd" --doctor)"
  [[ "$doctor_unverified" == *"tokeneconomizer"*"(registered, unverified:"* ]] || fail
  ! grep -q "plugin list" "$FAKE_CODEX_LOG" || fail
  ! grep -q "marketplace list" "$FAKE_CODEX_LOG" || fail

  mv "$CODEX_HOME/config.toml" "$CODEX_HOME/config.toml.bak"
  : >"$FAKE_CODEX_LOG"
  status_cfg_absent="$("$te_cmd" status --json)"
  [[ "$(jq -r '.state' <<<"$status_cfg_absent")" == "registered_unverified" ]] || fail
  [[ "$(jq -r '.registration_state' <<<"$status_cfg_absent")" == "unknown" ]] || fail
  [[ "$(jq -r '.plugin_installed' <<<"$status_cfg_absent")" == "null" ]] || fail
  ! grep -q "plugin list" "$FAKE_CODEX_LOG" || fail
  mv "$CODEX_HOME/config.toml.bak" "$CODEX_HOME/config.toml"

  mkdir -p "$TOKENECONOMIZER_HOME/bin"
  printf '#!/bin/sh\nexit 0\n' >"$TOKENECONOMIZER_HOME/bin/te"
  chmod +x "$TOKENECONOMIZER_HOME/bin/te"
  status_tested="$(FAKE_CODEX_VER="0.160.0" "$te_cmd" status --json)"
  [[ "$(jq -r '.state' <<<"$status_tested")" == "registered_unverified" ]] || fail
  doctor_tested="$(FAKE_CODEX_VER="0.160.0" "$devkit_cmd" --doctor)"
  [[ "$doctor_tested" == *"[INFO]"*"tokeneconomizer"*"(registered, unverified:"* ]] || fail
  ! grep -q '\[OK\].*tokeneconomizer' <<<"$doctor_tested" || fail

  status_unsup="$(FAKE_CODEX_VER="0.135.0" "$te_cmd" status --json)"
  [[ "$(jq -r '.codex_version' <<<"$status_unsup")" == "unprobed" ]] || fail
  [[ "$(jq -r '.codex_compatibility' <<<"$status_unsup")" == "unprobed" ]] || fail
  [[ "$(jq -r '.codex_path' <<<"$status_unsup")" == "$FAKE_BIN_DIR/codex" ]] || fail
  [[ "$(jq -r '.codex_reason' <<<"$status_unsup")" == *"version/compatibility unprobed"* ]] || fail
  [[ "$(jq -r '.state' <<<"$status_unsup")" == "registered_unverified" ]] || fail
  doctor_unsup="$(FAKE_CODEX_VER="0.135.0" "$devkit_cmd" --doctor)"
  [[ "$doctor_unsup" == *"[INFO]"*"tokeneconomizer"*"(registered, unverified:"* ]] || fail
  [[ "$doctor_unsup" == *"Result: Environment ready for squad-devkit."* ]] || fail

  : >"$FAKE_GIT_LOG"
  : >"$FAKE_CODEX_LOG"
  "$te_cmd" install >/dev/null
  ! grep -q "fetch" "$FAKE_GIT_LOG" || fail
  ! grep -q "plugin add" "$FAKE_CODEX_LOG" || fail
  [[ "$(jq '.installed | length' "$FAKE_STATE/plugins.json")" == "1" ]] || fail
}

orig_05b_pin_upgrade_and_reenable() {
  local old_sha="0000000000000000000000000000000000000001"
  printf '%s\n' "$old_sha" >"$cache_dir/upstream/.git/HEAD_SHA"
  printf '%s\n' "$old_sha" >"$CODEX_HOME/plugins/cache/tokeneconomizer/tokeneconomizer/0.1.0/pin.txt"
  jq --arg p "$old_sha" '.pinned_commit = $p' "$cache_dir/ownership.json" >"$cache_dir/ownership.json.tmp" && mv "$cache_dir/ownership.json.tmp" "$cache_dir/ownership.json"
  : >"$FAKE_CODEX_LOG"
  "$te_cmd" install >/dev/null
  grep -q "plugin add $pinned_sha" "$FAKE_CODEX_LOG" || grep -q "plugin add tokeneconomizer@tokeneconomizer" "$FAKE_CODEX_LOG" || fail
  [[ "$(cat "$CODEX_HOME/plugins/cache/tokeneconomizer/tokeneconomizer/0.1.0/pin.txt")" == "$pinned_sha" ]] || fail
  [[ "$(jq -r '.pinned_commit' "$cache_dir/ownership.json")" == "$pinned_sha" ]] || fail

  jq '.installed[0].enabled = false' "$FAKE_STATE/plugins.json" >"$FAKE_STATE/plugins.json.tmp" && mv "$FAKE_STATE/plugins.json.tmp" "$FAKE_STATE/plugins.json"
  sed 's/enabled = true/enabled = false/' "$CODEX_HOME/config.toml" >"$CODEX_HOME/config.toml.tmp" && mv "$CODEX_HOME/config.toml.tmp" "$CODEX_HOME/config.toml"
  [[ "$(jq -r '.state' <<<"$("$te_cmd" status --json)")" == "disabled" ]] || fail
  "$te_cmd" install >/dev/null
  [[ "$(jq -r '.installed[0].enabled' "$FAKE_STATE/plugins.json")" == "true" ]] || fail
  [[ "$(jq -r '.state' <<<"$("$te_cmd" status --json)")" == "registered_unverified" ]] || fail
}

orig_05c_dirty_checkout_and_exact_plugin_id() {
  touch "$cache_dir/upstream/untracked.txt"
  [[ "$(jq -r '.state' <<<"$("$te_cmd" status --json)")" == "unsupported" ]] || fail
  if "$te_cmd" install >"$orig_root/err" 2>&1; then fail; fi
  grep -qi "dirty\|untracked" "$orig_root/err" || fail
  rm -f "$cache_dir/upstream/untracked.txt"
  [[ "$(jq -r '.state' <<<"$("$te_cmd" status --json)")" == "registered_unverified" ]] || fail

  jq '.installed += [{
    pluginId: "tokeneconomizer@other-mkt",
    name: "tokeneconomizer",
    marketplaceName: "other-mkt",
    version: "0.1.0",
    installed: true,
    enabled: true,
    source: {source: "local", path: "/tmp/other-mkt/plugin"},
    marketplaceSource: {sourceType: "local", source: "/tmp/other-mkt"}
  }]' "$FAKE_STATE/plugins.json" >"$FAKE_STATE/plugins.json.tmp" && mv "$FAKE_STATE/plugins.json.tmp" "$FAKE_STATE/plugins.json"
  "$te_cmd" install >/dev/null
  [[ "$(jq -r '.state' <<<"$("$te_cmd" status --json)")" == "registered_unverified" ]] || fail
  jq '.installed = [.installed[] | select(.pluginId != "tokeneconomizer@other-mkt")]' "$FAKE_STATE/plugins.json" >"$FAKE_STATE/plugins.json.tmp" && mv "$FAKE_STATE/plugins.json.tmp" "$FAKE_STATE/plugins.json"
}

orig_06_scoped_repo_config() {
  local repo_a="$orig_root/repo_a" scope_out
  mkdir -p "$repo_a" "$TOKENECONOMIZER_HOME/repos/demo-repo-123"
  printf '{"microskills":"on"}\n' >"$TOKENECONOMIZER_HOME/repos/demo-repo-123/config.json"
  printf '{"loopguard":"off"}\n' >"$TOKENECONOMIZER_HOME/config.json"
  scope_out="$("$te_cmd" install --repo "$repo_a")"
  [[ "$scope_out" == *"Retained existing repo preferences"* ]] || fail
  [[ "$(jq -r '.microskills' "$TOKENECONOMIZER_HOME/repos/demo-repo-123/config.json")" == "on" ]] || fail
  [[ "$(jq -r '.toolprune' "$TOKENECONOMIZER_HOME/repos/demo-repo-123/config.json")" == "propose" ]] || fail
  [[ "$(jq -r '.loopguard' "$TOKENECONOMIZER_HOME/repos/demo-repo-123/config.json")" == "nudge" ]] || fail
  [[ "$(jq -r '.loopguard' "$TOKENECONOMIZER_HOME/config.json")" == "off" ]] || fail
  [[ "$(jq -r 'has("microskills")' "$TOKENECONOMIZER_HOME/config.json")" == "false" ]] || fail
}

orig_07_disable_fail_closed_and_reenable() {
  mkdir -p "$TOKENECONOMIZER_HOME/repos/demo-repo-123/codex"
  printf '{"rendered":"- use python -m pytest\n"}\n' >"$TOKENECONOMIZER_HOME/repos/demo-repo-123/codex/injection.json"

  if FAKE_CODEX_VER="0.135.0" "$te_cmd" disable >"$orig_root/err" 2>&1; then fail; fi
  [[ "$(jq -r '.plugin_added_by_devkit' "$cache_dir/ownership.json")" == "true" ]] || fail
  [[ "$(jq -r '.disabled' "$cache_dir/ownership.json")" == "false" ]] || fail
  [[ "$(jq '.installed | length' "$FAKE_STATE/plugins.json")" == "1" ]] || fail

  if FAKE_CODEX_PLUGIN_JSON_FAIL=1 "$te_cmd" disable >"$orig_root/err" 2>&1; then fail; fi
  [[ "$(jq -r '.plugin_added_by_devkit' "$cache_dir/ownership.json")" == "true" ]] || fail
  [[ "$(jq '.installed | length' "$FAKE_STATE/plugins.json")" == "1" ]] || fail

  mv "$FAKE_BIN_DIR/codex" "$FAKE_BIN_DIR/codex.hidden"
  if "$te_cmd" disable >"$orig_root/err" 2>&1; then fail; fi
  [[ "$(jq -r '.plugin_added_by_devkit' "$cache_dir/ownership.json")" == "true" ]] || fail
  mv "$FAKE_BIN_DIR/codex.hidden" "$FAKE_BIN_DIR/codex"

  local doctor_disabled
  "$te_cmd" disable >/dev/null
  [[ "$(jq '.installed | length' "$FAKE_STATE/plugins.json")" == "0" ]] || fail
  [[ "$(jq '.marketplaces | length' "$FAKE_STATE/marketplaces.json")" == "1" ]] || fail
  [[ -d "$cache_dir/upstream" ]] || fail
  [[ -f "$TOKENECONOMIZER_HOME/repos/demo-repo-123/codex/injection.json" ]] || fail
  [[ "$(jq -r '.state' <<<"$("$te_cmd" status --json)")" == "disabled" ]] || fail
  doctor_disabled="$("$devkit_cmd" --doctor)"
  [[ "$doctor_disabled" == *"[OPTIONAL]"*"tokeneconomizer"*"(disabled;"* ]] || fail

  "$te_cmd" install >/dev/null
  [[ "$(jq '.installed | length' "$FAKE_STATE/plugins.json")" == "1" ]] || fail
}

orig_07b_shared_marketplace_and_uninstall() {
  jq --arg src "$cache_dir/upstream" '.installed += [{
    pluginId: "extra@tokeneconomizer",
    name: "extra",
    marketplaceName: "tokeneconomizer",
    version: "0.1.0",
    installed: true,
    enabled: true,
    source: {source: "local", path: ($src + "/extra")},
    marketplaceSource: {sourceType: "local", source: $src}
  }]' "$FAKE_STATE/plugins.json" >"$FAKE_STATE/plugins.json.tmp" && mv "$FAKE_STATE/plugins.json.tmp" "$FAKE_STATE/plugins.json"

  "$te_cmd" uninstall >"$orig_root/shared_uninst" 2>&1
  grep -q "Preserved shared checkout" "$orig_root/shared_uninst" || fail
  [[ "$(jq '.installed | length' "$FAKE_STATE/plugins.json")" == "1" ]] || fail
  [[ "$(jq '.installed[0].pluginId' "$FAKE_STATE/plugins.json")" == '"extra@tokeneconomizer"' ]] || fail
  [[ "$(jq '.marketplaces | length' "$FAKE_STATE/marketplaces.json")" == "1" ]] || fail
  [[ -d "$cache_dir/upstream" ]] || fail
  [[ -f "$cache_dir/ownership.json" ]] || fail
  [[ "$(jq -r '.plugin_added_by_devkit' "$cache_dir/ownership.json")" == "false" ]] || fail

  jq '.installed = []' "$FAKE_STATE/plugins.json" >"$FAKE_STATE/plugins.json.tmp" && mv "$FAKE_STATE/plugins.json.tmp" "$FAKE_STATE/plugins.json"
  : >"$FAKE_STATE/list_count"
  if FAKE_CODEX_LIST_FAIL_ON_CALL=2 "$te_cmd" uninstall >"$orig_root/err" 2>&1; then fail; fi
  grep -q "Failed to query Codex plugins" "$orig_root/err" || fail
  [[ "$(jq '.marketplaces | length' "$FAKE_STATE/marketplaces.json")" == "1" ]] || fail
  [[ -d "$cache_dir/upstream" ]] || fail
  [[ -f "$cache_dir/ownership.json" ]] || fail

  : >"$FAKE_STATE/list_count"
  "$te_cmd" uninstall >/dev/null
  [[ "$(jq '.installed | length' "$FAKE_STATE/plugins.json")" == "0" ]] || fail
  [[ "$(jq '.marketplaces | length' "$FAKE_STATE/marketplaces.json")" == "0" ]] || fail
  [[ ! -e "$cache_dir/upstream" ]] || fail
  [[ ! -e "$cache_dir/ownership.json" ]] || fail
  [[ -f "$TOKENECONOMIZER_HOME/repos/demo-repo-123/codex/injection.json" ]] || fail
  [[ -f "$TOKENECONOMIZER_HOME/config.json" ]] || fail
  [[ "$(jq -r '.state' <<<"$("$te_cmd" status --json)")" == "absent" ]] || fail
}

orig_08_symlink_managed_paths() {
  local sym_target="$orig_root/sym_target_real"
  mkdir -p "$sym_target"
  ln -s "$sym_target" "$cache_dir"
  [[ "$(jq -r '.state' <<<"$("$te_cmd" status --json)")" == "unsupported" ]] || fail
  if "$te_cmd" install >"$orig_root/err" 2>&1; then fail; fi
  grep -qi "symlink" "$orig_root/err" || fail
  if "$te_cmd" disable >"$orig_root/err" 2>&1; then fail; fi
  if "$te_cmd" uninstall >"$orig_root/err" 2>&1; then fail; fi
  rm -f "$cache_dir"

  mkdir -p "$cache_dir"
  ln -s "$orig_root/nonexistent_broken_target" "$cache_dir/upstream"
  [[ "$(jq -r '.state' <<<"$("$te_cmd" status --json)")" == "unsupported" ]] || fail
  if "$te_cmd" install >"$orig_root/err" 2>&1; then fail; fi
  grep -qi "symlink" "$orig_root/err" || fail
  rm -f "$cache_dir/upstream"

  ln -s "$orig_root/nonexistent_ownership_target" "$cache_dir/ownership.json"
  [[ "$(jq -r '.state' <<<"$("$te_cmd" status --json)")" == "unsupported" ]] || fail
  if "$te_cmd" install >"$orig_root/err" 2>&1; then fail; fi
  if "$te_cmd" uninstall >"$orig_root/err" 2>&1; then fail; fi
  rm -f "$cache_dir/ownership.json"
  rmdir "$cache_dir"
}

orig_09_user_owned_and_malformed_ownership() {
  local user_clone="$orig_root/user_te_clone"
  mkdir -p "$user_clone/.claude-plugin" "$user_clone/plugin"
  codex plugin marketplace add "$user_clone" --json >/dev/null
  codex plugin add tokeneconomizer@tokeneconomizer --json >/dev/null

  if "$te_cmd" install >"$orig_root/err" 2>&1; then fail; fi
  grep -q "user-owned" "$orig_root/err" || fail
  if "$te_cmd" disable >"$orig_root/err" 2>&1; then fail; fi
  grep -q "user-owned" "$orig_root/err" || fail
  "$te_cmd" uninstall >"$orig_root/unowned_out" 2>&1
  grep -q "preserved user-owned state" "$orig_root/unowned_out" || fail
  [[ "$(jq '.installed | length' "$FAKE_STATE/plugins.json")" == "1" ]] || fail
  [[ "$(jq '.marketplaces | length' "$FAKE_STATE/marketplaces.json")" == "1" ]] || fail
  [[ -d "$user_clone" ]] || fail

  mkdir -p "$cache_dir"
  echo '{bad json' >"$cache_dir/ownership.json"
  if "$te_cmd" disable >"$orig_root/err" 2>&1; then fail; fi
  if "$te_cmd" uninstall >"$orig_root/err" 2>&1; then fail; fi
  [[ -d "$user_clone" ]] || fail
}

orig_10_sentinel_isolation() {
  [[ -f "$sentinel_claude" && ! -L "$sentinel_claude" && -x "$sentinel_claude" ]] || fail
  cmp -s "$sentinel_claude" "$sentinel_expected" || fail
}

run_case original 01_help_contract orig_01_help_contract
run_case original 02_readonly_absent_and_doctor orig_02_readonly_absent_and_doctor
run_case original 03_dependency_and_version_failures orig_03_dependency_and_version_failures
run_case original 04_rollback_and_signals orig_04_rollback_and_signals
run_case original 05_install_status_doctor_idempotent orig_05_install_status_doctor_idempotent
run_case original 05b_pin_upgrade_and_reenable orig_05b_pin_upgrade_and_reenable
run_case original 05c_dirty_checkout_and_exact_plugin_id orig_05c_dirty_checkout_and_exact_plugin_id
run_case original 06_scoped_repo_config orig_06_scoped_repo_config
run_case original 07_disable_fail_closed_and_reenable orig_07_disable_fail_closed_and_reenable
run_case original 07b_shared_marketplace_and_uninstall orig_07b_shared_marketplace_and_uninstall
run_case original 08_symlink_managed_paths orig_08_symlink_managed_paths
run_case original 09_user_owned_and_malformed_ownership orig_09_user_owned_and_malformed_ownership
run_case original 10_sentinel_isolation orig_10_sentinel_isolation

# ==============================================================================
# NEW INTEGRATION EVIDENCE CASES (isolated per case)
# ==============================================================================

new_cli_invalid_args_and_missing_values() {
  setup_case_env "cli_invalid"
  local rc=0 out=""

  # Help subcommands/no-arg succeed cleanly without mutations.
  out="$("$te_cmd")"
  [[ "$out" == *"Usage: squad-tokeneconomizer"* ]] || fail
  for sub in help install status disable uninstall; do
    if [[ "$sub" == "help" ]]; then
      "$te_cmd" help >/dev/null
    else
      "$te_cmd" "$sub" --help >/dev/null
    fi
  done
  [[ ! -e "$cache_dir" ]] || fail

  # Unknown command and unknown options per subcommand exit 2.
  rc=0; "$te_cmd" bogus_cmd >"$case_root/err" 2>&1 || rc=$?
  [[ "$rc" == "2" ]] || fail
  grep -q "Unknown command" "$case_root/err" || fail

  for pair in "install:--bogus" "status:--bogus" "disable:--bogus" "uninstall:--bogus"; do
    local sc="${pair%%:*}" fl="${pair#*:}"
    rc=0; "$te_cmd" "$sc" "$fl" >"$case_root/err" 2>&1 || rc=$?
    [[ "$rc" == "2" ]] || fail
  done

  # Missing/empty/invalid --repo values exit 2 and perform no install.
  rc=0; "$te_cmd" install --repo >"$case_root/err" 2>&1 || rc=$?
  [[ "$rc" == "2" ]] || fail
  grep -q "Missing value for --repo" "$case_root/err" || fail

  rc=0; "$te_cmd" install --repo "" >"$case_root/err" 2>&1 || rc=$?
  [[ "$rc" == "2" ]] || fail
  grep -q "Missing value for --repo" "$case_root/err" || fail

  rc=0; "$te_cmd" install --repo "$case_root/missing_repo" >"$case_root/err" 2>&1 || rc=$?
  [[ "$rc" == "2" ]] || fail
  grep -q "Invalid --repo directory" "$case_root/err" || fail

  printf 'not a dir\n' >"$case_root/regular_file"
  rc=0; "$te_cmd" install --repo "$case_root/regular_file" >"$case_root/err" 2>&1 || rc=$?
  [[ "$rc" == "2" ]] || fail
  grep -q "Invalid --repo directory" "$case_root/err" || fail

  rc=0; "$te_cmd" install --repo $'bad\npath' >"$case_root/err" 2>&1 || rc=$?
  [[ "$rc" == "2" ]] || fail
  grep -q "Invalid --repo directory" "$case_root/err" || fail

  [[ ! -e "$cache_dir" ]] || fail
  if [[ -e "$FAKE_STATE/plugins.json" ]]; then
    [[ "$(jq '.installed | length' "$FAKE_STATE/plugins.json")" == "0" ]] || fail
  fi
}

new_cli_empty_repo_equals() {
  setup_case_env "cli_empty_repo_eq"
  local rc=0
  "$te_cmd" install --repo= >"$case_root/out" 2>&1 || rc=$?
  if (( rc == 0 )); then
    echo "Product gap reproduced: 'squad-tokeneconomizer install --repo=' exited 0 instead of failing nonzero (exit 2) and proceeded with install." >&2
    sed 's/^/  out: /' "$case_root/out" >&2
    exit 1
  fi
  grep -qi "missing\|invalid\|--repo" "$case_root/out" || fail
  [[ ! -e "$cache_dir" ]] || fail
  if [[ -e "$FAKE_STATE/plugins.json" ]]; then
    [[ "$(jq '.installed | length' "$FAKE_STATE/plugins.json")" == "0" ]] || fail
  fi
}

new_cli_valid_repo_equals() {
  setup_case_env "cli_valid_repo_eq"
  local repo_eq="$case_root/repo_eq"
  mkdir -p "$repo_eq"
  "$te_cmd" install --repo="$repo_eq" >/dev/null
  [[ "$(jq -r '.microskills' "$TOKENECONOMIZER_HOME/repos/demo-repo-123/config.json")" == "envfacts" ]] || fail
  [[ "$(jq -r '.toolprune' "$TOKENECONOMIZER_HOME/repos/demo-repo-123/config.json")" == "propose" ]] || fail
  [[ "$(jq -r '.loopguard' "$TOKENECONOMIZER_HOME/repos/demo-repo-123/config.json")" == "nudge" ]] || fail
}

new_paths_with_spaces() {
  setup_case_env "paths_spaces" " with spaces"
  local py_space="$case_root/py dir with spaces/python3"
  local repo_space="$case_root/repo with spaces"
  mkdir -p "$repo_space"
  write_fake_python "3.12.2" "$py_space"
  export TE_PYTHON="$py_space"

  local out st doc
  out="$("$te_cmd" install --repo "$repo_space")"
  [[ "$out" == *"$pinned_sha"* ]] || fail
  [[ -f "$cache_dir/ownership.json" ]] || fail
  [[ "$(jq -r '.checkout_dir' "$cache_dir/ownership.json")" == "$cache_dir/upstream" ]] || fail
  [[ "$(jq -r '.microskills' "$TOKENECONOMIZER_HOME/repos/demo-repo-123/config.json")" == "envfacts" ]] || fail

  st="$("$te_cmd" status --json)"
  [[ "$(jq -r '.state' <<<"$st")" == "registered_unverified" ]] || fail
  [[ "$(jq -r '.registration_state' <<<"$st")" == "configured" ]] || fail
  doc="$("$devkit_cmd" --doctor)"
  [[ "$doc" == *"[INFO]"*"tokeneconomizer"*"(registered, unverified:"* ]] || fail

  "$te_cmd" disable >/dev/null
  [[ "$(jq -r '.state' <<<"$("$te_cmd" status --json)")" == "disabled" ]] || fail
  "$te_cmd" install --repo "$repo_space" >/dev/null
  [[ "$(jq -r '.state' <<<"$("$te_cmd" status --json)")" == "registered_unverified" ]] || fail
  "$te_cmd" uninstall >/dev/null
  [[ ! -e "$cache_dir" ]] || fail
  [[ -f "$TOKENECONOMIZER_HOME/repos/demo-repo-123/config.json" ]] || fail
  [[ "$(jq -r '.state' <<<"$("$te_cmd" status --json)")" == "absent" ]] || fail
}

new_malformed_plugin_and_marketplace_json() {
  setup_case_env "malformed_cli_json"
  local bad_payload

  # Malformed plugin list JSON & marketplace list JSON before install must fail closed.
  for bad_payload in '{bad json' '{"installed":"not-an-array"}' '[]'; do
    if FAKE_CODEX_PLUGIN_RAW_OUT="$bad_payload" "$te_cmd" install >"$case_root/err" 2>&1; then fail; fi
    [[ ! -e "$cache_dir" ]] || fail
  done
  for bad_payload in '{bad json' '{"marketplaces":"not-an-array"}' '[]'; do
    if FAKE_CODEX_MKT_RAW_OUT="$bad_payload" "$te_cmd" install >"$case_root/err" 2>&1; then fail; fi
    [[ ! -e "$cache_dir" ]] || fail
  done
  if FAKE_CODEX_MKT_JSON_FAIL=1 "$te_cmd" install >"$case_root/err" 2>&1; then fail; fi
  grep -q "codex plugin marketplace list --json" "$case_root/err" || fail
  [[ ! -e "$cache_dir" ]] || fail

  # Clean install, then malformed JSON during disable & uninstall must fail closed and retain ownership/state.
  "$te_cmd" install >/dev/null
  for bad_payload in '{bad json' '{"installed":"not-an-array"}'; do
    if FAKE_CODEX_PLUGIN_RAW_OUT="$bad_payload" "$te_cmd" disable >"$case_root/err" 2>&1; then fail; fi
    [[ "$(jq -r '.plugin_added_by_devkit' "$cache_dir/ownership.json")" == "true" ]] || fail
    [[ "$(jq '.installed | length' "$FAKE_STATE/plugins.json")" == "1" ]] || fail
    if FAKE_CODEX_PLUGIN_RAW_OUT="$bad_payload" "$te_cmd" uninstall >"$case_root/err" 2>&1; then fail; fi
    [[ -d "$cache_dir/upstream" && -f "$cache_dir/ownership.json" ]] || fail
    [[ "$(jq '.marketplaces | length' "$FAKE_STATE/marketplaces.json")" == "1" ]] || fail
  done
  for bad_payload in '{bad json' '{"marketplaces":"not-an-array"}'; do
    if FAKE_CODEX_MKT_RAW_OUT="$bad_payload" "$te_cmd" disable >"$case_root/err" 2>&1; then fail; fi
    [[ "$(jq '.installed | length' "$FAKE_STATE/plugins.json")" == "1" ]] || fail
    if FAKE_CODEX_MKT_RAW_OUT="$bad_payload" "$te_cmd" uninstall >"$case_root/err" 2>&1; then fail; fi
    [[ -d "$cache_dir/upstream" && -f "$cache_dir/ownership.json" ]] || fail
    [[ "$(jq '.marketplaces | length' "$FAKE_STATE/marketplaces.json")" == "1" ]] || fail
  done

  # Malformed JSON on second codex plugin list call during uninstall preserves marketplace/checkout and updates ownership.
  : >"$FAKE_STATE/list_count"
  if FAKE_CODEX_PLUGIN_RAW_OUT='{bad json' FAKE_CODEX_PLUGIN_RAW_CALL=2 "$te_cmd" uninstall >"$case_root/err" 2>&1; then fail; fi
  grep -q "Failed to query Codex plugins during uninstall" "$case_root/err" || fail
  [[ "$(jq '.installed | length' "$FAKE_STATE/plugins.json")" == "0" ]] || fail
  [[ "$(jq '.marketplaces | length' "$FAKE_STATE/marketplaces.json")" == "1" ]] || fail
  [[ -d "$cache_dir/upstream" ]] || fail
  [[ "$(jq -r '.plugin_added_by_devkit' "$cache_dir/ownership.json")" == "false" ]] || fail
  [[ "$(jq -r '.disabled' "$cache_dir/ownership.json")" == "true" ]] || fail
  [[ "$(jq -r '.marketplace_added_by_devkit' "$cache_dir/ownership.json")" == "true" ]] || fail
}

new_fetch_and_registration_failure_preserves_state() {
  setup_case_env "fetch_mkt_fail"
  # Fresh install failures clean up completely.
  if FAKE_GIT_FAIL=1 "$te_cmd" install >"$case_root/err" 2>&1; then fail; fi
  grep -q "Failed to fetch pinned TokenEconomizer commit" "$case_root/err" || fail
  [[ ! -e "$cache_dir" ]] || fail
  [[ "$(jq '.marketplaces | length' "$FAKE_STATE/marketplaces.json")" == "0" ]] || fail

  if FAKE_CODEX_MKT_ADD_FAIL=1 "$te_cmd" install >"$case_root/err" 2>&1; then fail; fi
  grep -q "Failed to register Codex marketplace" "$case_root/err" || fail
  [[ ! -e "$cache_dir" ]] || fail
  [[ "$(jq '.marketplaces | length' "$FAKE_STATE/marketplaces.json")" == "0" ]] || fail
  [[ "$(jq '.installed | length' "$FAKE_STATE/plugins.json")" == "0" ]] || fail

  # Upgrade failure from preexisting old_sha checkout preserves prior checkout, ownership, marketplace, and plugin.
  "$te_cmd" install >/dev/null
  local old_sha="0000000000000000000000000000000000000002"
  printf '%s\n' "$old_sha" >"$cache_dir/upstream/.git/HEAD_SHA"
  printf '%s\n' "$old_sha" >"$cache_dir/upstream/plugin/pin.txt"
  printf '%s\n' "$old_sha" >"$CODEX_HOME/plugins/cache/tokeneconomizer/tokeneconomizer/0.1.0/pin.txt"
  jq --arg p "$old_sha" '.pinned_commit = $p' "$cache_dir/ownership.json" >"$cache_dir/ownership.json.tmp" && mv "$cache_dir/ownership.json.tmp" "$cache_dir/ownership.json"

  if FAKE_GIT_FAIL=1 "$te_cmd" install >"$case_root/err" 2>&1; then fail; fi
  [[ "$(cat "$cache_dir/upstream/.git/HEAD_SHA")" == "$old_sha" ]] || fail
  [[ "$(cat "$cache_dir/upstream/plugin/pin.txt")" == "$old_sha" ]] || fail
  [[ "$(jq -r '.pinned_commit' "$cache_dir/ownership.json")" == "$old_sha" ]] || fail
  [[ "$(jq '.installed | length' "$FAKE_STATE/plugins.json")" == "1" ]] || fail
  [[ "$(jq '.marketplaces | length' "$FAKE_STATE/marketplaces.json")" == "1" ]] || fail
  ! compgen -G "$cache_dir/upstream.staging.*" >/dev/null || fail

  # Upgrade plugin-add failure restores backup_checkout (old_sha) back to upstream.
  if FAKE_CODEX_ADD_FAIL=1 "$te_cmd" install >"$case_root/err" 2>&1; then fail; fi
  [[ "$(cat "$cache_dir/upstream/.git/HEAD_SHA")" == "$old_sha" ]] || fail
  [[ "$(cat "$cache_dir/upstream/plugin/pin.txt")" == "$old_sha" ]] || fail
  [[ "$(jq -r '.pinned_commit' "$cache_dir/ownership.json")" == "$old_sha" ]] || fail
  [[ "$(jq '.installed | length' "$FAKE_STATE/plugins.json")" == "1" ]] || fail
  [[ "$(jq '.marketplaces | length' "$FAKE_STATE/marketplaces.json")" == "1" ]] || fail
  ! compgen -G "$cache_dir/upstream.backup.*" >/dev/null || fail
}

new_removal_failure_preserves_ownership() {
  setup_case_env "rm_fail"
  "$te_cmd" install >/dev/null

  if FAKE_CODEX_RM_FAIL=1 "$te_cmd" disable >"$case_root/err" 2>&1; then fail; fi
  grep -q "ownership marker retained" "$case_root/err" || fail
  [[ "$(jq -r '.plugin_added_by_devkit' "$cache_dir/ownership.json")" == "true" ]] || fail
  [[ "$(jq -r '.disabled' "$cache_dir/ownership.json")" == "false" ]] || fail
  [[ "$(jq '.installed | length' "$FAKE_STATE/plugins.json")" == "1" ]] || fail

  if FAKE_CODEX_RM_FAIL=1 "$te_cmd" uninstall >"$case_root/err" 2>&1; then fail; fi
  grep -q "Failed to remove devkit-owned Codex plugin" "$case_root/err" || fail
  [[ "$(jq -r '.plugin_added_by_devkit' "$cache_dir/ownership.json")" == "true" ]] || fail
  [[ "$(jq '.installed | length' "$FAKE_STATE/plugins.json")" == "1" ]] || fail
  [[ "$(jq '.marketplaces | length' "$FAKE_STATE/marketplaces.json")" == "1" ]] || fail
  [[ -d "$cache_dir/upstream" ]] || fail

  if FAKE_CODEX_MKT_RM_FAIL=1 "$te_cmd" uninstall >"$case_root/err" 2>&1; then fail; fi
  grep -q "Failed to remove devkit-owned Codex marketplace" "$case_root/err" || fail
  [[ "$(jq '.installed | length' "$FAKE_STATE/plugins.json")" == "0" ]] || fail
  [[ "$(jq '.marketplaces | length' "$FAKE_STATE/marketplaces.json")" == "1" ]] || fail
  [[ -d "$cache_dir/upstream" ]] || fail
  [[ "$(jq -r '.plugin_added_by_devkit' "$cache_dir/ownership.json")" == "false" ]] || fail
  [[ "$(jq -r '.disabled' "$cache_dir/ownership.json")" == "true" ]] || fail
  [[ "$(jq -r '.marketplace_added_by_devkit' "$cache_dir/ownership.json")" == "true" ]] || fail
}

new_malformed_and_symlink_scoped_json() {
  setup_case_env "malformed_scoped_json"
  local repo_d="$case_root/repo_d"
  local repo_cfg="$TOKENECONOMIZER_HOME/repos/demo-repo-123/config.json"
  local global_cfg="$TOKENECONOMIZER_HOME/config.json"
  local sentinel_cfg="$case_root/sentinel_repo_cfg.json"
  mkdir -p "$repo_d" "$(dirname "$repo_cfg")"
  printf '{"global_sentinel":"keep"}\n' >"$global_cfg"
  cp "$global_cfg" "$case_root/global.expected"

  # Malformed JSON object syntax.
  printf '{bad json\n' >"$repo_cfg"
  cp "$repo_cfg" "$case_root/malformed.expected"
  local rc=0
  "$te_cmd" install --repo "$repo_d" >"$case_root/err" 2>&1 || rc=$?
  if (( rc == 0 )); then
    echo "Product bug reproduced: 'install --repo' exited 0 despite malformed scoped config ($repo_cfg)." >&2
    sed 's/^/  out: /' "$case_root/err" >&2
    exit 1
  fi
  grep -q "Refusing to modify malformed JSON config" "$case_root/err" || fail
  cmp -s "$repo_cfg" "$case_root/malformed.expected" || fail
  cmp -s "$global_cfg" "$case_root/global.expected" || fail

  # Valid JSON but non-object (array).
  printf '["not","an","object"]\n' >"$repo_cfg"
  cp "$repo_cfg" "$case_root/array.expected"
  rc=0
  "$te_cmd" install --repo "$repo_d" >"$case_root/err" 2>&1 || rc=$?
  if (( rc == 0 )); then
    echo "Product bug reproduced: 'install --repo' exited 0 despite non-object scoped config ($repo_cfg)." >&2
    exit 1
  fi
  grep -q "Refusing to modify malformed JSON config" "$case_root/err" || fail
  cmp -s "$repo_cfg" "$case_root/array.expected" || fail
  cmp -s "$global_cfg" "$case_root/global.expected" || fail

  # Symlinked repo config file is refused without modifying target.
  rm -f "$repo_cfg"
  printf '{"target":"untouched"}\n' >"$sentinel_cfg"
  cp "$sentinel_cfg" "$case_root/sentinel_cfg.expected"
  ln -s "$sentinel_cfg" "$repo_cfg"
  rc=0
  "$te_cmd" install --repo "$repo_d" >"$case_root/err" 2>&1 || rc=$?
  if (( rc == 0 )); then
    echo "Product bug reproduced: 'install --repo' exited 0 despite symlinked scoped config ($repo_cfg)." >&2
    exit 1
  fi
  grep -q "Refusing symlinked config file" "$case_root/err" || fail
  [[ -L "$repo_cfg" ]] || fail
  cmp -s "$sentinel_cfg" "$case_root/sentinel_cfg.expected" || fail
  cmp -s "$global_cfg" "$case_root/global.expected" || fail
}

new_legacy_aliases_and_global_sentinels() {
  setup_case_env "legacy_aliases"
  local repo_e="$case_root/repo_e"
  local repo_cfg="$TOKENECONOMIZER_HOME/repos/demo-repo-123/config.json"
  local global_cfg="$TOKENECONOMIZER_HOME/config.json"
  local out st
  mkdir -p "$repo_e" "$(dirname "$repo_cfg")"

  # Full legacy aliases + global sentinel untouched.
  printf '{"inject":"off","untool":"auto","spiral":"off"}\n' >"$repo_cfg"
  printf '{"microskills":"custom","toolprune":"off","loopguard":"off"}\n' >"$global_cfg"
  cp "$global_cfg" "$case_root/global.expected"

  out="$("$te_cmd" install --repo "$repo_e")"
  [[ "$out" == *"Retained existing repo preferences"* ]] || fail
  [[ "$out" != *"Applied repo-scoped preferences"* ]] || fail
  [[ "$(jq -r '.inject' "$repo_cfg")" == "off" ]] || fail
  [[ "$(jq -r '.untool' "$repo_cfg")" == "auto" ]] || fail
  [[ "$(jq -r '.spiral' "$repo_cfg")" == "off" ]] || fail
  [[ "$(jq -r 'has("microskills") or has("toolprune") or has("loopguard")' "$repo_cfg")" == "false" ]] || fail
  cmp -s "$global_cfg" "$case_root/global.expected" || fail

  # Partial legacy alias retains inject and fills only missing toolprune/loopguard.
  printf '{"inject":"custom"}\n' >"$repo_cfg"
  out="$("$te_cmd" install --repo "$repo_e")"
  [[ "$out" == *"Retained existing repo preferences"* && "$out" == *"inject=custom"* ]] || fail
  [[ "$out" == *"Applied repo-scoped preferences"* ]] || fail
  [[ "$(jq -r '.inject' "$repo_cfg")" == "custom" ]] || fail
  [[ "$(jq -r 'has("microskills")' "$repo_cfg")" == "false" ]] || fail
  [[ "$(jq -r '.toolprune' "$repo_cfg")" == "propose" ]] || fail
  [[ "$(jq -r '.loopguard' "$repo_cfg")" == "nudge" ]] || fail
  cmp -s "$global_cfg" "$case_root/global.expected" || fail

  # Global config status summaries: overrides, no overrides, malformed JSON.
  st="$("$te_cmd" status --json)"
  [[ "$(jq -r '.global_config' <<<"$st")" == "microskills=custom, toolprune=off, loopguard=off" ]] || fail

  printf '{"unrelated":true}\n' >"$global_cfg"
  st="$("$te_cmd" status --json)"
  [[ "$(jq -r '.global_config' <<<"$st")" == "present (no mechanism overrides)" ]] || fail

  printf '{bad json\n' >"$global_cfg"
  st="$("$te_cmd" status --json)"
  [[ "$(jq -r '.global_config' <<<"$st")" == "present (malformed JSON)" ]] || fail
}

new_independent_codex_home_ownership() {
  setup_case_env "codex_home_indep"
  local home_a="$case_root/codex_a" state_a="$case_root/state_a" cache_a="$case_root/cache_a"
  local home_b="$case_root/codex_b" state_b="$case_root/state_b" cache_b="$case_root/cache_b"
  local user_clone_b="$case_root/user_clone_b"
  mkdir -p "$home_a" "$state_a" "$home_b" "$state_b" "$user_clone_b/.claude-plugin" "$user_clone_b/plugin"

  # Profile A: devkit-managed install using non-default CODEX_HOME and cache_a.
  CODEX_HOME="$home_a" FAKE_STATE="$state_a" SQUAD_TOKENECONOMIZER_CACHE_DIR="$cache_a" "$te_cmd" install >/dev/null
  [[ ! -e "$HOME/.codex" ]] || fail
  [[ "$(jq -r '.codex_home' "$cache_a/ownership.json")" == "$home_a" ]] || fail

  # Profile B: independent user-owned marketplace & plugin.
  CODEX_HOME="$home_b" FAKE_STATE="$state_b" codex plugin marketplace add "$user_clone_b" --json >/dev/null
  CODEX_HOME="$home_b" FAKE_STATE="$state_b" codex plugin add tokeneconomizer@tokeneconomizer --json >/dev/null

  snapshot_trees "$home_a" "$state_a/marketplaces.json" "$state_a/plugins.json" "$cache_a" >"$case_root/snap_a_before"
  snapshot_trees "$home_b" "$state_b/marketplaces.json" "$state_b/plugins.json" "$user_clone_b" >"$case_root/snap_b_before"

  # Checking or mutating Profile B (even when pointed at cache_a owned by home_a) must not delete cache_a or touch A/B.
  local st_b doc_b
  st_b="$(CODEX_HOME="$home_b" FAKE_STATE="$state_b" SQUAD_TOKENECONOMIZER_CACHE_DIR="$cache_a" "$te_cmd" status --json)"
  [[ "$(jq -r '.state' <<<"$st_b")" == "unowned" ]] || fail
  doc_b="$(CODEX_HOME="$home_b" FAKE_STATE="$state_b" SQUAD_TOKENECONOMIZER_CACHE_DIR="$cache_a" "$devkit_cmd" --doctor)"
  [[ "$doc_b" == *"[INFO]"*"tokeneconomizer"*"outside squad-devkit"* ]] || fail

  if CODEX_HOME="$home_b" FAKE_STATE="$state_b" SQUAD_TOKENECONOMIZER_CACHE_DIR="$cache_a" "$te_cmd" install >"$case_root/err" 2>&1; then fail; fi
  if CODEX_HOME="$home_b" FAKE_STATE="$state_b" SQUAD_TOKENECONOMIZER_CACHE_DIR="$cache_a" "$te_cmd" disable >"$case_root/err" 2>&1; then fail; fi
  if CODEX_HOME="$home_b" FAKE_STATE="$state_b" SQUAD_TOKENECONOMIZER_CACHE_DIR="$cache_a" "$te_cmd" uninstall >"$case_root/out_b" 2>&1; then fail; fi

  if [[ ! -d "$cache_a/upstream" || ! -f "$cache_a/ownership.json" ]]; then
    echo "Product bug reproduced: 'uninstall' under CODEX_HOME=$home_b deleted cache owned by CODEX_HOME=$home_a ($cache_a)." >&2
    sed 's/^/  out: /' "$case_root/out_b" >&2
    exit 1
  fi
  grep -q "preserved user-owned state\|different CODEX_HOME" "$case_root/out_b" || fail

  # Profile B with its own cache_b is also strictly unowned.
  if CODEX_HOME="$home_b" FAKE_STATE="$state_b" SQUAD_TOKENECONOMIZER_CACHE_DIR="$cache_b" "$te_cmd" install >"$case_root/err" 2>&1; then fail; fi
  CODEX_HOME="$home_b" FAKE_STATE="$state_b" SQUAD_TOKENECONOMIZER_CACHE_DIR="$cache_b" "$te_cmd" uninstall >/dev/null

  snapshot_trees "$home_a" "$state_a/marketplaces.json" "$state_a/plugins.json" "$cache_a" >"$case_root/snap_a_after"
  snapshot_trees "$home_b" "$state_b/marketplaces.json" "$state_b/plugins.json" "$user_clone_b" >"$case_root/snap_b_after"
  cmp -s "$case_root/snap_a_before" "$case_root/snap_a_after" || fail
  cmp -s "$case_root/snap_b_before" "$case_root/snap_b_after" || fail

  # Missing, non-string and relative marker homes must also fail closed.
  cp "$cache_a/ownership.json" "$case_root/valid_marker"
  local filter
  for filter in 'del(.codex_home)' '.codex_home = 42' '.codex_home = "relative"'; do
    jq "$filter" "$case_root/valid_marker" >"$cache_a/ownership.json"
    snapshot_trees "$home_a" "$home_b" "$state_a/marketplaces.json" "$state_a/plugins.json" "$state_b/marketplaces.json" "$state_b/plugins.json" "$cache_a" >"$case_root/malformed_before"
    if CODEX_HOME="$home_a" FAKE_STATE="$state_a" SQUAD_TOKENECONOMIZER_CACHE_DIR="$cache_a" "$te_cmd" uninstall >"$case_root/err" 2>&1; then fail; fi
    grep -q 'malformed ownership marker' "$case_root/err" || fail
    snapshot_trees "$home_a" "$home_b" "$state_a/marketplaces.json" "$state_a/plugins.json" "$state_b/marketplaces.json" "$state_b/plugins.json" "$cache_a" >"$case_root/malformed_after"
    cmp -s "$case_root/malformed_before" "$case_root/malformed_after" || fail
  done
  cp "$case_root/valid_marker" "$cache_a/ownership.json"

  # Uninstalling Profile A leaves Profile B untouched and $HOME/.codex still absent.
  CODEX_HOME="$home_a" FAKE_STATE="$state_a" SQUAD_TOKENECONOMIZER_CACHE_DIR="$cache_a" "$te_cmd" uninstall >/dev/null
  snapshot_trees "$home_b" "$state_b/marketplaces.json" "$state_b/plugins.json" "$user_clone_b" >"$case_root/snap_b_after_a_uninst"
  cmp -s "$case_root/snap_b_before" "$case_root/snap_b_after_a_uninst" || fail
  [[ ! -e "$HOME/.codex" ]] || fail
}

new_readonly_snapshots_and_tripwires() {
  setup_case_env "readonly_tripwires"

  assert_readonly_across_tools() {
    local expected_state="$1" expected_doc_tag="$2"
    local st doc
    local trip_file="$case_root/tripwire.hit"
    rm -f "$trip_file"
    snapshot_trees "$HOME" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME" "$CODEX_HOME" "$TOKENECONOMIZER_HOME" >"$case_root/snap.before"
    : >"$FAKE_CODEX_LOG"
    : >"$FAKE_GIT_LOG"
    st="$(FAKE_CODEX_TRIPWIRE_ANY=1 FAKE_TRIPWIRE_FILE="$trip_file" FAKE_GIT_TRIPWIRE_NET=1 FAKE_PY_TRIPWIRE_BOOTSTRAP=1 "$te_cmd" status --json)"
    if [[ -s "$trip_file" || -s "$FAKE_CODEX_LOG" ]]; then
      echo "Product bug reproduced: readonly 'status' invoked codex unexpectedly:" >&2
      cat "$FAKE_CODEX_LOG" "$trip_file" 2>/dev/null | sed 's/^/  codex: /' >&2
      exit 1
    fi
    [[ "$(jq -r '.state' <<<"$st")" == "$expected_state" ]] || fail
    [[ "$(jq -r '.codex_cli_introspected' <<<"$st")" == "false" ]] || fail
    [[ "$(jq -r '.codex_version' <<<"$st")" == "unprobed" ]] || fail
    [[ "$(jq -r '.codex_compatibility' <<<"$st")" == "unprobed" ]] || fail
    [[ "$(jq -r '.codex_path' <<<"$st")" == "$FAKE_BIN_DIR/codex" ]] || fail
    [[ "$(jq -r '.codex_reason' <<<"$st")" == *"version/compatibility unprobed"* ]] || fail
    FAKE_CODEX_TRIPWIRE_ANY=1 FAKE_TRIPWIRE_FILE="$trip_file" FAKE_GIT_TRIPWIRE_NET=1 FAKE_PY_TRIPWIRE_BOOTSTRAP=1 "$te_cmd" status >/dev/null
    if [[ -s "$trip_file" || -s "$FAKE_CODEX_LOG" ]]; then
      echo "Product bug reproduced: readonly 'status' invoked codex unexpectedly:" >&2
      cat "$FAKE_CODEX_LOG" "$trip_file" 2>/dev/null | sed 's/^/  codex: /' >&2
      exit 1
    fi
    snapshot_trees "$HOME" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME" "$CODEX_HOME" "$TOKENECONOMIZER_HOME" >"$case_root/snap.after"
    cmp -s "$case_root/snap.before" "$case_root/snap.after" || fail

    # Doctor invokes other optional CLIs (e.g. opencode) and general version probes;
    # verify integration helper invokes no codex plugin commands and mutates no tokeneconomizer/codex/devkit trees.
    snapshot_trees "$XDG_CACHE_HOME/squad-devkit" "$CODEX_HOME" "$TOKENECONOMIZER_HOME" "$HOME/.cache" "$HOME/.codex" "$HOME/.tokeneconomizer" >"$case_root/doc_snap.before"
    : >"$FAKE_CODEX_LOG"
    doc="$(FAKE_CODEX_TRIPWIRE_PLUGIN=1 FAKE_GIT_TRIPWIRE_NET=1 FAKE_PY_TRIPWIRE_BOOTSTRAP=1 "$devkit_cmd" --doctor)"
    [[ "$doc" == *"$expected_doc_tag"*"tokeneconomizer"* ]] || fail
    [[ "$doc" == *"Result: Environment ready for squad-devkit."* ]] || fail
    ! grep -q "plugin" "$FAKE_CODEX_LOG" || fail
    snapshot_trees "$XDG_CACHE_HOME/squad-devkit" "$CODEX_HOME" "$TOKENECONOMIZER_HOME" "$HOME/.cache" "$HOME/.codex" "$HOME/.tokeneconomizer" >"$case_root/doc_snap.after"
    cmp -s "$case_root/doc_snap.before" "$case_root/doc_snap.after" || fail
  }

  # 1) absent
  assert_readonly_across_tools "absent" "[OPTIONAL]"

  # 2) registered_unverified
  "$te_cmd" install >/dev/null
  assert_readonly_across_tools "registered_unverified" "[INFO]"

  # 3) disabled
  "$te_cmd" disable >/dev/null
  assert_readonly_across_tools "disabled" "[OPTIONAL]"

  # 4) unsupported (dirty checkout when installed/enabled)
  "$te_cmd" install >/dev/null
  touch "$cache_dir/upstream/extra_dirty_file"
  assert_readonly_across_tools "unsupported" "[WARN]"
  rm -f "$cache_dir/upstream/extra_dirty_file"
  "$te_cmd" uninstall >/dev/null

  # 5) unowned (user-owned marketplace & plugin + doctor output)
  local user_clone="$case_root/user_clone"
  mkdir -p "$user_clone/.claude-plugin" "$user_clone/plugin"
  codex plugin marketplace add "$user_clone" --json >/dev/null
  codex plugin add tokeneconomizer@tokeneconomizer --json >/dev/null
  assert_readonly_across_tools "unowned" "[INFO]"
}

new_broken_paths_symlinks_versions_and_toml() {
  setup_case_env "broken_paths_versions"

  # 1) Control characters in CODEX_HOME are rejected by install.
  if CODEX_HOME=$'/tmp/bad\tcodex' "$te_cmd" install >"$case_root/err" 2>&1; then fail; fi
  grep -q "Invalid control characters" "$case_root/err" || fail

  # 2) Invalid TE_PYTHON fails install with invalid_env reason.
  if TE_PYTHON="$case_root/no_such_python" "$te_cmd" install >"$case_root/err" 2>&1; then fail; fi
  grep -q "TE_PYTHON is not executable" "$case_root/err" || fail

  # 3) Unparseable codex --version -> blocked on install.
  if FAKE_CODEX_RAW_VERSION="codex-cli unknown-dev" "$te_cmd" install >"$case_root/err" 2>&1; then fail; fi
  grep -q "could not parse codex --version" "$case_root/err" || fail

  # 4) Install across tested & experimental version bands reports exact compatibility and never verified.
  local st inst_out doc
  for v_band in "0.145.0:experimental" "0.153.1:tested" "0.164.0:tested" "0.169.0:experimental"; do
    local v="${v_band%%:*}" compat="${v_band#*:}"
    inst_out="$(FAKE_CODEX_VER="$v" "$te_cmd" install)"
    [[ "$inst_out" == *"Codex CLI:  $v ($compat)"* ]] || fail
    st="$("$te_cmd" status --json)"
    [[ "$(jq -r '.state' <<<"$st")" == "registered_unverified" ]] || fail
  done
  st="$(TE_PYTHON="$case_root/no_such_python" "$te_cmd" status --json)"
  [[ "$(jq -r '.python_status' <<<"$st")" == "invalid_env" ]] || fail
  [[ "$(jq -r '.state' <<<"$st")" == "unsupported" ]] || fail

  # Missing codex binary in read-only mode reports missing compatibility and unsupported state without executing codex.
  mv "$FAKE_BIN_DIR/codex" "$FAKE_BIN_DIR/codex.missing"
  st="$(FAKE_CODEX_TRIPWIRE_ANY=1 "$te_cmd" status --json)"
  [[ "$(jq -r '.codex_path' <<<"$st")" == "" ]] || fail
  [[ "$(jq -r '.codex_version' <<<"$st")" == "" ]] || fail
  [[ "$(jq -r '.codex_compatibility' <<<"$st")" == "missing" ]] || fail
  [[ "$(jq -r '.state' <<<"$st")" == "unsupported" ]] || fail
  doc="$("$devkit_cmd" --doctor)"
  [[ "$doc" == *"[WARN]"*"tokeneconomizer"*"(unsupported:"* ]] || fail
  [[ "$doc" == *"Result: Environment ready for squad-devkit."* ]] || fail
  mv "$FAKE_BIN_DIR/codex.missing" "$FAKE_BIN_DIR/codex"

  # 5) Symlinked .git or required checkout file or missing required file -> unsupported.
  mv "$cache_dir/upstream/.git" "$cache_dir/upstream/.git.real"
  ln -s "$cache_dir/upstream/.git.real" "$cache_dir/upstream/.git"
  [[ "$(jq -r '.state' <<<"$("$te_cmd" status --json)")" == "unsupported" ]] || fail
  if "$te_cmd" install >"$case_root/err" 2>&1; then fail; fi
  rm -f "$cache_dir/upstream/.git"
  mv "$cache_dir/upstream/.git.real" "$cache_dir/upstream/.git"

  mv "$cache_dir/upstream/LICENSE" "$cache_dir/upstream/LICENSE.real"
  ln -s "$cache_dir/upstream/LICENSE.real" "$cache_dir/upstream/LICENSE"
  [[ "$(jq -r '.state' <<<"$("$te_cmd" status --json)")" == "unsupported" ]] || fail
  rm -f "$cache_dir/upstream/LICENSE"
  mv "$cache_dir/upstream/LICENSE.real" "$cache_dir/upstream/LICENSE"

  # 6) Symlinked CODEX_HOME/config.toml is not followed.
  mv "$CODEX_HOME/config.toml" "$CODEX_HOME/config.toml.real"
  ln -s "$CODEX_HOME/config.toml.real" "$CODEX_HOME/config.toml"
  st="$("$te_cmd" status --json)"
  [[ "$(jq -r '.registration_state' <<<"$st")" == "unknown" ]] || fail
  [[ "$(jq -r '.plugin_installed' <<<"$st")" == "null" ]] || fail
  rm -f "$CODEX_HOME/config.toml"
  mv "$CODEX_HOME/config.toml.real" "$CODEX_HOME/config.toml"

  # 7) Conservative TOML parser: unrelated sections, single quotes, inline comments.
  cat >"$CODEX_HOME/config.toml" <<EOF
[marketplaces.other]
source = "/tmp/other-marketplace"

[plugins."other@other"]
enabled = false

[marketplaces.tokeneconomizer] # inline comment
source = "$cache_dir/upstream" # comment

[plugins.'tokeneconomizer@tokeneconomizer'] # single-quoted plugin section
enabled = true # inline comment
EOF
  st="$("$te_cmd" status --json)"
  [[ "$(jq -r '.state' <<<"$st")" == "registered_unverified" ]] || fail
  [[ "$(jq -r '.registration_state' <<<"$st")" == "configured" ]] || fail
  [[ "$(jq -r '.plugin_installed' <<<"$st")" == "true" ]] || fail
  [[ "$(jq -r '.plugin_enabled' <<<"$st")" == "true" ]] || fail

  # 8) Manual plugin removal outside devkit followed by uninstall still cleans unshared marketplace & checkout.
  jq '.installed = []' "$FAKE_STATE/plugins.json" >"$FAKE_STATE/plugins.json.tmp" && mv "$FAKE_STATE/plugins.json.tmp" "$FAKE_STATE/plugins.json"
  "$te_cmd" uninstall >/dev/null
  [[ "$(jq '.marketplaces | length' "$FAKE_STATE/marketplaces.json")" == "0" ]] || fail
  [[ ! -e "$cache_dir" ]] || fail

  # 9) Unowned checkout directory (without ownership.json or registration) is reported unowned and never overwritten/deleted.
  mkdir -p "$cache_dir/upstream"
  printf 'user_file_sentinel\n' >"$cache_dir/upstream/keep.txt"
  [[ "$(jq -r '.state' <<<"$("$te_cmd" status --json)")" == "unowned" ]] || fail
  if "$te_cmd" install >"$case_root/err" 2>&1; then fail; fi
  grep -q "Refusing to overwrite unowned directory" "$case_root/err" || fail
  "$te_cmd" uninstall >"$case_root/out_unowned" 2>&1
  grep -q "preserved user-owned state" "$case_root/out_unowned" || fail
  [[ "$(cat "$cache_dir/upstream/keep.txt")" == "user_file_sentinel" ]] || fail
}

new_quoted_hash_source() {
  setup_case_env "quoted_hash" " # literal"
  "$te_cmd" install >/dev/null
  source "$repo_root/scripts/lib/squad-tokeneconomizer.sh"
  local quote comment st
  for quote in "\"" "'"; do
    for comment in "" " # trailing comment"; do
      printf '[marketplaces.tokeneconomizer]\nsource = %s%s%s%s\n[plugins."tokeneconomizer@tokeneconomizer"]\nenabled = true\n' \
        "$quote" "$cache_dir/upstream" "$quote" "$comment" >"$CODEX_HOME/config.toml"
      snapshot_trees "$HOME" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME" "$CODEX_HOME" "$TOKENECONOMIZER_HOME" >"$case_root/before"
      : >"$FAKE_CODEX_LOG"
      squad_te_read_local_codex_config "$CODEX_HOME/config.toml"
      [[ "$SQUAD_TE_CFG_MKT_SOURCE" == "$cache_dir/upstream" ]] || fail
      st="$(FAKE_CODEX_TRIPWIRE_ANY=1 "$te_cmd" status --json)"
      [[ "$(jq -r '.state' <<<"$st")" == "registered_unverified" ]] || fail
      [[ "$(jq -r '.owned_by_devkit' <<<"$st")" == "true" ]] || fail
      [[ "$(jq -r '.registration_state' <<<"$st")" == "configured" ]] || fail
      [[ ! -s "$FAKE_CODEX_LOG" ]] || fail
      snapshot_trees "$HOME" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME" "$CODEX_HOME" "$TOKENECONOMIZER_HOME" >"$case_root/after"
      cmp -s "$case_root/before" "$case_root/after" || fail
    done
  done
}

new_owned_checkout_move_signals() {
  local sig rc real_mv
  real_mv="$(command -v mv)"
  for sig in TERM INT; do
    setup_case_env "move_signal_$sig"
    "$te_cmd" install >/dev/null
    local old_sha="0000000000000000000000000000000000000003"
    printf '%s\n' "$old_sha" >"$cache_dir/upstream/.git/HEAD_SHA"
    printf '%s\n' "$old_sha" >"$cache_dir/upstream/plugin/pin.txt"
    jq --arg p "$old_sha" '.pinned_commit = $p' "$cache_dir/ownership.json" >"$case_root/marker"
    mv "$case_root/marker" "$cache_dir/ownership.json"
    mkdir -p "$TOKENECONOMIZER_HOME/repos/demo"
    printf 'learned sentinel\n' >"$TOKENECONOMIZER_HOME/repos/demo/learned.json"
    snapshot_trees "$cache_dir" "$CODEX_HOME" "$TOKENECONOMIZER_HOME" "$FAKE_STATE/marketplaces.json" "$FAKE_STATE/plugins.json" >"$case_root/before"
    cat >"$FAKE_BIN_DIR/mv" <<'EOF'
#!/usr/bin/env bash
"$TE_TEST_REAL_MV" "$@" || exit $?
if [[ "$1" == "$TE_TEST_CHECKOUT".staging.* && "$2" == "$TE_TEST_CHECKOUT" ]]; then
  printf '%s\n' "$TE_TEST_SIGNAL" >"$TE_TEST_SIGNAL_HIT"
  kill -"$TE_TEST_SIGNAL" "$PPID"
fi
EOF
    chmod +x "$FAKE_BIN_DIR/mv"
    rc=0
    TE_TEST_REAL_MV="$real_mv" TE_TEST_CHECKOUT="$cache_dir/upstream" TE_TEST_SIGNAL="$sig" TE_TEST_SIGNAL_HIT="$case_root/hit" \
      run_with_default_sigint "$te_cmd" install >"$case_root/out" 2>&1 || rc=$?
    [[ "$(cat "$case_root/hit")" == "$sig" ]] || fail
    if [[ "$sig" == TERM ]]; then [[ "$rc" == 143 ]] || fail; else [[ "$rc" == 130 ]] || fail; fi
    grep -q 'rolled back incomplete' "$case_root/out" || fail
    snapshot_trees "$cache_dir" "$CODEX_HOME" "$TOKENECONOMIZER_HOME" "$FAKE_STATE/marketplaces.json" "$FAKE_STATE/plugins.json" >"$case_root/after"
    cmp -s "$case_root/before" "$case_root/after" || fail
  done
}

new_final_sentinel_check() {
  [[ -f "$sentinel_claude" && ! -L "$sentinel_claude" && -x "$sentinel_claude" ]] || fail
  cmp -s "$sentinel_claude" "$sentinel_expected" || fail
}

run_case new 01_cli_invalid_args_and_missing_values new_cli_invalid_args_and_missing_values
run_case new 02_cli_empty_repo_equals new_cli_empty_repo_equals
run_case new 03_cli_valid_repo_equals new_cli_valid_repo_equals
run_case new 04_paths_with_spaces new_paths_with_spaces
run_case new 05_malformed_plugin_and_marketplace_json new_malformed_plugin_and_marketplace_json
run_case new 06_fetch_and_registration_failure_preserves_state new_fetch_and_registration_failure_preserves_state
run_case new 07_removal_failure_preserves_ownership new_removal_failure_preserves_ownership
run_case new 08_malformed_and_symlink_scoped_json new_malformed_and_symlink_scoped_json
run_case new 09_legacy_aliases_and_global_sentinels new_legacy_aliases_and_global_sentinels
run_case new 10_independent_codex_home_ownership new_independent_codex_home_ownership
run_case new 11_readonly_snapshots_and_tripwires new_readonly_snapshots_and_tripwires
run_case new 12_broken_paths_symlinks_versions_and_toml new_broken_paths_symlinks_versions_and_toml
run_case new 14_quoted_hash_source new_quoted_hash_source
run_case new 15_owned_checkout_move_signals new_owned_checkout_move_signals
run_case new 13_final_sentinel_check new_final_sentinel_check

total_cases=$((orig_total + new_total))
total_pass=$((orig_pass + new_pass))
total_fail=$((orig_fail + new_fail))
printf 'Summary: %d/%d passed (%d failed) | original: %d/%d | new: %d/%d\n' \
  "$total_pass" "$total_cases" "$total_fail" "$orig_pass" "$orig_total" "$new_pass" "$new_total"

if (( total_fail > 0 )); then
  echo "squad_tokeneconomizer_smoke: FAIL"
  exit 1
fi

echo "squad_tokeneconomizer_smoke: PASS"
