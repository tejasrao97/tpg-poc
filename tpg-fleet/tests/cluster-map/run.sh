#!/usr/bin/env bash
# clusterMap and the list inputs: workflows/scripts/validate-params.sh (with
# clustermap.py and workflows/params/cluster-map-keys.yaml), the clusterMap
# accessors of lib.sh, and fleet-day0.sh (tpg-day0 values and the version rule).
#
# validate-params.sh runs with the real lib.sh and a stub kubectl that lists the
# registered clusters. fleet-day0.sh runs with the real lib.sh and stubs for
# Git, the run ConfigMap and the target clusters (what each one runs), as a dry
# run, so the planned clusters/fleet.yaml is read from /tmp/fleet.json.
#
# Requires: bash 4, python3, jq, yq (mikefarah).
# ok() and bad() always return 0; single-quoted snippets are jq, yq or YAML.
# shellcheck disable=SC2015,SC2016
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
for t in python3 jq yq openssl; do command -v "$t" >/dev/null || { echo "SKIP tests/cluster-map: $t not installed" >&2; exit 0; }; done
yq --version 2>&1 | grep -q mikefarah || { echo "SKIP tests/cluster-map: yq is not mikefarah yq v4" >&2; exit 0; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { printf 'ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL %s\n' "$1"; [[ -z "${2:-}" ]] || printf '%s\n' "$2" | sed 's/^/       | /' | tail -12; FAIL=$((FAIL + 1)); }

# ---- stub kubectl: registered clusters
mkdir -p "$TMP/bin"
cat > "$TMP/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
if [[ "$*" == *"get secret -l tpg.fleet/cluster"* ]]; then
  printf '{"items":[%s]}' "$(for c in aks-tpg-poc-01 aks-tpg-poc-02 aks-tpg-poc-03; do
    printf '{"metadata":{"labels":{"tpg.fleet/cluster":"%s"}}},' "$c"; done | sed 's/,$//')"
  exit 0
fi
# the Workflow object of the run (tpg-rotate-credential reads wrappingToken from it): S_TOKEN set
if [[ "$*" == *"get workflow"* && -n "${S_TOKEN:-}" ]]; then
  jq -cn --arg t "$S_TOKEN" '{spec: {arguments: {parameters: [{name: "wrappingToken", value: $t}]}}}'
  exit 0
fi
exit 0
STUB
chmod +x "$TMP/bin/kubectl"
# the fleet repository the tpg-scale-instance validate step reads (Round 13 addendum):
# orders-db on aks-tpg-poc-01 runs HA, billing-db is a single node
mkdir -p "$TMP/scalerepo/clusters"
cp -r "$ROOT/clusters/_template" "$TMP/scalerepo/clusters/"
cat > "$TMP/scalerepo/clusters/fleet.yaml" <<'YAML'
clusters:
  aks-tpg-poc-01:
    operator:
      version: v4.5.0
    cluster:
      allowInPlaceRestore: true   # tpg-restore: the in-place pair below (validate-params.sh reads it)
    instances:
      orders-db:
        instance:
          highAvailability:
            enabled: true
            readReplicas: 2
      billing-db:
        instance:
          highAvailability:
            enabled: false
            readReplicas: 0
YAML
sed -e "s#source /scripts/lib.sh#source $ROOT/workflows/scripts/lib.sh#" \
    -e "/^source .*lib.sh\$/a git_clone() { rm -rf \"\$1\"; cp -r $TMP/scalerepo \"\$1\"; }" \
    "$ROOT/workflows/scripts/validate-params.sh" > "$TMP/validate.sh"

vp() {  # vp MODE VAR=VALUE... -> runs validate-params.sh; output in $OUT, status in $RC
  local mode="$1"; shift
  rm -rf "$TMP/work"
  RC=0; OUT="$(cd "$TMP" && env -i PATH="$TMP/bin:$PATH" HOME="$TMP" TPG_WORK="$TMP/work" "$@" \
    bash "$TMP/validate.sh" "$mode" 2>&1)" || RC=$?
}
valid() { [[ "$RC" -eq 0 ]] && ok "$1" || bad "$1" "$OUT"; }
invalid() {  # invalid LABEL TEXT...
  local t
  [[ "$RC" -ne 0 ]] || { bad "$1 (accepted)" "$OUT"; return; }
  for t in "${@:2}"; do grep -qF -- "$t" <<<"$OUT" || { bad "$1 (no '$t')" "$OUT"; return; }; done
  ok "$1"
}

MAP_OK='aks-tpg-poc-01:
  operatorVersion: 4.5.0
  instances:
    orders-db:
      postgresVersion: 16.10
      highAvailability: true
      storageSize: 50Gi
      cpu: "2"
    billing-db:
      postgresVersion: postgres-17.6
      highAvailability: false
      backupEnableSSL: true
aks-tpg-poc-02:
  operatorVersion: v4.5.0
  instances:
    orders-db: {postgresVersion: "17.6", highAvailability: true, readReplicas: 2}'

# ---- tpg-day0
vp day0 P_CLUSTER_MAP="$MAP_OK" P_PUSH_MODE=direct
valid "day0: a YAML clusterMap with per-instance keys is valid"
[[ "$(cat /tmp/selection)" == "aks-tpg-poc-01,aks-tpg-poc-02" && "$(jq -c . /tmp/clusters.json)" == '["aks-tpg-poc-01","aks-tpg-poc-02"]' ]] \
  && ok "day0: the selection and the cluster list come from the map" || bad "day0 selection" "$(cat /tmp/selection) $(cat /tmp/clusters.json)"
jq -e '.["aks-tpg-poc-01"].instances["orders-db"].postgresVersion == "postgres-16.10" and .["aks-tpg-poc-01"].operatorVersion == "v4.5.0"' \
  "$TMP/work/cmap.json" >/dev/null && ok "day0: an unquoted 16.10 stays postgres-16.10; 4.5.0 becomes v4.5.0" || bad "day0 normalize" "$(cat "$TMP/work/cmap.json")"
vp day0 P_CLUSTER_MAP='{"aks-tpg-poc-01":{"operatorVersion":"v4.5.0","instances":{"orders-db":{"postgresVersion":"17.6","highAvailability":true}}}}' P_PUSH_MODE=pr
valid "day0: a JSON clusterMap is valid"
vp day0 P_CLUSTER_MAP='aks-tpg-poc-01:
  operatorVersion: v4.5.0
  instances:
    orders_db: {postgresVersion: "17.6", highAvailability: true}' P_PUSH_MODE=direct
invalid "day0: orders_db is refused with a valid name suggested" "clusterMap.aks-tpg-poc-01.instances.orders_db" "(for example orders-db)"
vp day0 P_CLUSTER_MAP='aks-tpg-poc-1:
  operatorVersion: v4.5.0
  instances:
    orders-db: {postgresVersion: "17.6", highAvailability: true}' P_PUSH_MODE=direct
invalid "day0: an unregistered cluster is refused with the closest registered one" "cluster 'aks-tpg-poc-1' is not registered (did you mean aks-tpg-poc-01?)"
vp day0 P_CLUSTER_MAP='aks-tpg-poc-01:
  operatorVersion: v4.5.0
  instances:
    orders-db: {postgresVerison: "17.6", highAvailability: true}' P_PUSH_MODE=direct
invalid "day0: a misspelled key is refused with the closest key" "unknown key postgresVerison (did you mean postgresVersion?)"
vp day0 P_CLUSTER_MAP='aks-tpg-poc-01:
  instances:
    orders-db: {operatorVersion: v4.5.0, postgresVersion: "17.6", highAvailability: true}' P_PUSH_MODE=direct
invalid "day0: operatorVersion on an instance is refused (a cluster key)" "operatorVersion is a cluster key: put it next to instances" "operatorVersion is required"
vp day0 P_CLUSTER_MAP='aks-tpg-poc-01:
  instances:
    orders-db: {postgresVersion: "17.6", highAvailability: true}' P_OPERATOR_VERSION=v4.5.0 P_PUSH_MODE=direct
valid "day0: the operatorVersion input is the default of a cluster without the key"
vp day0 P_CLUSTER_MAP='aks-tpg-poc-01:
  operatorVersion: v4.5.0
  instances:
    orders-db: {postgresVersion: "17.6", replicas: 2, highAvailability: yes}' P_PUSH_MODE=direct
invalid "day0: a key of another workflow and a bad boolean are refused" "replicas: not used by tpg-day0 (used by tpg-scale-instance)" "'yes' must be true or false"
vp day0 P_CLUSTER_MAP="$MAP_OK" P_CLUSTERS=all P_PUSH_MODE=direct
invalid "day0: clusterMap and clusters together are refused" "clusterMap and clusters cannot be used together"
vp day0 P_CLUSTERS=all P_INSTANCES='[orders-db]' P_HA=true P_OPERATOR_VERSION=v4.5.0 P_POSTGRES_VERSION=17.6 P_PUSH_MODE=direct
valid "day0: the list inputs without clusterMap stay valid"
vp day0 P_CLUSTER_MAP='just words' P_PUSH_MODE=direct
invalid "day0: a clusterMap that is not a mapping is refused" "clusterMap must be a mapping"

# ---- Round 23 phase 3: the instance key namespace (day0 and create-instance only)
for wf in day0 create-instance; do
  OPV=''; [[ "$wf" != day0 ]] || OPV='  operatorVersion: v4.5.0'   # a cluster key of tpg-day0 only
  vp "$wf" P_CLUSTER_MAP="aks-tpg-poc-01:
${OPV}
  instances:
    orders-db: {postgresVersion: \"17.6\", highAvailability: true, namespace: team-orders}
    billing-db: {postgresVersion: \"17.6\", highAvailability: false, namespace: team-orders}" P_PUSH_MODE=direct
  valid "${wf}: key namespace is accepted, also the same one on two instances (a shared namespace)"
  jq -e '.["aks-tpg-poc-01"].instances["orders-db"].namespace == "team-orders"' "$TMP/work/cmap.json" >/dev/null \
    && ok "${wf}: the namespace is kept in the normalized map" || bad "${wf} namespace normalized" "$(cat "$TMP/work/cmap.json")"
  # the reserved list is the one in cluster-map-keys.yaml (Round 23 review: every namespace the fleet installs
  # into, and any name starting with kube-)
  for r in $(yq -r '.instance.namespace.reserved[]' "$ROOT/workflows/params/cluster-map-keys.yaml") kube-other kube-x; do
    vp "$wf" P_CLUSTER_MAP="aks-tpg-poc-01:
${OPV}
  instances:
    orders-db: {postgresVersion: \"17.6\", highAvailability: true, namespace: ${r}}" P_PUSH_MODE=direct
    invalid "${wf}: reserved namespace ${r} is refused" "namespace '${r}' is reserved"
  done
  for r in vault-secrets-operator-system tpg-vault cert-manager monitoring argocd argo vault tanzu-postgres-operator kube-system default; do
    yq -e '.instance.namespace.reserved | contains(["'"$r"'"])' "$ROOT/workflows/params/cluster-map-keys.yaml" >/dev/null \
      && ok "${wf}: ${r} is in the reserved list" || bad "${wf}: ${r} is not in the reserved list of cluster-map-keys.yaml"
  done
  vp "$wf" P_CLUSTER_MAP="aks-tpg-poc-01:
${OPV}
  instances:
    orders-db: {postgresVersion: \"17.6\", highAvailability: true, namespace: kubernetes-team}" P_PUSH_MODE=direct
  valid "${wf}: a name that only contains kube (kubernetes-team) is not reserved; the prefix is kube-"
  vp "$wf" P_CLUSTER_MAP="aks-tpg-poc-01:
${OPV}
  instances:
    orders-db: {postgresVersion: \"17.6\", highAvailability: true, namespace: Team_Orders}" P_PUSH_MODE=direct
  invalid "${wf}: a namespace that is not a lowercase DNS label is refused" "instances.orders-db.namespace: 'Team_Orders' must be a namespace name"
  vp "$wf" P_CLUSTER_MAP="aks-tpg-poc-01:
${OPV}
  instances:
    orders-db: {postgresVersion: \"17.6\", highAvailability: true, namespace: $(printf 'a%.0s' $(seq 1 64))}" P_PUSH_MODE=direct
  invalid "${wf}: a namespace of 64 characters is refused (63 at most)" "must be a namespace name"
  vp "$wf" P_CLUSTER_MAP="aks-tpg-poc-01:
${OPV}
  instances:
    orders-db: {postgresVersion: \"17.6\", highAvailability: true, namespace: $(printf 'a%.0s' $(seq 1 63))}" P_PUSH_MODE=direct
  valid "${wf}: a namespace of 63 characters is accepted"
  vp "$wf" P_CLUSTER_MAP="aks-tpg-poc-01:
${OPV}
  instances:
    orders-db: {postgresVersion: \"17.6\", highAvailability: true, namespace: [team-orders]}" P_PUSH_MODE=direct
  invalid "${wf}: a list is not a namespace" "a single value is expected"
done
vp delete-instance P_CLUSTER_MAP='aks-tpg-poc-01:
  instances:
    orders-db: {namespace: team-orders}' P_CONFIRM='[aks-tpg-poc-01]' P_PUSH_MODE=direct
invalid "delete-instance: namespace is not a key of it (the delete reads fleet.yaml)" "namespace: not used by tpg-delete-instance (used by tpg-day0, tpg-create-instance)"
vp patch P_CLUSTER_MAP='aks-tpg-poc-01:
  instances:
    orders-db: {namespace: team-orders}' P_PUSH_MODE=direct
invalid "patch: namespace is not a key of it" "namespace: not used by tpg-patch"

# ---- CA bundle sources (Round 15, 3.i and 3.ii)
vp day0 P_CLUSTER_MAP='aks-tpg-poc-01: {operatorVersion: v4.5.0, instances: {orders-db: {postgresVersion: "17.6", highAvailability: true, backupEnableSSL: true, backupCaBundleFile: [./ca.pem]}}}' P_PUSH_MODE=direct \
  P_PATCH_FILES="{\"./ca.pem\": \"$(printf 'x' | base64)\"}"
invalid "3.i: a local CA bundle file is read from patchFiles and checked as PEM" "backupCaBundleFile: ca.pem: no PEM certificate"
vp day0 P_CLUSTER_MAP='aks-tpg-poc-01: {operatorVersion: v4.5.0, instances: {orders-db: {postgresVersion: "17.6", highAvailability: true, backupEnableSSL: true, backupCaBundleFile: [repo:ca-bundles/azure.pem], backupCaBundleVaultSecret: azure-storage}}}' P_PUSH_MODE=direct
invalid "3.i/3.ii: a file and a Vault secret on one level are refused" "backupCaBundleFile and backupCaBundleVaultSecret on one level: name one source"
vp day0 P_CLUSTER_MAP='aks-tpg-poc-01: {operatorVersion: v4.5.0, backupCaBundleVaultSecret: azure-storage, instances: {orders-db: {postgresVersion: "17.6", highAvailability: true, backupEnableSSL: true, backupCaBundleFile: [repo:ca-bundles/azure.pem]}}}' P_PUSH_MODE=direct
valid "3.i/3.ii: an instance file over a cluster Vault secret (one source per level) is valid"
vp day0 P_CLUSTER_MAP='aks-tpg-poc-01: {operatorVersion: v4.5.0, instances: {orders-db: {postgresVersion: "17.6", highAvailability: true, backupCaBundleVaultSecret: azure-storage}}}' P_PUSH_MODE=direct
invalid "3.ii: a CA bundle source needs backupEnableSSL=true" "a CA bundle source needs backupEnableSSL=true"
vp day0 P_CLUSTER_MAP='aks-tpg-poc-01: {operatorVersion: v4.5.0, instances: {orders-db: {postgresVersion: "17.6", highAvailability: true, backupEnableSSL: true, backupCaBundleFile: [repo:helm_artifacts/x.pem]}}}' P_PUSH_MODE=direct
invalid "3.i: a repo: CA bundle lives under ca-bundles/" "repo:helm_artifacts/x.pem"
vp day0 P_CLUSTERS='[aks-tpg-poc-01]' P_INSTANCES='[orders-db]' P_HA=true P_OPERATOR_VERSION=v4.5.0 P_POSTGRES_VERSION=17.6 P_BACKUP_CA_VAULT=azure-storage P_PUSH_MODE=direct
invalid "3.ii: the Vault secret input without backupEnableSSL is refused" "need backupEnableSSL=true"
vp day0 P_CLUSTER_MAP='aks-tpg-poc-01: {operatorVersion: v4.5.0, instances: {orders-db: {postgresVersion: "17.6", highAvailability: true, enableSSL: true}}}' P_PUSH_MODE=direct
invalid "3.iii: enableSSL is renamed backupEnableSSL" "unknown key enableSSL (renamed backupEnableSSL in Round 15)"
vp patch P_CLUSTERS='[aks-tpg-poc-01]' P_INSTANCES='[orders-db]' P_BACKUP_CA_VAULT=azure-storage P_PUSH_MODE=direct
valid "3.ii: tpg-patch with only a CA bundle source is a patch run"

# ---- tpg-scale-instance
vp scale P_CLUSTERS='[aks-tpg-poc-01, aks-tpg-poc-02]' P_INSTANCES='[orders-db, billing-db]' P_REPLICAS=2 P_PUSH_MODE=direct
valid "scale: clusters and instances lists are valid"
vp scale P_CLUSTERS=all P_INSTANCES='[orders-db]' P_REPLICAS=2 P_PUSH_MODE=direct
invalid "scale: clusters=all is refused" "clusters does not accept all"
vp scale P_CLUSTER_MAP='aks-tpg-poc-01: {instances: {orders-db: {}}}' P_PUSH_MODE=direct
invalid "scale: replicas is required (map key or input)" "orders-db: replicas is required (the map key replicas or the workflow input replicas)"
vp scale P_CLUSTER_MAP='aks-tpg-poc-01: {instances: {orders-db: {replicas: 3, enableHAIfNeeded: false}, billing-db: {}}}' P_REPLICAS=1 P_PUSH_MODE=direct
valid "scale: the replicas input is the default of an instance without the key"
vp scale P_CLUSTER_MAP='aks-tpg-poc-01: {instances: {billing-db: {replicas: 2, enableHAIfNeeded: false}}}' P_PUSH_MODE=direct
invalid "scale: replicas 2 with enableHAIfNeeded=false on a single-node instance fails at validation" \
  "aks-tpg-poc-01/billing-db: replicas 2 needs highAvailability, and billing-db is declared a single node" "(HA_DISABLED)"
vp scale P_CLUSTERS='[aks-tpg-poc-01]' P_INSTANCES='[orders-db, billing-db]' P_REPLICAS=1 P_ENABLE_HA=false P_PUSH_MODE=direct
invalid "scale inputs: enableHAIfNeeded=false names only the single-node instance" "aks-tpg-poc-01/billing-db: replicas 1 needs highAvailability"
grep -q "orders-db: replicas" <<<"$OUT" && bad "scale inputs: the HA instance is not refused" "$OUT" || ok "scale inputs: the HA instance is not refused"
vp scale P_CLUSTERS='[aks-tpg-poc-01]' P_INSTANCES='[billing-db]' P_REPLICAS=0 P_ENABLE_HA=false P_PUSH_MODE=direct
valid "scale inputs: replicas=0 with enableHAIfNeeded=false is valid (a single node stays one)"
# maxReadReplicas, rolloutMode, maxParallel (Round 14)
vp scale P_CLUSTERS='[aks-tpg-poc-01]' P_MAX_READ_REPLICAS=5 P_PUSH_MODE=direct
valid "scale: maxReadReplicas alone (no instances) is valid"
vp scale P_CLUSTERS='[aks-tpg-poc-01]' P_PUSH_MODE=direct
invalid "scale: neither instances nor maxReadReplicas is refused" "instances is mandatory"
vp scale P_CLUSTERS='[aks-tpg-poc-01]' P_REPLICAS=2 P_MAX_READ_REPLICAS=5 P_PUSH_MODE=direct
invalid "scale: replicas without instances is refused" "replicas needs instances"
vp scale P_CLUSTERS='[aks-tpg-poc-01]' P_MAX_READ_REPLICAS=0 P_PUSH_MODE=direct
invalid "scale: maxReadReplicas 0 is refused" "maxReadReplicas must be a positive integer"
vp scale P_CLUSTERS='[aks-tpg-poc-01]' P_MAX_READ_REPLICAS=1 P_PUSH_MODE=direct
invalid "scale: a cap below a declared readReplicas fails at validation" \
  "aks-tpg-poc-01: maxReadReplicas 1 is below the read replicas of orders-db=2 (MAX_BELOW_CURRENT)"
vp scale P_CLUSTERS='[aks-tpg-poc-01]' P_INSTANCES='[orders-db]' P_REPLICAS=1 P_MAX_READ_REPLICAS=1 P_PUSH_MODE=direct
valid "scale: the same cap is valid when the run scales the instance down to it"
vp scale P_CLUSTER_MAP='aks-tpg-poc-01: {maxReadReplicas: 1}' P_PUSH_MODE=direct
invalid "scale map: a cap below a declared readReplicas fails at validation" "orders-db=2 (MAX_BELOW_CURRENT)"
vp scale P_CLUSTER_MAP='aks-tpg-poc-01: {maxReadReplicas: 1, instances: {orders-db: {replicas: 0}}}' P_PUSH_MODE=direct
valid "scale map: a cap with the instance scaled down in the same entry is valid"
vp scale P_CLUSTER_MAP='aks-tpg-poc-01: {}' P_PUSH_MODE=direct
invalid "scale map: a cluster with neither instances nor maxReadReplicas is refused" "nothing to do on this cluster"
vp scale P_CLUSTER_MAP='aks-tpg-poc-01: {}' P_MAX_READ_REPLICAS=4 P_PUSH_MODE=direct
valid "scale map: the maxReadReplicas input fills a cluster entry without instances"
vp scale P_CLUSTER_MAP='aks-tpg-poc-02: {maxReadReplicas: 4}' P_PUSH_MODE=direct
invalid "scale map: a cap for a cluster without a fleet.yaml entry is refused" "aks-tpg-poc-02: maxReadReplicas is written to clusters.aks-tpg-poc-02.cluster"
vp scale P_CLUSTERS='[aks-tpg-poc-01]' P_INSTANCES='[orders-db]' P_REPLICAS=1 P_ROLLOUT_MODE=waves P_MAX_PARALLEL=0 P_PUSH_MODE=direct
invalid "scale: rolloutMode and maxParallel are checked" "rolloutMode" "maxParallel must be a positive integer"

# ---- tpg-backup and tpg-backup-retention
vp backup P_CLUSTERS=all
valid "backup: clusters=all (the CronWorkflows) is valid"
vp backup P_CLUSTER_MAP='aks-tpg-poc-02: {instances: {orders-db: {backupType: incremental, backupTimeoutSeconds: 600}}}'
valid "backup: a clusterMap with backupType and backupTimeoutSeconds is valid"
vp backup P_CLUSTER_MAP='aks-tpg-poc-02: {instances: {orders-db: {backupType: weekly}}}'
invalid "backup: an unknown backupType is refused" "'weekly' must be one of full, incremental, differential"
vp backup-retention P_CLUSTERS=all
invalid "Round 15: tpg-backup-retention is gone" "unknown validation mode backup-retention"
vp day0 P_CLUSTER_MAP='aks-tpg-poc-01: {operatorVersion: v4.5.0, instances: {orders-db: {postgresVersion: "17.6", highAvailability: true, retentionDays: 7}}}' P_PUSH_MODE=direct
invalid "Round 15: retentionDays is not a clusterMap key" "unknown key retentionDays"
vp day0 P_CLUSTER_MAP='aks-tpg-poc-01: {operatorVersion: v4.5.0, instances: {orders-db: {postgresVersion: "17.6", highAvailability: true, backupFullRetention: 0}}}' P_PUSH_MODE=direct
invalid "Round 15: backupFullRetention 0 is refused" "'0' must be a positive integer"
vp day0 P_CLUSTER_MAP='aks-tpg-poc-01: {operatorVersion: v4.5.0, instances: {orders-db: {postgresVersion: "17.6", highAvailability: true, backupFullRetention: 14, backupFullRetentionType: time}}}' P_PUSH_MODE=direct
valid "Round 15: backupFullRetention with backupFullRetentionType time is valid"
vp day0 P_CLUSTERS='[aks-tpg-poc-01]' P_INSTANCES='[orders-db]' P_HA=true P_OPERATOR_VERSION=v4.5.0 P_POSTGRES_VERSION=17.6 P_BACKUP_FULL_RETENTION_TYPE=days P_PUSH_MODE=direct
invalid "Round 15: backupFullRetentionType is count or time" "backupFullRetentionType"

# ---- tpg-delete-instance and tpg-delete-apps
vp delete-instance P_CLUSTERS='[aks-tpg-poc-01, aks-tpg-poc-02]' P_INSTANCES='[orders-db, billing-db]' P_CONFIRM='[billing-db, orders-db]'
valid "delete-instance: confirm repeats the instances (any order)"
vp delete-instance P_CLUSTERS='[aks-tpg-poc-01]' P_INSTANCES='[orders-db]' P_CONFIRM='[orders]'
invalid "delete-instance: a confirm that differs is refused" "confirm must repeat the instances value"
# tpg-restore takes a list of pairs (Round 23); the rules of its keys are tested in tests/restore-map
RESTORE_BACKUP_MAP='- sourceClusterConfig: {aks-tpg-poc-01: {pg-orders: {orders-db: {sourceBackupName: orders-db-full-1}}}}
  targetClusterConfig: {aks-tpg-poc-02: {pg-orders: {orders-db-dr: {pitrEnabled: false}}}}'
vp restore P_CLUSTER_MAP="$RESTORE_BACKUP_MAP"
valid "restore: a named backup into another cluster is valid (Round 23 phase 6a follow-up)"
vp restore P_CLUSTER_MAP='- sourceClusterConfig: {aks-tpg-poc-01: {pg-orders: {orders-db: {sourceBackupName: orders-db-full-1}}}}
  targetClusterConfig: {aks-tpg-poc-01: {pg-orders: {orders-db: {pitrEnabled: false, confirm: orders-db}}}}' P_DRY_RUN=false
valid "restore: a named backup in place with confirm is valid"
vp delete-apps P_CLUSTERS='[aks-tpg-poc-01, aks-tpg-poc-02]' P_APPS='{"aks-tpg-poc-01":["tpg-operator"],"aks-tpg-poc-02":["tpg-operator"]}' P_CONFIRM='[aks-tpg-poc-02, aks-tpg-poc-01]' P_DRY_RUN=true P_PURGE_PVCS=false P_PURGE_NS=false P_PUSH_MODE=direct
valid "delete-apps: confirm repeats the clusters in any order"
vp delete-instance P_CLUSTER_MAP='aks-tpg-poc-01: {instances: {orders-db: {purgeNamespace: true}}}' P_CONFIRM='[aks-tpg-poc-01]'
invalid "delete-instance: purgeNamespace without purgePvcs is refused per instance" "orders-db: purgeNamespace=true needs purgePvcs=true"
vp delete-apps P_CLUSTER_MAP='aks-tpg-poc-03:
  deleteOperator: true
  instances:
    orders-db: {purgePvcs: true, purgeNamespace: true, finalBackup: required}
aks-tpg-poc-02:
  deleteOperator: true
  instances: {}' P_CONFIRM='[aks-tpg-poc-02, aks-tpg-poc-03]' P_DRY_RUN=true P_PUSH_MODE=direct
valid "delete-apps: a clusterMap with an operator-only cluster is valid"
vp delete-apps P_CLUSTER_MAP='aks-tpg-poc-03: {instances: {orders-db: {}}}' P_CONFIRM='[aks-tpg-poc-03]' P_DRY_RUN=true P_PUSH_MODE=direct
invalid "delete-apps: purgePvcs has no default" "orders-db: purgePvcs is required"
vp delete-apps P_CLUSTER_MAP='aks-tpg-poc-03: {instances: {}}' P_CONFIRM='[aks-tpg-poc-03]' P_DRY_RUN=true P_PUSH_MODE=direct
invalid "delete-apps: a cluster with nothing to delete is refused" "nothing to do on this cluster"

# ---- tpg-patch (Round 14: contents in patchFiles; Round 15: a list of postgres
# patch files, absolute, ~/ and ../ paths, repo:, clearKinds)
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
PG_OK="$(b64 $'apiVersion: sql.tanzu.vmware.com/v1\nkind: Postgres\nspec:\n  logLevel: Debug\n')"
VAL_OK="$(b64 $'backup:\n  fullRetention: 6\n')"
OP_OK="$(b64 $'resources:\n  limits: {cpu: 500m, memory: 300Mi}\nenableSecurityContext: true\n')"
vp patch P_CLUSTER_MAP='aks-tpg-poc-01:
  operatorValuesPatchFilePath: [./op.yaml]
  instances:
    orders-db: {postgresPatchFilePath: [pg.yaml], postgresValuesPatchFilePath: [vals/backup.yaml]}' P_PUSH_MODE=direct \
  P_PATCH_FILES="{\"op.yaml\": \"${OP_OK}\", \"./pg.yaml\": \"${PG_OK}\", \"vals/backup.yaml\": \"${VAL_OK}\"}"
valid "patch: a clusterMap with one file per kind, contents in patchFiles (./ ignored on either side), is valid"
PG_SCHED="$(b64 $'apiVersion: sql.tanzu.vmware.com/v1\nkind: PostgresBackupSchedule\nmetadata: {name: orders-db-backup-full}\nspec:\n  backupTemplate: {spec: {type: full}}\n  schedule: "0 1 * * *"\n')"
vp patch P_CLUSTER_MAP='aks-tpg-poc-01: {instances: {orders-db: {postgresPatchFilePath: [a.yaml, b.yaml]}}}' P_PUSH_MODE=direct \
  P_PATCH_FILES="{\"a.yaml\": \"${PG_OK}\", \"b.yaml\": \"${PG_SCHED}\"}"
valid "patch 1c: a list of postgres patch files (one kind per file) is valid"
vp patch P_CLUSTERS='[aks-tpg-poc-01]' P_INSTANCES='[orders-db]' P_POSTGRES_PATCH='[a.yaml, b.yaml]' P_PUSH_MODE=direct \
  P_PATCH_FILES="{\"a.yaml\": \"${PG_OK}\", \"b.yaml\": \"${PG_OK}\"}"
invalid "patch 1c: two files patching the same object are refused" "Postgres"
vp patch P_CLUSTER_MAP='aks-tpg-poc-01: {instances: {orders-db: {postgresPatchFilePath: [a.yaml, a.yaml]}}}' P_PUSH_MODE=direct \
  P_PATCH_FILES="{\"a.yaml\": \"${PG_OK}\"}"
invalid "patch 1c: the same file twice is refused" "postgresPatchFilePath: duplicate entries"
vp patch P_CLUSTER_MAP='aks-tpg-poc-01: {instances: {orders-db: {postgresPatchFilePath: [repo:helm_artifacts/instance/tpg-instance/patches/example-postgres-resources-ex4m1.yaml]}}}' P_PUSH_MODE=direct
valid "patch 2iii: a repo: file is read from the fleet branch, not from patchFiles"
vp patch P_CLUSTER_MAP='aks-tpg-poc-01: {instances: {orders-db: {postgresPatchFilePath: [repo:clusters/fleet.yaml]}}}' P_PUSH_MODE=direct
invalid "patch 2iii: a repo: file outside helm_artifacts/instance/tpg-instance/patches is refused" "repo:clusters/fleet.yaml"
vp patch P_CLUSTER_MAP='aks-tpg-poc-01: {operatorManifestPatchFilePath: m.yaml}' P_PUSH_MODE=direct
invalid "patch: operatorManifestPatchFilePath is gone" "unknown key operatorManifestPatchFilePath"
vp patch P_CLUSTER_MAP='aks-tpg-poc-01: {instances: {orders-db: {postgresPatchFilePath: [../up/pg.yaml, /abs/sched.yaml, "~/home.yaml"]}}}' P_PUSH_MODE=direct \
  P_PATCH_FILES="{\"../up/pg.yaml\": \"${PG_OK}\", \"/abs/sched.yaml\": \"${PG_SCHED}\", \"~/home.yaml\": \"$(b64 $'apiVersion: sql.tanzu.vmware.com/v1\nkind: PostgresBackupLocation\nspec:\n  retentionPolicy: {fullRetention: {number: 5}}\n')\"}"
valid "patch 1d: ../, absolute and ~/ paths are accepted (the key is the path as given)"
vp patch P_CLUSTER_MAP='aks-tpg-poc-01: {instances: {orders-db: {postgresPatchFilePath: [pg.txt]}}}' P_PUSH_MODE=direct
invalid "patch 1d: a path that is not a .yaml or .yml file is refused" "pg.txt"
vp patch P_CLUSTER_MAP='aks-tpg-poc-01: {instances: {orders-db: {valuesPatchFilePath: mem.yaml}}}' P_PUSH_MODE=direct
invalid "patch 1b: valuesPatchFilePath is renamed" "unknown key valuesPatchFilePath (renamed postgresValuesPatchFilePath in Round 15)"
vp patch P_CLUSTER_MAP='aks-tpg-poc-01: {instances: {orders-db: {postgresValuesPatchFilePath: [mem.yaml]}}}' P_PUSH_MODE=direct
invalid "patch: a file whose contents did not come is refused" "mem.yaml: its contents are not in patchFiles"
vp patch P_CLUSTER_MAP='aks-tpg-poc-01: {instances: {orders-db: {}}}' P_PUSH_MODE=direct
invalid "patch: an instance without any patch file is refused" "no postgresPatchFilePath, postgresValuesPatchFilePath or CA bundle source"
vp patch P_CLUSTERS=all P_OPERATOR_VALUES_PATCH='[op.yaml]' P_PUSH_MODE=direct P_PATCH_FILES="{\"op.yaml\": \"${OP_OK}\"}"
valid "patch: an operator values patch on every cluster (inputs) is valid"
vp patch P_CLUSTERS=all P_PUSH_MODE=direct
invalid "patch: no patch file at all is refused" "no patch file"
# the repo: paths of the operator files (Round 23 phase 1: helm_artifacts/operator/{patches,overlays}/)
vp patch P_CLUSTERS=all P_OPERATOR_VALUES_PATCH='[repo:helm_artifacts/operator/patches/team.yaml]' P_PUSH_MODE=direct
valid "patch: repo:helm_artifacts/operator/patches/team.yaml is a valid operator patch file"
vp patch P_CLUSTERS=all P_OPERATOR_VALUES_PATCH='[repo:helm_artifacts/operator/patches/clusters/c1.yaml]' P_PUSH_MODE=direct
invalid "patch: the per-cluster patch copy is refused as an operator patch file" "is a copy the workflows write per cluster"
vp patch P_CLUSTERS=all P_OPERATOR_VALUES_PATCH='[repo:helm_artifacts/operator/overlays/clusters/c1.yaml]' P_PUSH_MODE=direct
invalid "patch: the per-cluster overlay copy is refused as an operator patch file" "repo:helm_artifacts/operator/overlays/clusters/c1.yaml" "under helm_artifacts/operator/patches/"
vp day0 P_CLUSTERS='[aks-tpg-poc-01]' P_INSTANCES='[orders-db]' P_HA=true P_OPERATOR_VERSION=v4.5.0 P_POSTGRES_VERSION=17.6 P_PUSH_MODE=direct \
  P_OPERATOR_VALUES_OVERLAY_FILE='[repo:helm_artifacts/operator/overlays/clusters/c1.yaml]'
invalid "day0: the per-cluster overlay copy is refused as an operator overlay file" "is a copy the workflows write per cluster"
vp day0 P_CLUSTERS='[aks-tpg-poc-01]' P_INSTANCES='[orders-db]' P_HA=true P_OPERATOR_VERSION=v4.5.0 P_POSTGRES_VERSION=17.6 P_PUSH_MODE=direct \
  P_OPERATOR_VALUES_OVERLAY_FILE='[repo:helm_artifacts/operator/patches/clusters/c1.yaml]'
invalid "day0: the per-cluster patch copy is refused as an operator overlay file" "under helm_artifacts/operator/overlays/"
vp patch P_CLUSTERS=all P_OPERATOR_VALUES_PATCH='[repo:patches/operator/x.yaml]' P_PUSH_MODE=direct
invalid "patch: the old path repo:patches/operator/x.yaml is refused" "repo:patches/operator/x.yaml" "under helm_artifacts/operator/patches/"
vp patch P_CLUSTERS=all P_OPERATOR_VALUES_PATCH='[repo:helm_artifacts/operator/patches/../../clusters/fleet.yaml]' P_PUSH_MODE=direct
invalid "patch: a .. escape out of helm_artifacts/operator/patches is refused" "no .."
vp patch P_CLUSTERS='[aks-tpg-poc-01]' P_INSTANCES='[orders-db]' P_POSTGRES_PATCH='[repo:helm_artifacts/operator/patches/team.yaml]' P_PUSH_MODE=direct
invalid "patch: an operator folder file is refused as postgresPatchFilePath" "postgresPatchFilePath" "under helm_artifacts/instance/tpg-instance/patches/"
# the clusterMap route refuses the same copies (clustermap.py and the schema)
vp patch P_CLUSTER_MAP='aks-tpg-poc-01: {operatorValuesPatchFilePath: [repo:helm_artifacts/operator/patches/clusters/c1.yaml]}' P_PUSH_MODE=direct
invalid "patch: a clusterMap operator patch file in the per-cluster patch copy is refused" "is a copy the workflows write per cluster"
vp day0 P_CLUSTER_MAP='aks-tpg-poc-01: {operatorVersion: v4.5.0, operatorValuesOverlayFilePath: [repo:helm_artifacts/operator/overlays/clusters/c1.yaml], instances: {orders-db: {postgresVersion: "17.6", highAvailability: true}}}' P_PUSH_MODE=direct
invalid "day0: a clusterMap operator overlay file in the per-cluster overlay copy is refused" "is a copy the workflows write per cluster"
# 1a: the file must fit the input it is passed to
vp patch P_CLUSTERS='[aks-tpg-poc-01]' P_INSTANCES='[orders-db]' P_VALUES_PATCH='[pg.yaml]' P_PUSH_MODE=direct P_PATCH_FILES="{\"pg.yaml\": \"${PG_OK}\"}"
invalid "patch 1a: a Postgres manifest passed as postgresValuesPatchFilePath is refused" \
  "postgresValuesPatchFilePath: pg.yaml: is a Kubernetes manifest (kind: Postgres), not chart values" "pass it as postgresPatchFilePath"
vp patch P_CLUSTERS='[aks-tpg-poc-01]' P_INSTANCES='[orders-db]' P_POSTGRES_PATCH='[v.yaml]' P_PUSH_MODE=direct P_PATCH_FILES="{\"v.yaml\": \"${VAL_OK}\"}"
invalid "patch 1a: chart values passed as postgresPatchFilePath are refused" "holds chart values (backup), not a Postgres manifest: pass it as postgresValuesPatchFilePath"
vp patch P_CLUSTERS='[aks-tpg-poc-01]' P_INSTANCES='[orders-db]' P_VALUES_PATCH='[v.yaml]' P_PUSH_MODE=direct \
  P_PATCH_FILES="{\"v.yaml\": \"$(b64 $'instance:\n  storageSze: 30Gi\n')\"}"
invalid "patch 1a: an unknown chart value is named with the closest key" "instance.storageSze is not a value of the tpg-instance chart (did you mean storageSize?)"
vp patch P_CLUSTERS='[aks-tpg-poc-01]' P_INSTANCES='[orders-db]' P_POSTGRES_PATCH='[p.yaml]' P_PUSH_MODE=direct \
  P_PATCH_FILES="{\"p.yaml\": \"$(b64 $'apiVersion: sql.tanzu.vmware.com/v1\nkind: Postgres\nspec:\n  logLevl: Debug\n')\"}"
invalid "patch 1a: a field the Postgres CRD does not have is refused" "spec.logLevl is not a field of the Postgres resource (did you mean logLevel?)"
vp patch P_CLUSTERS='[aks-tpg-poc-01]' P_POSTGRES_PATCH= P_OPERATOR_VALUES_PATCH='[o.yaml]' P_PUSH_MODE=direct \
  P_PATCH_FILES="{\"o.yaml\": \"$(b64 $'operatorImage: reg.example.com/postgres-operator:v4.5.0\nnodeSelector: {pool: system}\nresources: {limits: {gpu: 1}}\n')\"}"
invalid "patch 1b: operator keys outside the allow-list are refused" "nodeSelector cannot be patched" "resources.limits.gpu cannot be set (only cpu and memory)"
vp patch P_CLUSTERS='[aks-tpg-poc-01]' P_OPERATOR_VALUES_PATCH='[o.yaml]' P_PUSH_MODE=direct \
  P_PATCH_FILES="{\"o.yaml\": \"$(b64 $'apiVersion: apps/v1\nkind: Deployment\nmetadata: {name: postgres-operator}\n')\"}"
invalid "patch 1b: a manifest as operator values is refused" "operatorValuesPatchFilePath: o.yaml: is a Kubernetes manifest, not operator chart values"
vp patch P_CLUSTERS='[aks-tpg-poc-01]' P_OPERATOR_VALUES_PATCH='[o.yaml]' P_PUSH_MODE=direct \
  P_PATCH_FILES="{\"o.yaml\": \"${OP_OK}\", \"extra.yaml\": \"${VAL_OK}\"}"
invalid "patch: patchFiles may carry only the named files" "patchFiles carries extra.yaml, which no path input or clusterMap key names"
vp patch P_CLUSTERS='[aks-tpg-poc-01]' P_INSTANCES='[orders-db]' P_CLEAR_KINDS='[PostgresBackupSchedule, postgresValues]' P_PATCH_MODE=clear P_PUSH_MODE=direct
valid "patch 1c: patchMode=clear takes clearKinds and no files"
vp patch P_CLUSTERS='[aks-tpg-poc-01]' P_INSTANCES='[orders-db]' P_VALUES_PATCH='[v.yaml]' P_PATCH_MODE=clear P_PUSH_MODE=direct
invalid "patch 1c: patchMode=clear with a path is refused" "patchMode=clear takes no path or CA bundle inputs" "clearKinds is mandatory"
vp patch P_CLUSTERS='[aks-tpg-poc-01]' P_INSTANCES='[orders-db]' P_CLEAR_KINDS='[all, Postgres]' P_PATCH_MODE=clear P_PUSH_MODE=direct
invalid "patch 1c: clearKinds all stands alone" "clearKinds: all stands alone"
vp patch P_CLUSTERS='[aks-tpg-poc-01]' P_INSTANCES='[orders-db]' P_CLEAR_KINDS='[Postgress]' P_PATCH_MODE=clear P_PUSH_MODE=direct
invalid "patch 1c: an unknown kind in clearKinds is refused" "clearKinds: 'Postgress' must be one of"
vp patch P_CLUSTER_MAP='aks-tpg-poc-01: {clearKinds: [operatorValues], instances: {orders-db: {clearKinds: [Postgres]}}}' P_PATCH_MODE=clear P_PUSH_MODE=direct
valid "patch 1c: clearKinds at cluster and instance level of the clusterMap"
vp patch P_CLUSTERS='[aks-tpg-poc-01]' P_INSTANCES='[orders-db]' P_CLEAR_KINDS='[Postgres]' P_POSTGRES_PATCH='[pg.yaml]' P_PUSH_MODE=direct P_PATCH_FILES="{\"pg.yaml\": \"${PG_OK}\"}"
invalid "patch 1c: clearKinds with patchMode=apply is refused" "clearKinds applies to patchMode=clear only"
vp patch P_CLUSTERS='[aks-tpg-poc-01]' P_INSTANCES='[orders-db]' P_VALUES_PATCH='[v.yaml]' P_PATCH_MODE=append P_PUSH_MODE=direct P_PATCH_FILES="{\"v.yaml\": \"${VAL_OK}\"}"
invalid "patch: the Round 11 patchMode values are refused" "patchMode must be one of: apply clear (got 'append')"
vp patch P_CLUSTERS='[aks-tpg-poc-01]' P_INSTANCES='[orders-db]' P_VALUES_PATCH='[v.yaml]' P_PUSH_MODE=direct P_PATCH_FILES="{\"v.yaml\": \"$(b64 $'backup: [x\n')\"}"
invalid "patch: a file that is not YAML is refused" "v.yaml: not valid YAML"

# ---- tpg-upgrade
vp upgrade P_CLUSTER_MAP='aks-tpg-poc-01: {operatorVersion: v4.5.1, instances: {orders-db: {postgresVersion: "17.7", allowMajor: true}}}' P_PUSH_MODE=direct
valid "upgrade: operator and Postgres in one clusterMap is valid"
[[ "$(cat /tmp/approval)" == "true" ]] && ok "upgrade: allowMajor in the map asks for batch approval" || bad "upgrade approval $(cat /tmp/approval)"
vp upgrade P_CLUSTER_MAP='aks-tpg-poc-01: {instances: {orders-db: {}}}' P_PUSH_MODE=direct
invalid "upgrade: a map without versions is refused" "nothing to upgrade"
vp upgrade P_CLUSTER_MAP='aks-tpg-poc-01: {instances: {orders-db: {}}}' P_COMPONENT=postgres P_TARGET_VERSION=17.7 P_PUSH_MODE=direct
valid "upgrade: component=postgres with targetVersion as the default of every instance"
vp upgrade P_CLUSTER_MAP='aks-tpg-poc-01: {operatorVersion: v4.5.1}' P_TARGET_VERSION=4.5.1 P_PUSH_MODE=direct
invalid "upgrade: targetVersion without component is refused with clusterMap" "targetVersion needs component=operator or component=postgres with clusterMap"

# ---- Round 12: exposure and network policy values (list, map and CIDR types, null)
D0='P_CLUSTERS=[aks-tpg-poc-01] P_INSTANCES=[orders-db] P_HA=true P_OPERATOR_VERSION=v4.5.0 P_POSTGRES_VERSION=17.6 P_PUSH_MODE=direct'
# shellcheck disable=SC2086
vp day0 $D0 P_EXPOSURE=internalLoadBalancer P_INTERNAL_LB_SUBNET=apps-subnet P_ALLOWED_SOURCE_RANGES='[10.0.0.0/8, 192.168.10.0/24]' \
  P_SERVICE_ANNOTATIONS='service.beta.kubernetes.io/azure-dns-label-name: orders' P_NETWORK_POLICY=baseline \
  P_INGRESS_FROM_NAMESPACES='[app, batch]' P_INGRESS_FROM_POD_LABELS='{"role":"api"}' P_EGRESS_TO_FQDNS='[api.example.com, *.example.org]'
valid "day0 inputs: exposure, subnet, CIDRs, a YAML annotation map, baseline policy with rules"
# shellcheck disable=SC2086
vp day0 $D0 P_EXPOSURE=nodePort P_ALLOWED_SOURCE_RANGES='[10.0.0.1/8]' P_EGRESS_TO_FQDNS='[http://x]' P_NETWORK_POLICY=baseline
invalid "day0 inputs: unknown exposure, CIDR with host bits, URL as a host name" "exposure" "'10.0.0.1/8' must be a CIDR such as 10.20.0.0/16 (host bits zero)" "'http://x' must be a host name"
# shellcheck disable=SC2086
vp day0 $D0 P_EXPOSURE=internalLoadBalancer P_INTERNAL_LB_SUBNET=AKS-Apps_Subnet.01
valid "day0 inputs: an Azure subnet name with uppercase, '_' and '.'"
# shellcheck disable=SC2086
vp day0 $D0 P_EXPOSURE=internalLoadBalancer P_INTERNAL_LB_SUBNET='apps/subnet'
invalid "day0 inputs: a subnet name with '/' is refused" "must be an Azure subnet name"
vp day0 P_CLUSTER_MAP='aks-tpg-poc-01: {operatorVersion: v4.5.0, instances: {orders-db: {postgresVersion: "17.6", highAvailability: true, exposure: internalLoadBalancer, internalLoadBalancerSubnet: AKS_Apps}}}' P_PUSH_MODE=direct
valid "day0 clusterMap: internalLoadBalancerSubnet takes an Azure name"
vp day0 P_CLUSTER_MAP='aks-tpg-poc-01: {operatorVersion: v4.5.0, instances: {orders-db: {postgresVersion: "17.6", highAvailability: true, internalLoadBalancerSubnet: -apps}}}' P_PUSH_MODE=direct
invalid "day0 clusterMap: an Azure name must start with a letter or digit" "must be an Azure resource name"
# shellcheck disable=SC2086
vp day0 $D0 P_INGRESS_FROM_NAMESPACES='[app]'
invalid "day0 inputs: a rule without networkPolicy=baseline" "the ingressFrom*/egressTo* rules need networkPolicy=baseline"
# shellcheck disable=SC2086
vp day0 $D0 P_SERVICE_ANNOTATIONS='just words'
invalid "day0 inputs: an annotation input that is not a map" "serviceAnnotations must be a map (YAML or JSON)"
vp day0 P_CLUSTER_MAP='aks-tpg-poc-01:
  operatorVersion: v4.5.0
  instances:
    orders-db: {postgresVersion: "17.6", highAvailability: true, exposure: loadBalancer, allowedSourceRanges: [203.0.113.0/24],
                networkPolicy: baseline, ingressFromCidrs: [203.0.113.0/24], ingressFromPodLabels: {app.kubernetes.io/name: api}}' P_PUSH_MODE=direct
valid "day0 clusterMap: exposure and policy keys as YAML lists and maps"
vp day0 P_CLUSTER_MAP='aks-tpg-poc-01:
  operatorVersion: v4.5.0
  instances:
    orders-db: {postgresVersion: "17.6", highAvailability: null, ingressFromNamespaces: [], serviceAnnotations: {}}' P_PUSH_MODE=direct
invalid "day0 clusterMap: null and empty lists or maps are refused with the fix named" \
  "highAvailability: null is not a value; remove the key to use the default" \
  "ingressFromNamespaces: the list is empty; name at least one value, for example [a, b]" \
  "serviceAnnotations: a non-empty mapping is expected"
vp day0 P_CLUSTER_MAP='aks-tpg-poc-01: {operatorVersion: v4.5.0, instances: {orders-db: {postgresVersion: "17.6", highAvailability: true, ingressFromNamespaces: [App_1]}}}' P_PUSH_MODE=direct
invalid "day0 clusterMap: a namespace that is not a DNS label" "'App_1' must be a lowercase DNS label"

# ---- Round 13: HA and readReplicas, operator backup schedules, FerretDB (D69 to D71)
# Round 13 addendum: the two depend on each other, checked where they are set
# shellcheck disable=SC2086
vp day0 P_CLUSTERS='[aks-tpg-poc-01]' P_INSTANCES='[orders-db]' P_HA=false P_READ_REPLICAS=2 P_OPERATOR_VERSION=v4.5.0 P_POSTGRES_VERSION=17.6 P_PUSH_MODE=direct
invalid "day0 inputs: readReplicas 2 with highAvailability=false is refused" "inputs: readReplicas 2 needs highAvailability=true"
vp day0 P_CLUSTERS='[aks-tpg-poc-01]' P_INSTANCES='[orders-db]' P_HA=false P_OPERATOR_VERSION=v4.5.0 P_POSTGRES_VERSION=17.6 P_PUSH_MODE=direct
valid "day0 inputs: highAvailability=false without readReplicas is a single node"
vp day0 P_CLUSTERS='[aks-tpg-poc-01]' P_INSTANCES='[orders-db]' P_HA=true P_OPERATOR_VERSION=v4.5.0 P_POSTGRES_VERSION=17.6 P_PUSH_MODE=direct
valid "day0 inputs: highAvailability=true without readReplicas means 1"
vp day0 P_CLUSTER_MAP='aks-tpg-poc-02: {operatorVersion: v4.5.0, instances: {orders-db: {postgresVersion: "16.9", highAvailability: false, readReplicas: 2}}}' P_HA=true P_PUSH_MODE=direct
invalid "day0 clusterMap: an entry with highAvailability false and readReplicas 2 is refused" \
  "clusterMap.aks-tpg-poc-02.instances.orders-db: readReplicas 2 needs highAvailability=true"
vp day0 P_CLUSTER_MAP='aks-tpg-poc-01: {operatorVersion: v4.5.0, instances: {orders-db: {postgresVersion: "17.6"}, audit-db: {postgresVersion: "17.6", highAvailability: false}}}' P_HA=true P_READ_REPLICAS=3 P_PUSH_MODE=direct
valid "day0 clusterMap: the readReplicas input does not apply to an entry that sets highAvailability false"
vp day0 P_CLUSTER_MAP='aks-tpg-poc-01: {operatorVersion: v4.5.0, instances: {orders-db: {postgresVersion: "17.6", readReplicas: 2}}}' P_HA=false P_PUSH_MODE=direct
invalid "day0 clusterMap: an entry readReplicas with the highAvailability=false input is refused" \
  "clusterMap.aks-tpg-poc-01.instances.orders-db: readReplicas 2 needs highAvailability=true"
vp create-instance P_CLUSTERS='[aks-tpg-poc-01]' P_INSTANCES='[docs-db]' P_HA=false P_READ_REPLICAS=1 P_POSTGRES_VERSION=17.6 P_PUSH_MODE=direct
invalid "create-instance inputs: readReplicas 1 with highAvailability=false is refused" "inputs: readReplicas 1 needs highAvailability=true"
# shellcheck disable=SC2086
vp day0 $D0 P_READ_REPLICAS=0
invalid "day0 inputs: highAvailability=true with readReplicas 0 is refused" "inputs: highAvailability=true needs readReplicas 1 or more"
vp day0 P_CLUSTER_MAP='aks-tpg-poc-01: {operatorVersion: v4.5.0, instances: {orders-db: {postgresVersion: "17.6", highAvailability: true, readReplicas: 0}, audit-db: {postgresVersion: "17.6", highAvailability: false, readReplicas: 0}}}' P_PUSH_MODE=direct
invalid "day0 clusterMap: readReplicas 0 with highAvailability true is refused for that instance only" \
  "clusterMap.aks-tpg-poc-01.instances.orders-db: highAvailability=true needs readReplicas 1 or more"
grep -q "audit-db" <<<"$OUT" && bad "day0 clusterMap: a single node (false, 0) is accepted" "$OUT" || ok "day0 clusterMap: a single node (false, 0) is accepted"
# shellcheck disable=SC2086
vp day0 $D0 P_BACKUP_SCHEDULE=operator P_OPERATOR_FULL_SCHEDULE='0 1 * * 0' P_OPERATOR_INCR_SCHEDULE=''
valid "day0 inputs: backupSchedule=operator with a full schedule only"
# shellcheck disable=SC2086
vp day0 $D0 P_BACKUP_SCHEDULE=operator P_OPERATOR_FULL_SCHEDULE='every sunday'
invalid "day0 inputs: a full schedule that is not cron" "operatorFullSchedule must be a cron schedule of 5 fields"
vp day0 P_CLUSTER_MAP='aks-tpg-poc-01: {operatorVersion: v4.5.0, instances: {orders-db: {postgresVersion: "17.6", highAvailability: true, backupSchedule: operator, operatorFullSchedule: "30 2 * * 6", operatorIncrementalSchedule: none}}}' P_PUSH_MODE=direct
valid "day0 clusterMap: operator schedules per instance (incremental none)"
vp day0 P_CLUSTER_MAP='aks-tpg-poc-01: {operatorVersion: v4.5.0, instances: {orders-db: {postgresVersion: "17.6", highAvailability: true, operatorFullSchedule: "0 0 * *"}}}' P_PUSH_MODE=direct
invalid "day0 clusterMap: a cron with 4 fields" "operatorFullSchedule: '0 0 * *' must be a cron schedule of 5 fields"
# shellcheck disable=SC2086
vp day0 $D0 P_FERRET=true P_FERRET_REPLICAS=2 P_FERRET_RO_REPLICAS=1 P_FERRET_EXPOSURE=internalLoadBalancer P_FERRET_SECRET=orders-db-app-user-db-secret
valid "day0 inputs: FerretDB with read-only proxies on an HA instance"
vp day0 P_CLUSTERS='[aks-tpg-poc-01]' P_INSTANCES='[orders-db]' P_HA=false P_OPERATOR_VERSION=v4.5.0 P_POSTGRES_VERSION=17.6 P_PUSH_MODE=direct \
  P_FERRET=true P_FERRET_RO_REPLICAS=1
invalid "day0 inputs: read-only FerretDB proxies on a single node" "ferretReadOnlyReplicas 1 needs highAvailability=true"
# shellcheck disable=SC2086
vp day0 $D0 P_FERRET=yes P_FERRET_REPLICAS=0 P_FERRET_SECRET=Bad_Name
invalid "day0 inputs: FerretDB input types" "ferret must be true or false" "ferretReplicas must be a positive integer" "ferretSecretName 'Bad_Name' must be a Kubernetes object name"
vp day0 P_CLUSTERS='[aks-tpg-poc-01]' P_INSTANCES='[orders-db]' P_HA=false P_OPERATOR_VERSION=v4.5.0 P_POSTGRES_VERSION=17.6 P_PUSH_MODE=direct \
  P_FERRET_RO_REPLICAS=1
invalid "day0 inputs: read-only FerretDB proxies on a single node with ferret empty (same rule as the admission policy)" "ferretReadOnlyReplicas 1 needs highAvailability=true"
vp create-instance P_CLUSTER_MAP='aks-tpg-poc-01: {instances: {docs-db: {postgresVersion: "17.6", highAvailability: false, ferret: true, ferretReadOnlyReplicas: 2}}}' P_PUSH_MODE=direct
invalid "create-instance clusterMap: read-only FerretDB proxies need highAvailability" "clusterMap.aks-tpg-poc-01.instances.docs-db: ferretReadOnlyReplicas 2 needs highAvailability=true"
vp create-instance P_CLUSTER_MAP='aks-tpg-poc-01: {instances: {docs-db: {postgresVersion: "17.6", highAvailability: true, ferret: true, ferretExposure: nodePort}}}' P_PUSH_MODE=direct
invalid "create-instance clusterMap: ferretExposure is an enum" "ferretExposure: 'nodePort' must be one of clusterIP, internalLoadBalancer, loadBalancer"

# ---- tpg-create-instance
vp create-instance P_CLUSTERS='[aks-tpg-poc-01, aks-tpg-poc-02]' P_INSTANCES='[reports-db]' P_HA=false P_POSTGRES_VERSION=17.6 P_PUSH_MODE=direct
valid "create-instance: clusters and instances lists"
vp create-instance P_CLUSTERS='[aks-tpg-poc-01]' P_INSTANCES='[reports-db]' P_PUSH_MODE=direct
invalid "create-instance: highAvailability and postgresVersion are mandatory without clusterMap" "highAvailability" "postgresVersion"
vp create-instance P_CLUSTER_MAP='aks-tpg-poc-01: {instances: {reports-db: {postgresVersion: "17.6", highAvailability: false}}}
aks-tpg-poc-02: {instances: {audit-db: {highAvailability: true, readReplicas: 2}}}' P_POSTGRES_VERSION=16.10 P_PUSH_MODE=pr
valid "create-instance clusterMap: other instances per cluster, the input postgresVersion is the default"
vp create-instance P_CLUSTER_MAP='aks-tpg-poc-01: {operatorVersion: v4.5.0, instances: {reports-db: {postgresVersion: "17.6", highAvailability: false}}}' P_PUSH_MODE=direct
invalid "create-instance clusterMap: operatorVersion is not a key of tpg-create-instance" "operatorVersion"
vp create-instance P_CLUSTERS='[aks-tpg-poc-01]' P_INSTANCES='[reports-db]' P_HA=false P_POSTGRES_VERSION=17.6 P_PUSH_MODE=direct \
  P_POSTGRES_OVERLAY_FILES='[debug.yaml]' P_PATCH_FILES="{\"debug.yaml\": \"$(b64 $'operatorImage: x/y:1\n')\"}"
invalid "create-instance: a file of the wrong kind is refused (1a)" "postgresOverlayFilePath: debug.yaml: holds operator chart values: pass it as operatorValuesOverlayFilePath"

# ---- tpg-network-policy
vp network-policy P_CLUSTERS='[aks-tpg-poc-01]' P_INSTANCES='[orders-db]' P_NP_MODE=apply P_PUSH_MODE=direct P_INGRESS_FROM_NAMESPACES='[app]' P_EGRESS_TO_CIDRS='[10.50.0.0/16]'
valid "network-policy apply: rules as inputs"
vp network-policy P_CLUSTERS='[aks-tpg-poc-01]' P_INSTANCES='[orders-db]' P_PUSH_MODE=direct
invalid "network-policy: mode is mandatory" "mode"
vp network-policy P_CLUSTERS='[aks-tpg-poc-01]' P_INSTANCES='[orders-db]' P_NP_MODE=remove P_PUSH_MODE=direct P_INGRESS_FROM_NAMESPACES='[app]'
invalid "network-policy remove: rule inputs are refused" "mode=remove deletes the whole policy: leave the rule inputs empty"
vp network-policy P_CLUSTER_MAP='aks-tpg-poc-01: {instances: {orders-db: {ingressFromCidrs: [10.1.0.0/16]}}}' P_NP_MODE=remove P_PUSH_MODE=direct
invalid "network-policy remove: clusterMap rules are refused" "clusterMap may name the instances (and postgresVersion guards) but no rules"
vp network-policy P_CLUSTER_MAP='aks-tpg-poc-01: {instances: {orders-db: {networkPolicy: none}}}' P_NP_MODE=update P_PUSH_MODE=direct
invalid "network-policy clusterMap: networkPolicy is a day0 and create-instance key only" "networkPolicy"

# ---- Round 23 phase 2: strict lists. Every list input is bracketed, even with one value; only
# all (and auto for components) stays bare. One parser (clustermap.py as_list) behind lib.sh list_items.
CM="$ROOT/workflows/scripts/clustermap.py"
li() { RC=0; OUT="$(python3 "$CM" list "$@" 2>&1)" || RC=$?; }   # li NAME VALUE [OPTS]: items one per line
li clusters '[aks-tpg-poc-01, aks-tpg-poc-02]'
[[ "$RC" -eq 0 && "$OUT" == $'aks-tpg-poc-01\naks-tpg-poc-02' ]] && ok "list: a YAML flow list gives one item per line" || bad "list flow" "$OUT"
li clusters '["aks-tpg-poc-01","aks-tpg-poc-02"]' --csv
[[ "$RC" -eq 0 && "$OUT" == "aks-tpg-poc-01,aks-tpg-poc-02" ]] && ok "list: the JSON form is the same list (--csv: the internal comma form)" || bad "list json" "$OUT"
li clusters "[ 'aks-tpg-poc-01' , \"aks-tpg-poc-02\" ]" --json
[[ "$RC" -eq 0 && "$OUT" == '["aks-tpg-poc-01","aks-tpg-poc-02"]' ]] && ok "list: quotes and spaces inside the brackets are accepted (--json)" || bad "list quotes" "$OUT"
li clusters '[aks-tpg-poc-01]'
[[ "$RC" -eq 0 && "$OUT" == "aks-tpg-poc-01" ]] && ok "list: a list of one value" || bad "list one" "$OUT"
li clusters 'aks-tpg-poc-01,aks-tpg-poc-02'
[[ "$RC" -eq 1 && "$OUT" == *"clusters: 'aks-tpg-poc-01,aks-tpg-poc-02' is not a list"* && "$OUT" == *"[a] or [a, b]"* && "$OUT" == *"Did you mean [aks-tpg-poc-01, aks-tpg-poc-02]?"* ]] \
  && ok "list: a comma-separated string is refused with the list syntax and the bracketed form" || bad "list comma" "$OUT"
li clusters 'aks-tpg-poc-01'
[[ "$RC" -eq 1 && "$OUT" == *"Did you mean [aks-tpg-poc-01]?"* ]] && ok "list: one bare name where a list is required is refused" || bad "list bare one" "$OUT"
li clusters '[a, , b]'
[[ "$RC" -eq 1 && "$OUT" == *"clusters: the list has an empty element"* ]] && ok "list: an empty element [a, , b] is refused" || bad "list empty element" "$OUT"
li clusters '[a, b,]'
[[ "$RC" -eq 1 && "$OUT" == *"empty element"* ]] && ok "list: a trailing comma is an empty element" || bad "list trailing comma" "$OUT"
li clusters '[]'
[[ "$RC" -eq 1 && "$OUT" == *"clusters: the list is empty"* && "$OUT" == *"[a, b]"* ]] && ok "list: [] is refused with the list message" || bad "list []" "$OUT"
li clusters '[repo: helm_artifacts/x.yaml]' --files
[[ "$RC" -eq 1 && "$OUT" == 'clusters: repo:<file path> "check for white spaces in between"' ]] && ok "list: [repo: x.yaml] (a mapping in YAML) fails with the whitespace message" || bad "list repo space" "$OUT"
li f '["repo: x.yaml"]' --files
[[ "$RC" -eq 1 && "$OUT" == 'f: repo:<file path> "check for white spaces in between"' ]] && ok "list: a quoted entry with a space fails with the same message" || bad "list repo space quoted" "$OUT"
li f 'repo: x.yaml' --files
[[ "$RC" -eq 1 && "$OUT" == *'repo:<file path> "check for white spaces in between"'* ]] && ok "list: a bare repo: x.yaml fails with the whitespace message too" || bad "list repo space bare" "$OUT"
li f '[./a.yaml, repo:helm_artifacts/x.yaml, ~/b.yml]' --files
[[ "$RC" -eq 0 && "$(wc -l <<<"$OUT")" -eq 3 ]] && ok "list: local paths and repo:<path> entries are items" || bad "list files" "$OUT"
li f 'all' --bare all
[[ "$RC" -eq 0 && "$OUT" == "all" ]] && ok "list: all stays bare where the input takes it" || bad "list all" "$OUT"
li f 'all'
[[ "$RC" -eq 1 && "$OUT" == *"not a list"* ]] && ok "list: all is refused where the input does not take it" || bad "list all refused" "$OUT"
li f '[a.yaml, b.yaml]' --files --one
[[ "$RC" -eq 1 && "$OUT" == *"exactly one file is expected, in brackets: [path]"* ]] && ok "list: a single-file input with two files is refused" || bad "list one file" "$OUT"
li f '   '
[[ "$RC" -eq 0 && -z "$OUT" ]] && ok "list: an empty value is an unset input (no items, no error)" || bad "list empty value" "$OUT"
li f '[a, "b]'
[[ "$RC" -eq 1 && "$OUT" == *"unterminated quote"* ]] && ok "list: an unterminated quote is refused" || bad "list quote" "$OUT"

# validate-params.sh: the inputs
BASE_D0='P_HA=true P_OPERATOR_VERSION=v4.5.0 P_POSTGRES_VERSION=17.6 P_PUSH_MODE=direct'
# shellcheck disable=SC2086  # BASE_D0 is a list of assignments
vp day0 P_CLUSTERS=all P_INSTANCES='orders-db,billing-db' $BASE_D0
invalid "R23 day0: instances=orders-db,billing-db (a comma string) is refused with the list syntax" \
  "instances: 'orders-db,billing-db' is not a list" "Did you mean [orders-db, billing-db]?"
# shellcheck disable=SC2086
vp day0 P_CLUSTERS=all P_INSTANCES=orders-db $BASE_D0
invalid "R23 day0: one bare instance where a list is required is refused" "instances: 'orders-db' is not a list" "Did you mean [orders-db]?"
# shellcheck disable=SC2086
vp day0 P_CLUSTERS='[aks-tpg-poc-01]' P_INSTANCES='[orders-db]' $BASE_D0
valid "R23 day0: a list of one cluster and a list of one instance are valid"
[[ "$(cat /tmp/selection)" == "aks-tpg-poc-01" ]] && ok "R23 day0: the selection is the internal comma form" || bad "R23 selection" "$(cat /tmp/selection)"
# shellcheck disable=SC2086
vp day0 P_CLUSTERS='["aks-tpg-poc-01","aks-tpg-poc-02"]' P_INSTANCES='["orders-db"]' $BASE_D0
valid "R23 day0: the JSON form is valid"
[[ "$(cat /tmp/selection)" == "aks-tpg-poc-01,aks-tpg-poc-02" ]] && ok "R23 day0: the JSON list selects both clusters" || bad "R23 selection json" "$(cat /tmp/selection)"
# shellcheck disable=SC2086
vp day0 P_CLUSTERS='[aks-tpg-poc-01, aks-tpg-poc-02]' P_INSTANCES='[orders-db, , billing-db]' $BASE_D0
invalid "R23 day0: an empty element [a, , b] is refused" "instances: the list has an empty element"
# shellcheck disable=SC2086
vp day0 P_CLUSTERS='[]' P_INSTANCES='[orders-db]' $BASE_D0
invalid "R23 day0: clusters=[] is refused with the list message" "clusters: the list is empty"
# shellcheck disable=SC2086
vp day0 P_CLUSTERS='[all]' P_INSTANCES='[orders-db]' $BASE_D0
invalid "R23 day0: [all] is refused (all stays bare)" "clusters: all stands alone, without brackets"
# shellcheck disable=SC2086
vp day0 P_CLUSTERS='aks-tpg-poc-01,aks-tpg-poc-02' P_INSTANCES='[orders-db]' $BASE_D0
invalid "R23 day0: clusters as a comma string is refused" "clusters: 'aks-tpg-poc-01,aks-tpg-poc-02' is not a list" "Did you mean [aks-tpg-poc-01, aks-tpg-poc-02]?"
# shellcheck disable=SC2086
vp day0 P_CLUSTERS='[aks-tpg-poc-09]' P_INSTANCES='[orders-db]' $BASE_D0
invalid "R23 day0: an unregistered cluster in a list is named" "cluster 'aks-tpg-poc-09' is not registered"
# shellcheck disable=SC2086
vp day0 P_CLUSTERS=all P_INSTANCES='[orders-db]' P_INGRESS_FROM_NAMESPACES='app,batch' P_NETWORK_POLICY=baseline $BASE_D0
invalid "R23 day0: ingressFromNamespaces as a comma string is refused" "ingressFromNamespaces: 'app,batch' is not a list" "Did you mean [app, batch]?"
# shellcheck disable=SC2086
vp day0 P_CLUSTERS=all P_INSTANCES='[orders-db]' P_ALLOWED_SOURCE_RANGES='10.0.0.0/8' P_EXPOSURE=internalLoadBalancer $BASE_D0
invalid "R23 day0: one bare CIDR where a list is required is refused" "allowedSourceRanges: '10.0.0.0/8' is not a list" "Did you mean [10.0.0.0/8]?"
# shellcheck disable=SC2086
vp day0 P_CLUSTERS=all P_INSTANCES='[orders-db]' P_EGRESS_TO_FQDNS='[api.example.com, *.example.org]' P_NETWORK_POLICY=baseline $BASE_D0
valid "R23 day0: egressToFqdns as a bracketed list is valid"
# shellcheck disable=SC2086
vp day0 P_CLUSTERS=all P_INSTANCES='[orders-db]' P_EGRESS_TO_CIDRS='[]' P_NETWORK_POLICY=baseline $BASE_D0
invalid "R23 day0: egressToCidrs=[] is refused" "egressToCidrs: the list is empty"
# files
# shellcheck disable=SC2086
vp day0 P_CLUSTERS=all P_INSTANCES='[orders-db]' P_POSTGRES_OVERLAY_FILES='[repo: helm_artifacts/instance/tpg-instance/overlays/x.yaml]' $BASE_D0
invalid "R23 day0: [repo: x.yaml] (a space after the colon) fails with the whitespace message" \
  'postgresOverlayFilePath: repo:<file path> "check for white spaces in between"'
# shellcheck disable=SC2086
vp day0 P_CLUSTERS=all P_INSTANCES='[orders-db]' P_VALUES_OVERLAY_FILES='repo: helm_artifacts/instance/tpg-instance/overlays/x.yaml' $BASE_D0
invalid "R23 day0: a single-file input with repo: and a space fails with the same message" \
  'postgresValuesOverlayFilePath: repo:<file path> "check for white spaces in between"'
# shellcheck disable=SC2086
vp day0 P_CLUSTERS=all P_INSTANCES='[orders-db]' P_VALUES_OVERLAY_FILES='[a.yaml, b.yaml]' $BASE_D0
invalid "R23 day0: a single-file input holds exactly one file" "postgresValuesOverlayFilePath: exactly one file is expected, in brackets: [path]"
# shellcheck disable=SC2086
vp day0 P_CLUSTERS=all P_INSTANCES='[orders-db]' P_VALUES_OVERLAY_FILES='repo:helm_artifacts/instance/tpg-instance/overlays/x.yaml' $BASE_D0
invalid "R23 day0: a single file without brackets is not a list" "postgresValuesOverlayFilePath: 'repo:helm_artifacts/instance/tpg-instance/overlays/x.yaml' is not a list"
vp patch P_CLUSTERS=all P_OPERATOR_VALUES_PATCH='[repo:helm_artifacts/operator/patches/team.yaml]' P_PUSH_MODE=direct
valid "R23 patch: a single-file input in brackets, [repo:<path>], is valid"
vp patch P_CLUSTERS='[aks-tpg-poc-01]' P_INSTANCES='[orders-db]' P_POSTGRES_PATCH='a.yaml,b.yaml' P_PUSH_MODE=direct
invalid "R23 patch: postgresPatchFilePath as a comma string is refused" "postgresPatchFilePath: 'a.yaml,b.yaml' is not a list" "Did you mean [a.yaml, b.yaml]?"
vp patch P_CLUSTERS='[aks-tpg-poc-01]' P_INSTANCES='[orders-db]' P_CLEAR_KINDS='Postgres,postgresValues' P_PATCH_MODE=clear P_PUSH_MODE=direct
invalid "R23 patch: clearKinds as a comma string is refused" "clearKinds: 'Postgres,postgresValues' is not a list" "Did you mean [Postgres, postgresValues]?"
vp patch P_CLUSTERS='[aks-tpg-poc-01]' P_INSTANCES='[orders-db]' P_CLEAR_KINDS='all' P_PATCH_MODE=clear P_PUSH_MODE=direct
valid "R23 patch: clearKinds=all stays bare"
vp patch P_CLUSTERS='[aks-tpg-poc-01]' P_INSTANCES='[orders-db]' P_CLEAR_KINDS='[Postgres, postgresValues]' P_PATCH_MODE=clear P_PUSH_MODE=direct
valid "R23 patch: clearKinds as a bracketed list is valid"
vp patch P_CLUSTERS=all P_INSTANCES=all P_CLEAR_KINDS='[]' P_PATCH_MODE=clear P_PUSH_MODE=direct
invalid "R23 patch: clearKinds=[] is refused" "clearKinds: the list is empty"
# confirm, apps, components, rotate
vp delete-instance P_CLUSTERS='[aks-tpg-poc-01]' P_INSTANCES='[orders-db]' P_CONFIRM='orders-db'
invalid "R23 delete-instance: confirm as a bare name is refused" "confirm: 'orders-db' is not a list" "Did you mean [orders-db]?"
vp delete-instance P_CLUSTERS='[aks-tpg-poc-01]' P_INSTANCES='[orders-db]' P_CONFIRM='[orders-db]'
valid "R23 delete-instance: confirm as a list of one repeats the instances"
vp delete-instance P_CLUSTER_MAP='aks-tpg-poc-01: {instances: {orders-db: {}}}' P_CONFIRM='aks-tpg-poc-01'
invalid "R23 delete-instance (clusterMap): confirm as a bare name is refused" "confirm: 'aks-tpg-poc-01' is not a list"
vp delete-instance P_CLUSTER_MAP='aks-tpg-poc-01: {instances: {orders-db: {}}}' P_CONFIRM='[aks-tpg-poc-02]'
invalid "R23 delete-instance (clusterMap): a confirm that differs names the expected list" "confirm must repeat the cluster names of clusterMap ([aks-tpg-poc-01])"
APPS_BASE="P_CLUSTERS=[aks-tpg-poc-01] P_CONFIRM=[aks-tpg-poc-01] P_DRY_RUN=true P_PURGE_PVCS=false P_PURGE_NS=false P_PUSH_MODE=direct"
# shellcheck disable=SC2086
vp delete-apps $APPS_BASE P_APPS='{"aks-tpg-poc-01":["tpg-instances:orders-db","tpg-instances:billing-db","tpg-operator"]}'
valid "R23 delete-apps: each instance is its own element, tpg-instances:orders-db"
# shellcheck disable=SC2086
vp delete-apps $APPS_BASE P_APPS='{"aks-tpg-poc-01":["tpg-instances:orders-db,billing-db"]}'
invalid "R23 delete-apps: tpg-instances:orders-db,billing-db (two instances in one element) is refused" \
  "names several instances in one element" '"tpg-instances:orders-db", "tpg-instances:billing-db"'
# shellcheck disable=SC2086
vp delete-apps P_CLUSTERS='aks-tpg-poc-01' P_CONFIRM='[aks-tpg-poc-01]' P_DRY_RUN=true P_PURGE_PVCS=false P_PURGE_NS=false P_PUSH_MODE=direct P_APPS='{"aks-tpg-poc-01":["tpg-operator"]}'
invalid "R23 delete-apps: clusters as a bare name is refused" "clusters: 'aks-tpg-poc-01' is not a list"
vp helm-addons P_CLUSTERS='[aks-tpg-poc-01]' P_COMPONENTS='cert-manager,vso'
invalid "R23 helm-addons: components as a comma string is refused" "components: 'cert-manager,vso' is not a list" "Did you mean [cert-manager, vso]?"
vp helm-addons P_CLUSTERS='[aks-tpg-poc-01]' P_COMPONENTS='[cert-manager, vso]'
valid "R23 helm-addons: components as a bracketed list is valid"
vp helm-addons P_CLUSTERS='[aks-tpg-poc-01]' P_COMPONENTS='auto'
valid "R23 helm-addons: components=auto stays bare"
vp helm-addons P_CLUSTERS='[aks-tpg-poc-01]' P_COMPONENTS='[auto]'
invalid "R23 helm-addons: [auto] is refused (auto stays bare)" "components: auto stands alone, without brackets"
vp helm-addons P_CLUSTERS='[aks-tpg-poc-01]' P_COMPONENTS='[monitoring, grafana]'
invalid "R23 helm-addons: an unknown component in the list is named" "components must be one of: cert-manager vso monitoring (got 'grafana')"
vp helm-addons P_CLUSTERS=all
valid "R23 helm-addons: clusters=all stays bare"
vp helm-addons P_CLUSTERS=aks-tpg-poc-01
invalid "R23 helm-addons: clusters as one bare name is refused" "clusters: 'aks-tpg-poc-01' is not a list"
vp backup P_CLUSTERS=all
valid "R23 backup: clusters=all stays bare"
vp backup P_CLUSTERS='[aks-tpg-poc-01, aks-tpg-poc-02]' P_INSTANCES='[orders-db]'
valid "R23 backup: lists of clusters and instances"
vp backup P_CLUSTERS='aks-tpg-poc-01,aks-tpg-poc-02'
invalid "R23 backup: a comma string for clusters is refused" "clusters: 'aks-tpg-poc-01,aks-tpg-poc-02' is not a list"
# the single-file CA input of tpg-rotate-credential
vp rotate P_SECRET_TYPE=ca-bundle P_SECRET_NAME=storage-ca P_CA_FILE='./ca.pem' P_CLUSTERS=all
invalid "R23 rotate: caBundleFile without brackets is refused" "caBundleFile: './ca.pem' is not a list"
vp rotate P_SECRET_TYPE=ca-bundle P_SECRET_NAME=storage-ca P_CA_FILE='[repo: ca-bundles/x.pem]' P_CLUSTERS=all
invalid "R23 rotate: caBundleFile [repo: x.pem] fails with the whitespace message" 'caBundleFile: repo:<file path> "check for white spaces in between"'
vp rotate P_SECRET_TYPE=ca-bundle P_SECRET_NAME=storage-ca P_CLUSTERS=aks-tpg-poc-01
invalid "R23 rotate: clusters as one bare name is refused" "clusters: 'aks-tpg-poc-01' is not a list"
# clusterMap: list keys are sequences; a string is refused with the list message; single files are a one-element sequence
vp day0 P_CLUSTER_MAP='aks-tpg-poc-01: {operatorVersion: v4.5.0, instances: {orders-db: {postgresVersion: "17.6", highAvailability: true, ingressFromNamespaces: "app,batch"}}}' P_PUSH_MODE=direct
invalid "R23 clusterMap: a comma string for a list key is refused with the list message" \
  "ingressFromNamespaces: 'app,batch' is not a list" "Did you mean [app, batch]?"
vp day0 P_CLUSTER_MAP='aks-tpg-poc-01: {operatorVersion: v4.5.0, instances: {orders-db: {postgresVersion: "17.6", highAvailability: true, ingressFromNamespaces: app}}}' P_PUSH_MODE=direct
invalid "R23 clusterMap: one bare value for a list key is refused" "ingressFromNamespaces: 'app' is not a list" "Did you mean [app]?"
vp day0 P_CLUSTER_MAP='aks-tpg-poc-01: {operatorVersion: v4.5.0, instances: {orders-db: {postgresVersion: "17.6", highAvailability: true, ingressFromNamespaces: "[app]"}}}' P_PUSH_MODE=direct
invalid "R23 clusterMap: a quoted [app] is a string, not a YAML sequence, and is refused" "ingressFromNamespaces: '[app]' is not a list"
vp day0 P_CLUSTER_MAP='aks-tpg-poc-01: {operatorVersion: v4.5.0, instances: {orders-db: {postgresVersion: "17.6", highAvailability: true, ingressFromNamespaces: [app]}}}' P_PUSH_MODE=direct
valid "R23 clusterMap: a list key as a one-element sequence is valid"
vp day0 P_CLUSTER_MAP='{"aks-tpg-poc-01": {"operatorVersion": "v4.5.0", "instances": {"orders-db": {"postgresVersion": "17.6", "highAvailability": true, "egressToFqdns": ["api.example.com"]}}}}' P_PUSH_MODE=direct
valid "R23 clusterMap: the JSON form of a list key is valid"
vp patch P_CLUSTER_MAP='aks-tpg-poc-01: {instances: {orders-db: {postgresPatchFilePath: [repo: helm_artifacts/instance/tpg-instance/patches/x.yaml]}}}' P_PUSH_MODE=direct
invalid "R23 clusterMap: [repo: x.yaml] (YAML reads a mapping) fails with the whitespace message" \
  'postgresPatchFilePath: repo:<file path> "check for white spaces in between"'
vp patch P_CLUSTER_MAP='aks-tpg-poc-01: {instances: {orders-db: {postgresPatchFilePath: a.yaml}}}' P_PUSH_MODE=direct
invalid "R23 clusterMap: a file list key given as a string is refused" "postgresPatchFilePath: 'a.yaml' is not a list"
vp patch P_CLUSTER_MAP='aks-tpg-poc-01: {instances: {orders-db: {postgresValuesPatchFilePath: v.yaml}}}' P_PUSH_MODE=direct
invalid "R23 clusterMap: a single-file key given as a string is refused (brackets, one file)" "postgresValuesPatchFilePath: 'v.yaml' is not a list"
vp patch P_CLUSTER_MAP='aks-tpg-poc-01: {instances: {orders-db: {postgresValuesPatchFilePath: [a.yaml, b.yaml]}}}' P_PUSH_MODE=direct
invalid "R23 clusterMap: a single-file key holds exactly one file" "postgresValuesPatchFilePath: exactly one file is expected, in brackets: [path]"
vp patch P_CLUSTER_MAP='aks-tpg-poc-01: {instances: {orders-db: {postgresPatchFilePath: []}}}' P_PUSH_MODE=direct
invalid "R23 clusterMap: [] for a list key is refused with the list message" "postgresPatchFilePath: the list is empty"
vp patch P_CLUSTER_MAP='aks-tpg-poc-01: {instances: {orders-db: {postgresPatchFilePath: ["a.yaml", ""]}}}' P_PUSH_MODE=direct
invalid "R23 clusterMap: an empty element in a sequence is refused" "postgresPatchFilePath: the list has an empty element"
vp patch P_CLUSTER_MAP='aks-tpg-poc-01: {clearKinds: "Postgres,postgresValues", instances: {orders-db: {}}}' P_PATCH_MODE=clear P_PUSH_MODE=direct
invalid "R23 clusterMap: clearKinds as a comma string is refused" "clearKinds: 'Postgres,postgresValues' is not a list" "Did you mean [Postgres, postgresValues]?"
vp patch P_CLUSTER_MAP='aks-tpg-poc-01: {clearKinds: all, instances: {orders-db: {}}}' P_PATCH_MODE=clear P_PUSH_MODE=direct
valid "R23 clusterMap: clearKinds: all stays bare"

# ---- Round 23 phase 2 review: the rotate selection, hasWrite, [all], messages, literal matching
# rotate: the validate step writes /tmp/selection (the internal comma form) and the discover step
# reads that, never the bracketed input; an input [c1] handed to discover is NOT_REGISTERED
cat > "$TMP/prelude-disc.sh" <<PRELUDE
export TPG_WORK="$TMP/discwork"
source "$ROOT/workflows/scripts/lib.sh"
set +e
git_clone() { rm -rf "\$1"; cp -r "$TMP/scalerepo" "\$1"; }
record() { printf '%s|%s|%s|%s\n' "\$1" "\$2" "\${3:-}" "\${4:-}" >> "$TMP/disc-records"; }
record_entry() { record "\$@"; }
run_records() { echo '{}'; }
registered_clusters() { printf 'aks-tpg-poc-01\naks-tpg-poc-02\naks-tpg-poc-03\n'; }
registered_wave() { echo 0; }
kubectl() { :; }
PRELUDE
sed "s#source /scripts/lib.sh#source $TMP/prelude-disc.sh#" "$ROOT/workflows/scripts/discover.sh" > "$TMP/discover-rot.sh"
disc() {  # disc SELECTION: the discover step of a rotate run; the inventory names in $INV, the records in $DREC
  rm -rf "$TMP/discwork"; : > "$TMP/disc-records"; rm -f /tmp/inventory.json
  RC=0; OUT="$(bash "$TMP/discover-rot.sh" wf "$1" 2>&1)" || RC=$?
  INV="$(jq -c 'map(.name)' /tmp/inventory.json 2>/dev/null || echo none)"; DREC="$(cat "$TMP/disc-records")"
}
vp rotate P_SECRET_TYPE=broadcom-registry P_CLUSTERS='[aks-tpg-poc-01]'
valid "R23 review rotate: clusters=[aks-tpg-poc-01] is valid"
disc "$(cat /tmp/selection)"
[[ "$RC" -eq 0 && "$INV" == '["aks-tpg-poc-01"]' && "$DREC" != *NOT_REGISTERED* ]] \
  && ok "R23 review rotate: discover with the selection of a validate of clusters=[c1] finds the cluster" || bad "rotate selection to discover" "$(cat /tmp/selection) $INV $DREC $OUT"
disc '[aks-tpg-poc-01]'
[[ "$DREC" == *NOT_REGISTERED* ]] \
  && ok "R23 review rotate: the raw bracketed input is NOT_REGISTERED in discover (why the templates pass the selection)" || bad "raw bracketed input" "$INV $DREC"
vp rotate P_SECRET_TYPE=backup-storage P_CLUSTERS=all
valid "R23 review rotate: clusters=all is valid"
disc "$(cat /tmp/selection)"
[[ "$RC" -eq 0 && "$(jq -r 'length' /tmp/inventory.json)" -ge 1 && "$DREC" != *NOT_REGISTERED* ]] \
  && ok "R23 review rotate: the selection of clusters=all stays all" || bad "rotate all selection" "$(cat /tmp/selection) $INV $DREC"
# hasWrite: the write step runs for a wrappingToken or a caBundleFile, decided by the validate step
vp rotate P_SECRET_TYPE=broadcom-registry P_CLUSTERS=all
valid "R23 review rotate: nothing to write is valid"
[[ "$(cat /tmp/hasWrite)" == false ]] && ok "R23 review rotate: no wrappingToken and no caBundleFile: hasWrite false" || bad "hasWrite false" "$(cat /tmp/hasWrite 2>&1)"
vp rotate P_SECRET_TYPE=broadcom-registry P_CLUSTERS=all S_TOKEN=hvs.0123456789abcdefghij
valid "R23 review rotate: a wrapping token is valid"
[[ "$(cat /tmp/hasWrite)" == true ]] && ok "R23 review rotate: a wrappingToken: hasWrite true" || bad "hasWrite token" "$(cat /tmp/hasWrite 2>&1)"
openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj /CN=ok-ca -keyout "$TMP/rot.key" -out "$TMP/rot.pem" 2>/dev/null
ROT_PF="$(jq -cn --arg b "$(base64 < "$TMP/rot.pem" | tr -d '\n')" '{"./ca.pem": $b}')"
vp rotate P_SECRET_TYPE=ca-bundle P_SECRET_NAME=storage-ca P_CLUSTERS=all P_CA_FILE='[./ca.pem]' P_PATCH_FILES="$ROT_PF"
valid "R23 review rotate: caBundleFile [./ca.pem] with its patchFiles is valid"
[[ "$(cat /tmp/hasWrite)" == true ]] && ok "R23 review rotate: a caBundleFile: hasWrite true" || bad "hasWrite ca" "$(cat /tmp/hasWrite 2>&1)"
vp rotate P_SECRET_TYPE=ca-bundle P_SECRET_NAME=storage-ca P_CLUSTERS=all P_CA_FILE="['./ca.pem']" P_PATCH_FILES="$ROT_PF"
valid "R23 review rotate: a single-quoted element ['./ca.pem'] is valid"
[[ "$(cat /tmp/hasWrite)" == true ]] && ok "R23 review rotate: a quoted caBundleFile element: hasWrite true (no quote reaches a when expression)" || bad "hasWrite quoted ca" "$(cat /tmp/hasWrite 2>&1)"

# [all] is refused for clearKinds too (only the bare all)
vp patch P_CLUSTERS='[aks-tpg-poc-01]' P_INSTANCES='[orders-db]' P_CLEAR_KINDS='[all]' P_PATCH_MODE=clear P_PUSH_MODE=direct
invalid "R23 review patch: clearKinds=[all] is refused" "clearKinds: all stands alone, without brackets: clearKinds=all"
vp patch P_CLUSTER_MAP='aks-tpg-poc-01: {clearKinds: [all], instances: {orders-db: {}}}' P_PATCH_MODE=clear P_PUSH_MODE=direct
invalid "R23 review clusterMap: clearKinds: [all] is refused (the bare scalar all stays)" "clearKinds: all stands alone, without brackets"
vp patch P_CLUSTER_MAP='aks-tpg-poc-01: {instances: {orders-db: {clearKinds: [all]}}}' P_PATCH_MODE=clear P_PUSH_MODE=direct
invalid "R23 review clusterMap: an instance clearKinds: [all] is refused" "clearKinds: all stands alone, without brackets"

# messages that do not send the user in a circle
vp day0 P_CLUSTERS=all P_INSTANCES=all P_HA=true P_OPERATOR_VERSION=v4.5.0 P_POSTGRES_VERSION=17.6 P_PUSH_MODE=direct
invalid "R23 review day0: instances=all says the workflow does not take all" "instances does not accept all"
[[ "$OUT" != *"Did you mean [all]"* ]] && ok "R23 review day0: instances=all does not suggest [all]" || bad "instances=all suggests [all]" "$OUT"
vp day0 P_CLUSTERS=all P_INSTANCES='[all]' P_HA=true P_OPERATOR_VERSION=v4.5.0 P_POSTGRES_VERSION=17.6 P_PUSH_MODE=direct
invalid "R23 review day0: instances=[all] says the workflow does not take all" "instances does not accept all"
[[ "$OUT" != *"instances=all"* ]] && ok "R23 review day0: instances=[all] does not suggest instances=all" || bad "[all] suggests instances=all" "$OUT"
vp delete-instance P_CLUSTERS='[all]' P_INSTANCES='[orders-db]' P_CONFIRM='[orders-db]'
invalid "R23 review delete-instance: clusters=[all] says the workflow does not take all" "clusters does not accept all"
[[ "$OUT" != *"clusters=all"* ]] && ok "R23 review delete-instance: clusters=[all] does not suggest clusters=all" || bad "clusters [all] suggests clusters=all" "$OUT"
vp delete-instance P_CLUSTERS=all P_INSTANCES='[orders-db]' P_CONFIRM='[orders-db]'
invalid "R23 review delete-instance: clusters=all says the workflow does not take all" "clusters does not accept all"
vp create-instance P_CLUSTERS='[all]' P_INSTANCES='[new-db]' P_PUSH_MODE=direct
invalid "R23 review create-instance: clusters=[all] says the workflow does not take all" "clusters does not accept all"
li f 'all'
[[ "$RC" -eq 1 && "$OUT" != *"Did you mean [all]"* && "$OUT" == *"does not take all"* ]] \
  && ok "R23 review list: all where it is not taken has no Did-you-mean [all]" || bad "list all message" "$OUT"

# a cluster name is a literal, never a regular expression
vp rotate P_SECRET_TYPE=broadcom-registry P_CLUSTERS='[".*"]'
invalid "R23 review rotate: clusters=[\".*\"] is not registered (no regex match)" "cluster '.*' is not registered"
vp day0 P_CLUSTERS='[aks-tpg-poc-0.]' P_INSTANCES='[orders-db]' P_HA=true P_OPERATOR_VERSION=v4.5.0 P_POSTGRES_VERSION=17.6 P_PUSH_MODE=direct
invalid "R23 review day0: a pattern in a cluster list is not registered" "cluster 'aks-tpg-poc-0.' is not registered"
disc '.*'
[[ "$DREC" == *"result..*|FAILED|NOT_REGISTERED"* ]] \
  && ok "R23 review discover: a selection of .* is NOT_REGISTERED (literal membership)" || bad "discover regex" "$INV $DREC $OUT"

# the list text: nested lists and line breaks inside an element
li clusters '[a, [b]]'
[[ "$RC" -eq 1 && "$OUT" == *"clusters: a list entry must be a plain value, not a nested list"* ]] && ok "list: a nested list [a, [b]] is refused" || bad "list nested" "$OUT"
li clusters '[[b, c]]'
[[ "$RC" -eq 1 && "$OUT" == *"not a nested list"* ]] && ok "list: [[b, c]] is refused as a nested list" || bad "list nested 2" "$OUT"
li clusters '[["b"], "c"]'
[[ "$RC" -eq 1 && "$OUT" == *"not a nested list"* ]] && ok "list: a nested JSON list is refused" || bad "list nested json" "$OUT"
li clusters $'[a\nb, c]'
[[ "$RC" -eq 1 && "$OUT" == *"clusters: a list entry holds a line break"* ]] && ok "list: a line break inside an element is refused" || bad "list newline" "$OUT"
li clusters $'["a\\nb","c"]'
[[ "$RC" -eq 1 && "$OUT" == *"clusters: a list entry holds a line break"* ]] && ok "list: a line break inside a quoted JSON element is refused" || bad "list newline json" "$OUT"
li clusters $'[a,\n b]'
[[ "$RC" -eq 0 && "$OUT" == $'a\nb' ]] && ok "list: a line break between elements is only white space" || bad "list newline between" "$OUT"

# ---- lib accessors
cat > "$TMP/acc.sh" <<ACC
export TPG_WORK="$TMP/acc"
source "$ROOT/workflows/scripts/lib.sh"
set +e
printf '%s|' "\$(cmap_ival aks-tpg-poc-01 orders-db storageSize 20Gi)" "\$(cmap_ival aks-tpg-poc-01 billing-db storageSize 20Gi)" \
  "\$(cmap_cval aks-tpg-poc-02 operatorVersion v0)" "\$(cmap_instances aks-tpg-poc-01 | paste -sd,)" "\$(cmap_clusters | paste -sd,)"
ACC
got="$(PATH="$TMP/bin:$PATH" P_CLUSTER_MAP="$MAP_OK" bash "$TMP/acc.sh" 2>/dev/null)"
[[ "$got" == "50Gi|20Gi|v4.5.0|billing-db,orders-db|aks-tpg-poc-01,aks-tpg-poc-02|" ]] \
  && ok "lib: map keys override, the input default applies, instances and clusters listed" || bad "lib accessors" "$got"
rm -rf "$TMP/acc"
got="$(PATH="$TMP/bin:$PATH" P_CLUSTER_MAP="" bash "$TMP/acc.sh" 2>/dev/null)"
[[ "$got" == "20Gi|20Gi|v0|||" ]] && ok "lib: without clusterMap every accessor returns the default" || bad "lib no map" "$got"

# ---- fleet-day0.sh: values and the version rule (dry run)
REPO="$TMP/repo"
mkdir -p "$REPO/clusters/_template"
cp "$ROOT/clusters/_template/"*.yaml "$REPO/clusters/_template/"
cat > "$REPO/clusters/fleet.yaml" <<'YAML'
clusters:
  aks-tpg-poc-01:
    operator: {version: v4.5.0}
    instances:
      orders-db: {instance: {postgresVersion: postgres-16.9}}
  aks-tpg-poc-02:
    operator: {version: v4.5.0}
    instances:
      orders-db: {instance: {postgresVersion: postgres-16.9}}
  aks-tpg-poc-03:
    operator: {version: v4.4.0}
YAML
# live state per cluster: operator image tag ("" = not installed) and running instances
cat > "$TMP/live.json" <<'JSON'
{"aks-tpg-poc-01": {"operator": "", "instances": {}},
 "aks-tpg-poc-02": {"operator": "v4.5.0", "instances": {"orders-db": "postgres-16.9"}},
 "aks-tpg-poc-03": {"operator": "v4.4.0", "instances": {}},
 "aks-tpg-poc-04": {"operator": "latest", "instances": {}}}
JSON
cat > "$TMP/day0-prelude.sh" <<PRELUDE
export TPG_WORK="$TMP/day0work"
source "$ROOT/workflows/scripts/lib.sh"
CMAP_KEYS="$ROOT/workflows/params/cluster-map-keys.yaml"
git_clone() { rm -rf "\$1"; cp -r "$REPO" "\$1"; }
record() { printf '%s %s %s %s\n' "\$1" "\$2" "\${3:-}" "\${4:-}" >> "$TMP/records"; printf '%s' "\$2" > /tmp/result; RESULT_RECORDED=1; }
record_entry() { printf '%s %s %s %s\n' "\$1" "\$2" "\${3:-}" "\${4:-}" >> "$TMP/records"; }
appset_refresh() { :; }
setting() { case "\$1" in backupCaBundle) printf '%s' "\${S_CA-PEM}" ;; acnsEnabled) printf false ;; esac; }
git_commit_push() { :; }
use_cluster() { CLUSTER="\$1"; }
tk() {
  local live; live="\$(jq -c --arg c "\$CLUSTER" '.[\$c]' "$TMP/live.json")"
  case "\$*" in
    *readyz*) return 0 ;;
    *"get deploy -A -o json"*)
      jq -c '{items: (if .operator == "" then [] else [{spec: {template: {spec: {containers: [{image: ("reg.example/postgres-operator:" + .operator)}]}}}}] end)}' <<<"\$live" ;;
    *"get postgres"*)
      local i; i="\$(sed -E 's/.*get postgres ([a-z0-9-]+).*/\1/' <<<"\$*")"
      local v; v="\$(jq -r --arg i "\$i" '.instances[\$i] // ""' <<<"\$live")"
      [[ -n "\$v" ]] || return 1
      [[ "\$*" == *jsonpath* ]] && printf '%s' "\$v"
      return 0 ;;
  esac
}
PRELUDE
sed "s#source /scripts/lib.sh#source $TMP/day0-prelude.sh#" "$ROOT/workflows/scripts/fleet-day0.sh" > "$TMP/fleet-day0.sh"
# a real CA bundle: the plan checks it (Round 15, ca_check) and records it as @ca:<sha12>@
openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj /CN=test-ca -keyout "$TMP/ca.key" -out "$TMP/ca.pem" 2>/dev/null
export S_CA; S_CA="$(cat "$TMP/ca.pem")"
CA_PH="@ca:$(printf '%s' "$S_CA" | sha256sum | cut -c1-12)@"
day0() {  # day0 CLUSTERS_JSON VAR=VALUE... -> planned fleet.yaml JSON in $FLEET, records in $TMP/records
  rm -rf "$TMP/day0work" "$TMP/records" /tmp/fleet.json; : > "$TMP/records"
  RC=0; OUT="$(env PATH="$TMP/bin:$PATH" P_DRY_RUN=true P_PUSH_MODE=direct "${@:2}" bash "$TMP/fleet-day0.sh" wf "$1" 2>&1)" || RC=$?
  FLEET="$(cat /tmp/fleet.json 2>/dev/null || echo '{}')"
}
day0 '["aks-tpg-poc-01","aks-tpg-poc-02","aks-tpg-poc-03"]' P_INSTANCES='[orders-db]' P_HA=true \
  P_OPERATOR_VERSION=4.4.0 P_POSTGRES_VERSION=17.6
[[ "$RC" -eq 0 ]] && ok "item 8: the run goes ahead with a blocked cluster" || bad "item 8 rc" "$OUT"
jq -e '.clusters["aks-tpg-poc-01"].operator.version == "v4.4.0" and .clusters["aks-tpg-poc-01"].instances["orders-db"].instance.postgresVersion == "postgres-17.6"' <<<"$FLEET" >/dev/null \
  && grep -q "FLEET_OVERRIDDEN aks-tpg-poc-01 operator v4.5.0 -> v4.4.0 (not installed on the cluster)" <<<"$OUT" \
  && ok "item 8: nothing runs on aks-tpg-poc-01, so the input replaces the fleet.yaml versions (FLEET_OVERRIDDEN)" || bad "item 8 override" "$OUT"
grep -q "^block.aks-tpg-poc-02 BLOCKED DOWNGRADE_NOT_ALLOWED operator v4.5.0 runs on aks-tpg-poc-02" "$TMP/records" \
  && jq -e '.clusters["aks-tpg-poc-02"].operator.version == "v4.5.0"' <<<"$FLEET" >/dev/null \
  && ok "item 8: aks-tpg-poc-02 runs v4.5.0: v4.4.0 is BLOCKED (DOWNGRADE_NOT_ALLOWED) and fleet.yaml is kept" || bad "item 8 downgrade" "$(cat "$TMP/records")"
day0 '["aks-tpg-poc-02"]' P_INSTANCES='[orders-db]' P_HA=true P_OPERATOR_VERSION=v4.5.0 P_POSTGRES_VERSION=17.6
grep -q "^block.aks-tpg-poc-02 BLOCKED UPGRADE_REQUIRED orders-db runs postgres-16.9 on aks-tpg-poc-02: use tpg-upgrade component=postgres targetVersion=postgres-17.6 instances=orders-db" "$TMP/records" \
  && ok "item 8: a running instance on another version is BLOCKED with the tpg-upgrade command" || bad "item 8 instance" "$(cat "$TMP/records")"
day0 '["aks-tpg-poc-03"]' P_INSTANCES='[orders-db]' P_HA=true P_OPERATOR_VERSION=v4.5.0 P_POSTGRES_VERSION=17.6
grep -q "^block.aks-tpg-poc-03 BLOCKED UPGRADE_REQUIRED operator v4.4.0 runs on aks-tpg-poc-03: use tpg-upgrade component=operator targetVersion=v4.5.0" "$TMP/records" \
  && ok "item 8: a newer operator input on a running cluster is BLOCKED (UPGRADE_REQUIRED)" || bad "item 8 upgrade" "$(cat "$TMP/records")"
day0 '["aks-tpg-poc-04"]' P_INSTANCES='[orders-db]' P_HA=true P_OPERATOR_VERSION=v4.5.0 P_POSTGRES_VERSION=17.6
grep -q "^block.aks-tpg-poc-04 BLOCKED VERSION_UNKNOWN an operator runs on aks-tpg-poc-04 but its version cannot be read" "$TMP/records" \
  && ok "item 8: an operator whose version cannot be read is BLOCKED (VERSION_UNKNOWN)" || bad "item 8 unknown" "$(cat "$TMP/records")"
day0 '["aks-tpg-poc-02"]' P_INSTANCES='[orders-db]' P_HA=true P_OPERATOR_VERSION=v4.5.0 P_POSTGRES_VERSION=16.9 P_STORAGE_SIZE=40Gi
jq -e '.clusters["aks-tpg-poc-02"].instances["orders-db"].instance.storageSize == "40Gi"' <<<"$FLEET" >/dev/null && ! grep -q '^block' "$TMP/records" \
  && ok "item 8: the versions the cluster runs are accepted and other inputs are written" || bad "item 8 same version" "$OUT $(cat "$TMP/records")"
day0 '[]' P_CLUSTER_MAP='aks-tpg-poc-01:
  operatorVersion: v4.5.0
  maxReadReplicas: 4
  instances:
    orders-db: {postgresVersion: "17.6", highAvailability: true, readReplicas: 4, cpu: "2", memory: 8Gi, backupEnableSSL: true}
    reporting-db: {postgresVersion: "17.6", highAvailability: false, backupSchedule: none}' P_HA=true P_READ_REPLICAS=3
jq -e '.clusters["aks-tpg-poc-01"] as $c
  | $c.cluster.maxReadReplicas == 4
  and $c.instances["orders-db"].instance.resources.data.requests.cpu == "2" and $c.instances["orders-db"].instance.resources.data.limits.cpu == "2"
  and $c.instances["orders-db"].instance.resources.data.limits.memory == "8Gi"
  and $c.instances["orders-db"].instance.highAvailability.readReplicas == 4
  and $c.instances["orders-db"].backup.enableSSL == true
  and $c.instances["orders-db"].backup.caBundle == $ph
  and ($c.instances["reporting-db"].backup | has("caBundle") | not)
  and $c.instances["reporting-db"].instance.highAvailability == {"enabled": false, "readReplicas": 0}
  and $c.instances["reporting-db"].backup.scheduled == false
  and $c.instances["reporting-db"].backup.enableSSL == false' --arg ph "$CA_PH" <<<"$FLEET" >/dev/null \
  && ok "day0 clusterMap: every key lands on its fleet.yaml paths (cpu twice, no replicas without HA, backupSchedule none, caBundle as its @ca:<sha12>@ placeholder with backupEnableSSL only)" \
  || bad "day0 clusterMap write" "$(jq -c '.clusters["aks-tpg-poc-01"]' <<<"$FLEET") $OUT $(cat "$TMP/records")"
day0 '[]' P_CLUSTER_MAP='aks-tpg-poc-01:
  operatorVersion: v4.5.0
  instances:
    reporting-db: {postgresVersion: "17.6", highAvailability: false, readReplicas: 2}' P_HA=true
grep -q "result.git FAILED INVALID_INPUT .*aks-tpg-poc-01/reporting-db: readReplicas 2 needs highAvailability=true" "$TMP/records" \
  && ok "day0 backstop: fleet-day0.sh refuses readReplicas 2 with highAvailability false (no silent 0)" || bad "day0 backstop rr" "$(cat "$TMP/records")"
day0 '[]' P_CLUSTER_MAP='aks-tpg-poc-01: {operatorVersion: v4.5.0, instances: {orders-db: {postgresVersion: "17.6", highAvailability: true, readReplicas: 5}}}'
[[ "$RC" -ne 0 ]] && grep -q "readReplicas 5 exceeds maxReadReplicas 3" "$TMP/records" \
  && ok "day0 clusterMap: readReplicas above maxReadReplicas fails the step" || bad "day0 max" "$(cat "$TMP/records") $OUT"

echo
echo "tests/cluster-map: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
