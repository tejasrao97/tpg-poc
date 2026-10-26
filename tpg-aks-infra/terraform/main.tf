# Every resource below is created in the single resource group from
# module.resource_group. AKS additionally owns one node resource group per
# cluster (<resource group>-<cluster>-nodes); Azure requires it to be separate.

module "resource_group" {
  source = "./modules/resource-group"

  name     = local.resource_group_name
  location = var.location
  tags     = local.tags
}

module "network" {
  source = "./modules/network"

  network_mode        = var.network_mode
  prefix              = var.prefix
  resource_group_name = module.resource_group.name
  location            = module.resource_group.location
  vnet_cidr           = var.vnet_cidr
  subnet_indexes      = { for name, c in local.clusters : name => c.subnet_index }
  hub_cluster_name    = var.hub_cluster_name
  # snet-jumpbox, byo mode only (managed mode: the jumpbox module makes its own VNet)
  jumpbox_subnet_enabled = var.enable_jumpbox
  # The hub egress IP stays zone-redundant whatever the node pools span.
  availability_zones = ["1", "2", "3"]
  tags               = local.tags
}

# Control plane identities. In byo mode they need Network Contributor on their
# subnet (and the hub on its egress IP) before the clusters are created.
module "cluster_identities" {
  source = "./modules/identity"

  create_role_assignments = var.create_role_assignments

  resource_group_name = module.resource_group.name
  location            = module.resource_group.location
  tags                = local.tags

  identities = {
    for name, c in local.clusters : "id-${name}" => {
      roles = {
        for key, ra in {
          subnet      = { scope = module.network.subnet_ids[name], role = "Network Contributor" }
          "egress-ip" = { scope = module.network.hub_egress_ip_id, role = "Network Contributor" }
        } : key => ra if local.byo && (key == "subnet" || c.role == "hub")
      }
    }
  }
}

module "monitoring" {
  source = "./modules/monitoring"

  prefix                    = var.prefix
  resource_group_name       = module.resource_group.name
  location                  = module.resource_group.location
  cluster_ids               = { for name, m in module.aks : name => m.id }
  enable_container_insights = var.enable_container_insights
  log_retention_days        = var.log_retention_days
  enable_azure_monitor      = var.enable_azure_monitor
  grafana_major_version     = var.grafana_major_version
  grafana_admin_object_id   = data.azurerm_client_config.current.object_id
  create_role_assignments   = var.create_role_assignments
  tags                      = local.tags
}

module "aks" {
  source   = "./modules/aks"
  for_each = local.clusters

  name                = each.key
  resource_group_name = module.resource_group.name
  location            = module.resource_group.location
  node_resource_group = "${module.resource_group.name}-${each.key}-nodes"
  kubernetes_version  = var.kubernetes_version
  sku_tier            = var.sku_tier
  identity_id         = module.cluster_identities.ids["id-${each.key}"]
  subnet_id           = module.network.subnet_ids[each.key]

  authorized_ip_ranges    = each.value.role == "hub" ? local.hub_authorized_ranges : local.target_authorized_ranges
  outbound_ip_address_ids = each.value.role == "hub" && local.byo ? [module.network.hub_egress_ip_id] : []

  network = {
    pod_cidr       = var.pod_cidr
    service_cidr   = var.service_cidr
    dns_service_ip = var.dns_service_ip
  }

  os_sku              = var.os_sku
  acns_enabled        = var.acns_enabled
  autoscaling         = { enabled = var.enable_autoscaling }
  auto_scaler_profile = var.auto_scaler_profile

  system_pool = merge(var.system_pool, {
    # Targets keep application pods off the system pool.
    only_critical_addons = each.value.role == "target"
  })

  # Only target clusters get the pgdata user pool.
  user_pools = {
    for pool, cfg in {
      pgdata = merge(var.postgres_pool, {
        node_labels = { "tpg.fleet/pool" = "postgres" }
        node_taints = []
      })
    } : pool => cfg if each.value.role == "target"
  }

  upgrade = {
    max_surge          = var.upgrade_max_surge
    automatic_channel  = var.automatic_upgrade_channel
    node_os_channel    = var.node_os_upgrade_channel
    maintenance_window = var.maintenance_window
  }

  workload_identity_enabled  = var.enable_workload_identity
  image_cleaner              = { enabled = var.image_cleaner_interval_hours != null, interval_hours = coalesce(var.image_cleaner_interval_hours, 168) }
  azure_policy_enabled       = var.enable_azure_policy
  log_analytics_workspace_id = module.monitoring.log_analytics_workspace_id
  monitor_metrics_enabled    = var.enable_azure_monitor

  tags = each.value.role == "target" ? merge(local.tags, { "tpg.fleet-wave" = tostring(local.target_waves[each.key]) }) : local.tags

  depends_on = [module.cluster_identities]
}

module "storage" {
  source = "./modules/storage"

  prefix              = var.prefix
  resource_group_name = module.resource_group.name
  location            = module.resource_group.location
  container_names     = [for name in local.target_names : "pg-backups-${name}"]
  https_only          = var.backup_storage_https_only
  logs_container_name = "argo-logs"
  logs_retention_days = var.argo_logs_retention_days
  tags                = local.tags
}

# HashiCorp Vault auto-unseal (vault_unseal_mode = "azure-keyvault" only):
# Key Vault with an RSA key, and a workload identity for the Vault server pod
# (ServiceAccount vault/vault on the hub) with Key Vault Crypto User on it.
# With the default "shamir" mode none of this is created.
module "vault_unseal" {
  source = "./modules/keyvault"
  count  = local.vault_akv ? 1 : 0

  prefix                     = var.prefix
  resource_group_name        = module.resource_group.name
  location                   = module.resource_group.location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  deployer_object_id         = data.azurerm_client_config.current.object_id
  purge_protection_enabled   = var.key_vault_purge_protection
  soft_delete_retention_days = var.key_vault_soft_delete_days
  tags                       = local.tags
}

# The Vault workload identity. It needs no role assignment: the Key Vault grants
# it get, wrapKey and unwrapKey with an access policy below.
module "vault_identity" {
  source = "./modules/identity"
  count  = local.vault_akv ? 1 : 0

  resource_group_name = module.resource_group.name
  location            = module.resource_group.location
  tags                = local.tags

  identities = {
    "id-vault" = {
      roles = {}
      federated_credentials = {
        "vault-server" = {
          issuer  = module.aks[var.hub_cluster_name].oidc_issuer_url
          subject = "system:serviceaccount:vault:vault"
        }
      }
    }
  }
}

# Data-plane access for the Vault server pod: get, wrapKey and unwrapKey on the
# unseal key. An access policy instead of a role assignment, so the deployment
# needs no Microsoft.Authorization/roleAssignments/write.
resource "azurerm_key_vault_access_policy" "vault_unseal" {
  count = local.vault_akv ? 1 : 0

  key_vault_id = module.vault_unseal[0].key_vault_id
  tenant_id    = module.vault_unseal[0].tenant_id
  object_id    = module.vault_identity[0].principal_ids["id-vault"]

  key_permissions = ["Get", "WrapKey", "UnwrapKey"]

  # Destroyed before the Key Vault module (the key, the deployer's policy and
  # the vault itself), created after it.
  depends_on = [module.vault_unseal]
}

# Optional operator jumpbox (enable_jumpbox). byo mode: subnet snet-jumpbox in
# the fleet VNet; managed mode: a VNet of its own with the same address range.
# Its identity gets Contributor on the resource group, Cluster Admin on every
# cluster and Reader on every node resource group; its public /32 joins the API
# server authorized ranges (locals.tf).
# The tools, the fleet repository and the fleet setup: jumpbox-provision.tf.
module "jumpbox" {
  source = "./modules/jumpbox"
  count  = var.enable_jumpbox ? 1 : 0

  prefix              = var.prefix
  resource_group_name = module.resource_group.name
  location            = module.resource_group.location
  create_network      = !local.byo
  subnet_id           = module.network.jumpbox_subnet_id
  address_prefix      = module.network.jumpbox_subnet_cidr
  admin_allowed_cidrs = var.admin_allowed_cidrs
  admin_username      = var.jumpbox_admin_username
  ssh_public_key      = var.jumpbox_ssh_public_key
  os                  = var.jumpbox_os
  vm_size             = var.jumpbox_vm_size
  os_disk_gb          = var.jumpbox_os_disk_gb
  # jumpbox_setup_method = "cloud-init": setup-jumpbox.sh runs at first boot
  cloud_init_script = local.jumpbox_cloud_init ? file("${path.module}/../scripts/jumpbox/setup-jumpbox.sh") : null

  create_role_assignments = var.create_role_assignments
  role_assignments = merge(
    { "resource-group" = { scope = module.resource_group.id, role = "Contributor" } },
    { for name, m in module.aks : "aks-${name}" => { scope = m.id, role = "Azure Kubernetes Service Cluster Admin Role" } },
    # managed network mode: Vault and the remote-write gateway are public load
    # balancers limited to the targets' outbound IPs, which live in the node
    # resource groups (scripts/lib/vault.sh vault_target_source_cidrs)
    { for name, m in module.aks : "nodes-${name}" => { scope = "/subscriptions/${var.subscription_id}/resourceGroups/${m.node_resource_group}", role = "Reader" } },
  )

  tags = local.tags
}

# High availability places a primary, a standby and the read replicas on
# different nodes and zones. Terraform cannot know whether an HA instance will
# be deployed (tpg-day0 decides that later), so this is a warning: the Day 0
# pre-check reports a cluster BLOCKED when highAvailability=true and its pgdata
# pool cannot hold the instance. The system pool is not covered by the rule.
check "postgres_pool_supports_high_availability" {
  assert {
    condition = length(var.postgres_pool.zones) >= 3 && var.postgres_pool.node_count >= 3
    error_message = format(
      "postgres_pool spans %d zone(s) with %d node(s). Postgres instances deployed with highAvailability=true need 3 zones and 3 nodes; tpg-day0 will report such clusters BLOCKED (PGDATA_POOL_NOT_HA_CAPABLE). Single-node instances are unaffected.",
      length(var.postgres_pool.zones), var.postgres_pool.node_count
    )
  }
}
