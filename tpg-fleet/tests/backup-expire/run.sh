#!/usr/bin/env bash
# tpg-backup-expire (Round 23, locked decision 5): workflows/scripts/backup-expire.sh with the real
# lib.sh (backup_list, backup_dependents, backup_expire, backup_expire_all), clustermap.py and
# validate-params.sh, and stubs for the target cluster (kubectl: PostgresBackup objects; an expire
# is the patch spec.expire=true, and the stub plays the operator: it removes the backup and, for a full
# backup, the backups that depend on it; $TMP/decline.<name> makes it decline, $TMP/silent.<name> makes it
# stay silent) and for curl (it must never be called: tpg-backup-expire never deletes blobs).
#   expire named    one backup; a leaf of a chain
#   dependents      a backup with dependents is BLOCKED with the list (nothing is patched); all dependents
#                   named is not blocked; includeDependents expires the chain, newest first
#   purge all       every backup with a label, newest first; a backup without a label is skipped
#   dry run         the plan, nothing patched (BLOCKED is shown too)
#   declined        a named backup that pgBackRest declines fails the instance with the operator's message
#                   and stops; with purgeBackups a decline is reported (DECLINED_SOME, warning), not a failure
#   confirm         validate step: dryRun=false needs confirm = the cluster names of clusterMap
#   refused         backups together with purgeBackups: true; neither; includeDependents with purgeBackups
# LAB ITEM: how the real operator reports an expire is not known; _backup_expire_state (lib.sh) is the one
# place that reads it, and this suite pins what it does with the stub's answers.
# Requires: bash 4, python3, jq, yq (mikefarah); skipped without them.
# shellcheck disable=SC2015,SC2016
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
for t in python3 jq yq; do command -v "$t" >/dev/null || { echo "SKIP tests/backup-expire: $t not installed" >&2; exit 0; }; done
yq --version 2>&1 | grep -q mikefarah || { echo "SKIP tests/backup-expire: yq is not mikefarah yq v4" >&2; exit 0; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { printf 'ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL %s\n' "$1"; [[ -z "${2:-}" ]] || printf '%s\n' "$2" | sed 's/^/       | /' | tail -25; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------- the validate step
mkdir -p "$TMP/bin"
cat > "$TMP/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
if [[ "$*" == *"get secret -l tpg.fleet/cluster"* ]]; then
  printf '{"items":[%s]}' "$(for c in aks-tpg-poc-01 aks-tpg-poc-02; do printf '{"metadata":{"labels":{"tpg.fleet/cluster":"%s"}}},' "$c"; done | sed 's/,$//')"
fi
exit 0
STUB
chmod +x "$TMP/bin/kubectl"
sed -e "s#source /scripts/lib.sh#source $ROOT/workflows/scripts/lib.sh#" "$ROOT/workflows/scripts/validate-params.sh" > "$TMP/validate.sh"
vp() {  # vp VAR=VALUE... -> validate-params.sh backup-expire; output in $OUT, status in $RC
  rm -rf "$TMP/work"
  RC=0; OUT="$(cd "$TMP" && env -i PATH="$TMP/bin:$PATH" HOME="$TMP" TPG_WORK="$TMP/work" "$@" bash "$TMP/validate.sh" backup-expire 2>&1)" || RC=$?
}
valid() { [[ "$RC" -eq 0 ]] && ok "$1" || bad "$1" "$OUT"; }
invalid() {  # invalid LABEL TEXT...
  local t
  [[ "$RC" -ne 0 ]] || { bad "$1 (accepted)" "$OUT"; return; }
  for t in "${@:2}"; do grep -qF -- "$t" <<<"$OUT" || { bad "$1 (no '$t')" "$OUT"; return; }; done
  ok "$1"
}
MAP_NAMED='aks-tpg-poc-01:
  instances:
    orders-db:
      backups: [orders-db-full-1]
      includeDependents: true
aks-tpg-poc-02:
  instances:
    billing-db: {purgeBackups: true}'
vp P_CLUSTER_MAP="$MAP_NAMED" P_DRY_RUN=true
valid "validate: backups on one instance, purgeBackups on another, dryRun true (the default) needs no confirm"
vp P_CLUSTER_MAP="$MAP_NAMED" P_DRY_RUN=false P_CONFIRM='[aks-tpg-poc-01, aks-tpg-poc-02]'
valid "validate: dryRun=false with confirm = the cluster names of clusterMap"
vp P_CLUSTER_MAP="$MAP_NAMED" P_DRY_RUN=false P_CONFIRM='[aks-tpg-poc-01]'
invalid "validate: confirm that misses a cluster of clusterMap is refused" "confirm must repeat the cluster names of clusterMap ([aks-tpg-poc-01, aks-tpg-poc-02])"
vp P_CLUSTER_MAP="$MAP_NAMED" P_DRY_RUN=false P_CONFIRM='[aks-tpg-poc-01, aks-tpg-poc-02, aks-tpg-poc-03]'
invalid "validate: confirm with a cluster that is not in clusterMap is refused" "confirm must repeat the cluster names of clusterMap"
vp P_CLUSTER_MAP="$MAP_NAMED" P_DRY_RUN=false
invalid "validate: dryRun=false without confirm is refused" "confirm is mandatory with dryRun=false" "[aks-tpg-poc-01, aks-tpg-poc-02]"
vp P_CLUSTER_MAP="$MAP_NAMED" P_DRY_RUN=false P_CONFIRM='aks-tpg-poc-01,aks-tpg-poc-02'
invalid "validate: confirm as a comma string is refused (strict lists)" "is not a list"
vp P_CLUSTER_MAP='aks-tpg-poc-01:
  instances:
    orders-db: {backups: [orders-db-full-1], purgeBackups: true}' P_DRY_RUN=true
invalid "validate: backups together with purgeBackups: true is refused" "orders-db: backups and purgeBackups: true cannot be used together"
vp P_CLUSTER_MAP='aks-tpg-poc-01:
  instances:
    orders-db: {backups: [orders-db-full-1], purgeBackups: false}' P_DRY_RUN=true
valid "validate: backups with purgeBackups: false is fine (purgeBackups false means not set)"
vp P_CLUSTER_MAP='aks-tpg-poc-01:
  instances:
    orders-db: {includeDependents: true}' P_DRY_RUN=true
invalid "validate: an instance with neither backups nor purgeBackups is refused" "name the backups to expire"
vp P_CLUSTER_MAP='aks-tpg-poc-01:
  instances:
    orders-db: {purgeBackups: true, includeDependents: true}' P_DRY_RUN=true
invalid "validate: includeDependents with purgeBackups is refused" "includeDependents applies to backups"
vp P_CLUSTER_MAP='aks-tpg-poc-01:
  instances:
    orders-db: {backups: orders-db-full-1}' P_DRY_RUN=true
invalid "validate: backups as a string is refused with the list syntax" "orders-db.backups" "is not a list"
vp P_CLUSTER_MAP='aks-tpg-poc-01:
  instances:
    orders-db: {backups: [Orders_DB]}' P_DRY_RUN=true
invalid "validate: a backup name that is not a Kubernetes name is refused" "must be a Kubernetes object name"
vp P_CLUSTER_MAP='aks-tpg-poc-01:
  instances:
    orders-db: {backups: []}' P_DRY_RUN=true
invalid "validate: an empty backups list is refused" "the list is empty"
vp P_DRY_RUN=true
invalid "validate: no clusterMap is refused (clusterMap only)" "clusterMap is mandatory"
vp P_CLUSTER_MAP='aks-tpg-poc-09:
  instances:
    orders-db: {purgeBackups: true}' P_DRY_RUN=true
invalid "validate: a cluster that is not registered is refused" "aks-tpg-poc-09"
vp P_CLUSTER_MAP='aks-tpg-poc-01:
  instances:
    orders-db: {purgeBackups: true, finalBackup: "false"}' P_DRY_RUN=true
invalid "validate: a key of another workflow (finalBackup) is refused" "not used by tpg-backup-expire"
vp P_CLUSTER_MAP='aks-tpg-poc-01:
  instances:
    orders-db: {purgeBackups: true}' P_DRY_RUN=maybe
invalid "validate: dryRun must be true or false" "dryRun must be true or false"
vp P_CLUSTER_MAP='aks-tpg-poc-01: {}' P_DRY_RUN=true
invalid "validate: a cluster without instances is refused" "at least one instance"

# ---------------------------------------------------------------- backup-expire.sh
cat > "$TMP/backups.base.json" <<'JSON'
{"items": [
 {"metadata": {"name": "orders-full-1"},  "spec": {"sourceInstance": {"name": "orders-db"}, "type": "full"},         "status": {"phase": "Succeeded", "restoreLabel": "20260101-000000F"}},
 {"metadata": {"name": "orders-incr-1a"}, "spec": {"sourceInstance": {"name": "orders-db"}, "type": "incremental"},  "status": {"phase": "Succeeded", "restoreLabel": "20260101-000000F_20260102-000000I"}},
 {"metadata": {"name": "orders-diff-1"},  "spec": {"sourceInstance": {"name": "orders-db"}, "type": "differential"}, "status": {"phase": "Succeeded", "restoreLabel": "20260101-000000F_20260103-000000D"}},
 {"metadata": {"name": "orders-incr-1b"}, "spec": {"sourceInstance": {"name": "orders-db"}, "type": "incremental"},  "status": {"phase": "Succeeded", "restoreLabel": "20260101-000000F_20260104-000000I"}},
 {"metadata": {"name": "orders-full-2"},  "spec": {"sourceInstance": {"name": "orders-db"}, "type": "full"},         "status": {"phase": "Succeeded", "restoreLabel": "20260110-000000F"}},
 {"metadata": {"name": "orders-incr-2a"}, "spec": {"sourceInstance": {"name": "orders-db"}, "type": "incremental"},  "status": {"phase": "Succeeded", "restoreLabel": "20260110-000000F_20260111-000000I"}},
 {"metadata": {"name": "orders-failed"},  "spec": {"sourceInstance": {"name": "orders-db"}, "type": "full"},         "status": {"phase": "Failed"}},
 {"metadata": {"name": "billing-full-1"}, "spec": {"sourceInstance": {"name": "billing-db"}, "type": "full"},        "status": {"phase": "Succeeded", "restoreLabel": "20260101-000000F"}}
]}
JSON

cat > "$TMP/prelude.tmpl" <<'PRELUDE'
export TPG_WORK="@TMP@/work"
export CMAP_KEYS="@ROOT@/workflows/params/cluster-map-keys.yaml"
source "@ROOT@/workflows/scripts/lib.sh"
set +e
EV="@TMP@/events"
ev() { printf '%s\n' "$*" >> "$EV"; }
record() { printf '%s|%s|%s|%s\n' "$1" "$2" "${3:-}" "${4:-}" >> "@TMP@/records"; RESULT_RECORDED=1; }
record_entry() { printf '%s|%s|%s|%s\n' "$1" "$2" "${3:-}" "${4:-}" >> "@TMP@/records"; }
use_cluster() { CLUSTER="$1"; }
instance_ns() { case "$2" in billing-db) printf 'pg-billing-db' ;; *) printf 'pg-orders-db' ;; esac; }
pg_state() { [[ -f "@TMP@/notrunning" ]] && printf 'Failed' || printf 'Running'; }
busy_operations() { [[ -f "@TMP@/busy" ]] && printf 'postgresbackup ' || true; }
sleep() { :; }
curl() { ev "CURL $*"; return 1; }
# the target cluster: the PostgresBackup objects of $TMP/backups.json; an expire patch plays the operator
tk() {
  local args="$*" name
  case "$args" in
    *"get postgresbackup -o json"*) cat "@TMP@/backups.json" ;;
    *"get postgresbackup "*"--ignore-not-found"*)
      name="$(awk '{for (i = 1; i <= NF; i++) if ($i == "postgresbackup") { print $(i + 1); exit }}' <<<"$args")"
      jq -c --arg n "$name" '.items[] | select(.metadata.name == $n)' "@TMP@/backups.json" ;;
    *" patch postgresbackup "*)
      name="$(awk '{for (i = 1; i <= NF; i++) if ($i == "postgresbackup") { print $(i + 1); exit }}' <<<"$args")"
      ev "patch $name"
      if [[ -f "@TMP@/keep.$name" ]]; then   # the object already has spec.expire=true: the patch changes nothing, and the operator says nothing new
        jq '.' "@TMP@/backups.json" > "@TMP@/b.n"
      elif [[ -f "@TMP@/silent.$name" ]]; then
        jq --arg n "$name" '(.items[] | select(.metadata.name == $n) | .spec.expire) = true' "@TMP@/backups.json" > "@TMP@/b.n"
      elif [[ -f "@TMP@/decline.$name" ]]; then
        jq --arg n "$name" '(.items[] | select(.metadata.name == $n)) |= (.spec.expire = true | .status.conditions = [{type: "Expired", reason: "ExpireFailed", status: "False", message: "pgBackRest: unable to remove the latest full backup"}])' "@TMP@/backups.json" > "@TMP@/b.n"
      else
        # the operator expires the set: a full backup takes its differentials and incrementals along
        jq --arg n "$name" '([.items[] | select(.metadata.name == $n) | .status.restoreLabel][0] // "") as $l
          | .items |= map(select(.metadata.name != $n and (($l | endswith("F")) and ((.status.restoreLabel // "") | startswith($l + "_")) | not)))' "@TMP@/backups.json" > "@TMP@/b.n"
      fi
      mv "@TMP@/b.n" "@TMP@/backups.json" ;;
    *) return 0 ;;
  esac
}
PRELUDE
sed -e "s#@TMP@#$TMP#g" -e "s#@ROOT@#$ROOT#g" "$TMP/prelude.tmpl" > "$TMP/prelude.sh"
sed -e "s#source /scripts/lib.sh#source $TMP/prelude.sh#" "$ROOT/workflows/scripts/backup-expire.sh" > "$TMP/backup-expire.sh"

reset() { rm -rf "$TMP/work"; rm -f "$TMP"/silent.* "$TMP"/decline.* "$TMP"/keep.* "$TMP/notrunning" "$TMP/busy"; : > "$TMP/records"; : > "$TMP/events"; cp "$TMP/backups.base.json" "$TMP/backups.json"; }
run() {  # run MAP DRY [TIMEOUT] -> backup-expire.sh for orders-db; output in $OUT, status in $RC
  RC=0; OUT="$(P_CLUSTER_MAP="$1" bash "$TMP/backup-expire.sh" wf c1 orders-db "$2" "${3:-10}" 2>&1)" || RC=$?
}
rec() { grep -F "result.c1.orders-db|" "$TMP/records" | tail -n1 || true; }
patched() { grep '^patch ' "$TMP/events" | sed 's/^patch //' | paste -sd' ' -; }
left() { jq -r '[.items[] | select(.spec.sourceInstance.name == "orders-db") | .metadata.name] | join(" ")' "$TMP/backups.json"; }
mapof() { printf 'c1:\n  instances:\n    orders-db: %s\n' "$1"; }

# ---- the dependents of a backup (derived from the restore labels)
reset
# shellcheck disable=SC2030  # the subshell is on purpose (lib.sh is sourced in several subshells of this suite)
( export TPG_WORK="$TMP/work"; source "$TMP/prelude.sh"
  for b in orders-full-1 orders-incr-1a orders-diff-1 orders-incr-1b orders-full-2 orders-incr-2a orders-failed; do
    printf '%s=%s\n' "$b" "$(backup_dependents pg-orders-db "$b" | paste -sd' ' -)"
  done ) > "$TMP/deps.out" 2>&1
want='orders-full-1=orders-incr-1a orders-diff-1 orders-incr-1b
orders-incr-1a=
orders-diff-1=orders-incr-1b
orders-incr-1b=
orders-full-2=orders-incr-2a
orders-incr-2a=
orders-failed='
[[ "$(cat "$TMP/deps.out")" == "$want" ]] \
  && ok "backup_dependents: a full backup has every differential and incremental up to the next full; a differential the incrementals after it; an incremental taken before a differential none; a failed backup none" \
  || bad "dependents" "$(cat "$TMP/deps.out")"

# ---- expire named
reset
run "$(mapof '{backups: [orders-incr-2a]}')" false
[[ "$RC" -eq 0 && "$(patched)" == "orders-incr-2a" ]] && rec | grep -q "|SUCCEEDED||1 backups expired" \
  && [[ "$(left)" == "orders-full-1 orders-incr-1a orders-diff-1 orders-incr-1b orders-full-2 orders-failed" ]] \
  && ok "expire named: one incremental backup, spec.expire=true patched on it only; the operator removes it; SUCCEEDED" || bad "expire named" "$(cat "$TMP/events") $(cat "$TMP/records") $OUT"
grep -q 'wait expire of PostgresBackup orders-incr-2a: poll 1/1' <<<"$OUT" && grep -q 'PostgresBackup orders-incr-2a is gone' <<<"$OUT" \
  && ok "expire named: the wait is logged (poll, what the object says)" || bad "wait log" "$OUT"
! grep -q '^CURL' "$TMP/events" && ok "expire named: no blob is touched (curl was never called)" || bad "curl called" "$(cat "$TMP/events")"
reset
run "$(mapof '{backups: [orders-incr-1a, orders-incr-1b]}')" false
[[ "$(patched)" == "orders-incr-1b orders-incr-1a" ]] && ok "expire named: several backups go newest first" || bad "order of named" "$(patched) $(cat "$TMP/records")"

# ---- dependents: BLOCKED, listed; nothing patched
reset
run "$(mapof '{backups: [orders-full-1]}')" false
rec | grep -q '|BLOCKED|HAS_DEPENDENTS|orders-full-1 has dependents: orders-incr-1a,orders-diff-1,orders-incr-1b' && rec | grep -q 'set includeDependents: true' \
  && [[ -z "$(patched)" && "$(left)" == "orders-full-1 orders-incr-1a orders-diff-1 orders-incr-1b orders-full-2 orders-incr-2a orders-failed" ]] \
  && ok "dependents: a full backup with dependents is BLOCKED (HAS_DEPENDENTS) with the list and the fix; nothing is patched" || bad "blocked" "$(cat "$TMP/events") $(cat "$TMP/records")"
reset
run "$(mapof '{backups: [orders-diff-1]}')" false
rec | grep -q '|BLOCKED|HAS_DEPENDENTS|orders-diff-1 has dependents: orders-incr-1b' && [[ -z "$(patched)" ]] \
  && ok "dependents: a differential backup with an incremental after it is BLOCKED as well" || bad "blocked diff" "$(cat "$TMP/records")"
reset
run "$(mapof '{backups: [orders-full-2, orders-incr-2a]}')" false
rec | grep -q '|SUCCEEDED||2 backups expired' && [[ "$(patched)" == "orders-incr-2a orders-full-2" ]] \
  && ok "dependents: when every dependent is named too, nothing is blocked; dependents go first" || bad "all named" "$(cat "$TMP/events") $(cat "$TMP/records")"
reset
run "$(mapof '{backups: [orders-full-1], includeDependents: true}')" false
rec | grep -q '|SUCCEEDED||4 backups expired, newest first: orders-incr-1b, orders-diff-1, orders-incr-1a, orders-full-1' \
  && [[ "$(patched)" == "orders-incr-1b orders-diff-1 orders-incr-1a orders-full-1" && "$(left)" == "orders-full-2 orders-incr-2a orders-failed" ]] \
  && ok "includeDependents: the chain is expired newest first (incrementals, differential, then the full backup); the next chain is untouched" || bad "include" "$(cat "$TMP/events") $(cat "$TMP/records")"
reset
run "$(mapof '{backups: [orders-diff-1], includeDependents: true}')" false
[[ "$(patched)" == "orders-incr-1b orders-diff-1" ]] && ok "includeDependents: a differential with its incremental" || bad "include diff" "$(cat "$TMP/records")"

# ---- purge all
reset
run "$(mapof '{purgeBackups: true}')" false
rec | grep -q '|SUCCEEDED||6 of 6 backups expired, 1 without a pgBackRest label skipped' \
  && [[ "$(patched)" == "orders-incr-2a orders-full-2 orders-incr-1b orders-diff-1 orders-incr-1a orders-full-1" && "$(left)" == "orders-failed" ]] \
  && ok "purge all: every backup with a label, newest first; the failed backup (no label) is skipped; billing-db's backup is not touched" || bad "purge all" "$(cat "$TMP/events") $(cat "$TMP/records")"
jq -e '.items[] | select(.metadata.name == "billing-full-1")' "$TMP/backups.json" >/dev/null && ! grep -q '^CURL' "$TMP/events" \
  && ok "purge all: the backups of other instances stay and no blob is deleted (curl never called)" || bad "purge scope" "$(cat "$TMP/events")"

# ---- dry run changes nothing
reset
run "$(mapof '{backups: [orders-full-1], includeDependents: true}')" true
rec | grep -q '|SUCCEEDED|DRY_RUN|would expire 4 backups, newest first: orders-incr-1b, orders-diff-1, orders-incr-1a, orders-full-1 (3 dependents included by includeDependents)' \
  && [[ -z "$(patched)" ]] && cmp -s "$TMP/backups.json" "$TMP/backups.base.json" \
  && ok "dry run: the plan with the dependents; no patch, the objects are as they were" || bad "dry run" "$(cat "$TMP/events") $(cat "$TMP/records")"
reset
run "$(mapof '{backups: [orders-full-1]}')" true
rec | grep -q '|BLOCKED|HAS_DEPENDENTS|' && [[ -z "$(patched)" ]] && ok "dry run: a BLOCKED instance is shown as BLOCKED" || bad "dry run blocked" "$(cat "$TMP/records")"
reset
run "$(mapof '{purgeBackups: true}')" true
rec | grep -q '|SUCCEEDED|DRY_RUN|would expire all 6 backups of orders-db in pg-orders-db, newest first: orders-incr-2a, orders-full-2' && [[ -z "$(patched)" ]] && cmp -s "$TMP/backups.json" "$TMP/backups.base.json" \
  && ok "dry run: purgeBackups lists what it would expire; nothing patched" || bad "dry run purge" "$(cat "$TMP/records")"

# ---- what pgBackRest declines
reset
touch "$TMP/decline.orders-full-2"
run "$(mapof '{backups: [orders-full-2, orders-incr-2a]}')" false
rec | grep -q '|FAILED|BACKUP_EXPIRE_DECLINED|pgBackRest declined to expire orders-full-2: pgBackRest: unable to remove the latest full backup (1 expired before; the remaining 0 were not attempted)' \
  && ok "declined: a backup the user named that pgBackRest declines fails the instance with the operator's message" || bad "declined named" "$(cat "$TMP/events") $(cat "$TMP/records")"
reset
touch "$TMP/decline.orders-incr-1b"
run "$(mapof '{backups: [orders-full-1], includeDependents: true}')" false
rec | grep -q '|FAILED|BACKUP_EXPIRE_DECLINED|pgBackRest declined to expire orders-incr-1b' && [[ "$(patched)" == "orders-incr-1b" ]] \
  && rec | grep -q 'the remaining 3 were not attempted' \
  && ok "declined: a dependent that is declined stops the run; the backups it holds up are not attempted" || bad "declined dependent" "$(cat "$TMP/events") $(cat "$TMP/records")"
reset
touch "$TMP/decline.orders-full-2"
run "$(mapof '{purgeBackups: true}')" false
rec | grep -q '|SUCCEEDED|DECLINED_SOME|5 of 6 backups expired, 1 without a pgBackRest label skipped; pgBackRest declined 1: orders-full-2: pgBackRest: unable to remove the latest full backup' \
  && grep -q 'warning.c1.orders-db|WARNING|BACKUP_EXPIRE_DECLINED|orders-full-2' "$TMP/records" \
  && ok "declined with purgeBackups: reported (DECLINED_SOME and a warning with the operator's message), not a failure of the run" || bad "declined purge" "$(cat "$TMP/events") $(cat "$TMP/records")"
reset
touch "$TMP/silent.orders-incr-2a"
run "$(mapof '{backups: [orders-incr-2a]}')" false
rec | grep -q '|TIMEOUT||orders-incr-2a: no answer from the operator in 10s (phase Succeeded)' && ok "no answer from the operator: TIMEOUT with the phase" || bad "timeout" "$(cat "$TMP/records")"
reset
touch "$TMP/silent.orders-incr-2a"
run "$(mapof '{purgeBackups: true}')" false
rec | grep -q '|TIMEOUT||orders-incr-2a: TIMEOUT no answer from the operator' && [[ "$(patched)" == "orders-incr-2a" ]] \
  && ok "purge all: a backup that gets no answer is a TIMEOUT of the instance (the others are not attempted blindly)" || bad "purge timeout" "$(cat "$TMP/events") $(cat "$TMP/records")"

# ---- refusals
reset
run "$(mapof '{backups: [orders-nope]}')" false
rec | grep -q '|FAILED|UNKNOWN_BACKUP|no PostgresBackup orders-nope for orders-db in pg-orders-db. Backups of orders-db: orders-failed, orders-full-1' && [[ -z "$(patched)" ]] \
  && ok "refused: a backup that does not exist (UNKNOWN_BACKUP, the existing ones listed), nothing patched" || bad "unknown" "$(cat "$TMP/records")"
reset
run "$(mapof '{backups: [billing-full-1]}')" false
rec | grep -q '|FAILED|UNKNOWN_BACKUP|' && ok "refused: the backup of another instance is not found for this one" || bad "other instance" "$(cat "$TMP/records")"
reset
run "$(mapof '{backups: [orders-failed]}')" false
rec | grep -q '|FAILED|NOT_EXPIRABLE|orders-failed has no pgBackRest label (phase Failed)' && [[ -z "$(patched)" ]] && ok "refused: a backup that never completed has nothing to expire (NOT_EXPIRABLE)" || bad "no label" "$(cat "$TMP/records")"
reset
touch "$TMP/notrunning"
run "$(mapof '{purgeBackups: true}')" false
rec | grep -q '|FAILED|INSTANCE_NOT_RUNNING|' && [[ -z "$(patched)" ]] && ok "refused: the instance is not Running (the operator cannot expire)" || bad "not running" "$(cat "$TMP/records")"
reset
touch "$TMP/busy"
run "$(mapof '{purgeBackups: true}')" false
rec | grep -q '|FAILED|OPERATION_IN_PROGRESS|postgresbackup' && [[ -z "$(patched)" ]] && ok "refused: a backup or restore is running on the instance (OPERATION_IN_PROGRESS)" || bad "busy" "$(cat "$TMP/records")"
reset
touch "$TMP/silent.orders-incr-2a"
run "$(mapof '{backups: [orders-incr-2a]}')" false 40
grep -q 'wait expire of PostgresBackup orders-incr-2a: gave up' <<<"$OUT" && grep -q 'poll 4/4' <<<"$OUT" \
  && ok "the wait is timeoutSeconds / 10 polls, each logged" || bad "poll count" "$OUT"

# ---- _backup_expire_state trusts only conditions the operator wrote for the current generation of the object
state() { printf '%s' "$1" | ( source "$TMP/prelude.sh"; _backup_expire_state ); }
OLD_FALSE='{"metadata":{"generation":2},"spec":{"expire":true},"status":{"phase":"Succeeded","conditions":[{"type":"Expired","status":"False","reason":"ExpireFailed","message":"old refusal","observedGeneration":1}]}}'
NEW_FALSE='{"metadata":{"generation":2},"spec":{"expire":true},"status":{"phase":"Succeeded","conditions":[{"type":"Expired","status":"False","reason":"ExpireFailed","message":"fresh refusal","observedGeneration":2}]}}'
NEW_TRUE='{"metadata":{"generation":2},"spec":{"expire":true},"status":{"phase":"Succeeded","conditions":[{"type":"Expired","status":"True","observedGeneration":2}]}}'
NO_GEN='{"metadata":{"generation":2},"spec":{"expire":true},"status":{"phase":"Succeeded","conditions":[{"type":"Expired","status":"False","reason":"ExpireFailed","message":"no generation"}]}}'
[[ "$(state "$OLD_FALSE")" == PENDING ]] && ok "expire state: an Expired=False condition of an older generation (observedGeneration 1, object at 2) is not read as DECLINED" || bad "stale false" "$(state "$OLD_FALSE")"
[[ "$(state "$NEW_FALSE")" == "DECLINED fresh refusal" ]] && ok "expire state: the same condition for the current generation is DECLINED with the operator's message" || bad "fresh false" "$(state "$NEW_FALSE")"
[[ "$(state "$NEW_TRUE")" == EXPIRED ]] && ok "expire state: Expired=True for the current generation is EXPIRED" || bad "fresh true" "$(state "$NEW_TRUE")"
[[ "$(state "$NO_GEN")" == PENDING ]] && ok "expire state: a condition without observedGeneration on an object at generation 2 is not trusted" || bad "no observedGeneration" "$(state "$NO_GEN")"
[[ "$(state '{"metadata":{"generation":2},"status":{"phase":"Expired","conditions":[{"type":"Expired","status":"False","observedGeneration":1}]}}')" == EXPIRED ]] \
  && ok "expire state: the phase Expired is EXPIRED whatever an older condition says" || bad "phase expired"
reset
jq '(.items[] | select(.metadata.name == "orders-incr-2a")) |= (.spec.expire = true | .metadata.generation = 2 | .status.conditions = [{type: "Expired", reason: "ExpireFailed", status: "False", message: "old refusal", observedGeneration: 1}])' "$TMP/backups.base.json" > "$TMP/backups.json"
touch "$TMP/keep.orders-incr-2a"
run "$(mapof '{backups: [orders-incr-2a]}')" false
rec | grep -q '|TIMEOUT||orders-incr-2a: no answer from the operator' && ! rec | grep -q 'DECLINED' \
  && ok "a re-run where spec.expire is already true and the only Expired=False is from an older generation waits and times out like a normal expire (not DECLINED)" || bad "re-run stale decline" "$(cat "$TMP/records")"
reset
jq '(.items[] | select(.metadata.name == "orders-incr-2a")) |= (.spec.expire = true | .metadata.generation = 2 | .status.conditions = [{type: "Expired", reason: "ExpireFailed", status: "False", message: "fresh refusal", observedGeneration: 2}])' "$TMP/backups.base.json" > "$TMP/backups.json"
touch "$TMP/keep.orders-incr-2a"
run "$(mapof '{backups: [orders-incr-2a]}')" false
rec | grep -q '|FAILED|BACKUP_EXPIRE_DECLINED|pgBackRest declined to expire orders-incr-2a: fresh refusal' \
  && ok "a re-run whose Expired=False is for the current generation is DECLINED with the message" || bad "re-run fresh decline" "$(cat "$TMP/records")"

# ---- busy_operations: an expired object the operator keeps is not an unfinished operation
busy_of() {  # busy_of BACKUP_ITEMS_JSON [RESTORE_ITEMS_JSON] -> busy_operations output
  ( export BK="$1" RS="${2:-[]}"; source "$ROOT/workflows/scripts/lib.sh"; WORK="$TMP/work-busy"
    instance_ns() { printf 'pg-orders-db'; }
    CLUSTER=c1
    tk() { case "$*" in *"get postgresbackup -o json"*) printf '{"items":%s}' "$BK" ;; *"get postgresrestore -o json"*) printf '{"items":%s}' "$RS" ;; *) printf '{"items":[]}' ;; esac; }
    busy_operations orders-db )
}
BKP() { printf '[{"metadata":{"name":"b"},"spec":%s,"status":{"phase":"%s"}}]' "$1" "$2"; }
[[ -z "$(busy_of "$(BKP '{"expire":true}' Expired)")" ]] && ok "busy_operations: a PostgresBackup with spec.expire=true in the phase Expired is not busy" || bad "busy expired" "$(busy_of "$(BKP '{"expire":true}' Expired)")"
[[ -z "$(busy_of "$(BKP '{"expire":true}' Expiring)")" ]] && ok "busy_operations: spec.expire=true in the phase Expiring is not busy (the operator kept the object)" || bad "busy expiring"
[[ -z "$(busy_of "$(BKP '{"expire":true}' Running)")" ]] && ok "busy_operations: any PostgresBackup with spec.expire=true is left out of the running set" || bad "busy expire true"
[[ -z "$(busy_of "$(BKP '{}' Expired)")" ]] && ok "busy_operations: the phase Expired is finished even without spec.expire" || bad "busy phase expired"
[[ "$(busy_of "$(BKP '{}' Running)")" == "postgresbackup " ]] && ok "busy_operations: a running backup without spec.expire is still busy" || bad "busy running" "$(busy_of "$(BKP '{}' Running)")"
[[ "$(busy_of "$(BKP '{"expire":true}' Expired)" '[{"metadata":{"name":"r"},"status":{"phase":"Running"}}]')" == "postgresrestore " ]] \
  && ok "busy_operations: an expired backup does not hide a running restore" || bad "busy restore" "$(busy_of "$(BKP '{"expire":true}' Expired)" '[{"metadata":{"name":"r"},"status":{"phase":"Running"}}]')"

# ---- repo_shared fails closed: only a definite "no such resource" means a cluster has no locations
rs() {  # rs CRD LIST -> repo_shared for c1/ns/i-backup-location against c2; CRD: ok|timeout|notfound, LIST: ok|garbage|noresource|forbidden|noitems|shared. Prints SHARED:<with> or NOT_SHARED
  ( export CRD="$1" LIST="$2"; source "$ROOT/workflows/scripts/lib.sh"; WORK="$TMP/work-rs"
    use_cluster() { CLUSTER="$1"; }
    registered_clusters() { printf 'c1\nc2\n'; }
    _secret_account() { printf 'acct1'; }
    tk() {
      case "$*" in
        *"get crd postgresbackuplocations"*)
          if [[ "$CLUSTER" == c2 ]]; then
            case "$CRD" in
              timeout) echo "Unable to connect to the server: net/http: request canceled (Client.Timeout exceeded)" >&2; return 1 ;;
              notfound) echo 'Error from server (NotFound): customresourcedefinitions.apiextensions.k8s.io "postgresbackuplocations.sql.tanzu.vmware.com" not found' >&2; return 1 ;;
            esac
          fi
          return 0 ;;
        *readyz*) return 0 ;;
        *"get postgresbackuplocation -A -o json"*)
          if [[ "$CLUSTER" == c2 ]]; then
            case "$LIST" in
              garbage) echo '<html>502 Bad Gateway</html>'; return 0 ;;
              noitems) echo '{"kind":"Status"}'; return 0 ;;
              noresource) echo 'error: the server doesn'"'"'t have a resource type "postgresbackuplocation"' >&2; return 1 ;;
              forbidden) echo 'Error from server (Forbidden): postgresbackuplocations is forbidden' >&2; return 1 ;;
              shared) echo '{"items":[{"metadata":{"namespace":"t","name":"copy"},"spec":{"storage":{"azure":{"container":"pg","repoPath":"/ns/i"}}}}]}'; return 0 ;;
              *) echo '{"items":[]}'; return 0 ;;
            esac
          fi
          echo '{"items":[{"metadata":{"namespace":"ns","name":"i-backup-location"},"spec":{"storage":{"azure":{"container":"pg","repoPath":"/ns/i"}}}}]}' ;;
      esac
    }
    set +e
    if repo_shared c1 ns i-backup-location pg /ns/i blob.core.windows.net acct1; then echo "SHARED:$REPO_SHARED_WITH"; else echo NOT_SHARED; fi )
}
r="$(rs timeout ok)"; [[ "$r" == SHARED:*"cluster c2"*"not scanned"* ]] \
  && ok "repo_shared: a failing CRD lookup (a timeout) followed by an OK /readyz marks the cluster not scanned: shared" || bad "crd timeout" "$r"
r="$(rs notfound ok)"; [[ "$r" == NOT_SHARED ]] && ok "repo_shared: NotFound for the CRD means no locations there (not shared)" || bad "crd notfound" "$r"
r="$(rs ok garbage)"; [[ "$r" == SHARED:*"cluster c2"*"not scanned"* ]] && ok "repo_shared: a location list jq cannot parse marks the cluster not scanned: shared" || bad "garbage list" "$r"
r="$(rs ok noitems)"; [[ "$r" == SHARED:*"cluster c2"*"not scanned"* ]] && ok "repo_shared: an answer without an items list is not a list of zero locations: shared" || bad "no items" "$r"
r="$(rs ok noresource)"; [[ "$r" == NOT_SHARED ]] && ok "repo_shared: 'the server doesn't have a resource type' for the list means none there" || bad "no resource type" "$r"
r="$(rs ok forbidden)"; [[ "$r" == SHARED:*"cluster c2"*"not scanned"* ]] && ok "repo_shared: any other error of the list (Forbidden) is not scanned: shared" || bad "forbidden" "$r"
r="$(rs ok ok)"; [[ "$r" == NOT_SHARED ]] && ok "repo_shared: a readable cluster with no other location on the repository is not shared" || bad "clean" "$r"
r="$(rs ok shared)"; [[ "$r" == "SHARED:c2/t/copy (/ns/i)" ]] && ok "repo_shared: a location on the repository of another cluster is named" || bad "named" "$r"

# ---- the template, the script and the wiring
yq -e '.spec.arguments.parameters[] | select(.name == "dryRun") | .value == "true"' "$ROOT/workflows/templates/tpg-backup-expire.yaml" >/dev/null \
  && ok "the template: dryRun defaults to true" || bad "template dryRun default"
[[ "$(yq '[.spec.arguments.parameters[].name] | sort | join(",")' "$ROOT/workflows/templates/tpg-backup-expire.yaml")" == "clusterMap,confirm,dryRun,timeoutSeconds,toolsImage" ]] \
  && ok "the template takes clusterMap, dryRun, confirm, timeoutSeconds, toolsImage (clusterMap only: no clusters or instances input)" || bad "template inputs"
grep -q 'templates/tpg-backup-expire.yaml' "$ROOT/workflows/kustomization.yaml" && grep -q 'scripts/backup-expire.sh' "$ROOT/workflows/kustomization.yaml" \
  && ok "kustomization.yaml has the template and the script" || bad "kustomization"
yq -e '.spec.templates[] | select(.name == "main") | .steps[][] | select(.name == "gate") | .templateRef.template == "blocked-gate"' "$ROOT/workflows/templates/tpg-backup-expire.yaml" >/dev/null \
  && ok "the template ends with the blocked-gate step (a BLOCKED instance ends the run Failed after the others ran)" || bad "gate"
yq -e '.spec.templates[] | select(.name == "expire-instance") | .synchronization.mutexes[0].name | test("tpg-instance-")' "$ROOT/workflows/templates/tpg-backup-expire.yaml" >/dev/null \
  && ok "expire-instance holds the same mutex as tpg-delete-instance" || bad "mutex"
! grep -qE 'blob_|curl' "$ROOT/workflows/scripts/backup-expire.sh" && ok "backup-expire.sh has no blob code (blobs are deleted only by purgeBackups of the delete workflows)" || bad "blob code in backup-expire.sh"

echo
echo "backup-expire: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
