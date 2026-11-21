#!/usr/bin/env bash
# Opt-in real-CLI and real-upstream contract evidence test for TokenEconomizer.
# Default invocation skips without network or real CLI calls; set SQUAD_TE_REAL_CLI=1 to run.
# Never invokes codex exec/login/model/hooks runtime or modifies real user HOME/CODEX_HOME.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
te_cmd="$repo_root/scripts/squad-tokeneconomizer.sh"
pinned_sha="583fff78bf504b59d542f953c31e87d01d02ab42"
upstream_url="https://github.com/microsoft/TokenEconomizer.git"
expected_license="Apache-2.0"

pass_count=0
fail_count=0
skip_count=0

record_pass() {
  local name="$1" detail="${2:-}"
  pass_count=$((pass_count + 1))
  if [[ -n "$detail" ]]; then
    printf 'PASS: %s — %s\n' "$name" "$detail"
  else
    printf 'PASS: %s\n' "$name"
  fi
}

record_fail() {
  local name="$1" detail="${2:-}"
  fail_count=$((fail_count + 1))
  if [[ -n "$detail" ]]; then
    printf 'FAIL: %s — %s\n' "$name" "$detail" >&2
  else
    printf 'FAIL: %s\n' "$name" >&2
  fi
}

record_skip() {
  local name="$1" detail="${2:-}"
  skip_count=$((skip_count + 1))
  if [[ -n "$detail" ]]; then
    printf 'SKIP: %s — %s\n' "$name" "$detail"
  else
    printf 'SKIP: %s\n' "$name"
  fi
}

print_summary_and_exit() {
  printf 'Summary: PASS=%d FAIL=%d SKIP=%d\n' "$pass_count" "$fail_count" "$skip_count"
  if (( fail_count > 0 )); then
    exit 1
  fi
  exit 0
}

if [[ "${SQUAD_TE_REAL_CLI:-0}" != "1" ]]; then
  printf 'TokenEconomizer Real CLI Contract Suite\n'
  printf '  pinned_sha: %s\n' "$pinned_sha"
  printf '  mode:       opt-out (set SQUAD_TE_REAL_CLI=1 to run real git/codex/upstream contract checks)\n'
  record_skip "real_cli_opt_in" "SQUAD_TE_REAL_CLI=1 not set; no network, no real codex/git calls, no mutations"
  print_summary_and_exit
fi

orig_home="${HOME:-}"
incoming_te_python="${TE_PYTHON:-}"

unset HC_TERMINAL_ID HC_TERMINAL_SOCKET HC_SCOPE
unset SQUAD_DEVKIT_ORCA_TERMINAL ORCA_PANE_KEY ORCA_CLI_COMMAND ORCA_DEV_REPO_ROOT
unset SQUAD_DEVKIT_WORKSPACE SQUAD_WORKTREE_WORKSPACE SQUAD_MANAGER_ID SQUAD_DEVKIT_YOLO
unset CODEX_HOME CLAUDE_CONFIG_DIR TE_PYTHON TOKENECONOMIZER_HOME
unset SQUAD_TOKENECONOMIZER_CACHE_DIR OPENAI_API_KEY CODEX_API_KEY

# Discover binaries via command -v only; never execute any binary before isolated temp dirs and guards are active.
real_git="$(command -v git 2>/dev/null || true)"
real_codex="$(command -v codex 2>/dev/null || true)"

if [[ -z "$real_git" ]]; then
  record_skip "prereq_git" "git binary not found on PATH"
  print_summary_and_exit
fi
if [[ -z "$real_codex" ]]; then
  record_skip "prereq_codex" "codex CLI not found on PATH"
  print_summary_and_exit
fi

temp_root_raw="$(mktemp -d /tmp/squad-te-real-cli.XXXXXX)"
temp_dir="$(cd "$temp_root_raw" && pwd -P)"
cleanup() {
  rm -rf "$temp_dir"
}
trap cleanup EXIT

export HOME="$temp_dir/home"
export XDG_CACHE_HOME="$temp_dir/xdg_cache"
export XDG_CONFIG_HOME="$temp_dir/xdg_config"
export XDG_DATA_HOME="$temp_dir/xdg_data"
export XDG_STATE_HOME="$temp_dir/xdg_state"
export CODEX_HOME="$temp_dir/codex_home"
export TOKENECONOMIZER_HOME="$temp_dir/te_home"
export SQUAD_TOKENECONOMIZER_CACHE_DIR="$temp_dir/devkit_te_cache"

mkdir -p "$HOME" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" \
  "$CODEX_HOME" "$TOKENECONOMIZER_HOME" "$temp_dir/bin"

# Load helper library only after isolated HOME/XDG/CODEX_HOME/TE env vars are active.
# shellcheck source=../scripts/lib/squad-tokeneconomizer.sh
source "$repo_root/scripts/lib/squad-tokeneconomizer.sh"

guard_isolated_paths() {
  local var val resolved
  for var in HOME XDG_CACHE_HOME XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME CODEX_HOME TOKENECONOMIZER_HOME SQUAD_TOKENECONOMIZER_CACHE_DIR; do
    val="${!var:-}"
    [[ -n "$val" ]] || { echo "Guard failed: $var is empty" >&2; return 1; }
    resolved="$(squad_te_realpath "$val")"
    [[ "$resolved" == "$temp_dir/"* ]] || { echo "Guard failed: $var=$resolved outside $temp_dir" >&2; return 1; }
    if [[ -n "$orig_home" ]]; then
      [[ "$resolved" != "$orig_home" && "$resolved" != "$orig_home/"* ]] || {
        echo "Guard failed: $var=$resolved overlaps real HOME=$orig_home" >&2
        return 1
      }
    fi
  done
  [[ ! -e "$CODEX_HOME/auth.json" && ! -L "$CODEX_HOME/auth.json" ]] || {
    echo "Guard failed: auth.json must not exist in isolated CODEX_HOME" >&2
    return 1
  }
  [[ ! -e "$HOME/.codex" && ! -L "$HOME/.codex" ]] || {
    echo "Guard failed: unexpected $HOME/.codex" >&2
    return 1
  }
  return 0
}

codex_log="$temp_dir/codex_invocations.log"
codex_audit_log="$temp_dir/codex_audit.log"
: >"$codex_log"
: >"$codex_audit_log"

# Transparent guard/audit wrapper around the real codex binary from the very first invocation:
# - enforces isolated HOME and CODEX_HOME under $temp_dir before any codex execution
# - blocks codex exec/login/model/auth/etc. so no model or auth call can ever run
# - records HOME, CODEX_HOME, and args in codex_audit_log (never truncated) and args in codex_log
# - execs the real codex binary untouched for --version and plugin commands
cat >"$temp_dir/bin/codex" <<EOF
#!/usr/bin/env bash
set -euo pipefail
case "\${HOME:-}" in
  "$temp_dir/"*) ;;
  *)
    echo "CODEX_GUARD_ERROR: HOME=\${HOME:-unset} is outside $temp_dir" >&2
    exit 97
    ;;
esac
case "\${CODEX_HOME:-}" in
  "$temp_dir/"*) ;;
  *)
    echo "CODEX_GUARD_ERROR: CODEX_HOME=\${CODEX_HOME:-unset} is outside $temp_dir" >&2
    exit 97
    ;;
esac
case "\${1:-}" in
  --version)
    ;;
  plugin)
    case "\${2:-}" in
      add|list|remove) ;;
      marketplace)
        case "\${3:-}" in
          add|list|remove) ;;
          *)
            echo "CODEX_GUARD_BLOCKED: forbidden plugin marketplace subcommand: \$*" >&2
            exit 98
            ;;
        esac
        ;;
      *)
        echo "CODEX_GUARD_BLOCKED: forbidden plugin subcommand: \$*" >&2
        exit 98
        ;;
    esac
    ;;
  *)
    echo "CODEX_GUARD_BLOCKED: forbidden codex command (no exec/login/model): \$*" >&2
    exit 98
    ;;
esac
printf 'HOME=%s CODEX_HOME=%s ARGS=%s\n' "\$HOME" "\$CODEX_HOME" "\$*" >>"$codex_audit_log"
printf '%s\n' "\$*" >>"$codex_log"
exec "$real_codex" "\$@"
EOF
chmod +x "$temp_dir/bin/codex"
export PATH="$temp_dir/bin:$PATH"

# Verify isolation and zero pre-probe codex invocations before executing any prerequisite probe.
if ! guard_isolated_paths 2>"$temp_dir/guard.err"; then
  record_fail "env_isolation_guard" "$(cat "$temp_dir/guard.err")"
  print_summary_and_exit
fi
if [[ "$(command -v codex)" != "$temp_dir/bin/codex" ]] || [[ -s "$codex_audit_log" ]]; then
  record_fail "env_isolation_guard" "codex wrapper not active or pre-isolation invocation recorded"
  print_summary_and_exit
fi

if ! squad_has_jq; then
  record_skip "prereq_jq" "jq (or squad jq) not found"
  print_summary_and_exit
fi

git_ver="$("$real_git" --version 2>&1 | head -n 1 || true)"
codex_ver_raw="$(codex --version 2>&1 || true)"
codex_ver=""
if [[ "$codex_ver_raw" =~ codex-cli[[:space:]]+([0-9]+\.[0-9]+\.[0-9]+) ]]; then
  codex_ver="${BASH_REMATCH[1]}"
elif [[ "$codex_ver_raw" =~ ([0-9]+\.[0-9]+\.[0-9]+) ]]; then
  codex_ver="${BASH_REMATCH[1]}"
fi

if [[ -z "$codex_ver" ]] || (( $(squad_te_semver_cmp "$codex_ver" "$SQUAD_TE_CODEX_MIN_HOOKS") < 0 )); then
  record_skip "prereq_codex_version" "codex >= $SQUAD_TE_CODEX_MIN_HOOKS required (got '${codex_ver_raw:-unknown}')"
  print_summary_and_exit
fi

probe_python_bin() {
  local candidate="$1"
  [[ -n "$candidate" ]] || return 1
  command -v "$candidate" >/dev/null 2>&1 || [[ -x "$candidate" ]] || return 1
  "$candidate" -E -S -c 'import sys; print("%d.%d.%d" % sys.version_info[:3]); sys.exit(0 if sys.version_info >= (3, 10) else 1)' </dev/null 2>/dev/null
}

real_python=""
real_python_ver=""
python_from_path=0
if [[ -n "$incoming_te_python" ]]; then
  if out="$(probe_python_bin "$incoming_te_python")"; then
    real_python="$incoming_te_python"
    real_python_ver="$(printf '%s' "$out" | head -n 1)"
    export TE_PYTHON="$real_python"
  fi
fi

if [[ -z "$real_python" ]]; then
  for py_name in python3 python3.15 python3.14 python3.13 python3.12 python3.11 python3.10 python; do
    if out="$(probe_python_bin "$py_name")"; then
      real_python="$(command -v "$py_name")"
      real_python_ver="$(printf '%s' "$out" | head -n 1)"
      python_from_path=1
      break
    fi
  done
fi

if [[ -z "$real_python" ]]; then
  for py_path in \
    /opt/homebrew/bin/python3.15 /opt/homebrew/bin/python3.14 /opt/homebrew/bin/python3.13 \
    /opt/homebrew/bin/python3.12 /opt/homebrew/bin/python3.11 /opt/homebrew/bin/python3.10 \
    /usr/local/bin/python3.15 /usr/local/bin/python3.14 /usr/local/bin/python3.13 \
    /usr/local/bin/python3.12 /usr/local/bin/python3.11 /usr/local/bin/python3.10 \
    /Library/Frameworks/Python.framework/Versions/3.*/bin/python3.*; do
    [[ -x "$py_path" && ! -d "$py_path" ]] || continue
    if out="$(probe_python_bin "$py_path")"; then
      real_python="$py_path"
      real_python_ver="$(printf '%s' "$out" | head -n 1)"
      export TE_PYTHON="$real_python"
      break
    fi
  done
fi

if [[ -z "$real_python" ]]; then
  fallback_py_ver="$(python3 --version 2>&1 || true)"
  record_skip "prereq_python" "Python >= 3.10 not found in PATH or standard installed paths (default python3: ${fallback_py_ver:-none})"
  print_summary_and_exit
fi

printf 'TokenEconomizer Real CLI Contract Suite\n'
printf '  pinned_sha:    %s\n' "$pinned_sha"
printf '  upstream_url:  %s\n' "$upstream_url"
printf '  codex_bin:     %s (version %s)\n' "$real_codex" "$codex_ver"
printf '  git_bin:       %s (%s)\n' "$real_git" "$git_ver"
printf '  python_bin:    %s (version %s, on_path=%s)\n' "$real_python" "$real_python_ver" "$python_from_path"
printf '  isolated_root: %s\n' "$temp_dir"
printf '  runtime_scope: real CLI registration + upstream CLI only (no codex exec/login/model/hooks runtime)\n'

# 1. Isolation and guard enforcement
guard_err=""
guard_rc=0
if ! guard_isolated_paths 2>"$temp_dir/guard.err"; then
  guard_rc=1
  guard_err="$(cat "$temp_dir/guard.err")"
elif [[ "$(command -v codex)" != "$temp_dir/bin/codex" ]]; then
  guard_rc=1
  guard_err="codex wrapper not first on PATH"
else
  blocked_rc=0
  codex exec --help >"$temp_dir/blocked.out" 2>&1 || blocked_rc=$?
  if [[ "$blocked_rc" != "98" ]]; then
    guard_rc=1
    guard_err="expected codex exec guard exit 98, got $blocked_rc"
  fi
fi
if (( guard_rc == 0 )); then
  record_pass "env_isolation_guard" "isolated HOME/CODEX_HOME/XDG/TOKENECONOMIZER_HOME/cache under $temp_dir; exec/model blocked (exit 98)"
else
  record_fail "env_isolation_guard" "$guard_err"
  print_summary_and_exit
fi

# 1b. First-probe isolation guard: verify prerequisite --version ran inside isolated HOME/CODEX_HOME and escapes exit 97
audit_line_count="$(wc -l <"$codex_audit_log" | tr -d '[:space:]')"
first_audit_line="$(head -n 1 "$codex_audit_log" 2>/dev/null || true)"
expected_audit_prefix="HOME=$HOME CODEX_HOME=$CODEX_HOME ARGS="

escape_home_rc=0
HOME="${orig_home:-/tmp/nonexistent-orig-home}" codex --version >"$temp_dir/escape_home.out" 2>&1 || escape_home_rc=$?
escape_codex_rc=0
CODEX_HOME="${orig_home:-/tmp/nonexistent-orig-home}/.codex" codex --version >"$temp_dir/escape_codex.out" 2>&1 || escape_codex_rc=$?
audit_after_escape="$(wc -l <"$codex_audit_log" | tr -d '[:space:]')"

if [[ "$audit_line_count" == "1" ]] &&
   [[ "$first_audit_line" == "${expected_audit_prefix}--version" ]] &&
   [[ "$escape_home_rc" == "97" && "$escape_codex_rc" == "97" ]] &&
   [[ "$audit_after_escape" == "$audit_line_count" ]]; then
  record_pass "real_codex_first_probe_isolated" "first probe audited ($first_audit_line); unisolated HOME/CODEX_HOME rejected (exit 97)"
else
  record_fail "real_codex_first_probe_isolated" "count=$audit_line_count->$audit_after_escape first='$first_audit_line' escape_rc=($escape_home_rc,$escape_codex_rc)"
  print_summary_and_exit
fi

# 2. Network reachability check before install lifecycle
if ! "$real_git" ls-remote --exit-code "$upstream_url" HEAD >/dev/null 2>&1; then
  record_skip "prereq_network" "network unreachable to $upstream_url; skipping real upstream fetch/lifecycle cases"
  print_summary_and_exit
fi

# 3. Read-only status when absent
: >"$codex_log"
status_absent_rc=0
status_absent_out="$("$te_cmd" status --json 2>"$temp_dir/status_absent.err")" || status_absent_rc=$?
if (( status_absent_rc == 0 )) &&
   [[ "$(squad_jq -r '.state' <<<"$status_absent_out")" == "absent" ]] &&
   [[ "$(squad_jq -r '.codex_cli_introspected' <<<"$status_absent_out")" == "false" ]] &&
   [[ "$(squad_jq -r '.registration_state' <<<"$status_absent_out")" == "absent" ]] &&
   [[ "$(squad_jq -r '.ephemeral_exec_compatible' <<<"$status_absent_out")" == "false" ]] &&
   [[ "$(squad_jq -r '.worktree_identity_canonicalized' <<<"$status_absent_out")" == "true" ]] &&
   [[ "$(squad_jq -r '.python_status' <<<"$status_absent_out")" == "ok" ]] &&
   ! grep -q "plugin" "$codex_log" &&
   [[ ! -e "$SQUAD_TOKENECONOMIZER_CACHE_DIR" ]] &&
   [[ ! -e "$CODEX_HOME/config.toml" ]] &&
   [[ ! -e "$TOKENECONOMIZER_HOME/config.json" ]]; then
  record_pass "real_status_absent_readonly" "exit=0 state=absent codex_cli_introspected=false no plugin list or mutations"
else
  record_fail "real_status_absent_readonly" "exit=$status_absent_rc err=$(tr '\n' ' ' <"$temp_dir/status_absent.err")"
fi

# 4. Real install & pinned upstream commit/files/license verification
: >"$codex_log"
install_rc=0
install_out="$("$te_cmd" install 2>"$temp_dir/install.err")" || install_rc=$?
checkout_dir="$SQUAD_TOKENECONOMIZER_CACHE_DIR/upstream"
ownership_file="$SQUAD_TOKENECONOMIZER_CACHE_DIR/ownership.json"
head_sha=""
dirty_status=""
if [[ -d "$checkout_dir/.git" ]]; then
  head_sha="$("$real_git" -C "$checkout_dir" rev-parse HEAD 2>/dev/null || true)"
  dirty_status="$("$real_git" -C "$checkout_dir" status --porcelain --untracked-files=all 2>/dev/null || echo ERR)"
fi

required_files_ok=1
for rel in \
  ".claude-plugin/marketplace.json" \
  "plugin/.codex-plugin/plugin.json" \
  "plugin/hooks/codex-hooks.json" \
  "plugin/scripts/te-hook" \
  "plugin/scripts/te_bootstrap.py" \
  "LICENSE"; do
  if [[ ! -f "$checkout_dir/$rel" || -L "$checkout_dir/$rel" ]]; then
    required_files_ok=0
  fi
done

if (( install_rc == 0 )) &&
   [[ "$install_out" == *"$pinned_sha"* ]] &&
   [[ "$head_sha" == "$pinned_sha" ]] &&
   [[ -z "$dirty_status" ]] &&
   (( required_files_ok == 1 )) &&
   grep -q "Apache License" "$checkout_dir/LICENSE" &&
   grep -q "Version 2.0" "$checkout_dir/LICENSE" &&
   squad_jq -e '.name == "tokeneconomizer"' "$checkout_dir/plugin/.codex-plugin/plugin.json" >/dev/null 2>&1 &&
   squad_jq -e '.plugins | length >= 1' "$checkout_dir/.claude-plugin/marketplace.json" >/dev/null 2>&1 &&
   [[ -f "$ownership_file" ]] &&
   [[ "$(squad_jq -r '.managed_by' "$ownership_file")" == "squad-devkit" ]] &&
   [[ "$(squad_jq -r '.pinned_commit' "$ownership_file")" == "$pinned_sha" ]] &&
   [[ "$(squad_jq -r '.upstream_license' "$ownership_file")" == "$expected_license" ]] &&
   [[ "$(squad_jq -r '.marketplace_added_by_devkit' "$ownership_file")" == "true" ]] &&
   [[ "$(squad_jq -r '.plugin_added_by_devkit' "$ownership_file")" == "true" ]] &&
   [[ "$(squad_jq -r '.disabled' "$ownership_file")" == "false" ]] &&
   [[ ! -e "$TOKENECONOMIZER_HOME/config.json" ]]; then
  record_pass "real_install_and_upstream_pin" "exit=$install_rc HEAD=$head_sha clean=true Apache-2.0 ownership=valid global_cfg=untouched"
else
  record_fail "real_install_and_upstream_pin" "exit=$install_rc head=${head_sha:-none} dirty=${dirty_status:-clean} files_ok=$required_files_ok err=$(tr '\n' ' ' <"$temp_dir/install.err")"
  print_summary_and_exit
fi

# 5. Real Codex CLI plugin & marketplace contract after install
mkt_list_rc=0
plug_list_rc=0
mkt_json="$(codex plugin marketplace list --json 2>"$temp_dir/mkt_list.err")" || mkt_list_rc=$?
plug_json="$(codex plugin list --json 2>"$temp_dir/plug_list.err")" || plug_list_rc=$?
real_checkout="$(squad_te_realpath "$checkout_dir")"
real_mkt_src="$(squad_jq -r '.marketplaces[] | select(.name == "tokeneconomizer") | (.marketplaceSource.source // .root // empty)' <<<"$mkt_json" 2>/dev/null | head -n 1 || true)"
real_plug_row="$(squad_jq -c '.installed[] | select(.pluginId == "tokeneconomizer@tokeneconomizer")' <<<"$plug_json" 2>/dev/null | head -n 1 || true)"
real_plug_enabled="$(squad_jq -r '.enabled // empty' <<<"$real_plug_row" 2>/dev/null || true)"
real_plug_installed="$(squad_jq -r '.installed // empty' <<<"$real_plug_row" 2>/dev/null || true)"
real_plug_src="$(squad_jq -r '.source.path // empty' <<<"$real_plug_row" 2>/dev/null || true)"

if (( mkt_list_rc == 0 && plug_list_rc == 0 )) &&
   [[ -n "$real_mkt_src" ]] &&
   [[ "$(squad_te_realpath "$real_mkt_src")" == "$real_checkout" ]] &&
   [[ "$real_plug_installed" == "true" ]] &&
   [[ "$real_plug_enabled" == "true" ]] &&
   squad_te_path_within_checkout "$real_plug_src" "$checkout_dir" &&
   [[ -f "$CODEX_HOME/config.toml" ]] &&
   grep -Fq '[marketplaces.tokeneconomizer]' "$CODEX_HOME/config.toml" &&
   grep -Fq '[plugins."tokeneconomizer@tokeneconomizer"]' "$CODEX_HOME/config.toml"; then
  record_pass "real_codex_plugin_contract" "codex $codex_ver registered marketplace+plugin from $real_checkout (CLI registration only; hooks/model runtime untested)"
else
  record_fail "real_codex_plugin_contract" "mkt_rc=$mkt_list_rc plug_rc=$plug_list_rc mkt_src=$real_mkt_src plug_src=$real_plug_src installed=$real_plug_installed enabled=$real_plug_enabled"
fi

# 6. Read-only status after install: no plugin introspection + managed tree snapshot comparison
snapshot_trees() {
  local out_file="$1"
  "$real_python" - "$out_file" "$SQUAD_TOKENECONOMIZER_CACHE_DIR" "$CODEX_HOME" "$TOKENECONOMIZER_HOME" <<'PY'
import hashlib, json, os, stat, sys

out_file = sys.argv[1]
roots = sys.argv[2:]
entries = {}

for idx, root in enumerate(roots):
    label = f"root{idx}"
    if not os.path.exists(root):
        entries[label] = {"exists": False}
        continue
    for cur, dirs, files in os.walk(root, followlinks=False):
        dirs.sort()
        files.sort()
        for name in dirs + files:
            full = os.path.join(cur, name)
            rel = label + "/" + os.path.relpath(full, root)
            st = os.lstat(full)
            kind = "dir" if stat.S_ISDIR(st.st_mode) else ("link" if stat.S_ISLNK(st.st_mode) else "file")
            digest = ""
            if kind == "file":
                h = hashlib.sha256()
                with open(full, "rb") as fh:
                    for chunk in iter(lambda: fh.read(65536), b""):
                        h.update(chunk)
                digest = h.hexdigest()
            elif kind == "link":
                digest = os.readlink(full)
            entries[rel] = {
                "kind": kind,
                "mode": stat.S_IMODE(st.st_mode),
                "size": st.st_size,
                "mtime_ns": st.st_mtime_ns,
                "digest": digest,
            }

with open(out_file, "w", encoding="utf-8") as fh:
    json.dump(entries, fh, sort_keys=True)
PY
}

compare_snapshots() {
  local before_file="$1" after_file="$2"
  "$real_python" - "$before_file" "$after_file" <<'PY'
import json, sys

with open(sys.argv[1], encoding="utf-8") as fh:
    before = json.load(fh)
with open(sys.argv[2], encoding="utf-8") as fh:
    after = json.load(fh)

added = sorted(set(after) - set(before))
removed = sorted(set(before) - set(after))
content_changed = []
mtime_only = []

for k in sorted(set(before) & set(after)):
    b, a = before[k], after[k]
    if b.get("kind") != a.get("kind") or b.get("mode") != a.get("mode") or b.get("digest") != a.get("digest"):
        content_changed.append(k)
    elif b.get("size") != a.get("size") or b.get("mtime_ns") != a.get("mtime_ns"):
        mtime_only.append(k)

print(json.dumps({
    "added": added,
    "removed": removed,
    "content_changed": content_changed,
    "mtime_only": mtime_only,
}))
PY
}

snapshot_trees "$temp_dir/snap_before.json"
: >"$codex_log"
status_inst_rc=0
status_inst_json="$("$te_cmd" status --json 2>"$temp_dir/status_inst.err")" || status_inst_rc=$?
status_human_rc=0
status_human_out="$("$te_cmd" status 2>"$temp_dir/status_human.err")" || status_human_rc=$?
snapshot_trees "$temp_dir/snap_after.json"
snap_diff="$(compare_snapshots "$temp_dir/snap_before.json" "$temp_dir/snap_after.json")"
post_status_dirty="$("$real_git" -C "$checkout_dir" status --porcelain --untracked-files=all 2>/dev/null || echo ERR)"

if (( status_inst_rc == 0 && status_human_rc == 0 )) &&
   [[ "$(squad_jq -r '.state' <<<"$status_inst_json")" == "registered_unverified" ]] &&
   [[ "$(squad_jq -r '.codex_cli_introspected' <<<"$status_inst_json")" == "false" ]] &&
   [[ "$(squad_jq -r '.owned_by_devkit' <<<"$status_inst_json")" == "true" ]] &&
   [[ "$(squad_jq -r '.checkout_commit' <<<"$status_inst_json")" == "$pinned_sha" ]] &&
   [[ "$(squad_jq -r '.checkout_valid' <<<"$status_inst_json")" == "true" ]] &&
   [[ "$(squad_jq -r '.registration_state' <<<"$status_inst_json")" == "configured" ]] &&
   [[ "$(squad_jq -r '.plugin_installed' <<<"$status_inst_json")" == "true" ]] &&
   [[ "$(squad_jq -r '.plugin_enabled' <<<"$status_inst_json")" == "true" ]] &&
   [[ "$(squad_jq -r '.ephemeral_exec_compatible' <<<"$status_inst_json")" == "false" ]] &&
   [[ "$status_human_out" == *"registered_unverified"* ]] &&
   ! grep -q "plugin" "$codex_log" &&
   [[ "$(squad_jq -r '(.added | length) + (.removed | length) + (.content_changed | length) + (.mtime_only | length)' <<<"$snap_diff")" == "0" ]] &&
   [[ -z "$post_status_dirty" ]]; then
  record_pass "real_status_readonly_snapshot" "exit=0 state=registered_unverified no plugin list tree_unchanged=true"
else
  record_fail "real_status_readonly_snapshot" "rc=($status_inst_rc,$status_human_rc) diff=$snap_diff codex_log=$(tr '\n' ';' <"$codex_log")"
fi

# 7. Repeat install is idempotent
: >"$codex_log"
repeat_rc=0
"$te_cmd" install >"$temp_dir/repeat.out" 2>"$temp_dir/repeat.err" || repeat_rc=$?
repeat_plug_count="$(codex plugin list --json 2>/dev/null | squad_jq '[.installed[] | select(.pluginId == "tokeneconomizer@tokeneconomizer")] | length' 2>/dev/null || echo -1)"
if (( repeat_rc == 0 )) &&
   ! grep -q "plugin add" "$codex_log" &&
   ! grep -q "marketplace add" "$codex_log" &&
   [[ "$repeat_plug_count" == "1" ]]; then
  record_pass "real_repeat_install_idempotent" "exit=0 no re-add/re-fetch installed_count=1"
else
  record_fail "real_repeat_install_idempotent" "exit=$repeat_rc count=$repeat_plug_count codex_log=$(tr '\n' ';' <"$codex_log")"
fi

# 8. Scoped repo defaults read back through real upstream CLI + global sentinel unchanged
repo_scoped="$temp_dir/repo_scoped"
repo_retain="$temp_dir/repo_retain"
mkdir -p "$repo_scoped" "$repo_retain"
"$real_git" -C "$repo_scoped" init -q
"$real_git" -C "$repo_retain" init -q

printf '{"loopguard":"off","sentinel":"global_untouched"}\n' >"$TOKENECONOMIZER_HOME/config.json"
cp "$TOKENECONOMIZER_HOME/config.json" "$temp_dir/global_cfg.expected"

te_bootstrap="$checkout_dir/plugin/scripts/te_bootstrap.py"
"$real_python" "$te_bootstrap" cli --host codex --cwd "$repo_retain" config set microskills=on >/dev/null
retain_pre_microskills="$("$real_python" "$te_bootstrap" cli --host codex --cwd "$repo_retain" status --json 2>/dev/null | squad_jq -r '.config.microskills // empty')"

scoped_rc=0
"$te_cmd" install --repo "$repo_scoped" >"$temp_dir/scoped.out" 2>"$temp_dir/scoped.err" || scoped_rc=$?
retain_rc=0
retain_out="$("$te_cmd" install --repo "$repo_retain" 2>"$temp_dir/retain.err")" || retain_rc=$?

scoped_status="$("$real_python" "$te_bootstrap" cli --host codex --cwd "$repo_scoped" status --json 2>/dev/null || echo '{}')"
retain_status="$("$real_python" "$te_bootstrap" cli --host codex --cwd "$repo_retain" status --json 2>/dev/null || echo '{}')"
repo_state_dir="$(squad_jq -r '.state // empty' <<<"$scoped_status")"

if (( scoped_rc == 0 && retain_rc == 0 )) &&
   [[ "$(squad_jq -r '.config.microskills' <<<"$scoped_status")" == "envfacts" ]] &&
   [[ "$(squad_jq -r '.config.toolprune' <<<"$scoped_status")" == "propose" ]] &&
   [[ "$(squad_jq -r '.config.loopguard' <<<"$scoped_status")" == "nudge" ]] &&
   [[ "$retain_pre_microskills" == "envfacts+distiller" ]] &&
   [[ "$retain_out" == *"Retained existing repo preferences"* ]] &&
   [[ "$(squad_jq -r '.config.microskills' <<<"$retain_status")" == "envfacts+distiller" ]] &&
   [[ "$(squad_jq -r '.config.toolprune' <<<"$retain_status")" == "propose" ]] &&
   [[ "$(squad_jq -r '.config.loopguard' <<<"$retain_status")" == "nudge" ]] &&
   cmp -s "$TOKENECONOMIZER_HOME/config.json" "$temp_dir/global_cfg.expected"; then
  record_pass "real_scoped_repo_defaults" "real semantic readback: microskills=envfacts toolprune=propose loopguard=nudge; pre-existing microskills=on->envfacts+distiller retained; global sentinel byte-identical"
else
  record_fail "real_scoped_repo_defaults" "scoped_rc=$scoped_rc retain_rc=$retain_rc pre=$retain_pre_microskills scoped=$(squad_jq -c '.config|{microskills,toolprune,loopguard}' <<<"$scoped_status" 2>/dev/null) retain=$(squad_jq -c '.config|{microskills,toolprune,loopguard}' <<<"$retain_status" 2>/dev/null)"
fi

# 9. Ordinary git worktree identity verified directly through upstream CLI
wt_main="$temp_dir/wt_main"
wt_linked="$temp_dir/wt_linked"
mkdir -p "$wt_main"
"$real_git" -C "$wt_main" init -q
"$real_git" -C "$wt_main" config user.email "te-test@example.com"
"$real_git" -C "$wt_main" config user.name "TE Test"
printf 'fixture\n' >"$wt_main/README.md"
"$real_git" -C "$wt_main" add README.md
"$real_git" -C "$wt_main" commit -q -m "init fixture"
"$real_git" -C "$wt_main" worktree add -q -b wt-fixture "$wt_linked"

wt_main_no_remote="$("$real_python" "$te_bootstrap" cli --host codex --cwd "$wt_main" status --json 2>/dev/null || echo '{}')"
wt_link_no_remote="$("$real_python" "$te_bootstrap" cli --host codex --cwd "$wt_linked" status --json 2>/dev/null || echo '{}')"

"$real_git" -C "$wt_main" remote add origin "https://github.com/example/squad-te-wt-fixture.git"
wt_main_remote="$("$real_python" "$te_bootstrap" cli --host codex --cwd "$wt_main" status --json 2>/dev/null || echo '{}')"
wt_link_remote="$("$real_python" "$te_bootstrap" cli --host codex --cwd "$wt_linked" status --json 2>/dev/null || echo '{}')"

"$real_git" -C "$wt_main" worktree remove --force "$wt_linked" >/dev/null 2>&1 || rm -rf "$wt_linked"

k1="$(squad_jq -r '.repo_key // empty' <<<"$wt_main_no_remote")"
k2="$(squad_jq -r '.repo_key // empty' <<<"$wt_link_no_remote")"
id1="$(squad_jq -r '.identified_by // empty' <<<"$wt_main_no_remote")"
k3="$(squad_jq -r '.repo_key // empty' <<<"$wt_main_remote")"
k4="$(squad_jq -r '.repo_key // empty' <<<"$wt_link_remote")"
id3="$(squad_jq -r '.identified_by // empty' <<<"$wt_main_remote")"

if [[ -n "$k1" && "$k1" == "$k2" && "$id1" == "path" ]] &&
   [[ -n "$k3" && "$k3" == "$k4" && "$id3" == "remote" ]] &&
   [[ "$(squad_jq -r '.state // empty' <<<"$wt_main_remote")" == "$(squad_jq -r '.state // empty' <<<"$wt_link_remote")" ]]; then
  record_pass "real_git_worktree_identity" "main and linked worktree share repo_key ($id1=$k1, $id3=$k3) via upstream te_bootstrap.py"
else
  record_fail "real_git_worktree_identity" "no_remote=($k1,$k2,$id1) remote=($k3,$k4,$id3)"
fi

# 10. Disable + re-enable lifecycle with learned data sentinel
learned_repo_sentinel=""
if [[ -n "$repo_state_dir" ]]; then
  mkdir -p "$repo_state_dir"
  learned_repo_sentinel="$repo_state_dir/injection.json"
  printf '{"rendered":"- use pytest -q\n"}\n' >"$learned_repo_sentinel"
  cp "$learned_repo_sentinel" "$temp_dir/learned_repo.expected"
fi
learned_home_sentinel="$TOKENECONOMIZER_HOME/learned-sentinel.txt"
printf 'keep-learned-data\n' >"$learned_home_sentinel"
cp "$learned_home_sentinel" "$temp_dir/learned_home.expected"

disable_rc=0
"$te_cmd" disable >"$temp_dir/disable.out" 2>"$temp_dir/disable.err" || disable_rc=$?
plug_after_disable="$(codex plugin list --json 2>/dev/null | squad_jq '[.installed[] | select(.pluginId == "tokeneconomizer@tokeneconomizer")] | length' 2>/dev/null || echo -1)"
mkt_after_disable="$(codex plugin marketplace list --json 2>/dev/null | squad_jq '[.marketplaces[] | select(.name == "tokeneconomizer")] | length' 2>/dev/null || echo -1)"
status_disabled="$("$te_cmd" status --json 2>/dev/null || echo '{}')"

reenable_rc=0
"$te_cmd" install >"$temp_dir/reenable.out" 2>"$temp_dir/reenable.err" || reenable_rc=$?
plug_after_reenable="$(codex plugin list --json 2>/dev/null | squad_jq '[.installed[] | select(.pluginId == "tokeneconomizer@tokeneconomizer" and .enabled == true)] | length' 2>/dev/null || echo -1)"
status_reenabled="$("$te_cmd" status --json 2>/dev/null || echo '{}')"

if (( disable_rc == 0 && reenable_rc == 0 )) &&
   [[ "$plug_after_disable" == "0" && "$mkt_after_disable" == "1" ]] &&
   [[ "$(squad_jq -r '.state' <<<"$status_disabled")" == "disabled" ]] &&
   [[ -d "$checkout_dir" && -f "$ownership_file" ]] &&
   [[ "$plug_after_reenable" == "1" ]] &&
   [[ "$(squad_jq -r '.state' <<<"$status_reenabled")" == "registered_unverified" ]] &&
   cmp -s "$learned_home_sentinel" "$temp_dir/learned_home.expected" &&
   { [[ -z "$learned_repo_sentinel" ]] || cmp -s "$learned_repo_sentinel" "$temp_dir/learned_repo.expected"; }; then
  record_pass "real_disable_and_reenable" "disable_rc=0 removed plugin only; reenable_rc=0 restored plugin; checkout and learned sentinels preserved"
else
  record_fail "real_disable_and_reenable" "disable_rc=$disable_rc reenable_rc=$reenable_rc plug_dis=$plug_after_disable mkt_dis=$mkt_after_disable plug_re=$plug_after_reenable"
fi

# 11. Uninstall removes devkit checkout/marketplace/plugin and preserves learned data + global config
uninstall_rc=0
"$te_cmd" uninstall >"$temp_dir/uninstall.out" 2>"$temp_dir/uninstall.err" || uninstall_rc=$?
plug_after_uninst="$(codex plugin list --json 2>/dev/null | squad_jq '[.installed[] | select(.pluginId == "tokeneconomizer@tokeneconomizer")] | length' 2>/dev/null || echo -1)"
mkt_after_uninst="$(codex plugin marketplace list --json 2>/dev/null | squad_jq '[.marketplaces[] | select(.name == "tokeneconomizer")] | length' 2>/dev/null || echo -1)"
status_after_uninst="$("$te_cmd" status --json 2>/dev/null || echo '{}')"

if (( uninstall_rc == 0 )) &&
   [[ "$plug_after_uninst" == "0" && "$mkt_after_uninst" == "0" ]] &&
   [[ ! -e "$checkout_dir" && ! -e "$ownership_file" && ! -e "$SQUAD_TOKENECONOMIZER_CACHE_DIR" ]] &&
   [[ "$(squad_jq -r '.state' <<<"$status_after_uninst")" == "absent" ]] &&
   cmp -s "$TOKENECONOMIZER_HOME/config.json" "$temp_dir/global_cfg.expected" &&
   cmp -s "$learned_home_sentinel" "$temp_dir/learned_home.expected" &&
   { [[ -z "$learned_repo_sentinel" ]] || cmp -s "$learned_repo_sentinel" "$temp_dir/learned_repo.expected"; } &&
   awk -v p="$expected_audit_prefix" 'index($0, p) != 1 { bad=1 } END { exit bad }' "$codex_audit_log" &&
   guard_isolated_paths; then
  record_pass "real_uninstall_and_sentinels" "uninstall_rc=0 plugin=0 mkt=0 cache_removed=true learned_sentinels_and_global_cfg=preserved"
else
  record_fail "real_uninstall_and_sentinels" "uninstall_rc=$uninstall_rc plug=$plug_after_uninst mkt=$mkt_after_uninst state=$(squad_jq -r '.state' <<<"$status_after_uninst" 2>/dev/null)"
fi

print_summary_and_exit
