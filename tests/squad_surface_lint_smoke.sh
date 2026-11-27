#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp_root="${TMPDIR:-/tmp}"
tmp_root="${tmp_root%/}"
tmp="$(mktemp -d "$tmp_root/squad-surface-lint.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
export PATH="$root/target/debug:$PATH"
cargo build --quiet --manifest-path "$root/Cargo.toml"
out="$(squad lint --dir "$tmp")"
grep -q 'OK:' <<< "$out"
printf '{{ value }}\n' > "$tmp/AGENTS.md"
out="$(squad lint --dir "$tmp")"
grep -q 'WARN' <<< "$out"
if squad lint --dir "$tmp" --strict >/dev/null 2>&1; then exit 1; fi
json="$(squad lint --dir "$tmp" --json)"
[[ "$json" == *template_placeholder* ]]
head -c 32769 /dev/zero | tr '\0' x > "$tmp/AGENTS.md"
if squad lint --dir "$tmp" >/dev/null 2>&1; then exit 1; fi
"$root/scripts/squad-devkit.sh" --doctor > "$tmp/doctor" 2>&1 || true
grep -q 'Harness Surface:' "$tmp/doctor"
