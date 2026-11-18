#!/usr/bin/env bash
# Claude Code hook for the Telegram remote: queues the manager's last reply
# (Stop) or a "waiting for you" message (Notification) in the outbox spool.
# Usage: squad-telegram-hook.sh <stop|notification> <label>   (hook JSON on stdin)
# Never blocks or alters the session: always exits 0 and prints nothing.

tg_hook_main() {
  local event="${1:-}" label="${2:-}" input transcript text
  # shellcheck source=squad-telegram-spool.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/squad-telegram-spool.sh" || return 0
  tg_enabled || return 0
  [[ -n "$label" ]] || return 0
  input="$(cat)"
  case "$event" in
    stop)
      transcript="$(printf '%s' "$input" | squad_jq -r '.transcript_path // empty')"
      [[ -n "$transcript" && -f "$transcript" ]] || return 0
      # The turn's final assistant entry (main thread only, after the last real
      # user prompt). If it has no text, send nothing rather than an older reply.
      text="$(tail -n 40 "$transcript" | squad_jq -Rrs '
        [split("\n")[] | fromjson? | select(type == "object" and .isSidechain != true)] as $e
        | ([range(0; $e | length) as $i
            | select($e[$i].type == "user"
              and ($e[$i].message.content
                | type == "string" or (type == "array" and any(.[]?; type == "object" and .type == "text"))))
            | $i] | last // -1) as $u
        | [$e[($u + 1):][] | select(.type == "assistant")] | last
        | if . == null then empty
          else (.message.content | if type == "string" then .
              else [.[]? | select(type == "object" and .type == "text") | .text] | join("\n") end)
          end')"
      [[ -n "$text" ]] && tg_spool_put "$label" reply "$text"
      ;;
    notification)
      text="$(printf '%s' "$input" | squad_jq -r '.message // empty')"
      [[ -n "$text" ]] && tg_spool_put "$label" waiting "$text"
      ;;
  esac
  return 0
}

tg_hook_main "$@" >/dev/null 2>&1 || true
exit 0
