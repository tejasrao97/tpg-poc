#!/usr/bin/env bash
# backup-expire.sh WORKFLOW_NAME CLUSTER INSTANCE DRY_RUN TIMEOUT_SECONDS
# tpg-backup-expire (Round 23, locked decision 5), one instance. What to expire comes from the instance entry of
# clusterMap (P_CLUSTER_MAP):
#   backups: [..]            the PostgresBackup names to expire
#   includeDependents: true  also expire the differential and incremental backups that depend on them. Needed
#                            for a backup that has dependents (a full backup with its chain, a differential
#                            with the incrementals after it); without it the instance is BLOCKED
#                            (HAS_DEPENDENTS) with the list, nothing is expired
#   purgeBackups: true       expire every backup of the instance (not together with backups). Blobs are never
#                            deleted here: that is purgeBackups of tpg-delete-instance and tpg-delete-apps
# A backup is expired by setting spec.expire=true on its PostgresBackup; the operator runs pgBackRest expire for
# the set and the script waits for its answer (lib.sh backup_expire). Dependents are expired first, newest first,
# so no expire cascades.
# DRY_RUN=true (the workflow default) records the plan - what would be expired, what is BLOCKED - and changes
# nothing. A BLOCKED instance is reported (the run ends Failed through blocked-gate.sh, the others ran).
# Results (result.<cluster>.<instance>):
#   SUCCEEDED            expired (detail lists them); DRY_RUN: the plan; purgeBackups: what pgBackRest declined
#                        is reported in the detail and as a warning (reason DECLINED_SOME), not a failure
#   BLOCKED              HAS_DEPENDENTS: a named backup has dependents that are not named and includeDependents
#                        is not true
#   FAILED               UNKNOWN_BACKUP, NOT_EXPIRABLE (no pgBackRest label: the backup never completed),
#                        INSTANCE_NOT_RUNNING, OPERATION_IN_PROGRESS, BACKUP_EXPIRE_DECLINED (a backup the
#                        user asked for, named or a dependent: pgBackRest refused; the operator's message is
#                        the detail; later backups are not attempted), EXPIRE_FAILED
#   TIMEOUT              no answer from the operator in time
# LAB ITEM: what the operator reports when pgBackRest refuses (for example the last full backup) is read in one
# place, lib.sh _backup_expire_state; verify it on the lab cluster.
WF="$1"; C="$2"; I="$3"; DRY="${4:-true}"; TIMEOUT="${5:-600}"
# shellcheck source=workflows/scripts/lib.sh
source /scripts/lib.sh

key="result.${C}.${I}"
result_guard "$key"
NS="$(instance_ns "$C" "$I")" || { record "$key" FAILED FLEET_UNREADABLE "$FLEET_UNREADABLE_DETAIL"; exit 0; }
use_cluster "$C" || { record "$key" FAILED NOT_REGISTERED; exit 0; }

cmap_load || { record "$key" FAILED INVALID_INPUT "clusterMap could not be read"; exit 0; }
PURGE="$(cmap_ival "$C" "$I" purgeBackups false)"
INCLUDE="$(cmap_ival "$C" "$I" includeDependents false)"
mapfile -t NAMED < <(jq -r --arg c "$C" --arg i "$I" '.[$c].instances[$i].backups // [] | .[]' "$WORK/cmap.json")

state="$(pg_state "$I")"
if [[ "$state" != "Running" ]]; then
  record "$key" FAILED INSTANCE_NOT_RUNNING "currentState=${state:-none}: the operator expires backups only while the instance runs"
  exit 0
fi
busy="$(busy_operations "$I")"
[[ -z "$busy" ]] || { record "$key" FAILED OPERATION_IN_PROGRESS "$busy"; exit 0; }

list="$(backup_list "$NS" "$I")" || { record "$key" FAILED BACKUPS_UNREADABLE "the PostgresBackups of ${I} cannot be read in ${NS}"; exit 0; }

# ---- purgeBackups: every backup of the instance
if [[ "$PURGE" == "true" ]]; then
  total="$(jq '[.[] | select(.kind != "")] | length' <<<"$list")"
  if [[ "$DRY" == "true" ]]; then
    record "$key" SUCCEEDED DRY_RUN "would expire all ${total} backups of ${I} in ${NS}, newest first: $(jq -r '[.[] | select(.kind != "")] | reverse | map(.name) | join(", ")' <<<"$list"); blobs are not deleted"
    exit 0
  fi
  if backup_expire_all "$NS" "$I" "$TIMEOUT"; then
    detail="${BE_EXPIRED} of ${total} backups expired"
    [[ "$BE_SKIPPED" -eq 0 ]] || detail+=", ${BE_SKIPPED} without a pgBackRest label skipped"
    if [[ "${#BE_DECLINED[@]}" -gt 0 ]]; then
      d="$(printf '%s; ' "${BE_DECLINED[@]}" | sed 's/; $//')"
      record_entry "warning.${C}.${I}" WARNING BACKUP_EXPIRE_DECLINED "$d"
      record "$key" SUCCEEDED DECLINED_SOME "${detail}; pgBackRest declined ${#BE_DECLINED[@]}: ${d}"
    else
      record "$key" SUCCEEDED "" "$detail"
    fi
  else
    st=FAILED; reason=EXPIRE_FAILED
    printf '%s\n' "${BE_FAILED[@]}" | grep -q ' TIMEOUT ' && { st=TIMEOUT; reason=""; }
    record "$key" "$st" "$reason" "$(printf '%s; ' "${BE_FAILED[@]}" | sed 's/; $//') (${BE_EXPIRED} expired before)"
  fi
  exit 0
fi

# ---- backups: [..] - the plan: every named backup, its dependents
[[ "${#NAMED[@]}" -gt 0 ]] || { record "$key" FAILED INVALID_INPUT "no backups listed and purgeBackups is not true"; exit 0; }
bad=""
for b in "${NAMED[@]}"; do
  row="$(jq -c --arg n "$b" '.[] | select(.name == $n)' <<<"$list")"
  if [[ -z "$row" ]]; then
    bad+="${bad:+; }no PostgresBackup ${b} for ${I} in ${NS}"
  elif [[ "$(jq -r '.kind' <<<"$row")" == "" ]]; then
    bad+="${bad:+; }${b} has no pgBackRest label (phase $(jq -r '.phase // "none"' <<<"$row")): it never completed, there is nothing in the repository to expire"
  fi
done
if [[ -n "$bad" ]]; then
  reason=UNKNOWN_BACKUP; [[ "$bad" != *"no pgBackRest label"* ]] || reason=NOT_EXPIRABLE
  record "$key" FAILED "$reason" "${bad}. Backups of ${I}: $(jq -r 'map(.name) | join(", ")' <<<"$list")"
  exit 0
fi
declare -A WANT=()
for b in "${NAMED[@]}"; do WANT["$b"]=1; done
blocked=""
for b in "${NAMED[@]}"; do
  deps="$(backup_dependents "$NS" "$b")" || { record "$key" FAILED BACKUPS_UNREADABLE "the dependents of ${b} cannot be read"; exit 0; }
  missing=""
  for d in $deps; do [[ -n "${WANT[$d]:-}" ]] || missing+="${missing:+,}${d}"; done
  [[ -z "$missing" ]] || blocked+="${blocked:+; }${b} has dependents: ${missing}"
  if [[ "$INCLUDE" == "true" ]]; then for d in $deps; do WANT["$d"]=1; done; fi
done
if [[ -n "$blocked" && "$INCLUDE" != "true" ]]; then
  record "$key" BLOCKED HAS_DEPENDENTS "${blocked}. Expiring a backup expires the backups that depend on it; set includeDependents: true to expire them together, or list the dependents too. Nothing was expired"
  exit 0
fi
# the order: newest first (the list is oldest first), so dependents go before what they depend on
mapfile -t ORDER < <(jq -r --argjson w "$(printf '%s\n' "${!WANT[@]}" | jq -Rc '[., inputs]')" '[.[] | select(.name as $n | $w | index($n))] | reverse | .[].name' <<<"$list")
plan="$(printf '%s, ' "${ORDER[@]}" | sed 's/, $//')"
extra=$(( ${#ORDER[@]} - ${#NAMED[@]} ))
if [[ "$DRY" == "true" ]]; then
  record "$key" SUCCEEDED DRY_RUN "would expire ${#ORDER[@]} backups, newest first: ${plan}$([[ "$extra" -le 0 ]] || echo " (${extra} dependents included by includeDependents)")"
  exit 0
fi

# ---- expire, dependents first; stop at the first backup that pgBackRest declines or that gets no answer
done_n=0
for b in "${ORDER[@]}"; do
  backup_expire "$NS" "$b" "$TIMEOUT" || true
  case "$BACKUP_EXPIRE_OUTCOME" in
    EXPIRED|MISSING) done_n=$((done_n + 1)) ;;
    DECLINED)
      record "$key" FAILED BACKUP_EXPIRE_DECLINED "pgBackRest declined to expire ${b}: ${BACKUP_EXPIRE_DETAIL} (${done_n} expired before; the remaining $(( ${#ORDER[@]} - done_n - 1 )) were not attempted)"
      exit 0 ;;
    TIMEOUT)
      record "$key" TIMEOUT "" "${b}: ${BACKUP_EXPIRE_DETAIL} (${done_n} expired before)"
      exit 0 ;;
    *)
      record "$key" FAILED EXPIRE_FAILED "${b}: ${BACKUP_EXPIRE_DETAIL} (${done_n} expired before)"
      exit 0 ;;
  esac
done
record "$key" SUCCEEDED "" "${done_n} backups expired, newest first: ${plan}"
