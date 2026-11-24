#!/usr/bin/env bash
set -euo pipefail
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cat >"$tmp/suite.json" <<'JSON'
{"trials":2,"tasks":[{"id":"ok","cmd":"true"},{"id":"bad","cmd":"false"}]}
JSON
printf '%s\n' '{"type":"assistant","message":{"model":"fixture","usage":{"input_tokens":4,"output_tokens":2}}}' malformed >"$tmp/log.jsonl"
squad trace normalize --engine claude --log "$tmp/log.jsonl" >"$tmp/trace.jsonl"
grep -q '"schema_version":1' "$tmp/trace.jsonl"
squad eval fixture --suite "$tmp/suite.json" --json --out "$tmp/baseline.json" >"$tmp/out"
grep -q '"pass_at_k"' "$tmp/out"
cat >"$tmp/regression.json" <<'JSON'
{"trials":2,"tasks":[{"id":"ok","cmd":"false"},{"id":"bad","cmd":"false"}]}
JSON
if squad eval fixture --suite "$tmp/regression.json" --baseline "$tmp/baseline.json" >/dev/null 2>"$tmp/err"; then echo 'regression was accepted' >&2; exit 1; fi
grep -q 'regression for ok' "$tmp/err"
mkdir "$tmp/fixture"
printf 'clean\n' >"$tmp/fixture/state"
cat >"$tmp/isolated.json" <<JSON
{"trials":2,"tasks":[{"id":"isolated","cmd":"echo changed > state; exit 1","fixture_dir":"$tmp/fixture","oracle":"grep -q changed state"}]}
JSON
squad eval fixture --suite "$tmp/isolated.json" --json >"$tmp/isolated.out"
grep -q '"passed": 2' "$tmp/isolated.out"
echo 'PASS: trace normalization, fixture scoring, isolated trials, oracle grading and baseline regression'
