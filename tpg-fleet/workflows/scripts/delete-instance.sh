#!/usr/bin/env bash
# delete-instance.sh WORKFLOW CLUSTER INSTANCE CONFIRM FINAL_BACKUP PURGE_PVCS PURGE_NAMESPACE TIMEOUT [PURGE_BACKUPS]
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
# The Azure Blob backup repository is kept unless purgeBackups=true (Round 23, locked decision 4):
#   - before the delete (2b2), while the operator runs: every PostgresBackup of the instance is expired
#     (spec.expire=true, newest first, lib.sh backup_expire_all); what pgBackRest declines is reported, not a
#     failure; no answer in time (BACKUP_EXPIRE_TIMEOUT) or an API error (BACKUP_EXPIRE_ERROR) fails the run before anything is deleted
#   - after the instance and its backup location are gone (4b): every blob under the container and repoPath of
#     the location is deleted (Azure Blob REST, the storage key from Vault, lib.sh blob_delete_prefix)
#   - a repoPath that another PostgresBackupLocation on ANY registered cluster also uses (also a folder inside
#     or around it; a cluster that cannot be scanned counts as sharing) is only expired: the blobs stay and the
#     result and a warning say so
#   - refused before anything changes: finalBackup true or required (the final backup would be deleted at once:
#     INVALID_OPTIONS), a location that cannot be read (PURGE_LOCATION_UNKNOWN), the repository root as repoPath
#     (PURGE_REPOPATH_REFUSED), no storage key in Vault (NO_VAULT_SECRET), a location on another storage
#     account than the fleet's (PURGE_ACCOUNT_MISMATCH)
#   - the container, repoPath, endpoint, Secret name and storage account of the location are copied into the audit
#     copy (deleted.backupLocation), so a re-run finds them after the location object is gone, and compares the
#     account with the fleet's (PURGE_ACCOUNT_MISMATCH); a non-default Secret whose account cannot be determined is
#     refused (PURGE_ACCOUNT_UNKNOWN)
#   - the sharing check runs twice: at the start (the refusal and the plan) and again right before the blobs are
#     deleted (a location that appeared meanwhile keeps them: BACKUP_REPO_SHARED)
#   - a re-run after BLOB_PURGE_FAILED (the Postgres, the entry and the location are gone) names the instance again
#     with purgeBackups=true: tpg-delete-instance (discover.sh) and tpg-delete-apps accept it because the audit copy
#     records the repository; this script then finishes the blob purge only (blob requests are retried on
#     429, 5xx and curl failures)
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
WF="$1"; C="$2"; I="$3"; CONFIRM="$4"; FINAL_BACKUP="${5:-true}"; PURGE_PVCS="${6:-false}"; PURGE_NS="${7:-false}"; TIMEOUT="${8:-1800}"; PURGE_BACKUPS="${9:-false}"
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
  PURGE_BACKUPS="$(cmap_ival "$C" "$I" purgeBackups "$PURGE_BACKUPS")"
fi

# ---- 1 guards
[[ "$CONFIRM" == "$I" ]] || fail NOT_CONFIRMED "set confirm=${I}"
[[ "$PURGE_NS" != "true" || "$PURGE_PVCS" == "true" ]] || fail INVALID_OPTIONS "purgeNamespace=true needs purgePvcs=true"
[[ "$PURGE_BACKUPS" != "true" || "$FINAL_BACKUP" == "false" ]] \
  || fail INVALID_OPTIONS "purgeBackups=true needs finalBackup=false: the final backup (finalBackup=${FINAL_BACKUP}) would be expired and deleted with the others"
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

# ---- 1b the backup repository (Round 23): where the instance's backups are, for the audit copy and for
#      purgeBackups; everything that can refuse a purge is decided here, before anything changes
LOC="${I}-backup-location"
LOC_KNOWN=false; LOC_CONT=""; LOC_PATH=""; LOC_EP=""
LOC_SECRET=""; LOC_ACCT=""
if location_repo "$NS" "$LOC"; then
  LOC_KNOWN=true; LOC_CONT="$BL_CONTAINER"; LOC_PATH="$BL_PATH"; LOC_EP="$BL_ENDPOINT"; LOC_SECRET="$BL_SECRET"
  LOC_ACCT="$(_secret_account "$NS" "${LOC_SECRET:-backup-storage}")"   # empty when the Secret cannot be read: judged below
elif deleted_backup_repo "$WORK/repo" "$C" "$I"; then
  # a re-run: the location object is gone, the audit copy of the first run has what it pointed to
  acopy="$(deleted_copy "$WORK/repo" "$C" "$I")"
  LOC_KNOWN=true; LOC_CONT="$(yq -r '.deleted.backupLocation.container' "$acopy")"; LOC_PATH="$(yq -r '.deleted.backupLocation.repoPath // "/"' "$acopy")"
  LOC_EP="$(yq -r '.deleted.backupLocation.endpoint // "blob.core.windows.net"' "$acopy")"
  LOC_SECRET="$(yq -r '.deleted.backupLocation.secret // "backup-storage"' "$acopy")"; LOC_ACCT="$(yq -r '.deleted.backupLocation.accountName // ""' "$acopy")"
  # a copy that does not record the account (written before Round 23 review, or the Secret was unreadable then): the Secret may still be there
  [[ -n "$LOC_ACCT" ]] || LOC_ACCT="$(_secret_account "$NS" "$LOC_SECRET")"
fi
PURGE_BLOBS=false; REPO_NOTE=""; EXPIRE_WORD="no backups expired"   # how 4b words a kept repository: "backups expired" once the expire ran
if [[ "$PURGE_BACKUPS" == "true" ]]; then
  [[ "$LOC_KNOWN" == "true" ]] \
    || fail PURGE_LOCATION_UNKNOWN "PostgresBackupLocation ${NS}/${LOC} does not exist and no audit copy in clusters/deleted/${C} records its container and repoPath, so the backups cannot be found; set purgeBackups=false (the blobs stay), or delete them by hand"
  [[ "$(repo_norm "$LOC_PATH")" != "/" ]] \
    || fail PURGE_REPOPATH_REFUSED "the repoPath of ${LOC} is the root of container ${LOC_CONT}; purgeBackups never deletes a whole container (set purgeBackups=false and delete the blobs by hand)"
  if repo_shared "$C" "$NS" "$LOC" "$LOC_CONT" "$LOC_PATH" "$LOC_EP" "$LOC_ACCT"; then
    REPO_NOTE="repository ${LOC_CONT}${LOC_PATH} is also used by ${REPO_SHARED_WITH}"
  else
    PURGE_BLOBS=true
    ST_ACCOUNT="$(vault_secret backup-storage accountName)" \
      || fail NO_VAULT_SECRET "backup-storage (tpg/shared/backup-storage): the storage account is needed to delete the blobs of ${LOC_CONT}${LOC_PATH}"
    vault_secret backup-storage accountKey >/dev/null \
      || fail NO_VAULT_SECRET "backup-storage (tpg/shared/backup-storage): the storage key is needed to delete the blobs of ${LOC_CONT}${LOC_PATH}"
    # the account behind the Secret of the location (read now, or recorded in the audit copy of a re-run) must be the
    # account of the key in Vault. An unreadable account is only accepted for the fleet's own Secret backup-storage
    # (synced from that same Vault entry); any other Secret could point anywhere
    if [[ -z "$LOC_ACCT" ]]; then
      [[ "${LOC_SECRET:-backup-storage}" == "backup-storage" ]] \
        || fail PURGE_ACCOUNT_UNKNOWN "the storage account of Secret ${LOC_SECRET} (backup location ${LOC}) cannot be determined (the Secret in ${NS} cannot be read and the audit copy does not record it), so the key in Vault (account ${ST_ACCOUNT}) may not belong to it; the blobs are not deleted"
    else
      [[ "$LOC_ACCT" == "$ST_ACCOUNT" ]] \
        || fail PURGE_ACCOUNT_MISMATCH "the Secret ${LOC_SECRET:-backup-storage} of ${LOC} names storage account ${LOC_ACCT}, the key in Vault is the fleet's account ${ST_ACCOUNT}; the blobs are not deleted"
    fi
  fi
  notes+=("purgeBackups: ${LOC_CONT}${LOC_PATH}")
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

# ---- 2b2 purgeBackups (Round 23): expire every PostgresBackup while the operator runs. The Postgres is still
#      there (the entry only leaves Git below), so the operator can run pgBackRest expire for each backup set.
#      What pgBackRest declines is reported; no answer in time stops the run before the delete
if [[ "$PURGE_BACKUPS" == "true" ]]; then
  if [[ "$EXISTS" != "true" ]]; then
    notes+=("no backups expired: Postgres ${I} does not run (the operator cannot expire)")
    [[ -f "$f" ]] || notes+=("re-run: the Postgres and its fleet.yaml entry are already deleted; only the blob purge is finished")
  elif [[ "$(pg_state "$I")" != "Running" ]]; then
    # the operator expires only while the instance runs. Its blobs go anyway when the repository is its own;
    # a repository another location uses would keep backups of this instance that nobody can expire any more
    [[ "$PURGE_BLOBS" == "true" ]] \
      || fail BACKUP_EXPIRE_IMPOSSIBLE "currentState=$(pg_state "$I"): the operator cannot expire backups, and ${REPO_NOTE:-the repository is shared}; nothing was deleted"
    notes+=("no backups expired: currentState=$(pg_state "$I") (the blobs are deleted anyway)")
  elif backup_expire_all "$NS" "$I" "$TIMEOUT"; then
    EXPIRE_WORD="backups expired"
    notes+=("${BE_EXPIRED} backups expired$([[ "$BE_SKIPPED" -eq 0 ]] || echo ", ${BE_SKIPPED} without a pgBackRest label skipped")")
    if [[ "${#BE_DECLINED[@]}" -gt 0 ]]; then
      notes+=("pgBackRest declined to expire ${#BE_DECLINED[@]}: $(printf '%s; ' "${BE_DECLINED[@]}" | sed 's/; $//')")
      record_entry "warning.${C}.${I}" WARNING BACKUP_EXPIRE_DECLINED "$(printf '%s; ' "${BE_DECLINED[@]}" | sed 's/; $//')"
    fi
  else
    # no answer in time (TIMEOUT), or the backups/the expire could not be read or set (ERROR): two different fixes
    fail "BACKUP_EXPIRE_${BE_FAIL_OUTCOME:-ERROR}" "nothing was deleted; $(printf '%s; ' "${BE_FAILED[@]}" | sed 's/; $//')"
  fi
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
  # where the backups are (Round 23): a re-run with purgeBackups finds the repository here after the location object is gone,
  # and the storage account its Secret named ("" when it could not be read), to compare with the fleet's account
  [[ "$LOC_KNOWN" != "true" ]] || BC="$LOC_CONT" BP="$LOC_PATH" BE="${LOC_EP:-blob.core.windows.net}" BS="${LOC_SECRET:-backup-storage}" BA="$LOC_ACCT" \
    yq -i '.deleted.backupLocation = {"container": strenv(BC), "repoPath": strenv(BP), "endpoint": strenv(BE), "secret": strenv(BS), "accountName": strenv(BA)}' "$WORK/repo/$drel"
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

# ---- 4b purgeBackups (Round 23): the instance and its location are gone; delete every blob left under its
#      container and repoPath (unless another location uses the repository: then the blobs stay)
if [[ "$PURGE_BACKUPS" == "true" ]]; then
  if [[ "$PURGE_BLOBS" == "true" ]]; then
    # a lot has happened since the check at 1b (expires, hand-over, push and the wait for a pull request, the
    # Application removal, the Postgres delete): look again before the first blob goes. A location that uses the
    # repository now keeps the blobs
    if repo_shared "$C" "$NS" "$LOC" "$LOC_CONT" "$LOC_PATH" "$LOC_EP" "$LOC_ACCT"; then
      PURGE_BLOBS=false
      REPO_NOTE="repository ${LOC_CONT}${LOC_PATH} is now also used by ${REPO_SHARED_WITH} (found just before the blobs were to be deleted)"
    fi
  fi
  if [[ "$PURGE_BLOBS" == "true" ]]; then
    # the storage key lives in this shell only (Vault Agent file -> variable -> python3 environment); it is
    # not logged, not recorded and not in an argument
    ST_KEY="$(vault_secret backup-storage accountKey)" || fail NO_VAULT_SECRET "backup-storage (tpg/shared/backup-storage)"
    if blob_delete_prefix "$ST_ACCOUNT" "$ST_KEY" "$LOC_CONT" "$LOC_PATH" "$LOC_EP"; then
      ST_KEY=""
      notes+=("${BLOB_DELETED} blobs deleted under ${LOC_CONT}${LOC_PATH}")
    else
      ST_KEY=""
      fail BLOB_PURGE_FAILED "${BLOB_ERROR} (${BLOB_DELETED} deleted); the instance is deleted, run tpg-delete-instance again with purgeBackups=true to finish"
    fi
  else
    notes+=("${EXPIRE_WORD}, blobs KEPT: ${REPO_NOTE}")
    record_entry "warning.${C}.${I}.repo" WARNING BACKUP_REPO_SHARED "${REPO_NOTE}: the blobs under ${LOC_CONT}${LOC_PATH} were not deleted"
  fi
fi

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
[[ "$PURGE_BACKUPS" == "true" ]] || notes+=("backup repository kept: stanza ${stanza:-unknown}")
detail="$(printf '%s; ' "${notes[@]}")"
record "$key" SUCCEEDED "" "${detail%; }"
