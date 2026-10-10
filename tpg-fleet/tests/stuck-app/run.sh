#!/usr/bin/env bash
# Round 22: an Application stuck in Deleting with a ComparisonError (expired registry token) is
# removed by clearing its finalizer: app_removed_or_force / app_stuck_reason from lib.sh, with stub
# kubectl and app_exists. Needs bash and jq.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
command -v jq >/dev/null || { echo "SKIP tests/stuck-app: jq not installed" >&2; exit 0; }
PASS=0; FAIL=0
ok()  { printf 'ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL %s\n' "$1"; [[ -z "${2:-}" ]] || printf '       %s\n' "$2"; FAIL=$((FAIL + 1)); }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
awk '/^app_gone\(\)/ {p=1} /^_app_line\(\)/ {p=0} p {print}' "$ROOT/workflows/scripts/lib.sh" > "$T/helpers.sh"
grep -q "^app_removed_or_force()" "$T/helpers.sh" || { bad "helpers not found in lib.sh"; exit 1; }
LOGF="$T/log"; : > "$LOGF"
log() { printf '%s\n' "$*" >> "$LOGF"; }
log_cmd() { log "  \$ $*"; }
sleep() { :; }
wait_logged() { local l="$1" n="$2" f="$4" i; shift 4; for i in $(seq 1 "$n"); do "$f" "$@" && return 0; done; return 1; }
STATE="$T/state"          # present | gone
PATCHED="$T/patched"
app_exists() { [[ "$(cat "$STATE")" == present ]]; }
kubectl() {
  case "$*" in
    *" patch application "*) : > "$PATCHED"; if [[ -n "${PATCH_FAILS:-}" ]]; then return 1; fi; echo gone > "$STATE" ;;
    *" get application "*)
      [[ "$(cat "$STATE")" == present ]] || return 1
      jq -cn --arg d "${DELETING:-}" --arg c "${COND:-}" '{metadata: ({name: "a"} + (if $d != "" then {deletionTimestamp: $d} else {} end)),
        status: {conditions: (if $c != "" then [{type: "ComparisonError", message: $c}] else [] end)}}' ;;
  esac
}
source "$T/helpers.sh"

run() { echo present > "$STATE"; rm -f "$PATCHED"; : > "$LOGF"; FORCED_NOTE=""; "$@"; }

echo gone > "$STATE"; rc=0; app_removed_or_force a true || rc=$?
[[ "$rc" == 0 && ! -e "$PATCHED" && -z "$FORCED_NOTE" ]] && ok "an Application that is gone is not touched" || bad "gone app"

DELETING=2026-10-08T10:00:00Z COND="rpc error: 401 Unauthorized"
rc=0; run app_removed_or_force a true || rc=$?
[[ "$rc" == 0 && -e "$PATCHED" ]] && ok "stuck + force: the finalizer is removed" || bad "force" "$(cat "$LOGF")"
[[ "$FORCED_NOTE" == FORCED:*"without rendering"*"401 Unauthorized"* ]] && ok "FORCED note carries the condition" || bad "note" "$FORCED_NOTE"
grep -q "is stuck: Deleting since .*ComparisonError: rpc error: 401" "$LOGF" && ok "the condition is logged" || bad "log" "$(cat "$LOGF")"

rc=0; run app_removed_or_force a false || rc=$?
[[ "$rc" == 1 && ! -e "$PATCHED" ]] && ok "forceDeleteStuckApps=false: nothing is patched, returns 1" || bad "no force"

unset DELETING COND
rc=0; run app_removed_or_force a true || rc=$?
[[ "$rc" == 1 && ! -e "$PATCHED" ]] && ok "present but not stuck: never forced" || bad "not stuck" "$(cat "$LOGF")"

DELETING=2026-10-08T10:00:00Z COND=
rc=0; run app_removed_or_force a true || rc=$?
[[ "$rc" == 1 && ! -e "$PATCHED" ]] && ok "Deleting without a ComparisonError (a slow delete) is never forced" || bad "slow delete" "$(cat "$LOGF")"

DELETING=2026-10-08T10:00:00Z COND=x PATCH_FAILS=1
rc=0; run app_removed_or_force a true || rc=$?
[[ "$rc" == 1 && -z "$FORCED_NOTE" ]] && grep -q "patch failed" "$LOGF" && ok "a failed patch is reported, not claimed as FORCED" || bad "patch fail" "$(cat "$LOGF")"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"; [[ "$FAIL" == 0 ]]
