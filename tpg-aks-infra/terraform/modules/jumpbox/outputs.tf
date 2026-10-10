output "public_ip" {
  description = "Static public IP address of the jumpbox."
  value       = azurerm_public_ip.jumpbox.ip_address
}

output "public_cidr" {
  description = "Public IP of the jumpbox as a /32 CIDR, for the API server authorized IP ranges."
  value       = "${azurerm_public_ip.jumpbox.ip_address}/32"
}

output "vm_id" {
  description = "Resource ID of the VM (a new VM re-runs the provisioning in the root module)."
  value       = azurerm_linux_virtual_machine.jumpbox.id
}

output "admin_username" {
  description = "Admin user on the VM."
  value       = azurerm_linux_virtual_machine.jumpbox.admin_username
}

output "generated_private_key" {
  description = "OpenSSH private key generated for the admin user."
  value       = tls_private_key.jumpbox.private_key_openssh
  sensitive   = true
}

output "generated_public_key" {
  description = "OpenSSH public key generated for the admin user."
  value       = trimspace(tls_private_key.jumpbox.public_key_openssh)
}

output "identity_client_id" {
  description = "Client ID of the jumpbox managed identity (az login --identity --client-id)."
  value       = azurerm_user_assigned_identity.jumpbox.client_id
}

output "identity_principal_id" {
  description = "Principal (object) ID of the jumpbox managed identity."
  value       = azurerm_user_assigned_identity.jumpbox.principal_id
}

output "role_assignment_commands" {
  description = "az commands for the role assignments that were not created (empty when create_role_assignments is true)."
  value = var.create_role_assignments ? [] : [
    for k, ra in var.role_assignments :
    format("az role assignment create --assignee-object-id %s --assignee-principal-type ServicePrincipal --role \"%s\" --scope %s  # id-jumpbox/%s",
    azurerm_user_assigned_identity.jumpbox.principal_id, ra.role, ra.scope, k)
  ]
}
