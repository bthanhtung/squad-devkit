#!/usr/bin/env bash
# Isolated git worktrees for squad workers. Each worker gets its own worktree
# and branch (squad/<worker-id>) under the squad workspace,
# .squad/worktrees/<repository>-<hash>/<worker-id>, which `git status` ignores
# through .git/info/exclude. (Not inside .git: agents treat files there as
# sensitive and refuse to edit them.) A worktree starts from a snapshot of the
# repository's working tree (tracked and untracked files, minus ignored ones)
# taken without touching the real index, and its changes come back as a patch
# applied with a three-way merge.

worktree_repository_root() {
  git -C "$1" rev-parse --show-toplevel 2>/dev/null
}

# Worktree directory for a repository: worktree_home <repository-root>.
# SQUAD_WORKTREE_WORKSPACE (the squad workspace) must be set.
worktree_home() {
  local root="$1" hash
  hash="$(printf '%s' "$root" | cksum | cut -d ' ' -f 1)"
  printf '%s/.squad/worktrees/%s-%s\n' "${SQUAD_WORKTREE_WORKSPACE:?}" "$(basename "$root")" "$hash"
}

# Keeps .squad/ out of `git status` when the worktrees live inside the repository.
worktree_exclude_squad() {
  local root="$1" exclude
  case "${SQUAD_WORKTREE_WORKSPACE:?}/" in
    "$root"/*) ;;
    *) return 0 ;;
  esac
  exclude="$(git -C "$root" rev-parse --path-format=absolute --git-path info/exclude)" || return 0
  mkdir -p "$(dirname "$exclude")"
  grep -qxE '/?\.squad/?' "$exclude" 2>/dev/null || printf '.squad/\n' >>"$exclude"
}

# Prints a commit holding the repository's current working tree.
worktree_snapshot() {
  local root="$1" index tree
  local parent=()
  index="$(mktemp)"
  rm -f "$index"
  if git -C "$root" rev-parse -q --verify HEAD >/dev/null; then
    GIT_INDEX_FILE="$index" git -C "$root" read-tree HEAD
    parent=(-p HEAD)
  fi
  GIT_INDEX_FILE="$index" git -C "$root" add -A
  tree="$(GIT_INDEX_FILE="$index" git -C "$root" write-tree)"
  rm -f "$index"
  git -C "$root" -c user.name=squad-devkit -c user.email=squad-devkit@localhost \
    commit-tree "$tree" ${parent[@]+"${parent[@]}"} -m "squad-devkit snapshot"
}

# Prints the worker's worktree path, creating it from a fresh snapshot unless an
# unmerged one already exists (fix rounds continue in the same worktree).
worktree_create() {
  local root="$1" id="$2" home path base
  home="$(worktree_home "$root")" || return 1
  path="$home/$id"
  mkdir -p "$home"
  worktree_exclude_squad "$root"
  if [[ -d "$path" && -f "$home/$id.base" ]]; then
    printf '%s\n' "$path"
    return 0
  fi
  # Serialise creation: parallel workers share the repository's worktree metadata.
  for _ in $(seq 1 60); do
    mkdir "$home/.lock" 2>/dev/null && break
    sleep 0.25
  done
  base="$(worktree_snapshot "$root")" &&
    git -C "$root" worktree add -q -f -B "squad/$id" "$path" "$base" >/dev/null 2>&1 &&
    printf '%s\n' "$base" >"$home/$id.base"
  local status=$?
  rmdir "$home/.lock" 2>/dev/null || true
  (( status == 0 )) || return "$status"
  printf '%s\n' "$path"
}

worktree_base() {
  local home
  home="$(worktree_home "$1")" || return 1
  cat "$home/$2.base" 2>/dev/null
}

# Commits whatever the worker left in its worktree to its branch.
worktree_commit() {
  local path="$1" message="$2"
  git -C "$path" add -A
  if ! git -C "$path" diff --cached --quiet; then
    git -C "$path" -c user.name=squad-devkit -c user.email=squad-devkit@localhost \
      commit -q --no-verify -m "$message"
  fi
}

# Prints the worker's changes since its snapshot as a binary-safe patch.
worktree_patch() {
  local root="$1" id="$2" home base
  home="$(worktree_home "$root")" || return 1
  base="$(worktree_base "$root" "$id")" || return 1
  git -C "$home/$id" diff --binary "$base" HEAD
}

# Applies a patch to the repository's working tree with a three-way merge.
# A temporary index built from the working tree stands in for the real one,
# which stays untouched; conflicts leave standard markers in the files.
worktree_apply() {
  local root="$1" patch="$2" index status=0
  index="$(mktemp)"
  rm -f "$index"
  if git -C "$root" rev-parse -q --verify HEAD >/dev/null; then
    GIT_INDEX_FILE="$index" git -C "$root" read-tree HEAD
  fi
  GIT_INDEX_FILE="$index" git -C "$root" add -A
  GIT_INDEX_FILE="$index" git -C "$root" apply --3way "$patch" 2>&1 || status=$?
  rm -f "$index"
  return "$status"
}

worktree_remove() {
  local root="$1" id="$2" home
  home="$(worktree_home "$root")" || return 1
  git -C "$root" worktree remove --force "$home/$id" >/dev/null 2>&1 || rm -rf "${home:?}/$id"
  git -C "$root" worktree prune >/dev/null 2>&1 || true
  git -C "$root" branch -D -q "squad/$id" >/dev/null 2>&1 || true
  rm -f "$home/$id.base"
}
