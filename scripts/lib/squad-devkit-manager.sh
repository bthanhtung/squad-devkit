#!/usr/bin/env bash
# Runs one manager session in the current project: archives managers whose
# process has exited, joins the squad, starts the manager CLI with the role
# prompt, and leaves the squad when the CLI exits.
# Usage: squad-devkit-manager.sh <client> <instructions> [message]
# The instructions may contain {{MANAGER_ID}}, replaced by the joined agent ID;
# the message is the human's first request, shown in the chat.
set -euo pipefail

lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$lib_dir/squad-tmux-launcher-helpers.sh"
source "$lib_dir/squad-devkit-agents.sh"

client="$1"
prompt_template="$2"
first_message="${3:-}"
pid_directory=".squad/managers"
mkdir -p "$pid_directory"

# A manager is stale when its recorded process is gone, or, for managers
# without a pid file, when it has not been seen for SQUAD_DEVKIT_STALE_MINUTES.
stale_cutoff=$(( $(date +%s) - ${SQUAD_DEVKIT_STALE_MINUTES:-30} * 60 ))
while IFS= read -r line; do
  [[ "$line" == *'"role":"manager-devkit"'* ]] || continue
  agent_id="$(printf '%s' "$line" | sed -n 's/^{"id":"\([^"]*\)".*/\1/p')"
  last_seen="$(printf '%s' "$line" | sed -n 's/.*"last_seen":\([0-9]*\).*/\1/p')"
  [[ -n "$agent_id" ]] || continue
  pid_file="$pid_directory/$agent_id.pid"
  if [[ -f "$pid_file" ]]; then
    kill -0 "$(cat "$pid_file")" 2>/dev/null && continue
  elif [[ -n "$last_seen" ]] && (( last_seen >= stale_cutoff )); then
    continue
  fi
  squad leave "$agent_id" >/dev/null 2>&1 || true
  rm -f "$pid_file"
done < <(squad agents --json 2>/dev/null || true)

join_arguments=(join manager --role manager-devkit)
client_flag="$(squad_client_flag "$client")"
[[ -n "$client_flag" ]] && join_arguments+=(--client "$client_flag")
join_arguments+=(--protocol-version 2)
join_output="$(squad "${join_arguments[@]}")"
manager_id="$(printf '%s\n' "$join_output" | sed -n 's/.*Joined as \([^ ]*\) (role:.*/\1/p' | head -n 1)"
if [[ -z "$manager_id" ]]; then
  printf '%s\n' "$join_output" >&2
  echo "Could not join the squad as manager" >&2
  exit 1
fi
printf '%s\n' "$$" >"$pid_directory/$manager_id.pid"
leave_squad() {
  squad leave "$manager_id" >/dev/null 2>&1 || true
  rm -f "$pid_directory/$manager_id.pid"
}
trap leave_squad EXIT

# The launcher writes {{MANAGER_LABEL}} so the same instructions also fit a
# fallback manager.
build_instructions() {
  local text="${prompt_template//\{\{MANAGER_ID\}\}/$manager_id}"
  text="${text//\{\{MANAGER_LABEL\}\}/$(manager_label "$1")}"
  if [[ -f .squad/roles/manager-devkit.md ]]; then
    text+=$'\n\n'"## Your role (.squad/roles/manager-devkit.md)"$'\n\n'
    text+="$(grep -v '^<!-- squad-devkit template' .squad/roles/manager-devkit.md)"
  fi
  printf '%s' "$text"
}

# squad-worker reads these, so workers report to this manager and record
# their tasks here even when they work in another project (--project).
export SQUAD_MANAGER_ID="$manager_id"
export SQUAD_DEVKIT_WORKSPACE="$PWD"
export SQUAD_DEVKIT_MANAGER_WRAPPER_PID="$$"

# When Claude Code is the manager, a StopFailure hook hands the session to a
# fallback manager once the account hits its usage or billing limit.
fallback=""
handoff_marker="$pid_directory/$manager_id.handoff.json"
settings_file=""
if [[ "$client" == claude ]]; then
  fallback="${SQUAD_DEVKIT_FALLBACK_MANAGER-codex}"
  if [[ "$fallback" == none || "$fallback" == claude ]] || ! command -v "$fallback" >/dev/null 2>&1 ||
    ! is_manager_client "$fallback"; then
    fallback=""
  fi
fi
rm -f "$handoff_marker"
if [[ -n "$fallback" ]]; then
  settings_file="$pid_directory/$manager_id.settings.json"
  hook_command="$(shell_join "$lib_dir/squad-devkit-handoff-hook.sh" "$PWD/$handoff_marker")"
  jq -n --arg matcher "${SQUAD_DEVKIT_FALLBACK_ON:-rate_limit|billing_error}" --arg command "$hook_command" \
    '{hooks: {StopFailure: [{matcher: $matcher, hooks: [{type: "command", command: $command}]}]}}' >"$settings_file" 2>/dev/null ||
    settings_file=""
fi

status=0
eval "$(manager_start_command "$client" "$(build_instructions "$client")" "$first_message" "$settings_file")" || status=$?
[[ -n "$settings_file" ]] && rm -f "$settings_file"
if [[ -z "$fallback" || ! -f "$handoff_marker" ]]; then
  exit "$status"
fi

# Hand off: write the recent conversation and task state for the fallback.
error="$(jq -r '.error // "unknown"' "$handoff_marker" 2>/dev/null || echo unknown)"
transcript="$(jq -r '.transcript_path // empty' "$handoff_marker" 2>/dev/null || true)"
handoff_notes="$pid_directory/$manager_id.handoff.md"
{
  printf '# Manager handoff\n\nClaude Code stopped with `%s` at %s.\n\n' "$error" "$(date '+%Y-%m-%d %H:%M')"
  printf '## Recent conversation\n\n'
  if [[ -f "$transcript" ]]; then
    jq -r '
      select(.type == "user" or .type == "assistant") | . as $entry
      | (.message.content | if type == "string" then .
          else [.[]? | select(.type == "text") | .text] | join("\n") end) as $text
      | select(($text | length) > 0)
      | "**\($entry.type)**: \($text | .[0:1500])\n"' "$transcript" 2>/dev/null | tail -n 120
  else
    printf '(transcript not available)\n'
  fi
  printf '\n## Squad tasks\n\n```\n%s\n```\n' "$(squad task list 2>&1 | tail -n 80)"
  printf '\nPlans: .squad/plans/  Worker reports: .squad/workers/\n'
} >"$handoff_notes"
rm -f "$handoff_marker"

printf '\n\033[1m[squad-devkit] Claude Code stopped (%s). Handing over to %s as manager.\033[0m\n\n' \
  "$error" "$(manager_label "$fallback")" >&2
handoff_message="Claude Code, the previous manager of this squad, stopped because it hit a limit ($error). You are now the manager, with the same squad ID. Read $PWD/$handoff_notes (recent conversation and task state), .squad/plans/, and squad task list. Workers that were running may have stopped with Claude Code: rerun unfinished tasks. Then tell the human briefly where things stand and continue the work."
status=0
eval "$(manager_start_command "$fallback" "$(build_instructions "$fallback")" "$handoff_message")" || status=$?
exit "$status"
