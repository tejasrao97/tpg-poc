output "vnet_id" {
  description = "VNet ID (null in managed mode)."
  value       = try(azurerm_virtual_network.fleet[0].id, null)
}

output "vnet_name" {
  description = "VNet name (null in managed mode)."
  value       = try(azurerm_virtual_network.fleet[0].name, null)
}

output "subnet_ids" {
  description = "Map of cluster name to subnet ID (values are null in managed mode)."
  value       = { for name in keys(var.subnet_indexes) : name => try(azurerm_subnet.cluster[name].id, null) }
}

output "hub_egress_ip_id" {
  description = "Hub egress public IP ID (null in managed mode)."
  value       = try(azurerm_public_ip.hub_egress[0].id, null)
}

output "hub_egress_ip" {
  description = "Hub egress public IP address (null in managed mode)."
  value       = try(azurerm_public_ip.hub_egress[0].ip_address, null)
}

output "hub_egress_cidr" {
  description = "Hub egress IP as a /32 CIDR (null in managed mode)."
  value       = try("${azurerm_public_ip.hub_egress[0].ip_address}/32", null)
}

output "jumpbox_subnet_id" {
  description = "Subnet ID of snet-jumpbox (null in managed mode or when the jumpbox is disabled)."
  value       = try(azurerm_subnet.jumpbox[0].id, null)
}

output "jumpbox_subnet_cidr" {
  description = "Address range for the jumpbox: snet-jumpbox in byo mode, the jumpbox VNet in managed mode."
  value       = local.jumpbox_subnet_cidr
}
