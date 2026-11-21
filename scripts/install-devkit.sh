#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/lib/squad-tmux-launcher-helpers.sh"
source "$script_dir/lib/squad-devkit-agents.sh"

usage() {
  cat <<'EOF'
Usage: install-devkit.sh [--manager CLI] [--no-prompt] [--no-hud] [--no-skill] [--build-squad] [--with-tokeneconomizer]

Link squad-devkit, squad-worker, squad-monitor, squad-orchestration, squad-route, squad-ask,
squad-telegram, and squad-tokeneconomizer into ~/.local/bin (or SQUAD_DEVKIT_BIN_DIR)
and choose the manager CLI. Claude Code is the default when installed; without
it, the installer asks which installed CLI should manage and saves the answer.
Re-run it, or run squad-devkit --setup, to change the choice.

Pass --build-squad to compile the squad message bus binary from source using cargo
instead of downloading a prebuilt release binary.

Pass --with-tokeneconomizer to opt into the experimental Codex TokenEconomizer
plugin (pinned upstream checkout and Codex plugin registration). Off by default;
if optional installation fails, a warning is printed and base squad-devkit remains usable.

If the claude-hud status line plugin is installed, the installer also turns on
its weekly quota and usage-pace display (display.sevenDayThreshold = 0,
display.usagePace = true) unless you already set those keys; --no-hud skips it.
The manager's status line then shows the weekly quota next to the squad label.

It also installs the squad-devkit skill for Claude Code (~/.claude/skills) and
Codex (~/.codex/skills) as a link to skills/squad-devkit in this repository, so
any session can delegate to workers and `git pull` keeps the skill current;
--no-skill skips it. An existing non-link directory there is left untouched.
EOF
}

manager_client=""
no_prompt=0
configure_hud=1
install_skill=1
build_squad=0
with_tokeneconomizer=0
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
    --build-squad) build_squad=1 ;;
    --with-tokeneconomizer) with_tokeneconomizer=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

detect_squad_target() {
  if ! command -v uname >/dev/null 2>&1; then
    return 1
  fi
  local os arch
  os="$(uname -s)"
  arch="$(uname -m)"
  case "$os" in
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

  if (( build_squad == 0 )) && command -v squad >/dev/null 2>&1; then
    local version_output matched=0 token
    version_output="$(squad --version 2>/dev/null || true)"
    local -a tokens=()
    read -r -a tokens <<<"$version_output"
    for token in "${tokens[@]}"; do
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
      archive_url="$base_url/$archive_name"
      checksums_url="$base_url/SHA256SUMS"

      tmp_dir="$(mktemp -d)"
      if curl -fsSL "$checksums_url" -o "$tmp_dir/SHA256SUMS" 2>/dev/null && \
         curl -fsSL "$archive_url" -o "$tmp_dir/$archive_name" 2>/dev/null; then
        local checksum_line expected_hash actual_hash
        checksum_line="$(grep -E "(^|[[:space:]])${archive_name}\$" "$tmp_dir/SHA256SUMS" || true)"
        if [[ -z "$checksum_line" ]]; then
          echo "Error: missing checksum for $archive_name in SHA256SUMS" >&2
          rm -rf "$tmp_dir"
          exit 1
        fi
        expected_hash="$(awk '{print $1}' <<<"$checksum_line")"
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

        tar -xzf "$tmp_dir/$archive_name" -C "$tmp_dir"
        if [[ -f "$tmp_dir/squad" ]]; then
          mkdir -p "$bin_directory"
          cp "$tmp_dir/squad" "$bin_directory/squad"
          chmod 755 "$bin_directory/squad"
          installed=1
        fi
      fi
      rm -rf "$tmp_dir"
    fi
  fi

  if (( installed == 0 )); then
    if command -v cargo >/dev/null 2>&1; then
      echo "Building squad from source..."
      cargo build --release --locked --manifest-path "$repo_dir/Cargo.toml"
      mkdir -p "$bin_directory"
      cp "$repo_dir/target/release/squad" "$bin_directory/squad"
      chmod 755 "$bin_directory/squad"
      installed=1
    elif (( build_squad == 0 )) && command -v squad >/dev/null 2>&1; then
      local existing_version
      existing_version="$(squad --version 2>/dev/null || true)"
      echo "Warning: keeping existing squad on PATH ($existing_version)" >&2
      installed=1
    else
      echo "Could not get squad: install Rust (https://rustup.rs) and rerun, or download a binary from https://github.com/bthanhtung/squad-devkit/releases" >&2
      exit 1
    fi
  fi

  if command -v squad >/dev/null 2>&1; then
    local current_squad
    current_squad="$(command -v squad)"
    if [[ "$current_squad" != "$bin_directory/squad" ]]; then
      printf 'Warning: %s shadows %s/squad earlier on PATH\n' "$current_squad" "$bin_directory" >&2
    fi
  fi
}

bin_directory="${SQUAD_DEVKIT_BIN_DIR:-$HOME/.local/bin}"
ensure_squad
mkdir -p "$bin_directory"
ln -sfn "$script_dir/squad-devkit.sh" "$bin_directory/squad-devkit"
ln -sfn "$script_dir/squad-worker.sh" "$bin_directory/squad-worker"
ln -sfn "$script_dir/squad-worker-monitor.sh" "$bin_directory/squad-monitor"
ln -sfn "$script_dir/squad-orchestration.sh" "$bin_directory/squad-orchestration"
ln -sfn "$script_dir/squad-route.sh" "$bin_directory/squad-route"
ln -sfn "$script_dir/squad-ask.sh" "$bin_directory/squad-ask"
ln -sfn "$script_dir/squad-telegram.sh" "$bin_directory/squad-telegram"
ln -sfn "$script_dir/squad-tokeneconomizer.sh" "$bin_directory/squad-tokeneconomizer"
printf 'Linked squad-devkit, squad-worker, squad-monitor, squad-orchestration, squad-route, squad-ask, squad-telegram, and squad-tokeneconomizer into %s\n' "$bin_directory"

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
    ln -sfn "$skill_source" "$target"
    printf 'Skill: linked %s\n' "$target"
  done
fi
case ":$PATH:" in
  *":$bin_directory:"*) ;;
  *) printf 'Add %s to your PATH to run them from any terminal.\n' "$bin_directory" ;;
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
if (( ${#worker_engines[@]} == 0 )); then
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

if (( with_tokeneconomizer == 1 )); then
  if ! "$script_dir/squad-tokeneconomizer.sh" install; then
    echo "Warning: optional TokenEconomizer installation failed; base squad-devkit installation remains usable. Run squad-tokeneconomizer install to retry." >&2
  fi
fi

cat <<EOF

Shell completions:
  Bash: source "$script_dir/completions/squad-devkit.bash" (add to ~/.bashrc)
  Zsh:  fpath=("$script_dir/completions" \$fpath); autoload -Uz compinit && compinit (add to ~/.zshrc)

Start with: squad-devkit [project] [objective]
EOF
