#!/usr/bin/env bash
# tpg-delete-instance and tpg-delete-apps with instances that share a namespace (Round 23,
# locked decision 8; workflows/scripts/delete-instance.sh, delete-apps.sh, lib.sh ns_handover) and the
# namespace helpers they and the other workflows use:
#   hand-over     the owner of the shared Secrets leaves: the successor's Application exists first, the
#                 owner flags move in one commit, only the shared objects of the successor's Application
#                 (ServiceAccount tpg-vso, VaultStaticSecrets regsecret and backup-storage) are synced
#                 (it adopts them), the tracking annotation and the health of the Secrets are checked,
#                 and only then the entry leaves Git and the Application is removed - so exactly one
#                 Application tracks the shared Secrets at every step, and they are never deleted. A
#                 failure after the flag commit pushes a revert (the old owner owns them again)
#   successor     tpg-delete-apps: the successor is an instance that stays, never one of the run
#   purge         purgeNamespace is refused while another instance of the namespace remains
#                 (NAMESPACE_SHARED, nothing changes); allowed for the last one; PVCs are the ones of
#                 the instance; tpg-delete-apps defers the namespace to after the last instance of the
#                 run (only when every instance of it in the run purges it), and with deleteOperator
#                 removes everything
#   audit copy    a re-run finds the namespace in clusters/deleted/<cluster>/<instance>-<yyyymmddHHMM>.yaml,
#                 matched by exactly that name (orders is not orders-db), checked against the live Postgres
#   instance_ns   the chain: a checkout, the run inventory, a clone; FLEET_UNREADABLE when none works
#   day0-deploy   a non-owner of the shared Secrets syncs only after they exist (the owner's shared
#                 objects are synced first, or SHARED_SECRETS_MISSING)
# Runs the scripts with the real lib.sh, clustermap.py and chart, and stubs for Git, the Argo CD
# Applications (a sync renders the real chart and moves the tracking annotation to the Application
# whose chart renders the VaultStaticSecret) and the target cluster.
# Requires: bash 4, python3, jq, yq (mikefarah), helm; skipped without them.
# shellcheck disable=SC2015,SC2016
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
for t in python3 jq yq helm; do command -v "$t" >/dev/null || { echo "SKIP tests/delete: $t not installed" >&2; exit 0; }; done
yq --version 2>&1 | grep -q mikefarah || { echo "SKIP tests/delete: yq is not mikefarah yq v4" >&2; exit 0; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { printf 'ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL %s\n' "$1"; [[ -z "${2:-}" ]] || printf '%s\n' "$2" | sed 's/^/       | /' | tail -25; FAIL=$((FAIL + 1)); }

REPO="$TMP/repo"
mkdir -p "$REPO/clusters" "$REPO/helm_artifacts"
cp -r "$ROOT/helm_artifacts/instance" "$REPO/helm_artifacts/"
cp -r "$ROOT/clusters/_template" "$REPO/clusters/"
# app-a owns the Secrets of the namespace "shared"; app-b and app-c share it; orders-db is alone in pg-orders-db
cat > "$TMP/fleet.base.yaml" <<'YAML'
clusters:
  c1:
    operator: {version: v4.5.0}
    instances:
      app-a: {instance: {namespace: shared, postgresVersion: postgres-17.6}}
      app-b: {instance: {namespace: shared, sharedSecretsOwner: false, postgresVersion: postgres-17.6}}
      app-c: {instance: {namespace: shared, sharedSecretsOwner: false, postgresVersion: postgres-17.6}}
      orders-db: {instance: {postgresVersion: postgres-17.6}}
YAML

cat > "$TMP/prelude.tmpl" <<'PRELUDE'
export TPG_WORK="@TMP@/work"
source "@ROOT@/workflows/scripts/lib.sh"
CMAP_KEYS="@ROOT@/workflows/params/cluster-map-keys.yaml"
set +e
EV="@TMP@/events"
ev() { printf '%s\n' "$*" >> "$EV"; }
record() { printf '%s|%s|%s|%s\n' "$1" "$2" "${3:-}" "${4:-}" >> "@TMP@/records"; RESULT_RECORDED=1; }
record_entry() { printf '%s|%s|%s|%s\n' "$1" "$2" "${3:-}" "${4:-}" >> "@TMP@/records"; }
run_data() { :; }
setting() { :; }
use_cluster() { CLUSTER="$1"; }
git_clone() { rm -rf "$1"; mkdir -p "$1"; cp -r "@REPO@/." "$1/"; cp "@TMP@/fleet.yaml" "$1/clusters/fleet.yaml"
  [[ ! -d "@TMP@/deleted" ]] || cp -r "@TMP@/deleted" "$1/clusters/deleted"; }
git_commit_push() {
  local dir="$1" n
  if [[ "${FLEET_CLONE:-}" == "$dir" && -d "$WORK/fleet" ]]; then fleet_flush "$dir"; fi
  fleet_yaml_style "$dir/clusters/fleet.yaml"
  cp "$dir/clusters/fleet.yaml" "@TMP@/fleet.yaml"
  [[ ! -d "$dir/clusters/deleted" ]] || { rm -rf "@TMP@/deleted"; cp -r "$dir/clusters/deleted" "@TMP@/deleted"; }
  n=$(( $(cat "@TMP@/rev" 2>/dev/null || echo 0) + 1 )); echo "$n" > "@TMP@/rev"
  PUSHED_REVISION="rev$n"
  ev "commit rev$n|$2|owners-in-shared=$(yq '[.clusters.c1.instances[] | select(.instance.namespace == "shared") | select(.instance.sharedSecretsOwner != false)] | length' "@TMP@/fleet.yaml")"
  if [[ "${FLEET_CLONE:-}" == "$dir" && -d "$WORK/fleet" ]]; then fleet_materialize "$dir"; fi
}
fleet_head() { echo "rev$(cat "@TMP@/rev" 2>/dev/null || echo 0)"; }
appset_refresh() { :; }
app_exists() { [[ " $(cat "@TMP@/removed" 2>/dev/null | tr '\n' ' ') " != *" $1 "* ]]; }
app_stuck_reason() { :; }
app_removed_or_force() { ev "removed $1|tracked-by=$(cat "@TMP@/tracked")"; echo "$1" >> "@TMP@/removed"; FORCED_NOTE=""; return 0; }
# a sync renders the chart of the instance from the pushed fleet.yaml; the Application whose chart renders
# the shared VaultStaticSecret becomes the one Argo CD tracks it with (the apply writes the annotation).
# --resources: a selective sync (the event says which objects). $TMP/sync-fail: the sync fails;
# $TMP/no-move: it succeeds and changes nothing
sleep() { :; }
app_sync_wait() {
  local app="$1" inst sel="full" tail
  inst="${app#tpg-c1-}"
  shift 2
  while [[ $# -gt 0 ]]; do case "$1" in --resources) sel="selective:$2"; shift 2 ;; --revision) shift 2 ;; *) shift ;; esac; done
  if [[ -f "@TMP@/sync-fail" ]]; then
    SYNC_FAIL_REASON=SYNC_FAILED; SYNC_FAIL_DETAIL="$app: sync failed"
    ev "sync $app|failed|tracked-by=$(cat "@TMP@/tracked")|$sel"
    return 1
  fi
  rm -rf "@TMP@/render-repo"; mkdir -p "@TMP@/render-repo/clusters" "@TMP@/render-repo/helm_artifacts"
  cp -r "@REPO@/helm_artifacts/instance" "@TMP@/render-repo/helm_artifacts/"; cp -r "@REPO@/clusters/_template" "@TMP@/render-repo/clusters/"
  cp "@TMP@/fleet.yaml" "@TMP@/render-repo/clusters/fleet.yaml"
  if instance_render "@TMP@/render-repo" c1 "$inst" 2>/dev/null | yq -e 'select(.kind == "VaultStaticSecret" and .metadata.name == "regsecret")' >/dev/null 2>&1; then
    [[ -f "@TMP@/no-move" ]] || echo "$app" > "@TMP@/tracked"
    ev "sync $app|renders the shared Secrets|tracked-by=$(cat "@TMP@/tracked")|$sel"
  else
    ev "sync $app|renders no shared Secrets|tracked-by=$(cat "@TMP@/tracked")|$sel"
  fi
  return 0
}
live_items() {  # live_items [NAMESPACE]: the Postgres objects as the kubectl list JSON
  jq -Rn '[inputs | split(" ") | select(length == 2) | {metadata: {name: .[0], namespace: .[1]}}]' < "@TMP@/live" \
    | jq -c --arg ns "${1:-}" '{items: [.[] | select($ns == "" or .metadata.namespace == $ns)]}'
}
tk() {
  local ns="" args="$*" name
  [[ "$1" != "-n" ]] || ns="$2"
  case "$args" in
    *readyz*) return 0 ;;
    *"get crd postgres.sql.tanzu.vmware.com"*) return 0 ;;
    *"get crd -o name"*) return 0 ;;
    *"get vaultstaticsecret "*|*"get serviceaccount "*)   # the shared objects: tracked by the Application $TMP/tracked names
      jq -cn --arg t "$(cat "@TMP@/tracked"):apiextensions/Shared:${ns}/${5}" --arg r "$([[ -f "@TMP@/vss-not-ready" ]] && echo False || echo True)" \
        '{metadata: {annotations: {"argocd.argoproj.io/tracking-id": $t}}, status: {conditions: [{type: "Ready", status: $r}]}}' ;;
    "get postgres -A -o json"*) live_items ;;
    *" get postgres -o json"*) live_items "$ns" ;;
    *" get postgres "*)
      name="$5"
      grep -qx "$name $ns" "@TMP@/live" || { echo "Error from server (NotFound): postgres \"$name\" not found" >&2; return 1; }
      case "$args" in *currentState*) printf 'Running' ;; *stanzaName*) printf 'stanza-%s' "$name" ;; esac ;;
    *" get pvc"*)
      sel=""; [[ "$args" != *"-l postgres-instance="* ]] || sel="$(sed -E 's/.*-l postgres-instance=([^ ]+).*/\1/' <<<"$args")"
      jq -Rn --arg ns "$ns" --arg sel "$sel" '[inputs | split(" ") | select(length == 3 and .[1] == $ns and ($sel == "" or .[2] == $sel))
        | {metadata: {name: .[0]}, spec: {volumeName: ("pv-" + .[0])}}] | {items: .}' < "@TMP@/pvcs" | jq -c . ;;
    *" delete postgres "*)
      name="$5"; ev "delete postgres $ns/$name"; grep -vx "$name $ns" "@TMP@/live" > "@TMP@/live.n"; mv "@TMP@/live.n" "@TMP@/live" ;;
    *" delete pvc "*)
      ev "delete pvc $ns|$(sed -E 's/.* delete pvc //' <<<"$args")"
      sel=""; [[ "$args" != *"-l postgres-instance="* ]] || sel="$(sed -E 's/.*-l postgres-instance=([^ ]+).*/\1/' <<<"$args")"
      awk -v ns="$ns" -v sel="$sel" '!($2 == ns && (sel == "" || $3 == sel))' "@TMP@/pvcs" > "@TMP@/pvcs.n"; mv "@TMP@/pvcs.n" "@TMP@/pvcs" ;;
    "delete namespace "*) ev "delete namespace $3"; echo "$3" >> "@TMP@/nsgone" ;;
    "get namespace "*) ! grep -qx "$3" "@TMP@/nsgone" ;;
    *" get "*"-o json"*) echo '{"items":[]}' ;;
    *) return 0 ;;
  esac
}
PRELUDE
sed -e "s#@TMP@#$TMP#g" -e "s#@ROOT@#$ROOT#g" -e "s#@REPO@#$REPO#g" "$TMP/prelude.tmpl" > "$TMP/prelude.sh"
for s in delete-instance delete-apps; do
  sed -e "s#source /scripts/lib.sh#source $TMP/prelude.sh#" -e "s#bash /scripts/delete-instance.sh#bash $TMP/delete-instance.sh#" \
    "$ROOT/workflows/scripts/$s.sh" > "$TMP/$s.sh"
done

reset() {  # reset [REMOVE_INSTANCES...]: the base fleet, every instance running, one PVC each, app-a tracks the shared Secrets
  rm -rf "$TMP/work" "$TMP/deleted" "$TMP/render-repo"; rm -f "$TMP/sync-fail" "$TMP/no-move" "$TMP/vss-not-ready"; : > "$TMP/nsgone"; : > "$TMP/records"; : > "$TMP/events"; : > "$TMP/removed"; echo 0 > "$TMP/rev"
  cp "$TMP/fleet.base.yaml" "$TMP/fleet.yaml"
  printf 'app-a shared\napp-b shared\napp-c shared\norders-db pg-orders-db\n' > "$TMP/live"
  printf 'data-app-a-0 shared app-a\ndata-app-b-0 shared app-b\ndata-app-c-0 shared app-c\ndata-orders-db-0 pg-orders-db orders-db\n' > "$TMP/pvcs"
  echo tpg-c1-app-a > "$TMP/tracked"
  local i
  for i in "$@"; do
    I="$i" yq -i 'del(.clusters.c1.instances[strenv(I)])' "$TMP/fleet.yaml"
    grep -vE "^$i " "$TMP/live" > "$TMP/live.n"; mv "$TMP/live.n" "$TMP/live"
    grep -vE " $i\$" "$TMP/pvcs" > "$TMP/pvcs.n"; mv "$TMP/pvcs.n" "$TMP/pvcs"
  done
}
del() {  # del INSTANCE FINAL PVCS NS -> tpg-delete-instance; output in $OUT, status in $RC
  RC=0; OUT="$(bash "$TMP/delete-instance.sh" wf c1 "$1" "$1" "$2" "$3" "$4" 600 2>&1)" || RC=$?
}
apps() {  # apps JSON PVCS NS [DRY] -> tpg-delete-apps
  RC=0; OUT="$(P_APPS="$1" P_DRY_RUN="${4:-false}" P_PURGE_PVCS="$2" P_PURGE_NS="$3" P_FINAL_BACKUP=false P_FORCE=false P_TIMEOUT=600 \
    bash "$TMP/delete-apps.sh" wf c1 2>&1)" || RC=$?
}
appsmap() {  # appsmap CLUSTERMAP_JSON [DRY] -> tpg-delete-apps with a clusterMap (the normalized map, as clustermap.py makes it)
  mkdir -p "$TMP/work"; printf '%s' "$1" > "$TMP/work/cmap.json"
  RC=0; OUT="$(P_CLUSTER_MAP=map P_DRY_RUN="${2:-false}" P_FINAL_BACKUP=false P_PURGE_PVCS=false P_PURGE_NS=false P_FORCE=false P_TIMEOUT=600 \
    bash "$TMP/delete-apps.sh" wf c1 2>&1)" || RC=$?
}
rec() { grep -F "$1" "$TMP/records" || true; }
lineno() { { grep -n -F -- "$1" "$TMP/events" || true; } | head -n1 | cut -d: -f1; }   # first line of the events file with the text, empty when none
has_ev() { grep -qF -- "$1" "$TMP/events"; }
owners_now() { yq '[.clusters.c1.instances[] | select(.instance.namespace == "shared") | select(.instance.sharedSecretsOwner != false)] | length' "$TMP/fleet.yaml"; }

# ---- the owner leaves: hand-over
reset
del app-a false false false
c1="$(lineno 'commit rev1|move the shared Secrets of c1/shared from app-a to app-b')"
s1="$(lineno 'sync tpg-c1-app-b|renders the shared Secrets|tracked-by=tpg-c1-app-b')"
c2="$(lineno 'commit rev2|delete c1/app-a')"
r1="$(lineno 'removed tpg-c1-app-a|tracked-by=tpg-c1-app-b')"
[[ "$RC" -eq 0 && -n "$c1" && -n "$s1" && -n "$c2" && -n "$r1" && "$c1" -lt "$s1" && "$s1" -lt "$c2" && "$c2" -lt "$r1" ]] \
  && ok "hand-over: commit the owner flags, sync the successor (it adopts the Secrets), then remove the entry and the Application of the old owner" \
  || bad "hand-over order" "$(cat "$TMP/events") $OUT"
has_ev 'commit rev1|move the shared Secrets of c1/shared from app-a to app-b|owners-in-shared=1' && has_ev 'commit rev2|delete c1/app-a (wf)|owners-in-shared=1' \
  && ok "hand-over: exactly one instance of the namespace is the owner in both commits" || bad "one owner per commit" "$(cat "$TMP/events")"
grep -q '^tpg-c1-app-b$' "$TMP/tracked" && [[ "$(grep -c 'tracked-by=' "$TMP/events")" -ge 2 ]] && ! grep -q 'tracked-by=$' "$TMP/events" \
  && ok "hand-over: the tracking annotation names one Application at every step (app-a, then app-b from the sync on)" || bad "tracked" "$(cat "$TMP/events")"
! has_ev 'delete postgres shared/app-b' && ! has_ev 'delete postgres shared/app-c' && ! has_ev 'delete namespace' \
  && ok "hand-over: nothing of the other instances is deleted (the shared Secrets stay)" || bad "nothing else deleted" "$(cat "$TMP/events")"
yq -e '.clusters.c1.instances | has("app-a") | not' "$TMP/fleet.yaml" >/dev/null \
  && [[ "$(yq '.clusters.c1.instances["app-b"].instance | has("sharedSecretsOwner")' "$TMP/fleet.yaml")" == false \
        && "$(yq '.clusters.c1.instances["app-c"].instance.sharedSecretsOwner' "$TMP/fleet.yaml")" == false ]] \
  && ok "hand-over: app-b is the owner now (no flag), app-c stays a non-owner, app-a is gone from fleet.yaml" || bad "flags after" "$(cat "$TMP/fleet.yaml")"
ls "$TMP/deleted/c1/"app-a-*.yaml >/dev/null 2>&1 && [[ "$(yq '.instance.namespace' "$TMP"/deleted/c1/app-a-*.yaml)" == shared ]] \
  && ok "the audit copy keeps the namespace" || bad "audit copy" "$(ls -R "$TMP/deleted" 2>&1)"
rec "result.c1.app-a|SUCCEEDED" | grep -q "shared Secrets of shared moved to app-b" \
  && ok "hand-over: the result names the move" || bad "hand-over result" "$(cat "$TMP/records")"

# a hand-over that failed half way: app-a is not the owner any more, app-b is, but still app-a tracks the Secrets
reset
yq -i '.clusters.c1.instances["app-a"].instance.sharedSecretsOwner = false | del(.clusters.c1.instances["app-b"].instance.sharedSecretsOwner)' "$TMP/fleet.yaml"
del app-a false false false
has_ev 'sync tpg-c1-app-b|renders the shared Secrets|tracked-by=tpg-c1-app-b' && ! has_ev 'move the shared Secrets' && [[ "$RC" -eq 0 ]] \
  && ok "hand-over: a run after a half-done hand-over only syncs the owner (no second commit) and goes on" || bad "half-done" "$(cat "$TMP/events") $OUT"

# the successor cannot take over (its sync fails): the owner flag commit is reverted, the instance stays
reset
touch "$TMP/sync-fail"
del app-a false false false
rec "result.c1.app-a|FAILED|HANDOVER_FAILED" | grep -q "SYNC_FAILED" && has_ev 'commit rev1|move the shared Secrets of c1/shared from app-a to app-b' \
  && has_ev 'commit rev2|revert the hand-over of the shared Secrets of c1/shared from app-a to app-b|owners-in-shared=1' \
  && ! has_ev 'commit rev3' && ! has_ev 'removed' && ! has_ev 'delete c1/app-a' && yq -e '.clusters.c1.instances | has("app-a")' "$TMP/fleet.yaml" >/dev/null \
  && ok "hand-over: when the successor does not sync, the flag commit is reverted (rev2) and the delete stops before app-a leaves Git (HANDOVER_FAILED)" \
  || bad "hand-over failed" "$(cat "$TMP/events") $(cat "$TMP/records")"
[[ "$(owners_now)" == 1 && "$(yq '.clusters.c1.instances["app-a"].instance | has("sharedSecretsOwner")' "$TMP/fleet.yaml")" == false \
   && "$(yq '.clusters.c1.instances["app-b"].instance.sharedSecretsOwner' "$TMP/fleet.yaml")" == false ]] && grep -q '^tpg-c1-app-a$' "$TMP/tracked" \
  && ok "hand-over: after the revert Git has app-a as the owner again (app-b a non-owner) and Argo CD still tracks the Secrets with app-a" || bad "revert state" "$(cat "$TMP/fleet.yaml") $(cat "$TMP/tracked")"
rec "result.c1.app-a|FAILED|HANDOVER_FAILED" | grep -q "owner flags were reverted in Git" \
  && ok "hand-over: the failure says the flags were reverted" || bad "revert text" "$(cat "$TMP/records")"
# the sync succeeds but the Secrets are not taken over / not healthy: the same revert
reset
touch "$TMP/no-move"
del app-a false false false
has_ev 'commit rev2|revert the hand-over' && ! has_ev 'delete c1/app-a' && rec "result.c1.app-a|FAILED|HANDOVER_FAILED" | grep -q "tracked by" \
  && ok "hand-over: a sync that does not move the tracking annotation is reverted as well" || bad "no-move" "$(cat "$TMP/events") $(cat "$TMP/records")"
# the sync moved the annotation but a VaultStaticSecret is not healthy: reverted, and the annotation goes back to app-a
reset
touch "$TMP/vss-not-ready"
del app-a false false false
c1="$(lineno 'sync tpg-c1-app-b|renders the shared Secrets|tracked-by=tpg-c1-app-b')"
c2="$(lineno 'commit rev2|revert the hand-over')"
c3="$(lineno 'sync tpg-c1-app-a|renders the shared Secrets|tracked-by=tpg-c1-app-a|selective:')"
[[ -n "$c1" && -n "$c2" && -n "$c3" && "$c1" -lt "$c2" && "$c2" -lt "$c3" ]] && grep -q '^tpg-c1-app-a$' "$TMP/tracked" && [[ "$(owners_now)" == 1 ]] \
  && ok "hand-over: Secrets not healthy after the successor's sync: reverted, and the objects are synced back to app-a (the annotation returns)" \
  || bad "unhealthy revert" "$(cat "$TMP/events") $(cat "$TMP/records")"
# the successor has no Application: refused before anything is pushed
reset
echo tpg-c1-app-b >> "$TMP/removed"
del app-a false false false
! has_ev 'commit' && ! has_ev 'sync ' && rec "result.c1.app-a|FAILED|HANDOVER_FAILED" | grep -q "tpg-c1-app-b does not exist" && [[ "$(owners_now)" == 1 ]] \
  && [[ "$(yq '.clusters.c1.instances["app-b"].instance.sharedSecretsOwner' "$TMP/fleet.yaml")" == false ]] \
  && ok "hand-over: a successor whose Application does not exist is found before the flag commit (nothing pushed, nothing synced)" || bad "no app" "$(cat "$TMP/events") $(cat "$TMP/records")"

# the sync of the hand-over is selective: the shared objects of the successor, not its whole Application
reset
del app-a false false false
sel="$(grep -F 'sync tpg-c1-app-b|' "$TMP/events" | head -n1)"
[[ "$sel" == *'|selective::ServiceAccount:shared/tpg-vso,secrets.hashicorp.com:VaultStaticSecret:shared/regsecret,secrets.hashicorp.com:VaultStaticSecret:shared/backup-storage' \
   && "$(grep -c '^sync ' "$TMP/events")" == 1 ]] \
  && ok "hand-over: one selective sync of tpg-vso, regsecret and backup-storage (no Postgres, backup location or the rest of the Application)" || bad "selective" "$(cat "$TMP/events")"

# ---- a non-owner leaves: no hand-over
reset
del app-c false false false
[[ "$RC" -eq 0 && "$(grep -c '^commit' "$TMP/events")" == 1 ]] && has_ev 'commit rev1|delete c1/app-c' && ! has_ev 'sync ' && grep -q '^tpg-c1-app-a$' "$TMP/tracked" \
  && ok "a non-owner leaves with one commit and no sync; app-a keeps the Secrets" || bad "non-owner" "$(cat "$TMP/events") $OUT"

# ---- purgeNamespace
reset
del app-b true true true
rec "result.c1.app-b|FAILED|NAMESPACE_SHARED" | grep -q "which app-a, app-c also use(s)" && [[ ! -s "$TMP/events" ]] \
  && ok "purgeNamespace=true is refused while other instances remain in the namespace (NAMESPACE_SHARED), nothing changed" || bad "purge refused" "$(cat "$TMP/records") $(cat "$TMP/events")"
reset
del orders-db false true true
has_ev 'delete namespace pg-orders-db' && [[ "$RC" -eq 0 ]] \
  && ok "purgeNamespace=true on an instance that is alone in its namespace deletes the namespace as before" || bad "purge alone" "$(cat "$TMP/events") $OUT"
reset
del app-b false true false
has_ev 'delete pvc shared|-l postgres-instance=app-b' && ! has_ev 'delete pvc shared|--all' && grep -q 'data-app-a-0 shared' "$TMP/pvcs" && grep -q 'data-app-c-0 shared' "$TMP/pvcs" && ! grep -q 'data-app-b-0' "$TMP/pvcs" \
  && ok "purgePvcs in a shared namespace deletes only the PVCs of the instance (label postgres-instance)" || bad "pvc selector" "$(cat "$TMP/events") $(cat "$TMP/pvcs")"
# one after the other: the last one of the namespace may purge it
reset
del app-c false true false; del app-b false true false; del app-a false true true
has_ev 'delete namespace shared' && [[ "$RC" -eq 0 ]] && ! has_ev 'move the shared Secrets' \
  && ok "the last instance of the namespace can purge it (no other instance remains; nothing to hand over)" || bad "last purge" "$(cat "$TMP/events") $OUT"

# ---- tpg-delete-apps
reset app-c
apps '{"c1":["tpg-instances:app-a","tpg-instances:app-b"]}' true true
has_ev 'delete namespace shared' && [[ "$(grep -c 'delete namespace shared' "$TMP/events")" == 1 ]] \
  && [[ "$(lineno 'delete namespace shared')" -gt "$(lineno 'delete postgres shared/app-b')" && "$(lineno 'delete namespace shared')" -gt "$(lineno 'delete postgres shared/app-a')" ]] \
  && ! has_ev 'sync ' && ! has_ev 'move the shared Secrets' && [[ "$RC" -eq 0 ]] \
  && ok "delete-apps: both instances of a shared namespace are in the run: the namespace is deleted once, after the last, with no hand-over" || bad "apps shared run" "$(cat "$TMP/events") $(cat "$TMP/records") $OUT"
reset
apps '{"c1":["tpg-instances:app-a","tpg-instances:app-b"]}' true true
rec "result.c1.app-a|FAILED|NAMESPACE_SHARED" | grep -q "app-c" && [[ ! -s "$TMP/events" ]] && [[ "$RC" -ne 0 ]] \
  && ok "delete-apps: purgeNamespace on a namespace that app-c (not in the run) still uses is refused up front, nothing changed" || bad "apps refused" "$(cat "$TMP/records") $(cat "$TMP/events")"
reset
apps '{"c1":["tpg-instances:app-a","tpg-instances:app-b"]}' true false
[[ "$RC" -eq 0 ]] && ! has_ev 'delete namespace' && has_ev 'sync tpg-c1-app-c|renders the shared Secrets' \
  && ! has_ev 'sync tpg-c1-app-b' && [[ "$(grep -c 'commit rev.*move the shared Secrets' "$TMP/events")" == 1 ]] \
  && has_ev 'move the shared Secrets of c1/shared from app-a to app-c' && ! has_ev 'move the shared Secrets of c1/shared from app-b' \
  && ok "delete-apps: without purgeNamespace the owner hands over to the instance that stays (app-c) - exactly one hand-over, never to app-b, which leaves in the same run" \
  || bad "apps handover" "$(cat "$TMP/events") $OUT"
yq -e '.clusters.c1.instances | has("app-a") or has("app-b") | not' "$TMP/fleet.yaml" >/dev/null && [[ "$(owners_now)" == 1 ]] \
  && ok "delete-apps: app-a and app-b are gone from fleet.yaml, app-c is the one owner" || bad "apps handover fleet" "$(cat "$TMP/fleet.yaml")"
# the owner is the second of the run (app-b owns, app-a does not): app-a leaves without a hand-over, app-b hands over to app-c
reset
yq -i '.clusters.c1.instances["app-a"].instance.sharedSecretsOwner = false | del(.clusters.c1.instances["app-b"].instance.sharedSecretsOwner)' "$TMP/fleet.yaml"
echo tpg-c1-app-b > "$TMP/tracked"
apps '{"c1":["tpg-instances:app-a","tpg-instances:app-b"]}' true false
[[ "$RC" -eq 0 && "$(grep -c 'commit rev.*move the shared Secrets' "$TMP/events")" == 1 ]] && has_ev 'move the shared Secrets of c1/shared from app-b to app-c' \
  && ! has_ev 'sync tpg-c1-app-a' && ! has_ev 'sync tpg-c1-app-b' && grep -q '^tpg-c1-app-c$' "$TMP/tracked" \
  && ok "delete-apps: the owner is the last of the run: one hand-over, to the instance that stays" || bad "apps handover order" "$(cat "$TMP/events") $OUT"
reset
apps '{"c1":["tpg-instances","tpg-operator"]}' true true
[[ "$RC" -eq 0 ]] && [[ "$(grep -c 'delete namespace shared' "$TMP/events")" == 1 ]] \
  && [[ "$(lineno 'delete namespace shared')" -gt "$(lineno 'delete postgres shared/app-c')" && "$(lineno 'delete namespace shared')" -gt "$(lineno 'delete postgres shared/app-b')" ]] \
  && has_ev 'delete namespace pg-orders-db' && has_ev 'delete namespace tanzu-postgres-operator' && ! has_ev 'sync ' \
  && ok "delete-apps with deleteOperator removes everything: every instance first, each purged namespace once after its last instance, then the operator namespace" || bad "apps operator" "$(cat "$TMP/events") $(cat "$TMP/records") $OUT"
reset
apps '{"c1":["tpg-instances:app-a"]}' true true true
rec "result.c1.app-a|FAILED|NAMESPACE_SHARED" | grep -q . && ok "delete-apps dry run: a purge that would be refused fails in the plan as well" || bad "apps dry run" "$(cat "$TMP/records") $OUT"

# ---- the audit copy of a deleted entry is matched by exactly <instance>-<yyyymmddHHMM>.yaml (Round 23 review)
# "orders" is re-run (entry gone, Postgres still live in team-o); "orders-db" was deleted earlier from the namespace
# legacy with purgePvcs=false (its PVC kept on purpose). A prefix glob took the copy of orders-db for orders.
copy_fixture() {  # copy_fixture: the audit copies of orders (team-o) and orders-db (legacy), orders live, one PVC each
  reset
  mkdir -p "$TMP/deleted/c1"
  printf 'instance: {namespace: team-o, postgresVersion: postgres-17.6}\ndeleted: {workflow: w}\n' > "$TMP/deleted/c1/orders-202610100000.yaml"
  printf 'instance: {namespace: legacy, postgresVersion: postgres-17.6}\ndeleted: {workflow: w}\n' > "$TMP/deleted/c1/orders-db-202610100100.yaml"
  echo "orders team-o" >> "$TMP/live"
  echo "data-orders-0 team-o orders" >> "$TMP/pvcs"
  echo "data-orders-db-0 legacy orders-db" >> "$TMP/pvcs"
}
copy_fixture
del orders false true false
[[ "$RC" -eq 0 ]] && has_ev 'delete postgres team-o/orders' && has_ev 'delete pvc team-o|' && ! grep -q legacy "$TMP/events" && grep -q 'data-orders-db-0 legacy orders-db' "$TMP/pvcs" \
  && ! grep -q 'data-orders-0' "$TMP/pvcs" \
  && ok "audit copy: a re-run of orders uses its own copy (team-o); the kept PVC of orders-db in legacy is not touched" || bad "orders re-run" "$(cat "$TMP/events") $(cat "$TMP/pvcs") $OUT"
# the namespace purge of the re-run deletes team-o, never legacy
copy_fixture
del orders false true true
has_ev 'delete namespace team-o' && ! has_ev 'delete namespace legacy' && [[ "$RC" -eq 0 ]] \
  && ok "audit copy: purgeNamespace of the re-run deletes the namespace of the instance (team-o), not the one of orders-db" || bad "orders re-run purge" "$(cat "$TMP/events") $OUT"
# only the copy of another instance whose name starts like this one: the instance is unknown, nothing happens
reset
mkdir -p "$TMP/deleted/c1"
printf 'instance: {namespace: legacy, postgresVersion: postgres-17.6}\ndeleted: {workflow: w}\n' > "$TMP/deleted/c1/orders-db-202610100100.yaml"
printf 'instance: {namespace: legacy}\n' > "$TMP/deleted/c1/orders-1234.yaml"
del orders false true false
rec "result.c1.orders|FAILED|UNKNOWN_INSTANCE" | grep -q . && [[ ! -s "$TMP/events" ]] \
  && ok "audit copy: the copy of orders-db (and a file that is not <instance>-<12 digits>.yaml) is no copy of orders: UNKNOWN_INSTANCE, nothing changed" \
  || bad "prefix copy" "$(cat "$TMP/events") $(cat "$TMP/records") $OUT"
# the newest copy of the exact name wins
reset
mkdir -p "$TMP/deleted/c1"
printf 'instance: {namespace: old-ns}\n' > "$TMP/deleted/c1/orders-202601010000.yaml"
printf 'instance: {namespace: team-o}\n' > "$TMP/deleted/c1/orders-202610100000.yaml"
echo "orders team-o" >> "$TMP/live"
del orders false false false
has_ev 'delete postgres team-o/orders' && ok "audit copy: of several copies of the instance the newest decides" || bad "newest copy" "$(cat "$TMP/events") $OUT"
# the copy says team-o, a Postgres of that name lives elsewhere: refused (not the same instance)
copy_fixture
grep -vx "orders team-o" "$TMP/live" > "$TMP/live.n"; mv "$TMP/live.n" "$TMP/live"; echo "orders other-ns" >> "$TMP/live"
del orders false true true
rec "result.c1.orders|FAILED|NAMESPACE_MISMATCH" | grep -q "other-ns" && [[ ! -s "$TMP/events" ]] \
  && ok "audit copy: a live Postgres of that name in another namespace than the copy says is refused (NAMESPACE_MISMATCH), nothing deleted" || bad "mismatch" "$(cat "$TMP/events") $(cat "$TMP/records") $OUT"
# no copy, ALLOW_UNTRACKED: the one live Postgres of that name decides; two of them are ambiguous, never pg-<instance>
reset
echo "ghost team-g" >> "$TMP/live"
ALLOW_UNTRACKED=true del ghost false false false
has_ev 'delete postgres team-g/ghost' && ok "no entry, no copy (ALLOW_UNTRACKED): the namespace of the one live Postgres of that name" || bad "live lookup" "$(cat "$TMP/events") $OUT"
reset
printf 'ghost team-g\nghost team-h\n' >> "$TMP/live"
ALLOW_UNTRACKED=true del ghost false false false
rec "result.c1.ghost|FAILED|NAMESPACE_AMBIGUOUS" | grep -q "team-g,team-h" && [[ ! -s "$TMP/events" ]] \
  && ok "no entry, no copy, two live Postgres of that name: NAMESPACE_AMBIGUOUS (no pg-<instance> guess), nothing deleted" || bad "ambiguous" "$(cat "$TMP/events") $(cat "$TMP/records") $OUT"
# with a copy the ambiguity is settled by the copy's namespace
reset
mkdir -p "$TMP/deleted/c1"; printf 'instance: {namespace: team-h}\n' > "$TMP/deleted/c1/ghost-202610100000.yaml"
printf 'ghost team-g\nghost team-h\n' >> "$TMP/live"
ALLOW_UNTRACKED=true del ghost false false false
has_ev 'delete postgres team-h/ghost' && ! has_ev 'team-g' && ok "two live Postgres of that name: the audit copy picks its own namespace" || bad "ambiguous copy" "$(cat "$TMP/events") $OUT"
# deleted_copy itself
rm -rf "$TMP/dc"; mkdir -p "$TMP/dc/clusters/deleted/c1"
: > "$TMP/dc/clusters/deleted/c1/orders-db-202610100100.yaml"; : > "$TMP/dc/clusters/deleted/c1/orders-1.yaml"; : > "$TMP/dc/clusters/deleted/c1/orders-202610100000.yaml.bak"
dcp() { bash -c "source '$ROOT/workflows/scripts/lib.sh'; deleted_copy '$TMP/dc' c1 $1 || echo none" 2>/dev/null; }
[[ "$(dcp orders)" == none && "$(dcp orders-db)" == "$TMP/dc/clusters/deleted/c1/orders-db-202610100100.yaml" && "$(dcp order)" == none ]] \
  && ok "deleted_copy: orders-db-<stamp> is no copy of orders; orders-1.yaml and *.yaml.bak are no copies at all" || bad "deleted_copy" "$(dcp orders) $(dcp orders-db)"
: > "$TMP/dc/clusters/deleted/c1/orders-202610100000.yaml"; : > "$TMP/dc/clusters/deleted/c1/orders-202701010000.yaml"
[[ "$(dcp orders)" == "$TMP/dc/clusters/deleted/c1/orders-202701010000.yaml" ]] && ok "deleted_copy: the newest stamp of the instance" || bad "deleted_copy newest" "$(dcp orders)"

# ---- tpg-delete-apps: purgeNamespace with a clusterMap (Round 23 review)
# one instance of a shared namespace purges it, another one of the run says false (its PVCs are meant to stay)
cm_ns() {  # cm_ns A_PURGE B_PURGE [OPERATOR] -> clusterMap JSON for app-a and app-b (both purgePvcs true)
  jq -cn --arg a "$1" --arg b "$2" --arg op "${3:-false}" '{c1: {deleteOperator: $op, instances: {
    "app-a": {finalBackup: "false", purgePvcs: "true", purgeNamespace: $a},
    "app-b": {finalBackup: "false", purgePvcs: ($b | if . == "keep" then "false" else "true" end), purgeNamespace: ($b | if . == "keep" then "false" else . end)}}}}'
}
reset app-c
appsmap "$(cm_ns true false)"
rec "result.c1.app-a|FAILED|NAMESPACE_SHARED" | grep -q "app-b" && [[ ! -s "$TMP/events" && "$RC" -ne 0 ]] \
  && ok "delete-apps: purgeNamespace=true for app-a while app-b (same run, same namespace) says false: refused up front, NAMESPACE_SHARED names app-b, nothing deleted" \
  || bad "mixed purge" "$(cat "$TMP/events") $(cat "$TMP/records") $OUT"
reset app-c
appsmap "$(cm_ns true false true)"
rec "result.c1.app-a|FAILED|NAMESPACE_SHARED" | grep -q "app-b" && [[ ! -s "$TMP/events" ]] \
  && ok "delete-apps: the same with deleteOperator (everything goes, but not the PVCs app-b keeps): refused" || bad "mixed purge operator" "$(cat "$TMP/events") $(cat "$TMP/records") $OUT"
reset app-c
appsmap "$(cm_ns true true)"
[[ "$RC" -eq 0 && "$(grep -c 'delete namespace shared' "$TMP/events")" == 1 ]] \
  && [[ "$(lineno 'delete namespace shared')" -gt "$(lineno 'delete postgres shared/app-b')" && "$(lineno 'delete namespace shared')" -gt "$(lineno 'delete postgres shared/app-a')" ]] \
  && ok "delete-apps: every instance of the namespace in the run purges it: the namespace is deleted once, after the last" || bad "all purge" "$(cat "$TMP/events") $(cat "$TMP/records") $OUT"
reset app-c
appsmap "$(cm_ns false false)"
[[ "$RC" -eq 0 ]] && ! has_ev 'delete namespace' && ok "delete-apps: nobody purges: the namespace stays" || bad "none purge" "$(cat "$TMP/events") $OUT"
reset app-c
appsmap "$(cm_ns false true)"
rec "result.c1.app-b|FAILED|NAMESPACE_SHARED" | grep -q "app-a" && [[ ! -s "$TMP/events" ]] \
  && ok "delete-apps: the instance that purges is the second one: refused as well, naming app-a" || bad "second purges" "$(cat "$TMP/events") $(cat "$TMP/records") $OUT"

# ---- tpg-delete-apps: a live instance whose entry is gone (Round 23 review)
# orders: entry gone, audit copy says team-o, the Postgres is live there: it is one of ours (before: expected pg-orders, skipped silently)
copy_fixture
yq -i 'del(.clusters.c1.instances["app-c"])' "$TMP/fleet.yaml"
apps '{"c1":["tpg-instances"]}' true false
has_ev 'delete postgres team-o/orders' && ! grep -q legacy "$TMP/events" \
  && ok "delete-apps: a live instance whose entry is gone is found in the namespace of its audit copy (team-o) and deleted" || bad "gone live" "$(cat "$TMP/events") $(cat "$TMP/records") $OUT"
# ghost: live in team-g, no entry, no copy: not ours, left alone with a message in the report
reset
echo "ghost team-g" >> "$TMP/live"
apps '{"c1":["tpg-instances"]}' true false
! has_ev 'team-g' && rec "warning.c1.team-g.ghost|WARNING|POSTGRES_SKIPPED" | grep -q "team-g/ghost is not in the namespace its fleet.yaml entry or audit copy gives (pg-ghost)" \
  && ok "delete-apps: a Postgres outside the namespace of its entry or copy is skipped with a report line (POSTGRES_SKIPPED), not silently" || bad "ghost skipped" "$(cat "$TMP/events") $(cat "$TMP/records") $OUT"
# and the explicit selection deletes it (ALLOW_UNTRACKED: the one live Postgres of that name)
reset
echo "ghost team-g" >> "$TMP/live"
apps '{"c1":["tpg-instances:ghost"]}' true false
has_ev 'delete postgres team-g/ghost' && ok "delete-apps: tpg-instances:ghost deletes it, in the namespace the live lookup finds" || bad "ghost selected" "$(cat "$TMP/events") $(cat "$TMP/records") $OUT"

# ---- the namespace of an instance: a checkout, the run inventory, a clone (Round 23 review)
# instance_ns reads, in this order: a checkout the step has, the inventory, a clone; nothing readable: rc 1, no pg-<instance> guess
chain() {  # chain SETUP_SNIPPET INSTANCE -> prints "<ns>|rc=<n>|clones=<n>" of instance_ns c1 INSTANCE in a fresh step with a working clone
  rm -rf "$TMP/chain"; mkdir -p "$TMP/chain"; : > "$TMP/chain/clones"
  bash -c "
    export TPG_WORK='$TMP/chain/work'
    source '$ROOT/workflows/scripts/lib.sh'
    set +e
    git_clone() { echo clone >> '$TMP/chain/clones'; rm -rf \"\$1\"; mkdir -p \"\$1\"; cp -r '$REPO/.' \"\$1/\"; cp '$TMP/fleet.yaml' \"\$1/clusters/fleet.yaml\"; }
    run_data() { return 1; }
    $1
    ns=\"\$(instance_ns c1 $2)\"; rc=\$?
    echo \"\${ns}|rc=\${rc}|clones=\$(wc -l < '$TMP/chain/clones' | tr -d ' ')\"" 2>/dev/null
}
reset
yq -i '.clusters.c1.instances["app-a"].instance.namespace = "team-x" | del(.clusters.c1.instances["orders-db"].instance.namespace)' "$TMP/fleet.yaml"
mkdir -p "$TMP/chain-repo"; rm -rf "$TMP/chain-repo"; mkdir -p "$TMP/chain-repo/clusters"; cp "$TMP/fleet.yaml" "$TMP/chain-repo/clusters/fleet.yaml"
[[ "$(chain "INSTANCE_NS_REPO='$TMP/chain-repo'" app-a)" == "team-x|rc=0|clones=0" ]] && ok "instance_ns: a checkout the step has: the namespace of the entry, no clone" || bad "chain checkout" "$(chain "INSTANCE_NS_REPO='$TMP/chain-repo'" app-a)"
[[ "$(chain "INSTANCE_NS_REPO='$TMP/chain-repo'" orders-db)" == "pg-orders-db|rc=0|clones=0" ]] && ok "instance_ns: a checkout was read and the entry has no namespace: pg-<instance>" || bad "chain default" "$(chain "INSTANCE_NS_REPO='$TMP/chain-repo'" orders-db)"
[[ "$(chain "INSTANCE_NS_REPO='$TMP/chain-repo'" not-declared)" == "pg-not-declared|rc=0|clones=0" ]] && ok "instance_ns: a checkout was read and the instance is not declared in it: pg-<instance>" || bad "chain undeclared" "$(chain "INSTANCE_NS_REPO='$TMP/chain-repo'" not-declared)"
chain_inv() {  # chain_inv INSTANCE: with the inventory file in place
  rm -rf "$TMP/chain"; mkdir -p "$TMP/chain"; : > "$TMP/chain/clones"
  printf '[{"name":"c1","instances":[{"name":"app-a","namespace":"from-inventory"}]}]' > "$TMP/chain/inventory.json"
  bash -c "
    export TPG_WORK='$TMP/chain/work'
    source '$ROOT/workflows/scripts/lib.sh'
    set +e
    git_clone() { echo clone >> '$TMP/chain/clones'; return 128; }
    run_data() { [[ \"\$1\" == inventory ]] && cat '$TMP/chain/inventory.json'; return 0; }
    ns=\"\$(instance_ns c1 $1)\"; rc=\$?
    echo \"\${ns}|rc=\${rc}|clones=\$(wc -l < '$TMP/chain/clones' | tr -d ' ')\"" 2>/dev/null
}
[[ "$(chain_inv app-a)" == "from-inventory|rc=0|clones=0" ]] && ok "instance_ns: no checkout, the instance is in the run inventory: its namespace, no clone" || bad "chain inventory" "$(chain_inv app-a)"
[[ "$(chain_inv app-zz)" == "|rc=1|clones=1" ]] && ok "instance_ns: the instance is not in the inventory and the clone fails: no output, rc 1 (FLEET_UNREADABLE for the caller), never pg-<instance>" || bad "chain inventory miss" "$(chain_inv app-zz)"
[[ "$(chain "true" app-a)" == "team-x|rc=0|clones=1" ]] && ok "instance_ns: no checkout and no inventory: one clone is made and read" || bad "chain clone" "$(chain "true" app-a)"
[[ "$(chain "true" orders-db)" == "pg-orders-db|rc=0|clones=1" ]] && ok "instance_ns: a clone was read and the entry has no namespace: pg-<instance>" || bad "chain clone default" "$(chain "true" orders-db)"
chain_fail() {
  rm -rf "$TMP/chain"; mkdir -p "$TMP/chain"; : > "$TMP/chain/clones"
  bash -c "
    export TPG_WORK='$TMP/chain/work'
    source '$ROOT/workflows/scripts/lib.sh'
    set +e
    git_clone() { echo clone >> '$TMP/chain/clones'; echo 'clone failed (Vault down)' >&2; return 128; }
    run_data() { return 1; }
    ns=\"\$(instance_ns c1 orders)\"; rc=\$?
    echo \"\${ns}|rc=\${rc}|clones=\$(wc -l < '$TMP/chain/clones' | tr -d ' ')\"" 2>/dev/null
}
[[ "$(chain_fail)" == "|rc=1|clones=1" ]] && ok "instance_ns: no checkout, no inventory, the clone fails (the review's probe): nothing printed, rc 1 - not pg-orders" || bad "chain failure" "$(chain_fail)"
# the callers stop with FLEET_UNREADABLE
RC=0; OUT="$(bash -c "
  export TPG_WORK='$TMP/chain/work2'
  record() { printf '%s|%s|%s|%s\n' \"\$1\" \"\$2\" \"\${3:-}\" \"\${4:-}\"; RESULT_RECORDED=1; }
  source '$ROOT/workflows/scripts/lib.sh'
  git_clone() { return 128; }; run_data() { return 1; }
  use_cluster() { CLUSTER=\"\$1\"; }
  rc=0; sync_instance_app c1 orders 60 abc || rc=\$?; echo \"rc=\$rc reason=\$SYNC_FAIL_REASON\"
  [[ -z \"\$(pg_state orders)\" ]] && echo pg_state-empty
  [[ -n \"\$(busy_operations orders)\" ]] && echo busy" 2>/dev/null)" || RC=$?
grep -q 'rc=4 reason=FLEET_UNREADABLE' <<<"$OUT" && grep -q pg_state-empty <<<"$OUT" && grep -q '^busy$' <<<"$OUT" \
  && ok "lib callers: sync_instance_app fails with FLEET_UNREADABLE, pg_state reads nothing, busy_operations reports busy - no kubectl runs against a guessed namespace" || bad "lib callers" "$OUT"
# backup-instance.sh records FLEET_UNREADABLE and exits 0 (one instance never blocks the others)
sed -e "s#source /scripts/lib.sh#source $TMP/prelude-unreadable.sh#" "$ROOT/workflows/scripts/backup-instance.sh" > "$TMP/backup-instance.sh"
cat > "$TMP/prelude-unreadable.sh" <<PRELUDE
export TPG_WORK="$TMP/work-unreadable"
source "$ROOT/workflows/scripts/lib.sh"
set +e
record() { printf '%s|%s|%s|%s\n' "\$1" "\$2" "\${3:-}" "\${4:-}" >> "$TMP/records"; RESULT_RECORDED=1; }
git_clone() { return 128; }
run_data() { return 1; }
tk() { echo "tk must not run: \$*" >> "$TMP/events"; return 0; }
PRELUDE
reset
RC=0; OUT="$(bash "$TMP/backup-instance.sh" wf c1 orders full 600 2>&1)" || RC=$?
rec "result.c1.orders|FAILED|FLEET_UNREADABLE" | grep -q . && [[ "$RC" -eq 0 && ! -s "$TMP/events" ]] \
  && ok "backup-instance.sh: an unreadable fleet repository is FAILED FLEET_UNREADABLE (exit 0), nothing runs on the cluster" || bad "backup unreadable" "$(cat "$TMP/records" "$TMP/events") $OUT"

# ---- inventory_instances: the owner of the shared Secrets first, only where the sync asks for it
inv_order() {  # inv_order [owners-first] -> the instances of c1 in the order inventory_instances gives
  bash -c "
    export TPG_WORK='$TMP/chain/work3'
    source '$ROOT/workflows/scripts/lib.sh'
    run_data() { echo '[{\"name\":\"c1\",\"instances\":[{\"name\":\"app-b\",\"secretsOwner\":false},{\"name\":\"orders-db\",\"secretsOwner\":true},{\"name\":\"app-c\",\"secretsOwner\":false},{\"name\":\"app-a\",\"secretsOwner\":true}]}]'; }
    inventory_instances c1 ${1:-} | paste -sd' '" 2>/dev/null
}
[[ "$(inv_order)" == "app-b orders-db app-c app-a" ]] && ok "inventory_instances: the inventory order is kept (upgrades and the pre-check)" || bad "inventory order" "$(inv_order)"
[[ "$(inv_order owners-first)" == "orders-db app-a app-b app-c" ]] \
  && ok "inventory_instances owners-first (the sync): the owners first, each group in the inventory order" || bad "owners first" "$(inv_order owners-first)"
grep -q 'inventory_instances "\$C" owners-first' "$ROOT/workflows/scripts/day0-deploy.sh" \
  && ! grep -nE 'inventory_instances "\$C" owners-first' "$ROOT/workflows/scripts/operator-upgrade.sh" "$ROOT/workflows/scripts/postgres-upgrade.sh" "$ROOT/workflows/scripts/day0-precheck.sh" | grep -q . \
  && ok "only day0-deploy.sh asks for the owners first; operator-upgrade, postgres-upgrade and the pre-check keep the inventory order" || bad "callers of owners-first"

# ---- fleet_ns_members / fleet_ns_owners read the fleet file once, whatever the number of instances
reset
nsy="$TMP/ns-many.yaml"; { echo "clusters:"; echo "  c1:"; echo "    instances:"; for n in $(seq 1 60); do echo "      i$n: {instance: {namespace: ns$((n % 3)), sharedSecretsOwner: $([[ $((n % 20)) -eq 0 ]] && echo true || echo false), postgresVersion: postgres-17.6}}"; done; } > "$nsy"
mkdir -p "$TMP/many/clusters"; cp "$nsy" "$TMP/many/clusters/fleet.yaml"
t0=$SECONDS
out="$(bash -c "source '$ROOT/workflows/scripts/lib.sh'; fleet_ns_owners '$TMP/many' c1 ns0 | paste -sd,; fleet_ns_members '$TMP/many' c1 ns1 | wc -l | tr -d ' '" 2>/dev/null)"
[[ "$out" == "i60,20"* || "$out" == $'i60\n20' ]] && (( SECONDS - t0 <= 5 )) \
  && ok "fleet_ns_owners / fleet_ns_members: 60 instances in one pass (the owners of ns0 and the members of ns1 as the entries say)" || bad "ns many" "$out in $((SECONDS - t0))s"

# ---- tpg-day0 / tpg-create-instance: a non-owner syncs only when the shared Secrets exist (Round 23 review)
cat > "$TMP/prelude-day0.sh" <<PRELUDE
source "$TMP/prelude.sh"
use_cluster() { CLUSTER="\$1"; }
record_status() { :; }
record_entry() { printf '%s|%s|%s|%s\n' "\$1" "\$2" "\${3:-}" "\${4:-}" >> "$TMP/records"; }
operator_wait_ready() { return 0; }
azure_backup_supported() { return 0; }
fleet_head() { echo rev0; }
sync_instance_app() { ev "sync_instance_app \$2"; return 0; }
pg_wait_ready() { return 0; }
exposure_follow() { EXPOSURE_DETAIL=ClusterIP; return 0; }
secret_present() { return 0; }
app_exists() { [[ " \$(cat "$TMP/removed" 2>/dev/null | tr '\n' ' ') " != *" \$1 "* ]]; }
tk() {
  case "\$*" in
    *" get secret "*)   # -n NS get secret NAME: the Secrets in \$TMP/secrets as "ns/name" lines
      grep -qx "\$2/\$5" "$TMP/secrets" ;;
    *"get postgres "*) printf 'stanza-x' ;;
    *) return 0 ;;
  esac
}
PRELUDE
sed -e "s#source /scripts/lib.sh#source $TMP/prelude-day0.sh#" "$ROOT/workflows/scripts/day0-deploy.sh" > "$TMP/day0-deploy.sh"
deploy() {  # deploy INSTANCES_JSON: day0-deploy.sh for c1 (tpg-create-instance scope) with this inventory
  mkdir -p "$TMP/work"
  jq -cn --argjson i "$1" '[{name: "c1", instances: $i}]' > "$TMP/inventory-day0.json"
  RC=0; OUT="$(DEPLOY_SCOPE=instances bash -c "run_data() { cat '$TMP/inventory-day0.json'; }; export -f run_data; exec bash '$TMP/day0-deploy.sh' wf c1 600" 2>&1)" || RC=$?
}
INV_B='[{"name":"app-b","namespace":"shared","secretsOwner":false,"postgresVersion":"postgres-17.6"}]'
# the inventory comes from run_data: the day0 prelude reads the file
sed -i "s#^record_status() { :; }#record_status() { :; }\nrun_data() { cat \"$TMP/inventory-day0.json\"; }#" "$TMP/prelude-day0.sh"
reset
: > "$TMP/secrets"   # the namespace has no regsecret / backup-storage yet
deploy "$INV_B"
c_sel="$(lineno 'sync tpg-c1-app-a|renders the shared Secrets|tracked-by=tpg-c1-app-a|selective:')"; c_app="$(lineno 'sync_instance_app app-b')"
[[ -n "$c_sel" && -n "$c_app" && "$c_sel" -lt "$c_app" ]] \
  && ok "day0-deploy: a non-owner with no shared Secrets in its namespace: the owner's shared objects are synced first (selective), then the instance" || bad "non-owner syncs owner first" "$(cat "$TMP/events") $(cat "$TMP/records") $OUT"
reset
printf 'shared/regsecret\nshared/backup-storage\n' > "$TMP/secrets"
deploy "$INV_B"
! has_ev 'sync tpg-c1-app-a' && has_ev 'sync_instance_app app-b' \
  && ok "day0-deploy: the shared Secrets exist: the non-owner syncs at once, no sync of the owner" || bad "secrets there" "$(cat "$TMP/events") $OUT"
reset
: > "$TMP/secrets"; echo tpg-c1-app-a >> "$TMP/removed"
deploy "$INV_B"
rec "result.c1|FAILED|SHARED_SECRETS_MISSING" | grep -q "tpg-c1-app-a, the instance that owns the shared Secrets there, has no Argo CD Application" && ! has_ev 'sync_instance_app' \
  && ok "day0-deploy: the owner has no Application: SHARED_SECRETS_MISSING names it, the instance is not synced" || bad "owner no app" "$(cat "$TMP/events") $(cat "$TMP/records") $OUT"
reset
yq -i '.clusters.c1.instances["app-a"].instance.sharedSecretsOwner = false' "$TMP/fleet.yaml"
: > "$TMP/secrets"
deploy "$INV_B"
rec "result.c1|FAILED|SHARED_SECRETS_MISSING" | grep -q "no other instance of the namespace does" && ! has_ev 'sync_instance_app' \
  && ok "day0-deploy: no instance of the namespace owns the shared Secrets: SHARED_SECRETS_MISSING says so" || bad "no owner" "$(cat "$TMP/events") $(cat "$TMP/records") $OUT"
reset
INV_AB='[{"name":"app-b","namespace":"shared","secretsOwner":false,"postgresVersion":"postgres-17.6"},{"name":"app-a","namespace":"shared","secretsOwner":true,"postgresVersion":"postgres-17.6"}]'
printf 'shared/regsecret\nshared/backup-storage\n' > "$TMP/secrets"
deploy "$INV_AB"
[[ "$(grep -F 'sync_instance_app' "$TMP/events" | paste -sd' ')" == "sync_instance_app app-a sync_instance_app app-b" ]] \
  && ok "day0-deploy: the owner of the namespace is synced before the instance that shares it (inventory order b, a)" || bad "owner first in deploy" "$(cat "$TMP/events") $OUT"

echo
echo "delete: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
