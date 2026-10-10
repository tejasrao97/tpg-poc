# ---------------------------------------------------------------------------
# Subscription, naming and region
# ---------------------------------------------------------------------------
variable "subscription_id" {
  description = "Azure subscription ID that hosts all POC resources."
  type        = string
}

variable "location" {
  description = "Azure region for every resource. Must offer 3 availability zones."
  type        = string
  default     = "eastus2"
}

variable "prefix" {
  description = "Short lowercase prefix used in resource names."
  type        = string
  default     = "tpgpoc"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{2,10}$", var.prefix))
    error_message = "prefix must be 3-11 lowercase letters or digits and start with a letter."
  }
}

variable "resource_group_name" {
  description = "Name of the resource group created for every POC resource. null uses rg-<prefix>."
  type        = string
  default     = null
}

variable "hub_cluster_name" {
  description = "Name of the management (hub) AKS cluster that runs Argo CD and Argo Workflows."
  type        = string
  default     = "aks-tpg-hub"
}

variable "target_cluster_prefix" {
  description = "Prefix of the target AKS cluster names. Clusters are named <prefix>-01, -02, ..."
  type        = string
  default     = "aks-tpg-poc"
}

variable "target_cluster_count" {
  description = "Number of target AKS clusters (3 for the POC, raise to scale to n)."
  type        = number
  default     = 3

  validation {
    condition     = var.target_cluster_count >= 1 && var.target_cluster_count <= 60
    error_message = "target_cluster_count must be between 1 and 60."
  }
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default = {
    project     = "tanzu-postgres-gitops-poc"
    environment = "poc"
  }
}

# ---------------------------------------------------------------------------
# Access and networking
# ---------------------------------------------------------------------------
variable "network_mode" {
  description = <<-EOT
    managed (default since Round 19): AKS-managed VNets; forces public API servers (api_access_mode is
    not used), and needs no Network Contributor role assignments.
    byo: VNet, /22 subnet per cluster, static hub egress IP, API servers limited by api_access_mode. The
    control-plane identities need Network Contributor on their subnet (and the hub on its egress IP)
    before the clusters are created, so byo requires create_role_assignments = true.
  EOT
  type        = string
  default     = "managed"

  validation {
    condition     = contains(["byo", "managed"], var.network_mode)
    error_message = "network_mode must be byo or managed."
  }

  validation {
    condition     = var.network_mode != "byo" || var.create_role_assignments
    error_message = "network_mode = \"byo\" needs create_role_assignments = true: the cluster identities need Network Contributor on their subnets and the hub egress IP before AKS creates the clusters. Use network_mode = \"managed\", or run Terraform with an Owner or User Access Administrator account."
  }
}

variable "api_access_mode" {
  description = "network_mode byo only (managed always has public API servers). restricted: API servers accept admin_allowed_cidrs (targets also the hub egress IP). public: API servers accept all addresses."
  type        = string
  default     = "restricted"

  validation {
    condition     = contains(["restricted", "public"], var.api_access_mode)
    error_message = "api_access_mode must be restricted or public."
  }
}

variable "admin_allowed_cidrs" {
  description = "CIDRs allowed to reach the API servers (restricted mode) and the Argo UI load balancers. [\"0.0.0.0/0\"] also makes the API servers public."
  type        = list(string)

  validation {
    condition     = length(var.admin_allowed_cidrs) > 0 && alltrue([for c in var.admin_allowed_cidrs : can(cidrhost(c, 0))])
    error_message = "admin_allowed_cidrs must contain at least one valid CIDR."
  }
}

variable "vnet_cidr" {
  description = "Address space of the POC virtual network (byo mode). Each cluster gets a /22 subnet. The jumpbox range (enable_jumpbox) comes from its last /22 in both network modes."
  type        = string
  default     = "10.10.0.0/16"
}

variable "pod_cidr" {
  description = "Azure CNI Overlay pod CIDR (reused by every cluster; must not overlap the VNet)."
  type        = string
  default     = "192.168.0.0/16"
}

variable "service_cidr" {
  description = "Kubernetes service CIDR (reused by every cluster; must not overlap the VNet)."
  type        = string
  default     = "172.16.0.0/16"
}

variable "dns_service_ip" {
  description = "Cluster DNS service IP inside service_cidr."
  type        = string
  default     = "172.16.0.10"
}

# ---------------------------------------------------------------------------
# Clusters
# ---------------------------------------------------------------------------
variable "kubernetes_version" {
  description = "AKS Kubernetes version (for example 1.35). null selects the AKS default version for the region."
  type        = string
  default     = null
}

variable "sku_tier" {
  description = "AKS control plane tier: Free, Standard (uptime SLA) or Premium."
  type        = string
  default     = "Standard"

  validation {
    condition     = contains(["Free", "Standard", "Premium"], var.sku_tier)
    error_message = "sku_tier must be Free, Standard or Premium."
  }
}

variable "os_sku" {
  description = "Node OS SKU for every pool."
  type        = string
  default     = "Ubuntu2404"
}

variable "enable_autoscaling" {
  description = "Enable the cluster autoscaler on every node pool. Node counts are set per pool in system_pool and postgres_pool."
  type        = bool
  default     = true
}

variable "auto_scaler_profile" {
  description = "Cluster autoscaler profile (values match the portal defaults)."
  type = object({
    expander                      = optional(string, "random")
    balance_similar_node_groups   = optional(bool, false)
    scale_down_unneeded           = optional(string, "10m")
    scale_down_delay_after_add    = optional(string, "10m")
    skip_nodes_with_local_storage = optional(bool, false)
    max_node_provisioning_time    = optional(string, "15m")
  })
  default = {}
}

variable "system_pool" {
  description = <<-EOT
    System node pool of the hub and target clusters. Ephemeral OS disks must fit the VM cache or temp disk (Standard_D8ds_v5: 300 GiB temp).
    zones holds 1 to 3 of the availability zones "1", "2" and "3"; the pool is spread across them.
    node_count is the node count at creation; Terraform ignores later changes to it (the autoscaler owns it, and with autoscaling off use az aks nodepool scale).
    min_count and max_count bound the autoscaler. node_count and min_count are at least length(zones), so every selected zone can hold a node.
    The default is one zone and one node: the system pool runs no Postgres data, and the HA rule applies to postgres_pool only.
  EOT
  type = object({
    vm_size         = optional(string, "Standard_D8ds_v5")
    os_disk_type    = optional(string, "Ephemeral")
    os_disk_size_gb = optional(number, 300)
    max_pods        = optional(number, 110)
    zones           = optional(list(string), ["1"])
    node_count      = optional(number, 1)
    min_count       = optional(number, 1)
    max_count       = optional(number, 5)
  })
  default = {}

  validation {
    condition = (
      length(var.system_pool.zones) >= 1 && length(var.system_pool.zones) <= 3 &&
      length(setsubtract(var.system_pool.zones, ["1", "2", "3"])) == 0 &&
      length(distinct(var.system_pool.zones)) == length(var.system_pool.zones)
    )
    error_message = "system_pool.zones must hold 1 to 3 distinct values out of \"1\", \"2\" and \"3\"."
  }

  validation {
    condition     = var.system_pool.node_count >= length(var.system_pool.zones) && var.system_pool.min_count >= length(var.system_pool.zones)
    error_message = "system_pool.node_count and system_pool.min_count must be at least the number of zones in system_pool.zones (one node per zone)."
  }

  validation {
    condition     = var.system_pool.min_count <= var.system_pool.node_count && var.system_pool.node_count <= var.system_pool.max_count
    error_message = "system_pool needs min_count <= node_count <= max_count."
  }
}

variable "postgres_pool" {
  description = <<-EOT
    Target clusters' user node pool pgdata that runs Postgres pods.
    zones holds 1 to 3 of the availability zones "1", "2" and "3"; the pool is spread across them.
    node_count is the node count at creation; Terraform ignores later changes to it (the autoscaler owns it, and with autoscaling off use az aks nodepool scale).
    min_count and max_count bound the autoscaler. node_count and min_count are at least length(zones), so every selected zone can hold a node.
    High availability (tpg-day0 highAvailability=true) needs 3 zones and 3 nodes here; the check block in main.tf warns when this pool is smaller,
    and the Day 0 pre-check reports such a cluster BLOCKED instead of deploying an HA instance that cannot be scheduled.
  EOT
  type = object({
    vm_size         = optional(string, "Standard_D8ds_v5")
    os_disk_type    = optional(string, "Managed")
    os_disk_size_gb = optional(number, 256)
    max_pods        = optional(number, 30)
    zones           = optional(list(string), ["1", "2", "3"])
    node_count      = optional(number, 3)
    min_count       = optional(number, 3)
    max_count       = optional(number, 6)
  })
  default = {}

  validation {
    condition = (
      length(var.postgres_pool.zones) >= 1 && length(var.postgres_pool.zones) <= 3 &&
      length(setsubtract(var.postgres_pool.zones, ["1", "2", "3"])) == 0 &&
      length(distinct(var.postgres_pool.zones)) == length(var.postgres_pool.zones)
    )
    error_message = "postgres_pool.zones must hold 1 to 3 distinct values out of \"1\", \"2\" and \"3\"."
  }

  validation {
    condition     = var.postgres_pool.node_count >= length(var.postgres_pool.zones) && var.postgres_pool.min_count >= length(var.postgres_pool.zones)
    error_message = "postgres_pool.node_count and postgres_pool.min_count must be at least the number of zones in postgres_pool.zones (one node per zone)."
  }

  validation {
    condition     = var.postgres_pool.min_count <= var.postgres_pool.node_count && var.postgres_pool.node_count <= var.postgres_pool.max_count
    error_message = "postgres_pool needs min_count <= node_count <= max_count."
  }
}

variable "postgres_data_disk_sku" {
  description = <<-EOT
    Managed-disk SKU of the StorageClass tpg-data-retain, which holds the Postgres data and WAL volumes
    and the Vault server volume on the hub. Written to the inventory and applied by the fleet scripts.
    StandardSSD_LRS  Standard SSD, single zone; the cheapest option that Postgres can use
    StandardSSD_ZRS  Standard SSD replicated across zones
    Premium_LRS      Premium SSD, single zone
    Premium_ZRS      Premium SSD replicated across zones (default; a zone-redundant volume can be
                     reattached in another zone, which matters when a Postgres pod moves)
    PremiumV2_LRS    Premium SSD v2, single zone, configurable IOPS and throughput
    The ZRS options need a region with availability zones.
  EOT
  type        = string
  default     = "Premium_ZRS"

  validation {
    condition     = contains(["StandardSSD_LRS", "StandardSSD_ZRS", "Premium_LRS", "Premium_ZRS", "PremiumV2_LRS"], var.postgres_data_disk_sku)
    error_message = "postgres_data_disk_sku must be StandardSSD_LRS, StandardSSD_ZRS, Premium_LRS, Premium_ZRS or PremiumV2_LRS."
  }
}

variable "acns_enabled" {
  description = <<-EOT
    Advanced Container Networking Services on every cluster (network_profile advanced_networking,
    security). Needed for FQDN rules in CiliumNetworkPolicy: with it the Postgres network policies
    (tpg-network-policy, networkPolicy=baseline) allow backup egress to *.blob.core.windows.net only
    and accept egressToFqdns; without it backup egress is any address on 443 (and 80 while
    enableSSL is false). ACNS is a paid AKS feature.
  EOT
  type        = bool
  default     = false
}

variable "backup_storage_https_only" {
  description = <<-EOT
    "Secure transfer required" on the backup storage account. false (default) also accepts plain
    HTTP, which the Postgres backup locations use when enableSSL is false (the fleet default:
    clusters/_template/cluster.yaml backup.enableSSL, tpg-day0 backupEnableSSL). Set true when
    every instance uses enableSSL: true; Azure then refuses HTTP and an instance with
    enableSSL: false cannot back up. TLS 1.2 stays the minimum for HTTPS either way.
  EOT
  type        = bool
  default     = false
}

variable "argo_logs_retention_days" {
  description = <<-EOT
    Days the archived Argo Workflows logs (container argo-logs in the backup storage account) are
    kept before a lifecycle rule deletes them. 0 keeps them for ever (no rule).
  EOT
  type        = number
  default     = 90

  validation {
    condition     = var.argo_logs_retention_days >= 0 && var.argo_logs_retention_days <= 3650
    error_message = "argo_logs_retention_days must be between 0 and 3650."
  }
}

variable "create_role_assignments" {
  description = <<-EOT
    Create the Azure role assignments this deployment needs (Network Contributor for the cluster
    identities on the subnet and the hub public IP, and the monitoring roles). It requires
    Microsoft.Authorization/roleAssignments/write, which a Contributor does not have.
    With false, Terraform creates everything else and the output role_assignments_to_create lists
    the exact az commands for an owner; the preflight and verify steps then report what is missing.
    The Vault unseal Key Vault never needs this: it grants access with Key Vault access policies.
    Default false (Round 19): most accounts that run the POC are Contributors. Set true when the
    account is Owner or User Access Administrator; run_fleet_setup and network_mode = "byo" require true.
    With false (and so network_mode managed) the output lists the monitoring (Managed Grafana) and jumpbox
    assignments; the Network Contributor ones exist only with byo.
  EOT
  type        = bool
  default     = false
  nullable    = false
}

variable "upgrade_max_surge" {
  description = "Extra nodes added per pool during upgrades. maxUnavailable stays 0 (AKS accepts only one of the two)."
  type        = string
  default     = "10%"
}

variable "automatic_upgrade_channel" {
  description = "Cluster auto-upgrade channel: null (none), patch, stable, rapid or node-image. Off by default so upgrades never interrupt POC tests."
  type        = string
  default     = null
}

variable "node_os_upgrade_channel" {
  description = "Node OS upgrade channel: None, Unmanaged, SecurityPatch or NodeImage."
  type        = string
  default     = "None"
}

variable "maintenance_window" {
  description = "Weekly window for auto-upgrade and node OS upgrades; used only when a channel is active."
  type = object({
    day_of_week    = string
    start_time     = string
    duration_hours = number
    utc_offset     = string
  })
  default = {
    day_of_week    = "Sunday"
    start_time     = "00:00"
    duration_hours = 8
    utc_offset     = "+00:00"
  }
}

variable "enable_workload_identity" {
  description = "Enable Microsoft Entra Workload ID on every cluster."
  type        = bool
  default     = true
}

variable "image_cleaner_interval_hours" {
  description = "Image Cleaner interval in hours. null disables Image Cleaner."
  type        = number
  default     = 168
}

variable "enable_azure_policy" {
  description = "Enable the Azure Policy add-on on every cluster."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# Monitoring
# ---------------------------------------------------------------------------
variable "enable_container_insights" {
  description = "Create a Log Analytics workspace and enable Container Insights (managed identity auth) on every cluster. Default false (Round 19); nothing in the scripts or workflows depends on it."
  type        = bool
  default     = false
}

variable "log_retention_days" {
  description = "Log Analytics retention in days."
  type        = number
  default     = 30
}

variable "enable_azure_monitor" {
  description = "Create an Azure Monitor workspace and Azure Managed Grafana, and enable managed Prometheus on every cluster (monitoring option A)."
  type        = bool
  default     = false
}

variable "grafana_major_version" {
  description = "Azure Managed Grafana major version (11 or 12)."
  type        = number
  default     = 12
}

# ---------------------------------------------------------------------------
# Jumpbox (optional operator VM)
# ---------------------------------------------------------------------------
variable "enable_jumpbox" {
  description = <<-EOT
    Create a Linux VM for operators: static public IP, SSH (key only) from admin_allowed_cidrs,
    a managed identity with Contributor on the resource group and Azure Kubernetes Service
    Cluster Admin Role on every cluster. Terraform copies scripts/ and env.sh to the admin
    user's home over SSH and runs scripts/jumpbox/setup-jumpbox.sh there (jumpbox-provision.tf),
    so the machine running Terraform must be inside admin_allowed_cidrs. Its /32 is added to the
    API server authorized IP ranges when the API servers are restricted.
  EOT
  type        = bool
  default     = false
}

variable "jumpbox_ssh_public_key" {
  description = <<-EOT
    Optional OpenSSH public key of the jumpbox admin user (for example the content of
    ~/.ssh/id_ed25519.pub), authorized next to the key pair Terraform generates (output
    jumpbox_ssh_private_key).
  EOT
  type        = string
  default     = null

  validation {
    condition     = var.jumpbox_ssh_public_key == null || can(regex("^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)) [A-Za-z0-9+/=]+", var.jumpbox_ssh_public_key))
    error_message = "jumpbox_ssh_public_key must be an OpenSSH public key (ssh-ed25519, ssh-rsa or ecdsa-sha2-nistp*), not a private key or a file path."
  }
}

variable "jumpbox_ssh_private_key_path" {
  description = <<-EOT
    Optional path of the private key that matches jumpbox_ssh_public_key, used by the Terraform
    provisioners instead of the generated key. Read with file() at apply; null: the generated key.
  EOT
  type        = string
  default     = null

  validation {
    condition     = var.jumpbox_ssh_private_key_path == null || var.jumpbox_ssh_public_key != null
    error_message = "jumpbox_ssh_private_key_path needs jumpbox_ssh_public_key: the VM authorizes only the generated key and jumpbox_ssh_public_key."
  }
}

variable "jumpbox_setup_method" {
  description = <<-EOT
    How the jumpbox gets its tools (with jumpbox_provision = true):
      remote-exec  Terraform copies scripts/ and env.sh over SSH and runs setup-jumpbox.sh there;
                   its output is in the terraform apply output (terraform_data.jumpbox_setup).
                   Needed by create_fleet_repo and run_fleet_setup. deploy-scripts/terraform-enabled-deploy.sh.
      cloud-init   the VM's custom_data writes setup-jumpbox.sh to /home/<admin>/setup-jumpbox.sh and
                   runs it once at first boot (log: /var/log/cloud-init-output.log and
                   /var/log/tpg-jumpbox/setup-cloud-init.log); Terraform opens no SSH connection.
                   deploy-scripts/deploy.sh, whose copy step adds scripts/, env.sh and the rest.
  EOT
  type        = string
  default     = "remote-exec"

  validation {
    condition     = contains(["remote-exec", "cloud-init"], var.jumpbox_setup_method)
    error_message = "jumpbox_setup_method must be remote-exec or cloud-init."
  }

  validation {
    condition     = var.jumpbox_setup_method == "remote-exec" || (!var.create_fleet_repo && !var.run_fleet_setup)
    error_message = "create_fleet_repo and run_fleet_setup run over SSH after the jumpbox setup: they need jumpbox_setup_method = \"remote-exec\"."
  }
}

variable "jumpbox_provision" {
  description = <<-EOT
    Install the tools on the jumpbox, as jumpbox_setup_method says (remote-exec: copy scripts/ and env.sh
    and run setup-jumpbox.sh over SSH, terraform_data.jumpbox_setup; cloud-init: at first boot), and allow
    create_fleet_repo and run_fleet_setup (remote-exec only). false: the VM only, with no tools installed
    (tests/jumpbox uses it, as the provisioners need a reachable VM).
  EOT
  type        = bool
  default     = true
}

variable "jumpbox_admin_username" {
  description = "Admin user on the jumpbox."
  type        = string
  default     = "tpgadmin"

  validation {
    condition = can(regex("^[a-z_][a-z0-9_-]{0,31}$", var.jumpbox_admin_username)) && !contains([
      "1", "123", "a", "actuser", "adm", "admin", "admin1", "admin2", "administrator", "aspnet", "backup",
      "console", "david", "guest", "john", "owner", "root", "server", "sql", "support", "support_388945a0",
      "sys", "test", "test1", "test2", "test3", "user", "user1", "user2", "user3", "user4", "user5",
    ], var.jumpbox_admin_username)
    error_message = "jumpbox_admin_username must be a lowercase Linux user name of up to 32 characters that Azure does not reserve (such as root, admin, administrator, test or user)."
  }
}

variable "jumpbox_os" {
  description = "Jumpbox image: ubuntu-24.04, ubuntu-22.04, rhel-9 (pay-as-you-go) or rocky-9 (Marketplace plan: accept the terms once, see modules/jumpbox)."
  type        = string
  default     = "ubuntu-24.04"

  validation {
    condition     = contains(["ubuntu-24.04", "ubuntu-22.04", "rhel-9", "rocky-9"], var.jumpbox_os)
    error_message = "jumpbox_os must be ubuntu-24.04, ubuntu-22.04, rhel-9 or rocky-9."
  }
}

variable "jumpbox_vm_size" {
  description = "Jumpbox VM size."
  type        = string
  default     = "Standard_D4s_v5"
}

variable "jumpbox_os_disk_gb" {
  description = "Jumpbox OS disk size in GB (Premium_LRS)."
  type        = number
  default     = 64

  validation {
    condition     = var.jumpbox_os_disk_gb >= 64 && var.jumpbox_os_disk_gb <= 4095
    error_message = "jumpbox_os_disk_gb must be between 64 and 4095."
  }
}

# ---------------------------------------------------------------------------
# Fleet repository and fleet setup from the jumpbox (jumpbox-provision.tf)
# ---------------------------------------------------------------------------
variable "create_fleet_repo" {
  description = <<-EOT
    Upload fleet_zip_path to the jumpbox, unzip it to ~/tpg-fleet, create the GitHub repository
    fleet_repo_owner/fleet_repo_name (private), run scripts/set-repo-url.sh with its URL,
    scripts/validate.sh, then commit and push to fleet_repo_branch
    (scripts/jumpbox/push-fleet-repo.sh). Needs enable_jumpbox and TF_VAR_git_admin_pat.
  EOT
  type        = bool
  default     = false

  validation {
    condition     = !var.create_fleet_repo || (var.enable_jumpbox && var.jumpbox_provision)
    error_message = "create_fleet_repo needs enable_jumpbox = true and jumpbox_provision = true."
  }
}

variable "run_fleet_setup" {
  description = <<-EOT
    On the jumpbox, source env.sh and run scripts/run.sh --hub install --targets terraform --expose-ui
    --save-vault-recovery-keys (scripts/jumpbox/run-fleet-setup.sh), after every cluster and role
    assignment exists. The fleet repository is the one create_fleet_repo pushed, or FLEET_REPO_URL
    of env.sh (cloned to ~/tpg-fleet). Needs TF_VAR_broadcom_token, TF_VAR_git_read_pat and
    TF_VAR_git_push_pat.
  EOT
  type        = bool
  default     = false

  validation {
    condition     = !var.run_fleet_setup || (var.enable_jumpbox && var.jumpbox_provision && var.create_role_assignments)
    error_message = "run_fleet_setup needs enable_jumpbox = true, jumpbox_provision = true and create_role_assignments = true (without its role assignments the jumpbox identity cannot reach the clusters)."
  }
}

variable "fleet_repo_owner" {
  description = "create_fleet_repo: GitHub user or organization that owns the new fleet repository."
  type        = string
  default     = null

  validation {
    condition     = !var.create_fleet_repo || (var.fleet_repo_owner != null && can(regex("^[A-Za-z0-9][A-Za-z0-9-]{0,38}$", coalesce(var.fleet_repo_owner, "-"))))
    error_message = "create_fleet_repo needs fleet_repo_owner, a GitHub user or organization name."
  }
}

variable "fleet_repo_name" {
  description = "create_fleet_repo: name of the new fleet repository."
  type        = string
  default     = "poc-tpg-fleet-v15"

  validation {
    condition     = can(regex("^[A-Za-z0-9._-]{1,100}$", var.fleet_repo_name)) && !endswith(var.fleet_repo_name, ".git")
    error_message = "fleet_repo_name must be a GitHub repository name (letters, digits, '.', '_' and '-'), without .git."
  }
}

variable "fleet_repo_branch" {
  description = "create_fleet_repo: branch the fleet repository is pushed to (and FLEET_REPO_REVISION on the jumpbox)."
  type        = string
  default     = "main"

  validation {
    condition     = can(regex("^[A-Za-z0-9._/-]+$", var.fleet_repo_branch)) && !startswith(var.fleet_repo_branch, "-")
    error_message = "fleet_repo_branch must be a plain branch name."
  }
}

variable "fleet_zip_path" {
  description = "create_fleet_repo: absolute path of tpg-fleet.zip (one top-level folder), for example /home/<you>/tpg-fleet.zip. Relative paths and ~ are refused. null: tpg-fleet.zip next to the tpg-aks-infra folder."
  type        = string
  default     = null

  validation {
    condition = var.fleet_zip_path == null || (
      startswith(coalesce(var.fleet_zip_path, "-"), "/") && endswith(coalesce(var.fleet_zip_path, "-"), ".zip")
      && !can(regex("(^|/)\\.\\.?(/|$)|//|[\\[\\][:space:]\"'$`\\\\]", coalesce(var.fleet_zip_path, "-")))
    )
    error_message = "fleet_zip_path must be an absolute path to a .zip file, such as /home/tpgadmin/tpg-fleet.zip: no relative path, no ~, no '.' or '..' segments, no '//', no spaces, quotes, $, backtick, backslash or brackets."
  }
}

variable "fleet_repo_validate" {
  description = "create_fleet_repo: run scripts/validate.sh (which includes tests/run-all.sh) in the unzipped folder before the push. Default false (Round 20); it runs only when env.sh also sets FLEET_VALIDATE or fleet_repo_validate to true."
  type        = bool
  default     = false
}

variable "fleet_repo_force" {
  description = <<-EOT
    create_fleet_repo: push to a repository whose branch already holds different content, replacing
    the branch history (git push --force). false: such a repository stops the step; a branch that
    already holds the same files is left as it is. It takes effect only when env.sh also sets
    FLEET_REPO_FORCE or fleet_repo_force to true.
  EOT
  type        = bool
  default     = false
}

variable "github_url" {
  description = "create_fleet_repo: GitHub web URL. GitHub Enterprise Server: https://<host> (the API is then https://<host>/api/v3)."
  type        = string
  default     = "https://github.com"

  validation {
    condition     = can(regex("^https://[^/@]+$", var.github_url))
    error_message = "github_url must be https://<host> with no path and no credentials."
  }
}

# Secrets for the jumpbox provisioners. Export them as TF_VAR_<name>; never put
# them in terraform.tfvars. They are passed to the jumpbox in the environment of
# one SSH session and written to no file there; Terraform keeps them out of the
# state, but a saved plan file (terraform plan -out) holds them: delete it.
variable "git_admin_pat" {
  description = "create_fleet_repo: GitHub token that can create the repository and push to it (classic: scope repo; fine-grained: Administration and Contents, Read and write)."
  type        = string
  default     = ""
  sensitive   = true
  nullable    = false
}

variable "broadcom_token" {
  description = "run_fleet_setup: BROADCOM_TOKEN of the hub-secrets step."
  type        = string
  default     = ""
  sensitive   = true
  nullable    = false
}

variable "git_read_pat" {
  description = "run_fleet_setup: GIT_READ_PAT of the hub-secrets step (fine-grained, Contents: Read-only)."
  type        = string
  default     = ""
  sensitive   = true
  nullable    = false
}

variable "git_push_pat" {
  description = "run_fleet_setup: GIT_PUSH_PAT of the hub-secrets step (fine-grained, Contents and Pull requests: Read and write)."
  type        = string
  default     = ""
  sensitive   = true
  nullable    = false
}

# ---------------------------------------------------------------------------
# HashiCorp Vault (hub)
# ---------------------------------------------------------------------------
variable "vault_unseal_mode" {
  description = <<-EOT
    How Vault on the hub unseals. Required: there is no default, so every deployment states the choice.
    Written to the inventory (vault.unsealMode) for scripts/steps/35-vault.sh.
      shamir          5 unseal key shares, threshold 3, shown once at init; after every vault-0 restart
                      run scripts/run.sh ... --only vault-unseal. No Azure resources.
      azure-keyvault  auto-unseal with an RSA key in an Azure Key Vault created here, through a
                      workload identity (id-vault) federated to ServiceAccount vault/vault on the hub.
  EOT
  type        = string

  validation {
    condition     = contains(["shamir", "azure-keyvault"], var.vault_unseal_mode)
    error_message = "vault_unseal_mode must be shamir or azure-keyvault."
  }
}

variable "key_vault_purge_protection" {
  description = <<-EOT
    azure-keyvault mode: purge protection on the unseal Key Vault. Off by default so that
    terraform destroy removes the Key Vault and the POC can be rebuilt with the same prefix.
    Deleting the Key Vault or the unseal key permanently destroys the Vault data: the recovery
    keys allow a rekey or a new root token, they do not decrypt the storage. Set it to true for
    anything that outlives the POC.
  EOT
  type        = bool
  default     = false
}

variable "key_vault_soft_delete_days" {
  description = "azure-keyvault mode: days a deleted Key Vault or key stays recoverable (7 to 90)."
  type        = number
  default     = 7
}
