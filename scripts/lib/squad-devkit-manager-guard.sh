#!/usr/bin/env bash
# Claude Code PreToolUse hook installed by squad-devkit-manager.sh. The manager
# plans, verifies and delegates; this hook denies edits to project files and
# `git commit` / `git push` / `gh pr merge` that no plan approves. Any internal
# error allows the call (a broken guard must not brick the manager); the plan
# gate in squad-worker is the hard gate.
# Usage: squad-devkit-manager-guard.sh <project_dir>   (hook JSON on stdin)
# Env: SQUAD_DEVKIT_GUARD=0 disables it; SQUAD_DEVKIT_GUARD_ALLOW is a
# colon-separated list of extra directories the manager may edit.
# No `set -u`: bash 3.2 (macOS) rejects empty arrays under it.
set -o pipefail

[[ "${SQUAD_DEVKIT_GUARD:-1}" == 0 ]] && exit 0

lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=squad-plan.sh
source "$lib_dir/squad-plan.sh"

allow_on_error() {
  echo "squad-devkit-manager-guard: $1; allowing the tool call" >&2
  exit 0
}

command -v jq >/dev/null 2>&1 || allow_on_error "jq is missing"
project_dir="${1:-}"
[[ -d "$project_dir" ]] || allow_on_error "project directory not found"
project_dir="$(cd "$project_dir" && pwd -P)"

input="$(cat)"
fields="$(jq -r '[.tool_name // "", .cwd // "", .tool_input.file_path // .tool_input.notebook_path // "",
  (.tool_input.command // "" | gsub("\n"; "\u001e"))] | join("\u001f")' <<<"$input" 2>/dev/null)" ||
  allow_on_error "could not parse the hook input"
IFS=$'\037' read -r tool_name cwd file_path command <<<"$fields"
command="${command//$'\036'/$'\n'}"
[[ -n "$cwd" && -d "$cwd" ]] || cwd="$project_dir"

deny() {
  jq -nc --arg reason "$1" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
  exit 0
}

# Prints an absolute, physical path: symlinks are followed (leaf and parents,
# max 40 hops) before `..` is collapsed, so /var and /private/var compare equal
# and a link into the project cannot hide it. Components that do not exist yet
# are appended as given. Nothing here word-splits or globs.
resolve_path() {
  local path="$1" base="$2" part target cur="" rest="" pending hops=0
  [[ "$path" == /* ]] || path="$base/$path"
  pending="$path"
  while [[ -n "$pending" ]]; do
    part="${pending%%/*}"
    if [[ "$pending" == */* ]]; then pending="${pending#*/}"; else pending=""; fi
    case "$part" in
      '' | .) ;;
      ..)
        if [[ -n "$rest" ]]; then rest="${rest%/*}"; else cur="${cur%/*}"; fi
        ;;
      *)
        if [[ -z "$rest" && -L "$cur/$part" && $hops -lt 40 ]]; then
          hops=$((hops + 1))
          target="$(readlink "$cur/$part")"
          [[ "$target" == /* ]] && cur=""
          pending="$target/$pending"
        elif [[ -z "$rest" && -d "$cur/$part" ]]; then
          cur="$cur/$part"
        else
          rest="$rest/$part"
        fi
        ;;
    esac
  done
  cur="$cur$rest"
  printf '%s\n' "${cur:-/}"
}

# Resolves <arg> against <base> for cd / git -C. Prints nothing when the
# directory cannot be known statically (variables, substitutions, globs, `cd -`,
# ~user, or a relative path after an unknown directory).
step_dir() { # <base> <arg>
  local base="$1" arg="$2"
  # shellcheck disable=SC2088 # deliberately the literal "~" word from the command, expanded here by hand
  if [[ "$arg" == "~" || "$arg" == "~/"* ]]; then arg="$HOME${arg:1}"; fi
  case "$arg" in
    '' | - | '~'* | *'$'* | *'`'* | *'*'* | *'?'* | *'['*) return 0 ;;
  esac
  [[ "$arg" == /* || -n "$base" ]] || return 0
  resolve_path "$arg" "$base"
}

under() { [[ "$1" == "$2" || "$1" == "$2"/* ]]; }

# Inside the project only .squad/ is editable, whatever the allow-list says.
# Outside it, the temp dirs, Claude's per-project memory and
# SQUAD_DEVKIT_GUARD_ALLOW apply.
path_allowed() {
  local path="$1" root entry
  under "$path" "$(resolve_path "$project_dir/.squad" "$project_dir")" && return 0
  under "$path" "$project_dir" && return 1
  local roots=("${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects" /tmp /private/tmp /private/var/folders)
  [[ -n "${TMPDIR:-}" ]] && roots+=("$TMPDIR")
  while IFS= read -r entry; do
    [[ -n "$entry" ]] && roots+=("$entry")
  done < <(printf '%s\n' "${SQUAD_DEVKIT_GUARD_ALLOW:-}" | tr ':' '\n')
  for root in "${roots[@]}"; do
    root="$(resolve_path "$root" "$project_dir")"
    [[ -n "$root" ]] || continue
    under "$path" "$root" && return 0
  done
  return 1
}

# Sets $deny_reason and returns 1 when no plan approves <action> for the repo
# at physical top level <top>. A plan approves by basename or by absolute path;
# for a push, every approving high-risk plan must also approve review.
git_approved() { # <action> <repo toplevel>
  local action="$1" top="$2" repo plan found=0
  repo="$(basename "$top")"
  while IFS= read -r plan; do
    [[ -n "$plan" ]] || continue
    found=1
    if [[ "$action" == push && "$(plan_field "$plan" risk)" == high ]] && ! plan_approves "$plan" review "$repo" "$top"; then
      deny_reason="push of $repo from high-risk plan $(basename "$plan") needs \"- review: $repo\" (or \"- review: $top\") in ## Approvals after a reviewer passes."
      return 1
    fi
  done < <(plan_list_approvals "$project_dir/.squad/plans" "$action" "$repo" "$top")
  [[ $found -eq 1 ]] && return 0
  deny_reason="git $action in $repo needs a human approval recorded in a plan: add \"- $action: $top\" under ## Approvals in .squad/plans/<plan>.md after the human approves (a bare \"$repo\" also matches, but so does any repository with that name)."
  return 1
}

# Prints the physical top level of the repository containing <dir>, if any.
repo_top() { # <dir>
  local top
  top="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)" || return 0
  (cd "$top" 2>/dev/null && pwd -P)
}

# Sets $target_top to the repository a git command started in <dir> uses, given
# its --git-dir / GIT_DIR and --work-tree / GIT_WORK_TREE values ("" when not
# given). Empty $target_top means no repository. Returns 1 when the target cannot
# be known statically: an unknown <dir>, or a value that is not a literal,
# existing path.
resolve_target() { # <dir> <git dir> <work tree>
  local dir="$1" gd="" wt="" cfg
  target_top=""
  [[ -n "$dir" && -d "$dir" ]] || return 1
  if [[ -n "$3" ]]; then
    wt="$(step_dir "$dir" "$3")"
    [[ -n "$wt" && -d "$wt" ]] || return 1
  fi
  if [[ -z "$2" ]]; then
    target_top="$(repo_top "$dir")"
    return 0
  fi
  gd="$(step_dir "$dir" "$2")"
  [[ -n "$gd" && -d "$gd" ]] || return 1
  git --git-dir="$gd" rev-parse --git-dir >/dev/null 2>&1 || return 1
  if [[ -n "$wt" ]]; then
    target_top="$wt"
  elif cfg="$(git --git-dir="$gd" config core.worktree 2>/dev/null)" && [[ -n "$cfg" ]]; then
    target_top="$(step_dir "$gd" "$cfg")"
    [[ -n "$target_top" && -d "$target_top" ]] || return 1
  elif [[ "$(basename "$gd")" == .git ]]; then
    target_top="$(dirname "$gd")"
  else
    target_top="$gd" # a bare repository
  fi
  return 0
}

deny_unresolved() { # <action>
  deny "Could not verify the target repository of $1; run \"git -C <literal path> $1\" after recording the approval in a plan."
}

# An operation found inside a wrapper (bash -c, eval, xargs, …) that the
# structured parse cannot see into. It runs in the session cwd unless the command
# names another target somewhere, which is then denied as unverifiable.
unverified() { # <action> <explicit target seen: 0|1>
  local top
  [[ "$2" == 1 ]] && deny_unresolved "$1"
  top="$(repo_top "$cwd")"
  [[ -n "$top" ]] && git_approved "$1" "$top" && return 0
  deny "Could not verify $1 in this command; run it as a plain \"git -C <repo> $1 …\" command after recording the approval in a plan."
}

# An operation the structured parse found: <dir> is the working directory (empty
# when unknown), then the GIT_DIR and GIT_WORK_TREE values, then 1 when the
# segment names some other target it cannot follow.
run_op() { # <action> <dir> <git dir> <work tree> <unresolvable: 0|1>
  if [[ "$1" == commit ]]; then resolved_commit=$((resolved_commit + 1)); else resolved_push=$((resolved_push + 1)); fi
  if [[ "$5" == 1 ]] || ! resolve_target "$2" "$3" "$4"; then deny_unresolved "$1"; fi
  [[ -n "$target_top" ]] || return 0
  git_approved "$1" "$target_top" || deny "$deny_reason"
}

# Records a GIT_DIR= / GIT_WORK_TREE= assignment into the caller's $gd / $wt; an
# empty value becomes "-", which never resolves.
target_assignment() { # <word>
  case "$1" in
    GIT_DIR=*) gd="${1#GIT_DIR=}" && gd="${gd:--}" ;;
    GIT_WORK_TREE=*) wt="${1#GIT_WORK_TREE=}" && wt="${wt:--}" ;;
  esac
}

# Clears the caller's $gd / $wt for an unset GIT_DIR / GIT_WORK_TREE name.
target_unset() { # <name>
  case "$1" in
    GIT_DIR) gd="" ;;
    GIT_WORK_TREE) wt="" ;;
  esac
}

# Checks one command segment; reads and updates the globals $workdir and
# $env_gd / $env_wt (GIT_DIR / GIT_WORK_TREE set by earlier segments).
check_segment() {
  local words=() word dir sub="" i=0 j n arg unres=0 gd="$env_gd" wt="$env_wt" via_env=0
  # Word splitting only; quoting beyond surrounding quotes is not interpreted.
  read -r -a words <<<"$1"
  n=${#words[@]}
  [[ $n -gt 0 ]] || return 0
  for i in "${!words[@]}"; do
    word="${words[$i]}"
    word="${word#[\"\']}"
    words[i]="${word%[\"\']}"
  done
  i=0
  while [[ $i -lt $n ]]; do
    case "${words[$i]}" in
      sudo | time | nohup | exec | command | builtin | then | do | else | '!' | '{' | '(') i=$((i + 1)) ;;
      env)
        via_env=1
        i=$((i + 1))
        while [[ $i -lt $n ]]; do
          case "${words[$i]}" in
            -i | - | -0 | --ignore-environment | --null) i=$((i + 1)) ;;
            -u | --unset)
              target_unset "${words[$((i + 1))]:-}"
              i=$((i + 2))
              ;;
            --unset=*)
              target_unset "${words[$i]#--unset=}"
              i=$((i + 1))
              ;;
            -*)
              unres=1
              i=$((i + 1))
              ;;
            GIT_DIR=* | GIT_WORK_TREE=*)
              target_assignment "${words[$i]}"
              i=$((i + 1))
              ;;
            [A-Za-z_]*=*) i=$((i + 1)) ;;
            *) break ;;
          esac
        done
        ;;
      GIT_DIR=* | GIT_WORK_TREE=*)
        target_assignment "${words[$i]}"
        i=$((i + 1))
        ;;
      [A-Za-z_]*=*) i=$((i + 1)) ;;
      *) break ;;
    esac
  done
  case "${words[$i]:-}" in
    '')
      # A bare assignment list sets the variables for the following segments.
      if [[ $via_env -eq 0 ]]; then
        env_gd="$gd"
        env_wt="$wt"
      fi
      return 0
      ;;
    export | declare | typeset)
      for word in "${words[@]:$((i + 1))}"; do target_assignment "$word"; done
      env_gd="$gd"
      env_wt="$wt"
      return 0
      ;;
    unset)
      for word in "${words[@]:$((i + 1))}"; do target_unset "$word"; done
      env_gd="$gd"
      env_wt="$wt"
      return 0
      ;;
    cd | pushd)
      j=$((i + 1))
      while [[ "${words[$j]:-}" == -?* ]]; do j=$((j + 1)); done
      arg="${words[$j]:-}"
      if [[ -z "$arg" && "${words[$i]}" == pushd ]]; then
        workdir=""
      else
        [[ -n "$arg" ]] || arg="~"
        workdir="$(step_dir "$workdir" "$arg")"
      fi
      return 0
      ;;
    popd)
      workdir=""
      return 0
      ;;
    gh | */gh)
      if [[ "${words[$((i + 1))]:-}" == pr && "${words[$((i + 2))]:-}" == merge ]]; then
        # -R / --repo names a remote repository that maps to no local path.
        for word in "${words[@]:$((i + 3))}"; do
          case "$word" in
            -R* | --repo | --repo=*) unres=1 ;;
          esac
        done
        run_op push "$workdir" "$gd" "$wt" "$unres"
      fi
      return 0
      ;;
    git | */git) ;;
    *) return 0 ;;
  esac
  dir="$workdir"
  i=$((i + 1))
  while [[ $i -lt $n ]]; do
    word="${words[$i]}"
    case "$word" in
      -C)
        i=$((i + 1))
        dir="$(step_dir "$dir" "${words[$i]:-}")"
        ;;
      -c | --namespace) i=$((i + 1)) ;;
      --git-dir=*) gd="${word#--git-dir=}" && gd="${gd:--}" ;;
      --work-tree=*) wt="${word#--work-tree=}" && wt="${wt:--}" ;;
      --git-dir)
        i=$((i + 1))
        gd="${words[$i]:--}"
        ;;
      --work-tree)
        i=$((i + 1))
        wt="${words[$i]:--}"
        ;;
      -*) ;;
      *)
        sub="$word"
        break
        ;;
    esac
    i=$((i + 1))
  done
  case "$sub" in
    commit | push) run_op "$sub" "$dir" "$gd" "$wt" "$unres" ;;
  esac
}

# Loose detector over the raw command: counts `<tool> … <word>` occurrences,
# where the words after each <tool> token run to the next <tool> token (cut at
# the first ; | & unless a quote precedes it). Sets $loose_n, and sets
# $loose_explicit to 1 when the words before a counted <word> match <target-regex>.
loose_count() { # <tool> <chunk-regex> [<target-regex>]
  local tool_re="(^|[^[:alnum:]_.-])$1['\"]?[[:space:]]+" line rest chunk pre n=0
  loose_explicit=0
  while IFS= read -r line; do
    while [[ "$line" =~ $tool_re ]]; do
      rest="${line#*"${BASH_REMATCH[0]}"}"
      if [[ "$rest" =~ $tool_re ]]; then chunk="${rest%%"${BASH_REMATCH[0]}"*}"; else chunk="$rest"; fi
      pre="${chunk%%[;|&]*}"
      case "$pre" in
        *\"* | *\'* | *\`*) ;;
        *) chunk="$pre" ;;
      esac
      if [[ "$chunk" =~ $2 ]]; then
        n=$((n + 1))
        pre="${chunk%%"${BASH_REMATCH[0]}"*}"
        [[ -n "${3:-}" && "$pre" =~ $3 ]] && loose_explicit=1
      fi
      line="$rest"
    done
  done <<<"$raw_command"
  loose_n=$n
}

case "$tool_name" in
  Edit | Write | MultiEdit | NotebookEdit)
    [[ -n "$file_path" ]] || exit 0
    path="$(resolve_path "$file_path" "$cwd")"
    path_allowed "$path" ||
      deny "Manager does not edit project files ($path). Delegate the change to a worker (squad-worker ... --plan <plan>) or add an allowed path via SQUAD_DEVKIT_GUARD_ALLOW."
    ;;
  Bash)
    nl=$'\n'
    # A backslash-newline continues the line: join it before any parsing.
    continuation="\\$nl"
    command="${command//"$continuation"/ }"
    raw_command="$command"
    resolved_commit=0
    resolved_push=0
    workdir="$(resolve_path "$cwd" "$cwd")"
    env_gd=""
    env_wt=""
    # ; & | and backtick start a new segment; ( and ) become segments of their
    # own that save and restore the directory and GIT_DIR / GIT_WORK_TREE state,
    # since a subshell's cd or export does not outlive it.
    separators=';&|`'
    command="$(printf '%s' "$command" | tr "$separators" '\n\n\n\n')"
    command="${command//\(/$nl($nl}"
    command="${command//\)/$nl)$nl}"
    saved_dir=()
    saved_gd=()
    saved_wt=()
    while IFS= read -r segment; do
      case "$segment" in
        '(')
          depth=${#saved_dir[@]}
          saved_dir[depth]="$workdir"
          saved_gd[depth]="$env_gd"
          saved_wt[depth]="$env_wt"
          ;;
        ')')
          depth=${#saved_dir[@]}
          if [[ $depth -eq 0 ]]; then
            workdir="" # unbalanced: the directory can no longer be known
          else
            depth=$((depth - 1))
            workdir="${saved_dir[$depth]}"
            env_gd="${saved_gd[$depth]}"
            env_wt="${saved_wt[$depth]}"
            unset "saved_dir[$depth]" "saved_gd[$depth]" "saved_wt[$depth]"
          fi
          ;;
        *) check_segment "$segment" ;;
      esac
    done <<<"$command"
    # A directory change or GIT_DIR / GIT_WORK_TREE anywhere means a wrapped
    # operation may not run in the session cwd.
    moved_re="(^|[^[:alnum:]_./-])(cd|pushd|popd)([^[:alnum:]_./-]|$)|(^|[^[:alnum:]_])GIT_(DIR|WORK_TREE)=|--chdir|(^|[^[:alnum:]_./-])env[[:space:]]+([^;&|]*[[:space:]])?-C"
    moved=0
    [[ "$raw_command" =~ $moved_re ]] && moved=1
    git_target_re="(^|[[:space:]])['\"]?(-C|--git-dir|--work-tree)([[:space:]=]|$)"
    loose_count git '(^|[[:space:]])commit([^[:alnum:]_-]|$)' "$git_target_re"
    commits=$loose_n
    commit_explicit=$((moved | loose_explicit))
    loose_count git '(^|[[:space:]])push([^[:alnum:]_-]|$)' "$git_target_re"
    pushes=$loose_n
    push_explicit=$((moved | loose_explicit))
    loose_count gh '(^|[[:space:]])pr[[:space:]]+(.*[[:space:]])?merge([^[:alnum:]_-]|$)'
    pushes=$((pushes + loose_n))
    # gh pr merge -R <owner/repo> usually follows the PR number.
    gh_target_re="(^|[[:space:]])['\"]?(-R|--repo)"
    if [[ $loose_n -gt 0 && "$raw_command" =~ $gh_target_re ]]; then push_explicit=1; fi
    # The segment split also cuts quoted wrapper text (bash -c 'cd x && git
    # push'), so the structured parse may have checked a wrapped operation
    # against the wrong directory: with a wrapper present, any named target denies.
    wrapper_re="(^|[^[:alnum:]_.-])((ba|z|da|k)?sh['\"]?[[:space:]]+(-[^[:space:]]+[[:space:]]+)*-[[:alnum:]]*c|eval|xargs)([^[:alnum:]_./-]|$)"
    if [[ "$raw_command" =~ $wrapper_re ]] && [[ $((commit_explicit | push_explicit)) -eq 1 ]]; then
      [[ $commits -gt 0 ]] && deny_unresolved commit
      [[ $pushes -gt 0 ]] && deny_unresolved push
    fi
    [[ $commits -gt $resolved_commit ]] && unverified commit "$commit_explicit"
    [[ $pushes -gt $resolved_push ]] && unverified push "$push_explicit"
    ;;
esac
exit 0
