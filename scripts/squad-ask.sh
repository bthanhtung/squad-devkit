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
# IPC mode never opens or falls back to the manager database.
if [[ -n "${SQUAD_ASK_IPC_DIR:-}" ]]; then
  command -v python3 >/dev/null 2>&1 || { echo 'IPC mode requires python3' >&2; exit 1; }
  exec python3 - "$SQUAD_ASK_IPC_DIR" "$to" "$reply_to" "$check" "$timeout" "$text" <<'PYIPC'
import json
import os
import pathlib
import sys
import stat
import time
import uuid

try:
    directory, to, reply, check, timeout, text = sys.argv[1:]
    if not timeout.isascii() or not timeout.isdecimal() or not 1 <= int(timeout) <= 300:
        raise ValueError("IPC timeout must be 1..300 seconds")
    if check != "1" and not text.strip():
        raise ValueError("The message is empty")
    directory = pathlib.Path(directory).resolve(strict=True)
    if not directory.is_dir():
        raise ValueError("IPC directory is unavailable")
    request_id = str(uuid.uuid4())
    request = {"version": 1, "id": request_id,
               "op": "check" if check == "1" else "reply" if reply else "send",
               "to": reply or to, "text": text, "timeout": int(timeout)}
    data = json.dumps(request).encode()
    if len(data) > 16384:
        raise ValueError("IPC request exceeds 16 KiB")
    pending = directory / (request_id + ".tmp")
    request_path = directory / (request_id + ".request.json")
    response_path = directory / (request_id + ".response.json")
    try:
        with pending.open("xb") as stream:
            os.chmod(pending, 0o600)
            stream.write(data)
        pending.rename(request_path)
        deadline = time.monotonic() + int(timeout)
        while not response_path.exists():
            if time.monotonic() >= deadline:
                raise TimeoutError("IPC broker response timed out")
            time.sleep(0.05)
        descriptor = os.open(response_path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(descriptor, "rb") as stream:
            info = os.fstat(stream.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_size > 16384:
                raise ValueError("Invalid IPC response file")
            data = stream.read(16385)
            if len(data) > 16384:
                raise ValueError("IPC response exceeds 16 KiB")
        response = json.loads(data)
        if not isinstance(response, dict):
            raise ValueError("Invalid IPC response object")
        if response.get("id") != request_id or response.get("ok") is not True:
            raise ValueError("IPC broker rejected request or returned invalid correlation ID")
        output = response.get("output", "")
        if not isinstance(output, str):
            raise ValueError("Invalid IPC response output")
        print(output)
    finally:
        for path in (pending, request_path, response_path):
            path.unlink(missing_ok=True)
except (OSError, ValueError, TimeoutError) as error:
    print("squad-ask IPC: " + str(error), file=sys.stderr)
    sys.exit(1)
PYIPC
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
