#!/usr/bin/env bash
# rotate-cluster.sh WORKFLOW_NAME CLUSTER SECRET_TYPE
# Target side of a credential rotation: wait until the Vault Secrets Operator on
# the cluster has written the new Vault value into every managed namespace, then
# verify it. The expected value comes from Vault through Vault Agent (this pod).
#   broadcom-registry: regsecret in tanzu-postgres-operator and every pg-* managed
#                      namespace; then an image pull with the operator image
#   backup-storage:    backup-storage in every pg-* managed namespace; then every
#                      PostgresBackupLocation reconciles the new Secret version
# Records result.<cluster> UPDATED | FAILED | SKIPPED. Exits 1 on FAILED.
WF="$1"; C="$2"; TYPE="$3"
# shellcheck source=workflows/scripts/lib.sh
source /scripts/lib.sh

key="result.${C}"
fail() { record "$key" FAILED "$1" "${2:-}"; exit 1; }
result_guard "$key"
if ! use_cluster "$C" || ! tk get --raw=/readyz >/dev/null 2>&1; then
  record "$key" SKIPPED UNREACHABLE; exit 0
fi
mapfile -t NSS < <(tk get namespace -l tpg.fleet/managed=true -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
  | grep -E '^(tanzu-postgres-operator|pg-.+)$' | sort | awk '$0 == "tanzu-postgres-operator" { print "0 " $0; next } { print "1 " $0 }' | sort | cut -d' ' -f2 || true)
[[ "${#NSS[@]}" -gt 0 ]] || { record "$key" SKIPPED NO_MANAGED_NAMESPACES; exit 0; }

# check_namespaces SECRET JQ_EXPR WANT_SHA16 [pg-only]: wait for the Secret of every namespace to hold the Vault value.
# Every namespace is checked (5 minutes each, stopping as soon as it matches); the ones that
# never match are collected in NOT_SYNCED with their short checksums.
NOT_SYNCED=""
check_namespaces() {
  local name="$1" expr="$2" want="$3" only="${4:-}" ns
  NOT_SYNCED=""
  for ns in "${NSS[@]}"; do
    [[ "$only" != pg-only || "$ns" == pg-* ]] || continue
    if ! wait_logged "${ns}/${name} holds the Vault value" 30 10 secret_matches "$ns" "$name" "$expr" "$want"; then
      NOT_SYNCED="${NOT_SYNCED:+${NOT_SYNCED}, }${ns}/${name} (live ${LIVE_SHA:0:8}, Vault ${want:0:8})"
    fi
  done
  [[ -z "$NOT_SYNCED" ]]
}

# pull_check_state POD: one poll of the image pull of the pull-check pod; sets PULL_RESULT
PULL_RESULT=""
pull_check_state() {
  local waiting pulled
  log_cmd "kubectl -n tanzu-postgres-operator get pod $1 -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}{.status.containerStatuses[0].imageID}'"
  waiting="$(tk -n tanzu-postgres-operator get pod "$1" -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || true)"
  pulled="$(tk -n tanzu-postgres-operator get pod "$1" -o jsonpath='{.status.containerStatuses[0].imageID}' 2>/dev/null || true)"
  log "  waiting reason: ${waiting:-none}; imageID: ${pulled:+set}${pulled:-not yet}"
  if [[ "$waiting" == "ErrImagePull" || "$waiting" == "ImagePullBackOff" ]]; then PULL_RESULT="pull-failed"; return 0; fi
  if [[ -n "$pulled" ]]; then PULL_RESULT="pulled"; return 0; fi
  return 1
}

# backup_location_current NAMESPACE BACKUP_LOCATION RESOURCE_VERSION: one poll of "the location has seen the Secret version"
backup_location_current() {
  local cur
  log_cmd "kubectl -n $1 get postgresbackuplocation $2 -o jsonpath='{.status.currentSecretResourceVersion}'  (want $3)"
  cur="$(tk -n "$1" get postgresbackuplocation "$2" -o jsonpath='{.status.currentSecretResourceVersion}' 2>/dev/null || true)"
  log "  currentSecretResourceVersion: ${cur:-none}"
  [[ "$cur" == "$3" ]]
}

case "$TYPE" in
  broadcom-registry)
    P="$(vault_secret broadcom-registry password)" || fail NO_VAULT_SECRET broadcom-registry
    want="$(printf '%s' "$P" | sha16)"
    log "the Vault value of tpg/shared/broadcom-registry (password) has checksum ${want:0:8}; checking ${#NSS[@]} namespace(s): ${NSS[*]}"
    check_namespaces regsecret '.data[".dockerconfigjson"] | @base64d | fromjson | .auths[].password' "$want" \
      || fail SECRET_NOT_SYNCED "not synced after 5 minutes: ${NOT_SYNCED}"
    image="$(tk -n tanzu-postgres-operator get deploy -l app=postgres-operator \
      -o jsonpath='{.items[0].spec.template.spec.containers[0].image}' 2>/dev/null || true)"
    [[ -n "$image" ]] || fail VERIFY_FAILED "operator Deployment not found for pull test"
    pod="tpg-pull-check-$(date +%s)"
    tk -n tanzu-postgres-operator run "$pod" --image="$image" --restart=Never \
      --image-pull-policy=Always \
      --overrides='{"apiVersion":"v1","spec":{"imagePullSecrets":[{"name":"regsecret"}],"tolerations":[{"operator":"Exists"}]}}' \
      --command -- sh -c "exit 0" >/dev/null || fail VERIFY_FAILED "could not create pull-check pod"
    log_cmd "kubectl -n tanzu-postgres-operator run ${pod} --image=${image} --restart=Never --image-pull-policy=Always (imagePullSecrets: regsecret)"
    PULL_RESULT=""
    wait_logged "image pull of ${pod} with the new regsecret" 30 5 pull_check_state "$pod" || true
    result="$PULL_RESULT"
    tk -n tanzu-postgres-operator delete pod "$pod" --wait=false >/dev/null 2>&1 || true
    [[ "$result" == "pulled" ]] || fail VERIFY_FAILED "image pull with the new token: ${result:-timeout}"
    record "$key" UPDATED "" "regsecret synced from Vault in ${#NSS[@]} namespaces, image pull verified"
    ;;
  backup-storage)
    K="$(vault_secret backup-storage accountKey)" || fail NO_VAULT_SECRET backup-storage
    want="$(printf '%s' "$K" | sha16)"
    log "the Vault value of tpg/shared/backup-storage (accountKey) has checksum ${want:0:8}; checking the pg-* namespaces of: ${NSS[*]}"
    check_namespaces backup-storage '.data.accountKey | @base64d' "$want" pg-only \
      || fail SECRET_NOT_SYNCED "not synced after 5 minutes: ${NOT_SYNCED}"
    count=0
    for ns in "${NSS[@]}"; do
      [[ "$ns" == pg-* ]] || continue
      rv="$(tk -n "$ns" get secret backup-storage -o jsonpath='{.metadata.resourceVersion}')"
      for bl in $(tk -n "$ns" get postgresbackuplocation -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
        wait_logged "${ns}/${bl} picks up Secret resourceVersion ${rv}" 30 10 backup_location_current "$ns" "$bl" "$rv" \
          || fail VERIFY_FAILED "$ns/$bl did not pick up Secret resourceVersion $rv"
      done
      count=$((count + 1))
    done
    record "$key" UPDATED "" "backup-storage synced from Vault in ${count} namespaces, backup locations reconciled"
    ;;
  *) fail INVALID_SECRET_TYPE "$TYPE" ;;
esac
