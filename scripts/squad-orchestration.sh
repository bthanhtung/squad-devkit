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

# Substring work (${s:0:n}) must count characters, not bytes: force a UTF-8 locale.
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
  *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) ;;
  *) export LC_ALL=en_US.UTF-8 ;;
esac
utf8_probe="é"
if (( ${#utf8_probe} != 1 )); then
  export LC_ALL=C.UTF-8
fi
unset utf8_probe

# Environment variables:
#   SQUAD_ORCHESTRATION_LIVE=1    Keep live loop running even when stdout is not a TTY (for tests)

usage() {
  cat <<'EOF'
Usage: squad-orchestration.sh [--once] [--since EPOCH] [--layout LAYOUT] [--root ID] [--all-managers] [--focus] [WORKERS_DIR]

Live terminal orchestration view showing manager and worker flow.

  --once            Render one frame without escape codes and exit
  --since EPOCH     Show runs started at or after EPOCH (default: $SQUAD_DEVKIT_SESSION_START or 0)
  --layout LAYOUT   Layout to render: graph, pipeline, or tree (default: $SQUAD_ORCHESTRATION_LAYOUT or graph)
  --root ID         Start zoomed into sub-manager ID (Esc disabled)
  --all-managers    Show every manager in the directory grouped per manager
  --focus           Present mode: header, main lane and waiting group only
  -h, --help        Show this help

Environment:
  SQUAD_ORCHESTRATION_LIVE=1  Keep live loop running even when stdout is not a TTY (for tests)
EOF
}

once=0
since="${SQUAD_DEVKIT_SESSION_START:-0}"
layout="${SQUAD_ORCHESTRATION_LAYOUT:-graph}"
locked_root=""
zoom_target=""
all_managers=0
focus=0
history_expanded=0
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
    --all-managers)
      all_managers=1
      ;;
    --focus)
      focus=1
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
c_asking="" c_stopped="" c_brief="" c_answer="" c_question="" c_done=""

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

WS_ROOT="$(resolve_workspace_root "$workers_dir")"
WS_NAME="${WS_ROOT##*/}"
[[ -n "$WS_NAME" ]] || WS_NAME="$(basename "$WS_ROOT")"
SINCE_HHMM="$(format_time "$since")"

# Cached data arrays populated by load_data
W_NAME=()
W_STARTED=()
W_FINISHED=()
W_PLAN_NAME=()
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
W_EDGE_ARROW=()
W_EDGE_TEXT=()
W_EDGE_TYPE=()
W_MSG_RECENT=()
W_MGR=()
SM_LIST=()

P_NAME=()
P_ACTIVE=()
P_LAST_TS=()
P_DONE_CNT=()
P_FAIL_CNT=()
P_TOT_CNT=()
P_ORDER=()

H_TS=()
H_FROM=()
H_TO=()
H_TYPE=()
H_BODY=()
H_TAIL=()

DATA_NOW=0
MANAGER_ID="manager"
INFERRED_MANAGER_ID="manager"
MANAGERS_LIST=()
TOTAL_WORKERS=0
RUNNING_COUNT=0
COMPLETED_COUNT=0
FAILED_COUNT=0
STOPPED_COUNT=0
LOST_COUNT=0
TOTAL_TOKENS=0

FRAME_TPL=("" "" "" "")

load_data() {
  W_NAME=()
  W_STARTED=()
  W_FINISHED=()
  W_PLAN_NAME=()
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
  W_EDGE_ARROW=()
  W_EDGE_TEXT=()
  W_EDGE_TYPE=()
  W_MSG_RECENT=()
  W_MGR=()
  SM_LIST=()

  P_NAME=()
  P_ACTIVE=()
  P_LAST_TS=()
  P_DONE_CNT=()
  P_FAIL_CNT=()
  P_TOT_CNT=()
  P_ORDER=()

  H_TS=()
  H_FROM=()
  H_TO=()
  H_TYPE=()
  H_BODY=()
  H_TAIL=()
  MANAGERS_LIST=()

  DATA_NOW="${SQUAD_ORCHESTRATION_NOW:-$(date +%s)}"
  TOTAL_WORKERS=0
  RUNNING_COUNT=0
  COMPLETED_COUNT=0
  FAILED_COUNT=0
  STOPPED_COUNT=0
  LOST_COUNT=0
  TOTAL_TOKENS=0

  local raw_worker=() raw_started=() raw_finished=() raw_plan=() raw_state=()
  local raw_pids=() raw_engine=() raw_model=() raw_tok=() raw_worktree=()
  local raw_role=() raw_parent=() raw_depth=() raw_mgr=() raw_round=()

  local status_file k v
  if [[ -d "$workers_dir" ]]; then
    for status_file in "$workers_dir"/*.status; do
      [[ -e "$status_file" ]] || continue
      local f_worker="" f_started="" f_finished="" f_plan="" f_state="" f_pid=""
      local f_engine="" f_model="" f_tok_in="" f_tok_out="" f_tokens="" f_worktree=""
      local f_role="" f_parent="" f_depth="" f_manager=""
      while IFS='=' read -r k v || [[ -n "$k" ]]; do
        case "$k" in
          worker)     f_worker="$v" ;;
          started)    f_started="$v" ;;
          finished)   f_finished="$v" ;;
          plan)       f_plan="$v" ;;
          state)      f_state="$v" ;;
          pid)        f_pid="$v" ;;
          engine)     f_engine="$v" ;;
          model)      f_model="$v" ;;
          tokens_in)  f_tok_in="$v" ;;
          tokens_out) f_tok_out="$v" ;;
          tokens)     f_tokens="$v" ;;
          worktree)   f_worktree="$v" ;;
          role)       f_role="$v" ;;
          parent)     f_parent="$v" ;;
          depth)      f_depth="$v" ;;
          manager)    f_manager="$v" ;;
        esac
      done < "$status_file"

      [[ -n "$f_started" && "$f_started" =~ ^[0-9]+$ ]] || continue
      (( f_started >= since )) || continue
      [[ -n "$f_worker" ]] || continue

      local found_idx=-1
      local idx=0 w_cnt="${#raw_worker[@]}"
      while (( idx < w_cnt )); do
        if [[ "${raw_worker[$idx]}" == "$f_worker" ]]; then
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
        raw_worker[$found_idx]="$f_worker"
        raw_round[$found_idx]=1
        raw_started[$found_idx]="$f_started"
        raw_finished[$found_idx]="$f_finished"
        raw_plan[$found_idx]="$f_plan"
        raw_state[$found_idx]="$f_state"
        raw_pids[$found_idx]="$f_pid"
        raw_engine[$found_idx]="$f_engine"
        raw_model[$found_idx]="$f_model"
        raw_tok[$found_idx]="$f_tok"
        raw_worktree[$found_idx]="$f_worktree"
        raw_role[$found_idx]="${f_role:-dev}"
        raw_parent[$found_idx]="$f_parent"
        raw_depth[$found_idx]="$f_depth"
        raw_mgr[$found_idx]="$f_manager"
      else
        raw_round[$found_idx]=$(( raw_round[$found_idx] + 1 ))
        if [[ -n "$f_parent" && -z "${raw_parent[$found_idx]}" ]]; then
          raw_parent[$found_idx]="$f_parent"
        fi
        if [[ -n "$f_manager" && -z "${raw_mgr[$found_idx]}" ]]; then
          raw_mgr[$found_idx]="$f_manager"
        fi
        if (( f_started >= raw_started[$found_idx] )); then
          raw_started[$found_idx]="$f_started"
          raw_finished[$found_idx]="$f_finished"
          raw_plan[$found_idx]="$f_plan"
          raw_state[$found_idx]="$f_state"
          raw_pids[$found_idx]="$f_pid"
          raw_engine[$found_idx]="$f_engine"
          raw_model[$found_idx]="$f_model"
          raw_tok[$found_idx]="$f_tok"
          raw_worktree[$found_idx]="$f_worktree"
          [[ -z "$f_role" ]] || raw_role[$found_idx]="$f_role"
          [[ -z "$f_parent" ]] || raw_parent[$found_idx]="$f_parent"
          [[ -z "$f_depth" ]] || raw_depth[$found_idx]="$f_depth"
          [[ -z "$f_manager" ]] || raw_mgr[$found_idx]="$f_manager"
        fi
      fi
    done
  fi

  # Read raw history to infer MANAGER_ID from sender frequency
  local history_raw
  history_raw="$(read_history "$WS_ROOT" "$since")"
  local regex="^[[:space:]*]*\\[([^]]+)\\][[:space:]]+([^[:space:]]+)[[:space:]]*->[[:space:]]*([^:]+):[[:space:]]*(.*)$"
  local sender_names=()
  local sender_counts=()
  local raw_line
  while IFS= read -r raw_line; do
    [[ -n "$raw_line" ]] || continue
    if [[ "$raw_line" =~ $regex ]]; then
      local h_from="${BASH_REMATCH[2]}"
      local from_is_worker=0
      local wi=0
      while (( wi < ${#raw_worker[@]} )); do
        if [[ "${raw_worker[$wi]}" == "$h_from" ]]; then
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
    fi
  done <<< "$history_raw"

  local best_sender="" best_cnt=0 s_i=0 s_cnt="${#sender_names[@]}"
  while (( s_i < s_cnt )); do
    if (( sender_counts[$s_i] > best_cnt )); then
      best_cnt="${sender_counts[$s_i]}"
      best_sender="${sender_names[$s_i]}"
    fi
    s_i=$(( s_i + 1 ))
  done
  INFERRED_MANAGER_ID="${best_sender:-manager}"

  local VIEW_MANAGER_ID="${SQUAD_MANAGER_ID:-}"
  if [[ -z "$VIEW_MANAGER_ID" ]]; then
    VIEW_MANAGER_ID="$INFERRED_MANAGER_ID"
  fi
  MANAGER_ID="$VIEW_MANAGER_ID"

  # Resolve manager and visibility for each raw worker
  local raw_cnt="${#raw_worker[@]}"
  local raw_eff_mgr=()
  local raw_shown=()
  local ri=0
  while (( ri < raw_cnt )); do
    local cur_idx="$ri"
    local visited=0
    while [[ -n "${raw_parent[$cur_idx]:-}" ]] && (( visited < raw_cnt )); do
      local p_name="${raw_parent[$cur_idx]}"
      local p_found=-1
      local pj=0
      while (( pj < raw_cnt )); do
        if [[ "${raw_worker[$pj]}" == "$p_name" ]]; then
          p_found="$pj"
          break
        fi
        pj=$(( pj + 1 ))
      done
      if (( p_found < 0 )); then
        break
      fi
      cur_idx="$p_found"
      visited=$(( visited + 1 ))
    done

    local eff_m=""
    if [[ -n "${raw_mgr[$cur_idx]:-}" ]]; then
      eff_m="${raw_mgr[$cur_idx]}"
    elif [[ -n "${raw_mgr[$ri]:-}" ]]; then
      eff_m="${raw_mgr[$ri]}"
    fi
    raw_eff_mgr[$ri]="$eff_m"

    local is_shown=0
    if (( all_managers == 1 )); then
      is_shown=1
    else
      if [[ "$eff_m" == "$VIEW_MANAGER_ID" ]]; then
        is_shown=1
      elif [[ -z "$eff_m" && -z "${SQUAD_MANAGER_ID:-}" ]]; then
        # Legacy status files (no manager=) are hidden once the manager id is known.
        is_shown=1
      fi
    fi
    raw_shown[$ri]="$is_shown"
    ri=$(( ri + 1 ))
  done

  # Populate W_* with shown workers
  local final_pids=()
  ri=0
  while (( ri < raw_cnt )); do
    if (( raw_shown[ri] == 1 )); then
      local w_idx="${#W_NAME[@]}"
      W_NAME[$w_idx]="${raw_worker[$ri]}"
      W_STARTED[$w_idx]="${raw_started[$ri]}"
      W_FINISHED[$w_idx]="${raw_finished[$ri]}"
      W_PLAN_NAME[$w_idx]="${raw_plan[$ri]}"
      W_STATE[$w_idx]="${raw_state[$ri]}"
      final_pids[$w_idx]="${raw_pids[$ri]}"
      W_ENGINE[$w_idx]="${raw_engine[$ri]}"
      W_MODEL[$w_idx]="${raw_model[$ri]}"
      W_TOK[$w_idx]="${raw_tok[$ri]}"
      W_WORKTREE[$w_idx]="${raw_worktree[$ri]}"
      W_ROLE[$w_idx]="${raw_role[$ri]}"
      W_PARENT[$w_idx]="${raw_parent[$ri]}"
      W_DEPTH[$w_idx]="${raw_depth[$ri]}"
      W_ROUND[$w_idx]="${raw_round[$ri]}"
      local assigned_m="${raw_eff_mgr[$ri]}"
      if [[ -z "$assigned_m" ]]; then
        if (( all_managers == 1 )); then
          assigned_m="$INFERRED_MANAGER_ID"
        else
          assigned_m="$VIEW_MANAGER_ID"
        fi
      fi
      W_MGR[$w_idx]="$assigned_m"
    fi
    ri=$(( ri + 1 ))
  done
  TOTAL_WORKERS="${#W_NAME[@]}"

  # Finalize worker fields and aggregate counts
  local wi=0
  while (( wi < TOTAL_WORKERS )); do
    local st="${W_STATE[$wi]}"
    local pid="${final_pids[$wi]}"
    if [[ "$st" == "running" ]]; then
      if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
        st="lost"
      fi
    fi
    W_STATE[$wi]="$st"

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
    W_MSG_RECENT[$wi]=0

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

  # Parse history into H_* and match against workers
  local tail_idx=-1 tail_lines=0
  while IFS= read -r raw_line; do
    [[ -n "$raw_line" ]] || continue
    if [[ ! "$raw_line" =~ $regex ]]; then
      # Continuation line of a multi-line message: keep the first few for previews.
      if (( tail_idx >= 0 && tail_lines < 12 )); then
        H_TAIL[$tail_idx]+="${raw_line}"$'\n'
        tail_lines=$(( tail_lines + 1 ))
      fi
      continue
    fi
    tail_idx=-1
    tail_lines=0
    if [[ "$raw_line" =~ $regex ]]; then
      local h_ts="${BASH_REMATCH[1]}"
      local h_from="${BASH_REMATCH[2]}"
      local h_to="${BASH_REMATCH[3]}"
      local h_body="${BASH_REMATCH[4]}"
      classify_msg "$h_body"
      local h_type="$REPLY"

      local keep_msg=1
      if (( all_managers == 0 )); then
        keep_msg=0
        if [[ "$h_from" == "$VIEW_MANAGER_ID" || "$h_to" == "$VIEW_MANAGER_ID" ]]; then
          keep_msg=1
        else
          local chk_w=0
          while (( chk_w < TOTAL_WORKERS )); do
            if [[ "${W_NAME[$chk_w]}" == "$h_from" || "${W_NAME[$chk_w]}" == "$h_to" ]]; then
              keep_msg=1
              break
            fi
            chk_w=$(( chk_w + 1 ))
          done
        fi
      fi

      if (( keep_msg == 1 )); then
        local h_idx="${#H_TS[@]}"
        H_TS[$h_idx]="$h_ts"
        H_FROM[$h_idx]="$h_from"
        H_TO[$h_idx]="$h_to"
        H_TYPE[$h_idx]="$h_type"
        H_BODY[$h_idx]="$h_body"
        H_TAIL[$h_idx]=""
        tail_idx="$h_idx"
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
            [[ "$other" == "$wp" ]] || match_edge=0
          else
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
              else
                W_ASKING[$wi]=0
              fi
            elif [[ "$h_to" == "$wn" && "$h_type" == "ANSWER" ]]; then
              W_ASKING[$wi]=0
            fi
          fi
        fi
        wi=$(( wi + 1 ))
      done
    fi
  done <<< "$history_raw"

  # Finalize worker edge info (Bug fix: terminal states show done/failed)
  wi=0
  while (( wi < TOTAL_WORKERS )); do
    local mtype="${W_LAST_TYPE[$wi]}"
    case "${W_STATE[$wi]}" in
      completed)   mtype="done" ;;
      failed|lost) mtype="failed" ;;
      *)
        if [[ -z "$mtype" ]]; then
          mtype="brief"
        fi
        ;;
    esac
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
      P_ACTIVE[$p_found]=0
      P_LAST_TS[$p_found]=0
      P_DONE_CNT[$p_found]=0
      P_FAIL_CNT[$p_found]=0
      P_TOT_CNT[$p_found]=0
    fi

    P_TOT_CNT[$p_found]=$(( P_TOT_CNT[$p_found] + 1 ))
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

  # Build MANAGERS_LIST
  MANAGERS_LIST=()
  if (( all_managers == 0 )); then
    MANAGERS_LIST=("$VIEW_MANAGER_ID")
  else
    local m_act=()
    wi=0
    while (( wi < TOTAL_WORKERS )); do
      local wm="${W_MGR[$wi]}"
      [[ -n "$wm" ]] || wm="$INFERRED_MANAGER_ID"
      local m_idx=-1
      local mi=0
      while (( mi < ${#MANAGERS_LIST[@]} )); do
        if [[ "${MANAGERS_LIST[$mi]}" == "$wm" ]]; then
          m_idx="$mi"
          break
        fi
        mi=$(( mi + 1 ))
      done
      local w_act="${W_STARTED[$wi]}"
      if [[ -n "${W_FINISHED[$wi]}" && "${W_FINISHED[$wi]}" =~ ^[0-9]+$ ]]; then
        (( W_FINISHED[wi] > w_act )) && w_act="${W_FINISHED[$wi]}"
      fi
      if (( m_idx < 0 )); then
        m_idx="${#MANAGERS_LIST[@]}"
        MANAGERS_LIST[$m_idx]="$wm"
        m_act[$m_idx]="$w_act"
      else
        if (( w_act > m_act[m_idx] )); then
          m_act[$m_idx]="$w_act"
        fi
      fi
      wi=$(( wi + 1 ))
    done
    local m_cnt="${#MANAGERS_LIST[@]}"
    local mi=1
    while (( mi < m_cnt )); do
      local key_m="${MANAGERS_LIST[$mi]}"
      local key_a="${m_act[$mi]}"
      local mj=$(( mi - 1 ))
      while (( mj >= 0 )); do
        if (( key_a > m_act[mj] )); then
          MANAGERS_LIST[$(( mj + 1 ))]="${MANAGERS_LIST[$mj]}"
          m_act[$(( mj + 1 ))]="${m_act[$mj]}"
          mj=$(( mj - 1 ))
        else
          break
        fi
      done
      MANAGERS_LIST[$(( mj + 1 ))]="$key_m"
      m_act[$(( mj + 1 ))]="$key_a"
      mi=$(( mi + 1 ))
    done
    if (( ${#MANAGERS_LIST[@]} == 0 )); then
      MANAGERS_LIST=("$INFERRED_MANAGER_ID")
    fi
  fi

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

format_collapsed_plan_line() {
  local pi="$1" columns="$2"
  local age=$(( DATA_NOW - P_LAST_TS[pi] ))
  fmt_elapsed "$age"
  local age_str="$REPLY"
  local plain="▸ Plan ${P_NAME[$pi]} · ✓${P_DONE_CNT[$pi]} ✗${P_FAIL_CNT[$pi]} · last ${age_str} ago"
  trunc_str "$plain" "$columns"
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
    trunc_str "$REPLY" 34
    (( ${#REPLY} > max_em_len )) && max_em_len="${#REPLY}"
    wi=$(( wi + 1 ))
  done

  local m_i=0 m_tot="${#MANAGERS_LIST[@]}"
  while (( m_i < m_tot )); do
    local cur_mgr="${MANAGERS_LIST[$m_i]}"
    local plan_list=()
    local raw_p_cnt="${#P_ORDER[@]}"
    local r_i=0
    while (( r_i < raw_p_cnt )); do
      local cand_pi="${P_ORDER[$r_i]}"
      local has_nodes=0
      local wi=0
      while (( wi < TOTAL_WORKERS )); do
        local wm="${W_MGR[$wi]}"
        [[ -n "$wm" ]] || wm="$INFERRED_MANAGER_ID"
        if [[ "$wm" == "$cur_mgr" && "${W_PLAN_NAME[$wi]}" == "${P_NAME[$cand_pi]}" ]]; then
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
        local wm="${W_MGR[$wi]}"
        [[ -n "$wm" ]] || wm="$INFERRED_MANAGER_ID"
        if [[ "$wm" == "$cur_mgr" && "${W_PLAN_NAME[$wi]}" == "${P_NAME[$pi]}" ]]; then
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
      (( max_d1_show <= 4 )) || max_d1_show=4

      # Build ordered list of (worker_idx, rel_depth, is_last_in_group) for display
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
            local wm="${W_MGR[$wi]}"
            [[ -n "$wm" ]] || wm="$INFERRED_MANAGER_ID"
            if [[ "$wm" == "$cur_mgr" && "${W_PARENT[$wi]}" == "${W_NAME[$w_top]}" ]]; then
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

      local plan_line="Plan ${P_NAME[$pi]}"
      (( ${#plan_line} <= columns )) || plan_line="${plan_line:0:$columns}"
      DIAG_T0+="${plan_line}"$'\n'
      DIAG_LINE_COUNT=$(( DIAG_LINE_COUNT + 1 ))

      local tree_root_id="$cur_mgr"
      [[ -n "$zoom_target" && "$cur_mgr" == "$zoom_target" ]] && tree_root_id="$zoom_target"
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
        pad_str "${W_NAME[$w]}" $(( max_w_len + 2 ))
      fi
      local worker_col="$REPLY"

      fmt_eng_mod "${W_ENGINE[$w]}" "${W_MODEL[$w]}"
      trunc_str "$REPLY" 34
      pad_str "$REPLY" $(( max_em_len + 2 ))
      local eng_mod_col="$REPLY"

      local eff_state="${W_STATE[$w]}"
      if (( r_depth == 1 && W_KIDS_RUNNING[w] > 0 )); then
        eff_state="running"
      fi

      local state_plain state_disp state_color=""
      case "$eff_state" in
        running)
          state_plain="⠋ running  "
          state_disp="@@SPIN@@ running  "
          state_color="$c_running"
          ;;
        completed)
          state_plain="✓ completed "
          state_disp="$state_plain"
          state_color="$c_completed"
          ;;
        failed)
          state_plain="✗ failed   "
          state_disp="$state_plain"
          state_color="$c_failed"
          ;;
        stopped)
          state_plain="⏸ stopped  "
          state_disp="$state_plain"
          state_color="$c_stopped"
          ;;
        lost)
          state_plain="? lost     "
          state_disp="$state_plain"
          state_color="$c_failed"
          ;;
        *)
          pad_str "$eff_state" 11
          state_plain="$REPLY"
          state_disp="$REPLY"
          state_color=""
          ;;
      esac

      fmt_elapsed "${W_ELAPSED[$w]}"
      local elapsed_text="$REPLY"
      local tail_part="$elapsed_text"
      local disp_tok="${W_TOK[$w]}"
      if (( r_depth == 1 && W_BRANCH_TOK[w] > disp_tok )); then
        disp_tok="${W_BRANCH_TOK[$w]}"
      fi
      if (( disp_tok > 0 )); then
        fmt_human_count "$disp_tok"
        local tok_text="${REPLY} tok"
        if (( W_ROUND[w] > 1 )); then
          tail_part="${elapsed_text}  ${tok_text}  round ${W_ROUND[$w]}"
        else
          tail_part="${elapsed_text}  ${tok_text}"
        fi
      elif (( W_ROUND[w] > 1 )); then
        tail_part="${elapsed_text}  round ${W_ROUND[$w]}"
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
      local r_done=0 r_fail=0
      while (( idx < pw_cnt )); do
        local rw="${pw[$idx]}"
        case "${W_STATE[$rw]}" in
          completed)   r_done=$(( r_done + 1 )) ;;
          failed|lost) r_fail=$(( r_fail + 1 )) ;;
        esac
        idx=$(( idx + 1 ))
      done
      local sum_plain="   +${rest_cnt} earlier · ✓${r_done} ✗${r_fail}"
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
  m_i=$(( m_i + 1 ))
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

  local gutter_w=5
  if [[ -n "$zoom_target" ]]; then
    gutter_w=0
  fi
  local eff_columns=$(( columns - gutter_w ))
  (( eff_columns >= 15 )) || eff_columns=15

  local inner_w=16 content_w=14
  if (( columns <= 60 )); then
    inner_w=12
    content_w=11
  fi
  local box_w=$(( inner_w + 2 ))
  local half_box=$(( box_w / 2 ))
  local gap=2
  if (( eff_columns < 4 * box_w + 3 * gap && eff_columns >= 4 * box_w + 3 * 1 )); then
    gap=1
  fi
  local per_row=$(( (eff_columns + gap) / (box_w + gap) ))
  (( per_row >= 1 )) || per_row=1
  (( per_row <= 4 )) || per_row=4

  local full_bars="${DASHES_PAD:0:$inner_w}"
  local left_bars="${DASHES_PAD:0:$(( half_box - 1 ))}"
  local right_bars="${DASHES_PAD:0:$(( inner_w - half_box ))}"
  local d_full_bars="${DOUBLE_DASHES_PAD:0:$inner_w}"
  local d_left_bars="${DOUBLE_DASHES_PAD:0:$(( half_box - 1 ))}"
  local d_right_bars="${DOUBLE_DASHES_PAD:0:$(( inner_w - half_box ))}"

  local m_i=0 m_tot="${#MANAGERS_LIST[@]}"
  while (( m_i < m_tot )); do
    local cur_mgr="${MANAGERS_LIST[$m_i]}"
    local plan_list=()
    local raw_p_cnt="${#P_ORDER[@]}"
    local r_i=0
    while (( r_i < raw_p_cnt )); do
      local cand_pi="${P_ORDER[$r_i]}"
      local has_nodes=0
      local wi=0
      while (( wi < TOTAL_WORKERS )); do
        local wm="${W_MGR[$wi]}"
        [[ -n "$wm" ]] || wm="$INFERRED_MANAGER_ID"
        if [[ "$wm" == "$cur_mgr" && "${W_PLAN_NAME[$wi]}" == "${P_NAME[$cand_pi]}" ]]; then
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

    # Calculate height needed for expanded plans
    local exp_heights=()
    local rank=0
    while (( rank < p_cnt )); do
      local pi="${plan_list[$rank]}"
      local cnt=0 wi=0
      while (( wi < TOTAL_WORKERS )); do
        local wm="${W_MGR[$wi]}"
        [[ -n "$wm" ]] || wm="$INFERRED_MANAGER_ID"
        if [[ "$wm" == "$cur_mgr" && "${W_PLAN_NAME[$wi]}" == "${P_NAME[$pi]}" ]]; then
          if [[ -n "$zoom_target" ]]; then
            [[ "${W_PARENT[$wi]}" == "$zoom_target" ]] && cnt=$(( cnt + 1 ))
          elif [[ -z "${W_PARENT[$wi]}" ]]; then
            cnt=$(( cnt + 1 ))
          fi
        fi
        wi=$(( wi + 1 ))
      done
      if (( cnt > per_row )); then
        exp_heights[$rank]=13
      else
        exp_heights[$rank]=12
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
      if (( needed1 > diag_budget && diag_budget < 12 )); then
        num_expanded=0
      fi
    fi

    # Exactly ONE top manager box for cur_mgr
    local top_box_label="$cur_mgr"
    if [[ -n "$zoom_target" ]]; then
      top_box_label="$zoom_target"
    elif [[ -n "${SQUAD_DEVKIT_MANAGER_CLIENT:-}" ]]; then
      top_box_label="${cur_mgr} · ${SQUAD_DEVKIT_MANAGER_CLIENT}"
    fi

    local mgr_inner_w="$inner_w"
    (( ${#top_box_label} + 2 > mgr_inner_w )) && mgr_inner_w=$(( ${#top_box_label} + 2 ))
    (( mgr_inner_w > columns - 4 )) && mgr_inner_w=$(( columns - 4 ))
    center_str "$top_box_label" "$mgr_inner_w"
    local mgr_cell="$REPLY"

    local mgr_dashes="${DASHES_PAD:0:$(( mgr_inner_w - 1 ))}"
    local mgr_full="${DASHES_PAD:0:$mgr_inner_w}"
    local d_mgr_dashes="${DOUBLE_DASHES_PAD:0:$(( mgr_inner_w - 1 ))}"
    local d_mgr_full="${DOUBLE_DASHES_PAD:0:$mgr_inner_w}"

    local mgr_top mgr_mid mgr_bot
    if [[ -n "$zoom_target" ]]; then
      if [[ -n "$c_manager" ]]; then
        mgr_top=" ${c_manager}╔${d_mgr_full}╗${reset}"
        mgr_mid=" ${c_manager}║${mgr_cell}║${reset}"
        if (( p_cnt > 0 )); then
          mgr_bot=" ${c_manager}╚╦${d_mgr_dashes}╝${reset}"
        else
          mgr_bot=" ${c_manager}╚${d_mgr_full}╝${reset}"
        fi
      else
        mgr_top=" ╔${d_mgr_full}╗"
        mgr_mid=" ║${mgr_cell}║"
        if (( p_cnt > 0 )); then
          mgr_bot=" ╚╦${d_mgr_dashes}╝"
        else
          mgr_bot=" ╚${d_mgr_full}╝"
        fi
      fi
    else
      if [[ -n "$c_manager" ]]; then
        mgr_top=" ${c_manager}┌${mgr_full}┐${reset}"
        mgr_mid=" ${c_manager}│${mgr_cell}│${reset}"
        if (( p_cnt > 0 )); then
          mgr_bot=" ${c_manager}└┬${mgr_dashes}┘${reset}"
        else
          mgr_bot=" ${c_manager}└${mgr_full}┘${reset}"
        fi
      else
        mgr_top=" ┌${mgr_full}┐"
        mgr_mid=" │${mgr_cell}│"
        if (( p_cnt > 0 )); then
          mgr_bot=" └┬${mgr_dashes}┘"
        else
          mgr_bot=" └${mgr_full}┘"
        fi
      fi
    fi

    local mgr_box="${mgr_top}"$'\n'"${mgr_mid}"$'\n'"${mgr_bot}"$'\n'
    DIAG_T0+="$mgr_box"
    DIAG_T1+="$mgr_box"
    DIAG_T2+="$mgr_box"
    DIAG_T3+="$mgr_box"
    DIAG_LINE_COUNT=$(( DIAG_LINE_COUNT + 3 ))

    if (( p_cnt > 0 )); then
      local trunk_line="  │"$'\n'
      DIAG_T0+="$trunk_line"
      DIAG_T1+="$trunk_line"
      DIAG_T2+="$trunk_line"
      DIAG_T3+="$trunk_line"
      DIAG_LINE_COUNT=$(( DIAG_LINE_COUNT + 1 ))
    fi

    rank=0
    while (( rank < p_cnt )); do
      local pi="${plan_list[$rank]}"
      local is_last_plan=0
      (( rank == p_cnt - 1 )) && is_last_plan=1

      if (( rank >= num_expanded )); then
        format_collapsed_plan_line "$pi" "$(( columns - 5 ))"
        local col_line
        if (( is_last_plan == 1 )); then
          col_line="  └─ ${REPLY}"$'\n'
        else
          col_line="  ├─ ${REPLY}"$'\n'
        fi
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
      wi=0
      while (( wi < TOTAL_WORKERS )); do
        local wm="${W_MGR[$wi]}"
        [[ -n "$wm" ]] || wm="$INFERRED_MANAGER_ID"
        if [[ "$wm" == "$cur_mgr" && "${W_PLAN_NAME[$wi]}" == "${P_NAME[$pi]}" ]]; then
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

      local eff_row_cnt="$row_cnt"
      (( eff_row_cnt >= 1 )) || eff_row_cnt=1

      # Group node geometry
      local span=$(( eff_row_cnt * box_w + (eff_row_cnt - 1) * gap ))
      local done="${P_DONE_CNT[$pi]:-0}"
      local tot="${P_TOT_CNT[$pi]:-0}"
      local fail="${P_FAIL_CNT[$pi]:-0}"
      local g_text="▸ ${P_NAME[$pi]}  ${done}/${tot} ✓"
      (( fail > 0 )) && g_text+=" ✗${fail}"

      local M L_g R_g inner_gw gw top_bars disp_gtext pad_gw
      local pref_top pref_mid pref_bot g_top g_mid g_bot_static g_bot_dot

      if [[ -n "$zoom_target" ]]; then
        local mgr_L=$(( (span - box_w) / 2 ))
        (( mgr_L >= 0 )) || mgr_L=0
        if (( mgr_L + box_w > columns )); then
          mgr_L=$(( columns - box_w ))
        fi
        M=$(( mgr_L + half_box ))
        (( M >= 6 )) || M=6

        L_g=5
        if (( is_last_plan == 1 )); then
          pref_top="  └─ "
          pref_mid="     "
          pref_bot="     "
        else
          pref_top="  ├─ "
          pref_mid="  │  "
          pref_bot="  │  "
        fi

        local min_gw=$(( ${#g_text} + 4 ))
        R_g=$(( L_g + min_gw - 1 ))
        (( R_g < M + 2 )) && R_g=$(( M + 2 ))
        local sym_R=$(( 2 * M - L_g ))
        (( sym_R > R_g && sym_R <= columns - 2 )) && R_g="$sym_R"
        (( R_g > columns - 2 )) && R_g=$(( columns - 2 ))
        (( R_g > L_g + 3 )) || R_g=$(( L_g + 3 ))

        inner_gw=$(( R_g - L_g - 1 ))
        top_bars="${DASHES_PAD:0:$inner_gw}"
        g_top="${pref_top}╭${top_bars}╮"

        local content_gw=$(( inner_gw - 2 ))
        disp_gtext="$g_text"
        if (( ${#disp_gtext} > content_gw )); then
          trunc_str "$disp_gtext" "$content_gw"
          disp_gtext="$REPLY"
        fi
        pad_gw=$(( content_gw - ${#disp_gtext} ))
        (( pad_gw >= 0 )) || pad_gw=0
        g_mid="${pref_mid}│ ${disp_gtext}${SPACES_PAD:0:$pad_gw} │"

        if (( row_cnt > 0 )); then
          local b_left_len=$(( M - L_g - 1 ))
          local b_right_len=$(( R_g - M - 1 ))
          local b_left="${DASHES_PAD:0:$b_left_len}"
          local b_right="${DASHES_PAD:0:$b_right_len}"
          g_bot_static="${pref_bot}╰${b_left}┬${b_right}╯"
          g_bot_dot="${pref_bot}╰${b_left}${c_running_bright}●${reset}${b_right}╯"
        else
          g_bot_static="${pref_bot}╰${top_bars}╯"
          g_bot_dot="$g_bot_static"
        fi
      else
        M=$(( gutter_w + span / 2 ))

        gw=$(( ${#g_text} + 4 ))
        (( gw < 24 )) && gw=24
        if (( gw > columns - gutter_w - 2 )); then
          gw=$(( columns - gutter_w - 2 ))
        fi
        (( gw >= 14 )) || gw=14

        local b_left_len=$(( (gw - 3) / 2 ))
        local b_right_len=$(( gw - 3 - b_left_len ))
        L_g=$(( M - 1 - b_left_len ))
        if (( L_g < gutter_w )); then
          L_g="$gutter_w"
          b_left_len=$(( M - L_g - 1 ))
          (( b_left_len >= 0 )) || b_left_len=0
          b_right_len=$(( gw - 3 - b_left_len ))
        fi
        R_g=$(( L_g + gw - 1 ))
        if (( R_g > columns - 2 )); then
          R_g=$(( columns - 2 ))
          gw=$(( R_g - L_g + 1 ))
          b_right_len=$(( R_g - M - 1 ))
          (( b_right_len >= 0 )) || b_right_len=0
        fi

        local ext_len=$(( L_g - gutter_w ))
        (( ext_len >= 0 )) || ext_len=0
        local ext_dashes="${DASHES_PAD:0:$ext_len}"
        local ext_spaces="${SPACES_PAD:0:$ext_len}"

        if (( is_last_plan == 1 )); then
          pref_top="  └─${ext_dashes} "
          pref_mid="     ${ext_spaces}"
          pref_bot="     ${ext_spaces}"
        else
          pref_top="  ├─${ext_dashes} "
          pref_mid="  │  ${ext_spaces}"
          pref_bot="  │  ${ext_spaces}"
        fi

        inner_gw=$(( gw - 2 ))
        top_bars="${DASHES_PAD:0:$inner_gw}"
        g_top="${pref_top}╭${top_bars}╮"

        local content_gw=$(( inner_gw - 2 ))
        disp_gtext="$g_text"
        if (( ${#disp_gtext} > content_gw )); then
          trunc_str "$disp_gtext" "$content_gw"
          disp_gtext="$REPLY"
        fi
        pad_gw=$(( content_gw - ${#disp_gtext} ))
        (( pad_gw >= 0 )) || pad_gw=0
        g_mid="${pref_mid}│ ${disp_gtext}${SPACES_PAD:0:$pad_gw} │"

        if (( row_cnt > 0 )); then
          local b_left="${DASHES_PAD:0:$b_left_len}"
          local b_right="${DASHES_PAD:0:$b_right_len}"
          g_bot_static="${pref_bot}╰${b_left}┬${b_right}╯"
          g_bot_dot="${pref_bot}╰${b_left}${c_running_bright}●${reset}${b_right}╯"
        else
          g_bot_static="${pref_bot}╰${top_bars}╯"
          g_bot_dot="$g_bot_static"
        fi
      fi

      if (( row_cnt == 0 )); then
        local empty_plan="${g_top}"$'\n'"${g_mid}"$'\n'"${g_bot_static}"$'\n'
        DIAG_T0+="$empty_plan"
        DIAG_T1+="$empty_plan"
        DIAG_T2+="$empty_plan"
        DIAG_T3+="$empty_plan"
        DIAG_LINE_COUNT=$(( DIAG_LINE_COUNT + 3 ))
        if (( is_last_plan == 0 )); then
          local t_line="  │"$'\n'
          DIAG_T0+="$t_line"
          DIAG_T1+="$t_line"
          DIAG_T2+="$t_line"
          DIAG_T3+="$t_line"
          DIAG_LINE_COUNT=$(( DIAG_LINE_COUNT + 1 ))
        fi
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
        local L_b=$(( gutter_w + b_idx * (box_w + gap) ))
        local C_b=$(( L_b + half_box ))
        centers[$b_idx]="$C_b"
        if ( [[ "${W_STATE[$w]}" == "running" ]] || (( W_KIDS_RUNNING[w] > 0 )) ) && (( W_ASKING[w] == 0 )); then
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

      local bus_trunk=""
      if (( gutter_w > 0 )); then
        if (( is_last_plan == 1 )); then
          bus_trunk="     "
        else
          bus_trunk="  │  "
        fi
      fi
      local pad_to_bus=$(( min_c - gutter_w ))
      (( pad_to_bus >= 0 )) || pad_to_bus=0
      local bus_pad="${SPACES_PAD:0:$pad_to_bus}"

      local bus_static="${bus_trunk}${bus_pad}"
      local bus_mid_dot="${bus_trunk}${bus_pad}"
      local bus_junc_dot="${bus_trunk}${bus_pad}"

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
      local edge_trunk=""
      local box_trunk=""
      if (( gutter_w > 0 )); then
        if (( is_last_plan == 1 )); then
          edge_trunk="     "
          box_trunk="     "
        else
          edge_trunk="  │  "
          box_trunk="  │  "
        fi
      fi
      local edge_static="$edge_trunk" edge_dot="$edge_trunk"
      local cur_col="$gutter_w"
      local top_row="$box_trunk" l1_row="$box_trunk" l2_row="$box_trunk" l3_row="$box_trunk" l4_row="$box_trunk" bot_row="$box_trunk"

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
        (( b_idx > 0 )) && sep="${SPACES_PAD:0:$gap}"

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
            state_disp="? ${done_k}/${tot_k} kids"
            [[ -n "$c_asking" ]] && box_color="@@ASK_CLR@@"
          elif (( sm_running == 1 )); then
            state_plain="⠋ ${done_k}/${tot_k} kids"
            state_disp="@@SPIN@@ ${done_k}/${tot_k} kids"
            box_color="$c_running"
          else
            case "${W_STATE[$w]}" in
              completed)
                state_plain="✓ ${done_k}/${tot_k} kids"
                state_disp="$state_plain"
                box_color="$c_completed"
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
        elif (( W_ASKING[w] == 1 )); then
          state_plain="? asking"
          state_disp="? asking"
          [[ -n "$c_asking" ]] && box_color="@@ASK_CLR@@"
        else
          case "${W_STATE[$w]}" in
            running)
              state_plain="⠋ running"
              state_disp="@@SPIN@@ running"
              box_color="$c_running"
              ;;
            completed)
              state_plain="✓ completed"
              state_disp="✓ completed"
              box_color="$c_completed"
              ;;
            failed)
              state_plain="✗ failed"
              state_disp="✗ failed"
              box_color="$c_failed"
              ;;
            stopped)
              state_plain="⏸ stopped"
              state_disp="⏸ stopped"
              box_color="$c_stopped"
              ;;
            lost)
              state_plain="? lost"
              state_disp="? lost"
              box_color="$c_failed"
              ;;
            *)
              state_plain="${W_STATE[$w]}"
              state_disp="${W_STATE[$w]}"
              box_color=""
              ;;
          esac
        fi

        fmt_elapsed "${W_ELAPSED[$w]}"
        local elapsed_text="$REPLY"
        local line4_str="$elapsed_text"
        local box_tok="${W_TOK[$w]}"
        (( is_sm_node == 1 )) && box_tok="${W_BRANCH_TOK[$w]}"
        if (( box_tok > 0 && W_ROUND[w] >= 2 )); then
          fmt_human_count "$box_tok"
          local tok_s="$REPLY"
          line4_str="${elapsed_text}  ${tok_s}  r${W_ROUND[$w]}"
          if (( ${#line4_str} > content_w )); then
            line4_str="${elapsed_text} ${tok_s} r${W_ROUND[$w]}"
          fi
        elif (( box_tok > 0 )); then
          fmt_human_count "$box_tok"
          line4_str="${elapsed_text}  ${REPLY}"
        elif (( W_ROUND[w] >= 2 )); then
          line4_str="${elapsed_text}  r${W_ROUND[$w]}"
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

        fmt_short_model "${W_MODEL[$w]}" "$content_w"
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

        if (( is_sm_node == 1 )); then
          if [[ -n "$box_color" ]]; then
            top_row+="${sep}${box_color}╔${d_left_bars}┴${d_right_bars}╗${reset}"
            l1_row+="${sep}${box_color}║${reset}${c1}${box_color}║${reset}"
            l2_row+="${sep}${box_color}║${reset}${c2}${box_color}║${reset}"
            l3_row+="${sep}${box_color}║${c3}│${reset}"
            l3_row="${l3_row%│${reset}}║${reset}"
            l4_row+="${sep}${box_color}║${reset}${c4}${box_color}║${reset}"
            bot_row+="${sep}${box_color}╚${d_full_bars}╝${reset}"
          else
            top_row+="${sep}╔${d_left_bars}┴${d_right_bars}╗"
            l1_row+="${sep}║${c1}║"
            l2_row+="${sep}║${c2}║"
            l3_row+="${sep}║${c3}║"
            l4_row+="${sep}║${c4}║"
            bot_row+="${sep}╚${d_full_bars}╝"
          fi
        elif [[ -n "$box_color" ]]; then
          top_row+="${sep}${box_color}┌${left_bars}┴${right_bars}┐${reset}"
          l1_row+="${sep}${box_color}│${reset}${c1}${box_color}│${reset}"
          l2_row+="${sep}${box_color}│${reset}${c2}${box_color}│${reset}"
          l3_row+="${sep}${box_color}│${c3}│${reset}"
          l4_row+="${sep}${box_color}│${reset}${c4}${box_color}│${reset}"
          bot_row+="${sep}${box_color}└${full_bars}┘${reset}"
        else
          top_row+="${sep}┌${left_bars}┴${right_bars}┐"
          l1_row+="${sep}│${c1}│"
          l2_row+="${sep}│${c2}│"
          l3_row+="${sep}│${c3}│"
          l4_row+="${sep}│${c4}│"
          bot_row+="${sep}└${full_bars}┘"
        fi

        b_idx=$(( b_idx + 1 ))
      done

      local box_block="${top_row}"$'\n'"${l1_row}"$'\n'"${l2_row}"$'\n'"${l3_row}"$'\n'"${l4_row}"$'\n'"${bot_row}"$'\n'
      local gn_top_mid="${g_top}"$'\n'"${g_mid}"$'\n'

      if (( use_anim == 1 && any_running_edge == 1 )); then
        DIAG_T0+="${gn_top_mid}${g_bot_dot}"$'\n'"${bus_static}"$'\n'"${edge_static}"$'\n'"${box_block}"
        DIAG_T1+="${gn_top_mid}${g_bot_static}"$'\n'"${bus_mid_dot}"$'\n'"${edge_static}"$'\n'"${box_block}"
        DIAG_T2+="${gn_top_mid}${g_bot_static}"$'\n'"${bus_junc_dot}"$'\n'"${edge_static}"$'\n'"${box_block}"
        DIAG_T3+="${gn_top_mid}${g_bot_static}"$'\n'"${bus_static}"$'\n'"${edge_dot}"$'\n'"${box_block}"
      else
        local static_plan="${gn_top_mid}${g_bot_static}"$'\n'"${bus_static}"$'\n'"${edge_static}"$'\n'"${box_block}"
        DIAG_T0+="$static_plan"
        DIAG_T1+="$static_plan"
        DIAG_T2+="$static_plan"
        DIAG_T3+="$static_plan"
      fi
      DIAG_LINE_COUNT=$(( DIAG_LINE_COUNT + 11 ))

      if (( rest_cnt > 0 )); then
        local r_done=0 r_fail=0 r_idx="$row_cnt"
        while (( r_idx < pw_cnt )); do
          local rw="${pw[$r_idx]}"
          case "${W_STATE[$rw]}" in
            completed)   r_done=$(( r_done + 1 )) ;;
            failed|lost) r_fail=$(( r_fail + 1 )) ;;
          esac
          r_idx=$(( r_idx + 1 ))
        done
        local sum_plain
        if (( gutter_w > 0 )); then
          if (( is_last_plan == 1 )); then
            sum_plain="     +${rest_cnt} earlier · ✓${r_done} ✗${r_fail}"
          else
            sum_plain="  │  +${rest_cnt} earlier · ✓${r_done} ✗${r_fail}"
          fi
        else
          sum_plain="  +${rest_cnt} earlier · ✓${r_done} ✗${r_fail}"
        fi
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

      if (( is_last_plan == 0 )); then
        local t_line="  │"$'\n'
        DIAG_T0+="$t_line"
        DIAG_T1+="$t_line"
        DIAG_T2+="$t_line"
        DIAG_T3+="$t_line"
        DIAG_LINE_COUNT=$(( DIAG_LINE_COUNT + 1 ))
      fi

      rank=$(( rank + 1 ))
    done

    if (( m_i < m_tot - 1 )); then
      DIAG_T0+=$'\n'
      DIAG_T1+=$'\n'
      DIAG_T2+=$'\n'
      DIAG_T3+=$'\n'
      DIAG_LINE_COUNT=$(( DIAG_LINE_COUNT + 1 ))
    fi
    m_i=$(( m_i + 1 ))
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
      if [[ -n "${W_WORKTREE[$w]}" && -d "${W_WORKTREE[$w]}" ]]; then
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

    local state_plain state_color="" is_spin=0
    case "${W_STATE[$w]}" in
      running)   state_plain="⠋ running";   state_color="$c_running";   is_spin=1 ;;
      completed) state_plain="✓ completed"; state_color="$c_completed" ;;
      failed)    state_plain="✗ failed";    state_color="$c_failed" ;;
      stopped)   state_plain="⏸ stopped";   state_color="$c_stopped" ;;
      lost)      state_plain="? lost";      state_color="$c_failed" ;;
      *)         state_plain="${W_STATE[$w]}"; state_color="" ;;
    esac

    fmt_elapsed "${W_ELAPSED[$w]}"
    local raw_l2="${state_plain}  ${REPLY}"

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

  DIAG_T1="$DIAG_T0"
  DIAG_T2="$DIAG_T0"
  DIAG_T3="$DIAG_T0"
}

# ---------------------------------------------------------------------------
# Lifecycle flow chart (graph layout): numbered stage nodes, labelled edges,
# "Waiting on you" group, outcomes, conversation notes, history line, footer.
# ---------------------------------------------------------------------------
LC_NODE_W=18
LC_EDGE_W=9
LC_LANE_PLAN=""
LC_SHOWN_PLANS=""
LANE_BLOCK=""
LANE_LINES=0

fmt_elapsed_short() {
  local s="${1:-0}"
  (( s >= 0 )) || s=0
  if (( s < 60 )); then
    REPLY="${s}s"
  elif (( s < 3600 )); then
    REPLY="$(( s / 60 ))m"
  else
    printf -v REPLY '%dh%02dm' $(( s / 3600 )) $(( s % 3600 / 60 ))
  fi
}

# Remove UUID-looking tokens and collapse whitespace.
lc_clean_text() {
  local s="$1" uuid_re='[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
  while [[ "$s" =~ $uuid_re ]]; do
    s="${s/${BASH_REMATCH[0]}/}"
  done
  s="${s//$'\t'/ }"
  while [[ "$s" == *"  "* ]]; do
    s="${s//  / }"
  done
  s="${s# }"
  REPLY="${s% }"
}

# First sentence of a message body (keeps a trailing ? or !).
lc_first_sentence() {
  lc_clean_text "${1%%$'\n'*}"
  local s="$REPLY" head sep
  head="${s%%[.?!] *}"
  if [[ "$head" != "$s" ]]; then
    sep="${s:${#head}:1}"
    [[ "$sep" != "." ]] || sep=""
    s="${head}${sep}"
  fi
  REPLY="$s"
}

# Title of a brief: first line after "## Goal", else first non-empty line without leading #.
lc_brief_title() {
  local h_idx="$1" all line stripped text="" want=0 title="" first_head="" first_plain=""
  local goal_re='^[[:space:]]*#+[[:space:]]*[Gg]oal[[:space:]]*:?[[:space:]]+([^[:space:]].*)$'
  all="${H_BODY[$h_idx]}"$'\n'"${H_TAIL[$h_idx]:-}"
  while IFS= read -r line; do
    stripped="${line#"${line%%[![:space:]]*}"}"
    [[ -n "$stripped" ]] || continue
    if [[ "$stripped" == "#"* ]]; then
      if [[ "$line" =~ $goal_re ]]; then
        title="${BASH_REMATCH[1]}"
        break
      fi
      text="${stripped#"${stripped%%[![:space:]#]*}"}"
      case "$text" in
        [Gg]oal|[Gg]oal:) want=1; continue ;;
        ""|Selection*|"Files you own"*|"Shared plan"*|Plan|Rules|Verification*) continue ;;
      esac
      [[ -n "$first_head" ]] || first_head="$text"
      continue
    fi
    case "$stripped" in
      [Gg]oal|[Gg]oal:) want=1; continue ;;
      Selection:*|"Files you own"*) continue ;;
    esac
    if (( want == 1 )); then
      lc_first_sentence "$stripped"
      title="$REPLY"
      break
    fi
    [[ -n "$first_plain" ]] || first_plain="$stripped"
  done <<< "$all"
  [[ -n "$title" ]] || title="${first_head:-$first_plain}"
  lc_clean_text "$title"
}

# Set LC_BOX0..LC_BOX4 (each LC_NODE_W columns wide).
# args: line1 line2 line3 border_colour line1_colour line3_colour
lc_box() {
  local bars="${DASHES_PAD:0:16}" bc="$4" c1="$5" c3="$6" cell
  LC_BOX0="${bc}╭${bars}╮${reset}"
  LC_BOX4="${bc}╰${bars}╯${reset}"
  box_cell "$1" 16 14
  LC_BOX1="${bc}│${reset}${c1}${REPLY}${reset}${bc}│${reset}"
  box_cell "$2" 16 14
  LC_BOX2="${bc}│${reset}${dim}${REPLY}${reset}${bc}│${reset}"
  box_cell "$3" 16 14
  cell="$REPLY"
  if [[ "$3" == "●"* ]] && (( use_anim == 1 )) && [[ "$6" == "$c_running" ]]; then
    cell="${cell/●/@@SPIN@@}"
  fi
  LC_BOX3="${bc}│${reset}${c3}${cell}${reset}${bc}│${reset}"
}

# Set LC_EDGE (LC_EDGE_W columns) for a verb label.
lc_edge() {
  local label="$1" col=""
  local fill=$(( LC_EDGE_W - 2 - ${#label} ))
  (( fill >= 1 )) || fill=1
  case "$label" in
    brief|fix) col="$c_brief" ;;
    ask)       col="$c_question" ;;
    answer)    col="$c_answer" ;;
    done)      col="$c_done" ;;
    failed)    col="$c_failed" ;;
  esac
  LC_EDGE="${col}─${label}${DASHES_PAD:0:$fill}▶${reset}"
}

# Chip text and colour for worker index $1 -> LC_CHIP, LC_CHIP_COL.
lc_chip() {
  local wi="$1" ask_col="$c_asking"
  (( use_color == 0 )) || ask_col="@@ASK_CLR@@"
  case "${W_STATE[$wi]}" in
    running)
      if (( W_ASKING[wi] == 1 )); then
        LC_CHIP="? waiting"; LC_CHIP_COL="$ask_col"
      else
        fmt_elapsed_short "${W_ELAPSED[$wi]}"
        LC_CHIP="● running ${REPLY}"; LC_CHIP_COL="$c_running"
      fi
      ;;
    completed) LC_CHIP="✓ done";    LC_CHIP_COL="$c_completed" ;;
    failed)    LC_CHIP="✗ failed";  LC_CHIP_COL="$c_failed" ;;
    lost)      LC_CHIP="✗ lost";    LC_CHIP_COL="$c_failed" ;;
    stopped)   LC_CHIP="⏸ stopped"; LC_CHIP_COL="$c_stopped" ;;
    *)         LC_CHIP="${W_STATE[$wi]:-?}"; LC_CHIP_COL="$c_stopped" ;;
  esac
}

lc_edge_label() {
  local wi="$1"
  case "${W_EDGE_TYPE[$wi]}" in
    ANSWER)   REPLY="answer" ;;
    QUESTION) REPLY="ask" ;;
    done)
      # A running worker whose last message is "done" has been re-briefed (a fix round).
      if [[ "${W_STATE[$wi]}" == "running" ]]; then REPLY="fix"; else REPLY="done"; fi
      ;;
    failed)   REPLY="failed" ;;
    *)
      if (( W_ROUND[wi] > 1 )); then REPLY="fix"; else REPLY="brief"; fi
      ;;
  esac
}

# Append the lane of manager $1 to LANE_BLOCK / LANE_LINES.
# args: manager row_budget columns show_label
lc_render_lane() {
  local mgr="$1" row_budget="$2" columns="$3" show_label="$4"
  # Fan-out: manager on the left, worker nodes in 1..3 columns on the right. Each column hangs on
  # its own trunk (2 cols of prefix + LC_EDGE_W of edge + LC_NODE_W of node); columns after the
  # first are fed by a rail above the first row. Workers run in parallel: no edge joins two nodes.
  local colw=$(( LC_NODE_W + LC_EDGE_W + 2 )) ne=1
  if (( columns >= 110 )); then
    ne=$(( (columns - LC_NODE_W) / colw ))
    (( ne <= 3 )) || ne=3
    (( columns >= 150 || ne <= 2 )) || ne=2
  fi

  # The manager's most relevant plan (P_ORDER is ranked) that has top-level workers.
  local plan="" pi wi
  for pi in ${P_ORDER[@]+"${P_ORDER[@]}"}; do
    for (( wi = 0; wi < TOTAL_WORKERS; wi++ )); do
      if [[ "${W_MGR[$wi]}" == "$mgr" && -z "${W_PARENT[$wi]}" && "${W_PLAN_NAME[$wi]}" == "${P_NAME[$pi]}" ]]; then
        plan="${P_NAME[$pi]}"
        break 2
      fi
    done
  done
  [[ -n "$plan" ]] || return 0
  LC_SHOWN_PLANS+="|${plan}|"
  [[ -n "$LC_LANE_PLAN" ]] || LC_LANE_PLAN="$plan"

  # Top-level workers of that plan in start order (stable insertion sort).
  local lane=() n=0 k j key
  for (( wi = 0; wi < TOTAL_WORKERS; wi++ )); do
    if [[ "${W_MGR[$wi]}" == "$mgr" && -z "${W_PARENT[$wi]}" && "${W_PLAN_NAME[$wi]}" == "$plan" ]]; then
      lane[$n]="$wi"
      n=$(( n + 1 ))
    fi
  done
  for (( k = 1; k < n; k++ )); do
    key="${lane[$k]}"
    j=$(( k - 1 ))
    while (( j >= 0 )) && (( W_STARTED[${lane[$j]}] > W_STARTED[$key] )); do
      lane[$(( j + 1 ))]="${lane[$j]}"
      j=$(( j - 1 ))
    done
    lane[$(( j + 1 ))]="$key"
  done

  (( ne <= n )) || ne=n
  local rows=$(( (n + ne - 1) / ne )) first_row=0 skipped=0
  (( row_budget >= 1 )) || row_budget=1
  if (( rows > row_budget )); then
    first_row=$(( rows - row_budget ))
    skipped=$(( first_row * ne ))
  fi

  if [[ "$show_label" == 1 ]]; then
    trunc_str "▸ ${mgr} · plan ${plan}" "$columns"
    LANE_BLOCK+="${bold}${REPLY}${reset}"$'\n'
    LANE_LINES=$(( LANE_LINES + 1 ))
  fi
  if (( skipped > 0 )); then
    LANE_BLOCK+="${dim}… ${skipped} earlier${reset}"$'\n'
    LANE_LINES=$(( LANE_LINES + 1 ))
  fi

  local blank="${SPACES_PAD:0:$LC_EDGE_W}" gap="${SPACES_PAD:0:$LC_NODE_W}"
  local cblank="${SPACES_PAD:0:$(( LC_EDGE_W + LC_NODE_W ))}"
  local row c pos rail
  for (( row = first_row; row < rows; row++ )); do
    local L0 L1 L2 L3 L4 kl=() kc=() maxk=0 kk
    if (( row == first_row )); then
      local m_engine="manager"
      if [[ "$mgr" == "$MANAGER_ID" && -n "${SQUAD_DEVKIT_MANAGER_CLIENT:-}" ]]; then
        m_engine="$SQUAD_DEVKIT_MANAGER_CLIENT"
      fi
      lc_box "$mgr" "$m_engine" "◆ manager" "$c_manager" "$c_manager" "$c_manager"
      L0="$LC_BOX0"; L1="$LC_BOX1"; L2="$LC_BOX2"; L3="$LC_BOX3"; L4="$LC_BOX4"
      if (( ne > 1 )); then
        # Rail above the first row: feeds the trunk of every column.
        rail="${gap} ┌"
        for (( c = 1; c < ne; c++ )); do
          rail+="${DASHES_PAD:0:$(( LC_EDGE_W + LC_NODE_W + 1 ))}"
          if (( c == ne - 1 )); then rail+="┐"; else rail+="┬"; fi
        done
        LANE_BLOCK+="${dim}${rail}${reset}"$'\n'
        LANE_LINES=$(( LANE_LINES + 1 ))
      fi
    else
      L0="$gap"; L1="$gap"; L2="$gap"; L3="$gap"; L4="$gap"
    fi
    for (( c = 0; c < ne; c++ )); do
      pos=$(( row * ne + c ))
      kc[$c]=0
      if (( pos >= n )); then
        L0+="  ${cblank}"; L1+="  ${cblank}"; L2+="  ${cblank}"; L3+="  ${cblank}"; L4+="  ${cblank}"
        continue
      fi
      local later=0 top=" " conn=" " glyph hang=" "
      (( pos + ne >= n )) || later=1
      if (( row > first_row || ne > 1 )); then top="│"; fi
      if (( later == 1 )); then hang="│"; fi
      if (( row == first_row && c == 0 )); then
        conn="─"
        if (( ne > 1 )); then
          if (( later == 1 )); then glyph="┼"; else glyph="┤"; fi
        elif (( later == 1 )); then glyph="┬"; else glyph="─"; fi
      elif (( later == 1 )); then glyph="├"; else glyph="└"; fi
      wi="${lane[$pos]}"
      lc_chip "$wi"
      local chip="$LC_CHIP" chip_col="$LC_CHIP_COL" key
      printf -v key '%02d %s' $(( pos + 1 )) "${W_NAME[$wi]}"
      local role="${W_ROLE[$wi]:-dev}" l2 mw
      [[ "$role" != "sub-manager" ]] || role="sub-mgr"
      mw=$(( 14 - ${#role} - 3 ))
      if (( mw >= 4 )); then
        fmt_short_model "${W_MODEL[$wi]}" "$mw"
        l2="${role} · ${REPLY}"
      else
        fmt_short_model "${W_MODEL[$wi]}" 14
        l2="$REPLY"
      fi
      lc_box "$key" "$l2" "$chip" "$chip_col" "$bold" "$chip_col"
      lc_edge_label "$wi"
      lc_edge "$REPLY"
      L0+="${dim} ${top}${reset}${blank}${LC_BOX0}"
      L1+="${dim} ${top}${reset}${blank}${LC_BOX1}"
      L2+="${dim}${conn}${glyph}${reset}${LC_EDGE}${LC_BOX2}"
      L3+="${dim} ${hang}${reset}${blank}${LC_BOX3}"
      L4+="${dim} ${hang}${reset}${blank}${LC_BOX4}"

      # Sub-manager children: indented mini-row under the node (its own children only).
      local kid_shown=0 kid_total=0 ki avail txt pad glyph_k
      avail="$LC_NODE_W"
      if (( ne == 1 )); then avail=$(( columns - LC_NODE_W - LC_EDGE_W - 2 )); fi
      (( avail >= 8 )) || avail=8
      for (( ki = 0; ki < TOTAL_WORKERS; ki++ )); do
        [[ "${W_PARENT[$ki]}" == "${W_NAME[$wi]}" ]] || continue
        kid_total=$(( kid_total + 1 ))
        (( kid_shown < 3 )) || continue
        kid_shown=$(( kid_shown + 1 ))
        lc_chip "$ki"
        glyph_k="${LC_CHIP%% *}"
        printf -v txt '└ %02d %s · %s' "$kid_shown" "${W_NAME[$ki]}" "$glyph_k"
        trunc_str "$txt" "$avail"
        if [[ "$REPLY" == "$txt" ]]; then
          pad=$(( ne == 1 ? 0 : avail - ${#txt} ))
          kl[$(( c * 5 + kc[c] ))]="${txt%"$glyph_k"}${LC_CHIP_COL}${glyph_k}${reset}${SPACES_PAD:0:$pad}"
        else
          pad=$(( ne == 1 ? 0 : avail - ${#REPLY} ))
          kl[$(( c * 5 + kc[c] ))]="${REPLY}${SPACES_PAD:0:$pad}"
        fi
        kc[$c]=$(( kc[c] + 1 ))
      done
      if (( kid_total > kid_shown )); then
        printf -v txt '└ +%d more' $(( kid_total - kid_shown ))
        kl[$(( c * 5 + kc[c] ))]="${dim}${txt}${reset}${SPACES_PAD:0:$(( ne == 1 ? 0 : avail - ${#txt} ))}"
        kc[$c]=$(( kc[c] + 1 ))
      fi
      if (( kc[c] > maxk )); then maxk="${kc[$c]}"; fi
    done
    LANE_BLOCK+="${L0}"$'\n'"${L1}"$'\n'"${L2}"$'\n'"${L3}"$'\n'"${L4}"$'\n'
    LANE_LINES=$(( LANE_LINES + 5 ))
    for (( kk = 0; kk < maxk; kk++ )); do
      local kline="$gap" ktrunk
      for (( c = 0; c < ne; c++ )); do
        pos=$(( row * ne + c ))
        ktrunk=" "
        if (( pos + ne < n )); then ktrunk="│"; fi
        kline+="${dim} ${ktrunk}${reset}${SPACES_PAD:0:$LC_EDGE_W}"
        if (( kk < kc[c] )); then kline+="${kl[$(( c * 5 + kk ))]}"; else kline+="${gap}"; fi
      done
      LANE_BLOCK+="${kline}"$'\n'
      LANE_LINES=$(( LANE_LINES + 1 ))
    done
  done
  return 0
}

# Outcomes line for all shown workers -> LC_OUT_PLAIN / LC_OUT_DISP ("" when none).
lc_outcomes() {
  local columns="$1" ok=() bad=() wi
  for (( wi = 0; wi < TOTAL_WORKERS; wi++ )); do
    # Only the plans on screen (all plans before the lanes are rendered).
    if [[ -n "$LC_SHOWN_PLANS" && "$LC_SHOWN_PLANS" != *"|${W_PLAN_NAME[$wi]}|"* ]]; then
      continue
    fi
    case "${W_STATE[$wi]}" in
      completed)   ok[${#ok[@]}]="${W_NAME[$wi]}" ;;
      failed|lost) bad[${#bad[@]}]="${W_NAME[$wi]}" ;;
    esac
  done
  LC_OUT_PLAIN=""; LC_OUT_DISP=""
  (( ${#ok[@]} + ${#bad[@]} > 0 )) || return 0
  local so="${#ok[@]}" sb="${#bad[@]}" plain="" disp="" okp badp i
  while :; do
    okp=""; badp=""
    if (( ${#ok[@]} > 0 )); then
      okp="✓"
      for (( i = 0; i < so; i++ )); do okp+=" ${ok[$i]}"; done
      (( so >= ${#ok[@]} )) || okp+=" +$(( ${#ok[@]} - so ))"
    fi
    if (( ${#bad[@]} > 0 )); then
      badp="✗"
      for (( i = 0; i < sb; i++ )); do badp+=" ${bad[$i]}"; done
      (( sb >= ${#bad[@]} )) || badp+=" +$(( ${#bad[@]} - sb ))"
    fi
    plain="Outcomes  ${okp}"
    disp="${bold}Outcomes${reset}  ${c_completed}${okp}${reset}"
    if [[ -n "$badp" ]]; then
      plain+="${okp:+   }${badp}"
      disp+="${okp:+   }${c_failed}${badp}${reset}"
    fi
    if (( ${#plain} <= columns )) || (( so == 0 && sb == 0 )); then
      break
    fi
    if (( so >= sb && so > 0 )); then so=$(( so - 1 )); else sb=$(( sb - 1 )); fi
  done
  if (( ${#plain} > columns )); then
    trunc_str "$plain" "$columns"
    plain="$REPLY"; disp="$REPLY"
  fi
  LC_OUT_PLAIN="$plain"
  LC_OUT_DISP="$disp"
  return 0
}

# Succeeds when history message $1 is part of worker $2's own exchange with its manager
# (a sub-manager's chat with its children belongs to the children's lines).
lc_msg_for_worker() {
  local i="$1" w="$2" other ki
  if [[ "${H_FROM[$i]}" == "$w" ]]; then
    other="${H_TO[$i]}"
  elif [[ "${H_TO[$i]}" == "$w" ]]; then
    other="${H_FROM[$i]}"
  else
    return 1
  fi
  for (( ki = 0; ki < TOTAL_WORKERS; ki++ )); do
    if [[ "${W_NAME[$ki]}" == "$other" && "${W_PARENT[$ki]}" == "$w" ]]; then
      return 1
    fi
  done
  return 0
}

# Conversation notes: one line per worker, newest first -> LC_CONV_LINES.
lc_conversation() {
  local columns="$1" max_lines="$2"
  LC_CONV_LINES=()
  (( max_lines > 0 )) || return 0
  local hc="${#H_TS[@]}" i wi seen="|" names=() last_i=() wn
  for (( i = hc - 1; i >= 0; i-- )); do
    for (( wi = 0; wi < TOTAL_WORKERS; wi++ )); do
      wn="${W_NAME[$wi]}"
      if [[ "$seen" != *"|${wn}|"* ]] && lc_msg_for_worker "$i" "$wn"; then
        seen+="${wn}|"
        names[${#names[@]}]="$wn"
        last_i[${#last_i[@]}]="$i"
      fi
    done
    (( ${#names[@]} < max_lines )) || break
  done
  local nw=0 nn k
  for nn in ${names[@]+"${names[@]}"}; do
    (( ${#nn} <= nw )) || nw="${#nn}"
  done
  (( nw <= 14 )) || nw=14
  for (( k = 0; k < ${#names[@]} && k < max_lines; k++ )); do
    # One bounded line per worker: brief "<title>" · fix×N · last <verb> HH:MM [· ? asked "…"]
    local w="${names[$k]}" title="task" briefs=0 verb="" pending="" hhmm tail_txt line_txt
    for (( i = 0; i < hc; i++ )); do
      lc_msg_for_worker "$i" "$w" || continue
      case "${H_TYPE[$i]}" in
        brief)
          briefs=$(( briefs + 1 ))
          if (( briefs == 1 )); then
            lc_brief_title "$i"
            title="${REPLY:-task}"
          fi
          verb="brief"; pending=""
          ;;
        QUESTION)
          clean_msg_preview QUESTION "${H_BODY[$i]}"
          lc_first_sentence "$REPLY"
          pending="$REPLY"; verb="ask"
          ;;
        ANSWER)  verb="answer"; pending="" ;;
        done)    verb="done"; pending="" ;;
        failed)  verb="failed"; pending="" ;;
      esac
    done
    if (( briefs > 1 )) && [[ "$verb" == "brief" ]]; then verb="fix"; fi
    rfc3339_to_hhmm "${H_TS[${last_i[$k]}]}"
    hhmm="$REPLY"
    tail_txt=""
    (( briefs <= 1 )) || tail_txt=" · fix×$(( briefs - 1 ))"
    tail_txt+=" · last ${verb:-brief} ${hhmm}"
    if [[ -n "$pending" ]]; then
      trunc_str "$pending" 28
      tail_txt+=" · ? asked \"${REPLY}\""
    fi
    pad_str "$w" "$nw"
    local head_txt="$REPLY" tmax
    tmax=$(( columns - ${#head_txt} - 10 - ${#tail_txt} ))
    (( tmax >= 8 )) || tmax=8
    trunc_str "$title" "$tmax"
    line_txt="${head_txt}  brief \"${REPLY}\"${tail_txt}"
    trunc_str "$line_txt" "$columns"
    LC_CONV_LINES[$k]="$REPLY"
  done
  return 0
}

# Waiting group: workers whose last message is an unanswered QUESTION.
lc_waiting() {
  local columns="$1" max_lines="$2"
  LC_WAIT_BLOCK=""; LC_WAIT_LINES=0
  local waiting=() wi
  for (( wi = 0; wi < TOTAL_WORKERS; wi++ )); do
    if [[ "${W_STATE[$wi]}" == "running" ]] && (( W_ASKING[wi] == 1 )); then
      waiting[${#waiting[@]}]="$wi"
    fi
  done
  local nwait="${#waiting[@]}"
  (( nwait > 0 )) || return 0
  local ask_col="$c_asking"
  (( use_color == 0 )) || ask_col="@@ASK_CLR@@"
  LC_WAIT_BLOCK="${bold}Waiting on you (${nwait})${reset}"$'\n'
  LC_WAIT_LINES=1
  local shown=0 i q age head tail avail
  for wi in "${waiting[@]}"; do
    if (( shown >= max_lines )); then
      LC_WAIT_BLOCK+="${dim}+$(( nwait - shown )) more${reset}"$'\n'
      LC_WAIT_LINES=$(( LC_WAIT_LINES + 1 ))
      break
    fi
    q=""; age=""
    for (( i = ${#H_TS[@]} - 1; i >= 0; i-- )); do
      if [[ "${H_FROM[$i]}" == "${W_NAME[$wi]}" && "${H_TYPE[$i]}" == "QUESTION" ]]; then
        clean_msg_preview QUESTION "${H_BODY[$i]}"
        lc_clean_text "$REPLY"
        q="$REPLY"
        rfc3339_to_epoch "${H_TS[$i]}"
        if (( REPLY > 0 )); then
          fmt_elapsed_short $(( DATA_NOW - REPLY ))
          age="$REPLY"
        fi
        break
      fi
    done
    head="? ${W_NAME[$wi]}  "
    tail=""
    [[ -z "$age" ]] || tail="  · ${age}"
    avail=$(( columns - ${#head} - ${#tail} ))
    (( avail >= 1 )) || avail=1
    trunc_str "$q" "$avail"
    LC_WAIT_BLOCK+="${ask_col}${head}${REPLY}${tail}${reset}"$'\n'
    LC_WAIT_LINES=$(( LC_WAIT_LINES + 1 ))
    shown=$(( shown + 1 ))
  done
  return 0
}

build_lifecycle_frame() {
  local columns="$1" lines="$2" rule_line="$3"
  ensure_pad_len "$columns"
  local failed_total=$(( FAILED_COUNT + LOST_COUNT ))

  LANE_BLOCK=""; LANE_LINES=0; LC_SHOWN_PLANS=""; LC_LANE_PLAN=""
  local is_live=0
  (( once == 1 )) || is_live=1

  lc_waiting "$columns" 3
  local wait_block="$LC_WAIT_BLOCK" wait_lines="$LC_WAIT_LINES"

  lc_outcomes "$columns"
  local out_plain="$LC_OUT_PLAIN" out_disp="$LC_OUT_DISP" out_lines=0
  if [[ -n "$out_plain" ]] && (( focus == 0 )); then
    out_lines=1
  fi

  local flow_cfg="${SQUAD_ORCHESTRATION_FLOW_LINES:-6}"
  [[ "$flow_cfg" =~ ^[0-9]+$ ]] || flow_cfg=6
  local hist_cnt="${#H_TS[@]}"

  local mgrs=("${MANAGERS_LIST[@]}")
  (( ${#mgrs[@]} > 0 )) || mgrs=("$MANAGER_ID")
  local nm="${#mgrs[@]}" show_label=0
  (( all_managers == 0 )) || show_label=1

  local hist_line_cnt=1 footer_lines=0 conv_min=0
  (( focus == 0 )) || hist_line_cnt=0
  (( is_live == 0 )) || footer_lines=1
  if (( focus == 0 && hist_cnt > 0 && flow_cfg > 0 )); then
    conv_min=3
  fi

  # Rows of nodes that fit; one line per manager is kept for its label / "earlier" note.
  local avail=$(( lines - 1 - wait_lines - out_lines - hist_line_cnt - footer_lines - conv_min - nm ))
  local row_budget=$(( avail / 5 / nm ))
  (( row_budget >= 1 )) || row_budget=1

  local mi
  if (( TOTAL_WORKERS > 0 )); then
    for (( mi = 0; mi < nm; mi++ )); do
      lc_render_lane "${mgrs[$mi]}" "$row_budget" "$columns" "$show_label"
    done
  fi
  lc_outcomes "$columns"
  out_plain="$LC_OUT_PLAIN"
  out_disp="$LC_OUT_DISP"
  if [[ -z "$out_plain" ]] || (( focus == 1 )); then
    out_lines=0
  else
    out_lines=1
  fi

  # -- header (1 line): drop time/tokens, shorten the plan, drop the plan, then truncate
  local mgr_txt="$MANAGER_ID" client="${SQUAD_DEVKIT_MANAGER_CLIENT:-}"
  (( all_managers == 0 )) || mgr_txt="all managers (${nm})"
  local first_start=0 wi span="" tokp=""
  for (( wi = 0; wi < TOTAL_WORKERS; wi++ )); do
    if (( first_start == 0 || W_STARTED[wi] < first_start )); then
      first_start="${W_STARTED[$wi]}"
    fi
  done
  if (( first_start > 0 )); then
    fmt_elapsed_short $(( DATA_NOW - first_start ))
    span="$REPLY"
  fi
  if (( TOTAL_TOKENS > 0 )); then
    fmt_human_count "$TOTAL_TOKENS"
    tokp="${REPLY} tok"
  fi
  local sep="  ·  " who="● ${mgr_txt}"
  if [[ -n "$client" ]] && (( all_managers == 0 )); then
    who+=" · ${client}"
  fi
  local counts="●${RUNNING_COUNT} running ✓${COMPLETED_COUNT} ✗${failed_total}"
  local time_tok="${span}${tokp:+  ${tokp}}"
  local plan_seg="" hdr_plain="" hdr_disp="" stage
  for stage in 0 1 2 3; do
    plan_seg=""
    if [[ -n "$LC_LANE_PLAN" ]] && (( all_managers == 0 )) && (( stage < 3 )); then
      plan_seg="plan ${LC_LANE_PLAN}"
      if (( stage == 2 )); then
        trunc_str "$plan_seg" 24
        plan_seg="$REPLY"
      fi
    fi
    hdr_plain="${who}"
    [[ -z "$plan_seg" ]] || hdr_plain+="${sep}${plan_seg}"
    hdr_plain+="${sep}${counts}"
    if (( stage == 0 )) && [[ -n "$time_tok" ]]; then
      hdr_plain+="${sep}${time_tok}"
    fi
    if (( ${#hdr_plain} <= columns )); then
      break
    fi
  done
  if (( ${#hdr_plain} > columns )); then
    trunc_str "$hdr_plain" "$columns"
    hdr_disp="$REPLY"
  else
    hdr_disp="${c_manager}${who}${reset}"
    [[ -z "$plan_seg" ]] || hdr_disp+="${sep}${bold}${plan_seg}${reset}"
    hdr_disp+="${sep}${c_running}●${RUNNING_COUNT} running${reset} ${c_completed}✓${COMPLETED_COUNT}${reset} ${c_failed}✗${failed_total}${reset}"
    if (( stage == 0 )) && [[ -n "$time_tok" ]]; then
      hdr_disp+="${sep}${dim}${time_tok}${reset}"
    fi
  fi

  local frame="${hdr_disp}"$'\n' used=1
  if (( TOTAL_WORKERS == 0 )); then
    trunc_str "No worker runs in this session yet." "$columns"
    frame+="${REPLY}"$'\n'
    used=$(( used + 1 ))
  else
    frame+="${LANE_BLOCK}"
    used=$(( used + LANE_LINES ))
  fi
  frame+="${wait_block}"
  used=$(( used + wait_lines ))

  if (( focus == 0 && TOTAL_WORKERS > 0 )); then
    if (( out_lines > 0 )); then
      frame+="${out_disp}"$'\n'
      used=$(( used + 1 ))
    fi

    # Older plans: one summary line, expanded into a list with key h.
    local older=0 old_done=0 old_fail=0 pi older_idx=()
    for (( pi = 0; pi < ${#P_NAME[@]}; pi++ )); do
      if [[ "$LC_SHOWN_PLANS" != *"|${P_NAME[$pi]}|"* ]]; then
        older=$(( older + 1 ))
        old_done=$(( old_done + P_DONE_CNT[pi] ))
        old_fail=$(( old_fail + P_FAIL_CNT[pi] ))
        older_idx[${#older_idx[@]}]="$pi"
      fi
    done
    local hist_block="" hist_used=0
    if (( older > 0 )); then
      local noun="plans" hl
      (( older != 1 )) || noun="plan"
      hl="History  ${older} earlier ${noun} · ✓${old_done} ✗${old_fail}"
      (( is_live == 0 )) || hl+="  (h to expand)"
      trunc_str "$hl" "$columns"
      hist_block="${dim}${REPLY}${reset}"$'\n'
      hist_used=1
      if (( history_expanded == 1 && is_live == 1 )); then
        local room=$(( lines - used - footer_lines - 3 )) shown_old=0 oi
        for oi in "${older_idx[@]}"; do
          (( shown_old < room )) || break
          format_collapsed_plan_line "$oi" "$columns"
          hist_block+="${REPLY}"$'\n'
          hist_used=$(( hist_used + 1 ))
          shown_old=$(( shown_old + 1 ))
        done
      fi
    fi

    # Conversation notes fill what is left (rule + title + lines).
    local conv_room=$(( lines - used - hist_used - footer_lines - 2 )) conv_n="$flow_cfg" cl
    (( conv_n <= conv_room )) || conv_n="$conv_room"
    if (( hist_cnt > 0 && conv_n > 0 )); then
      lc_conversation "$columns" "$conv_n"
      if (( ${#LC_CONV_LINES[@]} > 0 )); then
        frame+="${rule_line}"$'\n'"${bold}Conversation${reset}"$'\n'
        for cl in "${LC_CONV_LINES[@]}"; do
          frame+="${cl}"$'\n'
        done
      fi
    fi
    frame+="${hist_block}"
  fi

  if (( is_live == 1 )); then
    local keys="l layout  a all managers  h history  f focus  q quit"
    (( focus == 0 )) || keys="l layout  a all managers  f unfocus  q quit"
    trunc_str "$keys" "$columns"
    frame+="${dim}${REPLY}${reset}"$'\n'
  fi

  FRAME_TPL[0]="$frame"
  FRAME_TPL[1]="$frame"
  FRAME_TPL[2]="$frame"
  FRAME_TPL[3]="$frame"
  return 0
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

  # Default graph layout: lifecycle flow chart (narrow panes and --root zoom keep the legacy views).
  if [[ "$layout" == "graph" && -z "$zoom_target" ]] && (( columns >= 48 )); then
    build_lifecycle_frame "$columns" "$lines" "$rule_line"
    return 0
  fi

  # 1. Header (2 lines): build from parts and drop least important parts until it fits
  # Order of dropping: key hint -> token total -> since HH:MM -> layout name (-> ws -> title)
  local failed_total=$(( FAILED_COUNT + LOST_COUNT ))
  local run_seg="● ${RUNNING_COUNT} running"
  local done_seg="✓ ${COMPLETED_COUNT} done"
  local fail_seg="✗ ${failed_total} failed"
  local counts_plain="${run_seg}  ${done_seg}  ${fail_seg}"
  local counts_disp="$counts_plain"
  if (( use_color == 1 )); then
    counts_disp="${c_running}${run_seg}${reset}  ${c_completed}${done_seg}${reset}  ${c_failed}${fail_seg}${reset}"
  fi

  local tok_part=""
  if (( TOTAL_TOKENS > 0 )); then
    fmt_human_count "$TOTAL_TOKENS"
    tok_part="${REPLY} tok"
  fi
  local keys_part=""
  if (( once == 0 )); then
    keys_part="[g]raph [p]ipeline [t]ree [a]ll [q]uit"
  fi

  local mgr_hdr_part=""
  if (( all_managers == 1 )); then
    mgr_hdr_part="all managers (${#MANAGERS_LIST[@]})"
  else
    mgr_hdr_part="${MANAGER_ID}"
  fi

  local use_keys=0 use_tok=0 use_since=1 use_layout=1 use_ws=1 use_title=1
  [[ -n "$keys_part" ]] && use_keys=1
  [[ -n "$tok_part" ]] && use_tok=1

  local header_plain=""
  local drop_step=0
  while (( drop_step <= 6 )); do
    header_plain=""
    (( use_title == 1 )) && header_plain="squad orchestration"
    header_plain="${header_plain:+${header_plain} · }${mgr_hdr_part}"
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
    if (( ${#run_seg} + 2 + ${#done_seg} <= columns )); then
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
    header_disp="${header_disp:+${header_disp} · }${mgr_hdr_part}"
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
    local show_msgs="$hist_cnt"
    (( show_msgs > flow_limit )) && show_msgs="$flow_limit"

    flow_block+="${rule_line}"$'\n'
    local flow_hdr="Flow (latest ${flow_limit})"
    (( ${#flow_hdr} <= columns )) || flow_hdr="${flow_hdr:0:$columns}"
    flow_block+="${flow_hdr}"$'\n'

    local h_idx=$(( hist_cnt - show_msgs ))
    while (( h_idx < hist_cnt )); do
      local f_ts="${H_TS[$h_idx]}"
      local f_from="${H_FROM[$h_idx]}"
      local f_to="${H_TO[$h_idx]}"
      local f_type="${H_TYPE[$h_idx]}"
      local f_body="${H_BODY[$h_idx]}"

      rfc3339_to_hhmm "$f_ts"
      local f_hhmm="$REPLY"
      clean_msg_preview "$f_type" "$f_body"
      local f_preview="$REPLY"

      local f_arrow="${f_from} ──${f_type}──▶ ${f_to}"
      local arrow_col
      if (( ${#f_arrow} < 32 )); then
        pad_str "$f_arrow" 32
        arrow_col="$REPLY"
      else
        arrow_col="${f_arrow}  "
      fi

      local prefix="  ${f_hhmm}  ${arrow_col}"
      local prefix_len="${#prefix}"
      local avail=$(( columns - prefix_len ))
      (( avail > 0 )) || avail=1
      trunc_str "$f_preview" "$avail"
      f_preview="$REPLY"

      local flow_row_plain="${prefix}${f_preview}"
      local flow_row_display="$flow_row_plain"
      if (( ${#flow_row_plain} > columns )); then
        flow_row_display="${flow_row_plain:0:$columns}"
      elif (( use_color == 1 )); then
        local color_arrow
        case "$f_type" in
          brief)    color_arrow="${c_brief}──brief──▶${reset}" ;;
          ANSWER)   color_arrow="${c_answer}──ANSWER──▶${reset}" ;;
          QUESTION) color_arrow="${c_question}──QUESTION──▶${reset}" ;;
          done)     color_arrow="${c_done}──done──▶${reset}" ;;
          failed)   color_arrow="${c_failed}──failed──▶${reset}" ;;
          *)        color_arrow="${dim}──${f_type}──▶${reset}" ;;
        esac
        local colored_arrow="${f_from} ${color_arrow} ${f_to}"
        local pad_spaces=$(( ${#arrow_col} - ${#f_arrow} ))
        local spaces_str="${SPACES_PAD:0:$pad_spaces}"
        flow_row_display="  ${dim}${f_hhmm}${reset}  ${colored_arrow}${spaces_str}${f_preview}"
      fi

      flow_block+="${flow_row_display}"$'\n'
      h_idx=$(( h_idx + 1 ))
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
      a|A)
        all_managers=$(( 1 - all_managers ))
        load_data
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
      f|F)
        focus=$(( 1 - focus ))
        build_frame_templates
        subframe=0
        ;;
      h|H)
        history_expanded=$(( 1 - history_expanded ))
        build_frame_templates
        subframe=0
        ;;
      $'\t'|l|L)
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
