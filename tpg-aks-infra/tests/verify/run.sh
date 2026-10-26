#!/usr/bin/env bash
# scripts/steps/60-verify.sh against a stubbed cluster.
#
# What this proves: every check that reads a field of a Kubernetes object says
# so when the object is missing. Before, a missing StorageClass produced
#
#   WARN aks-tpg-poc-01: StorageClass tpg-data-retain (disk SKU StandardSSD_LRS)
#
# which reads as a wrong disk SKU. It now names the missing object, and a
# StorageClass that exists with the wrong SKU reports the SKU it has.
#
# And the run ends with one summary: every failed check grouped by resource,
# with the clusters it fails on (a StorageClass missing on the hub and the three
# targets is one entry naming the four clusters), advisory findings apart, exit 1
# on any issue and "All checks passed" otherwise (cases 4 to 6 exercise the
# summary itself through scripts/lib/findings.sh).
#
# The stub kubectl and helm live in tpg-fleet (tests/helm4/bin), so both
# repositories test against the same fakes. Set FLEET_LOCAL_DIR, or keep the two
# repositories side by side.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
FLEET="${FLEET_LOCAL_DIR:-$(cd "$ROOT/.." && pwd)/tpg-fleet}"
STUBS="${FLEET}/tests/helm4/bin"

command -v python3 >/dev/null || { echo "SKIP tests/verify: python3 not installed" >&2; exit 0; }
command -v yq >/dev/null || { echo "SKIP tests/verify: yq not installed" >&2; exit 0; }
[[ -d "$STUBS" ]] || { echo "SKIP tests/verify: stubs not found at ${STUBS} (set FLEET_LOCAL_DIR)" >&2; exit 0; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export PATH="${STUBS}:${PATH}"
export ENV_FILE="$TMP/env.sh"; : > "$ENV_FILE"
export INVENTORY="$TMP/inventory.yaml"
export STUB_KUBECTL_STATE="$TMP/cluster.json" STUB_HELM_STATE="$TMP/helm.json"
cat > "$INVENTORY" <<'YAML'
subscriptionId: 11111111-2222-3333-4444-555555555555
adminAllowedCidrs: ["203.0.113.10/32"]
hub: {name: aks-tpg-hub, resourceGroup: rg-tpgpoc, access: az, adminCredentials: true, egressCidrs: []}
targets:
  - {name: aks-tpg-poc-01, resourceGroup: rg-tpgpoc, wave: 0, access: az, adminCredentials: true,
     backupContainer: pg-backups-aks-tpg-poc-01}
  - {name: aks-tpg-poc-02, resourceGroup: rg-tpgpoc, wave: 1, access: az, adminCredentials: true,
     backupContainer: pg-backups-aks-tpg-poc-02}
  - {name: aks-tpg-poc-03, resourceGroup: rg-tpgpoc, wave: 1, access: az, adminCredentials: true,
     backupContainer: pg-backups-aks-tpg-poc-03}
backup: {storageAccount: tpgpocbkp, resourceGroup: rg-tpgpoc, createContainers: false, keySource: terraform}
storage: {dataDiskSku: StandardSSD_LRS}
vault: {unsealMode: shamir, exposure: public}
YAML
echo '{"releases": []}' > "$STUB_HELM_STATE"
PASS=0; FAIL=0

# The script colours its output; the assertions match plain text.
strip_ansi() { sed -E $'s/\033\\[[0-9;]*m//g'; }
export TPG_RETRY_DELAY=0
run_verify() {
  VERIFY_RC=0
  bash "$ROOT/scripts/steps/60-verify.sh" > "$TMP/out" 2> "$TMP/err" || VERIFY_RC=$?
  cat "$TMP/out" "$TMP/err" | strip_ansi
}

# assert NAME PATTERN: the run must print a line matching PATTERN
assert() {
  local name="$1" pattern="$2"
  if grep -Eq "$pattern" "$TMP/all"; then printf 'ok   %s\n' "$name"; PASS=$((PASS + 1))
  else printf 'FAIL %s\n       expected a line matching: %s\n' "$name" "$pattern"; FAIL=$((FAIL + 1)); fi
}
refute() {
  local name="$1" pattern="$2"
  if grep -Eq "$pattern" "$TMP/all"; then printf 'FAIL %s\n       unexpected line: %s\n' "$name" \
      "$(grep -Em1 "$pattern" "$TMP/all")"; FAIL=$((FAIL + 1))
  else printf 'ok   %s\n' "$name"; PASS=$((PASS + 1)); fi
}

echo "== case 1: nothing exists on any cluster"
echo '{"crds": [], "deployments": [], "statefulsets": [], "secrets": [], "services": []}' > "$STUB_KUBECTL_STATE"
run_verify > "$TMP/all"
assert "missing StorageClass is named, not read as a wrong SKU" \
  'StorageClass tpg-data-retain.*storageclass/tpg-data-retain not found on aks-tpg-poc-01'
refute "no bare WARN that only repeats the expected SKU" \
  'WARN aks-tpg-poc-01: StorageClass tpg-data-retain \(disk SKU StandardSSD_LRS\)$'
assert "missing Deployment is named" 'argocd-server ready: deploy/argocd-server not found on aks-tpg-hub'
assert "missing ConfigMap is named" 'cm/argocd-cm not found on aks-tpg-hub'
assert "missing CRD is named" 'cert-manager available: crd/certificates.cert-manager.io not found'
assert "missing Helm release is named" 'Helm release vault/vault is not installed on aks-tpg-hub'
assert "missing AppProject tpg-hub is named" 'AppProject tpg-hub: appproject/tpg-hub not found on aks-tpg-hub'
assert "missing admission policy is named (cluster-scoped)" \
  'ValidatingAdmissionPolicy tpg-application-sync: validatingadmissionpolicy/tpg-application-sync not found on aks-tpg-hub$'
assert "missing tpg-patch WorkflowTemplate is named" 'WorkflowTemplate tpg-patch: workflowtemplate/tpg-patch not found on aks-tpg-hub'
assert "missing tpg-backup-expire WorkflowTemplate is named (Round 23)" 'WorkflowTemplate tpg-backup-expire: workflowtemplate/tpg-backup-expire not found on aks-tpg-hub'
assert "the run ends with the summary" '^=+ verify summary =+$'
assert "the missing StorageClass on the hub is an issue (35-vault.sh creates it)" \
  '^ +[0-9]+\. StorageClass tpg-data-retain \(disk SKU StandardSSD_LRS\)$'
assert "the hub entry lists the hub only" '^ +clusters: aks-tpg-hub$'
assert "on targets whose tpg-platform never synced it is one WARNING entry for the three" \
  'clusters: aks-tpg-poc-01, aks-tpg-poc-02, aks-tpg-poc-03'
assert "with the reason once, naming the step that creates it" \
  'storageclass/tpg-data-retain not found on each cluster listed; this object will be created when the tpg-day0 workflow runs'
assert "the summary counts the issues" '^ISSUES \([0-9]+\)'
assert "the run fails with the count" 'FAIL verify found [0-9]+ issue\(s\)'
if [[ "$VERIFY_RC" -ne 0 ]]; then printf 'ok   %s\n' "exit status is non-zero ($VERIFY_RC)"; PASS=$((PASS + 1))
else printf 'FAIL %s\n' "exit status is 0 although checks failed"; FAIL=$((FAIL + 1)); fi
refute "the former message is gone" 'one or more checks failed'


echo
echo "== case 1b: the targets' tpg-platform Applications have synced, the StorageClass is still missing"
python3 - "$STUB_KUBECTL_STATE" <<'PY'
import json, sys
apps = [{"name": "tpg-%s-platform" % c, "namespace": "argocd",
         "status": {"history": [{"id": 0, "revision": "abc123"}]}}
        for c in ("aks-tpg-poc-01", "aks-tpg-poc-02")]
# poc-03: first sync finished, history not written yet
apps.append({"name": "tpg-aks-tpg-poc-03-platform", "namespace": "argocd",
             "status": {"operationState": {"phase": "Succeeded"}}})
json.dump({"crds": [], "deployments": [], "statefulsets": [], "secrets": [], "services": [],
           "applications": apps}, open(sys.argv[1], "w"))
PY
run_verify > "$TMP/all"
assert "after the first platform sync a missing StorageClass is an issue on every cluster" \
  'clusters: aks-tpg-hub, aks-tpg-poc-01, aks-tpg-poc-02, aks-tpg-poc-03'
assert "with the plain reason" 'storageclass/tpg-data-retain not found on each cluster listed$'
refute "and no longer the tpg-day0 warning" 'will be created when the tpg-day0 workflow runs'

echo
echo "== case 2: the StorageClass exists with the wrong SKU"
python3 - "$STUB_KUBECTL_STATE" <<'PY'
import json, sys
json.dump({"crds": [], "deployments": [], "statefulsets": [], "secrets": [], "services": [],
           "storageclasses": [{"name": "tpg-data-retain", "skuName": "Premium_ZRS"}]},
          open(sys.argv[1], "w"))
PY
run_verify > "$TMP/all"
assert "a wrong SKU reports the value that is there" \
  "StorageClass tpg-data-retain.*has 'Premium_ZRS' where 'StandardSSD_LRS' is expected"
refute "and does not claim the object is missing" \
  'storageclass/tpg-data-retain not found on aks-tpg-poc-01'

echo
echo "== case 3: the StorageClass exists with the expected SKU"
python3 - "$STUB_KUBECTL_STATE" <<'PY'
import json, sys
json.dump({"crds": [], "deployments": [], "statefulsets": [], "secrets": [], "services": [],
           "storageclasses": [{"name": "tpg-data-retain", "skuName": "StandardSSD_LRS"}]},
          open(sys.argv[1], "w"))
PY
run_verify > "$TMP/all"
assert "a matching SKU passes" 'OK +StorageClass tpg-data-retain \(disk SKU StandardSSD_LRS\)'
refute "and is not in the summary" '^ +[0-9]+\. StorageClass tpg-data-retain'

echo
echo "== case 3b: instances in the namespaces of clusters/fleet.yaml (Round 23)"
# the tpg-fleet clone the verify step reads: app-a and app-b share the namespace "shared" (app-a owns the Secrets),
# orders-db is in its default namespace pg-orders-db, which does not exist on the cluster yet
FLEETDIR="$TMP/fleetclone"; mkdir -p "$FLEETDIR/clusters" "$FLEETDIR/workflows/params"
cp "$FLEET/workflows/params/cluster-map-keys.yaml" "$FLEETDIR/workflows/params/"
cat > "$FLEETDIR/clusters/fleet.yaml" <<'YAML'
clusters:
  aks-tpg-poc-01:
    operator: {version: v4.5.0}
    instances:
      app-a: {instance: {namespace: shared, postgresVersion: postgres-17.6}}
      app-b: {instance: {namespace: shared, sharedSecretsOwner: false, postgresVersion: postgres-17.6}}
      orders-db: {instance: {postgresVersion: postgres-17.6}}
YAML
python3 - "$STUB_KUBECTL_STATE" <<'PY'
import json, sys
json.dump({"crds": ["postgres.sql.tanzu.vmware.com"], "deployments": [], "statefulsets": [], "secrets": [], "services": [],
           "namespaces": ["shared"], "postgres": [{"namespace": "shared", "name": "app-a"}]}, open(sys.argv[1], "w"))
PY
ORIG_FLD="${FLEET_LOCAL_DIR-}"; export FLEET_LOCAL_DIR="$FLEETDIR"
run_verify > "$TMP/all"
assert "an instance is checked in its fleet.yaml namespace, not in pg-<instance>" 'OK +instance aks-tpg-poc-01/app-a in namespace shared'
assert "a Postgres object missing from its namespace is a warning that names the namespace" \
  'Postgres aks-tpg-poc-01/app-b.*postgres/app-b not found on aks-tpg-poc-01 \(namespace shared\)'
assert "a namespace that does not exist yet is a warning" 'namespace pg-orders-db of instance aks-tpg-poc-01/orders-db.*namespace/pg-orders-db not found'
refute "exactly one owner of the shared Secrets in a namespace is no finding" 'namespace shared shared Secrets'
cat > "$FLEETDIR/clusters/fleet.yaml" <<'YAML'
clusters:
  aks-tpg-poc-01:
    operator: {version: v4.5.0}
    instances:
      app-a: {instance: {namespace: shared, postgresVersion: postgres-17.6}}
      app-b: {instance: {namespace: shared, postgresVersion: postgres-17.6}}
      app-c: {instance: {namespace: other, sharedSecretsOwner: false, postgresVersion: postgres-17.6}}
      app-d: {instance: {namespace: kube-system, postgresVersion: postgres-17.6}}
      app-e: {instance: {namespace: kube-team, postgresVersion: postgres-17.6}}
      app-f: {instance: {namespace: vault-secrets-operator-system, postgresVersion: postgres-17.6}}
YAML
run_verify > "$TMP/all"
assert "two owners in one namespace are an issue" 'namespace shared shared Secrets'
assert "and the issue names them" '2 of the instances app-a, app-b render the shared Secrets'
assert "a namespace without an owner is an issue" 'namespace other shared Secrets'
assert "a reserved namespace is an issue" 'instance aks-tpg-poc-01/app-d namespace kube-system'
assert "a name starting with kube- is an issue (the reserved prefix of cluster-map-keys.yaml)" 'instance aks-tpg-poc-01/app-e namespace kube-team'
assert "a namespace the fleet installs into (the Vault Secrets Operator) is an issue" 'instance aks-tpg-poc-01/app-f namespace vault-secrets-operator-system'
if [[ -n "$ORIG_FLD" ]]; then export FLEET_LOCAL_DIR="$ORIG_FLD"; else unset FLEET_LOCAL_DIR; fi

# ------------------------------------------------------------------ summary only
# scripts/lib/findings.sh with synthetic findings: the grouping, the per-cluster
# reasons, the warnings and the exit status, without a cluster.
summary_case() {  # summary_case NAME SCRIPT: run SCRIPT after sourcing common.sh and findings.sh
  local rc=0
  bash -c "source '$ROOT/scripts/lib/common.sh'; source '$ROOT/scripts/lib/findings.sh'; HUB=aks-tpg-hub; $2; print_summary" \
    > "$TMP/out" 2>&1 || rc=$?
  strip_ansi < "$TMP/out" > "$TMP/all"
  SUMMARY_RC="$rc"
}

expect_rc() {  # expect_rc zero|non-zero: the exit status of the last summary_case
  if { [[ "$1" == zero ]] && [[ "$SUMMARY_RC" -eq 0 ]]; } || { [[ "$1" == non-zero ]] && [[ "$SUMMARY_RC" -ne 0 ]]; }; then
    printf 'ok   exit status %s (%s)\n' "$1" "$SUMMARY_RC"; PASS=$((PASS + 1))
  else
    printf 'FAIL exit status %s, expected %s\n' "$SUMMARY_RC" "$1"; FAIL=$((FAIL + 1))
  fi
}

echo
echo "== case 4: no finding at all"
summary_case ok 'CUR=aks-tpg-hub'
assert "success message" '^All checks passed on the hub aks-tpg-hub and 3 target cluster\(s\)\.$'
refute "no ISSUES block" '^ISSUES'
expect_rc zero

echo
echo "== case 5: warnings only"
summary_case warn 'CUR=aks-tpg-poc-02; advisory "data pool not HA-capable" "2 Ready node(s) in 1 zone(s)"'
assert "WARNINGS block" '^WARNINGS \(1\)'
assert "still a success, counting the warnings" 'All checks passed on the hub aks-tpg-hub and 3 target cluster\(s\) \(1 warning\(s\) above\)'
expect_rc zero

echo
echo "== case 6: one resource, different reasons per cluster"
# shellcheck disable=SC2016  # expanded by the bash -c in summary_case
summary_case mixed 'for c in aks-tpg-poc-01 aks-tpg-poc-03; do CUR=$c; issue "StorageClass tpg-data-retain (disk SKU Premium_ZRS)" "storageclass/tpg-data-retain not found on $c"; done
  CUR=aks-tpg-poc-02; issue "StorageClass tpg-data-retain (disk SKU Premium_ZRS)" "storageclass/tpg-data-retain has StandardSSD_LRS where Premium_ZRS is expected"
  CUR=aks-tpg-poc-02; issue "cluster Secret argocd/cluster-aks-tpg-poc-02" "secret/cluster-aks-tpg-poc-02 not found on aks-tpg-hub"'
assert "one entry for the StorageClass on three clusters" 'clusters: aks-tpg-poc-01, aks-tpg-poc-03, aks-tpg-poc-02'
assert "per-cluster reason when they differ" '^ +aks-tpg-poc-02: storageclass/tpg-data-retain has StandardSSD_LRS'
assert "the cluster name is put back in the reason" '^ +aks-tpg-poc-01: storageclass/tpg-data-retain not found on aks-tpg-poc-01$'
assert "a per-cluster object keeps its name in the summary" '^ +[0-9]+\. cluster Secret argocd/cluster-aks-tpg-poc-02$'
assert "two issues counted" '^ISSUES \(2\)'
expect_rc non-zero

echo
echo "verify: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
