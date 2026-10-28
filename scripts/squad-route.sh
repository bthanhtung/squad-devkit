#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: squad-route "<redacted task digest>"

Optional advisory triage for the manager. Sends a short, redacted digest of a
task (request, plan summary, target files, risks; never source code, secrets,
tokens, logs, or personal data) to a typed-decision router and prints its
recommendation as one JSON object:

  {"configured":true,"workstream":"code","confidence":0.91,"risk":"moderate",
   "complexity":"high","needs_human":0.12,"accept":true}

The router is advisory only (shadow mode): the manager records it next to its
own decision and never lets it authorize destructive actions, security
decisions, deployments, or skipping human approval. "accept" is true only when
confidence >= SQUAD_DEVKIT_ROUTER_MIN_CONFIDENCE (0.85), needs_human < 0.5, and
the risk is not high.

Configuration (unset URL means not configured; the command prints
{"configured":false} and exits 0):
  SQUAD_DEVKIT_ROUTER_URL      endpoint accepting {model, state, questions}
  SQUAD_DEVKIT_ROUTER_MODEL    model name sent in the request
  SQUAD_DEVKIT_ROUTER_KEY_ENV  name of the variable holding the bearer token
                               (default SQUAD_DEVKIT_ROUTER_KEY)
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  '') usage >&2; exit 2 ;;
esac
digest="$*"

if [[ -z "${SQUAD_DEVKIT_ROUTER_URL:-}" ]]; then
  echo '{"configured":false}'
  exit 0
fi
command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || {
  echo '{"configured":true,"error":"curl and jq are required"}'
  exit 0
}
key_variable="${SQUAD_DEVKIT_ROUTER_KEY_ENV:-SQUAD_DEVKIT_ROUTER_KEY}"
key="${!key_variable:-}"
minimum="${SQUAD_DEVKIT_ROUTER_MIN_CONFIDENCE:-0.85}"

request="$(jq -n --arg model "${SQUAD_DEVKIT_ROUTER_MODEL:-}" --arg message "$digest" '{
  model: $model,
  state: {message: $message},
  questions: {
    workstream: {type: "choice", instructions: "Which workstream owns this task?",
      criteria: {
        code: "bounded implementation with known files and contract",
        debug: "failure, regression, stack trace, or unexpected behavior",
        infra: "Docker, network, proxy, deploy, runtime, or operations",
        security: "auth, secret, access-control, dependency, or exposure risk",
        docs: "documentation-only change",
        research: "data gathering, logs, metrics, or analysis without code changes",
        needs_deeper_impact: "facts need impact or cross-repo analysis",
        needs_human: "a human decision is required before changes"}},
    risk: {type: "score", instructions: "How costly is a wrong or low-quality result?",
      criteria: ["low", "moderate", "high"]},
    complexity: {type: "score", instructions: "How complex is the implementation?",
      criteria: ["low", "moderate", "high"]},
    needs_human: {type: "noul", instructions: "Does this require a human decision before changes?"}
  }} | if .model == "" then del(.model) else . end')"

headers=(-H 'Content-Type: application/json')
[[ -n "$key" ]] && headers+=(-H "Authorization: Bearer $key")
if ! response="$(curl -sS --fail --max-time "${SQUAD_DEVKIT_ROUTER_TIMEOUT:-20}" \
  "${headers[@]}" -d "$request" "$SQUAD_DEVKIT_ROUTER_URL" 2>&1)"; then
  jq -nc --arg error "$response" '{configured: true, error: ($error | .[0:200])}'
  exit 0
fi

# A score's label is the criterion nearest to the expected position.
jq -c --argjson minimum "$minimum" '
  def score_label($answer): ($answer.legend // {}) as $legend
    | ($answer.score // 0 | round | tostring) as $index | $legend[$index] // null;
  .answers as $a
  | {configured: true,
     workstream: $a.workstream.choice,
     confidence: $a.workstream.confidence,
     risk: score_label($a.risk),
     complexity: score_label($a.complexity),
     needs_human: $a.needs_human.noul}
  | .accept = ((.confidence // 0) >= $minimum and (.needs_human // 1) < 0.5 and .risk != "high")' \
  <<<"$response" 2>/dev/null || echo '{"configured":true,"error":"unexpected router response"}'
