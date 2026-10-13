# tpg-aks-infra

Terraform modules and prerequisite scripts for the **Tanzu for Postgres on AKS GitOps POC**. This repository creates (or adopts) the AKS clusters and prepares them so that the Argo Workflows in [`tpg-fleet`](https://github.com/<org>/tpg-fleet) can run.

| Layer | Location | What it does |
|---|---|---|
| Azure | `terraform/` | One resource group holding the network, identities, hub and target AKS clusters, backup storage, monitoring and the optional Key Vault for Vault auto-unseal |
| Prerequisites | `scripts/run.sh` | Four scenarios: hub with or without Argo, clusters from Terraform or pre-created |
| Secrets | `scripts/steps/35-vault.sh` | HashiCorp Vault (community) on the hub, and every target cluster wired to it |
| Access | `scripts/access.sh` | Prints every UI endpoint and login of the fleet to the terminal |
| Argo on AKS | `docs/README-argo-on-aks.md` | Step-by-step Argo CD and Argo Workflows install with LoadBalancer UIs |
| Manual steps | `docs/README-manual-steps.md` | Every scripted step as commands with examples |

## Repository layout

```text
tpg-aks-infra/
  terraform/
    main.tf, variables.tf, locals.tf, outputs.tf, versions.tf
    terraform.tfvars.example
    modules/
      resource-group/   the single resource group for every Terraform resource
      network/          byo: VNet, /22 subnets, hub egress IP; managed: nothing
      identity/         managed identities, role assignments, federated credentials
      aks/              one AKS cluster with its user node pools
      storage/          backup Storage Account and containers
      keyvault/         Key Vault, key and workload identity for Vault auto-unseal (optional)
      monitoring/       optional Log Analytics + Container Insights; optional managed Prometheus + Grafana
      jumpbox/          operator VM, public IP, NSG, identity, generated SSH key (optional, enable_jumpbox)
    jumpbox-provision.tf  copy scripts/ and env.sh to the jumpbox, install the tools, push the
                          fleet repository, run run.sh there (optional, over SSH)
  scripts/
    run.sh              scenario runner
    access.sh           every UI endpoint and login, printed to the terminal
    wf-logs.sh          archived Argo Workflows step logs, read from Azure Blob
    vault-secret.sh     named CA bundles in Vault (ca put|get|list|delete) and wrapping tokens
                        for tpg-rotate-credential (wrap), over kubectl exec or --vault-addr
    jumpbox/setup-jumpbox.sh  tool install on the jumpbox (Terraform over SSH, re-runnable), --clone
    jumpbox/push-fleet-repo.sh  tpg-fleet.zip to a new GitHub repository (create_fleet_repo)
    jumpbox/run-fleet-setup.sh  run.sh on the jumpbox, detached from SSH (run_fleet_setup)
    lib/common.sh       helpers and inventory access, plus the block shared with tpg-fleet
                        workflows/scripts/common.sh: API retries, pod watch, Helm release
                        pre-check (hr_*), metrics flow check
    lib/findings.sh     the verify summary (issues grouped by resource and cluster)
    lib/vault.sh        Vault CLI through vault-0, login, KV, Kubernetes auth, Services, TLS
    lib/credential-checks.sh  Broadcom registry and GitHub PAT pre-checks
    lib/argo-rbac.sh    the Argo CD RBAC deny block for the tpg target Applications (check-argo.sh,
                        60-verify.sh)
    hub/install/        install-argo.sh        (hub without Argo)
    hub/existing/       check-argo.sh          (hub with Argo)
    hub/                ui-admin.sh, print-ui.sh
    targets/terraform/  inventory-from-terraform.sh
    targets/precreated/ validate-inventory.sh, preflight.sh
    steps/              10-kubeconfigs 20-target-service-accounts 30-register-clusters
                        35-vault 40-hub-secrets 45-helm-addons 50-bootstrap-fleet 60-verify
                        vault-unseal (on demand)
  deploy-scripts/
    deploy.sh           local deployment: preflight|apply|repo|setup|copy|all
    terraform-enabled-deploy.sh  deployment through the jumpbox: preflight|apply|all
    lib/deploy-common.sh  prompts, deploy.tfvars, env.sh, tool checks, plan and apply
  inventory/clusters.example.yaml
  argo/                 Helm values for Argo CD and Argo Workflows
  tests/verify/         60-verify.sh and its summary against stubbed clusters (make test)
  tests/preflight/      preflight.sh storage check (secure transfer) against a stubbed az (make test)
  tests/argocd-rbac/    the RBAC deny block with the real argocd CLI (make test; skipped without it)
  tests/jumpbox/        setup-jumpbox.sh (shellcheck, --dry-run per OS), the jumpbox Terraform
                        (fmt, validate, tofu test with mocked providers), push-fleet-repo.sh against
                        a fake GitHub API, run-fleet-setup.sh, and the Vault keys file of
                        run.sh --save-vault-recovery-keys (make test)
  tests/deploy-scripts/ deploy.sh and terraform-enabled-deploy.sh against stubbed terraform, az, ssh
                        and a recording run.sh and push-fleet-repo.sh (make test)
  tests/vault-secret/   vault-secret.sh against a fake vault CLI (kubectl exec) and an HTTPS mock of
                        the Vault API (--vault-addr) (make test)
  docs/
  env.sh.example
  Makefile
```

## Terraform

### What it creates

Every resource is created in **one resource group**: `rg-<prefix>`, or the `resource_group_name` you set. `terraform destroy` deletes that group and everything in it. AKS also creates a node resource group per cluster (`<resource group>-<cluster>-nodes`) for VM scale sets, disks, load balancers and, in managed network mode, the VNet. Azure requires that group to be separate, and it is removed with its cluster.

| Resource | Default name | Module |
|---|---|---|
| Resource group | `rg-tpgpoc` (`eastus2`) | resource-group |
| VNet and subnets (`byo`) | `vnet-tpgpoc` 10.10.0.0/16, `snet-<cluster>` /22 | network |
| Hub egress IP (`byo`) | `pip-aks-tpg-hub-egress` | network |
| Control plane identities | `id-<cluster>` | identity |
| Hub cluster | `aks-tpg-hub` | aks |
| Target clusters | `aks-tpg-poc-01` .. `-03` (`target_cluster_count`) | aks |
| Backup storage | `tpgpocbkp<random>`, containers `pg-backups-<target>` and `argo-logs` (archived workflow logs, deleted after `argo_logs_retention_days`, 90, by a lifecycle rule). Accepts HTTP unless `backup_storage_https_only = true` | storage |
| Vault unseal Key Vault, key, identity (`vault_unseal_mode = "azure-keyvault"`) | `kv-tpgpoc<random>`, `vault-unseal`, `id-vault` | keyvault |
| Log Analytics, Container Insights DCR (only with `enable_container_insights = true`) | `log-tpgpoc`, `MSCI-eastus2-tpgpoc` | monitoring |
| Managed Prometheus and Grafana (optional) | `amw-tpgpoc`, `amg-tpgpoc` | monitoring |
| Jumpbox VM, public IP, NSG, identity, subnet (optional, `enable_jumpbox = true`) | `vm-tpgpoc-jumpbox`, `pip-tpgpoc-jumpbox`, `nsg-tpgpoc-jumpbox`, `id-jumpbox`, `snet-jumpbox` 10.10.252.0/27 | jumpbox, network |

### Resource naming in code

Terraform addresses describe the role of each resource instead of the generic `this`:

| Module | Address |
|---|---|
| resource-group | `azurerm_resource_group.fleet` |
| network | `azurerm_virtual_network.fleet`, `azurerm_subnet.cluster`, `azurerm_public_ip.hub_egress` |
| identity | `azurerm_user_assigned_identity.managed_identity`, `azurerm_role_assignment.identity_role`, `azurerm_federated_identity_credential.workload_federation` |
| aks | `azurerm_kubernetes_cluster.cluster`, `azurerm_kubernetes_cluster_node_pool.user` |
| storage | `azurerm_storage_account.backups`, `azurerm_storage_container.backups` |
| keyvault | `azurerm_key_vault.unseal`, `azurerm_key_vault_key.unseal`, `azurerm_key_vault_access_policy.deployer` |
| monitoring | `azurerm_log_analytics_workspace.container_logs`, `azurerm_monitor_workspace.prometheus`, `azurerm_dashboard_grafana.grafana` |

### Cluster settings

| Setting | Default | Variable |
|---|---|---|
| Tier | Standard | `sku_tier` |
| Node pools | Autoscaling; each pool picks 1 to 3 availability zones and holds at least one node per zone | `enable_autoscaling`, `<pool>.zones`, `<pool>.node_count`, `.min_count`, `.max_count` |
| System pool | D8ds_v5, Ephemeral 300 GB, 110 pods; zone 1, 1 node, autoscaler 1-5 | `system_pool.zones`, `.node_count`, `.min_count`, `.max_count` |
| `pgdata` pool (targets) | D8ds_v5, Managed 256 GB, 30 pods; zones 1, 2, 3, 3 nodes, autoscaler 3-6 | `postgres_pool.zones`, `.node_count`, `.min_count`, `.max_count` |
| Postgres data disks | `Premium_ZRS` (StorageClass `tpg-data-retain`) | `postgres_data_disk_sku` |
| Role assignments | Not created (default `false` since Round 19): the commands for an owner are in the output `role_assignments_to_create` | `create_role_assignments` |
| Node OS | Ubuntu 24.04 | `os_sku` |
| Upgrade surge | 10% (max unavailable 0) | `upgrade_max_surge` |
| Auto-upgrade | Off (`none` / `None`); weekly Sunday window ready | `automatic_upgrade_channel`, `node_os_upgrade_channel`, `maintenance_window` |
| Workload identity, OIDC issuer | On | `enable_workload_identity` |
| Image Cleaner | Every 168 h | `image_cleaner_interval_hours` |
| Azure Policy add-on | On | `enable_azure_policy` |
| Container Insights | Off (default `false` since Round 19); `true` adds the Log Analytics workspace and managed-identity Container Insights | `enable_container_insights` |
| Managed Prometheus + Grafana | Off | `enable_azure_monitor` |
| Advanced Container Networking Services (security: FQDN rules in CiliumNetworkPolicy) | Off | `acns_enabled` |
| Vault unseal | No default: `vault_unseal_mode` is required (`shamir` or `azure-keyvault`) | `vault_unseal_mode`, `key_vault_purge_protection` (off), `key_vault_soft_delete_days` |

The backup storage module also outputs `backup_storage_ca_bundle`: the Azure root certificate authorities (`terraform/modules/storage/azure-ca-roots.pem`) that the account's blob endpoint chains to, checked against the live endpoint at apply. It is the `caBundle` of backup locations with `enableSSL: true`; the inventory step writes it to `.work/backup-ca-bundle.pem` and the hub-secrets step stores it in `tpg-settings` (`backupCaBundle`). `acns_enabled` reaches the workflows the same way (`acnsEnabled`); see `docs/README-manual-steps.md` 2.3.

These defaults follow a review of an Azure portal-created cluster (`blrck-pg-02`). Differences that remain on purpose:

- One node per selected availability zone, where the portal cluster uses 2 nodes in one zone.
- A user-assigned control plane identity instead of system-assigned.
- A BYO VNet in `byo` mode.
- Upgrades are manual.

### Access and network modes

| Mode | Settings | API servers | Hub to targets |
|---|---|---|---|
| Managed network (default since Round 19) | `network_mode = "managed"` | Public (forced; `api_access_mode` is not used) | AKS-managed outbound IP |
| BYO, restricted | `network_mode = "byo"`, `api_access_mode = "restricted"` | Authorized IP ranges: `admin_allowed_cidrs` (+ hub egress IP on targets) | Static hub egress IP |
| BYO, public | `network_mode = "byo"`, `api_access_mode = "public"` or `admin_allowed_cidrs = ["0.0.0.0/0"]` | Open to all addresses | Any egress |

**Security posture of the default.** `managed` means API servers open to the internet (authenticated, but without authorized IP ranges) and a public Vault load balancer (limited to the target clusters' outbound IPs); use `byo` with `api_access_mode = "restricted"` to close both.

`byo` requires `create_role_assignments = true` (a Terraform validation refuses it otherwise): the cluster control-plane identities need Network Contributor on their subnets, and the hub on its egress IP, before AKS creates the clusters, so those assignments cannot be left to an owner afterwards. `managed` needs none of them. In `managed` mode Vault's `vault-fleet` and the standalone monitoring gateway use public load balancers limited to the targets' outbound IPs (looked up with `az`), and the jumpbox gets a VNet of its own.

### Availability zones, node counts and high availability

Each node pool picks its own zones, so the pools no longer share one list:

```hcl
system_pool   = { zones = ["1"],           node_count = 1, min_count = 1, max_count = 5 }
postgres_pool = { zones = ["1", "2", "3"], node_count = 3, min_count = 3, max_count = 6 }
```

`zones` holds 1 to 3 of `"1"`, `"2"` and `"3"`, and `node_count` and `min_count` must be at least the number of zones, so every selected zone can hold a node. Two zones therefore allow `min_count = 2`. Terraform rejects a smaller count with a named error.

The **3 nodes across 3 zones** rule applies to the `pgdata` pool only, and only to Postgres instances deployed with `highAvailability=true`: a primary, a standby and the read replicas have to land on different nodes and zones. Terraform cannot know that intent (`tpg-day0` decides it later), so it warns:

```text
Warning: Check block assertion failed
postgres_pool spans 2 zone(s) with 2 node(s). Postgres instances deployed with
highAvailability=true need 3 zones and 3 nodes; tpg-day0 will report such clusters
BLOCKED (PGDATA_POOL_NOT_HA_CAPABLE). Single-node instances are unaffected.
```

`tpg-day0` then enforces it: with `highAvailability=true` it inspects the target's data-pool nodes and reports that cluster `BLOCKED` without changing anything. Single-node instances run on any pool shape. The system pool is outside the rule, which is why its default is one zone and one node; that also means the hub's Argo CD, Vault and monitoring pods have no zone redundancy until you widen it.

### Postgres data disks

`postgres_data_disk_sku` sets the managed-disk SKU of the StorageClass `tpg-data-retain`, which holds the Postgres data and WAL volumes and the Vault volume on the hub:

| Value | Notes |
|---|---|
| `StandardSSD_LRS` | Standard SSD in one zone: the cheapest option Postgres can use |
| `StandardSSD_ZRS` | Standard SSD replicated across zones |
| `Premium_LRS` | Premium SSD in one zone |
| `Premium_ZRS` (default) | Premium SSD replicated across zones; a volume can be reattached in another zone, which matters when a Postgres pod moves |
| `PremiumV2_LRS` | Premium SSD v2 with configurable IOPS and throughput, one zone |

The value reaches the clusters through the inventory: the `vault` step renders the StorageClass on the hub, and the `tpg-platform` ApplicationSet patches `skuName` on every target from the label `tpg.fleet/dataDiskSku` on its Argo CD cluster Secret. The ZRS options need a region with availability zones.

### Role assignments

Creating an Azure role assignment needs `Microsoft.Authorization/roleAssignments/write`, which Contributor does not include. The unseal Key Vault therefore grants access with **Key Vault access policies** (the deployer gets key create and get, the `id-vault` identity gets get, wrapKey and unwrapKey), so that part of the deployment never needs the permission.

`create_role_assignments` defaults to `false` (Round 19), since most accounts that run the POC are Contributors; set it to `true` when the account is Owner or User Access Administrator. `run_fleet_setup` needs `true`, as the jumpbox uses its Cluster Admin role assignments inside the same apply. The deploy scripts ask which case applies (section "Deploy scripts").

The remaining assignments are the Network Contributor roles the cluster identities need on their subnet and on the hub egress IP in `byo` network mode (which is why `byo` requires `true`), plus the monitoring roles and the jumpbox roles. With `create_role_assignments = false` (and therefore `managed`) Terraform skips them, finishes the rest, and prints what an owner has to run:

```bash
terraform output -json role_assignments_to_create | jq -r '.[]'
# az role assignment create --assignee-object-id <id> --assignee-principal-type ServicePrincipal \
#   --role "Reader" --scope /subscriptions/.../resourceGroups/rg-tpgpoc-aks-tpg-hub-nodes  # id-jumpbox/nodes-aks-tpg-hub
# (managed network mode: the jumpbox and Managed Grafana assignments; the Network
#  Contributor ones appear only with byo, which needs create_role_assignments = true)
```

Leave the variable at `false` afterwards: with `true` Terraform would try to create the same assignments again and Azure rejects a duplicate with `RoleAssignmentExists`. For pre-created clusters the preflight step reports a Key Vault identity that still has no crypto role, with the command to fix it.

### Apply

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # subscription_id, admin_allowed_cidrs,
                                               # modes, vault_unseal_mode (required)
az login
terraform init
terraform plan -out tfplan
terraform apply tfplan
cd ..
```

`backup_storage_https_only` (default `false`) must match the instances' backup `enableSSL` (`tpg-fleet` `backup.enableSSL`, default `false`): an account that accepts HTTPS only rejects a backup location with `enableSSL: false`.

`terraform destroy` purges the soft-deleted Key Vault and its `vault-unseal` key when `key_vault_purge_protection = false`: the deployer's access policy includes the `Purge` key permission, and the provider's `key_vault` features are set explicitly in `versions.tf`. Without `Purge` the first destroy failed with a 403 on the key purge and only a second run succeeded.

Terraform keeps state locally in `terraform/terraform.tfstate`. The state contains the backup storage account key and, with `enable_jumpbox`, the generated jumpbox SSH private key: keep it private (`.gitignore` excludes it). The configuration is meant for a fresh deployment and contains no state moves from earlier layouts.

## Jumpbox (optional)

A Linux VM in the resource group for running the scripts and the offline tests of both repositories. It is off by default; turn it on in `terraform.tfvars`:

```hcl
enable_jumpbox = true
```

With `jumpbox_setup_method = "remote-exec"` (the default), Terraform reaches the VM over SSH to set it up (`terraform/jumpbox-provision.tf`), so **the machine that runs Terraform must be inside `admin_allowed_cidrs`**; with `cloud-init` Terraform does not connect, but `deploy.sh copy` does, so the same holds for it, which is also the only source the NSG lets in on port 22.

| Variable | Default | Notes |
|---|---|---|
| `enable_jumpbox` | `false` | Creates everything below |
| `jumpbox_ssh_public_key` | none | Optional. Your own OpenSSH public key, authorized next to the key pair Terraform generates; password login is disabled |
| `jumpbox_ssh_private_key_path` | none | Optional. The private key of `jumpbox_ssh_public_key`, used by the provisioners instead of the generated key (read at apply, not stored) |
| `jumpbox_provision` | `true` | `false`: the VM only, no tools (the tests use it) |
| `jumpbox_setup_method` | `remote-exec` | How the tools are installed (Round 19): `remote-exec` over SSH from Terraform, its output in `terraform apply` (needed by `create_fleet_repo` and `run_fleet_setup`; `terraform-enabled-deploy.sh`); `cloud-init` at first boot, no SSH from Terraform (`deploy.sh`) |
| `jumpbox_admin_username` | `tpgadmin` | |
| `jumpbox_os` | `ubuntu-24.04` | `ubuntu-22.04`; `rhel-9` (pay-as-you-go: the RHEL subscription is billed with the VM); `rocky-9` (Marketplace image with a plan: run `az vm image terms accept --publisher resf --offer rockylinux-x86_64 --plan 9-base` once per subscription before the apply) |
| `jumpbox_vm_size` | `Standard_D4s_v5` | |
| `jumpbox_os_disk_gb` | `64` | Premium_LRS |

| Resource | Name | Notes |
|---|---|---|
| VM | `vm-<prefix>-jumpbox`, host name `<prefix>-jumpbox` | `jumpbox_setup_method = "remote-exec"` (default): no custom data, set up over SSH by `terraform_data.jumpbox_setup`. `"cloud-init"`: custom data that runs `setup-jumpbox.sh` at first boot (below) |
| SSH key pair | `tls_private_key` in `modules/jumpbox` | ED25519, generated by Terraform; the private key is in the Terraform state and in the output `jumpbox_ssh_private_key` |
| Public IP | `pip-<prefix>-jumpbox` | Static, Standard |
| Network security group | `nsg-<prefix>-jumpbox` | On the NIC: inbound TCP 22 from `admin_allowed_cidrs` only |
| Subnet | `snet-jumpbox` | `byo`: in `vnet-<prefix>`, a /27 at the start of the last /22 slot of `vnet_cidr`, which no cluster uses (`10.10.252.0/27` by default). `managed`: in its own VNet `vnet-<prefix>-jumpbox` with the same range |
| Managed identity | `id-jumpbox` | Contributor on the resource group; Azure Kubernetes Service Cluster Admin Role on the hub and every target; Reader on every node resource group (Round 19: in `managed` mode `run.sh` reads the targets' outbound IPs there for the public Vault and gateway load balancers) |

With restricted API servers (`api_access_mode = "restricted"` in `byo` mode) the jumpbox address (/32) is added to the authorized IP ranges of the hub and of every target, next to `admin_allowed_cidrs`. Public API servers (`public` or `managed` mode) need nothing.

The role assignments follow `create_role_assignments`: with `false` they appear in `role_assignments_to_create` (the lines ending in `# id-jumpbox/...`). The outputs are `jumpbox_public_ip`, `jumpbox_ssh_command`, `jumpbox_ssh_private_key` (sensitive), `jumpbox_identity_client_id`, and with the options below `fleet_repo_url` and `jumpbox_vault_keys_file` (all `null` while unused).

A jumpbox created before Round 16 is **replaced** by the first apply of this version: its SSH keys change (the generated key is added), and Azure cannot change the keys of a VM in place. The static public IP stays.

### What Terraform does on the VM

**Two setup methods** (`jumpbox_setup_method`, Round 19):

- `remote-exec` (default, `terraform-enabled-deploy.sh`): the three steps below, over SSH.
- `cloud-init` (`deploy.sh`): the VM's custom data stores `setup-jumpbox.sh`, copies it to `/home/<admin>/setup-jumpbox.sh` once the admin user exists, and runs it once as root at first boot. Its output is in `/var/log/cloud-init-output.log` and `/var/log/tpg-jumpbox/setup-cloud-init.log`. Terraform opens no SSH connection, and none of the steps below exists. `deploy.sh copy` then adds what remote-exec would have put there (section "Deploy scripts"). Changing `jumpbox_setup_method` on an existing jumpbox does not set it up again: the custom data is ignored after creation, and `remote-exec` only runs its steps when their inputs change. For a clean switch, rebuild the VM with `terraform apply -replace='module.jumpbox[0].azurerm_linux_virtual_machine.jumpbox'`. Terraform ignores later changes of the custom data, so a newer `setup-jumpbox.sh` never replaces the VM: `deploy.sh copy` runs it again over SSH when its sha256 differs from the one the jumpbox recorded in `/var/lib/tpg-jumpbox/setup-jumpbox.sha256`.

With `remote-exec`, three `terraform_data` resources in `terraform/jumpbox-provision.tf` run in order over SSH, after the VM exists:

| Step | When | What |
|---|---|---|
| `jumpbox_setup` | `enable_jumpbox` | Copies `scripts/` to `~/scripts`, `env.sh` to `~/env.sh` (`env.sh.example` when there is no `env.sh`), writes `~/env.jumpbox.sh`, `~/.work/inventory.yaml` and `~/.work/backup-ca-bundle.pem`, then runs `sudo ~/scripts/jumpbox/setup-jumpbox.sh`, which first waits, visibly, for the image's first boot (`cloud-init status --wait`) |
| `fleet_repo` | `create_fleet_repo = true` | Uploads `fleet_zip_path` to `~/tpg-fleet.zip` and runs `~/scripts/jumpbox/push-fleet-repo.sh` (below) |
| `jumpbox_run` | `run_fleet_setup = true` | Runs `~/scripts/jumpbox/run-fleet-setup.sh --hub install --targets terraform --expose-ui --save-vault-recovery-keys` once every cluster, identity and role assignment exists |

**Logs.** Each step prints a header (`== jumpbox_setup: ...`, `== fleet_repo: ...`, `== jumpbox_run: ...`) and runs its script with stderr merged into stdout, so every line of `setup-jumpbox.sh`, `push-fleet-repo.sh` and `run-fleet-setup.sh` (with `run.sh`) appears in the `terraform apply` output as it happens. A copy stays on the jumpbox: `/var/log/tpg-jumpbox/setup-<UTC>.log`, `~/.work/logs/push-fleet-repo-<UTC>.log`, `~/.work/fleet-setup/run-<UTC>.log`. The step ends with the script's exit code (`bash -o pipefail`). No provisioner block holds a sensitive value, which would make Terraform suppress the output (`tests/jumpbox` checks it).

A step that fails taints only its `terraform_data` resource; the next `terraform apply` runs it again and never replaces the VM for it. A step also runs again when its inputs change: a new VM, any changed file under `scripts/`, a changed `env.sh`, inventory or `tpg-fleet.zip` (`jumpbox_run` follows `jumpbox_setup` and `fleet_repo`).

`~/env.jumpbox.sh` holds the jumpbox values; `scripts/lib/common.sh` reads it after `env.sh`, so they win: `FLEET_LOCAL_DIR=~/tpg-fleet`, `INVENTORY_PREBUILT=true`, `VAULT_RECOVERY_KEYS_FILE=~/.tpg/vault-keys.txt`, the identity's client ID, the subscription, and with `create_fleet_repo` the repository URL, branch (`FLEET_REPO_REVISION`), `GITHUB_API_URL`, `FLEET_VALIDATE_TFVARS` and `FLEET_REPO_FORCE_TFVARS` (the Terraform values; the env.sh switches below are separate). The next apply overwrites it; put your own settings in `env.sh`.

`~/.work/inventory.yaml` is the inventory `inventory-from-terraform.sh` builds from `terraform output`, built by Terraform from the same values, because the jumpbox has no Terraform state. With `INVENTORY_PREBUILT=true` the inventory step only checks it. One difference: `backup.keySource` is `az`, as the jumpbox identity can list the storage account keys.

### Secrets

The tokens are Terraform variables marked sensitive. Export them in your shell, never in `terraform.tfvars`:

```bash
read -rsp 'GitHub admin PAT: ' TF_VAR_git_admin_pat && export TF_VAR_git_admin_pat   # create_fleet_repo
read -rsp 'Broadcom token: '   TF_VAR_broadcom_token && export TF_VAR_broadcom_token  # run_fleet_setup
read -rsp 'GitHub read PAT: '  TF_VAR_git_read_pat   && export TF_VAR_git_read_pat    # run_fleet_setup
read -rsp 'GitHub push PAT: '  TF_VAR_git_push_pat   && export TF_VAR_git_push_pat    # run_fleet_setup
```

They reach the VM only inside the remote-exec script of `fleet_repo` and `jumpbox_run`, which Terraform writes to `/dev/shm` (memory) and which deletes itself as its first command; the scripts pass them on in the environment (`run.sh` inherits them). They are not written to a file on the VM, and Terraform does not store variables or provisioner scripts in the state. A **saved plan file** (`terraform plan -out=tfplan`, `make plan`) does hold them: apply it and delete it. The generated SSH private key is in the state; keep the state private, as before.

### Fleet repository (`create_fleet_repo`)

```hcl
create_fleet_repo = true
fleet_repo_owner  = "<github-user-or-org>"
# fleet_repo_name     = "poc-tpg-fleet-v15"
# fleet_repo_branch   = "main"
# fleet_zip_path      = "/home/<you>/tpg-fleet.zip"   # absolute only; default: tpg-fleet.zip next to the tpg-aks-infra folder
# fleet_repo_validate = false   # default; true also needs FLEET_VALIDATE=true in env.sh
# fleet_repo_force    = false   # default; true also needs FLEET_REPO_FORCE=true in env.sh
# github_url          = "https://github.com"    # GitHub Enterprise Server: https://<host>
```

`scripts/jumpbox/push-fleet-repo.sh ~/tpg-fleet.zip`:

1. Unzips into `~/tpg-fleet`. The zip holds one top-level folder; `__MACOSX/`, `.DS_Store` and any `.git` are left out. An existing `~/tpg-fleet` is moved to `~/tpg-fleet.prev-<UTC time>`.
2. Creates the private repository `fleet_repo_owner/fleet_repo_name` through the GitHub REST API (`POST /user/repos` when the owner is the token's user, `POST /orgs/<owner>/repos` otherwise), unless it exists.
3. Runs `scripts/set-repo-url.sh https://github.com/<owner>/<name>.git` and makes every `*.sh` executable.
4. Commits on `fleet_repo_branch` (`git init -b`).
5. Runs `scripts/validate.sh`, which includes `tests/run-all.sh`, **only if enabled** (off by default since Round 20, see "Validation and force are opt-in" below). A failure stops the step before the push.
6. Pushes. An empty repository or a missing branch is pushed to; a branch that already holds the same files is left as it is; a branch with other content stops the step unless force is enabled (`fleet_repo_force = true` and `FLEET_REPO_FORCE=true` in env.sh), which replaces the branch history with `git push --force`.

**Validation and force are opt-in (Round 20).** `scripts/validate.sh` and `git push --force` run only when two switches say so, and both default to off:

| | Terraform (`terraform.tfvars` / `deploy.tfvars`) | `env.sh` (either spelling; if both are set, both must be true) |
|---|---|---|
| `scripts/validate.sh` | `fleet_repo_validate = true` | `export FLEET_VALIDATE="true"` or `export fleet_repo_validate="true"` |
| `git push --force` | `fleet_repo_force = true` | `export FLEET_REPO_FORCE="true"` or `export fleet_repo_force="true"` |

A missing or false switch skips it, and the step says which one ("validate.sh skipped: FLEET_VALIDATE=false in env.sh"); there is no mismatch error. On the jumpbox, Terraform writes its half as `FLEET_VALIDATE_TFVARS` / `FLEET_REPO_FORCE_TFVARS` into `env.jumpbox.sh`, and the other half comes from the jumpbox's `env.sh`. With validation off, `deploy.sh` does not require yamllint, shellcheck, kustomize, kubeconform or PyYAML.

`GIT_ADMIN_PAT` creates the repository and pushes: a classic PAT with scope `repo`, or a fine-grained PAT with Administration and Contents, Read and write (for an organization, the token's user must be allowed to create repositories there). curl reads it from a config on stdin and git from a `GIT_ASKPASS` script that reads the environment, so it is in no command line, file or git configuration. The script also runs by hand on the jumpbox, as the admin user, with the variables of `env.jumpbox.sh` and `GIT_ADMIN_PAT` exported.

### Fleet setup from the jumpbox (`run_fleet_setup`)

```hcl
run_fleet_setup = true
```

Needs `env.sh` (copy `env.sh.example` and set at least `GITHUB_USER`, `BROADCOM_USER` and `MONITORING_OPTION`), `create_role_assignments = true`, and the three run tokens exported. The fleet repository is the one `create_fleet_repo` pushed; without `create_fleet_repo`, `FLEET_REPO_URL` of `env.sh` is cloned to `~/tpg-fleet` with `GITHUB_USER` and `GIT_READ_PAT`.

`scripts/jumpbox/run-fleet-setup.sh`:

1. Reads `env.sh` and `env.jumpbox.sh` (through `scripts/lib/common.sh`).
2. Runs `az login --identity` with the jumpbox identity and waits up to 10 minutes until it can read the hub cluster (role assignments take a few minutes to apply).
3. Clones the fleet repository if `~/tpg-fleet` is not a clone yet.
4. Starts `scripts/run.sh --hub install --targets terraform --expose-ui --save-vault-recovery-keys` with `setsid nohup`, output to `~/.work/fleet-setup/run-<UTC time>.log` (`run.log` points at the latest), and follows the log until `run.sh` ends; the step ends with the exit code of `run.sh`. A dropped SSH connection or a Ctrl+C in Terraform does not stop `run.sh`. Started again while that `run.sh` still runs, it follows it instead of starting a second one.

The `vault` step writes the unseal (shamir) or recovery (azure-keyvault) keys to `~/.tpg/vault-keys.txt` on the jumpbox (output `jumpbox_vault_keys_file`) instead of showing them; see "Vault keys file" below. **Copy the file off the jumpbox into a password manager, then delete it.** A full run takes roughly 30 to 60 minutes; follow it from another terminal with `ssh ... tail -f ~/.work/fleet-setup/run.log`.

### Log in

```bash
terraform -chdir=terraform output -raw jumpbox_ssh_private_key > ~/.ssh/tpg-jumpbox && chmod 600 ~/.ssh/tpg-jumpbox
terraform -chdir=terraform output -raw jumpbox_ssh_command   # ssh -i ~/.ssh/tpg-jumpbox tpgadmin@<public ip>
ssh -i ~/.ssh/tpg-jumpbox tpgadmin@<public ip>               # or your own key (jumpbox_ssh_public_key)

# on the jumpbox
az login --identity             # the VM's managed identity (id-jumpbox)
                                # (or: az login --identity --client-id <jumpbox_identity_client_id>)
az aks get-credentials -g rg-tpgpoc -n aks-tpg-hub --admin
kubectl get nodes
```

The identity is enough for `az` and `kubectl` work on the clusters and on the resources in the resource group. It cannot create role assignments or reach anything outside the resource group: run Terraform with your own account (`az login --use-device-code`). The Terraform state stays on the machine that ran Terraform (see Apply); on the jumpbox, `scripts/run.sh --targets terraform` reads the inventory Terraform uploaded (`INVENTORY_PREBUILT=true`). From `~`, the jumpbox works like a clone of this repository: `~/scripts/run.sh --hub install --targets terraform --only verify`.

### Tools

`~/scripts/jumpbox/setup-jumpbox.sh` installs three groups; `--only` picks some of them:

| Group | Tools |
|---|---|
| `run-time` | Azure CLI (packages.microsoft.com), kubectl, Helm 4, argo, argocd, yq (mikefarah), jq, git, curl, openssl, OpenTofu (`TF_TOOL=terraform` for Terraform), kubelogin; HashiCorp Vault CLI with `--vault` |
| `tests` | python3 with PyYAML, shellcheck, kubeconform, kustomize, yamllint, the envtest binaries (etcd, kube-apiserver) from `setup-envtest`; `KUBEBUILDER_ASSETS` is set in `/etc/profile.d/tpg-jumpbox.sh` |
| `extras` | kubectx, kubens, fzf, tmux, bash completion for kubectl, helm, argo and argocd |

Every tool is pinned at the top of the script and checked with sha256 before it is installed: against the checksum file the vendor publishes for that release, or, for shellcheck and setup-envtest (no vendor checksum), against a checksum recorded in the script. yamllint and its dependencies are installed with `pip --require-hashes`, the envtest archive is checked by `setup-envtest` against the sha512 in the controller-tools index, and the Azure CLI repository key must have the pinned fingerprint. A missing or wrong checksum stops the script. `--dry-run` prints the OS, package manager, packages, tools, versions, URLs and checksum sources without downloading anything. Supported: Ubuntu 22.04 and 24.04, RHEL 9, Rocky Linux 9 (x86_64). On Ubuntu, `apt-get` waits up to 15 minutes for the dpkg lock that `apt-daily` and `unattended-upgrades` hold right after boot.

The output of the first run is in the `terraform apply` output. The script is safe to run again: a tool whose pinned version is installed is skipped.

```bash
sudo ~/scripts/jumpbox/setup-jumpbox.sh                        # install what is missing or out of date
sudo ~/scripts/jumpbox/setup-jumpbox.sh --only tests           # one group
sudo TF_TOOL=terraform ~/scripts/jumpbox/setup-jumpbox.sh --only run-time --vault
~/scripts/jumpbox/setup-jumpbox.sh --dry-run                   # the plan only
```

A newer `setup-jumpbox.sh` (or any other change under `scripts/`) is applied by the next `terraform apply`: `jumpbox_setup` copies `scripts/` again and re-runs the script, without replacing the VM.

`terraform apply -replace='module.jumpbox[0].azurerm_linux_virtual_machine.jumpbox'` rebuilds the VM from scratch (the admin user's home, with `~/.tpg/vault-keys.txt`, is lost); the three steps then run again.

### Clone the repositories

Not needed with `create_fleet_repo` or `run_fleet_setup`, which put `tpg-fleet` at `~/tpg-fleet` and this repository's scripts at `~/scripts`. For full clones, run as the admin user, without `sudo`. The token is read from the environment only: the script hands it to git through a temporary `GIT_ASKPASS` script that reads the variables and is deleted afterwards. It is not written to a file, a command line, the remote URL or the git configuration, and no credential helper stores it.

```bash
export GITHUB_USER='<github-username>'
read -rsp 'GitHub PAT: ' GIT_READ_PAT && export GIT_READ_PAT   # fine-grained PAT, Contents: Read-only
export FLEET_REPO_URL='https://github.com/<org>/tpg-fleet.git'
export INFRA_REPO_URL='https://github.com/<org>/tpg-aks-infra.git'
~/scripts/jumpbox/setup-jumpbox.sh --clone   # clones into ~/src (CLONE_DIR to change it); an existing clone is left as it is
unset GIT_READ_PAT
```

`read -rs` keeps the token out of the shell history. Public repositories need no token. A later `git pull` of a private repository asks for the user name and token again. The clones match the default `FLEET_LOCAL_DIR` (`~/src/tpg-fleet`) of `env.sh.example`, but `~/env.jumpbox.sh` sets `FLEET_LOCAL_DIR=~/tpg-fleet` for `~/scripts`; then run the offline tests with `make test` in `~/src/tpg-aks-infra` and `tests/run-all.sh` in `~/src/tpg-fleet`.

## Deploy scripts (`deploy-scripts/`)

Two scripts run the whole deployment after a few prompts. They do what the sections above and below describe, in order, and leave the same files behind.

| | `terraform-enabled-deploy.sh` | `deploy.sh` |
|---|---|---|
| Where the fleet repository is pushed and `run.sh` runs | On the jumpbox, by the Terraform provisioners (`create_fleet_repo`, `run_fleet_setup`) | On this machine |
| Jumpbox | Always (`enable_jumpbox = true`) | Optional (asked); then the fleet repository and `.work` are copied to it |
| Subcommands | `preflight`, `apply`, `all` | `preflight`, `apply`, `repo`, `setup`, `copy`, `all` |
| Tools on this machine | terraform 1.9+ or tofu 1.9+, az, jq, curl (ssh to log in later) | Everything `run.sh` needs (bash 4+, az, kubectl, Helm 3.10+ or 4, argocd, mikefarah yq v4, jq, git, curl, openssl, python3, terraform or tofu), unzip, and for `scripts/validate.sh` yamllint, shellcheck, kustomize, kubeconform and PyYAML; ssh and tar for `copy` |

```bash
deploy-scripts/terraform-enabled-deploy.sh all     # or: make deploy-terraform
deploy-scripts/deploy.sh all                       # or: make deploy
deploy-scripts/deploy.sh all --from setup          # resume after a failed step
deploy-scripts/deploy.sh setup                     # one step
```

Without a subcommand both print their usage and do nothing. Options: `--run-step-from STEP` (`deploy.sh` `setup` and `all` only) starts `scripts/run.sh` at its step `STEP` (`run.sh --from STEP`) to resume after a failed `run.sh`; a failed `run.sh` prints the exact line (`deploy.sh setup --run-step-from <failed step>`). `terraform-enabled-deploy.sh` has no such option: resume by hand on the jumpbox with `~/scripts/jumpbox/run-fleet-setup.sh --hub install --targets terraform --expose-ui --save-vault-recovery-keys --from STEP` (the three run tokens exported), which its failed-apply message prints. `--yes` answers the confirmations (the plan, the `env.sh` change, the jumpbox copy), `--non-interactive` asks nothing and takes every value from the files and the environment (it needs `--yes` for the confirmations), `--from STEP` (with `all` only) resumes at a step with the values saved by the earlier run.

### Values

Both scripts ask only for the essentials; everything else (node pools, disk SKUs, monitoring flags such as `enable_container_insights`, ...) comes from `terraform/terraform.tfvars` or the defaults. Each prompt shows a default, taken from the environment (`TF_VAR_<name>`, or the variable itself for the `env.sh` values), `terraform/deploy.tfvars`, `terraform/terraform.tfvars`, `env.sh`, then the Terraform default. The subscription defaults to `az account show`, the admin CIDRs to this machine's public IP (`/32`, from `https://ifconfig.me`); `vault_unseal_mode` has no default, as in Terraform.

| Asked | Saved in |
|---|---|
| `subscription_id`, `location`, `prefix`, `resource_group_name`, `target_cluster_count`, `admin_allowed_cidrs` | `terraform/deploy.tfvars` |
| `create_role_assignments`: "Can the account running Terraform create role assignments (Owner or User Access Administrator)?" (default no). `terraform-enabled-deploy.sh` needs yes and asks again after no, saying why; `deploy.sh` accepts no (below) | `terraform/deploy.tfvars` |
| `network_mode` (default `managed`): with the role answer no, `byo` is refused with the reason and asked again. `api_access_mode` only for `byo`; with `managed` the summary shows "API servers: public (managed network mode)" | `terraform/deploy.tfvars` |
| `vault_unseal_mode` (no default) | `terraform/deploy.tfvars` |
| `enable_jumpbox` (`deploy.sh`), `jumpbox_os`, `jumpbox_admin_username` | `terraform/deploy.tfvars` |
| `fleet_repo_owner`, `fleet_repo_name`, `fleet_repo_branch`, `fleet_zip_path` (absolute path) | `terraform/deploy.tfvars` |
| `GITHUB_USER`, `BROADCOM_USER`, `MONITORING_OPTION`, `FLEET_LOCAL_DIR` (`deploy.sh`, absolute path, no default: always typed; not repeated in the summary) | `env.sh`; `deploy.sh` also writes `FLEET_REPO_URL`, `FLEET_REPO_REVISION`, `GITHUB_API_URL` (from the repository values) and `TF_BIN` (the binary it found: `tofu` when only OpenTofu is installed) |
| `GIT_ADMIN_PAT`, `BROADCOM_TOKEN`, `GIT_READ_PAT`, `GIT_PUSH_PAT` | Nowhere: from the environment or a hidden prompt, kept as shell variables and handed only to the command that needs them (`push-fleet-repo.sh` gets `GIT_ADMIN_PAT`, `run.sh` the other three; terraform, ssh and the rest get none). `terraform-enabled-deploy.sh` exports them as `TF_VAR_git_admin_pat`, ... for terraform |

Each question is printed on one line and its default on the next, as `default = <value>`: press Enter to take it, or type another value. `FLEET_LOCAL_DIR` has no default line (Round 19): type the absolute path each time; with `--non-interactive` or `all --from` it comes from `env.sh`.

**Paths (Round 18).** `FLEET_LOCAL_DIR` and `fleet_zip_path` take an absolute path only, used exactly as typed: nothing is put in front of it, `~` is not expanded and nothing is stripped. Refused, with the reason, and asked again:
- a path that does not start with `/` (relative, `~/...`, or the default pasted with its brackets);
- spaces, quotes, `$`, backticks, backslashes, `[` or `]`;
- `.` or `..` segments, `//`, a trailing `/`;
- `fleet_zip_path` that is not an existing file ending in `.zip`;
- `FLEET_LOCAL_DIR` whose parent folder does not exist, that is inside tpg-aks-infra, or that holds the zip. It has no default (Round 19): type it; with `--non-interactive` it comes from the environment or `env.sh` only, never from `env.sh.example`.

A relative value already saved in `terraform.tfvars`, `deploy.tfvars` or `env.sh` is not offered as the default; with `--non-interactive` the script stops and names the file. Terraform's `fleet_zip_path` takes an absolute path only as well (validation), and `push-fleet-repo.sh` refuses a relative zip or `FLEET_LOCAL_DIR`.

`terraform/deploy.tfvars` (git-ignored) is passed with `-var-file` after `terraform.tfvars`, so its values win; `terraform.tfvars` is never rewritten. Once a value is in `deploy.tfvars`, change it there (or at the prompt): a later edit of the same key in `terraform.tfvars` has no effect. Lines you add to `deploy.tfvars` yourself (for example `github_url` or `fleet_repo_validate`) are kept when the scripts rewrite it. Lists may span lines in either file. The scripts also set `enable_jumpbox`, `jumpbox_provision`, `jumpbox_setup_method`, `create_fleet_repo` and `run_fleet_setup` there: the switches `true` and `remote-exec` for `terraform-enabled-deploy.sh`; `cloud-init` and `create_fleet_repo`/`run_fleet_setup` `false` for `deploy.sh`. `env.sh` is created from `env.sh.example` when it is missing; otherwise only the lines of the asked values change, after the diff is shown and you type `yes`.

Every run is logged to `.work/deploy-<UTC time>.log` (mode 600). No token reaches a file, the log or a command line; the scripts refuse to run under `bash -x`, whose trace would print them. Because the output also goes to the log, `run.sh` sees no terminal: add-on releases that are already installed follow `ADDONS_EXISTING` in `env.sh` (default `skip`), as in any run without a terminal.

### `terraform-enabled-deploy.sh`

- `preflight`: the tools above and `az login`.
- `apply`: the values and the four tokens, `deploy.tfvars`, `env.sh` (the jumpbox needs it: `run_fleet_setup`), `terraform init`, `terraform plan` (no plan file is saved, as it would hold the tokens), one confirmation, `terraform apply -auto-approve`. Inside that apply the jumpbox pushes the fleet repository and runs `run.sh --hub install --targets terraform --expose-ui --save-vault-recovery-keys` (section "Jumpbox (optional)"). At the end the script prints how to save the SSH key, read the Vault keys file on the jumpbox and delete it.
- `all`: `preflight`, then `apply`.

This machine must be inside `admin_allowed_cidrs`, as Terraform reaches the jumpbox over SSH.

### `deploy.sh`

| Subcommand | What it does | Needs first |
|---|---|---|
| `preflight` | The tools of every step and their versions, `az login`; refuses an `env.jumpbox.sh` next to `env.sh` (it belongs on the jumpbox) | |
| `apply` | Infrastructure values, `deploy.tfvars`, `terraform plan`, one confirmation, `terraform apply`; a jumpbox gets `jumpbox_setup_method = "cloud-init"` and installs its tools at first boot. With `create_role_assignments = false` the step then prints the `az role assignment create` commands of `role_assignments_to_create` for an owner. `all` **pauses** there (exit status 75, resume with `deploy.sh all --from repo`) only when they include Network Contributor ones, which `run.sh` needs; in `managed` mode (the only mode with `false`) the list holds the jumpbox and Managed Grafana assignments, which repo and setup on this machine do not need, so the run goes on | |
| `repo` | Repository values, `env.sh` (which `push-fleet-repo.sh` reads again, so it must hold the same repository URL, branch and folder), then `scripts/jumpbox/push-fleet-repo.sh <zip>` here: unzip to `FLEET_LOCAL_DIR` (an existing folder is moved to `<folder>.prev-<UTC time>`), create the private repository, `set-repo-url.sh`, `validate.sh` (`fleet_repo_validate`), push | `GIT_ADMIN_PAT` |
| `setup` | `env.sh`, then `scripts/run.sh --hub install --targets terraform --expose-ui --save-vault-recovery-keys` here; the Vault keys go to `VAULT_RECOVERY_KEYS_FILE` on this machine | `apply`, `repo`, the three run tokens |
| `copy` | With a jumpbox: waits over SSH for its first boot (`cloud-init status --wait`); if `setup-jumpbox.sh` did not finish there, prints the end of `/var/log/cloud-init-output.log`. Then `scripts/` to `~/scripts`; a `setup-jumpbox.sh` that did not finish, or differs from the one the jumpbox ran (its recorded sha256), runs again with `sudo`, its output shown and kept in `/var/log/tpg-jumpbox/setup-<UTC>.log` (a failure stops the copy; the next copy tries again). Then `FLEET_LOCAL_DIR`, `.git` included, to `~/tpg-fleet` (an existing one is moved to `~/tpg-fleet.prev-<UTC time>`), `env.sh` to `~/env.sh`, `.work` to `~/.work`, kubeconfig included, and `~/env.jumpbox.sh` and `~/.work/inventory.yaml` (`backup.keySource: az`, as the jumpbox has no Terraform state) from the Terraform outputs `jumpbox_env_override` and `jumpbox_inventory_yaml`, so the jumpbox ends up as after the remote-exec setup. The Vault keys file is not copied. Without a jumpbox it does nothing | `setup` (the kubeconfig), a confirmation |
| `all` | The tool check, every value and token once, a summary, then `apply`, `repo`, `setup`, `copy` with one confirmation (the plan) | |

A step whose earlier step is missing stops and names the subcommand to run first. Any failing command fails the subcommand. A failed step in `all` stops the run and prints `deploy.sh all --from <step>`. The copy uses the generated key from a private temporary folder that is removed on every path (or `jumpbox_ssh_private_key_path`), and `.work/jumpbox_known_hosts`; after the VM was replaced at the same IP, remove the old host key with `ssh-keygen -R <ip> -f .work/jumpbox_known_hosts`.

The copy puts **cluster-admin credentials on a second machine**: the kubeconfig of `.work` holds the admin client certificates of every cluster. They are as valid on the jumpbox as here, until the clusters' credentials are rotated (`az aks rotate-certs`), after which both copies are stale. The jumpbox's own identity could fetch them as well (`~/scripts/run.sh ... --only kubeconfigs`). After the copy, the submit scripts and `pgdata.py` run on the jumpbox:

```bash
ssh -i ~/.ssh/tpg-jumpbox tpgadmin@<public ip>
export KUBECONFIG=~/.work/kubeconfig
~/tpg-fleet/scripts/submit/tpg-day0.sh
~/scripts/run.sh --hub install --targets terraform --only verify
```

## Prerequisite scripts

### Prerequisites for `scripts/run.sh`

`scripts/run.sh` reads the fleet repository **from disk**, not from GitHub: the
`vault`, `addons` and `bootstrap` steps apply files out of `FLEET_LOCAL_DIR` and
run `tpg-fleet/workflows/scripts/helm-addons.sh` from it. A clone of `tpg-fleet`
that is missing, stale or still carries the `<org>` placeholder fails those steps
after the clusters have been touched, so do all of this first.

`deploy-scripts/deploy.sh` does all of this on this machine and `deploy-scripts/terraform-enabled-deploy.sh` through the jumpbox (section "Deploy scripts"). On the jumpbox, `create_fleet_repo = true` does steps 1 and 2 (unzip, `set-repo-url.sh`,
`chmod +x`, `validate.sh` with `tests/run-all.sh`, commit and push) and
`run_fleet_setup = true` does step 4 and runs `run.sh` (section "Jumpbox (optional)").

**1. Clone both repositories side by side.** The tests in either repository find
the other one when they are siblings.

```bash
mkdir -p ~/src && cd ~/src
git clone https://github.com/<your-org>/tpg-fleet.git
git clone https://github.com/<your-org>/tpg-aks-infra.git
```

**2. Prepare the `tpg-fleet` clone.** Every command runs inside it.

```bash
cd ~/src/tpg-fleet

# a. Replace the https://github.com/<org>/tpg-fleet.git placeholder everywhere
#    (bootstrap/, appsets, the Argo CD repository Secret). Argo CD cannot read
#    the repository until this is done.
./scripts/set-repo-url.sh https://github.com/<your-org>/tpg-fleet.git

# b. clusters/fleet.yaml ships empty (clusters: {}): tpg-day0 adds clusters and
#    instances itself. clusters/fleet.example.yaml shows a filled-in file.

# c. The scripts are run directly, so they must stay executable through the
#    clone (a zip or a Windows checkout can drop the bit).
chmod +x scripts/*.sh tests/run-all.sh tests/*/run.sh

# d. Offline tests: the CLI flag rules (Helm 4 dropped -a from helm list),
#    helm-addons.sh against a Helm 4 CLI, input types, clusterMap, tpg-patch,
#    the admission policies and the Argo CD RBAC block. No cluster, no Azure;
#    suites whose binary is missing (helm, envtest, argocd) print SKIP.
tests/run-all.sh

# e. Full static validation: yamllint, shellcheck, kustomize build,
#    helm lint/template of the instance chart, kubeconform.
./scripts/validate.sh

# f. Push, so Argo CD and the workflows read the same content from GitHub.
git add -A && git commit -m "Set repository URL" && git push -u origin main
```

`FLEET_LOCAL_DIR` must point at this clone and its checked-out branch must be
`FLEET_REPO_REVISION`; the `register` step warns when the local clone and the
pushed branch disagree.

**3. `helm-addons.sh` must read `KPS_HUB_EXTRA_VALUES` with a default.** The
script runs under `set -u`, and standalone hub monitoring aborts before
installing anything if that variable is unset. Check the clone:

```bash
grep -n 'raw="${KPS_HUB_EXTRA_VALUES:-}"' workflows/scripts/helm-addons.sh
```

One match means the clone is current. No match means it predates this fix, and
`monitoring_hub()` has to start like this:

```bash
monitoring_hub() {
  # raw defaults to empty: the script runs with set -u, and an unset
  # KPS_HUB_EXTRA_VALUES would otherwise abort the hub monitoring install with
  # "KPS_HUB_EXTRA_VALUES: unbound variable" before anything is installed.
  local f raw="${KPS_HUB_EXTRA_VALUES:-}"
  local files=("$FLEET_DIR/monitoring/standalone/hub/kps-values.yaml"
               "$FLEET_DIR/monitoring/grafana/alerts/grafana-alerting-values.yaml") m="$TMP/kps-hub.yaml"
  for f in ${raw//,/ }; do
    [[ "$f" == /* ]] || f="$FLEET_DIR/$f"
    [[ -f "$f" ]] || die "KPS_HUB_EXTRA_VALUES file not found: $f"
    files+=("$f")
  done
```

**4. Environment variables.** `env.sh` is sourced by every script in
`scripts/`; credentials are exported in the shell instead, so they never reach a
file.

| Variable | Set in | Required | Purpose |
|---|---|---|---|
| `FLEET_REPO_URL` | `env.sh` | yes | Fleet repository Argo CD reads and the workflows push to |
| `FLEET_REPO_REVISION` | `env.sh` | yes (`main`) | Branch of that repository |
| `FLEET_LOCAL_DIR` | `env.sh` | yes | Local `tpg-fleet` clone the `vault`, `addons` and `bootstrap` steps read (an absolute path; the deploy scripts and `push-fleet-repo.sh` refuse anything else) |
| `GITHUB_USER` | `env.sh` | yes | Owner of the fleet repository; checked against both PATs |
| `BROADCOM_USER` | `env.sh` | yes | Broadcom support portal user for the registry token |
| `MONITORING_OPTION` | `env.sh` | yes (`none`) | `none`, `azure` or `standalone`; written to `tpg-settings` |
| `TF_BIN` | `env.sh` | no (`terraform`) | `terraform` or `tofu` |
| `GITHUB_API_URL` | `env.sh` | no | GitHub Enterprise API root |
| `ARGOCD_CHART_VERSION`, `ARGO_WORKFLOWS_CHART_VERSION` | `env.sh` | no | Pinned hub chart versions |
| `KPS_HUB_EXTRA_VALUES` | `env.sh` | no | Extra hub `kps` values files, relative to `FLEET_LOCAL_DIR` |
| `ADDONS_EXISTING` | `env.sh` or shell | no | `ask`, `upgrade`, `skip`, `abort` for add-ons that already exist (`--yes` sets `upgrade`) |
| `BROADCOM_TOKEN` | shell | yes | Broadcom registry token; the scripts prompt when it is unset |
| `GIT_READ_PAT` | shell | yes | Fine-grained PAT, Contents: Read-only |
| `GIT_PUSH_PAT` | shell | yes | Fine-grained PAT, Contents: Read and write (plus Pull requests for `pushMode=pr`) |
| `BACKUP_STORAGE_KEY` | shell | no | Overrides `backup.keySource` |
| `ARGOCD_ADMIN_PASSWORD` | shell | no | Existing hub with no `argocd-initial-admin-secret` |
| `GRAFANA_ADMIN_PASSWORD` | shell | no | Standalone monitoring; generated when unset |
| `VAULT_TOKEN` | shell | no | Vault token with the `tpg-admin` policy; otherwise the scripts log in as `tpg-setup` |
| `VALIDATE_PR_WRITE` | shell | no | `true` proves Pull requests: write with a throwaway pull request |
| `VAULT_RECOVERY_KEYS_FILE` | `env.sh` | no (`~/.tpg/vault-keys.txt`) | Where `--save-vault-recovery-keys` writes the Vault keys |
| `INVENTORY_PREBUILT` | `env.jumpbox.sh` | no (`false`) | `true`: the inventory step checks `.work/inventory.yaml` that Terraform uploaded instead of reading `terraform output` (the jumpbox) |
| `FLEET_VALIDATE` or `fleet_repo_validate`, `FLEET_REPO_FORCE` or `fleet_repo_force` | `env.sh` | no (off) | `scripts/jumpbox/push-fleet-repo.sh`: run `validate.sh` / push with `--force` only when the Terraform variable of the same name is true as well |
| `FLEET_VALIDATE_TFVARS`, `FLEET_REPO_FORCE_TFVARS` | `env.jumpbox.sh`, or passed by `deploy.sh` | no | The Terraform half of the two switches above |
| `GIT_ADMIN_PAT` | shell | for `push-fleet-repo.sh` | Creates the fleet repository and pushes; Terraform passes `TF_VAR_git_admin_pat` |
| `INVENTORY`, `KUBECONFIG` | n/a | n/a | Set by `run.sh` and `scripts/lib/common.sh`; do not override |

### Prepare

```bash
cp env.sh.example env.sh      # FLEET_REPO_URL, FLEET_LOCAL_DIR, GITHUB_USER, BROADCOM_USER, MONITORING_OPTION
export BROADCOM_TOKEN='...' GIT_READ_PAT='...' GIT_PUSH_PAT='...'   # or let the scripts prompt
export GRAFANA_ADMIN_PASSWORD='...'   # standalone monitoring only; generated when not set
export VALIDATE_PR_WRITE=true         # optional: prove the push PAT by opening and closing a test pull request
```

Secrets are exported in the shell and never written to files. The one exception is opt-in: `--save-vault-recovery-keys` writes the Vault unseal or recovery keys to `VAULT_RECOVERY_KEYS_FILE` (below).

`~/env.jumpbox.sh`, when it exists next to `env.sh`, is read after it (the jumpbox; Terraform writes it).

Tools: az, kubectl, Helm (3.10+ or 4.x), argocd CLI v3.5.3, argo CLI v4.1, jq,
yq v4 (mikefarah), git, openssl, python3, and kubelogin for Entra ID-only
clusters. The workflow steps run `alpine/k8s:1.35.8`, which ships **Helm 4**:
the scripts avoid the flags Helm 4 removed and
`tpg-fleet/tests/cli-flags` fails the build when one comes back. The same suite fails on a jq or yq
alternative whose fallback is `true` or a non-zero number: jq's `//` also replaces an explicit
`false` (design decision I22).

### Choose the scenario

| | Hub without Argo | Hub with Argo already installed |
|---|---|---|
| **Clusters from Terraform** | `scripts/run.sh --hub install --targets terraform` | `scripts/run.sh --hub existing --targets terraform` |
| **Pre-created clusters** | `scripts/run.sh --hub install --targets precreated --inventory inventory/clusters.yaml` | `scripts/run.sh --hub existing --targets precreated --inventory inventory/clusters.yaml` |

For pre-created clusters, first copy `inventory/clusters.example.yaml` to `inventory/clusters.yaml` and fill in names, resource groups, waves, the access method (`az` or `kubeconfig`) and the existing backup Storage Account.

### Steps

| Step | Script | Terraform | Pre-created | Result |
|---|---|---|---|---|
| inventory | `targets/terraform/inventory-from-terraform.sh` or `targets/precreated/validate-inventory.sh` | generated (`INVENTORY_PREBUILT=true`: the file Terraform uploaded, checked) | validated | `.work/inventory.yaml` or `inventory/clusters.yaml` |
| preflight | `targets/precreated/preflight.sh` | skipped | read-only az checks | Cluster state, private API, local accounts, 3-zone pools, hub egress in target authorized ranges, storage containers (including `argo-logs`), the storage account HTTPS-only setting against `backup.httpsOnly` |
| kubeconfigs | `steps/10-kubeconfigs.sh` | az --admin | az (admin or kubelogin) or kubeconfig import | `.work/kubeconfig`, one context per cluster |
| hub | `hub/install/install-argo.sh` or `hub/existing/check-argo.sh` | | | Argo CD and Argo Workflows installed as Helm releases after the same pre-check as the add-ons (upgrade / skip / abort for a release that differs), or an existing Argo checked and additively patched |
| vault | `steps/35-vault.sh` | | | StorageClass `tpg-data-retain` with the configured disk SKU, then Vault on the hub (its pod table printed like every release: `vault-0` must start, then be Ready after the unseal): initialized, unsealed, configured with the initial root token (KV `tpg/`, Kubernetes auth, policies, roles, userpass `tpg-admin`), keys shown once (or, with `--save-vault-recovery-keys`, written to `VAULT_RECOVERY_KEYS_FILE`), root token revoked, Vault Secrets Operator on the hub |
| service-accounts | `steps/20-target-service-accounts.sh` | | | `kube-system/argocd-manager` and `tpg-vault-reviewer`, each with a token |
| register | `steps/30-register-clusters.sh` | | | `argocd/cluster-<target>` (labelled with `tpg.fleet/wave` and `tpg.fleet/dataDiskSku`), `argo/kubeconfig-<target>`, and `auth/k8s-<target>` in Vault |
| hub-secrets | `steps/40-hub-secrets.sh` | | | Credential pre-checks, the three credentials written to Vault, Argo CD repositories through VaultStaticSecrets, `tpg-settings` (including `backupCaBundle`, checked against the blob endpoint with openssl, and `acnsEnabled`), `argocd-workflow-token`, the Argo Workflows log archive (`argo/artifact-repositories`, `VaultStaticSecret argo/argo-artifacts`) |
| addons | `steps/45-helm-addons.sh` | | | Helm releases: `cert-manager` and the Vault Secrets Operator on targets. Standalone: the remote-write credential in Vault, `kps` and the remote-write gateway on the hub (and Secret `monitoring/grafana-admin`), `kps` + `tpg-ksm` on targets, and a check that every target's metrics reach the hub. Azure: the managed Prometheus add-on on clusters that lack it, the Grafana role check, the dashboard import |
| bootstrap | `steps/50-bootstrap-fleet.sh` | | | AppProjects `tpg` and `tpg-hub`, ApplicationSets, `tpg-hub-workflows` (which also installs the three admission policies `tpg-workflow-parameters`, `tpg-application-sync` and `tpg-credential-writer`, and the ServiceAccounts `argo/tpg-workflow` and `argo/tpg-credential-writer`), monitoring option |
| verify | `steps/60-verify.sh` | | | Read-only checks, including the Argo CD RBAC deny block (with the `argocd` CLI), AppProject `tpg-hub`, the three admission policies and their bindings, the ServiceAccounts `argo/tpg-workflow` and `argo/tpg-credential-writer`, the templates (`tpg-lib` and the thirteen workflows, `tpg-backup-expire` and `tpg-restore` among them), `backupCaBundle` and `acnsEnabled` in `tpg-settings`, per target the Azure fields of the PostgresBackupLocation CRD and CiliumNetworkPolicy (advisory), and, when `FLEET_LOCAL_DIR` holds the tpg-fleet clone, every instance declared in its `clusters/fleet.yaml` in its namespace (Round 23: `instance.namespace`, default `pg-<instance>`, not a reserved namespace, exactly one instance per namespace renders the shared Secrets; a namespace or Postgres that does not exist yet is a warning until tpg-day0 or tpg-create-instance creates it); a target's StorageClass `tpg-data-retain` missing before its `tpg-<cluster>-platform` Application has ever synced is a warning (tpg-day0 creates it), an issue after that. Ends with "All checks passed ..." or a summary of the issues grouped by resource with the clusters each one fails on (and advisory warnings apart), exit 1 |

### Options

| Option | Scenario | Effect |
|---|---|---|
| `--from STEP` / `--only STEP` | all | Resume or repeat a step |
| `--dry-run` | all | Print the step plan |
| `--fix-authorized-ips` | pre-created | Add the hub egress CIDRs to target API server authorized IP ranges |
| `--check-only` | existing hub | Stop after the hub checks; preflight reports but does not create containers or change authorized IPs |
| `--set-tracking-annotation` | existing hub | Set `application.resourceTrackingMethod: annotation` (affects every Application) |
| `--expose-ui` | all | Patch `argocd-server` and `argo-server` to LoadBalancer, expose the Vault UI, and (standalone monitoring) create the public Grafana, Prometheus and Alertmanager Services. Every load balancer is limited to `adminAllowedCidrs` |
| `--yes` | all | Upgrade Helm add-ons that are already installed instead of asking (`ADDONS_EXISTING=upgrade`). Existing hub: also add the Argo CD RBAC deny block for every subject that can still act on the tpg target Applications (`ASSUME_YES=1`) |
| `--only vault-unseal` | all | Unseal Vault after `vault-0` restarted (unseal mode `shamir`) |
| `--only access` | all | Print every UI endpoint and login to the terminal |
| `--rotate-vault-admin` | with `--only access` | Set a new Vault UI password for `tpg-admin` and print it |
| `--save-vault-recovery-keys` | all | First run of the `vault` step: write the 5 unseal or recovery keys to `VAULT_RECOVERY_KEYS_FILE` (mode 600) instead of showing them; no "stored" prompt, no terminal needed. The root token is not saved. See "Vault keys file" |

Before the credentials are stored, the `hub-secrets` step checks them and stops on the first failure with the exact error:

- the Broadcom registry token with `helm registry login` against the registry endpoint (a throwaway registry config, never `~/.config/helm`);
- both GitHub fine-grained PATs against the GitHub API: token type, owner, expiry date, access to the repository, the `contents` permission (read for `GIT_READ_PAT`, write for `GIT_PUSH_PAT`) and a `git ls-remote`. `GIT_PUSH_PAT` is additionally proven with `git push --dry-run`, and with `VALIDATE_PR_WRITE=true` by opening and closing a throwaway pull request.

An existing hub only receives additive changes: `accounts.workflow-bot: apiKey` when missing, the `role:tpg-sync` lines appended to `policy.csv` (including `repositories, get`, which `tpg-rotate-credential` needs to read the Argo CD repository connection state; a hub that has the role without that line gets it added by `--only hub`, and verify checks it), the RBAC deny block (with `--yes`, below), and the `argo-ui-admin` ServiceAccount. Helm owns those objects, so the script writes matching Helm values to `.work/hub-existing-*.yaml` for you to merge.

**Only the workflows sync the tpg target Applications.** People may not `sync` (which also covers rollback), `override`, `update` or `delete` the Applications of project `tpg`; `workflow-bot` (`role:tpg-sync`) syncs them. Argo CD evaluates a deny before any allow, and a deny on a role also removes what `policy.default` grants through it, so every subject that can act on project `tpg` gets its own deny lines, in a marked block of `policy.csv`:

```text
# >>> tpg-fleet rbac >>>
p, role:admin, applications, sync, tpg/*, deny
p, role:admin, applications, override, tpg/*, deny
p, role:admin, applications, update, tpg/*, deny
p, role:admin, applications, delete, tpg/*, deny
# <<< tpg-fleet rbac <<<
```

A hub installed by `run.sh` carries the block for `role:admin` (`argo/argocd-values.yaml`). On an existing hub, `check-argo.sh` asks the Argo CD permission checker (`argocd admin settings rbac can`) about `role:admin`, the `admin` user, `policy.default` and every subject and group named in `policy.csv`. Without `--yes` it prints the block and stops with `ARGO_RBAC_MISSING`; with `--yes` it writes the block (replacing an older one between the markers), checks again that no subject is left and that `workflow-bot` can still sync, and adds the block to the Helm values file it writes. There is no break-glass role. The hub admission policy `tpg-application-sync` (installed from `tpg-fleet/workflows/admission/`) refuses the same syncs at the Kubernetes API, including a `kubectl edit`, and the hub Applications are in project `tpg-hub`, which the deny lines do not cover.

The Make targets `deploy`, `deploy-terraform`, `install-terraform`, `existing-terraform`, `install-precreated`, `existing-precreated`, `check-existing-hub`, `addons`, `vault`, `vault-unseal`, `access`, `verify`, `wf-logs` (`WF=<workflow>`) and `test` wrap the same commands.

**Retries.** Every `kubectl`, `helm`, `az` and `argocd` call in the scripts retries transient errors of the AKS API server or Azure (timeouts, connection resets, TLS handshake timeouts, HTTP 429/502/503/504): 5 attempts with 5, 10, 20 and 40 seconds between them, set with `TPG_RETRY_ATTEMPTS` and `TPG_RETRY_DELAY` in `env.sh`. Other errors fail at once. Interactive commands (`kubectl exec`, `port-forward`, `logs -f`, `az login`, `argocd login`) are not retried. The log shows only the command and its verb, never the arguments.

**Waiting for pods.** While a Helm install waits, the pods of the namespace are printed every 5 seconds, and the step stops as soon as a pod cannot start (at once for `CreateContainerConfigError` and similar, after 60 seconds of `CrashLoopBackOff`, `ImagePullBackOff`, `Error` or `OOMKilled`, after 5 minutes unschedulable), with the pod's events and logs.

### Examples

```bash
# Everything, clusters from Terraform, fresh hub
scripts/run.sh --hub install --targets terraform

# Existing hub: inventory, preflight, kubeconfigs and hub checks only; no cluster or Azure changes
scripts/run.sh --hub existing --targets precreated --inventory inventory/clusters.yaml --check-only

# Pre-created clusters whose API servers do not yet allow the hub
scripts/run.sh --hub existing --targets precreated --inventory inventory/clusters.yaml --fix-authorized-ips

# Resume after fixing a repository credential
scripts/run.sh --hub install --targets terraform --from hub-secrets

# Without a terminal (Terraform on the jumpbox runs this): the Vault keys go to a file
scripts/run.sh --hub install --targets terraform --expose-ui --save-vault-recovery-keys
```

## Secrets in HashiCorp Vault

The `vault` step installs HashiCorp Vault (community edition, chart `hashicorp/vault` 0.34.1) on the hub, in namespace `vault`, with the Vault Agent Injector and a single server backed by integrated storage on `tpg-data-retain`. These credentials live in it, and nothing else:

| Vault path (KV v2 mount `tpg`) | Contents | Read by |
|---|---|---|
| `tpg/shared/broadcom-registry` | Broadcom registry user and token | Argo Workflows (Vault Agent), the Argo CD OCI repository, `regsecret` in every operator and instance namespace |
| `tpg/shared/github-read`, `tpg/shared/github-push` | The two GitHub fine-grained PATs | The Argo CD Git repository, and the workflows that push to `clusters/fleet.yaml` |
| `tpg/shared/backup-storage` | Azure storage account name and key | `backup-storage` in every instance namespace, which the `PostgresBackupLocation` refers to; `argo/argo-artifacts` for the workflow log archive |
| `tpg/shared/monitoring-remote-write` | User and password of the hub remote-write gateway (standalone monitoring; created by the `addons` step with a random password) | The hub gateway's htpasswd, and `monitoring/tpg-remote-write` on every target |
| `tpg/ca-bundles/<name>` | A named PEM CA bundle (key `caBundle`) for backup storage that uses a private CA; written with `scripts/vault-secret.sh ca put` or by `tpg-rotate-credential` | `tpg-day0`, `tpg-create-instance` and `tpg-patch` when the input `backupCaBundleVaultSecret` or the clusterMap key of that name refers to it |
| `tpg/custom/<name>` | Free-form key/value secrets written by `tpg-rotate-credential` with `credential=custom` | Nothing in this repository; for the operator's own use |

Postgres instance database users are not in Vault: they stay with the operator, because they are planned to move to OIDC or LDAP.

Who may read and write what is set by five policies in `tpg-fleet/vault/policies/`, bound to Kubernetes auth roles:

| Role | Auth mount | ServiceAccount | Policy |
|---|---|---|---|
| `tpg-setup` | `auth/kubernetes` (hub) | `vault/tpg-setup` | `tpg-admin`: the `tpg` mount, auth mounts, roles and policies, and `sys/wrapping/wrap` (used by these scripts and `scripts/vault-secret.sh`) |
| `tpg-workflow` | `auth/kubernetes` (hub) | `argo/tpg-workflow` | `tpg-workflow`: read the shared paths and `tpg/ca-bundles/*` |
| `tpg-credential-writer` | `auth/kubernetes` (hub) | `argo/tpg-credential-writer` | `tpg-credential-writer`: create, update and read the five shared credential paths, `tpg/ca-bundles/*` and `tpg/custom/*` (no delete); 15-minute tokens. Only the `write` step of `tpg-rotate-credential` runs as this ServiceAccount; the admission policy `tpg-credential-writer` refuses any other Workflow that names it, references that template or changes the run's spec, and keeps the workflow ServiceAccounts to the run records among the ConfigMaps of `argo` and to pod metadata (`tpg-fleet/docs/workflow-commands.md`, section 17) |
| `tpg-argocd` | `auth/kubernetes` (hub) | `tpg-vso` in `argocd` and `argo` | `tpg-argocd`: read the registry token, the read PAT and the backup storage key (for the workflow log archive) |
| `tpg-vso` | `auth/k8s-<cluster>` (one per target) | `tpg-vso` in any namespace | `tpg-target`: read the registry token, the backup key and the monitoring remote-write credential |

Each target cluster gets its own auth mount, created by the `register` step with the target's API server address, CA and the token of the `tpg-vault-reviewer` ServiceAccount. Targets reach Vault at `vault-fleet`: a public load balancer limited to the targets' outbound IPs in `managed` network mode (the default since Round 19), an internal one with `byo` (`vault.exposure` in the inventory), always over TLS with the CA that the step generates.

On the first run the step initializes Vault, unseals it from memory, configures it with the initial root token (mount, auth, policies, roles, `tpg-admin`), proves a login with role `tpg-setup`, and only then shows the unseal or recovery keys and the root token, once (or writes the keys to a file with `--save-vault-recovery-keys`, below). Ctrl+C, TERM or HUP while the keys are on screen does not end the step: the keys are shown again and the "stored" prompt asks again. If the step fails after init, the keys are printed before it exits. A later run that finds Vault initialized but not configured (the `tpg-setup` login is refused) resumes: it asks for the initial root token, or, with an empty answer, generates a new one from 3 unseal or recovery keys (`vault operator generate-root`), finishes the configuration and revokes it. The root token is revoked at the end, once a login with role `tpg-setup` is proven to work. For the UI there is a userpass account `tpg-admin` whose password is kept in Vault at `tpg/admin/vault-ui`; `scripts/run.sh ... --only access` prints it, and `--rotate-vault-admin` replaces it.

### Unseal modes

`vault_unseal_mode` has no default: every deployment states the choice, and `terraform plan` stops with "No value for required variable" until it is set. For pre-created clusters the same choice is `vault.unsealMode` in the inventory, and the vault step stops with both options named when it is missing.

| `vault_unseal_mode` | How it works | After a `vault-0` restart |
|---|---|---|
| `shamir` | 5 key shares, threshold 3, shown once on the terminal at init (or written to `VAULT_RECOVERY_KEYS_FILE` with `--save-vault-recovery-keys`). No Azure resources | `scripts/run.sh --hub <mode> --targets <mode> --only vault-unseal` and paste 3 keys |
| `azure-keyvault` | Auto-unseal with an RSA key in the Key Vault that Terraform creates, reached through the workload identity `id-vault` federated to ServiceAccount `vault/vault`. Init prints 5 recovery keys | Vault unseals itself |

Both modes print their keys once, on the terminal only, unless `--save-vault-recovery-keys` is passed. Store them in your own password manager before you continue: without them a sealed Vault in `shamir` mode cannot be opened again, and in `azure-keyvault` mode the recovery keys are what allow a rekey or a new root token.

### Vault keys file (`--save-vault-recovery-keys`)

With `scripts/run.sh ... --save-vault-recovery-keys`, the first run of the `vault` step (the one that runs `vault operator init`) writes the keys to a file instead of the terminal:

- **Contents:** the 5 key shares (unseal keys in `shamir` mode, recovery keys in `azure-keyvault` mode), one `Key <n>: <value>` line each, under a header with the mode, the hub and the UTC time. **Never the root token**: it is revoked at the end of the step, as without the flag.
- **Path:** `VAULT_RECOVERY_KEYS_FILE` (`env.sh`; default `~/.tpg/vault-keys.txt`; on the jumpbox `/home/<admin>/.tpg/vault-keys.txt`, Terraform output `jumpbox_vault_keys_file`). The directory is created with mode 700 and the file with mode 600. An existing file is never overwritten, since it may hold the only copy of a live Vault's keys: the new keys then go to `<file>.<UTC time>`.
- **Output:** only the path is printed, never a key, so the keys stay out of the `terraform apply` output and any CI log.
- **No terminal needed:** the step runs under Terraform `remote-exec` and skips the "stored" prompt.
- **Checks:** before `vault operator init` the step proves it can write to the directory, and stops otherwise. If the write still fails after init, the step shows the keys on the terminal when one is attached. Without a terminal it stops before the root token is revoked, with recovery steps (uninstall the `vault` release, delete PVC `data-vault-0`, re-run).
- Later runs, `--only vault-unseal` and `--only access` do not read the file: an unseal after a `vault-0` restart in `shamir` mode still takes 3 keys typed at the prompt.

Copy the file into a password manager, or split the keys between people, then delete it (`shred -u ~/.tpg/vault-keys.txt` on the jumpbox). Without the flag nothing changes: the keys are shown once and never written.

The unseal Key Vault uses its public endpoint and grants access with **Key Vault access policies**, not Azure RBAC: the identity running Terraform may create and read the key, and `id-vault` may get, wrap and unwrap it. That is deliberate: an access policy is written on the Key Vault itself, which a Contributor may do, while an RBAC role assignment needs `Microsoft.Authorization/roleAssignments/write`. Purge protection is **off** (`key_vault_purge_protection = false`) so `terraform destroy` removes the Key Vault and the POC can be rebuilt with the same prefix; soft delete stays at the 7-day minimum. The trade is real: deleting the Key Vault or the `vault-unseal` key permanently destroys the Vault data, because the recovery keys do not decrypt the storage. Set `key_vault_purge_protection = true` for anything that outlives the POC.

Secrets are never written to files by these scripts: tokens go into `kubectl exec` on standard input, `helm registry login` uses a throwaway registry config, and the unseal keys stay in memory for the length of the run. The one exception is `--save-vault-recovery-keys`, which you pass on purpose.

### Named CA bundles and new credential values (`scripts/vault-secret.sh`)

`scripts/vault-secret.sh` keeps named CA bundles in Vault and prepares new credential values for the workflow `tpg-rotate-credential`. It reaches Vault with `kubectl exec` into `vault/vault-0` on the hub (a 30-minute token of role `tpg-setup`), or over HTTPS with `--vault-addr https://<vault-ui or vault-fleet address>:8200` and the userpass account `tpg-admin` (password from `VAULT_UI_PASSWORD`, or asked for). `VAULT_TOKEN`, when exported, is used as is.

A named bundle is the PEM CA of a backup storage endpoint that uses a private CA. The workflows `tpg-day0`, `tpg-create-instance` and `tpg-patch` read it when the input or clusterMap key `backupCaBundleVaultSecret` names it, and copy it into the instance's `backup.caBundle` in `fleet.yaml`: changing or deleting the bundle in Vault later does not change running instances until the next `tpg-patch`.

```bash
scripts/vault-secret.sh ca put storage-ca ./storage-ca.pem   # write or replace tpg/ca-bundles/storage-ca
scripts/vault-secret.sh ca list
scripts/vault-secret.sh ca get storage-ca                    # print the PEM
terraform -chdir=terraform output -raw backup_storage_ca_bundle | scripts/vault-secret.sh ca put azure-storage -
```

`ca put` checks that the file holds PEM certificates, none expired, at most 64 KiB.

`wrap` puts a new credential value into a Vault response-wrapping token (single use, valid 10 minutes) and prints only the token. The value comes from an exported shell variable or from a hidden prompt, and never reaches a command-line argument or a file. The workflow unwraps the token in its `write` step, which alone runs as `argo/tpg-credential-writer`, writes the new version to Vault and then refreshes the Secrets that depend on it.

```bash
read -rs GIT_PUSH_PAT; export GIT_PUSH_PAT GITHUB_USER=<github-user>
T="$(scripts/vault-secret.sh wrap git-push)"
argo submit -n argo --from workflowtemplate/tpg-rotate-credential \
  -p secretType=git-push -p wrappingToken="$T" --watch
unset GIT_PUSH_PAT T
```

The secret types and their variables are `broadcom-registry` (`BROADCOM_USER`, `BROADCOM_TOKEN`), `git-read` and `git-push` (`GITHUB_USER`, `GIT_READ_PAT` or `GIT_PUSH_PAT`), `backup-storage` (`BACKUP_STORAGE_KEY`; the account name comes from the inventory), `monitoring-remote-write` (`REMOTE_WRITE_PASSWORD`, 16 characters or more), `ca-bundle NAME FILE` and `custom NAME KEY...` (one hidden prompt per key). A token that someone else unwrapped first makes the workflow fail with `WRAPPING_TOKEN_INVALID`: treat that as a sign that the token was intercepted, and replace the credential again. `scripts/vault-secret.sh --help` lists every option.

## Access to the UIs and credentials

```bash
scripts/run.sh --hub <mode> --targets <mode> --only access    # or: make access
```

It prints, to the terminal only, the Argo CD URL with the admin password, where the archived workflow logs are, the Argo Workflows URL with the `argo-ui-admin` bearer token, the Vault URL with the `tpg-admin` password, seal state and unseal mode, the Grafana, Prometheus and Alertmanager URLs with the Grafana password (or the Azure Managed Grafana endpoint), every Postgres instance with its service host and how to read its credentials, and the kubeconfig with its contexts. Services that are not exposed are printed as a ready-to-run `kubectl port-forward` command.

## First workflow

```bash
export KUBECONFIG="$PWD/.work/kubeconfig"
# Dry run: validates the inputs, shows the clusters/fleet.yaml change and runs the pre-check
argo submit -n argo --from workflowtemplate/tpg-day0 \
  -p clusters=all -p 'instances=[orders-db]' -p highAvailability=true \
  -p operatorVersion=v4.5.0 -p postgresVersion=postgres-17.6 -p pushMode=direct \
  -p dryRun=true --watch
# Deploy
argo submit -n argo --from workflowtemplate/tpg-day0 \
  -p clusters=all -p 'instances=[orders-db]' -p highAvailability=true \
  -p operatorVersion=v4.5.0 -p postgresVersion=postgres-17.6 -p pushMode=direct --watch
```

Add instances to a cluster that runs the operator with `tpg-create-instance`, and set their network policy with `tpg-network-policy`. An instance runs in `pg-<instance>` unless its `clusterMap` entry names a `namespace` (Round 23). `tpg-fleet/scripts/submit/tpg-<workflow>.sh` asks for the inputs interactively instead. See `tpg-fleet/docs/workflow-commands.md` for every workflow with examples.

## Scaling from 3 to n clusters

No per-cluster folder is needed in `tpg-fleet`: every cluster uses `clusters/_template/`, and `tpg-day0` adds the cluster to `clusters/fleet.yaml`.

- **Terraform:**
  1. Raise `target_cluster_count` and run `terraform apply`.
  2. Run `scripts/run.sh --hub <mode> --targets terraform`. Existing clusters are re-applied without changes.
- **Pre-created:**
  1. Append the cluster to `inventory/clusters.yaml`.
  2. Run `scripts/run.sh --hub <mode> --targets precreated`.

Then run `tpg-day0 -p 'clusters=[<new>]' ...` with the same inputs as the other clusters.

## Monitoring options

- **Option A, Azure Monitor:** `enable_azure_monitor = true` and `MONITORING_OPTION=azure`. The bootstrap step applies the Argo CD Applications in `tpg-fleet/bootstrap/monitoring/azure`. The `addons` step enables the managed Prometheus add-on (`az aks update --enable-azure-monitor-metrics`) on every cluster that lacks it, linked to the Azure Monitor workspace (from Terraform, or `monitoring.azureMonitorWorkspaceId` for pre-created clusters), and checks its `ama-metrics` pods. It checks that Azure Managed Grafana has `Monitoring Data Reader` on the workspace and prints the `az role assignment create` command when it does not (a Contributor cannot create it), then imports the dashboards and alerts (`tpg-fleet/monitoring/grafana/import-azure-grafana.sh rg-tpgpoc amg-tpgpoc` does the same by hand).
- **Option B, standalone:** `MONITORING_OPTION=standalone`. The addons step installs Helm releases: `kps` (kube-prometheus-stack 91.4.0) on the hub with Grafana, Alertmanager and the dashboards, and `kps` (Prometheus agent) plus `tpg-ksm` (kube-state-metrics) on every target. It creates Secret `monitoring/grafana-admin` before the install. Targets write to the hub through the remote-write gateway `monitoring/tpg-remote-write`: https on port 8443 with a certificate from the Vault CA, basic auth with the credential in Vault `tpg/shared/monitoring-remote-write`, and only `/api/v1/write` forwarded. Its load balancer is internal, or public and limited to the target egress CIDRs, from the inventory `monitoring.remoteWriteExposure` (Terraform: `internal` for `byo` networking, `public` otherwise). The step stores `https://<gateway IP>:8443/api/v1/write` in `tpg-settings`, so targets are configured without manual IP edits, and fails when a target's metrics do not reach the hub within 5 minutes (`MONITORING_FLOW_TIMEOUT`). Grafana's Prometheus and Alertmanager data sources are provisioned explicitly. With `--expose-ui` it also creates the LoadBalancer Services `tpg-grafana-public`, `tpg-prometheus-public` and `tpg-alertmanager-public`, limited to `adminAllowedCidrs`. Check them with `helm list -n monitoring`.

Both options have five dashboards in the folder Tanzu Postgres: Fleet, Instance overview, Replication and HA, Backup/WAL/restore, and Alerts.

Both options scrape the Postgres instances every 10 seconds with a `PodMonitor` for the `postgres-exporter` sidecar that the operator runs next to each instance, and both alert when Vault is sealed (`tpg-vault-sealed`).

Container Insights (`enable_container_insights`, off by default since Round 19) is independent of both options.

## Workflow logs

Argo Workflows archives every step's log to the `argo-logs` container of the backup storage account (`archiveLogs`, namespace default artifact repository `argo/artifact-repositories`, account key from Vault through `VaultStaticSecret argo/argo-artifacts`). The Argo UI shows a finished step's log after its pod is gone, while the Workflow exists (7 days). Later:

```bash
scripts/wf-logs.sh <workflow> --list          # or: make wf-logs WF=<workflow>
scripts/wf-logs.sh <workflow> --grep RESULT
```

A lifecycle rule deletes the logs after `argo_logs_retention_days` (90). For a pre-created storage account, preflight creates the container; add the rule once with the command in `docs/README-manual-steps.md` section 3.3.

## Clean up

```bash
make destroy   # deletes the resource group: all clusters, the Storage Account and every backup
```

For pre-created clusters, nothing is deleted by this repository. To remove the fleet objects, see the uninstall section of `docs/README-argo-on-aks.md`.
