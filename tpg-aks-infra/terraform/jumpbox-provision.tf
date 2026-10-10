# Jumpbox provisioning over SSH (Round 16), jumpbox_setup_method = "remote-exec"
# only (with "cloud-init" the VM runs setup-jumpbox.sh at first boot instead,
# modules/jumpbox, and nothing here connects). Three steps, in order:
#
#   terraform_data.jumpbox_setup  enable_jumpbox (and jumpbox_provision): copy
#                                 scripts/ to ~/scripts, env.sh to ~/env.sh, the
#                                 generated ~/env.jumpbox.sh, ~/.work/inventory.yaml
#                                 and ~/.work/backup-ca-bundle.pem, then run
#                                 sudo ~/scripts/jumpbox/setup-jumpbox.sh
#   terraform_data.fleet_repo     create_fleet_repo: upload tpg-fleet.zip and run
#                                 ~/scripts/jumpbox/push-fleet-repo.sh
#   terraform_data.jumpbox_run    run_fleet_setup: ~/scripts/jumpbox/run-fleet-setup.sh,
#                                 which sources env.sh and runs scripts/run.sh
#                                 --hub install --targets terraform --expose-ui
#                                 --save-vault-recovery-keys
#
# A failed step taints only its terraform_data resource: the next apply runs it
# again, and the VM is never replaced for it. A step also runs again when its
# inputs change (triggers_replace): a new VM, a changed file under scripts/, a
# changed env.sh or inventory, a new tpg-fleet.zip.
#
# The machine running Terraform connects to the jumpbox's public IP on port 22,
# so it must be inside admin_allowed_cidrs. The secrets (git_admin_pat,
# broadcom_token, git_read_pat, git_push_pat) reach the VM only inside the
# remote-exec script, which Terraform writes to /dev/shm (memory) and which
# deletes itself as its first command; the scripts then hand them on in the
# environment. They are not in the Terraform state, but a saved plan file holds
# them.
#
# Logs (Round 19): each remote-exec step prints a header, runs its script with
# stderr merged into stdout, so every line shows in the terraform apply output
# as it happens, and tees it to a log on the jumpbox. bash -o pipefail: the
# script's exit code, not tee's, ends the step. No provisioner block holds a
# sensitive value (tests/jumpbox checks it), as Terraform would then suppress
# the whole output; the connection's private key does not count.

locals {
  jumpbox_provision  = var.enable_jumpbox && var.jumpbox_provision && var.jumpbox_setup_method == "remote-exec"
  jumpbox_cloud_init = var.enable_jumpbox && var.jumpbox_provision && var.jumpbox_setup_method == "cloud-init"
  jumpbox_home       = "/home/${var.jumpbox_admin_username}"

  jumpbox_private_key = local.jumpbox_provision ? (
    var.jumpbox_ssh_private_key_path != null
    ? file(pathexpand(var.jumpbox_ssh_private_key_path))
    : module.jumpbox[0].generated_private_key
  ) : null

  # env.sh of this repository, or env.sh.example when there is none
  # (run_fleet_setup requires env.sh: see terraform_data.jumpbox_run).
  env_sh_path    = "${path.module}/../env.sh"
  env_sh_present = fileexists(local.env_sh_path)
  jumpbox_env_sh = file(local.env_sh_present ? local.env_sh_path : "${path.module}/../env.sh.example")

  fleet_zip_path = coalesce(var.fleet_zip_path, abspath("${path.module}/../../tpg-fleet.zip")) # absolute either way
  github_api_url = var.github_url == "https://github.com" ? "https://api.github.com" : "${var.github_url}/api/v3"
  fleet_repo_url = "${var.github_url}/${coalesce(var.fleet_repo_owner, "<owner>")}/${var.fleet_repo_name}.git"

  jumpbox_vault_keys_file = "${local.jumpbox_home}/.tpg/vault-keys.txt"

  # Read by scripts/lib/common.sh after env.sh, so these values win.
  jumpbox_env_override = <<-EOT
    # Written by Terraform (terraform/jumpbox-provision.tf); the next apply replaces it.
    # scripts/lib/common.sh reads it after env.sh, so these values win.
    export FLEET_LOCAL_DIR="${local.jumpbox_home}/tpg-fleet"
    export INVENTORY_PREBUILT="true"
    export VAULT_RECOVERY_KEYS_FILE="${local.jumpbox_vault_keys_file}"
    export JUMPBOX_IDENTITY_CLIENT_ID="${var.enable_jumpbox ? module.jumpbox[0].identity_client_id : ""}"
    export AZURE_SUBSCRIPTION_ID="${var.subscription_id}"
    %{~if var.create_fleet_repo}
    export FLEET_REPO_URL="${local.fleet_repo_url}"
    export FLEET_REPO_REVISION="${var.fleet_repo_branch}"
    export FLEET_REPO_OWNER="${var.fleet_repo_owner == null ? "" : var.fleet_repo_owner}"
    export FLEET_REPO_NAME="${var.fleet_repo_name}"
    export GITHUB_URL="${var.github_url}"
    export GITHUB_API_URL="${local.github_api_url}"
    export FLEET_VALIDATE_TFVARS="${var.fleet_repo_validate}"
    export FLEET_REPO_FORCE_TFVARS="${var.fleet_repo_force}"
    %{~endif}
  EOT

  # The inventory scripts/targets/terraform/inventory-from-terraform.sh builds
  # from terraform output, built here from the same values: the jumpbox has no
  # state (INVENTORY_PREBUILT=true). One difference: backup.keySource is az, as
  # the jumpbox identity (Contributor on the resource group) can list the keys.
  jumpbox_inventory = {
    subscriptionId    = var.subscription_id
    adminAllowedCidrs = var.admin_allowed_cidrs
    source            = "terraform"
    hub = {
      name             = module.aks[var.hub_cluster_name].name
      resourceGroup    = module.resource_group.name
      access           = "az"
      adminCredentials = true
      kubeconfig       = ""
      context          = ""
      egressCidrs      = module.network.hub_egress_ip != null ? ["${module.network.hub_egress_ip}/32"] : []
    }
    targets = [for t in local.target_names : {
      name             = t
      resourceGroup    = module.resource_group.name
      wave             = local.target_waves[t]
      access           = "az"
      adminCredentials = true
      kubeconfig       = ""
      context          = ""
      backupContainer  = "pg-backups-${t}"
    }]
    backup = {
      storageAccount   = module.storage.account_name
      resourceGroup    = module.resource_group.name
      createContainers = false
      keySource        = "az"
      logsContainer    = module.storage.logs_container
      httpsOnly        = var.backup_storage_https_only
      caBundleFile     = ".work/backup-ca-bundle.pem"
    }
    network = {
      acnsEnabled = var.acns_enabled
    }
    monitoring = {
      remoteWriteExposure     = local.byo ? "internal" : "public"
      extraSourceCidrs        = []
      azureMonitorWorkspaceId = module.monitoring.azure_monitor_workspace_id != null ? module.monitoring.azure_monitor_workspace_id : ""
      grafanaResourceGroup    = module.monitoring.grafana_name != null ? module.resource_group.name : ""
      grafanaName             = module.monitoring.grafana_name != null ? module.monitoring.grafana_name : ""
    }
    storage = {
      dataDiskSku = var.postgres_data_disk_sku
    }
    nodePools = local.node_pool_zones
    vault = merge(
      {
        unsealMode       = var.vault_unseal_mode
        exposure         = local.byo ? "internal" : "public"
        extraSourceCidrs = []
      },
      { for k, v in {
        azureKeyVault = {
          name     = try(module.vault_unseal[0].key_vault_name, "")
          keyName  = try(module.vault_unseal[0].key_name, "")
          tenantId = data.azurerm_client_config.current.tenant_id
          clientId = try(module.vault_identity[0].client_ids["id-vault"], "")
        }
      } : k => v if local.vault_akv },
    )
  }
  jumpbox_inventory_yaml = yamlencode(local.jumpbox_inventory)

  scripts_dir  = "${path.module}/../scripts"
  scripts_hash = sha256(join(",", [for f in sort(fileset(local.scripts_dir, "**")) : "${f}=${filesha256("${local.scripts_dir}/${f}")}"]))

  # Secrets for the remote-exec scripts: base64, so no value can break the shell
  # quoting. nonsensitive() only because Terraform would otherwise suppress the
  # provisioner output (the run.sh log); the values are never printed.
  b64_git_admin_pat  = nonsensitive(base64encode(var.git_admin_pat))
  b64_broadcom_token = nonsensitive(base64encode(var.broadcom_token))
  b64_git_read_pat   = nonsensitive(base64encode(var.git_read_pat))
  b64_git_push_pat   = nonsensitive(base64encode(var.git_push_pat))
}

# 1. Tools, scripts and settings
resource "terraform_data" "jumpbox_setup" {
  count = local.jumpbox_provision ? 1 : 0

  triggers_replace = {
    vm        = module.jumpbox[0].vm_id
    scripts   = local.scripts_hash
    env       = sha256(local.jumpbox_env_sh)
    override  = sha256(local.jumpbox_env_override)
    inventory = sha256(local.jumpbox_inventory_yaml)
    ca_bundle = sha256(module.storage.ca_bundle)
  }

  connection {
    type        = "ssh"
    host        = module.jumpbox[0].public_ip
    user        = var.jumpbox_admin_username
    private_key = local.jumpbox_private_key
    timeout     = "10m"
  }

  provisioner "remote-exec" {
    inline = [
      "set -e",
      "echo '== jumpbox_setup: copying scripts/, env.sh, env.jumpbox.sh and the inventory to the jumpbox'",
      "rm -rf \"$HOME/scripts\"",
      "mkdir -p \"$HOME/scripts\" \"$HOME/.work\"",
      "chmod 700 \"$HOME/.work\"",
    ]
  }

  # Trailing slash: the content of scripts/ goes into ~/scripts
  provisioner "file" {
    source      = "${local.scripts_dir}/"
    destination = "${local.jumpbox_home}/scripts"
  }

  provisioner "file" {
    content     = local.jumpbox_env_sh
    destination = "${local.jumpbox_home}/env.sh"
  }

  provisioner "file" {
    content     = local.jumpbox_env_override
    destination = "${local.jumpbox_home}/env.jumpbox.sh"
  }

  provisioner "file" {
    content     = local.jumpbox_inventory_yaml
    destination = "${local.jumpbox_home}/.work/inventory.yaml"
  }

  provisioner "file" {
    content     = "${trimsuffix(module.storage.ca_bundle, "\n")}\n"
    destination = "${local.jumpbox_home}/.work/backup-ca-bundle.pem"
  }

  # The file provisioner does not keep the executable bit
  provisioner "remote-exec" {
    inline = [
      "set -e",
      "chmod 600 \"$HOME/env.sh\" \"$HOME/env.jumpbox.sh\" \"$HOME/.work/inventory.yaml\"",
      "find \"$HOME/scripts\" -type f -name '*.sh' -exec chmod 755 {} +",
      "echo '== jumpbox_setup: sudo setup-jumpbox.sh (log on the jumpbox: /var/log/tpg-jumpbox/setup-<UTC>.log)'",
      "sudo install -d -m 0755 /var/log/tpg-jumpbox",
      "sudo bash -o pipefail -c \"bash '$HOME/scripts/jumpbox/setup-jumpbox.sh' 2>&1 | tee /var/log/tpg-jumpbox/setup-$(date -u +%Y%m%dT%H%M%SZ).log\"",
    ]
  }

  depends_on = [module.jumpbox]
}

# 2. The fleet repository
resource "terraform_data" "fleet_repo" {
  count = local.jumpbox_provision && var.create_fleet_repo ? 1 : 0

  triggers_replace = {
    vm     = module.jumpbox[0].vm_id
    zip    = fileexists(local.fleet_zip_path) ? filesha256(local.fleet_zip_path) : "" # missing: the precondition below
    repo   = local.fleet_repo_url
    branch = var.fleet_repo_branch
  }

  lifecycle {
    precondition {
      condition     = fileexists(local.fleet_zip_path)
      error_message = "create_fleet_repo: ${local.fleet_zip_path} not found; set fleet_zip_path to tpg-fleet.zip."
    }
    precondition {
      condition     = var.git_admin_pat != ""
      error_message = "create_fleet_repo needs the GitHub token that creates the repository: export TF_VAR_git_admin_pat."
    }
  }

  connection {
    type        = "ssh"
    host        = module.jumpbox[0].public_ip
    user        = var.jumpbox_admin_username
    private_key = local.jumpbox_private_key
    timeout     = "10m"
    # The script below carries a token: memory only, and it deletes itself first
    script_path = "/dev/shm/tpg-terraform-%RAND%.sh"
  }

  provisioner "file" {
    source      = local.fleet_zip_path
    destination = "${local.jumpbox_home}/tpg-fleet.zip"
  }

  provisioner "remote-exec" {
    inline = [
      "rm -f -- \"$0\"",
      "set -e",
      "GIT_ADMIN_PAT=\"$(printf '%s' '${local.b64_git_admin_pat}' | base64 -d)\"",
      "export GIT_ADMIN_PAT",
      "mkdir -p \"$HOME/.work/logs\"",
      "echo \"== fleet_repo: push-fleet-repo.sh (log on the jumpbox: $HOME/.work/logs/push-fleet-repo-<UTC>.log)\"",
      "exec bash -o pipefail -c 'bash \"$HOME/scripts/jumpbox/push-fleet-repo.sh\" \"$HOME/tpg-fleet.zip\" 2>&1 | tee \"$HOME/.work/logs/push-fleet-repo-$(date -u +%Y%m%dT%H%M%SZ).log\"'",
    ]
  }

  depends_on = [terraform_data.jumpbox_setup]
}

# 3. scripts/run.sh from the jumpbox, once every cluster and role assignment exists
resource "terraform_data" "jumpbox_run" {
  count = local.jumpbox_provision && var.run_fleet_setup ? 1 : 0

  triggers_replace = {
    setup = terraform_data.jumpbox_setup[0].id
    repo  = var.create_fleet_repo ? terraform_data.fleet_repo[0].id : ""
  }

  lifecycle {
    precondition {
      condition     = local.env_sh_present
      error_message = "run_fleet_setup uploads env.sh of tpg-aks-infra (GITHUB_USER, BROADCOM_USER, MONITORING_OPTION, ...): copy env.sh.example to env.sh and edit it first."
    }
    precondition {
      condition     = var.broadcom_token != "" && var.git_read_pat != "" && var.git_push_pat != ""
      error_message = "run_fleet_setup needs the hub-secrets tokens: export TF_VAR_broadcom_token, TF_VAR_git_read_pat and TF_VAR_git_push_pat."
    }
  }

  connection {
    type        = "ssh"
    host        = module.jumpbox[0].public_ip
    user        = var.jumpbox_admin_username
    private_key = local.jumpbox_private_key
    timeout     = "10m"
    # The script below carries tokens: memory only, and it deletes itself first
    script_path = "/dev/shm/tpg-terraform-%RAND%.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "rm -f -- \"$0\"",
      "set -e",
      "BROADCOM_TOKEN=\"$(printf '%s' '${local.b64_broadcom_token}' | base64 -d)\"",
      "GIT_READ_PAT=\"$(printf '%s' '${local.b64_git_read_pat}' | base64 -d)\"",
      "GIT_PUSH_PAT=\"$(printf '%s' '${local.b64_git_push_pat}' | base64 -d)\"",
      "export BROADCOM_TOKEN GIT_READ_PAT GIT_PUSH_PAT",
      "echo \"== jumpbox_run: run-fleet-setup.sh, then scripts/run.sh (log on the jumpbox: $HOME/.work/fleet-setup/run-<UTC>.log)\"",
      "exec bash \"$HOME/scripts/jumpbox/run-fleet-setup.sh\" --hub install --targets terraform --expose-ui --save-vault-recovery-keys 2>&1",
    ]
  }

  depends_on = [
    terraform_data.jumpbox_setup,
    terraform_data.fleet_repo,
    module.aks,
    module.jumpbox,
    module.cluster_identities,
    module.monitoring,
    module.storage,
    module.vault_identity,
    azurerm_key_vault_access_policy.vault_unseal,
  ]
}
