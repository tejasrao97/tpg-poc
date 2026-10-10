#!/usr/bin/env bash
# delete-apps.sh WORKFLOW_NAME CLUSTER
# tpg-delete-apps, one cluster. Applications for the cluster come from clusterMap
# (P_CLUSTER_MAP: deleteOperator and force per cluster, the instances listed, and
# finalBackup, purgePvcs and purgeNamespace per instance), or from P_APPS (JSON map):
#   tpg-instances                     every Postgres instance on the cluster
#   tpg-instances:<i>                 one selected instance (one element per instance, Round 23)
#   tpg-operator                      the Tanzu Postgres operator and its CRDs:
#     postgres, postgresbackups, postgresbackuplocations, postgresbackupschedules,
#     postgresferretdocumentdbs, postgresmigrations, postgresrestores, postgresversions,
#     postgresversionupgrades (.sql.tanzu.vmware.com)
#
# Order: instances (delete-instance.sh: final backup, fleet.yaml removal, CR delete, optional
# PVC and namespace purge) -> remaining Tanzu Postgres custom resources -> operator
# (fleet.yaml, Application, leftover cluster-scoped objects, namespace) -> CRDs.
# Guard: the operator is not removed while Postgres instances that are not part of this run
# exist, or while a backup, restore or upgrade is running, unless P_FORCE=true, which deletes
# those instances too.
# P_DRY_RUN=true records the plan and changes nothing. The Azure Blob backup repository is
# never deleted.
# Namespaces (Round 23): an instance's namespace is instance.namespace of its entry in
# clusters/fleet.yaml (default pg-<instance>; the audit copy in clusters/deleted when the entry is gone,
# lib.sh instance_ns_known); "its own namespace" below means that one. A live Postgres outside the
# namespace of its entry or copy is not an instance of tpg-instances: it is left alone and reported
# (warning POSTGRES_SKIPPED; tpg-instances:<name> selects it only when no entry and no audit copy names
# another namespace and the name runs in one namespace; the warning says which case it is, and otherwise
# in which namespace to delete it by hand). purgeNamespace
# on an instance whose namespace another instance outside this run still uses is refused
# (NAMESPACE_SHARED, nothing changes), and so is purgeNamespace=true for one instance of a namespace
# when another instance of the run in it has purgeNamespace=false; instances of the run that share a
# namespace and all purge it are deleted first and the namespace goes after the last of them. With
# deleteOperator the run removes everything: the namespaces purged are deleted after the last instance
# of them whoever else was there. The owner of the shared Secrets of a namespace hands them over to an
# instance that stays (never to one of the run).
# Environment: P_APPS P_DRY_RUN P_PURGE_PVCS P_PURGE_NS P_FORCE P_FORCE_DELETE_STUCK P_FINAL_BACKUP P_TIMEOUT
#              PUSH_MODE PR_TIMEOUT_SECONDS
WF="$1"; C="$2"
# shellcheck source=workflows/scripts/lib.sh
source /scripts/lib.sh
export PUSH_MODE="${PUSH_MODE:-direct}"

DRY="${P_DRY_RUN:-true}"; FORCE="${P_FORCE:-false}"; TIMEOUT="${P_TIMEOUT:-1800}"
KINDS="postgresferretdocumentdbs postgresbackupschedules postgresbackups postgresbackuplocations postgresrestores postgresversionupgrades postgresmigrations"
failed=0
cfail() { record "result.${C}.$1" FAILED "$2" "${3:-}"; failed=1; }
result_guard "result.${C}"

if cmap_set; then
  # the same application list, built from the map entry of the cluster
  apps="$(jq -cn --arg op "$(cmap_cval "$C" deleteOperator false)" --arg inst "$(cmap_instances "$C" | paste -sd,)" \
    '($inst | split(",") | map(select(length > 0) | "tpg-instances:" + .)) + (if $op == "true" then ["tpg-operator"] else [] end)')"
  FORCE="$(cmap_cval "$C" force "$FORCE")"
  export DELETE_FROM_MAP=true
else
  apps="$(jq -c --arg c "$C" '.[$c] // []' <<<"$P_APPS")"
fi
DELETE_OPERATOR=false; ALL_INSTANCES=false; SELECTED=""
while read -r a; do
  case "$a" in
    tpg-operator) DELETE_OPERATOR=true ;;
    tpg-instances|tpg-instances:all) ALL_INSTANCES=true ;;
    tpg-instances:*) SELECTED="$(printf '%s\n%s' "$SELECTED" "${a#tpg-instances:}")" ;;
  esac
done < <(jq -r '.[]' <<<"$apps")

use_cluster "$C" || { cfail cluster NOT_REGISTERED; exit 1; }
tk get --raw=/readyz >/dev/null 2>&1 || { cfail cluster UNREACHABLE "API server not reachable from the hub"; exit 1; }
REPO="$WORK/repo"
git_clone "$REPO"
declared="$(fleet_instances "$REPO" "$C")"
has_crd=false; tk get crd postgres.sql.tanzu.vmware.com >/dev/null 2>&1 && has_crd=true
live="[]"
[[ "$has_crd" == "true" ]] && live="$(tk get postgres -A -o json | jq -c '[.items[]? | {name: .metadata.name, namespace: .metadata.namespace}]')"
# the namespace each live instance should be in: its entry in clusters/fleet.yaml (default pg-<instance>),
# else the audit copy of a deleted entry in clusters/deleted (exactly <instance>-<yyyymmddHHMM>.yaml)
live="$(while read -r row; do
    [[ -n "$row" ]] || continue
    jq -c --arg e "$(instance_ns_known "$REPO" "$C" "$(jq -r .name <<<"$row")")" '. + {expected: $e}' <<<"$row"
  done < <(jq -c '.[]' <<<"$live") | jq -sc '.')"
live_names="$(jq -r '.[].name' <<<"$live")"

# ---- targets
targets=""
if [[ "$ALL_INSTANCES" == "true" ]]; then
  targets="$(printf '%s\n%s\n' "$declared" "$(jq -r '.[] | select(.namespace == .expected) | .name' <<<"$live")" | grep -v '^$' | sort -u || true)"
  # a Postgres outside the namespace of its entry or audit copy is not one of ours: left alone, and said so.
  # tpg-instances:<name> reaches it only when nothing records another namespace for the name (no entry, no
  # audit copy) and it runs in one namespace only (delete-instance.sh gone_instance_ns); otherwise the
  # message says it has to be deleted by hand, and where
  while read -r row; do
    [[ -n "$row" ]] || continue
    n="$(jq -r .name <<<"$row")"; rns="$(jq -r .namespace <<<"$row")"; rexp="$(jq -r .expected <<<"$row")"
    rsrc="$(instance_ns_source "$REPO" "$C" "$n")"
    rall="$(jq -r --arg n "$n" '[.[] | select(.name == $n) | .namespace] | sort | join(", ")' <<<"$live")"
    why="Postgres ${rns}/${n} is not in the namespace its fleet.yaml entry or audit copy gives (${rexp}), so tpg-instances leaves it alone"
    case "$rsrc" in
      entry) fix="; the entry in ${FLEET_REL} says ${rexp}, so tpg-instances:${n} cannot reach it: delete it by hand in namespace ${rns} (kubectl -n ${rns} delete postgres ${n})" ;;
      copy)  fix="; the audit copy in clusters/deleted/${C} says ${rexp}, so tpg-instances:${n} cannot reach it (NAMESPACE_MISMATCH): delete it by hand in namespace ${rns} (kubectl -n ${rns} delete postgres ${n}) if it is not the deleted instance" ;;
      *)     if [[ "$rall" == *,* ]]; then
               fix="; ${n} runs in ${rall}, so tpg-instances:${n} refuses it (NAMESPACE_AMBIGUOUS): delete it by hand in namespace ${rns} (kubectl -n ${rns} delete postgres ${n})"
             else
               fix="; select it with tpg-instances:${n} to delete it"
             fi ;;
    esac
    record_entry "warning.${C}.${rns}.${n}" WARNING POSTGRES_SKIPPED "${why}${fix}"
  done < <(jq -c '.[] | select(.namespace != .expected)' <<<"$live")
else
  while read -r i; do
    [[ -n "$i" ]] || continue
    if grep -Fqx -- "$i" <<<"$declared" || grep -Fqx -- "$i" <<<"$live_names"; then
      targets="$(printf '%s\n%s' "$targets" "$i")"
    else
      cfail "$i" UNKNOWN_INSTANCE "not declared in ${FLEET_REL} and no Postgres ${i} on ${C}"
    fi
  done < <(sort -u <<<"$SELECTED")
  targets="$(grep -v '^$' <<<"$targets" | sort -u || true)"
fi

foreign="[]"   # Postgres CRs that block the operator removal
if [[ "$DELETE_OPERATOR" == "true" && "$has_crd" == "true" ]]; then
  foreign="$(jq -c --arg t "$targets" '($t | split("\n")) as $tl | [.[] | select(.namespace != .expected or ((.name as $n | $tl | index($n)) | not))]' <<<"$live")"
  busy="$(for k in postgresbackups postgresrestores postgresversionupgrades; do
      tk get "$k" -A -o json 2>/dev/null | jq -r --arg k "$k" '.items[]? | select((.status.phase // "") | test("^(Succeeded|Failed|PreCheckFailed)$") | not) | $k + ":" + .metadata.namespace + "/" + .metadata.name'
    done)"
  if [[ -n "$busy" && "$FORCE" != "true" ]]; then
    cfail operator OPERATION_IN_PROGRESS "$(paste -sd' ' <<<"$busy"); wait or set force=true"
  fi
  if [[ "$(jq 'length' <<<"$foreign")" -gt 0 ]]; then
    if [[ "$FORCE" == "true" ]]; then
      targets="$(printf '%s\n%s\n' "$targets" "$(jq -r '.[] | select(.namespace == .expected) | .name' <<<"$foreign")" | grep -v '^$' | sort -u || true)"
      foreign="$(jq -c '[.[] | select(.namespace != .expected)]' <<<"$foreign")"
    else
      cfail operator CRS_EXIST "Postgres instances not in this run: $(jq -r 'map(.namespace + "/" + .name) | join(" ")' <<<"$foreign"); add them to apps or set force=true"
    fi
  fi
fi
# purgeNamespace, refused before anything changes (NAMESPACE_SHARED):
#   - on a namespace that instances outside this run still use (deleteOperator removes everything, so it
#     is allowed there)
#   - when instances of the run share the namespace and not every one of them has purgeNamespace=true:
#     the namespace is deleted once, after the last of them, and would take the PVCs of the one that
#     keeps them (purgePvcs=false, purgeNamespace=false); with deleteOperator as well
for i in $targets; do
  [[ "$(cmap_ival "$C" "$i" purgeNamespace "${P_PURGE_NS:-}")" == "true" ]] || continue
  ins="$(instance_ns_known "$REPO" "$C" "$i")"
  keeps=""
  for j in $targets; do
    [[ "$j" != "$i" && "$(instance_ns_known "$REPO" "$C" "$j")" == "$ins" ]] || continue
    [[ "$(cmap_ival "$C" "$j" purgeNamespace "${P_PURGE_NS:-}")" == "true" ]] || keeps="${keeps:+${keeps} }${j}"
  done
  if [[ -n "$keeps" ]]; then
    cfail "$i" NAMESPACE_SHARED "purgeNamespace=true would delete namespace ${ins}, which ${keeps// /, } also use(s) in this run with purgeNamespace=false (their PVCs are meant to stay); set purgeNamespace=true for ${keeps// /, } too, or false for ${i}"
    continue
  fi
  [[ "$DELETE_OPERATOR" != "true" ]] || continue
  stay="$(for o in $( { fleet_ns_members "$REPO" "$C" "$ins"; jq -r --arg ns "$ins" '.[] | select(.namespace == $ns) | .name' <<<"$live"; } | sort -u); do
      grep -Fqx -- "$o" <<<"$targets" || printf '%s ' "$o"
    done)"
  stay="${stay% }"
  [[ -z "$stay" ]] || cfail "$i" NAMESPACE_SHARED "purgeNamespace=true would delete namespace ${ins}, which ${stay// /, } also use(s) and which this run does not delete; delete them too, or set purgeNamespace=false for ${i}"
done
[[ "$failed" -eq 0 ]] || exit 1

crds="$(tk get crd -o name 2>/dev/null | sed 's#^customresourcedefinition.apiextensions.k8s.io/##' | grep '\.sql\.tanzu\.vmware\.com$' || true)"

# ---- dry run
if [[ "$DRY" == "true" ]]; then
  for i in $targets; do
    in_git="no"; grep -Fqx -- "$i" <<<"$declared" && in_git="yes"
    record "result.${C}.${i}" SUCCEEDED DRY_RUN "would delete Postgres ${i} (fleet.yaml entry: ${in_git}; finalBackup=$(cmap_ival "$C" "$i" finalBackup "${P_FINAL_BACKUP:-true}"), purgePvcs=$(cmap_ival "$C" "$i" purgePvcs "${P_PURGE_PVCS:-}"), purgeNamespace=$(cmap_ival "$C" "$i" purgeNamespace "${P_PURGE_NS:-}"))"
  done
  if [[ "$DELETE_OPERATOR" == "true" ]]; then
    record "result.${C}.operator" SUCCEEDED DRY_RUN "would delete tpg-${C}-operator, namespace tanzu-postgres-operator$( [[ "$(jq 'length' <<<"$foreign")" -gt 0 ]] && printf ', Postgres CRs outside their own namespace: %s' "$(jq -r 'map(.namespace + "/" + .name) | join(" ")' <<<"$foreign")" ) and CRDs: $(paste -sd' ' <<<"${crds:-none}")"
  fi
  exit 0
fi

# ---- instances
# DELETE_RUN_INSTANCES: the instances of this run leave together, so a namespace they share is deleted
# after the last of them (delete-instance.sh defers it into NS_PURGE_FILE; DELETE_OPERATOR_RUN: everything goes)
DELETE_RUN_INSTANCES="$(paste -sd' ' <<<"$targets")"
export DELETE_RUN_INSTANCES DELETE_OPERATOR_RUN="$DELETE_OPERATOR" NS_PURGE_FILE="$WORK/ns-purge"
: > "$NS_PURGE_FILE"
instance_failed=0
for i in $targets; do
  ALLOW_UNTRACKED=true bash /scripts/delete-instance.sh "$WF" "$C" "$i" "$i" "${P_FINAL_BACKUP:-true}" "$P_PURGE_PVCS" "$P_PURGE_NS" "$TIMEOUT" \
    || instance_failed=1
done
[[ "$instance_failed" -eq 0 ]] || failed=1
# namespaces purged by instances of a shared namespace, now that the last of them is gone
if [[ "$instance_failed" -eq 0 ]]; then
  while read -r ns; do
    [[ -n "$ns" ]] || continue
    tk get namespace "$ns" >/dev/null 2>&1 || continue   # the last instance of it deleted it already
    if tk delete namespace "$ns" --ignore-not-found --wait=true --timeout=600s >/dev/null; then
      record_entry "result.${C}.namespace-${ns}" SUCCEEDED "" "namespace ${ns} deleted after the last instance of it"
    else
      cfail "namespace-${ns}" NAMESPACE_DELETE_FAILED "$ns"
    fi
  done < <(sort -u "$NS_PURGE_FILE")
fi
[[ "$DELETE_OPERATOR" == "true" ]] || exit "$failed"
if [[ "$instance_failed" -ne 0 ]]; then
  cfail operator BLOCKED_BY_INSTANCE_FAILURES "the operator stays until every instance is deleted"
  exit 1
fi

ofail() { cfail operator "$1" "${2:-}"; exit 1; }
notes=()

# ---- remaining Tanzu Postgres custom resources (operator still running, so finalizers complete)
for f in $(jq -c '.[]' <<<"$foreign"); do
  tk -n "$(jq -r .namespace <<<"$f")" delete postgres "$(jq -r .name <<<"$f")" --wait=true --timeout="${TIMEOUT}s" >/dev/null \
    || ofail DELETE_TIMEOUT "postgres $(jq -r '.namespace + "/" + .name' <<<"$f")"
  notes+=("force-deleted postgres $(jq -r '.namespace + "/" + .name' <<<"$f")")
done
if [[ "$has_crd" == "true" ]]; then
  for k in $KINDS; do
    n="$(tk get "$k" -A -o json 2>/dev/null | jq '(.items // []) | length' || echo 0)"
    [[ "${n:-0}" -gt 0 ]] || continue
    tk delete "$k" -A --all --wait=true --timeout=300s >/dev/null 2>&1 || true
    notes+=("${n} ${k}")
  done
fi

# ---- Git: remove the operator (and the cluster entry when it has no instances left)
git_clone "$REPO"
if fleet_has_cluster "$REPO" "$C"; then
  C="$C" yq -i 'del(.clusters[strenv(C)].operator) |
    del(.clusters[strenv(C)] | select((.instances // {}) | length == 0))' "$REPO/$FLEET_REL"
  git_commit_push "$REPO" "delete operator on ${C} (${WF})" "$FLEET_REL" || ofail GIT_PUSH_FAILED "pushMode=${PUSH_MODE}"
fi
app="tpg-${C}-operator"
appset_refresh tpg-operator
app_removed_or_force "$app" "${P_FORCE_DELETE_STUCK:-true}" || ofail APPLICATION_NOT_REMOVED "$app still exists (stuck: $(app_stuck_reason "$app" || true))"
[[ -z "$FORCED_NOTE" ]] || notes+=("$FORCED_NOTE")

# ---- leftovers of the operator Application (cluster-scoped objects, namespace)
for r in $(tk api-resources --namespaced=false --verbs=list,delete -o name 2>/dev/null | grep -v '^customresourcedefinitions'); do
  for o in $(tk get "$r" -o json 2>/dev/null | jq -r --arg a "tpg-${C}-operator:" \
      '.items[]? | select((.metadata.annotations["argocd.argoproj.io/tracking-id"] // "") | startswith($a)) | .metadata.name'); do
    tk delete "$r" "$o" --ignore-not-found --wait=false >/dev/null && notes+=("${r}/${o}")
  done
done
tk delete namespace tanzu-postgres-operator --ignore-not-found --wait=true --timeout=600s >/dev/null \
  || ofail NAMESPACE_DELETE_FAILED tanzu-postgres-operator

# ---- CRDs
crds="$(tk get crd -o name 2>/dev/null | sed 's#^customresourcedefinition.apiextensions.k8s.io/##' | grep '\.sql\.tanzu\.vmware\.com$' || true)"
for crd in $crds; do
  if ! tk delete crd "$crd" --wait=true --timeout=300s >/dev/null 2>&1; then
    # The operator is gone: clear finalizers on objects that still block the CRD
    kind="${crd%%.*}"
    for o in $(tk get "$kind" -A -o json 2>/dev/null | jq -r '.items[]? | (.metadata.namespace // "") + "/" + .metadata.name'); do
      ns="${o%%/*}"; name="${o#*/}"
      nsarg=(); [[ -z "$ns" ]] || nsarg=(-n "$ns")
      tk "${nsarg[@]}" patch "$kind" "$name" --type merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
    done
    tk delete crd "$crd" --wait=true --timeout=300s >/dev/null 2>&1 || ofail CRD_DELETE_FAILED "$crd"
    notes+=("finalizers cleared for ${kind}")
  fi
done
left="$(tk get crd -o name 2>/dev/null | grep -c '\.sql\.tanzu\.vmware\.com$' || true)"
[[ "${left:-0}" -eq 0 ]] || ofail CRD_DELETE_FAILED "${left} Tanzu Postgres CRDs remain"
record "result.${C}.operator" SUCCEEDED "" "CRDs deleted: $(paste -sd' ' <<<"${crds:-none}")$( [[ ${#notes[@]} -gt 0 ]] && printf '; %s' "$(printf '%s, ' "${notes[@]}" | sed 's/, $//')" )"
exit "$failed"
