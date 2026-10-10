#!/usr/bin/env bash
# Keys nothing evaluates (Round 15, 1g; tools/unused-keys/audit.py): the chart
# values, clusters/fleet.example.yaml, the WorkflowTemplate inputs and their P_*
# variables, and (with the sibling tpg-aks-infra clone) the Terraform variables
# and the inventory example. Then the lint itself: a key planted in a copy of the
# repository (a chart value, a template input, an allow-list entry that is no
# longer a finding) makes it fail.
# Requires python3 with PyYAML, and helm for the chart checks.
# ok() and bad() always return 0
# shellcheck disable=SC2015
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
python3 -c 'import yaml' 2>/dev/null || { echo "SKIP tests/unused-keys: python3 PyYAML not installed" >&2; exit 0; }
command -v helm >/dev/null || { echo "SKIP tests/unused-keys: helm not installed" >&2; exit 0; }
PASS=0; FAIL=0
ok()  { printf 'ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL %s\n' "$1"; [[ -z "${2:-}" ]] || printf '%s\n' "$2" | sed 's/^/       | /' | tail -12; FAIL=$((FAIL + 1)); }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

RC=0; OUT="$(python3 "$ROOT/tools/unused-keys/audit.py" 2>&1)" || RC=$?
[[ "$RC" -eq 0 ]] && ok "every key is evaluated, or explained in the allow-list ($(tail -n1 <<<"$OUT"))" || bad "audit" "$OUT"

# the lint on a copy with planted keys
C="$TMP/fleet"; mkdir -p "$C"
cp -r "$ROOT/tools" "$ROOT/charts" "$ROOT/clusters" "$ROOT/workflows" "$ROOT/bootstrap" "$C/"
sed -i 's/^  walStorageSize: 10Gi$/  walStorageSize: 10Gi\n  retentionDays: 35/' "$C/clusters/_template/instance.yaml"
RC=0; OUT="$(INFRA_DIR=/nonexistent python3 "$C/tools/unused-keys/audit.py" 2>&1)" || RC=$?
[[ "$RC" -ne 0 ]] && grep -q "FAIL chart instance.retentionDays: clusters/_template/instance.yaml: changing it changes no rendered object" <<<"$OUT" \
  && ok "a value no template reads fails the lint" || bad "planted value" "$OUT"
cp "$ROOT/clusters/_template/instance.yaml" "$C/clusters/_template/instance.yaml"
python3 - "$C/workflows/templates/tpg-backup.yaml" <<'PY'
import sys, yaml
p = sys.argv[1]; d = yaml.safe_load(open(p))
d["spec"]["arguments"]["parameters"].append({"name": "keepDays", "value": "7"})
yaml.safe_dump(d, open(p, "w"), sort_keys=False)
PY
RC=0; OUT="$(INFRA_DIR=/nonexistent python3 "$C/tools/unused-keys/audit.py" 2>&1)" || RC=$?
[[ "$RC" -ne 0 ]] && grep -q "FAIL inputs tpg-backup.keepDays: the template never references it" <<<"$OUT" \
  && ok "a WorkflowTemplate input nothing uses fails the lint" || bad "planted input" "$OUT"
cp "$ROOT/workflows/templates/tpg-backup.yaml" "$C/workflows/templates/tpg-backup.yaml"
python3 - "$C/tools/unused-keys/allow-list.yaml" <<'PY'
import sys, yaml
p = sys.argv[1]; d = yaml.safe_load(open(p))
d["chart"]["instance.walStorageSize"] = {"reason": "test", "readBy": "charts/tpg-instance/values.yaml"}
yaml.safe_dump(d, open(p, "w"), sort_keys=False)
PY
RC=0; OUT="$(INFRA_DIR=/nonexistent python3 "$C/tools/unused-keys/audit.py" 2>&1)" || RC=$?
[[ "$RC" -ne 0 ]] && grep -q "FAIL allow-list chart instance.walStorageSize: no longer a finding" <<<"$OUT" \
  && ok "an allow-list entry for an evaluated key fails the lint (the list stays exact)" || bad "stale allow-list" "$OUT"

echo
echo "unused-keys: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
