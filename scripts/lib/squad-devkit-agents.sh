#!/usr/bin/env bash
# Manager CLI selection shared by squad-devkit and install-devkit.
# Expects shell_join from squad-tmux-launcher-helpers.sh.

manager_clients=(claude codex agy gemini grok opencode)

# Built-in trust order for worker engines (claude > codex > opencode > grok, agy > ccr).
worker_engine_order=(claude codex opencode grok agy ccr)

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

# One-line description of what each worker engine is best for.
worker_role_label() {
  case "$1" in
    claude) printf 'Must be right first time: high risk or high complexity (smallest model that fits)' ;;
    codex) printf 'Normal implementation, debugging, tests; anything needing a shell or MCP' ;;
    opencode) printf 'Low-risk implementation, second opinion' ;;
    grok) printf 'Low-risk implementation, second opinion (experimental)' ;;
    agy) printf 'Low-risk implementation, second opinion (experimental)' ;;
    ccr) printf 'Docs, comments, small exact edits (file tools only, no shell)' ;;
    *) return 1 ;;
  esac
}

# The --client value squad join accepts for this CLI, if any.
squad_client_flag() {
  case "$1" in
    claude|codex|gemini|opencode|grok|agy|ccr) printf '%s' "$1" ;;
  esac
}

# Only the exact boolean 1 opts this session into native permission bypass.
validate_yolo_client() {
  case "${SQUAD_DEVKIT_YOLO:-0}" in
    0) return 0 ;;
    1) ;;
    *) echo 'SQUAD_DEVKIT_YOLO must be 0 or 1' >&2; return 2 ;;
  esac
  case "$1" in
    claude|codex|agy) ;;
    *) echo 'YOLO supports only claude, codex, and agy' >&2; return 2 ;;
  esac
}

# Prints the interactive command that starts a manager. The instructions go
# to the system prompt where the CLI supports it (Claude Code, Codex), so the
# chat shows only the human's message; other CLIs receive them as the first
# message. The message may be empty. A fourth argument adds a Claude Code
# settings file (used for the handoff hook).
manager_start_command() {
  local client="$1"
  local instructions="$2"
  local message="${3:-}"
  validate_yolo_client "$client" || return $?
  local binary
  binary="$(command -v "$client")"
  local permission_mode="${SQUAD_DEVKIT_PERMISSION_MODE-auto}"
  local literal_quotes="'''"
  local arguments=()
  if [[ "${SQUAD_DEVKIT_YOLO:-0}" == 1 ]]; then
    case "$client" in
      codex) arguments+=(--dangerously-bypass-approvals-and-sandbox) ;;
      *) arguments+=(--dangerously-skip-permissions) ;;
    esac
  fi
  case "$client" in
    claude)
      if [[ "${SQUAD_DEVKIT_YOLO:-0}" == 1 ]]; then
        [[ -n "${4:-}" ]] || arguments+=(--settings '{"sandbox":{"enabled":false}}')
      elif [[ -n "$permission_mode" && "$permission_mode" != default ]]; then
        arguments+=(--permission-mode "$permission_mode")
      fi
      arguments+=(--append-system-prompt "$instructions")
      if [[ -n "${4:-}" ]]; then
        arguments+=(--settings "$4")
      fi
      ;;
    codex)
      # The value is a TOML literal string, which cannot contain three quotes.
      arguments+=(-c "developer_instructions=$literal_quotes${instructions//$literal_quotes/"' ' '"}$literal_quotes")
      ;;
    *)
      message="$instructions${message:+$'\n\n'"The human's request: $message"}"
      ;;
  esac
  if [[ -n "$message" ]]; then
    case "$client" in
      agy|gemini) arguments+=(-i "$message") ;;
      opencode) arguments+=(--prompt "$message") ;;
      *) arguments+=("$message") ;;
    esac
  fi
  shell_join "$binary" ${arguments[@]+"${arguments[@]}"}
}

installed_manager_clients() {
  local client
  for client in "${manager_clients[@]}"; do
    if command -v "$client" >/dev/null 2>&1; then
      printf '%s\n' "$client"
    fi
  done
}

# Prints installed worker engines in the built-in trust order.
installed_worker_engines() {
  local engine
  for engine in "${worker_engine_order[@]}"; do
    if command -v "$engine" >/dev/null 2>&1; then
      printf '%s\n' "$engine"
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

# Removes a key=value line from the config file, mirroring devkit_config_set.
devkit_config_unset() {
  local file
  file="$(devkit_config_file)"
  if [[ -f "$file" ]]; then
    grep -v "^$1=" "$file" >"$file.tmp" || true
    mv "$file.tmp" "$file"
  fi
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

# Asks a yes/no confirmation; empty or y/Y (or yes) means yes, anything else
# means no. EOF prints a message and returns 1.
confirm_save() {
  local answer=""
  printf 'Save this setup? [Y/n]: ' >&2
  if ! IFS= read -r answer; then
    printf '\nNo setup saved; aborting.\n' >&2
    return 1
  fi
  case "$answer" in
    ""|y|Y|yes|YES|Yes) return 0 ;;
    *) return 1 ;;
  esac
}

# Interactive setup wizard shared by `squad-devkit --setup` and the first
# interactive `install-devkit.sh` run. Detects installed AI CLIs, lets the user
# pick the manager and the worker engines and their preference order, and saves
# the result. Prompts and menus go to stderr; the final "Saved setup" line goes
# to stdout. Returns 0 after saving, 1 to abort without writing anything.
run_setup_wizard() {
  local client=""
  local engine=""
  local answer=""
  local mode=""
  local manager=""
  local managers=()
  local workers=()
  local ordered=""
  local index=0
  local tok=""
  local resolved=""
  local seen=""
  local ok=1
  local tokens=""

  # (a) Show what is installed.
  printf 'Detected AI CLIs:\n' >&2
  printf '  Managers:\n' >&2
  for client in "${manager_clients[@]}"; do
    if command -v "$client" >/dev/null 2>&1; then
      printf '    %-9s %-16s installed\n' "$client" "$(manager_label "$client")" >&2
    else
      printf '    %-9s %-16s not installed\n' "$client" "$(manager_label "$client")" >&2
    fi
  done
  printf '  Workers:\n' >&2
  for engine in "${worker_engine_order[@]}"; do
    if command -v "$engine" >/dev/null 2>&1; then
      printf '    %-9s %-16s installed\n' "$engine" "$(worker_role_label "$engine")" >&2
    else
      printf '    %-9s %-16s not installed\n' "$engine" "$(worker_role_label "$engine")" >&2
    fi
  done

  while IFS= read -r client; do
    [[ -n "$client" ]] && managers+=("$client")
  done < <(installed_manager_clients)
  if (( ${#managers[@]} == 0 )); then
    echo "No supported manager CLI found. Install one of: ${manager_clients[*]}" >&2
    return 1
  fi

  # (b) Choose the setup mode; 1 is the default on empty input.
  printf '1) Default (recommended)\n' >&2
  printf '2) Personal custom\n' >&2
  while [[ -z "$mode" ]]; do
    printf 'Setup [1]: ' >&2
    if ! IFS= read -r answer; then
      printf '\nNo setup chosen; aborting.\n' >&2
      return 1
    fi
    answer="${answer//[[:space:]]/}"
    answer="${answer:-1}"
    case "$answer" in
      1) mode=default ;;
      2) mode=custom ;;
      *) printf 'Enter 1 or 2.\n' >&2 ;;
    esac
  done

  if [[ "$mode" == custom ]]; then
    # (d) Personal custom: pick the manager, then the ordered workers.
    manager="$(prompt_for_manager 'Choose the manager CLI:')" || return 1
    while IFS= read -r engine; do
      [[ -n "$engine" ]] && workers+=("$engine")
    done < <(installed_worker_engines)

    printf 'Workers (installed):\n' >&2
    index=0
    for engine in "${workers[@]}"; do
      index=$((index + 1))
      printf '  %d) %-9s %s\n' "$index" "$engine" "$(worker_role_label "$engine")" >&2
    done

    ordered=""
    ok=0
    while (( ok == 0 )); do
      printf 'Workers in your preferred order (e.g. 2,1; empty = all in this order): ' >&2
      if ! IFS= read -r answer; then
        printf '\nNo setup saved; aborting.\n' >&2
        return 1
      fi
      ordered=""
      seen=""
      ok=1
      if [[ -z "${answer//[[:space:]]/}" ]]; then
        # Empty: every installed worker, in the order listed above.
        for engine in "${workers[@]}"; do
          ordered="${ordered:+$ordered,}$engine"
        done
      else
        tokens="${answer//,/ }"
        for tok in $tokens; do
          resolved=""
          if [[ "$tok" =~ ^[0-9]+$ ]]; then
            if (( tok >= 1 && tok <= ${#workers[@]} )); then
              resolved="${workers[$((tok - 1))]}"
            else
              printf 'No such worker number: %s\n' "$tok" >&2
              ok=0
              break
            fi
          elif [[ " ${worker_engine_order[*]} " == *" $tok "* ]]; then
            if command -v "$tok" >/dev/null 2>&1; then
              resolved="$tok"
            else
              printf 'Worker not installed: %s\n' "$tok" >&2
              ok=0
              break
            fi
          else
            printf 'Unknown worker: %s\n' "$tok" >&2
            ok=0
            break
          fi
          case ":$seen:" in
            *":$resolved:"*)
              printf 'Duplicate worker: %s\n' "$resolved" >&2
              ok=0
              break
              ;;
          esac
          seen+=":$resolved"
          ordered="${ordered:+$ordered,}$resolved"
        done
      fi
    done

    printf 'Manager: %s (%s) - plans, delegates, verifies; does not write code\n' \
      "$manager" "$(manager_label "$manager")" >&2
    printf 'Workers (in the order you chose):\n' >&2
    if [[ -n "$ordered" ]]; then
      for engine in ${ordered//,/ }; do
        printf '  - %-9s %s\n' "$engine" "$(worker_role_label "$engine")" >&2
      done
    else
      printf '  (none)\n' >&2
    fi
    confirm_save || return 1
    save_manager "$manager"
    devkit_config_set workers "$ordered"
    devkit_config_set setup_mode custom
    printf 'Saved setup to %s. Change it any time with: squad-devkit --setup\n' "$(devkit_config_file)"
    return 0
  fi

  # (c) Default: Claude Code when installed, else the first installed manager;
  # every installed worker in the built-in trust order.
  if command -v claude >/dev/null 2>&1; then
    manager=claude
  else
    manager="${managers[0]}"
  fi
  printf 'Manager: %s (%s) - plans, delegates, verifies; does not write code\n' \
    "$manager" "$(manager_label "$manager")" >&2
  printf 'Workers (most trusted first):\n' >&2
  while IFS= read -r engine; do
    [[ -n "$engine" ]] && workers+=("$engine")
  done < <(installed_worker_engines)
  index=0
  for engine in "${workers[@]}"; do
    index=$((index + 1))
    printf '  %d) %-9s %s\n' "$index" "$engine" "$(worker_role_label "$engine")" >&2
  done
  confirm_save || return 1
  save_manager "$manager"
  devkit_config_set setup_mode default
  devkit_config_unset workers
  printf 'Saved setup to %s. Change it any time with: squad-devkit --setup\n' "$(devkit_config_file)"
  return 0
}
