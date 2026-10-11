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

# Round 23 (strict lists): the list patterns of workflows/params/types.yaml run in the API server as CEL
# (RE2): no repeat count above 255 (the tools image's musl regex refuses more; CEL costs grow with it;
# vaultToken, checked in the validate step without the regex, is the one exception, within RE2's 1000),
# no lookahead and no back-reference; and they accept the bracketed forms and refuse the comma forms
if command -v python3 >/dev/null && python3 -c 'import yaml' 2>/dev/null; then
  out="$(python3 - "$ROOT/workflows/params/types.yaml" <<'PY'
import re, sys, yaml
types = yaml.safe_load(open(sys.argv[1]))["types"]
problems = []
for name, spec in types.items():
    pat = spec.get("pattern") or ""
    limit = 1000 if name == "vaultToken" else 255     # RE2 allows 1000; the list types stay within the 255 of the tools image
    for m in re.finditer(r"\{(\d*)(?:,(\d*))?\}", pat):
        if any(int(x) > limit for x in m.groups() if x):
            problems.append(f"{name}: repeat count {m.group(0)} above {limit}")
    if re.search(r"\(\?[=!<]|\\[1-9]", pat):
        problems.append(f"{name}: lookahead or back-reference (not RE2)")
# type -> (accepted, refused)
cases = {
  "list": (["[a]", "[a, b]", '["a","b"]', "['a', \"b\"]", "[ a ,b ]"],
           ["a", "a,b", "[]", "[a, , b]", "[a,]", "[,a]", "[A]", "[a b]", "all", "[a]]"]),
  "listOrAll": (["all", "[a]", "[a, b]", '["a"]'], ["a", "a,b", "[]", "[a, , b]", "[a,]"]),
  "components": (["auto", "[vso]", "[cert-manager, vso, monitoring]"], ["vso", "cert-manager,vso", "[]", "[auto]", "[a]", "[vso, , vso]"]),
  "cidrList": (["[10.20.0.0/16]", "[10.20.0.0/16, 10.30.0.0/24]", "[fd00::/8]"], ["10.20.0.0/16", "10.20.0.0/16,10.30.0.0/24", "[]", "[10.20.0.0]"]),
  "fqdnList": (["[db.example.com]", "[db.example.com, *.example.org]"], ["db.example.com", "db.example.com,*.example.org", "[]", "[http://x]"]),
  "pairList": (["[{sourceClusterConfig: {}}]", "- sourceClusterConfig:\n    c: {}", "  [ ]", '[{"a": 1}]'], ["aks-tpg-poc-01: {}", "{a: b}", "-sourceClusterConfig", "just text"]),
  "patchFileList": (["[./a.yaml]", "[a.yaml, repo:helm_artifacts/x.yaml]", "[~/a.yml, /abs/b.yaml, ../c.yaml]"],
                    ["a.yaml", "a.yaml,b.yaml", "[]", "[repo: x.yaml]", "[a.txt]", "[a.yaml, , b.yaml]"]),
  "patchFile": (["[./a.yaml]", "[repo:helm_artifacts/x.yaml]", '["a.yaml"]'], ["a.yaml", "[a.yaml, b.yaml]", "[]", "[repo: x.yaml]", "[a.txt]"]),
  "caFile": (["[./ca.pem]", "[repo:ca-bundles/x.crt]"], ["ca.pem", "[ca.pem, b.pem]", "[]", "[repo: ca-bundles/x.pem]", "[ca.txt]"]),
  "kindList": (["all", "[Postgres]", "[Postgres, postgresValues]"], ["Postgres", "Postgres,postgresValues", "[]", "[all]", "[all, Postgres]", "[Nope]"]),
}
for t, (good, bad) in cases.items():
    pat = types[t]["pattern"]
    for v in good:
        if not re.search(pat, v):
            problems.append(f"{t} refuses {v!r}")
    for v in bad:
        if re.search(pat, v):
            problems.append(f"{t} accepts {v!r}")
print("\n".join(problems))
PY
)"
  [[ -z "$out" ]] && ok "the list patterns of types.yaml are RE2-safe, take the bracketed forms and refuse the comma forms, [] and empty elements" \
    || bad "list patterns of types.yaml" "$out"
else
  echo "note: python3 PyYAML not installed: the list patterns of types.yaml are not checked here" >&2
fi

echo
echo "tests/regex-limits: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
