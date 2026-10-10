# The single resource group that holds every resource this configuration
# creates. Azure places AKS node resources (VMSS, NICs, managed load balancers,
# managed VNets in network_mode = "managed") in a separate node resource group
# that AKS owns; those groups are named after this one and are deleted with
# their cluster.
resource "azurerm_resource_group" "fleet" {
  name     = var.name
  location = var.location
  tags     = var.tags
}
