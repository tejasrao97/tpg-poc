output "subscription_id" {
  value = var.subscription_id
}

output "tenant_id" {
  value = data.azurerm_client_config.current.tenant_id
}

output "resource_group_name" {
  description = "The resource group that holds every POC resource."
  value       = module.resource_group.name
}

output "location" {
  value = module.resource_group.location
}

output "network_mode" {
  value = var.network_mode
}

output "api_access_mode" {
  description = "Effective API server access: public or restricted."
  value       = local.api_public ? "public" : "restricted"
}

output "hub_cluster_name" {
  value = module.aks[var.hub_cluster_name].name
}

output "target_cluster_names" {
  value = local.target_names
}

output "target_cluster_waves" {
  description = "Initial rollout wave per target cluster (0 = canary)."
  value       = local.target_waves
}

output "node_resource_groups" {
  description = "AKS-owned node resource group per cluster."
  value       = { for name, m in module.aks : name => m.node_resource_group }
}

output "oidc_issuer_urls" {
  value = { for name, m in module.aks : name => m.oidc_issuer_url }
}

output "hub_egress_ip" {
  description = "Static hub egress IP (null in managed mode)."
  value       = module.network.hub_egress_ip
}

output "admin_allowed_cidrs" {
  value = var.admin_allowed_cidrs
}

output "backup_storage_account_name" {
  value = module.storage.account_name
}

output "backup_containers" {
  value = { for name in local.target_names : name => "pg-backups-${name}" }
}

output "argo_logs_container" {
  description = "Container of the archived Argo Workflows logs in the backup storage account."
  value       = module.storage.logs_container
}

output "backup_storage_https_only" {
  description = "Secure transfer required on the backup storage account (false: HTTP accepted too)."
  value       = var.backup_storage_https_only
}

output "backup_storage_ca_bundle" {
  description = "PEM bundle of the Azure root certificate authorities the backup storage blob endpoint chains to (checked at apply). PostgresBackupLocation caBundle for enableSSL: true; run.sh writes it to tpg-settings backupCaBundle."
  value       = module.storage.ca_bundle
}

output "backup_storage_ca_issuers" {
  description = "Issuers of the certificate chain the blob endpoint presented when Terraform checked it."
  value       = module.storage.blob_endpoint_issuers
}

output "acns_enabled" {
  description = "Advanced Container Networking Services on every cluster (CiliumNetworkPolicy toFQDNs for the network policies)."
  value       = var.acns_enabled
}

output "backup_storage_account_key" {
  value     = module.storage.primary_access_key
  sensitive = true
}

output "log_analytics_workspace_id" {
  value = module.monitoring.log_analytics_workspace_id
}

output "azure_monitor_workspace_id" {
  value = module.monitoring.azure_monitor_workspace_id
}

output "grafana_name" {
  value = module.monitoring.grafana_name
}

output "grafana_endpoint" {
  value = module.monitoring.grafana_endpoint
}

output "vault_unseal_mode" {
  description = "Vault unseal mode: shamir or azure-keyvault."
  value       = var.vault_unseal_mode
}

output "vault_azure_key_vault" {
  description = "azure-keyvault mode: Key Vault, key and workload identity for the Vault auto-unseal (null in shamir mode)."
  value = local.vault_akv ? {
    name      = module.vault_unseal[0].key_vault_name
    key_name  = module.vault_unseal[0].key_name
    tenant_id = data.azurerm_client_config.current.tenant_id
    client_id = module.vault_identity[0].client_ids["id-vault"]
  } : null
}

output "postgres_data_disk_sku" {
  description = "Managed-disk SKU of the StorageClass tpg-data-retain (Postgres data and WAL volumes, and the Vault volume on the hub)."
  value       = var.postgres_data_disk_sku
}

output "node_pool_zones" {
  description = "Availability zones per node pool, and the node counts that follow from them."
  value       = local.node_pool_zones
}

output "role_assignments_to_create" {
  description = <<-EOT
    az commands for the role assignments Terraform did not create because
    create_role_assignments is false. Empty when Terraform created them.
    Run them with an account that has Microsoft.Authorization/roleAssignments/write.
    Leave create_role_assignments at false afterwards: Terraform would try to create
    the same assignments again and Azure rejects a duplicate with RoleAssignmentExists.
  EOT
  value = var.create_role_assignments ? [] : concat(
    module.cluster_identities.role_assignment_commands,
    module.monitoring.role_assignment_commands,
    flatten(module.jumpbox[*].role_assignment_commands),
  )
}

output "jumpbox_public_ip" {
  description = "Static public IP of the jumpbox (null when enable_jumpbox is false)."
  value       = var.enable_jumpbox ? module.jumpbox[0].public_ip : null
}

output "jumpbox_ssh_command" {
  description = "SSH command for the jumpbox admin user with the generated key, saved first with terraform output -raw jumpbox_ssh_private_key (null when enable_jumpbox is false)."
  value       = var.enable_jumpbox ? "ssh -i ~/.ssh/tpg-jumpbox ${var.jumpbox_admin_username}@${module.jumpbox[0].public_ip}" : null
}

output "jumpbox_ssh_private_key" {
  description = <<-EOT
    OpenSSH private key Terraform generated for the jumpbox admin user (null when enable_jumpbox is false).
      terraform output -raw jumpbox_ssh_private_key > ~/.ssh/tpg-jumpbox && chmod 600 ~/.ssh/tpg-jumpbox
  EOT
  value       = var.enable_jumpbox ? module.jumpbox[0].generated_private_key : null
  sensitive   = true
}

output "fleet_repo_url" {
  description = "URL of the fleet repository create_fleet_repo creates and pushes (null when create_fleet_repo is false)."
  value       = var.create_fleet_repo ? local.fleet_repo_url : null
}

output "jumpbox_vault_keys_file" {
  description = "run_fleet_setup: file on the jumpbox with the Vault unseal or recovery keys (run.sh --save-vault-recovery-keys). Copy it off the jumpbox, then delete it."
  value       = var.run_fleet_setup ? local.jumpbox_vault_keys_file : null
}

output "jumpbox_env_override" {
  description = "Content of ~/env.jumpbox.sh on the jumpbox (jumpbox paths, INVENTORY_PREBUILT, the identity); deploy-scripts/deploy.sh copy writes it on a cloud-init jumpbox. null without a jumpbox."
  value       = var.enable_jumpbox ? local.jumpbox_env_override : null
}

output "jumpbox_inventory_yaml" {
  description = "The inventory for the jumpbox (~/.work/inventory.yaml, backup.keySource az); deploy-scripts/deploy.sh copy writes it on a cloud-init jumpbox. null without a jumpbox."
  value       = var.enable_jumpbox ? local.jumpbox_inventory_yaml : null
}

output "jumpbox_identity_client_id" {
  description = "Client ID of the jumpbox managed identity, for az login --identity --client-id (null when enable_jumpbox is false)."
  value       = var.enable_jumpbox ? module.jumpbox[0].identity_client_id : null
}
