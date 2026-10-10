output "name" {
  description = "Resource group name."
  value       = azurerm_resource_group.fleet.name
}

output "id" {
  description = "Resource group ID."
  value       = azurerm_resource_group.fleet.id
}

output "location" {
  description = "Resource group region."
  value       = azurerm_resource_group.fleet.location
}
