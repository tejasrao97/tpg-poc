output "account_name" {
  description = "Storage account name."
  value       = azurerm_storage_account.backups.name
}

output "account_id" {
  description = "Storage account ID."
  value       = azurerm_storage_account.backups.id
}

output "containers" {
  description = "Container names."
  value       = [for c in azurerm_storage_container.backups : c.name]
}

output "primary_access_key" {
  description = "Primary access key."
  value       = azurerm_storage_account.backups.primary_access_key
  sensitive   = true
}

output "logs_container" {
  description = "Container of the archived Argo Workflows logs."
  value       = azurerm_storage_container.argo_logs.name
}

output "ca_bundle" {
  description = "PEM bundle of the Azure root certificate authorities that the blob endpoint chains to (PostgresBackupLocation caBundle with enableSSL: true)."
  value       = local.azure_ca_roots_pem
}

output "blob_endpoint_issuers" {
  description = "Issuers of the certificate chain the blob endpoint presented when Terraform checked it."
  value       = [for c in data.tls_certificate.blob_endpoint.certificates : c.issuer]
}
