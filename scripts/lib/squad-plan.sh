#!/usr/bin/env bash
# Plan files for the squad manager (see templates/devkit/plan.md.example).
# A plan is markdown with `## Heading` sections; headings match case-insensitively.
# Sourcing this file has no side effects.

# Inspect help rather than invoking unknown commands: older squad joins them as roles.
squad_supports() {
  [[ "${SQUAD_RUST_DISABLE:-0}" != 1 ]] || return 1
  command -v squad >/dev/null 2>&1 || return 1
  squad help 2>/dev/null | grep "^  squad $1 " >/dev/null
}

# Cache by binary path so switching PATH cannot reuse another binary's capabilities.
squad_supports_plan_v2() {
  [[ "${SQUAD_RUST_DISABLE:-0}" != 1 ]] || return 1
  local binary usage
  binary="$(command -v squad)" || return 1
  if [[ "${_SQUAD_PLAN_V2_BINARY:-}" != "$binary" ]]; then
    _SQUAD_PLAN_V2_BINARY="$binary"
    _SQUAD_PLAN_V2_SUPPORTED=0
    if squad_supports plan; then
      usage="$(squad plan 2>&1 || true)"
      [[ "$usage" != *append-approval* ]] || _SQUAD_PLAN_V2_SUPPORTED=1
    fi
  fi
  [[ "${_SQUAD_PLAN_V2_SUPPORTED:-0}" == 1 ]]
}

# Prints the body of the `## <name>` section (without its heading): plan_section <file> <name>.
plan_section() {
  awk -v name="$2" '
    BEGIN { name = tolower(name) }
    /^## / {
      heading = tolower($0)
      sub(/^## +/, "", heading)
      sub(/[ \t:]+$/, "", heading)
      inside = (heading == name)
      next
    }
    inside { print }
  ' "$1"
}

plan_has_section() {
  awk -v name="$2" '
    BEGIN { name = tolower(name) }
    /^## / {
      heading = tolower($0)
      sub(/^## +/, "", heading)
      sub(/[ \t:]+$/, "", heading)
      if (heading == name) found = 1
    }
    END { exit found ? 0 : 1 }
  ' "$1"
}

# Prints the value of a `- <Label>: value` bullet in the Triage section.
plan_triage_value() {
  plan_section "$1" Triage | awk -v label="$2" '
    BEGIN { label = tolower(label) }
    {
      line = $0
      sub(/^[ \t]*[-*][ \t]+/, "", line)
      key = tolower(substr(line, 1, index(line, ":") - 1))
      if (index(line, ":") > 0 && key == label) {
        value = substr(line, index(line, ":") + 1)
        sub(/^[ \t]+/, "", value)
        sub(/[ \t]+$/, "", value)
        print value
        exit
      }
    }'
}

# Prints the first word of a Triage value, lowercased, without trailing punctuation:
# `Moderate. text` -> moderate, `high — text` -> high.
plan_triage_level() {
  local word
  word="$(plan_triage_value "$1" "$2" | awk '{ print tolower($1) }')"
  while [[ "$word" == *[.,\;:\)—-] ]]; do
    word="${word%[.,\;:\)-]}"
    word="${word%—}"
  done
  printf '%s\n' "$word"
}

# Prints one line per missing item; returns 0 when the plan is valid.
plan_validate() {
  if squad_supports plan; then squad plan validate "$@"; return $?; fi
  local file="$1" missing=0 section label value body lowered
  if [[ ! -f "$file" ]]; then
    printf 'file not found: %s\n' "$file"
    return 1
  fi
  for section in Triage Goal Perspectives Tasks Acceptance; do
    if [[ "$section" == Perspectives && "$(plan_triage_level "$file" Risk)" == low && "$(plan_triage_level "$file" Complexity)" == low ]]; then
      continue
    fi
    if ! plan_has_section "$file" "$section"; then
      printf 'missing section: ## %s\n' "$section"
      missing=1
    fi
  done
  if plan_has_section "$file" Triage; then
    value="$(plan_triage_level "$file" Risk)"
    case "$value" in
      low|moderate|high) ;;
      *) printf 'missing triage line: - Risk: low|moderate|high\n'; missing=1 ;;
    esac
    value="$(plan_triage_level "$file" Complexity)"
    case "$value" in
      low|moderate|high) ;;
      *) printf 'missing triage line: - Complexity: low|moderate|high\n'; missing=1 ;;
    esac
    value="$(plan_triage_value "$file" squad-route)"
    if [[ -z "$value" ]]; then
      printf 'missing triage line: - squad-route: <route>\n'
      missing=1
    fi
  fi
  if plan_has_section "$file" Perspectives; then
    body="$(plan_section "$file" Perspectives | tr '[:upper:]' '[:lower:]')"
    for label in 'Principal engineer' 'Engineering manager' 'Technical lead' 'QA/QC' 'End user'; do
      lowered="$(printf '%s' "$label" | tr '[:upper:]' '[:lower:]')"
      if [[ "$body" != *"$lowered"* ]]; then
        printf 'missing perspective: %s\n' "$label"
        missing=1
      fi
    done
  fi
  return "$missing"
}

# Prints the lowercased Triage value (low, moderate, high) or nothing: plan_field <file> risk|complexity.
plan_field() {
  local value
  case "$2" in
    risk) value="$(plan_triage_level "$1" Risk)" ;;
    complexity) value="$(plan_triage_level "$1" Complexity)" ;;
    *) return 0 ;;
  esac
  case "$value" in
    low|moderate|high) printf '%s\n' "$value" ;;
  esac
  return 0
}

# Returns 0 when the Approvals section holds `- <action>: <repo>`, `- <action>: *`
# or `- <action>: <absolute path>` equal to <repo_path> (both compared physically):
# plan_approves <file> <action> <repo> [<repo_path>].
plan_approves() {
  local file="$1" action="$2" repo="$3" repo_path="${4:-}" value
  [[ -f "$file" ]] || return 1
  if [[ -n "$repo_path" && -d "$repo_path" ]]; then
    repo_path="$(cd "$repo_path" && pwd -P)" || repo_path=""
  fi
  while IFS= read -r value; do
    case "$value" in
      '') ;;
      '*') return 0 ;;
      /*)
        [[ -n "$repo_path" ]] || continue
        [[ "$value" == / ]] || value="${value%/}"
        [[ "$value" == "$repo_path" ]] && return 0
        [[ -d "$value" && "$(cd "$value" && pwd -P)" == "$repo_path" ]] && return 0
        ;;
      *) [[ "$value" == "$repo" ]] && return 0 ;;
    esac
  done < <(plan_section "$file" Approvals | awk -v action="$action" '
    BEGIN { action = tolower(action) }
    {
      line = $0
      if (line !~ /^[ \t]*[-*][ \t]+/) next
      sub(/^[ \t]*[-*][ \t]+/, "", line)
      colon = index(line, ":")
      if (colon == 0) next
      if (tolower(substr(line, 1, colon - 1)) != action) next
      value = substr(line, colon + 1)
      sub(/^[ \t]+/, "", value)
      sub(/[ \t].*$/, "", value)
      sub(/—.*$/, "", value)
      print value
    }
  ')
  return 1
}

# Prints every plan (non-recursive) in a directory that approves the action,
# newest mtime first; returns 1 when none does:
# plan_list_approvals <dir> <action> <repo> [<repo_path>].
plan_list_approvals() {
  if squad_supports plan; then squad plan approves "$@"; return $?; fi
  local dir="$1" action="$2" repo="$3" repo_path="${4:-}" file status=1
  [[ -d "$dir" ]] || return 1
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    if plan_approves "$dir/$file" "$action" "$repo" "$repo_path"; then
      printf '%s\n' "$dir/$file"
      status=0
    fi
  done < <(cd "$dir" 2>/dev/null && ls -t -- *.md 2>/dev/null)
  return "$status"
}

# Prints the newest approving plan: plan_find_approval <dir> <action> <repo> [<repo_path>].
plan_find_approval() {
  local plans
  plans="$(plan_list_approvals "$@")" || return 1
  printf '%s\n' "${plans%%$'\n'*}"
}

# Prints the shared context sections (Goal, Findings, Decisions) from a plan file,
# plus an optional <plan-stem>.context.md companion file (bounded to
# SQUAD_WORKER_MAX_CONTEXT_BYTES, default 16384): plan_shared_context <file>.
plan_shared_context() {
  if squad_supports plan; then squad plan context "$@"; return $?; fi
  local file="$1" section body companion max_bytes="${SQUAD_WORKER_MAX_CONTEXT_BYTES:-16384}"
  [[ -f "$file" ]] || return 0
  for section in Goal Findings Decisions; do
    if plan_has_section "$file" "$section"; then
      body="$(plan_section "$file" "$section" | awk 'NF { found = 1 } found { print }')"
      if [[ -n "$body" ]]; then
        printf '### Plan %s\n%s\n\n' "$section" "$body"
      fi
    fi
  done
  companion="${file%.md}.context.md"
  if [[ "$companion" != "$file" && -f "$companion" && -s "$companion" ]]; then
    printf '### Shared Context (%s)\n' "$(basename "$companion")"
    python3 - "$companion" "$max_bytes" <<'PYTHON'
import sys
with open(sys.argv[1], 'rb') as source:
    text = source.read().decode('utf-8', errors='replace')
limit = int(sys.argv[2])
if limit < 0:
    raise ValueError('context byte limit must be nonnegative')
sys.stdout.buffer.write(text.encode('utf-8')[:limit].decode('utf-8', errors='ignore').encode('utf-8'))
PYTHON
    local status=$?
    [[ "$status" == 0 ]] || return "$status"
    printf '\n\n'
  fi
  return 0
}

# Adds a bullet to the end of the Approvals section, creating the section at the
# end of the file when missing: plan_append_approval <file> <bullet line>.
# Only a single review-override or plan-review-override line is accepted, so
# a reason cannot smuggle in another approval. The entry reaches awk through the
# environment: `awk -v` would turn a typed `\n` into a real newline.
plan_append_approval() {
  if squad_supports_plan_v2; then squad plan append-approval "$@"; return $?; fi
  local file="$1" line="$2" tmp
  case "$line" in
    *$'\n'* | *$'\r'*) return 2 ;;
    '- review-override: '?* | '- plan-review-override: '?*) ;;
    *) return 2 ;;
  esac
  if ! plan_has_section "$file" Approvals; then
    {
      [[ ! -s "$file" ]] || printf '\n'
      printf '## Approvals\n%s\n' "$line"
    } >>"$file"
    return 0
  fi
  tmp="$(mktemp "$file.XXXXXX")" || return 1
  # Copy the plan's mode and timestamps first: mktemp creates the file as 0600.
  cp -p "$file" "$tmp" || { rm -f "$tmp"; return 1; }
  if ENTRY="$line" awk '
    function flush() {
      if (inside && !done) { print ENVIRON["ENTRY"]; printf "%s", blanks; done = 1 }
      blanks = ""
    }
    /^## / {
      heading = tolower($0)
      sub(/^## +/, "", heading)
      sub(/[ \t:]+$/, "", heading)
      flush()
      inside = (heading == "approvals" && !done)
      print
      next
    }
    inside && /^[ \t]*$/ { blanks = blanks $0 "\n"; next }
    inside { printf "%s", blanks; blanks = ""; print; next }
    { print }
    END { flush() }
  ' "$file" >"$tmp"; then
    mv -f "$tmp" "$file" && return 0
  fi
  rm -f "$tmp"
  return 1
}

# Best effort secondary storage: the atomic status file remains authoritative.
squad_record_status() {
  squad_supports run || return 0
  local file="$1" directory workspace
  directory="$(cd "$(dirname "$file")" && pwd -P)" || return 0
  workspace="$(dirname "$(dirname "$directory")")"
  [[ -d "$workspace/.squad" ]] || return 0
  if ! squad run record --workspace "$workspace" --status-file "$directory/$(basename "$file")"; then
    printf 'squad-worker: could not index status in SQLite: %s\n' "$file" >&2
  fi
  return 0
}

# Exact IDs in top-level bullets or ### headings; nested lines belong to the entry.
# Prints the task body only when exactly one nonempty entry matches.
plan_task() {
  if squad_supports_plan_v2; then squad plan task "$@"; return $?; fi
  plan_section "$1" Tasks | TASK_ID="$2" awk '
    /^- / || /^### / {
      line = $0
      sub(/^(- |### )/, "", line)
      id = line
      sub(/[ \t:(].*$/, "", id)
      inside = (id == ENVIRON["TASK_ID"])
      if (inside) {
        matches++
        sub(/^[^ \t:(]+[ \t]*/, "", line)
        sub(/^\([^)]*\)[ \t]*/, "", line)
        sub(/^:[ \t]*/, "", line)
        body = body line "\n"
        if (line ~ /[^ \t]/) nonempty = 1
      }
      next
    }
    inside {
      body = body $0 "\n"
      if ($0 ~ /[^ \t]/) nonempty = 1
    }
    END {
      if (matches != 1 || !nonempty) exit 1
      printf "%s", body
    }
  '
}

# The complete entry, including routing metadata, is the DAG run identity.
plan_task_entry() {
  if squad_supports_plan_v2; then squad plan task-entry "$@"; return $?; fi
  plan_section "$1" Tasks | TASK_ID="$2" awk '
    /^- / || /^### / {
      line=$0; sub(/^(- |### )/, "", line)
      sub(/[ \t:(].*$/, "", line)
      inside=(line == ENVIRON["TASK_ID"])
      if (inside) matches++
    }
    inside { body = body $0 "\n" }
    END { if (matches != 1) exit 1; printf "%s", body }
  '
}
