#!/usr/bin/env bash
set -euo pipefail
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"
touch Cargo.toml
squad init --harness
test -f .squad/harness.toml
squad harness validate
squad harness show --json > manifest.json
python3 - <<'PY'
import json
with open("manifest.json") as f:
    c = json.load(f)
assert c["version"] == 1
assert c["gates"]["post_merge"] == ["cargo test --all"]
assert c["sandbox"] == {"profile": "workspace", "network": "deny"}
PY
printf '# keep\n' >> .squad/harness.toml
cp .squad/harness.toml expected
squad init --harness
cmp expected .squad/harness.toml
squad init --harness --force
if cmp -s expected .squad/harness.toml; then
    echo "force did not overwrite manifest" >&2
    exit 1
fi
squad harness validate --file .squad/harness.toml
squad harness show --file .squad/harness.toml > rendered.toml
squad harness validate --file rendered.toml
printf 'version = 2\n' > invalid.toml
if squad harness validate --file invalid.toml; then exit 1; fi
if squad harness validate --file missing.toml; then exit 1; fi
if squad harness show --unknown; then exit 1; fi
echo "harness manifest smoke: passed"
