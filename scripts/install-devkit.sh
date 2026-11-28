#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/lib/squad-jq.sh"
source "$script_dir/lib/squad-tmux-launcher-helpers.sh"
source "$script_dir/lib/squad-devkit-agents.sh"

usage() {
  cat <<'EOF'
Usage: install-devkit.sh [--manager CLI] [--no-prompt] [--no-hud] [--no-skill] [--no-deck] [--build-squad]

Link squad-devkit, squad-worker, squad-monitor, squad-orchestration, squad-route, squad-ask, and squad-telegram into ~/.local/bin (or SQUAD_DEVKIT_BIN_DIR)
and choose the manager CLI. Claude Code is the default when installed; without
it, the installer asks which installed CLI should manage and saves the answer.
Re-run it, or run squad-devkit --setup, to change the choice.

Pass --build-squad to compile the squad message bus binary from source using cargo
instead of downloading a prebuilt release binary.

If the claude-hud status line plugin is installed, the installer also turns on
its weekly quota and usage-pace display (display.sevenDayThreshold = 0,
display.usagePace = true) unless you already set those keys; --no-hud skips it.
The manager's status line then shows the weekly quota next to the squad label.

It also installs the squad-devkit skill for Claude Code (~/.claude/skills) and
Codex (~/.codex/skills) as a link to skills/squad-devkit in this repository, so
any session can delegate to workers and `git pull` keeps the skill current;
--no-skill skips it. An existing non-link directory there is left untouched.

With Claude Code 2.1.289 or later, it also installs the squad deck (a live worker
dashboard, mods/squad-deck) as a user-scope plugin read from this repository, so
every manager session has it after /reload-plugins; --no-deck skips it. A failure
there is a warning and never fails the install.
EOF
}

manager_client=""
no_prompt=0
configure_hud=1
install_skill=1
install_deck=1
build_squad=0
while (( $# > 0 )); do
  case "$1" in
    --manager)
      if (( $# < 2 )) || [[ -z "$2" ]]; then
        echo "Missing value for $1" >&2
        exit 2
      fi
      manager_client="$2"
      shift
      ;;
    --manager=*) manager_client="${1#*=}" ;;
    --no-prompt) no_prompt=1 ;;
    --no-hud) configure_hud=0 ;;
    --no-skill) install_skill=0 ;;
    --no-deck) install_deck=0 ;;
    --build-squad) build_squad=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

detect_squad_target() {
  local arch
  arch="${SQUAD_INSTALL_ARCH:-$(uname -m)}"
  case "$install_os" in
    MINGW*|MSYS*|CYGWIN*)
      case "$arch" in
        x86_64|amd64|AMD64) echo "x86_64-pc-windows-msvc" ;;
        *) return 1 ;;
      esac
      ;;
    Darwin)
      case "$arch" in
        arm64|aarch64) echo "aarch64-apple-darwin" ;;
        x86_64) echo "x86_64-apple-darwin" ;;
        *) return 1 ;;
      esac
      ;;
    Linux)
      case "$arch" in
        x86_64) echo "x86_64-unknown-linux-musl" ;;
        aarch64|arm64) echo "aarch64-unknown-linux-musl" ;;
        *) return 1 ;;
      esac
      ;;
    *) return 1 ;;
  esac
}

ensure_squad() {
  if [[ "${SQUAD_DEVKIT_SKIP_SQUAD:-0}" == "1" ]] || is_truthy "${SQUAD_DEVKIT_SKIP_SQUAD:-}"; then
    return 0
  fi

  local repo_dir cargo_version
  repo_dir="$(cd "$script_dir/.." && pwd)"
  cargo_version="$(sed -n 's/^version = "\(.*\)"/\1/p' "$repo_dir/Cargo.toml" | head -n 1)"
  if [[ -z "$cargo_version" ]]; then
    echo "Error: could not determine squad version from $repo_dir/Cargo.toml" >&2
    exit 1
  fi

  if (( build_squad == 0 )) && command -v "$squad_bin_name" >/dev/null 2>&1; then
    local version_output matched=0 token
    version_output="$("$squad_bin_name" --version 2>/dev/null || true)"
    local -a tokens=()
    read -r -a tokens <<<"$version_output"
    for token in ${tokens[@]+"${tokens[@]}"}; do
      if [[ "$token" == "$cargo_version" ]]; then
        matched=1
        break
      fi
    done
    if (( matched == 1 )); then
      return 0
    fi
  fi

  local installed=0
  if (( build_squad == 0 )); then
    local target
    if target="$(detect_squad_target)"; then
      local base_url archive_name archive_url checksums_url tmp_dir
      base_url="${SQUAD_DEVKIT_RELEASE_URL:-https://github.com/bthanhtung/squad-devkit/releases/download/v$cargo_version}"
      base_url="${base_url%/}"
      archive_name="squad-${target}.tar.gz"
      if [[ "$target" == *-pc-windows-* ]]; then
        archive_name="squad-${target}.zip"
      fi
      archive_url="$base_url/$archive_name"
      checksums_url="$base_url/SHA256SUMS"

      tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/squad-install.XXXXXX")"
      if curl -fsSL "$archive_url" -o "$tmp_dir/$archive_name" 2>/dev/null; then
        if ! curl -fsSL "$checksums_url" -o "$tmp_dir/SHA256SUMS" 2>/dev/null; then
          echo "Error: missing checksum manifest SHA256SUMS for $archive_name" >&2
          rm -rf "$tmp_dir"
          exit 1
        fi
        local checksum_line expected_hash actual_hash
        checksum_line="$(awk -v archive="$archive_name" '
          { sub(/\r$/, "") }
          {
            start = length($0) - length(archive) + 1
            if (start >= 1 && substr($0, start) == archive &&
                (start == 1 || substr($0, start - 1, 1) ~ /[[:space:]*]/)) print
          }
        ' "$tmp_dir/SHA256SUMS")"
        local checksum_error=""
        case "$checksum_line" in
          "") checksum_error=missing ;;
          *$'\n'*) checksum_error=duplicate ;;
        esac
        if [[ -n "$checksum_error" ]]; then
          echo "Error: $checksum_error checksum for $archive_name in SHA256SUMS" >&2
          rm -rf "$tmp_dir"
          exit 1
        fi
        expected_hash="$(awk '{print tolower($1)}' <<<"$checksum_line")"
        if command -v sha256sum >/dev/null 2>&1; then
          actual_hash="$(sha256sum "$tmp_dir/$archive_name" | awk '{print $1}')"
        elif command -v shasum >/dev/null 2>&1; then
          actual_hash="$(shasum -a 256 "$tmp_dir/$archive_name" | awk '{print $1}')"
        else
          echo "Error: neither sha256sum nor shasum found for checksum verification" >&2
          rm -rf "$tmp_dir"
          exit 1
        fi

        if [[ -z "$actual_hash" || "$actual_hash" != "$expected_hash" ]]; then
          echo "Error: checksum mismatch for $archive_name (expected $expected_hash, got $actual_hash)" >&2
          rm -rf "$tmp_dir"
          exit 1
        fi

        mkdir "$tmp_dir/extracted"
        if ! extract_squad "$tmp_dir/$archive_name" "$tmp_dir/extracted" ||
          [[ ! -f "$tmp_dir/extracted/$squad_bin_name" || -L "$tmp_dir/extracted/$squad_bin_name" ]]; then
          echo "Error: could not extract $squad_bin_name from $archive_name" >&2
          rm -rf "$tmp_dir"
          exit 1
        fi
        if ! install_squad_binary "$tmp_dir/extracted/$squad_bin_name"; then
          rm -rf "$tmp_dir"
          exit 1
        fi
        installed=1
      fi
      rm -rf "$tmp_dir"
    fi
  fi

  if (( installed == 0 )); then
    if command -v cargo >/dev/null 2>&1; then
      echo "Building squad from source..."
      cargo build --release --locked --manifest-path "$repo_dir/Cargo.toml"
      install_squad_binary "$repo_dir/target/release/$squad_bin_name"
      installed=1
    elif (( build_squad == 0 )) && command -v "$squad_bin_name" >/dev/null 2>&1; then
      local existing_version
      existing_version="$("$squad_bin_name" --version 2>/dev/null || true)"
      echo "Warning: keeping existing squad on PATH ($existing_version)" >&2
      installed=1
    else
      echo "Could not get squad: install Rust (https://rustup.rs) and rerun, or download a binary from https://github.com/bthanhtung/squad-devkit/releases" >&2
      exit 1
    fi
  fi

  if command -v "$squad_bin_name" >/dev/null 2>&1; then
    local current_squad
    current_squad="$(command -v "$squad_bin_name")"
    if [[ "$current_squad" != "$bin_directory/$squad_bin_name" ]]; then
      printf 'Warning: %s shadows %s earlier on PATH\n' "$current_squad" "$bin_directory/$squad_bin_name" >&2
    fi
  fi
}

extract_squad() {
  local archive="$1" destination="$2"
  if [[ "$archive" != *.zip ]]; then
    tar -xzf "$archive" -C "$destination" squad
  elif command -v unzip >/dev/null 2>&1; then
    unzip -q "$archive" squad.exe -d "$destination"
  elif command -v python3 >/dev/null 2>&1; then
    python3 -m zipfile -e "$archive" "$destination"
  elif command -v python >/dev/null 2>&1; then
    python -m zipfile -e "$archive" "$destination"
  else
    SQUAD_ZIP="$(cygpath -w "$archive")" SQUAD_EXTRACT="$(cygpath -w "$destination")" \
      powershell.exe -NoProfile -Command '$ErrorActionPreference = "Stop"; Expand-Archive -LiteralPath $env:SQUAD_ZIP -DestinationPath $env:SQUAD_EXTRACT'
  fi
}

install_squad_binary() {
  local staged
  [[ ! -d "$bin_directory/$squad_bin_name" ]] || return 1
  mkdir -p "$bin_directory" && staged="$(mktemp "$bin_directory/.squad-install.XXXXXX")" || return 1
  if ! cp "$1" "$staged" || ! chmod 755 "$staged" || ! mv -f "$staged" "$bin_directory/$squad_bin_name"; then
    rm -f "$staged"
    return 1
  fi
}

install_command_entry() {
  local source="$script_dir/$1.sh" target="$bin_directory/$2" escaped
  if (( windows_install )); then
    escaped=${source//\'/\'\\\'\'}
    rm -f "$target"
    printf '#!/usr/bin/env bash\nexec '\''%s'\'' "$@"\n' "$escaped" >"$target"
    chmod 755 "$target"
  else
    ln -sfn "$source" "$target"
    [[ -L "$target" ]] || { printf 'Error: expected symlink at %s\n' "$target" >&2; return 1; }
  fi
}

install_os="${SQUAD_INSTALL_OS:-$(uname -s)}"
windows_install=0
squad_bin_name=squad
case "$install_os" in
  MINGW*|MSYS*|CYGWIN*) windows_install=1; squad_bin_name=squad.exe ;;
esac
bin_directory="${SQUAD_DEVKIT_BIN_DIR:-$HOME/.local/bin}"
ensure_squad
mkdir -p "$bin_directory"
install_command_entry squad-devkit squad-devkit
install_command_entry squad-worker squad-worker
install_command_entry squad-worker-monitor squad-monitor
install_command_entry squad-orchestration squad-orchestration
install_command_entry squad-route squad-route
install_command_entry squad-ask squad-ask
install_command_entry squad-telegram squad-telegram
printf 'Linked squad-devkit, squad-worker, squad-monitor, squad-orchestration, squad-route, squad-ask, and squad-telegram into %s\n' "$bin_directory"

# The skill is a link into this repository, so pulling updates it.
if (( install_skill == 1 )); then
  skill_source="$(cd "$script_dir/.." && pwd)/skills/squad-devkit"
  for skills_directory in "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills" "${CODEX_HOME:-$HOME/.codex}/skills"; do
    # Only for tools that are set up on this machine.
    [[ -d "$(dirname "$skills_directory")" ]] || continue
    target="$skills_directory/squad-devkit"
    if [[ -e "$target" && ! -L "$target" ]]; then
      printf 'Skill: kept your own %s (not a link)\n' "$target"
      continue
    fi
    mkdir -p "$skills_directory"
    if (( windows_install )); then
      if MSYS=winsymlinks:nativestrict ln -sfn "$skill_source" "$target" && [[ -L "$target" ]]; then
        printf 'Skill: linked %s\n' "$target"
      else
        printf 'Skill: skipped %s (native symlinks unavailable)\n' "$target" >&2
      fi
    else
      ln -sfn "$skill_source" "$target"
      printf 'Skill: linked %s\n' "$target"
    fi
  done
fi

# The squad deck, as a user-scope plugin read in place from this repository.
# Every failure here is a warning: the deck is optional.
if (( install_deck == 1 )); then
  deck_claude="$(command -v claude 2>/dev/null || true)"
  deck_root="$(cd "$script_dir/.." && pwd)"
  deck_plugins="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins"
  deck_version=""
  [[ -z "$deck_claude" ]] || deck_version="$("$deck_claude" --version 2>/dev/null | head -n 1 || true)"
  deck_parts="$(printf '%s' "$deck_version" | sed -n 's/^[^0-9]*\([0-9][0-9]*\)\.\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2 \3/p')"
  if [[ -z "$deck_claude" ]]; then
    :
  elif [[ -z "$deck_parts" ]]; then
    printf 'Deck: skipped (could not read the Claude Code version)\n'
  else
    read -r deck_major deck_minor deck_patch <<<"$deck_parts"
    # shellcheck disable=SC2154 # set in lib/squad-devkit-agents.sh
    IFS=. read -r need_major need_minor need_patch <<<"$deck_min_claude_version"
    if (( 10#$deck_major * 1000000000 + 10#$deck_minor * 1000000 + 10#$deck_patch < need_major * 1000000000 + need_minor * 1000000 + need_patch )); then
      printf 'Deck: skipped (Claude Code %s.%s.%s is older than %s)\n' "$deck_major" "$deck_minor" "$deck_patch" "$deck_min_claude_version"
    else
      deck_done=""
      if [[ -f "$deck_plugins/known_marketplaces.json" ]] &&
        squad_jq -e 'has("squad-devkit")' "$deck_plugins/known_marketplaces.json" >/dev/null 2>&1; then
        deck_done="marketplace squad-devkit already added"
      elif "$deck_claude" plugin marketplace add "$deck_root" >/dev/null 2>&1; then
        deck_done="added marketplace squad-devkit"
      else
        printf 'Deck: warning: could not add the squad-devkit marketplace; run: claude plugin marketplace add %s\n' "$deck_root" >&2
      fi
      if [[ -n "$deck_done" ]]; then
        if deck_key="$(deck_installed_plugin)"; then
          printf 'Deck: %s, %s already installed\n' "$deck_done" "$deck_key"
        elif "$deck_claude" plugin install squad-deck@squad-devkit --scope user >/dev/null 2>&1; then
          printf 'Deck: %s, installed squad-deck@squad-devkit (user scope); run /reload-plugins in a running session\n' "$deck_done"
        else
          printf 'Deck: warning: could not install squad-deck; run: claude plugin install squad-deck@squad-devkit --scope user\n' >&2
        fi
      fi
    fi
  fi
fi
case ":$PATH:" in
  *":$bin_directory:"*) ;;
  *)
    if (( windows_install )); then
      printf 'Add %s to PATH in ~/.bashrc for Git Bash/MSYS2.\n' "$bin_directory"
    else
      printf 'Add %s to PATH in your shell startup file.\n' "$bin_directory"
    fi
    ;;
esac

interactive=0
if (( no_prompt == 0 )) && { [[ -t 0 ]] || is_truthy "${SQUAD_DEVKIT_FORCE_PROMPT:-}"; }; then
  interactive=1
fi
# On the first interactive install (no saved setup_mode yet), offer the full
# setup wizard; --manager and --no-prompt skip it.
if (( interactive == 1 )) && [[ -z "$manager_client" ]] &&
  [[ -z "$(devkit_config_get setup_mode)" ]]; then
  if ! run_setup_wizard; then
    printf 'Setup skipped; run squad-devkit --setup later.\n' >&2
  fi
fi
if [[ -n "$manager_client" ]]; then
  manager_client="$(resolve_manager "$manager_client" "$interactive")"
  save_manager "$manager_client"
else
  manager_client="$(resolve_manager "" "$interactive")"
fi
printf 'Manager: %s (%s)\n' "$manager_client" "$(manager_label "$manager_client")"

worker_engines=()
saved_workers="$(devkit_config_get workers)"
disabled_workers="$(devkit_config_get disabled_workers)"
# A disabled engine is always skipped, mirroring worker_enabled in the launcher.
worker_disabled() {
  local engine
  for engine in ${disabled_workers//,/ }; do
    [[ "$engine" == "$1" ]] && return 0
  done
  return 1
}
# List only installed, enabled engines: the saved workers order when one is set
# (custom setup), otherwise the built-in trust order.
if [[ -n "$saved_workers" ]]; then
  for engine in ${saved_workers//,/ }; do
    if command -v "$engine" >/dev/null 2>&1 && ! worker_disabled "$engine"; then
      worker_engines+=("$engine")
    fi
  done
else
  # shellcheck disable=SC2154 # worker_engine_order is defined in lib/squad-devkit-agents.sh
  for engine in "${worker_engine_order[@]}"; do
    if command -v "$engine" >/dev/null 2>&1 && ! worker_disabled "$engine"; then
      worker_engines+=("$engine")
    fi
  done
fi
if [[ -z "${worker_engines[*]:-}" ]]; then
  echo 'Workers: none (install claude, codex, opencode, grok, or ccr; until then the manager does the work itself)'
elif [[ "$(devkit_config_get setup_mode)" == custom ]]; then
  printf 'Workers (in the order you chose): %s\n' "${worker_engines[*]}"
else
  printf 'Workers (most trusted first): %s\n' "${worker_engines[*]}"
fi
hud_config="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/claude-hud/config.json"
if (( configure_hud == 1 )) && [[ -d "$(dirname "$hud_config")" ]] && command -v jq >/dev/null 2>&1; then
  current="$(cat "$hud_config" 2>/dev/null || echo '{}')"
  if updated="$(jq '.display = ({sevenDayThreshold: 0, usagePace: true} + (.display // {}))' <<<"$current" 2>/dev/null)"; then
    if [[ "$(jq -c . <<<"$current" 2>/dev/null)" != "$(jq -c . <<<"$updated")" ]]; then
      printf '%s\n' "$updated" >"$hud_config.tmp" && mv "$hud_config.tmp" "$hud_config"
      echo "claude-hud: weekly quota and usage pace enabled ($hud_config)"
    else
      echo 'claude-hud: weekly quota display already configured'
    fi
  fi
fi

cat <<EOF

Shell completions:
  Bash: source "$script_dir/completions/squad-devkit.bash" (add to ~/.bashrc)
  Zsh:  fpath=("$script_dir/completions" \$fpath); autoload -Uz compinit && compinit (add to ~/.zshrc)

Start with: squad-devkit [project] [objective]
EOF
