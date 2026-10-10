locals {
  byo = var.network_mode == "byo"

  # The cluster subnets take slots 0..target_cluster_count (at most 0..60) of
  # the 64 cidrsubnet(vnet_cidr, 6, index) slots. The jumpbox uses the start of
  # the last slot (63), which no cluster can reach: a /27 for a /16 VNet, or the
  # whole slot when the slot is smaller than a /27.
  jumpbox_slot        = cidrsubnet(var.vnet_cidr, 6, 63)
  jumpbox_slot_bits   = tonumber(split("/", local.jumpbox_slot)[1])
  jumpbox_subnet_cidr = cidrsubnet(local.jumpbox_slot, max(0, 27 - local.jumpbox_slot_bits), 0)
}

# network_mode = "byo": one VNet with a /22 subnet per cluster and a static
# hub egress IP. network_mode = "managed": nothing is created here; AKS creates
# a managed VNet per cluster in its node resource group.
resource "azurerm_virtual_network" "fleet" {
  count = local.byo ? 1 : 0

  name                = "vnet-${var.prefix}"
  location            = var.location
  resource_group_name = var.resource_group_name
  address_space       = [var.vnet_cidr]
  tags                = var.tags
}

resource "azurerm_subnet" "cluster" {
  for_each = local.byo ? var.subnet_indexes : {}

  name                 = "snet-${each.key}"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.fleet[0].name
  address_prefixes     = [cidrsubnet(var.vnet_cidr, 6, each.value)]
}

# Operator jumpbox (enable_jumpbox, byo mode). In managed mode the jumpbox
# module creates its own VNet with the same address range.
resource "azurerm_subnet" "jumpbox" {
  count = local.byo && var.jumpbox_subnet_enabled ? 1 : 0

  name                 = "snet-jumpbox"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.fleet[0].name
  address_prefixes     = [local.jumpbox_subnet_cidr]
}

# Static outbound IP of the hub. Target API servers add it to their authorized
# IP ranges so Argo CD and Argo Workflows on the hub can reach them.
resource "azurerm_public_ip" "hub_egress" {
  count = local.byo ? 1 : 0

  name                = "pip-${var.hub_cluster_name}-egress"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = var.availability_zones
  tags                = var.tags
}
