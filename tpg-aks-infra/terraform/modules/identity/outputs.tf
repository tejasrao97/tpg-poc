output "ids" {
  description = "Map of identity name to resource ID."
  value       = { for k, v in azurerm_user_assigned_identity.managed_identity : k => v.id }
}

output "principal_ids" {
  description = "Map of identity name to principal (object) ID."
  value       = { for k, v in azurerm_user_assigned_identity.managed_identity : k => v.principal_id }
}

output "client_ids" {
  description = "Map of identity name to client ID."
  value       = { for k, v in azurerm_user_assigned_identity.managed_identity : k => v.client_id }
}

output "role_assignment_ids" {
  description = "Map of <identity>/<key> to role assignment ID (empty when create_role_assignments is false)."
  value       = { for k, v in azurerm_role_assignment.identity_role : k => v.id }
}

output "role_assignment_commands" {
  description = "az commands for the role assignments that were not created (empty when create_role_assignments is true)."
  value = var.create_role_assignments ? [] : [
    for k, ra in local.role_assignments :
    format("az role assignment create --assignee-object-id %s --assignee-principal-type ServicePrincipal --role \"%s\" --scope %s  # %s",
    azurerm_user_assigned_identity.managed_identity[ra.identity].principal_id, ra.role, ra.scope, k)
  ]
}
