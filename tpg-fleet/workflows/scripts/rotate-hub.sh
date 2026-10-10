#!/usr/bin/env bash
# rotate-hub.sh WORKFLOW_NAME SECRET_TYPE
# Hub side of a credential rotation. The new value is already in Vault (written
# by tpg-aks-infra scripts/run.sh --only hub-secrets, which checks it first); this
# step waits until the hub consumers use it and verifies it.
#   broadcom-registry: Argo CD repository repo-tanzu-postgres-oci (VaultStaticSecret) reconnects
#   git-read:          Argo CD repository repo-tpg-fleet (VaultStaticSecret) reconnects
#   git-push:          clone and push --dry-run with the Vault value (Vault Agent, this pod)
#   backup-storage:    the new key opens every target's container (Get Container Properties)
#   monitoring-remote-write: a warning to rebuild the hub gateway (tpg-aks-infra run.sh --only addons)
#   ca-bundle:         tpg/ca-bundles/<secretName> holds PEM certificates that have not expired
#   custom:            nothing to verify (Round 15, D87)
WF="$1"; TYPE="$2"
# shellcheck source=workflows/scripts/lib.sh
source /scripts/lib.sh
VSS_KUBECTL=kubectl   # vss_summary reads the hub, not a target cluster

key="result.hub"
fail() { record "$key" FAILED "$1" "${2:-}"; exit 1; }
result_guard "$key"

# argocd_repo_check REPOSITORY_SECRET REPO_URL: wait for the VaultStaticSecret to be
# Ready after VSO's next refresh (refreshAfter 60s), then for Argo CD to connect.
argocd_repo_check() {
  local vss="$1" url="$2" st="" state="" listed=0
  log "the VaultStaticSecret argocd/${vss} re-reads Vault every 60 s (refreshAfter): waiting 70 s for one refresh"
  log_cmd "sleep 70   # then: kubectl -n argocd get vaultstaticsecret ${vss}"
  sleep 70
  vss_ready() {
    log_cmd "kubectl -n argocd get vaultstaticsecret ${vss} -o json | jq (Ready, else SecretSynced)"
    st="$(kubectl -n argocd get vaultstaticsecret "$vss" -o json 2>/dev/null \
      | jq -r '[.status.conditions[]? | select(.type == "Ready" or .type == "SecretSynced")] | ((map(select(.type == "Ready")) + .)[0].status // "")')"
    log "  Ready/SecretSynced: ${st:-unknown}; $(vss_summary argocd "$vss")"
    [[ "$st" == "True" ]]
  }
  wait_logged "VaultStaticSecret argocd/${vss} Ready" 20 15 vss_ready \
    || fail SECRET_NOT_SYNCED "VaultStaticSecret argocd/${vss} not Ready"
  argocd_connection() {
    local body
    log_cmd "GET ${ARGOCD_URL:-<argocd>}/api/v1/repositories?forceRefresh=true   (as workflow-bot) | jq '.items[] | select(.repo == \"${url}\") | .connectionState.status'"
    body="$(acd GET "/api/v1/repositories?forceRefresh=true")" || body=""
    # items is absent when the list is empty: Argo CD leaves out every repository the caller may not read
    if jq -e '(.items // []) | length > 0' >/dev/null 2>&1 <<<"$body"; then listed=1; fi
    state="$(jq -r --arg u "$url" '(.items // [])[] | select(.repo == $u) | .connectionState.status' 2>/dev/null <<<"$body" | head -n1)"
    log "  repositories listed: $(jq -r '(.items // []) | length' 2>/dev/null <<<"$body" || echo '?'); connection state of ${url}: ${state:-unknown}"
    [[ "$state" == "Successful" ]]
  }
  wait_logged "Argo CD connection to ${url}" 12 15 argocd_connection && return 0
  [[ "$listed" == 1 ]] || fail RBAC_MISSING "Argo CD returned no repositories to workflow-bot: add 'p, role:tpg-sync, repositories, get, *, allow' to argocd-rbac-cm (tpg-aks-infra scripts/run.sh --hub existing ... --only hub adds it)"
  fail VERIFY_FAILED "Argo CD connection state for ${url}: ${state:-unknown}"
}

case "$TYPE" in
  broadcom-registry)
    argocd_repo_check repo-tanzu-postgres-oci "$(setting registryHost)"
    record "$key" UPDATED "" "repo-tanzu-postgres-oci synced from Vault, Argo CD connection Successful"
    ;;
  git-read)
    argocd_repo_check repo-tpg-fleet "$(setting fleetRepoURL)"
    record "$key" UPDATED "" "repo-tpg-fleet synced from Vault, Argo CD connection Successful"
    ;;
  git-push)
    git_clone "$WORK/repo" || fail VERIFY_FAILED "clone with the Vault value tpg/shared/github-push failed"
    git -C "$WORK/repo" push --dry-run --quiet origin "HEAD:$(setting fleetRevision)" \
      || fail VERIFY_FAILED "push authentication failed"
    record "$key" UPDATED "" "tpg/shared/github-push verified (clone and push dry-run)"
    ;;
  backup-storage)
    A="$(vault_secret backup-storage accountName)" || fail NO_VAULT_SECRET backup-storage
    K="$(vault_secret backup-storage accountKey)" || fail NO_VAULT_SECRET backup-storage
    [[ "$A" == "$(setting backupStorageAccount)" ]] \
      || fail VERIFY_FAILED "Vault accountName ${A} differs from tpg-settings backupStorageAccount $(setting backupStorageAccount)"
    checked=()
    for c in $(run_data inventory | jq -r '.[].name'); do
      code="$(blob_container_status "$A" "$K" "pg-backups-${c}")"
      [[ "$code" == "200" ]] || fail VERIFY_FAILED "container pg-backups-${c}: HTTP ${code} with the new key (403: key rejected, 404: container missing)"
      checked+=("pg-backups-${c}")
    done
    record "$key" UPDATED "" "new key opens ${#checked[@]} containers: ${checked[*]:-none}"
    ;;
  monitoring-remote-write)
    # the hub gateway reads a htpasswd Secret that tpg-aks-infra builds from Vault
    record_entry "warning.hub.monitoring" WARNING GATEWAY_NOT_UPDATED \
      "the remote-write gateway on the hub still accepts the previous credential: run tpg-aks-infra scripts/run.sh --only addons now (it rebuilds monitoring/tpg-remote-write-htpasswd from Vault, restarts the gateway and checks that every target's metrics arrive); until then the targets whose Vault Secrets Operator already has the new credential cannot write metrics"
    record "$key" UPDATED "" "tpg/shared/monitoring-remote-write is in Vault; the targets pick it up through the Vault Secrets Operator (monitoring/tpg-remote-write)"
    ;;
  ca-bundle)
    vault_kv_read "ca-bundles/${P_SECRET_NAME:-}" caBundle "$WORK/ca.pem" || fail NO_VAULT_SECRET "tpg/ca-bundles/${P_SECRET_NAME:-}: ${VAULT_READ_ERROR}"
    msg="$(ca_check "$WORK/ca.pem")" || fail VERIFY_FAILED "tpg/ca-bundles/${P_SECRET_NAME:-}: ${msg}"
    record "$key" UPDATED "" "tpg/ca-bundles/${P_SECRET_NAME:-} holds $(grep -c 'BEGIN CERTIFICATE' "$WORK/ca.pem") certificate(s) that have not expired; runs use it with backupCaBundleVaultSecret=${P_SECRET_NAME:-} (tpg-day0, tpg-create-instance, tpg-patch)"
    ;;
  custom)
    record "$key" UPDATED "" "tpg/custom/${P_SECRET_NAME:-} written; nothing in the fleet reads it"
    ;;
  *) fail INVALID_SECRET_TYPE "$TYPE" ;;
esac
