# bash completion for squad-devkit, squad-worker, squad-monitor
# shellcheck shell=bash

_squad_devkit_find_workspace() {
  local dir="$PWD"
  if [[ -n "${SQUAD_DEVKIT_WORKSPACE:-}" && -d "$SQUAD_DEVKIT_WORKSPACE/.squad" ]]; then
    printf '%s' "$SQUAD_DEVKIT_WORKSPACE"
    return 0
  fi
  while [[ "$dir" != "/" && -n "$dir" ]]; do
    if [[ -d "$dir/.squad" ]]; then
      printf '%s' "$dir"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  return 1
}

_squad_devkit() {
  local cur prev
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"

  local opts="--manager --setup --doctor --list --ghostty --tmux --dry-run --task --prompt --clean --clean-all --no-attach --no-prompt --version -h --help"
  local managers="claude codex agy gemini grok opencode"

  case "$prev" in
    --manager)
      # shellcheck disable=SC2207
      COMPREPLY=( $(compgen -W "$managers" -- "$cur") )
      return 0
      ;;
    --task|--prompt)
      return 0
      ;;
  esac

  if [[ "$cur" == -* ]]; then
    # shellcheck disable=SC2207
    COMPREPLY=( $(compgen -W "$opts" -- "$cur") )
    return 0
  fi

  # Filename / directory completion fallback
  # shellcheck disable=SC2207
  COMPREPLY=( $(compgen -d -- "$cur") )
}

_squad_worker() {
  local cur prev
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"

  local opts="--engine --role --title --brief --brief-file --project --profile --model --mcp --all-mcp --timeout --worktree --no-worktree --manager --list --stop --merge --discard -h --help"
  local engines="claude codex grok agy ccr"
  local roles="dev tester reviewer researcher manager-devkit"
  local profiles="high medium max"

  case "$prev" in
    --engine)
      # shellcheck disable=SC2207
      COMPREPLY=( $(compgen -W "$engines" -- "$cur") )
      return 0
      ;;
    --role)
      # shellcheck disable=SC2207
      COMPREPLY=( $(compgen -W "$roles" -- "$cur") )
      return 0
      ;;
    --profile)
      # shellcheck disable=SC2207
      COMPREPLY=( $(compgen -W "$profiles" -- "$cur") )
      return 0
      ;;
    --project|--brief-file)
      # shellcheck disable=SC2207
      COMPREPLY=( $(compgen -f -- "$cur") )
      return 0
      ;;
    --stop)
      local ws running_ids="all"
      if ws="$(_squad_devkit_find_workspace)"; then
        local sf id st
        for sf in "$ws"/.squad/workers/*.status; do
          [[ -f "$sf" ]] || continue
          st="$(sed -n 's/^state=//p' "$sf" 2>/dev/null | tail -n 1)"
          if [[ "$st" == "running" ]]; then
            id="$(sed -n 's/^worker=//p' "$sf" 2>/dev/null | tail -n 1)"
            [[ -n "$id" ]] && running_ids+=" $id"
          fi
        done
      fi
      # shellcheck disable=SC2207
      COMPREPLY=( $(compgen -W "$running_ids" -- "$cur") )
      return 0
      ;;
    --merge|--discard)
      local ws unmerged_ids="all"
      if ws="$(_squad_devkit_find_workspace)"; then
        local sf id wt seen=" "
        for sf in "$ws"/.squad/workers/*.status; do
          [[ -f "$sf" ]] || continue
          wt="$(sed -n 's/^worktree=//p' "$sf" 2>/dev/null | tail -n 1)"
          id="$(sed -n 's/^worker=//p' "$sf" 2>/dev/null | tail -n 1)"
          if [[ -n "$wt" && -d "$wt" && "$seen" != *" $id "* ]]; then
            seen+="$id "
            unmerged_ids+=" $id"
          fi
        done
      fi
      # shellcheck disable=SC2207
      COMPREPLY=( $(compgen -W "$unmerged_ids" -- "$cur") )
      return 0
      ;;
  esac

  if [[ "$cur" == -* ]]; then
    # shellcheck disable=SC2207
    COMPREPLY=( $(compgen -W "$opts" -- "$cur") )
    return 0
  fi
}

_squad_monitor() {
  local cur prev
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"

  local opts="--all --savings --text --once -h --help"

  case "$prev" in
    --all|--savings)
      # shellcheck disable=SC2207
      COMPREPLY=( $(compgen -d -- "$cur") )
      return 0
      ;;
  esac

  if [[ "$cur" == -* ]]; then
    # shellcheck disable=SC2207
    COMPREPLY=( $(compgen -W "$opts" -- "$cur") )
    return 0
  fi

  # First non-option argument is status-file or directory
  # shellcheck disable=SC2207
  COMPREPLY=( $(compgen -f -- "$cur") )
}

complete -F _squad_devkit squad-devkit
complete -F _squad_devkit squad-devkit.sh
complete -F _squad_worker squad-worker
complete -F _squad_worker squad-worker.sh
complete -F _squad_monitor squad-monitor
complete -F _squad_monitor squad-worker-monitor.sh
