#!/usr/bin/env bash
# Foreground scheduler; all launches and merges use the normal worker entry point.
squad_dag_run() (
  local launcher="$1" plan="" manager="${SQUAD_MANAGER_ID:-}" jobs=3 cap="" dry=0 merge=0
  local retries=' ' arg id entry header deps file state lock owner host pid started actual
  local i j n count=0 active done_count launched_count progress workspace
  local ids=() engines=() tiers=() roles=() owns=() verifies=() dependencies=() hashes=() states=() files=() launched=() children=() visited=()
  shift
  while (( $# )); do
    arg="$1"; shift
    case "$arg" in
      --dry-run) dry=1;;
      --merge-if-green) merge=1;;
      --run-plan|--manager|--jobs|--max-launches|--retry)
        (( $# )) && [[ -n "$1" ]] || { echo "Missing value for $arg" >&2; exit 2; }
        case "$arg" in
          --run-plan) plan="$1";; --manager) manager="$1";; --jobs) jobs="$1";;
          --max-launches) cap="$1";;
          --retry)
            [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo 'Invalid retry task ID'; exit 2; }
            retries="$retries$1 ";;
        esac
        shift;;
      *) echo "Invalid run-plan option: $arg" >&2; exit 2;;
    esac
  done
  [[ -n "$manager" && -f "$plan" && "$jobs" =~ ^[1-9][0-9]*$ && ( -z "$cap" || "$cap" =~ ^[1-9][0-9]*$ ) ]] || { echo 'run-plan requires a plan, --manager, and positive --jobs/--max-launches' >&2; exit 2; }
  plan="$(cd "$(dirname "$plan")" && pwd -P)/$(basename "$plan")"
  workspace="${SQUAD_DEVKIT_WORKSPACE:-$PWD}"
  while [[ ! -d "$workspace/.squad" ]]; do
    [[ "$workspace" != / ]] || { echo 'No .squad workspace found'; exit 2; }
    workspace="$(dirname "$workspace")"
  done
  cd "$workspace" || exit 2
  # Parse every entry before acquiring a lock or launching anything.
  while IFS= read -r id; do
    [[ "$id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo "Invalid task ID: $id"; exit 2; }
    for arg in "${ids[@]+${ids[@]}}"; do [[ "$arg" != "$id" ]] || { echo "Duplicate task ID: $id"; exit 2; }; done
    entry="$(plan_task_entry "$plan" "$id")"
    header="${entry%%$'\n'*}"
    if [[ ! "$header" =~ ^(-\ |###\ )[A-Za-z0-9._-]+\ \(([A-Za-z0-9_-]+)\ (fast|balanced|strong),\ ([A-Za-z0-9_-]+)\):\ .+ ]]; then
      echo "Task $id requires engine, tier (fast|balanced|strong), and role"; exit 2
    fi
    engines[count]="${BASH_REMATCH[2]}"; tiers[count]="${BASH_REMATCH[3]}"; roles[count]="${BASH_REMATCH[4]}"
    owns[count]=""; verifies[count]=""
    if [[ "$entry" =~ Files:\ ([^$'\n']+) ]]; then
      file="${BASH_REMATCH[1]}"; file="${file%%. Depends on:*}"; file="${file%%. Verify:*}"; owns[count]="${file%.}"
    fi
    [[ -n "${owns[count]}" || "${roles[count]}" == reviewer ]] || { echo "Task $id requires Files"; exit 2; }
    [[ "$entry" =~ Depends\ on:\ ([A-Za-z0-9_,.\ -]+) ]] || { echo "Task $id requires Depends on"; exit 2; }
    deps="${BASH_REMATCH[1]}"; deps="${deps%%. Verify*}"; deps="${deps%.}"; deps="${deps//,/ }"
    [[ "$deps" != none ]] || deps=""
    dependencies[count]="$deps"
    if [[ "$entry" =~ Verify:\ \`([^\`]+)\` ]]; then verifies[count]="${BASH_REMATCH[1]}"
    elif [[ "$entry" == *"Verify:"* ]]; then echo "Task $id has invalid Verify syntax"; exit 2; fi
    hashes[count]="$(plan_task_entry "$plan" "$id" | shasum -a 256 | awk '{print $1}')"
    ids[count]="$id"; launched[count]=0; visited[count]=0; count=$((count+1))
  done < <(plan_section "$plan" Tasks | awk '/^- / || /^### / {sub(/^(- |### )/, ""); sub(/[ \t:(].*$/, ""); print}')
  (( count )) || { echo 'Plan has no tasks'; exit 2; }
  for id in $retries; do
    progress=0
    for arg in "${ids[@]}"; do [[ "$id" != "$arg" ]] || progress=1; done
    (( progress )) || { echo "Unknown retry task: $id"; exit 2; }
  done
  for ((i=0;i<count;i++)); do
    for id in ${dependencies[i]}; do
      progress=0
      for arg in "${ids[@]}"; do [[ "$id" != "$arg" ]] || progress=1; done
      (( progress )) || { echo "Unknown dependency: $id"; exit 2; }
    done
  done
  for ((n=0;n<count;n++)); do
    progress=0
    for ((i=0;i<count;i++)); do
      (( visited[i] == 0 )) || continue
      active=0
      for id in ${dependencies[i]}; do
        for ((j=0;j<count;j++)); do [[ "$id" != "${ids[j]}" ]] || (( visited[j] )) || active=1; done
      done
      if (( active == 0 )); then visited[i]=1; progress=1; fi
    done
    (( progress )) || break
  done
  for ((i=0;i<count;i++)); do (( visited[i] )) || { echo 'Dependency cycle'; exit 2; }; done
  cap="${cap:-$count}"
  mkdir -p .squad/run-plan
  lock=".squad/run-plan/$(printf '%s' "$plan" | shasum -a 256 | awk '{print $1}').lock"
  host="$(hostname -s 2>/dev/null || uname -n)"
  if ! mkdir "$lock" 2>/dev/null; then
    owner="$lock/owner"; pid="$(status_get "$owner" pid)"; started="$(status_get "$owner" started)"
    if [[ "$(status_get "$owner" host)" == "$host" && "$pid" =~ ^[1-9][0-9]*$ && -n "$started" ]] && actual="$(LC_ALL=C ps -axo pid=,lstart= 2>/dev/null)" && ! awk -v pid="$pid" '$1==pid {found=1} END {exit !found}' <<<"$actual"; then
      # Claim stale cleanup before deleting: two reclaimers must not remove a new lock.
      mkdir "$lock/reclaim" 2>/dev/null || { echo 'Another runner is reclaiming the plan lock'; exit 3; }
      if [[ "$(status_get "$owner" pid)" != "$pid" || "$(status_get "$owner" started)" != "$started" || "$(status_get "$owner" host)" != "$host" ]]; then
        rmdir "$lock/reclaim"; echo 'Plan lock owner changed'; exit 3
      fi
      # Rename the claimed directory atomically; never expose an ownerless lock.
      [[ ! -e "$lock.stale.$$" ]] || exit 3
      mv "$lock" "$lock.stale.$$" || exit 3
      rm -f "$lock.stale.$$/owner"
      rmdir "$lock.stale.$$/reclaim" "$lock.stale.$$"
      mkdir "$lock" 2>/dev/null || exit 3
    else echo 'Another runner holds the plan lock'; exit 3; fi
  fi
  printf 'pid=%s\nhost=%s\nstarted=%s\n' "$$" "$host" "$(date +%s)" >"$lock/owner"
  trap 'rm -f "$lock/owner"; rmdir "$lock" 2>/dev/null || true' EXIT
  while :; do
    active=0; done_count=0
    for ((i=0;i<count;i++)); do
      file=""
      while IFS= read -r arg; do
        if [[ "$(status_get "$arg" plan)" == "$plan" && "$(status_get "$arg" plan_task)" == "${ids[i]}" ]]; then file="$arg"; break; fi
      done < <(ls -t .squad/workers/*.status 2>/dev/null || true)
      files[i]="$file"; state=ready
      if [[ -n "$file" ]]; then
        reconcile_status "$file"
        state="$(status_get "$file" state)"
        if [[ "$state" == running ]]; then state=running
        elif [[ "$(status_get "$file" plan_task_sha256)" != "${hashes[i]}" ]]; then state=changed
        elif [[ "$state" == failed || "$state" == lost || "$state" == stopped || "$(status_get "$file" verify)" =~ ^(fail|timeout)$ ]]; then state=failed
        elif [[ -n "$(status_get "$file" merged)" ]]; then state="done"
        elif [[ "$state" == "done" || "$state" == completed ]]; then state='blocked by manager'
        else state=failed; fi
        if [[ "$state" != running && "$retries" == *" ${ids[i]} "* && "${launched[i]}" == 0 ]]; then state=ready; fi
      fi
      [[ "$state" != running ]] || active=$((active+1))
      [[ "$state" != "done" ]] || done_count=$((done_count+1))
      states[i]="$state"
    done
    for ((i=0;i<count;i++)); do
      [[ "${states[i]}" == ready ]] || continue
      for id in ${dependencies[i]}; do
        for ((j=0;j<count;j++)); do
          if [[ "$id" == "${ids[j]}" && "${states[j]}" != "done" ]]; then states[i]="blocked by $id"; fi
        done
      done
    done
    printf 'ID / STATE / ENGINE TIER\n'
    for ((i=0;i<count;i++)); do
      printf '%s / %s / %s %s\n' "${ids[i]}" "${states[i]}" "${engines[i]}" "${tiers[i]}"
      case "${states[i]}" in
        changed) echo "task ${ids[i]} changed since its run; relaunch with --retry ${ids[i]}";;
        failed) echo "blocked: ${ids[i]} failed; fix with squad-worker ${ids[i]} or --retry ${ids[i]}";;
      esac
    done
    (( done_count != count )) || exit 0
    (( dry == 0 )) || exit 3
    progress=0
    if (( merge )); then
      for ((i=0;i<count;i++)); do
        [[ "${states[i]}" == 'blocked by manager' ]] || continue
        if [[ "$(status_get "${files[i]}" verify)" == pass ]]; then
          # --merge selects by worker ID: never let it select another plan's run.
          file=""
          while IFS= read -r arg; do
            [[ "$(status_get "$arg" worker)" != "${ids[i]}" ]] || { file="$arg"; break; }
          done < <(ls -t .squad/workers/*.status 2>/dev/null || true)
          if [[ "$file" != "${files[i]}" ]]; then
            echo "Waiting on manager: ${ids[i]} has a newer run in another plan"; exit 3
          fi
          "$launcher" --merge "${ids[i]}" || { echo "Waiting on manager: ${ids[i]} and its dependents"; exit 3; }
          [[ -n "$(status_get "${files[i]}" merged)" ]] || { echo "Waiting on manager: ${ids[i]} was not merged"; exit 3; }
          progress=1
        fi
      done
      (( progress == 0 )) || continue
    fi
    children=(); launched_count=0
    for ((i=0;i<count;i++)); do
      [[ "${states[i]}" == ready && "${launched[i]}" == 0 ]] || continue
      (( active < jobs && launched_count < cap )) || continue
      local args=("${ids[i]}" --task "${ids[i]}" --plan-task "${ids[i]}" --plan "$plan" --manager "$manager" --engine "${engines[i]}" --model-tier "${tiers[i]}" --role "${roles[i]}")
      [[ -z "${owns[i]}" ]] || args+=(--own "${owns[i]}")
      [[ -z "${verifies[i]}" ]] || args+=(--verify "${verifies[i]}")
      "$launcher" "${args[@]}" &
      children[${#children[@]}]=$!
      launched[i]=1; active=$((active+1)); launched_count=$((launched_count+1)); progress=1
    done
    cap=$((cap-launched_count))
    for pid in "${children[@]+${children[@]}}"; do wait "$pid" || true; done
    (( progress )) || exit 3
  done
)
