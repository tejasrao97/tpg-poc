#!/usr/bin/env bash
# delete-instance.sh WORKFLOW CLUSTER INSTANCE CONFIRM FINAL_BACKUP PURGE_PVCS PURGE_NAMESPACE TIMEOUT
# Guarded delete of one Postgres instance (README: Day 2: delete).
#   1 guards      confirm == instance, instance declared in clusters/fleet.yaml (ALLOW_UNTRACKED=true:
#                 may be missing there), no backup/restore/upgrade in progress
#   2 backup      final full backup when the instance is Running (finalBackup: true|false|required)
#   2b            FerretDB and the operator backup schedules of the instance (D70, D71), deleted
#                 only after the final backup, so a failed run leaves the instance as it was
#   3 Git         remove clusters.<cluster>.instances.<instance> from clusters/fleet.yaml and keep
#                 a copy in clusters/deleted/<cluster>/<instance>-<time>.yaml (PUSH_MODE direct | pr);
#                 the ApplicationSet removes the Application without touching resources
#   4 delete      Postgres CR (operator removes pods, services, secrets) and backup location CR
#   5 purge       optional: PVCs and their Retain PVs/disks; optional: the namespace
# The Azure Blob backup repository is never deleted by this workflow.
# Namespace (Round 23): the instance's namespace is read from clusters/fleet.yaml (instance.namespace,
# default pg-<instance>; the copy in clusters/deleted/ when the entry is gone). Instances may share a
# namespace, and then
#   - purgeNamespace=true is refused (NAMESPACE_SHARED, before anything changes) while another instance
#     of the namespace remains in clusters/fleet.yaml or on the cluster. tpg-delete-apps passes
#     DELETE_RUN_INSTANCES (the instances of its run: they leave anyway, so the namespace is deleted
#     after the last of them) and, with deleteOperator, DELETE_OPERATOR_RUN=true (it removes everything:
#     the namespace is deleted after the last instance of it, by tpg-delete-apps; NS_PURGE_FILE)
#   - the PVCs of the purge are the ones of this instance (label postgres-instance), not every PVC
#   - an owner of the shared Secrets hands them over to a remaining instance before its entry leaves
#     Git (lib.sh ns_handover: the successor's Application must exist; the owner flags move in one
#     commit; only the shared objects of the successor's Application are synced; the tracking
#     annotation and the Secrets are checked; one Argo CD Application owns the objects at any moment).
#     A failure after the flag commit reverts it (HANDOVER_FAILED, the instance stays). With
#     DELETE_RUN_INSTANCES the successor is one of the other instances that stay, never one that
#     leaves in the same run
#   - when the entry is already gone (a re-run) the namespace is read from the audit copy
#     clusters/deleted/<cluster>/<instance>-<yyyymmddHHMM>.yaml (exactly that name, lib.sh deleted_copy) and
#     checked against the live Postgres (NAMESPACE_MISMATCH, NAMESPACE_AMBIGUOUS: lib.sh gone_instance_ns)
#     The namespace resolved here is handed to every helper (lib.sh instance_ns_override: busy_operations,
#     pg_state, backup-instance.sh), so none of them falls back to pg-<instance> for a gone entry
# DELETE_FROM_MAP=true (tpg-delete-instance, tpg-delete-apps): finalBackup,
# purgePvcs and purgeNamespace come from clusterMap (P_CLUSTER_MAP) when set for
# the instance, and the clusterMap postgresVersion guard applies.
WF="$1"; C="$2"; I="$3"; CONFIRM="$4"; FINAL_BACKUP="${5:-true}"; PURGE_PVCS="${6:-false}"; PURGE_NS="${7:-false}"; TIMEOUT="${8:-1800}"
# shellcheck source=workflows/scripts/lib.sh
source /scripts/lib.sh

key="result.${C}.${I}"
notes=()
fail() { record "$key" FAILED "$1" "${2:-}"; exit 1; }
result_guard "$key"

if [[ "${DELETE_FROM_MAP:-false}" == "true" ]]; then
  FINAL_BACKUP="$(cmap_ival "$C" "$I" finalBackup "$FINAL_BACKUP")"
  PURGE_PVCS="$(cmap_ival "$C" "$I" purgePvcs "$PURGE_PVCS")"
  PURGE_NS="$(cmap_ival "$C" "$I" purgeNamespace "$PURGE_NS")"
fi

# ---- 1 guards
[[ "$CONFIRM" == "$I" ]] || fail NOT_CONFIRMED "set confirm=${I}"
[[ "$PURGE_NS" != "true" || "$PURGE_PVCS" == "true" ]] || fail INVALID_OPTIONS "purgeNamespace=true needs purgePvcs=true"
git_clone "$WORK/repo"
fleet_materialize "$WORK/repo"
f="$WORK/fleet/${C}/${I}.yaml"
if [[ ! -f "$f" ]]; then
  if deleted_copy "$WORK/repo" "$C" "$I" >/dev/null; then
    notes+=("instance already removed from fleet.yaml (re-run)")
  elif [[ "${ALLOW_UNTRACKED:-false}" == "true" ]]; then
    notes+=("instance was not declared in fleet.yaml")
  else
    fail UNKNOWN_INSTANCE "no clusters.${C}.instances.${I} in ${FLEET_REL}; declared: $(fleet_instances "$WORK/repo" "$C" | paste -sd, -)"
  fi
fi
use_cluster "$C" || fail NOT_REGISTERED
# ---- the namespace of the instance (Round 23): its entry; when the entry is gone (a re-run) the audit copy
#      clusters/deleted/<cluster>/<instance>-<yyyymmddHHMM>.yaml, matched by exactly that name and checked
#      against the live Postgres (lib.sh gone_instance_ns); without a copy the live Postgres of that name
#      (ALLOW_UNTRACKED), never a guess when two have it
if [[ -f "$f" ]]; then
  NS="$(instance_ns "$C" "$I")" || fail FLEET_UNREADABLE "$FLEET_UNREADABLE_DETAIL"
else
  gone_instance_ns "$WORK/repo" "$C" "$I" || fail "$GONE_REASON" "$GONE_DETAIL"
  NS="$GONE_NS"
fi
# every helper below (busy_operations, pg_state, backup-instance.sh) asks lib.sh instance_ns, which reads the
# entry in the checkout and gives pg-<instance> for a gone one: tell it the namespace resolved here
instance_ns_override "$C" "$I" "$NS"
if [[ "${DELETE_FROM_MAP:-false}" == "true" ]] && ! g="$(cmap_guard "$C" "$I")"; then
  record "$key" SKIPPED_VERSION_MISMATCH "" "$g"
  exit 0
fi
# ---- instances that share the namespace (Round 23)
SHARED="$(fleet_ns_members "$WORK/repo" "$C" "$NS" | grep -vFx -- "$I" || true)"   # in clusters/fleet.yaml
LIVE_OTHERS="$(tk -n "$NS" get postgres -o json 2>/dev/null | jq -r --arg i "$I" '.items[]? | select(.metadata.name != $i) | .metadata.name' || true)"
OTHERS="$(printf '%s\n%s\n' "$SHARED" "$LIVE_OTHERS" | grep -v '^$' | sort -u || true)"   # every other instance that uses the namespace
RUN_LEAVES="$(tr ' ' '\n' <<<"${DELETE_RUN_INSTANCES:-}")"                             # tpg-delete-apps: the instances of the run leave too
BLOCKERS=""                                                                              # the others that stay after this run
for o in $OTHERS; do grep -Fqx -- "$o" <<<"$RUN_LEAVES" || BLOCKERS="${BLOCKERS:+${BLOCKERS} }${o}"; done
DEFER_NS=false
if [[ "$PURGE_NS" == "true" && -n "$OTHERS" ]]; then
  if [[ -n "$BLOCKERS" && "${DELETE_OPERATOR_RUN:-false}" != "true" ]]; then
    fail NAMESPACE_SHARED "purgeNamespace=true would delete namespace ${NS}, which ${BLOCKERS// /, } also use(s); delete ${BLOCKERS// /, } first, or set purgeNamespace=false (tpg-delete-apps with deleteOperator=true removes everything)"
  fi
  # every other instance of the namespace leaves in this run (or deleteOperator removes everything):
  # the namespace is deleted after the last of them, not while one of them still needs its final backup
  DEFER_NS=true; PURGE_NS=false
fi
EXISTS=true
tk -n "$NS" get postgres "$I" >/dev/null 2>&1 || EXISTS=false
if [[ "$EXISTS" == "true" ]]; then
  busy="$(busy_operations "$I")"
  [[ -z "$busy" ]] || fail OPERATION_IN_PROGRESS "$busy"
fi

# ---- 2 final backup
if [[ "$EXISTS" == "true" && "$FINAL_BACKUP" != "false" ]]; then
  if [[ "$(pg_state "$I")" == "Running" ]]; then
    bash /scripts/backup-instance.sh "$WF" "$C" "$I" full "$TIMEOUT"
    b="$(run_data "$key")"
    [[ "$(jq -r '.status' <<<"$b")" == "SUCCEEDED" ]] || fail FINAL_BACKUP_FAILED "$(jq -r '.status + " " + .reason + " " + .detail' <<<"$b")"
    notes+=("final backup $(jq -r '.detail' <<<"$b" | cut -d' ' -f1)")
  elif [[ "$FINAL_BACKUP" == "required" ]]; then
    fail FINAL_BACKUP_IMPOSSIBLE "currentState=$(pg_state "$I")"
  else
    notes+=("no final backup: currentState=$(pg_state "$I")")
  fi
fi
stanza="$(tk -n "$NS" get postgres "$I" -o jsonpath='{.status.stanzaName}' 2>/dev/null || true)"

# ---- 2b FerretDB and the operator backup schedules (D70, D71), after the final
#      backup succeeded and before the entry leaves Git: FerretDB would lose its
#      backend, and no scheduled backup may start during the delete. A run that
#      stopped earlier (guards, final backup) leaves both in place
if [[ "$EXISTS" == "true" ]]; then
  for kind in postgresferretdocumentdb postgresbackupschedule; do
    tk get crd "${kind}s.sql.tanzu.vmware.com" >/dev/null 2>&1 || continue
    gone="$(tk -n "$NS" get "$kind" -o json 2>/dev/null | jq -r --arg i "$I" '[.items[]
      | select(.metadata.name == $i or .metadata.labels["tpg.fleet/instance"] == $i
               or .spec.backupTemplate.spec.sourceInstance.name == $i) | .metadata.name] | join(" ")')"
    [[ -n "$gone" ]] || continue
    # shellcheck disable=SC2086  # the names, one argument each
    tk -n "$NS" delete "$kind" $gone --wait=true --timeout=300s >/dev/null || fail DELETE_TIMEOUT "${kind} ${gone}"
    notes+=("${kind} ${gone// /,} deleted")
  done
fi

# ---- 2c shared namespace (Round 23): when other instances of the namespace stay, the Secrets they
#      share move to one of them before this entry leaves Git (lib.sh ns_handover: commit the owner
#      flags, sync the successor, check the Argo CD tracking annotation moved - one owner at any moment)
if [[ -f "$f" && -n "$SHARED" ]]; then
  stay=""
  for o in $SHARED; do grep -Fqx -- "$o" <<<"$RUN_LEAVES" || stay="${stay:+${stay} }${o}"; done
  if [[ -z "$stay" ]]; then
    notes+=("shared Secrets of ${NS} stay: every other instance of it leaves in this run")
  elif ! ns_handover "$WORK/repo" "$C" "$I" "$NS" "$TIMEOUT" "$stay"; then
    fail "$HANDOVER_REASON" "$HANDOVER_DETAIL"
  elif [[ -n "$HANDOVER_NOTE" ]]; then
    notes+=("$HANDOVER_NOTE")
  fi
fi

# ---- 3 Git: remove the entry from fleet.yaml, keep a copy for audit and re-creation
if [[ -f "$f" ]]; then
  mkdir -p "$WORK/repo/clusters/deleted/${C}"
  drel="clusters/deleted/${C}/${I}-$(date -u +%Y%m%d%H%M).yaml"
  C="$C" I="$I" yq '.clusters[strenv(C)].instances[strenv(I)]' "$WORK/repo/$FLEET_REL" > "$WORK/repo/$drel"
  W="$WF" T="$(date -u +%Y-%m-%dT%H:%M:%SZ)" S="$stanza" yq -i '.deleted = {"workflow": strenv(W), "time": strenv(T), "stanzaName": strenv(S)}' "$WORK/repo/$drel"
  C="$C" I="$I" yq -i 'del(.clusters[strenv(C)].instances[strenv(I)])' "$WORK/repo/$FLEET_REL"
  rm -rf "$WORK/fleet"   # nothing to write back: the entry is gone
  git_commit_push "$WORK/repo" "delete ${C}/${I} (${WF})" "$FLEET_REL" "$drel" || fail GIT_PUSH_FAILED "pushMode=${PUSH_MODE:-direct}"
fi
app="tpg-${C}-${I}"
appset_refresh tpg-instances
app_removed_or_force "$app" "${P_FORCE_DELETE_STUCK:-true}" \
  || fail APPLICATION_NOT_REMOVED "$app still exists (stuck: $(app_stuck_reason "$app" || true)); check tpg-instances preserveResourcesOnDeletion"
[[ -z "$FORCED_NOTE" ]] || notes+=("$FORCED_NOTE")

# ---- 4 delete the database objects
if [[ "$EXISTS" == "true" ]]; then
  tk -n "$NS" delete postgres "$I" --wait=true --timeout="${TIMEOUT}s" >/dev/null || fail DELETE_TIMEOUT "postgres ${I}"
  for _ in $(seq 1 40); do
    [[ "$(tk -n "$NS" get pods -l "postgres-instance=${I}" -o name 2>/dev/null | wc -l)" -eq 0 ]] && break
    sleep 15
  done
fi
tk -n "$NS" delete postgresbackuplocation "${I}-backup-location" --ignore-not-found --wait=true >/dev/null || notes+=("backup location CR not deleted")

# ---- 5 optional purge
# a namespace that other instances use: only the PVCs of this instance (label postgres-instance)
pvc_get=(); pvc_del=(--all)
[[ -z "$OTHERS" ]] || { pvc_get=(-l "postgres-instance=${I}"); pvc_del=(-l "postgres-instance=${I}"); }
pvcs="$(tk -n "$NS" get pvc ${pvc_get[@]+"${pvc_get[@]}"} -o json 2>/dev/null || echo '{"items":[]}')"
count="$(jq '.items | length' <<<"$pvcs")"
if [[ "$PURGE_PVCS" == "true" && "$count" -gt 0 ]]; then
  # Retain StorageClass: switch each bound PV to Delete first so the Azure disk goes too
  for pv in $(jq -r '.items[].spec.volumeName // empty' <<<"$pvcs"); do
    tk patch pv "$pv" -p '{"spec":{"persistentVolumeReclaimPolicy":"Delete"}}' >/dev/null || notes+=("pv ${pv} not patched")
  done
  tk -n "$NS" delete pvc "${pvc_del[@]}" --wait=true --timeout=600s >/dev/null || fail PVC_DELETE_FAILED
  notes+=("${count} PVCs and disks deleted")
elif [[ "$count" -gt 0 ]]; then
  notes+=("${count} PVCs kept in ${NS} (Retain)")
elif [[ "$PURGE_PVCS" == "true" && -n "$OTHERS" ]]; then
  notes+=("no PVC with the label postgres-instance=${I} in ${NS}, which other instances share: nothing purged")
fi
if [[ "$PURGE_NS" == "true" ]]; then
  tk delete namespace "$NS" --wait=true --timeout=600s >/dev/null || fail NAMESPACE_DELETE_FAILED
  notes+=("namespace ${NS} deleted")
elif [[ "$DEFER_NS" == "true" ]]; then
  # purgeNamespace with other instances in the namespace that leave in this run (tpg-delete-apps):
  # the namespace is deleted after the last of them, by delete-apps.sh
  printf '%s\n' "$NS" >> "${NS_PURGE_FILE:-$WORK/ns-purge}"
  notes+=("namespace ${NS} is deleted after the last instance of it (${OTHERS//$'\n'/, })")
fi
notes+=("backup repository kept: stanza ${stanza:-unknown}")
detail="$(printf '%s; ' "${notes[@]}")"
record "$key" SUCCEEDED "" "${detail%; }"
