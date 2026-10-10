#!/usr/bin/env bash
# On the hub:
#   1. Pre-checks, before anything is stored (the step exits with the exact error):
#        Broadcom registry token  helm registry login <registry> (throwaway registry config)
#        GitHub PATs (both)       token active and not expired, repository selected,
#                                 Contents read (REST and Git), read/write PAT push
#                                 authorized (git push --dry-run) and Pull requests read;
#                                 VALIDATE_PR_WRITE=true also opens and closes a test pull request
#   2. Vault KV (mount tpg, written with the tpg-admin role):
#        shared/broadcom-registry  username, password     (workflows, VSO hub and targets)
#        shared/github-read        username, token        (Argo CD repository, VSO hub)
#        shared/github-push        username, token        (workflows)
#        shared/backup-storage     accountName, accountKey (workflows, VSO targets)
#   3. Argo CD repository Secrets repo-tpg-fleet and repo-tanzu-postgres-oci as
#      VaultStaticSecrets (Vault Secrets Operator on the hub keeps them in sync)
#   4. Archived workflow logs: Secret argo/argo-artifacts (VaultStaticSecret of
#      tpg/shared/backup-storage) and ConfigMap argo/artifact-repositories, the
#      namespace default artifact repository with archiveLogs: true (Azure Blob
#      container backup.logsContainer, default argo-logs)
#   5. tpg-settings ConfigMap (with the backup storage CA bundle, backupCaBundle,
#      and acnsEnabled) and the workflow-bot Argo CD API token
# Secrets are read from the environment or prompted for; they are never written
# to files. Earlier versions kept the credentials in argo/tpg-src-broadcom-registry,
# argo/tpg-src-backup-storage and argo/tpg-git-push: this step deletes them.
source "$(dirname "$0")/../lib/common.sh"
source "$(dirname "$0")/../lib/vault.sh"
source "$(dirname "$0")/../lib/credential-checks.sh"

require_cmd kubectl jq yq argocd helm curl git
require_inventory
require_env FLEET_REPO_URL FLEET_REPO_REVISION GITHUB_USER BROADCOM_USER
HUB="$(hub_name)"
require_context "$HUB"
REGISTRY="tanzu-sql-postgres.packages.broadcom.com"
GITHUB_API_URL="${GITHUB_API_URL:-https://api.github.com}"
vault_require_unsealed
kubectl --context "$HUB" get crd vaultstaticsecrets.secrets.hashicorp.com >/dev/null 2>&1 \
  || die "the Vault Secrets Operator is not installed on $HUB: run the vault step first"

prompt_secret BROADCOM_TOKEN "Broadcom registry token"
prompt_secret GIT_READ_PAT "GitHub fine-grained PAT (read-only, for Argo CD)"
prompt_secret GIT_PUSH_PAT "GitHub fine-grained PAT (read and write, for Argo Workflows)"
SA="$(inv '.backup.storageAccount')"
SA_KEY="$(backup_key)"
[[ -n "$SA_KEY" ]] || die "could not read the backup storage account key"

# ---------------------------------------------------------------- 1. pre-checks
check_broadcom_token "$REGISTRY" "$BROADCOM_USER" "$BROADCOM_TOKEN"
check_github_pats "$FLEET_REPO_URL" "$FLEET_REPO_REVISION" "$GITHUB_API_URL" "$GITHUB_USER" "$GIT_READ_PAT" "$GIT_PUSH_PAT"

# ---------------------------------------------------------------- 2. Vault KV
log "Writing the credentials to Vault (KV v2 mount tpg)"
vault_login
# the values reach jq through the environment, never as a command-line argument
vault_kv_put shared/broadcom-registry "$(U="$BROADCOM_USER" P="$BROADCOM_TOKEN" jq -cn '{username: env.U, password: env.P}')"
vault_kv_put shared/github-read "$(U="$GITHUB_USER" P="$GIT_READ_PAT" jq -cn '{username: env.U, token: env.P}')"
vault_kv_put shared/github-push "$(U="$GITHUB_USER" P="$GIT_PUSH_PAT" jq -cn '{username: env.U, token: env.P}')"
vault_kv_put shared/backup-storage "$(U="$SA" P="$SA_KEY" jq -cn '{accountName: env.U, accountKey: env.P}')"
ok "tpg/shared/broadcom-registry, github-read, github-push, backup-storage"
for s in tpg-src-broadcom-registry tpg-src-backup-storage tpg-git-push; do
  if kubectl --context "$HUB" -n argo get secret "$s" >/dev/null 2>&1; then
    kubectl --context "$HUB" -n argo delete secret "$s" >/dev/null
    ok "deleted the former Secret argo/$s (the credential is in Vault now)"
  fi
done

# ---------------------------------------------------------------- 3. Argo CD repositories (VSO)
log "Argo CD repository Secrets from Vault (VaultStaticSecrets in argocd)"
kubectl --context "$HUB" -n argocd create serviceaccount tpg-vso --dry-run=client -o yaml \
  | kubectl --context "$HUB" apply -f - >/dev/null
# shellcheck disable=SC2016  # Go templates evaluated by the Vault Secrets Operator
jq -n --arg url "$FLEET_REPO_URL" --arg reg "$REGISTRY" '
  def vss($name; $path; $templates): {
    apiVersion: "secrets.hashicorp.com/v1beta1", kind: "VaultStaticSecret",
    metadata: {name: $name, namespace: "argocd", labels: {"tpg.fleet/managed": "true"}},
    spec: {
      vaultAuthRef: "tpg-vault/tpg-vault", type: "kv-v2", mount: "tpg", path: $path, refreshAfter: "60s",
      destination: {
        name: $name, create: true, overwrite: true,
        labels: {"argocd.argoproj.io/secret-type": "repository", "tpg.fleet/managed": "true"},
        transformation: {excludeRaw: true, excludes: [".*"], templates: $templates}
      }
    }
  };
  {apiVersion: "v1", kind: "List", items: [
    vss("repo-tpg-fleet"; "shared/github-read"; {
      type: {text: "git"}, url: {text: $url},
      username: {text: "{{ get .Secrets \"username\" }}"},
      password: {text: "{{ get .Secrets \"token\" }}"}}),
    vss("repo-tanzu-postgres-oci"; "shared/broadcom-registry"; {
      name: {text: "tanzu-postgres"}, type: {text: "helm"}, url: {text: $reg}, enableOCI: {text: "true"},
      username: {text: "{{ get .Secrets \"username\" }}"},
      password: {text: "{{ get .Secrets \"password\" }}"}})
  ]}' | kubectl --context "$HUB" apply -f - >/dev/null

for name in repo-tpg-fleet repo-tanzu-postgres-oci; do
  st=""
  for _ in $(seq 1 30); do
    # The operator publishes Ready and SecretSynced; older versions only SecretSynced.
    st="$(kubectl --context "$HUB" -n argocd get vaultstaticsecret "$name" -o json \
      | jq -r '[.status.conditions[]? | select(.type == "Ready" or .type == "SecretSynced")] | ((map(select(.type == "Ready")) + .)[0].status // "")')"
    [[ "$st" == "True" ]] && break
    sleep 5
  done
  if [[ "$st" != "True" ]]; then
    kubectl --context "$HUB" -n argocd get vaultstaticsecret "$name" -o json \
      | jq -r '.status.conditions[]? | "  " + .type + "=" + .status + ": " + .message' >&2
    die "VaultStaticSecret argocd/$name did not sync from Vault (check the vault-secrets-operator logs and auth/kubernetes role tpg-argocd)"
  fi
done
ok "repo-tpg-fleet, repo-tanzu-postgres-oci synced from Vault"

# ---------------------------------------------------------------- 4. archived workflow logs
# Every workflow step's log is copied to Azure Blob when the step ends
# (archiveLogs), so it can still be read after the pod is deleted
# (podGC OnPodSuccess) and after the Workflow itself is deleted (TTL 7 days):
# in the UI while the Workflow exists, afterwards with scripts/wf-logs.sh.
# The namespace default artifact repository (ConfigMap artifact-repositories,
# annotation workflows.argoproj.io/default-artifact-repository) needs no change
# to the Argo Workflows Helm values, so it works the same on an existing hub.
LOGS_CONTAINER="$(inv '.backup.logsContainer // "argo-logs"')"
log "Archived workflow logs: Azure Blob ${SA}/${LOGS_CONTAINER}"
jq -n '{
  apiVersion: "secrets.hashicorp.com/v1beta1", kind: "VaultStaticSecret",
  metadata: {name: "argo-artifacts", namespace: "argo", labels: {"tpg.fleet/managed": "true"}},
  spec: {vaultAuthRef: "tpg-vault/tpg-vault", type: "kv-v2", mount: "tpg", path: "shared/backup-storage",
         refreshAfter: "60s",
         destination: {name: "argo-artifacts", create: true, overwrite: true,
                       labels: {"tpg.fleet/managed": "true"}, transformation: {excludeRaw: true}}}
}' | kubectl --context "$HUB" apply -f - >/dev/null
for _ in $(seq 1 30); do
  kubectl --context "$HUB" -n argo get secret argo-artifacts >/dev/null 2>&1 && break
  sleep 5
done
kubectl --context "$HUB" -n argo get secret argo-artifacts >/dev/null 2>&1 \
  || die "Secret argo/argo-artifacts was not synced from Vault: $(kubectl --context "$HUB" -n argo get vaultstaticsecret argo-artifacts -o json \
       | jq -r '[.status.conditions[]? | .type + "=" + .status + " " + (.message // "")] | join("; ")') (the VaultAuth tpg-vault/tpg-vault must allow namespace argo: re-run --only vault)"
jq -n --arg sa "$SA" --arg c "$LOGS_CONTAINER" '{
  apiVersion: "v1", kind: "ConfigMap",
  metadata: {name: "artifact-repositories", namespace: "argo",
             labels: {"tpg.fleet/managed": "true"},
             annotations: {"workflows.argoproj.io/default-artifact-repository": "tpg-azure-logs"}},
  data: {"tpg-azure-logs": ({archiveLogs: true,
                            azure: {endpoint: ("https://" + $sa + ".blob.core.windows.net"), container: $c,
                                    accountKeySecret: {name: "argo-artifacts", key: "accountKey"}}} | tojson)}
}' | kubectl --context "$HUB" apply -f - >/dev/null
ok "argo/argo-artifacts (from Vault) and argo/artifact-repositories: logs archived to ${SA}/${LOGS_CONTAINER}"

# ---------------------------------------------------------------- 5. settings and Argo CD token
log "tpg-settings ConfigMap (argo namespace)"
MONITORING_OPTION="${MONITORING_OPTION:-none}"
case "$MONITORING_OPTION" in none|azure|standalone) ;; *) die "MONITORING_OPTION must be none, azure or standalone" ;; esac
# Written by the addons step; kept when this step runs again
RW_URL="$(kubectl --context "$HUB" -n argo get configmap tpg-settings \
  -o jsonpath='{.data.hubPrometheusRemoteWriteUrl}' 2>/dev/null || true)"
# Azure Storage CA bundle for PostgresBackupLocation enableSSL: true (design
# decision D63): the Terraform output backup_storage_ca_bundle, written to
# .work/backup-ca-bundle.pem by the inventory step, or inventory
# backup.caBundleFile for a pre-created account (default: the Azure root
# certificate authorities in terraform/modules/storage/azure-ca-roots.pem).
# The account's blob endpoint must verify against it.
CA_FILE="$(inv '.backup.caBundleFile // ""')"
[[ -n "$CA_FILE" ]] || CA_FILE="${REPO_ROOT}/terraform/modules/storage/azure-ca-roots.pem"
[[ "$CA_FILE" = /* ]] || CA_FILE="${REPO_ROOT}/${CA_FILE}"
[[ -s "$CA_FILE" ]] || die "backup CA bundle ${CA_FILE} not found (inventory backup.caBundleFile)"
n_ca="$(grep -c -- '-----BEGIN CERTIFICATE-----' "$CA_FILE" || true)"
[[ "${n_ca:-0}" -gt 0 ]] || die "${CA_FILE} holds no PEM certificate"
if command -v openssl >/dev/null 2>&1; then
  # openssl exits non-zero when verification fails; that must reach the check
  # below, not end the step through set -e and pipefail
  vr="$( { openssl s_client -connect "${SA}.blob.core.windows.net:443" -servername "${SA}.blob.core.windows.net" \
           -CAfile "$CA_FILE" -verify_return_error </dev/null 2>/dev/null || true; } \
         | awk -F': ' '/Verify return code/ && !found {print $2; found=1}')"
  if [[ "$vr" == 0\ * ]]; then
    ok "${SA}.blob.core.windows.net verifies against ${CA_FILE} (${n_ca} CA certificate(s))"
  else
    die "${SA}.blob.core.windows.net does not verify against ${CA_FILE}: ${vr:-no answer}. Update the bundle (https://learn.microsoft.com/azure/security/fundamentals/azure-ca-details)"
  fi
else
  warn "openssl not found: the CA bundle is not checked against ${SA}.blob.core.windows.net"
fi
ACNS_ENABLED="$(inv '.network.acnsEnabled // false')"
kubectl --context "$HUB" -n argo create configmap tpg-settings \
  --from-file=backupCaBundle="$CA_FILE" \
  --from-literal=acnsEnabled="$ACNS_ENABLED" \
  --from-literal=fleetRepoURL="$FLEET_REPO_URL" \
  --from-literal=fleetRevision="$FLEET_REPO_REVISION" \
  --from-literal=registryHost="$REGISTRY" \
  --from-literal=githubApiUrl="$GITHUB_API_URL" \
  --from-literal=monitoringOption="$MONITORING_OPTION" \
  --from-literal=hubPrometheusRemoteWriteUrl="$RW_URL" \
  --from-literal=backupStorageAccount="$SA" \
  --from-literal=vaultAddr="$VAULT_INCLUSTER_ADDR" \
  --from-literal=vaultFleetAddr="$(vault_fleet_addr)" \
  --dry-run=client -o yaml | kubectl --context "$HUB" apply -f - >/dev/null
ok "tpg-settings"

log "Generating the workflow-bot Argo CD API token"
# Port-forward works whether or not argocd-server is exposed.
PF_PORT="${ARGOCD_PF_PORT:-18080}"
kubectl --context "$HUB" -n argocd port-forward svc/argocd-server "${PF_PORT}:443" >/dev/null 2>&1 &
PF_PID=$!
cleanup_add "kill $PF_PID"
sleep 3
if [[ -z "${ARGOCD_ADMIN_PASSWORD:-}" ]]; then
  ARGOCD_ADMIN_PASSWORD="$(kubectl --context "$HUB" -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)"
fi
prompt_secret ARGOCD_ADMIN_PASSWORD "Argo CD admin password (argocd-initial-admin-secret not found)"
argocd login "localhost:${PF_PORT}" --username admin --password "$ARGOCD_ADMIN_PASSWORD" \
  --insecure --grpc-web >/dev/null
TOKEN="$(argocd account generate-token --account workflow-bot --grpc-web)"
upsert_generic_secret "$HUB" argo argocd-workflow-token --from-literal=token="$TOKEN"
TOKEN=""
ok "argocd-workflow-token"

log "Repository connection status in Argo CD"
argocd repo list --grpc-web
