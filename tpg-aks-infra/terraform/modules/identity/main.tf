# User-assigned managed identities with optional role assignments and
# workload identity federated credentials.
#
# The root module calls this module twice:
#   - control plane identities (id-<cluster>), created before the clusters
#   - workload identities federated to the clusters' OIDC issuers, created after
locals {
  role_assignments = merge([
    for identity, cfg in var.identities : {
      for key, ra in cfg.roles : "${identity}/${key}" => merge(ra, { identity = identity })
    }
  ]...)

  federated_credentials = merge([
    for identity, cfg in var.identities : {
      for key, fc in cfg.federated_credentials : "${identity}/${key}" => merge(fc, { identity = identity, name = key })
    }
  ]...)
}

resource "azurerm_user_assigned_identity" "managed_identity" {
  for_each = var.identities

  name                = each.key
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

# Role assignments need Microsoft.Authorization/roleAssignments/write. With
# create_role_assignments = false they are skipped and the module outputs the
# az commands instead, so a deployment can finish without that permission.
resource "azurerm_role_assignment" "identity_role" {
  for_each = var.create_role_assignments ? local.role_assignments : {}

  scope                            = each.value.scope
  role_definition_name             = each.value.role
  principal_id                     = azurerm_user_assigned_identity.managed_identity[each.value.identity].principal_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}

resource "azurerm_federated_identity_credential" "workload_federation" {
  for_each = local.federated_credentials

  name                      = each.value.name
  user_assigned_identity_id = azurerm_user_assigned_identity.managed_identity[each.value.identity].id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = each.value.issuer
  subject                   = each.value.subject
}
