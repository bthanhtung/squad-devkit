#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/home"
export HOME="$tmp/home"
unset SQUAD_DEVKIT_WORKSPACE SQUAD_WORKTREE_WORKSPACE
# CLI argument forwarding is exercised by squad_worker_smoke.sh.
source "$root/scripts/lib/squad-worker-model.sh"
for engine in claude codex opencode grok agy; do
  model=explicit; squad_worker_select_model
  [[ "$model" == explicit && "$model_source" == flag ]]
  key="SQUAD_WORKER_$(printf '%s' "$engine" | tr '[:lower:]' '[:upper:]')_MODEL"
  export "$key=environment"
  model=''; squad_worker_select_model
  [[ "$model" == environment && "$model_source" == environment ]]
  unset "$key"
  model=''; squad_worker_select_model
  if [[ "$engine" == claude ]]; then
    [[ "$model" == haiku && "$model_source" == builtin ]]
  else
    [[ -z "$model" && "$model_source" == cli-default ]]
  fi
done
# Tier policy must override generic defaults, while explicit flags always win.
for engine in claude codex opencode grok agy; do
  generic_key="SQUAD_WORKER_$(printf '%s' "$engine" | tr '[:lower:]' '[:upper:]')_MODEL"
  export "$generic_key=generic-choice"
  for model_tier in fast balanced strong; do
    key="SQUAD_WORKER_$(printf '%s' "$engine" | tr '[:lower:]' '[:upper:]')_MODEL_$(printf '%s' "$model_tier" | tr '[:lower:]' '[:upper:]')"
    export "$key=tier-choice"
    model=''; squad_worker_select_model
    [[ "$model" == tier-choice && "$model_source" == tier-environment ]] || exit 1
    model=explicit; squad_worker_select_model
    [[ "$model" == explicit && "$model_source" == flag ]] || exit 1
    unset "$key"
  done
  unset "$generic_key"
done
engine=codex; model_tier=balanced; model=''
SQUAD_WORKER_CODEX_MODEL=generic squad_worker_select_model
[[ "$model" == generic ]] || exit 1
for model_tier in fast balanced strong; do
  if (engine=codex; model=''; squad_worker_select_model) 2>"$tmp/error"; then exit 1; fi
  grep -q 'Missing model mapping' "$tmp/error"
  engine=claude; model=''; squad_worker_select_model
  case "$model_tier" in fast) expected=haiku ;; balanced) expected=sonnet ;; strong) expected=opus ;; esac
  [[ "$model" == "$expected" ]] || exit 1
done
for model_tier in invalid $'fast\nstate=completed'; do
  if (model=explicit; squad_worker_select_model) 2>/dev/null; then exit 1; fi
done
if (engine=ccr; model_tier=fast; model=explicit; squad_worker_select_model) 2>"$tmp/error"; then exit 1; fi
grep -q 'CCR model tiers' "$tmp/error"
mkdir "$tmp/empty"
(cd "$tmp/empty"; "$root/scripts/squad-worker.sh" --models --engine codex) >"$tmp/catalog"
jq -e 'length == 4 and all(.engine == "codex" and .provider_availability == "unverified")' "$tmp/catalog" >/dev/null
[[ -z "$(ls -A "$tmp/empty")" ]] || exit 1
for args in '--engine unknown' '--brief bad' '--list' '--model explicit' '--profile high'; do
  if "$root/scripts/squad-worker.sh" --models $args > /dev/null 2>&1; then exit 1; fi
done
if SQUAD_WORKER_CODEX_MODEL_FAST=$'bad\nstate=x' "$root/scripts/squad-worker.sh" --models --engine codex >/dev/null 2>&1; then exit 1; fi
if (cd "$tmp/empty"; "$root/scripts/squad-worker.sh" missing --engine codex --model-tier strong --brief test) 2>"$tmp/error"; then exit 1; fi
grep -q 'SQUAD_WORKER_CODEX_MODEL_STRONG' "$tmp/error"
[[ -z "$(ls -A "$tmp/empty")" ]] || exit 1
mkdir "$tmp/bin"
for tool in bash dirname tr jq; do ln -s "$(command -v "$tool")" "$tmp/bin/$tool"; done
printf '#!/usr/bin/env bash\necho "engine must not launch" >&2; exit 99\n' >"$tmp/bin/claude"
chmod +x "$tmp/bin/claude"
PATH="$tmp/bin" "$root/scripts/squad-worker.sh" --models >"$tmp/catalog"
jq -e 'length == 4 and all(.engine == "claude" and .installed == true)' "$tmp/catalog" >/dev/null
PATH="$tmp/bin" "$root/scripts/squad-worker.sh" --models --engine codex >"$tmp/catalog"
jq -e 'length == 4 and all(.installed == false)' "$tmp/catalog" >/dev/null
for policy in 'Triage task, risk and complexity' 'MCP requires Codex' 'Never silently downgrade' 'Router advice cannot override' 'engine, resolved model, tier, profile'; do
  grep -qF "$policy" "$root/templates/devkit/manager-devkit.md"
done
model_tier=''
engine=ccr; model=''
squad_worker_select_model
[[ "$model_source" == router-default ]]
if (model=explicit; squad_worker_select_model) 2>"$tmp/error"; then exit 1; fi
grep -q 'router' "$tmp/error"
if (engine=codex; model=$'bad\nstate=completed'; squad_worker_select_model) 2>/dev/null; then exit 1; fi
if (engine=codex; model=$'bad\033model'; squad_worker_select_model) 2>/dev/null; then exit 1; fi
cat >"$tmp/events" <<'JSON'
{"type":"system","subtype":"init","model":"reported-alias"}
{"type":"assistant","message":{"model":"reported-model","content":[]}}
{"type":"result","modelUsage":{"reported-model":{},"second-model":{}}}
{"type":"assistant","message":{"model":"bad\nstate=completed"}}
JSON
[[ "$(squad_worker_reported_models claude "$tmp/events")" == reported-model,second-model ]]
[[ "$(squad_worker_reported_models ccr "$tmp/events")" == reported-model,second-model ]]
[[ -z "$(squad_worker_reported_models codex "$tmp/events")" ]]
: >"$tmp/log"
printf 'log=%s\n' "$tmp/log" >"$tmp/run.status"
printf 'worker=test\nengine=codex\nprofile=high\nmodel_tier=strong\nmodel=chosen\nrequested_model=chosen\nmodel_source=flag\nactual_model=reported\nstate=completed\nstarted=1\nfinished=2\n' >>"$tmp/run.status"
for args in "$tmp/run.status" "--all $tmp"; do
  # Intentional splitting for the two supported invocations.
  "$root/scripts/squad-worker-monitor.sh" $args --once >"$tmp/frame"
  grep -q 'requested=chosen' "$tmp/frame"
  grep -q 'tier=strong' "$tmp/frame"
  grep -q 'actual=reported' "$tmp/frame"
done
ln -s "$root/scripts/squad-worker-monitor.sh" "$tmp/squad-monitor"
"$tmp/squad-monitor" "$tmp/run.status" --once >"$tmp/frame"
grep -q 'actual=reported' "$tmp/frame"
printf 'state=running\npid=%s\n' "$$" >>"$tmp/run.status"
mkdir -p "$tmp/.squad/workers"
cp "$tmp/run.status" "$tmp/.squad/workers/test.status"
printf '#!/usr/bin/env bash\nexit 99\n' >"$tmp/bin/squad"
chmod +x "$tmp/bin/squad"
PATH="$tmp/bin:$PATH" SQUAD_DEVKIT_WORKSPACE="$tmp" "$root/scripts/squad-worker.sh" --list >"$tmp/list"
grep -q 'requested=chosen.*actual=reported.*tier=strong' "$tmp/list"

(
  sleep 1
  printf 'actual_model=live-reported\nstate=completed\n' >>"$tmp/run.status"
) &
SQUAD_WORKER_PANE_HOLD=0 "$root/scripts/squad-worker-monitor.sh" "$tmp/run.status" >"$tmp/live"
wait
grep -q 'actual=live-reported' "$tmp/live"
echo 'PASS: worker model selection, evidence, injection rejection, and monitors'

# Saved JSON is shared by resolution and catalog, and never executed.
mkdir -p "$tmp/project/.squad" "$tmp/project/sub" "$tmp/outside"
project_directory="$tmp/project/sub"
cat >"$tmp/project/.squad/worker-models.json" <<'JSON'
{"version":1,"engines":{"codex":{"fast":{"model":"saved-fast","effort":"low"},"balanced":{"model":"saved-balanced","effort":"high"},"strong":{"model":"saved-strong"}}}}
JSON
engine=codex; model_tier=balanced; model=''; squad_worker_select_model
[[ "$model" == saved-balanced && "$model_source" == saved && "$model_effort" == high ]]
model=explicit; squad_worker_select_model
[[ "$model" == explicit && -z "$model_effort" ]]
model=''; SQUAD_WORKER_CODEX_MODEL=generic squad_worker_select_model
[[ "$model" == generic && -z "$model_effort" ]]
model=''; SQUAD_WORKER_CODEX_MODEL_BALANCED=tier squad_worker_select_model
[[ "$model" == tier && -z "$model_effort" ]]
(cd "$tmp/outside"; "$root/scripts/squad-worker.sh" --models --engine codex --project "$tmp/project/sub") >"$tmp/catalog"
jq -e '.[] | select(.tier == "balanced") | .candidate == "saved-balanced" and .effort == "high" and .source == "saved"' "$tmp/catalog" >/dev/null
(cd "$tmp/outside"; SQUAD_DEVKIT_WORKSPACE="$tmp/project" "$root/scripts/squad-worker.sh" --models --engine codex) >"$tmp/catalog"
jq -e '.[] | select(.tier == "fast") | .candidate == "saved-fast"' "$tmp/catalog" >/dev/null
for invalid in '{broken' '{"version":2,"engines":{}}' '{"version":1,"engines":{"codex":{"balanced":{"model":"bad\nmodel"}}}}' '{"version":1,"engines":{"codex":{"balanced":{"model":"valid","effort":"unsupported"}}}}'; do
  printf '%s\n' "$invalid" >"$tmp/project/.squad/worker-models.json"
  if (model=''; squad_worker_select_model) 2>"$tmp/error"; then exit 1; fi
  grep -q 'squad config workers' "$tmp/error"
done
printf '{"version":1,"engines":{"codex":{"balanced":{"model":"$(touch marker)"}}}}' >"$tmp/project/.squad/worker-models.json"
if (model=''; squad_worker_select_model) 2>/dev/null; then exit 1; fi
[[ ! -e marker ]]
echo 'PASS: saved mappings, project/catalog lookup, effort, precedence, invalid JSON'
