#!/usr/bin/env bash
# shellcheck disable=SC2154 # squad-worker.sh sets the globals adapters read.
# Antigravity CLI headless, stream-json (see lib/squad-engine.sh for the adapter protocol).

engine_agy_check_deps() {
  require_command agy
}

engine_agy_build_command() {
  engine_command=(agy -p "$prompt" --mode accept-edits --output-format stream-json)
  [[ "$yolo" != 1 ]] || engine_command+=(--dangerously-skip-permissions)
  [[ -z "$model_effort" ]] || engine_command+=(--effort "$model_effort")
  [[ -z "$model" ]] || engine_command+=(--model "$model")
  squad_engine_require_jq
}

# Native AGY streams end with {event:result,result:{status,response}} and may
# interleave plain diagnostics (ignored); accept only one valid terminal SUCCESS. Claude-
# shaped and plain-text output stay supported. Damaged or
# non-object JSON is never plaintext.
agy_extract_report() {
  local verdict
  verdict="$(jq -R -s -r '
    [split("\n")[] | select(test("\\S")) | sub("^\\s+";"") | sub("\\s+$";"") | . as $s | (try {v: fromjson} catch null) as $p
     | if $p == null then (if $s | test("^[{\\[]") then {bad: true} elif $s | test("^root agent idle; waiting for ") then {} else {text: true} end)
       elif ($p.v | type) == "object" then {o: $p.v} else {bad: true} end] as $l
    | [$l[] | .o // empty] as $objs
    | if any($l[]; .bad) then "damaged JSON in stream"
      elif any($objs[]; has("event")) then
        [$objs[] | select(.event == "result")] as $r
        | if any($objs[]; .event == "error" or has("error")) then "stream contains an error event"
          elif ($r | length) != 1 then "expected exactly one terminal result, found \($r | length)"
          elif ($objs[-1].event != "result") then "events follow the terminal result"
          elif ($r[0].result.status // "") != "SUCCESS" then "terminal status \($r[0].result.status // "missing")"
          elif (($r[0].result.response | type) != "string") or (($r[0].result.response | test("\\S")) | not) then "terminal SUCCESS has no response"
          else "ok:" + $r[0].result.response end
      elif any($objs[]; .type == "result") then
        ([$objs[] | select(.type == "result") | .result // empty] | join("\n")) as $t
        | if $t == "" then "result has no text" else "ok:" + $t end
      elif ($objs | length) > 0 then "no result event in stream"
      elif any($l[]; .text) then "plain:" else "no report in stream" end' "$absolute_log" 2>/dev/null || echo 'unparseable stream')"
  case "$verdict" in
    ok:*) printf '%s\n' "${verdict#ok:}" >"$absolute_report" ;;
    plain:) cp "$absolute_log" "$absolute_report" ;;
    *) printf '\nsquad-worker: AGY stream rejected: %s\n' "$verdict" >>"$absolute_log" ;;
  esac
}

engine_agy_run_and_extract_report() {
  "${engine_command[@]}" </dev/null >"$absolute_log" 2>&1 || return $?
  agy_extract_report
}

engine_agy_reported_models() {
  squad_worker_stream_models "$1"
}
