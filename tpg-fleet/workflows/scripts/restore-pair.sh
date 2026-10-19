#!/usr/bin/env bash
# restore-pair.sh WORKFLOW_NAME
# Restore one pair of the clusterMap of tpg-restore (Round 23, locked decision 7, phase 6b). The pair
# comes from the environment as the normalized JSON object that clustermap.py restore writes (fields in
# the header of clustermap.py; plan-batches.sh hands it over whole):
#   P_PAIR                   the pair: base64 of its JSON (plan-batches.sh), or the JSON itself
#   P_DRY_RUN                true (default): read-only plan; false: restore
#   P_PUSH_MODE              direct | pr, for the clusters/fleet.yaml entry of a new target
#   P_KEEP_SOURCE_LOCATION   true (default): keep the copy of the source backup location in the target namespace
#   P_TIMEOUT                seconds for the restore phase (the wait for synced backups counts against it)
#   P_PR_TIMEOUT             seconds to wait for a pull request (pushMode pr)
#   P_SYNC_TIMEOUT           seconds for an Argo CD sync of this pair (default 1800)
#   P_READY_TIMEOUT          seconds to wait for the restored instance to run (default 1800)
#   P_BACKUP_TIMEOUT         seconds to wait for the post-restore backup (default 10800)
# The result is result.<target cluster>.<target instance>; pairs are independent of each other.
#
# What a pair does (the numbers are those of the phase 6 plan):
#  1 Source: the instance on its cluster (live?), in clusters/fleet.yaml (its namespace must be the one of the
#    pair), its PostgresVersion (minor, flavour: the -lite pattern of types.yaml liteVersion), its
#    PostgresBackupLocation (container, repoPath, Secret) and stanza.
#  2 Named backup (pitrEnabled false): same namespace -> the PostgresBackup must exist and be Succeeded now
#    (BACKUP_NOT_FOUND, BACKUP_NOT_SUCCEEDED, also in a dry run); another namespace or cluster -> the SOURCE
#    PostgresBackup must be readable and Succeeded first (SOURCE_BACKUP_UNVERIFIED, BACKUP_NOT_SUCCEEDED) and report
#    status.restoreLabel (BACKUP_LABEL_UNKNOWN): backupSync names the synced backup in the target namespace after that label.
#  3 PITR: location and stanza come from the live source, else from the source PostgresBackup; a given value
#    that differs is a WARNING (the given value wins); with neither a live source nor a readable
#    sourceBackupName they are mandatory (PITR_SOURCE_UNKNOWN). srcBackupLabel is spec.pitr.sourceBackupLocation.set.
#    (An in-place pair is only possible on a cluster with clusters.<cluster>.cluster.allowInPlaceRestore: true;
#    the validate step refuses the whole run otherwise, IN_PLACE_NOT_ALLOWED, so no pair gets here without it.)
#  4 Matrix: standard -> lite is BLOCKED (RESTORE_FLAVOUR_UNSUPPORTED); a target version below the version of the backup (the named
#    backup's status.fullPostgresVersion, else the live source's, else its PostgresVersion) is BLOCKED (RESTORE_VERSION_LOWER), a lower
#    major version included. skipMinorVersionCheck only sets the operator's annotation and relaxes none of this; another (higher)
#    major version is the operator's to refuse. Only this pair.
#  5 Target: a live Postgres of the target name in the target namespace on the target cluster is only restored into when it is the
#    source itself (in place); any other is refused for this pair at plan time, also in a dry run (TARGET_EXISTS: restore in place or
#    choose a new instance name). A fleet entry that is declared but not deployed is a new target and its entry is REPLACED (the declared namespace is kept). An in-place pair needs confirm =
#    its name for a real run (validate-params.sh enforces it; CONFIRMATION_MISMATCH here is the second line of defence); confirm on
#    any other pair is refused at validate. The spec file (targetInstanceSpecFilePath) is the source of truth for the restored Postgres:
#    its spec is spec.targetInstance.spec as it is, no merge over a chart render; allowed for a new target and for an in-place restore.
#    A new target writes its entry to clusters/fleet.yaml (git_commit_push: pushMode): a copy of the source's entry
#    (disableInitialBackup, backup.repoPath, FerretDB, restorePatch, instance.restored and the Postgres patch and overlay files of
#    the source dropped, instance.namespace set), or a skeleton (namespace, the spec file's version) when the source is not there;
#    the owner of the shared Secrets is decided like tpg-day0 (exactly one per namespace).
#    The restore-patch (Round 23, second revision): the spec the restored Postgres has is stored as
#    restore-patch/<instance>-restore-<uid>.yaml (one kind: Postgres document, apiVersion, kind and spec) and recorded in the entry as
#    restorePatch.current (the former current becomes previous and is no longer applied) with restorePatch.mode, together with
#    instance.restored: true and the fleet-equivalent fields of the spec written into instance: (lib.sh restore_patch_record), so Argo CD
#    renders the Postgres the restore made (templates/_helpers.tpl tpg.restoredPostgres; the restore-patch's own backupLocation and
#    imagePullSecret win, the fleet's <instance>-backup-location and regsecret fill in only where it omits them; a backupLocation it
#    names must exist in the target namespace now, BACKUP_LOCATION_MISSING):
#      with a spec file   the spec file's spec. A new target (one declared in fleet.yaml but not deployed included): mode base, in the same
#                         commit as the entry. In place: mode over (the operator merged the file into the existing Postgres), in a commit
#                         of its own after the restore succeeded
#      without one        after the restore succeeded and the instance runs, the spec of the Postgres is read from the cluster
#                         (the .spec only: status, metadata, managed fields and the like are not part of it; null values are dropped;
#                         nothing else is stripped, the live spec is the truth) and stored the same way, mode base, in a commit of its own
#                         (a failure to read or store it is the warning RESTORE_PATCH_NOT_RECORDED; a new target's adoption sync is then
#                         left out, since the chart would render the copied entry over the restored Postgres)
#    spec.targetInstance.spec of the PostgresRestore is the spec file's spec or absent (the name only: the operator creates the instance
#    and fills in its spec: LAB ITEM how). An instance restored in place that has no entry in fleet.yaml is not managed by Argo CD: nothing is
#    recorded. The shared objects (ServiceAccount tpg-vso, VaultStaticSecrets regsecret and backup-storage) are only ever applied
#    by the Argo CD Application of their owner: a selective sync of those objects (and of the backup location of the new instance)
#    before the restore, the whole Application after it (adoption).
#  6 Another namespace or cluster: the source PostgresBackupLocation is copied into the target namespace
#    (backupSync on, retention so high that no expiry runs through it, labels tpg.fleet/restore-source); a
#    location of the target namespace for the same container and repoPath is REUSED when its backupSync is on
#    (SOURCE_LOCATION_CONFLICT otherwise; a list of the target namespace's locations that cannot be read is TARGET_UNREADABLE, not
#    an empty list). Its Secret: backup-storage comes from the namespace (Vault Secrets Operator) or, when missing, from Vault; any other
#    Secret is copied from the source cluster into a Secret of the copy's OWN name, <copy name>-creds (spec.storage.azure.secret.name of
#    the copy; labelled tpg.fleet/restore-source), so copies of different sources never share or overwrite one whatever the sources call
#    theirs. A reused copy keeps using the Secret it has: when its contents differ from the source's it is updated only if its
#    restore-source label equals this pair's source, otherwise SOURCE_SECRET_CONFLICT (no label: a Secret this workflow did not make).
#    Secret values are held in shell variables and piped to kubectl on stdin: never a file, an argument or a log line. A named
#    backup then waits for the synced PostgresBackup in the target namespace (BACKUPS_NOT_SYNCED): the one with the source
#    backup's restoreLabel, stanza, the location of the copy (or the reused one) and the source instance, named sync-<label>-<hash>,
#    not like the source backup (BACKUP_AMBIGUOUS for more than one); the PostgresRestore names it.
#  7 dryRun: nothing is changed on a cluster, in Git or in Argo CD; the whole plan, the PostgresRestore as YAML
#    included, is logged and recorded (plan.restore.<cluster>.<instance>).
#  8 The PostgresRestore is rendered through helm_artifacts/instance/crd-reference (tpg.prune: zero defaults
#    left out), applied, and waited for within restoreTimeoutSeconds; then the instance must run (pg_wait_ready),
#    and a new target is adopted by its Application (sync_instance_app).
#  9 postRestoreBackup: a full backup of the target as tpg-backup takes it (a failure is the warning POST_RESTORE_BACKUP_FAILED, the pair
#    stays SUCCEEDED). keepSourceLocation=false removes the
#    copy this run created (never a reused one), and with it the copy's own Secret and no other, unless a Postgres of the target namespace names it as its spec.backupLocation (the restored
#    instance, from the spec file or as the operator made it, or any other): then it is kept and the warning SOURCE_LOCATION_IN_USE names the
#    instance(s); when the instances cannot be listed it is kept with SOURCE_LOCATION_NOT_REMOVED. While the copy exists repo_shared (tpg-delete-instance,
#    tpg-delete-apps purgeBackups) treats the source repository as shared, which is intended.
# 10 Success is the PostgresRestore Succeeded and the target Running.
#
# Reason codes: INVALID_PAIR NOT_REGISTERED FLEET_UNREADABLE SOURCE_NAMESPACE_MISMATCH SOURCE_UNREADABLE
#   BACKUP_NOT_FOUND BACKUP_NOT_SUCCEEDED BACKUP_LABEL_UNKNOWN BACKUP_AMBIGUOUS BACKUP_OF_OTHER_INSTANCE SOURCE_BACKUP_UNVERIFIED PITR_SOURCE_UNKNOWN
#   BACKUP_LOCATION_NOT_INITIALIZED SOURCE_LOCATION_UNKNOWN SOURCE_LOCATION_UNREADABLE NO_FULL_BACKUP INVALID_TIMESTAMP
#   OUTSIDE_RECOVERY_WINDOW TARGET_UNREADABLE NAMESPACE_IMMUTABLE INSTANCE_NAME_IN_USE TARGET_EXISTS
#   CONFIRMATION_MISMATCH (in place only) OPERATION_IN_PROGRESS UNKNOWN_TARGET_CLUSTER SPEC_FILE_REQUIRED SPEC_FILE_NOT_FOUND
#   SPEC_FILE_NOT_RECEIVED SPEC_FILE_INVALID (a repo: spec file that is a symbolic link or lies behind one, or outside restore-specs/) FLEET_EDIT_FAILED CHART_RENDER_FAILED VERSION_NOT_AVAILABLE
#   NAMESPACE_SECRET_CONFLICT BACKUP_LOCATION_MISSING SOURCE_LOCATION_CONFLICT SOURCE_SECRET_CONFLICT
#   SOURCE_SECRET_UNREADABLE NO_VAULT_SECRET GIT_PUSH_FAILED NAMESPACE_OWNER_CONFLICT APP_NOT_GENERATED
#   SHARED_SECRETS_MISSING SECRET_NOT_SYNCED TARGET_PREPARE_FAILED SOURCE_LOCATION_FAILED BACKUPS_NOT_SYNCED
#   CREATE_FAILED RESTORE_FAILED TARGET_<reason> UNEXPECTED_ERROR
#   BLOCKED: RESTORE_FLAVOUR_UNSUPPORTED RESTORE_VERSION_LOWER; TIMEOUT; SKIPPED_IN_PROGRESS
#   warnings (report section Warnings): SRC_LOCATION_DIFFERS SRC_STANZA_DIFFERS CONFIRMATION_MISSING (in place, dry run)
#   RECOVERY_WINDOW_UNVERIFIED BACKUP_LABEL_UNVERIFIED MATRIX_UNVERIFIED OPERATION_IN_PROGRESS ADOPTION_NOT_SYNCED
#   POST_RESTORE_BACKUP_FAILED (the restore succeeded and the instance runs: the pair stays SUCCEEDED) RESTORE_PATCH_NOT_RECORDED
#   (names the fields of the live spec that fail the Postgres schema check)
#   SOURCE_LOCATION_NOT_REMOVED SOURCE_LOCATION_IN_USE (the pair stays SUCCEEDED; names the instance(s) that use the copy)
WF="$1"
# shellcheck source=workflows/scripts/lib.sh
source /scripts/lib.sh

PAIR="${P_PAIR:-}"
# plan-batches.sh hands the pair over as base64 of its JSON (Argo escapes quotes in {{item.pair}}); raw JSON is
# accepted as well (the tests, a run by hand)
if [[ "$PAIR" != "{"* ]]; then PAIR="$(base64 -d <<<"$PAIR" 2>/dev/null || true)"; fi
jq -e 'type == "object" and (.target.cluster | type == "string") and (.target.instance | type == "string")' <<<"$PAIR" >/dev/null 2>&1 \
  || { record result.restore FAILED INVALID_PAIR "P_PAIR is neither JSON nor base64 of JSON of a normalized pair: ${P_PAIR:0:200}"; exit 1; }
pj() { jq -r "$1" <<<"$PAIR"; }
SC="$(pj .source.cluster)"; SNS="$(pj .source.namespace)"; SI="$(pj .source.instance)"; SBK="$(pj '.source.backupName // ""')"
TC="$(pj .target.cluster)"; TNS="$(pj .target.namespace)"; TI="$(pj .target.instance)"
SPEC="$(pj '.target.specFile // ""')"; CONFIRM="$(pj '.target.confirm // ""')"
SKIPMINOR="$(pj '.target.skipMinorVersionCheck // false')"; POSTBACKUP="$(pj '.target.postRestoreBackup // false')"
METHOD="$(pj .method)"; IN_PLACE="$(pj '.inPlace // false')"; SAME_NS="$(pj '.sameNamespace // false')"
PITR_TS="$(pj '.pitr.timestamp // ""')"; PITR_TARGET="$(pj '.pitr.target // ""')"; PITR_BEST="$(pj '.pitr.bestEffort // false')"
PITR_BL="$(pj '.pitr.backupLocation // ""')"; PITR_ST="$(pj '.pitr.stanza // ""')"; PITR_LABEL="$(pj '.pitr.backupLabel // ""')"
LABEL="$(pj .label)"
DRY="${P_DRY_RUN:-true}"; KEEP="${P_KEEP_SOURCE_LOCATION:-true}"; TIMEOUT="${P_TIMEOUT:-7200}"
SYNC_TIMEOUT="${P_SYNC_TIMEOUT:-1800}"; READY_TIMEOUT="${P_READY_TIMEOUT:-1800}"; BACKUP_TIMEOUT="${P_BACKUP_TIMEOUT:-10800}"
export PUSH_MODE="${P_PUSH_MODE:-direct}" PR_TIMEOUT_SECONDS="${P_PR_TIMEOUT:-3600}"
RKEY="result.${TC}.${TI}"
result_guard "$RKEY"

REPO="$WORK/repo"
PLAN=(); NOTES=(); WARNS=()
plan() { PLAN+=("$*"); }
dump_plan() { plan_text >&2; }
note() { NOTES+=("$*"); log "$*"; }
join_list() {  # join_list ITEM...: "a; b; c" (empty without items)
  local out="" n
  for n in "$@"; do [[ -n "$n" ]] || continue; out="${out:+${out}; }${n}"; done
  printf '%s' "$out"
}
plan_text() { printf '%s\n' "pair ${LABEL} (method ${METHOD}, dryRun ${DRY})"; printf '%s\n' "${PLAN[@]}" | sed 's/^/  /'; }
plan_save() { record_entry "plan.restore.${TC}.${TI}" PLANNED "" "$(plan_text)"; }
fail() {   # fail REASON [DETAIL]: the pair is refused or broke; nothing further is attempted
  local w; w="$(join_list ${WARNS[@]+"${WARNS[@]}"})"
  dump_plan
  record "$RKEY" FAILED "$1" "${2:-}${w:+ [warnings: ${w}]}"; exit 1
}
block() {  # block REASON DETAIL: the matrix does not allow this pair (only this pair is stopped)
  plan "BLOCKED ${1}: ${2}"; plan_save; dump_plan
  record "$RKEY" BLOCKED "$1" "$2"; exit 1
}
warn() {   # warn CODE DETAIL: shown in the report (Warnings), the pair goes on
  WARNS+=("$1: $2"); record_entry "warning.${TC}.${TI}.${1}" WARNING "$1" "$2"
}

# ---- small readers (the current cluster is the one use_cluster selected last)
to_src() { use_cluster "$SC" || fail NOT_REGISTERED "$SC"; }
to_tgt() { use_cluster "$TC" || fail NOT_REGISTERED "$TC"; }
OBJ=""; OBJ_ERR=""
get_obj() {  # get_obj NAMESPACE KIND NAME -> OBJ (JSON; empty when the object does not exist); returns 1 with OBJ_ERR when the cluster cannot be read
  local errf="$WORK/get.err"
  OBJ=""; OBJ_ERR=""
  if ! OBJ="$(tk -n "$1" get "$2" "$3" --ignore-not-found -o json 2>"$errf")"; then
    OBJ=""; OBJ_ERR="$(tr '\n' ' ' <"$errf" | cut -c1-300)"; return 1
  fi
}
LITE_RE="$(for f in "$TPG_LIB_DIR/types.yaml" "$TPG_LIB_DIR/../params/types.yaml"; do [[ -f "$f" ]] && { yq -r '.types.liteVersion.pattern' "$f"; break; }; done)"
LITE_RE="${LITE_RE:--lite\$}"
is_lite() { [[ "$1" =~ $LITE_RE ]]; }
ver_of() { sed -nE 's/^(postgres-)?([0-9]+(\.[0-9]+)?).*$/\2/p' <<<"$1"; }   # postgres-17.6-lite -> 17.6
PV_FOUND=false; PV_VER=""
pv_version() {  # pv_version NAME: PV_VER = major.minor of the PostgresVersion NAME on the current cluster (dbVersion, else read from the name), PV_FOUND = it exists
  local j v=""
  PV_FOUND=false
  if j="$(tk get postgresversion "$1" --ignore-not-found -o json 2>/dev/null)" && [[ -n "$j" ]]; then
    v="$(ver_of "$(jq -r '.spec.dbVersion // empty' <<<"$j")")"; PV_FOUND=true   # 17.5.9 -> 17.5: the compare is major.minor
  fi
  [[ -n "$v" ]] || v="$(ver_of "$1")"
  PV_VER="$v"
}
copy_want() {  # the fixed name of the copy of the source backup location in the target namespace
  local want="restore-src-${SC}-${SNS}-${SI}"
  [[ "${#want}" -le 253 ]] || want="restore-src-$(printf '%s-%s-%s' "$SC" "$SNS" "$SI" | cksum | cut -d' ' -f1)"
  printf '%s' "$want"
}
patch_schemas_path() {
  if [[ -f "$TPG_LIB_DIR/patch-schemas.json" ]]; then printf '%s' "$TPG_LIB_DIR/patch-schemas.json"
  else printf '%s' "$TPG_LIB_DIR/../params/patch-schemas.json"; fi
}
secret_meta() {  # secret_meta NAMESPACE KIND NAME -> metadata JSON; rc 0 read, 1 NotFound, 2 other error (text on stdout). The data is never read
  local out rc=0
  out="$(tk -n "$1" get "$2" "$3" -o jsonpath='{.metadata}' 2>&1)" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    printf '%s' "$out" | tr '\n,' ' ;' | head -c 300
    grep -qiE 'NotFound|not found' <<<"$out" && return 1
    return 2
  fi
  jq -e 'type == "object"' <<<"$out" >/dev/null 2>&1 || { printf 'unexpected answer: %s' "$(tr '\n,' ' ;' <<<"$out" | head -c 200)"; return 2; }
  printf '%s' "$out"
}
fleet_secret() {  # fleet_secret NAMESPACE NAME -> 0 the Secret exists and the fleet keeps it, 1 it exists and is foreign, 2 absent, 3 unreadable
  # (the rule of day0-precheck.sh: tracked by an Application tpg-<cluster>-*, or created by a VaultStaticSecret of its name that is)
  local sj vj rc=0
  sj="$(secret_meta "$1" secret "$2")" || rc=$?
  case "$rc" in 0) ;; 1) return 2 ;; *) SECRET_ERR="$sj"; return 3 ;; esac
  jq -e --arg a "tpg-${TC}-" '((.annotations["argocd.argoproj.io/tracking-id"] // "") | startswith($a))' <<<"$sj" >/dev/null 2>&1 && return 0
  if jq -e --arg n "$2" 'any(.ownerReferences[]?; .kind == "VaultStaticSecret" and .name == $n and ((.apiVersion // "") | startswith("secrets.hashicorp.com/")))' <<<"$sj" >/dev/null 2>&1; then
    rc=0; vj="$(secret_meta "$1" vaultstaticsecret "$2")" || rc=$?
    case "$rc" in
      0) jq -e --arg a "tpg-${TC}-" '((.annotations["argocd.argoproj.io/tracking-id"] // "") | startswith($a))' <<<"$vj" >/dev/null 2>&1 && return 0 ;;
      1) ;;
      *) SECRET_ERR="$vj"; return 3 ;;
    esac
  fi
  return 1
}
SECRET_ERR=""

# ---- 0. the clusters and the fleet repository (read-only)
use_cluster "$SC" || fail NOT_REGISTERED "$SC"
use_cluster "$TC" || fail NOT_REGISTERED "$TC"
git_clone "$REPO" >/dev/null 2>&1 \
  || fail FLEET_UNREADABLE "the fleet repository could not be cloned (Vault github-push, GitHub): the source and target entries of clusters/fleet.yaml cannot be read"
export INSTANCE_NS_REPO="$REPO"

# ---- 1. the source: the instance (live? in clusters/fleet.yaml?), its version, backup location and stanza
SRC_FLEET=false
fleet_has_instance "$REPO" "$SC" "$SI" && SRC_FLEET=true
if [[ "$SRC_FLEET" == true ]]; then
  fns="$(instance_ns_in "$REPO" "$SC" "$SI")"
  [[ "$fns" == "$SNS" ]] || fail SOURCE_NAMESPACE_MISMATCH "clusters/fleet.yaml declares ${SI} on ${SC} in namespace ${fns}, the pair says ${SNS}: correct the source namespace of the pair (the namespace of an instance cannot change)"
fi
instance_ns_override "$SC" "$SI" "$SNS"
to_src
get_obj "$SNS" postgres "$SI" || fail SOURCE_UNREADABLE "Postgres ${SNS}/${SI} on ${SC} could not be read: ${OBJ_ERR}"
SRC_LIVE=false; SRC_PG=""
[[ -z "$OBJ" ]] || { SRC_LIVE=true; SRC_PG="$OBJ"; }
S_PGV=""; S_BL=""; S_STANZA=""
if [[ "$SRC_LIVE" == true ]]; then
  S_PGV="$(jq -r '.spec.postgresVersion.name // ""' <<<"$SRC_PG")"
  S_BL="$(jq -r '.spec.backupLocation.name // ""' <<<"$SRC_PG")"
  S_STANZA="$(jq -r '.status.stanzaName // ""' <<<"$SRC_PG")"
elif [[ "$SRC_FLEET" == true ]]; then
  S_PGV="$(instance_effective "$REPO" "$SC" "$SI" '.instance.postgresVersion' '')"
fi
S_VER=""
if [[ -n "$S_PGV" ]]; then pv_version "$S_PGV"; S_VER="$PV_VER"; fi
S_VER_LIVE=""
[[ "$SRC_LIVE" != true ]] || S_VER_LIVE="$(ver_of "$(jq -r '.status.postgresVersion // ""' <<<"$SRC_PG")")"
S_LITE=false; if [[ -n "$S_PGV" ]] && is_lite "$S_PGV"; then S_LITE=true; fi
plan "source: $( [[ "$SRC_LIVE" == true ]] && echo "Postgres ${SC}/${SNS}/${SI} is live" || echo "${SC}/${SNS}/${SI} is not on the cluster" )$( [[ "$SRC_FLEET" == true ]] && echo ", declared in clusters/fleet.yaml" || echo ", not in clusters/fleet.yaml" ); version ${S_PGV:-unknown}${S_VER:+ (${S_VER}, $( [[ "$S_LITE" == true ]] && echo lite || echo standard ))}; location ${S_BL:-none}, stanza ${S_STANZA:-none}"

# ---- 2. a named backup: it must be a Succeeded PostgresBackup before anything else happens
SB=""; SB_ERR=""
if [[ -n "$SBK" ]]; then
  if get_obj "$SNS" postgresbackup "$SBK"; then SB="$OBJ"; else SB_ERR="$OBJ_ERR"; fi
fi
S_VER_BACKUP=""
[[ -z "$SB" ]] || S_VER_BACKUP="$(ver_of "$(jq -r '.status.fullPostgresVersion // ""' <<<"$SB")")"
if [[ -n "$SB" ]]; then
  # a pair names one source instance: a backup of another instance is no recovery point for it
  sinst="$(jq -r '.spec.sourceInstance.name // ""' <<<"$SB")"
  if [[ -n "$sinst" && "$sinst" != "$SI" ]]; then
    fail BACKUP_OF_OTHER_INSTANCE "PostgresBackup ${SNS}/${SBK} on ${SC} is a backup of ${sinst}, not of the source instance ${SI} of the pair: name ${sinst} as the source instance (a pair has exactly one), or give a backup of ${SI}"
  fi
fi
if [[ "$METHOD" == backup ]]; then
  if [[ -z "$SB" ]]; then
    sb_why="does not exist"; [[ -z "$SB_ERR" ]] || sb_why="could not be read (${SB_ERR})"
    if [[ "$SAME_NS" == true ]]; then
      fail BACKUP_NOT_FOUND "PostgresBackup ${SNS}/${SBK} on ${SC} ${sb_why}: a named backup restored inside the source namespace must exist and be Succeeded now; list them with kubectl -n ${SNS} get postgresbackup"
    fi
    fail SOURCE_BACKUP_UNVERIFIED "PostgresBackup ${SNS}/${SBK} on ${SC} ${sb_why}: a restore into another namespace or cluster first checks that the source backup exists and is Succeeded, and refuses when it cannot"
  fi
  sphase="$(jq -r '.status.phase // ""' <<<"$SB")"
  [[ "$sphase" == Succeeded ]] || fail BACKUP_NOT_SUCCEEDED "PostgresBackup ${SNS}/${SBK} on ${SC} is in phase ${sphase:-<none>}, not Succeeded"
  # Into another namespace or cluster the operator names the synced backup after its pgBackRest label
  # (sync-<label lowercase>-<8 of the stanza uuid>), not after this one: the label finds it (BACKUP_LABEL_UNKNOWN without one)
  SB_LABEL=""; SB_STANZA=""
  if [[ "$SAME_NS" != true ]]; then
    SB_LABEL="$(jq -r '.status.restoreLabel // ""' <<<"$SB")"; SB_STANZA="$(jq -r '.status.stanzaName // ""' <<<"$SB")"
    [[ -n "$SB_LABEL" ]] || fail BACKUP_LABEL_UNKNOWN "PostgresBackup ${SNS}/${SBK} on ${SC} reports no status.restoreLabel (the pgBackRest label): backupSync names the synced backup in ${TNS} after that label, so it could not be found there; check that the backup completed and the operator version"
  fi
  plan "named backup ${SNS}/${SBK} on ${SC}: Succeeded$( [[ "$SAME_NS" == true ]] && echo " (same namespace: no wait, no copy)" || echo " (source check passed; the target namespace gets a copy of the source backup location and the same-named backup is waited for)" )"
fi

# ---- 3. point-in-time recovery: the backup location (as seen from the source namespace) and the stanza
SRC_BL=""; SRC_STANZA=""
if [[ "$METHOD" != backup ]]; then
  d_bl=""; d_st=""
  if [[ "$SRC_LIVE" == true ]]; then d_bl="$S_BL"; d_st="$S_STANZA"
  elif [[ -n "$SB" ]]; then d_bl="$(jq -r '.status.backupLocation // ""' <<<"$SB")"; d_st="$(jq -r '.status.stanzaName // ""' <<<"$SB")"
  fi
  src_word="the live Postgres"; [[ "$SRC_LIVE" == true ]] || src_word="PostgresBackup ${SBK}"
  if [[ -n "$PITR_BL" && -n "$d_bl" && "$PITR_BL" != "$d_bl" ]]; then
    warn SRC_LOCATION_DIFFERS "srcBackupLocationName ${PITR_BL} differs from ${d_bl}, which ${src_word} reports; the given value is used"
  fi
  if [[ -n "$PITR_ST" && -n "$d_st" && "$PITR_ST" != "$d_st" ]]; then
    warn SRC_STANZA_DIFFERS "srcStanzaName ${PITR_ST} differs from ${d_st}, which ${src_word} reports; the given value is used"
  fi
  SRC_BL="${PITR_BL:-$d_bl}"; SRC_STANZA="${PITR_ST:-$d_st}"
  if [[ -z "$SRC_BL" || -z "$SRC_STANZA" ]]; then
    if [[ "$SRC_LIVE" == true ]]; then
      fail BACKUP_LOCATION_NOT_INITIALIZED "${SNS}/${SI} on ${SC} has no backup location or no stanza yet (backupLocation '${S_BL}', stanza '${S_STANZA}'): it has never backed up; give srcBackupLocationName and srcStanzaName if the repository is known"
    fi
    fail PITR_SOURCE_UNKNOWN "pitrEnabled: true needs the backup location and the stanza of the source, and ${SI} is not on ${SC} (namespace ${SNS})$( [[ -n "$SBK" ]] && echo " and sourceBackupName ${SBK} names no PostgresBackup that can be read${SB_ERR:+ (${SB_ERR})}" || echo ", with no sourceBackupName to read them from"): set pitrConfig.sourceBackupConfig.srcBackupLocationName and srcStanzaName in the target (the stanza is shown by pgbackrest info), or name a PostgresBackup of the source in sourceBackupName"
  fi
  plan "pitr ${METHOD}: backup location ${SRC_BL} (${SNS}), stanza ${SRC_STANZA}${PITR_LABEL:+, starting from backup set ${PITR_LABEL}}"
  # recovery window: the newest Succeeded full backup that is old enough
  to_src
  if bj="$(tk -n "$SNS" get postgresbackup -o json 2>/dev/null)"; then
    oldest="$(jq -r --arg i "$SI" '[.items[]? | select(.spec.sourceInstance.name == $i and .spec.type == "full"
      and .status.phase == "Succeeded" and .status.timeStarted != null) | .status.timeStarted | fromdateiso8601] | min // empty' <<<"$bj")" || oldest=""
    if [[ -z "$oldest" ]]; then
      if [[ "$SRC_LIVE" == true ]]; then fail NO_FULL_BACKUP "no Succeeded full backup of ${SI} on ${SC} (${SNS}): there is nothing to recover from"; fi
      warn RECOVERY_WINDOW_UNVERIFIED "no Succeeded full backup of ${SI} is listed in ${SNS} on ${SC}; the recovery point is not checked against them"
    elif [[ "$METHOD" == time ]]; then
      target_epoch="$(jq -rn --arg t "$PITR_TS" '$t | fromdateiso8601' 2>/dev/null)" || fail INVALID_TIMESTAMP "$PITR_TS"
      (( target_epoch < $(date +%s) )) || fail INVALID_TIMESTAMP "pitrConfig.timestamp ${PITR_TS} is in the future"
      (( target_epoch > oldest )) || fail OUTSIDE_RECOVERY_WINDOW "pitrConfig.timestamp ${PITR_TS} is older than the oldest full backup ($(date -u -d "@${oldest}" +%Y-%m-%dT%H:%M:%SZ))"
    fi
    if [[ -n "$PITR_LABEL" ]] && ! jq -e --arg l "$PITR_LABEL" 'any(.items[]?; .status.restoreLabel == $l)' <<<"$bj" >/dev/null; then
      warn BACKUP_LABEL_UNVERIFIED "no PostgresBackup of ${SNS} on ${SC} carries the pgBackRest label ${PITR_LABEL}; the label is passed on as given"
    fi
  else
    warn RECOVERY_WINDOW_UNVERIFIED "the PostgresBackups of ${SNS} on ${SC} could not be read; the recovery point is not checked against them"
  fi
elif [[ "$SAME_NS" != true ]]; then
  # a named backup into another namespace or cluster: the location of the backup, to copy
  SRC_BL="$(jq -r '.status.backupLocation // ""' <<<"$SB")"
  [[ -n "$SRC_BL" ]] || SRC_BL="$S_BL"
  [[ -n "$SRC_BL" ]] || fail SOURCE_LOCATION_UNKNOWN "PostgresBackup ${SBK} reports no backup location and ${SI} is not live: the backup location to copy into ${TNS} is unknown"
fi

# the source location object, for the copy into another namespace or cluster
LOC_JSON=""
if [[ "$SAME_NS" != true ]]; then
  to_src
  get_obj "$SNS" postgresbackuplocation "$SRC_BL" || fail SOURCE_LOCATION_UNREADABLE "PostgresBackupLocation ${SNS}/${SRC_BL} on ${SC} could not be read: ${OBJ_ERR}"
  [[ -n "$OBJ" ]] || fail SOURCE_LOCATION_UNREADABLE "PostgresBackupLocation ${SNS}/${SRC_BL} on ${SC} does not exist: the copy for ${TNS} cannot be built from it"
  LOC_JSON="$OBJ"
  LOC_CONT="$(jq -r '.spec.storage.azure.container // ""' <<<"$LOC_JSON")"
  [[ -n "$LOC_CONT" ]] || fail SOURCE_LOCATION_UNREADABLE "PostgresBackupLocation ${SNS}/${SRC_BL} on ${SC} is not an Azure location (spec.storage.azure.container is empty): only Azure Blob locations are copied"
  LOC_PATH="$(jq -r '.spec.storage.azure.repoPath // "/"' <<<"$LOC_JSON")"
  LOC_EP="$(jq -r '.spec.storage.azure.endpoint // "blob.core.windows.net"' <<<"$LOC_JSON")"
  LOC_SECRET="$(jq -r '.spec.storage.azure.secret.name // "backup-storage"' <<<"$LOC_JSON")"
fi

# ---- 5. the target: the source itself (in place) or a new instance; any other live Postgres of that name is TARGET_EXISTS
to_tgt
TGT_FLEET=false
fleet_has_instance "$REPO" "$TC" "$TI" && TGT_FLEET=true
if [[ "$TGT_FLEET" == true ]]; then
  tfns="$(instance_ns_in "$REPO" "$TC" "$TI")"
  [[ "$tfns" == "$TNS" ]] || fail NAMESPACE_IMMUTABLE "${TI} is declared in namespace ${tfns} on ${TC}, the pair asks for ${TNS}; the namespace of an instance cannot change (name another instance, or the declared namespace)"
fi
instance_ns_override "$TC" "$TI" "$TNS"
get_obj "$TNS" postgres "$TI" || fail TARGET_UNREADABLE "Postgres ${TNS}/${TI} on ${TC} could not be read: ${OBJ_ERR}"
TGT_EXISTS=false; TGT_PG=""
[[ -z "$OBJ" ]] || { TGT_EXISTS=true; TGT_PG="$OBJ"; }

# The spec file (targetInstanceSpecFilePath) is the source of truth for the restored Postgres: its spec is rendered as it is as
# spec.targetInstance.spec of the PostgresRestore (no merge over a chart render) and stored in the fleet repository as a restore-patch
# that the chart renders the restored instance from (the render of a restored instance, tpg.restoredPostgres). Allowed for a new target and for an in-place restore.
# A live Postgres of the target name that is not the source (not in place) is refused first: TARGET_EXISTS.
SPEC_JSON=""   # the spec of the spec file (compact JSON)
load_spec() {  # load_spec: SPEC_JSON from the file; the pair fails with the reason when it cannot be used
  local sf="$WORK/spec-file.yaml" out
  if patch_is_repo "$SPEC"; then
    [[ -e "$REPO/${SPEC#repo:}" || -L "$REPO/${SPEC#repo:}" ]] || fail SPEC_FILE_NOT_FOUND "${SPEC}: no such file on the fleet branch"
    # a committed symbolic link is no spec file: it could lead out of restore-specs/ to any file of the clone (the file itself, and every
    # folder on the way, must lie under restore-specs/ for real)
    local specdir real
    specdir="$(realpath -- "$REPO/helm_artifacts/instance/tpg-instance/restore-specs" 2>/dev/null)" || specdir=""
    real="$(realpath -- "$REPO/${SPEC#repo:}" 2>/dev/null)" || real=""
    # (the folder itself must be the folder, not a link to another one)
    if [[ -L "$REPO/${SPEC#repo:}" || -z "$specdir" || "$specdir" != "$(realpath -- "$REPO")/helm_artifacts/instance/tpg-instance/restore-specs" || "$real" != "$specdir"/* ]]; then
      fail SPEC_FILE_INVALID "${SPEC}: is a symbolic link or lies behind one and does not stay inside helm_artifacts/instance/tpg-instance/restore-specs/: commit the spec file itself there"
    fi
    [[ -f "$real" ]] || fail SPEC_FILE_NOT_FOUND "${SPEC}: no such file on the fleet branch"
    cp "$real" "$sf"
  else
    patch_file_write "$SPEC" "$sf" "$REPO" || fail SPEC_FILE_NOT_RECEIVED "${SPEC}: ${PATCH_FILES_ERROR:-its contents are not in patchFiles}"
  fi
  yq ea -o=json -I=0 '[.]' "$sf" > "$WORK/spec-file.json" 2>"$WORK/spec-file.err" \
    || fail SPEC_FILE_INVALID "${SPEC}: not valid YAML: $(head -n 2 "$WORK/spec-file.err" | tr '\n' ' ')"
  if ! out="$(python3 "$TPG_LIB_DIR/patchcheck.py" spec "$WORK/spec-file.json" --schemas "$(patch_schemas_path)" --name "$SPEC")"; then
    fail SPEC_FILE_INVALID "$(tr '\n' ';' <<<"$out")"
  fi
  SPEC_JSON="$(jq -c '[.[] | select(. != null and . != {})][0].spec // {}' "$WORK/spec-file.json")"
  [[ "$SPEC_JSON" != '{}' ]] || fail SPEC_FILE_INVALID "${SPEC}: spec is empty: the spec file is the spec of the restored instance"
}
if [[ "$TGT_EXISTS" == true && "$IN_PLACE" != true ]]; then
  # a restore overwrites the data of the instance it restores into: only the source itself may be that (in place); anything else that
  # runs under the target name is somebody's instance
  fail TARGET_EXISTS "a Postgres named ${TI} already runs at ${TC}/${TNS}/${TI} and is not the source instance of this pair: restore in place or choose a new instance name (in place means the source and the target are the same cluster, namespace and instance; a restore never overwrites another instance)"
fi

ENTRY_NEW=false; T_OWNER=""; BUSY=""; T_PGV=""; T_BLN=""; RP_NOTE=""
if [[ "$TGT_EXISTS" == true ]]; then
  # an in-place restore (TARGET_EXISTS above refused every other existing target)
  [[ -z "$SPEC" ]] || load_spec
  if [[ "$CONFIRM" != "$TI" ]]; then
    if [[ "$DRY" == false ]]; then
      fail CONFIRMATION_MISMATCH "restoring ${TC}/${TNS}/${TI} in place overwrites its data: set confirm: ${TI} in the target of the pair"
    fi
    warn CONFIRMATION_MISSING "the restore of ${TC}/${TNS}/${TI} is in place: a real run (dryRun=false) is refused unless the pair sets confirm: ${TI}"
  fi
  T_PGV="$(jq -r '.postgresVersion.name // ""' <<<"${SPEC_JSON:-null}")"
  [[ -n "$T_PGV" ]] || T_PGV="$(jq -r '.spec.postgresVersion.name // ""' <<<"$TGT_PG")"
  [[ -z "$SPEC_JSON" ]] || T_BLN="$(jq -r '.backupLocation.name // ""' <<<"$SPEC_JSON")"
  BUSY="$(busy_operations "$TI" | sed 's/postgresrestore//' | tr -s ' ' | sed 's/^ //;s/ $//')"
  if [[ -n "$BUSY" && "$DRY" == true ]]; then
    warn OPERATION_IN_PROGRESS "${TC}/${TI} has an unfinished ${BUSY}: a real run is refused until it finished"
  fi
  plan "target: existing Postgres ${TC}/${TNS}/${TI} (version ${T_PGV:-unknown}); its data is overwritten (in place); spec.targetInstance.spec: $( [[ -n "$SPEC" ]] && echo "the spec file ${SPEC}, as it is (it overrides the existing instance's values)" || echo "none, only the name" )"
else
  # a live Postgres of that name in another namespace of the cluster would clash with the Application tpg-<cluster>-<instance>
  other="$(live_postgres_namespaces "$TI" | grep -vFx -- "$TNS" | paste -sd, - || true)"
  [[ -z "$other" ]] || fail INSTANCE_NAME_IN_USE "a Postgres named ${TI} already runs in namespace ${other} on ${TC}; the instance name is unique per cluster in clusters/fleet.yaml: choose another target instance name"
  fleet_has_cluster "$REPO" "$TC" || fail UNKNOWN_TARGET_CLUSTER "no clusters.${TC} in ${FLEET_REL}: run tpg-day0 for ${TC} first (a new restore target is added to its entry)"
  if [[ -n "$SPEC" ]]; then
    load_spec
    [[ "$(jq -r '.postgresVersion.name // ""' <<<"$SPEC_JSON")" != "" ]] \
      || fail SPEC_FILE_INVALID "${SPEC}: spec.postgresVersion.name is missing: the version of the new instance is needed for its entry in ${FLEET_REL} and for the restore matrix"
  fi
  # no live Postgres of that name: a new target, also when ${FLEET_REL} declares the instance already (declared but not deployed): its entry is
  # replaced by the one the restore writes (a copy of the source's, or the skeleton of the spec file), the declared namespace kept (checked above)
  ENTRY_NEW=true
  [[ "$TGT_FLEET" != true ]] || note "the entry ${TC}/${TI} is declared in ${FLEET_REL} but not deployed: it is a new target, its entry is replaced"
fi

# stage_restore_patch SPEC_JSON MODE: SPEC_JSON (the spec file's spec, or the spec read from the cluster) as a restore-patch in the clone $REPO
# (restore-patch/<instance>-restore-<uid>.yaml), recorded as restorePatch.current of the instance's entry of clusters/fleet.yaml (the former
# current becomes previous) with restorePatch.mode MODE (base | over), instance.restored: true and the fleet-equivalent fields of the spec
# written into the entry (lib.sh restore_patch_record)
RP_PATH=""
stage_restore_patch() {
  RP_PATH="$(restore_patch_store "$REPO" "$TI" "$1")" && restore_patch_record "$REPO" "$TC" "$TI" "$RP_PATH" "$2" "$1"
}

# prepare_entry: write the entry of the new target to the clone in $REPO (a copy of the source's entry, or a skeleton
# when the source is not in clusters/fleet.yaml and a spec file gives the instance) and decide who owns the shared Secrets of the
# namespace. Run on the clone of the plan, and again on a fresh clone under the fleet lock right before the push, so two new
# targets of one namespace never both own them.
prepare_entry() {
  local f="$REPO/$FLEET_REL" others
  if [[ "$SRC_FLEET" == true ]]; then
    # The restored instance inherits the source's settings, its backup scheduler included (backup.scheduled, backup.operatorSchedules,
    # D70), but not FerretDB (D71): a restored copy does not start serving MongoDB clients on its own (turn it on with a
    # tpg-patch values file). A copied values patch that turns FerretDB on is overridden with valuesOverride. It gets its own
    # pgBackRest repository path (the chart default /<namespace>/<instance>): the copy must not keep the source's pinned
    # backup.repoPath, and no initial-backup skip of the source. The Postgres patch and overlay files of the source changed the
    # source's Postgres, not the restored one (its spec is the restore-patch): they are not copied. Nothing of the source's
    # restore (instance.restored, restorePatch) is copied either.
    SC_="$SC" TC_="$TC" SI_="$SI" TI_="$TI" NS_="$TNS" yq -i '
      .clusters[strenv(TC_)].instances[strenv(TI_)] = .clusters[strenv(SC_)].instances[strenv(SI_)]
      | del(.clusters[strenv(TC_)].instances[strenv(TI_)].ferret)
      | del(.clusters[strenv(TC_)].instances[strenv(TI_)].backup.repoPath)
      | del(.clusters[strenv(TC_)].instances[strenv(TI_)].instance.disableInitialBackup)
      | del(.clusters[strenv(TC_)].instances[strenv(TI_)].restorePatch)
      | del(.clusters[strenv(TC_)].instances[strenv(TI_)].instance.restored)
      | del(.clusters[strenv(TC_)].instances[strenv(TI_)].patches.postgres)
      | del(.clusters[strenv(TC_)].instances[strenv(TI_)].overlays.postgres)
      | del(.clusters[strenv(TC_)].instances[strenv(TI_)].patches | select(length == 0))
      | del(.clusters[strenv(TC_)].instances[strenv(TI_)].overlays | select(length == 0))
      | .clusters[strenv(TC_)].instances[strenv(TI_)].instance.namespace = strenv(NS_)
      | del(.clusters[strenv(TC_)].instances[strenv(TI_)].instance.sharedSecretsOwner)' "$f" || return 1
    if [[ "$(instance_effective "$REPO" "$TC" "$TI" '.ferret.enabled' false)" == "true" ]]; then
      TC_="$TC" TI_="$TI" yq -i '.clusters[strenv(TC_)].instances[strenv(TI_)].valuesOverride.ferret.enabled = false' "$f" || return 1
    fi
    # the version of the spec file is the version of the instance (the entry of the source may be another one)
    if [[ -n "$SPEC_JSON" ]]; then
      TC_="$TC" TI_="$TI" V_="$(jq -r '.postgresVersion.name' <<<"$SPEC_JSON")" yq -i '.clusters[strenv(TC_)].instances[strenv(TI_)].instance.postgresVersion = strenv(V_)' "$f" || return 1
    fi
  else
    # the whole entry is the skeleton (a declared entry of that name is replaced, not merged into)
    TC_="$TC" TI_="$TI" NS_="$TNS" V_="$(jq -r '.postgresVersion.name' <<<"$SPEC_JSON")" yq -i '
      .clusters[strenv(TC_)].instances[strenv(TI_)] = {"instance": {"namespace": strenv(NS_), "postgresVersion": strenv(V_)}}' "$f" || return 1
  fi
  # who renders the ServiceAccount tpg-vso and the VaultStaticSecrets regsecret and backup-storage: exactly one instance per namespace
  others="$(fleet_ns_owners "$REPO" "$TC" "$TNS" | grep -vFx -- "$TI" || true)"
  if [[ -n "$others" ]]; then
    TC_="$TC" TI_="$TI" yq -i '.clusters[strenv(TC_)].instances[strenv(TI_)].instance.sharedSecretsOwner = false' "$f" || return 1
    T_OWNER=false; OWNER_NOTE="$(head -n1 <<<"$others")"
  else
    TC_="$TC" TI_="$TI" yq -i 'del(.clusters[strenv(TC_)].instances[strenv(TI_)].instance.sharedSecretsOwner)' "$f" || return 1
    T_OWNER=true; OWNER_NOTE=""
  fi
  # the spec file of the pair is recorded with the entry, in the same commit (a new instance: mode base)
  [[ -z "$SPEC_JSON" ]] || stage_restore_patch "$SPEC_JSON" base || return 1
}
OWNER_NOTE=""
if [[ "$ENTRY_NEW" == true ]]; then
  if [[ "$SRC_FLEET" != true && -z "$SPEC" ]]; then
    fail SPEC_FILE_REQUIRED "${SC}/${SI} is not declared in ${FLEET_REL} (nothing to copy for the new instance ${TC}/${TI}): give targetInstanceSpecFilePath, one kind: Postgres document with at least spec.postgresVersion.name"
  fi
  prepare_entry || fail FLEET_EDIT_FAILED "$FLEET_REL"
fi
# The restore-patch of an in-place restore is recorded in a commit of its own after the restore succeeded: the spec file's spec, or the spec
# read from the cluster. Mode over with a spec file (the operator merged the file into the existing Postgres), base otherwise. An instance
# that has no entry is not managed by Argo CD: nothing is recorded. (A new target, also one whose entry was declared, has its entry and, with a
# spec file, its restore-patch written by prepare_entry.)
RP_FORM=base; [[ -z "$SPEC_JSON" || "$TGT_EXISTS" != true ]] || RP_FORM=over
if [[ "$TGT_EXISTS" == true && "$TGT_FLEET" != true ]]; then
  RP_NOTE="${TC}/${TI} has no entry in ${FLEET_REL}: $( [[ -n "$SPEC_JSON" ]] && echo "the spec file is used for the restore only" || echo "its spec is not read" ), no restore-patch is recorded (Argo CD does not manage this instance)"
elif [[ "$TGT_EXISTS" == true && -n "$SPEC_JSON" ]]; then
  stage_restore_patch "$SPEC_JSON" "$RP_FORM" || fail FLEET_EDIT_FAILED "$FLEET_REL (restorePatch of ${TI})"
fi

if [[ "$TGT_EXISTS" == false ]]; then
  # the chart must render the entry (with the restore-patch staged in the clone); the restored spec itself is the spec file's, or
  # the operator's when there is none
  if ! rendered="$(instance_render "$REPO" "$TC" "$TI" 2>"$WORK/render.err")"; then
    fail CHART_RENDER_FAILED "${TC}/${TI}: $(tr '\n' ' ' <"$WORK/render.err" | cut -c1-300)"
  fi
  base_spec="$(yq -o=json -I=0 'select(.kind == "Postgres") | .spec' <<<"$rendered")"
  [[ -n "$base_spec" && "$base_spec" != null ]] || fail CHART_RENDER_FAILED "${TC}/${TI}: the chart rendered no Postgres"
  if [[ -n "$SPEC_JSON" ]]; then
    T_PGV="$(jq -r '.postgresVersion.name // ""' <<<"$SPEC_JSON")"
    T_BLN="$(jq -r '.backupLocation.name // ""' <<<"$SPEC_JSON")"
  else
    T_PGV="$(jq -r '.postgresVersion.name // ""' <<<"$base_spec")"
    T_BLN="$(jq -r '.backupLocation.name // ""' <<<"$base_spec")"
  fi
  plan "target: new instance ${TC}/${TNS}/${TI}, version ${T_PGV:-unknown}; spec.targetInstance.spec: $( [[ -n "$SPEC" ]] && echo "the spec file ${SPEC}, as it is" || echo "none, only the name: the operator creates the instance and fills in its spec (lab item: how it fills it)" ); ${FLEET_REL}: $( [[ "$ENTRY_NEW" == true ]] && echo "the entry would be $( [[ "$TGT_FLEET" == true ]] && echo "replaced (it is declared but not deployed)" || echo added )$( [[ "$SRC_FLEET" == true ]] && echo " (a copy of the entry of ${SC}/${SI})" || echo " (from the spec file)" ) (pushMode ${PUSH_MODE})" || echo "the entry already exists" ); shared Secrets of ${TNS}: $( [[ "$T_OWNER" == true ]] && echo "owned by ${TI}" || echo "owned by ${OWNER_NOTE:-another instance}" )"
fi
RP_WHAT="the spec file"; [[ -n "$SPEC_JSON" ]] || RP_WHAT="the spec of the restored Postgres, read from ${TC} once it runs"
RP_PLAN="mode ${RP_FORM}, restorePatch.current of ${TC}/${TI}, instance.restored: true and the fleet-equivalent fields of the spec written into the entry; the chart renders the Postgres from it (its fields; its own backupLocation and imagePullSecret win and the fleet's fill in where it omits them (${TI}-backup-location, regsecret); then the later changes of the entry and the tpg-patch patch file)"
if [[ "$ENTRY_NEW" == true && -n "$SPEC_JSON" ]]; then
  plan "restore-patch: ${RP_WHAT} would be stored as helm_artifacts/instance/tpg-instance/restore-patch/${TI}-restore-<uid>.yaml in the same commit as the entry: ${RP_PLAN}"
elif [[ -n "$RP_NOTE" ]]; then
  plan "restore-patch: ${RP_NOTE}"
else
  plan "restore-patch: ${RP_WHAT} would be stored as helm_artifacts/instance/tpg-instance/restore-patch/${TI}-restore-<uid>.yaml in a commit of its own after the restore succeeded (pushMode ${PUSH_MODE}): ${RP_PLAN}; a restore-patch it replaces becomes previous and is no longer applied"
fi

# ---- 4. the matrix: standard -> lite, a lower minor version, another major version
to_tgt
if [[ -z "$T_PGV" ]]; then
  warn MATRIX_UNVERIFIED "the PostgresVersion of the target ${TC}/${TNS}/${TI} is not known: the restore matrix was not checked"
else
  pv_version "$T_PGV"; T_VER="$PV_VER"
  if [[ ( "$TGT_EXISTS" == false || -n "$SPEC_JSON" ) && "$PV_FOUND" != true ]]; then
    fail VERSION_NOT_AVAILABLE "PostgresVersion ${T_PGV} of the instance ${TI} does not exist on ${TC} (kubectl get postgresversion); the operator there offers other versions, or is not installed"
  fi
  T_LITE=false; is_lite "$T_PGV" && T_LITE=true
  # the version the backup was taken from: the named backup's status.fullPostgresVersion, else the live source's
  # (status.postgresVersion), else the PostgresVersion of the source (dbVersion, or read from its name)
  S_VER_FROM="PostgresVersion ${S_PGV}"
  if [[ -n "$S_VER_BACKUP" ]]; then S_VER="$S_VER_BACKUP"; S_VER_FROM="PostgresBackup ${SBK} (status.fullPostgresVersion)"
  elif [[ -n "$S_VER_LIVE" ]]; then S_VER="$S_VER_LIVE"; S_VER_FROM="the live Postgres (status.postgresVersion)"; fi
  if [[ -z "$S_PGV" && -z "$S_VER" ]]; then
    warn MATRIX_UNVERIFIED "the PostgresVersion of the source ${SC}/${SNS}/${SI} is not known (not live, not in ${FLEET_REL}): the restore matrix (flavour, minor version) was not checked"
  else
    if [[ -n "$S_PGV" && "$S_LITE" == false && "$T_LITE" == true ]]; then
      block RESTORE_FLAVOUR_UNSUPPORTED "the backups of ${SI} are of the standard version ${S_PGV}; the target ${TI} is the lite version ${T_PGV}: a standard backup cannot be restored into a lite instance; choose a standard PostgresVersion for the target"
    fi
    if [[ -n "$S_VER" && -n "$T_VER" ]]; then
      smaj="${S_VER%%.*}"; smin="${S_VER#*.}"; [[ "$smin" != "$S_VER" ]] || smin=0
      tmaj="${T_VER%%.*}"; tmin="${T_VER#*.}"; [[ "$tmin" != "$T_VER" ]] || tmin=0
      # a lower version always blocks (skipMinorVersionCheck only sets the operator's annotation); another major version is
      # the operator's to refuse, a higher one is passed on
      if (( tmaj < smaj || (tmaj == smaj && tmin < smin) )); then
        block RESTORE_VERSION_LOWER "the target ${T_PGV} (${T_VER}) is a lower version than ${S_VER}, the version of ${S_VER_FROM}: choose ${S_VER} or newer (skipMinorVersionCheck only sets the operator's annotation, it relaxes no check of this workflow)"
      fi
      if (( tmaj > smaj )); then plan "note: the target ${T_PGV} (${T_VER}) is another major version than the source (${S_VER}): the operator refuses a restore across major versions itself"; fi
    fi
  fi
  plan "matrix: source ${S_PGV:-unknown} -> target ${T_PGV} $( [[ "$T_LITE" == true ]] && echo "(lite)" || echo "(standard)" ): allowed"
fi

# ---- the new namespace: Secrets the fleet does not manage would be overwritten by the owner's VaultStaticSecrets
if [[ "$ENTRY_NEW" == true && "$T_OWNER" == true ]]; then
  for sec in regsecret backup-storage; do
    rc=0; fleet_secret "$TNS" "$sec" || rc=$?
    case "$rc" in
      0|2) ;;
      3) fail TARGET_UNREADABLE "cannot read the Secret ${TNS}/${sec} on ${TC}: ${SECRET_ERR}" ;;
      *) fail NAMESPACE_SECRET_CONFLICT "namespace ${TNS} on ${TC} already has the Secret ${sec}, which the fleet does not manage (instance ${TI} would overwrite it from Vault); rename that Secret or choose another target namespace" ;;
    esac
  done
fi
if [[ -n "$SPEC_JSON" && -n "${T_BLN:-}" && "$T_BLN" != "${TI}-backup-location" ]]; then
  # a backupLocation the spec file names wins over the fleet's (tpg.restoredPostgres): it must exist for the restored instance to use it.
  # The fixed name of the copy of the source backup location is the exception: this run makes the copy before the restore (step 6 checks
  # below that the copy is the location in use, not another one that was reused)
  if [[ "$SAME_NS" == true || "$T_BLN" != "$(copy_want)" ]]; then
    get_obj "$TNS" postgresbackuplocation "$T_BLN" || true
    [[ -n "$OBJ" ]] || fail BACKUP_LOCATION_MISSING "the spec file names backupLocation ${T_BLN}, which does not exist in ${TNS} on ${TC}: create it there, or leave backupLocation out of the spec file (the fleet then renders ${TI}-backup-location for the instance)"
  fi
fi

# ---- 6. another namespace or cluster: the copy of the source backup location (reused when one exists)
COPY_NAME=""; COPY_CREATE=false; COPY_SPEC=""; COPY_SECRET=""
copy_secret_want() {  # the Secret of a copy this run creates: its own, named after the copy (two copies never share one, whatever the sources call theirs)
  local want="${COPY_NAME}-creds"
  [[ "${#want}" -le 253 ]] || want="restore-src-$(printf '%s' "$COPY_NAME" | cksum | cut -d' ' -f1)-creds"
  printf '%s' "$want"
}
find_copy() {  # find_copy: COPY_NAME, COPY_CREATE and COPY_SECRET (the Secret the copy reads) for the target namespace (a location for the same container and repoPath is reused)
  local want lst rows name cont path ep sync sec
  want="$(copy_want)"
  COPY_NAME="$want"; COPY_CREATE=true
  to_tgt
  # a list that cannot be read is not an empty list (a copy could then be created next to one that exists): the pair fails closed
  lst="$(tk -n "$TNS" get postgresbackuplocation -o json 2>"$WORK/loclist.err")" \
    || fail TARGET_UNREADABLE "the PostgresBackupLocations of ${TNS} on ${TC} could not be listed: $(tr '\n' ' ' <"$WORK/loclist.err" | cut -c1-300)"
  rows="$(jq -r '.items[]? | select(.spec.storage.azure.container != null)
    | [.metadata.name, .spec.storage.azure.container, (.spec.storage.azure.repoPath // "/"),
       (.spec.storage.azure.endpoint // "blob.core.windows.net"), (if .spec.backupSync.enabled == false then "false" else "true" end),
       (.spec.storage.azure.secret.name // "backup-storage")] | @tsv' <<<"$lst" 2>/dev/null)" \
    || fail TARGET_UNREADABLE "the PostgresBackupLocations of ${TNS} on ${TC} were listed, but the answer is not JSON: ${lst:0:200}"
  while IFS=$'\t' read -r name cont path ep sync sec; do
    [[ -n "$name" ]] || continue
    if [[ "$cont" == "$LOC_CONT" && "$ep" == "$LOC_EP" && "$(repo_norm "$path")" == "$(repo_norm "$LOC_PATH")" ]]; then
      [[ "$sync" == true ]] || fail SOURCE_LOCATION_CONFLICT "PostgresBackupLocation ${TNS}/${name} on ${TC} already points at ${LOC_CONT}${LOC_PATH} but has backupSync disabled, so the backups of the source repository do not appear there: enable backupSync on it, or delete it and run again"
      COPY_NAME="$name"; COPY_CREATE=false; COPY_SECRET="$sec"   # a reused copy keeps using the Secret it has
      return 0
    fi
    [[ "$name" != "$want" ]] || fail SOURCE_LOCATION_CONFLICT "PostgresBackupLocation ${TNS}/${name} on ${TC} exists for another repository (${cont}${path}), not the source repository ${LOC_CONT}${LOC_PATH}: delete it or choose another target namespace"
  done <<<"$rows"
  # a new copy: backup-storage stays the namespace's own Secret of the fleet; any other credentials get a Secret of the copy's own
  if [[ "$LOC_SECRET" == backup-storage ]]; then COPY_SECRET=backup-storage; else COPY_SECRET="$(copy_secret_want)"; fi
}
if [[ "$SAME_NS" != true ]]; then
  find_copy
  if [[ "$COPY_SECRET" != backup-storage ]]; then
    # the credentials of the copy are copied from the source in a real run: they must be there to copy (only the metadata is read here)
    to_src
    rc=0; secret_meta "$SNS" secret "$LOC_SECRET" >/dev/null || rc=$?
    [[ "$rc" -eq 0 ]] || fail SOURCE_SECRET_UNREADABLE "Secret ${SNS}/${LOC_SECRET} on ${SC}, the credentials of the source backup location ${SRC_BL}, cannot be read"
  fi
  if [[ -n "$SPEC_JSON" && "${T_BLN:-}" == "$(copy_want)" && "$COPY_NAME" != "$T_BLN" ]]; then
    fail BACKUP_LOCATION_MISSING "the spec file names backupLocation ${T_BLN}, the copy of the source backup location, but ${TNS} on ${TC} already has ${COPY_NAME} for that repository, which this run reuses instead of creating ${T_BLN}: name ${COPY_NAME} in the spec file, or leave backupLocation out of it"
  fi
  src_label="${SC}.${SI}"; [[ "${#src_label}" -le 63 ]] || src_label="$(printf '%s' "$src_label" | cksum | cut -d' ' -f1)"
  COPY_SPEC="$(jq -c --arg sec "$COPY_SECRET" '{
      retentionPolicy: {fullRetention: {type: "count", number: 9999999}, diffRetention: {number: 9999999}},
      storage: {azure: (.spec.storage.azure | {container, repoPath, endpoint, keyType, caBundle, forcePathStyle,
        enableSSL: (.enableSSL // false), secret: {name: $sec}} | with_entries(select(.value != null)))},
      backupSync: {enabled: true}, backupIntegrityValidation: {enabled: true}}
      + (if (.spec.additionalParameters // {}) != {} then {additionalParameters: .spec.additionalParameters} else {} end)' <<<"$LOC_JSON")"
  if [[ "$COPY_CREATE" == true ]]; then
    plan "source location: ${SNS}/${SRC_BL} on ${SC} (${LOC_CONT}${LOC_PATH}) would be copied as ${TNS}/${COPY_NAME} on ${TC} (backupSync on, retention 9999999, label tpg.fleet/restore-source=${src_label}); Secret ${COPY_SECRET}$( [[ "$COPY_SECRET" == backup-storage ]] && echo ": the backup-storage of ${TNS} (Vault Secrets Operator), else created from Vault" || echo " (its own, removed with it by keepSourceLocation=false): copied from ${SC}/${SNS}/${LOC_SECRET} in memory" )"
  else
    plan "source location: ${TNS}/${COPY_NAME} on ${TC} already points at ${LOC_CONT}${LOC_PATH} with backupSync on: reused, not created, never removed by this run; it reads the Secret ${COPY_SECRET}$( [[ "$COPY_SECRET" == backup-storage ]] && echo " of the namespace" || echo ", which is refreshed from ${SC}/${SNS}/${LOC_SECRET} in memory when its contents differ (only when it is labelled tpg.fleet/restore-source=${src_label}, else SOURCE_SECRET_CONFLICT)" )"
  fi
  [[ "$METHOD" != backup ]] || plan "named backup: after the location exists, wait for the PostgresBackup in ${TNS} on ${TC} that backupSync makes of ${SBK} to appear and be Succeeded: the one with restoreLabel ${SB_LABEL}, stanza ${SB_STANZA:-<any>}, location ${COPY_NAME} and instance ${SI} (it is named sync-<label>-<hash>, not ${SBK}; counts against restoreTimeoutSeconds ${TIMEOUT}s; Failed stops the pair at once); the PostgresRestore then names it"
fi
RESTORE_BL="$SRC_BL"; [[ "$SAME_NS" == true ]] || RESTORE_BL="$COPY_NAME"

# ---- 8. the PostgresRestore: rendered through the reference chart (tpg.prune leaves zero defaults out)
RENDERED=""
render_obj() {  # render_obj KIND VALUES_JSON: RENDERED = the object as YAML (CHART_RENDER_FAILED when helm fails; call it in this shell, not in $(...))
  local out
  printf '%s' "$2" > "$WORK/render-values.json"
  out="$(helm template ref "$REPO/helm_artifacts/instance/crd-reference" -f "$WORK/render-values.json" 2>"$WORK/render.err")" \
    || fail CHART_RENDER_FAILED "${1}: $(tr '\n' ' ' <"$WORK/render.err" | cut -c1-300)"
  RENDERED="$(K="$1" yq 'select(.kind == strenv(K))' <<<"$out" | sed '/^---$/d;/^# Source:/d')"
}
RNAME="${TI}-restore-$(date -u +%Y%m%d%H%M%S)"
# spec.targetInstance.spec is the spec file's spec as it is, or absent (the name only): the operator creates a new instance and
# fills in its spec (lab item), an existing one keeps its spec
tinst="$(jq -cn --arg n "$TI" --argjson spec "${SPEC_JSON:-null}" '{name: $n} + (if $spec != null then {spec: $spec} else {} end)')"
if [[ "$METHOD" == backup ]]; then
  # into another namespace or cluster the synced backup has another name, known after backupSync: a placeholder in the plan
  RESTORE_SB="$SBK"; [[ "$SAME_NS" == true ]] || RESTORE_SB="@synced:${SB_LABEL}@"
  rspec="$(jq -cn --arg b "$RESTORE_SB" --argjson t "$tinst" '{sourceBackup: {name: $b}, targetInstance: $t}')"
else
  rspec="$(jq -cn --arg type "$METHOD" --arg ts "$PITR_TS" --arg tg "$PITR_TARGET" --argjson best "$PITR_BEST" --arg bl "$RESTORE_BL" \
    --arg st "$SRC_STANZA" --arg lab "$PITR_LABEL" --argjson t "$tinst" '
    {pitr: ({type: $type}
        + (if $ts != "" then {timestamp: $ts} else {} end)
        + (if $tg != "" then {target: $tg} else {} end)
        + (if $best then {bestEffort: true} else {} end)
        + {sourceBackupLocation: ({name: $bl, stanzaName: $st} + (if $lab != "" then {set: $lab} else {} end))}),
     targetInstance: $t}')"
fi
render_obj PostgresRestore "$(jq -cn --arg name "$RNAME" --arg wf "$WF" --argjson skip "$SKIPMINOR" --argjson spec "$rspec" \
  '{postgresRestore: {enabled: true, name: $name, labels: {"tpg.fleet/workflow": $wf},
    annotations: (if $skip then {"sql.tanzu.vmware.com/skip-minor-version-check": "true"} else {} end), spec: $spec}}')"
RESTORE_YAML="$RENDERED"
COPY_YAML=""
if [[ "$SAME_NS" != true && "$COPY_CREATE" == true ]]; then
  render_obj PostgresBackupLocation "$(jq -cn --arg name "$COPY_NAME" --arg wf "$WF" --arg src "$src_label" --argjson spec "$COPY_SPEC" \
    '{postgresBackupLocation: {enabled: true, name: $name, labels: {"tpg.fleet/restore-source": $src, "tpg.fleet/managed": "true"},
      annotations: {"tpg.fleet/created-by": $wf}, spec: $spec}}')"
  COPY_YAML="$RENDERED"
fi
plan "PostgresRestore ${TNS}/${RNAME} on ${TC}:"
plan "    ${RESTORE_YAML//$'\n'/$'\n'    }"
[[ -z "$COPY_YAML" ]] || { plan "PostgresBackupLocation ${TNS}/${COPY_NAME} on ${TC}:"; plan "    ${COPY_YAML//$'\n'/$'\n'    }"; }
if [[ "$POSTBACKUP" == true ]]; then plan "after the restore: a full backup of ${TI} (post-restore backup)"; fi
if [[ "$SAME_NS" != true ]]; then
  if [[ "$KEEP" == true ]]; then plan "keepSourceLocation: ${COPY_NAME} stays in ${TNS}; while it exists repo_shared treats the source repository as shared"
  elif [[ "$COPY_CREATE" == true ]]; then plan "keepSourceLocation=false: ${COPY_NAME} would be removed after a successful restore"
  else plan "keepSourceLocation=false: ${COPY_NAME} was not created by this run and is kept"; fi
fi

# ---- 7. dry run: the plan is recorded, nothing was changed
if [[ "$DRY" == true ]]; then
  plan_save
  dump_plan
  w="$(join_list ${WARNS[@]+"${WARNS[@]}"})"
  record "$RKEY" SUCCEEDED DRY_RUN "would restore ${SC}/${SNS}/${SI} into ${TC}/${TNS}/${TI} ($( [[ "$METHOD" == backup ]] && echo "backup ${SBK}" || echo "pitr ${METHOD}" ), $( [[ "$TGT_EXISTS" == true ]] && echo "in place" || echo "new instance" )); nothing was changed; the plan is in plan.restore.${TC}.${TI}${w:+; warnings: ${w}}"
  exit 0
fi

# ======================================================================== a real restore from here
plan_save
dump_plan
# an unfinished restore of this target: wait two minutes, then leave the pair alone
in_progress() {
  local r
  r="$(latest_cr postgresrestore "$TNS" ".spec.targetInstance.name == \"${TI}\"")"
  [[ -n "$r" ]] || return 1
  case "$(jq -r '.status.phase // ""' <<<"$r")" in
    Succeeded|Failed) return 1 ;;
    *) printf '%s' "$r"; return 0 ;;
  esac
}
to_tgt
if [[ "$TGT_EXISTS" == true && -n "$BUSY" ]]; then
  fail OPERATION_IN_PROGRESS "${TC}/${TI} has an unfinished ${BUSY} (kubectl -n ${TNS} get ${BUSY// /,}): restore after it finished"
fi
if in_progress >/dev/null; then
  log "a restore of ${TI} is still in progress, waiting 2 minutes"
  sleep 120
  if R="$(in_progress)"; then
    record "$RKEY" SKIPPED_IN_PROGRESS "" "$(jq -r '.metadata.name + " phase " + (.status.phase // "Pending")' <<<"$R")"
    exit 0
  fi
fi

# ---- 5 (real) a new target: the entry goes to Git, the Application provides the shared objects and the backup location
wait_app() {  # wait_app APP: the ApplicationSet has generated the Application
  app_exists "$1" && return 0
  appset_refresh tpg-instances || true
  wait_logged "Application ${1} generated" 40 15 app_exists "$1"
}
PUSHED_REV=""
if [[ "$ENTRY_NEW" == true ]]; then
  if [[ "$PUSH_MODE" == direct ]]; then
    # the owner of the shared Secrets is decided under the fleet lock on the newest clusters/fleet.yaml: concurrent pairs into one new
    # namespace see each other's entry
    fleet_lock_acquire || true
    git_clone "$REPO" >/dev/null 2>&1 || { fleet_lock_release; fail FLEET_UNREADABLE "the fleet repository could not be cloned again before the push"; }
    if [[ "$TGT_FLEET" != true ]] && fleet_has_instance "$REPO" "$TC" "$TI"; then
      note "the entry ${TC}/${TI} appeared in ${FLEET_REL} meanwhile: it is kept as it is"
      fleet_lock_release
    else
      prepare_entry || { fleet_lock_release; fail FLEET_EDIT_FAILED "$FLEET_REL"; }
      git_commit_push "$REPO" "restore: add ${TC}/${TI} from ${SC}/${SI} (${WF})" "$FLEET_REL" ${SPEC_JSON:+"$RESTORE_PATCH_DIR"} \
        || { fleet_lock_release; fail GIT_PUSH_FAILED "pushMode=${PUSH_MODE}: the entry ${TC}/${TI} was not pushed to ${FLEET_REL}"; }
      fleet_lock_release
    fi
  else
    git_commit_push "$REPO" "restore: add ${TC}/${TI} from ${SC}/${SI} (${WF})" "$FLEET_REL" ${SPEC_JSON:+"$RESTORE_PATCH_DIR"} \
      || fail GIT_PUSH_FAILED "pushMode=${PUSH_MODE}: the entry ${TC}/${TI} was not merged into ${FLEET_REL}${PR_NUMBER:+ (pull request #${PR_NUMBER})}"
  fi
  PUSHED_REV="${PUSHED_REVISION:-}"
  # never two owners of the shared Secrets (concurrent pull requests into one namespace)
  n_owners="$(fleet_ns_owners "$REPO" "$TC" "$TNS" | grep -c . || true)"
  if [[ "$n_owners" -gt 1 && "$(_flag_get "$REPO" "$TC" "$TI")" != false ]]; then
    fail NAMESPACE_OWNER_CONFLICT "after the push ${FLEET_REL} names $(fleet_ns_owners "$REPO" "$TC" "$TNS" | paste -sd, -) as owners of the shared Secrets of ${TNS} on ${TC}; set instance.sharedSecretsOwner: false on all but one of them and run again (nothing was synced)"
  fi
fi
# a new instance (one declared in clusters/fleet.yaml but not deployed included): its Application provides the shared objects and the backup location
if [[ "$TGT_EXISTS" == false ]]; then
  to_tgt
  tk create namespace "$TNS" --dry-run=client -o yaml | tk apply -f - >/dev/null || fail TARGET_PREPARE_FAILED "namespace ${TNS} on ${TC}"
  tk label namespace "$TNS" tpg.fleet/managed=true --overwrite >/dev/null || fail TARGET_PREPARE_FAILED "label of namespace ${TNS} on ${TC}"
  wait_app "tpg-${TC}-${TI}" || fail APP_NOT_GENERATED "tpg-${TC}-${TI}: the ApplicationSet tpg-instances did not generate it after the push"
  REV="${PUSHED_REV:-$(fleet_head)}"
  if [[ "$(_flag_get "$REPO" "$TC" "$TI")" != false ]]; then
    # the owner: only its Application applies the shared objects (selective sync, nothing else of the Application)
    sync_shared_secrets "$TC" "$TI" "$TNS" "$SYNC_TIMEOUT" "$REV" \
      || fail SHARED_SECRETS_MISSING "tpg-${TC}-${TI}: the shared objects of ${TNS} were not synced: ${SYNC_FAIL_REASON} ${SYNC_FAIL_DETAIL}"
    for sec in regsecret backup-storage; do
      wait_logged "Secret ${TNS}/${sec}" 30 10 secret_present "$TNS" "$sec" || fail SECRET_NOT_SYNCED "${TNS}/${sec} from Vault"
    done
  else
    ensure_shared_secrets "$TC" "$TI" "$TNS" "$SYNC_TIMEOUT" "$REV" || fail SHARED_SECRETS_MISSING "$SHARED_DETAIL"
  fi
  if [[ "${T_BLN:-}" == "${TI}-backup-location" ]]; then
    app_sync_wait "tpg-${TC}-${TI}" "$SYNC_TIMEOUT" ${REV:+--revision "$REV"} \
      --resources "sql.tanzu.vmware.com:PostgresBackupLocation:${TNS}/${T_BLN}" \
      || fail TARGET_PREPARE_FAILED "the backup location ${TNS}/${T_BLN} of the new instance was not synced: ${SYNC_FAIL_REASON} ${SYNC_FAIL_DETAIL}"
  fi
fi

# ---- 6 (real) the copy of the source location with its Secret
COPY_MADE=false; COPY_SECRET_MADE=false
secret_in_target() {  # the Secret of the copied (or reused) location is in the target namespace (values only ever in memory)
  local sec="$COPY_SECRET" rc=0 sacct skey live_sha want have lab
  to_tgt
  if [[ "$sec" == backup-storage ]]; then
    rc=0; fleet_secret "$TNS" backup-storage || rc=$?
    case "$rc" in
      0) return 0 ;;
      3) fail TARGET_UNREADABLE "cannot read the Secret ${TNS}/backup-storage on ${TC}: ${SECRET_ERR}" ;;
    esac
    sacct="$(vault_secret backup-storage accountName)" || fail NO_VAULT_SECRET "backup-storage (tpg/shared/backup-storage): the storage account of the fleet is needed for the Secret of ${COPY_NAME} in ${TNS}"
    skey="$(vault_secret backup-storage accountKey)" \
      || fail NO_VAULT_SECRET "backup-storage (tpg/shared/backup-storage): the storage account of the fleet is needed for the Secret of ${COPY_NAME} in ${TNS}"
    if [[ "$rc" -eq 1 ]]; then
      # a Secret backup-storage the fleet does not manage: fine when it holds the fleet's key, otherwise it is somebody else's
      want="$(printf '%s' "$skey" | sha16)"
      if secret_matches "$TNS" backup-storage '.data.accountKey | @base64d' "$want"; then
        skey=""; sacct=""; return 0
      fi
      skey=""; sacct=""
      fail NAMESPACE_SECRET_CONFLICT "namespace ${TNS} on ${TC} has a Secret backup-storage that the fleet does not manage and that does not hold the fleet's storage key; the copied location ${COPY_NAME} reads it: rename that Secret or choose another target namespace"
    fi
    # absent (a namespace the fleet does not manage): created from Vault, in memory
    A="$sacct" K="$skey" jq -n --arg src "$src_label" '{apiVersion: "v1", kind: "Secret", type: "Opaque",
        metadata: {name: "backup-storage", labels: {"tpg.fleet/restore-source": $src, "tpg.fleet/managed": "true"}},
        data: {accountName: (env.A | @base64), accountKey: (env.K | @base64)}}' | tk -n "$TNS" apply -f - >/dev/null \
      || { skey=""; sacct=""; fail TARGET_PREPARE_FAILED "Secret backup-storage in ${TNS} on ${TC}"; }
    skey=""; sacct=""
    COPY_SECRET_MADE=true; note "Secret ${TNS}/backup-storage was created from Vault (the namespace has no VaultStaticSecret for it)"
    return 0
  fi
  # any other Secret: the copy's own, copied from the source cluster in memory. A new copy has a Secret of its own name (<copy>-creds), so no
  # other copy or Secret of the namespace is touched; a reused copy keeps the Secret it has: it is refreshed when its contents differ, but
  # only when it was made for this source (tpg.fleet/restore-source), otherwise it is somebody else's or another source's
  to_src
  local sj tj
  sj="$(tk -n "$SNS" get secret "$LOC_SECRET" -o json 2>/dev/null)" || sj=""
  [[ -n "$sj" ]] || fail SOURCE_SECRET_UNREADABLE "Secret ${SNS}/${LOC_SECRET} on ${SC}, the credentials of the source backup location ${SRC_BL}, could not be read"
  have="$(printf '%s' "$sj" | jq -S -c '.data // {}' | sha16)"
  to_tgt
  live_sha=""
  if tj="$(tk -n "$TNS" get secret "$sec" -o json 2>/dev/null)" && [[ -n "$tj" ]]; then
    live_sha="$(printf '%s' "$tj" | jq -S -c '.data // {}' | sha16)"
    lab="$(printf '%s' "$tj" | jq -r '.metadata.labels["tpg.fleet/restore-source"] // ""')"
    tj=""
    if [[ "$live_sha" == "$have" ]]; then
      # as it should be: nothing to write; one made for this source by an earlier run is this copy's own, removed with it
      sj=""; [[ "$lab" != "$src_label" ]] || COPY_SECRET_MADE=true
      return 0
    fi
    if [[ -z "$lab" ]]; then
      sj=""
      fail SOURCE_SECRET_CONFLICT "namespace ${TNS} on ${TC} already has a Secret ${sec} with other contents that this workflow did not create; the location ${COPY_NAME} reads it and needs the credentials of ${SC}/${SNS}/${LOC_SECRET}: rename that Secret or choose another target namespace"
    elif [[ "$lab" != "$src_label" ]]; then
      sj=""
      fail SOURCE_SECRET_CONFLICT "the Secret ${sec} of namespace ${TNS} on ${TC} has other contents and was made for another restore source (tpg.fleet/restore-source=${lab}, this pair's source is ${src_label}); the location ${COPY_NAME} reads it and needs the credentials of ${SC}/${SNS}/${LOC_SECRET}: it is not overwritten; restore from that source, or delete the Secret and the location ${COPY_NAME} if they are no longer needed"
    fi
  fi
  tj=""
  printf '%s' "$sj" | S="$src_label" N="$sec" jq '{apiVersion: "v1", kind: "Secret", type: (.type // "Opaque"),
      metadata: {name: env.N, labels: {"tpg.fleet/restore-source": env.S, "tpg.fleet/managed": "true"}}, data: (.data // {})}' \
    | tk -n "$TNS" apply -f - >/dev/null || { sj=""; fail TARGET_PREPARE_FAILED "Secret ${sec} in ${TNS} on ${TC}"; }
  sj=""
  COPY_SECRET_MADE=true; note "Secret ${TNS}/${sec} was copied from ${SC}/${SNS}/${LOC_SECRET} (contents not logged)"
}
START="$SECONDS"
if [[ "$SAME_NS" != true ]]; then
  secret_in_target
  if [[ "$COPY_CREATE" == true ]]; then
    to_tgt
    printf '%s\n' "$COPY_YAML" | tk -n "$TNS" apply -f - >/dev/null || fail SOURCE_LOCATION_FAILED "PostgresBackupLocation ${TNS}/${COPY_NAME} on ${TC}"
    COPY_MADE=true
    note "source backup location ${TNS}/${COPY_NAME} created"
  fi
  if [[ "$METHOD" == backup ]]; then
    last_phase=""; synced_seen=""; SYNC_NAME=""
    while true; do
      to_tgt
      matches="[]"
      if tk -n "$TNS" get postgresbackup -o json > "$WORK/synced.json" 2>/dev/null; then
        # the synced backup: the label (case: the object name is lowercase), stanza, location and instance of the source backup
        matches="$(jq -c --arg l "$SB_LABEL" --arg st "$SB_STANZA" --arg loc "$COPY_NAME" --arg i "$SI" '[.items[]?
          | select(((.status.restoreLabel // "") | ascii_downcase) == ($l | ascii_downcase) and ($st == "" or (.status.stanzaName // "") == $st)
                   and (.status.backupLocation // "") == $loc and (.spec.sourceInstance.name // "") == $i)
          | {name: .metadata.name, phase: (.status.phase // "")}]' "$WORK/synced.json")"
        synced_seen="$(jq -r '[.items[]? | "\(.metadata.name) (label \(.status.restoreLabel // "none"), \(.status.phase // "no phase"))"] | join(", ")' "$WORK/synced.json")"
      fi
      if [[ "$(jq 'length' <<<"$matches")" -gt 1 ]]; then
        fail BACKUP_AMBIGUOUS "more than one PostgresBackup in ${TNS} on ${TC} has restoreLabel ${SB_LABEL}, stanza ${SB_STANZA:-<any>}, location ${COPY_NAME} and instance ${SI}: $(jq -r 'map(.name) | join(", ")' <<<"$matches"); remove the duplicates (or the extra location) and run the pair again"
      fi
      if [[ "$(jq 'length' <<<"$matches")" -eq 1 ]]; then
        SYNC_NAME="$(jq -r '.[0].name' <<<"$matches")"; last_phase="$(jq -r '.[0].phase' <<<"$matches")"
        case "$last_phase" in
          Succeeded) break ;;
          Failed) fail BACKUP_NOT_SUCCEEDED "the synced PostgresBackup ${TNS}/${SYNC_NAME} on ${TC} (source backup ${SBK}, restoreLabel ${SB_LABEL}) is Failed" ;;
        esac
      fi
      if (( SECONDS - START > TIMEOUT )); then
        fail BACKUPS_NOT_SYNCED "the synced PostgresBackup of ${SBK} (restoreLabel ${SB_LABEL}, stanza ${SB_STANZA:-<any>}, location ${COPY_NAME}, instance ${SI}) did not appear Succeeded in ${TNS} on ${TC} within ${TIMEOUT}s (last phase seen: ${last_phase:-not there}); backupSync of ${COPY_NAME} has not listed it. In the namespace: ${synced_seen:-no PostgresBackup}"
      fi
      log "waiting for the synced PostgresBackup of ${SBK} (restoreLabel ${SB_LABEL}) in ${TNS} on ${TC}: phase ${last_phase:-<not there>} ($((SECONDS - START))s)"
      sleep 20
    done
    note "PostgresBackup ${TNS}/${SYNC_NAME} (source backup ${SBK}, restoreLabel ${SB_LABEL}) synced and Succeeded"
    # the PostgresRestore names the synced backup
    RESTORE_YAML="$(N="$SYNC_NAME" yq '.spec.sourceBackup.name = strenv(N)' <<<"$RESTORE_YAML")"
  fi
fi

# ---- 8 (real) create the PostgresRestore and wait for it
to_tgt
log "creating PostgresRestore ${TNS}/${RNAME} (${METHOD}) -> ${TC}/${TI}"
printf '%s\n' "$RESTORE_YAML" | tk -n "$TNS" apply -f - >/dev/null || fail CREATE_FAILED "$RNAME"
# START is the one clock of the restore phase: the wait for synced backups above counts against restoreTimeoutSeconds too
while true; do
  j="$(tk -n "$TNS" get postgresrestore "$RNAME" -o json 2>/dev/null || echo '{}')"
  phase="$(jq -r '.status.phase // ""' <<<"$j")"
  case "$phase" in
    Succeeded) break ;;
    Failed) fail RESTORE_FAILED "$(jq -r '[.status.conditions[]?.message] | join("; ")' <<<"$j" | tr '\n' ' ')" ;;
  esac
  if (( SECONDS - START > TIMEOUT )); then
    record "$RKEY" TIMEOUT "" "${RNAME} phase=${phase:-none}$(join_list ${NOTES[@]+"${NOTES[@]}"} | sed 's/^/; /')"
    exit 1
  fi
  log "PostgresRestore ${TNS}/${RNAME}: phase ${phase:-<none>} ($((SECONDS - START))s); pods: $(tk -n "$TNS" get pods --no-headers 2>/dev/null \
    | awk '{printf "%s%s=%s %s", (n++ ? ", " : ""), $1, $3, $2}')"
  sleep 30
done

pg_wait_ready "$TI" "$READY_TIMEOUT" || fail "TARGET_${POD_WATCH_REASON:-NOT_RUNNING}" "$TI: ${POD_WATCH_DETAIL:-}"
[[ "$TGT_EXISTS" == true || -n "$SPEC_JSON" ]] || note "no spec file: ${TI} was created by the operator from spec.targetInstance.name alone, which fills in its spec (lab item: not verified how); the spec it has is read below"

# ---- 5 (real) the restore-patch: the spec of the restored Postgres as the entry's restorePatch (lib.sh restore_patch_record, templates/_helpers.tpl
# tpg.restoredPostgres). A new entry with a spec file recorded it in the commit of the entry. Everywhere else it is a commit of its own, now
# that the restore succeeded and the instance runs (pushMode applies), before the adoption sync of a new instance: the spec file's
# spec, or without one the spec read from the cluster
SNAP_SPEC=""; SNAP_ERR=""
snapshot_spec() {  # snapshot_spec: SNAP_SPEC = the .spec of the restored Postgres on the target (JSON, nulls dropped), valid as a Postgres spec; 1 with SNAP_ERR
  local f="$WORK/snapshot.json"
  SNAP_SPEC=""; SNAP_ERR=""
  to_tgt
  get_obj "$TNS" postgres "$TI" || { SNAP_ERR="Postgres ${TNS}/${TI} on ${TC} could not be read: ${OBJ_ERR}"; return 1; }
  [[ -n "$OBJ" ]] || { SNAP_ERR="Postgres ${TNS}/${TI} does not exist on ${TC}"; return 1; }
  SNAP_SPEC="$(jq -c '(.spec // {}) | walk(if type == "object" then with_entries(select(.value != null)) else . end)' <<<"$OBJ")"
  [[ "$SNAP_SPEC" != '{}' && "$SNAP_SPEC" != null ]] || { SNAP_ERR="Postgres ${TNS}/${TI} on ${TC} has no spec"; SNAP_SPEC=""; return 1; }
  jq -c '[{apiVersion: "sql.tanzu.vmware.com/v1", kind: "Postgres", spec: .}]' <<<"$SNAP_SPEC" > "$f"
  if ! SNAP_ERR="$(python3 "$TPG_LIB_DIR/patchcheck.py" spec "$f" --schemas "$(patch_schemas_path)" --name "the spec of ${TNS}/${TI}" | tr '\n' ';')"; then
    SNAP_SPEC=""; return 1
  fi
  SNAP_ERR=""
}
RP_RECORDED=true   # false: the Application of the new instance must not be synced (the chart would render it from the entry)
if [[ "$ENTRY_NEW" == true && -n "$SPEC_JSON" ]]; then
  :   # recorded with the entry
elif [[ -n "$RP_NOTE" ]]; then
  note "$RP_NOTE"
else
  RP_RECORDED=false
  RP_SPEC="$SPEC_JSON"
  if [[ -z "$RP_SPEC" ]]; then
    if snapshot_spec; then RP_SPEC="$SNAP_SPEC"; note "no spec file: the spec of ${TI} was read from ${TC} (${#RP_SPEC} bytes) and is stored as its restore-patch"
    else warn RESTORE_PATCH_NOT_RECORDED "the restore succeeded, but the spec of ${TC}/${TNS}/${TI} could not be read as the restore-patch: ${SNAP_ERR}$( [[ "$TGT_EXISTS" == true ]] || echo "; the Application tpg-${TC}-${TI} is not synced, since the chart would render the entry over the restored Postgres" )"; fi
  fi
  if [[ -n "$RP_SPEC" ]]; then
    rp_ok=false
    [[ "$PUSH_MODE" != direct ]] || fleet_lock_acquire || true
    if git_clone "$REPO" >/dev/null 2>&1 && fleet_has_instance "$REPO" "$TC" "$TI" && stage_restore_patch "$RP_SPEC" "$RP_FORM" \
       && git_commit_push "$REPO" "restore: record the restore-patch of ${TC}/${TI} (${WF})" "$FLEET_REL" "$RESTORE_PATCH_DIR"; then
      rp_ok=true; PUSHED_REV="${PUSHED_REVISION:-$PUSHED_REV}"
    fi
    [[ "$PUSH_MODE" != direct ]] || fleet_lock_release
    if [[ "$rp_ok" == true ]]; then
      RP_RECORDED=true
      note "the spec of ${TI} is recorded as restorePatch.current of ${TC}/${TI} in ${FLEET_REL} (${RP_PATH}, mode ${RP_FORM}); the chart of Application tpg-${TC}-${TI} renders the Postgres from it"
    else
      warn RESTORE_PATCH_NOT_RECORDED "the restore succeeded, but the spec could not be recorded as the restore-patch of ${TC}/${TI} in ${FLEET_REL} (pushMode ${PUSH_MODE}); the next sync of Application tpg-${TC}-${TI} renders the entry without it$( [[ "$TGT_EXISTS" == true ]] || echo " (not synced by this run)" )"
    fi
  fi
fi

# ---- 5 (real) the new instance is adopted by its Application
if [[ "$TGT_EXISTS" == false && "$RP_RECORDED" == true ]]; then
  if sync_instance_app "$TC" "$TI" "$SYNC_TIMEOUT" "$PUSHED_REV"; then
    note "Application tpg-${TC}-${TI} synced: the instance is managed by Argo CD"
  else
    warn ADOPTION_NOT_SYNCED "Application tpg-${TC}-${TI} did not sync (${SYNC_FAIL_REASON}: ${SYNC_FAIL_DETAIL}): check it in Argo CD"
    note "Application tpg-${TC}-${TI} did not sync after the restore"
  fi
fi

# ---- 9 post-restore backup, then the copy of the source location
if [[ "$POSTBACKUP" == true ]]; then
  RESULT_KEY="backup.${TC}.${TI}" bash /scripts/backup-instance.sh "$WF" "$TC" "$TI" full "$BACKUP_TIMEOUT" || true
  b="$(run_data "backup.${TC}.${TI}")"; [[ -n "$b" ]] || b='{}'
  if [[ "$(jq -r '.status // ""' <<<"$b")" != "SUCCEEDED" ]]; then
    # the restore succeeded and the instance runs: the pair stays SUCCEEDED, the failed backup is a warning
    warn POST_RESTORE_BACKUP_FAILED "the restore itself succeeded and ${TI} runs, but the full backup after it did not: $(jq -r '(.status // "no result") + " " + (.reason // "") + " " + (.detail // "")' <<<"$b"); take one with tpg-backup"
  else
    note "post-restore backup: $(jq -r '.detail' <<<"$b")"
  fi
fi
if [[ "$SAME_NS" != true ]]; then
  if [[ "$KEEP" == false && "$COPY_MADE" == true ]]; then
    to_tgt
    # an instance of the namespace that names the copy as its spec.backupLocation (the restored one, as the operator or the spec file
    # made it, or any other) keeps it: the copy is its backup location now. If the instances cannot be listed none can be ruled out.
    in_use=""; in_use_err=""
    if pgj="$(tk -n "$TNS" get postgres -o json 2>"$WORK/inuse.err")"; then
      in_use="$(jq -r --arg l "$COPY_NAME" '[.items[]? | select(.spec.backupLocation.name == $l) | .metadata.name] | join(",")' <<<"$pgj" 2>/dev/null)" \
        || in_use_err="the answer was not JSON"
    else
      in_use_err="$(tr '\n' ' ' <"$WORK/inuse.err" | cut -c1-300)"
    fi
    # another pair of this run (or anyone) may still restore from the same copy: it is removed only when no restore is unfinished here
    unfinished="$(tk -n "$TNS" get postgresrestore -o json 2>/dev/null | jq -r "[.items[]? | ${OP_ACTIVE_JQ} | .metadata.name] | join(\",\")" 2>/dev/null || true)"
    if [[ -n "$in_use_err" ]]; then
      warn SOURCE_LOCATION_NOT_REMOVED "PostgresBackupLocation ${TNS}/${COPY_NAME} on ${TC} was kept: the Postgres instances of ${TNS} could not be read to check that none uses it (${in_use_err}); delete it by hand when none does"
    elif [[ -n "$in_use" ]]; then
      warn SOURCE_LOCATION_IN_USE "PostgresBackupLocation ${TNS}/${COPY_NAME} on ${TC} was kept although keepSourceLocation=false: spec.backupLocation of ${in_use} names it; the instance(s) use it as their backup location, so removing it would break them"
    elif [[ -n "$unfinished" ]]; then
      note "source backup location ${TNS}/${COPY_NAME} kept although keepSourceLocation=false: the restore(s) ${unfinished} in ${TNS} are not finished and may still use it; delete it by hand afterwards"
    elif tk -n "$TNS" delete postgresbackuplocation "$COPY_NAME" --ignore-not-found >/dev/null 2>&1; then
      note "source backup location ${TNS}/${COPY_NAME} removed (keepSourceLocation=false)"
      # the copy's own Secret goes with it (the Secret of a copy this run created, named after the copy; no other Secret is touched)
      if [[ "$COPY_SECRET_MADE" == true && "$COPY_SECRET" != backup-storage ]]; then tk -n "$TNS" delete secret "$COPY_SECRET" --ignore-not-found >/dev/null 2>&1 || true; fi
    else
      warn SOURCE_LOCATION_NOT_REMOVED "PostgresBackupLocation ${TNS}/${COPY_NAME} on ${TC} could not be removed; delete it by hand"
    fi
  elif [[ "$COPY_MADE" == true || "$COPY_CREATE" == false ]]; then
    note "source backup location ${TNS}/${COPY_NAME} kept (delete it by hand when the restore is validated; while it exists the repository counts as shared)"
  fi
fi
w="$(join_list ${WARNS[@]+"${WARNS[@]}"})"
notes="$(join_list ${NOTES[@]+"${NOTES[@]}"})"
record "$RKEY" SUCCEEDED "" "restored ${SC}/${SNS}/${SI} into ${TC}/${TNS}/${TI} ($( [[ "$METHOD" == backup ]] && echo "backup ${SBK}${SYNC_NAME:+ = ${SYNC_NAME}}" || echo "pitr ${METHOD}" ))${notes:+; ${notes}}${w:+; warnings: ${w}}"
