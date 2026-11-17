# shellcheck shell=bash

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/squad-jq.sh"

# Summarises a codex --json, claude stream-json, agy stream-json (old runs only), or opencode
# JSONL log as tab-separated metrics on the first line, then one activity line
# per event: summarise_log <log> [engine]. Only the engine's own stream format
# is parsed; an unknown engine (older status files) tries all of them.
summarise_log() {
  local log="$1" engine="${2:-}" strict="${3:-0}"
  local root="${log%/.squad/workers/*}/"
  local codex=false claude=false agy=false opencode=false
  case "$engine" in
    codex) codex=true ;;
    claude|ccr) claude=true ;;
    agy) claude=true agy=true ;;
    opencode) opencode=true ;;
    grok) ;;
    *) codex=true claude=true agy=true opencode=true ;;
  esac
  if [[ ! -s "$log" ]] || ! squad_has_jq; then
    [[ "$strict" == 0 ]] || return 1
    printf '\t\t\t\t\t\t\n'
    return 0
  fi
  squad_jq -R -r -s --arg root "$root" --argjson codex "$codex" --argjson claude "$claude" --argjson agy "$agy" --argjson opencode "$opencode" '
    def short: tostring | split($root) | join("") | gsub("[\u0000-\u001f\u007f-\u009f]+"; " ") | .[0:160];
    def cmd: tostring | sub("^/bin/(ba|z)?sh -l?c "; "") | short;
    def clean_out:
      split("\n")
      | map(gsub("\r"; ""))
      | map(select(length > 0
          and (startswith("Command exited with code") | not)
          and (startswith("Command output:") | not)
          and (startswith("Reading additional input") | not)
          and (startswith("The tool\u0027s output was truncated") | not)))
      | first // "";
    def out_line:
      if . != null and . != "" then
        (clean_out | if length > 0 then "\t  ↳ " + short else "" end)
      else "" end;
    # Every usage object normalised to {in, cached, out}; in includes
    # cache reads and writes, so fresh input is in - cached.
    def norm: if has("input_tokens") then
        {in: ((.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_tokens // 0)),
         cached: (.cached_input_tokens // .cache_read_input_tokens // .cache_read_tokens // 0),
         out: (.output_tokens // 0)}
      else
        {in: ((.input // 0) + (.cache.read // 0) + (.cache.write // 0)),
         cached: (.cache.read // 0),
         out: ((.output // 0) + (.reasoning // 0))}
      end;

    [split("\n")[] | fromjson? | select(type == "object")] as $events
    | (if $codex then [$events[] | select(.type == "item.completed") | .item] else [] end) as $done
    | (if $codex then [$events[] | select(.type == "item.started") | .item] else [] end) as $started
    | ([$done[] | .id]) as $done_ids
    | (if $claude then [$events[] | select(.type == "assistant") | .message.content[]? | select(.type == "tool_use")] else [] end) as $tools
    | (if $claude then [$events[] | select(.type == "user") | .message.content[]? | select(.type == "tool_result" and .is_error == true)] else [] end) as $tool_errors
    | (if $claude then reduce $events[] as $e ({};
        if $e.type == "user" then
          reduce ($e.message.content[]? | select(.type == "tool_result")) as $tr (.;
            .[$tr.tool_use_id] = $tr
          )
        else . end
      ) else {} end) as $claude_results
    | (if $agy then [$events[] | select(.event == "step_update" and .step_update.step_type == "tool" and .step_update.state == "DONE") | .step_update] else [] end) as $agy_tools
    | (if $agy then [$events[] | select(.event == "step_update" and .step_update.step_type == "tool" and .step_update.state == "ACTIVE") | .step_update] else [] end) as $agy_active_tools
    | [$agy_tools[] | select((.tool_info.output // "") | test("exit code [1-9]|status FAILED|failed"; "i"))] as $agy_tool_errors
    | (if $opencode then [$events[] | select(.type == "tool_use") | .part] else [] end) as $oc_tools
    | ((if $codex then [$events[] | select(.type == "turn.completed") | .usage] else [] end)
       + (if $claude then [$events[] | select(.type == "result") | .usage | select(. != null)] else [] end)
       + (if $agy then [$events[] | select(.event == "result") | .result.usage | select(. != null)] else [] end)
       + (if $opencode then [$events[] | select(.type == "step_finish") | .part.tokens | select(. != null)] else [] end)) as $usage
    | [
        ([$done[] | select(.type == "command_execution" or .type == "mcp_tool_call")] | length) + ($tools | length) + ($agy_tools | length) + ($oc_tools | length),
        ([$done[] | select((.type == "command_execution" and .exit_code != 0) or (.type == "mcp_tool_call" and .status != "completed"))] | length) + ($tool_errors | length) + ($agy_tool_errors | length)
          + ([$oc_tools[] | select(.state.status == "error" or ((.state.metadata.metadata.exit // 0) != 0))] | length),
        ([$done[] | select(.type == "file_change") | .changes[]?] | length)
          + ([$tools[] | select(.name == "Edit" or .name == "Write")] | length)
          + ([$agy_tools[] | select(.tool_name == "write_to_file" or .tool_name == "replace_file_content" or .tool_name == "multi_replace_file_content" or .tool_name == "notebook_edit")] | length)
          + ([$oc_tools[] | select(.tool == "edit" or .tool == "write" or .tool == "patch" or .tool == "multiedit")] | length),
        ([$usage[] | norm | .in] | add // ""),
        ([$usage[] | norm | .cached] | add // ""),
        ([$usage[] | norm | .out] | add // ""),
        ((if $claude then [$events[] | select(.type == "result") | .num_turns] else [] end)
          + (if $agy then [$events[] | select(.event == "result") | .result.num_turns] else [] end) | last // "")
      ] | map(tostring) | join("\t"),
    ( $events[]
      | if $codex and .type == "item.completed" then .item
          | if .type == "command_execution" then
              (if .exit_code == 0 then "✓ " else "✗ " end) + (.command | cmd) + (if .exit_code == 0 then "" else "  (exit \(.exit_code))" end)
              + (.aggregated_output | out_line)
            elif .type == "mcp_tool_call" then
              (if .status == "completed" then "⚙ " else "✗ " end) + (("\(.server)/\(.tool)") | short)
            elif .type == "file_change" then "✎ " + ([.changes[]? | .path] | join(", ") | short)
            elif .type == "agent_message" then "» " + (.text | short)
            elif .type == "error" then "! " + (.message | short)
            else empty end
        elif $claude and .type == "assistant" then .message.content[]?
          | if .type == "tool_use" then
              (if .id != null and $claude_results[.id].is_error == true then "✗ " else "→ " end)
              + (.name | short) + " " + ((.input.file_path // .input.path // .input.pattern // .input.command // "") | short)
              + (if .id != null then ($claude_results[.id].content | out_line) else "" end)
            elif .type == "text" and (.text | length) > 0 then "» " + (.text | short)
            else empty end
        elif $claude and .type == "user" then .message.content[]?
          | if .type == "tool_result" and .is_error == true then
              "✗ tool error: " + (.content | short)
            else empty end
        elif $agy and .event == "step_update" and .step_update.step_type == "tool" and .step_update.state == "DONE" then
          .step_update |
          (if .tool_name == "read_file" then
            "✓ read " + (.tool_info.parameters.Path // "" | short)
           elif .tool_name == "run_command" then
            "✓ " + (.tool_info.parameters.CommandLine // "" | cmd)
           elif .tool_name == "write_to_file" or .tool_name == "replace_file_content" or .tool_name == "multi_replace_file_content" or .tool_name == "notebook_edit" then
            "✎ " + (.tool_info.parameters.Path // "" | short)
           else
            "⚙ " + (.tool_name | short)
           end)
          + (.tool_info.output | out_line)
        elif $agy and .event == "result" and (.result.response | type) == "string" then "» " + (.result.response | short)
        elif $agy and .event == "error" then "! " + (.error.message // .error | short)
        elif $opencode and .type == "tool_use" then .part
          | (if .state.status == "error" or ((.state.metadata.metadata.exit // 0) != 0) then "✗ " else "✓ " end) as $mark
          | (if .tool == "shell" then
              $mark + ((.state.input.command // "") | cmd)
              + (if ((.state.metadata.metadata.exit // 0) != 0) then "  (exit \(.state.metadata.metadata.exit))" else "" end)
            elif .tool == "read" then
              $mark + "read " + ((.state.input.path // "") | short)
            elif .tool == "edit" or .tool == "write" then
              (if .state.status == "error" then "✗ " else "✎ " end) + ((.state.input.filePath // .state.input.path // "") | short)
            else
              (if .state.status == "error" then "✗ " else "⚙ " end) + (.tool | short)
            end)
          + (if .state.status == "error" and .state.error != null then " " + (.state.error | short) else "" end)
          + (.state.output | out_line)
        elif $opencode and .type == "text" then "» " + (.part.text | short)
        else empty end ),
    ( [$started[] | select(.type == "command_execution") | select(.id as $id | $done_ids | index($id) | not)]
      | last | select(. != null) | "… running: " + (.command | cmd) ),
    ( [$agy_active_tools[] | select(.tool_name != null)]
      | last | select(. != null) | "… running: " + ((.tool_name | short) + " " + ((.tool_info.parameters.CommandLine // .tool_info.parameters.Path // "") | short)) )
  ' "$log" 2>/dev/null || { [[ "$strict" == 0 ]] && printf '\t\t\t\t\t\t\n'; }
}

