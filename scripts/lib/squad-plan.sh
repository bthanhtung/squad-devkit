#!/usr/bin/env bash
# Plan files for the squad manager (see templates/devkit/plan.md.example).
# A plan is markdown with `## Heading` sections; headings match case-insensitively.
# Sourcing this file has no side effects.

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
  local file="$1" missing=0 section label value body lowered
  if [[ ! -f "$file" ]]; then
    printf 'file not found: %s\n' "$file"
    return 1
  fi
  for section in Triage Goal Perspectives Tasks Acceptance; do
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

# Adds a bullet to the end of the Approvals section, creating the section at the
# end of the file when missing: plan_append_approval <file> <bullet line>.
# Only a single `- review-override: …` line is accepted (status 2 otherwise), so
# a reason cannot smuggle in another approval. The entry reaches awk through the
# environment: `awk -v` would turn a typed `\n` into a real newline.
plan_append_approval() {
  local file="$1" line="$2" tmp
  case "$line" in
    *$'\n'* | *$'\r'*) return 2 ;;
    '- review-override: '?*) ;;
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
