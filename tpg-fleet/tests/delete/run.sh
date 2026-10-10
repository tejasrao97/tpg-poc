#!/usr/bin/env bash
# tpg-delete-instance and tpg-delete-apps with instances that share a namespace (Round 23,
# locked decision 8; workflows/scripts/delete-instance.sh, delete-apps.sh, lib.sh ns_handover):
#   hand-over     the owner of the shared Secrets leaves: the owner flags move in one commit, the
#                 successor's Application is synced (it adopts the objects), the tracking annotation is
#                 checked, and only then the entry leaves Git and the Application is removed - so
#                 exactly one Application tracks the shared Secrets at every step, and they are
#                 never deleted
#   purge         purgeNamespace is refused while another instance of the namespace remains
#                 (NAMESPACE_SHARED, nothing changes); allowed for the last one; PVCs are the ones of
#                 the instance; tpg-delete-apps defers the namespace to after the last instance of the
#                 run, and with deleteOperator removes everything
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
# the shared VaultStaticSecret becomes the one Argo CD tracks it with (the apply writes the annotation)
app_sync_wait() {
  local app="$1" inst
  inst="${app#tpg-c1-}"
  rm -rf "@TMP@/render-repo"; mkdir -p "@TMP@/render-repo/clusters" "@TMP@/render-repo/helm_artifacts"
  cp -r "@REPO@/helm_artifacts/instance" "@TMP@/render-repo/helm_artifacts/"; cp -r "@REPO@/clusters/_template" "@TMP@/render-repo/clusters/"
  cp "@TMP@/fleet.yaml" "@TMP@/render-repo/clusters/fleet.yaml"
  if instance_render "@TMP@/render-repo" c1 "$inst" 2>/dev/null | yq -e 'select(.kind == "VaultStaticSecret" and .metadata.name == "regsecret")' >/dev/null 2>&1; then
    echo "$app" > "@TMP@/tracked"
    ev "sync $app|renders the shared Secrets|tracked-by=$app"
  else
    ev "sync $app|renders no shared Secrets|tracked-by=$(cat "@TMP@/tracked")"
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
    *"get vaultstaticsecret regsecret"*)
      jq -cn --arg t "$(cat "@TMP@/tracked"):apiextensions/VaultStaticSecret:${ns}/regsecret" '{metadata: {annotations: {"argocd.argoproj.io/tracking-id": $t}}}' ;;
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
  rm -rf "$TMP/work" "$TMP/deleted" "$TMP/render-repo"; : > "$TMP/nsgone"; : > "$TMP/records"; : > "$TMP/events"; : > "$TMP/removed"; echo 0 > "$TMP/rev"
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
rec() { grep -F "$1" "$TMP/records" || true; }
lineno() { grep -n -F -- "$1" "$TMP/events" | head -n1 | cut -d: -f1; }   # first line of the events file with the text, empty when none
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

# the successor cannot take over: the instance stays
reset
app_sync_fail='app_sync_wait() { SYNC_FAIL_REASON=SYNC_FAILED; SYNC_FAIL_DETAIL="tpg-c1-app-b: sync failed"; return 1; }'
{ cat "$TMP/prelude.sh"; echo "$app_sync_fail"; } > "$TMP/prelude-fail.sh"
sed "s#$TMP/prelude.sh#$TMP/prelude-fail.sh#" "$TMP/delete-instance.sh" > "$TMP/delete-instance-fail.sh"
RC=0; OUT="$(bash "$TMP/delete-instance-fail.sh" wf c1 app-a app-a false false false 600 2>&1)" || RC=$?
rec "result.c1.app-a|FAILED|HANDOVER_FAILED" | grep -q "SYNC_FAILED" && ! has_ev 'commit rev2' && ! has_ev 'removed' && yq -e '.clusters.c1.instances | has("app-a")' "$TMP/fleet.yaml" >/dev/null \
  && ok "hand-over: when the successor does not sync the delete stops before app-a leaves Git (HANDOVER_FAILED)" || bad "hand-over failed" "$(cat "$TMP/events") $(cat "$TMP/records")"

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
  && ok "delete-apps: without purgeNamespace the owner hands over to the instance that stays (app-c)" || bad "apps handover" "$(cat "$TMP/events") $OUT"
reset
apps '{"c1":["tpg-instances","tpg-operator"]}' true true
[[ "$RC" -eq 0 ]] && [[ "$(grep -c 'delete namespace shared' "$TMP/events")" == 1 ]] \
  && [[ "$(lineno 'delete namespace shared')" -gt "$(lineno 'delete postgres shared/app-c')" && "$(lineno 'delete namespace shared')" -gt "$(lineno 'delete postgres shared/app-b')" ]] \
  && has_ev 'delete namespace pg-orders-db' && has_ev 'delete namespace tanzu-postgres-operator' && ! has_ev 'sync ' \
  && ok "delete-apps with deleteOperator removes everything: every instance first, each purged namespace once after its last instance, then the operator namespace" || bad "apps operator" "$(cat "$TMP/events") $(cat "$TMP/records") $OUT"
reset
apps '{"c1":["tpg-instances:app-a"]}' true true true
rec "result.c1.app-a|FAILED|NAMESPACE_SHARED" | grep -q . && ok "delete-apps dry run: a purge that would be refused fails in the plan as well" || bad "apps dry run" "$(cat "$TMP/records") $OUT"

echo
echo "delete: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
