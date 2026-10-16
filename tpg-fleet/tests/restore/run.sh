#!/usr/bin/env bash
# tpg-restore, one pair (Round 23, phase 6b): workflows/scripts/restore-pair.sh with the real lib.sh,
# clustermap.py (it normalizes every pair), patchcheck.py, the tpg-instance chart (instance_render) and the
# crd-reference chart (the PostgresRestore and the location copy are rendered through it), and stubs for
# everything that leaves the process:
#   - two clusters, c1 (the source) and c2 (the target), as a directory of JSON objects ($TMP/cl/<cluster>/<kind>/<ns>/<name>.json)
#     behind a tk stub that implements get/apply/delete/create/label; the stub plays the operator (a PostgresRestore
#     gets its phase and, for a new target, a Postgres object; a source location copy makes the backups appear)
#     and Argo CD (a selective sync of the shared objects makes the Secrets, of the backup location the location)
#   - the fleet repository as a directory (git_clone copies it, git_commit_push writes the clone back), vault_secret,
#     record/record_entry (files), sleep (moves SECONDS forward), pg_wait_ready, sync_instance_app, backup-instance.sh
# Cases (every refusal and branch of the 10 steps has one):
#   1 plans (dryRun): same namespace, another cluster, every PITR type, the annotation, TARGET_EXISTS for a live target that is not the source; read-only
#   2 the named backup checks (same namespace: BACKUP_NOT_FOUND, BACKUP_NOT_SUCCEEDED; another one: SOURCE_BACKUP_UNVERIFIED)
#   3 the PITR derivation (live, from the source backup, PITR_SOURCE_UNKNOWN, warnings for a given value that differs)
#   4 the matrix (RESTORE_FLAVOUR_UNSUPPORTED, RESTORE_VERSION_LOWER, skipMinorVersionCheck; a higher major version is the operator's to refuse)
#   5 the target (confirm, spec file, namespace, name in use, unknown cluster, owner rules, Secret conflicts)
#   6 the location copy (create, reuse, SOURCE_LOCATION_CONFLICT) and its Secret (Vault, copied; never in a file, log or record)
#   7 real runs: order of the steps, fleet entry, adoption, waits, timeouts, failures, postRestoreBackup, keepSourceLocation
#   8 crashes (UNEXPECTED_ERROR) and the independence of pairs
#   0 (first) the pair shapes: new cluster, same cluster another namespace, a new instance in the source namespace and in place, each with a named
#     backup and every PITR type, with and without a spec file, as a dry run (read-only: no create, apply, patch or delete), with the
#     rendered PostgresRestore and location copy checked; 7e the same shapes (three methods) in real runs; 7f the reasons no other case reaches;
#     7g canary: a failed canary pair exits non-zero and stops the run
#   RESTORE_RENDER_DIR=<dir>: only section 0 runs and the rendered PostgresRestore and PostgresBackupLocation of every shape are left in <dir>
#     (<shape>-<recovery>-<spec>.restore.yaml and .location.yaml); tests/crd-reference checks them against the CRD schemas
# Requires: bash 4, python3, jq, yq (mikefarah), helm; skipped without them.
# shellcheck disable=SC2015,SC2016,SC2030,SC2031
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
for t in python3 jq yq helm; do command -v "$t" >/dev/null || { echo "SKIP tests/restore: $t not installed" >&2; exit 0; }; done
yq --version 2>&1 | grep -q mikefarah || { echo "SKIP tests/restore: yq is not mikefarah yq v4" >&2; exit 0; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { printf 'ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL %s\n' "$1"; [[ -z "${2:-}" ]] || printf '%s\n' "$2" | sed 's/^/       | /' | tail -25; FAIL=$((FAIL + 1)); }

VAULT_KEY='VAULT-ACCOUNT-KEY-0123456789'      # the fleet's storage key in the Vault stub
COPIED='COPIED-SOURCE-SECRET-VALUE-42'         # the contents of the custom Secret of the source location

# ---------------------------------------------------------------- the fleet repository and the clusters
mkdir -p "$TMP/fleet.base/clusters/_template" "$TMP/fleet.base/helm_artifacts/instance"
cp "$ROOT"/clusters/_template/*.yaml "$TMP/fleet.base/clusters/_template/"
cp -r "$ROOT/helm_artifacts/instance/tpg-instance" "$ROOT/helm_artifacts/instance/crd-reference" "$TMP/fleet.base/helm_artifacts/instance/"
RSD="$TMP/fleet.base/helm_artifacts/instance/tpg-instance/restore-specs"
RPD="$TMP/fleet.base/helm_artifacts/instance/tpg-instance/restore-patch"
rm -f "$RPD"/example-*   # the examples of fleet.example.yaml are not part of this fleet
cat > "$TMP/fleet.base/clusters/fleet.yaml" <<'YAML'
clusters:
  c1:
    operator:
      version: v4.5.0
    instances:
      orders-db:
        instance:
          namespace: pg-orders
          postgresVersion: postgres-17.6
          disableInitialBackup: true
        backup:
          repoPath: /pg-orders
        ferret:
          enabled: true
          replicas: 1
      reports-db:
        instance:
          namespace: pg-orders
          postgresVersion: postgres-17.6
          sharedSecretsOwner: false
  c2:
    operator:
      version: v4.5.0
    instances:
      dr-db:
        instance:
          namespace: pg-dr-existing
          postgresVersion: postgres-17.6
YAML
cat > "$RSD/orders-dr.yaml" <<'YAML'
apiVersion: sql.tanzu.vmware.com/v1
kind: Postgres
spec:
  postgresVersion:
    name: postgres-17.6
  storageSize: 50Gi
  highAvailability:
    enabled: false
YAML
cat > "$RSD/orders-lite.yaml" <<'YAML'
apiVersion: sql.tanzu.vmware.com/v1
kind: Postgres
spec:
  postgresVersion:
    name: postgres-17.6-lite
YAML
printf 'apiVersion: sql.tanzu.vmware.com/v1\nkind: Postgres\nspec:\n  postgresVersion:\n    name: %s\n' postgres-17.4 > "$RSD/orders-old.yaml"
printf 'apiVersion: sql.tanzu.vmware.com/v1\nkind: Postgres\nspec:\n  postgresVersion:\n    name: %s\n' postgres-18.1 > "$RSD/orders-18.yaml"
printf 'apiVersion: sql.tanzu.vmware.com/v1\nkind: Postgres\nspec:\n  postgresVersion:\n    name: %s\n' postgres-17.5 > "$RSD/orders-175.yaml"   # its PostgresVersion has the three-part dbVersion 17.5.9
printf 'apiVersion: sql.tanzu.vmware.com/v1\nkind: Postgres\nspec:\n  postgresVersion:\n    name: %s\n' postgres-17.8 > "$RSD/orders-new.yaml"
printf 'apiVersion: sql.tanzu.vmware.com/v1\nkind: Postgres\nspec:\n  postgresVersion:\n    name: %s\n' postgres-16.9 > "$RSD/orders-16.yaml"
printf 'apiVersion: sql.tanzu.vmware.com/v1\nkind: Postgres\nspec:\n  postgresVersion:\n    name: %s\n' postgres-19.0 > "$RSD/orders-nover.yaml"
printf 'apiVersion: sql.tanzu.vmware.com/v1\nkind: Postgres\nspec:\n  postgresVersion:\n    name: postgres-17.6\n  noSuchField: 1\n' > "$RSD/orders-bad.yaml"
printf 'apiVersion: sql.tanzu.vmware.com/v1\nkind: Postgres\nspec:\n  postgresVersion:\n    name: postgres-17.6\n  pgConfig:\n    dbname: orders\n---\napiVersion: sql.tanzu.vmware.com/v1\nkind: Postgres\nspec:\n  storageSize: 5Gi\n' > "$RSD/orders-two.yaml"
printf 'apiVersion: sql.tanzu.vmware.com/v1\nkind: Postgres\nspec:\n  postgresVersion:\n    name: postgres-17.6\n  pgConfig:\n    dbname: orders\n' > "$RSD/orders-extra.yaml"
printf 'apiVersion: sql.tanzu.vmware.com/v1\nkind: Postgres\nspec:\n  postgresVersion:\n    name: postgres-17.6\n  backupLocation:\n    name: shared-location\n' > "$RSD/orders-loc.yaml"
printf 'apiVersion: sql.tanzu.vmware.com/v1\nkind: Postgres\nspec:\n  postgresVersion:\n    name: postgres-17.6\n' > "$RSD/legacy.yaml"
# a spec file that names the copy of the source backup location by its fixed name (restore-src-<cluster>-<namespace>-<instance>)
printf 'apiVersion: sql.tanzu.vmware.com/v1\nkind: Postgres\nspec:\n  postgresVersion:\n    name: postgres-17.6\n  backupLocation:\n    name: restore-src-c1-pg-orders-orders-db\n' > "$RSD/orders-copyloc.yaml"

# seed CLUSTER KIND NAMESPACE NAME JSON: an object of the fake cluster base state ("_" for cluster-scoped kinds)
mkdir -p "$TMP/cl.base"
seed() { mkdir -p "$TMP/cl.base/$1/$2/$3"; printf '%s' "$5" > "$TMP/cl.base/$1/$2/$3/$4.json"; }
mkdir -p "$TMP/cl.base/c1" "$TMP/cl.base/c2"
for c in c1 c2; do
  for v in 16.9:postgres-16.9 17.4:postgres-17.4 17.5.9:postgres-17.5 17.6:postgres-17.6 17.6:postgres-17.6-lite 17.8:postgres-17.8 18.1:postgres-18.1; do
    seed "$c" postgresversion _ "${v#*:}" "$(jq -cn --arg n "${v#*:}" --arg d "${v%%:*}" '{kind: "PostgresVersion", metadata: {name: $n}, spec: {dbVersion: $d}}')"
  done
done
TRACK='tpg-c1-orders-db:sql.tanzu.vmware.com/Postgres:pg-orders/orders-db'
seed c1 postgres pg-orders orders-db '{"kind":"Postgres","metadata":{"name":"orders-db","namespace":"pg-orders"},"spec":{"postgresVersion":{"name":"postgres-17.6"},"backupLocation":{"name":"orders-db-backup-location"}},"status":{"currentState":"Running","stanzaName":"pg-orders-orders-db-0000"}}'
seed c1 postgresbackuplocation pg-orders orders-db-backup-location '{"kind":"PostgresBackupLocation","metadata":{"name":"orders-db-backup-location","namespace":"pg-orders"},"spec":{"storage":{"azure":{"container":"pg-backups-c1","repoPath":"/pg-orders","endpoint":"blob.core.windows.net","keyType":"shared","enableSSL":true,"caBundle":"-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----","secret":{"name":"backup-storage"}}},"backupSync":{"enabled":true}}}'
for b in "orders-full-1:Succeeded" "orders-failed:Failed" "orders-running:Running"; do
  seed c1 postgresbackup pg-orders "${b%%:*}" "$(jq -cn --arg n "${b%%:*}" --arg p "${b#*:}" '{kind: "PostgresBackup", metadata: {name: $n, namespace: "pg-orders"}, spec: {sourceInstance: {name: "orders-db"}, type: "full"},
    status: {phase: $p, restoreLabel: "20200101-000000F", timeStarted: "2020-01-01T00:00:00Z", backupLocation: "orders-db-backup-location", stanzaName: "pg-orders-orders-db-0000"}}')"
done
# backups that report the version they were taken from (status.fullPostgresVersion)
for b in "orders-full-v174:17.4" "orders-full-v178:17.8"; do
  seed c1 postgresbackup pg-orders "${b%%:*}" "$(jq -cn --arg n "${b%%:*}" --arg v "${b#*:}" '{kind: "PostgresBackup", metadata: {name: $n, namespace: "pg-orders"}, spec: {sourceInstance: {name: "orders-db"}, type: "full"},
    status: {phase: "Succeeded", fullPostgresVersion: $v, restoreLabel: "20200103-000000F", timeStarted: "2020-01-03T00:00:00Z", backupLocation: "orders-db-backup-location", stanzaName: "pg-orders-orders-db-0000"}}')"
done
seed c1 postgresbackup pg-orders other-inst-full '{"kind":"PostgresBackup","metadata":{"name":"other-inst-full","namespace":"pg-orders"},"spec":{"sourceInstance":{"name":"reports-db"},"type":"full"},"status":{"phase":"Succeeded","restoreLabel":"20200102-000000F","timeStarted":"2020-01-02T00:00:00Z","backupLocation":"orders-db-backup-location","stanzaName":"pg-orders-reports-db-0000"}}'
for s in regsecret backup-storage; do
  seed c1 secret pg-orders "$s" "$(jq -cn --arg n "$s" --arg t "$TRACK" '{kind: "Secret", metadata: {name: $n, namespace: "pg-orders", annotations: {"argocd.argoproj.io/tracking-id": $t}}, data: {accountKey: ("'"$VAULT_KEY"'" | @base64)}}')"
done
# a legacy source (not in clusters/fleet.yaml, not a backup-storage location): its own Secret
seed c1 postgres pg-legacy legacy-db '{"kind":"Postgres","metadata":{"name":"legacy-db","namespace":"pg-legacy"},"spec":{"postgresVersion":{"name":"postgres-17.6"},"backupLocation":{"name":"legacy-loc"}},"status":{"currentState":"Running","stanzaName":"legacy-stanza"}}'
seed c1 postgresbackuplocation pg-legacy legacy-loc '{"kind":"PostgresBackupLocation","metadata":{"name":"legacy-loc","namespace":"pg-legacy"},"spec":{"storage":{"azure":{"container":"legacy-container","repoPath":"/legacy","secret":{"name":"src-creds"}}}}}'
seed c1 secret pg-legacy src-creds "$(jq -cn '{kind: "Secret", metadata: {name: "src-creds", namespace: "pg-legacy"}, type: "Opaque", data: {accountName: ("legacyacct" | @base64), accountKey: ("'"$COPIED"'" | @base64)}}')"
seed c1 postgresbackup pg-legacy legacy-full-1 '{"kind":"PostgresBackup","metadata":{"name":"legacy-full-1","namespace":"pg-legacy"},"spec":{"sourceInstance":{"name":"legacy-db"},"type":"full"},"status":{"phase":"Succeeded","restoreLabel":"20200101-000000F","timeStarted":"2020-01-01T00:00:00Z","backupLocation":"legacy-loc","stanzaName":"legacy-stanza"}}'
# a second legacy source: another container, but its location uses a Secret of the same name (src-creds) with other contents
COPIED2='COPIED-SECOND-SOURCE-SECRET-77'
seed c1 postgres pg-legacy2 legacy2-db '{"kind":"Postgres","metadata":{"name":"legacy2-db","namespace":"pg-legacy2"},"spec":{"postgresVersion":{"name":"postgres-17.6"},"backupLocation":{"name":"legacy2-loc"}},"status":{"currentState":"Running","stanzaName":"legacy2-stanza"}}'
seed c1 postgresbackuplocation pg-legacy2 legacy2-loc '{"kind":"PostgresBackupLocation","metadata":{"name":"legacy2-loc","namespace":"pg-legacy2"},"spec":{"storage":{"azure":{"container":"legacy2-container","repoPath":"/legacy2","secret":{"name":"src-creds"}}}}}'
seed c1 secret pg-legacy2 src-creds "$(jq -cn '{kind: "Secret", metadata: {name: "src-creds", namespace: "pg-legacy2"}, type: "Opaque", data: {accountName: ("legacy2acct" | @base64), accountKey: ("'"$COPIED2"'" | @base64)}}')"
seed c1 postgresbackup pg-legacy2 legacy2-full-1 '{"kind":"PostgresBackup","metadata":{"name":"legacy2-full-1","namespace":"pg-legacy2"},"spec":{"sourceInstance":{"name":"legacy2-db"},"type":"full"},"status":{"phase":"Succeeded","restoreLabel":"20200101-000000F","timeStarted":"2020-01-01T00:00:00Z","backupLocation":"legacy2-loc","stanzaName":"legacy2-stanza"}}'
# a source whose instance is gone but whose backup and location are still there
seed c1 postgresbackup pg-gone gone-full-1 '{"kind":"PostgresBackup","metadata":{"name":"gone-full-1","namespace":"pg-gone"},"spec":{"sourceInstance":{"name":"gone-db"},"type":"full"},"status":{"phase":"Succeeded","restoreLabel":"20200101-000000F","timeStarted":"2020-01-01T00:00:00Z","backupLocation":"gone-loc","stanzaName":"gone-stanza"}}'
seed c1 postgresbackuplocation pg-gone gone-loc '{"kind":"PostgresBackupLocation","metadata":{"name":"gone-loc","namespace":"pg-gone"},"spec":{"storage":{"azure":{"container":"gone-container","repoPath":"/gone","secret":{"name":"backup-storage"}}}}}'
# …and one that reports no backup location at all (nothing to copy for another namespace or cluster)
seed c1 postgresbackup pg-gone gone-noloc '{"kind":"PostgresBackup","metadata":{"name":"gone-noloc","namespace":"pg-gone"},"spec":{"sourceInstance":{"name":"gone-db"},"type":"full"},"status":{"phase":"Succeeded","restoreLabel":"20200101-000000F","timeStarted":"2020-01-01T00:00:00Z"}}'
# c2: an existing target in a fleet namespace
seed c2 postgres pg-dr-existing dr-db '{"kind":"Postgres","metadata":{"name":"dr-db","namespace":"pg-dr-existing"},"spec":{"postgresVersion":{"name":"postgres-17.6"}},"status":{"currentState":"Running","stanzaName":"pg-dr-existing-dr-db-0000"}}'
for s in regsecret backup-storage; do
  seed c2 secret pg-dr-existing "$s" "$(jq -cn --arg n "$s" '{kind: "Secret", metadata: {name: $n, namespace: "pg-dr-existing", annotations: {"argocd.argoproj.io/tracking-id": "tpg-c2-dr-db:x"}}, data: {accountKey: ("'"$VAULT_KEY"'" | @base64)}}')"
done

# ---------------------------------------------------------------- the stubs (sourced after the real lib.sh)
cat > "$TMP/prelude.tmpl" <<'PRELUDE'
export TPG_WORK="@TMP@/work" INSTANCE_NS_OVERRIDE=""
source "@ROOT@/workflows/scripts/lib.sh"
FLEETREPO="@TMP@/fleet.repo"; CLD="@TMP@/cl"; FLAGS="@TMP@/flags"; EV="@TMP@/events"; REC="@TMP@/rec"
ev() { printf '%s\n' "$*" >> "$EV"; }
flag() { [[ -e "$FLAGS/$1" ]]; }
flagval() { cat "$FLAGS/$1" 2>/dev/null || true; }
sleep() { SECONDS=$((SECONDS + ${1:-1})); }
record() {
  mkdir -p "$REC"; printf '%s' "$2" > "$REC/$1.status"; printf '%s' "${3:-}" > "$REC/$1.reason"; printf '%s' "${4:-}" > "$REC/$1.detail"
  printf '%s|%s|%s|%s\n' "$1" "$2" "${3:-}" "$(tr '\n' ' ' <<<"${4:-}")" >> "@TMP@/records"; RESULT_RECORDED=1
}
record_entry() {
  mkdir -p "$REC"; printf '%s' "$2" > "$REC/$1.status"; printf '%s' "${3:-}" > "$REC/$1.reason"; printf '%s' "${4:-}" > "$REC/$1.detail"
  printf '%s|%s|%s|%s\n' "$1" "$2" "${3:-}" "$(tr '\n' ' ' <<<"${4:-}")" >> "@TMP@/records"
}
run_data() { [[ -f "$REC/$1.status" ]] || return 0; jq -cn --arg s "$(cat "$REC/$1.status")" --arg r "$(cat "$REC/$1.reason")" --arg d "$(cat "$REC/$1.detail")" '{status: $s, reason: $r, detail: $d}'; }
use_cluster() { [[ -d "$CLD/$1" ]] || return 1; CLUSTER="$1"; }
git_clone() { flag clone.fail && return 1; rm -rf "$1"; mkdir -p "$(dirname "$1")"; cp -r "$FLEETREPO" "$1"; }
git_commit_push() {
  ev "push mode=${PUSH_MODE} $2"
  flag push.fail && return 1
  if flag push.failfrom && (( $(grep -c '^push' "$EV") >= $(flagval push.failfrom) )); then return 1; fi
  cp "$1/clusters/fleet.yaml" "$FLEETREPO/clusters/fleet.yaml"
  # the restore-patch files of the clone (new, and the deletion of the one that fell out of the window)
  if [[ -d "$1/helm_artifacts/instance/tpg-instance/restore-patch" ]]; then
    rm -rf "$FLEETREPO/helm_artifacts/instance/tpg-instance/restore-patch"; cp -r "$1/helm_artifacts/instance/tpg-instance/restore-patch" "$FLEETREPO/helm_artifacts/instance/tpg-instance/restore-patch"
  fi
  # another writer's entry that arrives with ours (the owner conflict of two pull requests)
  if flag push.race; then yq -i '.clusters.c2.instances."'"$(flagval push.race)"'".instance = {"namespace": "pg-dr-new", "postgresVersion": "postgres-17.6"}' "$FLEETREPO/clusters/fleet.yaml"; cp "$FLEETREPO/clusters/fleet.yaml" "$1/clusters/fleet.yaml"; fi
  PUSHED_REVISION="rev-$(date +%s%N)"
}
fleet_lock_acquire() { ev "lock acquire"; }
fleet_lock_release() { ev "lock release"; }
fleet_head() { printf 'head0001'; }
appset_refresh() { ev "appset refresh $1"; }
app_exists() { ! flag app.missing; }
sync_instance_app() { ev "adopt $1 $2"; SYNC_FAIL_REASON=SYNC_FAILED; SYNC_FAIL_DETAIL="stub"; ! flag adopt.fail; }
pg_wait_ready() {
  ev "wait ready $1"
  if flag target.notrunning; then POD_WATCH_REASON=CRASHLOOP; POD_WATCH_DETAIL="pod $1-0 CrashLoopBackOff"; return 1; fi
  return 0
}
vault_secret() { flag vault.fail && return 1; case "$2" in accountName) printf 'vaultacct' ;; accountKey) printf '%s' "@VAULT_KEY@" ;; esac; }
# Argo CD: a selective sync creates what the owner's Application would render
app_sync_wait() {
  local app="$1" res="" ns n o
  shift 2
  while [[ $# -gt 0 ]]; do case "$1" in --resources) res="$2"; shift 2 ;; --pods) shift 3 ;; *) shift 2 ;; esac; done
  ev "sync ${app} resources=${res}"
  flag sync.fail && { SYNC_FAIL_REASON=SYNC_FAILED; SYNC_FAIL_DETAIL="stub sync failure"; return 1; }
  IFS=, read -ra o <<<"$res"
  for n in "${o[@]}"; do
    ns="${n#*:*:}"; ns="${ns%%/*}"
    case "$n" in
      *VaultStaticSecret:*/regsecret|*VaultStaticSecret:*/backup-storage)
        flag sync.nosecret && continue
        local s="${n##*/}" a="${app}"
        mkdir -p "$CLD/$CLUSTER/secret/$ns"
        jq -cn --arg n "$s" --arg ns "$ns" --arg a "$a" '{kind: "Secret", metadata: {name: $n, namespace: $ns, annotations: {"argocd.argoproj.io/tracking-id": ($a + ":x")}}, data: {accountKey: ("@VAULT_KEY@" | @base64)}}' > "$CLD/$CLUSTER/secret/$ns/$s.json" ;;
      *PostgresBackupLocation:*)
        local l="${n##*/}"
        mkdir -p "$CLD/$CLUSTER/postgresbackuplocation/$ns"
        jq -cn --arg n "$l" --arg ns "$ns" '{kind: "PostgresBackupLocation", metadata: {name: $n, namespace: $ns}, spec: {storage: {azure: {container: "pg-backups", repoPath: ("/" + $ns + "/x")}}}}' > "$CLD/$CLUSTER/postgresbackuplocation/$ns/$l.json" ;;
    esac
  done
  return 0
}
tk() {
  local ns="" all=false out="" ignore=false file="" pos=() d f body json k nm nsx
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n) ns="$2"; shift 2 ;;
      -A) all=true; shift ;;
      -o) out="$2"; shift 2 ;;
      -f) file="$2"; shift 2 ;;
      --ignore-not-found) ignore=true; shift ;;
      --*|-*) shift ;;
      *) pos+=("$1"); shift ;;
    esac
  done
  local verb="${pos[0]:-}" kind="${pos[1]:-}" name="${pos[2]:-}"
  [[ ! -e "$FLAGS/tkfail.${CLUSTER}.${kind}" ]] || { echo "Error from server (Forbidden): ${kind} is forbidden: User cannot list" >&2; return 1; }
  # a list of one namespace (no name, no -A) that fails, while the reads by name and the cluster-wide lists work
  [[ "$verb" != get || -n "$name" || "$all" == true || ! -e "$FLAGS/tkfail.nslist.${CLUSTER}.${kind}" ]] || { echo "Error from server (Forbidden): ${kind} is forbidden: User cannot list in ${ns}" >&2; return 1; }
  case "$verb" in
    get)
      d="$CLD/$CLUSTER/$kind/${ns:-_}"
      if [[ -n "$name" ]]; then
        f="$d/$name.json"
        if [[ -f "$f" ]]; then
          if [[ "$out" == jsonpath* ]]; then jq -c '.metadata' "$f"; else cat "$f"; fi
        elif [[ "$ignore" == true ]]; then :
        else echo "Error from server (NotFound): ${kind} \"${name}\" not found" >&2; return 1; fi
      elif [[ "$kind" == crd || "$kind" == pods ]]; then return 0
      else
        if [[ "$all" == true ]]; then set -- "$CLD/$CLUSTER/$kind"/*/*.json; else set -- "$d"/*.json; fi
        if [[ -f "${1:-}" ]]; then jq -s '{items: .}' "$@"; else echo '{"items":[]}'; fi
      fi ;;
    apply)
      if [[ -n "$file" && "$file" != - ]]; then body="$(cat "$file")"; else body="$(cat)"; fi
      json="$(printf '%s' "$body" | yq -o=json -I=0 '.')"
      k="$(jq -r '.kind | ascii_downcase' <<<"$json")"; nm="$(jq -r '.metadata.name' <<<"$json")"
      nsx="$(jq -r '.metadata.namespace // empty' <<<"$json")"; nsx="${nsx:-$ns}"
      case "$k" in namespace|postgresversion) nsx="_" ;; esac
      ev "apply ${CLUSTER} ${k} ${nsx}/${nm}"
      case "$k" in vaultstaticsecret|serviceaccount) ev "APPLIED-SHARED ${k} ${nsx}/${nm}" ;; esac
      [[ ! -e "$FLAGS/apply.fail.${k}" ]] || { echo "Error from server (Invalid): ${k} ${nm} is invalid" >&2; return 1; }
      mkdir -p "$CLD/$CLUSTER/$k/$nsx"
      printf '%s' "$json" | jq --arg ns "$nsx" 'if $ns == "_" then . else .metadata.namespace = $ns end' > "$CLD/$CLUSTER/$k/$nsx/$nm.json"
      case "$k" in
        postgresrestore)
          local phase; phase="$(flagval restore.phase)"; phase="${phase:-Succeeded}"
          jq --arg p "$phase" '.status = {phase: $p, conditions: (if $p == "Failed" then [{message: "restore pod failed: stub"}] else [] end)}' "$CLD/$CLUSTER/$k/$nsx/$nm.json" > "$CLD/$CLUSTER/$k/$nsx/$nm.tmp" && mv "$CLD/$CLUSTER/$k/$nsx/$nm.tmp" "$CLD/$CLUSTER/$k/$nsx/$nm.json"
          local ti; ti="$(jq -r '.spec.targetInstance.name' "$CLD/$CLUSTER/$k/$nsx/$nm.json")"
          if [[ "$(jq -r '.spec.targetInstance.spec // empty' "$CLD/$CLUSTER/$k/$nsx/$nm.json")" != "" ]]; then
            mkdir -p "$CLD/$CLUSTER/postgres/$nsx"
            jq '{kind: "Postgres", metadata: {name: .spec.targetInstance.name, namespace: .metadata.namespace}, spec: .spec.targetInstance.spec, status: {currentState: "Running", stanzaName: "s"}}' "$CLD/$CLUSTER/$k/$nsx/$nm.json" > "$CLD/$CLUSTER/postgres/$nsx/$ti.json"
          elif [[ ! -f "$CLD/$CLUSTER/postgres/$nsx/$ti.json" ]] && ! flag snap.gone; then
            # no spec file: the operator creates the instance and fills in its spec (what it adds is the operator's: a runtime-looking
            # metadata and status, a null field)
            mkdir -p "$CLD/$CLUSTER/postgres/$nsx"
            jq -n --arg n "$ti" --arg ns "$nsx" --argjson extra "${SNAP_EXTRA:-{\}}" '{kind: "Postgres",
              metadata: {name: $n, namespace: $ns, uid: "u-1", resourceVersion: "77", managedFields: [{manager: "postgres-operator"}], annotations: {"kubectl.kubernetes.io/last-applied-configuration": "x"}},
              spec: ({postgresVersion: {name: "postgres-17.6"}, storageClassName: "operator-default", storageSize: "20Gi", highAvailability: {enabled: true, readReplicas: 1},
                backupLocation: {name: "restore-src-location"}, imagePullSecret: {name: "regsecret"}, logLevel: "Debug", certificateSecretName: null} + $extra),
              status: {currentState: "Running", stanzaName: "s", dbVersion: "17.6"}}' > "$CLD/$CLUSTER/postgres/$nsx/$ti.json"
          fi ;;
        postgresbackuplocation)
          if [[ "$(jq -r '.metadata.annotations["tpg.fleet/created-by"] // empty' "$CLD/$CLUSTER/$k/$nsx/$nm.json")" != "" && -s "$FLAGS/sync.names" ]]; then
            local bn
            for bn in $(cat "$FLAGS/sync.names"); do
              case "$(flagval sync.mode)" in never) continue ;; failed) phase=Failed ;; running) phase=Running ;; *) phase=Succeeded ;; esac
              mkdir -p "$CLD/$CLUSTER/postgresbackup/$nsx"
              jq -cn --arg n "$bn" --arg ns "$nsx" --arg p "$phase" '{kind: "PostgresBackup", metadata: {name: $n, namespace: $ns, labels: {"sql.tanzu.vmware.com/recovered-from-backuplocation": "true"}}, status: {phase: $p}}' > "$CLD/$CLUSTER/postgresbackup/$nsx/$bn.json"
            done
          fi ;;
      esac ;;
    create)
      ev "create ${CLUSTER} ${kind} ${name}"
      [[ "$kind" == namespace ]] && printf 'apiVersion: v1\nkind: Namespace\nmetadata:\n  name: %s\n' "$name" ;;
    patch) ev "patch ${CLUSTER} ${kind} ${ns}/${name}" ;;
    label) ev "label ${CLUSTER} ${kind} ${name}" ;;
    delete)
      ev "delete ${CLUSTER} ${kind} ${ns}/${name}"
      [[ ! -e "$FLAGS/delete.fail.${kind}" ]] || { echo "Error from server (Forbidden): ${kind} ${name} cannot be deleted" >&2; return 1; }
      rm -f "$CLD/$CLUSTER/$kind/${ns:-_}/$name.json" ;;
    *) return 0 ;;
  esac
}
PRELUDE
sed -e "s#@TMP@#$TMP#g" -e "s#@ROOT@#$ROOT#g" -e "s#@VAULT_KEY@#$VAULT_KEY#g" "$TMP/prelude.tmpl" > "$TMP/prelude.sh"
# backup-instance.sh stub (the post-restore backup): records the call and a result under RESULT_KEY
cat > "$TMP/backup-instance.sh" <<STUB
#!/usr/bin/env bash
printf 'backup %s\n' "\$*" >> "$TMP/events"
mkdir -p "$TMP/rec"
st=SUCCEEDED; [[ -e "$TMP/flags/backup.fail" ]] && st=FAILED
printf '%s' "\$st" > "$TMP/rec/\${RESULT_KEY}.status"; printf '' > "$TMP/rec/\${RESULT_KEY}.reason"; printf 'stub backup' > "$TMP/rec/\${RESULT_KEY}.detail"
STUB
sed -e "s#source /scripts/lib.sh#source $TMP/prelude.sh#" -e "s#bash /scripts/backup-instance.sh#bash $TMP/backup-instance.sh#" \
  "$ROOT/workflows/scripts/restore-pair.sh" > "$TMP/restore-pair.sh"

# ---------------------------------------------------------------- helpers
CM="$ROOT/workflows/scripts/clustermap.py"
yq -o=json -I=0 '.' "$ROOT/workflows/params/cluster-map-keys.yaml" > "$TMP/keys.json"
printf 'c1\nc2\n' > "$TMP/registered"
side() {  # side CLUSTER NS INSTANCE KEYS
  printf '    %s:\n      %s:\n        %s:' "$1" "$2" "$3"
  if [[ -z "$4" ]]; then printf ' {}\n'; else printf '\n'; printf '%s\n' "$4" | sed 's/^/          /'; fi
}
mk() {  # mk 'c/ns/inst' 'source keys' 'c/ns/inst' 'target keys' [--confirm-required]: the normalized pair in $PJ
  local s t; IFS=/ read -ra s <<<"$1"; IFS=/ read -ra t <<<"$3"
  { printf -- '- sourceClusterConfig:\n'; side "${s[0]}" "${s[1]}" "${s[2]}" "$2"; printf '  targetClusterConfig:\n'; side "${t[0]}" "${t[1]}" "${t[2]}" "$4"; } \
    | yq -o=json -I=0 '(.. | select(tag == "!!float")) tag = "!!str"' > "$TMP/in.json"
  python3 "$CM" restore --map "$TMP/in.json" --keys "$TMP/keys.json" --registered "$TMP/registered" --out "$TMP/out.json" >"$TMP/mk.err" 2>&1 \
    || { echo "mk: clustermap.py refused the pair: $(cat "$TMP/mk.err")" >&2; return 1; }
  PJ="$(jq -c '.[0]' "$TMP/out.json")"
}
reset() {
  rm -rf "$TMP/cl" "$TMP/flags" "$TMP/rec" "$TMP/work" "$TMP/fleet.repo"; mkdir -p "$TMP/flags" "$TMP/rec"
  cp -r "$TMP/cl.base" "$TMP/cl"; cp -r "$TMP/fleet.base" "$TMP/fleet.repo"; : > "$TMP/events"; : > "$TMP/records"
}
set_flag() { mkdir -p "$TMP/flags"; printf '%s' "${2:-1}" > "$TMP/flags/$1"; }
run() {  # run PAIR_JSON [VAR=VALUE...]: restore-pair.sh; OUT, RC. P_DRY_RUN defaults to true
  rm -rf "$TMP/work"
  RC=0; OUT="$(cd "$TMP" && env P_DRY_RUN=true P_TIMEOUT=100 P_PR_TIMEOUT=10 "${@:2}" P_PAIR="$1" bash "$TMP/restore-pair.sh" tpg-restore-x 2>&1)" || RC=$?
  RUN_N=$((RUN_N + 1)); [[ "${SHOW_RUN:-}" != list ]] || printf 'run %s: %s dry=%s\n' "$RUN_N" "$(jq -r '.label' <<<"$1")" "$(grep -o 'P_DRY_RUN=[a-z]*' <<<"$*" | tail -1)" >&2
  [[ "$RUN_N" != "${SHOW_RUN:-0}" ]] || { printf '%s\n' "$OUT" | sed 's/^/  > /' >&2; sed 's/^/  ev> /' "$TMP/events" >&2; }   # SHOW_RUN=N prints the log of the Nth run
}
RUN_N=0
RK=""
st() { cat "$TMP/rec/result.$RK.status" 2>/dev/null || true; }
reason() { cat "$TMP/rec/result.$RK.reason" 2>/dev/null || true; }
detail() { cat "$TMP/rec/result.$RK.detail" 2>/dev/null || true; }
expect() {  # expect LABEL STATUS REASON [TEXT...]: the result record of the pair (RK), and the TEXT in its detail
  local t
  if [[ "$(st)" != "$2" || "$(reason)" != "$3" ]]; then bad "$1 (got $(st)/$(reason), want $2/$3)" "$(detail)
$(tail -12 <<<"$OUT")"; return; fi
  for t in "${@:4}"; do grep -qF -- "$t" <<<"$(detail)" || { bad "$1 (no '$t' in the detail)" "$(detail)"; return; }; done
  ok "$1"
}
ev_has() { grep -qE -- "$1" "$TMP/events"; }
plan_block() {  # plan_block HEADER_REGEX -> the YAML block that follows the plan line (6 spaces of indent) of the plan record
  awk -v h="$1" '$0 ~ h {f=1; next} f && /^      / {sub(/^      /, ""); print; next} f {exit}' "$TMP/rec/plan.restore.${RKP:-$RK}.detail" 2>/dev/null | sed 's/^result\.//' || true
}
restore_yaml() { plan_block 'PostgresRestore .* on '; }
snapshot() { (cd "$TMP/cl" && find . -type f | sort | xargs cat | sha256sum | cut -c1-16; sha256sum < "$TMP/fleet.repo/clusters/fleet.yaml" | cut -c1-16) | paste -sd' ' -; }
nothing_changed() {  # nothing_changed LABEL SNAPSHOT_BEFORE: the clusters, the fleet repository and the Argo CD calls are as they were
  local after; after="$(snapshot)"
  if [[ "$after" == "$2" ]] && ! grep -qE '^(apply|push|sync|adopt|delete|label|lock|create|patch)' "$TMP/events"; then ok "$1: read-only (no object created, applied, patched or deleted, nothing pushed, no Argo CD call)"
  else bad "$1: read-only" "before $2 after $after
$(cat "$TMP/events")"; fi
}
no_secret_leak() {  # no_secret_leak LABEL VALUE...: the values are in no file outside the fake clusters, no record, no log
  local v bad_in=""
  for v in "$@"; do
    grep -rqF -- "$v" "$TMP/records" "$TMP/rec" "$TMP/events" "$TMP/work" 2>/dev/null && bad_in="$bad_in records/work"
    grep -qF -- "$v" <<<"$OUT" && bad_in="$bad_in log"
    grep -rlF -- "$v" "$TMP" --exclude-dir=cl --exclude-dir=cl.base --exclude=prelude.sh --exclude=prelude.tmpl --exclude=restore-pair.sh 2>/dev/null | grep -q . && bad_in="$bad_in files"
  done
  [[ -z "$bad_in" ]] && ok "$1: no secret value in a file, a record, an argument list or the log" || bad "$1: a secret value leaked into:$bad_in" "$(grep -rlF -- "${1}" "$TMP" 2>/dev/null | head)"
}

# the usual pairs
ORDERS_BACKUP='sourceBackupName: orders-full-1'
BACKUP_T='pitrEnabled: false'
LATEST=$'pitrEnabled: true\npitrConfig:\n  type: latest'
SPECF='targetInstanceSpecFilePath: [repo:helm_artifacts/instance/tpg-instance/restore-specs/legacy.yaml]'

echo "== 0. the pair shapes: where it restores x the recovery point x spec file (dry run, read-only), rendered objects checked"
SHAPES="${RESTORE_RENDER_DIR:-$TMP/shapes}"; mkdir -p "$SHAPES"
COPYN=restore-src-c1-pg-orders-orders-db      # the copy of the source backup location (fixed name) in another namespace or cluster
declare -A SH_TGT=([newcluster]=c2/pg-dr/orders-dr [othernamespace]=c1/pg-orders-dr/orders-dr [samenamespace]=c1/pg-orders/orders-copy [inplace]=c1/pg-orders/orders-db)
declare -A REC_TGT=([backup]="$BACKUP_T" [latest]="$LATEST"
  [time]=$'pitrEnabled: true\nbestEffort: true\npitrConfig:\n  type: time\n  timestamp: 2024-06-01T00:00:00Z'
  [lsn]=$'pitrEnabled: true\nbestEffort: false\npitrConfig:\n  type: lsn\n  target: 0/3000060'
  [transaction]=$'pitrEnabled: true\nbestEffort: true\npitrConfig:\n  type: transaction\n  target: "987654"')
SPEC_ORDERS='targetInstanceSpecFilePath: [repo:helm_artifacts/instance/tpg-instance/restore-specs/orders-dr.yaml]'
shape_pair() {  # shape_pair SHAPE RECOVERY SPEC(spec|nospec): PJ, T (cluster, namespace, instance of the target), RK, RKP
  local tkeys="${REC_TGT[$2]}" skeys=""
  [[ "$2" != backup ]] || skeys="$ORDERS_BACKUP"
  [[ "$1" != inplace ]] || tkeys+=$'\nconfirm: orders-db'
  [[ "$3" != spec ]] || tkeys+=$'\n'"$SPEC_ORDERS"
  mk c1/pg-orders/orders-db "$skeys" "${SH_TGT[$1]}" "$tkeys"
  IFS=/ read -ra T <<<"${SH_TGT[$1]}"; RK="${T[0]}.${T[2]}"; RKP="$RK"
}
shape_check() {  # shape_check TAG SHAPE RECOVERY SPEC Y C: the rendered PostgresRestore (Y) and location copy (C) say what the shape and the recovery point say
  local tag="$1" shape="$2" kind="$3" spec="$4" y="$5" c="$6" why="" want_loc="$COPYN" p
  case "$shape" in samenamespace|inplace) want_loc=orders-db-backup-location ;; esac
  [[ "$(yq '.kind' <<<"$y")" == PostgresRestore && "$(yq '.spec.targetInstance.name' <<<"$y")" == "${T[2]}" ]] || why+=" kind or targetInstance.name;"
  [[ "$(yq '.spec.targetInstance | has("spec")' <<<"$y")" == "$([[ "$spec" == spec ]] && echo true || echo false)" ]] || why+=" targetInstance.spec only with a spec file;"
  if [[ "$spec" == spec ]]; then [[ "$(yq '.spec.targetInstance.spec.storageSize' <<<"$y")" == 50Gi ]] || why+=" the spec file's storageSize;"; fi
  if [[ "$kind" == backup ]]; then
    [[ "$(yq '.spec.sourceBackup.name' <<<"$y")" == orders-full-1 && "$(yq '.spec | has("pitr")' <<<"$y")" == false ]] || why+=" spec.sourceBackup.name without pitr;"
  else
    p='.spec.pitr'
    [[ "$(yq "$p.type" <<<"$y")" == "$kind" && "$(yq '.spec | has("sourceBackup")' <<<"$y")" == false \
       && "$(yq "$p.sourceBackupLocation.stanzaName" <<<"$y")" == pg-orders-orders-db-0000 && "$(yq "$p.sourceBackupLocation.name" <<<"$y")" == "$want_loc" ]] \
      || why+=" spec.pitr type, repository ($want_loc) or stanza, or a sourceBackup next to it;"
    case "$kind" in
      latest) [[ "$(yq "$p | has(\"bestEffort\") or has(\"timestamp\") or has(\"target\")" <<<"$y")" == false ]] || why+=" latest carries bestEffort, timestamp or target;" ;;
      time) [[ "$(yq "$p.timestamp" <<<"$y")" == 2024-06-01T00:00:00Z && "$(yq "$p.bestEffort" <<<"$y")" == true ]] || why+=" time: timestamp, bestEffort;" ;;
      lsn) [[ "$(yq "$p.target" <<<"$y")" == 0/3000060 && "$(yq "$p | has(\"bestEffort\")" <<<"$y")" == false ]] || why+=" lsn: target (bestEffort false is a zero default);" ;;
      transaction) [[ "$(yq "$p.target" <<<"$y")" == 987654 && "$(yq "$p.bestEffort" <<<"$y")" == true ]] || why+=" transaction: target, bestEffort;" ;;
    esac
  fi
  case "$shape" in
    newcluster|othernamespace) [[ "$(yq '.kind' <<<"$c")" == PostgresBackupLocation && "$(yq '.metadata.name' <<<"$c")" == "$COPYN" && "$(yq '.spec.backupSync.enabled' <<<"$c")" == true ]] \
        || why+=" the location copy ($COPYN, backupSync on);" ;;
    *) [[ -z "$c" ]] || why+=" a location copy although the namespace is the source's;" ;;
  esac
  [[ -z "$why" ]] && ok "$tag: the PostgresRestore says $( [[ "$kind" == backup ]] && echo "sourceBackup" || echo "pitr $kind" ), targetInstance ${T[2]}$( [[ "$spec" == spec ]] && echo " with the spec file's spec" ), $( [[ -n "$c" ]] && echo "the location copy is rendered" || echo "no location copy" )" \
    || bad "$tag:$why" "$y
$c"
}
for shape in newcluster othernamespace samenamespace inplace; do
  reset
  for kind in backup latest time lsn transaction; do
    for spec in nospec spec; do
      tag="$shape $kind $spec"
      shape_pair "$shape" "$kind" "$spec"
      snap="$(snapshot)"; run "$PJ"
      if [[ "$(st)" == SUCCEEDED && "$(reason)" == DRY_RUN ]]; then
        Y="$(restore_yaml)"; C="$(plan_block 'PostgresBackupLocation .* on ')"
        printf '%s\n' "$Y" > "$SHAPES/${shape}-${kind}-${spec}.restore.yaml"
        [[ -z "$C" ]] || printf '%s\n' "$C" > "$SHAPES/${shape}-${kind}-${spec}.location.yaml"
        shape_check "$tag" "$shape" "$kind" "$spec" "$Y" "$C"
      else bad "$tag: dry run (got $(st)/$(reason), want SUCCEEDED/DRY_RUN)" "$(detail)
$(tail -8 <<<"$OUT")"; fi
      nothing_changed "$tag" "$snap"
    done
  done
done
if [[ -n "${RESTORE_RENDER_DIR:-}" ]]; then
  echo; echo "tests/restore (render only): ${PASS} passed, ${FAIL} failed; the rendered objects are in ${RESTORE_RENDER_DIR}"
  [[ "$FAIL" -eq 0 ]]; exit
fi

echo "== 1. plans: dryRun records the plan and changes nothing"
reset
RK=c1.orders-copy; mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c1/pg-orders/orders-copy "$BACKUP_T"
snap="$(snapshot)"; run "$PJ"
expect "a named backup into a new instance of the same namespace: SUCCEEDED/DRY_RUN" SUCCEEDED DRY_RUN "would restore c1/pg-orders/orders-db into c1/pg-orders/orders-copy" "plan.restore.c1.orders-copy"
nothing_changed "same namespace, new instance" "$snap"
RKP=c1.orders-copy; Y="$(restore_yaml)"
[[ "$(yq '.kind' <<<"$Y")" == PostgresRestore && "$(yq '.spec.sourceBackup.name' <<<"$Y")" == orders-full-1 && "$(yq '.spec | has("pitr")' <<<"$Y")" == false \
   && "$(yq '.spec.targetInstance.name' <<<"$Y")" == orders-copy ]] \
  && ok "the PostgresRestore: spec.sourceBackup.name = sourceBackupName, no pitr, targetInstance.name" || bad "restore yaml" "$Y"
[[ "$(yq '.spec.targetInstance | has("spec")' <<<"$Y")" == false ]] && grep -q 'spec.targetInstance.spec: none, only the name: the operator creates the instance and fills in its spec (lab item' "$TMP/rec/plan.restore.c1.orders-copy.detail" \
  && ok "a new target without a spec file: spec.targetInstance.spec is omitted (the operator creates the instance; the plan names the lab item)" || bad "no spec" "$Y $(cat "$TMP/rec/plan.restore.c1.orders-copy.detail")"
grep -q 'restore-src' <<<"$(cat "$TMP/rec/plan.restore.c1.orders-copy.detail")" && bad "a same-namespace restore needs no location copy" "$(cat "$TMP/rec/plan.restore.c1.orders-copy.detail")" || ok "a same-namespace restore plans no location copy"
grep -q 'entry would be added' "$TMP/rec/plan.restore.c1.orders-copy.detail" && grep -q 'shared Secrets of pg-orders: owned by orders-db' "$TMP/rec/plan.restore.c1.orders-copy.detail" \
  && ok "the plan says the entry would be added and who owns the shared Secrets (orders-db, the namespace's owner)" || bad "plan text" "$(cat "$TMP/rec/plan.restore.c1.orders-copy.detail")"

reset
RK=c2.orders-dr; mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c2/pg-dr/orders-dr "$BACKUP_T"
snap="$(snapshot)"; run "$PJ"
expect "a named backup onto another cluster: SUCCEEDED/DRY_RUN" SUCCEEDED DRY_RUN "would restore c1/pg-orders/orders-db into c2/pg-dr/orders-dr"
nothing_changed "another cluster" "$snap"
D="$(cat "$TMP/rec/plan.restore.c2.orders-dr.detail")"
grep -q 'would be copied as pg-dr/restore-src-c1-pg-orders-orders-db on c2' <<<"$D" && grep -q 'PostgresBackup pg-dr/orders-full-1 on c2 to appear' <<<"$D" \
  && ok "the plan states that the location copy would be created and sourceBackupName then waited for" || bad "copy plan" "$D"
RKP=c2.orders-dr; C="$(plan_block 'PostgresBackupLocation .* on ')"
[[ "$(yq '.metadata.name' <<<"$C")" == restore-src-c1-pg-orders-orders-db && "$(yq '.spec.backupSync.enabled' <<<"$C")" == true \
   && "$(yq '.spec.retentionPolicy.fullRetention.number' <<<"$C")" == 9999999 && "$(yq '.spec.retentionPolicy.diffRetention.number' <<<"$C")" == 9999999 \
   && "$(yq '.spec.storage.azure.container' <<<"$C")" == pg-backups-c1 && "$(yq '.spec.storage.azure.repoPath' <<<"$C")" == /pg-orders \
   && "$(yq '.spec.storage.azure.secret.name' <<<"$C")" == backup-storage && "$(yq '.spec.storage.azure.enableSSL' <<<"$C")" == true \
   && "$(yq '.spec.storage.azure.caBundle' <<<"$C" | head -n1)" == "-----BEGIN CERTIFICATE-----" ]] \
  && ok "the location copy: source name and metadata dropped, backupSync on, retention 9999999, same container, repoPath, Secret, enableSSL and caBundle" || bad "copy yaml" "$C"
[[ "$(yq '.metadata.labels["tpg.fleet/restore-source"]' <<<"$C")" == "c1.orders-db" && "$(yq '.metadata | has("namespace")' <<<"$C")" == false && "$(yq '.spec.storage.azure | has("forcePathStyle")' <<<"$C")" == false ]] \
  && ok "the copy is labelled tpg.fleet/restore-source, carries no namespace (the apply sets it) and no zero default (forcePathStyle)" || bad "copy labels" "$C"
Y="$(restore_yaml)"
[[ "$(yq '.spec.targetInstance | keys | join(",")' <<<"$Y")" == name ]] && ok "onto another cluster without a spec file: targetInstance carries the name only (the chart render is not sent)" || bad "targetInstance keys" "$Y"

echo "== 1b. every PITR type renders into spec.pitr"
reset
RK=c2.orders-dr
declare -A PITR_KEYS=([latest]="$LATEST"
  [time]=$'pitrEnabled: true\nbestEffort: true\npitrConfig:\n  type: time\n  timestamp: 2024-06-01T00:00:00Z'
  [lsn]=$'pitrEnabled: true\nbestEffort: false\npitrConfig:\n  type: lsn\n  target: 0/3000060'
  [transaction]=$'pitrEnabled: true\nbestEffort: true\npitrConfig:\n  type: transaction\n  target: "987654"')
for typ in latest time lsn transaction; do
  keys="${PITR_KEYS[$typ]}"
  mk c1/pg-orders/orders-db '' c2/pg-dr/orders-dr "$keys"; run "$PJ"
  expect "pitr $typ: SUCCEEDED/DRY_RUN" SUCCEEDED DRY_RUN
  Y="$(RKP=c2.orders-dr restore_yaml)"
  [[ "$(yq '.spec.pitr.type' <<<"$Y")" == "$typ" && "$(yq '.spec | has("sourceBackup")' <<<"$Y")" == false \
     && "$(yq '.spec.pitr.sourceBackupLocation.name' <<<"$Y")" == restore-src-c1-pg-orders-orders-db && "$(yq '.spec.pitr.sourceBackupLocation.stanzaName' <<<"$Y")" == pg-orders-orders-db-0000 ]] \
    && ok "pitr $typ: spec.pitr.type, the derived location (the copy in the target namespace) and stanza, no spec.sourceBackup" || bad "pitr $typ yaml" "$Y"
  case "$typ" in
    latest) [[ "$(yq '.spec.pitr | has("bestEffort")' <<<"$Y")" == false && "$(yq '.spec.pitr | has("timestamp")' <<<"$Y")" == false ]] && ok "pitr latest: no bestEffort, timestamp or target" || bad "latest fields" "$Y" ;;
    time) [[ "$(yq '.spec.pitr.timestamp' <<<"$Y")" == 2024-06-01T00:00:00Z && "$(yq '.spec.pitr.bestEffort' <<<"$Y")" == true ]] && ok "pitr time: timestamp and bestEffort true" || bad "time fields" "$Y" ;;
    lsn) [[ "$(yq '.spec.pitr.target' <<<"$Y")" == 0/3000060 && "$(yq '.spec.pitr | has("bestEffort")' <<<"$Y")" == false ]] && ok "pitr lsn: target; bestEffort false is a zero default and is left out" || bad "lsn fields" "$Y" ;;
    transaction) [[ "$(yq '.spec.pitr.target' <<<"$Y")" == 987654 ]] && ok "pitr transaction: target" || bad "transaction fields" "$Y" ;;
  esac
done
mk c1/pg-orders/orders-db '' c2/pg-dr/orders-dr "$(printf 'pitrEnabled: true\nbestEffort: true\npitrConfig:\n  type: time\n  timestamp: 2024-06-01T00:00:00Z\n  sourceBackupConfig:\n    srcBackupLabel: 20200101-000000F')"; run "$PJ"
Y="$(RKP=c2.orders-dr restore_yaml)"
[[ "$(yq '.spec.pitr.sourceBackupLocation.set' <<<"$Y")" == 20200101-000000F ]] && ok "srcBackupLabel is spec.pitr.sourceBackupLocation.set" || bad "set" "$Y"
mk c1/pg-orders/orders-db '' c1/pg-orders/orders-copy "$LATEST"; run "$PJ"
RKP=c1.orders-copy; Y="$(restore_yaml)"
[[ "$(yq '.spec.pitr.sourceBackupLocation.name' <<<"$Y")" == orders-db-backup-location ]] && ok "PITR inside the source namespace names the source's own location (no copy)" || bad "same ns pitr" "$Y"

echo "== 1c. skipMinorVersionCheck, TARGET_EXISTS, in place and confirm"
reset
RK=c2.orders-dr; mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c2/pg-dr/orders-dr $'pitrEnabled: false\nskipMinorVersionCheck: true'; run "$PJ"
Y="$(RKP=c2.orders-dr restore_yaml)"
[[ "$(yq '.metadata.annotations["sql.tanzu.vmware.com/skip-minor-version-check"]' <<<"$Y")" == true ]] && ok "skipMinorVersionCheck: the annotation sql.tanzu.vmware.com/skip-minor-version-check: \"true\" on the PostgresRestore" || bad "annotation" "$Y"
mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c2/pg-dr/orders-dr "$BACKUP_T"; run "$PJ"
Y="$(RKP=c2.orders-dr restore_yaml)"
[[ "$(yq '.metadata | has("annotations")' <<<"$Y")" == false && "$(yq '.metadata.labels["tpg.fleet/workflow"]' <<<"$Y")" == tpg-restore-x ]] && ok "without the flag no annotation; the workflow label is there" || bad "no annotation" "$Y"
reset
# a live Postgres of the target name that is not the source and not in place: TARGET_EXISTS at plan time, also in a dry run
RK=c2.dr-db; mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c2/pg-dr-existing/dr-db "$BACKUP_T"; snap="$(snapshot)"; run "$PJ"
expect "a live Postgres with the target name on the target cluster (dry run): FAILED TARGET_EXISTS" FAILED TARGET_EXISTS "c2/pg-dr-existing/dr-db" "restore in place or choose a new instance name"
[[ "$RC" -ne 0 ]] && ok "TARGET_EXISTS exits non-zero (the pair failed; the run fails at the end)" || bad "TARGET_EXISTS rc"
nothing_changed "TARGET_EXISTS (dry run)" "$snap"
[[ ! -e "$TMP/rec/plan.restore.c2.dr-db.status" ]] && ok "…no plan is recorded for a refused pair" || bad "plan recorded"
run "$PJ" P_DRY_RUN=false
expect "…the same in a real run, before anything happened" FAILED TARGET_EXISTS "restore in place or choose a new instance name"
nothing_changed "TARGET_EXISTS (real run)" "$snap"
mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c2/pg-dr-existing/dr-db $'pitrEnabled: false\ntargetInstanceSpecFilePath: [repo:helm_artifacts/instance/tpg-instance/restore-specs/orders-dr.yaml]'; run "$PJ"
expect "…with a spec file the reason is TARGET_EXISTS as well (no TARGET_SPEC_FILE_REFUSED any more)" FAILED TARGET_EXISTS
mk c1/pg-orders/orders-db '' c2/pg-dr-existing/dr-db "$LATEST"; run "$PJ"
expect "…also for a point-in-time recovery" FAILED TARGET_EXISTS
# an existing instance in the source namespace of the same cluster (a copy next to the source): the same
cp "$TMP/cl/c1/postgres/pg-orders/orders-db.json" "$TMP/cl/c1/postgres/pg-orders/orders-live.json"
jq '.metadata.name = "orders-live"' "$TMP/cl/c1/postgres/pg-orders/orders-live.json" > "$TMP/x" && mv "$TMP/x" "$TMP/cl/c1/postgres/pg-orders/orders-live.json"
RK=c1.orders-live; mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c1/pg-orders/orders-live "$BACKUP_T"; run "$PJ"
expect "a live Postgres in the source namespace that is not the source: TARGET_EXISTS" FAILED TARGET_EXISTS "c1/pg-orders/orders-live"
# the next pair of the run is unaffected, the failed one is reported
RK=c1.orders-copy; mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c1/pg-orders/orders-copy "$BACKUP_T"; run "$PJ"
expect "the next pair (a new instance) is not affected by the refused one" SUCCEEDED DRY_RUN
# a fleet entry that is declared but not deployed is a new target, not an existing one
yq -i '.clusters.c1.instances.orders-declared.instance = {"namespace": "pg-orders", "postgresVersion": "postgres-17.6"}' "$TMP/fleet.repo/clusters/fleet.yaml"
RK=c1.orders-declared; mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c1/pg-orders/orders-declared "$BACKUP_T"; run "$PJ"
expect "an entry declared in clusters/fleet.yaml but not deployed is a new target: planned" SUCCEEDED DRY_RUN
grep -q 'the entry would be replaced (it is declared but not deployed) (a copy of the entry of c1/orders-db)' "$TMP/rec/plan.restore.c1.orders-declared.detail" && ok "…the plan says its entry would be replaced by a copy of the source's" || bad "declared plan" "$(cat "$TMP/rec/plan.restore.c1.orders-declared.detail")"
reset
RK=c1.orders-db; mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c1/pg-orders/orders-db $'pitrEnabled: false\nconfirm: orders-db'; snap="$(snapshot)"; run "$PJ"
expect "in place with confirm: SUCCEEDED/DRY_RUN (the live source is the target: not TARGET_EXISTS)" SUCCEEDED DRY_RUN
[[ ! -e "$TMP/rec/warning.c1.orders-db.CONFIRMATION_MISSING.status" ]] && ok "confirm given: no CONFIRMATION_MISSING warning" || bad "unexpected warning"
Y="$(RKP=c1.orders-db restore_yaml)"
[[ "$(yq '.spec.targetInstance | has("spec")' <<<"$Y")" == false && "$(yq '.spec.targetInstance.name' <<<"$Y")" == orders-db ]] && ok "in place without a spec file: targetInstance.name only, no spec" || bad "in place spec" "$Y"
nothing_changed "in place" "$snap"
mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c1/pg-orders/orders-db "$BACKUP_T"; run "$PJ"
expect "in place without confirm: the dry run goes on" SUCCEEDED DRY_RUN
[[ "$(cat "$TMP/rec/warning.c1.orders-db.CONFIRMATION_MISSING.status" 2>/dev/null)" == WARNING ]] && ok "CONFIRMATION_MISSING is a warning in a dry run of an in-place pair (validate refuses a real run)" || bad "confirmation warning" "$(cat "$TMP/records")"
run "$PJ" P_DRY_RUN=false
expect "in place without confirm in a real run: CONFIRMATION_MISMATCH (defence in depth: validate refuses it first)" FAILED CONFIRMATION_MISMATCH "set confirm: orders-db"

echo "== 2. the named backup checks"
reset
RK=c1.orders-copy
mk c1/pg-orders/orders-db 'sourceBackupName: orders-nope' c1/pg-orders/orders-copy "$BACKUP_T"; snap="$(snapshot)"; run "$PJ"
expect "same namespace, backup missing: BACKUP_NOT_FOUND also in a dry run" FAILED BACKUP_NOT_FOUND "pg-orders/orders-nope" "must exist and be Succeeded"
nothing_changed "BACKUP_NOT_FOUND" "$snap"
mk c1/pg-orders/orders-db 'sourceBackupName: orders-failed' c1/pg-orders/orders-copy "$BACKUP_T"; run "$PJ"
expect "same namespace, backup Failed: BACKUP_NOT_SUCCEEDED (dry run)" FAILED BACKUP_NOT_SUCCEEDED "phase Failed"
mk c1/pg-orders/orders-db 'sourceBackupName: orders-running' c1/pg-orders/orders-copy "$BACKUP_T"; run "$PJ" P_DRY_RUN=false
expect "same namespace, backup Running: BACKUP_NOT_SUCCEEDED, no wait" FAILED BACKUP_NOT_SUCCEEDED "phase Running"
mk c1/pg-orders/orders-db 'sourceBackupName: orders-nope' c2/pg-dr/orders-dr "$BACKUP_T"; RK=c2.orders-dr; run "$PJ"
expect "another cluster, source backup missing: SOURCE_BACKUP_UNVERIFIED" FAILED SOURCE_BACKUP_UNVERIFIED "does not exist"
set_flag tkfail.c1.postgresbackup
run "$PJ"
expect "another cluster, source cluster unreadable: SOURCE_BACKUP_UNVERIFIED (refused, not assumed)" FAILED SOURCE_BACKUP_UNVERIFIED "could not be read" "Forbidden"
rm -f "$TMP/flags/tkfail.c1.postgresbackup"
mk c1/pg-orders/orders-db 'sourceBackupName: orders-failed' c2/pg-dr/orders-dr "$BACKUP_T"; run "$PJ"
expect "another cluster, source backup Failed: BACKUP_NOT_SUCCEEDED" FAILED BACKUP_NOT_SUCCEEDED "phase Failed"
mk c1/pg-orders/orders-db 'sourceBackupName: other-inst-full' c1/pg-orders/orders-copy "$BACKUP_T"; RK=c1.orders-copy; snap="$(snapshot)"; run "$PJ"
expect "a backup of another instance than the pair's source: BACKUP_OF_OTHER_INSTANCE is a refusal (also in a dry run)" FAILED BACKUP_OF_OTHER_INSTANCE "is a backup of reports-db, not of the source instance orders-db" "a pair has exactly one"
nothing_changed "BACKUP_OF_OTHER_INSTANCE" "$snap"
[[ ! -e "$TMP/rec/warning.c1.orders-copy.BACKUP_OF_OTHER_INSTANCE.status" ]] && ok "…and no longer a warning" || bad "still a warning"
mk c1/pg-orders/orders-db 'sourceBackupName: other-inst-full' c2/pg-dr/orders-dr "$BACKUP_T"; RK=c2.orders-dr; run "$PJ" P_DRY_RUN=false
expect "…the same into another cluster, in a real run" FAILED BACKUP_OF_OTHER_INSTANCE "reports-db"
mk c1/pg-orders/orders-db 'sourceBackupName: other-inst-full' c2/pg-dr/orders-dr "$LATEST"; run "$PJ"
expect "…with pitr and a sourceBackupName of another instance too" FAILED BACKUP_OF_OTHER_INSTANCE
mk c1/pg-orders/reports-db 'sourceBackupName: other-inst-full' c1/pg-orders/orders-copy "$BACKUP_T"; RK=c1.orders-copy; run "$PJ"
expect "a backup of the pair's own source instance (reports-db) is fine" SUCCEEDED DRY_RUN

echo "== 3. PITR: location and stanza"
reset
RK=c2.orders-dr
mk c1/pg-gone/gone-db '' c2/pg-dr/orders-dr "$LATEST"$'\n'"$SPECF"; run "$PJ"
expect "source gone, no sourceBackupName, nothing given: PITR_SOURCE_UNKNOWN with a clear message" FAILED PITR_SOURCE_UNKNOWN "srcBackupLocationName and srcStanzaName" "is not on c1"
mk c1/pg-gone/gone-db 'sourceBackupName: gone-full-1' c2/pg-dr/orders-dr "$LATEST"$'\n'"$SPECF"; run "$PJ"
expect "source gone: location and stanza come from the source PostgresBackup" SUCCEEDED DRY_RUN
Y="$(RKP=c2.orders-dr restore_yaml)"
[[ "$(yq '.spec.pitr.sourceBackupLocation.name' <<<"$Y")" == restore-src-c1-pg-gone-gone-db && "$(yq '.spec.pitr.sourceBackupLocation.stanzaName' <<<"$Y")" == gone-stanza ]] \
  && ok "…the stanza from the backup, the location copied from the backup's location (gone-loc) under the copy name" || bad "gone yaml" "$Y"
mk c1/pg-gone/gone-db '' c2/pg-dr/orders-dr $'pitrEnabled: true\npitrConfig:\n  type: latest\n  sourceBackupConfig:\n    srcBackupLocationName: gone-loc\n    srcStanzaName: gone-stanza\n'"$SPECF"; run "$PJ"
expect "source gone, location and stanza given: used (nothing to derive)" SUCCEEDED DRY_RUN
mk c1/pg-gone/gone-db '' c2/pg-dr/orders-dr $'pitrEnabled: true\npitrConfig:\n  type: latest\n  sourceBackupConfig:\n    srcBackupLocationName: gone-loc\n'"$SPECF"; run "$PJ"
expect "source gone, only the location given: PITR_SOURCE_UNKNOWN (the stanza is mandatory then)" FAILED PITR_SOURCE_UNKNOWN
reset
mk c1/pg-orders/orders-db '' c2/pg-dr/orders-dr $'pitrEnabled: true\npitrConfig:\n  type: latest\n  sourceBackupConfig:\n    srcBackupLocationName: orders-db-backup-location\n    srcStanzaName: pg-orders-orders-db-0000'; run "$PJ"
expect "given location and stanza equal to what the cluster reports: no warning" SUCCEEDED DRY_RUN
compgen -G "$TMP/rec/warning.*" >/dev/null && bad "warning without a difference" "$(ls "$TMP/rec")" || ok "…and none is recorded"
reset
mk c1/pg-orders/orders-db '' c2/pg-dr/orders-dr $'pitrEnabled: true\npitrConfig:\n  type: latest\n  sourceBackupConfig:\n    srcStanzaName: other-stanza'; run "$PJ"
expect "a given stanza that differs from the live one: the pair goes on" SUCCEEDED DRY_RUN
[[ -e "$TMP/rec/warning.c2.orders-dr.SRC_STANZA_DIFFERS.status" ]] && grep -q 'other-stanza differs from pg-orders-orders-db-0000' "$TMP/rec/warning.c2.orders-dr.SRC_STANZA_DIFFERS.detail" \
  && ok "SRC_STANZA_DIFFERS is a warning naming both values" || bad "stanza warning" "$(ls "$TMP/rec")"
Y="$(RKP=c2.orders-dr restore_yaml)"; [[ "$(yq '.spec.pitr.sourceBackupLocation.stanzaName' <<<"$Y")" == other-stanza ]] && ok "the given stanza wins" || bad "given wins" "$Y"
reset
mkdir -p "$TMP/cl/c1/postgresbackuplocation/pg-orders"
jq '.metadata.name = "elsewhere"' "$TMP/cl/c1/postgresbackuplocation/pg-orders/orders-db-backup-location.json" > "$TMP/cl/c1/postgresbackuplocation/pg-orders/elsewhere.json"
mk c1/pg-orders/orders-db '' c2/pg-dr/orders-dr $'pitrEnabled: true\npitrConfig:\n  type: latest\n  sourceBackupConfig:\n    srcBackupLocationName: elsewhere'; run "$PJ"
expect "a given location that differs from the live one" SUCCEEDED DRY_RUN
[[ -e "$TMP/rec/warning.c2.orders-dr.SRC_LOCATION_DIFFERS.status" ]] && ok "SRC_LOCATION_DIFFERS is a warning" || bad "location warning"
Y="$(RKP=c2.orders-dr restore_yaml)"; [[ "$(yq '.spec.pitr.sourceBackupLocation.name' <<<"$Y")" == restore-src-c1-pg-orders-orders-db ]] && ok "…and the copy is built from the given location (the object elsewhere)" || bad "given location yaml" "$Y"
reset
mk c1/pg-orders/orders-db '' c2/pg-dr/orders-dr $'pitrEnabled: true\npitrConfig:\n  type: latest\n  sourceBackupConfig:\n    srcBackupLocationName: no-such-loc'; run "$PJ"
expect "a location that cannot be read in the source namespace: SOURCE_LOCATION_UNREADABLE" FAILED SOURCE_LOCATION_UNREADABLE "does not exist"
reset
jq '.status.stanzaName = ""' "$TMP/cl/c1/postgres/pg-orders/orders-db.json" > "$TMP/x" && mv "$TMP/x" "$TMP/cl/c1/postgres/pg-orders/orders-db.json"
mk c1/pg-orders/orders-db '' c2/pg-dr/orders-dr "$LATEST"; run "$PJ"
expect "a live source without a stanza: BACKUP_LOCATION_NOT_INITIALIZED" FAILED BACKUP_LOCATION_NOT_INITIALIZED "no stanza yet"
reset
for k in orders-full-1 orders-failed orders-running other-inst-full orders-full-v174 orders-full-v178; do rm -f "$TMP/cl/c1/postgresbackup/pg-orders/$k.json"; done
mk c1/pg-orders/orders-db '' c2/pg-dr/orders-dr "$LATEST"; run "$PJ"
expect "a live source without a Succeeded full backup: NO_FULL_BACKUP" FAILED NO_FULL_BACKUP
reset
mk c1/pg-orders/orders-db '' c2/pg-dr/orders-dr $'pitrEnabled: true\nbestEffort: true\npitrConfig:\n  type: time\n  timestamp: 2099-01-01T00:00:00Z'; run "$PJ"
expect "a recovery time in the future: INVALID_TIMESTAMP" FAILED INVALID_TIMESTAMP "in the future"
mk c1/pg-orders/orders-db '' c2/pg-dr/orders-dr $'pitrEnabled: true\nbestEffort: true\npitrConfig:\n  type: time\n  timestamp: 2019-01-01T00:00:00Z'; run "$PJ"
expect "a recovery time before the oldest full backup: OUTSIDE_RECOVERY_WINDOW" FAILED OUTSIDE_RECOVERY_WINDOW "2020-01-01T00:00:00Z"
mk c1/pg-orders/orders-db '' c2/pg-dr/orders-dr $'pitrEnabled: true\nbestEffort: true\npitrConfig:\n  type: time\n  timestamp: 2024-06-01T00:00:00Z\n  sourceBackupConfig:\n    srcBackupLabel: 20200505-000000F'; run "$PJ"
expect "an unknown backup label is a warning only" SUCCEEDED DRY_RUN
[[ -e "$TMP/rec/warning.c2.orders-dr.BACKUP_LABEL_UNVERIFIED.status" ]] && ok "BACKUP_LABEL_UNVERIFIED" || bad "label warning"
mk c1/pg-orders/orders-db '' c2/pg-dr/orders-dr "$LATEST"; set_flag tkfail.c1.postgresbackup; run "$PJ"
expect "PostgresBackups that cannot be listed: a warning, not a refusal (RECOVERY_WINDOW_UNVERIFIED)" SUCCEEDED DRY_RUN
[[ -e "$TMP/rec/warning.c2.orders-dr.RECOVERY_WINDOW_UNVERIFIED.status" ]] && ok "RECOVERY_WINDOW_UNVERIFIED" || bad "window warning"

echo "== 4. the matrix"
reset
RK=c2.orders-dr
tgt() { mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c2/pg-dr/orders-dr "pitrEnabled: false
targetInstanceSpecFilePath: [repo:helm_artifacts/instance/tpg-instance/restore-specs/$1]${2:+
$2}"; }
tgt orders-lite.yaml; run "$PJ"
expect "standard source -> lite target: BLOCKED RESTORE_FLAVOUR_UNSUPPORTED" BLOCKED RESTORE_FLAVOUR_UNSUPPORTED "postgres-17.6-lite" "choose a standard PostgresVersion"
[[ -e "$TMP/rec/plan.restore.c2.orders-dr.detail" ]] && ok "a BLOCKED pair still records its plan so far" || bad "blocked plan"
tgt orders-old.yaml; run "$PJ"
expect "a lower minor version: BLOCKED RESTORE_VERSION_LOWER" BLOCKED RESTORE_VERSION_LOWER "postgres-17.4" "lower version than 17.6" "relaxes no check"
tgt orders-old.yaml 'skipMinorVersionCheck: true'; run "$PJ"
expect "…skipMinorVersionCheck does not lift it: still BLOCKED RESTORE_VERSION_LOWER" BLOCKED RESTORE_VERSION_LOWER "only sets the operator's annotation"
[[ ! -e "$TMP/rec/warning.c2.orders-dr.RESTORE_VERSION_LOWER_SKIPPED.status" ]] && ok "…RESTORE_VERSION_LOWER_SKIPPED does not exist any more" || bad "skipped warning"
# a PostgresVersion whose spec.dbVersion has three parts (17.5.9) is compared as major.minor (17.5), not as a bash arithmetic error
tgt orders-175.yaml; run "$PJ"
expect "a target whose PostgresVersion has a three-part dbVersion (17.5.9) below the source (17.6): BLOCKED RESTORE_VERSION_LOWER" BLOCKED RESTORE_VERSION_LOWER "postgres-17.5 (17.5)" "lower version than 17.6"
tgt orders-new.yaml; run "$PJ"
expect "a higher minor version is allowed" SUCCEEDED DRY_RUN
for c in c1 c2; do jq '.spec.dbVersion = "17.6.2"' "$TMP/cl/$c/postgresversion/_/postgres-17.6.json" > "$TMP/x" && mv "$TMP/x" "$TMP/cl/$c/postgresversion/_/postgres-17.6.json"; done
tgt orders-new.yaml; run "$PJ"
expect "a source PostgresVersion with a three-part dbVersion (17.6.2) and a higher target: allowed (no arithmetic error)" SUCCEEDED DRY_RUN
tgt orders-175.yaml; run "$PJ"
expect "…and a lower target is still blocked" BLOCKED RESTORE_VERSION_LOWER "lower version than 17.6"
for c in c1 c2; do jq '.spec.dbVersion = "17.6"' "$TMP/cl/$c/postgresversion/_/postgres-17.6.json" > "$TMP/x" && mv "$TMP/x" "$TMP/cl/$c/postgresversion/_/postgres-17.6.json"; done
tgt orders-16.yaml; run "$PJ"
expect "a lower major version: BLOCKED RESTORE_VERSION_LOWER" BLOCKED RESTORE_VERSION_LOWER "postgres-16.9"
tgt orders-18.yaml; run "$PJ"
expect "a higher major version is not blocked by the workflow (RESTORE_MAJOR_DIFFERS is removed; the operator refuses it)" SUCCEEDED DRY_RUN
grep -q 'the operator refuses a restore across major versions itself' "$TMP/rec/plan.restore.c2.orders-dr.detail" && ok "…the plan notes that the operator decides" || bad "major note" "$(cat "$TMP/rec/plan.restore.c2.orders-dr.detail")"
tgt orders-18.yaml 'skipMinorVersionCheck: true'; run "$PJ"
expect "…with skipMinorVersionCheck the same" SUCCEEDED DRY_RUN
# the version of the named backup counts (status.fullPostgresVersion), not only the source's current version
mk c1/pg-orders/orders-db 'sourceBackupName: orders-full-v178' c2/pg-dr/orders-dr "pitrEnabled: false
targetInstanceSpecFilePath: [repo:helm_artifacts/instance/tpg-instance/restore-specs/orders-dr.yaml]"; run "$PJ"
expect "a backup taken at 17.8 into a 17.6 target: BLOCKED RESTORE_VERSION_LOWER (the backup's fullPostgresVersion, although the source runs 17.6)" BLOCKED RESTORE_VERSION_LOWER "17.8" "PostgresBackup orders-full-v178"
mk c1/pg-orders/orders-db 'sourceBackupName: orders-full-v174' c2/pg-dr/orders-dr "pitrEnabled: false
targetInstanceSpecFilePath: [repo:helm_artifacts/instance/tpg-instance/restore-specs/orders-old.yaml]"; run "$PJ"
expect "a backup taken at 17.4 into a 17.4 target: allowed (the source runs 17.6)" SUCCEEDED DRY_RUN
tgt orders-nover.yaml; run "$PJ"
expect "a version the target cluster does not have: VERSION_NOT_AVAILABLE" FAILED VERSION_NOT_AVAILABLE "postgres-19.0"
# a lite source is restored into a standard or a lite target
jq '.spec.postgresVersion.name = "postgres-17.6-lite"' "$TMP/cl/c1/postgres/pg-orders/orders-db.json" > "$TMP/x" && mv "$TMP/x" "$TMP/cl/c1/postgres/pg-orders/orders-db.json"
tgt orders-lite.yaml; run "$PJ"
expect "lite source -> lite target is allowed" SUCCEEDED DRY_RUN
tgt orders-dr.yaml; run "$PJ"
expect "lite source -> standard target is allowed" SUCCEEDED DRY_RUN
reset
# independent per pair: a blocked pair does not change the next one's result
tgt orders-lite.yaml; run "$PJ"; blocked_rc="$RC"
mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c2/pg-dr/orders-dr2 "$BACKUP_T"; RK=c2.orders-dr2; run "$PJ"
[[ "$blocked_rc" -ne 0 && "$(st)" == SUCCEEDED ]] && ok "the BLOCKED pair exits non-zero (a canary stops); the next pair is unaffected and SUCCEEDED" || bad "independent pairs" "rc=$blocked_rc $(st)"
reset
set_flag unknown.version
jq 'del(.status)' "$TMP/cl/c1/postgres/pg-orders/orders-db.json" > "$TMP/x" && mv "$TMP/x" "$TMP/cl/c1/postgres/pg-orders/orders-db.json"
# a source without a live Postgres, not in the fleet and a backup only: no version known
mk c1/pg-gone/gone-db 'sourceBackupName: gone-full-1' c2/pg-dr/orders-dr "$BACKUP_T"$'\n'"$SPECF"; RK=c2.orders-dr; run "$PJ"
expect "a source whose version is unknown: the matrix is not checked (warning MATRIX_UNVERIFIED), the pair goes on" SUCCEEDED DRY_RUN
[[ -e "$TMP/rec/warning.c2.orders-dr.MATRIX_UNVERIFIED.status" ]] && ok "MATRIX_UNVERIFIED" || bad "matrix warning"

echo "== 5. the target"
reset
RK=c2.dr-db
mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c2/pg-other/dr-db "$BACKUP_T"; run "$PJ"
expect "a target declared in another namespace: NAMESPACE_IMMUTABLE" FAILED NAMESPACE_IMMUTABLE "declared in namespace pg-dr-existing"
mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c2/pg-dr/dr-db "$BACKUP_T"; run "$PJ"
expect "…the same without a fleet entry: the Postgres of that name runs elsewhere (INSTANCE_NAME_IN_USE after the entry check)" FAILED NAMESPACE_IMMUTABLE
reset
yq -i 'del(.clusters.c2.instances.dr-db)' "$TMP/fleet.repo/clusters/fleet.yaml"
mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c2/pg-dr/dr-db "$BACKUP_T"; run "$PJ"
expect "a live Postgres of that name in another namespace of the cluster: INSTANCE_NAME_IN_USE" FAILED INSTANCE_NAME_IN_USE "pg-dr-existing"
reset
yq -i 'del(.clusters.c2)' "$TMP/fleet.repo/clusters/fleet.yaml"
RK=c2.orders-dr; mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c2/pg-dr/orders-dr "$BACKUP_T"; run "$PJ"
expect "a target cluster without an entry in clusters/fleet.yaml: UNKNOWN_TARGET_CLUSTER" FAILED UNKNOWN_TARGET_CLUSTER "run tpg-day0"
reset
mk c1/pg-legacy/legacy-db 'sourceBackupName: legacy-full-1' c2/pg-dr/orders-dr "$BACKUP_T"; run "$PJ"
expect "a source that is not in clusters/fleet.yaml and no spec file: SPEC_FILE_REQUIRED" FAILED SPEC_FILE_REQUIRED "targetInstanceSpecFilePath"
mk c1/pg-legacy/legacy-db 'sourceBackupName: legacy-full-1' c2/pg-dr/orders-dr $'pitrEnabled: false\ntargetInstanceSpecFilePath: [repo:helm_artifacts/instance/tpg-instance/restore-specs/legacy.yaml]'; run "$PJ"
expect "…with a spec file the pair plans" SUCCEEDED DRY_RUN
reset
RK=c2.orders-dr
mk c1/pg-legacy/legacy-db 'sourceBackupName: legacy-full-1' c2/pg-dr/orders-dr $'pitrEnabled: false\ntargetInstanceSpecFilePath: [repo:helm_artifacts/instance/tpg-instance/restore-specs/missing.yaml]'; run "$PJ"
expect "a repo: spec file that is not on the fleet branch: SPEC_FILE_NOT_FOUND" FAILED SPEC_FILE_NOT_FOUND "no such file"
# a committed symlink under restore-specs/ is no spec file (it could point at any file of the clone)
RSR="$TMP/fleet.repo/helm_artifacts/instance/tpg-instance/restore-specs"
ln -s orders-dr.yaml "$RSR/link-same.yaml"            # a valid spec file, reached through a link inside the folder
ln -s ../../../../clusters/fleet.yaml "$RSR/link-out.yaml"   # a file outside the folder
ln -s ../../../../clusters "$RSR/sub"                 # a folder outside the folder: restore-specs/sub/fleet.yaml
for f in link-same.yaml link-out.yaml sub/fleet.yaml; do
  mk c1/pg-legacy/legacy-db 'sourceBackupName: legacy-full-1' c2/pg-dr/orders-dr "pitrEnabled: false
targetInstanceSpecFilePath: [repo:helm_artifacts/instance/tpg-instance/restore-specs/$f]"; run "$PJ"
  expect "a spec file that is, or lies behind, a symbolic link ($f): SPEC_FILE_INVALID" FAILED SPEC_FILE_INVALID "symbolic link" "restore-specs/"
done
mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c1/pg-orders/orders-db $'pitrEnabled: false\nconfirm: orders-db\ntargetInstanceSpecFilePath: [repo:helm_artifacts/instance/tpg-instance/restore-specs/link-same.yaml]'; RK=c1.orders-db; run "$PJ"
expect "…the same for an in-place restore" FAILED SPEC_FILE_INVALID "symbolic link"
RK=c2.orders-dr
rm -f "$RSR/link-same.yaml" "$RSR/link-out.yaml" "$RSR/sub"
mv "$RSR" "$RSR.real"; ln -s restore-specs.real "$RSR"   # the folder itself replaced by a link to another folder
mk c1/pg-legacy/legacy-db 'sourceBackupName: legacy-full-1' c2/pg-dr/orders-dr $'pitrEnabled: false\ntargetInstanceSpecFilePath: [repo:helm_artifacts/instance/tpg-instance/restore-specs/legacy.yaml]'; run "$PJ"
expect "…restore-specs/ itself a link to another folder: SPEC_FILE_INVALID" FAILED SPEC_FILE_INVALID "symbolic link"
rm -f "$RSR"; mv "$RSR.real" "$RSR"
mk c1/pg-legacy/legacy-db 'sourceBackupName: legacy-full-1' c2/pg-dr/orders-dr $'pitrEnabled: false\ntargetInstanceSpecFilePath: [./local.yaml]'; run "$PJ" P_PATCH_FILES='{}'
expect "a local spec file that is not in patchFiles: SPEC_FILE_NOT_RECEIVED" FAILED SPEC_FILE_NOT_RECEIVED "patchFiles"
B64="$(base64 -w0 "$RSD/orders-dr.yaml")"
run "$PJ" P_PATCH_FILES="{\"./local.yaml\": \"$B64\"}"
expect "a local spec file in patchFiles is used" SUCCEEDED DRY_RUN
Y="$(RKP=c2.orders-dr restore_yaml)"
[[ "$(yq '.spec.targetInstance.spec.storageSize' <<<"$Y")" == 50Gi && "$(yq '.spec.targetInstance.spec | has("highAvailability")' <<<"$Y")" == false \
   && "$(yq '.spec.targetInstance.spec.postgresVersion.name' <<<"$Y")" == postgres-17.6 ]] \
  && ok "the spec file is the instance spec: storageSize 50Gi, highAvailability enabled:false is a zero default and is left out (pruned like a Postgres)" || bad "spec file" "$Y"
[[ "$(yq '.spec.targetInstance.spec | keys | join(",")' <<<"$Y")" == "postgresVersion,storageSize" ]] \
  && ok "…and nothing else: no chart render is merged under it (no imagePullSecret, no backupLocation from the fleet)" || bad "spec not merged" "$Y"
for f in orders-bad orders-two; do
  mk c1/pg-legacy/legacy-db 'sourceBackupName: legacy-full-1' c2/pg-dr/orders-dr "pitrEnabled: false
targetInstanceSpecFilePath: [repo:helm_artifacts/instance/tpg-instance/restore-specs/$f.yaml]"; run "$PJ"
  expect "an invalid spec file ($f): SPEC_FILE_INVALID" FAILED SPEC_FILE_INVALID
done
mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c2/pg-dr/orders-dr $'pitrEnabled: false\ntargetInstanceSpecFilePath: [repo:helm_artifacts/instance/tpg-instance/restore-specs/orders-extra.yaml]'; run "$PJ"
expect "a spec file field the entry does not render: the pair goes on, no SPEC_FILE_NOT_IN_ENTRY any more" SUCCEEDED DRY_RUN
Y="$(RKP=c2.orders-dr restore_yaml)"
[[ ! -e "$TMP/rec/warning.c2.orders-dr.SPEC_FILE_NOT_IN_ENTRY.status" && "$(yq '.spec.targetInstance.spec.pgConfig.dbname' <<<"$Y")" == orders ]] \
  && ok "…the field is in spec.targetInstance.spec as the file has it" || bad "extra field" "$Y"
mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c2/pg-dr/orders-dr $'pitrEnabled: false\ntargetInstanceSpecFilePath: [repo:helm_artifacts/instance/tpg-instance/restore-specs/orders-loc.yaml]'; run "$PJ"
expect "a spec file backupLocation that does not exist in the target namespace: BACKUP_LOCATION_MISSING" FAILED BACKUP_LOCATION_MISSING "shared-location" "pg-dr on c2" "leave backupLocation out"
mkdir -p "$TMP/cl/c2/postgresbackuplocation/pg-dr"
printf '%s' '{"kind":"PostgresBackupLocation","metadata":{"name":"shared-location","namespace":"pg-dr"},"spec":{"storage":{"azure":{"container":"pg-backups","repoPath":"/pg-dr/shared"}}}}' > "$TMP/cl/c2/postgresbackuplocation/pg-dr/shared-location.json"
run "$PJ"
expect "…the location exists in the target namespace: the pair plans" SUCCEEDED DRY_RUN
[[ -z "$(find "$TMP/rec" -name 'warning.c2.orders-dr.*' 2>/dev/null)" ]] && ! grep -q 'first sync of its Application points' "$TMP/records" \
  && ok "the restore-patch names its own location: no replacement warning (it wins over the fleet's orders-dr-backup-location)" || bad "location warning" "$(cat "$TMP/records")"
grep -q 'its own backupLocation and imagePullSecret win and the fleet.s fill in' "$TMP/rec/plan.restore.c2.orders-dr.detail" && ok "the plan tells the render: the restore-patch's backupLocation and imagePullSecret win, the fleet's fill in where it omits them" || bad "plan references" "$(cat "$TMP/rec/plan.restore.c2.orders-dr.detail")"
reset
mk c1/pg-orders-wrong/orders-db "$ORDERS_BACKUP" c2/pg-dr/orders-dr "$BACKUP_T"; RK=c2.orders-dr; run "$PJ"
expect "a source namespace that is not the entry's: SOURCE_NAMESPACE_MISMATCH" FAILED SOURCE_NAMESPACE_MISMATCH "declares orders-db on c1 in namespace pg-orders"
reset
# the owner rules and the namespace Secrets
mkdir -p "$TMP/cl/c2/secret/pg-dr"
jq -cn '{kind: "Secret", metadata: {name: "regsecret", namespace: "pg-dr"}, data: {x: ("eA==")}}' > "$TMP/cl/c2/secret/pg-dr/regsecret.json"
RK=c2.orders-dr; mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c2/pg-dr/orders-dr "$BACKUP_T"; run "$PJ"
expect "a new namespace with a Secret regsecret the fleet does not manage: NAMESPACE_SECRET_CONFLICT (the new owner would overwrite it)" FAILED NAMESPACE_SECRET_CONFLICT "regsecret"
reset
mkdir -p "$TMP/cl/c2/secret/pg-dr"
jq -cn '{kind: "Secret", metadata: {name: "backup-storage", namespace: "pg-dr", annotations: {"argocd.argoproj.io/tracking-id": "tpg-c2-other:x"}}, data: {x: "eA=="}}' > "$TMP/cl/c2/secret/pg-dr/backup-storage.json"
run "$PJ"
expect "a Secret the fleet manages (tracked by tpg-c2-*) is no conflict" SUCCEEDED DRY_RUN
reset
mkdir -p "$TMP/cl/c2/secret/pg-dr"
jq -cn '{kind: "Secret", metadata: {name: "backup-storage", namespace: "pg-dr"}, data: {x: ("eA==")}}' > "$TMP/cl/c2/secret/pg-dr/backup-storage.json"
set_flag tkfail.c2.vaultstaticsecret
run "$PJ"
expect "a Secret created by hand is a conflict even when the VaultStaticSecret cannot be read (fail closed)" FAILED NAMESPACE_SECRET_CONFLICT
reset
yq -i '.clusters.c2.instances.pg-dr-owner.instance = {"namespace": "pg-dr", "postgresVersion": "postgres-17.6"}' "$TMP/fleet.repo/clusters/fleet.yaml"
mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c2/pg-dr/orders-dr "$BACKUP_T"; run "$PJ"
expect "a namespace that has an owner already: the new target joins it" SUCCEEDED DRY_RUN
grep -q 'owned by pg-dr-owner' "$TMP/rec/plan.restore.c2.orders-dr.detail" && ok "the plan names the existing owner (pg-dr-owner): the new entry would get sharedSecretsOwner false" || bad "owner plan" "$(cat "$TMP/rec/plan.restore.c2.orders-dr.detail")"

echo "== 6. the location copy and its Secret (dry run)"
reset
RK=c2.orders-dr
mkdir -p "$TMP/cl/c2/postgresbackuplocation/pg-dr"
printf '%s' '{"kind":"PostgresBackupLocation","metadata":{"name":"earlier-copy","namespace":"pg-dr"},"spec":{"storage":{"azure":{"container":"pg-backups-c1","repoPath":"/pg-orders"}},"backupSync":{"enabled":true}}}' > "$TMP/cl/c2/postgresbackuplocation/pg-dr/earlier-copy.json"
mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c2/pg-dr/orders-dr "$BACKUP_T"; run "$PJ"
expect "an existing location for the same container and repoPath with backupSync on: reused" SUCCEEDED DRY_RUN
grep -q 'pg-dr/earlier-copy on c2 already points at pg-backups-c1/pg-orders with backupSync on: reused' "$TMP/rec/plan.restore.c2.orders-dr.detail" && ok "the plan says it is reused, not created and never removed" || bad "reuse plan" "$(cat "$TMP/rec/plan.restore.c2.orders-dr.detail")"
! grep -q 'PostgresBackupLocation pg-dr/restore-src' "$TMP/rec/plan.restore.c2.orders-dr.detail" && ok "no copy is rendered when one is reused" || bad "copy rendered although reused"
jq '.spec.backupSync.enabled = false' "$TMP/cl/c2/postgresbackuplocation/pg-dr/earlier-copy.json" > "$TMP/x" && mv "$TMP/x" "$TMP/cl/c2/postgresbackuplocation/pg-dr/earlier-copy.json"
run "$PJ"
expect "…with backupSync disabled: SOURCE_LOCATION_CONFLICT" FAILED SOURCE_LOCATION_CONFLICT "backupSync disabled" "enable backupSync"
rm -f "$TMP/cl/c2/postgresbackuplocation/pg-dr/earlier-copy.json"
printf '%s' '{"kind":"PostgresBackupLocation","metadata":{"name":"restore-src-c1-pg-orders-orders-db","namespace":"pg-dr"},"spec":{"storage":{"azure":{"container":"other","repoPath":"/x"}},"backupSync":{"enabled":true}}}' > "$TMP/cl/c2/postgresbackuplocation/pg-dr/restore-src-c1-pg-orders-orders-db.json"
run "$PJ"
expect "the copy's name taken by a location of another repository: SOURCE_LOCATION_CONFLICT" FAILED SOURCE_LOCATION_CONFLICT "another repository"
# a list of the locations that fails is not an empty list: the pair fails closed, in a dry run too
reset
set_flag tkfail.nslist.c2.postgresbackuplocation
mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c2/pg-dr/orders-dr "$BACKUP_T"; run "$PJ"
expect "the PostgresBackupLocations of the target namespace cannot be listed: TARGET_UNREADABLE, not an empty list (dry run)" FAILED TARGET_UNREADABLE "PostgresBackupLocations" "pg-dr" "Forbidden"
run "$PJ" P_DRY_RUN=false
expect "…and in a real run, before anything is created" FAILED TARGET_UNREADABLE "PostgresBackupLocations"
! ev_has '^(apply|push|sync|create|label)' && ok "…nothing was created, applied or pushed" || bad "acted after the unreadable list" "$(cat "$TMP/events")"
reset
mk c1/pg-legacy/legacy-db 'sourceBackupName: legacy-full-1' c2/pg-dr/orders-dr $'pitrEnabled: false\ntargetInstanceSpecFilePath: [repo:helm_artifacts/instance/tpg-instance/restore-specs/legacy.yaml]'; run "$PJ"
expect "a source location with its own Secret (src-creds): planned" SUCCEEDED DRY_RUN
grep -q 'Secret restore-src-c1-pg-legacy-legacy-db-creds .*: copied from c1/pg-legacy/src-creds in memory' "$TMP/rec/plan.restore.c2.orders-dr.detail" && ok "the plan says the copy gets its own Secret (named after the copy), copied in memory" || bad "secret plan" "$(cat "$TMP/rec/plan.restore.c2.orders-dr.detail")"
RKP=c2.orders-dr; C="$(plan_block 'PostgresBackupLocation .* on ')"
[[ "$(yq '.spec.storage.azure.secret.name' <<<"$C")" == restore-src-c1-pg-legacy-legacy-db-creds ]] \
  && ok "…and the copy's spec.storage.azure.secret.name points at it (not at the source's src-creds)" || bad "copy secret name" "$C"
rm -f "$TMP/cl/c1/secret/pg-legacy/src-creds.json"
run "$PJ"
expect "…a source Secret that cannot be read: SOURCE_SECRET_UNREADABLE (also in a dry run)" FAILED SOURCE_SECRET_UNREADABLE "src-creds"
no_secret_leak "dry runs" "$COPIED" "$VAULT_KEY"

echo "== 7. real runs"
reset
RK=c2.orders-dr
set_flag sync.names "orders-full-1 orders-full-0"
mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c2/pg-dr/orders-dr "$BACKUP_T"; run "$PJ" P_DRY_RUN=false
expect "a named backup onto a new instance of another cluster and namespace: SUCCEEDED" SUCCEEDED "" "restored c1/pg-orders/orders-db into c2/pg-dr/orders-dr" "PostgresBackup pg-dr/orders-full-1 synced and Succeeded" "Application tpg-c2-orders-dr synced"
order="$(grep -nE '^(push|label c2 namespace|sync tpg-c2-orders-dr resources=:ServiceAccount|sync tpg-c2-orders-dr resources=sql|apply c2 postgresbackuplocation|apply c2 postgresrestore|wait ready|adopt)' "$TMP/events" | sed -E 's/^[0-9]+://' | cut -c1-48 | paste -sd'|' -)"
want="push mode=direct restore: add c2/orders-dr from c1/orders-db (tpg-restore-x)|label c2 namespace pg-dr|sync tpg-c2-orders-dr resources=:ServiceAccount:pg-dr/tpg-vso,secrets.hashicorp.com|sync tpg-c2-orders-dr resources=sql.tanzu.vmware.com:PostgresBackupLocation:pg-dr/orders-dr|apply c2 postgresbackuplocation pg-dr/restore-src-c1-pg-orders-orders-db|apply c2 postgresrestore pg-dr/orders-dr-restore|wait ready orders-dr|push mode=direct restore: record the restore-patch of c2/orders-dr|adopt c2 orders-dr"
want="$(cut -c1-48 <<<"${want//|/$'\n'}" | paste -sd'|' -)"
[[ "$order" == "$want" ]] && ok "the order: entry pushed, namespace, shared objects synced by the owner's Application, the new instance's location synced, source location copied, restore, instance Running, restore-patch (the spec read from the cluster) pushed, adoption" || bad "order of steps" "$order
$want
$(cat "$TMP/events")"
! ev_has 'APPLIED-SHARED' && ok "no VaultStaticSecret or ServiceAccount is ever kubectl-applied (only the owner's Application syncs them)" || bad "shared objects applied" "$(cat "$TMP/events")"
E="$(yq '.clusters.c2.instances.orders-dr' "$TMP/fleet.repo/clusters/fleet.yaml")"
[[ "$(yq '.instance.namespace' <<<"$E")" == pg-dr && "$(yq '.instance | has("disableInitialBackup")' <<<"$E")" == false && "$(yq '.backup | has("repoPath")' <<<"$E")" == false \
   && "$(yq 'has("ferret")' <<<"$E")" == false && "$(yq '.instance | has("sharedSecretsOwner")' <<<"$E")" == false && "$(yq '.instance.postgresVersion' <<<"$E")" == postgres-17.6 ]] \
  && ok "the entry in clusters/fleet.yaml: copy of the source's with instance.namespace, without disableInitialBackup, backup.repoPath and ferret; the first instance of its namespace owns the shared Secrets" || bad "fleet entry" "$E"
[[ "$(yq '.clusters.c1.instances.orders-db.backup.repoPath' "$TMP/fleet.repo/clusters/fleet.yaml")" == /pg-orders ]] && ok "the source entry is untouched" || bad "source entry changed"
[[ -f "$TMP/cl/c2/postgresbackuplocation/pg-dr/restore-src-c1-pg-orders-orders-db.json" ]] && ok "keepSourceLocation (default true): the copy stays in the target namespace" || bad "copy removed"
jq -e '.metadata.labels["tpg.fleet/restore-source"] == "c1.orders-db"' "$TMP/cl/c2/postgresbackuplocation/pg-dr/restore-src-c1-pg-orders-orders-db.json" >/dev/null && ok "…labelled tpg.fleet/restore-source" || bad "copy label"
grep -q 'kept (delete it by hand' <<<"$(detail)" && ok "…and the result says it is kept" || bad "kept note" "$(detail)"
no_secret_leak "backup-storage from Vault" "$VAULT_KEY"

echo "-- keepSourceLocation=false removes the copy this run created, and only that"
reset
set_flag sync.names "orders-full-1"
run "$PJ" P_DRY_RUN=false P_KEEP_SOURCE_LOCATION=false
expect "keepSourceLocation=false: SUCCEEDED" SUCCEEDED "" "removed (keepSourceLocation=false)"
[[ ! -f "$TMP/cl/c2/postgresbackuplocation/pg-dr/restore-src-c1-pg-orders-orders-db.json" ]] && ev_has '^delete c2 postgresbackuplocation pg-dr/restore-src' && ok "the copy is deleted after the success" || bad "copy not deleted" "$(cat "$TMP/events")"
reset
set_flag sync.names "orders-full-1"
mkdir -p "$TMP/cl/c2/postgresrestore/pg-dr"
printf '%s' '{"kind":"PostgresRestore","metadata":{"name":"other-restore","namespace":"pg-dr"},"spec":{"targetInstance":{"name":"other"}},"status":{"phase":"Running"}}' > "$TMP/cl/c2/postgresrestore/pg-dr/other-restore.json"
run "$PJ" P_DRY_RUN=false P_KEEP_SOURCE_LOCATION=false
expect "keepSourceLocation=false while another restore of the namespace is unfinished: SUCCEEDED, the copy is kept" SUCCEEDED "" "kept although keepSourceLocation=false" "other-restore"
[[ -f "$TMP/cl/c2/postgresbackuplocation/pg-dr/restore-src-c1-pg-orders-orders-db.json" ]] && ! ev_has '^delete' && ok "…nothing is deleted" || bad "copy deleted under a running restore" "$(cat "$TMP/events")"
reset
set_flag sync.names "orders-full-1"
mkdir -p "$TMP/cl/c2/postgresbackuplocation/pg-dr"
printf '%s' '{"kind":"PostgresBackupLocation","metadata":{"name":"earlier-copy","namespace":"pg-dr"},"spec":{"storage":{"azure":{"container":"pg-backups-c1","repoPath":"/pg-orders"}},"backupSync":{"enabled":true}}}' > "$TMP/cl/c2/postgresbackuplocation/pg-dr/earlier-copy.json"
mkdir -p "$TMP/cl/c2/postgresbackup/pg-dr"
printf '%s' '{"kind":"PostgresBackup","metadata":{"name":"orders-full-1","namespace":"pg-dr"},"status":{"phase":"Succeeded"}}' > "$TMP/cl/c2/postgresbackup/pg-dr/orders-full-1.json"
run "$PJ" P_DRY_RUN=false P_KEEP_SOURCE_LOCATION=false
expect "a reused location with keepSourceLocation=false: SUCCEEDED" SUCCEEDED ""
[[ -f "$TMP/cl/c2/postgresbackuplocation/pg-dr/earlier-copy.json" ]] && ! ev_has '^delete' && ! ev_has 'apply c2 postgresbackuplocation' && ok "…the reused location is neither created nor deleted" || bad "reused location touched" "$(cat "$TMP/events")"
jq -e --arg n earlier-copy '.spec | tostring | contains("earlier-copy")' "$TMP/cl/c2/postgresrestore/pg-dr/"*.json >/dev/null 2>&1 && ok "…and the PostgresRestore does not depend on a new copy (named backup: spec.sourceBackup.name)" || ok "…the named backup restore uses spec.sourceBackup.name"

echo "-- keepSourceLocation=false keeps a copy that an instance of the namespace uses (SOURCE_LOCATION_IN_USE)"
COPYN=restore-src-c1-pg-orders-orders-db
COPYF="$TMP/cl/c2/postgresbackuplocation/pg-dr/$COPYN.json"
RK=c2.orders-dr
reset
mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c2/pg-dr/orders-dr "$BACKUP_T"
set_flag sync.names "orders-full-1"
# live snapshot: the operator gave the restored Postgres the copy as its backupLocation
run "$PJ" P_DRY_RUN=false P_KEEP_SOURCE_LOCATION=false SNAP_EXTRA='{"backupLocation":{"name":"'"$COPYN"'"}}'
expect "a restored Postgres (live snapshot) that uses the copy: SUCCEEDED, the copy is kept" SUCCEEDED "" "SOURCE_LOCATION_IN_USE" "orders-dr"
[[ -f "$COPYF" ]] && ! ev_has '^delete' && ok "…the copy is not deleted" || bad "copy deleted while the restored instance uses it" "$(cat "$TMP/events")"
[[ "$(cat "$TMP/rec/warning.c2.orders-dr.SOURCE_LOCATION_IN_USE.status" 2>/dev/null)" == WARNING ]] \
  && grep -qF "$COPYN" "$TMP/rec/warning.c2.orders-dr.SOURCE_LOCATION_IN_USE.detail" && grep -qF "orders-dr" "$TMP/rec/warning.c2.orders-dr.SOURCE_LOCATION_IN_USE.detail" \
  && ok "…SOURCE_LOCATION_IN_USE is a warning of the report that names the copy and the instance" || bad "in-use warning" "$(cat "$TMP/records")"
# a spec file that names the copy: planned (the copy is created by this run before the instance needs it), kept after the restore
reset
RK=c2.orders-dr; mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c2/pg-dr/orders-dr "$BACKUP_T"$'\ntargetInstanceSpecFilePath: [repo:helm_artifacts/instance/tpg-instance/restore-specs/orders-copyloc.yaml]'
run "$PJ"
expect "a spec file that names the copy this run creates: the dry run plans it (not BACKUP_LOCATION_MISSING)" SUCCEEDED DRY_RUN
set_flag sync.names "orders-full-1"
run "$PJ" P_DRY_RUN=false P_KEEP_SOURCE_LOCATION=false
expect "…a real run with keepSourceLocation=false: SUCCEEDED, the copy is kept" SUCCEEDED "" "SOURCE_LOCATION_IN_USE" "orders-dr"
[[ -f "$COPYF" ]] && ! ev_has '^delete' && ok "…the copy named by the spec file is not deleted" || bad "copy deleted while the spec file names it" "$(cat "$TMP/events")"
# the spec file names the fixed copy name, but this run reuses another location for the same repository: that name does not exist
reset
mkdir -p "$TMP/cl/c2/postgresbackuplocation/pg-dr"
printf '%s' '{"kind":"PostgresBackupLocation","metadata":{"name":"earlier-copy","namespace":"pg-dr"},"spec":{"storage":{"azure":{"container":"pg-backups-c1","repoPath":"/pg-orders"}},"backupSync":{"enabled":true}}}' > "$TMP/cl/c2/postgresbackuplocation/pg-dr/earlier-copy.json"
run "$PJ"
expect "a spec file that names the copy's fixed name while another location is reused: BACKUP_LOCATION_MISSING" FAILED BACKUP_LOCATION_MISSING "$COPYN" "earlier-copy"
# another instance of the target namespace uses the copy: kept, named
reset
mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c2/pg-dr/orders-dr "$BACKUP_T"
set_flag sync.names "orders-full-1"
seed_pg() { mkdir -p "$TMP/cl/c2/postgres/pg-dr"; jq -cn --arg n "$1" --arg l "$2" '{kind: "Postgres", metadata: {name: $n, namespace: "pg-dr"}, spec: {postgresVersion: {name: "postgres-17.6"}, backupLocation: {name: $l}}}' > "$TMP/cl/c2/postgres/pg-dr/$1.json"; }
seed_pg neighbour-db "$COPYN"
run "$PJ" P_DRY_RUN=false P_KEEP_SOURCE_LOCATION=false
expect "another Postgres of the namespace uses the copy: SUCCEEDED, kept, the warning names that instance" SUCCEEDED "" "SOURCE_LOCATION_IN_USE" "neighbour-db"
[[ -f "$COPYF" ]] && ! ev_has '^delete' && ok "…the copy is not deleted" || bad "copy deleted while a neighbour uses it" "$(cat "$TMP/events")"
# every Postgres of the namespace is read: instances that use other locations do not keep it
reset
set_flag sync.names "orders-full-1"
seed_pg neighbour-db some-other-location
run "$PJ" P_DRY_RUN=false P_KEEP_SOURCE_LOCATION=false
expect "no Postgres of the namespace uses the copy (a neighbour uses another location): SUCCEEDED, removed" SUCCEEDED "" "removed (keepSourceLocation=false)"
[[ ! -f "$COPYF" ]] && ev_has '^delete c2 postgresbackuplocation pg-dr/restore-src' && [[ ! -e "$TMP/rec/warning.c2.orders-dr.SOURCE_LOCATION_IN_USE.status" ]] \
  && ok "…the copy is deleted and there is no SOURCE_LOCATION_IN_USE warning" || bad "copy not removed although unused" "$(cat "$TMP/events")"
# the Postgres list of the namespace cannot be read: the copy is kept (fail closed) with the warning SOURCE_LOCATION_NOT_REMOVED
reset
set_flag sync.names "orders-full-1"; set_flag tkfail.nslist.c2.postgres
run "$PJ" P_DRY_RUN=false P_KEEP_SOURCE_LOCATION=false
expect "the Postgres list of the namespace cannot be read: SUCCEEDED, the copy is kept (SOURCE_LOCATION_NOT_REMOVED)" SUCCEEDED "" "SOURCE_LOCATION_NOT_REMOVED" "Forbidden"
[[ -f "$COPYF" ]] && ! ev_has '^delete' && ok "…nothing is deleted when no instance can be ruled out" || bad "copy deleted without checking" "$(cat "$TMP/events")"
# the delete itself fails: the pair stays SUCCEEDED with the warning SOURCE_LOCATION_NOT_REMOVED
reset
set_flag sync.names "orders-full-1"; set_flag delete.fail.postgresbackuplocation
run "$PJ" P_DRY_RUN=false P_KEEP_SOURCE_LOCATION=false
expect "the copy cannot be deleted: SUCCEEDED with the warning SOURCE_LOCATION_NOT_REMOVED" SUCCEEDED "" "SOURCE_LOCATION_NOT_REMOVED" "delete it by hand"
[[ "$(cat "$TMP/rec/warning.c2.orders-dr.SOURCE_LOCATION_NOT_REMOVED.status" 2>/dev/null)" == WARNING ]] && ok "…recorded as a warning of the report" || bad "not-removed warning" "$(cat "$TMP/records")"

echo "-- the wait for the synced backup"
reset
set_flag sync.mode never; set_flag sync.names "orders-full-1"
run "$PJ" P_DRY_RUN=false P_TIMEOUT=60
expect "the backup never appears: BACKUPS_NOT_SYNCED naming the last phase" FAILED BACKUPS_NOT_SYNCED "did not appear Succeeded" "last phase seen: not there"
! ev_has 'apply c2 postgresrestore' && ok "no PostgresRestore is created before the backup is there" || bad "restore created"
reset
set_flag sync.mode failed; set_flag sync.names "orders-full-1"
run "$PJ" P_DRY_RUN=false
expect "the synced backup is Failed: BACKUP_NOT_SUCCEEDED at once" FAILED BACKUP_NOT_SUCCEEDED "is Failed"
reset
set_flag sync.mode running; set_flag sync.names "orders-full-1"
run "$PJ" P_DRY_RUN=false P_TIMEOUT=60
expect "the synced backup stays Running: BACKUPS_NOT_SYNCED with the last phase" FAILED BACKUPS_NOT_SYNCED "last phase seen: Running"

echo "-- the restore phase"
reset
set_flag sync.names "orders-full-1"; set_flag restore.phase Failed
run "$PJ" P_DRY_RUN=false
expect "the PostgresRestore fails: RESTORE_FAILED with the operator's message" FAILED RESTORE_FAILED "restore pod failed: stub"
reset
set_flag sync.names "orders-full-1"; set_flag restore.phase Running
run "$PJ" P_DRY_RUN=false P_TIMEOUT=100
expect "the PostgresRestore does not finish in restoreTimeoutSeconds: TIMEOUT with its phase" TIMEOUT "" "phase=Running"
reset
set_flag sync.names "orders-full-1"; set_flag target.notrunning
run "$PJ" P_DRY_RUN=false
expect "the restore Succeeded but the instance does not run: TARGET_CRASHLOOP" FAILED TARGET_CRASHLOOP "CrashLoopBackOff"
reset
set_flag sync.names "orders-full-1"; set_flag apply.fail.postgresrestore
run "$PJ" P_DRY_RUN=false
expect "the PostgresRestore cannot be created: CREATE_FAILED" FAILED CREATE_FAILED
reset
set_flag sync.names "orders-full-1"; set_flag adopt.fail
run "$PJ" P_DRY_RUN=false
expect "the Application does not sync after the restore: the pair still SUCCEEDED (restore Succeeded, target Running) with a warning" SUCCEEDED "" "did not sync after the restore"
[[ -e "$TMP/rec/warning.c2.orders-dr.ADOPTION_NOT_SYNCED.status" ]] && ok "ADOPTION_NOT_SYNCED is a warning" || bad "adoption warning"
reset
set_flag sync.names "orders-full-1"; set_flag push.fail
run "$PJ" P_DRY_RUN=false
expect "the entry cannot be pushed: GIT_PUSH_FAILED, nothing else happened" FAILED GIT_PUSH_FAILED "pushMode=direct"
! ev_has '^(sync|apply)' && ok "…no sync and no object before the push succeeded" || bad "acted before the push" "$(cat "$TMP/events")"
: > "$TMP/events"
set_flag push.fail
run "$PJ" P_DRY_RUN=false P_PUSH_MODE=pr
expect "pushMode pr: the failure names the mode" FAILED GIT_PUSH_FAILED "pushMode=pr"
ev_has 'push mode=pr' && ! ev_has 'lock acquire' && ok "pushMode pr: no fleet lock is held while a pull request waits" || bad "pr mode" "$(cat "$TMP/events")"
reset
set_flag app.missing
run "$PJ" P_DRY_RUN=false
expect "the ApplicationSet does not generate the Application: APP_NOT_GENERATED" FAILED APP_NOT_GENERATED "tpg-c2-orders-dr"
reset
set_flag sync.fail
run "$PJ" P_DRY_RUN=false
expect "the owner's shared objects do not sync: SHARED_SECRETS_MISSING with the sync reason" FAILED SHARED_SECRETS_MISSING "SYNC_FAILED"
reset
set_flag clone.fail
run "$PJ"
expect "the fleet repository cannot be cloned: FLEET_UNREADABLE" FAILED FLEET_UNREADABLE

echo "-- new targets and the owner of the shared Secrets"
reset
set_flag sync.names "orders-full-1"
RK=c1.orders-copy; mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c1/pg-orders/orders-copy "$BACKUP_T"; run "$PJ" P_DRY_RUN=false
expect "a new instance in the source namespace: SUCCEEDED" SUCCEEDED ""
E="$(yq '.clusters.c1.instances.orders-copy' "$TMP/fleet.repo/clusters/fleet.yaml")"
[[ "$(yq '.instance.sharedSecretsOwner' <<<"$E")" == false && "$(yq '.backup | has("repoPath")' <<<"$E")" == false ]] \
  && ok "it joins a namespace that has an owner: sharedSecretsOwner false, and it gets its own repository path (repoPath dropped)" || bad "joiner entry" "$E"
! ev_has 'resources=:ServiceAccount' && ! ev_has 'APPLIED-SHARED' && ok "…and syncs no shared object (both Secrets exist; ensure_shared_secrets has nothing to do)" || bad "joiner synced shared" "$(cat "$TMP/events")"
! ev_has 'apply c1 postgresbackuplocation' && ok "a restore inside the source namespace creates no location copy" || bad "unexpected copy" "$(cat "$TMP/events")"
reset
set_flag sync.names "orders-full-1"
RK=c2.orders-a; mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c2/pg-dr/orders-a "$BACKUP_T"; run "$PJ" P_DRY_RUN=false
RK=c2.orders-b; mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c2/pg-dr/orders-b "$BACKUP_T"; run "$PJ" P_DRY_RUN=false
n_own="$(yq '[.clusters.c2.instances | to_entries[] | select(.value.instance.namespace == "pg-dr" and (.value.instance.sharedSecretsOwner != false))] | length' "$TMP/fleet.repo/clusters/fleet.yaml")"
[[ "$n_own" == 1 && "$(yq '.clusters.c2.instances.orders-b.instance.sharedSecretsOwner' "$TMP/fleet.repo/clusters/fleet.yaml")" == false ]] \
  && ok "two new targets into one new namespace: exactly one owner (the second sees the first's entry on the fresh clone under the fleet lock)" || bad "two owners" "$(yq '.clusters.c2.instances' "$TMP/fleet.repo/clusters/fleet.yaml")"
ev_has 'lock acquire' && ev_has 'lock release' && ok "direct mode decides the owner under the fleet lock" || bad "lock events"
reset
set_flag sync.names "orders-full-1"; set_flag push.race orders-race
RK=c2.orders-a; mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c2/pg-dr-new/orders-a "$BACKUP_T"; run "$PJ" P_DRY_RUN=false P_PUSH_MODE=pr
expect "two owners after the pushes (pull requests merged side by side): NAMESPACE_OWNER_CONFLICT before any sync" FAILED NAMESPACE_OWNER_CONFLICT "instance.sharedSecretsOwner: false"
! ev_has '^(sync|apply c2 postgresrestore)' && ok "…nothing was synced or restored" || bad "acted after the conflict" "$(cat "$TMP/events")"

reset
set_flag sync.names "orders-full-1"
declare_db() {  # declare_db: c2/declared-db in pg-declared as a user could have declared it, with settings that must not survive a restore into it
  yq -i '.clusters.c2.instances.declared-db = {"instance": {"namespace": "pg-declared", "postgresVersion": "postgres-17.6", "disableInitialBackup": true, "sharedSecretsOwner": false, "storageSize": "7Gi"},
    "ferret": {"enabled": true, "replicas": 2}, "patches": {"postgres": {"current": "patches/declared-ex4m1.yaml"}},
    "backup": {"repoPath": "/declared-own"}}' "$TMP/fleet.repo/clusters/fleet.yaml"
}
declare_db
RK=c2.declared-db; mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c2/pg-declared/declared-db "$BACKUP_T"; run "$PJ" P_DRY_RUN=false
expect "an instance declared in clusters/fleet.yaml but not deployed is a new target: restored into, SUCCEEDED" SUCCEEDED "" "restored c1/pg-orders/orders-db into c2/pg-declared/declared-db"
E="$(yq '.clusters.c2.instances.declared-db' "$TMP/fleet.repo/clusters/fleet.yaml")"
[[ "$(grep -c '^push' "$TMP/events")" -eq 2 ]] && ev_has 'push mode=direct restore: add c2/declared-db from c1/orders-db' && ev_has 'push mode=direct restore: record the restore-patch of c2/declared-db' \
  && ev_has 'resources=:ServiceAccount:pg-declared/tpg-vso' && ev_has '^adopt c2 declared-db' \
  && [[ "$(yq '.instance.namespace' <<<"$E")" == pg-declared ]] \
  && ok "…the declared entry is replaced like a new target's (pushed first, then the restore-patch read from the cluster), keeping its namespace; its Application provides the shared objects and adopts the restored instance" || bad "declared target" "$(cat "$TMP/events")
$E"
[[ "$(yq 'has("ferret")' <<<"$E")" == false && "$(yq '.patches // {} | has("postgres")' <<<"$E")" == false && "$(yq '.instance | has("disableInitialBackup")' <<<"$E")" == false \
   && "$(yq '.instance | has("sharedSecretsOwner")' <<<"$E")" == false && "$(yq '.instance.storageSize' <<<"$E")" != 7Gi && "$(yq '.backup | has("repoPath")' <<<"$E")" == false ]] \
  && ok "…and nothing of the declared entry survives: no ferret, patches.postgres, disableInitialBackup, foreign sharedSecretsOwner, storageSize 7Gi or backup.repoPath (the entry is a copy of the source's, with the source's disableInitialBackup, ferret and repoPath dropped)" || bad "declared entry survived" "$E"
reset
declare_db
yq -i '.clusters.c2.instances.declared-db.instance.sharedSecretsOwner = true' "$TMP/fleet.repo/clusters/fleet.yaml"
yq -i '.clusters.c2.instances.pg-declared-owner.instance = {"namespace": "pg-declared", "postgresVersion": "postgres-17.6"}' "$TMP/fleet.repo/clusters/fleet.yaml"
run "$PJ"
expect "a declared entry that claims the shared Secrets of a namespace another instance owns: planned" SUCCEEDED DRY_RUN
grep -q 'shared Secrets of pg-declared: owned by pg-declared-owner' "$TMP/rec/plan.restore.c2.declared-db.detail" && ok "…the replaced entry follows the owner rules (the other instance keeps them), not the declared flag" || bad "declared owner" "$(cat "$TMP/rec/plan.restore.c2.declared-db.detail")"
reset
mkdir -p "$TMP/cl/c2/secret/pg-declared"
jq -cn '{kind: "Secret", metadata: {name: "regsecret", namespace: "pg-declared"}, data: {x: ("eA==")}}' > "$TMP/cl/c2/secret/pg-declared/regsecret.json"
declare_db
run "$PJ"
expect "a declared entry in a namespace with a Secret regsecret the fleet does not manage: NAMESPACE_SECRET_CONFLICT (a new target's check, also in a dry run)" FAILED NAMESPACE_SECRET_CONFLICT "regsecret"

echo "-- an in-place target: confirm, in-progress and busy (any other existing target is TARGET_EXISTS)"
reset
RK=c1.orders-db; set_flag sync.names "orders-full-1"
rm -f "$TMP/cl/c1/postgresbackup/pg-orders/orders-running.json"   # a running backup of the instance blocks a real in-place restore
mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c1/pg-orders/orders-db $'pitrEnabled: false\nconfirm: orders-db'; run "$PJ" P_DRY_RUN=false
expect "an in-place restore with confirm: SUCCEEDED" SUCCEEDED "" "restored c1/pg-orders/orders-db into c1/pg-orders/orders-db"
! ev_has '^adopt' && ok "in place: no adoption sync (the instance is managed already)" || bad "in place adopted" "$(cat "$TMP/events")"
Y="$(jq -c '.spec' "$TMP/cl/c1/postgresrestore/pg-orders/"*.json)"
[[ "$(jq 'has("targetInstance") and (.targetInstance | has("spec") | not)' <<<"$Y")" == true ]] && ok "…and its PostgresRestore carries no instance spec" || bad "in place restore spec" "$Y"
! ev_has 'apply c1 postgresbackuplocation' && ! ev_has 'APPLIED-SHARED' && ok "…no location copy and no shared object (same namespace)" || bad "in place copy" "$(cat "$TMP/events")"
reset
set_flag sync.names "orders-full-1"
mkdir -p "$TMP/cl/c1/postgresbackup/pg-orders"
run "$PJ" P_DRY_RUN=false
expect "a backup is running on the in-place target: OPERATION_IN_PROGRESS" FAILED OPERATION_IN_PROGRESS "postgresbackup"
reset
rm -f "$TMP/cl/c1/postgresbackup/pg-orders/orders-running.json"
mkdir -p "$TMP/cl/c1/postgresrestore/pg-orders"
printf '%s' '{"kind":"PostgresRestore","metadata":{"name":"orders-db-restore-old","namespace":"pg-orders","creationTimestamp":"2026-10-01T00:00:00Z"},"spec":{"targetInstance":{"name":"orders-db"}},"status":{"phase":"Running"}}' > "$TMP/cl/c1/postgresrestore/pg-orders/orders-db-restore-old.json"
run "$PJ" P_DRY_RUN=false
expect "a restore of the target is still running: SKIPPED_IN_PROGRESS after the wait" SKIPPED_IN_PROGRESS "" "orders-db-restore-old phase Running"

echo "-- the Secret of the copied location: one Secret per copy, named after the copy"
SECA=restore-src-c1-pg-legacy-legacy-db-creds      # the Secret of the copy of c1/pg-legacy/legacy-db
SECB=restore-src-c1-pg-legacy2-legacy2-db-creds    # the Secret of the copy of c1/pg-legacy2/legacy2-db
LEGACY_SPEC=$'pitrEnabled: false\ntargetInstanceSpecFilePath: [repo:helm_artifacts/instance/tpg-instance/restore-specs/legacy.yaml]'
secret_data() { jq -r '.data.accountKey | @base64d' "$TMP/cl/c2/secret/pg-dr/$1.json" 2>/dev/null || true; }
secret_label() { jq -r '.metadata.labels["tpg.fleet/restore-source"] // ""' "$TMP/cl/c2/secret/pg-dr/$1.json" 2>/dev/null || true; }
reset
RK=c2.orders-dr
set_flag sync.names "legacy-full-1"
mk c1/pg-legacy/legacy-db 'sourceBackupName: legacy-full-1' c2/pg-dr/orders-dr "$LEGACY_SPEC"; run "$PJ" P_DRY_RUN=false
expect "a location with its own Secret: SUCCEEDED, the Secret copied under the copy's own name" SUCCEEDED "" "Secret pg-dr/${SECA} was copied from c1/pg-legacy/src-creds"
[[ "$(secret_data "$SECA")" == "$COPIED" && "$(secret_label "$SECA")" == c1.legacy-db ]] \
  && ok "the target namespace has the Secret ${SECA} with the source's data, labelled as a restore copy" || bad "copied secret" "$(cat "$TMP/cl/c2/secret/pg-dr/$SECA.json" 2>/dev/null)"
[[ ! -e "$TMP/cl/c2/secret/pg-dr/src-creds.json" ]] && ok "…and no Secret src-creds (the source's name) is written to the target namespace" || bad "src-creds written"
[[ "$(jq -r '.spec.storage.azure.secret.name' "$TMP/cl/c2/postgresbackuplocation/pg-dr/restore-src-c1-pg-legacy-legacy-db.json")" == "$SECA" ]] \
  && ok "…the applied copy of the location reads it (spec.storage.azure.secret.name)" || bad "copy secret name" "$(cat "$TMP/cl/c2/postgresbackuplocation/pg-dr/restore-src-c1-pg-legacy-legacy-db.json")"
no_secret_leak "copied Secret" "$COPIED"

echo "-- two sources whose locations use a Secret of the same name, into one target namespace: both keep working"
set_flag sync.names "legacy-full-1 legacy2-full-1"
RK=c2.orders-dr2; mk c1/pg-legacy2/legacy2-db 'sourceBackupName: legacy2-full-1' c2/pg-dr/orders-dr2 "$LEGACY_SPEC"; run "$PJ" P_DRY_RUN=false
expect "the second source (src-creds with other contents) is restored into the same namespace: SUCCEEDED" SUCCEEDED "" "Secret pg-dr/${SECB} was copied from c1/pg-legacy2/src-creds"
[[ "$(secret_data "$SECA")" == "$COPIED" && "$(secret_data "$SECB")" == "$COPIED2" && "$(secret_label "$SECA")" == c1.legacy-db && "$(secret_label "$SECB")" == c1.legacy2-db ]] \
  && ok "each copy has its own Secret with its own contents; the first one is untouched" || bad "two secrets" "$(ls "$TMP/cl/c2/secret/pg-dr")"
[[ "$(jq -r '.spec.storage.azure.secret.name' "$TMP/cl/c2/postgresbackuplocation/pg-dr/restore-src-c1-pg-legacy-legacy-db.json")" == "$SECA" \
   && "$(jq -r '.spec.storage.azure.secret.name' "$TMP/cl/c2/postgresbackuplocation/pg-dr/restore-src-c1-pg-legacy2-legacy2-db.json")" == "$SECB" ]] \
  && ok "…and each location reads its own" || bad "location secrets"
no_secret_leak "two copied Secrets" "$COPIED" "$COPIED2"

echo "-- keepSourceLocation=false deletes the copy's own Secret and nothing else"
reset
RK=c2.orders-dr; set_flag sync.names "legacy-full-1 legacy2-full-1"
mk c1/pg-legacy/legacy-db 'sourceBackupName: legacy-full-1' c2/pg-dr/orders-dr "$LEGACY_SPEC"; run "$PJ" P_DRY_RUN=false
RK=c2.orders-dr2; mk c1/pg-legacy2/legacy2-db 'sourceBackupName: legacy2-full-1' c2/pg-dr/orders-dr2 "$LEGACY_SPEC"
# a Secret src-creds of somebody else in the namespace (the name the source locations use)
jq -cn '{kind: "Secret", metadata: {name: "src-creds", namespace: "pg-dr"}, data: {accountKey: ("SOMEBODY-ELSES" | @base64)}}' > "$TMP/cl/c2/secret/pg-dr/src-creds.json"
: > "$TMP/events"; run "$PJ" P_DRY_RUN=false P_KEEP_SOURCE_LOCATION=false
expect "keepSourceLocation=false for the second copy: SUCCEEDED, copy removed" SUCCEEDED "" "restore-src-c1-pg-legacy2-legacy2-db removed (keepSourceLocation=false)"
[[ ! -e "$TMP/cl/c2/secret/pg-dr/$SECB.json" ]] && ev_has "^delete c2 secret pg-dr/${SECB}\$" && ok "its own Secret ${SECB} is deleted with it" || bad "own secret not deleted" "$(cat "$TMP/events")"
[[ "$(secret_data "$SECA")" == "$COPIED" && "$(secret_data src-creds)" == SOMEBODY-ELSES && -e "$TMP/cl/c2/postgresbackuplocation/pg-dr/restore-src-c1-pg-legacy-legacy-db.json" ]] \
  && ! ev_has '^delete c2 secret pg-dr/(src-creds|restore-src-c1-pg-legacy-legacy-db-creds)$' \
  && ok "…the Secret of the first copy (still used by its location) and a foreign src-creds are not touched" || bad "other secrets touched" "$(cat "$TMP/events")"
reset
RK=c2.orders-dr; set_flag sync.names "legacy-full-1"
mk c1/pg-legacy/legacy-db 'sourceBackupName: legacy-full-1' c2/pg-dr/orders-dr "$LEGACY_SPEC"
mkdir -p "$TMP/cl/c2/secret/pg-dr"
jq -cn '{kind: "Secret", metadata: {name: "src-creds", namespace: "pg-dr"}, data: {accountKey: ("OTHER" | @base64)}}' > "$TMP/cl/c2/secret/pg-dr/src-creds.json"
run "$PJ" P_DRY_RUN=false
expect "a Secret src-creds of somebody else with other contents is no conflict any more: the copy has its own Secret" SUCCEEDED ""
[[ "$(secret_data src-creds)" == OTHER && "$(secret_data "$SECA")" == "$COPIED" ]] && ok "…src-creds is left alone" || bad "src-creds changed"

echo "-- the copy's own Secret exists already"
reset
set_flag sync.names "legacy-full-1"
mkdir -p "$TMP/cl/c2/secret/pg-dr"
jq -cn --arg n "$SECA" '{kind: "Secret", metadata: {name: $n, namespace: "pg-dr"}, data: {accountKey: ("OTHER" | @base64)}}' > "$TMP/cl/c2/secret/pg-dr/$SECA.json"
RK=c2.orders-dr; mk c1/pg-legacy/legacy-db 'sourceBackupName: legacy-full-1' c2/pg-dr/orders-dr "$LEGACY_SPEC"; run "$PJ" P_DRY_RUN=false
expect "a Secret of that name with other contents and no restore-source label: SOURCE_SECRET_CONFLICT" FAILED SOURCE_SECRET_CONFLICT "rename that Secret"
[[ "$(secret_data "$SECA")" == OTHER ]] && ok "…it is not overwritten" || bad "secret overwritten"
jq -cn --arg n "$SECA" '{kind: "Secret", metadata: {name: $n, namespace: "pg-dr", labels: {"tpg.fleet/restore-source": "c9.somebody-else"}}, data: {accountKey: ("OTHER" | @base64)}}' > "$TMP/cl/c2/secret/pg-dr/$SECA.json"
run "$PJ" P_DRY_RUN=false
expect "…labelled as the copy of another source (c9.somebody-else): SOURCE_SECRET_CONFLICT" FAILED SOURCE_SECRET_CONFLICT "c9.somebody-else" "c1.legacy-db"
[[ "$(secret_data "$SECA")" == OTHER && "$(secret_label "$SECA")" == c9.somebody-else ]] && ok "…it is not overwritten" || bad "secret of another source overwritten"
! ev_has '^apply c2 (secret|postgresbackuplocation|postgresrestore)' && ok "…and nothing else was applied" || bad "applied after the conflict" "$(cat "$TMP/events")"
jq -cn --arg n "$SECA" '{kind: "Secret", metadata: {name: $n, namespace: "pg-dr", labels: {"tpg.fleet/restore-source": "c9.somebody-else"}}, data: {accountName: ("legacyacct" | @base64), accountKey: ("'"$COPIED"'" | @base64)}}' > "$TMP/cl/c2/secret/pg-dr/$SECA.json"
run "$PJ" P_DRY_RUN=false
expect "…with the contents the source has: no conflict, nothing to update" SUCCEEDED ""
[[ "$(secret_label "$SECA")" == c9.somebody-else ]] && ! ev_has "^apply c2 secret pg-dr/${SECA}\$" && ok "…and it is not written" || bad "identical secret written" "$(cat "$TMP/events")"
reset
set_flag sync.names "legacy-full-1"
mkdir -p "$TMP/cl/c2/secret/pg-dr"
jq -cn --arg n "$SECA" '{kind: "Secret", metadata: {name: $n, namespace: "pg-dr", labels: {"tpg.fleet/restore-source": "c1.legacy-db"}}, data: {accountKey: ("OLD" | @base64)}}' > "$TMP/cl/c2/secret/pg-dr/$SECA.json"
run "$PJ" P_DRY_RUN=false
expect "a Secret of an earlier restore of the same source (label c1.legacy-db) is updated" SUCCEEDED ""
[[ "$(secret_data "$SECA")" == "$COPIED" ]] && ok "…to the source's current contents" || bad "secret not updated"

echo "-- a reused copy keeps using its own Secret"
reset
set_flag sync.names "legacy-full-1"
mkdir -p "$TMP/cl/c2/secret/pg-dr" "$TMP/cl/c2/postgresbackuplocation/pg-dr"
printf '%s' '{"kind":"PostgresBackupLocation","metadata":{"name":"earlier-copy","namespace":"pg-dr"},"spec":{"storage":{"azure":{"container":"legacy-container","repoPath":"/legacy","secret":{"name":"earlier-creds"}}},"backupSync":{"enabled":true}}}' > "$TMP/cl/c2/postgresbackuplocation/pg-dr/earlier-copy.json"
jq -cn '{kind: "Secret", metadata: {name: "earlier-creds", namespace: "pg-dr", labels: {"tpg.fleet/restore-source": "c1.legacy-db"}}, data: {accountKey: ("OLD" | @base64)}}' > "$TMP/cl/c2/secret/pg-dr/earlier-creds.json"
mkdir -p "$TMP/cl/c2/postgresbackup/pg-dr"   # the backups the earlier restore synced
printf '%s' '{"kind":"PostgresBackup","metadata":{"name":"legacy-full-1","namespace":"pg-dr"},"status":{"phase":"Succeeded"}}' > "$TMP/cl/c2/postgresbackup/pg-dr/legacy-full-1.json"
RK=c2.orders-dr; mk c1/pg-legacy/legacy-db 'sourceBackupName: legacy-full-1' c2/pg-dr/orders-dr "$LEGACY_SPEC"; run "$PJ" P_DRY_RUN=false P_KEEP_SOURCE_LOCATION=false
expect "the location of an earlier restore is reused: SUCCEEDED, its Secret earlier-creds refreshed (label equals this source)" SUCCEEDED "" "Secret pg-dr/earlier-creds was copied from c1/pg-legacy/src-creds"
rm -f "$TMP/cl/c2/postgres/pg-dr/orders-dr.json"   # the restored instance of that run, so the next run restores into a new target again
[[ "$(secret_data earlier-creds)" == "$COPIED" && ! -e "$TMP/cl/c2/secret/pg-dr/$SECA.json" ]] && ! ev_has 'apply c2 postgresbackuplocation' && ok "the reused copy keeps its own Secret; no Secret of the derived name and no new location" || bad "reused copy secret" "$(cat "$TMP/events")"
[[ -e "$TMP/cl/c2/postgresbackuplocation/pg-dr/earlier-copy.json" && -e "$TMP/cl/c2/secret/pg-dr/earlier-creds.json" ]] && ! ev_has '^delete' && ok "keepSourceLocation=false never removes a copy this run did not create, nor its Secret" || bad "reused copy removed" "$(cat "$TMP/events")"
jq '.metadata.labels["tpg.fleet/restore-source"] = "c9.somebody-else"' "$TMP/cl/c2/secret/pg-dr/earlier-creds.json" | jq '.data.accountKey = ("OLD" | @base64)' > "$TMP/x" && mv "$TMP/x" "$TMP/cl/c2/secret/pg-dr/earlier-creds.json"
run "$PJ" P_DRY_RUN=false
expect "…its Secret labelled for another source with other contents: SOURCE_SECRET_CONFLICT" FAILED SOURCE_SECRET_CONFLICT "earlier-creds" "c9.somebody-else"
[[ "$(secret_data earlier-creds)" == OLD ]] && ok "…and it is not overwritten" || bad "reused secret overwritten"
rm -f "$TMP/cl/c2/secret/pg-dr/earlier-creds.json"
run "$PJ" P_DRY_RUN=false
expect "…its Secret missing: created again under the reused copy's name" SUCCEEDED "" "Secret pg-dr/earlier-creds was copied"
[[ "$(secret_data earlier-creds)" == "$COPIED" && "$(secret_label earlier-creds)" == c1.legacy-db ]] && ok "…with the source's contents and label" || bad "reused secret not recreated"
reset
# a new target that joins a namespace whose shared Secrets are not the fleet's own (it does not own them: sharedSecretsOwner false):
# the Secret backup-storage the copied location reads is checked against the fleet's key (Vault), never written
set_flag sync.names "orders-full-1"
bare_ns() {  # bare_ns KEY: the namespace pg-bare has an owner entry and Secrets regsecret and backup-storage the fleet does not manage; backup-storage holds KEY
  yq -i '.clusters.c2.instances.bare-owner.instance = {"namespace": "pg-bare", "postgresVersion": "postgres-17.6"}' "$TMP/fleet.repo/clusters/fleet.yaml"
  mkdir -p "$TMP/cl/c2/secret/pg-bare"
  jq -cn '{kind: "Secret", metadata: {name: "regsecret", namespace: "pg-bare"}, data: {x: ("eA==")}}' > "$TMP/cl/c2/secret/pg-bare/regsecret.json"
  jq -cn --arg k "$1" '{kind: "Secret", metadata: {name: "backup-storage", namespace: "pg-bare"}, data: {accountKey: ($k | @base64)}}' > "$TMP/cl/c2/secret/pg-bare/backup-storage.json"
}
bare_ns "SOMEBODY-ELSES-KEY"
RK=c2.bare-db; mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c2/pg-bare/bare-db "$BACKUP_T"; run "$PJ" P_DRY_RUN=false
expect "a foreign backup-storage that does not hold the fleet's key: NAMESPACE_SECRET_CONFLICT" FAILED NAMESPACE_SECRET_CONFLICT "does not hold the fleet's storage key"
reset
set_flag sync.names "orders-full-1"
bare_ns "$VAULT_KEY"
run "$PJ" P_DRY_RUN=false
expect "a foreign backup-storage that holds the fleet's key is used as it is" SUCCEEDED ""
[[ "$(jq -r '.data.accountKey | @base64d' "$TMP/cl/c2/secret/pg-bare/backup-storage.json")" == "$VAULT_KEY" ]] && ! ev_has 'apply c2 secret pg-bare/backup-storage' && ok "…nothing is written to it" || bad "foreign secret written" "$(cat "$TMP/events")"
no_secret_leak "foreign backup-storage" "$VAULT_KEY" "SOMEBODY-ELSES-KEY"

echo "-- postRestoreBackup"
reset
RK=c2.orders-dr; set_flag sync.names "orders-full-1"
mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c2/pg-dr/orders-dr $'pitrEnabled: false\npostRestoreBackup: true'; run "$PJ" P_DRY_RUN=false
expect "postRestoreBackup: SUCCEEDED with the backup's result" SUCCEEDED "" "post-restore backup: stub backup"
ev_has '^backup tpg-restore-x c2 orders-dr full 10800' && ok "a full backup of the target through backup-instance.sh with its own timeout" || bad "backup call" "$(cat "$TMP/events")"
set_flag backup.fail
reset; set_flag backup.fail; set_flag sync.names "orders-full-1"
run "$PJ" P_DRY_RUN=false
expect "…a failing backup: the pair stays SUCCEEDED, POST_RESTORE_BACKUP_FAILED is a warning saying the restore itself succeeded" SUCCEEDED "" "warnings: POST_RESTORE_BACKUP_FAILED: the restore itself succeeded"
[[ "$(cat "$TMP/rec/warning.c2.orders-dr.POST_RESTORE_BACKUP_FAILED.status" 2>/dev/null)" == WARNING ]] && ok "…recorded as a warning of the report" || bad "backup warning record" "$(ls "$TMP/rec")"
mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c2/pg-dr/orders-dr "$BACKUP_T"; reset; set_flag sync.names "orders-full-1"; run "$PJ" P_DRY_RUN=false
! ev_has '^backup' && ok "no postRestoreBackup: no backup" || bad "backup without the flag"

echo "-- PITR, real"
reset
RK=c2.orders-dr; set_flag sync.names ""
mk c1/pg-orders/orders-db '' c2/pg-dr/orders-dr $'pitrEnabled: true\nbestEffort: true\npitrConfig:\n  type: time\n  timestamp: 2024-06-01T00:00:00Z'; run "$PJ" P_DRY_RUN=false
expect "pitr time onto another cluster: SUCCEEDED (no backup wait: the restore reads the repository)" SUCCEEDED ""
R="$(jq -c '.spec' "$TMP/cl/c2/postgresrestore/pg-dr/"*.json)"
[[ "$(jq -r '.pitr.type' <<<"$R")" == time && "$(jq -r '.pitr.sourceBackupLocation.name' <<<"$R")" == restore-src-c1-pg-orders-orders-db && "$(jq 'has("sourceBackup")' <<<"$R")" == false ]] \
  && ok "the applied PostgresRestore has spec.pitr (location = the copy) and no sourceBackup" || bad "applied pitr" "$R"
! grep -q 'waiting for the synced PostgresBackup' <<<"$OUT" && ok "…no wait for synced backups" || bad "unexpected wait"

echo "== 7b. clusters that cannot be read, failed preparation"
reset
RK=c2.orders-dr; mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c2/pg-dr/orders-dr "$BACKUP_T"
set_flag tkfail.c1.postgres; run "$PJ"
expect "the source Postgres cannot be read (not 'not found'): SOURCE_UNREADABLE" FAILED SOURCE_UNREADABLE "Forbidden"
rm -f "$TMP/flags/tkfail.c1.postgres"; set_flag tkfail.c2.postgres; run "$PJ"
expect "the target Postgres cannot be read: TARGET_UNREADABLE" FAILED TARGET_UNREADABLE "Forbidden"
rm -f "$TMP/flags/tkfail.c2.postgres"
yq -i '.clusters.c1.instances.orders-db.instance.exposure = "bogus"' "$TMP/fleet.repo/clusters/fleet.yaml"; run "$PJ"
expect "the chart cannot render the copied entry: CHART_RENDER_FAILED with the chart's message" FAILED CHART_RENDER_FAILED "exposure"
reset
set_flag sync.names "orders-full-1"; set_flag apply.fail.namespace; run "$PJ" P_DRY_RUN=false
expect "the namespace of a new target cannot be created: TARGET_PREPARE_FAILED" FAILED TARGET_PREPARE_FAILED "namespace pg-dr"
reset
set_flag sync.names "orders-full-1"; set_flag apply.fail.postgresbackuplocation; run "$PJ" P_DRY_RUN=false
expect "the location copy cannot be created: SOURCE_LOCATION_FAILED" FAILED SOURCE_LOCATION_FAILED "restore-src-c1-pg-orders-orders-db"
reset
set_flag sync.names "orders-full-1"; set_flag vault.fail
bare_ns "SOMEBODY-ELSES-KEY"
RK=c2.bare-db; mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c2/pg-bare/bare-db "$BACKUP_T"; run "$PJ" P_DRY_RUN=false
expect "Vault has no backup-storage to compare a foreign Secret with: NO_VAULT_SECRET" FAILED NO_VAULT_SECRET "tpg/shared/backup-storage"
reset
RK=c1.orders-db; mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c1/pg-orders/orders-db $'pitrEnabled: false\nconfirm: orders-db'
run "$PJ"
expect "a backup running on the in-place target is a warning in a dry run" SUCCEEDED DRY_RUN
[[ -e "$TMP/rec/warning.c1.orders-db.OPERATION_IN_PROGRESS.status" ]] && ok "OPERATION_IN_PROGRESS warning" || bad "busy warning"
if command -v kubeconform >/dev/null; then
  reset; RK=c2.orders-dr; mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c2/pg-dr/orders-dr "$BACKUP_T"; run "$PJ"
  RKP=c2.orders-dr
  { restore_yaml; echo ---; plan_block 'PostgresBackupLocation .* on '; } > "$TMP/rendered.yaml"
  SCHEMAS="$ROOT/helm_artifacts/instance/crd-reference/schemas/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json"
  kc="$(kubeconform -strict -summary -schema-location "$SCHEMAS" "$TMP/rendered.yaml" 2>&1)" && grep -q 'Valid: 2, Invalid: 0' <<<"$kc" \
    && ok "the rendered PostgresRestore and location copy pass kubeconform -strict against the CRD schemas" || bad "kubeconform" "$kc"
fi

echo "== 7c. the spec file is the source of truth: restore-patch (Round 23 phase 6b revision)"
RPDR="$TMP/fleet.repo/helm_artifacts/instance/tpg-instance/restore-patch"
rp_files() { local f; for f in "$RPDR"/*.yaml; do [[ -f "$f" ]] && basename "$f"; done; true; }
rendered_spec() {  # rendered_spec CLUSTER INSTANCE: the Postgres spec the chart renders from the fleet repository (JSON)
  (source "$TMP/prelude.sh"; instance_render "$TMP/fleet.repo" "$1" "$2" | yq -o=json -I=0 'select(.kind == "Postgres") | .spec')
}
SPEC_ORDERS='targetInstanceSpecFilePath: [repo:helm_artifacts/instance/tpg-instance/restore-specs/orders-dr.yaml]'
reset
RK=c2.orders-dr; set_flag sync.names "orders-full-1"
mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c2/pg-dr/orders-dr $'pitrEnabled: false\n'"$SPEC_ORDERS"; snap="$(snapshot)"; run "$PJ"
expect "a new target with a spec file (the source is in fleet.yaml): the dry run plans" SUCCEEDED DRY_RUN
nothing_changed "new target with a spec file" "$snap"
[[ -z "$(rp_files)" ]] && ok "dry run: no restore-patch file is written to the fleet repository" || bad "dry run wrote a restore-patch" "$(rp_files)"
grep -q 'restore-patch: the spec file would be stored as helm_artifacts/instance/tpg-instance/restore-patch/orders-dr-restore-<uid>.yaml in the same commit as the entry: mode base, restorePatch.current of c2/orders-dr, instance.restored: true and the fleet-equivalent fields' "$TMP/rec/plan.restore.c2.orders-dr.detail" \
  && ok "the plan says where the restore-patch goes, that it shares the commit of the entry, its mode and that the entry is marked restored and seeded" || bad "restore-patch plan" "$(cat "$TMP/rec/plan.restore.c2.orders-dr.detail")"
run "$PJ" P_DRY_RUN=false
expect "…a real run: SUCCEEDED" SUCCEEDED "" "restored c1/pg-orders/orders-db into c2/pg-dr/orders-dr"
RPF="$(rp_files)"
[[ "$(wc -l <<<"$RPF")" -eq 1 && "$RPF" =~ ^orders-dr-restore-[a-z0-9]{5}\.yaml$ ]] && ok "one restore-patch file <instance>-restore-<uid>.yaml is stored in restore-patch/" || bad "stored name" "$RPF"
E="$(yq '.clusters.c2.instances.orders-dr' "$TMP/fleet.repo/clusters/fleet.yaml")"
[[ "$(yq '.restorePatch.current' <<<"$E")" == "restore-patch/$RPF" && "$(yq '.restorePatch | has("previous")' <<<"$E")" == false && "$(yq '.restorePatch.mode' <<<"$E")" == base ]] \
  && ok "the entry records restorePatch.current (a chart-relative path), mode base, no previous" || bad "restorePatch record" "$E"
RPD_DOC="$RPDR/$RPF"
[[ "$(yq '. | keys | join(",")' "$RPD_DOC")" == "apiVersion,kind,spec" && "$(yq '.kind' "$RPD_DOC")" == Postgres && "$(yq '.apiVersion' "$RPD_DOC")" == sql.tanzu.vmware.com/v1 ]] \
  && [[ "$(yq -o=json -I=0 '.spec' "$RPD_DOC")" == "$(yq -o=json -I=0 '.spec' "$RSD/orders-dr.yaml")" ]] \
  && ok "the file is the Postgres document of the spec file: apiVersion, kind, spec as given, no metadata" || bad "restore-patch document" "$(cat "$RPD_DOC")"
[[ "$(yq '.instance.restored' <<<"$E")" == true && "$(yq '.instance.storageSize' <<<"$E")" == 50Gi && "$(yq '.instance.postgresVersion' <<<"$E")" == postgres-17.6 \
   && "$(yq -o=json -I=0 '.instance.highAvailability' <<<"$E")" == '{"enabled":false,"readReplicas":0}' && "$(yq '.instance.exposure' <<<"$E")" == clusterIP ]] \
  && ok "the entry is seeded: instance.restored true, and the fleet-equivalent fields of the spec file (storageSize 50Gi, version, a single node as explicit false/0, exposure clusterIP)" || bad "entry seeding" "$E"
[[ "$(yq '.instance | has("storageClassName")' <<<"$E")" == false && "$(yq '.instance | has("walStorageSize")' <<<"$E")" == false && "$(yq '.instance | has("resources")' <<<"$E")" == false ]] \
  && ok "…and the fleet-equivalent fields the spec file lacks are not in the entry (no value of the source's entry survives)" || bad "entry seeding absent" "$E"
[[ "$(grep -c '^push' "$TMP/events")" -eq 1 ]] && ok "the entry and the restore-patch are one commit (one push)" || bad "pushes" "$(cat "$TMP/events")"
RS="$(rendered_spec c2 orders-dr)"
[[ "$(jq -c 'keys' <<<"$RS")" == '["backupLocation","imagePullSecret","postgresVersion","storageSize"]' && "$(jq -c '.storageSize' <<<"$RS")" == '"50Gi"' ]] \
  && ok "the chart renders the restored Postgres from the restore-patch: the spec file's fields plus backupLocation and imagePullSecret, nothing of the chart defaults (a single node: no highAvailability)" || bad "chart render" "$RS"
PR="$(jq -c '.spec.targetInstance.spec' "$TMP/cl/c2/postgresrestore/pg-dr/"*.json)"
jq -e --argjson r "$RS" '. as $s | $s | to_entries | all(.[]; $r[.key] == .value)' <<<"$PR" >/dev/null \
  && ok "…every field of the spec.targetInstance.spec the PostgresRestore got is in the render, with the same value" || bad "render vs restore spec" "$PR
$RS"

echo "-- a spec file with its own backupLocation: it wins over the fleet's location in the render (third revision)"
reset
RK=c2.orders-dr; set_flag sync.names "orders-full-1"
mkdir -p "$TMP/cl/c2/postgresbackuplocation/pg-dr"
printf '%s' '{"kind":"PostgresBackupLocation","metadata":{"name":"shared-location","namespace":"pg-dr"},"spec":{"storage":{"azure":{"container":"pg-backups","repoPath":"/pg-dr/shared"}}}}' > "$TMP/cl/c2/postgresbackuplocation/pg-dr/shared-location.json"
mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c2/pg-dr/orders-dr $'pitrEnabled: false\ntargetInstanceSpecFilePath: [repo:helm_artifacts/instance/tpg-instance/restore-specs/orders-loc.yaml]'; run "$PJ" P_DRY_RUN=false
expect "a spec file that names an existing backupLocation: SUCCEEDED, no warning" SUCCEEDED ""
[[ -z "$(find "$TMP/rec" -name 'warning.c2.orders-dr.*' 2>/dev/null)" ]] && ok "…no warning at all (the spec file's own location is not replaced)" || bad "location warning" "$(cat "$TMP/records")"
RS="$(rendered_spec c2 orders-dr)"
[[ "$(jq -r '.backupLocation.name' <<<"$RS")" == shared-location && "$(jq -r '.imagePullSecret.name' <<<"$RS")" == regsecret ]] \
  && [[ "$(jq -r '.spec.targetInstance.spec.backupLocation.name' "$TMP/cl/c2/postgresrestore/pg-dr/"*.json)" == shared-location ]] \
  && ok "…the chart renders the spec file's backupLocation (as the restored Postgres has it), the fleet's regsecret fills in imagePullSecret" || bad "own location render" "$RS"
! ev_has 'resources=sql.tanzu.vmware.com:PostgresBackupLocation:pg-dr/orders-dr-backup-location' && ok "…the fleet's orders-dr-backup-location is not synced before the restore (the instance does not use it)" || bad "fleet location synced" "$(cat "$TMP/events")"

echo "-- a new target with a spec file, the source not in fleet.yaml: the entry is built from the file"
reset
RK=c2.orders-dr; set_flag sync.names "legacy-full-1"
mk c1/pg-legacy/legacy-db 'sourceBackupName: legacy-full-1' c2/pg-dr/orders-dr "pitrEnabled: false
targetInstanceSpecFilePath: [repo:helm_artifacts/instance/tpg-instance/restore-specs/orders-new.yaml]"; run "$PJ" P_DRY_RUN=false
expect "SUCCEEDED" SUCCEEDED ""
E="$(yq '.clusters.c2.instances.orders-dr' "$TMP/fleet.repo/clusters/fleet.yaml")"
[[ "$(yq '.instance.postgresVersion' <<<"$E")" == postgres-17.8 && "$(yq '.instance.namespace' <<<"$E")" == pg-dr && "$(yq '.restorePatch.current' <<<"$E")" =~ ^restore-patch/orders-dr-restore- ]] \
  && ok "the entry: namespace, the spec file's version and the restore-patch (a skeleton, since there is no entry to copy)" || bad "skeleton entry" "$E"
echo "-- a new target without a spec file: the spec is read from the cluster after the restore (the live snapshot)"
reset
RK=c2.orders-dr; set_flag sync.names "orders-full-1"
# the source was restored itself and has Postgres patch/overlay files and entry fields of its own: none of that travels to the new target
yq -i '.clusters.c1.instances.orders-db.restorePatch = {"current": "restore-patch/orders-db-restore-sssss.yaml", "mode": "base"}
  | .clusters.c1.instances.orders-db.instance.restored = true
  | .clusters.c1.instances.orders-db.instance.walStorageSize = "99Gi"
  | .clusters.c1.instances.orders-db.instance.resources.data.requests.memory = "9Gi"
  | .clusters.c1.instances.orders-db.patches.postgres.current = "patches/src-patch.yaml"
  | .clusters.c1.instances.orders-db.overlays.postgres.current = "overlays/src-overlay.yaml"' "$TMP/fleet.repo/clusters/fleet.yaml"
printf 'apiVersion: sql.tanzu.vmware.com/v1\nkind: Postgres\nspec:\n  logLevel: Debug\n  postgresVersion:\n    name: postgres-17.6\n' > "$RPDR/orders-db-restore-sssss.yaml"
printf 'apiVersion: sql.tanzu.vmware.com/v1\nkind: Postgres\nspec:\n  sharedMemorySize: 1Gi\n' > "$TMP/fleet.repo/helm_artifacts/instance/tpg-instance/patches/src-patch.yaml"
printf 'apiVersion: sql.tanzu.vmware.com/v1\nkind: Postgres\nspec:\n  sharedMemorySize: 2Gi\n' > "$TMP/fleet.repo/helm_artifacts/instance/tpg-instance/overlays/src-overlay.yaml"
cp "$TMP/fleet.repo/clusters/fleet.yaml" "$TMP/source-fleet.yaml"
mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c2/pg-dr/orders-dr "$BACKUP_T"; run "$PJ" P_DRY_RUN=false
expect "a source that has a restore-patch and Postgres patch files: SUCCEEDED" SUCCEEDED ""
E="$(yq '.clusters.c2.instances.orders-dr' "$TMP/fleet.repo/clusters/fleet.yaml")"
RPF="$(rp_files | grep -v sssss)"
[[ "$(yq '.restorePatch.current' <<<"$E")" == "restore-patch/$RPF" && "$RPF" =~ ^orders-dr-restore-[a-z0-9]{5}\.yaml$ && "$(yq '.restorePatch.mode' <<<"$E")" == base \
   && "$(yq '.restorePatch | has("previous")' <<<"$E")" == false && "$(yq '.restorePatch | has("postgresPatch")' <<<"$E")" == false && "$(yq '.instance.restored' <<<"$E")" == true ]] \
  && ok "the new target's own restore-patch (a file of its own, not the source's), mode base, instance.restored true; nothing of the source's restore travels" || bad "snapshot record" "$E"
[[ "$(yq '.patches | has("postgres")' <<<"$E")" == false && "$(yq '.overlays | has("postgres")' <<<"$E")" == false ]] \
  && [[ "$(yq '.clusters.c1.instances.orders-db.restorePatch.current' "$TMP/fleet.repo/clusters/fleet.yaml")" == "restore-patch/orders-db-restore-sssss.yaml" ]] \
  && ok "the Postgres patch and overlay files of the source are not copied (they changed the source's Postgres), the source's entry is untouched" || bad "copied patches" "$E"
[[ "$(yq '.instance.storageClassName' <<<"$E")" == operator-default && "$(yq '.instance.storageSize' <<<"$E")" == 20Gi && "$(yq '.instance.postgresVersion' <<<"$E")" == postgres-17.6 \
   && "$(yq -o=json -I=0 '.instance.highAvailability' <<<"$E")" == '{"enabled":true,"readReplicas":1}' && "$(yq '.instance | has("walStorageSize")' <<<"$E")" == false && "$(yq '.instance | has("resources")' <<<"$E")" == false ]] \
  && ok "the entry is seeded from the live spec (storageClassName, storageSize, HA); the source's walStorageSize and resources, which the live spec lacks, are removed" || bad "snapshot seeding" "$E"
SNAPF="$RPDR/$RPF"
LIVE="$(jq -c '.spec | del(.certificateSecretName)' "$TMP/cl/c2/postgres/pg-dr/orders-dr.json")"
[[ "$(yq '. | keys | join(",")' "$SNAPF")" == "apiVersion,kind,spec" && "$(yq -o=json -I=0 '.spec' "$SNAPF" | jq -S -c .)" == "$(jq -S -c . <<<"$LIVE")" ]] \
  && ok "the stored file is the Postgres document of the live spec read after the restore: apiVersion, kind and the .spec only (no metadata, managed fields or status), null fields dropped" || bad "snapshot document" "$(cat "$SNAPF")"
[[ "$(grep -c '^push' "$TMP/events")" -eq 2 ]] && ev_has 'push mode=direct restore: record the restore-patch of c2/orders-dr' \
  && ok "two commits: the entry before the restore, the restore-patch after it (the Application is adopted only after the second)" || bad "snapshot pushes" "$(cat "$TMP/events")"
RS="$(rendered_spec c2 orders-dr)"
[[ "$(jq -S -c . <<<"$RS")" == "$(jq -S -c . <<<"$LIVE")" && "$(jq -r '.backupLocation.name' <<<"$RS")" == restore-src-location ]] \
  && ok "the chart renders the live spec as it is (storageClassName operator-default, HA 1, logLevel Debug, nothing of the source's patches): the backupLocation and imagePullSecret the live spec sets win over the fleet's" || bad "snapshot render" "$RS
$LIVE"
[[ "$(jq 'has("spec")' <<<"$(jq -c '.spec.targetInstance' "$TMP/cl/c2/postgresrestore/pg-dr/"*.json)")" == false ]] && ok "…and the PostgresRestore carries spec.targetInstance.name only" || bad "restore without spec"
grep -q 'lab item' <<<"$(detail)" && ok "…the result records that how the operator fills the spec is a lab item" || bad "lab note" "$(detail)"
echo "-- …the live spec cannot be read, or is no Postgres spec: the pair stays SUCCEEDED, the Application is not synced"
reset
RK=c2.orders-dr; set_flag sync.names "orders-full-1"; set_flag snap.gone
mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c2/pg-dr/orders-dr "$BACKUP_T"; run "$PJ" P_DRY_RUN=false
expect "the restored Postgres is not there to read: SUCCEEDED with the warning RESTORE_PATCH_NOT_RECORDED" SUCCEEDED "" "warnings: RESTORE_PATCH_NOT_RECORDED" "does not exist on c2" "is not synced"
! ev_has '^adopt' && [[ -z "$(rp_files)" ]] && [[ "$(yq '.clusters.c2.instances.orders-dr.instance | has("restored")' "$TMP/fleet.repo/clusters/fleet.yaml")" == false ]] \
  && ok "…no adoption sync (the chart would render the copied entry over the restored Postgres), no restore-patch, the entry is not marked restored" || bad "snapshot gone" "$(cat "$TMP/events")"
reset
RK=c2.orders-dr; set_flag sync.names "orders-full-1"
mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c2/pg-dr/orders-dr "$BACKUP_T"; run "$PJ" P_DRY_RUN=false SNAP_EXTRA='{"noSuchField": 1}'
expect "a live spec the Postgres schema does not know: SUCCEEDED with the warning RESTORE_PATCH_NOT_RECORDED naming the field" SUCCEEDED "" "warnings: RESTORE_PATCH_NOT_RECORDED" "spec.noSuchField is not a field of the Postgres resource"
! ev_has '^adopt' && [[ -z "$(rp_files)" ]] && ok "…and nothing is stored or adopted" || bad "snapshot invalid" "$(cat "$TMP/events")"
reset
RK=c2.orders-dr; set_flag sync.names "orders-full-1"
mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c2/pg-dr/orders-dr "$BACKUP_T"; run "$PJ" P_DRY_RUN=false SNAP_EXTRA='{"noSuchField": 1, "pgConfig": {"bogusKey": "x"}, "monitoring": {"typo": true}}'
expect "several unknown fields: the warning names every one patchcheck.py reports, with its path" SUCCEEDED "" "warnings: RESTORE_PATCH_NOT_RECORDED" "spec.noSuchField is not a field of the Postgres resource" "spec.pgConfig.bogusKey is not a field of the Postgres resource" "spec.monitoring is not a field of the Postgres resource"
W="$(cat "$TMP/rec/warning.c2.orders-dr.RESTORE_PATCH_NOT_RECORDED.detail" 2>/dev/null)"
grep -q 'spec.noSuchField' <<<"$W" && grep -q 'spec.pgConfig.bogusKey' <<<"$W" && grep -q 'spec.monitoring' <<<"$W" && ok "…and the warning record of the report carries them too (not only the result line)" || bad "warning record" "$W"
reset
RK=c2.orders-dr; set_flag sync.names "orders-full-1"; set_flag push.failfrom 2
mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c2/pg-dr/orders-dr "$BACKUP_T"; run "$PJ" P_DRY_RUN=false
expect "the commit of the restore-patch fails (the entry was pushed before): SUCCEEDED with the warning RESTORE_PATCH_NOT_RECORDED" SUCCEEDED "" "warnings: RESTORE_PATCH_NOT_RECORDED" "pushMode direct" "not synced by this run"
! ev_has '^adopt' && [[ "$(yq '.clusters.c2.instances.orders-dr.instance | has("restored")' "$TMP/fleet.repo/clusters/fleet.yaml")" == false ]] \
  && ok "…no adoption sync and the entry is not marked restored" || bad "snapshot push failed" "$(cat "$TMP/events")"

echo "-- pushMode pr: the restore-patch is in the pull request commit"
reset
RK=c2.orders-dr; set_flag sync.names "orders-full-1"
mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c2/pg-dr/orders-dr $'pitrEnabled: false\n'"$SPEC_ORDERS"; run "$PJ" P_DRY_RUN=false P_PUSH_MODE=pr
expect "pushMode pr, a spec file: SUCCEEDED" SUCCEEDED ""
ev_has 'push mode=pr' && [[ -n "$(rp_files)" ]] && ok "the pull request commit carries the restore-patch next to the entry" || bad "pr restore-patch" "$(cat "$TMP/events")"

echo "-- in place with a spec file"
reset
rm -f "$TMP/cl/c1/postgresbackup/pg-orders/orders-running.json"   # a running backup of the instance blocks a real in-place restore
RK=c1.orders-db
mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c1/pg-orders/orders-db $'pitrEnabled: false\nconfirm: orders-db\n'"$SPEC_ORDERS"; snap="$(snapshot)"; run "$PJ"
expect "in place with a spec file: the dry run plans (the spec file is allowed)" SUCCEEDED DRY_RUN
nothing_changed "in place with a spec file" "$snap"
RKP=c1.orders-db; Y="$(restore_yaml)"
[[ "$(yq '.spec.targetInstance.name' <<<"$Y")" == orders-db && "$(yq '.spec.targetInstance.spec.storageSize' <<<"$Y")" == 50Gi && "$(yq '.spec.targetInstance.spec | keys | join(",")' <<<"$Y")" == "postgresVersion,storageSize" ]] \
  && ok "in place: spec.targetInstance.spec is the spec file as it is (it overrides the existing instance's values), next to the name" || bad "in place restore yaml" "$Y"
grep -q 'restore-patch: the spec file would be stored as .*orders-db-restore-<uid>.yaml in a commit of its own after the restore succeeded (pushMode direct): mode over, restorePatch.current of c1/orders-db' "$TMP/rec/plan.restore.c1.orders-db.detail" \
  && ok "the plan says the restore-patch is committed after the restore succeeded, in mode over" || bad "in place plan" "$(cat "$TMP/rec/plan.restore.c1.orders-db.detail")"
# a Postgres patch file that is current at the restore is recorded: the chart applies it under the restore-patch, a later one over it
yq -i '.clusters.c1.instances.orders-db.patches.postgres.current = "patches/ip-patch.yaml"' "$TMP/fleet.repo/clusters/fleet.yaml"
printf 'apiVersion: sql.tanzu.vmware.com/v1\nkind: Postgres\nspec:\n  sharedMemorySize: 1Gi\n' > "$TMP/fleet.repo/helm_artifacts/instance/tpg-instance/patches/ip-patch.yaml"
run "$PJ" P_DRY_RUN=false
expect "in place, real run: SUCCEEDED" SUCCEEDED "" "restored c1/pg-orders/orders-db into c1/pg-orders/orders-db" "recorded as restorePatch.current of c1/orders-db"
order="$(grep -nE '^(apply c1 postgresrestore|wait ready|push|adopt|sync)' "$TMP/events" | sed -E 's/^[0-9]+://' | cut -c1-24 | paste -sd'|' -)"
[[ "$order" == "apply c1 postgresrestore|wait ready orders-db|push mode=direct restore" ]] \
  && ok "in place: the restore-patch is committed after the restore and the instance running; no adoption sync, no Argo CD call" || bad "in place order" "$order
$(cat "$TMP/events")"
RPF="$(rp_files)"
[[ "$(yq '.clusters.c1.instances.orders-db.restorePatch.current' "$TMP/fleet.repo/clusters/fleet.yaml")" == "restore-patch/$RPF" && "$RPF" =~ ^orders-db-restore-[a-z0-9]{5}\.yaml$ ]] \
  && ok "…recorded on the existing entry of the in-place instance" || bad "in place record" "$(yq '.clusters.c1.instances.orders-db' "$TMP/fleet.repo/clusters/fleet.yaml") $RPF"
[[ "$(yq '.clusters.c1.instances.orders-db.instance.disableInitialBackup' "$TMP/fleet.repo/clusters/fleet.yaml")" == true && "$(yq '.clusters.c1.instances.orders-db.backup.repoPath' "$TMP/fleet.repo/clusters/fleet.yaml")" == /pg-orders ]] \
  && ok "…and the rest of the entry (disableInitialBackup, backup.repoPath, ferret, the patch references) is untouched" || bad "in place entry changed"
IE="$(yq '.clusters.c1.instances.orders-db' "$TMP/fleet.repo/clusters/fleet.yaml")"
[[ "$(yq '.restorePatch.mode' <<<"$IE")" == over && "$(yq '.restorePatch.postgresPatch' <<<"$IE")" == patches/ip-patch.yaml && "$(yq '.instance.restored' <<<"$IE")" == true \
   && "$(yq '.instance.storageSize' <<<"$IE")" == 50Gi && "$(yq '.instance | has("walStorageSize")' <<<"$IE")" == false && "$(yq '.patches.postgres.current' <<<"$IE")" == patches/ip-patch.yaml ]] \
  && ok "in place with a spec file: mode over, the postgres patch file current at the restore is recorded (postgresPatch), instance.restored true, the fields the spec file sets are written into the entry (storageSize 50Gi), the others stay" || bad "in place over" "$IE"
RS="$(rendered_spec c1 orders-db)"
[[ "$(jq -r '.storageSize' <<<"$RS")" == 50Gi && "$(jq -r '.sharedMemorySize' <<<"$RS")" == 1Gi && "$(jq -r '.walStorageSize' <<<"$RS")" == 10Gi && "$(jq -r '.persistentVolumeClaimPolicy' <<<"$RS")" == retain ]] \
  && ok "…the chart renders the existing render (chart defaults, the patch) with the spec file over it" || bad "in place over render" "$RS"
echo "-- a second restore with a spec file replaces the restore-patch; the third drops the oldest file"
FIRST="$RPF"
run "$PJ" P_DRY_RUN=false
SECOND="$(rp_files | grep -v "^${FIRST}$")"
RP="$(yq -o=json -I=0 '.clusters.c1.instances.orders-db.restorePatch' "$TMP/fleet.repo/clusters/fleet.yaml")"
[[ "$(jq -r '.current' <<<"$RP")" == "restore-patch/$SECOND" && "$(jq -r '.previous.path' <<<"$RP")" == "restore-patch/$FIRST" ]] && [[ "$(rp_files | wc -l)" -eq 2 ]] \
  && ok "the former current becomes previous (path and commit recorded); both files exist" || bad "second restore" "$RP
$(rp_files)"
run "$PJ" P_DRY_RUN=false
RP="$(yq -o=json -I=0 '.clusters.c1.instances.orders-db.restorePatch' "$TMP/fleet.repo/clusters/fleet.yaml")"
[[ "$(jq -r '.previous.path' <<<"$RP")" == "restore-patch/$SECOND" && ! -e "$RPDR/$FIRST" && "$(rp_files | wc -l)" -eq 2 ]] \
  && ok "the third replaces the second as previous and deletes the first: the folder holds the recorded files only" || bad "third restore" "$RP
$(rp_files)"
echo "-- in place without a spec file: the spec is read from the cluster (mode base); a source that is not in fleet.yaml; a failing push"
reset
rm -f "$TMP/cl/c1/postgresbackup/pg-orders/orders-running.json"
RK=c1.orders-db
mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c1/pg-orders/orders-db $'pitrEnabled: false\nconfirm: orders-db'; run "$PJ" P_DRY_RUN=false
expect "in place without a spec file: SUCCEEDED" SUCCEEDED "" "the spec of orders-db was read from c1" "recorded as restorePatch.current of c1/orders-db"
Y="$(jq -c '.spec.targetInstance' "$TMP/cl/c1/postgresrestore/pg-orders/"*.json)"
[[ "$(jq -c 'keys' <<<"$Y")" == '["name"]' ]] && ! ev_has '^(adopt|sync)' && [[ "$(grep -c '^push' "$TMP/events")" -eq 1 ]] \
  && ok "…only spec.targetInstance.name; one commit (the restore-patch), no adoption sync, no Argo CD call" || bad "in place without spec" "$Y $(cat "$TMP/events")"
IE="$(yq '.clusters.c1.instances.orders-db' "$TMP/fleet.repo/clusters/fleet.yaml")"
RPF="$(rp_files)"
[[ "$(yq '.restorePatch.current' <<<"$IE")" == "restore-patch/$RPF" && "$(yq '.restorePatch.mode' <<<"$IE")" == base && "$(yq '.instance.restored' <<<"$IE")" == true \
   && "$(yq '.instance.postgresVersion' <<<"$IE")" == postgres-17.6 && "$(yq -o=json -I=0 '.instance.highAvailability' <<<"$IE")" == '{"enabled":false,"readReplicas":0}' \
   && "$(yq '.instance.disableInitialBackup' <<<"$IE")" == true && "$(yq '.ferret.enabled' <<<"$IE")" == true ]] \
  && ok "…the live spec is the restore-patch (mode base) and seeds the entry (a live spec without HA is a single node, explicit); the rest of the entry (disableInitialBackup, ferret) stays" || bad "in place snapshot record" "$IE"
RS="$(rendered_spec c1 orders-db)"
[[ "$(jq -c 'keys' <<<"$RS")" == '["backupLocation","imagePullSecret","postgresVersion"]' ]] \
  && ok "…and the chart renders exactly the live spec (plus the fleet's backupLocation and imagePullSecret), no chart default" || bad "in place snapshot render" "$RS"
echo "-- a second restore without a spec file: the new snapshot is current, the old one previous and no longer applied"
FIRST="$RPF"
jq '.spec.logLevel = "Debug"' "$TMP/cl/c1/postgres/pg-orders/orders-db.json" > "$TMP/pg.json" && mv "$TMP/pg.json" "$TMP/cl/c1/postgres/pg-orders/orders-db.json"
run "$PJ" P_DRY_RUN=false
SECOND="$(rp_files | grep -v "^${FIRST}$")"
RP="$(yq -o=json -I=0 '.clusters.c1.instances.orders-db.restorePatch' "$TMP/fleet.repo/clusters/fleet.yaml")"
[[ "$(jq -r '.current' <<<"$RP")" == "restore-patch/$SECOND" && "$(jq -r '.previous.path' <<<"$RP")" == "restore-patch/$FIRST" && "$(jq -r '.mode' <<<"$RP")" == base ]] \
  && ok "the new snapshot is restorePatch.current, the old one previous" || bad "re-restore" "$RP"
RS="$(rendered_spec c1 orders-db)"
[[ "$(jq -r '.logLevel' <<<"$RS")" == Debug ]] && ok "…and the render follows the new current (the old restore-patch is not applied)" || bad "re-restore render" "$RS"
echo "-- a restore with a spec file after a snapshot restore: the mode turns to over"
yq -i '.clusters.c1.instances.orders-db.patches.postgres.current = "patches/ip-patch2.yaml"' "$TMP/fleet.repo/clusters/fleet.yaml"
printf 'apiVersion: sql.tanzu.vmware.com/v1\nkind: Postgres\nspec:\n  sharedMemorySize: 1Gi\n' > "$TMP/fleet.repo/helm_artifacts/instance/tpg-instance/patches/ip-patch2.yaml"
mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c1/pg-orders/orders-db $'pitrEnabled: false\nconfirm: orders-db\n'"$SPEC_ORDERS"; run "$PJ" P_DRY_RUN=false
RP="$(yq -o=json -I=0 '.clusters.c1.instances.orders-db.restorePatch' "$TMP/fleet.repo/clusters/fleet.yaml")"
[[ "$(jq -r '.mode' <<<"$RP")" == over && "$(jq -r '.postgresPatch' <<<"$RP")" == patches/ip-patch2.yaml && "$(jq -r '.previous.path' <<<"$RP")" == "restore-patch/$SECOND" ]] \
  && ok "a spec file restore over a snapshot restore: mode over with postgresPatch recorded, the snapshot becomes previous" || bad "mode over after snapshot" "$RP"
reset
rm -f "$TMP/cl/c1/postgresbackup/pg-orders/orders-running.json"
RK=c1.orders-db
mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c1/pg-orders/orders-db $'pitrEnabled: false\nconfirm: orders-db\n'"$SPEC_ORDERS"; run "$PJ" P_DRY_RUN=false
mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c1/pg-orders/orders-db $'pitrEnabled: false\nconfirm: orders-db'; run "$PJ" P_DRY_RUN=false
RP="$(yq -o=json -I=0 '.clusters.c1.instances.orders-db.restorePatch' "$TMP/fleet.repo/clusters/fleet.yaml")"
[[ "$(jq -r '.mode' <<<"$RP")" == base && "$(jq 'has("postgresPatch")' <<<"$RP")" == false && "$(jq 'has("previous")' <<<"$RP")" == true ]] \
  && ok "a snapshot restore over a spec file restore: mode base again, postgresPatch gone" || bad "mode base after over" "$RP"
reset
RK=c1.legacy-db
mk c1/pg-legacy/legacy-db 'sourceBackupName: legacy-full-1' c1/pg-legacy/legacy-db "pitrEnabled: false
confirm: legacy-db
targetInstanceSpecFilePath: [repo:helm_artifacts/instance/tpg-instance/restore-specs/legacy.yaml]"; run "$PJ" P_DRY_RUN=false
expect "in place on an instance that is not in clusters/fleet.yaml, with a spec file: SUCCEEDED" SUCCEEDED "" "has no entry in clusters/fleet.yaml: the spec file is used for the restore only, no restore-patch is recorded"
! ev_has '^push' && [[ -z "$(rp_files)" ]] && ok "…nothing is pushed" || bad "legacy in place pushed" "$(cat "$TMP/events")"
reset
rm -f "$TMP/cl/c1/postgresbackup/pg-orders/orders-running.json"
RK=c1.orders-db; set_flag push.fail
mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c1/pg-orders/orders-db $'pitrEnabled: false\nconfirm: orders-db\n'"$SPEC_ORDERS"; run "$PJ" P_DRY_RUN=false
expect "the restore-patch cannot be pushed after a successful restore: the pair stays SUCCEEDED" SUCCEEDED "" "warnings: RESTORE_PATCH_NOT_RECORDED"
[[ -e "$TMP/rec/warning.c1.orders-db.RESTORE_PATCH_NOT_RECORDED.status" ]] && ok "RESTORE_PATCH_NOT_RECORDED is a warning of the report" || bad "not recorded warning"

echo "-- an instance declared in fleet.yaml but not deployed, with a spec file"
reset
RK=c2.declared-db; set_flag sync.names "orders-full-1"
declare_db
mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c2/pg-declared/declared-db $'pitrEnabled: false\n'"$SPEC_ORDERS"; run "$PJ" P_DRY_RUN=false
expect "declared, not deployed, with a spec file: SUCCEEDED" SUCCEEDED ""
order="$(grep -nE '^(apply c2 postgresrestore|wait ready|push|adopt)' "$TMP/events" | sed -E 's/^[0-9]+://' | cut -c1-24 | paste -sd'|' -)"
[[ "$order" == "push mode=direct restore|apply c2 postgresrestore|wait ready declared-db|adopt c2 declared-db" && "$(yq '.clusters.c2.instances.declared-db.restorePatch.current' "$TMP/fleet.repo/clusters/fleet.yaml")" =~ ^restore-patch/declared-db-restore- ]] \
  && ok "the declared entry is replaced like a new target's: entry and restore-patch in one commit before the restore, then the restore, then the adoption sync" || bad "declared order" "$order $(yq '.clusters.c2.instances.declared-db' "$TMP/fleet.repo/clusters/fleet.yaml")"
E="$(yq '.clusters.c2.instances.declared-db' "$TMP/fleet.repo/clusters/fleet.yaml")"
[[ "$(yq 'has("ferret")' <<<"$E")" == false && "$(yq '.patches // {} | has("postgres")' <<<"$E")" == false && "$(yq '.instance | has("disableInitialBackup")' <<<"$E")" == false && "$(yq '.instance | has("sharedSecretsOwner")' <<<"$E")" == false ]] \
  && ok "…and the declared ferret, patches.postgres, disableInitialBackup and sharedSecretsOwner are gone" || bad "declared entry survived (spec file)" "$E"
echo "-- a declared entry whose source is not in clusters/fleet.yaml: replaced by the skeleton of the spec file"
reset
RK=c2.declared-db; set_flag sync.names "legacy-full-1"
declare_db
mk c1/pg-legacy/legacy-db 'sourceBackupName: legacy-full-1' c2/pg-declared/declared-db "$LEGACY_SPEC"; run "$PJ" P_DRY_RUN=false
expect "declared, source not in the fleet, with a spec file: SUCCEEDED" SUCCEEDED ""
E="$(yq '.clusters.c2.instances.declared-db' "$TMP/fleet.repo/clusters/fleet.yaml")"
[[ "$(yq '.instance.namespace' <<<"$E")" == pg-declared && "$(yq '.instance.restored' <<<"$E")" == true && "$(yq 'has("ferret")' <<<"$E")" == false && "$(yq 'has("patches")' <<<"$E")" == false \
   && "$(yq 'has("backup")' <<<"$E")" == false && "$(yq '.instance | has("disableInitialBackup") or has("sharedSecretsOwner") or has("storageSize")' <<<"$E")" == false ]] \
  && ok "the whole declared entry is replaced by the skeleton of the spec file (namespace, version, what the restore-patch adds), not merged into it" || bad "skeleton replace" "$E"

echo "-- spec file errors"
reset
RK=c2.orders-dr
printf 'apiVersion: sql.tanzu.vmware.com/v1\nkind: Postgres\nspec: {}\n' > "$RSD/orders-empty.yaml"
mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c1/pg-orders/orders-db $'pitrEnabled: false\nconfirm: orders-db\ntargetInstanceSpecFilePath: [repo:helm_artifacts/instance/tpg-instance/restore-specs/orders-bad.yaml]'; RK=c1.orders-db; run "$PJ"
expect "an invalid spec file for an in-place restore: SPEC_FILE_INVALID (checked like a new target's)" FAILED SPEC_FILE_INVALID
mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c1/pg-orders/orders-db $'pitrEnabled: false\nconfirm: orders-db\ntargetInstanceSpecFilePath: [repo:helm_artifacts/instance/tpg-instance/restore-specs/missing.yaml]'; run "$PJ"
expect "a spec file that is not on the fleet branch, in place: SPEC_FILE_NOT_FOUND" FAILED SPEC_FILE_NOT_FOUND
mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c1/pg-orders/orders-copy $'pitrEnabled: false\ntargetInstanceSpecFilePath: [repo:helm_artifacts/instance/tpg-instance/restore-specs/orders-nover.yaml]'; RK=c1.orders-copy; run "$PJ"
expect "a spec file with a PostgresVersion the cluster does not have: VERSION_NOT_AVAILABLE" FAILED VERSION_NOT_AVAILABLE "postgres-19.0"

echo "== 7d. later changes of a restored instance: tpg-upgrade component=postgres writes instance.postgresVersion, which overrides the restore-patch's version"
UP="$TMP/up"; rm -rf "$UP"; mkdir -p "$UP/repo/clusters" "$UP/repo/helm_artifacts/instance"
cp -r "$ROOT/clusters/_template" "$UP/repo/clusters/"; cp -r "$ROOT/helm_artifacts/instance/tpg-instance" "$UP/repo/helm_artifacts/instance/"
rm -f "$UP"/repo/helm_artifacts/instance/tpg-instance/restore-patch/example-*
printf 'apiVersion: sql.tanzu.vmware.com/v1\nkind: Postgres\nspec:\n  postgresVersion:\n    name: postgres-17.6\n  storageSize: 50Gi\n  logLevel: Debug\n' > "$UP/repo/helm_artifacts/instance/tpg-instance/restore-patch/up-db-restore-aaaaa.yaml"
cat > "$UP/repo/clusters/fleet.yaml" <<'YAML'
clusters:
  c1:
    operator: {version: v4.5.0}
    instances:
      up-db:
        instance: {namespace: pg-up, restored: true, postgresVersion: postgres-17.6, storageSize: 50Gi, highAvailability: {enabled: false, readReplicas: 0}}
        restorePatch: {current: restore-patch/up-db-restore-aaaaa.yaml, mode: base}
YAML
cat > "$UP/prelude.sh" <<PRELUDE
export TPG_WORK="$UP/work" INSTANCE_NS_OVERRIDE=""
source "$ROOT/workflows/scripts/lib.sh"
set +e
use_cluster() { CLUSTER="\$1"; }
result_guard() { :; }
record() { printf '%s|%s|%s|%s\n' "\$1" "\$2" "\${3:-}" "\${4:-}" >> "$UP/records"; }
instance_ns() { printf 'pg-up'; }
inventory_instances() { printf 'up-db\n'; }
pg_state() { echo Running; }
latest_cr() { :; }
sleep() { :; }
pods_watch() { return 0; }
pg_wait_ready() { return 0; }
git_clone() { rm -rf "\$1"; cp -r "$UP/repo" "\$1"; }
git_commit_push() { cp "\$1/clusters/fleet.yaml" "$UP/repo/clusters/fleet.yaml"; PUSHED_REVISION=abc123; }
sync_instance_app() { printf 'sync %s %s\n' "\$1" "\$2" >> "$UP/events"; return 0; }
tk() {
  case "\$*" in
    *"get postgresversion "*) return 0 ;;
    *"get postgresversionupgrade"*"-o json"*) echo '{"status":{"phase":"Succeeded"}}' ;;
    *"get postgresversionupgrade"*) printf 'Succeeded' ;;
    *"jsonpath={.spec.postgresVersion.name}"*) [[ -e "$UP/upgraded" ]] && printf 'postgres-17.8' || printf 'postgres-17.6' ;;
    *"jsonpath={.status.dbVersion}"*) [[ -e "$UP/upgraded" ]] && printf '17.8' || printf '17.6' ;;
    *" apply -f -"*) cat > "$UP/pvu.yaml"; : > "$UP/upgraded" ;;
  esac
}
PRELUDE
sed "s#source /scripts/lib.sh#source $UP/prelude.sh#" "$ROOT/workflows/scripts/postgres-upgrade.sh" > "$UP/postgres-upgrade.sh"
: > "$UP/records"; : > "$UP/events"
RC=0; OUT="$(cd "$UP" && env P_PRE_BACKUP=false P_PUSH_MODE=direct P_SPEC_WAIT_SECONDS=5 bash "$UP/postgres-upgrade.sh" tpg-upgrade-x c1 postgres-17.8 all 600 2>&1)" || RC=$?
[[ "$RC" -eq 0 ]] && grep -q 'result.c1.up-db|SUCCEEDED||minor upgrade' "$UP/records" \
  && [[ "$(yq '.clusters.c1.instances.up-db.instance.postgresVersion' "$UP/repo/clusters/fleet.yaml")" == postgres-17.8 && "$(yq '.clusters.c1.instances.up-db.instance.restored' "$UP/repo/clusters/fleet.yaml")" == true \
     && "$(yq '.clusters.c1.instances.up-db.restorePatch.current' "$UP/repo/clusters/fleet.yaml")" == restore-patch/up-db-restore-aaaaa.yaml ]] \
  && ok "tpg-upgrade component=postgres on a restored instance writes instance.postgresVersion and leaves restored and restorePatch alone" || bad "restored upgrade" "$OUT $(cat "$UP/records")"
UPR="$(source "$UP/prelude.sh"; instance_render "$UP/repo" c1 up-db | yq -o=json -I=0 'select(.kind == "Postgres") | .spec')"
[[ "$(jq -r '.postgresVersion.name' <<<"$UPR")" == postgres-17.8 && "$(jq -r '.storageSize' <<<"$UPR")" == 50Gi && "$(jq -r '.logLevel' <<<"$UPR")" == Debug && "$(jq 'has("walStorageSize")' <<<"$UPR")" == false ]] \
  && ok "…and the chart renders the new version over the restore-patch's 17.6, everything else of the restore-patch as it is" || bad "restored upgrade render" "$UPR"

echo "== 7e. real runs: the three methods (a new instance on another cluster, in another namespace of the cluster, in place) x a named backup and each PITR type"
real_check() {  # real_check SHAPE RECOVERY: a real run without a spec file (the spec of the restored Postgres is read from the cluster)
  local shape="$1" kind="$2" tag="real $1 $2" r why="" n_restore adopt_ev
  reset; set_flag sync.names "orders-full-1"
  rm -f "$TMP/cl/c1/postgresbackup/pg-orders/orders-running.json"   # a backup that is still running holds an in-place target (OPERATION_IN_PROGRESS)
  shape_pair "$shape" "$kind" nospec
  run "$PJ" P_DRY_RUN=false
  if [[ "$(st)" != SUCCEEDED ]]; then bad "$tag: got $(st)/$(reason), want SUCCEEDED" "$(detail)
$(tail -8 <<<"$OUT")"; return; fi
  n_restore="$(find "$TMP/cl/${T[0]}/postgresrestore/${T[1]}" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')"
  [[ "$n_restore" == 1 ]] || { bad "$tag: ${n_restore} PostgresRestore objects were applied, want 1" "$(cat "$TMP/events")"; return; }
  r="$(cat "$TMP/cl/${T[0]}/postgresrestore/${T[1]}/"*.json)"
  if [[ "$kind" == backup ]]; then
    [[ "$(jq -r '.spec.sourceBackup.name' <<<"$r")" == orders-full-1 && "$(jq '.spec | has("pitr")' <<<"$r")" == false ]] || why+=" spec.sourceBackup;"
  else
    [[ "$(jq -r '.spec.pitr.type' <<<"$r")" == "$kind" && "$(jq '.spec | has("sourceBackup")' <<<"$r")" == false ]] || why+=" spec.pitr.type ${kind};"
  fi
  [[ "$(jq -r '.spec.targetInstance.name' <<<"$r")" == "${T[2]}" ]] || why+=" targetInstance.name;"
  # the copy of the source location: another namespace or cluster only
  if [[ "$shape" == inplace || "$shape" == samenamespace ]]; then
    [[ ! -f "$TMP/cl/${T[0]}/postgresbackuplocation/${T[1]}/$COPYN.json" ]] || why+=" a location copy in the source namespace;"
  else
    [[ -f "$TMP/cl/${T[0]}/postgresbackuplocation/${T[1]}/$COPYN.json" ]] || why+=" no location copy;"
  fi
  # a named backup into another namespace or cluster waits for the synced backup; nothing else does
  if [[ "$kind" == backup && "$shape" != inplace && "$shape" != samenamespace ]]; then
    grep -q "PostgresBackup ${T[1]}/orders-full-1 synced and Succeeded" <<<"$(detail)" || why+=" no wait for the synced backup;"
  else
    ! grep -q "synced and Succeeded" <<<"$(detail)" || why+=" a wait for a synced backup;"
  fi
  # a new instance is adopted by its Application, an instance restored in place already is managed
  adopt_ev="^adopt ${T[0]} ${T[2]}"
  if [[ "$shape" == inplace ]]; then ev_has '^adopt' && why+=" an adoption sync of an instance that is managed already;"
  else ev_has "$adopt_ev" || why+=" no adoption sync;"; fi
  ev_has 'APPLIED-SHARED' && why+=" a shared object was applied by the workflow;"
  [[ -z "$why" ]] && ok "$tag: SUCCEEDED; the applied PostgresRestore says $( [[ "$kind" == backup ]] && echo sourceBackup || echo "pitr $kind" ), the copy, the wait and the adoption are as the shape says" \
    || bad "$tag:$why" "$(detail)
$(cat "$TMP/events")"
}
for shape in newcluster othernamespace inplace; do
  for kind in backup latest time lsn transaction; do real_check "$shape" "$kind"; done
done

echo "== 7f. reasons no other case reaches"
# FLEET_EDIT_FAILED: the entry of the new instance (with the restore-patch of its spec file) cannot be written to the clone of clusters/fleet.yaml
# (the helper that stores the restore-patch fails, as a full disk or a broken yq would make it)
reset
cat > "$TMP/editfail.sh" <<'OV'
restore_patch_store() { echo "no space left on device" >&2; return 1; }
OV
sed -e "s#source $TMP/prelude.sh#source $TMP/prelude.sh; source $TMP/editfail.sh#" "$TMP/restore-pair.sh" > "$TMP/restore-pair-editfail.sh"
RK=c2.orders-dr; mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c2/pg-dr/orders-dr "$BACKUP_T"$'\n'"$SPECF"
snap="$(snapshot)"
RC=0; OUT="$(cd "$TMP" && env P_DRY_RUN=true P_PAIR="$PJ" bash "$TMP/restore-pair-editfail.sh" tpg-restore-x 2>&1)" || RC=$?
expect "the entry of the new instance cannot be written: FLEET_EDIT_FAILED" FAILED FLEET_EDIT_FAILED "clusters/fleet.yaml"
[[ "$RC" -ne 0 ]] && ok "FLEET_EDIT_FAILED exits non-zero" || bad "FLEET_EDIT_FAILED rc"
nothing_changed "FLEET_EDIT_FAILED" "$snap"
# SECRET_NOT_SYNCED: the owner's Application synced the VaultStaticSecrets but the Secrets never appear
reset
set_flag sync.names "orders-full-1"; set_flag sync.nosecret
mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c2/pg-dr/orders-dr "$BACKUP_T"; run "$PJ" P_DRY_RUN=false
expect "the Secrets of the shared objects never appear in the namespace: SECRET_NOT_SYNCED" FAILED SECRET_NOT_SYNCED "pg-dr/regsecret"
! ev_has '^apply c2 postgresrestore' && ok "…no PostgresRestore is created without the Secrets" || bad "restore created without secrets" "$(cat "$TMP/events")"
# SOURCE_LOCATION_UNKNOWN: a named backup of an instance that is gone reports no backup location, and the copy needs one
reset
RK=c2.orders-dr; mk c1/pg-gone/gone-db 'sourceBackupName: gone-noloc' c2/pg-dr/orders-dr "$BACKUP_T"$'\n'"$SPECF"; run "$PJ"
expect "a source backup without a backup location and no live source: SOURCE_LOCATION_UNKNOWN" FAILED SOURCE_LOCATION_UNKNOWN "gone-noloc" "backup location to copy into pg-dr is unknown"
mk c1/pg-gone/gone-db 'sourceBackupName: gone-full-1' c2/pg-dr/orders-dr "$BACKUP_T"$'\n'"$SPECF"; run "$PJ"
expect "…a backup that reports its location (gone-full-1) plans" SUCCEEDED DRY_RUN

echo "== 7g. canary: a failed canary pair exits non-zero and stops the run"
# the batching (plan-batches.sh, with the stub lib of tests/rollout) of two real normalized pairs
cat > "$TMP/pb-lib.sh" <<'LIB'
log() { printf '%s\n' "$*" >&2; }
LIB
sed "s#source /scripts/lib.sh#source $TMP/pb-lib.sh#" "$ROOT/workflows/scripts/plan-batches.sh" > "$TMP/plan-batches.sh"
reset
mk c1/pg-orders/orders-db 'sourceBackupName: orders-nope' c2/pg-dr/orders-dr "$BACKUP_T"; P0="$PJ"
mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c2/pg-dr2/orders-dr2 "$BACKUP_T"; P1="$PJ"
PAIRS="$(jq -cs 'to_entries | map(.value.index = .key | .value)' <<<"$P0"$'\n'"$P1")"
(cd "$TMP" && P_PAIRS="$PAIRS" bash "$TMP/plan-batches.sh" tpg-restore-x false 2 canary >/dev/null 2>&1)
[[ "$(jq -c 'map(map(.index))' /tmp/batches.json)" == '[[0],[1]]' ]] && ok "rolloutMode canary: the first pair is a batch of its own, the second pair comes after it" || bad "canary batches" "$(cat /tmp/batches.json)"
# the canary pair fails (a missing source backup), is blocked (matrix) or runs out of time: the step exits non-zero, which fails the canary step
canary_stops() {  # canary_stops LABEL WANT_STATUS WANT_REASON [VAR=VALUE...]: the first pair ends so, the exit code is non-zero, and the run does not go on to the second pair
  local label="$1" ws="$2" wr="$3"; shift 3
  rm -rf "$TMP/rec"; mkdir -p "$TMP/rec"; : > "$TMP/events"
  RK=c2.orders-dr; run "$P0" "$@"
  local rc0="$RC" started=no
  # what the template does: the canary step is the first batch; a non-zero exit fails it and the later batches never start
  if [[ "$rc0" -eq 0 ]]; then started=yes; RK=c2.orders-dr2; run "$P1" "$@"; fi
  RK=c2.orders-dr
  if [[ "$(st)" == "$ws" && "$(reason)" == "$wr" && "$rc0" -ne 0 && "$started" == no && ! -e "$TMP/rec/result.c2.orders-dr2.status" ]] && ! ev_has 'dr2'; then
    ok "$label: the canary pair ends $ws/$wr with a non-zero exit, so the canary step fails and the second pair never starts"
  else bad "$label: got $(st)/$(reason) rc=${rc0}, second pair started: ${started}" "$(detail)"; fi
}
canary_stops "a canary whose source backup is missing" FAILED SOURCE_BACKUP_UNVERIFIED
mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c2/pg-dr/orders-dr "$BACKUP_T"$'\n'"$(printf 'targetInstanceSpecFilePath: [repo:helm_artifacts/instance/tpg-instance/restore-specs/orders-lite.yaml]')"; P0="$PJ"
canary_stops "a canary the matrix blocks (standard backup into a lite instance)" BLOCKED RESTORE_FLAVOUR_UNSUPPORTED
mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c2/pg-dr/orders-dr "$BACKUP_T"; P0="$PJ"
set_flag sync.mode never; set_flag sync.names "orders-full-1"
canary_stops "a canary that runs out of time (the backup never syncs)" FAILED BACKUPS_NOT_SYNCED P_DRY_RUN=false P_TIMEOUT=60
rm -f "$TMP/flags/sync.mode"
# a good canary lets the run go on
RK=c2.orders-dr; reset; set_flag sync.names "orders-full-1"; run "$P0"
[[ "$RC" -eq 0 && "$(st)" == SUCCEEDED ]] && ok "a canary pair that succeeds exits zero, so the run goes on to the next batch" || bad "good canary rc" "$(detail)"
# the template: only the canary step lacks continueOn, and the rest runs in a later step group
TPLR="$ROOT/workflows/templates/tpg-restore.yaml"
[[ "$(yq '[.spec.templates[] | select(.name == "main") | .steps[][] | select(.name == "canary") | has("continueOn")][0]' "$TPLR")" == false \
   && "$(yq '[.spec.templates[] | select(.name == "restore-batch") | .steps[][] | has("continueOn")][0]' "$TPLR")" == false \
   && "$(yq '[.spec.templates[] | select(.name == "main") | .steps[][] | select(.name == "first") | .continueOn.failed][0]' "$TPLR")" == true \
   && "$(yq '[.spec.templates[] | select(.name == "main") | .steps | to_entries | .[] | select(.value[].name == "canary") | .key][0] < [.spec.templates[] | select(.name == "main") | .steps | to_entries | .[] | select(.value[].name == "rest") | .key][0]' "$TPLR")" == true ]] \
  && ok "template: the canary step and the pair step inside it have no continueOn (a failed pair fails the canary), and rest runs in a later step group" || bad "canary in the template"

echo "== 8. crashes and unknown clusters"
reset
RK=c2.orders-dr
mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c2/pg-dr/orders-dr "$BACKUP_T"
# The pair crosses Argo as base64 (plan-batches.sh): the step decodes it, and raw JSON still works (tests, by hand). The
# JSON text with a backslash before every quote, as {{item.pair}} delivered it to the step, is not accepted
rm -rf "$TMP/rec"; mkdir -p "$TMP/rec"
run "$PJ"; RAW="$(st)/$(cat "$TMP/rec/result.$RK.reason" 2>/dev/null || true)"
rm -rf "$TMP/rec"; mkdir -p "$TMP/rec"
run "$(printf '%s' "$PJ" | base64 -w0)"; B64="$(st)/$(cat "$TMP/rec/result.$RK.reason" 2>/dev/null || true)"
[[ -n "$(st)" && "$RAW" == "$B64" ]] && ok "the pair as base64 gives the same result as the pair as JSON (${B64})" || bad "pair as base64" "raw ${RAW} base64 ${B64} $OUT"
ESC="$(jq -c '.' <<<"$PJ" | sed 's/"/\\"/g')"
RC=0; OUT="$(cd "$TMP" && env P_DRY_RUN=true P_PAIR="$ESC" bash "$TMP/restore-pair.sh" tpg-restore-x 2>&1)" || RC=$?
[[ "$RC" -ne 0 && "$(cat "$TMP/rec/result.restore.reason")" == INVALID_PAIR ]] && grep -q "neither JSON nor base64 of JSON" "$TMP/rec/result.restore.detail" 2>/dev/null \
  && ok "the escaped JSON text of the log (a backslash before every quote) is refused with INVALID_PAIR and says what is accepted" || bad "escaped pair" "$OUT $(cat "$TMP/records")"
RC=0; OUT="$(cd "$TMP" && env P_DRY_RUN=true P_PAIR='{"nonsense":1}' bash "$TMP/restore-pair.sh" tpg-restore-x 2>&1)" || RC=$?
[[ "$RC" -ne 0 && "$(cat "$TMP/rec/result.restore.status")" == FAILED && "$(cat "$TMP/rec/result.restore.reason")" == INVALID_PAIR ]] && ok "a P_PAIR that is not a normalized pair: INVALID_PAIR" || bad "invalid pair" "$OUT"
mkdir -p "$TMP/cl.gone"; mv "$TMP/cl/c2" "$TMP/cl.gone/c2"
run "$PJ"
expect "a target cluster that is not registered: NOT_REGISTERED" FAILED NOT_REGISTERED "c2"
mv "$TMP/cl.gone/c2" "$TMP/cl/c2"
# a crash in a helper: result_guard records UNEXPECTED_ERROR
cat > "$TMP/crash.sh" <<'CRASH'
instance_effective() { return 7; }
CRASH
mk c1/pg-orders/orders-db '' c2/pg-dr/orders-dr "$LATEST"
yq -i 'del(.clusters.c1.instances.orders-db.instance.namespace)' "$TMP/fleet.repo/clusters/fleet.yaml"
rm -rf "$TMP/cl/c1/postgres/pg-orders"
sed -e "s#source $TMP/prelude.sh#source $TMP/prelude.sh; source $TMP/crash.sh#" "$TMP/restore-pair.sh" > "$TMP/restore-pair-crash.sh"
mk c1/pg-orders/orders-db '' c2/pg-dr/orders-dr "$LATEST"; yq -i '.clusters.c1.instances.orders-db.instance.namespace = "pg-orders"' "$TMP/fleet.repo/clusters/fleet.yaml"
RC=0; OUT="$(cd "$TMP" && env P_DRY_RUN=true P_PAIR="$PJ" bash "$TMP/restore-pair-crash.sh" tpg-restore-x 2>&1)" || RC=$?
expect "an unexpected failure in a helper: FAILED/UNEXPECTED_ERROR with the script and line" FAILED UNEXPECTED_ERROR "restore-pair-crash.sh exited 7"

echo "== 9. docs/workflow-commands.md section 16 names every reason restore-pair.sh records, and only reasons the scripts know"
DOC="$ROOT/docs/workflow-commands.md"
SEC16="$(awk '/^## 16\. tpg-restore/{f=1; next} /^## 17\./{f=0} f' "$DOC")"
TABLE="$(printf '%s\n' "$SEC16" | awk '/^### Reasons the restore records/{f=1; next} /^### /{f=0} f')"
if [[ -z "$TABLE" ]]; then bad "section 16 of the docs has no 'Reasons the restore records' table"; else
  missing=""
  # every code the script passes to fail, block or warn (the placeholders REASON and CODE are the helpers' own parameters)
  while read -r code; do
    printf '%s\n' "$TABLE" | grep -q "\`${code}\`" || missing="${missing} ${code}"
  done < <(grep -oE '\b(fail|block|warn) [A-Z][A-Z_]{3,}' "$ROOT/workflows/scripts/restore-pair.sh" | awk '{print $2}' | sort -u | grep -vxE 'REASON|CODE')
  # the codes record() writes directly
  for code in INVALID_PAIR SKIPPED_IN_PROGRESS TIMEOUT DRY_RUN UNEXPECTED_ERROR; do
    printf '%s\n' "$TABLE" | grep -q "\`${code}\`" || [[ "$code" == DRY_RUN ]] || missing="${missing} ${code}"
  done
  # the validate step's own code
  printf '%s\n' "$TABLE" | grep -q '`IN_PLACE_NOT_ALLOWED`' || missing="${missing} IN_PLACE_NOT_ALLOWED"
  [[ -z "$missing" ]] && ok "every reason of restore-pair.sh is in the table of section 16" || bad "section 16 lacks the reasons:${missing}"
  unknown=""
  while read -r code; do
    case "$code" in
      TARGET_POD_\<REASON\>) code=TARGET_ ;;
    esac
    grep -qE "\b${code}" "$ROOT/workflows/scripts/restore-pair.sh" "$ROOT/workflows/scripts/validate-params.sh" || unknown="${unknown} ${code}"
  done < <(printf '%s\n' "$TABLE" | awk -F'|' 'NF > 3 {print $2}' | grep -oE '`[A-Z][A-Z_<>]+`' | tr -d '`' | sort -u)
  [[ -z "$unknown" ]] && ok "every reason of the table of section 16 is written by restore-pair.sh or the validate step" || bad "the table of section 16 names reasons no script writes:${unknown}"
fi

echo
echo "tests/restore: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
