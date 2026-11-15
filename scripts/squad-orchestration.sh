#!/usr/bin/env bash
set -euo pipefail

orig_args=("$@")

source_file="${BASH_SOURCE[0]:-$0}"
while [[ -L "$source_file" ]]; do
  source_dir="$(cd -P "$(dirname "$source_file")" && pwd)"
  link_target="$(readlink "$source_file")"
  if [[ "$link_target" == /* ]]; then
    source_file="$link_target"
  else
    source_file="$source_dir/$link_target"
  fi
done
script_dir="$(cd -P "$(dirname "$source_file")" && pwd)"
script_path="$script_dir/$(basename "$source_file")"

saved_tty=""
reload_on_hup() {
  [[ -z "$saved_tty" ]] || stty "$saved_tty" 2>/dev/null || true
  if [[ -t 1 ]]; then
    printf '\033[?2026l\033[?25h\033[0m\033[H\033[2J'
  fi
  export SQUAD_ORCHESTRATION_REEXEC=1
  exec bash "$script_path" ${orig_args[@]+"${orig_args[@]}"}
}

export LC_ALL="${LC_ALL:-en_US.UTF-8}"

# Environment variables:
#   SQUAD_ORCHESTRATION_LIVE=1    Keep live loop running even when stdout is not a TTY (for tests)

usage() {
  cat <<'EOF'
Usage: squad-orchestration.sh [--once] [--since EPOCH] [--layout LAYOUT] [--root ID] [--flow-filter MODE] [WORKERS_DIR]

Live terminal orchestration view showing manager and worker flow.

  --once               Render one frame without escape codes and exit
  --since EPOCH        Show runs started at or after EPOCH (default: $SQUAD_DEVKIT_SESSION_START or 0)
  --layout LAYOUT      Layout to render: graph, pipeline, or tree (default: $SQUAD_ORCHESTRATION_LAYOUT or graph)
  --root ID            Start zoomed into sub-manager ID (Esc disabled)
  --flow-filter MODE   Flow filter: all, questions, or failures (default: $SQUAD_ORCHESTRATION_FLOW_FILTER or all)
  -h, --help           Show this help

Interactive keys:
  g / p / t / Tab      Switch layout (graph, pipeline, tree)
  f                    Cycle Flow filter (all -> questions -> failures)
  e                    Toggle expanding '+N earlier' worker rows
  1-9 / z / Esc        Zoom into sub-manager / cycle / unzoom
  q                    Quit

Environment:
  SQUAD_ORCHESTRATION_LIVE=1  Keep live loop running even when stdout is not a TTY (for tests)
EOF
}

once=0
since="${SQUAD_DEVKIT_SESSION_START:-0}"
layout="${SQUAD_ORCHESTRATION_LAYOUT:-graph}"
flow_filter="${SQUAD_ORCHESTRATION_FLOW_FILTER:-all}"
expand_earlier=0
[[ "${SQUAD_ORCHESTRATION_EXPAND:-0}" == "1" ]] && expand_earlier=1
locked_root=""
zoom_target=""
workers_dir=""

while (( $# > 0 )); do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --once)
      once=1
      ;;
    --since)
      if (( $# < 2 )); then
        echo "Option --since requires an argument" >&2
        exit 2
      fi
      since="$2"
      shift
      ;;
    --since=*)
      since="${1#*=}"
      ;;
    --layout)
      if (( $# < 2 )); then
        echo "Option --layout requires an argument" >&2
        exit 2
      fi
      layout="$2"
      shift
      ;;
    --layout=*)
      layout="${1#*=}"
      ;;
    --root)
      if (( $# < 2 )) || [[ -z "$2" ]]; then
        echo "Option --root requires an argument" >&2
        exit 2
      fi
      locked_root="$2"
      zoom_target="$2"
      shift
      ;;
    --root=*)
      locked_root="${1#*=}"
      if [[ -z "$locked_root" ]]; then
        echo "Option --root requires an argument" >&2
        exit 2
      fi
      zoom_target="$locked_root"
      ;;
    --flow-filter)
      if (( $# < 2 )); then
        echo "Option --flow-filter requires an argument" >&2
        exit 2
      fi
      flow_filter="$2"
      shift
      ;;
    --flow-filter=*)
      flow_filter="${1#*=}"
      ;;
    -*)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
    *)
      if [[ -z "$workers_dir" ]]; then
        workers_dir="$1"
      else
        echo "Unexpected argument: $1" >&2
        exit 2
      fi
      ;;
  esac
  shift
done

if (( once == 0 )) && { [[ -t 1 ]] || [[ "${SQUAD_ORCHESTRATION_LIVE:-0}" == 1 ]]; }; then
  trap reload_on_hup HUP
fi

case "$layout" in
  graph|pipeline|tree) ;;
  *)
    echo "Invalid layout: $layout (expected tree, graph, or pipeline)" >&2
    exit 2
    ;;
esac

case "$flow_filter" in
  all|questions|failures) ;;
  *)
    echo "Invalid flow filter: $flow_filter (expected all, questions, or failures)" >&2
    exit 2
    ;;
esac

if [[ -z "$workers_dir" ]]; then
  workers_dir=".squad/workers"
fi

# Determine colour and animation flags once.
use_color=0
if [[ "${SQUAD_ORCHESTRATION_FORCE_COLOR:-}" == "1" ]]; then
  use_color=1
elif [[ -z "${NO_COLOR:-}" ]] && [[ -t 1 ]] && (( once == 0 )); then
  use_color=1
fi

use_anim=0
if (( use_color == 1 )) && [[ "${SQUAD_ORCHESTRATION_ANIMATE:-1}" != "0" ]]; then
  use_anim=1
fi

# Define colour tokens once (256-colour when tput colors >= 256, else 8-colour; empty when disabled).
bold="" dim="" reverse="" reset=""
c_manager="" c_running="" c_running_bright="" c_completed="" c_failed=""
c_asking="" c_stale="" c_stopped="" c_brief="" c_answer="" c_question="" c_done=""

if (( use_color == 1 )); then
  num_colors=8
  tc="$(tput colors 2>/dev/null </dev/tty || tput colors 2>/dev/null || echo 8)"
  if [[ "$tc" =~ ^[0-9]+$ ]] && (( tc >= 256 )); then
    num_colors=256
  elif [[ "${TERM:-}" == *256color* ]]; then
    num_colors=256
  fi
  bold=$'\033[1m'
  dim=$'\033[2m'
  reverse=$'\033[7m'
  reset=$'\033[0m'
  if (( num_colors >= 256 )); then
    c_manager=$'\033[1;38;5;171m'
    c_running=$'\033[38;5;220m'
    c_running_bright=$'\033[1;38;5;226m'
    c_completed=$'\033[38;5;78m'
    c_failed=$'\033[38;5;203m'
    c_asking=$'\033[38;5;81m'
    c_stale=$'\033[38;5;208m'
    c_stopped=$'\033[38;5;245m'
    c_brief=$'\033[38;5;75m'
    c_answer=$'\033[38;5;171m'
    c_question=$'\033[38;5;81m'
    c_done=$'\033[38;5;78m'
  else
    c_manager=$'\033[1;35m'
    c_running=$'\033[33m'
    c_running_bright=$'\033[1;33m'
    c_completed=$'\033[32m'
    c_failed=$'\033[31m'
    c_asking=$'\033[36m'
    c_stale=$'\033[1;31m'
    c_stopped=$'\033[90m'
    c_brief=$'\033[34m'
    c_answer=$'\033[35m'
    c_question=$'\033[36m'
    c_done=$'\033[32m'
  fi
fi

SPINNER_GLYPHS=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)

# Pre-build padding buffers to avoid per-cell subshells.
printf -v SPACES_PAD '%*s' 300 ''
DASHES_PAD="${SPACES_PAD// /─}"
DOUBLE_DASHES_PAD="${SPACES_PAD// /═}"

ensure_pad_len() {
  local need="$1"
  while (( ${#SPACES_PAD} < need )); do
    SPACES_PAD="${SPACES_PAD}${SPACES_PAD}"
    DASHES_PAD="${DASHES_PAD}${DASHES_PAD}"
    DOUBLE_DASHES_PAD="${DOUBLE_DASHES_PAD}${DOUBLE_DASHES_PAD}"
  done
}

terminal_columns() {
  local columns="${COLUMNS:-}"
  if [[ -z "$columns" ]]; then
    local sz=""
    if [[ -t 1 ]] || (( once == 0 )); then
      if [[ -t 0 ]]; then
        sz="$(stty size 2>/dev/null || true)"
      fi
      if [[ -z "$sz" && -t 1 ]]; then
        exec 3>&1
        sz="$(stty size <&3 2>/dev/null || true)"
        exec 3>&-
      fi
      if [[ -z "$sz" ]]; then
        sz="$(stty size 2>/dev/null </dev/tty || true)"
      fi
    fi
    if [[ "$sz" =~ ^[0-9]+[[:space:]]+([0-9]+)$ ]]; then
      columns="${BASH_REMATCH[1]}"
    elif [[ -t 1 ]] || (( once == 0 )); then
      columns="$(tput cols 2>/dev/null </dev/tty || tput cols 2>/dev/null || echo 80)"
    else
      columns="$(tput cols 2>/dev/null || echo 80)"
    fi
    [[ "$columns" =~ ^[0-9]+$ ]] && (( columns > 20 )) || columns=80
  fi
  [[ "$columns" =~ ^[0-9]+$ ]] && (( columns > 0 )) || columns=80
  REPLY="$columns"
}

terminal_lines() {
  local lines="${LINES:-}"
  if [[ -z "$lines" ]]; then
    local sz=""
    if [[ -t 1 ]] || (( once == 0 )); then
      if [[ -t 0 ]]; then
        sz="$(stty size 2>/dev/null || true)"
      fi
      if [[ -z "$sz" && -t 1 ]]; then
        exec 3>&1
        sz="$(stty size <&3 2>/dev/null || true)"
        exec 3>&-
      fi
      if [[ -z "$sz" ]]; then
        sz="$(stty size 2>/dev/null </dev/tty || true)"
      fi
    fi
    if [[ "$sz" =~ ^([0-9]+)[[:space:]]+[0-9]+$ ]]; then
      lines="${BASH_REMATCH[1]}"
    elif [[ -t 1 && "${TERM:-dumb}" != "dumb" ]]; then
      lines="$(tput lines 2>/dev/null </dev/tty || tput lines 2>/dev/null || echo 40)"
    else
      lines=40
    fi
    [[ "$lines" =~ ^[0-9]+$ ]] && (( lines > 0 )) || lines=40
  fi
  [[ "$lines" =~ ^[0-9]+$ ]] && (( lines > 0 )) || lines=40
  REPLY="$lines"
}

pad_str() {
  local s="$1" w="$2"
  local l="${#s}"
  if (( l < w )); then
    REPLY="${s}${SPACES_PAD:0:$(( w - l ))}"
  else
    REPLY="$s"
  fi
}

trunc_str() {
  local s="$1" max_w="$2"
  local l="${#s}"
  if (( l > max_w )); then
    if (( max_w > 1 )); then
      REPLY="${s:0:$(( max_w - 1 ))}…"
    elif (( max_w == 1 )); then
      REPLY="…"
    else
      REPLY=""
    fi
  else
    REPLY="$s"
  fi
}

center_str() {
  local s="$1" w="$2"
  local l="${#s}"
  if (( l >= w )); then
    REPLY="${s:0:$w}"
  else
    local lp=$(( (w - l) / 2 ))
    local rp=$(( w - l - lp ))
    REPLY="${SPACES_PAD:0:$lp}${s}${SPACES_PAD:0:$rp}"
  fi
}

box_cell() {
  local text="$1" inner_w="$2" content_w="$3"
  trunc_str "$text" "$content_w"
  pad_str "$REPLY" "$content_w"
  if (( inner_w > content_w + 1 )); then
    REPLY=" ${REPLY} "
  else
    REPLY=" ${REPLY}"
  fi
}

fmt_human_count() {
  local value="${1:-0}"
  if (( value >= 1000000 )); then
    REPLY="$(( value / 1000000 )).$(( value % 1000000 / 100000 ))M"
  elif (( value >= 1000 )); then
    REPLY="$(( value / 1000 ))k"
  else
    REPLY="$value"
  fi
}

fmt_elapsed() {
  local seconds="$1"
  (( seconds >= 0 )) || seconds=0
  if (( seconds < 60 )); then
    REPLY="${seconds}s"
  elif (( seconds < 3600 )); then
    printf -v REPLY '%dm%02ds' $((seconds / 60)) $((seconds % 60))
  else
    printf -v REPLY '%dh%02dm' $((seconds / 3600)) $((seconds % 3600 / 60))
  fi
}

format_time() {
  local epoch="${1:-0}"
  if [[ -z "$epoch" || "$epoch" -le 0 ]]; then
    printf '00:00'
    return
  fi
  date -r "$epoch" +%H:%M 2>/dev/null || date -d "@$epoch" +%H:%M 2>/dev/null || printf '00:00'
}

rfc3339_to_hhmm() {
  local ts="$1"
  if [[ "$ts" =~ T([0-9]{2}:[0-9]{2}) ]]; then
    REPLY="${BASH_REMATCH[1]}"
    return
  fi
  REPLY="00:00"
}

rfc3339_to_epoch() {
  local ts="$1" ep=""
  if [[ "$ts" =~ ^[0-9]+$ ]]; then
    REPLY="$ts"
    return
  fi
  ep="$(date -d "$ts" +%s 2>/dev/null || true)"
  if [[ -z "$ep" ]]; then
    if [[ "$ts" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})Z$ ]]; then
      ep="$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$ts" "+%s" 2>/dev/null || true)"
    elif [[ "$ts" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})([+-][0-9]{2}):([0-9]{2})$ ]]; then
      local no_colon="${ts%:*}${ts##*:}"
      ep="$(date -j -f "%Y-%m-%dT%H:%M:%S%z" "$no_colon" "+%s" 2>/dev/null || true)"
    fi
  fi
  REPLY="${ep:-0}"
}

fmt_eng_mod() {
  local eng="$1" mod="$2"
  if [[ -n "$eng" && -n "$mod" ]]; then
    REPLY="${eng} · ${mod}"
  elif [[ -n "$eng" ]]; then
    REPLY="$eng"
  elif [[ -n "$mod" ]]; then
    REPLY="$mod"
  else
    REPLY="-"
  fi
}

fmt_short_model() {
  local model="${1:-}" max_w="${2:-14}"
  local m="${model//[[:space:]]/}"
  if [[ -z "$m" ]]; then
    m="default"
  else
    m="${model##*/}"
    if [[ -z "$m" ]]; then
      m="default"
    elif (( ${#m} > max_w )); then
      if [[ "$m" == gemini-* ]]; then
        m="${m#gemini-}"
      elif [[ "$m" == claude-* ]]; then
        m="${m#claude-}"
      elif [[ "$m" == gpt-* ]]; then
        m="${m#gpt-}"
      fi
    fi
  fi
  trunc_str "$m" "$max_w"
}

# Format model + optional tier (fast/balanced/strong, abbreviated only if width forces it) into REPLY.
fmt_model_tier() {
  local raw_model="$1" tier="$2" max_w="$3"
  if [[ -z "$tier" ]]; then
    fmt_short_model "$raw_model" "$max_w"
    return
  fi
  local m="${raw_model//[[:space:]]/}"
  if [[ -z "$m" ]]; then
    m="default"
  else
    m="${raw_model##*/}"
    [[ -n "$m" ]] || m="default"
  fi
  local full="${m} · ${tier}"
  if (( ${#full} <= max_w )); then
    REPLY="$full"
    return
  fi
  if (( max_w >= ${#tier} + 8 )); then
    fmt_short_model "$raw_model" $(( max_w - 3 - ${#tier} ))
    if (( ${#REPLY} + 3 + ${#tier} <= max_w )); then
      REPLY="${REPLY} · ${tier}"
      return
    fi
  fi
  local abbr="$tier"
  case "$tier" in
    fast)     abbr="fst" ;;
    balanced) abbr="bal" ;;
    strong)   abbr="str" ;;
  esac
  if (( max_w >= ${#abbr} + 5 )); then
    fmt_short_model "$raw_model" $(( max_w - 3 - ${#abbr} ))
    if (( ${#REPLY} + 3 + ${#abbr} <= max_w )); then
      REPLY="${REPLY} · ${abbr}"
      return
    fi
  fi
  fmt_short_model "$raw_model" $(( max_w - 1 - ${#abbr} ))
  trunc_str "${REPLY} ${abbr}" "$max_w"
}

WRAP_LINES=()
wrap_text() {
  local text="$1" width="$2" max_lines="${3:-4}"
  WRAP_LINES=()
  if (( width <= 0 )); then
    WRAP_LINES[0]=""
    return
  fi
  text="${text//$'\r'/}"
  text="${text//$'\n'/ }"
  text="${text//$'\t'/ }"
  if (( ${#text} <= width )); then
    WRAP_LINES[0]="$text"
    return
  fi
  while (( ${#text} > width )); do
    if (( max_lines > 0 && ${#WRAP_LINES[@]} + 1 >= max_lines )); then
      trunc_str "$text" "$width"
      WRAP_LINES[${#WRAP_LINES[@]}]="$REPLY"
      return
    fi
    local chunk="${text:0:$width}"
    if [[ "${text:$width:1}" != " " && "$chunk" == *" "* ]]; then
      chunk="${chunk% *}"
    fi
    [[ -n "$chunk" ]] || chunk="${text:0:$width}"
    WRAP_LINES[${#WRAP_LINES[@]}]="$chunk"
    text="${text:${#chunk}}"
    while [[ "$text" == " "* ]]; do text="${text# }"; done
  done
  [[ -z "$text" ]] || WRAP_LINES[${#WRAP_LINES[@]}]="$text"
}

# Shared worker state-to-glyph/text/colour resolver for graph, tree, and pipeline views.
# Sets ST_PLAIN, ST_DISP, ST_COLOR, ST_IS_SPIN.
resolve_worker_state() {
  local w="$1"
  local eff_state="${2:-}"
  if [[ -z "$eff_state" ]] && (( w >= 0 )); then
    eff_state="${W_STATE[$w]}"
  fi
  local max_w="${3:-999}"
  local glyph="" label="" keep_glyph=0
  ST_COLOR=""
  ST_IS_SPIN=0

  if [[ "$eff_state" == "pending" ]]; then
    glyph="○"
    label="pending"
    ST_COLOR="$dim"
  elif [[ "$eff_state" == "running" ]]; then
    if (( W_ASKING[w] == 1 )); then
      glyph="?"
      keep_glyph=1
      if [[ -n "${W_ASK_AGE[$w]}" ]]; then
        fmt_elapsed "${W_ASK_AGE[$w]}"
        label="waiting ${REPLY}"
      else
        label="waiting"
      fi
      [[ -n "$c_asking" ]] && ST_COLOR="@@ASK_CLR@@"
    elif (( W_IS_STALE[w] == 1 )); then
      glyph="⚠"
      fmt_elapsed "${W_OUT_AGE[$w]}"
      label="stale ${REPLY}"
      ST_COLOR="$c_stale"
    else
      glyph="⠋"
      label="running"
      ST_COLOR="$c_running"
      ST_IS_SPIN=1
    fi
  else
    case "$eff_state" in
      completed)
        if [[ "${W_VERIFY[$w]}" == "fail" || "${W_VERIFY[$w]}" == "timeout" ]]; then
          glyph="✗"
          label="verify FAIL"
          ST_COLOR="$c_failed"
        else
          glyph="✓"
          label="completed"
          ST_COLOR="$c_completed"
        fi
        ;;
      failed)
        glyph="✗"
        label="failed"
        ST_COLOR="$c_failed"
        ;;
      stopped)
        glyph="⏸"
        label="stopped"
        ST_COLOR="$c_stopped"
        ;;
      lost)
        glyph="?"
        label="lost"
        ST_COLOR="$c_failed"
        ;;
      *)
        label="$eff_state"
        ;;
    esac
  fi

  if [[ -n "$glyph" ]]; then
    if (( keep_glyph == 0 && ${#glyph} + 1 + ${#label} > max_w && ${#label} <= max_w )); then
      ST_PLAIN="$label"
    else
      ST_PLAIN="${glyph} ${label}"
    fi
  else
    ST_PLAIN="$label"
  fi
  if (( ST_IS_SPIN == 1 )); then
    ST_DISP="${ST_PLAIN/⠋/@@SPIN@@}"
  else
    ST_DISP="$ST_PLAIN"
  fi
}

resolve_workspace_root() {
  local dir="${1%/}"
  if [[ "$dir" == /* ]]; then
    if [[ "$dir" == *"/.squad/workers" ]]; then
      printf '%s' "${dir%/.squad/workers}"
      return
    elif [[ "$dir" == *"/.squad" ]]; then
      printf '%s' "${dir%/.squad}"
      return
    elif [[ "$dir" == *"/.squad/"* ]]; then
      printf '%s' "${dir%/.squad/*}"
      return
    else
      printf '%s' "${dir%/*}"
      return
    fi
  fi
  local abs_dir
  if abs_dir="$(cd "$dir" 2>/dev/null && pwd)"; then
    if [[ "$abs_dir" == *"/.squad/workers" ]]; then
      printf '%s' "${abs_dir%/.squad/workers}"
      return
    elif [[ "$abs_dir" == *"/.squad" ]]; then
      printf '%s' "${abs_dir%/.squad}"
      return
    elif [[ "$abs_dir" == *"/.squad/"* ]]; then
      printf '%s' "${abs_dir%/.squad/*}"
      return
    fi
  fi
  if [[ "$dir" == *"/.squad/workers" ]]; then
    printf '%s' "${dir%/.squad/workers}"
  elif [[ "$dir" == *"/.squad" ]]; then
    printf '%s' "${dir%/.squad}"
  elif [[ "$dir" == *"/.squad/"* ]]; then
    printf '%s' "${dir%/.squad/*}"
  elif [[ "$dir" == ".squad"* ]]; then
    pwd
  else
    dirname "$dir"
  fi
}

read_history() {
  local ws_root="$1" since_epoch="$2"
  if [[ -n "${SQUAD_ORCHESTRATION_HISTORY_CMD:-}" ]]; then
    (cd "$ws_root" && eval "$SQUAD_ORCHESTRATION_HISTORY_CMD") 2>/dev/null || true
  elif command -v squad >/dev/null 2>&1; then
    (cd "$ws_root" && squad history --since "$since_epoch") 2>/dev/null || true
  fi
}

classify_msg() {
  local content="$1"
  if [[ "$content" == QUESTION* ]]; then
    REPLY="QUESTION"
  elif [[ "$content" == ANSWER* ]]; then
    REPLY="ANSWER"
  elif [[ "$content" == *" completed task "* ]]; then
    REPLY="done"
  elif [[ "$content" == *" failed"* ]]; then
    REPLY="failed"
  else
    REPLY="brief"
  fi
}

clean_msg_preview() {
  local type="$1" content="$2"
  case "$type" in
    QUESTION)
      if [[ "$content" =~ ^QUESTION([[:space:]]+from[^:]*:)?[[:space:]]*:?[[:space:]]*(.*)$ ]]; then
        REPLY="${BASH_REMATCH[2]}"
      else
        REPLY="$content"
      fi
      ;;
    ANSWER)
      if [[ "$content" =~ ^ANSWER([[:space:]]+from[^:]*:)?[[:space:]]*:?[[:space:]]*(.*)$ ]]; then
        REPLY="${BASH_REMATCH[2]}"
      else
        REPLY="$content"
      fi
      ;;
    done)
      if [[ "$content" =~ (completed task .*) ]]; then
        REPLY="${BASH_REMATCH[1]}"
      else
        REPLY="$content"
      fi
      ;;
    *)
      REPLY="$content"
      ;;
  esac
}

resolve_plan_file() {
  local raw_p="${1:-}"
  REPLY=""
  [[ -n "$raw_p" && "$raw_p" != "(no plan)" && "$raw_p" != "none" ]] || return 0
  case "$raw_p" in
    *$'\n'*|*$'\r'*) return 0 ;;
  esac
  local cand="$raw_p"
  if [[ "$cand" != /* ]]; then
    cand="${WS_ROOT}/${cand}"
  fi
  if [[ -f "$cand" && -r "$cand" ]]; then
    local p_dir
    if p_dir="$(cd "$(dirname "$cand")" 2>/dev/null && pwd -P)"; then
      REPLY="${p_dir}/$(basename "$cand")"
    else
      REPLY="$cand"
    fi
  fi
  return 0
}

# Prints tab-separated lines: id<TAB>engine<TAB>deps from ## Tasks of a plan file.
# Only matches '- <id> (<meta>): ...' lines; ignores wave headings and prose.
parse_plan_tasks() {
  local plan_file="$1"
  [[ -f "$plan_file" && -r "$plan_file" ]] || return 0
  awk '
    BEGIN { in_tasks = 0 }
    { gsub(/\r/, "") }
    /^##[[:space:]]+/ {
      h = tolower($0)
      sub(/^##[[:space:]]+/, "", h)
      sub(/[[:space:]:]+$/, "", h)
      in_tasks = (h == "tasks")
      next
    }
    !in_tasks { next }
    /^[[:space:]]*[-*][[:space:]]+/ {
      line = $0
      sub(/^[[:space:]]*[-*][[:space:]]+/, "", line)
      if (match(line, /^[A-Za-z0-9._-]+[[:space:]]*\(/)) {
        tid = substr(line, 1, RLENGTH - 1)
        sub(/[[:space:]]+$/, "", tid)
        rest = substr(line, RLENGTH + 1)
        close_p = index(rest, ")")
        if (close_p == 0) next
        meta = substr(rest, 1, close_p - 1)
        after_p = substr(rest, close_p + 1)
        if (after_p !~ /^[[:space:]]*:/) next
        eng = meta
        sub(/[,;].*$/, "", eng)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", eng)
        if (eng !~ /^[A-Za-z0-9_-]+$/) eng = ""
        deps = ""
        low_after = tolower(after_p)
        dp = index(low_after, "depends on:")
        if (dp > 0) {
          dstr = substr(after_p, dp + 11)
          gsub(/\([^)]*\)/, "", dstr)
          sub(/\.[[:space:]]+.*$/, "", dstr)
          sub(/;.*$/, "", dstr)
          sub(/\.[[:space:]]*$/, "", dstr)
          n = split(dstr, arr, ",")
          for (i = 1; i <= n; i++) {
            d = arr[i]
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", d)
            sub(/\.$/, "", d)
            low_d = tolower(d)
            if (low_d == "" || low_d == "none" || low_d == "n/a" || low_d == "-") continue
            if (d ~ /^[A-Za-z0-9._-]+$/) {
              deps = (deps == "" ? d : deps ", " d)
            }
          }
        }
        printf "%s\t%s\t%s\n", tid, eng, deps
      }
    }
  ' "$plan_file" 2>/dev/null || true
}

WS_ROOT="$(resolve_workspace_root "$workers_dir")"
WS_NAME="${WS_ROOT##*/}"
[[ -n "$WS_NAME" ]] || WS_NAME="$(basename "$WS_ROOT")"
SINCE_HHMM="$(format_time "$since")"

# Cached data arrays populated by load_data
W_NAME=()
W_STARTED=()
W_FINISHED=()
W_PLAN_NAME=()
W_PLAN_PATH=()
W_STATE=()
W_ENGINE=()
W_MODEL=()
W_TOK=()
W_ELAPSED=()
W_WORKTREE=()
W_ROUND=()
W_ROLE=()
W_PARENT=()
W_DEPTH=()
W_BRANCH_TOK=()
W_KIDS_TOTAL=()
W_KIDS_DONE=()
W_KIDS_RUNNING=()
W_SM_INDEX=()
W_LAST_TYPE=()
W_LAST_TS=()
W_ASKING=()
W_ASK_H_IDX=()
W_EDGE_ARROW=()
W_EDGE_TEXT=()
W_EDGE_TYPE=()
W_MSG_RECENT=()
W_STATUS_FILE=()
W_LOG=()
W_MODEL_TIER=()
W_VERIFY=()
W_SCOPE_VIOLATION=()
W_MERGED=()
W_DISCARDED=()
W_MERGE_STATE=()
W_ACTIVITY=()
W_OUT_AGE=()
W_IS_STALE=()
W_ASK_TS=()
W_ASK_AGE=()
W_ROUND_REASON=()
W_DEPS=()
SM_LIST=()

P_NAME=()
P_FILE=()
P_ACTIVE=()
P_LAST_TS=()
P_DONE_CNT=()
P_FAIL_CNT=()
P_TOK=()
P_TASK_TOTAL=()
P_TASK_DONE=()
P_ORDER=()

PT_PLAN=()
PT_ID=()
PT_ENGINE=()
PT_DEPS=()

H_TS=()
H_FROM=()
H_TO=()
H_TYPE=()
H_BODY=()

DATA_NOW=0
MANAGER_ID="manager"
TOTAL_WORKERS=0
RUNNING_COUNT=0
COMPLETED_COUNT=0
FAILED_COUNT=0
STOPPED_COUNT=0
LOST_COUNT=0
VERIFY_FAIL_COUNT=0
TOTAL_TOKENS=0

FRAME_TPL=("" "" "" "")

load_data() {
  W_NAME=()
  W_STARTED=()
  W_FINISHED=()
  W_PLAN_NAME=()
  W_PLAN_PATH=()
  W_STATE=()
  W_ENGINE=()
  W_MODEL=()
  W_TOK=()
  W_ELAPSED=()
  W_WORKTREE=()
  W_ROUND=()
  W_ROLE=()
  W_PARENT=()
  W_DEPTH=()
  W_BRANCH_TOK=()
  W_KIDS_TOTAL=()
  W_KIDS_DONE=()
  W_KIDS_RUNNING=()
  W_SM_INDEX=()
  W_LAST_TYPE=()
  W_LAST_TS=()
  W_ASKING=()
  W_ASK_H_IDX=()
  W_EDGE_ARROW=()
  W_EDGE_TEXT=()
  W_EDGE_TYPE=()
  W_MSG_RECENT=()
  W_STATUS_FILE=()
  W_LOG=()
  W_MODEL_TIER=()
  W_VERIFY=()
  W_SCOPE_VIOLATION=()
  W_MERGED=()
  W_DISCARDED=()
  W_MERGE_STATE=()
  W_ACTIVITY=()
  W_OUT_AGE=()
  W_IS_STALE=()
  W_ASK_TS=()
  W_ASK_AGE=()
  W_ROUND_REASON=()
  W_DEPS=()
  SM_LIST=()

  P_NAME=()
  P_FILE=()
  P_ACTIVE=()
  P_LAST_TS=()
  P_DONE_CNT=()
  P_FAIL_CNT=()
  P_TOK=()
  P_TASK_TOTAL=()
  P_TASK_DONE=()
  P_ORDER=()

  PT_PLAN=()
  PT_ID=()
  PT_ENGINE=()
  PT_DEPS=()

  H_TS=()
  H_FROM=()
  H_TO=()
  H_TYPE=()
  H_BODY=()

  DATA_NOW="${SQUAD_ORCHESTRATION_NOW:-$(date +%s)}"
  TOTAL_WORKERS=0
  RUNNING_COUNT=0
  COMPLETED_COUNT=0
  FAILED_COUNT=0
  STOPPED_COUNT=0
  LOST_COUNT=0
  VERIFY_FAIL_COUNT=0
  TOTAL_TOKENS=0

  local stale_secs="${SQUAD_ORCHESTRATION_STALE_SECS:-120}"
  [[ "$stale_secs" =~ ^[0-9]+$ ]] || stale_secs=120

  local raw_pids=()
  local prev_started=() prev_state=() prev_verify=() prev_scope=()
  local status_file line k v
  if [[ -d "$workers_dir" ]]; then
    for status_file in "$workers_dir"/*.status; do
      [[ -e "$status_file" ]] || continue
      local f_worker="" f_started="" f_finished="" f_plan="" f_state="" f_pid=""
      local f_engine="" f_model="" f_tok_in="" f_tok_out="" f_tokens="" f_worktree=""
      local f_role="" f_parent="" f_depth=""
      local f_tier="" f_verify="" f_scope="" f_merged="" f_discarded="" f_log=""
      while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == *=* ]] || continue
        k="${line%%=*}"
        v="${line#*=}"
        case "$k" in
          worker)          f_worker="$v" ;;
          started)         f_started="$v" ;;
          finished)        f_finished="$v" ;;
          plan)            f_plan="$v" ;;
          state)           f_state="$v" ;;
          pid)             f_pid="$v" ;;
          engine)          f_engine="$v" ;;
          model)           f_model="$v" ;;
          model_tier)      f_tier="$v" ;;
          verify)          f_verify="$v" ;;
          scope_violation) f_scope="$v" ;;
          merged)          f_merged="$v" ;;
          discarded)       f_discarded="$v" ;;
          log)             f_log="$v" ;;
          tokens_in)       f_tok_in="$v" ;;
          tokens_out)      f_tok_out="$v" ;;
          tokens)          f_tokens="$v" ;;
          worktree)        f_worktree="$v" ;;
          role)            f_role="$v" ;;
          parent)          f_parent="$v" ;;
          depth)           f_depth="$v" ;;
        esac
      done < "$status_file"

      [[ -n "$f_started" && "$f_started" =~ ^[0-9]+$ ]] || continue
      (( f_started >= since )) || continue
      [[ -n "$f_worker" ]] || continue

      local found_idx=-1
      local idx=0 w_cnt="${#W_NAME[@]}"
      while (( idx < w_cnt )); do
        if [[ "${W_NAME[$idx]}" == "$f_worker" ]]; then
          found_idx="$idx"
          break
        fi
        idx=$(( idx + 1 ))
      done

      local clean_in="${f_tok_in//[^0-9]/}"
      local clean_out="${f_tok_out//[^0-9]/}"
      local clean_tok="${f_tokens//[^0-9]/}"
      local f_tok=0
      if [[ -n "$clean_in" || -n "$clean_out" ]]; then
        f_tok=$(( ${clean_in:-0} + ${clean_out:-0} ))
      elif [[ -n "$clean_tok" ]]; then
        f_tok=$(( clean_tok ))
      fi

      if (( found_idx < 0 )); then
        found_idx="$w_cnt"
        W_NAME[$found_idx]="$f_worker"
        W_ROUND[$found_idx]=1
        W_STARTED[$found_idx]="$f_started"
        W_FINISHED[$found_idx]="$f_finished"
        W_PLAN_NAME[$found_idx]="$f_plan"
        W_PLAN_PATH[$found_idx]="$f_plan"
        W_STATE[$found_idx]="$f_state"
        raw_pids[$found_idx]="$f_pid"
        W_ENGINE[$found_idx]="$f_engine"
        W_MODEL[$found_idx]="$f_model"
        W_TOK[$found_idx]="$f_tok"
        W_WORKTREE[$found_idx]="$f_worktree"
        W_ROLE[$found_idx]="${f_role:-dev}"
        W_PARENT[$found_idx]="$f_parent"
        W_DEPTH[$found_idx]="$f_depth"
        W_STATUS_FILE[$found_idx]="$status_file"
        W_LOG[$found_idx]="$f_log"
        W_MODEL_TIER[$found_idx]="$f_tier"
        W_VERIFY[$found_idx]="$f_verify"
        W_SCOPE_VIOLATION[$found_idx]="$f_scope"
        W_MERGED[$found_idx]="$f_merged"
        W_DISCARDED[$found_idx]="$f_discarded"
        prev_started[$found_idx]=-1
        prev_state[$found_idx]=""
        prev_verify[$found_idx]=""
        prev_scope[$found_idx]=""
      else
        W_ROUND[$found_idx]=$(( W_ROUND[$found_idx] + 1 ))
        if [[ -n "$f_parent" && -z "${W_PARENT[$found_idx]}" ]]; then
          W_PARENT[$found_idx]="$f_parent"
        fi
        if (( f_started >= W_STARTED[$found_idx] )); then
          prev_started[$found_idx]="${W_STARTED[$found_idx]}"
          prev_state[$found_idx]="${W_STATE[$found_idx]}"
          prev_verify[$found_idx]="${W_VERIFY[$found_idx]}"
          prev_scope[$found_idx]="${W_SCOPE_VIOLATION[$found_idx]}"
          W_STARTED[$found_idx]="$f_started"
          W_FINISHED[$found_idx]="$f_finished"
          W_PLAN_NAME[$found_idx]="$f_plan"
          W_PLAN_PATH[$found_idx]="$f_plan"
          W_STATE[$found_idx]="$f_state"
          raw_pids[$found_idx]="$f_pid"
          W_ENGINE[$found_idx]="$f_engine"
          W_MODEL[$found_idx]="$f_model"
          W_TOK[$found_idx]="$f_tok"
          W_WORKTREE[$found_idx]="$f_worktree"
          W_STATUS_FILE[$found_idx]="$status_file"
          W_LOG[$found_idx]="$f_log"
          W_MODEL_TIER[$found_idx]="$f_tier"
          W_VERIFY[$found_idx]="$f_verify"
          W_SCOPE_VIOLATION[$found_idx]="$f_scope"
          W_MERGED[$found_idx]="$f_merged"
          W_DISCARDED[$found_idx]="$f_discarded"
          [[ -z "$f_role" ]] || W_ROLE[$found_idx]="$f_role"
          [[ -z "$f_parent" ]] || W_PARENT[$found_idx]="$f_parent"
          [[ -z "$f_depth" ]] || W_DEPTH[$found_idx]="$f_depth"
        elif (( prev_started[found_idx] < 0 || f_started >= prev_started[found_idx] )); then
          prev_started[$found_idx]="$f_started"
          prev_state[$found_idx]="$f_state"
          prev_verify[$found_idx]="$f_verify"
          prev_scope[$found_idx]="$f_scope"
        fi
      fi
    done
  fi

  TOTAL_WORKERS="${#W_NAME[@]}"

  # Finalize worker fields and build plan list
  local wi=0
  while (( wi < TOTAL_WORKERS )); do
    local st="${W_STATE[$wi]}"
    local pid="${raw_pids[$wi]}"
    if [[ "$st" == "running" ]]; then
      if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
        st="lost"
      fi
    fi
    W_STATE[$wi]="$st"

    W_MERGE_STATE[$wi]=""
    W_ACTIVITY[$wi]=""
    W_OUT_AGE[$wi]=""
    W_IS_STALE[$wi]=0
    W_ASK_TS[$wi]=""
    W_ASK_AGE[$wi]=""
    W_ROUND_REASON[$wi]=""

    if [[ "$st" == "running" ]]; then
      local live_file="${W_STATUS_FILE[$wi]%.status}.live"
      if [[ -n "${W_STATUS_FILE[$wi]}" && -f "$live_file" ]]; then
        local l_line lk lv l_tok_in="" l_tok_out="" l_act=""
        while IFS= read -r l_line || [[ -n "$l_line" ]]; do
          [[ "$l_line" == *=* ]] || continue
          lk="${l_line%%=*}"
          lv="${l_line#*=}"
          case "$lk" in
            tokens_in)  l_tok_in="$lv" ;;
            tokens_out) l_tok_out="$lv" ;;
            activity)   l_act="$lv" ;;
          esac
        done < "$live_file"
        local clean_l_in="${l_tok_in//[^0-9]/}"
        local clean_l_out="${l_tok_out//[^0-9]/}"
        if [[ -n "$clean_l_in" || -n "$clean_l_out" ]]; then
          W_TOK[$wi]=$(( ${clean_l_in:-0} + ${clean_l_out:-0} ))
        fi
        if [[ -n "$l_act" ]]; then
          l_act="${l_act//$'\r'/}"
          l_act="${l_act//$'\n'/}"
          l_act="${l_act//$'\t'/ }"
          if [[ "$l_act" =~ [[:cntrl:]] ]]; then
            l_act="$(printf '%s' "$l_act" | tr -d '[:cntrl:]')"
          fi
          W_ACTIVITY[$wi]="$l_act"
        fi
      fi
      local log_path="${W_LOG[$wi]}"
      if [[ -n "$log_path" && "$log_path" != /* && ! -e "$log_path" && -e "$WS_ROOT/$log_path" ]]; then
        log_path="$WS_ROOT/$log_path"
      fi
      if [[ -n "$log_path" && -e "$log_path" ]]; then
        local log_mtime=""
        log_mtime="$(stat -c %Y "$log_path" 2>/dev/null || stat -f %m "$log_path" 2>/dev/null || true)"
        if [[ "$log_mtime" =~ ^[0-9]+$ ]]; then
          local out_age=$(( DATA_NOW - log_mtime ))
          (( out_age >= 0 )) || out_age=0
          W_OUT_AGE[$wi]="$out_age"
          if (( out_age > stale_secs )); then
            W_IS_STALE[$wi]=1
          fi
        fi
      fi
    elif [[ "$st" == "completed" ]]; then
      if [[ "${W_VERIFY[$wi]}" == "fail" || "${W_VERIFY[$wi]}" == "timeout" ]]; then
        VERIFY_FAIL_COUNT=$(( VERIFY_FAIL_COUNT + 1 ))
      fi
      if [[ -n "${W_MERGED[$wi]}" ]]; then
        W_MERGE_STATE[$wi]="merged"
      elif [[ -n "${W_DISCARDED[$wi]}" ]]; then
        W_MERGE_STATE[$wi]="discarded"
      elif [[ -n "${W_WORKTREE[$wi]}" && -d "${W_WORKTREE[$wi]}" ]]; then
        W_MERGE_STATE[$wi]="unmerged"
      fi
    fi

    if (( W_ROUND[wi] >= 2 )); then
      if [[ "${prev_verify[$wi]}" == "fail" || "${prev_verify[$wi]}" == "timeout" ]]; then
        W_ROUND_REASON[$wi]="verify fail"
      elif [[ -n "${prev_scope[$wi]}" ]]; then
        W_ROUND_REASON[$wi]="scope"
      elif [[ "${prev_state[$wi]}" == "failed" ]]; then
        W_ROUND_REASON[$wi]="failed"
      elif [[ "${prev_state[$wi]}" == "stopped" ]]; then
        W_ROUND_REASON[$wi]="stopped"
      else
        W_ROUND_REASON[$wi]="fix"
      fi
    fi

    case "$st" in
      running)   RUNNING_COUNT=$(( RUNNING_COUNT + 1 )) ;;
      completed) COMPLETED_COUNT=$(( COMPLETED_COUNT + 1 )) ;;
      failed)    FAILED_COUNT=$(( FAILED_COUNT + 1 )) ;;
      stopped)   STOPPED_COUNT=$(( STOPPED_COUNT + 1 )) ;;
      lost)      LOST_COUNT=$(( LOST_COUNT + 1 )) ;;
    esac

    TOTAL_TOKENS=$(( TOTAL_TOKENS + W_TOK[$wi] ))

    if [[ -n "${W_PARENT[$wi]}" ]]; then
      W_DEPTH[$wi]=2
    elif [[ "${W_DEPTH[$wi]:-}" =~ ^[1-9][0-9]*$ ]]; then
      W_DEPTH[$wi]=$(( W_DEPTH[$wi] ))
    else
      W_DEPTH[$wi]=1
    fi
    W_BRANCH_TOK[$wi]="${W_TOK[$wi]}"
    W_KIDS_TOTAL[$wi]=0
    W_KIDS_DONE[$wi]=0
    W_KIDS_RUNNING[$wi]=0
    W_SM_INDEX[$wi]=0

    local r_mod="${W_MODEL[$wi]}"
    W_MODEL[$wi]="${r_mod##*/}"

    local r_started="${W_STARTED[$wi]}"
    local r_finished="${W_FINISHED[$wi]}"
    local el=0
    if [[ -n "$r_finished" && "$r_finished" =~ ^[0-9]+$ ]]; then
      el=$(( r_finished - r_started ))
    else
      el=$(( DATA_NOW - r_started ))
    fi
    (( el >= 0 )) || el=0
    W_ELAPSED[$wi]="$el"

    local raw_p="${W_PLAN_NAME[$wi]}"
    local p_name="(no plan)"
    if [[ -n "$raw_p" && "$raw_p" != "(no plan)" && "$raw_p" != "none" ]]; then
      local p_base="${raw_p##*/}"
      p_name="${p_base%.md}"
    fi
    W_PLAN_NAME[$wi]="$p_name"

    W_LAST_TYPE[$wi]=""
    W_LAST_TS[$wi]=""
    W_ASKING[$wi]=0
    W_ASK_H_IDX[$wi]=-1
    W_MSG_RECENT[$wi]=0
    W_DEPS[$wi]=""

    wi=$(( wi + 1 ))
  done

  # Aggregate child counts and branch tokens into parent sub-managers
  wi=0
  while (( wi < TOTAL_WORKERS )); do
    local p_id="${W_PARENT[$wi]}"
    if [[ -n "$p_id" ]]; then
      local pi_w=0
      while (( pi_w < TOTAL_WORKERS )); do
        if [[ "${W_NAME[$pi_w]}" == "$p_id" ]]; then
          W_BRANCH_TOK[$pi_w]=$(( W_BRANCH_TOK[pi_w] + W_TOK[wi] ))
          W_KIDS_TOTAL[$pi_w]=$(( W_KIDS_TOTAL[pi_w] + 1 ))
          case "${W_STATE[$wi]}" in
            completed) W_KIDS_DONE[$pi_w]=$(( W_KIDS_DONE[pi_w] + 1 )) ;;
            running)   W_KIDS_RUNNING[$pi_w]=$(( W_KIDS_RUNNING[pi_w] + 1 )) ;;
          esac
          break
        fi
        pi_w=$(( pi_w + 1 ))
      done
    fi
    wi=$(( wi + 1 ))
  done

  # Parse history
  local history_raw
  history_raw="$(read_history "$WS_ROOT" "$since")"
  local regex="^[[:space:]*]*\\[([^]]+)\\][[:space:]]+([^[:space:]]+)[[:space:]]*->[[:space:]]*([^:]+):[[:space:]]*(.*)$"
  local sender_names=()
  local sender_counts=()
  local raw_line last_h_idx=-1
  while IFS= read -r raw_line; do
    raw_line="${raw_line//$'\r'/}"
    [[ -n "$raw_line" ]] || { last_h_idx=-1; continue; }
    if [[ "$raw_line" =~ $regex ]]; then
      local h_ts="${BASH_REMATCH[1]}"
      local h_from="${BASH_REMATCH[2]}"
      local h_to="${BASH_REMATCH[3]}"
      local h_body="${BASH_REMATCH[4]}"
      classify_msg "$h_body"
      local h_type="$REPLY"

      local h_idx="${#H_TS[@]}"
      H_TS[$h_idx]="$h_ts"
      H_FROM[$h_idx]="$h_from"
      H_TO[$h_idx]="$h_to"
      H_TYPE[$h_idx]="$h_type"
      H_BODY[$h_idx]="$h_body"
      last_h_idx="$h_idx"

      # Track sender frequency (excluding known workers so root manager is inferred)
      local from_is_worker=0
      wi=0
      while (( wi < TOTAL_WORKERS )); do
        if [[ "${W_NAME[$wi]}" == "$h_from" ]]; then
          from_is_worker=1
          break
        fi
        wi=$(( wi + 1 ))
      done
      if (( from_is_worker == 0 )); then
        local s_i=0 s_cnt="${#sender_names[@]}" s_found=-1
        while (( s_i < s_cnt )); do
          if [[ "${sender_names[$s_i]}" == "$h_from" ]]; then
            s_found="$s_i"
            break
          fi
          s_i=$(( s_i + 1 ))
        done
        if (( s_found < 0 )); then
          sender_names[$s_cnt]="$h_from"
          sender_counts[$s_cnt]=1
        else
          sender_counts[$s_found]=$(( sender_counts[$s_found] + 1 ))
        fi
      fi

      # Match against workers
      wi=0
      while (( wi < TOTAL_WORKERS )); do
        local wn="${W_NAME[$wi]}"
        local wp="${W_PARENT[$wi]}"
        if [[ "$h_from" == "$wn" || "$h_to" == "$wn" ]]; then
          local other="$h_to"
          [[ "$h_from" == "$wn" ]] || other="$h_from"
          local match_edge=1
          if [[ -n "$wp" ]]; then
            # Child worker: match messages with its parent sub-manager
            [[ "$other" == "$wp" ]] || match_edge=0
          else
            # Depth-1 worker / sub-manager: ignore messages to/from its own children
            local ci_w=0
            while (( ci_w < TOTAL_WORKERS )); do
              if [[ "${W_NAME[$ci_w]}" == "$other" && "${W_PARENT[$ci_w]}" == "$wn" ]]; then
                match_edge=0
                break
              fi
              ci_w=$(( ci_w + 1 ))
            done
          fi
          if (( match_edge == 1 )); then
            W_LAST_TYPE[$wi]="$h_type"
            W_LAST_TS[$wi]="$h_ts"
            if [[ "$h_from" == "$wn" ]]; then
              if [[ "$h_type" == "QUESTION" ]]; then
                W_ASKING[$wi]=1
                W_ASK_TS[$wi]="$h_ts"
                W_ASK_H_IDX[$wi]="$h_idx"
              fi
            elif [[ "$h_to" == "$wn" && "$h_type" == "ANSWER" ]]; then
              W_ASKING[$wi]=0
              W_ASK_TS[$wi]=""
              W_ASK_H_IDX[$wi]=-1
            fi
          fi
        fi
        wi=$(( wi + 1 ))
      done
    elif [[ "$raw_line" == " "* || "$raw_line" == $'\t'* ]] && (( last_h_idx >= 0 )) && [[ "${H_TYPE[$last_h_idx]}" == "QUESTION" || "${H_TYPE[$last_h_idx]}" == "ANSWER" ]]; then
      local cont="$raw_line"
      cont="${cont//$'\t'/ }"
      if [[ "$cont" =~ [[:cntrl:]] ]]; then
        cont="$(printf '%s' "$cont" | tr -d '[:cntrl:]')"
      fi
      while [[ "$cont" == " "* ]]; do
        cont="${cont# }"
      done
      while [[ "$cont" == *" " ]]; do
        cont="${cont% }"
      done
      if [[ -n "$cont" && "${#H_BODY[$last_h_idx]}" -lt 1000 ]]; then
        if [[ -n "${H_BODY[$last_h_idx]}" ]]; then
          H_BODY[$last_h_idx]="${H_BODY[$last_h_idx]} ${cont}"
        else
          H_BODY[$last_h_idx]="$cont"
        fi
      fi
    else
      last_h_idx=-1
    fi
  done <<< "$history_raw"

  # Manager ID
  MANAGER_ID="${SQUAD_MANAGER_ID:-}"
  if [[ -z "$MANAGER_ID" ]]; then
    local best_sender="" best_cnt=0 s_i=0 s_cnt="${#sender_names[@]}"
    while (( s_i < s_cnt )); do
      if (( sender_counts[$s_i] > best_cnt )); then
        best_cnt="${sender_counts[$s_i]}"
        best_sender="${sender_names[$s_i]}"
      fi
      s_i=$(( s_i + 1 ))
    done
    MANAGER_ID="${best_sender:-manager}"
  fi

  # Finalize worker edge info and aggregate plan stats
  wi=0
  while (( wi < TOTAL_WORKERS )); do
    if [[ "${W_STATE[$wi]}" != "running" ]]; then
      W_ASKING[$wi]=0
      W_ASK_TS[$wi]=""
      W_ASK_H_IDX[$wi]=-1
    elif (( W_ASKING[wi] == 1 )) && [[ -n "${W_ASK_TS[$wi]}" ]]; then
      rfc3339_to_epoch "${W_ASK_TS[$wi]}"
      local ask_ep="$REPLY"
      if (( ask_ep > 0 )); then
        local ask_age=$(( DATA_NOW - ask_ep ))
        (( ask_age >= 0 )) || ask_age=0
        W_ASK_AGE[$wi]="$ask_age"
      fi
    fi

    local mtype="${W_LAST_TYPE[$wi]}"
    if [[ -z "$mtype" ]]; then
      case "${W_STATE[$wi]}" in
        completed)   mtype="done" ;;
        failed|lost) mtype="failed" ;;
        *)           mtype="brief" ;;
      esac
    fi
    case "$mtype" in
      brief)    W_EDGE_ARROW[$wi]="▼"; W_EDGE_TEXT[$wi]="brief";    W_EDGE_TYPE[$wi]="brief" ;;
      ANSWER)   W_EDGE_ARROW[$wi]="▼"; W_EDGE_TEXT[$wi]="ANSWER";   W_EDGE_TYPE[$wi]="ANSWER" ;;
      QUESTION) W_EDGE_ARROW[$wi]="▲"; W_EDGE_TEXT[$wi]="QUESTION"; W_EDGE_TYPE[$wi]="QUESTION" ;;
      done)     W_EDGE_ARROW[$wi]="▲"; W_EDGE_TEXT[$wi]="done";     W_EDGE_TYPE[$wi]="done" ;;
      failed)   W_EDGE_ARROW[$wi]="▲"; W_EDGE_TEXT[$wi]="failed";   W_EDGE_TYPE[$wi]="failed" ;;
    esac

    if (( use_color == 1 )) && [[ -n "${W_LAST_TS[$wi]}" ]]; then
      rfc3339_to_epoch "${W_LAST_TS[$wi]}"
      local msg_ep="$REPLY"
      if (( msg_ep > 0 && DATA_NOW - msg_ep >= 0 && DATA_NOW - msg_ep < 6 )); then
        W_MSG_RECENT[$wi]=1
      fi
    fi

    # Aggregate into plan
    local p_name="${W_PLAN_NAME[$wi]}"
    local pi=0 p_cnt="${#P_NAME[@]}" p_found=-1
    while (( pi < p_cnt )); do
      if [[ "${P_NAME[$pi]}" == "$p_name" ]]; then
        p_found="$pi"
        break
      fi
      pi=$(( pi + 1 ))
    done
    if (( p_found < 0 )); then
      p_found="$p_cnt"
      P_NAME[$p_found]="$p_name"
      P_FILE[$p_found]=""
      P_ACTIVE[$p_found]=0
      P_LAST_TS[$p_found]=0
      P_DONE_CNT[$p_found]=0
      P_FAIL_CNT[$p_found]=0
      P_TOK[$p_found]=0
      P_TASK_TOTAL[$p_found]=0
      P_TASK_DONE[$p_found]=0
    fi
    if [[ -z "${P_FILE[$p_found]}" && -n "${W_PLAN_PATH[$wi]}" ]]; then
      resolve_plan_file "${W_PLAN_PATH[$wi]}"
      P_FILE[$p_found]="$REPLY"
    fi
    P_TOK[$p_found]=$(( P_TOK[p_found] + W_TOK[wi] ))

    if [[ "${W_STATE[$wi]}" == "running" ]] || (( W_ASKING[$wi] == 1 || W_KIDS_RUNNING[wi] > 0 )); then
      P_ACTIVE[$p_found]=1
    fi
    local act_ts="${W_STARTED[$wi]}"
    if [[ -n "${W_FINISHED[$wi]}" && "${W_FINISHED[$wi]}" =~ ^[0-9]+$ ]]; then
      if (( W_FINISHED[$wi] > act_ts )); then
        act_ts="${W_FINISHED[$wi]}"
      fi
    fi
    if (( act_ts > P_LAST_TS[$p_found] )); then
      P_LAST_TS[$p_found]="$act_ts"
    fi
    case "${W_STATE[$wi]}" in
      completed)   P_DONE_CNT[$p_found]=$(( P_DONE_CNT[$p_found] + 1 )) ;;
      failed|lost) P_FAIL_CNT[$p_found]=$(( P_FAIL_CNT[$p_found] + 1 )) ;;
    esac

    wi=$(( wi + 1 ))
  done

  # Parse ## Tasks from each resolved plan file for progress, dependencies, and pending tasks
  local p_cnt="${#P_NAME[@]}"
  local pi=0
  while (( pi < p_cnt )); do
    local p_file="${P_FILE[$pi]}"
    if [[ -n "$p_file" && -f "$p_file" && -r "$p_file" ]]; then
      local parsed_tasks
      parsed_tasks="$(parse_plan_tasks "$p_file")"
      if [[ -n "$parsed_tasks" ]]; then
        local t_line
        while IFS= read -r t_line; do
          [[ -n "$t_line" ]] || continue
          local t_id="${t_line%%$'\t'*}"
          local t_rest="${t_line#*$'\t'}"
          local t_eng="${t_rest%%$'\t'*}"
          local t_deps="${t_rest#*$'\t'}"
          [[ -n "$t_id" ]] || continue

          P_TASK_TOTAL[$pi]=$(( P_TASK_TOTAL[pi] + 1 ))
          local matched_w=-1
          wi=0
          while (( wi < TOTAL_WORKERS )); do
            if [[ "${W_PLAN_NAME[$wi]}" == "${P_NAME[$pi]}" && "${W_NAME[$wi]}" == "$t_id" ]]; then
              matched_w="$wi"
              break
            fi
            wi=$(( wi + 1 ))
          done
          if (( matched_w >= 0 )); then
            W_DEPS[$matched_w]="$t_deps"
            if [[ "${W_STATE[$matched_w]}" == "completed" && "${W_VERIFY[$matched_w]}" != "fail" && "${W_VERIFY[$matched_w]}" != "timeout" ]]; then
              P_TASK_DONE[$pi]=$(( P_TASK_DONE[pi] + 1 ))
            fi
          else
            local pt_idx="${#PT_ID[@]}"
            PT_PLAN[$pt_idx]="$pi"
            PT_ID[$pt_idx]="$t_id"
            PT_ENGINE[$pt_idx]="$t_eng"
            PT_DEPS[$pt_idx]="$t_deps"
          fi
        done <<< "$parsed_tasks"
      fi
    fi
    pi=$(( pi + 1 ))
  done

  # Rank plans: plans with running/asking worker first, then newest activity, then name
  local p_cnt="${#P_NAME[@]}"
  local pi=0
  while (( pi < p_cnt )); do
    P_ORDER[$pi]="$pi"
    pi=$(( pi + 1 ))
  done

  local i=1
  while (( i < p_cnt )); do
    local key_p="${P_ORDER[$i]}"
    local j=$(( i - 1 ))
    while (( j >= 0 )); do
      local cmp_p="${P_ORDER[$j]}"
      local swap=0
      if (( P_ACTIVE[$key_p] > P_ACTIVE[$cmp_p] )); then
        swap=1
      elif (( P_ACTIVE[$key_p] == P_ACTIVE[$cmp_p] )); then
        if (( P_LAST_TS[$key_p] > P_LAST_TS[$cmp_p] )); then
          swap=1
        elif (( P_LAST_TS[$key_p] == P_LAST_TS[$cmp_p] )) && [[ "${P_NAME[$key_p]}" < "${P_NAME[$cmp_p]}" ]]; then
          swap=1
        fi
      fi
      if (( swap == 1 )); then
        P_ORDER[$(( j + 1 ))]="${P_ORDER[$j]}"
        j=$(( j - 1 ))
      else
        break
      fi
    done
    P_ORDER[$(( j + 1 ))]="$key_p"
    i=$(( i + 1 ))
  done

  # Assign 1-based zoom indices to sub-managers in plan & graph visual order
  local rank=0
  while (( rank < p_cnt )); do
    local pi_ord="${P_ORDER[$rank]}"
    local sm_pw=()
    wi=0
    while (( wi < TOTAL_WORKERS )); do
      if [[ "${W_PLAN_NAME[$wi]}" == "${P_NAME[$pi_ord]}" && -z "${W_PARENT[$wi]}" ]]; then
        if [[ "${W_ROLE[$wi]}" == "sub-manager" ]] || (( W_KIDS_TOTAL[wi] > 0 )); then
          sm_pw[${#sm_pw[@]}]="$wi"
        fi
      fi
      wi=$(( wi + 1 ))
    done
    local sm_cnt="${#sm_pw[@]}"
    local a=1
    while (( a < sm_cnt )); do
      local kw="${sm_pw[$a]}"
      local k_act=0
      [[ "${W_STATE[$kw]}" == "running" || "${W_ASKING[$kw]}" == "1" ]] || (( W_KIDS_RUNNING[kw] > 0 )) && k_act=1
      local b=$(( a - 1 ))
      while (( b >= 0 )); do
        local cw="${sm_pw[$b]}"
        local c_act=0
        [[ "${W_STATE[$cw]}" == "running" || "${W_ASKING[$cw]}" == "1" ]] || (( W_KIDS_RUNNING[cw] > 0 )) && c_act=1
        local swap=0
        if (( k_act > c_act )); then
          swap=1
        elif (( k_act == c_act )); then
          if (( k_act == 1 )); then
            (( W_STARTED[kw] < W_STARTED[cw] )) && swap=1
          else
            (( W_STARTED[kw] > W_STARTED[cw] )) && swap=1
          fi
        fi
        if (( swap == 1 )); then
          sm_pw[$(( b + 1 ))]="${sm_pw[$b]}"
          b=$(( b - 1 ))
        else
          break
        fi
      done
      sm_pw[$(( b + 1 ))]="$kw"
      a=$(( a + 1 ))
    done
    local si=0
    while (( si < sm_cnt )); do
      local sw="${sm_pw[$si]}"
      local z_idx=$(( ${#SM_LIST[@]} + 1 ))
      SM_LIST[${#SM_LIST[@]}]="$sw"
      W_SM_INDEX[$sw]="$z_idx"
      si=$(( si + 1 ))
    done
    rank=$(( rank + 1 ))
  done
}

# Format expanded or collapsed plan header into REPLY, scoped to zoom_target when set.
format_plan_header_line() {
  local pi="$1" columns="$2" collapsed="${3:-0}"
  local plan_tok="${P_TOK[$pi]}"
  local plan_done="${P_DONE_CNT[$pi]}"
  local plan_fail="${P_FAIL_CNT[$pi]}"
  local t_done="${P_TASK_DONE[$pi]}"
  local t_tot="${P_TASK_TOTAL[$pi]}"

  if [[ -n "$zoom_target" ]]; then
    plan_tok=0
    plan_done=0
    plan_fail=0
    t_tot=0
    t_done=0
    local wi=0
    while (( wi < TOTAL_WORKERS )); do
      if [[ "${W_PLAN_NAME[$wi]}" == "${P_NAME[$pi]}" && "${W_PARENT[$wi]}" == "$zoom_target" ]]; then
        plan_tok=$(( plan_tok + W_TOK[wi] ))
        case "${W_STATE[$wi]}" in
          completed)   plan_done=$(( plan_done + 1 )) ;;
          failed|lost) plan_fail=$(( plan_fail + 1 )) ;;
        esac
      fi
      wi=$(( wi + 1 ))
    done
  fi

  local plain
  if (( collapsed == 1 )); then
    plain="▸ Plan ${P_NAME[$pi]}"
  else
    plain="Plan ${P_NAME[$pi]}"
  fi
  if (( t_tot > 0 )); then
    plain="${plain} · ${t_done}/${t_tot} tasks"
  fi
  if (( plan_tok > 0 )); then
    fmt_human_count "$plan_tok"
    plain="${plain} · ${REPLY} tok"
  fi
  if (( collapsed == 1 )); then
    local age=$(( DATA_NOW - P_LAST_TS[pi] ))
    fmt_elapsed "$age"
    plain="${plain} · ✓${plan_done} ✗${plan_fail} · last ${REPLY} ago"
  fi
  trunc_str "$plain" "$columns"
}

format_collapsed_plan_line() {
  local pi="$1" columns="$2"
  format_plan_header_line "$pi" "$columns" 1
  if [[ -n "$dim" ]]; then
    REPLY="${dim}${REPLY}${reset}"
  fi
}

# Build tree diagram lines into DIAG_T0..DIAG_T3 and DIAG_LINE_COUNT
build_tree_diagram() {
  local columns="$1" diag_budget="$2"
  DIAG_T0=""
  DIAG_T1=""
  DIAG_T2=""
  DIAG_T3=""
  DIAG_LINE_COUNT=0

  local max_w_len=6 max_em_len=0
  local wi=0
  while (( wi < TOTAL_WORKERS )); do
    local wn="${W_NAME[$wi]}"
    local w_eff_len="${#wn}"
    if [[ -z "$zoom_target" && -n "${W_PARENT[$wi]}" ]]; then
      w_eff_len=$(( w_eff_len + 3 ))
    fi
    (( w_eff_len > max_w_len )) && max_w_len="$w_eff_len"
    fmt_eng_mod "${W_ENGINE[$wi]}" "${W_MODEL[$wi]}"
    if [[ -n "${W_MODEL_TIER[$wi]}" ]]; then
      REPLY="${REPLY} · ${W_MODEL_TIER[$wi]}"
    fi
    trunc_str "$REPLY" 42
    (( ${#REPLY} > max_em_len )) && max_em_len="${#REPLY}"
    wi=$(( wi + 1 ))
  done
  if [[ -z "$zoom_target" ]]; then
    local pt_i=0 pt_cnt="${#PT_ID[@]}"
    while (( pt_i < pt_cnt )); do
      local pt_len="${#PT_ID[$pt_i]}"
      (( pt_len > max_w_len )) && max_w_len="$pt_len"
      if [[ -n "${PT_ENGINE[$pt_i]}" ]]; then
        (( ${#PT_ENGINE[$pt_i]} > max_em_len )) && max_em_len="${#PT_ENGINE[$pt_i]}"
      fi
      pt_i=$(( pt_i + 1 ))
    done
  fi

  local plan_list=()
  local raw_p_cnt="${#P_ORDER[@]}"
  local r_i=0
  while (( r_i < raw_p_cnt )); do
    local cand_pi="${P_ORDER[$r_i]}"
    if [[ -n "$zoom_target" ]]; then
      local has_z=0
      wi=0
      while (( wi < TOTAL_WORKERS )); do
        if [[ "${W_PLAN_NAME[$wi]}" == "${P_NAME[$cand_pi]}" ]] && \
           [[ "${W_PARENT[$wi]}" == "$zoom_target" || "${W_NAME[$wi]}" == "$zoom_target" ]]; then
          has_z=1
          break
        fi
        wi=$(( wi + 1 ))
      done
      (( has_z == 1 )) && plan_list[${#plan_list[@]}]="$cand_pi"
    else
      plan_list[${#plan_list[@]}]="$cand_pi"
    fi
    r_i=$(( r_i + 1 ))
  done

  local p_cnt="${#plan_list[@]}"
  local num_expanded="$p_cnt"
  (( num_expanded > 2 )) && num_expanded=2
  if (( expand_earlier == 1 && num_expanded == 2 )); then
    local p0="${plan_list[0]}" p0_items=0
    wi=0
    while (( wi < TOTAL_WORKERS )); do
      if [[ "${W_PLAN_NAME[$wi]}" == "${P_NAME[$p0]}" ]]; then
        if [[ -n "$zoom_target" ]]; then
          [[ "${W_PARENT[$wi]}" == "$zoom_target" ]] && p0_items=$(( p0_items + 1 ))
        else
          p0_items=$(( p0_items + 1 ))
        fi
      fi
      wi=$(( wi + 1 ))
    done
    if [[ -z "$zoom_target" ]]; then
      local pt_i=0 pt_cnt="${#PT_ID[@]}"
      while (( pt_i < pt_cnt )); do
        (( PT_PLAN[pt_i] == p0 )) && p0_items=$(( p0_items + 1 ))
        pt_i=$(( pt_i + 1 ))
      done
    fi
    local half_avail=$(( (diag_budget - (p_cnt - 2)) / 2 - 2 ))
    if (( p0_items > half_avail && p0_items > 4 )); then
      num_expanded=1
    fi
  fi
  local collapsed_cnt=$(( p_cnt - num_expanded ))

  # Check how many worker lines each expanded plan can show within diag_budget
  local avail_for_expanded=$(( diag_budget - collapsed_cnt ))
  (( avail_for_expanded >= 4 )) || avail_for_expanded=4

  local rank=0
  while (( rank < p_cnt )); do
    local pi="${plan_list[$rank]}"
    if (( rank >= num_expanded )); then
      format_collapsed_plan_line "$pi" "$columns"
      DIAG_T0+="${REPLY}"$'\n'
      DIAG_LINE_COUNT=$(( DIAG_LINE_COUNT + 1 ))
      rank=$(( rank + 1 ))
      continue
    fi

    # Collect top-level workers in this plan sorted by started ascending
    local d1_w=()
    wi=0
    while (( wi < TOTAL_WORKERS )); do
      if [[ "${W_PLAN_NAME[$wi]}" == "${P_NAME[$pi]}" ]]; then
        if [[ -n "$zoom_target" ]]; then
          if [[ "${W_PARENT[$wi]}" == "$zoom_target" ]]; then
            d1_w[${#d1_w[@]}]="$wi"
          fi
        elif [[ -z "${W_PARENT[$wi]}" ]]; then
          d1_w[${#d1_w[@]}]="$wi"
        fi
      fi
      wi=$(( wi + 1 ))
    done
    local d1_cnt="${#d1_w[@]}"
    local a=1
    while (( a < d1_cnt )); do
      local kw="${d1_w[$a]}"
      local b=$(( a - 1 ))
      while (( b >= 0 )); do
        local cw="${d1_w[$b]}"
        if (( W_STARTED[kw] < W_STARTED[cw] )); then
          d1_w[$(( b + 1 ))]="${d1_w[$b]}"
          b=$(( b - 1 ))
        else
          break
        fi
      done
      d1_w[$(( b + 1 ))]="$kw"
      a=$(( a + 1 ))
    done

    local rem_exp=$(( num_expanded - rank ))
    local plan_budget=$(( avail_for_expanded / rem_exp ))
    local max_lines_budget=$(( plan_budget - 2 ))
    (( max_lines_budget >= 1 )) || max_lines_budget=1
    local max_d1_show="$max_lines_budget"
    if (( expand_earlier == 0 && max_d1_show > 4 )); then
      max_d1_show=4
    fi

    # Build ordered list of (worker_idx_or_pending, rel_depth) for display
    local pw=()
    local pw_rel_depth=()
    local d1_idx=0
    while (( d1_idx < d1_cnt )); do
      local w_top="${d1_w[$d1_idx]}"
      pw[${#pw[@]}]="$w_top"
      pw_rel_depth[${#pw_rel_depth[@]}]=1
      if [[ -z "$zoom_target" ]]; then
        local kids=()
        wi=0
        while (( wi < TOTAL_WORKERS )); do
          if [[ "${W_PARENT[$wi]}" == "${W_NAME[$w_top]}" ]]; then
            kids[${#kids[@]}]="$wi"
          fi
          wi=$(( wi + 1 ))
        done
        local k_cnt="${#kids[@]}"
        local ka=1
        while (( ka < k_cnt )); do
          local kkw="${kids[$ka]}"
          local kb=$(( ka - 1 ))
          while (( kb >= 0 )); do
            local kcw="${kids[$kb]}"
            if (( W_STARTED[kkw] < W_STARTED[kcw] )); then
              kids[$(( kb + 1 ))]="${kids[$kb]}"
              kb=$(( kb - 1 ))
            else
              break
            fi
          done
          kids[$(( kb + 1 ))]="$kkw"
          ka=$(( ka + 1 ))
        done
        local ki=0
        while (( ki < k_cnt )); do
          pw[${#pw[@]}]="${kids[$ki]}"
          pw_rel_depth[${#pw_rel_depth[@]}]=2
          ki=$(( ki + 1 ))
        done
      fi
      d1_idx=$(( d1_idx + 1 ))
    done
    if [[ -z "$zoom_target" ]]; then
      local pt_i=0 pt_cnt="${#PT_ID[@]}"
      while (( pt_i < pt_cnt )); do
        if (( PT_PLAN[pt_i] == pi )); then
          pw[${#pw[@]}]=$(( TOTAL_WORKERS + pt_i ))
          pw_rel_depth[${#pw_rel_depth[@]}]=1
        fi
        pt_i=$(( pt_i + 1 ))
      done
    fi

    local pw_cnt="${#pw[@]}"
    local show_cnt=0
    local shown_d1=0
    local scan_i=0
    while (( scan_i < pw_cnt )); do
      if (( pw_rel_depth[scan_i] == 1 )); then
        if (( shown_d1 >= max_d1_show )); then
          break
        fi
        shown_d1=$(( shown_d1 + 1 ))
      fi
      if (( show_cnt >= max_lines_budget )); then
        break
      fi
      show_cnt=$(( show_cnt + 1 ))
      scan_i=$(( scan_i + 1 ))
    done
    local rest_cnt=$(( pw_cnt - show_cnt ))
    if (( rest_cnt > 0 && 2 + show_cnt + 1 > plan_budget && show_cnt > 1 )); then
      show_cnt=$(( show_cnt - 1 ))
      rest_cnt=$(( pw_cnt - show_cnt ))
    fi

    format_plan_header_line "$pi" "$columns" 0
    local plan_line="$REPLY"
    DIAG_T0+="${plan_line}"$'\n'
    DIAG_LINE_COUNT=$(( DIAG_LINE_COUNT + 1 ))

    local tree_root_id="$MANAGER_ID"
    [[ -n "$zoom_target" ]] && tree_root_id="$zoom_target"
    local mgr_plain="  ${tree_root_id}"
    (( ${#mgr_plain} <= columns )) || mgr_plain="${mgr_plain:0:$columns}"
    if [[ -n "$c_manager" ]]; then
      DIAG_T0+="  ${c_manager}${mgr_plain:2}${reset}"$'\n'
    else
      DIAG_T0+="${mgr_plain}"$'\n'
    fi
    DIAG_LINE_COUNT=$(( DIAG_LINE_COUNT + 1 ))

    local idx=0
    while (( idx < show_cnt )); do
      local w="${pw[$idx]}"
      local r_depth="${pw_rel_depth[$idx]}"
      local branch
      if (( r_depth == 2 )); then
        local is_last_kid=1
        if (( idx + 1 < show_cnt && pw_rel_depth[idx + 1] == 2 )); then
          is_last_kid=0
        fi
        if (( is_last_kid == 1 )); then
          branch="      └─▶ "
        else
          branch="      ├─▶ "
        fi
        pad_str "${W_NAME[$w]}" $(( max_w_len - 3 + 2 ))
      else
        local has_more_d1=0
        local look=$(( idx + 1 ))
        while (( look < show_cnt )); do
          if (( pw_rel_depth[look] == 1 )); then
            has_more_d1=1
            break
          fi
          look=$(( look + 1 ))
        done
        if (( has_more_d1 == 0 )); then
          branch="   └─▶ "
        else
          branch="   ├─▶ "
        fi
        if (( w >= TOTAL_WORKERS )); then
          local pt_i=$(( w - TOTAL_WORKERS ))
          pad_str "${PT_ID[$pt_i]}" $(( max_w_len + 2 ))
        else
          pad_str "${W_NAME[$w]}" $(( max_w_len + 2 ))
        fi
      fi
      local worker_col="$REPLY"

      if (( w >= TOTAL_WORKERS )); then
        local pt_i=$(( w - TOTAL_WORKERS ))
        fmt_eng_mod "${PT_ENGINE[$pt_i]}" ""
        trunc_str "$REPLY" 42
        pad_str "$REPLY" $(( max_em_len + 2 ))
        local eng_mod_col="$REPLY"

        resolve_worker_state -1 "pending" 999
        local state_plain="$ST_PLAIN"
        if (( ${#state_plain} < 12 )); then
          pad_str "$state_plain" 12
          state_plain="$REPLY"
        else
          state_plain="${state_plain} "
        fi
        local tail_part=""
        if [[ -n "${PT_DEPS[$pt_i]}" ]]; then
          tail_part="after ${PT_DEPS[$pt_i]}"
        fi
        local row_plain="${branch}${worker_col}${eng_mod_col}${state_plain}${tail_part}"
        (( ${#row_plain} <= columns )) || row_plain="${row_plain:0:$columns}"
        local row_display="$row_plain"
        if [[ -n "$dim" ]]; then
          row_display="${dim}${row_plain}${reset}"
        fi
        DIAG_T0+="${row_display}"$'\n'
        DIAG_LINE_COUNT=$(( DIAG_LINE_COUNT + 1 ))
        idx=$(( idx + 1 ))
        continue
      fi

      fmt_eng_mod "${W_ENGINE[$w]}" "${W_MODEL[$w]}"
      if [[ -n "${W_MODEL_TIER[$w]}" ]]; then
        REPLY="${REPLY} · ${W_MODEL_TIER[$w]}"
      fi
      trunc_str "$REPLY" 42
      pad_str "$REPLY" $(( max_em_len + 2 ))
      local eng_mod_col="$REPLY"

      local eff_state="${W_STATE[$w]}"
      if (( r_depth == 1 && W_KIDS_RUNNING[w] > 0 )); then
        eff_state="running"
      fi

      resolve_worker_state "$w" "$eff_state" 999
      local state_plain="$ST_PLAIN" state_disp="$ST_DISP" state_color="$ST_COLOR"
      if (( ${#state_plain} < 12 )); then
        pad_str "$state_plain" 12
        state_plain="$REPLY"
        if (( ST_IS_SPIN == 1 )); then
          state_disp="${state_plain/⠋/@@SPIN@@}"
        else
          state_disp="$state_plain"
        fi
      else
        state_plain="${state_plain} "
        state_disp="${state_disp} "
      fi

      fmt_elapsed "${W_ELAPSED[$w]}"
      local elapsed_text="$REPLY"
      local tail_part="$elapsed_text"
      local disp_tok="${W_TOK[$w]}"
      if (( r_depth == 1 && W_BRANCH_TOK[w] > disp_tok )); then
        disp_tok="${W_BRANCH_TOK[$w]}"
      fi
      if (( disp_tok > 0 )); then
        fmt_human_count "$disp_tok"
        tail_part="${tail_part}  ${REPLY} tok"
      fi
      if (( W_ROUND[w] > 1 )); then
        tail_part="${tail_part}  round ${W_ROUND[$w]} (${W_ROUND_REASON[$w]})"
      fi
      if [[ -n "${W_SCOPE_VIOLATION[$w]}" ]]; then
        tail_part="${tail_part}  scope!"
      fi
      if [[ -n "${W_MERGE_STATE[$w]}" ]]; then
        tail_part="${tail_part}  ${W_MERGE_STATE[$w]}"
      fi
      if [[ -n "${W_DEPS[$w]}" ]]; then
        tail_part="${tail_part}  after ${W_DEPS[$w]}"
      fi
      if [[ "${W_STATE[$w]}" == "running" ]]; then
        if [[ -n "${W_OUT_AGE[$w]}" ]]; then
          fmt_elapsed "${W_OUT_AGE[$w]}"
          tail_part="${tail_part}  ${REPLY} ago"
        fi
        if [[ -n "${W_ACTIVITY[$w]}" ]]; then
          tail_part="${tail_part}  ${W_ACTIVITY[$w]}"
        fi
      fi

      local prefix_plain="${branch}${worker_col}${eng_mod_col}"
      local row_plain="${prefix_plain}${state_plain}${tail_part}"
      local row_display
      if (( ${#row_plain} <= columns )); then
        if [[ -n "$state_color" ]]; then
          row_display="${prefix_plain}${state_color}${state_disp}${reset}${tail_part}"
        else
          row_display="${prefix_plain}${state_disp}${tail_part}"
        fi
      elif (( ${#prefix_plain} + ${#state_plain} <= columns )); then
        local rem_tail=$(( columns - ${#prefix_plain} - ${#state_plain} ))
        local tail_trunc="${tail_part:0:$rem_tail}"
        if [[ -n "$state_color" ]]; then
          row_display="${prefix_plain}${state_color}${state_disp}${reset}${tail_trunc}"
        else
          row_display="${prefix_plain}${state_disp}${tail_trunc}"
        fi
      elif (( ${#prefix_plain} < columns )); then
        local rem_state=$(( columns - ${#prefix_plain} ))
        local state_trunc="${state_plain:0:$rem_state}"
        if [[ "$state_disp" != "$state_plain" ]]; then
          state_trunc="${state_trunc/⠋/@@SPIN@@}"
        fi
        if [[ -n "$state_color" ]]; then
          row_display="${prefix_plain}${state_color}${state_trunc}${reset}"
        else
          row_display="${prefix_plain}${state_trunc}"
        fi
      else
        row_display="${prefix_plain:0:$columns}"
      fi

      DIAG_T0+="${row_display}"$'\n'
      DIAG_LINE_COUNT=$(( DIAG_LINE_COUNT + 1 ))
      idx=$(( idx + 1 ))
    done

    if (( rest_cnt > 0 )); then
      local r_done=0 r_fail=0 r_pend=0
      while (( idx < pw_cnt )); do
        local rw="${pw[$idx]}"
        if (( rw >= TOTAL_WORKERS )); then
          r_pend=$(( r_pend + 1 ))
        else
          case "${W_STATE[$rw]}" in
            completed)   r_done=$(( r_done + 1 )) ;;
            failed|lost) r_fail=$(( r_fail + 1 )) ;;
          esac
        fi
        idx=$(( idx + 1 ))
      done
      local sum_plain="   +${rest_cnt} earlier · ✓${r_done} ✗${r_fail}"
      if (( r_pend > 0 )); then
        sum_plain="${sum_plain} ○${r_pend}"
      fi
      trunc_str "$sum_plain" "$columns"
      if [[ -n "$dim" ]]; then
        DIAG_T0+="${dim}${REPLY}${reset}"$'\n'
      else
        DIAG_T0+="${REPLY}"$'\n'
      fi
      DIAG_LINE_COUNT=$(( DIAG_LINE_COUNT + 1 ))
    fi

    avail_for_expanded=$(( avail_for_expanded - (2 + show_cnt + (rest_cnt > 0 ? 1 : 0)) ))
    rank=$(( rank + 1 ))
  done

  DIAG_T1="$DIAG_T0"
  DIAG_T2="$DIAG_T0"
  DIAG_T3="$DIAG_T0"
}

# Build graph diagram lines into DIAG_T0..DIAG_T3 and DIAG_LINE_COUNT
build_graph_diagram() {
  local columns="$1" diag_budget="$2"
  if (( columns < 20 )); then
    build_tree_diagram "$columns" "$diag_budget"
    return
  fi

  DIAG_T0=""
  DIAG_T1=""
  DIAG_T2=""
  DIAG_T3=""
  DIAG_LINE_COUNT=0

  local min_inner_w=16 min_content_w=14
  if (( columns <= 60 )); then
    min_inner_w=12
    min_content_w=11
  fi
  local min_box_w=$(( min_inner_w + 2 ))
  local gap=2
  local per_row=$(( (columns + gap) / (min_box_w + gap) ))
  (( per_row >= 1 )) || per_row=1
  (( per_row <= 4 )) || per_row=4

  local avail_box_w=$(( (columns - (per_row - 1) * gap) / per_row ))
  local inner_w=$(( avail_box_w - 2 ))
  (( inner_w >= min_inner_w )) || inner_w="$min_inner_w"
  (( inner_w <= 28 )) || inner_w=28
  local content_w=$(( inner_w - 2 ))
  if (( inner_w == min_inner_w )); then
    content_w="$min_content_w"
  fi
  local box_w=$(( inner_w + 2 ))
  local half_box=$(( box_w / 2 ))

  local full_bars="${DASHES_PAD:0:$inner_w}"
  local left_bars="${DASHES_PAD:0:$(( half_box - 1 ))}"
  local right_bars="${DASHES_PAD:0:$(( inner_w - half_box ))}"
  local d_full_bars="${DOUBLE_DASHES_PAD:0:$inner_w}"
  local d_left_bars="${DOUBLE_DASHES_PAD:0:$(( half_box - 1 ))}"
  local d_right_bars="${DOUBLE_DASHES_PAD:0:$(( inner_w - half_box ))}"

  local plan_list=()
  local raw_p_cnt="${#P_ORDER[@]}"
  local r_i=0
  while (( r_i < raw_p_cnt )); do
    local cand_pi="${P_ORDER[$r_i]}"
    local has_nodes=0
    local wi=0
    while (( wi < TOTAL_WORKERS )); do
      if [[ "${W_PLAN_NAME[$wi]}" == "${P_NAME[$cand_pi]}" ]]; then
        if [[ -n "$zoom_target" ]]; then
          if [[ "${W_PARENT[$wi]}" == "$zoom_target" || "${W_NAME[$wi]}" == "$zoom_target" ]]; then
            has_nodes=1
            break
          fi
        elif [[ -z "${W_PARENT[$wi]}" ]]; then
          has_nodes=1
          break
        fi
      fi
      wi=$(( wi + 1 ))
    done
    (( has_nodes == 1 )) && plan_list[${#plan_list[@]}]="$cand_pi"
    r_i=$(( r_i + 1 ))
  done

  local p_cnt="${#plan_list[@]}"
  local num_expanded="$p_cnt"
  (( num_expanded > 2 )) && num_expanded=2

  # Pre-collect sorted workers per plan: running/asking first, then most recent finished
  # Calculate height needed for 2 expanded plans vs 1 expanded plan (Rule 1 & 2)
  local exp_heights=()
  local rank=0
  while (( rank < p_cnt )); do
    local pi="${plan_list[$rank]}"
    local cnt=0 wi=0
    while (( wi < TOTAL_WORKERS )); do
      if [[ "${W_PLAN_NAME[$wi]}" == "${P_NAME[$pi]}" ]]; then
        if [[ -n "$zoom_target" ]]; then
          [[ "${W_PARENT[$wi]}" == "$zoom_target" ]] && cnt=$(( cnt + 1 ))
        elif [[ -z "${W_PARENT[$wi]}" ]]; then
          cnt=$(( cnt + 1 ))
        fi
      fi
      wi=$(( wi + 1 ))
    done
    if (( cnt > per_row )); then
      exp_heights[$rank]=14
    else
      exp_heights[$rank]=13
    fi
    rank=$(( rank + 1 ))
  done

  if (( num_expanded == 2 )); then
    local needed=$(( exp_heights[0] + exp_heights[1] + (p_cnt - 2) ))
    if (( needed > diag_budget )); then
      num_expanded=1
    fi
  fi
  if (( num_expanded == 1 && p_cnt >= 1 )); then
    local needed1=$(( exp_heights[0] + (p_cnt - 1) ))
    if (( needed1 > diag_budget && diag_budget < 13 )); then
      num_expanded=0
    fi
  fi

  rank=0
  while (( rank < p_cnt )); do
    local pi="${plan_list[$rank]}"
    if (( rank >= num_expanded )); then
      format_collapsed_plan_line "$pi" "$columns"
      local col_line="${REPLY}"$'\n'
      DIAG_T0+="$col_line"
      DIAG_T1+="$col_line"
      DIAG_T2+="$col_line"
      DIAG_T3+="$col_line"
      DIAG_LINE_COUNT=$(( DIAG_LINE_COUNT + 1 ))
      rank=$(( rank + 1 ))
      continue
    fi

    # Collect workers for this plan
    local pw=()
    local wi=0
    while (( wi < TOTAL_WORKERS )); do
      if [[ "${W_PLAN_NAME[$wi]}" == "${P_NAME[$pi]}" ]]; then
        if [[ -n "$zoom_target" ]]; then
          if [[ "${W_PARENT[$wi]}" == "$zoom_target" ]]; then
            pw[${#pw[@]}]="$wi"
          fi
        elif [[ -z "${W_PARENT[$wi]}" ]]; then
          pw[${#pw[@]}]="$wi"
        fi
      fi
      wi=$(( wi + 1 ))
    done
    local pw_cnt="${#pw[@]}"

    # Sort workers: active (running/asking) first by started asc, then finished by started desc
    local a=1
    while (( a < pw_cnt )); do
      local kw="${pw[$a]}"
      local k_act=0
      [[ "${W_STATE[$kw]}" == "running" || "${W_ASKING[$kw]}" == "1" ]] || (( W_KIDS_RUNNING[kw] > 0 )) && k_act=1
      local b=$(( a - 1 ))
      while (( b >= 0 )); do
        local cw="${pw[$b]}"
        local c_act=0
        [[ "${W_STATE[$cw]}" == "running" || "${W_ASKING[$cw]}" == "1" ]] || (( W_KIDS_RUNNING[cw] > 0 )) && c_act=1
        local swap=0
        if (( k_act > c_act )); then
          swap=1
        elif (( k_act == c_act )); then
          if (( k_act == 1 )); then
            (( W_STARTED[kw] < W_STARTED[cw] )) && swap=1
          else
            (( W_STARTED[kw] > W_STARTED[cw] )) && swap=1
          fi
        fi
        if (( swap == 1 )); then
          pw[$(( b + 1 ))]="${pw[$b]}"
          b=$(( b - 1 ))
        else
          break
        fi
      done
      pw[$(( b + 1 ))]="$kw"
      a=$(( a + 1 ))
    done

    local row_cnt="$pw_cnt"
    (( row_cnt > per_row )) && row_cnt="$per_row"
    local rest_cnt=$(( pw_cnt - row_cnt ))

    format_plan_header_line "$pi" "$columns"
    local plan_line="$REPLY"
    (( ${#plan_line} <= columns )) || plan_line="${plan_line:0:$columns}"
    DIAG_T0+="${plan_line}"$'\n'
    DIAG_T1+="${plan_line}"$'\n'
    DIAG_T2+="${plan_line}"$'\n'
    DIAG_T3+="${plan_line}"$'\n'
    DIAG_LINE_COUNT=$(( DIAG_LINE_COUNT + 1 ))

    local eff_row_cnt="$row_cnt"
    (( eff_row_cnt >= 1 )) || eff_row_cnt=1

    # Manager / Sub-manager top box geometry: centred over the span of the row_cnt boxes
    local span=$(( eff_row_cnt * box_w + (eff_row_cnt - 1) * gap ))
    local mgr_L=$(( (span - box_w) / 2 ))
    (( mgr_L >= 0 )) || mgr_L=0
    if (( mgr_L + box_w > columns )); then
      mgr_L=$(( columns - box_w ))
    fi
    local M=$(( mgr_L + half_box ))
    local mgr_pad="${SPACES_PAD:0:$mgr_L}"

    local top_box_label="$MANAGER_ID"
    [[ -n "$zoom_target" ]] && top_box_label="$zoom_target"
    trunc_str "$top_box_label" "$content_w"
    center_str "$REPLY" "$inner_w"
    local mgr_cell="$REPLY"

    local mgr_top mgr_mid mgr_bot_static mgr_bot_dot
    if [[ -n "$zoom_target" ]]; then
      if [[ -n "$c_manager" ]]; then
        mgr_top="${mgr_pad}${c_manager}╔${d_full_bars}╗${reset}"
        mgr_mid="${mgr_pad}${c_manager}║${mgr_cell}║${reset}"
        if (( row_cnt > 0 )); then
          mgr_bot_static="${mgr_pad}${c_manager}╚${d_left_bars}┬${d_right_bars}╝${reset}"
          mgr_bot_dot="${mgr_pad}${c_manager}╚${d_left_bars}${c_running_bright}●${c_manager}${d_right_bars}╝${reset}"
        else
          mgr_bot_static="${mgr_pad}${c_manager}╚${d_full_bars}╝${reset}"
          mgr_bot_dot="$mgr_bot_static"
        fi
      else
        mgr_top="${mgr_pad}╔${d_full_bars}╗"
        mgr_mid="${mgr_pad}║${mgr_cell}║"
        if (( row_cnt > 0 )); then
          mgr_bot_static="${mgr_pad}╚${d_left_bars}┬${d_right_bars}╝"
        else
          mgr_bot_static="${mgr_pad}╚${d_full_bars}╝"
        fi
        mgr_bot_dot="$mgr_bot_static"
      fi
    else
      if [[ -n "$c_manager" ]]; then
        mgr_top="${mgr_pad}${c_manager}┌${full_bars}┐${reset}"
        mgr_mid="${mgr_pad}${c_manager}│${mgr_cell}│${reset}"
        mgr_bot_static="${mgr_pad}${c_manager}└${left_bars}┬${right_bars}┘${reset}"
        mgr_bot_dot="${mgr_pad}${c_manager}└${left_bars}${c_running_bright}●${c_manager}${right_bars}┘${reset}"
      else
        mgr_top="${mgr_pad}┌${full_bars}┐"
        mgr_mid="${mgr_pad}│${mgr_cell}│"
        mgr_bot_static="${mgr_pad}└${left_bars}┬${right_bars}┘"
        mgr_bot_dot="$mgr_bot_static"
      fi
    fi

    if (( row_cnt == 0 )); then
      local empty_top="${mgr_top}"$'\n'"${mgr_mid}"$'\n'"${mgr_bot_static}"$'\n'
      DIAG_T0+="$empty_top"
      DIAG_T1+="$empty_top"
      DIAG_T2+="$empty_top"
      DIAG_T3+="$empty_top"
      DIAG_LINE_COUNT=$(( DIAG_LINE_COUNT + 3 ))
      rank=$(( rank + 1 ))
      continue
    fi

    # Compute box centres C_b and running flags for the visible row
    local centers=()
    local box_running=()
    local any_running_edge=0
    local b_idx=0
    while (( b_idx < row_cnt )); do
      local w="${pw[$b_idx]}"
      local L_b=$(( b_idx * (box_w + gap) ))
      local C_b=$(( L_b + half_box ))
      centers[$b_idx]="$C_b"
      if ( [[ "${W_STATE[$w]}" == "running" ]] || (( W_KIDS_RUNNING[w] > 0 )) ) && (( W_ASKING[w] == 0 && W_IS_STALE[w] == 0 )); then
        box_running[$b_idx]=1
        any_running_edge=1
      else
        box_running[$b_idx]=0
      fi
      b_idx=$(( b_idx + 1 ))
    done

    # Build bus line variants (static, midpoint dot, junction dot)
    local min_c="${centers[0]}"
    local max_c="${centers[$(( row_cnt - 1 ))]}"
    (( M < min_c )) && min_c="$M"
    (( M > max_c )) && max_c="$M"

    local bus_pad="${SPACES_PAD:0:$min_c}"
    local bus_static="$bus_pad"
    local bus_mid_dot="$bus_pad"
    local bus_junc_dot="$bus_pad"

    local col_i="$min_c"
    while (( col_i <= max_c )); do
      local is_stem=0 is_ctr=0 is_run_junc=0 is_run_mid=0
      (( col_i == M )) && is_stem=1
      b_idx=0
      while (( b_idx < row_cnt )); do
        local cb="${centers[$b_idx]}"
        if (( col_i == cb )); then
          is_ctr=1
          (( box_running[b_idx] == 1 )) && is_run_junc=1
        fi
        if (( box_running[b_idx] == 1 )); then
          local mid_c=$(( (M + cb) / 2 ))
          (( col_i == mid_c )) && is_run_mid=1
        fi
        b_idx=$(( b_idx + 1 ))
      done

      local ch="─"
      if (( min_c == max_c )); then
        ch="┼"
      elif (( col_i == min_c )); then
        if (( is_stem == 1 && is_ctr == 1 )); then
          ch="├"
        elif (( is_stem == 1 )); then
          ch="└"
        else
          ch="┌"
        fi
      elif (( col_i == max_c )); then
        if (( is_stem == 1 && is_ctr == 1 )); then
          ch="┤"
        elif (( is_stem == 1 )); then
          ch="┘"
        else
          ch="┐"
        fi
      else
        if (( is_stem == 1 && is_ctr == 1 )); then
          ch="┼"
        elif (( is_stem == 1 )); then
          ch="┴"
        elif (( is_ctr == 1 )); then
          ch="┬"
        else
          ch="─"
        fi
      fi

      bus_static+="$ch"
      if (( use_anim == 1 && is_run_mid == 1 )); then
        bus_mid_dot+="${c_running_bright}●${reset}"
      else
        bus_mid_dot+="$ch"
      fi
      if (( use_anim == 1 && is_run_junc == 1 )); then
        bus_junc_dot+="${c_running_bright}●${reset}"
      else
        bus_junc_dot+="$ch"
      fi

      col_i=$(( col_i + 1 ))
    done

    # Build edge line (static and step-3 dot at C_b) and worker boxes
    local edge_static="" edge_dot=""
    local cur_col=0
    local top_row="" l1_row="" l2_row="" l3_row="" l4_row="" l5_row="" bot_row=""

    b_idx=0
    while (( b_idx < row_cnt )); do
      local w="${pw[$b_idx]}"
      local C_b="${centers[$b_idx]}"
      local pad_n=$(( C_b - cur_col ))
      local pad_s="${SPACES_PAD:0:$pad_n}"

      local max_lbl=$(( box_w + gap - 3 ))
      local rem_cols=$(( columns - C_b - 2 ))
      (( rem_cols < max_lbl )) && max_lbl="$rem_cols"
      (( max_lbl >= 1 )) || max_lbl=1

      trunc_str "${W_EDGE_TEXT[$w]}" "$max_lbl"
      local lbl_trunc="$REPLY"
      local arrow_ch="${W_EDGE_ARROW[$w]}"

      local edge_clr=""
      if (( W_ASKING[w] == 1 )); then
        edge_clr="@@ASK_CLR@@"
      else
        case "${W_EDGE_TYPE[$w]}" in
          brief)    edge_clr="$c_brief" ;;
          ANSWER)   edge_clr="$c_answer" ;;
          QUESTION) edge_clr="$c_question" ;;
          done)     edge_clr="$c_done" ;;
          failed)   edge_clr="$c_failed" ;;
        esac
      fi
      if (( W_MSG_RECENT[w] == 1 )) && [[ -n "$reverse" ]]; then
        edge_clr="${reverse}${edge_clr}"
      fi

      if [[ -n "$edge_clr" ]]; then
        edge_static+="${pad_s}${edge_clr}${arrow_ch} ${lbl_trunc}${reset}"
      else
        edge_static+="${pad_s}${arrow_ch} ${lbl_trunc}"
      fi

      if (( use_anim == 1 && box_running[b_idx] == 1 )); then
        if [[ -n "$edge_clr" ]]; then
          edge_dot+="${pad_s}${c_running_bright}●${reset}${edge_clr} ${lbl_trunc}${reset}"
        else
          edge_dot+="${pad_s}${c_running_bright}●${reset} ${lbl_trunc}"
        fi
      else
        if [[ -n "$edge_clr" ]]; then
          edge_dot+="${pad_s}${edge_clr}${arrow_ch} ${lbl_trunc}${reset}"
        else
          edge_dot+="${pad_s}${arrow_ch} ${lbl_trunc}"
        fi
      fi

      cur_col=$(( C_b + 2 + ${#lbl_trunc} ))

      # Worker box content
      local sep=""
      (( b_idx > 0 )) && sep="  "

      local is_sm_node=0
      if [[ -z "$zoom_target" ]] && ( [[ "${W_ROLE[$w]}" == "sub-manager" ]] || (( W_KIDS_TOTAL[w] > 0 )) ); then
        is_sm_node=1
      fi

      local state_plain state_disp box_color=""
      if (( is_sm_node == 1 )); then
        local done_k="${W_KIDS_DONE[$w]}"
        local tot_k="${W_KIDS_TOTAL[$w]}"
        local sm_running=0
        if [[ "${W_STATE[$w]}" == "running" ]] || (( W_KIDS_RUNNING[w] > 0 )); then
          sm_running=1
        fi
        if (( W_ASKING[w] == 1 )); then
          state_plain="? ${done_k}/${tot_k} kids"
          state_disp="$state_plain"
          [[ -n "$c_asking" ]] && box_color="@@ASK_CLR@@"
        elif (( sm_running == 1 )); then
          if (( W_KIDS_RUNNING[w] == 0 && W_IS_STALE[w] == 1 )); then
            state_plain="⚠ ${done_k}/${tot_k} kids"
            state_disp="$state_plain"
            box_color="$c_stale"
          else
            state_plain="⠋ ${done_k}/${tot_k} kids"
            state_disp="@@SPIN@@ ${done_k}/${tot_k} kids"
            box_color="$c_running"
          fi
        else
          case "${W_STATE[$w]}" in
            completed)
              if [[ "${W_VERIFY[$w]}" == "fail" || "${W_VERIFY[$w]}" == "timeout" ]]; then
                state_plain="✗ ${done_k}/${tot_k} kids"
                state_disp="$state_plain"
                box_color="$c_failed"
              else
                state_plain="✓ ${done_k}/${tot_k} kids"
                state_disp="$state_plain"
                box_color="$c_completed"
              fi
              ;;
            failed)
              state_plain="✗ ${done_k}/${tot_k} kids"
              state_disp="$state_plain"
              box_color="$c_failed"
              ;;
            stopped)
              state_plain="⏸ ${done_k}/${tot_k} kids"
              state_disp="$state_plain"
              box_color="$c_stopped"
              ;;
            lost)
              state_plain="? ${done_k}/${tot_k} kids"
              state_disp="$state_plain"
              box_color="$c_failed"
              ;;
            *)
              state_plain="${W_STATE[$w]} ${done_k}/${tot_k} kids"
              state_disp="$state_plain"
              box_color=""
              ;;
          esac
        fi
      else
        resolve_worker_state "$w" "" "$content_w"
        state_plain="$ST_PLAIN"
        state_disp="$ST_DISP"
        box_color="$ST_COLOR"
      fi

      local line5_str=""
      if [[ "${W_STATE[$w]}" == "running" ]]; then
        local out_part=""
        if [[ -n "${W_OUT_AGE[$w]}" ]]; then
          fmt_elapsed "${W_OUT_AGE[$w]}"
          out_part="$REPLY"
        fi
        local act_part="${W_ACTIVITY[$w]}"
        if [[ -n "$out_part" && -n "$act_part" ]]; then
          if (( ${#out_part} + 3 + 4 <= content_w )); then
            line5_str="${out_part} · ${act_part}"
          else
            line5_str="${out_part} ${act_part}"
          fi
        elif [[ -n "$act_part" ]]; then
          line5_str="$act_part"
        elif [[ -n "$out_part" ]]; then
          line5_str="out ${out_part}"
        fi
      else
        if [[ -n "${W_SCOPE_VIOLATION[$w]}" ]]; then
          line5_str="scope!"
        fi
        if [[ -n "${W_MERGE_STATE[$w]}" ]]; then
          if [[ -n "$line5_str" ]]; then
            if (( ${#line5_str} + 3 + ${#W_MERGE_STATE[$w]} <= content_w )); then
              line5_str="${line5_str} · ${W_MERGE_STATE[$w]}"
            else
              line5_str="${line5_str} ${W_MERGE_STATE[$w]}"
            fi
          else
            line5_str="${W_MERGE_STATE[$w]}"
          fi
        fi
      fi

      fmt_elapsed "${W_ELAPSED[$w]}"
      local elapsed_text="$REPLY"
      local box_tok="${W_TOK[$w]}"
      (( is_sm_node == 1 )) && box_tok="${W_BRANCH_TOK[$w]}"
      local tok_s=""
      if (( box_tok > 0 )); then
        fmt_human_count "$box_tok"
        tok_s="$REPLY"
      fi
      local base4_wide="$elapsed_text" base4_tight="$elapsed_text"
      if [[ -n "$tok_s" ]]; then
        base4_wide="${elapsed_text}  ${tok_s}"
        base4_tight="${elapsed_text} ${tok_s}"
      fi

      local line4_str="$base4_wide"
      if (( ${#line4_str} > content_w )); then
        line4_str="$base4_tight"
      fi
      if (( W_ROUND[w] >= 2 )); then
        local r_full="r${W_ROUND[$w]} ${W_ROUND_REASON[$w]}"
        if (( ${#base4_wide} + 2 + ${#r_full} <= content_w )); then
          line4_str="${base4_wide}  ${r_full}"
        elif (( ${#base4_tight} + 1 + ${#r_full} <= content_w )); then
          line4_str="${base4_tight} ${r_full}"
        elif [[ -z "$line5_str" ]]; then
          line5_str="$r_full"
        elif (( ${#line5_str} + 3 + ${#r_full} <= content_w )); then
          line5_str="${line5_str} · ${r_full}"
        elif (( ${#line5_str} + 1 + ${#r_full} <= content_w )); then
          line5_str="${line5_str} ${r_full}"
        else
          line4_str="${base4_tight} ${r_full}"
        fi
      fi

      local line1_str="-"
      if (( is_sm_node == 1 )); then
        local sm_idx="${W_SM_INDEX[$w]:-1}"
        if [[ -n "${W_NAME[$w]}" && -n "${W_ENGINE[$w]}" ]]; then
          line1_str="[${sm_idx}] ${W_NAME[$w]} · ${W_ENGINE[$w]}"
        elif [[ -n "${W_NAME[$w]}" ]]; then
          line1_str="[${sm_idx}] ${W_NAME[$w]}"
        elif [[ -n "${W_ENGINE[$w]}" ]]; then
          line1_str="[${sm_idx}] ${W_ENGINE[$w]}"
        fi
      else
        if [[ -n "${W_NAME[$w]}" && -n "${W_ENGINE[$w]}" ]]; then
          line1_str="${W_NAME[$w]} · ${W_ENGINE[$w]}"
        elif [[ -n "${W_NAME[$w]}" ]]; then
          line1_str="${W_NAME[$w]}"
        elif [[ -n "${W_ENGINE[$w]}" ]]; then
          line1_str="${W_ENGINE[$w]}"
        fi
      fi

      fmt_model_tier "${W_MODEL[$w]}" "${W_MODEL_TIER[$w]}" "$content_w"
      local s_model="$REPLY"

      box_cell "$line1_str" "$inner_w" "$content_w"
      local c1="$REPLY"
      box_cell "$s_model" "$inner_w" "$content_w"
      local c2="$REPLY"
      box_cell "$state_plain" "$inner_w" "$content_w"
      local c3="$REPLY"
      if [[ "$state_disp" != "$state_plain" ]]; then
        c3="${c3/⠋/@@SPIN@@}"
      fi
      box_cell "$line4_str" "$inner_w" "$content_w"
      local c4="$REPLY"
      box_cell "$line5_str" "$inner_w" "$content_w"
      local c5="$REPLY"

      if (( is_sm_node == 1 )); then
        if [[ -n "$box_color" ]]; then
          top_row+="${sep}${box_color}╔${d_left_bars}┴${d_right_bars}╗${reset}"
          l1_row+="${sep}${box_color}║${reset}${c1}${box_color}║${reset}"
          l2_row+="${sep}${box_color}║${reset}${c2}${box_color}║${reset}"
          l3_row+="${sep}${box_color}║${c3}│${reset}"
          l3_row="${l3_row%│${reset}}║${reset}"
          l4_row+="${sep}${box_color}║${reset}${c4}${box_color}║${reset}"
          l5_row+="${sep}${box_color}║${reset}${c5}${box_color}║${reset}"
          bot_row+="${sep}${box_color}╚${d_full_bars}╝${reset}"
        else
          top_row+="${sep}╔${d_left_bars}┴${d_right_bars}╗"
          l1_row+="${sep}║${c1}║"
          l2_row+="${sep}║${c2}║"
          l3_row+="${sep}║${c3}║"
          l4_row+="${sep}║${c4}║"
          l5_row+="${sep}║${c5}║"
          bot_row+="${sep}╚${d_full_bars}╝"
        fi
      elif [[ -n "$box_color" ]]; then
        top_row+="${sep}${box_color}┌${left_bars}┴${right_bars}┐${reset}"
        l1_row+="${sep}${box_color}│${reset}${c1}${box_color}│${reset}"
        l2_row+="${sep}${box_color}│${reset}${c2}${box_color}│${reset}"
        l3_row+="${sep}${box_color}│${c3}│${reset}"
        l4_row+="${sep}${box_color}│${reset}${c4}${box_color}│${reset}"
        l5_row+="${sep}${box_color}│${reset}${c5}${box_color}│${reset}"
        bot_row+="${sep}${box_color}└${full_bars}┘${reset}"
      else
        top_row+="${sep}┌${left_bars}┴${right_bars}┐"
        l1_row+="${sep}│${c1}│"
        l2_row+="${sep}│${c2}│"
        l3_row+="${sep}│${c3}│"
        l4_row+="${sep}│${c4}│"
        l5_row+="${sep}│${c5}│"
        bot_row+="${sep}└${full_bars}┘"
      fi

      b_idx=$(( b_idx + 1 ))
    done

    local box_block="${top_row}"$'\n'"${l1_row}"$'\n'"${l2_row}"$'\n'"${l3_row}"$'\n'"${l4_row}"$'\n'"${l5_row}"$'\n'"${bot_row}"$'\n'
    local mgr_top_mid="${mgr_top}"$'\n'"${mgr_mid}"$'\n'

    if (( use_anim == 1 && any_running_edge == 1 )); then
      DIAG_T0+="${mgr_top_mid}${mgr_bot_dot}"$'\n'"${bus_static}"$'\n'"${edge_static}"$'\n'"${box_block}"
      DIAG_T1+="${mgr_top_mid}${mgr_bot_static}"$'\n'"${bus_mid_dot}"$'\n'"${edge_static}"$'\n'"${box_block}"
      DIAG_T2+="${mgr_top_mid}${mgr_bot_static}"$'\n'"${bus_junc_dot}"$'\n'"${edge_static}"$'\n'"${box_block}"
      DIAG_T3+="${mgr_top_mid}${mgr_bot_static}"$'\n'"${bus_static}"$'\n'"${edge_dot}"$'\n'"${box_block}"
    else
      local static_plan="${mgr_top_mid}${mgr_bot_static}"$'\n'"${bus_static}"$'\n'"${edge_static}"$'\n'"${box_block}"
      DIAG_T0+="$static_plan"
      DIAG_T1+="$static_plan"
      DIAG_T2+="$static_plan"
      DIAG_T3+="$static_plan"
    fi
    DIAG_LINE_COUNT=$(( DIAG_LINE_COUNT + 12 ))

    if (( rest_cnt > 0 && expand_earlier == 0 )); then
      local r_done=0 r_fail=0 r_idx="$row_cnt"
      while (( r_idx < pw_cnt )); do
        local rw="${pw[$r_idx]}"
        case "${W_STATE[$rw]}" in
          completed)   r_done=$(( r_done + 1 )) ;;
          failed|lost) r_fail=$(( r_fail + 1 )) ;;
        esac
        r_idx=$(( r_idx + 1 ))
      done
      local sum_plain="  +${rest_cnt} earlier · ✓${r_done} ✗${r_fail}"
      trunc_str "$sum_plain" "$columns"
      local sum_line="$REPLY"
      if [[ -n "$dim" ]]; then
        sum_line="${dim}${sum_line}${reset}"
      fi
      DIAG_T0+="${sum_line}"$'\n'
      DIAG_T1+="${sum_line}"$'\n'
      DIAG_T2+="${sum_line}"$'\n'
      DIAG_T3+="${sum_line}"$'\n'
      DIAG_LINE_COUNT=$(( DIAG_LINE_COUNT + 1 ))
    fi

    local extra_rows=() extra_i=0
    if (( expand_earlier == 1 )); then
      extra_i="$row_cnt"
      while (( extra_i < pw_cnt )); do
        local ew="${pw[$extra_i]}"
        resolve_worker_state "$ew" "${W_STATE[$ew]}" 999
        extra_rows[${#extra_rows[@]}]="  ${W_NAME[$ew]} · ${ST_PLAIN}"
        extra_i=$(( extra_i + 1 ))
      done
    fi
    extra_i=0
    while (( extra_i < pw_cnt )); do
      local ew="${pw[$extra_i]}"
      if [[ -n "${W_DEPS[$ew]}" ]]; then
        extra_rows[${#extra_rows[@]}]="  ${W_NAME[$ew]} after ${W_DEPS[$ew]}"
      fi
      extra_i=$(( extra_i + 1 ))
    done
    if [[ -z "$zoom_target" ]]; then
      extra_i=0
      while (( extra_i < ${#PT_ID[@]} )); do
        if (( PT_PLAN[extra_i] == pi )); then
          extra_rows[${#extra_rows[@]}]="  ${PT_ID[$extra_i]} · pending${PT_DEPS[$extra_i]:+ · after ${PT_DEPS[$extra_i]}}"
        fi
        extra_i=$(( extra_i + 1 ))
      done
    fi
    extra_i=0
    while (( extra_i < ${#extra_rows[@]} && DIAG_LINE_COUNT < diag_budget )); do
      trunc_str "${extra_rows[$extra_i]}" "$columns"
      local extra_line="${dim}${REPLY}${reset}"$'\n' extra_height=1
      if [[ "${extra_rows[$extra_i]}" == *" · pending"* ]] && (( DIAG_LINE_COUNT + 3 <= diag_budget )); then
        trunc_str "${extra_rows[$extra_i]#  }" $(( columns - 4 ))
        local pending_text="$REPLY" pending_w=$(( ${#REPLY} + 2 ))
        local pending_border="${DASHES_PAD:0:$pending_w}"
        extra_line="${dim}┌${pending_border}┐"$'\n'"│ ${pending_text} │"$'\n'"└${pending_border}┘${reset}"$'\n'
        extra_height=3
      fi
      DIAG_T0+="$extra_line"
      DIAG_T1+="$extra_line"
      DIAG_T2+="$extra_line"
      DIAG_T3+="$extra_line"
      DIAG_LINE_COUNT=$(( DIAG_LINE_COUNT + extra_height ))
      extra_i=$(( extra_i + 1 ))
    done

    rank=$(( rank + 1 ))
  done
}

# Build pipeline diagram lines into DIAG_T0..DIAG_T3 and DIAG_LINE_COUNT
build_pipeline_diagram() {
  local columns="$1" diag_budget="$2"
  DIAG_T0=""
  DIAG_T1=""
  DIAG_T2=""
  DIAG_T3=""
  DIAG_LINE_COUNT=0

  local p_cnt="${#P_ORDER[@]}"
  local num_expanded="$p_cnt"
  (( num_expanded > 2 )) && num_expanded=2
  local collapsed_cnt=$(( p_cnt - num_expanded ))

  local col_w=$(( (columns - 8) / 5 ))
  if (( columns >= 78 && col_w < 14 )); then
    col_w=14
  fi
  (( col_w >= 1 )) || col_w=1

  local hdr_row=""
  local col_idx=0
  local col_name
  for col_name in RUNNING FIX REVIEW DONE FAILED; do
    if (( col_idx < 4 )); then
      local cell_h
      if (( col_w >= 10 )); then
        pad_str "$col_name" $(( col_w - 3 ))
        cell_h="${REPLY}──▶"
      else
        trunc_str "${col_name}──▶" "$col_w"
        pad_str "$REPLY" "$col_w"
        cell_h="$REPLY"
      fi
      hdr_row+="${cell_h}  "
    else
      trunc_str "$col_name" "$col_w"
      pad_str "$REPLY" "$col_w"
      hdr_row+="$REPLY"
    fi
    col_idx=$(( col_idx + 1 ))
  done
  if (( ${#hdr_row} > columns )); then
    hdr_row="${hdr_row:0:$columns}"
  fi
  DIAG_T0+="${hdr_row}"$'\n'
  DIAG_LINE_COUNT=1

  # Sort workers newest first (by finished, else started)
  local all_w=()
  local wi=0
  while (( wi < TOTAL_WORKERS )); do
    if [[ -n "$zoom_target" ]]; then
      if [[ "${W_PARENT[$wi]}" == "$zoom_target" ]]; then
        all_w[${#all_w[@]}]="$wi"
      fi
    else
      all_w[${#all_w[@]}]="$wi"
    fi
    wi=$(( wi + 1 ))
  done
  local all_cnt="${#all_w[@]}"
  local a=1
  while (( a < all_cnt )); do
    local kw="${all_w[$a]}"
    local kw_ts="${W_STARTED[$kw]}"
    if [[ -n "${W_FINISHED[$kw]}" && "${W_FINISHED[$kw]}" =~ ^[0-9]+$ ]] && (( W_FINISHED[kw] > 0 )); then
      kw_ts="${W_FINISHED[$kw]}"
    fi
    local b=$(( a - 1 ))
    while (( b >= 0 )); do
      local cw="${all_w[$b]}"
      local cw_ts="${W_STARTED[$cw]}"
      if [[ -n "${W_FINISHED[$cw]}" && "${W_FINISHED[$cw]}" =~ ^[0-9]+$ ]] && (( W_FINISHED[cw] > 0 )); then
        cw_ts="${W_FINISHED[$cw]}"
      fi
      local swap=0
      if (( kw_ts > cw_ts )); then
        swap=1
      elif (( kw_ts == cw_ts && W_STARTED[kw] > W_STARTED[cw] )); then
        swap=1
      fi
      if (( swap == 1 )); then
        all_w[$(( b + 1 ))]="${all_w[$b]}"
        b=$(( b - 1 ))
      else
        break
      fi
    done
    all_w[$(( b + 1 ))]="$kw"
    a=$(( a + 1 ))
  done

  local col0_l1=() col0_l2=() col0_l2p=()
  local col1_l1=() col1_l2=() col1_l2p=()
  local col2_l1=() col2_l2=() col2_l2p=()
  local col3_l1=() col3_l2=() col3_l2p=()
  local col4_l1=() col4_l2=() col4_l2p=()

  local idx=0
  while (( idx < all_cnt )); do
    local w="${all_w[$idx]}"
    local b_col=4
    if [[ "${W_STATE[$w]}" == "running" ]] || (( W_KIDS_RUNNING[w] > 0 )); then
      if (( W_ROUND[w] >= 2 )); then
        b_col=1
      else
        b_col=0
      fi
    elif [[ "${W_STATE[$w]}" == "completed" ]]; then
      if [[ "${W_MERGE_STATE[$w]}" == "unmerged" ]]; then
        b_col=2
      else
        b_col=3
      fi
    else
      b_col=4
    fi

    local w_disp_id="${W_NAME[$w]}"
    if [[ -n "${W_PARENT[$w]}" ]]; then
      w_disp_id="${W_PARENT[$w]}›${W_NAME[$w]}"
    fi

    local raw_l1
    if (( p_cnt > 1 )); then
      local full_id="${W_PLAN_NAME[$w]}/${w_disp_id}"
      if (( ${#full_id} + 4 <= col_w )) && [[ -n "${W_ENGINE[$w]}" ]]; then
        raw_l1="${full_id} · ${W_ENGINE[$w]}"
      elif (( ${#full_id} <= col_w )); then
        raw_l1="$full_id"
      elif (( col_w > ${#w_disp_id} + 2 )); then
        trunc_str "${W_PLAN_NAME[$w]}" $(( col_w - ${#w_disp_id} - 1 ))
        raw_l1="${REPLY}/${w_disp_id}"
      else
        raw_l1="$w_disp_id"
      fi
    else
      if (( ${#w_disp_id} + 4 <= col_w )) && [[ -n "${W_ENGINE[$w]}" ]]; then
        raw_l1="${w_disp_id} · ${W_ENGINE[$w]}"
      else
        raw_l1="$w_disp_id"
      fi
    fi
    if [[ -n "${W_MODEL_TIER[$w]}" ]] && (( ${#raw_l1} + 3 + ${#W_MODEL_TIER[$w]} <= col_w )); then
      raw_l1="${raw_l1} · ${W_MODEL_TIER[$w]}"
    fi

    resolve_worker_state "$w" "" "$col_w"
    local state_plain="$ST_PLAIN" state_color="$ST_COLOR" is_spin="$ST_IS_SPIN"

    fmt_elapsed "${W_ELAPSED[$w]}"
    local elapsed_s="$REPLY"
    local raw_l2="$state_plain"
    if [[ -n "${W_SCOPE_VIOLATION[$w]}" ]]; then
      raw_l2="${raw_l2} scope!"
    fi
    if [[ -n "${W_MERGE_STATE[$w]}" ]]; then
      raw_l2="${raw_l2} ${W_MERGE_STATE[$w]}"
    fi
    if (( W_ROUND[w] >= 2 )); then
      raw_l2="${raw_l2} r${W_ROUND[$w]}:${W_ROUND_REASON[$w]}"
    fi
    if (( W_TOK[w] > 0 )); then
      fmt_human_count "${W_TOK[$w]}"
      raw_l2="${raw_l2} ${REPLY}"
    fi
    if [[ "${W_STATE[$w]}" == "running" ]]; then
      if [[ -n "${W_OUT_AGE[$w]}" ]]; then
        fmt_elapsed "${W_OUT_AGE[$w]}"
        raw_l2="${raw_l2} ${REPLY}"
      fi
      if [[ -n "${W_ACTIVITY[$w]}" ]]; then
        raw_l2="${raw_l2} ${W_ACTIVITY[$w]}"
      fi
    fi
    raw_l2="${raw_l2}  ${elapsed_s}"

    trunc_str "$raw_l1" "$col_w"
    pad_str "$REPLY" "$col_w"
    local c_l1="$REPLY"

    trunc_str "$raw_l2" "$col_w"
    pad_str "$REPLY" "$col_w"
    local c_l2_plain="$REPLY"
    local c_l2_disp="$c_l2_plain"
    if (( is_spin == 1 )); then
      c_l2_disp="${c_l2_disp/⠋/@@SPIN@@}"
    fi
    if [[ -n "$state_color" ]]; then
      c_l2_disp="${state_color}${c_l2_disp}${reset}"
    fi

    case "$b_col" in
      0)
        local n="${#col0_l1[@]}"
        col0_l1[$n]="$c_l1"; col0_l2[$n]="$c_l2_disp"; col0_l2p[$n]="$c_l2_plain"
        ;;
      1)
        local n="${#col1_l1[@]}"
        col1_l1[$n]="$c_l1"; col1_l2[$n]="$c_l2_disp"; col1_l2p[$n]="$c_l2_plain"
        ;;
      2)
        local n="${#col2_l1[@]}"
        col2_l1[$n]="$c_l1"; col2_l2[$n]="$c_l2_disp"; col2_l2p[$n]="$c_l2_plain"
        ;;
      3)
        local n="${#col3_l1[@]}"
        col3_l1[$n]="$c_l1"; col3_l2[$n]="$c_l2_disp"; col3_l2p[$n]="$c_l2_plain"
        ;;
      4)
        local n="${#col4_l1[@]}"
        col4_l1[$n]="$c_l1"; col4_l2[$n]="$c_l2_disp"; col4_l2p[$n]="$c_l2_plain"
        ;;
    esac

    idx=$(( idx + 1 ))
  done

  local cnts=("${#col0_l1[@]}" "${#col1_l1[@]}" "${#col2_l1[@]}" "${#col3_l1[@]}" "${#col4_l1[@]}")
  local max_total_cards=0
  local ci=0
  while (( ci < 5 )); do
    (( cnts[ci] > max_total_cards )) && max_total_cards="${cnts[$ci]}"
    ci=$(( ci + 1 ))
  done

  # Each card is 2 lines; reserve 1 line for header, collapsed_cnt for collapsed plans, 1 for +N more
  local avail_lines=$(( diag_budget - 1 - collapsed_cnt ))
  local max_cards=$(( avail_lines / 2 ))
  if (( max_total_cards > max_cards )); then
    max_cards=$(( (avail_lines - 1) / 2 ))
  fi
  (( max_cards >= 1 )) || max_cards=1

  local shown_cards="$max_total_cards"
  (( shown_cards > max_cards )) && shown_cards="$max_cards"

  local empty_cell="${SPACES_PAD:0:$col_w}"
  local card_idx=0
  while (( card_idx < shown_cards )); do
    local row1="" row2_disp="" row2_plain=""
    ci=0
    while (( ci < 5 )); do
      local sep=""
      (( ci > 0 )) && sep="  "
      local cell1="$empty_cell" cell2_disp="$empty_cell" cell2_plain="$empty_cell"
      if (( card_idx < cnts[ci] )); then
        case "$ci" in
          0) cell1="${col0_l1[$card_idx]}"; cell2_disp="${col0_l2[$card_idx]}"; cell2_plain="${col0_l2p[$card_idx]}" ;;
          1) cell1="${col1_l1[$card_idx]}"; cell2_disp="${col1_l2[$card_idx]}"; cell2_plain="${col1_l2p[$card_idx]}" ;;
          2) cell1="${col2_l1[$card_idx]}"; cell2_disp="${col2_l2[$card_idx]}"; cell2_plain="${col2_l2p[$card_idx]}" ;;
          3) cell1="${col3_l1[$card_idx]}"; cell2_disp="${col3_l2[$card_idx]}"; cell2_plain="${col3_l2p[$card_idx]}" ;;
          4) cell1="${col4_l1[$card_idx]}"; cell2_disp="${col4_l2[$card_idx]}"; cell2_plain="${col4_l2p[$card_idx]}" ;;
        esac
      fi
      row1+="${sep}${cell1}"
      row2_disp+="${sep}${cell2_disp}"
      row2_plain+="${sep}${cell2_plain}"
      ci=$(( ci + 1 ))
    done
    if (( ${#row1} > columns )); then
      row1="${row1:0:$columns}"
    fi
    if (( ${#row2_plain} > columns )); then
      row2_disp="${row2_plain:0:$columns}"
    fi
    DIAG_T0+="${row1}"$'\n'"${row2_disp}"$'\n'
    DIAG_LINE_COUNT=$(( DIAG_LINE_COUNT + 2 ))
    card_idx=$(( card_idx + 1 ))
  done

  if (( max_total_cards > shown_cards )); then
    local more_disp="" more_plain=""
    ci=0
    while (( ci < 5 )); do
      local sep=""
      (( ci > 0 )) && sep="  "
      local extra=$(( cnts[ci] - shown_cards ))
      if (( extra > 0 )); then
        trunc_str "+${extra} more" "$col_w"
        pad_str "$REPLY" "$col_w"
        local mcell="$REPLY"
        more_plain+="${sep}${mcell}"
        if [[ -n "$dim" ]]; then
          more_disp+="${sep}${dim}${mcell}${reset}"
        else
          more_disp+="${sep}${mcell}"
        fi
      else
        more_plain+="${sep}${empty_cell}"
        more_disp+="${sep}${empty_cell}"
      fi
      ci=$(( ci + 1 ))
    done
    if (( ${#more_plain} > columns )); then
      more_disp="${more_plain:0:$columns}"
    fi
    DIAG_T0+="${more_disp}"$'\n'
    DIAG_LINE_COUNT=$(( DIAG_LINE_COUNT + 1 ))
  fi

  local rank="$num_expanded"
  while (( rank < p_cnt )); do
    local pi="${P_ORDER[$rank]}"
    format_collapsed_plan_line "$pi" "$columns"
    DIAG_T0+="${REPLY}"$'\n'
    DIAG_LINE_COUNT=$(( DIAG_LINE_COUNT + 1 ))
    rank=$(( rank + 1 ))
  done

  # Pipeline columns stay compact; plan details share the remaining diagram space.
  local detail_i=0
  while (( detail_i < num_expanded && DIAG_LINE_COUNT < diag_budget )); do
    local detail_pi="${P_ORDER[$detail_i]}"
    format_plan_header_line "$detail_pi" "$columns"
    DIAG_T0+="${REPLY}"$'\n'
    DIAG_LINE_COUNT=$(( DIAG_LINE_COUNT + 1 ))
    local detail_w=0
    while (( detail_w < TOTAL_WORKERS && DIAG_LINE_COUNT < diag_budget )); do
      if [[ "${W_PLAN_NAME[$detail_w]}" == "${P_NAME[$detail_pi]}" && -n "${W_DEPS[$detail_w]}" ]] &&
         { [[ -z "$zoom_target" || "${W_PARENT[$detail_w]}" == "$zoom_target" ]]; }; then
        trunc_str "  ${W_NAME[$detail_w]} after ${W_DEPS[$detail_w]}" "$columns"
        DIAG_T0+="${REPLY}"$'\n'
        DIAG_LINE_COUNT=$(( DIAG_LINE_COUNT + 1 ))
      fi
      detail_w=$(( detail_w + 1 ))
    done
    local detail_pt=0
    while [[ -z "$zoom_target" ]] && (( detail_pt < ${#PT_ID[@]} && DIAG_LINE_COUNT < diag_budget )); do
      if (( PT_PLAN[detail_pt] == detail_pi )); then
        trunc_str "  ${PT_ID[$detail_pt]} · pending${PT_DEPS[$detail_pt]:+ · after ${PT_DEPS[$detail_pt]}}" "$columns"
        DIAG_T0+="${dim}${REPLY}${reset}"$'\n'
        DIAG_LINE_COUNT=$(( DIAG_LINE_COUNT + 1 ))
      fi
      detail_pt=$(( detail_pt + 1 ))
    done
    detail_i=$(( detail_i + 1 ))
  done

  DIAG_T1="$DIAG_T0"
  DIAG_T2="$DIAG_T0"
  DIAG_T3="$DIAG_T0"
}

build_frame_templates() {
  FRAME_TPL=("" "" "" "")
  DIAG_T0=""
  DIAG_T1=""
  DIAG_T2=""
  DIAG_T3=""
  DIAG_LINE_COUNT=0

  local columns lines
  terminal_columns
  columns="$REPLY"
  terminal_lines
  lines="$REPLY"
  ensure_pad_len "$columns"

  local rule_line="${DASHES_PAD:0:$columns}"
  if [[ -n "$dim" ]]; then
    rule_line="${dim}${rule_line}${reset}"
  fi

  # 1. Header (2 lines): build from parts and drop least important parts until it fits
  # Order of dropping: key hint -> token total -> since HH:MM -> layout name (-> ws -> title)
  local failed_total=$(( FAILED_COUNT + LOST_COUNT ))
  local run_seg="● ${RUNNING_COUNT} running"
  local done_seg="✓ ${COMPLETED_COUNT} done"
  local fail_seg="✗ ${failed_total} failed"
  local verify_seg=""
  if (( VERIFY_FAIL_COUNT > 0 )); then
    verify_seg="⚠ ${VERIFY_FAIL_COUNT} verify"
  fi
  local counts_plain="${run_seg}  ${done_seg}  ${fail_seg}"
  local counts_disp="$counts_plain"
  if (( use_color == 1 )); then
    counts_disp="${c_running}${run_seg}${reset}  ${c_completed}${done_seg}${reset}  ${c_failed}${fail_seg}${reset}"
  fi
  if [[ -n "$verify_seg" ]]; then
    counts_plain="${counts_plain}  ${verify_seg}"
    if (( use_color == 1 )); then
      counts_disp="${counts_disp}  ${c_failed}${verify_seg}${reset}"
    else
      counts_disp="$counts_plain"
    fi
  fi

  local tok_part=""
  if (( TOTAL_TOKENS > 0 )); then
    fmt_human_count "$TOTAL_TOKENS"
    tok_part="${REPLY} tok"
  fi
  local keys_part=""
  if (( once == 0 )); then
    keys_part="[g]raph [p]ipeline [t]ree [f]ilter [e]arlier [q]uit"
  fi

  local use_keys=0 use_tok=0 use_since=1 use_layout=1 use_ws=1 use_title=1
  [[ -n "$keys_part" ]] && use_keys=1
  [[ -n "$tok_part" ]] && use_tok=1

  local header_plain=""
  local drop_step=0
  while (( drop_step <= 6 )); do
    header_plain=""
    (( use_title == 1 )) && header_plain="squad orchestration"
    if (( use_ws == 1 )); then
      header_plain="${header_plain:+${header_plain} · }${WS_NAME}"
    fi
    if (( use_layout == 1 )); then
      header_plain="${header_plain:+${header_plain} · }${layout}"
    fi
    if (( use_since == 1 )); then
      header_plain="${header_plain:+${header_plain} · }since ${SINCE_HHMM}"
    fi
    header_plain="${header_plain:+${header_plain} · }${counts_plain}"
    if (( use_tok == 1 )); then
      header_plain="${header_plain} · ${tok_part}"
    fi
    if (( use_keys == 1 )); then
      header_plain="${header_plain} · ${keys_part}"
    fi

    if (( ${#header_plain} <= columns )); then
      break
    fi

    case "$drop_step" in
      0) use_keys=0 ;;
      1) use_tok=0 ;;
      2) use_since=0 ;;
      3) use_layout=0 ;;
      4) use_ws=0 ;;
      5) use_title=0 ;;
    esac
    drop_step=$(( drop_step + 1 ))
  done

  local header_disp=""
  if (( ${#header_plain} > columns )); then
    # Extreme narrow fallback (e.g. COLUMNS=18): drop trailing count segments before truncating
    local base3_plain="${run_seg}  ${done_seg}  ${fail_seg}"
    if (( ${#base3_plain} <= columns )); then
      header_plain="$base3_plain"
      if (( use_color == 1 )); then
        header_disp="${c_running}${run_seg}${reset}  ${c_completed}${done_seg}${reset}  ${c_failed}${fail_seg}${reset}"
      else
        header_disp="$header_plain"
      fi
    elif (( ${#run_seg} + 2 + ${#done_seg} <= columns )); then
      header_plain="${run_seg}  ${done_seg}"
      if (( use_color == 1 )); then
        header_disp="${c_running}${run_seg}${reset}  ${c_completed}${done_seg}${reset}"
      else
        header_disp="$header_plain"
      fi
    elif (( ${#run_seg} <= columns )); then
      header_plain="$run_seg"
      if (( use_color == 1 )); then
        header_disp="${c_running}${run_seg}${reset}"
      else
        header_disp="$header_plain"
      fi
    else
      header_plain="${run_seg:0:$columns}"
      header_disp="$header_plain"
    fi
  else
    if (( use_title == 1 )); then
      if (( use_color == 1 )); then
        header_disp="${bold}squad orchestration${reset}"
      else
        header_disp="squad orchestration"
      fi
    fi
    if (( use_ws == 1 )); then
      header_disp="${header_disp:+${header_disp} · }${WS_NAME}"
    fi
    if (( use_layout == 1 )); then
      header_disp="${header_disp:+${header_disp} · }${layout}"
    fi
    if (( use_since == 1 )); then
      header_disp="${header_disp:+${header_disp} · }since ${SINCE_HHMM}"
    fi
    header_disp="${header_disp:+${header_disp} · }${counts_disp}"
    if (( use_tok == 1 )); then
      header_disp="${header_disp} · ${tok_part}"
    fi
    if (( use_keys == 1 )); then
      header_disp="${header_disp} · ${keys_part}"
    fi
  fi

  local top_block="${header_disp}"$'\n'"${rule_line}"$'\n'
  local header_lines=2
  if [[ -n "$zoom_target" ]]; then
    local bc_plain="${MANAGER_ID} › ${zoom_target}"
    trunc_str "$bc_plain" "$columns"
    local bc_disp="$REPLY"
    if (( use_color == 1 && ${#bc_plain} <= columns )); then
      bc_disp="${c_manager}${MANAGER_ID}${reset} › ${bold}${zoom_target}${reset}"
    fi
    top_block+="${bc_disp}"$'\n'
    header_lines=3
  fi

  # 2. Compute budget: header (header_lines) + legend (1) + flow (min(FLOW_LINES=6, hist_cnt) + 2)
  local flow_cfg="${SQUAD_ORCHESTRATION_FLOW_LINES:-6}"
  [[ "$flow_cfg" =~ ^[0-9]+$ ]] || flow_cfg=6
  local hist_cnt="${#H_TS[@]}"
  local want_flow_msgs=0 want_flow_lines=0
  if (( hist_cnt > 0 && flow_cfg > 0 )); then
    want_flow_msgs="$hist_cnt"
    (( want_flow_msgs > flow_cfg )) && want_flow_msgs="$flow_cfg"
    want_flow_lines=$(( want_flow_msgs + 2 ))
  fi

  local diag_budget=$(( lines - (header_lines + 1) - want_flow_lines ))
  (( diag_budget >= 1 )) || diag_budget=1

  # 3. Build diagram
  if (( TOTAL_WORKERS == 0 )); then
    local empty_msg="No worker runs in this session yet."
    (( ${#empty_msg} <= columns )) || empty_msg="${empty_msg:0:$columns}"
    DIAG_T0="${empty_msg}"$'\n'
    DIAG_T1="$DIAG_T0"
    DIAG_T2="$DIAG_T0"
    DIAG_T3="$DIAG_T0"
    DIAG_LINE_COUNT=1
  else
    case "$layout" in
      graph)    build_graph_diagram "$columns" "$diag_budget" ;;
      pipeline) build_pipeline_diagram "$columns" "$diag_budget" ;;
      tree)     build_tree_diagram "$columns" "$diag_budget" ;;
    esac
  fi

  # 4. Flow section: min(SQUAD_ORCHESTRATION_FLOW_LINES=6, what is left after the diagram) + 2
  local flow_block=""
  local rem_after_diag=$(( lines - (header_lines + 1) - DIAG_LINE_COUNT ))
  if (( hist_cnt > 0 && flow_cfg > 0 && rem_after_diag >= 3 )); then
    local max_flow_fit=$(( rem_after_diag - 2 ))
    local flow_limit="$flow_cfg"
    (( flow_limit > max_flow_fit )) && flow_limit="$max_flow_fit"
    local flow_ids=() pinned_ids=() recent_ids=()
    local h_idx=0
    while (( h_idx < hist_cnt )); do
      local visible=0 pinned=0 wi=0
      while (( wi < TOTAL_WORKERS )); do
        if [[ "${H_FROM[$h_idx]}" == "${W_NAME[$wi]}" || "${H_TO[$h_idx]}" == "${W_NAME[$wi]}" ]]; then
          if [[ -z "$zoom_target" || "${W_PARENT[$wi]}" == "$zoom_target" || "${W_NAME[$wi]}" == "$zoom_target" ]]; then
            visible=1
            (( W_ASK_H_IDX[wi] == h_idx )) && pinned=1
          fi
        fi
        wi=$(( wi + 1 ))
      done
      if (( visible == 1 )); then
        local typ="${H_TYPE[$h_idx]}"
        if [[ "$flow_filter" == all || "$flow_filter" == questions && ( "$typ" == QUESTION || "$typ" == ANSWER ) || "$flow_filter" == failures && "$typ" == failed ]]; then
          if (( pinned == 1 )); then
            pinned_ids[${#pinned_ids[@]}]="$h_idx"
          else
            recent_ids[${#recent_ids[@]}]="$h_idx"
          fi
        fi
      fi
      h_idx=$(( h_idx + 1 ))
    done
    flow_ids=( ${pinned_ids[@]+"${pinned_ids[@]}"} )
    local recent_start=$(( ${#recent_ids[@]} - flow_limit + ${#pinned_ids[@]} ))
    (( recent_start >= 0 )) || recent_start=0
    while (( recent_start < ${#recent_ids[@]} )); do
      flow_ids[${#flow_ids[@]}]="${recent_ids[$recent_start]}"
      recent_start=$(( recent_start + 1 ))
    done
    flow_block+="${rule_line}"$'\n'
    trunc_str "Flow (latest ${flow_limit}) · ${flow_filter} [f]ilter [e]arlier" "$columns"
    flow_block+="${REPLY}"$'\n'
    local used=0 fi_idx=0
    while (( fi_idx < ${#flow_ids[@]} && used < flow_limit )); do
      h_idx="${flow_ids[$fi_idx]}"
      local f_type="${H_TYPE[$h_idx]}"
      rfc3339_to_hhmm "${H_TS[$h_idx]}"
      local prefix="  ${REPLY}  ${H_FROM[$h_idx]} ──${f_type}──▶ ${H_TO[$h_idx]}  "
      clean_msg_preview "$f_type" "${H_BODY[$h_idx]}"
      local preview="$REPLY" avail=$(( columns - ${#prefix} ))
      if (( avail < 12 )); then
        trunc_str "$prefix" "$columns"
        flow_block+="${REPLY}"$'\n'
        used=$(( used + 1 ))
        prefix="  "
        avail=$(( columns - 2 ))
      fi
      local remaining=$(( flow_limit - used ))
      local pins_left=$(( ${#pinned_ids[@]} - fi_idx - 1 ))
      if (( pins_left > 0 && remaining > pins_left )); then
        remaining=$(( remaining - pins_left ))
      fi
      if (( remaining <= 0 )); then break; fi
      if [[ "$f_type" == QUESTION || "$f_type" == ANSWER ]]; then
        wrap_text "$preview" "$avail" "$remaining"
      else
        trunc_str "$preview" "$avail"
        WRAP_LINES=( "$REPLY" )
      fi
      local li=0 indent="${SPACES_PAD:0:${#prefix}}"
      while (( li < ${#WRAP_LINES[@]} && used < flow_limit )); do
        flow_block+="${prefix}${WRAP_LINES[$li]}"$'\n'
        prefix="$indent"
        used=$(( used + 1 ))
        li=$(( li + 1 ))
      done
      fi_idx=$(( fi_idx + 1 ))
    done
  fi

  # 5. Legend (1 line)
  local legend_plain="Legend: ● running ✓ completed ✗ failed ⏸ stopped ? lost"
  local legend_disp
  if (( ${#legend_plain} > columns )); then
    legend_disp="${legend_plain:0:$columns}"
  elif (( use_color == 1 )); then
    legend_disp="Legend: ${c_running}● running${reset} ${c_completed}✓ completed${reset} ${c_failed}✗ failed${reset} ${c_stopped}⏸ stopped${reset} ${c_failed}? lost${reset}"
  else
    legend_disp="$legend_plain"
  fi

  FRAME_TPL[0]="${top_block}${DIAG_T0}${flow_block}${legend_disp}"$'\n'
  FRAME_TPL[1]="${top_block}${DIAG_T1}${flow_block}${legend_disp}"$'\n'
  FRAME_TPL[2]="${top_block}${DIAG_T2}${flow_block}${legend_disp}"$'\n'
  FRAME_TPL[3]="${top_block}${DIAG_T3}${flow_block}${legend_disp}"$'\n'
}

render_cached_frame() {
  local fnum="${1:-0}"
  local step=0 spin_idx=0
  if (( use_anim == 1 )); then
    step=$(( fnum % 4 ))
    spin_idx=$(( fnum % 10 ))
  fi
  local tpl="${FRAME_TPL[$step]}"
  local spin="${SPINNER_GLYPHS[$spin_idx]}"
  local ask_c="$c_asking"
  if (( use_anim == 1 && fnum % 2 == 0 )); then
    ask_c="${bold}${c_asking}"
  fi
  tpl="${tpl//@@SPIN@@/$spin}"
  tpl="${tpl//@@ASK_CLR@@/$ask_c}"
  REPLY="$tpl"
}

# Ensure blocking writes on TTY stdout (prevents macOS PTY 1024-byte EAGAIN drops under ttyd/vhs)
if [[ -t 1 ]] && command -v perl >/dev/null 2>&1; then
  perl -MFcntl -e 'fcntl(STDOUT, F_SETFL, fcntl(STDOUT, F_GETFL, 0) & ~O_NONBLOCK)' 2>/dev/null || true
fi

cycle_flow_filter() {
  case "$flow_filter" in
    all) flow_filter=questions ;;
    questions) flow_filter=failures ;;
    failures) flow_filter=all ;;
  esac
}

# One-shot execution mode
if (( once == 1 )) || { [[ ! -t 1 ]] && [[ "${SQUAD_ORCHESTRATION_LIVE:-0}" != 1 ]]; }; then
  load_data
  build_frame_templates
  forced_frame="${SQUAD_ORCHESTRATION_FRAME:-0}"
  [[ "$forced_frame" =~ ^[0-9]+$ ]] || forced_frame=0
  render_cached_frame "$forced_frame"
  if [[ -n "${SQUAD_ORCHESTRATION_SWITCH_LAYOUT:-}" ]]; then
    for next_step in ${SQUAD_ORCHESTRATION_SWITCH_LAYOUT//,/ }; do
      case "$next_step" in
        graph|pipeline|tree)
          layout="$next_step"
          ;;
        f|filter) cycle_flow_filter ;;
        e|expand) expand_earlier=$(( 1 - expand_earlier )) ;;
        zoom:*)
          zoom_target="${next_step#zoom:}"
          ;;
        unzoom)
          zoom_target=""
          ;;
      esac
      build_frame_templates
      render_cached_frame "$forced_frame"
    done
  fi
  printf '%s' "$REPLY"
  if [[ "${SQUAD_ORCHESTRATION_REEXEC:-0}" != 1 && -n "${SQUAD_WORKER_MONITOR_READY:-}" ]]; then
    printf '%s\n' "$$" >"$SQUAD_WORKER_MONITOR_READY"
  fi
  exit 0
fi

# Interactive loop with two clocks:
# - Data reload every SQUAD_ORCHESTRATION_INTERVAL (default 2s)
# - Animation redraw at SQUAD_ORCHESTRATION_FPS (default 4 FPS) from cached templates
interval="${SQUAD_ORCHESTRATION_INTERVAL:-2}"
[[ "$interval" =~ ^[0-9]+$ ]] && (( interval >= 1 )) || interval=2

fps="${SQUAD_ORCHESTRATION_FPS:-4}"
[[ "$fps" =~ ^[0-9]+$ ]] && (( fps >= 1 )) || fps=4

if (( fps == 1 )); then
  frame_delay="1"
else
  printf -v frame_delay '0.%03d' $(( 1000 / fps ))
fi

frames_per_reload=$(( interval * fps ))
(( frames_per_reload >= 1 )) || frames_per_reload=1

saved_tty=""
if [[ -t 0 ]] && (( BASH_VERSINFO[0] < 4 )) && [[ "$frame_delay" == *.* ]]; then
  saved_tty="$(stty -g 2>/dev/null || true)"
  if [[ -n "$saved_tty" ]]; then
    trap 'stty "$saved_tty" 2>/dev/null || true' EXIT INT TERM
    stty -icanon -echo 2>/dev/null || true
  fi
fi

first_frame=1
frame_counter=0
subframe=0
need_reload=1

while true; do
  if [[ -n "${SQUAD_DEVKIT_MANAGER_WRAPPER_PID:-}" ]] && ! kill -0 "$SQUAD_DEVKIT_MANAGER_WRAPPER_PID" 2>/dev/null; then
    exit 0
  fi

  if (( need_reload == 1 || subframe >= frames_per_reload )); then
    load_data
    build_frame_templates
    need_reload=0
    subframe=0
  fi

  draw_fnum="${SQUAD_ORCHESTRATION_FRAME:-$frame_counter}"
  [[ "$draw_fnum" =~ ^[0-9]+$ ]] || draw_fnum="$frame_counter"
  render_cached_frame "$draw_fnum"
  frame_output="${REPLY%$'\n'}"
  printf '\033[?2026h\033[H%s\033[K\033[J\033[?2026l' "${frame_output//$'\n'/$'\033[K\n'}"

  if (( first_frame == 1 )); then
    first_frame=0
    if [[ "${SQUAD_ORCHESTRATION_REEXEC:-0}" != 1 && -n "${SQUAD_WORKER_MONITOR_READY:-}" ]]; then
      printf '%s\n' "$$" >"$SQUAD_WORKER_MONITOR_READY"
    fi
  fi

  if [[ -t 0 ]]; then
    key=""
    if (( BASH_VERSINFO[0] >= 4 )) || [[ "$frame_delay" != *.* ]]; then
      IFS= read -r -s -t "$frame_delay" -n 1 key 2>/dev/null || true
    elif command -v perl >/dev/null 2>&1; then
      key="$(perl -e 'vec($r="",0,1)=1; if(select($r,undef,undef,$ARGV[0])>0){sysread(STDIN,$c,1);print $c}' "$frame_delay" 2>/dev/null || true)"
    else
      sleep "$frame_delay"
    fi
    case "$key" in
      q|Q)
        exit 0
        ;;
      g|G)
        layout="graph"
        build_frame_templates
        subframe=0
        ;;
      t|T)
        layout="tree"
        build_frame_templates
        subframe=0
        ;;
      p|P)
        layout="pipeline"
        build_frame_templates
        subframe=0
        ;;
      f|F)
        cycle_flow_filter
        build_frame_templates
        subframe=0
        ;;
      e|E)
        expand_earlier=$(( 1 - expand_earlier ))
        build_frame_templates
        subframe=0
        ;;
      [1-9])
        if (( key <= ${#SM_LIST[@]} )); then
          zoom_target="${W_NAME[${SM_LIST[$(( key - 1 ))]}]}"
          build_frame_templates
          subframe=0
        fi
        ;;
      z|Z)
        if (( ${#SM_LIST[@]} > 0 )); then
          next_sm_pos=0
          if [[ -n "$zoom_target" ]]; then
            sm_i=0
            while (( sm_i < ${#SM_LIST[@]} )); do
              if [[ "${W_NAME[${SM_LIST[$sm_i]}]}" == "$zoom_target" ]]; then
                next_sm_pos=$(( (sm_i + 1) % ${#SM_LIST[@]} ))
                break
              fi
              sm_i=$(( sm_i + 1 ))
            done
          fi
          zoom_target="${W_NAME[${SM_LIST[$next_sm_pos]}]}"
          build_frame_templates
          subframe=0
        fi
        ;;
      $'\033'|$'\177'|$'\010'|$'\b')
        if [[ -z "$locked_root" && -n "$zoom_target" ]]; then
          zoom_target=""
          build_frame_templates
          subframe=0
        fi
        ;;
      $'\t')
        case "$layout" in
          graph)    layout="pipeline" ;;
          pipeline) layout="tree" ;;
          tree)     layout="graph" ;;
        esac
        build_frame_templates
        subframe=0
        ;;
    esac
  else
    sleep "$frame_delay"
  fi

  frame_counter=$(( frame_counter + 1 ))
  subframe=$(( subframe + 1 ))
done
