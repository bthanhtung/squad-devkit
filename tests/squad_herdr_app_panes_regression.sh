#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
temp="$(mktemp -d /tmp/squad-herdr-app-panes.XXXXXX)"
trap 'rm -rf "$temp"' EXIT
mkdir -p "$temp/bin" "$temp/state"
export HERDR_APP_TEST_LOG="$temp/log"
export HERDR_APP_INVENTORY="$temp/inventory.json"
export HERDR_APP_COUNTER="$temp/counter"

mgr_term="t20"
mgr_pane="p1f8d0be7d420eec418e499686fe6bd35"
mgr_tab="tb993652052db4e360de4ec8e35aa8b12b"
mgr_space="spfe5a01324ea9a823f3cf555940b8171e"

reset_inventory() {
  printf '0\n' >"$HERDR_APP_COUNTER"
  cat >"$HERDR_APP_INVENTORY" <<EOF
{
  "spaces": [
    {
      "id": "sp-other",
      "name": "other",
      "folder": "/tmp",
      "machine": null,
      "active": false,
      "tabs": [
        {
          "id": "tb-other",
          "name": "1",
          "active": true,
          "settled": false,
          "terminals": [
            {
              "terminal": "t5",
              "pane": "p-other-tab",
              "status": null,
              "app": null,
              "name": null,
              "sub_agents": []
            }
          ]
        }
      ]
    },
    {
      "id": "$mgr_space",
      "name": "squad-devkit",
      "folder": "$repo",
      "machine": null,
      "active": true,
      "tabs": [
        {
          "id": "$mgr_tab",
          "name": "1",
          "active": true,
          "settled": false,
          "terminals": [
            {
              "terminal": "$mgr_term",
              "pane": "$mgr_pane",
              "status": "working",
              "app": "codex",
              "name": null,
              "sub_agents": []
            }
          ]
        }
      ]
    }
  ],
  "recent": []
}
EOF
}

cat >"$temp/bin/herdr-app" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
# Serialize fake inventory updates so log and state transitions are atomic.
lock="$HERDR_APP_INVENTORY.lock"
while ! mkdir "$lock" 2>/dev/null; do sleep 0.02; done
trap 'rmdir "$lock" 2>/dev/null || true' EXIT

printf '%s\n' "$*" >>"$HERDR_APP_TEST_LOG"
case "${1:-}" in
  ls)
    [[ "${FAKE_LS_FAIL:-0}" != 1 ]] || exit 1
    cat "$HERDR_APP_INVENTORY"
    ;;
  do)
    cmd="${2:-}"
    shift 2 || true
    case "$cmd" in
      pane.split)
        direction="" pane="" argv=""
        while (( $# > 0 )); do
          case "$1" in
            --direction) direction="$2"; shift 2 ;;
            --pane) pane="$2"; shift 2 ;;
            --argv) argv="$2"; shift 2 ;;
            *) exit 2 ;;
          esac
        done
        [[ -n "$direction" && -n "$pane" && -n "$argv" ]] || exit 2
        printf '%s' "$argv" >"$HERDR_APP_TEST_LOG.argv"
        case "${FAKE_SPLIT_MODE:-ok}" in
          error)
            printf '{"error":"split failed"}\n'
            exit 1
            ;;
          error_exit0)
            printf '{"error":"split failed"}\n'
            exit 0
            ;;
          empty)
            exit 0
            ;;
          malformed)
            printf 'not-json\n'
            exit 0
            ;;
          null_ids)
            printf '{"pane":null,"terminal":"t99"}\n'
            exit 0
            ;;
          whitespace_id)
            printf '{"pane":"bad pane","terminal":"t99"}\n'
            exit 0
            ;;
          wrong_tab)
            jq '.spaces[0].tabs[0].terminals += [{"terminal":"t-wrong","pane":"p-wrong","status":null,"app":null,"name":null,"sub_agents":[]}]' \
              "$HERDR_APP_INVENTORY" >"$HERDR_APP_INVENTORY.tmp"
            mv "$HERDR_APP_INVENTORY.tmp" "$HERDR_APP_INVENTORY"
            printf '{"pane":"p-wrong","terminal":"t-wrong"}\n'
            exit 0
            ;;
          unrecorded)
            printf '{"pane":"p-ghost","terminal":"t-ghost"}\n'
            exit 0
            ;;
        esac
        n="$(( $(cat "$HERDR_APP_COUNTER") + 1 ))"
        printf '%s\n' "$n" >"$HERDR_APP_COUNTER"
        new_pane="p_w$n"
        new_term="t_w$n"
        jq --arg target "$pane" --arg np "$new_pane" --arg nt "$new_term" '
          (.spaces[] | .tabs[] | select(any(.terminals[]; .pane == $target)) | .terminals) += [{
            terminal: $nt,
            pane: $np,
            status: null,
            app: null,
            name: null,
            sub_agents: []
          }]
        ' "$HERDR_APP_INVENTORY" >"$HERDR_APP_INVENTORY.tmp"
        mv "$HERDR_APP_INVENTORY.tmp" "$HERDR_APP_INVENTORY"
        printf '{"pane":"%s","terminal":"%s"}\n' "$new_pane" "$new_term"
        ;;
      pane.focus)
        [[ "${1:-}" == --pane && -n "${2:-}" ]] || exit 2
        printf '{"pane":"%s"}\n' "$2"
        ;;
      *)
        exit 2
        ;;
    esac
    ;;
  *)
    exit 2
    ;;
esac
FAKE
chmod +x "$temp/bin/herdr-app"

export PATH="$temp/bin:$PATH"
unset TMUX TMUX_PANE SQUAD_DEVKIT_ORCA_TERMINAL ORCA_PANE_KEY ORCA_CLI_COMMAND ORCA_DEV_REPO_ROOT
unset HERDR_ENV HERDR_PANE_ID HERDR_SOCKET_PATH HC_TERMINAL_SOCKET HC_SCOPE ZELLIJ ZELLIJ_SESSION_NAME
unset WEZTERM_PANE KITTY_WINDOW_ID ITERM_SESSION_ID SQUAD_DEVKIT_GHOSTTY_TERMINAL DISPLAY WAYLAND_DISPLAY
export HC_TERMINAL_ID="$mgr_term"

source "$repo/scripts/lib/squad-panes.sh"
squad_panes_dashboard() { echo dashboard >>"$HERDR_APP_TEST_LOG"; }

reset_inventory
[[ "$(squad_panes_herdr_app_manager)" == "$mgr_pane" ]]

# 1. First split goes right of manager, preserves cwd (with spaces/quotes) via argv,
# validates inventory in the same tab, and restores focus to manager.
quoted_ws="$temp/work 'space'"
quoted_script="$temp/monitor 'script'.sh"
mkdir -p "$quoted_ws"
cat >"$quoted_script" <<'EOF'
#!/usr/bin/env bash
pwd -P
EOF
chmod +x "$quoted_script"
: >"$HERDR_APP_TEST_LOG"
squad_open_monitor "$quoted_script" 'dev-1 · agy' "$quoted_ws" "$temp/state" /tmp/dashboard.sh required
grep -q "^do pane.split --direction right --pane $mgr_pane --argv " "$HERDR_APP_TEST_LOG"
grep -qx "do pane.focus --pane $mgr_pane" "$HERDR_APP_TEST_LOG"
[[ "$(cat "$temp/state/.herdr_app-$mgr_pane.last")" == p_w1 ]]
argv_cmd=()
while IFS= read -r arg; do
  argv_cmd+=("$arg")
done < <(jq -r '.[]' "$HERDR_APP_TEST_LOG.argv")
[[ "$("${argv_cmd[@]}")" == "$(cd "$quoted_ws" && pwd -P)" ]]

# 2. Second split stacks down from the live sibling in the same tab.
: >"$HERDR_APP_TEST_LOG"
squad_open_monitor "$quoted_script" 'dev-2 · agy' "$quoted_ws" "$temp/state" /tmp/dashboard.sh required
grep -q "^do pane.split --direction down --pane p_w1 --argv " "$HERDR_APP_TEST_LOG"
grep -qx "do pane.focus --pane $mgr_pane" "$HERDR_APP_TEST_LOG"
[[ "$(cat "$temp/state/.herdr_app-$mgr_pane.last")" == p_w2 ]]

# 3. Stale previous pane (closed or in another tab) reconciles via ls before mutating
# and splits right of manager in a single pane.split call.
for bad_prev in p-closed p-other-tab; do
  printf '%s\n' "$bad_prev" >"$temp/state/.herdr_app-$mgr_pane.last"
  : >"$HERDR_APP_TEST_LOG"
  squad_open_monitor "$quoted_script" 'dev-stale · agy' "$quoted_ws" "$temp/state" /tmp/dashboard.sh required
  [[ "$(grep -c '^do pane.split ' "$HERDR_APP_TEST_LOG")" == 1 ]]
  grep -q "^do pane.split --direction right --pane $mgr_pane --argv " "$HERDR_APP_TEST_LOG"
done
last_good="$(cat "$temp/state/.herdr_app-$mgr_pane.last")"

# 4. Split errors, malformed outputs, and wrong-tab/missing post-split inventory
# never retry pane.split, never open dashboard, restore focus, and preserve .last.
for mode in error error_exit0 empty malformed null_ids whitespace_id wrong_tab unrecorded; do
  : >"$HERDR_APP_TEST_LOG"
  if FAKE_SPLIT_MODE="$mode" squad_open_monitor "$quoted_script" "fail-$mode" "$quoted_ws" "$temp/state" /tmp/dashboard.sh required 2>"$temp/err"; then
    echo "expected $mode to fail" >&2
    exit 1
  fi
  grep -q 'herdr_app split failed or returned an invalid handle' "$temp/err"
  [[ "$(grep -c '^do pane.split ' "$HERDR_APP_TEST_LOG")" == 1 ]]
  grep -qx "do pane.focus --pane $mgr_pane" "$HERDR_APP_TEST_LOG"
  ! grep -q '^dashboard$' "$HERDR_APP_TEST_LOG"
  [[ "$(cat "$temp/state/.herdr_app-$mgr_pane.last")" == "$last_good" ]]
  # Standalone (non-required) also never falls back to dashboard when herdr_app split is uncertain.
  : >"$HERDR_APP_TEST_LOG"
  FAKE_SPLIT_MODE="$mode" squad_open_monitor "$quoted_script" "standalone-$mode" "$quoted_ws" "$temp/state" /tmp/dashboard.sh
  [[ "$(grep -c '^do pane.split ' "$HERDR_APP_TEST_LOG")" == 1 ]]
  ! grep -q '^dashboard$' "$HERDR_APP_TEST_LOG"
done

# 5. Missing, ambiguous, and remote manager terminals are rejected before any split.
: >"$HERDR_APP_TEST_LOG"
if HC_TERMINAL_ID=t-missing squad_open_monitor "$quoted_script" 'missing' "$quoted_ws" "$temp/state" /tmp/dashboard.sh required 2>"$temp/err"; then
  echo 'expected missing manager terminal to fail' >&2; exit 1
fi
grep -q 'Herdr desktop terminal (t-missing) could not be resolved' "$temp/err"
! grep -q '^do pane.split ' "$HERDR_APP_TEST_LOG"
! grep -q '^dashboard$' "$HERDR_APP_TEST_LOG"

jq --arg term "$mgr_term" '.spaces[0].tabs[0].terminals += [{"terminal":$term,"pane":"p-dup","status":null,"app":null,"name":null,"sub_agents":[]}]' \
  "$HERDR_APP_INVENTORY" >"$HERDR_APP_INVENTORY.tmp"
mv "$HERDR_APP_INVENTORY.tmp" "$HERDR_APP_INVENTORY"
: >"$HERDR_APP_TEST_LOG"
if squad_open_monitor "$quoted_script" 'ambiguous' "$quoted_ws" "$temp/state" /tmp/dashboard.sh required 2>"$temp/err"; then
  echo 'expected ambiguous manager terminal to fail' >&2; exit 1
fi
grep -q "Herdr desktop terminal ($mgr_term) could not be resolved" "$temp/err"
! grep -q '^do pane.split ' "$HERDR_APP_TEST_LOG"

reset_inventory
jq '.spaces[1].machine = "vps"' "$HERDR_APP_INVENTORY" >"$HERDR_APP_INVENTORY.tmp"
mv "$HERDR_APP_INVENTORY.tmp" "$HERDR_APP_INVENTORY"
: >"$HERDR_APP_TEST_LOG"
if squad_open_monitor "$quoted_script" 'remote' "$quoted_ws" "$temp/state" /tmp/dashboard.sh required 2>"$temp/err"; then
  echo 'expected remote manager terminal to fail' >&2; exit 1
fi
grep -q "Herdr desktop terminal ($mgr_term) could not be resolved" "$temp/err"
! grep -q '^do pane.split ' "$HERDR_APP_TEST_LOG"

# 6. Three concurrent splits serialize via .pane.lock and stack right -> down -> down in the manager tab.
reset_inventory
rm -f "$temp/state/.herdr_app-$mgr_pane.last"
: >"$HERDR_APP_TEST_LOG"
pids=()
for i in 1 2 3; do
  (squad_open_monitor "$quoted_script" "conc-$i" "$quoted_ws" "$temp/state" /tmp/dashboard.sh required) &
  pids+=("$!")
done
for pid in "${pids[@]}"; do
  wait "$pid"
done
[[ "$(grep -c '^do pane.split ' "$HERDR_APP_TEST_LOG")" == 3 ]]
split_calls="$(grep '^do pane.split ' "$HERDR_APP_TEST_LOG")"
[[ "$(printf '%s\n' "$split_calls" | sed -n '1p')" == "do pane.split --direction right --pane $mgr_pane --argv "* ]]
[[ "$(printf '%s\n' "$split_calls" | sed -n '2p')" == "do pane.split --direction down --pane p_w1 --argv "* ]]
[[ "$(printf '%s\n' "$split_calls" | sed -n '3p')" == "do pane.split --direction down --pane p_w2 --argv "* ]]
[[ "$(cat "$temp/state/.herdr_app-$mgr_pane.last")" == p_w3 ]]
jq -e --arg tab "$mgr_tab" '
  [.spaces[].tabs[] | select(.id == $tab) | .terminals[].pane] ==
  ["p1f8d0be7d420eec418e499686fe6bd35", "p_w1", "p_w2", "p_w3"]
' "$HERDR_APP_INVENTORY" >/dev/null

# 7. Doctor capability diagnostics distinguish resolved vs unresolved Herdr desktop terminals.
doctor_ok="$("$repo/scripts/squad-devkit.sh" --doctor)"
[[ "$doctor_ok" == *'Monitor pane mode: Herdr desktop split-pane (explicit manager terminal)'* ]]
doctor_unresolved="$(HC_TERMINAL_ID=t-missing "$repo/scripts/squad-devkit.sh" --doctor)"
[[ "$doctor_unresolved" == *'Monitor pane mode: Herdr desktop (monitor split unavailable: manager terminal not resolved)'* ]]

echo 'PASS: Herdr desktop terminal resolution, stacking, cwd argv, focus, failure safety, and 3-worker concurrency'
