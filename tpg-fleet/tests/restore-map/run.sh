#!/usr/bin/env bash
# The clusterMap of tpg-restore (Round 23, phase 6a): a list of pairs
# {sourceClusterConfig, targetClusterConfig}, each <cluster>: <namespace>: <instance>: {keys}.
# Checked here:
#   1 workflows/scripts/clustermap.py restore: the shape of the list, the cardinality of each side,
#     every key rule of locked decision 7 that needs no cluster (one case that is accepted and one
#     that is refused for each rule), the namespace rules, the one-file rule of
#     targetInstanceSpecFilePath with its whitespace message, the rules between the pairs, and the
#     normalized pair JSON the restore step reads
#   2 validate-params.sh restore: the workflow inputs of tpg-restore, the removed flat inputs, the
#     pairs it writes for the batching, and the local spec file in patchFiles
# validate-params.sh runs with the real lib.sh and a stub kubectl that lists the registered clusters.
#
# Requires: bash 4, python3, jq, yq (mikefarah).
# ok() and bad() always return 0; single-quoted snippets are jq, yq or YAML.
# shellcheck disable=SC2015,SC2016
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
for t in python3 jq yq; do command -v "$t" >/dev/null || { echo "SKIP tests/restore-map: $t not installed" >&2; exit 0; }; done
yq --version 2>&1 | grep -q mikefarah || { echo "SKIP tests/restore-map: yq is not mikefarah yq v4" >&2; exit 0; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { printf 'ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL %s\n' "$1"; [[ -z "${2:-}" ]] || printf '%s\n' "$2" | sed 's/^/       | /' | tail -12; FAIL=$((FAIL + 1)); }

CM="$ROOT/workflows/scripts/clustermap.py"
yq -o=json -I=0 '.' "$ROOT/workflows/params/cluster-map-keys.yaml" > "$TMP/keys.json"
printf 'aks-tpg-poc-01\naks-tpg-poc-02\naks-tpg-poc-03\n' > "$TMP/registered"

# ---- helpers for part 1
rm_run() {  # rm_run YAML [extra clustermap.py options] -> OUT, RC; the normalized pairs in $TMP/out.json
  local y="$1"; shift
  rm -f "$TMP/out.json"
  printf '%s\n' "$y" | yq -o=json -I=0 '(.. | select(tag == "!!float")) tag = "!!str"' > "$TMP/in.json"
  RC=0; OUT="$(python3 "$CM" restore --map "$TMP/in.json" --keys "$TMP/keys.json" --registered "$TMP/registered" \
    --out "$TMP/out.json" "$@" 2>&1)" || RC=$?
}
valid() { [[ "$RC" -eq 0 ]] && ok "$1" || bad "$1" "$OUT"; }
invalid() {  # invalid LABEL TEXT...: refused, and the messages hold every TEXT
  local t
  [[ "$RC" -ne 0 ]] || { bad "$1 (accepted)" "$(cat "$TMP/out.json" 2>/dev/null)"; return; }
  for t in "${@:2}"; do grep -qF -- "$t" <<<"$OUT" || { bad "$1 (no '$t')" "$OUT"; return; }; done
  ok "$1"
}
field() {  # field LABEL JQ_FILTER EXPECTED: a value of the first normalized pair
  local got
  got="$(jq -r ".[0] | $2" "$TMP/out.json" 2>&1)" || true
  [[ "$got" == "$3" ]] && ok "$1" || bad "$1 (got '$got', expected '$3')" "$(cat "$TMP/out.json" 2>/dev/null)"
}
# pair SRC_C SRC_NS SRC_I 'SRC_KEYS' TGT_C TGT_NS TGT_I 'TGT_KEYS': one pair as YAML; the key blocks are
# written without indentation, one key per line, and empty for an instance without keys
side() {  # side CLUSTER NS INSTANCE KEYS INDENT
  local pad="$5"
  printf '%s%s:\n%s  %s:\n%s    %s:' "$pad" "$1" "$pad" "$2" "$pad" "$3"
  if [[ -z "$4" ]]; then printf ' {}\n'; else printf '\n'; printf '%s\n' "$4" | sed "s/^/${pad}      /"; fi
}
pair() {
  printf -- '- sourceClusterConfig:\n'; side "$1" "$2" "$3" "$4" '    '
  printf '  targetClusterConfig:\n'; side "$5" "$6" "$7" "$8" '    '
}
# a source on aks-tpg-poc-01 and a target on another cluster, the usual restore into a new instance
X() { pair aks-tpg-poc-01 pg-orders orders-db "${1:-}" aks-tpg-poc-02 pg-orders-dr orders-db-dr "${2:-}"; }
# in place: the same cluster, namespace and instance
IP() { pair aks-tpg-poc-01 pg-orders orders-db "${1:-}" aks-tpg-poc-01 pg-orders orders-db "${2:-}"; }
LATEST=$'pitrEnabled: true\npitrConfig:\n  type: latest'
TIME=$'pitrEnabled: true\nbestEffort: true\npitrConfig:\n  type: time\n  timestamp: 2026-09-15T08:30:00Z'
LSN=$'pitrEnabled: true\nbestEffort: false\npitrConfig:\n  type: lsn\n  target: 0/3000060'
XID=$'pitrEnabled: true\nbestEffort: true\npitrConfig:\n  type: transaction\n  target: "987654"'
BACKUP=$'pitrEnabled: false'
TIME_NODAY=$'pitrEnabled: true\nbestEffort: true\npitrConfig:\n  type: time\n  timestamp: 2026-09-15'
TIME_OFFSET=$'pitrEnabled: true\nbestEffort: true\npitrConfig:\n  type: time\n  timestamp: 2026-09-15T08:30:00+02:00'
TIME_BAD=$'pitrEnabled: true\nbestEffort: true\npitrConfig:\n  type: time\n  timestamp: 2026-13-45T25:61:00Z'
TIME_QUOTED=$'pitrEnabled: true\nbestEffort: true\npitrConfig:\n  type: time\n  timestamp: "2026-09-15T08:30:00Z"'
LSN_BAD=$'pitrEnabled: true\nbestEffort: false\npitrConfig:\n  type: lsn\n  target: 3000060'
XID_BAD=$'pitrEnabled: true\nbestEffort: true\npitrConfig:\n  type: transaction\n  target: 0/3'
SRCB='sourceBackupName: orders-db-full-20260914000000'

echo "== 1. clustermap.py restore: shape of the list and of each pair"
rm_run "$(X '' "$LATEST")"
valid "a pair with the latest recovery point is accepted"
rm_run "$(X "$SRCB" "$BACKUP" | sed 's/aks-tpg-poc-02/aks-tpg-poc-01/; s/pg-orders-dr/pg-orders/; s/orders-db-dr/orders-db-copy/')"
valid "a restore from a named backup into a new instance of the source namespace is accepted"
rm_run '{"sourceClusterConfig": {}, "targetClusterConfig": {}}'
invalid "a mapping instead of a list is refused" "clusterMap must be a list of pairs" "sourceClusterConfig"
rm_run $'aks-tpg-poc-01:\n  instances:\n    orders-db: {}'
invalid "the clusterMap of the other workflows is refused with the pair syntax" "clusterMap must be a list of pairs" "sourceClusterConfig"
rm_run '[]'
invalid "an empty list is refused" "clusterMap: the list is empty" "one pair per restore"
rm_run '["a"]'
invalid "a pair that is a string is refused" "clusterMap[0]: a pair must be a mapping with sourceClusterConfig and targetClusterConfig"
rm_run $'- targetClusterConfig:\n    aks-tpg-poc-02:\n      pg-x:\n        x: {}'
invalid "a pair without sourceClusterConfig is refused" "clusterMap[0]: sourceClusterConfig is required"
rm_run $'- sourceClusterConfig:\n    aks-tpg-poc-01:\n      pg-x:\n        x: {}'
invalid "a pair without targetClusterConfig is refused" "clusterMap[0]: targetClusterConfig is required"
rm_run "$(X '' "$LATEST" | sed 's/^  targetClusterConfig:/  targetClusterConf:/')"
invalid "a misspelled pair key is refused with the closest key" "clusterMap[0]: unknown key targetClusterConf" "did you mean targetClusterConfig"
rm_run "$( { X '' "$LATEST"; X '' "$LATEST" | sed 's/orders-db-dr/orders-db-dr2/'; } )"
valid "two pairs are accepted"
rm_run "$( { X '' "$LATEST"; X '' "$BACKUP"; } )"
invalid "the error names the pair index" "clusterMap[1].sourceClusterConfig" "sourceBackupName is required"

echo "== 1. cardinality and names"
rm_run "$(printf -- '- sourceClusterConfig:\n'; side aks-tpg-poc-01 pg-orders orders-db '' '    '; side aks-tpg-poc-03 pg-orders orders-db '' '    '; printf '  targetClusterConfig:\n'; side aks-tpg-poc-02 pg-orders-dr orders-db-dr "$LATEST" '    ')"
invalid "two source clusters are refused" "clusterMap[0].sourceClusterConfig: exactly one cluster is expected, found 2 (aks-tpg-poc-01, aks-tpg-poc-03)" "one pair per restore"
rm_run "$(pair aks-tpg-poc-01 pg-orders orders-db '' aks-tpg-poc-02 pg-orders-dr orders-db-dr "$LATEST" | sed 's/^    aks-tpg-poc-02:/    aks-tpg-poc-02: {}\n    aks-tpg-poc-03:/')"
invalid "two target clusters are refused" "clusterMap[0].targetClusterConfig: exactly one cluster is expected, found 2"
rm_run $'- sourceClusterConfig:\n    aks-tpg-poc-01:\n      pg-a:\n        a: {}\n      pg-b:\n        b: {}\n  targetClusterConfig:\n    aks-tpg-poc-02:\n      pg-c:\n        c:\n          pitrEnabled: true\n          pitrConfig: {type: latest}'
invalid "two source namespaces are refused" "clusterMap[0].sourceClusterConfig.aks-tpg-poc-01: exactly one namespace is expected, found 2 (pg-a, pg-b)"
rm_run $'- sourceClusterConfig:\n    aks-tpg-poc-01:\n      pg-a:\n        a: {}\n        b: {}\n  targetClusterConfig:\n    aks-tpg-poc-02:\n      pg-c:\n        c:\n          pitrEnabled: true\n          pitrConfig: {type: latest}'
invalid "two source instances are refused" "clusterMap[0].sourceClusterConfig.aks-tpg-poc-01.pg-a: exactly one instance is expected, found 2 (a, b)"
rm_run $'- sourceClusterConfig:\n    aks-tpg-poc-01:\n      pg-a:\n        a: {}\n  targetClusterConfig:\n    aks-tpg-poc-02:\n      pg-c:\n        c1: {pitrEnabled: true, pitrConfig: {type: latest}}\n        c2: {pitrEnabled: true, pitrConfig: {type: latest}}'
invalid "two target instances are refused" "clusterMap[0].targetClusterConfig.aks-tpg-poc-02.pg-c: exactly one instance is expected, found 2 (c1, c2)"
rm_run $'- sourceClusterConfig: {}\n  targetClusterConfig:\n    aks-tpg-poc-02:\n      pg-c:\n        c: {pitrEnabled: true, pitrConfig: {type: latest}}'
invalid "an empty source side is refused" "clusterMap[0].sourceClusterConfig: names no cluster"
rm_run $'- sourceClusterConfig:\n    aks-tpg-poc-01:\n      orders-db:\n        sourceBackupName: x\n  targetClusterConfig:\n    aks-tpg-poc-02:\n      pg-c:\n        c: {pitrEnabled: true, pitrConfig: {type: latest}}'
invalid "a source without its namespace level is refused with the hint" "clusterMap[0].sourceClusterConfig.aks-tpg-poc-01.orders-db.sourceBackupName" "namespaces are mandatory"
rm_run "$(X '' "$LATEST" | sed 's/^    aks-tpg-poc-01:/    Aks_01:/')"
invalid "an invalid cluster name is refused" "clusterMap[0].sourceClusterConfig.Aks_01: 'Aks_01' is not a valid cluster name"
rm_run "$(X '' "$LATEST" | sed 's/aks-tpg-poc-02/aks-tpg-poc-9/')"
invalid "an unregistered target cluster is refused with the registered ones" "clusterMap[0].targetClusterConfig.aks-tpg-poc-9: cluster 'aks-tpg-poc-9' is not registered" "Registered clusters: aks-tpg-poc-01, aks-tpg-poc-02, aks-tpg-poc-03"
rm_run "$(X '' "$LATEST" | sed 's/aks-tpg-poc-01/aks-tpg-poc-07/')"
invalid "an unregistered source cluster is refused" "clusterMap[0].sourceClusterConfig.aks-tpg-poc-07: cluster 'aks-tpg-poc-07' is not registered"
rm_run "$(X '' "$LATEST" | sed 's/pg-orders-dr/PG_Orders/')"
invalid "a namespace that is not a DNS label is refused" "clusterMap[0].targetClusterConfig.aks-tpg-poc-02.PG_Orders" "must be a namespace name"
rm_run "$(X '' "$LATEST" | sed 's/pg-orders-dr/argocd/')"
invalid "the reserved namespace argocd is refused for the target" "namespace 'argocd' is reserved" "choose another"
rm_run "$(X '' "$LATEST" | sed 's/pg-orders-dr/kube-other/')"
invalid "a namespace starting with kube- is refused for the target" "namespace 'kube-other' is reserved" "kube-*"
rm_run "$(X '' "$LATEST" | sed 's/pg-orders-dr/tanzu-postgres-operator/')"
invalid "the operator namespace is refused for the target" "namespace 'tanzu-postgres-operator' is reserved"
rm_run "$(X '' "$LATEST" | sed 's/pg-orders-dr/orders-dr/')"
valid "a target namespace that does not start with pg- is accepted"
rm_run "$(X '' "$LATEST" | sed 's/orders-db-dr/Orders_DR/')"
invalid "an instance name that is not a DNS label is refused" "clusterMap[0].targetClusterConfig.aks-tpg-poc-02.pg-orders-dr.Orders_DR" "lowercase DNS label"
rm_run "$(IP "$SRCB" "$BACKUP"$'\nconfirm: orders-db')"
valid "the same cluster, namespace and instance on both sides is an in-place restore"
field "in place: the pair says so" '.inPlace' "true"

echo "== 1. keys of the source and the target"
rm_run "$(X $'sourceBackupName: orders-db-full-1\nbogus: 1' "$LATEST")"
invalid "an unknown source key is refused" "clusterMap[0].sourceClusterConfig.aks-tpg-poc-01.pg-orders.orders-db: unknown key bogus"
rm_run "$(X $'pitrEnabled: true' "$LATEST")"
invalid "a target key on the source side is refused with the hint" "pitrEnabled is a target key: put it under targetClusterConfig"
rm_run "$(X '' "$LATEST"$'\nsourceBackupName: x')"
invalid "a source key on the target side is refused with the hint" "sourceBackupName is a source key: put it under sourceClusterConfig"
rm_run "$(X '' $'pitrEnable: true\npitrConfig:\n  type: latest')"
invalid "a misspelled target key is refused with the closest key" "unknown key pitrEnable" "did you mean pitrEnabled"
rm_run "$(X 'sourceBackupName: Bad_Name' "$LATEST")"
invalid "a source backup name that is not a Kubernetes name is refused" "clusterMap[0].sourceClusterConfig.aks-tpg-poc-01.pg-orders.orders-db.sourceBackupName" "Kubernetes object name"
rm_run "$(X '' $'pitrConfig:\n  type: latest')"
invalid "pitrConfig without pitrEnabled is refused (pitrEnabled defaults to false)" "orders-db-dr.pitrConfig: not allowed with pitrEnabled: false (pitrEnabled is absent and defaults to false)" "set pitrEnabled: true"
rm_run "$(X '' $'pitrEnabled: maybe\npitrConfig:\n  type: latest')"
invalid "pitrEnabled is true or false" "pitrEnabled: 'maybe' must be true or false"
rm_run "$(X '' '')"
invalid "a target without keys is a named-backup restore, so sourceBackupName is required (both ways out named)" \
  "clusterMap[0].sourceClusterConfig.aks-tpg-poc-01.pg-orders.orders-db.sourceBackupName is required with pitrEnabled: false (pitrEnabled is absent and defaults to false)" \
  "give sourceBackupName" "set pitrEnabled: true with pitrConfig"
rm_run "$(X "$SRCB" '')"
valid "a target without keys and a sourceBackupName is a named-backup restore (pitrEnabled defaults to false)"
field "pitrEnabled absent: the method is backup" '.method' "backup"
field "pitrEnabled absent: the backup name" '.source.backupName' "orders-db-full-20260914000000"
field "pitrEnabled absent: pitr is off" '.pitr.enabled' "false"
rm_run "$(X "$SRCB" 'postRestoreBackup: true')"
valid "other keys without pitrEnabled keep the default (named backup)"
field "pitrEnabled absent with other keys: the method is backup" '.method' "backup"
rm_run "$(X "$SRCB" 'bestEffort: true')"
invalid "bestEffort without pitrEnabled is refused (named backup by default)" "orders-db-dr.bestEffort: not allowed with pitrEnabled: false (pitrEnabled is absent and defaults to false)"
rm_run "$(X '' 'postRestoreBackup: true')"
invalid "an absent pitrEnabled without sourceBackupName is refused" "sourceBackupName is required with pitrEnabled: false (pitrEnabled is absent" "give sourceBackupName, or set pitrEnabled: true with pitrConfig"

echo "== 1. pitrEnabled false: the backup the source names"
rm_run "$(X "$SRCB" "$BACKUP" | sed 's/aks-tpg-poc-02/aks-tpg-poc-01/; s/pg-orders-dr/pg-orders/')"
valid "pitrEnabled false with sourceBackupName is accepted (same cluster and namespace)"
field "pitrEnabled false: the method is backup" '.method' "backup"
field "pitrEnabled false: the backup name" '.source.backupName' "orders-db-full-20260914000000"
field "pitrEnabled false: pitr is off" '.pitr.enabled' "false"
rm_run "$(X '' "$BACKUP" | sed 's/aks-tpg-poc-02/aks-tpg-poc-01/; s/pg-orders-dr/pg-orders/')"
invalid "pitrEnabled false without sourceBackupName is refused" "clusterMap[0].sourceClusterConfig.aks-tpg-poc-01.pg-orders.orders-db.sourceBackupName is required with pitrEnabled: false"
rm_run "$(X "$SRCB" $'pitrEnabled: false\npitrConfig:\n  type: latest' | sed 's/aks-tpg-poc-02/aks-tpg-poc-01/; s/pg-orders-dr/pg-orders/')"
invalid "pitrEnabled false with pitrConfig is refused" "targetClusterConfig.aks-tpg-poc-01.pg-orders.orders-db-dr.pitrConfig: not allowed with pitrEnabled: false"
rm_run "$(X "$SRCB" $'pitrEnabled: false\nbestEffort: true' | sed 's/aks-tpg-poc-02/aks-tpg-poc-01/; s/pg-orders-dr/pg-orders/')"
invalid "pitrEnabled false with bestEffort is refused" "orders-db-dr.bestEffort: not allowed with pitrEnabled: false"
rm_run "$(X "$SRCB" "$BACKUP")"
valid "a named backup into another namespace of another cluster is accepted"
field "named backup, other cluster: the method" '.method' "backup"
field "named backup, other cluster: the scope" '[.inPlace, .sameCluster, .sameNamespace] | @csv' "false,false,false"
field "named backup, other cluster: the backup name" '.source.backupName' "orders-db-full-20260914000000"
rm_run "$(X "$SRCB" "$BACKUP" | sed 's/aks-tpg-poc-02/aks-tpg-poc-01/')"
valid "a named backup into another namespace of the same cluster is accepted"
field "named backup, other namespace: the scope" '[.inPlace, .sameCluster, .sameNamespace] | @csv' "false,true,false"
rm_run "$(X "$SRCB" "$BACKUP" | sed 's/pg-orders-dr/pg-orders/')"
valid "a named backup into the same namespace of another cluster is accepted"
field "named backup, same namespace name on another cluster: not the same namespace" '[.sameCluster, .sameNamespace] | @csv' "false,false"
rm_run "$(X "$SRCB" "$BACKUP")"
[[ "$OUT" != *"restores inside the source namespace only"* ]] && ok "the static refusal of a named backup into another namespace or cluster is gone" || bad "the refusal text is still produced" "$OUT"
rm_run "$(X '' "$BACKUP")"
invalid "a named backup into another cluster still needs sourceBackupName" "orders-db.sourceBackupName is required with pitrEnabled: false"
rm_run "$(X "$SRCB" "$BACKUP" | sed 's/aks-tpg-poc-02/aks-tpg-poc-01/; s/pg-orders-dr/pg-orders/')"
valid "a named backup into a new instance of the source namespace is accepted"

echo "== 1. pitrEnabled true: pitrConfig.type and its keys"
rm_run "$(X '' 'pitrEnabled: true')"
invalid "pitrEnabled true without pitrConfig is refused" "orders-db-dr.pitrConfig is required with pitrEnabled: true"
rm_run "$(X '' $'pitrEnabled: true\npitrConfig:\n  timestamp: 2026-09-15T08:30:00Z')"
invalid "pitrEnabled true without pitrConfig.type is refused" "pitrConfig.type is required with pitrEnabled: true"
rm_run "$(X '' $'pitrEnabled: true\npitrConfig:\n  type: lates')"
invalid "an unknown type is refused with the closest" "pitrConfig.type: 'lates' must be one of latest, time, lsn, transaction"
rm_run "$(X '' $'pitrEnabled: true\npitrConfig:\n  type: latest\n  taget: 1')"
invalid "an unknown pitrConfig key is refused" "pitrConfig: unknown key taget"
rm_run "$(X '' $'pitrEnabled: true\npitrConfig: latest')"
invalid "pitrConfig must be a mapping" "pitrConfig: a mapping is expected"
rm_run "$(X '' "$LATEST")"
valid "type latest alone is accepted"
field "latest: the method" '.method' "latest"
field "latest: pitr enabled" '.pitr.enabled' "true"
field "latest: bestEffort false" '.pitr.bestEffort' "false"
rm_run "$(X '' "$LATEST"$'\nbestEffort: true')"
invalid "latest with bestEffort is refused" "orders-db-dr.bestEffort: not allowed with pitrConfig.type: latest"
rm_run "$(X '' "$LATEST"$'\n  timestamp: 2026-09-15T08:30:00Z')"
invalid "latest with a timestamp is refused" "pitrConfig.timestamp: not allowed with pitrConfig.type: latest"
rm_run "$(X '' "$LATEST"$'\n  target: 0/3000060')"
invalid "latest with a target is refused" "pitrConfig.target: not allowed with pitrConfig.type: latest"
rm_run "$(X '' "$LATEST"$'\n  sourceBackupConfig:\n    srcBackupLabel: 20260915-020000F')"
invalid "latest with srcBackupLabel is refused" "pitrConfig.sourceBackupConfig.srcBackupLabel: not allowed with pitrConfig.type: latest"
rm_run "$(X '' "$TIME")"
valid "type time with a timestamp and bestEffort is accepted"
field "time: the timestamp" '.pitr.timestamp' "2026-09-15T08:30:00Z"
field "time: bestEffort" '.pitr.bestEffort' "true"
rm_run "$(X '' $'pitrEnabled: true\nbestEffort: true\npitrConfig:\n  type: time')"
invalid "type time without a timestamp is refused" "pitrConfig.timestamp is required with pitrConfig.type: time"
rm_run "$(X '' $'pitrEnabled: true\npitrConfig:\n  type: time\n  timestamp: 2026-09-15T08:30:00Z')"
invalid "type time without bestEffort is refused" "orders-db-dr.bestEffort is required with pitrConfig.type: time"
rm_run "$(X '' "$TIME"$'\n  target: 0/3000060')"
invalid "type time with a target is refused" "pitrConfig.target: not allowed with pitrConfig.type: time"
rm_run "$(X '' "$TIME_NODAY")"
invalid "a timestamp without the time of day is refused" "pitrConfig.timestamp: '2026-09-15' must be a UTC time such as 2026-09-15T08:30:00Z"
rm_run "$(X '' "$TIME_OFFSET")"
invalid "a timestamp with an offset is refused" "must be a UTC time"
rm_run "$(X '' "$TIME_BAD")"
invalid "a timestamp that is not a calendar time is refused" "is not a real date and time"
rm_run "$(X '' "$TIME_QUOTED")"
valid "a quoted timestamp is accepted"
rm_run "$(X '' "$LSN")"
valid "type lsn with a target is accepted"
field "lsn: the method" '.method' "lsn"
field "lsn: the target" '.pitr.target' "0/3000060"
field "lsn: bestEffort false" '.pitr.bestEffort' "false"
rm_run "$(X '' $'pitrEnabled: true\nbestEffort: true\npitrConfig:\n  type: lsn')"
invalid "type lsn without a target is refused" "pitrConfig.target is required with pitrConfig.type: lsn"
rm_run "$(X '' "$LSN_BAD")"
invalid "an lsn without the slash is refused" "pitrConfig.target: '3000060' must be a log sequence number such as 0/3000060"
rm_run "$(X '' "$LSN"$'\n  timestamp: 2026-09-15T08:30:00Z')"
invalid "type lsn with a timestamp is refused" "pitrConfig.timestamp: not allowed with pitrConfig.type: lsn"
rm_run "$(X '' $'pitrEnabled: true\npitrConfig:\n  type: lsn\n  target: 0/3000060')"
invalid "type lsn without bestEffort is refused" "bestEffort is required with pitrConfig.type: lsn"
rm_run "$(X '' "$XID")"
valid "type transaction with a target is accepted"
field "transaction: the method" '.method' "transaction"
field "transaction: the target" '.pitr.target' "987654"
rm_run "$(X '' "$XID_BAD")"
invalid "a transaction target that is not a number is refused" "pitrConfig.target: '0/3' must be a transaction ID (a number)"
rm_run "$(X '' $'pitrEnabled: true\nbestEffort: true\npitrConfig:\n  type: transaction')"
invalid "type transaction without a target is refused" "pitrConfig.target is required with pitrConfig.type: transaction"
rm_run "$(X '' "$XID"$'\n  sourceBackupConfig:\n    srcBackupLabel: 20260915-020000F')"
valid "srcBackupLabel with type transaction is accepted"
field "srcBackupLabel" '.pitr.backupLabel' "20260915-020000F"
rm_run "$(X '' "$TIME"$'\n  sourceBackupConfig:\n    srcBackupLocationName: orders-backups\n    srcStanzaName: pg-orders-orders-db-0000\n    srcBackupLabel: 20260915-020000F_20260916-010000I')"
valid "location, stanza and an incremental label are accepted"
field "location name" '.pitr.backupLocation' "orders-backups"
field "stanza name" '.pitr.stanza' "pg-orders-orders-db-0000"
field "incremental label" '.pitr.backupLabel' "20260915-020000F_20260916-010000I"
rm_run "$(X '' "$TIME"$'\n  sourceBackupConfig:\n    srcBackupLabel: yesterday')"
invalid "a backup label that is not a pgBackRest label is refused" "pitrConfig.sourceBackupConfig.srcBackupLabel: 'yesterday' must be a pgBackRest backup label"
rm_run "$(X '' "$TIME"$'\n  sourceBackupConfig:\n    srcStanzaName: "bad stanza"')"
invalid "a stanza name with a space is refused" "pitrConfig.sourceBackupConfig.srcStanzaName: 'bad stanza' must be a pgBackRest stanza name"
rm_run "$(X '' "$TIME"$'\n  sourceBackupConfig:\n    srcBackupLocationName: Bad_Location')"
invalid "a backup location name that is not a Kubernetes name is refused" "srcBackupLocationName: 'Bad_Location' must be a Kubernetes object name"
rm_run "$(X '' "$TIME"$'\n  sourceBackupConfig:\n    srcLabel: x')"
invalid "an unknown sourceBackupConfig key is refused with the closest" "sourceBackupConfig: unknown key srcLabel" "did you mean"
rm_run "$(X "$SRCB" "$LATEST")"
valid "a source backup name with PITR (it only gives the location and stanza) is accepted"
field "the backup name stays in the pair" '.source.backupName' "orders-db-full-20260914000000"

echo "== 1. targetInstanceSpecFilePath, confirm and the flags"
rm_run "$(X '' "$LATEST"$'\ntargetInstanceSpecFilePath: [./orders-dr.yaml]')"
valid "one local spec file in brackets is accepted"
field "the spec file" '.target.specFile' "./orders-dr.yaml"
RSD=helm_artifacts/instance/tpg-instance/restore-specs
rm_run "$(X '' "$LATEST"$'\ntargetInstanceSpecFilePath: [repo:'"$RSD"$'/orders-dr.yaml]')"
valid "one repo: spec file in the restore-specs folder is accepted"
field "the repo: spec file" '.target.specFile' "repo:$RSD/orders-dr.yaml"
rm_run "$(X '' "$LATEST"$'\ntargetInstanceSpecFilePath: [repo:'"$RSD"$'/team/orders-dr.yml]')"
valid "a .yml spec file in a subfolder of restore-specs is accepted"
rm_run "$(X "$SRCB" "$BACKUP"$'\ntargetInstanceSpecFilePath: [repo:'"$RSD"$'/orders-dr.yaml]')"
valid "a spec file with a named-backup restore into another namespace is accepted"
rm_run "$(X '' "$LATEST"$'\ntargetInstanceSpecFilePath: [repo:clusters/restore/orders-dr.yaml]')"
invalid "a repo: spec file outside the restore-specs folder is refused" "must be a file under $RSD/ of the fleet repository"
rm_run "$(X '' "$LATEST"$'\ntargetInstanceSpecFilePath: [repo:helm_artifacts/instance/tpg-instance/patches/orders-dr.yaml]')"
invalid "a spec file in the patches folder is refused" "must be a file under $RSD/ of the fleet repository"
rm_run "$(X '' "$LATEST"$'\ntargetInstanceSpecFilePath: [repo:helm_artifacts/instance/tpg-instance/restore-specsx/orders-dr.yaml]')"
invalid "a folder that only starts like restore-specs is refused" "must be a file under $RSD/ of the fleet repository"
rm_run "$(X '' "$LATEST"$'\ntargetInstanceSpecFilePath: [repo:'"$RSD"$'/../patches/orders-dr.yaml]')"
invalid "a repo: spec file with .. is refused" "(no leading /, no ..)"
rm_run "$(X '' "$LATEST"$'\ntargetInstanceSpecFilePath: [repo:/'"$RSD"$'/orders-dr.yaml]')"
invalid "an absolute repo: spec file is refused" "(no leading /, no ..)"
rm_run "$(X '' "$LATEST"$'\ntargetInstanceSpecFilePath: [repo:helm_artifacts/instance/tpg-instance//restore-specs/orders-dr.yaml]')"
invalid "a repo: spec file with // is refused" "(no leading /, no ..)"
rm_run "$(X '' "$LATEST"$'\ntargetInstanceSpecFilePath: [repo:'"$RSD"$'//orders-dr.yaml]')"
invalid "a repo: spec file with // inside the folder is refused" "(no leading /, no ..)"
rm_run "$(X '' "$LATEST"$'\ntargetInstanceSpecFilePath: [repo:'"$RSD"$'/README.md]')"
invalid "the README of the restore-specs folder is not a spec file" "must be repo:<path of a .yaml or .yml file"
rm_run "$(X '' "$LATEST"$'\ntargetInstanceSpecFilePath: [repo:'"$RSD"$'/orders-dr.json]')"
invalid "a repo: spec file that is not .yaml or .yml is refused" "must be repo:<path of a .yaml or .yml file"
rm_run "$(X '' "$LATEST"$'\ntargetInstanceSpecFilePath: [repo:'"$RSD"$'/]')"
invalid "the restore-specs folder itself is refused" "must be repo:<path of a .yaml or .yml file"
rm_run "$(X '' "$LATEST"$'\ntargetInstanceSpecFilePath: [repo:helm_artifacts/operator/patches/clusters/aks-tpg-poc-01/x.yaml]')"
invalid "a per-cluster operator copy is refused too" "restore-specs"
rm_run "$(X '' "$LATEST"$'\ntargetInstanceSpecFilePath: ./orders-dr.yaml')"
invalid "a spec file that is not in brackets is refused with the list syntax" "targetInstanceSpecFilePath: './orders-dr.yaml' is not a list" "[./orders-dr.yaml]"
rm_run "$(X '' "$LATEST"$'\ntargetInstanceSpecFilePath: [repo: clusters/restore/orders-dr.yaml]')"
invalid "repo: with a space is refused with the whitespace message" 'repo:<file path> "check for white spaces in between"'
rm_run "$(X '' "$LATEST"$'\ntargetInstanceSpecFilePath: [./a.yaml, ./b.yaml]')"
invalid "two spec files are refused" "exactly one file is expected"
rm_run "$(X '' "$LATEST"$'\ntargetInstanceSpecFilePath: [./orders-dr.txt]')"
invalid "a spec file that is not .yaml or .yml is refused" "must be the path of one .yaml or .yml file"
rm_run "$(X '' "$LATEST"$'\ntargetInstanceSpecFilePath: [repo:../orders-dr.yaml]')"
invalid "a repo: path with .. is refused" "(no leading /, no ..)"
rm_run "$(IP "$SRCB" "$BACKUP"$'\nconfirm: orders-db\ntargetInstanceSpecFilePath: [./orders-dr.yaml]')"
valid "a spec file for an in-place restore is accepted (its values override the existing instance's; Round 23 phase 6b revision)"
field "the in-place pair carries the spec file" '.target.specFile' "./orders-dr.yaml"
rm_run "$(IP "$SRCB" "$BACKUP"$'\nconfirm: orders-db')"
valid "in place with the confirmation is accepted"
rm_run "$(IP "$SRCB" "$BACKUP")" --confirm-required
invalid "in place without confirm is refused for a real restore" "orders-db.confirm is required" "in place" "overwrites its data"
rm_run "$(IP "$SRCB" "$BACKUP")"
valid "in place without confirm is accepted when the run is a dry run (the plan comes first)"
field "the pair carries an empty confirm" '.target.confirm' ""
rm_run "$(IP "$SRCB" "$BACKUP"$'\nconfirm: orders-dbx')" --confirm-required
invalid "a confirm that is not the target instance is refused" "confirm: 'orders-dbx' must repeat the target instance name orders-db"
rm_run "$(IP "$SRCB" "$BACKUP"$'\nconfirm: orders-dbx')"
invalid "a wrong confirm is refused in a dry run too" "must repeat the target instance name orders-db"
# Round 23, third revision: confirm belongs to an in-place restore only; a target that exists and is not the source is TARGET_EXISTS
rm_run "$(X '' "$LATEST"$'\nconfirm: orders-db-dr')"
invalid "confirm on a pair that is not in place is refused as meaningless" "targetClusterConfig.aks-tpg-poc-02.pg-orders-dr.orders-db-dr.confirm: not allowed" "only for an in-place restore" "remove confirm"
rm_run "$(X '' "$LATEST"$'\nconfirm: orders-db-dr')" --confirm-required
invalid "…also when the run is a real restore" "orders-db-dr.confirm: not allowed" "only for an in-place restore"
rm_run "$(X '' "$LATEST"$'\nconfirm: something-else')"
invalid "a wrong confirm on a pair that is not in place says it is not allowed (not that the name differs)" "confirm: not allowed" "only for an in-place restore"
rm_run "$(X "$SRCB" "$BACKUP"$'\nconfirm: orders-db-dr' | sed 's/aks-tpg-poc-02/aks-tpg-poc-01/')"
invalid "confirm on a copy into another namespace of the same cluster is refused" "confirm: not allowed" "only for an in-place restore"
rm_run "$(X "$SRCB" "$BACKUP"$'\nconfirm: orders-db' | sed 's/aks-tpg-poc-02/aks-tpg-poc-01/; s/pg-orders-dr/pg-orders/; s/orders-db-dr/orders-db-copy/')"
invalid "confirm on a new instance in the source namespace is refused" "confirm: not allowed" "only for an in-place restore"
rm_run "$(X '' "$LATEST"$'\nskipMinorVersionCheck: true\npostRestoreBackup: true')"
valid "skipMinorVersionCheck and postRestoreBackup are accepted"
field "skipMinorVersionCheck" '.target.skipMinorVersionCheck' "true"
field "postRestoreBackup" '.target.postRestoreBackup' "true"
rm_run "$(X '' "$LATEST")"
field "skipMinorVersionCheck defaults to false" '.target.skipMinorVersionCheck' "false"
field "postRestoreBackup defaults to false" '.target.postRestoreBackup' "false"
rm_run "$(X '' "$LATEST"$'\npostRestoreBackup: yes please')"
invalid "postRestoreBackup is true or false" "postRestoreBackup: 'yes please' must be true or false"

echo "== 1. the normalized pair"
rm_run "$(X "$SRCB" "$TIME"$'\nskipMinorVersionCheck: true' | sed 's/^      pg-orders-dr:/      pg-orders-dr:/')"
valid "a pair with every part is accepted"
jq -e '.[0] | keys == ["inPlace","index","label","method","pitr","sameCluster","sameNamespace","source","target"]
  and (.pitr | keys == ["backupLabel","backupLocation","bestEffort","enabled","stanza","target","timestamp","type"])
  and (.source | keys == ["backupName","cluster","instance","namespace"])
  and (.target | keys == ["cluster","confirm","instance","namespace","postRestoreBackup","skipMinorVersionCheck","specFile"])' "$TMP/out.json" >/dev/null \
  && ok "the normalized pair has the documented fields (index, label, method, scope flags, source, target, pitr)" || bad "pair fields" "$(cat "$TMP/out.json")"
field "index" '.index' "0"
field "label" '.label' "aks-tpg-poc-01/pg-orders/orders-db -> aks-tpg-poc-02/pg-orders-dr/orders-db-dr"
field "scope: other cluster" '[.inPlace, .sameCluster, .sameNamespace] | @csv' "false,false,false"
field "source and target" '[.source.cluster, .source.namespace, .source.instance, .target.cluster, .target.namespace, .target.instance] | join(" ")' \
  "aks-tpg-poc-01 pg-orders orders-db aks-tpg-poc-02 pg-orders-dr orders-db-dr"
rm_run "$(pair aks-tpg-poc-01 pg-orders orders-db '' aks-tpg-poc-01 pg-orders-copy orders-db-copy "$LATEST")"
field "scope: other namespace of the same cluster" '[.inPlace, .sameCluster, .sameNamespace] | @csv' "false,true,false"
rm_run "$(pair aks-tpg-poc-01 pg-orders orders-db '' aks-tpg-poc-01 pg-orders orders-db-copy "$LATEST")"
field "scope: same namespace, another instance" '[.inPlace, .sameCluster, .sameNamespace] | @csv' "false,true,true"
rm_run "$( { X '' "$LATEST"; X '' "$TIME" | sed 's/orders-db-dr/orders-db-dr2/'; } )"
jq -e 'map(.index) == [0, 1]' "$TMP/out.json" >/dev/null && ok "pairs are numbered in the order of the list" || bad "pair index" "$(cat "$TMP/out.json")"

echo "== 1. rules between the pairs"
rm_run "$( { X '' "$LATEST"; X '' "$TIME"; } )"
invalid "two pairs with the same target are refused" "clusterMap[1].targetClusterConfig: aks-tpg-poc-02/pg-orders-dr/orders-db-dr is also the target of clusterMap[0]"
rm_run "$( { X '' "$LATEST"; pair aks-tpg-poc-02 pg-orders-dr orders-db-dr '' aks-tpg-poc-03 pg-x orders-x "$LATEST"; } )"
invalid "a target that is the source of another pair is refused" "clusterMap[0].targetClusterConfig: aks-tpg-poc-02/pg-orders-dr/orders-db-dr is the source of clusterMap[1]"
rm_run "$( { X '' "$LATEST"; X '' "$LATEST" | sed 's/orders-db-dr/orders-db-dr2/'; } )"
valid "two pairs from one source into two targets are accepted"
rm_run "$( { X '' "$LATEST"; X '' "$LATEST" | sed 's/orders-db-dr/orders-db-dr2/'; } )" --no-such-option
[[ "$RC" -ne 0 ]] && ok "an unknown option is refused" || bad "unknown option accepted"

# ---- part 2: validate-params.sh restore
echo "== 2. validate-params.sh restore"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
if [[ "$*" == *"get secret -l tpg.fleet/cluster"* ]]; then
  printf '{"items":[%s]}' "$(for c in aks-tpg-poc-01 aks-tpg-poc-02 aks-tpg-poc-03; do
    printf '{"metadata":{"labels":{"tpg.fleet/cluster":"%s"}}},' "$c"; done | sed 's/,$//')"
  exit 0
fi
exit 0
STUB
chmod +x "$TMP/bin/kubectl"
# the fleet repository the validate step clones to read clusters.<c>.cluster.allowInPlaceRestore
mkdir -p "$TMP/fleetrepo/clusters/_template"
cp "$ROOT/clusters/_template/cluster.yaml" "$TMP/fleetrepo/clusters/_template/cluster.yaml"
fleet() { printf '%s\n' "$1" > "$TMP/fleetrepo/clusters/fleet.yaml"; }
fleet $'clusters:\n  aks-tpg-poc-01:\n    cluster:\n      allowInPlaceRestore: true\n    instances: {}\n  aks-tpg-poc-02:\n    instances: {}'
sed -e "s#source /scripts/lib.sh#source $ROOT/workflows/scripts/lib.sh#" \
    -e "/^source .*lib.sh\$/a git_clone() { [[ ! -f $TMP/clone-fails ]] || return 128; echo clone >> $TMP/clones; rm -rf \"\$1\"; cp -r $TMP/fleetrepo \"\$1\"; }" \
    "$ROOT/workflows/scripts/validate-params.sh" > "$TMP/validate.sh"
vp() {  # vp VAR=VALUE... -> runs validate-params.sh restore; output in $OUT, status in $RC; /tmp/pairs.json is read back
  rm -rf "$TMP/work"; rm -f /tmp/pairs.json "$TMP/clones"
  RC=0; OUT="$(cd "$TMP" && env -i PATH="$TMP/bin:$PATH" HOME="$TMP" TPG_WORK="$TMP/work" "$@" \
    bash "$TMP/validate.sh" restore 2>&1)" || RC=$?
}
vvalid() { [[ "$RC" -eq 0 ]] && ok "$1" || bad "$1" "$OUT"; }
vinvalid() {
  local t
  [[ "$RC" -ne 0 ]] || { bad "$1 (accepted)" "$OUT"; return; }
  for t in "${@:2}"; do grep -qF -- "$t" <<<"$OUT" || { bad "$1 (no '$t')" "$OUT"; return; }; done
  ok "$1"
}
MAP="$(X '' "$LATEST")"
vp P_CLUSTER_MAP="$MAP"
vvalid "restore: a clusterMap of one pair is accepted with the defaults (dryRun true, rolloutMode all)"
jq -e 'length == 1 and .[0].method == "latest"' /tmp/pairs.json >/dev/null && ok "restore: the normalized pairs are written to /tmp/pairs.json" || bad "pairs.json" "$(cat /tmp/pairs.json 2>&1)"
vp P_CLUSTER_MAP=""
vinvalid "restore: clusterMap is mandatory" "clusterMap is mandatory" "sourceClusterConfig"
vp P_CLUSTER_MAP='aks-tpg-poc-01: {instances: {orders-db: {}}}'
vinvalid "restore: a map of clusters is refused with the pair syntax" "clusterMap must be a list of pairs"
vp P_CLUSTER_MAP="$MAP"
[[ ! -e "$TMP/clones" ]] && ok "restore: a run without an in-place pair does not clone the fleet repository" || bad "restore: cloned without an in-place pair"
vp P_CLUSTER_MAP="$MAP" P_ROLLOUT_MODE=fast
vinvalid "restore: rolloutMode takes canary, batches or all" "rolloutMode must be one of: canary batches all"
vp P_CLUSTER_MAP="$MAP" P_ROLLOUT_MODE=canary P_MAX_PARALLEL=3 P_PUSH_MODE=pr P_DRY_RUN=false P_KEEP_SOURCE_LOCATION=false P_TIMEOUT=600 P_PR_TIMEOUT=900
vvalid "restore: canary, maxParallel, pushMode pr, dryRun false, keepSourceLocation false and the timeouts are accepted"
vp P_CLUSTER_MAP="$MAP" P_DRY_RUN=maybe
vinvalid "restore: dryRun is true or false" "dryRun must be true or false"
vp P_CLUSTER_MAP="$MAP" P_MAX_PARALLEL=0
vinvalid "restore: maxParallel is a positive integer" "maxParallel must be a positive integer"
vp P_CLUSTER_MAP="$MAP" P_PUSH_MODE=push
vinvalid "restore: pushMode is direct or pr" "pushMode must be one of: direct pr"
vp P_CLUSTER_MAP="$MAP" P_KEEP_SOURCE_LOCATION=sometimes
vinvalid "restore: keepSourceLocation is true or false" "keepSourceLocation must be true or false"
vp P_CLUSTER_MAP="$MAP" P_TIMEOUT=0
vinvalid "restore: restoreTimeoutSeconds is a positive integer" "restoreTimeoutSeconds must be a positive integer"
vp P_CLUSTER_MAP="$(IP "$SRCB" "$BACKUP")"
vvalid "restore: an in-place pair without confirm is accepted while dryRun is true (the default)"
vp P_CLUSTER_MAP="$(IP "$SRCB" "$BACKUP")" P_DRY_RUN=false
vinvalid "restore: an in-place pair without confirm is refused when dryRun is false" "orders-db.confirm is required"
vp P_CLUSTER_MAP="$(IP "$SRCB" "$BACKUP"$'\nconfirm: orders-db')" P_DRY_RUN=false
vvalid "restore: an in-place pair with confirm is accepted when dryRun is false"
vp P_CLUSTER_MAP="$(X '' "$LATEST"$'\nconfirm: orders-db-dr')" P_DRY_RUN=false
vinvalid "restore: confirm on a pair that is not in place is refused at validate (a target that exists is TARGET_EXISTS at plan time)" "orders-db-dr.confirm: not allowed" "only for an in-place restore"
vp P_CLUSTER_MAP="$(X '' "$LATEST"$'\nconfirm: orders-db-dr')"
vinvalid "restore: …also while dryRun is true" "orders-db-dr.confirm: not allowed"
# the in-place guard: clusters.<c>.cluster.allowInPlaceRestore (fleet.yaml override, else the template's false)
IPC="$(IP "$SRCB" "$BACKUP"$'\nconfirm: orders-db')"
vp P_CLUSTER_MAP="$IPC"
vvalid "restore: an in-place pair on a cluster with allowInPlaceRestore: true is accepted (dryRun true)"
[[ -e "$TMP/clones" ]] && ok "restore: the fleet repository was read to check it" || bad "restore: no clone for an in-place pair"
vp P_CLUSTER_MAP="$IPC" P_DRY_RUN=false
vvalid "restore: an in-place pair on a cluster with allowInPlaceRestore: true is accepted (dryRun false)"
IP2="$(pair aks-tpg-poc-02 pg-orders orders-db "$SRCB" aks-tpg-poc-02 pg-orders orders-db $'pitrEnabled: false\nconfirm: orders-db')"
vp P_CLUSTER_MAP="$IP2"
vinvalid "restore: an in-place pair on a cluster without the setting (template default false) refuses the run, also in a dry run" \
  "IN_PLACE_NOT_ALLOWED" "cluster aks-tpg-poc-02" "clusters.aks-tpg-poc-02.cluster.allowInPlaceRestore: true in clusters/fleet.yaml" "clusterMap[0]" "before any pair starts"
vp P_CLUSTER_MAP="$IP2" P_DRY_RUN=false
vinvalid "restore: the same refusal with dryRun false" "IN_PLACE_NOT_ALLOWED" "clusters.aks-tpg-poc-02.cluster.allowInPlaceRestore: true"
fleet $'clusters:\n  aks-tpg-poc-01:\n    cluster:\n      allowInPlaceRestore: false\n    instances: {}'
vp P_CLUSTER_MAP="$IPC"
vinvalid "restore: allowInPlaceRestore: false in fleet.yaml refuses the run" "IN_PLACE_NOT_ALLOWED" "cluster aks-tpg-poc-01" "clusters.aks-tpg-poc-01.cluster.allowInPlaceRestore: true"
fleet $'clusters:\n  aks-tpg-poc-02:\n    instances: {}'
vp P_CLUSTER_MAP="$IPC"
vinvalid "restore: a cluster without an entry in fleet.yaml refuses the run" "IN_PLACE_NOT_ALLOWED" "cluster aks-tpg-poc-01"
fleet $'clusters:\n  aks-tpg-poc-01:\n    cluster:\n      allowInPlaceRestore: "yes"\n    instances: {}'
vp P_CLUSTER_MAP="$IPC"
vinvalid "restore: only true allows it (any other value refuses)" "IN_PLACE_NOT_ALLOWED"
fleet $'clusters:\n  aks-tpg-poc-01:\n    cluster:\n      allowInPlaceRestore: true\n    instances: {}\n  aks-tpg-poc-02:\n    instances: {}'
vp P_CLUSTER_MAP="$( { printf '%s\n' "$IPC"; printf '%s\n' "$IP2"; } )"
vinvalid "restore: one pair of two on a cluster without the setting refuses the whole run" "IN_PLACE_NOT_ALLOWED" "cluster aks-tpg-poc-02" "clusterMap[1]"
grep -qF "aks-tpg-poc-01" <<<"$(grep -F IN_PLACE_NOT_ALLOWED <<<"$OUT")" && bad "restore: the allowed cluster is named in the refusal" "$OUT" || ok "restore: only the cluster without the setting is named"
vp P_CLUSTER_MAP="$( { printf '%s\n' "$IPC"; pair aks-tpg-poc-01 pg-x x-db '' aks-tpg-poc-02 pg-x x-db2 "$LATEST"; } )"
vvalid "restore: a not-in-place pair next to an allowed in-place pair is accepted"
vp P_CLUSTER_MAP="$(X "$SRCB" "$BACKUP" | sed 's/aks-tpg-poc-02/aks-tpg-poc-01/; s/pg-orders-dr/pg-orders/')"
vvalid "restore: a named backup into a new instance of the source namespace needs no allowInPlaceRestore"
touch "$TMP/clone-fails"
vp P_CLUSTER_MAP="$IPC"
vinvalid "restore: an unreadable fleet repository refuses the run (fail closed)" "IN_PLACE_NOT_ALLOWED" "clusters/fleet.yaml could not be read"
vp P_CLUSTER_MAP="$MAP"
vvalid "restore: an unreadable fleet repository does not matter without an in-place pair"
rm -f "$TMP/clone-fails"
vp P_CLUSTER_MAP="$(X '' "$LATEST"$'\npitrConfig2: 1')"
vinvalid "restore: a bad key is reported with the pair and the key path" "clusterMap[0].targetClusterConfig.aks-tpg-poc-02.pg-orders-dr.orders-db-dr: unknown key pitrConfig2"
vp P_CLUSTER_MAP="$MAP" P_SOURCE_CLUSTER=aks-tpg-poc-01
vvalid "restore: an environment variable of a removed flat input is not read"
# the local spec file: its contents travel in patchFiles (pack-patch-files.sh), checked as a Postgres document
SPEC_MAP="$(X '' "$LATEST"$'\ntargetInstanceSpecFilePath: [./orders-dr.yaml]')"
vp P_CLUSTER_MAP="$SPEC_MAP"
vinvalid "restore: a local spec file that is not in patchFiles is refused" "orders-db-dr.targetInstanceSpecFilePath: orders-dr.yaml: its contents are not in patchFiles"
PF_OK="$(jq -cn --arg c $'apiVersion: sql.tanzu.vmware.com/v1\nkind: Postgres\nspec:\n  postgresVersion:\n    name: postgres-17.6\n  highAvailability:\n    enabled: false\n' '{"orders-dr.yaml": ($c | @base64)}')"
vp P_CLUSTER_MAP="$SPEC_MAP" P_PATCH_FILES="$PF_OK"
vvalid "restore: a local spec file with one Postgres document in patchFiles is accepted"
PF_TWO="$(jq -cn --arg c $'apiVersion: sql.tanzu.vmware.com/v1\nkind: Postgres\nspec:\n  postgresVersion:\n    name: postgres-17.6\n---\napiVersion: sql.tanzu.vmware.com/v1\nkind: Postgres\nspec:\n  postgresVersion:\n    name: postgres-17.6\n' '{"orders-dr.yaml": ($c | @base64)}')"
vp P_CLUSTER_MAP="$SPEC_MAP" P_PATCH_FILES="$PF_TWO"
vinvalid "restore: a spec file with two documents is refused" "exactly one kind: Postgres document"
PF_KIND="$(jq -cn --arg c $'apiVersion: sql.tanzu.vmware.com/v1\nkind: PostgresBackupLocation\nspec:\n  retentionPolicy:\n    fullRetention:\n      number: 4\n' '{"orders-dr.yaml": ($c | @base64)}')"
vp P_CLUSTER_MAP="$SPEC_MAP" P_PATCH_FILES="$PF_KIND"
vinvalid "restore: a spec file of another kind is refused" "exactly one kind: Postgres document"
vp P_CLUSTER_MAP="$MAP" P_PATCH_FILES="$PF_OK"
vinvalid "restore: patchFiles that no spec file key names are refused" "patchFiles carries orders-dr.yaml, which no path input or clusterMap key names"
vp P_CLUSTER_MAP="$(X '' "$LATEST"$'\ntargetInstanceSpecFilePath: [repo:'"$RSD"$'/orders-dr.yaml]')"
vvalid "restore: a repo: spec file needs nothing in patchFiles (the plan step reads the repository)"

# ---- part 3: pack-patch-files.sh packs the spec file of a pair
echo "== 3. pack-patch-files.sh"
mkdir -p "$TMP/pack"
printf 'apiVersion: sql.tanzu.vmware.com/v1\nkind: Postgres\nspec:\n  postgresVersion:\n    name: postgres-17.6\n' > "$TMP/pack/orders-dr.yaml"
{ printf 'dryRun: "false"\nclusterMap: |\n'; X '' "$LATEST"$'\ntargetInstanceSpecFilePath: [./orders-dr.yaml]' | sed 's/^/  /'; } > "$TMP/pack/params.yaml"
RC=0; OUT="$(cd "$TMP/pack" && TPG_FLEET_DIR="$ROOT" bash "$ROOT/scripts/submit/pack-patch-files.sh" -o params.yaml 2>&1)" || RC=$?
if [[ "$RC" -eq 0 ]] && yq -r '.patchFiles' "$TMP/pack/params.yaml" | jq -e 'keys == ["./orders-dr.yaml"] or keys == ["orders-dr.yaml"]' >/dev/null; then
  ok "pack: the spec file named by a pair of the clusterMap is packed into patchFiles"
else bad "pack: spec file" "$OUT"; fi
{ printf 'clusterMap: |\n'; X '' "$LATEST"$'\ntargetInstanceSpecFilePath: [repo: '"$RSD"$'/orders-dr.yaml]' | sed 's/^/  /'; } > "$TMP/pack/ws.yaml"
RC=0; OUT="$(cd "$TMP/pack" && TPG_FLEET_DIR="$ROOT" bash "$ROOT/scripts/submit/pack-patch-files.sh" -o ws.yaml 2>&1)" || RC=$?
[[ "$RC" -ne 0 ]] && grep -qF 'targetInstanceSpecFilePath: repo:<file path> "check for white spaces in between"' <<<"$OUT" \
  && ok "pack: [repo: x.yaml] in a pair gets the whitespace message" || bad "pack: whitespace" "$OUT"
printf 'apiVersion: sql.tanzu.vmware.com/v1\nkind: PostgresBackupLocation\nspec:\n  retentionPolicy:\n    fullRetention:\n      number: 4\n' > "$TMP/pack/orders-dr.yaml"
RC=0; OUT="$(cd "$TMP/pack" && TPG_FLEET_DIR="$ROOT" bash "$ROOT/scripts/submit/pack-patch-files.sh" -o params.yaml 2>&1)" || RC=$?
[[ "$RC" -ne 0 ]] && grep -qF "exactly one kind: Postgres document" <<<"$OUT" \
  && ok "pack: a spec file of another kind is refused before the run" || bad "pack: other kind" "$OUT"

# ---- part 4: the WorkflowTemplate, the gate and the entry point (the pair itself: tests/restore)
echo "== 4. template, gate, restore-pair.sh"
TPL="$ROOT/workflows/templates/tpg-restore.yaml"
inputs="$(yq -r '.spec.arguments.parameters[].name' "$TPL" | sort | paste -sd' ')"
[[ "$inputs" == "clusterMap dryRun keepSourceLocation maxParallel patchFiles prTimeoutSeconds pushMode restoreTimeoutSeconds rolloutMode toolsImage" ]] \
  && ok "the template's inputs: clusterMap, rolloutMode, pushMode, dryRun, maxParallel, restoreTimeoutSeconds, prTimeoutSeconds, patchFiles, keepSourceLocation, toolsImage" || bad "template inputs" "$inputs"
d="$(yq -r '.spec.arguments.parameters[] | select(.name == "dryRun" or .name == "rolloutMode" or .name == "keepSourceLocation") | .name + "=" + .value' "$TPL" | sort | paste -sd' ')"
[[ "$d" == "dryRun=true keepSourceLocation=true rolloutMode=all" ]] && ok "defaults: dryRun true, rolloutMode all, keepSourceLocation true" || bad "template defaults" "$d"
flat='(P_|workflow\.parameters\.)(sourceCluster|SOURCE_CLUSTER|instance|INSTANCE|mode|MODE|targetTime|TARGET_TIME|backupName|BACKUP_NAME|lsn|LSN|xid|XID|targetCluster|TARGET_CLUSTER|targetInstance|TARGET_INSTANCE|confirm|CONFIRM|bestEffort|BEST_EFFORT)\b'
if grep -nE "$flat" "$TPL" "$ROOT/workflows/scripts/restore-pair.sh" | grep -v '^[^:]*:[0-9]*:\s*#'; then
  bad "a removed flat input is still referenced (above)"
else ok "no removed flat input is an input or environment variable of the template or the entry point"; fi
sed -n '/^  restore)/,/^  delete-instance)/p' "$ROOT/workflows/scripts/validate-params.sh" | grep -nE 'P_(SOURCE_CLUSTER|INSTANCE|MODE|TARGET_TIME|BACKUP_NAME|LSN|XID|TARGET_CLUSTER|TARGET_INSTANCE|CONFIRM|BEST_EFFORT)\b' \
  && bad "the restore branch of validate-params.sh reads a removed flat input (above)" || ok "the restore branch of validate-params.sh reads no removed flat input"
! grep -q 'cluster_one' "$ROOT/workflows/scripts/validate-params.sh" && ok "the cluster_one helper of Phase 2 is gone" || bad "cluster_one is still defined"
yq -o=json -I=0 '.spec.templates[] | select(.name == "main") | .steps | flatten | map(.name)' "$TPL" | jq -e '. == ["validate","init","batches","split","canary","first","rest","gate"]' >/dev/null \
  && ok "steps: validate, init, batches, split, canary or first batch, the rest, gate" || bad "template steps" "$(yq -o=json -I=0 '.spec.templates[0].steps | flatten | map(.name)' "$TPL")"
yq -e '(.spec.templates[] | select(.name == "main") | .steps[][] | select(.name == "canary") | .when) == "'"'"'{{workflow.parameters.rolloutMode}}'"'"' == '"'"'canary'"'"'"' "$TPL" >/dev/null \
  && yq -e '(.spec.templates[] | select(.name == "main") | .steps[][] | select(.name == "canary") | has("continueOn")) == false' "$TPL" >/dev/null \
  && yq -e '(.spec.templates[] | select(.name == "main") | .steps[][] | select(.name == "first") | .continueOn.failed) == true' "$TPL" >/dev/null \
  && yq -e '(.spec.templates[] | select(.name == "run-batches") | .steps[][] | select(.name == "restore") | .continueOn.failed) == true' "$TPL" >/dev/null \
  && ok "a failed canary fails its step (the run stops); a failed pair of any other batch does not stop the rest" || bad "canary and continueOn"
yq -e '(.spec.templates[] | select(.name == "restore-pair") | .container.command[1]) == "/scripts/restore-pair.sh"' "$TPL" >/dev/null \
  && grep -q 'scripts/restore-pair.sh' "$ROOT/workflows/kustomization.yaml" && grep -q 'params/types.yaml' "$ROOT/workflows/kustomization.yaml" \
  && ok "one restore-pair step per pair runs restore-pair.sh, which the tpg-scripts ConfigMap ships" || bad "restore-pair step"
yq -o=json -I=0 '.spec.templates[] | select(.name == "gate") | .container.args' "$TPL" | jq -e '. == ["{{workflow.name}}", "failed"]' >/dev/null \
  && ok "the run ends with the gate that also fails the run for a FAILED or TIMEOUT pair" || bad "gate step"
yq -e '(.spec.templates[] | select(.name == "validate") | .outputs.parameters[0].valueFrom.path) == "/tmp/pairs.json"' "$TPL" >/dev/null \
  && ok "the validate step outputs the normalized pairs" || bad "validate output"

mkdir -p "$TMP/gate"
cat > "$TMP/gate/lib.sh" <<'LIB'
log() { printf '%s\n' "$*" >&2; }
run_records() { printf '%s' "$RECORDS"; }
LIB
sed "s#source /scripts/lib.sh#source $TMP/gate/lib.sh#" "$ROOT/workflows/scripts/blocked-gate.sh" > "$TMP/gate/gate.sh"
rec() { jq -cn --arg k "$1" --arg s "$2" --arg r "$3" '{($k): ({status: $s, reason: $r} | tojson)}'; }
gate() { RC=0; OUT="$(RECORDS="$1" bash "$TMP/gate/gate.sh" wf ${2:+"$2"} 2>&1)" || RC=$?; }
gate "$(jq -cn --argjson a "$(rec result.c2.b SUCCEEDED '')" --argjson b "$(rec result.c2.c SKIPPED SKIPPED_IN_PROGRESS)" '$a + $b')" failed
[[ "$RC" -eq 0 ]] && ok "gate failed: SUCCEEDED and SKIPPED pairs pass" || bad "gate pass" "$OUT"
gate "$(jq -cn --argjson a "$(rec result.c2.b FAILED RESTORE_FAILED)" --argjson b "$(rec result.c2.c SUCCEEDED '')" '$a + $b')" failed
[[ "$RC" -ne 0 ]] && grep -q "c2.b FAILED RESTORE_FAILED" <<<"$OUT" && ok "gate failed: a FAILED pair fails the run and is named" || bad "gate FAILED" "$OUT"
gate "$(rec result.c2.b TIMEOUT '')" failed
[[ "$RC" -ne 0 ]] && ok "gate failed: a TIMEOUT pair fails the run" || bad "gate TIMEOUT" "$OUT"
gate "$(rec result.c2.b BLOCKED RESTORE_FLAVOUR_UNSUPPORTED)" failed
[[ "$RC" -ne 0 ]] && ok "gate failed: a BLOCKED pair fails the run" || bad "gate BLOCKED" "$OUT"
gate "$(rec result.c2.b FAILED X)"
[[ "$RC" -eq 0 ]] && ok "the gate without the argument still looks at BLOCKED only (the other workflows)" || bad "gate default" "$OUT"

mkdir -p "$TMP/stub"
cat > "$TMP/stub/lib.sh" <<'LIB'
log() { printf '%s\n' "$*" >&2; }
record() { printf 'RECORD %s|%s|%s|%s\n' "$1" "$2" "${3:-}" "${4:-}"; }
result_guard() { :; }
LIB
sed "s#source /scripts/lib.sh#source $TMP/stub/lib.sh#" "$ROOT/workflows/scripts/restore-pair.sh" > "$TMP/stub/pair.sh"
RC=0; OUT="$(P_PAIR='not json' bash "$TMP/stub/pair.sh" wf 2>&1)" || RC=$?
[[ "$RC" -ne 0 ]] && grep -q "INVALID_PAIR" <<<"$OUT" && ok "restore-pair.sh refuses an input that is not a normalized pair" || bad "stub invalid" "$OUT"

echo
echo "restore-map: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
