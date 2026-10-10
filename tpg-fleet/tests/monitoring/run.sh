#!/usr/bin/env bash
# monitoring/grafana/generate.py and docs/monitoring.md:
#   generator    generate.py --check: the Grafana alert rules, the API payloads, the
#                PrometheusRule, the dashboards and the reference section of
#                docs/monitoring.md are what the definitions produce
#   check mode   on a copy: --check fails on a hand edit of the reference, on missing
#                markers and on a JSON file that nothing generates, and writes nothing
#   reference    every PrometheusRule alert, Grafana rule uid and dashboard uid is named
#                in docs/monitoring.md; every metric there has a source
#   promtool     promtool check rules on the PrometheusRule's groups (skipped without promtool)
# Requires python3 with PyYAML; skipped without it.
# shellcheck disable=SC2016
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
command -v python3 >/dev/null || { echo "SKIP tests/monitoring: python3 not installed" >&2; exit 0; }
python3 -c "import yaml" 2>/dev/null || { echo "SKIP tests/monitoring: python3 PyYAML not installed" >&2; exit 0; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { printf 'ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL %s\n' "$1"; [[ -z "${2:-}" ]] || printf '%s\n' "$2" | sed 's/^/       | /' | tail -15; FAIL=$((FAIL + 1)); }
GEN="$ROOT/monitoring/grafana/generate.py"
DOC="$ROOT/docs/monitoring.md"
RULES="$ROOT/monitoring/standalone/hub/prometheusrule-tpg.yaml"

# ---- generator
if python3 "$GEN" --check >"$TMP/gen.out" 2>&1; then
  ok "generate.py --check: every generated file and the docs/monitoring.md reference are up to date"
else
  bad "generate.py --check (run python3 monitoring/grafana/generate.py)" "$(cat "$TMP/gen.out")"
fi

# ---- check mode, on a copy of the generator, its outputs and the page
copy() {
  rm -rf "$TMP/repo"; mkdir -p "$TMP/repo/docs"
  cp -R "$ROOT/monitoring" "$TMP/repo/monitoring"
  cp "$DOC" "$TMP/repo/docs/monitoring.md"
}
check_copy() { python3 "$TMP/repo/monitoring/grafana/generate.py" --check >"$TMP/c.out" 2>&1; }

copy
if check_copy; then ok "check mode: a clean copy passes"; else bad "check mode: a clean copy fails" "$(cat "$TMP/c.out")"; fi

copy
sed -i 's/^### Alert rules$/### Alert rules (edited by hand)/' "$TMP/repo/docs/monitoring.md"
cp "$TMP/repo/docs/monitoring.md" "$TMP/edited.md"
if check_copy; then bad "check mode: a hand edit of the reference passes"
elif grep -q 'docs/monitoring.md' "$TMP/c.out"; then ok "check mode: a hand edit of the reference fails and names docs/monitoring.md"
else bad "check mode: the failure does not name docs/monitoring.md" "$(cat "$TMP/c.out")"; fi
if cmp -s "$TMP/repo/docs/monitoring.md" "$TMP/edited.md"; then ok "check mode: writes nothing"
else bad "check mode: changed docs/monitoring.md"; fi

copy
grep -v 'BEGIN GENERATED: monitoring-reference' "$DOC" > "$TMP/repo/docs/monitoring.md"
if check_copy; then bad "check mode: a page without the BEGIN marker passes"
elif grep -q 'must hold the lines' "$TMP/c.out"; then ok "check mode: a page without the BEGIN marker fails"
else bad "check mode: missing marker not reported" "$(cat "$TMP/c.out")"; fi

copy
printf '{"uid": "tpg-removed"}\n' > "$TMP/repo/monitoring/grafana/alerts/api/tpg-removed.json"
if check_copy; then bad "check mode: an alert payload that nothing generates passes"
elif grep -q 'tpg-removed.json (not generated' "$TMP/c.out"; then ok "check mode: an alert payload that nothing generates fails"
else bad "check mode: the extra payload is not named" "$(cat "$TMP/c.out")"; fi

copy
sed -i 's/"refresh": "30s"/"refresh": "5s"/' "$TMP/repo/monitoring/standalone/hub/dashboards/tpg-backup.json"
if check_copy; then bad "check mode: a hand-edited dashboard passes"
elif grep -q 'dashboards/tpg-backup.json' "$TMP/c.out"; then ok "check mode: a hand-edited dashboard fails"
else bad "check mode: the edited dashboard is not named" "$(cat "$TMP/c.out")"; fi

# ---- reference: names in docs/monitoring.md
b="$(grep -c '^<!-- BEGIN GENERATED: monitoring-reference -->$' "$DOC" || true)"
e="$(grep -c '^<!-- END GENERATED: monitoring-reference -->$' "$DOC" || true)"
if [[ "$b" == 1 && "$e" == 1 ]]; then ok "docs/monitoring.md has one BEGIN and one END marker"
else bad "docs/monitoring.md markers" "BEGIN ${b}x, END ${e}x (expected once each)"; fi

python3 - "$RULES" >"$TMP/alerts" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
for g in doc["spec"]["groups"]:
    for r in g["rules"]:
        print(r["alert"])
PY
python3 - "$ROOT/monitoring/grafana/alerts/api" "$ROOT/monitoring/standalone/hub/dashboards" >"$TMP/uids" <<'PY'
import glob, json, os, sys
for d, kind in ((sys.argv[1], "rule"), (sys.argv[2], "dashboard")):
    for f in sorted(glob.glob(os.path.join(d, "*.json"))):
        print(kind, json.load(open(f))["uid"])
PY
missing=()
n=0
while read -r a; do
  n=$((n + 1))
  grep -qF -- "\`${a}\`" "$DOC" || missing+=("$a")
done <"$TMP/alerts"
if [[ "$n" -gt 0 && "${#missing[@]}" -eq 0 ]]; then ok "every PrometheusRule alert (${n}) is named in docs/monitoring.md"
else bad "PrometheusRule alerts missing from docs/monitoring.md (${n} rules)" "${missing[*]:-no alerts found in $RULES}"; fi
for kind in rule dashboard; do
  missing=(); n=0
  while read -r k u; do
    [[ "$k" == "$kind" ]] || continue
    n=$((n + 1))
    grep -qF -- "\`${u}\`" "$DOC" || missing+=("$u")
  done <"$TMP/uids"
  if [[ "$n" -gt 0 && "${#missing[@]}" -eq 0 ]]; then ok "every Grafana ${kind} uid (${n}) is named in docs/monitoring.md"
  else bad "Grafana ${kind} uids missing from docs/monitoring.md (${n} files)" "${missing[*]:-none found}"; fi
done
awk '/^<!-- BEGIN GENERATED: monitoring-reference -->$/ {on = 1} on {print} /^<!-- END GENERATED: monitoring-reference -->$/ {on = 0}' \
  "$DOC" >"$TMP/reference.md"
if grep -q 'not classified' "$TMP/reference.md"; then
  bad "a metric in the reference has no source (add it to METRIC_SOURCES in generate.py)" "$(grep 'not classified' "$TMP/reference.md")"
else
  ok "every metric in the reference has a source"
fi

# ---- promtool
if command -v promtool >/dev/null; then
  python3 - "$RULES" >"$TMP/rules.yaml" <<'PY'
import sys, yaml
print(yaml.safe_dump(yaml.safe_load(open(sys.argv[1]))["spec"], sort_keys=False))
PY
  if promtool check rules "$TMP/rules.yaml" >"$TMP/promtool.out" 2>&1; then
    ok "promtool check rules: the PrometheusRule groups are valid"
  else
    bad "promtool check rules" "$(cat "$TMP/promtool.out")"
  fi
else
  echo "skip promtool check rules: promtool not installed (the PrometheusRule is still checked by kubeconform in scripts/validate.sh)"
fi

echo
echo "monitoring: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
