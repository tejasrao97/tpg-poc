output "key_vault_id" {
  value = azurerm_key_vault.unseal.id
}

output "key_vault_name" {
  value = azurerm_key_vault.unseal.name
}

output "key_name" {
  value = azurerm_key_vault_key.unseal.name
}

output "key_versionless_id" {
  value = azurerm_key_vault_key.unseal.versionless_id
}

output "tenant_id" {
  description = "Tenant of the Key Vault, for the access policy of the Vault workload identity."
  value       = azurerm_key_vault.unseal.tenant_id
}
