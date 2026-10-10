output "log_analytics_workspace_id" {
  description = "Log Analytics workspace ID (null when Container Insights is off)."
  value       = try(azurerm_log_analytics_workspace.container_logs[0].id, null)
}

output "azure_monitor_workspace_id" {
  description = "Azure Monitor workspace ID (null when option A is off)."
  value       = try(azurerm_monitor_workspace.prometheus[0].id, null)
}

output "grafana_name" {
  description = "Managed Grafana name."
  value       = try(azurerm_dashboard_grafana.grafana[0].name, null)
}

output "grafana_endpoint" {
  description = "Managed Grafana URL."
  value       = try(azurerm_dashboard_grafana.grafana[0].endpoint, null)
}

output "role_assignment_commands" {
  description = "az commands for the Managed Grafana role assignments that were not created."
  value = (var.enable_azure_monitor && !var.create_role_assignments) ? [
    format("az role assignment create --assignee-object-id %s --assignee-principal-type ServicePrincipal --role \"Monitoring Data Reader\" --scope %s  # Managed Grafana -> Azure Monitor workspace",
    azurerm_dashboard_grafana.grafana[0].identity[0].principal_id, azurerm_monitor_workspace.prometheus[0].id),
    format("az role assignment create --assignee-object-id %s --role \"Grafana Admin\" --scope %s  # you -> Managed Grafana",
    var.grafana_admin_object_id, azurerm_dashboard_grafana.grafana[0].id),
  ] : []
}
