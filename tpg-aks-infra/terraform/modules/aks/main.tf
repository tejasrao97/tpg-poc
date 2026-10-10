locals {
  autoscale = var.autoscaling.enabled

  # Maintenance windows only apply when the matching channel is active.
  auto_upgrade_window = var.upgrade.automatic_channel != null && var.upgrade.maintenance_window != null
  node_os_window      = !contains(["None", "Unmanaged"], var.upgrade.node_os_channel) && var.upgrade.maintenance_window != null
}

resource "azurerm_kubernetes_cluster" "cluster" {
  name                         = var.name
  location                     = var.location
  resource_group_name          = var.resource_group_name
  dns_prefix                   = var.name
  kubernetes_version           = var.kubernetes_version
  sku_tier                     = var.sku_tier
  node_resource_group          = var.node_resource_group
  local_account_disabled       = false
  oidc_issuer_enabled          = true
  workload_identity_enabled    = var.workload_identity_enabled
  image_cleaner_enabled        = var.image_cleaner.enabled
  image_cleaner_interval_hours = var.image_cleaner.enabled ? var.image_cleaner.interval_hours : null
  azure_policy_enabled         = var.azure_policy_enabled
  automatic_upgrade_channel    = var.upgrade.automatic_channel
  node_os_upgrade_channel      = var.upgrade.node_os_channel
  tags                         = var.tags

  default_node_pool {
    name                         = "system"
    vm_size                      = var.system_pool.vm_size
    os_sku                       = var.os_sku
    os_disk_type                 = var.system_pool.os_disk_type
    os_disk_size_gb              = var.system_pool.os_disk_size_gb
    max_pods                     = var.system_pool.max_pods
    zones                        = var.system_pool.zones
    vnet_subnet_id               = var.subnet_id
    only_critical_addons_enabled = var.system_pool.only_critical_addons
    auto_scaling_enabled         = local.autoscale
    node_count                   = var.system_pool.node_count
    min_count                    = local.autoscale ? var.system_pool.min_count : null
    max_count                    = local.autoscale ? var.system_pool.max_count : null
    temporary_name_for_rotation  = "systemtmp"
    tags                         = var.tags

    upgrade_settings {
      max_surge = var.upgrade.max_surge
    }
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [var.identity_id]
  }

  # An empty list leaves the public API server open to all addresses.
  api_server_access_profile {
    authorized_ip_ranges = var.authorized_ip_ranges
  }

  dynamic "auto_scaler_profile" {
    for_each = local.autoscale ? [var.auto_scaler_profile] : []
    content {
      expander                      = auto_scaler_profile.value.expander
      balance_similar_node_groups   = auto_scaler_profile.value.balance_similar_node_groups
      scale_down_unneeded           = auto_scaler_profile.value.scale_down_unneeded
      scale_down_delay_after_add    = auto_scaler_profile.value.scale_down_delay_after_add
      skip_nodes_with_local_storage = auto_scaler_profile.value.skip_nodes_with_local_storage
      max_node_provisioning_time    = auto_scaler_profile.value.max_node_provisioning_time
    }
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_data_plane  = "cilium"
    network_policy      = "cilium"
    pod_cidr            = var.network.pod_cidr
    service_cidr        = var.network.service_cidr
    dns_service_ip      = var.network.dns_service_ip
    load_balancer_sku   = "standard"
    outbound_type       = "loadBalancer"

    load_balancer_profile {
      outbound_ip_address_ids   = length(var.outbound_ip_address_ids) > 0 ? var.outbound_ip_address_ids : null
      managed_outbound_ip_count = length(var.outbound_ip_address_ids) > 0 ? null : 1
      backend_pool_type         = "NodeIPConfiguration"
    }

    # Advanced Container Networking Services (ACNS): FQDN filtering in
    # CiliumNetworkPolicy (toFQDNs), used by the Postgres network policies for
    # the backup storage egress and egressToFqdns. A paid AKS feature, off by default.
    dynamic "advanced_networking" {
      for_each = var.acns_enabled ? [1] : []
      content {
        security_enabled      = true
        observability_enabled = false
      }
    }
  }

  dynamic "oms_agent" {
    for_each = var.log_analytics_workspace_id != null ? [1] : []
    content {
      log_analytics_workspace_id      = var.log_analytics_workspace_id
      msi_auth_for_monitoring_enabled = true
    }
  }

  dynamic "monitor_metrics" {
    for_each = var.monitor_metrics_enabled ? [1] : []
    content {
      annotations_allowed = null
      labels_allowed      = null
    }
  }

  dynamic "maintenance_window_auto_upgrade" {
    for_each = local.auto_upgrade_window ? [var.upgrade.maintenance_window] : []
    content {
      frequency   = "Weekly"
      interval    = 1
      day_of_week = maintenance_window_auto_upgrade.value.day_of_week
      start_time  = maintenance_window_auto_upgrade.value.start_time
      duration    = maintenance_window_auto_upgrade.value.duration_hours
      utc_offset  = maintenance_window_auto_upgrade.value.utc_offset
    }
  }

  dynamic "maintenance_window_node_os" {
    for_each = local.node_os_window ? [var.upgrade.maintenance_window] : []
    content {
      frequency   = "Weekly"
      interval    = 1
      day_of_week = maintenance_window_node_os.value.day_of_week
      start_time  = maintenance_window_node_os.value.start_time
      duration    = maintenance_window_node_os.value.duration_hours
      utc_offset  = maintenance_window_node_os.value.utc_offset
    }
  }

  lifecycle {
    ignore_changes = [default_node_pool[0].node_count]
  }
}

resource "azurerm_kubernetes_cluster_node_pool" "user" {
  for_each = var.user_pools

  name                        = each.key
  kubernetes_cluster_id       = azurerm_kubernetes_cluster.cluster.id
  mode                        = "User"
  vm_size                     = each.value.vm_size
  os_sku                      = var.os_sku
  os_disk_type                = each.value.os_disk_type
  os_disk_size_gb             = each.value.os_disk_size_gb
  max_pods                    = each.value.max_pods
  zones                       = each.value.zones
  vnet_subnet_id              = var.subnet_id
  auto_scaling_enabled        = local.autoscale
  node_count                  = each.value.node_count
  min_count                   = local.autoscale ? each.value.min_count : null
  max_count                   = local.autoscale ? each.value.max_count : null
  scale_down_mode             = "Delete"
  temporary_name_for_rotation = "${substr(each.key, 0, 9)}tmp"
  node_labels                 = each.value.node_labels
  node_taints                 = each.value.node_taints
  tags                        = var.tags

  # AKS allows only one of max_surge or max_unavailable; maxUnavailable stays 0.
  upgrade_settings {
    max_surge = var.upgrade.max_surge
  }

  lifecycle {
    ignore_changes = [node_count]
  }
}
