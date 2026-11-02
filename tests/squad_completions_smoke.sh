#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../scripts/completions/squad-devkit.bash
source "$root/scripts/completions/squad-devkit.bash"
fail() { echo "FAIL: $*" >&2; exit 1; }
check_bash() {
  local function=$1 expected=$2
  shift 2
  COMP_WORDS=("$@")
  COMP_CWORD=$((${#COMP_WORDS[@]} - 1))
  COMPREPLY=()
  "$function"
  [[ "${COMPREPLY[*]}" == "$expected" ]] || fail "Bash $*: ${COMPREPLY[*]}"
}
check_bash _squad_devkit --doctor squad-devkit --doc
check_bash _squad_devkit codex squad-devkit --manager co
check_bash _squad_devkit agy squad-devkit --workers ag
check_bash _squad_devkit ccr squad-devkit --disable-workers cc
check_bash _squad_worker opencode squad-worker worker-1 --engine open

command -v zsh >/dev/null || fail 'zsh is required for completion checks'
# Exercise the real Zsh completion system in a pseudo terminal, including _arguments.
zsh -f -s -- "$root" <<'ZSH'
set -eu
zmodload zsh/zpty
root=$1
zpty -b shell zsh -f
trap 'zpty -d shell' EXIT
zpty -w shell "autoload -Uz compinit; compinit -u -D; fpath=(\"$root/scripts/completions\" \$fpath); unfunction _squad-devkit 2>/dev/null; autoload -Uz \"$root/scripts/completions/_squad-devkit\"; compdef _squad-devkit squad-devkit squad-worker; PS1=''; report() { print -r -- \"RESULT:\$BUFFER:END\"; zle send-break; }; zle -N report; bindkey '^X' report; bindkey '^I' complete-word"
check() {
  local input=$1 expected=$2 output='' chunk='' tries=0
  # The report widget returns the buffer after Tab; it never executes the command.
  zpty -w -n shell "$input"$'\t\C-x'
  while (( tries++ < 100 )); do
    if zpty -r shell chunk; then output+=$chunk; fi
    if [[ $output == *"RESULT:$expected:END"* ]]; then return 0; fi
    sleep 0.05
  done
  print -ru2 -- "FAIL: Zsh $input; expected $expected; output: $output"
  return 1
}
check 'squad-devkit --doc' 'squad-devkit --doctor '
check 'squad-devkit --manager co' 'squad-devkit --manager codex '
check 'squad-devkit --workers ag' 'squad-devkit --workers agy '
check 'squad-devkit --disable-workers cc' 'squad-devkit --disable-workers ccr '
check 'squad-worker worker-1 --engine open' 'squad-worker worker-1 --engine opencode '
ZSH
printf 'PASS: Bash and Zsh completions\n'
