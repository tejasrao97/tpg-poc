# Azure Key Vault and RSA key for the HashiCorp Vault auto-unseal
# (vault_unseal_mode = "azure-keyvault").
#
# Access uses Key Vault ACCESS POLICIES, not Azure RBAC, on purpose: an access
# policy is written on the Key Vault resource itself, which a Contributor may
# do, while an RBAC role assignment needs Microsoft.Authorization/roleAssignments/write.
# Deployments run by an account without that permission fail with
# "AuthorizationFailed: ... does not have authorization to perform action
# 'Microsoft.Authorization/roleAssignments/write'".
#
#   - the identity running Terraform gets key create, get, list, update, delete,
#     recover and purge, so it can create the unseal key and remove it on
#     terraform destroy (the provider deletes the key, then purges it)
#   - the Vault workload identity (root module, module.vault_identity) gets
#     get, wrapKey and unwrapKey through an access policy in the root module
resource "random_string" "suffix" {
  length  = 6
  lower   = true
  upper   = false
  numeric = true
  special = false
}

resource "azurerm_key_vault" "unseal" {
  name                          = substr("kv${var.prefix}${random_string.suffix.result}", 0, 24)
  location                      = var.location
  resource_group_name           = var.resource_group_name
  tenant_id                     = var.tenant_id
  sku_name                      = "standard"
  rbac_authorization_enabled    = false
  purge_protection_enabled      = var.purge_protection_enabled
  soft_delete_retention_days    = var.soft_delete_retention_days
  public_network_access_enabled = true
  tags                          = var.tags
}

resource "azurerm_key_vault_access_policy" "deployer" {
  key_vault_id = azurerm_key_vault.unseal.id
  tenant_id    = var.tenant_id
  object_id    = var.deployer_object_id

  # Purge: terraform destroy deletes the key and then purges it (provider feature
  # key_vault.purge_soft_deleted_keys_on_destroy). Without Purge the destroy
  # fails with 403 ForbiddenByPolicy "does not have keys purge permission".
  key_permissions = ["Create", "Get", "List", "Update", "Delete", "Recover", "Purge", "GetRotationPolicy"]
}

resource "azurerm_key_vault_key" "unseal" {
  name         = var.key_name
  key_vault_id = azurerm_key_vault.unseal.id
  key_type     = "RSA"
  key_size     = 2048
  key_opts     = ["wrapKey", "unwrapKey"]
  tags         = var.tags

  # Create after, and destroy before, the deployer's access policy: the delete
  # and the purge of the key both run with the permissions that policy grants.
  depends_on = [azurerm_key_vault_access_policy.deployer]
}
