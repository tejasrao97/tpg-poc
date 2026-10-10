# tpg-workflow: Vault Agent in the hub Argo Workflows pods (role tpg-workflow,
# ServiceAccount argo/tpg-workflow). Reads the three values the workflows use, and
# the CA bundles the inputs backupCaBundleVaultSecret name (Round 15, D86; read by
# the step scripts with the pod's ServiceAccount token, lib.sh vault_kv_read).
path "tpg/data/shared/broadcom-registry" {
  capabilities = ["read"]
}
path "tpg/data/shared/github-push" {
  capabilities = ["read"]
}
path "tpg/data/shared/backup-storage" {
  capabilities = ["read"]
}
path "tpg/data/ca-bundles/*" {
  capabilities = ["read"]
}
