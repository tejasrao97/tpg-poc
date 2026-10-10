# OpenTofu test of the jumpbox wiring with mocked providers (no Azure).
# tests/jumpbox/run.sh copies it into a temporary copy of terraform/tests/.
# The AKS, monitoring and storage modules are replaced by fixed outputs: only
# the jumpbox, network, identity and resource group resources are planned.
mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id       = "00000000-0000-0000-0000-000000000001"
      object_id       = "00000000-0000-0000-0000-000000000002"
      subscription_id = "00000000-0000-0000-0000-000000000003"
    }
  }
  # The provider parses these IDs, so the mocks must look like Azure IDs.
  mock_resource "azurerm_resource_group" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/rg-tpgpoc" }
  }
  mock_resource "azurerm_virtual_network" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/rg-tpgpoc/providers/Microsoft.Network/virtualNetworks/vnet-mock" }
  }
  mock_resource "azurerm_subnet" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/rg-tpgpoc/providers/Microsoft.Network/virtualNetworks/vnet-mock/subnets/snet-mock" }
  }
  mock_resource "azurerm_public_ip" {
    defaults = {
      id         = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/rg-tpgpoc/providers/Microsoft.Network/publicIPAddresses/pip-mock"
      ip_address = "192.0.2.10"
    }
  }
  mock_resource "azurerm_user_assigned_identity" {
    defaults = {
      id           = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/rg-tpgpoc/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-mock"
      principal_id = "00000000-0000-0000-0000-00000000000a"
      client_id    = "00000000-0000-0000-0000-00000000000b"
    }
  }
  mock_resource "azurerm_network_interface" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/rg-tpgpoc/providers/Microsoft.Network/networkInterfaces/nic-mock" }
  }
  mock_resource "azurerm_network_security_group" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/rg-tpgpoc/providers/Microsoft.Network/networkSecurityGroups/nsg-mock" }
  }
}
mock_provider "random" {}
mock_provider "time" {}
mock_provider "tls" {}

override_module {
  target = module.aks
  outputs = {
    id                         = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/rg-tpgpoc/providers/Microsoft.ContainerService/managedClusters/aks-mock"
    name                       = "aks-mock"
    oidc_issuer_url            = "https://oidc.example/"
    node_resource_group        = "rg-tpgpoc-aks-mock-nodes"
    kubelet_identity_object_id = "00000000-0000-0000-0000-000000000004"
  }
}

override_module {
  target = module.monitoring
  outputs = {
    log_analytics_workspace_id = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/rg-tpgpoc/providers/Microsoft.OperationalInsights/workspaces/log-tpgpoc"
    azure_monitor_workspace_id = null
    grafana_name               = null
    grafana_endpoint           = null
    role_assignment_commands   = []
  }
}

override_module {
  target = module.storage
  outputs = {
    account_name          = "tpgpocbkpmock"
    account_id            = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/rg-tpgpoc/providers/Microsoft.Storage/storageAccounts/tpgpocbkpmock"
    containers            = {}
    primary_access_key    = "mock"
    logs_container        = "argo-logs"
    ca_bundle             = ""
    blob_endpoint_issuers = []
  }
}

# jumpbox_ssh_public_key below is a random 32-byte ed25519 public key made for
# this test; no private key exists for it. jumpbox_provision = false: the
# provisioners of jumpbox-provision.tf need a reachable VM, so the runs that
# turn it on use command = plan, which runs no provisioner.
variables {
  subscription_id     = "00000000-0000-0000-0000-000000000003"
  admin_allowed_cidrs = ["203.0.113.10/32"]
  vault_unseal_mode   = "shamir"
  jumpbox_provision   = false
}

run "disabled_by_default" {
  command = apply

  # byo, the mode with authorized IP ranges (it needs the role assignments)
  variables {
    network_mode            = "byo"
    create_role_assignments = true
  }

  assert {
    condition     = length(module.jumpbox) == 0 && output.jumpbox_public_ip == null && output.jumpbox_ssh_command == null && output.jumpbox_identity_client_id == null
    error_message = "enable_jumpbox = false must create no jumpbox and output nulls."
  }
  assert {
    condition     = jsonencode(local.hub_authorized_ranges) == jsonencode(["203.0.113.10/32"])
    error_message = "Without the jumpbox the hub ranges must be admin_allowed_cidrs only, got ${jsonencode(local.hub_authorized_ranges)}."
  }
}

run "byo_restricted" {
  command = apply

  variables {
    network_mode            = "byo"
    create_role_assignments = true
    enable_jumpbox          = true
    jumpbox_ssh_public_key  = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMUtCbxDqy8dck8Weu72EfuC+65lenVCyisbUppJ5znN test-only@example"
  }

  override_resource {
    target = module.jumpbox.azurerm_public_ip.jumpbox
    values = {
      id         = "/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/rg-tpgpoc/providers/Microsoft.Network/publicIPAddresses/pip-tpgpoc-jumpbox"
      ip_address = "198.51.100.7"
    }
  }

  assert {
    condition     = module.network.jumpbox_subnet_cidr == "10.10.252.0/27"
    error_message = "The jumpbox range of 10.10.0.0/16 must be 10.10.252.0/27 (start of slot 63), got ${module.network.jumpbox_subnet_cidr}."
  }
  assert {
    condition     = module.network.jumpbox_subnet_id != null
    error_message = "byo mode must create snet-jumpbox in the fleet VNet."
  }
  assert {
    condition     = contains(local.hub_authorized_ranges, "198.51.100.7/32") && contains(local.target_authorized_ranges, "198.51.100.7/32")
    error_message = "The jumpbox /32 must be in the hub and target authorized IP ranges."
  }
  assert {
    condition     = output.jumpbox_ssh_command == "ssh -i ~/.ssh/tpg-jumpbox tpgadmin@198.51.100.7" && output.jumpbox_public_ip == "198.51.100.7"
    error_message = "Unexpected jumpbox outputs: ${output.jumpbox_ssh_command}."
  }
  assert {
    condition     = output.jumpbox_identity_client_id == "00000000-0000-0000-0000-00000000000b"
    error_message = "jumpbox_identity_client_id must be the identity's client ID."
  }
  assert {
    condition     = length(module.jumpbox[0].role_assignment_commands) == 0 && length(output.role_assignments_to_create) == 0
    error_message = "With create_role_assignments = true no az commands are listed."
  }
}

run "without_role_assignments" {
  command = apply

  variables {
    enable_jumpbox          = true
    jumpbox_ssh_public_key  = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMUtCbxDqy8dck8Weu72EfuC+65lenVCyisbUppJ5znN test-only@example"
    create_role_assignments = false
    target_cluster_count    = 2
  }

  assert {
    # Contributor on the resource group; Cluster Admin and node resource group Reader on the hub and 2 targets
    condition     = length([for c in output.role_assignments_to_create : c if strcontains(c, "# id-jumpbox/")]) == 7
    error_message = "role_assignments_to_create must list 7 jumpbox commands, got ${jsonencode(output.role_assignments_to_create)}."
  }
  assert {
    condition     = length([for c in output.role_assignments_to_create : c if strcontains(c, "--role \"Azure Kubernetes Service Cluster Admin Role\"")]) == 3
    error_message = "One Cluster Admin command per cluster expected."
  }
  assert {
    condition     = length([for c in output.role_assignments_to_create : c if strcontains(c, "--role \"Reader\"") && strcontains(c, "-nodes")]) == 3
    error_message = "One Reader command per node resource group expected (managed mode: the outbound IPs Vault needs)."
  }
  assert {
    condition     = length([for c in output.role_assignments_to_create : c if strcontains(c, "Network Contributor")]) == 0
    error_message = "managed network mode with create_role_assignments = false lists no Network Contributor command."
  }
}

run "managed_network" {
  command = apply

  variables {
    enable_jumpbox         = true
    jumpbox_ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMUtCbxDqy8dck8Weu72EfuC+65lenVCyisbUppJ5znN test-only@example"
    network_mode           = "managed"
    jumpbox_os             = "rocky-9"
  }

  assert {
    condition     = module.network.jumpbox_subnet_id == null
    error_message = "managed mode has no fleet VNet: snet-jumpbox must not be created there."
  }
  assert {
    condition     = length(local.hub_authorized_ranges) == 0 && length(local.target_authorized_ranges) == 0
    error_message = "managed mode forces public API servers: no authorized ranges."
  }
  assert {
    condition     = output.jumpbox_public_ip != null
    error_message = "The jumpbox must exist in managed mode."
  }
}

run "generated_key_only" {
  command = apply

  variables {
    enable_jumpbox = true
  }

  assert {
    condition     = output.jumpbox_ssh_private_key != null && length(module.jumpbox) == 1
    error_message = "Without jumpbox_ssh_public_key the jumpbox must be created with the generated key, output jumpbox_ssh_private_key."
  }
  assert {
    condition     = length(terraform_data.jumpbox_setup) == 0
    error_message = "jumpbox_provision = false must plan no provisioning."
  }
}

run "private_key_path_needs_public_key" {
  command = plan

  variables {
    enable_jumpbox               = true
    jumpbox_ssh_private_key_path = "~/.ssh/id_ed25519"
  }

  expect_failures = [var.jumpbox_ssh_private_key_path]
}

run "run_fleet_setup_needs_role_assignments" {
  command = plan

  variables {
    enable_jumpbox          = true
    jumpbox_provision       = true
    run_fleet_setup         = true
    create_role_assignments = false
  }

  expect_failures = [var.run_fleet_setup]
}

run "create_fleet_repo_needs_owner" {
  command = plan

  variables {
    enable_jumpbox    = true
    jumpbox_provision = true
    create_fleet_repo = true
  }

  expect_failures = [var.fleet_repo_owner]
}

run "create_fleet_repo_needs_jumpbox" {
  command = plan

  variables {
    create_fleet_repo = true
    fleet_repo_owner  = "acme"
  }

  expect_failures = [var.create_fleet_repo]
}

run "defaults_round_19" {
  command = plan

  assert {
    condition     = var.create_role_assignments == false && var.enable_container_insights == false && var.jumpbox_setup_method == "remote-exec" && var.network_mode == "managed"
    error_message = "create_role_assignments and enable_container_insights default to false, jumpbox_setup_method to remote-exec, network_mode to managed."
  }
}

run "byo_needs_role_assignments" {
  command = plan

  variables {
    network_mode            = "byo"
    create_role_assignments = false
  }

  expect_failures = [var.network_mode]
}

run "cloud_init_method" {
  command = plan

  variables {
    enable_jumpbox       = true
    jumpbox_provision    = true
    jumpbox_setup_method = "cloud-init"
  }

  assert {
    condition     = length(terraform_data.jumpbox_setup) == 0 && output.jumpbox_env_override != null && output.jumpbox_inventory_yaml != null
    error_message = "cloud-init: no SSH provisioning, and the two outputs deploy.sh copy writes to the jumpbox."
  }
}

run "cloud_init_refuses_fleet_steps" {
  command = plan

  variables {
    enable_jumpbox       = true
    jumpbox_provision    = true
    jumpbox_setup_method = "cloud-init"
    create_fleet_repo    = true
    fleet_repo_owner     = "acme"
  }

  expect_failures = [var.jumpbox_setup_method]
}

run "jumpbox_inventory" {
  command = plan

  variables {
    enable_jumpbox    = true
    jumpbox_provision = true
  }

  assert {
    condition     = length(terraform_data.jumpbox_setup) == 1 && length(terraform_data.fleet_repo) == 0 && length(terraform_data.jumpbox_run) == 0
    error_message = "enable_jumpbox alone must plan jumpbox_setup only."
  }
  assert {
    condition     = local.jumpbox_inventory.backup.keySource == "az" && length(local.jumpbox_inventory.targets) == 3 && local.jumpbox_inventory.vault.unsealMode == "shamir"
    error_message = "The jumpbox inventory must use keySource az and list the 3 targets."
  }
  assert {
    condition     = !contains(keys(local.jumpbox_inventory.vault), "azureKeyVault")
    error_message = "shamir mode: the jumpbox inventory must have no vault.azureKeyVault."
  }
  assert {
    condition     = local.jumpbox_inventory.vault.exposure == "public" && local.jumpbox_inventory.monitoring.remoteWriteExposure == "public" && length(local.jumpbox_inventory.hub.egressCidrs) == 0
    error_message = "managed network mode: public Vault and gateway exposure, no hub egress CIDRs."
  }
  assert {
    condition     = strcontains(local.jumpbox_env_override, "export INVENTORY_PREBUILT=\"true\"") && strcontains(local.jumpbox_env_override, "export VAULT_RECOVERY_KEYS_FILE=\"/home/tpgadmin/.tpg/vault-keys.txt\"") && !strcontains(local.jumpbox_env_override, "FLEET_REPO_URL")
    error_message = "env.jumpbox.sh must set INVENTORY_PREBUILT and VAULT_RECOVERY_KEYS_FILE, and no FLEET_REPO_URL without create_fleet_repo: ${local.jumpbox_env_override}"
  }
}

run "fleet_zip_path_must_be_absolute" {
  command = plan

  variables {
    enable_jumpbox    = true
    jumpbox_provision = true
    create_fleet_repo = true
    fleet_repo_owner  = "acme"
    fleet_zip_path    = "../../tpg-fleet.zip"
  }

  expect_failures = [var.fleet_zip_path]
}

run "fleet_setup_needs_env_sh" {
  command = plan

  variables {
    create_role_assignments = true
    enable_jumpbox          = true
    jumpbox_provision       = true
    run_fleet_setup         = true
    broadcom_token          = "test-broadcom"
    git_read_pat            = "test-read"
    git_push_pat            = "test-push"
  }

  # the test copy has env.sh.example only
  expect_failures = [terraform_data.jumpbox_run]
}

run "fleet_repo" {
  command = plan

  variables {
    enable_jumpbox    = true
    jumpbox_provision = true
    create_fleet_repo = true
    fleet_repo_owner  = "acme"
    fleet_repo_branch = "release"
    git_admin_pat     = "test-admin" # fleet_zip_path null: tpg-fleet.zip next to the copy (tests/jumpbox/run.sh)
  }

  assert {
    condition     = length(terraform_data.fleet_repo) == 1 && length(terraform_data.jumpbox_run) == 0
    error_message = "create_fleet_repo alone must plan fleet_repo and no jumpbox_run."
  }
  assert {
    condition     = output.fleet_repo_url == "https://github.com/acme/poc-tpg-fleet-v15.git"
    error_message = "fleet_repo_url must be https://github.com/<owner>/<name>.git, got ${output.fleet_repo_url}."
  }
  assert {
    condition     = strcontains(local.jumpbox_env_override, "export FLEET_REPO_URL=\"https://github.com/acme/poc-tpg-fleet-v15.git\"") && strcontains(local.jumpbox_env_override, "export FLEET_REPO_REVISION=\"release\"") && strcontains(local.jumpbox_env_override, "export GITHUB_API_URL=\"https://api.github.com\"")
    error_message = "env.jumpbox.sh must carry the fleet repository settings: ${local.jumpbox_env_override}"
  }
  assert {
    condition     = !strcontains(local.jumpbox_env_override, "test-")
    error_message = "No token may be written to env.jumpbox.sh."
  }
}

run "private_key_refused" {
  command = plan

  variables {
    enable_jumpbox         = true
    jumpbox_ssh_public_key = "-----BEGIN OPENSSH PRIVATE KEY-----"
  }

  expect_failures = [var.jumpbox_ssh_public_key]
}
