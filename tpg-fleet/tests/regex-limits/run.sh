#!/usr/bin/env bash
# Bash regexes in the workflow scripts (Round 20). POSIX limits a repeat count {n,m} to 255; the
# musl regex of the tools image (alpine/k8s) refuses more with "Invalid contents of {}", which
# failed tpg-rotate-credential on wrappingToken ({16,512}). macOS bash refuses it too, so a
# local run catches it. Needs only bash and awk.
# shellcheck disable=SC2015  # ok/bad: A && ok || bad, as in the other suites
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0; FAIL=0
ok()  { printf 'ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL %s\n' "$1"; [[ -z "${2:-}" ]] || printf '       %s\n' "$2"; FAIL=$((FAIL + 1)); }

scan() {  # scan FILE...: lines with =~ whose repeat count exceeds 255
  awk '/=~/ { s = $0
        while (match(s, /\{[0-9]*,?[0-9]*\}/)) {
          v = substr(s, RSTART + 1, RLENGTH - 2); n = split(v, a, ",")
          if (a[n] + 0 > 255) { print FILENAME ":" FNR ": " $0; break }
          s = substr(s, RSTART + RLENGTH) } }' "$@"
}

found="$(scan "$ROOT"/workflows/scripts/*.sh "$ROOT"/scripts/*.sh "$ROOT"/scripts/submit/*.sh)"
[[ -z "$found" ]] && ok "no bash regex repeats more than 255 times" || bad "a bash regex repeat count above 255" "$found"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
# shellcheck disable=SC2016  # the text of a script, not expanded here
printf '[[ "$x" =~ ^[A-Za-z0-9._-]{16,512}$ ]] || err no\n[[ "$y" =~ ^[a-z]{0,251}$ ]] || err ok\n' > "$T/old.sh"
[[ "$(scan "$T/old.sh" | wc -l | tr -d ' ')" == 1 ]] && ok "the scan finds {16,512} and leaves {0,251} alone" || bad "the scan itself" "$(scan "$T/old.sh")"

# the shell here accepts what the tools image accepts: a valid token passes the Round 20 check
tokenv="hvs.CAESIJabcdefghijklmnopqrstuvwxyz0123456789"
[[ -z "$tokenv" || ( ${#tokenv} -ge 16 && ${#tokenv} -le 512 && "$tokenv" =~ ^[A-Za-z0-9._-]+$ ) ]] && ok "a Vault token passes the length and character check" || bad "token check"
tokenv="$(printf 'a%.0s' $(seq 1 513))"
[[ ${#tokenv} -le 512 ]] && bad "513 characters accepted" || ok "513 characters are refused"

echo
echo "tests/regex-limits: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
