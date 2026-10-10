#!/usr/bin/env bash
# The visible waits of the workflow scripts (Round 21): wait_logged, secret_matches, secret_present
# and vss_summary from workflows/scripts/lib.sh, with a stub tk (kubectl). Regression of Round 15 to
# 20: the live checksum was taken with `jq -r` (trailing newline) against a Vault checksum without
# one, so a Secret that already held the new value was reported SECRET_NOT_SYNCED after 5 minutes.
# Needs bash and jq (sha256sum is shimmed with shasum on macOS).
# shellcheck disable=SC2015  # ok/bad: A && ok || bad, as in the other suites
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
command -v jq >/dev/null || { echo "SKIP tests/waits: jq not installed" >&2; exit 0; }
PASS=0; FAIL=0
ok()  { printf 'ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL %s\n' "$1"; [[ -z "${2:-}" ]] || printf '       %s\n' "$2"; FAIL=$((FAIL + 1)); }
command -v sha256sum >/dev/null || sha256sum() { shasum -a 256; }

# the helpers, cut out of lib.sh between their markers
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
awk '/^# -+ visible waits \(Round 21\)/ {p=1} p {print} /^# -+ end of the visible waits/ {exit}' "$ROOT/workflows/scripts/lib.sh" > "$T/helpers.sh"
grep -q "^secret_matches()" "$T/helpers.sh" && ok "the helpers are in lib.sh" || { bad "helpers not found in lib.sh"; exit 1; }
sed -n '/^log()/p' "$ROOT/workflows/scripts/lib.sh" > "$T/log.sh"

LOGF="$T/step.log"
log() { printf '%s\n' "$*" >> "$LOGF"; }
SECRET_VALUE="hvs.example-token-value"
# tk get secret -> a dockerconfigjson with the current password; get vaultstaticsecret -> conditions
# shellcheck disable=SC2034  # what: the argument layout of tk, kept for reading
tk() {
  local what="$3"
  case " $* " in
    *" get secret "*)
      [[ -z "${NO_SECRET:-}" ]] || return 1
      jq -cn --arg p "$SECRET_VALUE" '{data: {".dockerconfigjson": ({auths: {"registry.example": {password: $p}}} | tojson | @base64)}}' ;;
    *" get vaultstaticsecret "*)
      echo '{"status":{"secretMAC":"S3atz4E1eWKh8m+HySY","conditions":[{"type":"SecretSynced","status":"True","message":"Secret synced"},{"type":"Ready","status":"True","message":"VaultStaticSecretReady"}]}}' ;;
  esac
}
sleep() { :; }
source "$T/helpers.sh"

EXPR='.data[".dockerconfigjson"] | @base64d | fromjson | .auths[].password'
want="$(printf '%s' "$SECRET_VALUE" | sha16)"

: > "$LOGF"
secret_matches ns1 regsecret "$EXPR" "$want" && ok "a live Secret that holds the Vault value matches (the Round 15 to 20 bug: it never did)" || bad "no match for an equal value" "$(cat "$LOGF")"
grep -q "match" "$LOGF" && grep -q "kubectl -n ns1 get secret regsecret -o json | jq -j" "$LOGF" && ok "the poll logs its command and the result" || bad "log lines" "$(cat "$LOGF")"
grep -q "${SECRET_VALUE}" "$LOGF" && bad "the secret value is in the log" || ok "the value itself never reaches the log"
grep -q "live ${want:0:8} = Vault ${want:0:8}" "$LOGF" && ok "only 8 characters of each checksum are logged" || bad "checksum log" "$(cat "$LOGF")"

old="$(printf '%s' "$SECRET_VALUE" | jq -R -r '.' | sha16)"
[[ "$old" != "$want" ]] && ok "the old comparison (jq -r against printf) really differed" || bad "old comparison equal?"

: > "$LOGF"
secret_matches ns1 regsecret "$EXPR" "0000000000000000" && bad "a different value matched" || ok "a different Vault value does not match"
grep -q "not yet; VaultStaticSecret: SecretSynced=True (Secret synced); Ready=True (VaultStaticSecretReady) | secretMAC S3atz4E1eWKh" "$LOGF" && ok "a mismatch logs the VaultStaticSecret conditions and secretMAC" || bad "VSS summary" "$(cat "$LOGF")"

: > "$LOGF"
NO_SECRET=1 secret_matches ns1 regsecret "$EXPR" "$want" && bad "missing Secret matched" || ok "a missing Secret does not match"
[[ "$LIVE_SHA" == "no-secret" ]] && grep -q "not found" "$LOGF" && ok "and says so" || bad "missing secret log" "$(cat "$LOGF")"

# wait_logged: polls, stops early, gives up, and logs each poll
: > "$LOGF"; n=0
flaky() { n=$((n + 1)); [[ "$n" -ge 3 ]]; }
wait_logged "flaky" 5 10 flaky && ok "wait_logged returns 0 as soon as the check passes" || bad "wait_logged early"
[[ "$n" == 3 && "$(grep -c 'wait flaky: poll' "$LOGF")" == 3 ]] && grep -q "done after" "$LOGF" && ok "it polled 3 times and logged each poll" || bad "poll count" "$n $(cat "$LOGF")"
: > "$LOGF"
never() { return 1; }
wait_logged "never" 2 10 never && bad "wait_logged never succeeded" || ok "wait_logged returns 1 when it gives up"
grep -q "gave up after" "$LOGF" && ok "and logs that it gave up" || bad "gave up log" "$(cat "$LOGF")"

# the scripts use the helpers and no longer carry the silent loops
RC="$ROOT/workflows/scripts/rotate-cluster.sh"
grep -q "jq -r \"\$expr\" 2>/dev/null | sha" "$RC" && bad "rotate-cluster.sh still compares with jq -r" || ok "rotate-cluster.sh does not compare with jq -r"
grep -q "check_namespaces regsecret" "$RC" && grep -q "check_namespaces backup-storage" "$RC" && ok "rotate-cluster.sh checks regsecret and backup-storage with the logged wait" || bad "check_namespaces"
grep -q "tanzu-postgres-operator\" { print \"0 \"" "$RC" && ok "the operator namespace is checked first" || bad "namespace order"
grep -q "wait_logged" "$ROOT/workflows/scripts/day0-deploy.sh" "$ROOT/workflows/scripts/restore.sh" "$ROOT/workflows/scripts/rotate-hub.sh" && ok "day0, restore and rotate-hub wait with wait_logged" || bad "other scripts"

echo
echo "tests/waits: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
