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
temp_directory="$(mktemp -d /tmp/squad-devkit-install-test.XXXXXX)"

cleanup() {
  rm -rf "$temp_directory"
}
trap cleanup EXIT

cargo_version="$(sed -n 's/^version = "\(.*\)"/\1/p' "$repo_root/Cargo.toml" | head -n 1)"
[[ -n "$cargo_version" ]] || fail

os="$(uname -s)"
arch="$(uname -m)"
target=""
case "$os" in
  Darwin)
    case "$arch" in
      arm64|aarch64) target="aarch64-apple-darwin" ;;
      x86_64) target="x86_64-apple-darwin" ;;
    esac
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

tar -czf "$fake_release_dir/$archive_name" -C "$staging_dir" squad

if command -v shasum >/dev/null 2>&1; then
  (cd "$fake_release_dir" && shasum -a 256 "$archive_name" > SHA256SUMS)
else
  (cd "$fake_release_dir" && sha256sum "$archive_name" > SHA256SUMS)
fi

test_path="$temp_directory/path"
mkdir -p "$test_path"

IFS=':' read -r -a path_dirs <<< "$PATH"
for dir in "${path_dirs[@]}"; do
  [[ -d "$dir" ]] || continue
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

export PATH="$test_path"
export HOME="$temp_directory/home"
export SQUAD_DEVKIT_BIN_DIR="$installed_bin"
export SQUAD_DEVKIT_RELEASE_URL="file://$fake_release_dir"

# Verify squad is not initially present on PATH
if command -v squad >/dev/null 2>&1; then
  fail
fi

# Run installer
bash "$repo_root/scripts/install-devkit.sh" --no-prompt --no-hud --no-skill

# Assert $installed_bin/squad was installed and executable
[[ -x "$installed_bin/squad" ]] || fail
[[ "$(SQUAD_DEVKIT_ROUTER_URL= "$installed_bin/squad-route" test)" == '{"configured":false}' ]] || fail
version_output="$("$installed_bin/squad" --version)"
[[ "$version_output" == *"$cargo_version"* ]] || fail

# Corrupt SHA256SUMS
rm -f "$installed_bin/squad"
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
[[ ! -e "$installed_bin/squad" ]] || fail

echo "squad_devkit_install_smoke: PASS"
