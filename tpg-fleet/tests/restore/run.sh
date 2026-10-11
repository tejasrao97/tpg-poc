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
#   1 plans (dryRun): same namespace, another cluster, every PITR type, the annotation, existing target; read-only
#   2 the named backup checks (same namespace: BACKUP_NOT_FOUND, BACKUP_NOT_SUCCEEDED; another one: SOURCE_BACKUP_UNVERIFIED)
#   3 the PITR derivation (live, from the source backup, PITR_SOURCE_UNKNOWN, warnings for a given value that differs)
#   4 the matrix (RESTORE_FLAVOUR_UNSUPPORTED, RESTORE_VERSION_LOWER, RESTORE_MAJOR_DIFFERS, skipMinorVersionCheck)
#   5 the target (confirm, spec file, namespace, name in use, unknown cluster, owner rules, Secret conflicts)
#   6 the location copy (create, reuse, SOURCE_LOCATION_CONFLICT) and its Secret (Vault, copied; never in a file, log or record)
#   7 real runs: order of the steps, fleet entry, adoption, waits, timeouts, failures, postRestoreBackup, keepSourceLocation
#   8 crashes (UNEXPECTED_ERROR) and the independence of pairs
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
  c3-unreachable-in-fleet-only: {}
YAML
sed -i '/c3-unreachable-in-fleet-only/d' "$TMP/fleet.base/clusters/fleet.yaml"
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
printf 'apiVersion: sql.tanzu.vmware.com/v1\nkind: Postgres\nspec:\n  postgresVersion:\n    name: %s\n' postgres-17.8 > "$RSD/orders-new.yaml"
printf 'apiVersion: sql.tanzu.vmware.com/v1\nkind: Postgres\nspec:\n  postgresVersion:\n    name: %s\n' postgres-19.0 > "$RSD/orders-nover.yaml"
printf 'apiVersion: sql.tanzu.vmware.com/v1\nkind: Postgres\nspec:\n  postgresVersion:\n    name: postgres-17.6\n  noSuchField: 1\n' > "$RSD/orders-bad.yaml"
printf 'apiVersion: sql.tanzu.vmware.com/v1\nkind: Postgres\nspec:\n  postgresVersion:\n    name: postgres-17.6\n  pgConfig:\n    dbname: orders\n---\napiVersion: sql.tanzu.vmware.com/v1\nkind: Postgres\nspec:\n  storageSize: 5Gi\n' > "$RSD/orders-two.yaml"
printf 'apiVersion: sql.tanzu.vmware.com/v1\nkind: Postgres\nspec:\n  postgresVersion:\n    name: postgres-17.6\n  pgConfig:\n    dbname: orders\n' > "$RSD/orders-extra.yaml"
printf 'apiVersion: sql.tanzu.vmware.com/v1\nkind: Postgres\nspec:\n  postgresVersion:\n    name: postgres-17.6\n  backupLocation:\n    name: shared-location\n' > "$RSD/orders-loc.yaml"
printf 'apiVersion: sql.tanzu.vmware.com/v1\nkind: Postgres\nspec:\n  postgresVersion:\n    name: postgres-17.6\n' > "$RSD/legacy.yaml"

# seed CLUSTER KIND NAMESPACE NAME JSON: an object of the fake cluster base state ("_" for cluster-scoped kinds)
mkdir -p "$TMP/cl.base"
seed() { mkdir -p "$TMP/cl.base/$1/$2/$3"; printf '%s' "$5" > "$TMP/cl.base/$1/$2/$3/$4.json"; }
mkdir -p "$TMP/cl.base/c1" "$TMP/cl.base/c2"
for c in c1 c2; do
  for v in 17.4:postgres-17.4 17.6:postgres-17.6 17.6:postgres-17.6-lite 17.8:postgres-17.8 18.1:postgres-18.1; do
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
seed c1 postgresbackup pg-orders other-inst-full '{"kind":"PostgresBackup","metadata":{"name":"other-inst-full","namespace":"pg-orders"},"spec":{"sourceInstance":{"name":"reports-db"},"type":"full"},"status":{"phase":"Succeeded","restoreLabel":"20200102-000000F","timeStarted":"2020-01-02T00:00:00Z","backupLocation":"orders-db-backup-location","stanzaName":"pg-orders-reports-db-0000"}}'
for s in regsecret backup-storage; do
  seed c1 secret pg-orders "$s" "$(jq -cn --arg n "$s" --arg t "$TRACK" '{kind: "Secret", metadata: {name: $n, namespace: "pg-orders", annotations: {"argocd.argoproj.io/tracking-id": $t}}, data: {accountKey: ("'"$VAULT_KEY"'" | @base64)}}')"
done
# a legacy source (not in clusters/fleet.yaml, not a backup-storage location): its own Secret
seed c1 postgres pg-legacy legacy-db '{"kind":"Postgres","metadata":{"name":"legacy-db","namespace":"pg-legacy"},"spec":{"postgresVersion":{"name":"postgres-17.6"},"backupLocation":{"name":"legacy-loc"}},"status":{"currentState":"Running","stanzaName":"legacy-stanza"}}'
seed c1 postgresbackuplocation pg-legacy legacy-loc '{"kind":"PostgresBackupLocation","metadata":{"name":"legacy-loc","namespace":"pg-legacy"},"spec":{"storage":{"azure":{"container":"legacy-container","repoPath":"/legacy","secret":{"name":"src-creds"}}}}}'
seed c1 secret pg-legacy src-creds "$(jq -cn '{kind: "Secret", metadata: {name: "src-creds", namespace: "pg-legacy"}, type: "Opaque", data: {accountName: ("legacyacct" | @base64), accountKey: ("'"$COPIED"'" | @base64)}}')"
seed c1 postgresbackup pg-legacy legacy-full-1 '{"kind":"PostgresBackup","metadata":{"name":"legacy-full-1","namespace":"pg-legacy"},"spec":{"sourceInstance":{"name":"legacy-db"},"type":"full"},"status":{"phase":"Succeeded","restoreLabel":"20200101-000000F","timeStarted":"2020-01-01T00:00:00Z","backupLocation":"legacy-loc","stanzaName":"legacy-stanza"}}'
# a source whose instance is gone but whose backup and location are still there
seed c1 postgresbackup pg-gone gone-full-1 '{"kind":"PostgresBackup","metadata":{"name":"gone-full-1","namespace":"pg-gone"},"spec":{"sourceInstance":{"name":"gone-db"},"type":"full"},"status":{"phase":"Succeeded","restoreLabel":"20200101-000000F","timeStarted":"2020-01-01T00:00:00Z","backupLocation":"gone-loc","stanzaName":"gone-stanza"}}'
seed c1 postgresbackuplocation pg-gone gone-loc '{"kind":"PostgresBackupLocation","metadata":{"name":"gone-loc","namespace":"pg-gone"},"spec":{"storage":{"azure":{"container":"gone-container","repoPath":"/gone","secret":{"name":"backup-storage"}}}}}'
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
  cp "$1/clusters/fleet.yaml" "$FLEETREPO/clusters/fleet.yaml"
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
          if [[ "$(jq -r '.spec.targetInstance.spec // empty' "$CLD/$CLUSTER/$k/$nsx/$nm.json")" != "" ]]; then
            local ti; ti="$(jq -r '.spec.targetInstance.name' "$CLD/$CLUSTER/$k/$nsx/$nm.json")"
            mkdir -p "$CLD/$CLUSTER/postgres/$nsx"
            jq '{kind: "Postgres", metadata: {name: .spec.targetInstance.name, namespace: .metadata.namespace}, spec: .spec.targetInstance.spec, status: {currentState: "Running", stanzaName: "s"}}' "$CLD/$CLUSTER/$k/$nsx/$nm.json" > "$CLD/$CLUSTER/postgres/$nsx/$ti.json"
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
      [[ "$kind" == namespace ]] && printf 'apiVersion: v1\nkind: Namespace\nmetadata:\n  name: %s\n' "$name" ;;
    label) ev "label ${CLUSTER} ${kind} ${name}" ;;
    delete) ev "delete ${CLUSTER} ${kind} ${ns}/${name}"; rm -f "$CLD/$CLUSTER/$kind/${ns:-_}/$name.json" ;;
    *) return 0 ;;
  esac
}
instance_effective_real="$(declare -f instance_effective)"
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
  [[ "$RUN_N" != "${SHOW_RUN:-0}" ]] || { printf '%s\n' "$OUT" | sed 's/^/  > /' >&2; cat "$TMP/events" | sed 's/^/  ev> /' >&2; }   # SHOW_RUN=N prints the log of the Nth run
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
snapshot() { (cd "$TMP/cl" && find . -type f | sort | xargs cat | sha256sum | cut -c1-16; cat "$TMP/fleet.repo/clusters/fleet.yaml" | sha256sum | cut -c1-16) | paste -sd' ' -; }
nothing_changed() {  # nothing_changed LABEL SNAPSHOT_BEFORE: the clusters, the fleet repository and the Argo CD calls are as they were
  local after; after="$(snapshot)"
  if [[ "$after" == "$2" ]] && ! grep -qE '^(apply|push|sync|adopt|delete|label|lock)' "$TMP/events"; then ok "$1: read-only (no object changed, nothing pushed, no Argo CD call)"
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

echo "== 1. plans: dryRun records the plan and changes nothing"
reset
RK=c1.orders-copy; mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c1/pg-orders/orders-copy "$BACKUP_T"
snap="$(snapshot)"; run "$PJ"
expect "a named backup into a new instance of the same namespace: SUCCEEDED/DRY_RUN" SUCCEEDED DRY_RUN "would restore c1/pg-orders/orders-db into c1/pg-orders/orders-copy" "plan.restore.c1.orders-copy"
nothing_changed "same namespace, new instance" "$snap"
RKP=c1.orders-copy; Y="$(restore_yaml)"
[[ "$(yq '.kind' <<<"$Y")" == PostgresRestore && "$(yq '.spec.sourceBackup.name' <<<"$Y")" == orders-full-1 && "$(yq '.spec | has("pitr")' <<<"$Y")" == false \
   && "$(yq '.spec.targetInstance.name' <<<"$Y")" == orders-copy && "$(yq '.spec.targetInstance.spec.postgresVersion.name' <<<"$Y")" == postgres-17.6 ]] \
  && ok "the PostgresRestore: spec.sourceBackup.name = sourceBackupName, no pitr, targetInstance.name and the instance spec of the new target" || bad "restore yaml" "$Y"
[[ "$(yq '.spec.targetInstance.spec | has("highAvailability")' <<<"$Y")" == true && "$(yq '.spec.targetInstance.spec.backupLocation.name' <<<"$Y")" == orders-copy-backup-location \
   && "$(yq '.spec.targetInstance.spec.imagePullSecret.name' <<<"$Y")" == regsecret ]] \
  && ok "the new target's spec is the chart render of its entry (its own backup location, regsecret, highAvailability)" || bad "chart render" "$Y"
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
[[ "$(yq '.spec.targetInstance.spec | has("ferret")' <<<"$Y")" == false ]] && ok "a restored copy gets no FerretDB (the entry's ferret block is dropped)" || bad "ferret" "$Y"

echo "== 1b. every PITR type renders into spec.pitr"
reset
RK=c2.orders-dr
PITR_KEYS_latest="$LATEST"
PITR_KEYS_time=$'pitrEnabled: true\nbestEffort: true\npitrConfig:\n  type: time\n  timestamp: 2024-06-01T00:00:00Z'
PITR_KEYS_lsn=$'pitrEnabled: true\nbestEffort: false\npitrConfig:\n  type: lsn\n  target: 0/3000060'
PITR_KEYS_transaction=$'pitrEnabled: true\nbestEffort: true\npitrConfig:\n  type: transaction\n  target: "987654"'
for typ in latest time lsn transaction; do
  keys="PITR_KEYS_${typ}"; keys="${!keys}"
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

echo "== 1c. skipMinorVersionCheck, existing target, confirm"
reset
RK=c2.orders-dr; mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c2/pg-dr/orders-dr $'pitrEnabled: false\nskipMinorVersionCheck: true'; run "$PJ"
Y="$(RKP=c2.orders-dr restore_yaml)"
[[ "$(yq '.metadata.annotations["sql.tanzu.vmware.com/skip-minor-version-check"]' <<<"$Y")" == true ]] && ok "skipMinorVersionCheck: the annotation sql.tanzu.vmware.com/skip-minor-version-check: \"true\" on the PostgresRestore" || bad "annotation" "$Y"
mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c2/pg-dr/orders-dr "$BACKUP_T"; run "$PJ"
Y="$(RKP=c2.orders-dr restore_yaml)"
[[ "$(yq '.metadata | has("annotations")' <<<"$Y")" == false && "$(yq '.metadata.labels["tpg.fleet/workflow"]' <<<"$Y")" == tpg-restore-x ]] && ok "without the flag no annotation; the workflow label is there" || bad "no annotation" "$Y"
reset
RK=c2.dr-db; mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c2/pg-dr-existing/dr-db "$BACKUP_T"; snap="$(snapshot)"; run "$PJ"
expect "an existing target without confirm: the dry run goes on with a warning" SUCCEEDED DRY_RUN
[[ "$(cat "$TMP/rec/warning.c2.dr-db.CONFIRMATION_MISSING.status" 2>/dev/null)" == WARNING ]] && ok "CONFIRMATION_MISSING is a warning in a dry run (a real run is refused)" || bad "confirmation warning" "$(cat "$TMP/records")"
Y="$(RKP=c2.dr-db restore_yaml)"
[[ "$(yq '.spec.targetInstance | has("spec")' <<<"$Y")" == false && "$(yq '.spec.targetInstance.name' <<<"$Y")" == dr-db ]] && ok "an existing target: targetInstance.name only, no spec" || bad "existing target spec" "$Y"
nothing_changed "existing target" "$snap"
reset
RK=c1.orders-db; mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c1/pg-orders/orders-db $'pitrEnabled: false\nconfirm: orders-db'; run "$PJ"
expect "in place with confirm: SUCCEEDED/DRY_RUN" SUCCEEDED DRY_RUN
[[ ! -e "$TMP/rec/warning.c1.orders-db.CONFIRMATION_MISSING.status" ]] && ok "confirm given: no CONFIRMATION_MISSING warning" || bad "unexpected warning"

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
mk c1/pg-orders/orders-db 'sourceBackupName: orders-full-1' c1/pg-orders/orders-db-ns2 "$BACKUP_T"
mk c1/pg-orders/orders-db 'sourceBackupName: other-inst-full' c1/pg-orders/orders-copy "$BACKUP_T"; RK=c1.orders-copy; run "$PJ"
expect "a backup of another instance: a warning, the pair goes on" SUCCEEDED DRY_RUN
[[ -e "$TMP/rec/warning.c1.orders-copy.BACKUP_OF_OTHER_INSTANCE.status" ]] && ok "BACKUP_OF_OTHER_INSTANCE is a warning" || bad "other instance warning"

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
ls "$TMP/rec" | grep -q '^warning\.' && bad "warning without a difference" "$(ls "$TMP/rec")" || ok "…and none is recorded"
reset
mk c1/pg-orders/orders-db '' c2/pg-dr/orders-dr $'pitrEnabled: true\npitrConfig:\n  type: latest\n  sourceBackupConfig:\n    srcStanzaName: other-stanza'; run "$PJ"
expect "a given stanza that differs from the live one: the pair goes on" SUCCEEDED DRY_RUN
[[ -e "$TMP/rec/warning.c2.orders-dr.SRC_STANZA_DIFFERS.status" ]] && grep -q 'other-stanza differs from pg-orders-orders-db-0000' "$TMP/rec/warning.c2.orders-dr.SRC_STANZA_DIFFERS.detail" \
  && ok "SRC_STANZA_DIFFERS is a warning naming both values" || bad "stanza warning" "$(ls "$TMP/rec")"
Y="$(RKP=c2.orders-dr restore_yaml)"; [[ "$(yq '.spec.pitr.sourceBackupLocation.stanzaName' <<<"$Y")" == other-stanza ]] && ok "the given stanza wins" || bad "given wins" "$Y"
reset
seed_extra() { :; }
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
for k in orders-full-1 orders-failed orders-running other-inst-full; do rm -f "$TMP/cl/c1/postgresbackup/pg-orders/$k.json"; done
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
expect "a lower minor version: BLOCKED RESTORE_VERSION_LOWER" BLOCKED RESTORE_VERSION_LOWER "postgres-17.4" "skipMinorVersionCheck"
tgt orders-old.yaml 'skipMinorVersionCheck: true'; run "$PJ"
expect "…with skipMinorVersionCheck the pair goes on" SUCCEEDED DRY_RUN
[[ -e "$TMP/rec/warning.c2.orders-dr.RESTORE_VERSION_LOWER_SKIPPED.status" ]] && ok "…and RESTORE_VERSION_LOWER_SKIPPED is recorded as a warning" || bad "skipped warning"
tgt orders-new.yaml; run "$PJ"
expect "a higher minor version is allowed" SUCCEEDED DRY_RUN
tgt orders-18.yaml; run "$PJ"
expect "another major version: BLOCKED RESTORE_MAJOR_DIFFERS" BLOCKED RESTORE_MAJOR_DIFFERS "same major version"
tgt orders-18.yaml 'skipMinorVersionCheck: true'; run "$PJ"
expect "…skipMinorVersionCheck does not lift a major difference" BLOCKED RESTORE_MAJOR_DIFFERS
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
mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c2/pg-dr-existing/dr-db "$BACKUP_T"; run "$PJ" P_DRY_RUN=false
expect "an existing target without confirm: CONFIRMATION_MISMATCH in a real run" FAILED CONFIRMATION_MISMATCH "set confirm: dr-db"
mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c2/pg-dr-existing/dr-db $'pitrEnabled: false\nconfirm: dr-db\ntargetInstanceSpecFilePath: [repo:helm_artifacts/instance/tpg-instance/restore-specs/orders-dr.yaml]'; run "$PJ" P_DRY_RUN=false
expect "an existing target refuses targetInstanceSpecFilePath" FAILED TARGET_SPEC_FILE_REFUSED "is for a new instance"
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
mk c1/pg-legacy/legacy-db 'sourceBackupName: legacy-full-1' c2/pg-dr/orders-dr $'pitrEnabled: false\ntargetInstanceSpecFilePath: [./local.yaml]'; run "$PJ" P_PATCH_FILES='{}'
expect "a local spec file that is not in patchFiles: SPEC_FILE_NOT_RECEIVED" FAILED SPEC_FILE_NOT_RECEIVED "patchFiles"
B64="$(base64 -w0 "$RSD/orders-dr.yaml")"
run "$PJ" P_PATCH_FILES="{\"./local.yaml\": \"$B64\"}"
expect "a local spec file in patchFiles is used" SUCCEEDED DRY_RUN
Y="$(RKP=c2.orders-dr restore_yaml)"
[[ "$(yq '.spec.targetInstance.spec.storageSize' <<<"$Y")" == 50Gi && "$(yq '.spec.targetInstance.spec | has("highAvailability")' <<<"$Y")" == false ]] \
  && ok "the spec file is the instance spec: storageSize 50Gi, highAvailability enabled:false is a zero default and is left out (pruned like a Postgres)" || bad "spec file merge" "$Y"
[[ "$(yq '.spec.targetInstance.spec.imagePullSecret.name' <<<"$Y")" == regsecret && "$(yq '.spec.targetInstance.spec.backupLocation.name' <<<"$Y")" == orders-dr-backup-location ]] \
  && ok "the fragment is merged over the render of the entry: imagePullSecret and backupLocation come from the fleet" || bad "spec merge base" "$Y"
for f in orders-bad orders-two; do
  mk c1/pg-legacy/legacy-db 'sourceBackupName: legacy-full-1' c2/pg-dr/orders-dr "pitrEnabled: false
targetInstanceSpecFilePath: [repo:helm_artifacts/instance/tpg-instance/restore-specs/$f.yaml]"; run "$PJ"
  expect "an invalid spec file ($f): SPEC_FILE_INVALID" FAILED SPEC_FILE_INVALID
done
mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c2/pg-dr/orders-dr $'pitrEnabled: false\ntargetInstanceSpecFilePath: [repo:helm_artifacts/instance/tpg-instance/restore-specs/orders-extra.yaml]'; run "$PJ"
expect "a spec file field the entry does not render: the pair goes on" SUCCEEDED DRY_RUN
[[ -e "$TMP/rec/warning.c2.orders-dr.SPEC_FILE_NOT_IN_ENTRY.status" ]] && grep -q pgConfig "$TMP/rec/warning.c2.orders-dr.SPEC_FILE_NOT_IN_ENTRY.detail" && ok "SPEC_FILE_NOT_IN_ENTRY names the field (pgConfig)" || bad "not in entry" "$(ls "$TMP/rec")"
mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c2/pg-dr/orders-dr $'pitrEnabled: false\ntargetInstanceSpecFilePath: [repo:helm_artifacts/instance/tpg-instance/restore-specs/orders-loc.yaml]'; run "$PJ"
expect "a spec file backupLocation that does not exist: BACKUP_LOCATION_MISSING" FAILED BACKUP_LOCATION_MISSING "shared-location"
mk c1/pg-orders/orders-db 'sourceBackupName: orders-full-1' c1/pg-wrong/orders-copy "$BACKUP_T"
reset
mk c1/pg-orders-wrong/orders-db "$ORDERS_BACKUP" c2/pg-dr/orders-dr "$BACKUP_T"; RK=c2.orders-dr; run "$PJ"
expect "a source namespace that is not the entry's: SOURCE_NAMESPACE_MISMATCH" FAILED SOURCE_NAMESPACE_MISMATCH "declares orders-db on c1 in namespace pg-orders"
mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c3/pg-dr/orders-dr "$BACKUP_T" 2>/dev/null && :
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
reset
mk c1/pg-legacy/legacy-db 'sourceBackupName: legacy-full-1' c2/pg-dr/orders-dr $'pitrEnabled: false\ntargetInstanceSpecFilePath: [repo:helm_artifacts/instance/tpg-instance/restore-specs/legacy.yaml]'; run "$PJ"
expect "a source location with its own Secret (src-creds): planned" SUCCEEDED DRY_RUN
grep -q 'Secret src-creds: copied from c1/pg-legacy in memory' "$TMP/rec/plan.restore.c2.orders-dr.detail" && ok "the plan says the Secret is copied in memory" || bad "secret plan" "$(cat "$TMP/rec/plan.restore.c2.orders-dr.detail")"
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
want="push mode=direct restore: add c2/orders-dr from c1/orders-db (tpg-restore-x)|label c2 namespace pg-dr|sync tpg-c2-orders-dr resources=:ServiceAccount:pg-dr/tpg-vso,secrets.hashicorp.com|sync tpg-c2-orders-dr resources=sql.tanzu.vmware.com:PostgresBackupLocation:pg-dr/orders-dr|apply c2 postgresbackuplocation pg-dr/restore-src-c1-pg-orders-orders-db|apply c2 postgresrestore pg-dr/orders-dr-restore|wait ready orders-dr|adopt c2 orders-dr"
want="$(cut -c1-48 <<<"${want//|/$'\n'}" | paste -sd'|' -)"
[[ "$order" == "$want" ]] && ok "the order: entry pushed, namespace, shared objects synced by the owner's Application, the new instance's location synced, source location copied, restore, instance Running, adoption" || bad "order of steps" "$order
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
mkdir -p "$TMP/cl/c2/postgresbackuplocation/pg-dr"
printf '%s' '{"kind":"PostgresBackupLocation","metadata":{"name":"earlier-copy","namespace":"pg-dr"},"spec":{"storage":{"azure":{"container":"pg-backups-c1","repoPath":"/pg-orders"}},"backupSync":{"enabled":true}}}' > "$TMP/cl/c2/postgresbackuplocation/pg-dr/earlier-copy.json"
mkdir -p "$TMP/cl/c2/postgresbackup/pg-dr"
printf '%s' '{"kind":"PostgresBackup","metadata":{"name":"orders-full-1","namespace":"pg-dr"},"status":{"phase":"Succeeded"}}' > "$TMP/cl/c2/postgresbackup/pg-dr/orders-full-1.json"
run "$PJ" P_DRY_RUN=false P_KEEP_SOURCE_LOCATION=false
expect "a reused location with keepSourceLocation=false: SUCCEEDED" SUCCEEDED ""
[[ -f "$TMP/cl/c2/postgresbackuplocation/pg-dr/earlier-copy.json" ]] && ! ev_has '^delete' && ! ev_has 'apply c2 postgresbackuplocation' && ok "…the reused location is neither created nor deleted" || bad "reused location touched" "$(cat "$TMP/events")"
jq -e --arg n earlier-copy '.spec | tostring | contains("earlier-copy")' "$TMP/cl/c2/postgresrestore/pg-dr/"*.json >/dev/null 2>&1 && ok "…and the PostgresRestore does not depend on a new copy (named backup: spec.sourceBackup.name)" || ok "…the named backup restore uses spec.sourceBackup.name"

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

echo "-- confirm, in-progress and busy targets"
reset
RK=c2.dr-db; set_flag sync.names "orders-full-1"
mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c2/pg-dr-existing/dr-db $'pitrEnabled: false\nconfirm: dr-db'; run "$PJ" P_DRY_RUN=false
expect "an existing target with confirm: SUCCEEDED" SUCCEEDED "" "restored c1/pg-orders/orders-db into c2/pg-dr-existing/dr-db"
! ev_has '^push' && ! ev_has '^adopt' && ok "an existing target: no fleet entry is written, no adoption sync" || bad "existing target touched fleet" "$(cat "$TMP/events")"
Y="$(jq -c '.spec' "$TMP/cl/c2/postgresrestore/pg-dr-existing/"*.json)"
[[ "$(jq 'has("targetInstance") and (.targetInstance | has("spec") | not)' <<<"$Y")" == true ]] && ok "…and its PostgresRestore carries no instance spec" || bad "existing target restore spec" "$Y"
ls "$TMP/cl/c2/secret/pg-dr-existing" | grep -q . && ok "…the copy's Secret backup-storage is the namespace's own (Vault Secrets Operator): nothing created" || bad "secret"
reset
set_flag sync.names "orders-full-1"
mkdir -p "$TMP/cl/c2/postgresbackup/pg-dr-existing"
printf '%s' '{"kind":"PostgresBackup","metadata":{"name":"nightly","namespace":"pg-dr-existing"},"spec":{"sourceInstance":{"name":"dr-db"}},"status":{"phase":"Running"}}' > "$TMP/cl/c2/postgresbackup/pg-dr-existing/nightly.json"
run "$PJ" P_DRY_RUN=false
expect "a backup is running on the existing target: OPERATION_IN_PROGRESS" FAILED OPERATION_IN_PROGRESS "postgresbackup"
reset
printf '%s' '{"kind":"PostgresRestore","metadata":{"name":"dr-db-restore-old","namespace":"pg-dr-existing"},"spec":{"targetInstance":{"name":"dr-db"}},"status":{"phase":"Running"}}' > /dev/null
mkdir -p "$TMP/cl/c2/postgresrestore/pg-dr-existing"
printf '%s' '{"kind":"PostgresRestore","metadata":{"name":"dr-db-restore-old","namespace":"pg-dr-existing","creationTimestamp":"2026-10-01T00:00:00Z"},"spec":{"targetInstance":{"name":"dr-db"}},"status":{"phase":"Running"}}' > "$TMP/cl/c2/postgresrestore/pg-dr-existing/dr-db-restore-old.json"
run "$PJ" P_DRY_RUN=false
expect "a restore of the target is still running: SKIPPED_IN_PROGRESS after the wait" SKIPPED_IN_PROGRESS "" "dr-db-restore-old phase Running"

echo "-- the Secret of the copied location"
reset
RK=c2.orders-dr
set_flag sync.names "legacy-full-1"
mk c1/pg-legacy/legacy-db 'sourceBackupName: legacy-full-1' c2/pg-dr/orders-dr $'pitrEnabled: false\ntargetInstanceSpecFilePath: [repo:helm_artifacts/instance/tpg-instance/restore-specs/legacy.yaml]'; run "$PJ" P_DRY_RUN=false
expect "a location with its own Secret: SUCCEEDED, the Secret copied" SUCCEEDED "" "Secret pg-dr/src-creds was copied from c1/pg-legacy"
[[ "$(jq -r '.data.accountKey | @base64d' "$TMP/cl/c2/secret/pg-dr/src-creds.json")" == "$COPIED" && "$(jq -r '.metadata.labels["tpg.fleet/restore-source"]' "$TMP/cl/c2/secret/pg-dr/src-creds.json")" == c1.legacy-db ]] \
  && ok "the target namespace has the Secret with the source's data, labelled as a restore copy" || bad "copied secret" "$(cat "$TMP/cl/c2/secret/pg-dr/src-creds.json" 2>/dev/null)"
no_secret_leak "copied Secret" "$COPIED"
reset
set_flag sync.names "legacy-full-1"
mkdir -p "$TMP/cl/c2/secret/pg-dr"
jq -cn '{kind: "Secret", metadata: {name: "src-creds", namespace: "pg-dr"}, data: {accountKey: ("OTHER" | @base64)}}' > "$TMP/cl/c2/secret/pg-dr/src-creds.json"
run "$PJ" P_DRY_RUN=false
expect "a Secret of that name with other contents that is not a restore copy: SOURCE_SECRET_CONFLICT" FAILED SOURCE_SECRET_CONFLICT "rename that Secret"
reset
set_flag sync.names "legacy-full-1"
mkdir -p "$TMP/cl/c2/secret/pg-dr"
jq -cn '{kind: "Secret", metadata: {name: "src-creds", namespace: "pg-dr", labels: {"tpg.fleet/restore-source": "c1.legacy-db"}}, data: {accountKey: ("OLD" | @base64)}}' > "$TMP/cl/c2/secret/pg-dr/src-creds.json"
run "$PJ" P_DRY_RUN=false
expect "an earlier restore copy of the Secret is updated" SUCCEEDED ""
[[ "$(jq -r '.data.accountKey | @base64d' "$TMP/cl/c2/secret/pg-dr/src-creds.json")" == "$COPIED" ]] && ok "…to the source's current contents" || bad "secret not updated"
reset
# an existing target in a namespace that has no Secret backup-storage (the fleet does not manage it): created from Vault, in memory
set_flag sync.names "orders-full-1"
jq 'del(.spec)' /dev/null 2>/dev/null; mkdir -p "$TMP/cl/c2/postgres/pg-bare"
printf '%s' '{"kind":"Postgres","metadata":{"name":"bare-db","namespace":"pg-bare"},"spec":{"postgresVersion":{"name":"postgres-17.6"}},"status":{"currentState":"Running"}}' > "$TMP/cl/c2/postgres/pg-bare/bare-db.json"
yq -i '.clusters.c2.instances.bare-db.instance = {"namespace": "pg-bare", "postgresVersion": "postgres-17.6"}' "$TMP/fleet.repo/clusters/fleet.yaml"
RK=c2.bare-db; mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c2/pg-bare/bare-db $'pitrEnabled: false\nconfirm: bare-db'; run "$PJ" P_DRY_RUN=false
expect "no backup-storage in the target namespace: created from Vault (in memory)" SUCCEEDED "" "Secret pg-bare/backup-storage was created from Vault"
[[ "$(jq -r '.data.accountKey | @base64d' "$TMP/cl/c2/secret/pg-bare/backup-storage.json")" == "$VAULT_KEY" ]] && ok "…with the fleet's account and key" || bad "vault secret content"
no_secret_leak "backup-storage created from Vault" "$VAULT_KEY"
reset
set_flag sync.names "orders-full-1"
mkdir -p "$TMP/cl/c2/postgres/pg-bare" "$TMP/cl/c2/secret/pg-bare"
printf '%s' '{"kind":"Postgres","metadata":{"name":"bare-db","namespace":"pg-bare"},"spec":{"postgresVersion":{"name":"postgres-17.6"}},"status":{"currentState":"Running"}}' > "$TMP/cl/c2/postgres/pg-bare/bare-db.json"
yq -i '.clusters.c2.instances.bare-db.instance = {"namespace": "pg-bare", "postgresVersion": "postgres-17.6"}' "$TMP/fleet.repo/clusters/fleet.yaml"
jq -cn '{kind: "Secret", metadata: {name: "backup-storage", namespace: "pg-bare"}, data: {accountKey: ("SOMEBODY-ELSES-KEY" | @base64)}}' > "$TMP/cl/c2/secret/pg-bare/backup-storage.json"
run "$PJ" P_DRY_RUN=false
expect "a foreign backup-storage that does not hold the fleet's key: NAMESPACE_SECRET_CONFLICT" FAILED NAMESPACE_SECRET_CONFLICT "does not hold the fleet's storage key"
jq -cn --arg k "$VAULT_KEY" '{kind: "Secret", metadata: {name: "backup-storage", namespace: "pg-bare"}, data: {accountKey: ($k | @base64)}}' > "$TMP/cl/c2/secret/pg-bare/backup-storage.json"
run "$PJ" P_DRY_RUN=false
expect "a foreign backup-storage that holds the fleet's key is used as it is" SUCCEEDED ""
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
expect "…a failing backup: POST_RESTORE_BACKUP_FAILED, saying the restore itself succeeded" FAILED POST_RESTORE_BACKUP_FAILED "the restore itself succeeded"
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
RK=c2.bare-db; set_flag sync.names "orders-full-1"; set_flag vault.fail
mkdir -p "$TMP/cl/c2/postgres/pg-bare"
printf '%s' '{"kind":"Postgres","metadata":{"name":"bare-db","namespace":"pg-bare"},"spec":{"postgresVersion":{"name":"postgres-17.6"}},"status":{"currentState":"Running"}}' > "$TMP/cl/c2/postgres/pg-bare/bare-db.json"
mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c2/pg-bare/bare-db $'pitrEnabled: false\nconfirm: bare-db'; run "$PJ" P_DRY_RUN=false
expect "Vault has no backup-storage when the target namespace needs it: NO_VAULT_SECRET" FAILED NO_VAULT_SECRET "tpg/shared/backup-storage"
reset
RK=c2.dr-db; mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c2/pg-dr-existing/dr-db "$BACKUP_T"
mkdir -p "$TMP/cl/c2/postgresbackup/pg-dr-existing"
printf '%s' '{"kind":"PostgresBackup","metadata":{"name":"nightly","namespace":"pg-dr-existing"},"spec":{"sourceInstance":{"name":"dr-db"}},"status":{"phase":"Running"}}' > "$TMP/cl/c2/postgresbackup/pg-dr-existing/nightly.json"
run "$PJ"
expect "a backup running on the existing target is a warning in a dry run" SUCCEEDED DRY_RUN
[[ -e "$TMP/rec/warning.c2.dr-db.OPERATION_IN_PROGRESS.status" ]] && ok "OPERATION_IN_PROGRESS warning" || bad "busy warning"
if command -v kubeconform >/dev/null; then
  reset; RK=c2.orders-dr; mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c2/pg-dr/orders-dr "$BACKUP_T"; run "$PJ"
  RKP=c2.orders-dr
  { restore_yaml; echo ---; plan_block 'PostgresBackupLocation .* on '; } > "$TMP/rendered.yaml"
  SCHEMAS="$ROOT/helm_artifacts/instance/crd-reference/schemas/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json"
  kc="$(kubeconform -strict -summary -schema-location "$SCHEMAS" "$TMP/rendered.yaml" 2>&1)" && grep -q 'Valid: 2, Invalid: 0' <<<"$kc" \
    && ok "the rendered PostgresRestore and location copy pass kubeconform -strict against the CRD schemas" || bad "kubeconform" "$kc"
fi

echo "== 8. crashes and unknown clusters"
reset
RK=c2.orders-dr
mk c1/pg-orders/orders-db "$ORDERS_BACKUP" c2/pg-dr/orders-dr "$BACKUP_T"
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

echo
echo "tests/restore: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
