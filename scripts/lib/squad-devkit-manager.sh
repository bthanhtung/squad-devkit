#!/usr/bin/env bash
# Runs one manager session in the current project: archives managers whose
# process has exited, joins the squad, starts the manager CLI with the role
# prompt, and leaves the squad when the CLI exits.
# Usage: squad-devkit-manager.sh <client> <prompt>
# The prompt may contain {{MANAGER_ID}}, replaced by the joined agent ID.
set -euo pipefail

lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$lib_dir/squad-tmux-launcher-helpers.sh"
source "$lib_dir/squad-devkit-agents.sh"

client="$1"
prompt_template="$2"
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

prompt="${prompt_template//\{\{MANAGER_ID\}\}/$manager_id}"
if [[ -f .squad/roles/manager-devkit.md ]]; then
  prompt+=$'\n\n'"## Your role (.squad/roles/manager-devkit.md)"$'\n\n'
  prompt+="$(grep -v '^<!-- squad-devkit template' .squad/roles/manager-devkit.md)"
fi

# squad-worker reads these, so workers report to this manager and record
# their tasks here even when they work in another project (--project).
export SQUAD_MANAGER_ID="$manager_id"
export SQUAD_DEVKIT_WORKSPACE="$PWD"
status=0
eval "$(manager_start_command "$client" "$prompt")" || status=$?
exit "$status"
