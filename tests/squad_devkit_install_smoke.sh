#!/usr/bin/env bash
set -euo pipefail

unset HC_TERMINAL_ID HC_TERMINAL_SOCKET HC_SCOPE
unset SQUAD_DEVKIT_ORCA_TERMINAL ORCA_PANE_KEY ORCA_CLI_COMMAND ORCA_DEV_REPO_ROOT
unset SQUAD_DEVKIT_WORKSPACE SQUAD_WORKTREE_WORKSPACE SQUAD_MANAGER_ID SQUAD_DEVKIT_YOLO
unset CODEX_HOME CLAUDE_CONFIG_DIR

trap 'echo "Failed at line $LINENO: $BASH_COMMAND" >&2' ERR

fail() {
  echo "Assertion failed at line ${BASH_LINENO[0]}" >&2
  exit 1
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temp_directory="$(mktemp -d "${TMPDIR:-/tmp}/squad-devkit-install-test.XXXXXX")"

cleanup() {
  rm -rf "$temp_directory"
}
trap cleanup EXIT

cargo_version="$(sed -n 's/^version = "\(.*\)"/\1/p' "$repo_root/Cargo.toml" | head -n 1)"
[[ -n "$cargo_version" ]] || fail

os="$(uname -s)"
arch="$(uname -m)"
target=""
binary=squad
case "$os" in
  Darwin)
    case "$arch" in
      arm64|aarch64) target="aarch64-apple-darwin" ;;
      x86_64) target="x86_64-apple-darwin" ;;
    esac
    ;;
  MINGW*|MSYS*|CYGWIN*)
    target=x86_64-pc-windows-msvc
    binary=squad.exe
    ;;
  Linux)
    case "$arch" in
      x86_64) target="x86_64-unknown-linux-musl" ;;
      aarch64|arm64) target="aarch64-unknown-linux-musl" ;;
    esac
    ;;
esac
[[ -n "$target" ]] || fail

fake_release_dir="$temp_directory/release"
mkdir -p "$fake_release_dir"
archive_name="squad-${target}.tar.gz"

staging_dir="$temp_directory/staging"
mkdir -p "$staging_dir"
cat >"$staging_dir/squad" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "--version" || "\${1:-}" == "-V" ]]; then
  echo "squad $cargo_version"
  exit 0
fi
echo "stub squad"
EOF
chmod +x "$staging_dir/squad"

if [[ "$binary" == squad.exe ]]; then
  archive_name="squad-${target}.zip"
  cp "$staging_dir/squad" "$staging_dir/squad.exe"
  (cd "$staging_dir" && python -m zipfile -c "$fake_release_dir/$archive_name" squad.exe)
else
  tar -czf "$fake_release_dir/$archive_name" -C "$staging_dir" squad
fi

if command -v shasum >/dev/null 2>&1; then
  (cd "$fake_release_dir" && shasum -a 256 "$archive_name" > SHA256SUMS)
else
  (cd "$fake_release_dir" && sha256sum "$archive_name" > SHA256SUMS)
fi

test_python="$(command -v python3 || command -v python)"
test_path="$temp_directory/path"
mkdir -p "$test_path"

IFS=':' read -r -a path_dirs <<< "$PATH"
for dir in "${path_dirs[@]}"; do
  [[ -d "$dir" ]] || continue
  if [[ "$binary" == squad.exe ]]; then
    if [[ ! -e "$dir/squad.exe" && ! -e "$dir/squad" ]]; then
      test_path_tail="${test_path_tail:-}:$dir"
    fi
    continue
  fi
  for bin in "$dir"/*; do
    [[ -x "$bin" && ! -d "$bin" ]] || continue
    name="$(basename "$bin")"
    if [[ "$name" != "squad" && ! -e "$test_path/$name" ]]; then
      ln -s "$bin" "$test_path/$name"
    fi
  done
done

# Ensure a manager CLI is available so installer setup passes
if [[ ! -e "$test_path/claude" ]]; then
  cat >"$test_path/claude" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$test_path/claude"
fi

installed_bin="$temp_directory/installed_bin"
mkdir -p "$installed_bin" "$temp_directory/home"

export PATH="$test_path${test_path_tail:-}"
export HOME="$temp_directory/home"
export SQUAD_DEVKIT_BIN_DIR="$installed_bin"
if [[ "$binary" == squad.exe ]]; then
  release_path="$(cygpath -m "$fake_release_dir")"
  export SQUAD_DEVKIT_RELEASE_URL="file:///$release_path"
else
  export SQUAD_DEVKIT_RELEASE_URL="file://$fake_release_dir"
fi

# Ensure a failing codex stub does not affect default offline install.
rm -f "$test_path/codex"
codex_log="$temp_directory/codex_calls"
cat >"$test_path/codex" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$codex_log"
exit 1
EOF
chmod +x "$test_path/codex"
# A fake claude that logs its arguments; the deck step must call it only as needed.
claude_log="$temp_directory/claude.log"
rm -f "$test_path/claude"
cat >"$test_path/claude" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == --version ]]; then echo '2.1.328 (Claude Code)'; exit 0; fi
printf '%s\n' "\$*" >>"$claude_log"
exit 0
EOF
chmod +x "$test_path/claude"
export CLAUDE_CONFIG_DIR="$temp_directory/claude-config"
mkdir -p "$CLAUDE_CONFIG_DIR/plugins"

# Verify squad is not initially present on PATH
if command -v squad >/dev/null 2>&1; then
  fail
fi

# Run the default installer without invoking codex or touching its plugin state.
bash "$repo_root/scripts/install-devkit.sh" --no-prompt --no-hud --no-skill

# Assert the binary and launcher were installed and are executable.
[[ -x "$installed_bin/$binary" ]] || fail
if [[ "$binary" == squad.exe ]]; then
  [[ ! -L "$installed_bin/squad-devkit" ]] || fail
  grep -q "^exec '" "$installed_bin/squad-devkit" || fail
else
  [[ -L "$installed_bin/squad-devkit" ]] || fail
fi
[[ "$("$installed_bin/squad-devkit" --version)" == *"$cargo_version"* ]] || fail
[[ "$(SQUAD_DEVKIT_ROUTER_URL='' "$installed_bin/squad-route" test)" == '{"configured":false}' ]] || fail
[[ ! -e "$codex_log" ]] || fail
[[ ! -e "$HOME/.codex/plugins" ]] || fail
version_output="$(bash "$installed_bin/$binary" --version)"
[[ "$version_output" == *"$cargo_version"* ]] || fail

# The deck step: marketplace add and install, once each.
[[ "$(grep -c '^plugin marketplace add ' "$claude_log")" == 1 ]] || fail
grep -qxF "plugin marketplace add $repo_root" "$claude_log" || fail
[[ "$(grep -c '^plugin install squad-deck@squad-devkit --scope user$' "$claude_log")" == 1 ]] || fail

# Already there (fixtures stand for what claude would have written): no calls.
: >"$claude_log"
printf '{"squad-devkit":{}}\n' >"$CLAUDE_CONFIG_DIR/plugins/known_marketplaces.json"
printf '{"version":2,"plugins":{"squad-deck@squad-devkit":[{"scope":"user"}]}}\n' >"$CLAUDE_CONFIG_DIR/plugins/installed_plugins.json"
bash "$repo_root/scripts/install-devkit.sh" --no-prompt --no-hud --no-skill >/dev/null 2>&1
[[ ! -s "$claude_log" ]] || fail

# --no-deck skips the step.
: >"$CLAUDE_CONFIG_DIR/plugins/known_marketplaces.json"
: >"$CLAUDE_CONFIG_DIR/plugins/installed_plugins.json"
bash "$repo_root/scripts/install-devkit.sh" --no-prompt --no-hud --no-skill --no-deck >/dev/null 2>&1
[[ ! -s "$claude_log" ]] || fail

# A failing claude is a warning, not a failed install.
rm -f "$test_path/claude"
cat >"$test_path/claude" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == --version ]]; then echo '2.1.328 (Claude Code)'; exit 0; fi
exit 1
EOF
chmod +x "$test_path/claude"
warn_output="$(bash "$repo_root/scripts/install-devkit.sh" --no-prompt --no-hud --no-skill 2>&1)"
[[ "$warn_output" == *'Deck: warning'* ]] || fail

cp "$fake_release_dir/SHA256SUMS" "$temp_directory/valid-sums"
# Corrupt SHA256SUMS
rm -f "$installed_bin/$binary"
echo "0000000000000000000000000000000000000000000000000000000000000000  $archive_name" > "$fake_release_dir/SHA256SUMS"

trap '' ERR
set +e
err_output="$(bash "$repo_root/scripts/install-devkit.sh" --no-prompt --no-hud --no-skill 2>&1)"
exit_code=$?
set -e
trap 'echo "Failed at line $LINENO: $BASH_COMMAND" >&2' ERR

# Assert non-zero exit code, "checksum" in error output, and nothing installed
(( exit_code != 0 )) || fail
[[ "$err_output" =~ [Cc]hecksum ]] || fail
[[ ! -e "$installed_bin/$binary" ]] || fail

printf 'existing binary\000\377' >"$installed_bin/$binary"
cp "$installed_bin/$binary" "$temp_directory/original"
for error in "missing checksum manifest" missing duplicate mismatch; do
  case "$error" in
    "missing checksum manifest") rm "$fake_release_dir/SHA256SUMS" ;;
    missing) printf 'other archive\n' >"$fake_release_dir/SHA256SUMS" ;;
    duplicate) cat "$temp_directory/valid-sums" "$temp_directory/valid-sums" >"$fake_release_dir/SHA256SUMS" ;;
    mismatch) printf '%064d *%s\n' 0 "$archive_name" >"$fake_release_dir/SHA256SUMS" ;;
  esac
  if err_output="$(bash "$repo_root/scripts/install-devkit.sh" --no-prompt --no-hud --no-skill 2>&1)"; then
    fail
  fi
  [[ "$err_output" == *"$error"* ]] || fail
  cmp "$temp_directory/original" "$installed_bin/$binary" || fail
done

if [[ "$binary" == squad ]]; then
  archive_name=squad-x86_64-pc-windows-msvc.zip
  cp "$staging_dir/squad" "$staging_dir/squad.exe"
  (cd "$staging_dir" && "$test_python" -m zipfile -c "$fake_release_dir/$archive_name" squad.exe)
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "$fake_release_dir" && sha256sum -b "$archive_name" >SHA256SUMS)
  else
    (cd "$fake_release_dir" && shasum -a 256 -b "$archive_name" >SHA256SUMS)
  fi
  export SQUAD_DEVKIT_BIN_DIR="$temp_directory/windows bin"
  SQUAD_INSTALL_OS=MINGW64_NT SQUAD_INSTALL_ARCH=AMD64 \
    bash "$repo_root/scripts/install-devkit.sh" --no-prompt --no-hud --no-skill --no-deck
  cmp "$SQUAD_DEVKIT_BIN_DIR/squad.exe" "$staging_dir/squad.exe" || fail
  [[ ! -L "$SQUAD_DEVKIT_BIN_DIR/squad-devkit" ]] || fail
  [[ "$("$SQUAD_DEVKIT_BIN_DIR/squad-devkit" --version)" == *"$cargo_version"* ]] || fail
fi

echo "squad_devkit_install_smoke: PASS"
