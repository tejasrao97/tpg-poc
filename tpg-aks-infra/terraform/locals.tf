locals {
  resource_group_name = coalesce(var.resource_group_name, "rg-${var.prefix}")

  target_names = [
    for i in range(var.target_cluster_count) : format("%s-%02d", var.target_cluster_prefix, i + 1)
  ]

  # Wave 0 is the canary (first target). All other targets start in wave 1.
  target_waves = { for i, name in local.target_names : name => (i == 0 ? 0 : 1) }

  # Subnet index 0 is the hub; targets use index 1..n.
  clusters = merge(
    { (var.hub_cluster_name) = { role = "hub", subnet_index = 0 } },
    { for i, name in local.target_names : name => { role = "target", subnet_index = i + 1 } }
  )

  byo = var.network_mode == "byo"

  # Public API servers: explicit public mode, 0.0.0.0/0 in the allow list, or managed networking.
  api_public = (
    var.api_access_mode == "public" ||
    contains(var.admin_allowed_cidrs, "0.0.0.0/0") ||
    !local.byo
  )

  # The jumpbox (enable_jumpbox) reaches every API server from its static IP.
  jumpbox_cidrs = var.enable_jumpbox ? [module.jumpbox[0].public_cidr] : []

  hub_authorized_ranges    = local.api_public ? [] : concat(var.admin_allowed_cidrs, local.jumpbox_cidrs)
  target_authorized_ranges = local.api_public ? [] : concat(var.admin_allowed_cidrs, local.jumpbox_cidrs, compact([module.network.hub_egress_cidr]))

  vault_akv = var.vault_unseal_mode == "azure-keyvault"

  tags = var.tags

  # Output node_pool_zones, and nodePools of the jumpbox inventory (jumpbox-provision.tf)
  node_pool_zones = {
    system = {
      zones      = var.system_pool.zones
      node_count = var.system_pool.node_count
      min_count  = var.system_pool.min_count
      max_count  = var.system_pool.max_count
    }
    pgdata = {
      zones      = var.postgres_pool.zones
      node_count = var.postgres_pool.node_count
      min_count  = var.postgres_pool.min_count
      max_count  = var.postgres_pool.max_count
      # tpg-day0 refuses highAvailability=true on a cluster whose pgdata pool
      # does not span 3 zones with 3 nodes.
      supports_high_availability = length(var.postgres_pool.zones) >= 3 && var.postgres_pool.node_count >= 3
    }
  }
}
