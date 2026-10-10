resource "random_string" "suffix" {
  length  = 6
  lower   = true
  upper   = false
  numeric = true
  special = false
}

# pgBackRest repository used by PostgresBackupLocation (spec.storage.azure), and
# the archived Argo Workflows logs (container argo-logs).
resource "azurerm_storage_account" "backups" {
  name                     = substr("${var.prefix}bkp${random_string.suffix.result}", 0, 24)
  resource_group_name      = var.resource_group_name
  location                 = var.location
  account_kind             = "StorageV2"
  account_tier             = "Standard"
  account_replication_type = var.replication_type
  min_tls_version          = "TLS1_2"
  # false by default: the Postgres backup locations use enableSSL: false (plain
  # HTTP) unless a cluster or instance sets it to true. HTTPS keeps working and
  # is still limited to TLS 1.2 or later.
  https_traffic_only_enabled      = var.https_only
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = true # the operator authenticates with keyType: shared
  tags                            = var.tags

  blob_properties {
    delete_retention_policy {
      days = var.soft_delete_days
    }
    container_delete_retention_policy {
      days = var.soft_delete_days
    }
  }
}

resource "azurerm_storage_container" "backups" {
  for_each = toset(var.container_names)

  name                  = each.key
  storage_account_id    = azurerm_storage_account.backups.id
  container_access_type = "private"
}

# Archived Argo Workflows logs: the hub artifact repository (ConfigMap
# argo/artifact-repositories, archiveLogs: true) writes every step's log here.
resource "azurerm_storage_container" "argo_logs" {
  name                  = var.logs_container_name
  storage_account_id    = azurerm_storage_account.backups.id
  container_access_type = "private"
}

# Deletes archived logs older than logs_retention_days. Only the argo-logs/
# prefix is covered: the pgBackRest repositories are expired by pgBackRest (the
# backup location's retentionPolicy), never by a lifecycle rule.
resource "azurerm_storage_management_policy" "argo_logs" {
  count = var.logs_retention_days > 0 ? 1 : 0

  storage_account_id = azurerm_storage_account.backups.id

  rule {
    name    = "expire-argo-logs"
    enabled = true
    filters {
      prefix_match = ["${var.logs_container_name}/"]
      blob_types   = ["blockBlob"]
    }
    actions {
      base_blob {
        delete_after_days_since_modification_greater_than = var.logs_retention_days
      }
    }
  }
}

# ---- CA bundle for PostgresBackupLocation enableSSL: true (design decision D63)
# pgBackRest verifies the blob endpoint against spec.storage.azure.caBundle. A TLS
# server does not send its root certificate, so the chain read from the endpoint
# alone cannot verify anything. The bundle is therefore the set of root
# certificate authorities Microsoft publishes for Azure services
# (https://learn.microsoft.com/azure/security/fundamentals/azure-ca-details),
# kept in azure-ca-roots.pem, and Terraform checks against the live endpoint that
# its chain is issued under one of them. A new intermediate CA from Azure changes
# nothing; a root outside the set fails the apply with the issuer it found.
locals {
  azure_ca_roots_pem = file("${path.module}/azure-ca-roots.pem")
  azure_ca_roots = {
    for i, pem in regexall("-----BEGIN CERTIFICATE-----[^-]+-----END CERTIFICATE-----", local.azure_ca_roots_pem) :
    tostring(i) => "${pem}\n"
  }
}

data "tls_certificate" "azure_ca_root" {
  for_each = local.azure_ca_roots
  content  = each.value
}

# The chain the blob endpoint of the new account presents (read at apply time).
# tls:// is a TLS handshake only; https:// would also send an HTTP HEAD request.
data "tls_certificate" "blob_endpoint" {
  url          = "tls://${azurerm_storage_account.backups.name}.blob.core.windows.net:443"
  verify_chain = true

  lifecycle {
    postcondition {
      condition = length(self.certificates) > 0 && anytrue([
        for r in data.tls_certificate.azure_ca_root : anytrue([
          for c in self.certificates : c.issuer == r.certificates[0].subject || c.sha1_fingerprint == r.certificates[0].sha1_fingerprint
        ])
      ])
      error_message = "The blob endpoint of ${azurerm_storage_account.backups.name} presents a chain that is not issued under the Azure root certificate authorities in modules/storage/azure-ca-roots.pem (issuers: ${join("; ", [for c in self.certificates : c.issuer])}). Update azure-ca-roots.pem from https://learn.microsoft.com/azure/security/fundamentals/azure-ca-details."
    }
  }
}
