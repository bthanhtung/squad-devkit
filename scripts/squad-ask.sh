#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: squad-ask --from ID --workspace DIR --to ID [--timeout SECONDS] QUESTION
       squad-ask --from ID --workspace DIR --reply ID ANSWER
       squad-ask --from ID --workspace DIR --check

Lets a squad worker talk to the manager or to another worker while it runs.

  --to ID      Send QUESTION and wait for the first reply (default 300 seconds).
               With no reply in time, carry on with your best judgment and
               record the assumption in your report.
  --reply ID   Send ANSWER to ID without waiting.
  --check      Print unread messages without waiting (for example questions
               from other workers); answer them with --reply.
EOF
}

from=""
workspace=""
to=""
reply_to=""
check=0
timeout="${SQUAD_ASK_TIMEOUT:-300}"
text=""
while (( $# > 0 )); do
  case "$1" in
    --from|--workspace|--to|--reply|--timeout)
      if (( $# < 2 )) || [[ -z "$2" ]]; then
        echo "Missing value for $1" >&2
        exit 2
      fi
      case "$1" in
        --from) from="$2" ;;
        --workspace) workspace="$2" ;;
        --to) to="$2" ;;
        --reply) reply_to="$2" ;;
        --timeout) timeout="$2" ;;
      esac
      shift
      ;;
    --check) check=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    *) text="${text:+$text }$1" ;;
  esac
  shift
done

if [[ -z "$from" || -z "$workspace" ]] || { (( check == 0 )) && [[ -z "$to$reply_to" ]]; }; then
  usage >&2
  exit 2
fi
if [[ ! -d "$workspace/.squad" ]]; then
  echo "Not a squad workspace: $workspace" >&2
  exit 2
fi
cd "$workspace"

if (( check == 1 )); then
  squad receive "$from" 2>/dev/null || true
  exit 0
fi
if [[ -z "${text//[[:space:]]/}" ]]; then
  echo "The message is empty" >&2
  exit 2
fi
if [[ -n "$reply_to" ]]; then
  squad send "$from" "$reply_to" "ANSWER from $from: $text" >/dev/null
  echo "Sent to $reply_to."
  exit 0
fi

squad send "$from" "$to" "QUESTION from $from (reply with squad-ask --reply $from, or squad send $to $from \"...\"): $text" >/dev/null
answer="$(squad receive "$from" --wait --timeout "$timeout" 2>/dev/null || true)"
if [[ -z "$answer" || "$answer" == *'No new messages'* ]]; then
  echo "No answer from $to within ${timeout}s. Continue with your best judgment and state the assumption in your report."
  exit 0
fi
printf '%s\n' "$answer"
