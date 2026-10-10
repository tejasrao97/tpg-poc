# Container Insights (Log Analytics) and, optionally, Azure Monitor managed
# Prometheus with Azure Managed Grafana (monitoring option A).

# ---------------------------------------------------------------------------
# Container Insights
# ---------------------------------------------------------------------------
resource "azurerm_log_analytics_workspace" "container_logs" {
  count = var.enable_container_insights ? 1 : 0

  name                = "log-${var.prefix}"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = "PerGB2018"
  retention_in_days   = var.log_retention_days
  tags                = var.tags
}

resource "azurerm_monitor_data_collection_rule" "container_insights" {
  count = var.enable_container_insights ? 1 : 0

  name                = "MSCI-${var.location}-${var.prefix}"
  location            = var.location
  resource_group_name = var.resource_group_name
  description         = "Container Insights collection (Tanzu Postgres POC)"
  tags                = var.tags

  destinations {
    log_analytics {
      workspace_resource_id = azurerm_log_analytics_workspace.container_logs[0].id
      name                  = "ciworkspace"
    }
  }

  data_flow {
    streams      = ["Microsoft-ContainerInsights-Group-Default"]
    destinations = ["ciworkspace"]
  }

  data_sources {
    extension {
      name           = "ContainerInsightsExtension"
      extension_name = "ContainerInsights"
      streams        = ["Microsoft-ContainerInsights-Group-Default"]
      extension_json = jsonencode({
        dataCollectionSettings = {
          interval               = "1m"
          namespaceFilteringMode = "Off"
          enableContainerLogV2   = true
        }
      })
    }
  }
}

resource "azurerm_monitor_data_collection_rule_association" "container_insights" {
  for_each = var.enable_container_insights ? var.cluster_ids : {}

  name                    = "ContainerInsightsExtension"
  target_resource_id      = each.value
  data_collection_rule_id = azurerm_monitor_data_collection_rule.container_insights[0].id
  description             = "Container Insights collection for ${each.key}."
}

# ---------------------------------------------------------------------------
# Managed Prometheus and Managed Grafana
# ---------------------------------------------------------------------------
resource "azurerm_monitor_workspace" "prometheus" {
  count = var.enable_azure_monitor ? 1 : 0

  name                = "amw-${var.prefix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

resource "azurerm_monitor_data_collection_endpoint" "prometheus" {
  count = var.enable_azure_monitor ? 1 : 0

  name                = "MSProm-${var.location}-${var.prefix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  kind                = "Linux"
  tags                = var.tags
}

resource "azurerm_monitor_data_collection_rule" "prometheus" {
  count = var.enable_azure_monitor ? 1 : 0

  name                        = "MSProm-${var.location}-${var.prefix}"
  resource_group_name         = var.resource_group_name
  location                    = var.location
  data_collection_endpoint_id = azurerm_monitor_data_collection_endpoint.prometheus[0].id
  kind                        = "Linux"
  description                 = "Managed Prometheus collection (Tanzu Postgres POC)"
  tags                        = var.tags

  destinations {
    monitor_account {
      monitor_account_id = azurerm_monitor_workspace.prometheus[0].id
      name               = "MonitoringAccount1"
    }
  }

  data_flow {
    streams      = ["Microsoft-PrometheusMetrics"]
    destinations = ["MonitoringAccount1"]
  }

  data_sources {
    prometheus_forwarder {
      streams = ["Microsoft-PrometheusMetrics"]
      name    = "PrometheusDataSource"
    }
  }
}

resource "azurerm_monitor_data_collection_rule_association" "prometheus" {
  for_each = var.enable_azure_monitor ? var.cluster_ids : {}

  name                    = "MSProm-${each.key}"
  target_resource_id      = each.value
  data_collection_rule_id = azurerm_monitor_data_collection_rule.prometheus[0].id
  description             = "Managed Prometheus collection for ${each.key}."
}

resource "azurerm_dashboard_grafana" "grafana" {
  count = var.enable_azure_monitor ? 1 : 0

  name                  = "amg-${var.prefix}"
  resource_group_name   = var.resource_group_name
  location              = var.location
  grafana_major_version = var.grafana_major_version
  sku                   = "Standard"
  api_key_enabled       = true
  tags                  = var.tags

  identity {
    type = "SystemAssigned"
  }

  azure_monitor_workspace_integrations {
    resource_id = azurerm_monitor_workspace.prometheus[0].id
  }
}

# Both assignments need Microsoft.Authorization/roleAssignments/write. With
# create_role_assignments = false they are skipped and listed in the root
# module output role_assignments_to_create instead.
resource "azurerm_role_assignment" "grafana_monitoring_data_reader" {
  count = var.enable_azure_monitor && var.create_role_assignments ? 1 : 0

  scope                = azurerm_monitor_workspace.prometheus[0].id
  role_definition_name = "Monitoring Data Reader"
  principal_id         = azurerm_dashboard_grafana.grafana[0].identity[0].principal_id
}

resource "azurerm_role_assignment" "grafana_admin" {
  count = var.enable_azure_monitor && var.create_role_assignments ? 1 : 0

  scope                = azurerm_dashboard_grafana.grafana[0].id
  role_definition_name = "Grafana Admin"
  principal_id         = var.grafana_admin_object_id
}
