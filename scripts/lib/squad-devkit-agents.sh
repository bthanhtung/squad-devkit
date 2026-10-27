#!/usr/bin/env bash
# Manager CLI selection shared by squad-devkit and install-devkit.
# Expects shell_join from squad-tmux-launcher-helpers.sh.

manager_clients=(claude codex agy gemini grok opencode)

manager_label() {
  case "$1" in
    claude) printf 'Claude Code' ;;
    codex) printf 'Codex CLI' ;;
    agy) printf 'Antigravity CLI' ;;
    gemini) printf 'Gemini CLI' ;;
    grok) printf 'Grok Build' ;;
    opencode) printf 'OpenCode' ;;
    *) return 1 ;;
  esac
}

is_manager_client() {
  manager_label "$1" >/dev/null 2>&1
}

# The --client value squad join accepts for this CLI, if any.
squad_client_flag() {
  case "$1" in
    claude|codex|gemini|opencode) printf '%s' "$1" ;;
  esac
}

# Prints the interactive command that starts a manager with an initial prompt.
manager_start_command() {
  local client="$1"
  local prompt="$2"
  local binary
  binary="$(command -v "$client")"
  local permission_mode="${SQUAD_DEVKIT_PERMISSION_MODE-auto}"
  case "$client" in
    claude)
      if [[ -n "$permission_mode" && "$permission_mode" != default ]]; then
        shell_join "$binary" --permission-mode "$permission_mode" "$prompt"
      else
        shell_join "$binary" "$prompt"
      fi
      ;;
    codex|grok) shell_join "$binary" "$prompt" ;;
    agy|gemini) shell_join "$binary" -i "$prompt" ;;
    opencode) shell_join "$binary" --prompt "$prompt" ;;
  esac
}

installed_manager_clients() {
  local client
  for client in "${manager_clients[@]}"; do
    if command -v "$client" >/dev/null 2>&1; then
      printf '%s\n' "$client"
    fi
  done
}

devkit_config_file() {
  printf '%s' "${SQUAD_DEVKIT_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/squad-devkit/config}"
}

devkit_config_get() {
  local file
  file="$(devkit_config_file)"
  [[ -f "$file" ]] || return 0
  sed -n "s/^$1=//p" "$file" | tail -n 1
}

devkit_config_set() {
  local file
  file="$(devkit_config_file)"
  mkdir -p "$(dirname "$file")"
  if [[ -f "$file" ]]; then
    grep -v "^$1=" "$file" >"$file.tmp" || true
    mv "$file.tmp" "$file"
  fi
  printf '%s=%s\n' "$1" "$2" >>"$file"
}

saved_manager() {
  devkit_config_get manager
}

save_manager() {
  devkit_config_set manager "$1"
}

# Asks which installed CLI should be the manager; prints the choice.
# The first option is Claude Code when installed, otherwise the first CLI found.
prompt_for_manager() {
  local reason="$1"
  local clients=()
  local client=""
  while IFS= read -r client; do
    [[ -n "$client" ]] && clients+=("$client")
  done < <(installed_manager_clients)
  if (( ${#clients[@]} == 0 )); then
    echo "No supported manager CLI found. Install one of: ${manager_clients[*]}" >&2
    return 1
  fi
  printf '%s\n' "$reason" >&2
  local index
  for index in "${!clients[@]}"; do
    printf '  %d) %-9s %s\n' "$((index + 1))" "${clients[$index]}" "$(manager_label "${clients[$index]}")" >&2
  done
  local answer=""
  while true; do
    printf 'Manager [1]: ' >&2
    if ! IFS= read -r answer; then
      printf '\nNo manager chosen; aborting.\n' >&2
      return 1
    fi
    answer="${answer//[[:space:]]/}"
    answer="${answer:-1}"
    if [[ "$answer" =~ ^[0-9]+$ ]] && (( answer >= 1 && answer <= ${#clients[@]} )); then
      printf '%s\n' "${clients[$((answer - 1))]}"
      return 0
    fi
    for client in "${clients[@]}"; do
      if [[ "$answer" == "$client" ]]; then
        printf '%s\n' "$client"
        return 0
      fi
    done
    printf 'Enter a number from 1 to %d.\n' "${#clients[@]}" >&2
  done
}

# Resolves the manager CLI: explicit value, saved choice, Claude Code by default,
# or a one-time question when Claude Code is missing. Saves first-time answers.
resolve_manager() {
  local requested="$1"
  local interactive="$2"
  local client="$requested"
  if [[ -z "$client" ]]; then
    client="$(saved_manager)"
    if [[ -n "$client" ]] && ! command -v "$client" >/dev/null 2>&1; then
      echo "Saved manager '$client' is no longer installed; choosing again." >&2
      client=""
    fi
  fi
  if [[ -z "$client" ]]; then
    if command -v claude >/dev/null 2>&1; then
      client=claude
    elif (( interactive == 1 )); then
      client="$(prompt_for_manager 'Claude Code is not installed. Choose the CLI that manages the squad:')" || return 1
      save_manager "$client"
      printf 'Saved manager: %s (%s). Change it with: squad-devkit --setup\n' \
        "$client" "$(devkit_config_file)" >&2
    else
      client="$(installed_manager_clients | head -n 1)"
      if [[ -z "$client" ]]; then
        echo "No supported manager CLI found. Install one of: ${manager_clients[*]}" >&2
        return 1
      fi
      echo "Claude Code is not installed; using $client as the manager." >&2
    fi
  fi
  if ! is_manager_client "$client"; then
    echo "Unknown manager: $client (use one of: ${manager_clients[*]})" >&2
    return 1
  fi
  if ! command -v "$client" >/dev/null 2>&1; then
    echo "Manager CLI not installed: $client" >&2
    return 1
  fi
  printf '%s\n' "$client"
}
