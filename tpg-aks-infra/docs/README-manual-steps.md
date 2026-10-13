# Manual steps behind the prerequisite scripts

This guide shows, command by command, everything `scripts/run.sh` automates. Use it to run a step by hand, to understand what a script changes, or to troubleshoot a failed step. Each section names the script it mirrors, the cluster it touches, and the expected result.

| Scenario | Command | Sections |
|---|---|---|
| Terraform clusters, hub without Argo | `scripts/run.sh --hub install --targets terraform` | 1, 2, 3.1, 4, 5.1, 6–12 |
| Terraform clusters, hub with Argo | `scripts/run.sh --hub existing --targets terraform` | 1, 2, 3.1, 4, 5.2, 6–12 |
| Pre-created clusters, hub without Argo | `scripts/run.sh --hub install --targets precreated` | 1, 3.2, 3.3, 4, 5.1, 6–12 |
| Pre-created clusters, hub with Argo | `scripts/run.sh --hub existing --targets precreated` | 1, 3.2, 3.3, 4, 5.2, 6–12 |

`run.sh` runs the steps in this order: `inventory`, `preflight` (pre-created only), `kubeconfigs`, `hub`, `vault`, `service-accounts`, `register`, `hub-secrets`, `addons`, `bootstrap`, `verify`. Two more steps run only with `--only`: `vault-unseal` (section 6.4) and `access` (section 13). Resume a failed run with `--from <step>` or repeat one step with `--only <step>`. Every step is idempotent. With `deploy-scripts/deploy.sh` the same resume is `deploy.sh setup --run-step-from <step>`; `scripts/validate.sh` of the fleet repository runs in its repo step only when `fleet_repo_validate` and `FLEET_VALIDATE` are both true (off by default).

`deploy-scripts/deploy.sh all` runs Terraform (section 2), the fleet repository preparation (1.3) with `scripts/jumpbox/push-fleet-repo.sh`, and `scripts/run.sh` on this machine after a few prompts; `deploy-scripts/terraform-enabled-deploy.sh all` runs one `terraform apply` whose jumpbox does the rest. The values they ask for go to `terraform/deploy.tfvars` and `env.sh` (section 1.4); the tokens stay in the environment. README, section "Deploy scripts".

## Contents

1. [Workstation and shell variables](#1-workstation-and-shell-variables) (1.3 clone and prepare tpg-fleet, 1.4 environment variables)
2. [Create the Azure infrastructure with Terraform](#2-create-the-azure-infrastructure-with-terraform)
3. [Build the cluster inventory](#3-build-the-cluster-inventory)
4. [Fetch kubeconfigs](#4-fetch-kubeconfigs)
5. [Prepare the hub](#5-prepare-the-hub)
6. [Install HashiCorp Vault on the hub](#6-install-hashicorp-vault-on-the-hub)
7. [Create the ServiceAccounts on each target](#7-create-the-serviceaccounts-on-each-target)
8. [Register the targets on the hub](#8-register-the-targets-on-the-hub)
9. [Store the credentials in Vault and create the hub settings](#9-store-the-credentials-in-vault-and-create-the-hub-settings)
10. [Install the Helm add-ons](#10-install-the-helm-add-ons)
11. [Bootstrap the fleet](#11-bootstrap-the-fleet)
12. [Verify](#12-verify)
13. [Print every UI endpoint and login](#13-print-every-ui-endpoint-and-login)
14. [Troubleshooting](#14-troubleshooting)

---

## 1. Workstation and shell variables

### 1.1 Tools

| Tool | Minimum version | Used by |
|---|---|---|
| Azure CLI | 2.60 | kubeconfigs, preflight, backup key |
| kubectl | cluster minor version | every step |
| kubelogin | 0.1.x | kubeconfigs, only for clusters with local accounts disabled |
| Helm | 3.10, or 4.x | hub install, add-ons |
| argocd CLI | v3.5.3 | hub-secrets |
| argo CLI | v4.1.3 | running workflows |
| jq | 1.6 | every step |
| yq (mikefarah) | v4.40 | inventory, kubeconfigs |
| openssl | 1.1.1 | Vault TLS (section 6.2) |
| Terraform or OpenTofu | 1.9 or later (`required_version = ">= 1.9.0"`) | Terraform scenario |

`yq` must be the Go implementation by Mike Farah. The Python `yq` wrapper uses different syntax and fails.

```bash
yq --version   # yq (https://github.com/mikefarah/yq/) version v4.x
```

The workflow steps run `alpine/k8s:1.35.8`, which ships **Helm 4**. Helm 4
removed the `-a` flag from `helm list` (it lists every release state by default), renamed
`--atomic` to `--rollback-on-failure` and `--force` to `--force-replace`, and
accepts only a registry domain for `helm registry login`. The scripts in both
repositories avoid those flags, and `tpg-fleet/tests/cli-flags` fails the build
if one comes back. Your workstation may still run Helm 3: every command in this
guide works on both.

```bash
helm version --short   # v3.16+ or v4.x
```

### 1.2 Variables used in this guide

```bash
cd tpg-aks-infra
cp env.sh.example env.sh      # edit FLEET_REPO_URL, FLEET_LOCAL_DIR, GITHUB_USER, BROADCOM_USER
source env.sh

export WORK="$PWD/.work"; mkdir -p "$WORK"; chmod 700 "$WORK"
export KUBECONFIG="$WORK/kubeconfig"   # all commands use a dedicated kubeconfig

export SUBSCRIPTION_ID="11111111-2222-3333-4444-555555555555"
export HUB="aks-tpg-hub"
export TARGETS="aks-tpg-poc-01 aks-tpg-poc-02 aks-tpg-poc-03"
export ALLOWED_CIDRS='["203.0.113.10/32"]'   # your public IP: curl -s https://ifconfig.me

az login
az account set --subscription "$SUBSCRIPTION_ID"
```

The scripts read these values from the inventory (section 3) instead of shell variables.

### 1.3 Clone and prepare tpg-fleet

Everything below runs before the first `scripts/run.sh`. `run.sh` reads the
fleet repository from disk: the `vault`, `addons` and `bootstrap` steps apply
files out of `FLEET_LOCAL_DIR` and run
`tpg-fleet/workflows/scripts/helm-addons.sh` from it. A clone that is missing,
stale, or still carries the `<org>` placeholder fails those steps after the
clusters have already been changed.

With the jumpbox, Terraform can do this section for you: `create_fleet_repo = true`
uploads `tpg-fleet.zip`, creates the GitHub repository and runs
`scripts/jumpbox/push-fleet-repo.sh`, which unzips it to `~/tpg-fleet`, runs
`set-repo-url.sh`, `chmod +x`, `validate.sh` (with `tests/run-all.sh`), commits
and pushes (README, "Jumpbox (optional)").

```bash
mkdir -p ~/src && cd ~/src
git clone https://github.com/<your-org>/tpg-fleet.git
git clone https://github.com/<your-org>/tpg-aks-infra.git
```

Inside the fleet clone:

```bash
cd ~/src/tpg-fleet

# Replace the https://github.com/<org>/tpg-fleet.git placeholder in bootstrap/,
# the ApplicationSets and the repository Secret. Argo CD cannot read the
# repository until this has run.
./scripts/set-repo-url.sh https://github.com/<your-org>/tpg-fleet.git
git grep -n '<org>' || echo "no placeholders left"

# clusters/fleet.yaml ships empty (clusters: {}); tpg-day0 adds clusters and
# instances itself. clusters/fleet.example.yaml shows a filled-in file.

# Keep the scripts executable (a zip or a Windows checkout can drop the bit).
chmod +x scripts/*.sh tests/run-all.sh tests/*/run.sh

# Offline tests: CLI flag rules, helm-addons.sh against a Helm 4 CLI, input
# types, clusterMap, tpg-patch, the admission policies (envtest), server-side
# apply and the Argo CD RBAC block (argocd CLI). A suite whose binary is
# missing prints SKIP.
tests/run-all.sh

# Static validation: yamllint, shellcheck, kustomize build, helm lint/template
# (with the example patch files), kubeconform, the generated monitoring files
# and the generated Workflow parameter policy.
./scripts/validate.sh

git add -A && git commit -m "Set repository URL" && git push -u origin main
git rev-parse --abbrev-ref HEAD     # must equal FLEET_REPO_REVISION
```

`monitoring_hub()` in `workflows/scripts/helm-addons.sh` must read
`KPS_HUB_EXTRA_VALUES` through a defaulted local. The script runs under
`set -u`, so an unset variable aborts the standalone hub monitoring install
before anything is installed:

```bash
grep -n 'raw="${KPS_HUB_EXTRA_VALUES:-}"' workflows/scripts/helm-addons.sh
```

One match means the clone is current. No match means it predates this fix; the
function has to start like this:

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
  merge_values "$m" "${files[@]}"
  grafana_admin_secret
  release kps kube-prometheus-stack "$KPS_VERSION" "$PROM_REPO" monitoring "$m" ""
  ...
```

Then prepare the infrastructure clone:

```bash
cd ~/src/tpg-aks-infra
chmod +x scripts/*.sh scripts/*/*.sh scripts/*/*/*.sh tests/*/run.sh
cp env.sh.example env.sh && vi env.sh        # section 1.4
./scripts/run.sh --hub install --targets terraform --dry-run   # prints the step list only
```

### 1.4 Environment variables

`env.sh` is sourced by every script under `scripts/` and is git-ignored. On the jumpbox, `env.jumpbox.sh` (written by Terraform) is read after it.
Credentials are **not** written to it: export them in the shell, or let the
`hub-secrets` step prompt for them.

| Variable | Set in | Required | Purpose |
|---|---|---|---|
| `FLEET_REPO_URL` | `env.sh` | yes | Fleet repository Argo CD reads and the workflows push to |
| `FLEET_REPO_REVISION` | `env.sh` | yes (`main`) | Branch of that repository |
| `FLEET_LOCAL_DIR` | `env.sh` | yes | Local `tpg-fleet` clone read by the `vault`, `addons` and `bootstrap` steps; an absolute path (the deploy scripts and `push-fleet-repo.sh` refuse a relative one) |
| `GITHUB_USER` | `env.sh` | yes | Owner of the fleet repository; checked against both PATs |
| `BROADCOM_USER` | `env.sh` | yes | Broadcom support portal user for the registry token |
| `MONITORING_OPTION` | `env.sh` | yes (`none`) | `none`, `azure` or `standalone`; written to `tpg-settings` |
| `TF_BIN` | `env.sh` | no (`terraform`) | `terraform` or `tofu` |
| `GITHUB_API_URL` | `env.sh` | no | GitHub Enterprise API root (`https://<host>/api/v3`) |
| `ARGOCD_CHART_VERSION`, `ARGO_WORKFLOWS_CHART_VERSION` | `env.sh` | no | Pinned hub chart versions (10.9.1, 2.0.6) |
| `KPS_HUB_EXTRA_VALUES` | `env.sh` | no | Extra hub `kps` values files, comma separated, relative to `FLEET_LOCAL_DIR` |
| `ADDONS_EXISTING` | `env.sh` or shell | no | `ask`, `upgrade`, `skip` or `abort` for Helm releases that already exist: the add-ons, Vault, and on a hub without Argo the `argocd` and `argo-workflows` releases |
| `TPG_RETRY_ATTEMPTS`, `TPG_RETRY_DELAY` | `env.sh` or shell | no (`5`, `5`) | Attempts and first delay (doubled each time) for transient `kubectl`, `helm`, `az` and `argocd` errors |
| `MONITORING_FLOW_TIMEOUT` | `env.sh` or shell | no (`300`) | Seconds to wait for a target's metrics on the hub Prometheus (standalone monitoring) |
| `BROADCOM_TOKEN` | shell | yes | Broadcom registry token |
| `GIT_READ_PAT` | shell | yes | Fine-grained PAT, Contents: Read-only |
| `GIT_PUSH_PAT` | shell | yes | Fine-grained PAT, Contents: Read and write (plus Pull requests for `pushMode=pr`) |
| `BACKUP_STORAGE_KEY` | shell | no | Overrides `backup.keySource` |
| `ARGOCD_ADMIN_PASSWORD` | shell | no | Existing hub with no `argocd-initial-admin-secret` |
| `GRAFANA_ADMIN_PASSWORD` | shell | no | Standalone monitoring; a 24-character password is generated when unset |
| `VAULT_TOKEN` | shell | no | Vault token with the `tpg-admin` policy; otherwise the scripts log in with the `tpg-setup` role |
| `VALIDATE_PR_WRITE` | shell | no | `true` proves Pull requests: write with a throwaway pull request |
| `VAULT_RECOVERY_KEYS_FILE` | `env.sh` | no (`~/.tpg/vault-keys.txt`) | Where `run.sh --save-vault-recovery-keys` writes the Vault keys (section 6.4) |
| `DEPLOY_TFVARS`, `DEPLOY_BASH_CANDIDATES` | shell | no | `deploy-scripts/`: another values file than `terraform/deploy.tfvars`; where to look for a bash 4 (default `/opt/homebrew/bin/bash /usr/local/bin/bash`) |
| `INVENTORY_PREBUILT` | `env.jumpbox.sh` | no (`false`) | `true` on the jumpbox: the inventory Terraform uploaded is checked instead of built from `terraform output` (section 3.1) |
| `GIT_ADMIN_PAT` | shell | for the jumpbox fleet repository | Creates the repository and pushes (`scripts/jumpbox/push-fleet-repo.sh`) |
| `INVENTORY` | set by `run.sh` | n/a | `.work/inventory.yaml` or `inventory/clusters.yaml` |
| `KUBECONFIG` | set by `common.sh` | n/a | Always `.work/kubeconfig`, so your own kubeconfig is untouched |

```bash
cd ~/src/tpg-aks-infra
source env.sh
read -rs -p 'Broadcom token: '        BROADCOM_TOKEN; echo; export BROADCOM_TOKEN
read -rs -p 'GitHub read-only PAT: '  GIT_READ_PAT;   echo; export GIT_READ_PAT
read -rs -p 'GitHub read/write PAT: ' GIT_PUSH_PAT;   echo; export GIT_PUSH_PAT
[[ -d "$FLEET_LOCAL_DIR/.git" ]] && echo "fleet clone: $FLEET_LOCAL_DIR ($(git -C "$FLEET_LOCAL_DIR" rev-parse --abbrev-ref HEAD))"
```

---

## 2. Create the Azure infrastructure with Terraform

Skip this section for pre-created clusters.

### 2.1 What the modules create

Every resource is created in one resource group, `rg-tpgpoc` by default (`resource_group_name` overrides it). Azure also creates one AKS-owned node resource group per cluster, named `rg-tpgpoc-<cluster>-nodes`. AKS requires that group to be separate, and it is deleted with the cluster.

| Module | Resources |
|---|---|
| `resource-group` | The POC resource group |
| `network` | `byo` mode: VNet `vnet-tpgpoc`, a /22 subnet per cluster, static hub egress IP. `managed` mode: nothing (AKS-managed VNets) |
| `identity` | `id-<cluster>` control plane identities; with `byo`, Network Contributor on their subnet (and the hub egress IP) |
| `aks` | One cluster per module instance: system pool, plus the `pgdata` user pool on targets |
| `storage` | Backup Storage Account (ZRS) and one private container per target |
| `monitoring` | Optionally Log Analytics and Container Insights (`enable_container_insights`, off by default since Round 19), managed Prometheus and Managed Grafana |
| `jumpbox` | Optional (`enable_jumpbox = true`): an operator VM with a public IP (SSH from `admin_allowed_cidrs` only), NSG, managed identity `id-jumpbox` (Contributor on the resource group, Cluster Admin on every cluster, Reader on every node resource group), and a /27 subnet `snet-jumpbox` (from the `network` module with `byo`, its own VNet with `managed`), with an SSH key pair generated by Terraform. `jumpbox_setup_method = "remote-exec"` (default): `terraform/jumpbox-provision.tf` copies `scripts/` and `env.sh` to the admin user's home over SSH and runs `scripts/jumpbox/setup-jumpbox.sh` there, its output in `terraform apply`; `"cloud-init"` (Round 19, `deploy-scripts/deploy.sh`): the VM runs `/home/<admin>/setup-jumpbox.sh` at first boot instead; and optionally pushes the fleet repository (`create_fleet_repo`) and runs `scripts/run.sh` (`run_fleet_setup`); see the README section "Jumpbox (optional)" |

Cluster defaults, aligned with an Azure portal-created cluster:

| Setting | Default |
|---|---|
| Tier | Standard (API server uptime SLA) |
| Node pools | Autoscaling on; each pool picks 1 to 3 availability zones and holds at least one node per zone |
| System pool | Standard_D8ds_v5, Ephemeral 300 GB OS disk, 110 pods per node, CriticalAddonsOnly on targets; zone 1, 1 node, autoscaler 1 to 5 |
| `pgdata` pool | Standard_D8ds_v5, Managed 256 GB OS disk, 30 pods per node; zones 1, 2 and 3, 3 nodes, autoscaler 3 to 6 (what `highAvailability=true` needs) |
| Postgres data disks | StorageClass `tpg-data-retain`, `Premium_ZRS` by default (`postgres_data_disk_sku`) |
| Node OS | Ubuntu 24.04 |
| Upgrades | max surge 10% (max unavailable 0); auto-upgrade and node OS channels off |
| Add-ons | Workload identity and OIDC issuer, Image Cleaner (168 h), Azure Policy; Container Insights only with `enable_container_insights = true` |
| Networking | Azure CNI Overlay with Cilium, pods 192.168.0.0/16, services 172.16.0.0/16 |

### 2.2 Choose API access and network mode

| Goal | `terraform.tfvars` |
|---|---|
| AKS-managed VNets (default since Round 19) | `network_mode = "managed"` (forces public API servers; no static hub egress IP; no Network Contributor role assignments) |
| Own VNet, API servers limited to your IP | `network_mode = "byo"`, `api_access_mode = "restricted"`, `admin_allowed_cidrs = ["203.0.113.10/32"]` and `create_role_assignments = true` |
| Own VNet, public API servers | `network_mode = "byo"`, `api_access_mode = "public"` (or `admin_allowed_cidrs = ["0.0.0.0/0"]`) and `create_role_assignments = true` |

`byo` needs `create_role_assignments = true`, which needs an Owner or User Access Administrator account: the cluster identities need Network Contributor on their subnets (and the hub on its egress IP) before the clusters exist, and Terraform refuses `byo` without it. In restricted mode, target API servers also allow the hub egress IP so that Argo CD and Argo Workflows can reach them. `admin_allowed_cidrs` is still used for the Argo UI load balancers in public mode, so keep your own CIDR there unless you want public UIs.

### 2.3 Apply

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # edit subscription_id and admin_allowed_cidrs
terraform init
terraform plan -out tfplan
terraform apply tfplan
terraform output
cd ..
```

Example output:

```text
api_access_mode = "public"
backup_storage_account_name = "tpgpocbkp7k2m9q"
hub_cluster_name = "aks-tpg-hub"
hub_egress_ip = null
network_mode = "managed"
resource_group_name = "rg-tpgpoc"
target_cluster_names = ["aks-tpg-poc-01", "aks-tpg-poc-02", "aks-tpg-poc-03"]
target_cluster_waves = { "aks-tpg-poc-01" = 0, "aks-tpg-poc-02" = 1, "aks-tpg-poc-03" = 1 }
```

Check the zone spread of a pool:

```bash
az aks nodepool show -g rg-tpgpoc --cluster-name aks-tpg-poc-01 -n pgdata \
  --query '{zones:availabilityZones, min:minCount, max:maxCount, osDisk:osDiskType, sku:osSku}' -o json
```

```json
{ "zones": ["1", "2", "3"], "min": 3, "max": 6, "osDisk": "Managed", "sku": "Ubuntu2404" }
```

Two storage settings belong together with the fleet: `backup_storage_https_only` (default `false`) must be `true` only when the instances use `enableSSL: true` (`tpg-fleet` `backup.enableSSL`, or `tpg-day0 -p backupEnableSSL=true`); `argo_logs_retention_days` (default 90) is how long the archived workflow logs in container `argo-logs` are kept. Check them after apply:

```bash
terraform output backup_storage_https_only
terraform output argo_logs_container
az storage account show -g rg-tpgpoc -n tpgpocbkp7k2m9q --query enableHttpsTrafficOnly -o tsv   # false
az storage account management-policy show -g rg-tpgpoc --account-name tpgpocbkp7k2m9q \
  --query 'policy.rules[].{name:name, prefix:definition.filters.prefixMatch, days:definition.actions.baseBlob.delete.daysAfterModificationGreaterThan}' -o json
```

**CA bundle for `enableSSL: true`.** pgBackRest checks the blob endpoint against the backup location's `caBundle`. A TLS server does not send its root certificate, so Terraform does not take the bundle from the endpoint: it uses the root certificate authorities Microsoft publishes for Azure services (`terraform/modules/storage/azure-ca-roots.pem`, from https://learn.microsoft.com/azure/security/fundamentals/azure-ca-details), reads the chain the new account presents (`data "tls_certificate"`), and fails the apply when that chain is not issued under one of them. The apply error then names the issuer it found; update `azure-ca-roots.pem` from the Microsoft page. The inventory step writes the bundle to `.work/backup-ca-bundle.pem`, and the hub-secrets step stores it in `tpg-settings` (`backupCaBundle`, 9.4), where tpg-day0 and tpg-create-instance read it for instances with `enableSSL: true`:

```bash
terraform output -raw backup_storage_ca_bundle | grep -c 'BEGIN CERTIFICATE'   # 7
terraform output backup_storage_ca_issuers                                     # the chain the endpoint presented
```

**Advanced Container Networking Services.** `acns_enabled` (default `false`) turns on the security part of AKS advanced networking on every cluster (`network_profile.advanced_networking`, a paid AKS feature). With it, CiliumNetworkPolicy accepts host-name rules: the Postgres network policies (`tpg-fleet` `networkPolicy=baseline`, `tpg-network-policy`) then allow backup egress to `*.blob.core.windows.net` only, and accept `egressToFqdns`. Without it, backup egress is allowed to any address on port 443 (and 80 while `enableSSL` is `false`), and `egressToFqdns` is refused (`ACNS_NOT_ENABLED`). The value reaches the workflows through the inventory (`network.acnsEnabled`) and `tpg-settings` (`acnsEnabled`).

**Destroy.** `terraform destroy` removes the Key Vault and purges it and the `vault-unseal` key (purge protection off). The deployer's access policy has the `Purge` key permission and `versions.tf` sets the provider's `key_vault` features explicitly, so the purge succeeds on the first run. Without `Purge` the first destroy failed with `403 ... does not have keys purge permission on key vault` and only a second run succeeded (the Key Vault itself could be purged, the key could not).

The configuration is a fresh deployment: it has no state migration from earlier layouts. If you applied an earlier version, run `terraform destroy` with that version first, or start from a new state.

---

## 3. Build the cluster inventory

Every later step reads the inventory: cluster names, resource groups, waves, access method and backup storage.

### 3.1 Terraform clusters

Mirrors `scripts/targets/terraform/inventory-from-terraform.sh`. It writes `.work/inventory.yaml` from the Terraform outputs:

```bash
terraform -chdir=terraform output -json | jq '. as $o | {
  subscriptionId: .subscription_id.value,
  adminAllowedCidrs: .admin_allowed_cidrs.value,
  hub: { name: .hub_cluster_name.value, resourceGroup: .resource_group_name.value,
         access: "az", adminCredentials: true,
         egressCidrs: (if .hub_egress_ip.value then [.hub_egress_ip.value + "/32"] else [] end) },
  targets: [ .target_cluster_names.value[] as $t | {
    name: $t, resourceGroup: $o.resource_group_name.value,
    wave: $o.target_cluster_waves.value[$t], access: "az", adminCredentials: true,
    backupContainer: $o.backup_containers.value[$t] } ],
  backup: { storageAccount: .backup_storage_account_name.value,
            resourceGroup: .resource_group_name.value,
            createContainers: false, keySource: "terraform",
            caBundleFile: ".work/backup-ca-bundle.pem" },
  network: { acnsEnabled: (.acns_enabled.value // false) }
}' | yq -P > .work/inventory.yaml
terraform -chdir=terraform output -raw backup_storage_ca_bundle > .work/backup-ca-bundle.pem
```

The script writes more fields (the logs container, `httpsOnly`, the monitoring block); the lines above are the ones this guide relies on.

On the jumpbox there is no Terraform state. With `run_fleet_setup` or `enable_jumpbox`, Terraform builds the same inventory itself (`local.jumpbox_inventory` in `terraform/jumpbox-provision.tf`, with `keySource: az`) and uploads it to `~/.work/inventory.yaml` with the CA bundle; `env.jumpbox.sh` sets `INVENTORY_PREBUILT=true`, and the script then only checks the file.

### 3.2 Pre-created clusters

Mirrors `scripts/targets/precreated/validate-inventory.sh`. Copy the example and fill it in:

```bash
cp inventory/clusters.example.yaml inventory/clusters.yaml
```

Find the values with az:

```bash
# Clusters, resource groups, zones and API access
az aks list --query '[].{name:name, rg:resourceGroup, k8s:kubernetesVersion,
  private:apiServerAccessProfile.enablePrivateCluster,
  ranges:apiServerAccessProfile.authorizedIpRanges,
  localAccountsDisabled:disableLocalAccounts}' -o table

# Existing storage accounts
az storage account list --query '[].{name:name, rg:resourceGroup, sku:sku.name, sharedKey:allowSharedKeyAccess}' -o table
```

Example `inventory/clusters.yaml`:

```yaml
subscriptionId: 11111111-2222-3333-4444-555555555555
adminAllowedCidrs:
  - 203.0.113.10/32
hub:
  name: blrck-hub
  resourceGroup: rg-aks-tanzu-data
  access: az
  adminCredentials: true
  egressCidrs: []            # discovered in preflight
targets:
  - name: blrck-pg-01
    resourceGroup: rg-aks-tanzu-data
    wave: 0
    access: az
    adminCredentials: true
    backupContainer: pg-backups-blrck-pg-01
  - name: blrck-pg-02
    resourceGroup: rg-aks-tanzu-data
    wave: 1
    access: kubeconfig        # read from an existing kubeconfig instead of az
    kubeconfig: ~/.kube/blrck-pg-02.yaml
    context: blrck-pg-02-admin
    backupContainer: pg-backups-blrck-pg-02
backup:
  storageAccount: tanzudatabkp01
  resourceGroup: rg-aks-tanzu-data
  createContainers: true
  keySource: az               # az | env (BACKUP_STORAGE_KEY) | terraform
  caBundleFile: ""            # empty: the Azure root CAs in terraform/modules/storage/azure-ca-roots.pem
network:
  acnsEnabled: false          # true when the clusters run ACNS (az aks show --query networkProfile.advancedNetworking)
```

The validation checks that the subscription ID is a GUID, that cluster names are unique, that each cluster has the fields its access method needs, that exactly one target is in wave 0 (a warning otherwise), and that the backup account is set.

### 3.3 Preflight for pre-created clusters

Mirrors `scripts/targets/precreated/preflight.sh`. The checks are read-only. Changes happen only with `--fix-authorized-ips`, or with `backup.createContainers: true`.

**Hub egress CIDRs.** Target API servers with authorized IP ranges must allow the hub's outbound IPs.

```bash
az aks show -g rg-aks-tanzu-data -n blrck-hub --query networkProfile.outboundType -o tsv
# loadBalancer

for id in $(az aks show -g rg-aks-tanzu-data -n blrck-hub \
    --query 'networkProfile.loadBalancerProfile.effectiveOutboundIPs[].id' -o tsv); do
  az network public-ip show --ids "$id" --query ipAddress -o tsv
done
# 52.177.10.44
```

For `managedNATGateway`, `userAssignedNATGateway` or `userDefinedRouting`, find the egress IP from the NAT gateway or firewall and set `hub.egressCidrs` in the inventory.

**Cluster state, private API, local accounts, node pools:**

```bash
az aks show -g rg-aks-tanzu-data -n blrck-pg-02 --query '{
  power: powerState.code,
  private: apiServerAccessProfile.enablePrivateCluster,
  ranges: apiServerAccessProfile.authorizedIpRanges,
  localAccountsDisabled: disableLocalAccounts,
  pools: agentPoolProfiles[].{name:name, mode:mode, min:minCount, count:count, zones:availabilityZones}}' -o json
```

| Result | Meaning | Action |
|---|---|---|
| `power` is not `Running` | Cluster stopped | `az aks start` |
| `private: true` | Private API server | The hub and your workstation need network line of sight (peering or VPN). The scripts do not configure that |
| `localAccountsDisabled: true` | Entra ID only | Set `adminCredentials: false` and install kubelogin |
| A User pool with fewer than 3 nodes or zones | HA instances cannot be scheduled | Warning only. `tpg-day0` with `highAvailability=true` reports the cluster `BLOCKED` (`PGDATA_POOL_NOT_HA_CAPABLE`); single-node instances are unaffected. For example, the portal cluster `blrck-pg-02` has a minimum of 2 |
| A System pool with fewer than 3 nodes or zones | Expected | Reported only: the rule covers the Postgres data pool |
| `ranges` is empty or null | Public API server | No change needed |

**Add the hub egress to a target's authorized IP ranges** (what `--fix-authorized-ips` does). `az aks update` replaces the whole list, so pass the existing ranges plus the new one:

```bash
current="$(az aks show -g rg-aks-tanzu-data -n blrck-pg-01 \
  --query 'apiServerAccessProfile.authorizedIpRanges' -o tsv | paste -sd, -)"
az aks update -g rg-aks-tanzu-data -n blrck-pg-01 \
  --api-server-authorized-ip-ranges "${current},52.177.10.44/32"
```

**Backup storage account and containers:**

```bash
SA=tanzudatabkp01; SA_RG=rg-aks-tanzu-data
az storage account show -g $SA_RG -n $SA --query allowSharedKeyAccess -o tsv   # true or empty
KEY="$(az storage account keys list -g $SA_RG -n $SA --query '[0].value' -o tsv)"

az storage container exists --account-name $SA --account-key "$KEY" --name pg-backups-blrck-pg-01 -o tsv
# False
az storage container create --account-name $SA --account-key "$KEY" \
  --name pg-backups-blrck-pg-01 --public-access off
```

The operator authenticates to Azure Blob with `keyType: shared`, so shared key access must be enabled on the account.

**HTTPS only.** The instances write backups with `enableSSL: false` (plain HTTP) by default, which an account with secure transfer required rejects. Preflight compares the account with `backup.httpsOnly` in the inventory:

```bash
az storage account show -g $SA_RG -n $SA --query enableHttpsTrafficOnly -o tsv
# true  -> either allow HTTP ...
az storage account update -g $SA_RG -n $SA --https-only false
#       ... or keep HTTPS only: backup.httpsOnly: true here, and backup.enableSSL: true in
#       tpg-fleet clusters/_template/cluster.yaml (or tpg-day0 -p backupEnableSSL=true)
```

Preflight reads `enableHttpsTrafficOnly` (older API versions: `supportsHttpsTrafficOnly`) as the account reports it and assumes secure transfer only when neither field is present. Before Round 13 it read `false` as `true` and refused an account that accepts HTTP (design decision I22).

**Archived workflow logs.** Container `backup.logsContainer` (default `argo-logs`) holds the Argo Workflows step logs. Preflight creates it with the backup containers (`backup.createContainers: true`). Terraform adds a lifecycle rule that deletes the logs after 90 days; on a pre-created account add it once:

```bash
POLICY='{"rules":[{"enabled":true,"name":"argo-logs-retention","type":"Lifecycle",
  "definition":{"filters":{"blobTypes":["blockBlob"],"prefixMatch":["argo-logs/"]},
                "actions":{"baseBlob":{"delete":{"daysAfterModificationGreaterThan":90}}}}}]}'
az storage account management-policy create -g $SA_RG --account-name $SA --policy "$POLICY"
```

`management-policy create` replaces every rule of the account: if it already has rules, add this one to the output of `az storage account management-policy show` instead.

---

## 4. Fetch kubeconfigs

Mirrors `scripts/steps/10-kubeconfigs.sh`. It builds `.work/kubeconfig` with one context per cluster, and each context is named after the cluster.

### 4.1 `access: az` with local accounts (adminCredentials: true)

With `--admin`, `az aks get-credentials` appends `-admin` to the context name even when `--context` is set, so `--context aks-tpg-hub` produces the context `aks-tpg-hub-admin`. Every later command uses the cluster name as the context, so rename it:

```bash
for c in $HUB $TARGETS; do
  # stale contexts from an earlier run, under both names
  kubectl config delete-context "$c" >/dev/null 2>&1 || true
  kubectl config delete-context "${c}-admin" >/dev/null 2>&1 || true
  az aks get-credentials --resource-group rg-tpgpoc --name "$c" --admin \
    --context "$c" --file "$KUBECONFIG" --overwrite-existing
  kubectl config get-contexts "${c}-admin" >/dev/null   # fails if the rename assumption ever changes
  kubectl config rename-context "${c}-admin" "$c"
  kubectl --context "$c" get --raw=/readyz; echo " $c"
done
```

```text
ok aks-tpg-hub
ok aks-tpg-poc-01
ok aks-tpg-poc-02
ok aks-tpg-poc-03
```

### 4.2 `access: az` with Entra ID only (adminCredentials: false)

```bash
az aks get-credentials -g rg-aks-tanzu-data -n blrck-pg-03 \
  --context blrck-pg-03 --file "$KUBECONFIG" --overwrite-existing
kubelogin convert-kubeconfig -l azurecli --kubeconfig "$KUBECONFIG" --context blrck-pg-03
kubectl --context blrck-pg-03 get --raw=/readyz
```

Your Entra identity needs the Azure Kubernetes Service RBAC Cluster Admin role (or equivalent) on the cluster, because step 6 creates a ClusterRoleBinding.

### 4.3 `access: kubeconfig`

Copy one context from an existing file and rename its cluster, user and context to the inventory name:

```bash
c=blrck-pg-02
kubectl config view --raw --flatten --minify \
  --kubeconfig ~/.kube/blrck-pg-02.yaml --context blrck-pg-02-admin > "$WORK/$c.import"

yq -i ".clusters[0].name = \"$c\" | .users[0].name = \"$c-user\" |
       .contexts[0].name = \"$c\" | .contexts[0].context.cluster = \"$c\" |
       .contexts[0].context.user = \"$c-user\" | .[\"current-context\"] = \"$c\"" "$WORK/$c.import"

KUBECONFIG="$KUBECONFIG:$WORK/$c.import" kubectl config view --raw --flatten > "$WORK/kubeconfig.merged"
mv "$WORK/kubeconfig.merged" "$KUBECONFIG" && chmod 600 "$KUBECONFIG" && rm "$WORK/$c.import"
kubectl config get-contexts
```

---

## 5. Prepare the hub

### 5.1 Hub without Argo: install

Mirrors `scripts/hub/install/install-argo.sh`. The full manual procedure, with the values files, UI login, verification and troubleshooting, is in [README-argo-on-aks.md](README-argo-on-aks.md). In short:

```bash
helm repo add argo https://argoproj.github.io/argo-helm --force-update

helm upgrade --install argocd argo/argo-cd --kube-context $HUB \
  -n argocd --create-namespace --version 10.9.1 \
  -f argo/argocd-values.yaml \
  --set-json "server.service.loadBalancerSourceRanges=$ALLOWED_CIDRS" --wait --timeout 15m

helm upgrade --install argo-workflows argo/argo-workflows --kube-context $HUB \
  -n argo --create-namespace --version 2.0.6 \
  -f argo/argo-workflows-values.yaml \
  --set-json "server.loadBalancerSourceRanges=$ALLOWED_CIDRS" --wait --timeout 15m
```

The script runs the same Helm release pre-check as the add-ons (section 10) for both releases: `UP_TO_DATE` does nothing; a release that differs in chart version or values shows the diff and asks to upgrade, skip or abort (`--yes` or `ADDONS_EXISTING=upgrade` upgrades; without a terminal it skips); a newer chart is never downgraded; Argo installed another way is `BLOCKED` and points you to 5.2. While `helm --wait` runs, the pods of the namespace are printed every 5 seconds and the install stops when one cannot start.

Answer `u` (or pass `--yes`) on a hub installed by an earlier version, so the current `argo/argocd-values.yaml` is applied: the Argo CD health check for `Postgres` (Healthy only when `status.currentState` is `Running`) and `timeout.reconciliation: 60s` (was 180s), which makes Argo CD see new CRDs and Git changes sooner. Check them:

```bash
kubectl --context $HUB -n argocd get cm argocd-cm -o jsonpath='{.data.timeout\.reconciliation}'; echo   # 60s
kubectl --context $HUB -n argocd get cm argocd-cm -o json | jq -r '.data | keys[] | select(startswith("resource.customizations.health"))'
```

Then create the UI login ServiceAccount (`scripts/hub/ui-admin.sh`) as in section 5.2.4.

### 5.2 Hub with Argo already installed: check and add

Mirrors `scripts/hub/existing/check-argo.sh`. The fleet manifests expect Argo CD in namespace `argocd` and Argo Workflows in namespace `argo`.

#### 5.2.1 Read-only checks

```bash
# Components ready
kubectl --context $HUB -n argocd get deploy argocd-server argocd-repo-server argocd-applicationset-controller
kubectl --context $HUB -n argocd get statefulset argocd-application-controller
kubectl --context $HUB -n argo get deploy -l 'app.kubernetes.io/component in (workflow-controller,server)'

# Versions (image tags)
kubectl --context $HUB -n argocd get deploy argocd-server -o jsonpath='{.spec.template.spec.containers[0].image}'; echo
kubectl --context $HUB -n argo get deploy -l app.kubernetes.io/component=workflow-controller \
  -o jsonpath='{.items[0].spec.template.spec.containers[0].image}'; echo

# Argo CD settings the fleet relies on
kubectl --context $HUB -n argocd get cm argocd-cm \
  -o jsonpath='{.data.application\.resourceTrackingMethod}{"\n"}{.data.accounts\.workflow-bot}{"\n"}'
kubectl --context $HUB -n argocd get cm argocd-rbac-cm -o jsonpath='{.data.policy\.csv}'

# Argo Workflows: namespace scope, metrics, auth modes
kubectl --context $HUB -n argo get deploy -l app.kubernetes.io/component=workflow-controller \
  -o jsonpath='{.items[0].spec.template.spec.containers[0].args}'; echo
kubectl --context $HUB -n argo get cm -l app.kubernetes.io/component=workflow-controller \
  -o jsonpath='{.items[0].data.config}' | yq '.metricsConfig'
kubectl --context $HUB -n argo get deploy -l app.kubernetes.io/component=server \
  -o jsonpath='{.items[0].spec.template.spec.containers[0].args}'; echo
```

| Check | Expected | If not |
|---|---|---|
| Argo CD image tag | `v3.x` (tested with v3.5.3) | Upgrade Argo CD |
| Argo Workflows image tag | `v4.x` (tested with v4.1.3) | Upgrade. The CronWorkflows use `spec.schedules` |
| `resourceTrackingMethod` | empty (defaults to annotation) or `annotation` | Day 0 pre-check reports BLOCKED instead of MANAGED. Use `--set-tracking-annotation` (5.2.3) |
| `accounts.workflow-bot` | contains `apiKey` | Added in 5.2.2 |
| `policy.csv` | contains `g, workflow-bot, role:tpg-sync` | Added in 5.2.2 |
| Controller `--managed-namespace` | absent or `argo` | Reinstall the controller to watch `argo` |
| `metricsConfig.enabled` | not `false` | Enable it: the dashboard and alerts use workflow metrics |
| Server args | include `client` in `--auth-mode` | Add `--auth-mode=client` |

Run only the checks with:

```bash
scripts/run.sh --hub existing --targets precreated --check-only   # stops after the hub checks
```

#### 5.2.2 Additive changes

These changes add keys and never remove or rewrite existing ones.

```bash
# Local account for Argo Workflows (only if accounts.workflow-bot is not set)
kubectl --context $HUB -n argocd patch cm argocd-cm --type merge \
  -p '{"data":{"accounts.workflow-bot":"apiKey"}}'

# Append the sync role (only if it is not already in policy.csv)
policy="$(kubectl --context $HUB -n argocd get cm argocd-rbac-cm -o jsonpath='{.data.policy\.csv}')"
newpolicy="$(printf '%s\n# tpg-fleet: Argo Workflows sync account\n%s\n' "$policy" \
'p, role:tpg-sync, applications, get, tpg/*, allow
p, role:tpg-sync, applications, sync, tpg/*, allow
p, role:tpg-sync, projects, get, tpg, allow
p, role:tpg-sync, repositories, get, *, allow
g, workflow-bot, role:tpg-sync')"
kubectl --context $HUB -n argocd patch cm argocd-rbac-cm --type merge \
  -p "$(jq -cn --arg p "$newpolicy" '{data:{"policy.csv":$p}}')"
```

If `accounts.workflow-bot` already exists without `apiKey`, the script stops. Change it by hand, for example to `apiKey, login`.

Then deny people what only the workflows may do on the tpg target Applications: `sync` (which also covers rollback and terminating an operation), `override`, `update` and `delete` on `tpg/*`. Argo CD evaluates a deny before any allow, and a deny on a role also removes what `policy.default` grants through that role, so every subject that can act on project `tpg` needs its own deny lines. The script asks the Argo CD permission checker about `role:admin`, the `admin` user, `policy.default` and every subject and group named in `policy.csv`, and without `--yes` stops with `ARGO_RBAC_MISSING` and prints the block; with `--yes` it writes it. By hand (needs the `argocd` CLI; `admin settings rbac can` reads a local copy of the ConfigMap and needs no login):

```bash
kubectl --context $HUB -n argocd get cm argocd-rbac-cm -o yaml > /tmp/rbac-cm.yaml
for s in role:admin admin $(kubectl --context $HUB -n argocd get cm argocd-rbac-cm -o jsonpath='{.data.policy\.default}'); do
  for a in sync override update delete; do
    argocd admin settings rbac can "$s" "$a" applications tpg/tpg-rbac-probe-operator --policy-file /tmp/rbac-cm.yaml -q \
      && echo "$s may still $a tpg Applications"
  done
done
```

Add one set of deny lines per subject reported (subjects named in `policy.csv` with `p,` or `g,` lines are checked the same way), inside the markers, so a later run replaces the block instead of adding a second one:

```bash
policy="$(kubectl --context $HUB -n argocd get cm argocd-rbac-cm -o jsonpath='{.data.policy\.csv}')"
block='# >>> tpg-fleet rbac >>>
# People may not sync, override, update or delete the tpg target Applications:
# the tpg workflows sync them as workflow-bot (role:tpg-sync). Written by tpg-aks-infra.
p, role:admin, applications, sync, tpg/*, deny
p, role:admin, applications, override, tpg/*, deny
p, role:admin, applications, update, tpg/*, deny
p, role:admin, applications, delete, tpg/*, deny
# <<< tpg-fleet rbac <<<'
kubectl --context $HUB -n argocd patch cm argocd-rbac-cm --type merge \
  -p "$(jq -cn --arg p "$(printf '%s\n%s\n' "$policy" "$block")" '{data:{"policy.csv":$p}}')"

# workflow-bot must still be allowed, everyone else refused
kubectl --context $HUB -n argocd get cm argocd-rbac-cm -o yaml > /tmp/rbac-cm.yaml
argocd admin settings rbac can workflow-bot sync applications tpg/tpg-rbac-probe-operator --policy-file /tmp/rbac-cm.yaml   # Yes
argocd admin settings rbac can role:admin sync applications tpg/tpg-rbac-probe-operator --policy-file /tmp/rbac-cm.yaml     # No
```

With `policy.matchMode: regex`, write `tpg/.*` instead of `tpg/*`. There is no break-glass role. The hub Applications (`tpg-hub-workflows`, `tpg-hub-monitoring`) are in project `tpg-hub` and are not affected.

#### 5.2.3 Opt-in changes

```bash
# --set-tracking-annotation: affects every Application on this Argo CD
kubectl --context $HUB -n argocd patch cm argocd-cm --type merge \
  -p '{"data":{"application.resourceTrackingMethod":"annotation"}}'

# --expose-ui: LoadBalancer Services restricted to your CIDRs
patch="$(jq -cn --argjson r "$ALLOWED_CIDRS" '{spec:{type:"LoadBalancer", loadBalancerSourceRanges:$r}}')"
kubectl --context $HUB -n argocd patch svc argocd-server --type merge -p "$patch"
kubectl --context $HUB -n argo patch svc \
  "$(kubectl --context $HUB -n argo get svc -l app.kubernetes.io/component=server -o jsonpath='{.items[0].metadata.name}')" \
  --type merge -p "$patch"
```

Changing the tracking method on an Argo CD that already manages other applications can make their resources show as OutOfSync until the next sync. Agree the change with the hub owner first.

#### 5.2.4 UI login ServiceAccount

```bash
kubectl --context $HUB apply -f - <<'YAML'
apiVersion: v1
kind: ServiceAccount
metadata: { name: argo-ui-admin, namespace: argo }
---
apiVersion: v1
kind: Secret
metadata:
  name: argo-ui-admin.service-account-token
  namespace: argo
  annotations: { kubernetes.io/service-account.name: argo-ui-admin }
type: kubernetes.io/service-account-token
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: { name: argo-ui-admin, namespace: argo }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: admin }
subjects: [ { kind: ServiceAccount, name: argo-ui-admin, namespace: argo } ]
YAML
```

#### 5.2.5 Persist the changes in Helm values

Helm owns `argocd-cm`, `argocd-rbac-cm` and the Services, so the next `helm upgrade` reverts manual patches. The script writes the equivalent values to `.work/hub-existing-argocd-values.yaml` and `.work/hub-existing-argo-workflows-values.yaml`. Merge them into your values files:

```yaml
# Argo CD
configs:
  cm:
    application.resourceTrackingMethod: annotation
    accounts.workflow-bot: apiKey
  rbac:
    policy.csv: |
      p, role:tpg-sync, applications, get, tpg/*, allow
      p, role:tpg-sync, applications, sync, tpg/*, allow
      p, role:tpg-sync, projects, get, tpg, allow
      p, role:tpg-sync, repositories, get, *, allow
      g, workflow-bot, role:tpg-sync
      # >>> tpg-fleet rbac >>>
      # People may not sync, override, update or delete the tpg target Applications:
      # the tpg workflows sync them as workflow-bot (role:tpg-sync). Written by tpg-aks-infra.
      p, role:admin, applications, sync, tpg/*, deny
      p, role:admin, applications, override, tpg/*, deny
      p, role:admin, applications, update, tpg/*, deny
      p, role:admin, applications, delete, tpg/*, deny
      # <<< tpg-fleet rbac <<<
server:
  service:
    type: LoadBalancer
    loadBalancerSourceRanges: ["203.0.113.10/32"]
```

```yaml
# Argo Workflows
controller:
  metricsConfig:
    enabled: true
server:
  serviceType: LoadBalancer
  loadBalancerSourceRanges: ["203.0.113.10/32"]
  authModes: [client]
```

---

## 6. Install HashiCorp Vault on the hub

Mirrors `scripts/steps/35-vault.sh`. Vault (community edition) holds the three fleet credentials; every cluster and every workflow reads them from it. Run this step from an interactive terminal: the unseal keys are shown once and are never written to a file. The exception is `scripts/run.sh ... --save-vault-recovery-keys` (the jumpbox run of Terraform `run_fleet_setup` passes it): the step then needs no terminal and writes the keys to `VAULT_RECOVERY_KEYS_FILE` instead (6.4).

Every command below runs the Vault CLI **inside** the `vault-0` pod, so the workstation needs no `vault` binary and no network path to Vault. Tokens reach the pod on standard input, never as command-line arguments.

### 6.1 Namespace, storage and Services

```bash
kubectl --context $HUB create namespace vault
# The StorageClass tpg-data-retain, with the disk SKU of this deployment
# (Terraform postgres_data_disk_sku, or storage.dataDiskSku in the inventory)
SKU="Premium_ZRS" yq '(select(.kind == "StorageClass") | .parameters.skuName) = strenv(SKU)' \
  "$FLEET_LOCAL_DIR/platform/base/storageclass.yaml" | kubectl --context $HUB apply -f -

# Service the targets use. Internal load balancer (same VNet) or public with
# loadBalancerSourceRanges; the script reads vault.exposure from the inventory.
kubectl --context $HUB apply -f - <<'YAML'
apiVersion: v1
kind: Service
metadata:
  name: vault-fleet
  namespace: vault
  annotations:
    service.beta.kubernetes.io/azure-load-balancer-internal: "true"
spec:
  type: LoadBalancer
  selector: { app.kubernetes.io/name: vault, component: server }
  ports: [ { name: https, port: 8200, targetPort: 8200 } ]
YAML
kubectl --context $HUB -n vault get svc vault-fleet -w    # wait for the external IP
```

### 6.2 TLS

The server certificate must carry every name and address the clients use: the in-cluster DNS names and the load balancer IPs.

```bash
IP="$(kubectl --context $HUB -n vault get svc vault-fleet -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
cd "$WORK"
openssl req -x509 -newkey rsa:4096 -nodes -days 3650 -subj '/CN=tpg-vault-ca' \
  -keyout vault-ca.key -out vault-ca.crt
openssl req -new -newkey rsa:4096 -nodes -subj '/CN=vault.vault.svc' -keyout vault.key -out vault.csr
printf 'subjectAltName=DNS:vault,DNS:vault.vault,DNS:vault.vault.svc,DNS:vault.vault.svc.cluster.local,DNS:vault-0.vault-internal,IP:%s,IP:127.0.0.1\nextendedKeyUsage=serverAuth\n' "$IP" > vault-san.cnf
openssl x509 -req -in vault.csr -CA vault-ca.crt -CAkey vault-ca.key -CAcreateserial \
  -days 3650 -extfile vault-san.cnf -out vault.crt

kubectl --context $HUB -n vault create secret generic vault-tls \
  --from-file=tls.crt=vault.crt --from-file=tls.key=vault.key --from-file=ca.crt=vault-ca.crt \
  --dry-run=client -o yaml | kubectl --context $HUB apply -f -
# The CA certificate, for the workflow pods and the Vault Secrets Operator (public, not a secret)
kubectl --context $HUB -n argo create secret generic vault-ca --from-file=ca.crt=vault-ca.crt \
  --dry-run=client -o yaml | kubectl --context $HUB apply -f -
kubectl --context $HUB -n argocd create secret generic vault-ca --from-file=ca.crt=vault-ca.crt \
  --dry-run=client -o yaml | kubectl --context $HUB apply -f -
shred -u vault-ca.key vault.key vault.csr; cd -
```

### 6.3 Helm release

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com && helm repo update hashicorp
# config-shamir.hcl, or config-azure-keyvault.hcl with @TENANT_ID@, @KEY_VAULT_NAME@
# and @KEY_NAME@ replaced, for auto-unseal
helm --kube-context $HUB upgrade --install vault hashicorp/vault --version 0.34.1 \
  -n vault --create-namespace \
  -f "$FLEET_LOCAL_DIR/vault/vault-values.yaml" \
  --set-file server.standalone.config="$FLEET_LOCAL_DIR/vault/config-shamir.hcl"
# No --wait: vault-0 is Ready only after init and unseal (6.4), so helm --wait would time out.
# Watch until vault-0 is Running with 0/1 Ready, then go on
kubectl --context $HUB -n vault get pods -w
```

The script does not wait for the pod to be Ready here: Vault is Ready only once it is initialized and unsealed (6.4). It prints the pod table of `vault` every 5 seconds, like the other releases, and goes on when `vault-0` has started (status `Started`); after the unseal it watches again until `vault-0` is Ready. A pod that cannot start (image pull, volume, configuration) stops the step with its events and logs.

`scripts/steps/45-helm-addons.sh` and this step both call `tpg-fleet/workflows/scripts/helm-addons.sh`, which first classifies what is already installed (`ADDON <release> <status> <detail>`: `UP_TO_DATE`, `SKIPPED_EXISTS`, `SKIPPED_NEWER`, `REUSED_EXISTING` or `BLOCKED`) and only then installs or upgrades. A Vault or kube-prometheus-stack installed by someone else is never reused, because the fleet needs its own configuration.

### 6.4 Initialize and unseal

The script keeps the keys and the initial root token in memory and configures Vault (6.5) **before** it shows them, so an interrupted run cannot leave an initialized but unconfigured Vault. From `vault operator init` until you confirm that the keys are stored, Ctrl+C, TERM and HUP do not end the step: the keys are shown again and the prompt asks again. If the step fails after init, the keys are printed before it exits.

With `--save-vault-recovery-keys` the script writes the 5 key shares, never the root token, to `VAULT_RECOVERY_KEYS_FILE` (default `~/.tpg/vault-keys.txt`): directory mode 700, file mode 600, and `<file>.<UTC time>` when the file already exists. It prints only the path. It checks that the directory is writable before `vault operator init`. The by-hand equivalent, for the record (keep the file off shared disks and delete it once the keys are in a password manager):

```bash
( umask 077; mkdir -p ~/.tpg )
v operator init -key-shares=5 -key-threshold=3 -format=json </dev/null \
  | jq -r '.unseal_keys_b64 | to_entries[] | "Key \(.key + 1): \(.value)"' > ~/.tpg/vault-keys.txt
# The root token is not in the file: without it, generate one with vault operator generate-root and 3 keys (Resume, below)
```

Shown on the terminal instead (without the flag):

```bash
v() { kubectl --context $HUB -n vault exec -i vault-0 -c vault -- vault "$@"; }

# Shamir: 5 key shares, any 3 unseal. azure-keyvault: -recovery-shares/-recovery-threshold
v operator init -key-shares=5 -key-threshold=3 -format=json </dev/null
# By hand, copy the 5 keys and the root token into a password manager now. They are shown once.

# Shamir only: unseal with three different keys (-it, because it prompts)
kubectl --context $HUB -n vault exec -it vault-0 -c vault -- vault operator unseal   # three times
v status
```

```text
Seal Type       shamir
Initialized     true
Sealed          false
```

The unseal mode is a required choice: `vault_unseal_mode` in Terraform has no default, and for pre-created clusters `vault.unsealMode` in the inventory is validated. With `vault_unseal_mode = "azure-keyvault"` Vault unseals itself after every restart, using the Key Vault key through the workload identity `id-vault`; the recovery keys from `init` are what allow a rekey or a new root token later.

The Key Vault is created on its public endpoint and grants access with **access policies** rather than Azure RBAC: Terraform's own identity may create and read the key, and `id-vault` may get, wrap and unwrap it. An access policy is written on the Key Vault itself, so the deployment does not need `Microsoft.Authorization/roleAssignments/write`, which is what makes a Contributor-only account fail with `AuthorizationFailed` on a role assignment. It is created with purge protection off, so `terraform destroy` removes it and the POC can be rebuilt with the same prefix. Deleting the Key Vault or the `vault-unseal` key therefore destroys the Vault data for good: the recovery keys do not decrypt the storage. Set `key_vault_purge_protection = true` for a deployment that outlives the POC.

**Resume after an interrupted init.** A Vault that is initialized and unsealed but refuses the `tpg-setup` login (`403 permission denied` on `auth/kubernetes/login`, or `role "tpg-setup" not found`) was initialized by a run that ended before 6.5. Run `scripts/run.sh ... --only vault` again: it asks for the initial root token (hidden input); with an empty answer it generates a new root token from 3 unseal or recovery keys, finishes 6.5 and revokes the token. By hand:

```bash
OTP="$(v operator generate-root -generate-otp)"
NONCE="$(v operator generate-root -init -otp="$OTP" -format=json | jq -r .nonce)"
# three times, each with a different key, typed at the hidden prompt:
read -rs -p 'unseal/recovery key: ' K; echo
ENC="$(printf '%s\n' "$K" | v operator generate-root -nonce="$NONCE" -format=json - | jq -r '.encoded_root_token // empty')"; unset K
# after the third key ENC is set:
export ROOT_TOKEN="$(v operator generate-root -decode="$ENC" -otp="$OTP")"
# then 6.5 with this ROOT_TOKEN, and revoke it at the end
```

After a `vault-0` restart in `shamir` mode, unseal it again:

```bash
scripts/run.sh --hub <mode> --targets <mode> --only vault-unseal
```

### 6.5 KV mount, policies, roles and the UI account

```bash
# Log in with the root token, on stdin
vt() { kubectl --context $HUB -n vault exec -i vault-0 -c vault -- \
  sh -lc 'read -r VAULT_TOKEN; export VAULT_TOKEN; exec vault "$@"' -- "$@"; }
export ROOT_TOKEN='<the root token from init>'

printf '%s\n' "$ROOT_TOKEN" | vt secrets enable -path=tpg -version=2 kv
printf '%s\n' "$ROOT_TOKEN" | vt auth enable kubernetes
printf '%s\n{"kubernetes_host":"https://kubernetes.default.svc:443"}\n' "$ROOT_TOKEN" \
  | vt write auth/kubernetes/config -

# ServiceAccounts the roles are bound to
kubectl --context $HUB -n vault create serviceaccount tpg-setup
kubectl --context $HUB -n argocd create serviceaccount tpg-vso
kubectl --context $HUB create namespace argo --dry-run=client -o yaml | kubectl --context $HUB apply -f -
kubectl --context $HUB -n argo create serviceaccount tpg-vso

# Policies from tpg-fleet/vault/policies/*.hcl
for f in "$FLEET_LOCAL_DIR"/vault/policies/*.hcl; do
  { printf '%s\n' "$ROOT_TOKEN"; cat "$f"; } | vt policy write "$(basename "$f" .hcl)" -
done

# Roles: ServiceAccount -> policy
printf '%s\n{"bound_service_account_names":["tpg-setup"],"bound_service_account_namespaces":["vault"],"token_policies":["tpg-admin"],"token_ttl":"30m","token_max_ttl":"4h"}\n' "$ROOT_TOKEN" \
  | vt write auth/kubernetes/role/tpg-setup -
printf '%s\n{"bound_service_account_names":["tpg-workflow"],"bound_service_account_namespaces":["argo"],"token_policies":["tpg-workflow"],"token_ttl":"1h","token_max_ttl":"4h"}\n' "$ROOT_TOKEN" \
  | vt write auth/kubernetes/role/tpg-workflow -
# The write step of tpg-rotate-credential only (its ServiceAccount comes with tpg-hub-workflows, section 11)
printf '%s\n{"bound_service_account_names":["tpg-credential-writer"],"bound_service_account_namespaces":["argo"],"token_policies":["tpg-credential-writer"],"token_ttl":"15m","token_max_ttl":"4h"}\n' "$ROOT_TOKEN" \
  | vt write auth/kubernetes/role/tpg-credential-writer -
printf '%s\n{"bound_service_account_names":["tpg-vso"],"bound_service_account_namespaces":["argocd","argo"],"token_policies":["tpg-argocd"],"token_ttl":"1h","token_max_ttl":"4h","audience":"vault"}\n' "$ROOT_TOKEN" \
  | vt write auth/kubernetes/role/tpg-argocd -

# UI account: userpass tpg-admin, password kept in Vault itself
PW="$(head -c 18 /dev/urandom | base64 | tr -d '/+=')"
printf '%s\n' "$ROOT_TOKEN" | vt auth enable userpass
printf '%s\n' "$ROOT_TOKEN" | vt write auth/userpass/users/tpg-admin password="$PW" policies=tpg-admin
printf '%s\n{"username":"tpg-admin","password":"%s"}\n' "$ROOT_TOKEN" "$PW" | vt kv put tpg/admin/vault-ui -

# Prove that the Kubernetes auth role works, then revoke the root token
JWT="$(kubectl --context $HUB -n vault create token tpg-setup --audience vault)"
printf '%s\n{"role":"tpg-setup","jwt":"%s"}\n' "$ROOT_TOKEN" "$JWT" | vt write auth/kubernetes/login -
printf '%s\n' "$ROOT_TOKEN" | vt token revoke -self
unset ROOT_TOKEN
```

The step ends by installing the Vault Secrets Operator on the hub (`helm-addons.sh --components vso`) and applying `VaultConnection` and `VaultAuth` `tpg-vault/tpg-vault` from `tpg-fleet/vault/tpg-vault-objects.yaml`, with `@VAULT_ADDR@`, `@AUTH_MOUNT@`, `@AUTH_ROLE@` and `@ALLOWED_NS@` (`argocd,argo` on the hub) replaced.

The script shows the keys only after the `tpg-setup` login above works; by hand, keep the order: configure, prove the login, store the keys, revoke the root token.

---

## 7. Create the ServiceAccounts on each target

Mirrors `scripts/steps/20-target-service-accounts.sh`. Each target gets two ServiceAccounts: `argocd-manager`, which Argo CD and the workflows use, and `tpg-vault-reviewer`, whose token lets Vault on the hub verify the ServiceAccount tokens of that cluster (`system:auth-delegator`).

```bash
for c in $TARGETS; do
kubectl --context "$c" apply -f - <<'YAML'
apiVersion: v1
kind: ServiceAccount
metadata: { name: argocd-manager, namespace: kube-system }
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: { name: argocd-manager }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: cluster-admin }
subjects: [ { kind: ServiceAccount, name: argocd-manager, namespace: kube-system } ]
---
apiVersion: v1
kind: Secret
metadata:
  name: argocd-manager-token
  namespace: kube-system
  annotations: { kubernetes.io/service-account.name: argocd-manager }
type: kubernetes.io/service-account-token
---
apiVersion: v1
kind: ServiceAccount
metadata: { name: tpg-vault-reviewer, namespace: kube-system }
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: { name: tpg-vault-reviewer }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: system:auth-delegator }
subjects: [ { kind: ServiceAccount, name: tpg-vault-reviewer, namespace: kube-system } ]
---
apiVersion: v1
kind: Secret
metadata:
  name: tpg-vault-reviewer-token
  namespace: kube-system
  annotations: { kubernetes.io/service-account.name: tpg-vault-reviewer }
type: kubernetes.io/service-account-token
YAML
done

# The token controller fills both Secrets within a few seconds
kubectl --context aks-tpg-poc-01 -n kube-system get secret argocd-manager-token \
  -o jsonpath='{.data.token}' | cut -c1-20; echo
```

---

## 8. Register the targets on the hub

Mirrors `scripts/steps/30-register-clusters.sh`. For each target, this step creates:

- an Argo CD cluster Secret `argocd/cluster-<target>`, labelled `tpg.fleet/managed=true` and `tpg.fleet/wave=<wave>`
- a kubeconfig Secret `argo/kubeconfig-<target>` for the workflow steps

```bash
c=aks-tpg-poc-01; wave=0

token="$(kubectl --context $c -n kube-system get secret argocd-manager-token -o jsonpath='{.data.token}' | base64 -d)"
ca="$(kubectl --context $c -n kube-system get secret argocd-manager-token -o jsonpath='{.data.ca\.crt}')"
server="$(kubectl config view --raw -o json | jq -r --arg c $c \
  '(.contexts[] | select(.name==$c) | .context.cluster) as $cl | .clusters[] | select(.name==$cl) | .cluster.server')"
echo "$server"
# https://aks-tpg-poc-01-k3x9d2.hcp.eastus2.azmk8s.io:443

# Argo CD cluster Secret
# the token goes to jq in the environment and to kubectl on stdin, never as an argument
T="$token" CA="$ca" jq -cn '{bearerToken: env.T, tlsClientConfig: {insecure: false, caData: env.CA}}' \
  | kubectl --context $HUB -n argocd create secret generic cluster-$c \
      --from-literal=name=$c --from-literal=server="$server" --from-file=config=/dev/stdin \
      --dry-run=client -o yaml | kubectl --context $HUB apply -f -
kubectl --context $HUB -n argocd label secret cluster-$c --overwrite \
  argocd.argoproj.io/secret-type=cluster tpg.fleet/managed=true tpg.fleet/wave=$wave

# Kubeconfig Secret for Argo Workflows
kc="$WORK/$c.kubeconfig"
printf '%s' "$ca" | base64 -d > "$WORK/$c.ca.crt"
kubectl config set-cluster $c --server="$server" --certificate-authority="$WORK/$c.ca.crt" --embed-certs=true --kubeconfig="$kc"
kubectl config set-credentials argocd-manager --token="$token" --kubeconfig="$kc"
kubectl config set-context default --cluster=$c --user=argocd-manager --kubeconfig="$kc"
kubectl config use-context default --kubeconfig="$kc"
kubectl --context $HUB -n argo create secret generic kubeconfig-$c --from-file=config="$kc" \
  --dry-run=client -o yaml | kubectl --context $HUB apply -f -
kubectl --context $HUB -n argo label secret kubeconfig-$c --overwrite tpg.fleet/cluster=$c tpg.fleet/wave=$wave
rm -f "$kc" "$WORK/$c.ca.crt"
```

Then register the cluster with Vault on the hub, so the Vault Secrets Operator running there can log in (one auth mount per cluster, `auth/k8s-<cluster>`):

```bash
reviewer="$(kubectl --context $c -n kube-system get secret tpg-vault-reviewer-token -o jsonpath='{.data.token}' | base64 -d)"
ca_pem="$(kubectl --context $c -n kube-system get secret tpg-vault-reviewer-token -o jsonpath='{.data.ca\.crt}' | base64 -d)"

printf '%s\n' "$VAULT_TOKEN" | vt auth enable -path="k8s-$c" kubernetes
{ printf '%s\n' "$VAULT_TOKEN"
  H="$server" CA="$ca_pem" T="$reviewer" jq -cn \
    '{kubernetes_host: env.H, kubernetes_ca_cert: env.CA, token_reviewer_jwt: env.T, disable_local_ca_jwt: true}'
} | vt write "auth/k8s-$c/config" -
{ printf '%s\n' "$VAULT_TOKEN"
  jq -cn '{bound_service_account_names:["tpg-vso"], bound_service_account_namespaces:["*"],
           token_policies:["tpg-target"], token_ttl:"1h", token_max_ttl:"4h", audience:"vault"}'
} | vt write "auth/k8s-$c/role/tpg-vso" -
```

`VAULT_TOKEN` is a token with the `tpg-admin` policy: `scripts/lib/vault.sh` gets one with the `tpg-setup` role, and by hand you can log in as `tpg-admin` through userpass. The role allows the ServiceAccount `tpg-vso` in any namespace, because every instance namespace has one.

The wave comes from the inventory only: the ApplicationSets read it from the Argo CD cluster Secret label and the workflows from the `kubeconfig-<target>` Secret label. Wave `0` is the canary. No per-cluster file is needed in `tpg-fleet`: `tpg-day0` adds the cluster to `clusters/fleet.yaml`. Confirm in Argo CD:

```bash
argocd cluster list --grpc-web
```

```text
SERVER                                                   NAME            STATUS
https://aks-tpg-poc-01-k3x9d2.hcp.eastus2.azmk8s.io:443  aks-tpg-poc-01  Unknown
https://kubernetes.default.svc                           in-cluster
```

`Unknown` is expected until the first Application syncs to that cluster.

---

## 9. Store the credentials in Vault and create the hub settings

Mirrors `scripts/steps/40-hub-secrets.sh`. Nothing is written to a file, and no credential is kept in a Kubernetes Secret that you create by hand: the three values go into Vault, and the Vault Secrets Operator builds the Argo CD repository Secrets from them.

### 9.1 Check the credentials first

The step refuses to store a credential that does not work, and prints the exact error.

```bash
read -rs -p 'Broadcom token: ' BROADCOM_TOKEN; echo
read -rs -p 'GitHub read-only PAT: ' GIT_READ_PAT; echo
read -rs -p 'GitHub read/write PAT: ' GIT_PUSH_PAT; echo

REGISTRY=tanzu-sql-postgres.packages.broadcom.com

# Broadcom registry: a throwaway registry config, so ~/.config/helm is not touched
cfg="$(mktemp -d)"
printf '%s' "$BROADCOM_TOKEN" | helm registry login "$REGISTRY" \
  --username "$BROADCOM_USER" --password-stdin --registry-config "$cfg/registry.json"
rm -rf "$cfg"

# GitHub PATs: type, owner, expiry, repository access and the contents permission
gh() { curl -sS -H "Accept: application/vnd.github+json" -H "Authorization: Bearer $1" \
  -H "X-GitHub-Api-Version: 2022-11-28" -D /tmp/h "https://api.github.com$2"; }
gh "$GIT_READ_PAT" /user | jq -r '.login'
grep -i 'github-authentication-token-expiration' /tmp/h
gh "$GIT_READ_PAT" "/repos/$GITHUB_USER/tpg-fleet" | jq -r '.permissions'
git -c credential.helper= ls-remote "https://$GITHUB_USER:$GIT_PUSH_PAT@github.com/$GITHUB_USER/tpg-fleet.git" >/dev/null
git -C "$FLEET_LOCAL_DIR" push --dry-run origin HEAD    # proves write access
```

A fine-grained PAT must start with `github_pat_`, be active (not expired), have the repository in its scope and `contents: read` (`GIT_READ_PAT`) or `contents: write` (`GIT_PUSH_PAT`); pull request mode also needs `pull_requests: write`. With `VALIDATE_PR_WRITE=true` the script proves that permission by opening and closing a throwaway pull request.

### 9.2 Write the values to Vault

```bash
SA=tpgpocbkp7k2m9q
SA_KEY="$(terraform -chdir=terraform output -raw backup_storage_account_key)"
# SA_KEY="$(az storage account keys list -g rg-aks-tanzu-data -n tanzudatabkp01 --query '[0].value' -o tsv)"

# vt() from section 6.5; VAULT_TOKEN is a token with the tpg-admin policy. The values
# reach jq through the environment (env.X), never as a command-line argument.
{ printf '%s\n' "$VAULT_TOKEN"; U="$BROADCOM_USER" P="$BROADCOM_TOKEN" jq -cn \
    '{username: env.U, password: env.P}'; } | vt kv put tpg/shared/broadcom-registry -
{ printf '%s\n' "$VAULT_TOKEN"; U="$GITHUB_USER" P="$GIT_READ_PAT" jq -cn \
    '{username: env.U, token: env.P}'; } | vt kv put tpg/shared/github-read -
{ printf '%s\n' "$VAULT_TOKEN"; U="$GITHUB_USER" P="$GIT_PUSH_PAT" jq -cn \
    '{username: env.U, token: env.P}'; } | vt kv put tpg/shared/github-push -
{ printf '%s\n' "$VAULT_TOKEN"; U="$SA" P="$SA_KEY" jq -cn \
    '{accountName: env.U, accountKey: env.P}'; } | vt kv put tpg/shared/backup-storage -
unset BROADCOM_TOKEN GIT_READ_PAT GIT_PUSH_PAT SA_KEY
```

A backup storage endpoint with a private CA can keep its CA bundle in Vault under a name, for the workflows to read (input or clusterMap key `backupCaBundleVaultSecret`). By hand (the script is `scripts/vault-secret.sh ca put NAME FILE`):

```bash
{ printf '%s\n' "$VAULT_TOKEN"; jq -cn --rawfile c ./storage-ca.pem '{caBundle:$c}'; } \
  | vt kv put tpg/ca-bundles/storage-ca -
```

A later change of a credential goes through the workflow `tpg-rotate-credential`, which takes the new value in a Vault response-wrapping token rather than as an input. By hand (the script is `scripts/vault-secret.sh wrap git-push`):

```bash
read -rs GIT_PUSH_PAT
T="$({ printf '%s\n' "$VAULT_TOKEN"; U="$GITHUB_USER" P="$GIT_PUSH_PAT" jq -cn '{username: env.U, token: env.P}'; } \
  | vt write -wrap-ttl=10m -format=json sys/wrapping/wrap - | jq -r '.wrap_info.token')"
unset GIT_PUSH_PAT
argo submit -n argo --from workflowtemplate/tpg-rotate-credential \
  -p secretType=git-push -p wrappingToken="$T" --watch
unset T
```

The token is single use and valid for 10 minutes. The `write` step unwraps it as `argo/tpg-credential-writer` and writes the new version.

If an earlier version of this repository created `argo/tpg-src-broadcom-registry`, `argo/tpg-src-backup-storage` or `argo/tpg-git-push`, delete them: the credentials now live in Vault only.

### 9.3 Argo CD repositories from Vault

Two `VaultStaticSecret` objects build the repository Secrets and keep them in step with Vault. `transformation.templates` turns the Vault fields into the keys Argo CD expects, and `excludes: [".*"]` keeps the raw Vault fields out of the Secret.

```bash
kubectl --context $HUB apply -f - <<YAML
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultStaticSecret
metadata:
  name: repo-tpg-fleet
  namespace: argocd
spec:
  vaultAuthRef: tpg-vault
  mount: tpg
  type: kv-v2
  path: shared/github-read
  refreshAfter: 60s
  destination:
    name: repo-tpg-fleet
    create: true
    overwrite: true
    labels: { argocd.argoproj.io/secret-type: repository }
    transformation:
      excludeRaw: true
      excludes: [".*"]
      templates:
        type: { text: "git" }
        url: { text: "$FLEET_REPO_URL" }
        username: { text: '{{ get .Secrets "username" }}' }
        password: { text: '{{ get .Secrets "token" }}' }
YAML

kubectl --context $HUB -n argocd get vaultstaticsecret repo-tpg-fleet
kubectl --context $HUB -n argocd get secret repo-tpg-fleet
```

The second object, `repo-tanzu-postgres-oci`, does the same for the Broadcom OCI registry (`type: helm`, `enableOCI: "true"`, `url: $REGISTRY`, `username` and `password` from `tpg/shared/broadcom-registry`).

Argo CD reports a `VaultStaticSecret` as Healthy only once its Secret is synced (the Lua health check in `argo/argocd-values.yaml`), so the Postgres sync wave never starts before the Secrets exist.

### 9.4 Settings and the workflow-bot token

`backupCaBundle` is the CA bundle for `enableSSL: true` (2.3): the Terraform file, or `backup.caBundleFile` of the inventory, or the Azure roots in `terraform/modules/storage/azure-ca-roots.pem`. Check the account's blob endpoint against it first:

```bash
CA_FILE=.work/backup-ca-bundle.pem        # pre-created: terraform/modules/storage/azure-ca-roots.pem, or your file
openssl s_client -connect "$SA.blob.core.windows.net:443" -servername "$SA.blob.core.windows.net" \
  -CAfile "$CA_FILE" -verify_return_error </dev/null 2>/dev/null | grep 'Verify return code'   # 0 (ok)
ACNS=false                                # true when the clusters run ACNS (2.3)
```

```bash
kubectl --context $HUB -n argo create configmap tpg-settings \
  --from-file=backupCaBundle="$CA_FILE" --from-literal=acnsEnabled="$ACNS" \
  --from-literal=fleetRepoURL="$FLEET_REPO_URL" --from-literal=fleetRevision="$FLEET_REPO_REVISION" \
  --from-literal=registryHost="$REGISTRY" --from-literal=backupStorageAccount="$SA" \
  --from-literal=githubApiUrl=https://api.github.com \
  --from-literal=monitoringOption="$MONITORING_OPTION" \
  --from-literal=hubPrometheusRemoteWriteUrl="" \
  --from-literal=vaultAddr="https://vault.vault.svc:8200" \
  --from-literal=vaultFleetAddr="https://$IP:8200" \
  --dry-run=client -o yaml | kubectl --context $HUB apply -f -
```

Generate the `workflow-bot` API token. The script uses a port-forward, so it works whether or not the Argo CD UI is exposed:

```bash
kubectl --context $HUB -n argocd port-forward svc/argocd-server 18080:443 >/dev/null 2>&1 &
PF=$!; sleep 3
ADMIN_PW="$(kubectl --context $HUB -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
argocd login localhost:18080 --username admin --password "$ADMIN_PW" --insecure --grpc-web
TOKEN="$(argocd account generate-token --account workflow-bot --grpc-web)"
kubectl --context $HUB -n argo create secret generic argocd-workflow-token --from-literal=token="$TOKEN" \
  --dry-run=client -o yaml | kubectl --context $HUB apply -f -
argocd repo list --grpc-web
kill $PF
```

```text
TYPE  NAME            REPO                                      INSECURE  OCI    LFS    CREDS  STATUS      MESSAGE
git                   https://github.com/acme/tpg-fleet.git     false     false  false  true   Successful
helm  tanzu-postgres  tanzu-sql-postgres.packages.broadcom.com  false     true   false  true   Successful
```

On an existing hub where `argocd-initial-admin-secret` was deleted, export `ARGOCD_ADMIN_PASSWORD` (or log in with SSO and an account allowed to generate tokens for `workflow-bot`).

### 9.5 Archive the workflow logs

Every workflow step's log is copied to Azure Blob when the step ends, through the namespace default artifact repository of `argo`. It needs no change to the Argo Workflows Helm values, so it works the same on an existing hub. The storage key comes from Vault:

```bash
cat <<EOF | kubectl --context $HUB apply -f -
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultStaticSecret
metadata: {name: argo-artifacts, namespace: argo}
spec:
  vaultAuthRef: tpg-vault/tpg-vault
  type: kv-v2
  mount: tpg
  path: shared/backup-storage
  refreshAfter: 60s
  destination: {name: argo-artifacts, create: true, overwrite: true, transformation: {excludeRaw: true}}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: artifact-repositories
  namespace: argo
  annotations: {workflows.argoproj.io/default-artifact-repository: tpg-azure-logs}
data:
  tpg-azure-logs: |
    archiveLogs: true
    azure:
      endpoint: https://$SA.blob.core.windows.net
      container: argo-logs
      accountKeySecret: {name: argo-artifacts, key: accountKey}
EOF
kubectl --context $HUB -n argo get secret argo-artifacts    # synced from Vault
```

The Argo UI shows a finished step's log after its pod is deleted, while the Workflow exists (7 days). Afterwards: `scripts/wf-logs.sh <workflow>` (`--list`, `--grep PATTERN`, `--out DIR`), which reads the key from `argo/argo-artifacts` and passes it to `az` in the environment of that one command. The lifecycle rule deletes the logs after 90 days (section 2.3 or 3.3).

---

## 10. Install the Helm add-ons

Mirrors `scripts/steps/45-helm-addons.sh`, which runs `tpg-fleet/workflows/scripts/helm-addons.sh` for each cluster. The add-ons are Helm releases, so `helm list -A` and `helm history` show them. Argo CD does not manage them.

| Cluster | Release | Chart | Namespace | When |
|---|---|---|---|---|
| Each target | `cert-manager` | jetstack `cert-manager` v1.21.2 (`crds.enabled=true`) | `cert-manager` | Always |
| Each target | `vault-secrets-operator` | hashicorp `vault-secrets-operator` 1.5.1 | `vault-secrets-operator-system` | Always |
| Hub | `vault`, `vault-secrets-operator` | hashicorp `vault` 0.34.1, `vault-secrets-operator` 1.5.1 | `vault`, `vault-secrets-operator-system` | Section 6 |
| Hub | `kps` | prometheus-community `kube-prometheus-stack` 91.4.0 | `monitoring` | `MONITORING_OPTION=standalone` |
| Hub | Deployment `tpg-remote-write` (not a Helm release: `kubectl apply -k monitoring/standalone/hub`) | `nginxinc/nginx-unprivileged:1.27-alpine` | `monitoring` | `MONITORING_OPTION=standalone` |
| Each target | `kps` (Prometheus agent, remote write to the hub) | `kube-prometheus-stack` 91.4.0 | `monitoring` | `MONITORING_OPTION=standalone` |
| Each target | `tpg-ksm` | `kube-state-metrics` 8.5.0 | `monitoring` | `MONITORING_OPTION=standalone` |

Each release is classified before anything changes, and the result is printed as `ADDON <release> <status> <detail>`:

| Status | What the script does |
|---|---|
| `INSTALLED`, `UPGRADED` | Installed or upgraded to the pinned chart version |
| `UP_TO_DATE` | Our release, same chart version and values: nothing to do |
| `SKIPPED_EXISTS` | Our release differs. On a terminal you are asked to upgrade, skip or abort; otherwise it is skipped (`--yes` or `ADDONS_EXISTING=upgrade` upgrades without asking) |
| `SKIPPED_NEWER` | The installed chart is newer than the pinned version; never downgraded |
| `REUSED_EXISTING` | A cert-manager (>= 1.14) or Vault Secrets Operator (>= 0.9) installed by someone else is running and is used as it is |
| `BLOCKED` | Another installation that cannot be reused, or an operation in progress. The step stops and the cluster is not changed |

While `helm --wait` runs, the pods of the release's namespace are printed every 5 seconds, and the install stops as soon as one cannot start, with its status, events and logs: at once for `CreateContainerConfigError`, `CreateContainerError`, `InvalidImageName` and `RunContainerError`, after 60 seconds of `CrashLoopBackOff`, `ImagePullBackOff`/`ErrImagePull`, `Error` or `OOMKilled`, after 5 minutes unschedulable or Pending.

### 10.1 cert-manager and the Vault Secrets Operator on the targets

```bash
VAULT_ADDR_FLEET="$(kubectl --context $HUB -n argo get cm tpg-settings -o jsonpath='{.data.vaultFleetAddr}')"
kubectl --context $HUB -n argo get secret vault-ca -o jsonpath='{.data.ca\.crt}' | base64 -d > "$WORK/vault-ca.crt"

for c in $TARGETS; do
  helm --kube-context $c upgrade --install cert-manager cert-manager \
    --repo https://charts.jetstack.io --version v1.21.2 \
    -n cert-manager --create-namespace --set crds.enabled=true --wait --timeout 15m
  kubectl --context $c -n cert-manager wait deploy --all --for=condition=Available --timeout=300s

  helm --kube-context $c upgrade --install vault-secrets-operator vault-secrets-operator \
    --repo https://helm.releases.hashicorp.com --version 1.5.1 \
    -n vault-secrets-operator-system --create-namespace \
    -f "$FLEET_LOCAL_DIR/vault/vso-values.yaml" --wait --timeout 15m

  # VaultConnection and VaultAuth tpg-vault, from tpg-fleet/vault/tpg-vault-objects.yaml
  sed -e "s|@VAULT_ADDR@|$VAULT_ADDR_FLEET|" -e "s|@AUTH_MOUNT@|k8s-$c|" \
      -e "s|@AUTH_ROLE@|tpg-vso|" -e "s|@ALLOWED_NS@|*|" \
      "$FLEET_LOCAL_DIR/vault/tpg-vault-objects.yaml" | kubectl --context $c apply -f -
  kubectl --context $c -n tpg-vault create secret generic vault-ca \
    --from-file=ca.crt="$WORK/vault-ca.crt" --dry-run=client -o yaml | kubectl --context $c apply -f -
done
```

The `tpg-helm-addons` workflow and `tpg-day0` (`installAddons=true`, the default) run the same installs for new clusters.

### 10.2 Standalone monitoring on the hub

The targets write their metrics to the hub through the remote-write gateway `tpg-remote-write`: nginx on port 8443 with a certificate from the Vault CA, basic auth with the credential in Vault `tpg/shared/monitoring-remote-write`, and only `/api/v1/write` forwarded to the hub Prometheus (which is a ClusterIP Service; every other path answers 404). Its load balancer is internal or public, from the inventory `monitoring.remoteWriteExposure`; a public one accepts only the target egress CIDRs and `monitoring.extraSourceCidrs`.

```bash
# 1. The credential, created once, kept in Vault only (vt() from 6.5, a token with the tpg-admin policy)
PW="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)"
printf '%s\n{"username":"tpg-remote-write","password":"%s"}\n' "$VAULT_TOKEN" "$PW" | vt kv put tpg/shared/monitoring-remote-write -
unset PW

# 2. The Service (public here; internal: annotation service.beta.kubernetes.io/azure-load-balancer-internal: "true"
#    and no loadBalancerSourceRanges)
kubectl --context $HUB create namespace monitoring --dry-run=client -o yaml | kubectl --context $HUB apply -f -
cat <<EOF | kubectl --context $HUB apply -f -
apiVersion: v1
kind: Service
metadata: {name: tpg-remote-write, namespace: monitoring, labels: {app.kubernetes.io/name: tpg-remote-write}}
spec:
  type: LoadBalancer
  selector: {app.kubernetes.io/name: tpg-remote-write}
  ports: [{name: https, port: 8443, targetPort: 8443}]
  loadBalancerSourceRanges: ["20.10.1.4/32", "20.10.2.7/32", "20.10.3.9/32"]   # target egress IPs
EOF
RW_IP="$(kubectl --context $HUB -n monitoring get svc tpg-remote-write -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"

# 3. TLS: a certificate for the gateway IP and names, signed by the Vault CA (Secret vault/vault-ca-keypair),
#    as in section 6.2, stored as Secret monitoring/tpg-remote-write-tls (tls.crt, tls.key)

# 4. htpasswd for the gateway: the apr1 hash, never the password
U="$(printf '%s\n' "$VAULT_TOKEN" | vt kv get -field=username tpg/shared/monitoring-remote-write)"
printf '%s\n' "$VAULT_TOKEN" | vt kv get -field=password tpg/shared/monitoring-remote-write \
  | openssl passwd -apr1 -stdin | sed "s/^/$U:/" \
  | kubectl --context $HUB -n monitoring create secret generic tpg-remote-write-htpasswd --from-file=htpasswd=/dev/stdin \
      --dry-run=client -o yaml | kubectl --context $HUB apply -f -
```

The workflows check that each target's metrics arrive by querying the hub Prometheus through the API server's service proxy, so `argo/tpg-workflow` gets `get` on `services/proxy` for `prometheus-operated` in `monitoring` (Role and RoleBinding `tpg-workflow-prometheus-query`).

Grafana reads its admin login from Secret `monitoring/grafana-admin`. Create it before the install, otherwise the Grafana pod stays in `CreateContainerConfigError`. The script uses `GRAFANA_ADMIN_PASSWORD` when it is exported and generates a 24-character password otherwise:

```bash
kubectl --context $HUB create namespace monitoring
GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)}"
kubectl --context $HUB -n monitoring create secret generic grafana-admin \
  --from-literal=admin-user=admin --from-literal=admin-password="$GRAFANA_ADMIN_PASSWORD"

cd "$FLEET_LOCAL_DIR"
helm --kube-context $HUB upgrade --install kps kube-prometheus-stack \
  --repo https://prometheus-community.github.io/helm-charts --version 91.4.0 \
  -n monitoring --create-namespace \
  -f monitoring/standalone/hub/kps-values.yaml \
  -f monitoring/grafana/alerts/grafana-alerting-values.yaml --wait --timeout 15m
kubectl --context $HUB apply -k monitoring/standalone/hub     # gateway, 5 dashboards, rules
cd -
kubectl --context $HUB -n monitoring rollout status deploy/tpg-remote-write

# Remote write URL for the targets, stored in tpg-settings for the workflows
kubectl --context $HUB -n argo patch configmap tpg-settings --type merge \
  -p "{\"data\":{\"hubPrometheusRemoteWriteUrl\":\"https://${RW_IP}:8443/api/v1/write\",\"monitoringOption\":\"standalone\"}}"

# Grafana data sources (Prometheus uid prometheus, Alertmanager uid alertmanager) and dashboards
kubectl --context $HUB -n monitoring get cm -l grafana_datasource=1
kubectl --context $HUB -n monitoring get cm -l grafana_dashboard=1
```

The dashboards are in the Grafana folder **Tanzu Postgres**: Fleet, Instance overview, Replication and HA, Backup/WAL/restore, and Alerts.

Read the Grafana password back with:

```bash
kubectl --context $HUB -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

To add SMTP notifications, export `KPS_HUB_EXTRA_VALUES=monitoring/grafana/smtp/grafana-smtp-values.yaml` (comma-separated for several files) and run `scripts/run.sh ... --only addons` again.

### 10.3 Standalone monitoring on the targets

Each target reads the credential from Vault (`VaultStaticSecret monitoring/tpg-remote-write`, role `tpg-vso`, policy `tpg-target`) and trusts the gateway with the Vault CA (`monitoring/tpg-remote-write-ca`, copied from `tpg-vault/vault-ca`).

```bash
RW="$(kubectl --context $HUB -n argo get cm tpg-settings -o jsonpath='{.data.hubPrometheusRemoteWriteUrl}')"
cd "$FLEET_LOCAL_DIR"
for c in $TARGETS; do
  kubectl --context $c create namespace monitoring --dry-run=client -o yaml | kubectl --context $c apply -f -
  kubectl --context $c apply -f monitoring/standalone/targets/remote-write-credentials.yaml
  kubectl --context $c -n tpg-vault get secret vault-ca -o json \
    | jq '{apiVersion, kind, type, data, metadata: {name: "tpg-remote-write-ca", namespace: "monitoring"}}' \
    | kubectl --context $c apply -f -
  kubectl --context $c -n monitoring get secret tpg-remote-write     # synced from Vault
  helm --kube-context $c upgrade --install kps kube-prometheus-stack \
    --repo https://prometheus-community.github.io/helm-charts --version 91.4.0 -n monitoring --create-namespace \
    -f monitoring/standalone/targets/kps-values.yaml \
    --set-string prometheus.prometheusSpec.externalLabels.cluster=$c \
    --set-json "prometheus.prometheusSpec.remoteWrite=[{\"url\":\"$RW\",
      \"basicAuth\":{\"username\":{\"name\":\"tpg-remote-write\",\"key\":\"username\"},\"password\":{\"name\":\"tpg-remote-write\",\"key\":\"password\"}},
      \"tlsConfig\":{\"ca\":{\"secret\":{\"name\":\"tpg-remote-write-ca\",\"key\":\"ca.crt\"}}}}]" --wait --timeout 15m
  helm --kube-context $c upgrade --install tpg-ksm kube-state-metrics \
    --repo https://prometheus-community.github.io/helm-charts --version 8.5.0 -n monitoring \
    -f monitoring/ksm/values.yaml --set prometheus.monitor.enabled=true --wait --timeout 15m
  kubectl --context $c apply -k monitoring/standalone/targets -n monitoring
  helm --kube-context $c list -n monitoring
done
cd -
```

```text
NAME     NAMESPACE   REVISION  STATUS    CHART                           APP VERSION
kps      monitoring  1         deployed  kube-prometheus-stack-91.4.0    ...
tpg-ksm  monitoring  1         deployed  kube-state-metrics-8.5.0        ...
```

Check that each target's metrics reach the hub (what the step and the workflows do, for up to 5 minutes; `MONITORING_NOT_FLOWING` otherwise):

```bash
for c in $TARGETS; do
  kubectl --context $HUB get --raw \
    "/api/v1/namespaces/monitoring/services/http:prometheus-operated:9090/proxy/api/v1/query?query=count(up%7Bcluster%3D%22$c%22%7D)" \
    | jq -r --arg c "$c" '"\($c): \(.data.result[0].value[1] // "no series")"'
done
kubectl --context $HUB -n monitoring logs deploy/tpg-remote-write --tail=5   # POST /api/v1/write ... 204
```

### 10.4 Azure Monitor option

With `MONITORING_OPTION=azure`, every cluster needs the managed Prometheus add-on linked to the Azure Monitor workspace (Terraform output, or `monitoring.azureMonitorWorkspaceId` for pre-created clusters). A pre-created cluster usually does not have it, and then shows no data in Grafana. The step enables it where it is off:

```bash
AMW="$(yq '.monitoring.azureMonitorWorkspaceId' "$INVENTORY")"
az aks show -g rg-aks-tanzu-data -n blrck-pg-02 --query azureMonitorProfile.metrics.enabled -o tsv
az aks update -g rg-aks-tanzu-data -n blrck-pg-02 --enable-azure-monitor-metrics --azure-monitor-workspace-resource-id "$AMW"
kubectl --context blrck-pg-02 -n kube-system get pods -l rsName=ama-metrics
```

Azure Managed Grafana reads the workspace only with the **Monitoring Data Reader** role on it. A Contributor cannot create that assignment, so the step checks it and prints the command for an owner:

```bash
PID="$(az grafana show -g rg-tpgpoc -n amg-tpgpoc --query identity.principalId -o tsv)"
az role assignment list --scope "$AMW" --assignee "$PID" --query "[].roleDefinitionName" -o tsv
az role assignment create --assignee-object-id "$PID" --assignee-principal-type ServicePrincipal \
  --role "Monitoring Data Reader" --scope "$AMW"
```

Then it imports the five dashboards (folder `tpg-postgres`) and the alert rules: `"$FLEET_LOCAL_DIR"/monitoring/grafana/import-azure-grafana.sh rg-tpgpoc amg-tpgpoc` (needs the Grafana Admin role on the Grafana instance).

---

## 11. Bootstrap the fleet

Mirrors `scripts/steps/50-bootstrap-fleet.sh`. Before you start, the `tpg-fleet` repository URL must be set and pushed (`tpg-fleet/scripts/set-repo-url.sh`). Clusters need no folder of their own: every cluster uses `clusters/_template/`, and `tpg-day0` adds each cluster to `clusters/fleet.yaml`.

```bash
cd "$FLEET_LOCAL_DIR"
grep -rl '<org>' bootstrap && echo "set the repository URL first"
for c in $TARGETS; do C=$c yq -e '.clusters | has(strenv(C))' clusters/fleet.yaml >/dev/null || echo "$c not in clusters/fleet.yaml yet (tpg-day0 adds it)"; done

kubectl --context $HUB apply -f bootstrap/project-tpg.yaml
kubectl --context $HUB apply -f bootstrap/project-tpg-hub.yaml     # hub Applications (not covered by the RBAC deny lines)
kubectl --context $HUB apply -f bootstrap/appsets/
kubectl --context $HUB apply -f bootstrap/app-hub-workflows.yaml
# Monitoring option azure only (standalone is installed with Helm in section 10; skip for none)
kubectl --context $HUB apply -f bootstrap/monitoring/azure/

kubectl --context $HUB -n argocd get application tpg-hub-workflows \
  -o jsonpath='{.status.sync.status}/{.status.health.status}{"\n"}'
# Synced/Healthy
kubectl --context $HUB -n argocd get applications -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status
cd -
```

Target Applications show `OutOfSync` / `Missing` until the Day 0 workflow syncs them. That is expected: they have no automated sync, and only the workflows may sync them. The operator and instance Applications appear only for clusters in `clusters/fleet.yaml`.

`tpg-hub-workflows` also installs three ValidatingAdmissionPolicies on the hub (Kubernetes 1.30 or later), from `tpg-fleet/workflows/admission/`, and the ServiceAccounts `argo/tpg-workflow` and `argo/tpg-credential-writer`:

| Policy | Refuses |
|---|---|
| `tpg-workflow-parameters` | A Workflow of a tpg WorkflowTemplate whose inputs do not match their types (generated from `workflows/params/types.yaml`) |
| `tpg-application-sync` | A new operation on a target Application (label `tpg.fleet/component` operator, instance or platform) that argocd-server does not write on behalf of `workflow-bot`, and switching on automated sync; this also covers a `kubectl edit` |
| `tpg-credential-writer` | In namespace `argo` (and any ClusterWorkflowTemplate): an object that names the ServiceAccount `tpg-credential-writer` (in `spec`, `templateDefaults`, a template or an inline template), except the WorkflowTemplate `tpg-rotate-credential`; a `podSpecPatch` that mentions a ServiceAccount or holds a backslash or `!!`; a `templateRef` to `tpg-rotate-credential` from another object; a run of `tpg-rotate-credential` with spec fields beyond `workflowTemplateRef` and `arguments`; a change of `tpg-rotate-credential` by anyone but Argo CD; a ConfigMap other than `tpg-run-*` written, or a pod spec changed, by the ServiceAccounts `tpg-workflow` or `tpg-credential-writer` (the write step runs its script from `tpg-scripts` and reads `tpg-settings`) |

```bash
kubectl --context $HUB get validatingadmissionpolicy,validatingadmissionpolicybinding | grep tpg-
```

Round 22 adds two things to what `tpg-hub-workflows` installs, both from `tpg-fleet/workflows/`. The Role `tpg-workflow` in namespace `argocd` now allows `get` and `patch` on `applications.argoproj.io`: `tpg-delete-apps` and `tpg-delete-instance` use it to remove the Argo CD finalizer of an Application that cannot be rendered (`ComparisonError`, for example after the Broadcom registry token expired) and so never finishes deleting (input `forceDeleteStuckApps`, default `true`); the admission policy `tpg-application-sync` does not block it, because it changes no operation. And every workflow that commits to `clusters/fleet.yaml` takes a lock, the ConfigMap `argo/tpg-run-fleet-lock`, which the workflow creates on first use (the Role in `argo` already allows `create`, `get` and `patch` on ConfigMaps); delete it only while no workflow runs. Check the Role after the sync:

```bash
kubectl --context $HUB -n argocd get role tpg-workflow -o json | jq '.rules[] | select(.resources[]? == "applications")'
```

---

## 12. Verify

Mirrors `scripts/steps/60-verify.sh`. Every check is read-only. The script does not stop at the first problem: it ends with a summary, one line per resource with the clusters it fails on, and exits 1 when there is at least one issue. Advisory findings (an existing Tanzu Postgres CRD, a data pool that cannot hold HA instances, and a target StorageClass `tpg-data-retain` that the first tpg-day0 has not created yet) are listed apart as warnings and do not change the exit code.

The StorageClass `tpg-data-retain` of a target comes from that cluster's `tpg-<cluster>-platform` Application, which only tpg-day0 syncs (`workflows/scripts/day0-deploy.sh`). On the first run of `scripts/run.sh`, before any tpg-day0, it does not exist yet: verify reports it as a warning ("this object will be created when the tpg-day0 workflow runs") as long as that Application has never synced (no `status.history` entry and no succeeded operation, or not generated yet). Once it has synced, or when the StorageClass or that Application cannot be read (an access or connection error rather than not found), it is an issue; a wrong disk SKU is always an issue, and so is a missing StorageClass on the hub (the `vault` step creates it).

```text
==================== verify summary ====================
ISSUES (1) resources that are missing or wrong, and where:
   1. archived workflow logs: Secret argo/argo-artifacts (from Vault)
      clusters: aks-tpg-hub
      secret/argo-artifacts not found on aks-tpg-hub (namespace argo)
WARNINGS (2) advisory, the run does not fail on these:
   1. StorageClass tpg-data-retain (disk SKU Premium_ZRS)
      clusters: aks-tpg-poc-01, aks-tpg-poc-02, aks-tpg-poc-03
      storageclass/tpg-data-retain not found on each cluster listed; this object will be created when the tpg-day0 workflow runs (day0-deploy.sh syncs the cluster's tpg-platform Application, which has not synced yet)
   2. data pool not HA-capable
      clusters: aks-tpg-poc-03
      2 Ready node(s) in 2 zone(s); tpg-day0 refuses highAvailability=true on this cluster

FAIL verify found 1 issue(s); fix them and re-run: scripts/run.sh ... --only verify
```

or `All checks passed on the hub aks-tpg-hub and 3 target cluster(s).` The descriptions come from the checks; the layout is as above.

Round 23: when `FLEET_LOCAL_DIR` points at the tpg-fleet clone, verify also reads `clusters/fleet.yaml` of that clone and checks every instance declared for a target in its namespace (`instance.namespace`, default `pg-<instance>`). A reserved namespace (the list `reserved` and `reservedPrefixes` of `namespace` in `workflows/params/cluster-map-keys.yaml`) is an issue, and so is a namespace in which not exactly one instance renders the shared Secrets (`instance.sharedSecretsOwner`); a namespace or a Postgres that does not exist yet is an advisory warning, because tpg-day0 and tpg-create-instance create them. The templates it requires are `tpg-lib` and the thirteen workflows, `tpg-backup-expire` and `tpg-restore` included.

```bash
kubectl --context $HUB -n argocd rollout status deploy/argocd-server --timeout=10s
kubectl --context $HUB -n argocd get cm argocd-cm -o jsonpath='{.data.accounts\.workflow-bot}'; echo
kubectl --context $HUB -n argo get secret argocd-workflow-token vault-ca
kubectl --context $HUB -n argo get configmap tpg-settings
kubectl --context $HUB -n argocd get secret repo-tpg-fleet repo-tanzu-postgres-oci
kubectl --context $HUB -n argocd get appproject tpg tpg-hub
kubectl --context $HUB -n argocd get application tpg-hub-workflows -o jsonpath='{.spec.project}'; echo   # tpg-hub
kubectl --context $HUB get validatingadmissionpolicy tpg-workflow-parameters tpg-application-sync tpg-credential-writer
kubectl --context $HUB get validatingadmissionpolicybinding tpg-workflow-parameters tpg-application-sync tpg-credential-writer
kubectl --context $HUB -n argo get serviceaccount tpg-workflow tpg-credential-writer
kubectl --context $HUB -n argo get workflowtemplate tpg-patch tpg-create-instance tpg-network-policy tpg-backup-expire tpg-restore
kubectl --context $HUB -n argo get cm tpg-settings -o jsonpath='{.data.backupCaBundle}' | grep -c 'BEGIN CERTIFICATE'
kubectl --context $HUB -n argo get cm tpg-settings -o jsonpath='{.data.acnsEnabled}'; echo
kubectl --context $HUB -n argocd get cm argocd-rbac-cm -o yaml > /tmp/rbac-cm.yaml   # RBAC deny block (argocd CLI)
argocd admin settings rbac can role:admin sync applications tpg/tpg-rbac-probe-operator --policy-file /tmp/rbac-cm.yaml     # No
argocd admin settings rbac can workflow-bot sync applications tpg/tpg-rbac-probe-operator --policy-file /tmp/rbac-cm.yaml   # Yes
kubectl --context $HUB -n argo get workflowtemplates
kubectl --context $HUB -n argo get sa tpg-workflow
kubectl --context $HUB -n argocd get cm argocd-cm -o json \
  | jq -r '.data | keys[] | select(startswith("resource.customizations.health"))'   # VaultStaticSecret and Postgres
kubectl --context $HUB -n argo get configmap artifact-repositories
kubectl --context $HUB -n argo get secret argo-artifacts

# Vault
kubectl --context $HUB -n vault exec -i vault-0 -c vault -- vault status
kubectl --context $HUB -n vault rollout status deploy/vault-agent-injector --timeout=10s
kubectl --context $HUB -n vault get svc vault-fleet
kubectl --context $HUB -n argocd get vaultstaticsecret repo-tpg-fleet repo-tanzu-postgres-oci

for c in $TARGETS; do
  kubectl --context $HUB -n argocd get secret cluster-$c
  kubectl --context $HUB -n argo get secret kubeconfig-$c
  kubectl --context $c get crd vaultstaticsecrets.secrets.hashicorp.com
  kubectl --context $c -n tpg-vault get vaultauth tpg-vault
  kubectl --context $c auth can-i '*' '*' --as=system:serviceaccount:kube-system:argocd-manager
  kubectl --context $c get nodes -L topology.kubernetes.io/zone,kubernetes.azure.com/agentpool
  kubectl --context $HUB -n argocd get applications -l tpg.fleet/cluster=$c
  kubectl --context $c get crd postgres.sql.tanzu.vmware.com 2>/dev/null && echo "existing Tanzu Postgres CRDs"
  kubectl --context $c get crd ciliumnetworkpolicies.cilium.io >/dev/null && echo "CiliumNetworkPolicy available"
  # once the operator runs: Azure Blob backups come from the CRD (the 4.5 documentation lists S3 and GCS only).
  # container is required; without caBundle only enableSSL: false instances can deploy (run.sh verify: advisory)
  kubectl --context $c explain postgresbackuplocation.spec.storage.azure 2>/dev/null | grep -E '^ +(container|caBundle|enableSSL)'
done
```

Check the Helm add-ons:

```bash
for c in $TARGETS; do helm --kube-context $c list -A | grep -E 'cert-manager|vault-secrets-operator|kps|tpg-ksm'; done
helm --kube-context $HUB -n vault status vault
helm --kube-context $HUB -n monitoring status kps        # standalone monitoring
kubectl --context $HUB -n monitoring get secret grafana-admin
kubectl --context $HUB -n monitoring get deploy,svc tpg-remote-write           # standalone monitoring
kubectl --context $HUB -n argo get cm tpg-settings -o jsonpath='{.data.hubPrometheusRemoteWriteUrl}'; echo   # https://...:8443/api/v1/write
for c in $TARGETS; do kubectl --context $c -n monitoring get secret tpg-remote-write tpg-remote-write-ca; done
```

Then run the Day 0 pre-check (dry run: nothing is pushed or deployed):

```bash
argo submit -n argo --from workflowtemplate/tpg-day0 \
  -p clusters=all -p 'instances=[orders-db]' -p highAvailability=true \
  -p operatorVersion=v4.5.0 -p postgresVersion=postgres-17.6 -p pushMode=direct \
  -p dryRun=true --watch
```

See `tpg-fleet/docs/workflow-commands.md` for every workflow command: each workflow section has a parameter-file schema and two worked examples with their `argo submit` commands (Round 23).

---

## 13. Print every UI endpoint and login

Mirrors `scripts/access.sh` (`scripts/run.sh ... --only access`, `make access`). Everything is printed to the terminal; nothing is written to a file.

```bash
# Argo CD
kubectl --context $HUB -n argocd get svc argocd-server
kubectl --context $HUB -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo

# Argo Workflows (paste the whole "Bearer ..." value in the client authentication field)
kubectl --context $HUB -n argo get svc argo-server
printf 'Bearer %s\n' "$(kubectl --context $HUB -n argo get secret argo-ui-admin.service-account-token -o jsonpath='{.data.token}' | base64 -d)"

# Vault: UI, seal state, and the tpg-admin password from Vault itself
kubectl --context $HUB -n vault get svc vault-ui vault-fleet
kubectl --context $HUB -n vault exec -i vault-0 -c vault -- vault status
# vt() from section 6.5, with a token that has the tpg-admin policy:
printf '%s\n' "$VAULT_TOKEN" | vt kv get -format=json tpg/admin/vault-ui | jq -r '.data.data.password'

# Grafana, Prometheus, Alertmanager (standalone monitoring), and the remote-write gateway
kubectl --context $HUB -n monitoring get svc
kubectl --context $HUB -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo

# Postgres instances and their credentials
for c in $TARGETS; do
  kubectl --context $c get postgres -A
  # pg-orders-db is the default namespace of orders-db; an instance may have another (clusterMap key namespace, Round 23)
  kubectl --context $c -n pg-orders-db get secret orders-db-db-secret -o jsonpath='{.data.password}' | base64 -d; echo
done
```

Archived workflow logs: in the Argo Workflows UI (the step's logs tab) while the Workflow exists, afterwards `scripts/wf-logs.sh <workflow>`.

A Service without an external IP is reached with a port-forward, for example `kubectl --context $HUB -n vault port-forward svc/vault 8200:8200` and then `https://localhost:8200/ui`. `scripts/run.sh ... --only access` prints the matching command for each one, and `--rotate-vault-admin` sets a new Vault UI password.

---

## 14. Troubleshooting

| Symptom | Step | Cause and fix |
|---|---|---|
| `yq: Error: unknown command` or `jq: error` from yq | any | Python yq installed. Install mikefarah yq v4 |
| `inventory ... still contains <placeholders>` | inventory | Replace every `<...>` value in `inventory/clusters.yaml` |
| `authorized IP ranges miss the hub egress` | preflight | Re-run with `--fix-authorized-ips`, or add the CIDR as in 3.3 |
| `hub outbound type is userDefinedRouting` | preflight | Set `hub.egressCidrs` to the firewall or NAT public IPs |
| `local accounts are disabled` | preflight | `adminCredentials: false` and install kubelogin |
| `cannot reach the API server of <cluster>` | kubeconfigs | Your IP is not in the authorized ranges: `az aks update --api-server-authorized-ip-ranges` |
| `namespace argocd already has workloads` | hub (install) | Argo already installed by another release: use `--hub existing` |
| `accounts.workflow-bot is 'login' (no apiKey)` | hub (existing) | Set it to `apiKey, login` by hand and persist it in Helm values |
| Additive patches disappear after `helm upgrade` | hub (existing) | Merge `.work/hub-existing-*.yaml` into your Helm values |
| `token for argocd-manager ... was not populated` | service-accounts | Token controller delayed; re-run with `--only service-accounts` |
| `argocd login` fails on `localhost:18080` | hub-secrets | Port 18080 in use: `export ARGOCD_PF_PORT=28080` |
| `storage account ... not found` | preflight | Wrong `backup.resourceGroup`, or the account is in another subscription |
| `... requires secure transfer (HTTPS only), but the fleet default is enableSSL: false` | preflight | Allow HTTP on the account (`az storage account update --https-only false`), or set `backup.httpsOnly: true` and use `enableSSL: true` for the instances (3.3) |
| The same message although `az storage account show --query enableHttpsTrafficOnly` prints `false` | preflight | A copy of `tpg-aks-infra` from before Round 13 read `false` as `true`. Update the repository (3.3, I22) |
| Grafana pod `CreateContainerConfigError` | addons | Secret `monitoring/grafana-admin` missing: re-run `--only addons` (creates it) or create it as in 10.2 |
| `ADDON <release> BLOCKED` | vault, addons | Another installation of that component, or an operation in progress. The detail names it: remove it, finish the operation (`helm rollback`), or reuse it when it is compatible |
| `ADDON <release> SKIPPED_EXISTS` | vault, addons | Our release exists with other values or an older chart. Re-run with `--yes` (`ADDONS_EXISTING=upgrade`) to apply |
| `Vault is not initialized. Run this step from an interactive terminal` | vault | The unseal keys are shown once, so the step needs a terminal. Run `scripts/run.sh ... --only vault` by hand |
| `Vault is still sealed` after a restart | vault, any workflow | `shamir`: `scripts/run.sh ... --only vault-unseal`. `azure-keyvault`: check `kubectl -n vault logs vault-0` for the workload identity and the Key Vault access policy (get, wrapKey, unwrapKey) |
| `AuthorizationFailed ... roleAssignments/write` | Terraform apply | The account may not create role assignments. The unseal Key Vault no longer needs any; keep `create_role_assignments = false` (the default since Round 19, which needs `network_mode = "managed"`) and run the commands from `terraform output -json role_assignments_to_create` with an owner account. Leave it `false` afterwards, or the next apply fails with `RoleAssignmentExists` |
| `tpg-day0` reports `PGDATA_POOL_NOT_HA_CAPABLE` | Day 0 | The target's data pool does not span 3 zones with 3 Ready nodes. Widen `postgres_pool.zones` and its counts and re-apply, or deploy that instance with `highAvailability=false` |
| `VaultStaticSecret ... did not sync from Vault` | hub-secrets, day0 | Vault sealed, the value missing at that path, or the role's policy does not allow it: `kubectl -n argocd get vaultstaticsecret <name> -o yaml` shows the condition message, `kubectl -n vault-secrets-operator-system logs deploy/vault-secrets-operator-controller-manager` the cause |
| `permission denied` in a workflow step | any workflow | The Vault Agent could not read a path: check the role in `auth/kubernetes/role/tpg-workflow` and the `tpg-workflow` policy |
| `helm registry login` fails in the pre-check | hub-secrets | The Broadcom token is wrong or expired. The exact registry error is printed above the failure |
| `github PAT ... is not active` or `contents: write missing` | hub-secrets | Regenerate the fine-grained PAT with the repository in scope and `contents: read`/`write` (plus `pull_requests: write` for `pushMode=pr`) |
| `could not read the hub Prometheus remote write URL` | addons | The gateway load balancer `monitoring/tpg-remote-write` has no IP yet: check `kubectl -n monitoring get svc tpg-remote-write` and re-run |
| `MONITORING_NOT_FLOWING <cluster>` | addons, tpg-helm-addons, tpg-day0 | No series with `cluster=<cluster>` on the hub Prometheus after 5 minutes. Check in order: the target's Prometheus log (`kubectl -n monitoring logs prometheus-kps-kube-prometheus-stack-prometheus-0 -c prometheus`, lines with `remote`); `401` means the credential differs (`monitoring/tpg-remote-write` against Vault; re-run `--only addons` to rebuild the hub htpasswd); `x509` means the CA (`monitoring/tpg-remote-write-ca`); a timeout means the network path (public: the target egress IP in the Service's `loadBalancerSourceRanges`; internal: peering). Azure option: the `ama-metrics` pods in `kube-system` |
| Grafana shows no data source | addons (standalone) | `kubectl -n monitoring get cm -l grafana_datasource=1` is empty: re-run `--only addons` (the kps values provision Prometheus and Alertmanager explicitly). Azure: the Monitoring Data Reader role on the workspace (10.4) |
| `403 ... does not have keys purge permission` on `vault-unseal` | Terraform destroy | An older configuration without the `Purge` key permission. Pull the current `tpg-aks-infra`, `terraform apply` (updates the access policy), then destroy; or run destroy a second time |
| `Vault login with role tpg-setup failed although Vault is unsealed` | vault | A run that ended after `vault operator init`. Re-run `--only vault` and give the initial root token, or press Enter to generate one from 3 keys (6.4) |
| `kubectl get: transient error (attempt 2/5), retrying in 10s` | any | An intermittent AKS API timeout that was retried; nothing to do. When the same command fails 5 times the step fails with the last error |
| `POD_CRASHLOOPBACKOFF`, `POD_CREATECONTAINERCONFIGERROR`, `POD_UNSCHEDULABLE` | addons, hub, any workflow | A pod of the release or instance could not start. The step log shows the pod table, the pod's events and the container logs (`--previous` for a restarted one) |
| `SYNC_REJECTED ... admission webhook "vpostgres.kb.io" denied the request ... postgresVersion.name cannot be changed` | tpg-upgrade | An older `tpg-fleet` in which Argo CD applied `spec.postgresVersion`. The current `tpg-instances` ApplicationSet ignores that field; re-apply `bootstrap/appsets/` and rerun the upgrade |
| Argo CD shows an instance Synced/Healthy while its pods do not run | any | The hub runs Argo CD values without the `Postgres` health check: re-run `--only hub` and answer `u` (or `--yes`) |
| `no archived logs for <workflow>` | wf-logs.sh | The run is older than the log archive, the name is wrong (`argo list`), or the lifecycle rule deleted it |
| `tpg-hub-workflows is OutOfSync/Missing` | bootstrap | Repository credentials wrong or URL placeholder still set: `argocd repo list --grpc-web` |
| `unknown shorthand flag: 'a' in -a` from helm | addons, vault, any workflow | A Helm 3 flag against Helm 4 (the tools image `alpine/k8s:1.35.8` ships Helm 4). `helm list` lists every state there without `-a`. Run `tpg-fleet/tests/cli-flags/run.sh` to find every such flag in both repositories |
| `KPS_HUB_EXTRA_VALUES: unbound variable` | addons (standalone) | The `tpg-fleet` clone predates the `monitoring_hub()` fix in section 1.3. Apply the snippet there, or pull the current `tpg-fleet` |
| `WARN <cluster>: StorageClass tpg-data-retain ... not found` | verify | The object does not exist on that cluster, which is different from a wrong SKU. On a target whose `tpg-<cluster>-platform` Application has never synced it is only a warning: tpg-day0 creates it (`day0-deploy.sh` syncs that Application). Once that Application has synced it is an issue: run tpg-day0 for the cluster again (only the workflows sync target Applications). The hub gets it from `--only vault` |
| `WARN ... has 'Premium_ZRS' where 'StandardSSD_LRS' is expected` | verify | The StorageClass exists with another disk SKU: `storage.dataDiskSku` in the inventory (or Terraform `postgres_data_disk_sku`) and the cluster disagree. A StorageClass is immutable, so delete and re-apply it, then re-run `--only vault` and sync `tpg-<cluster>-platform` |
| `tpg-<cluster>-<instance>` stays OutOfSync on `PostgresBackupLocation` | day0, any sync | An older chart rendered `spec.additionalParameters: {}` and `spec.storage.azure.forcePathStyle: false`. The CRD drops both on apply, so the diff never settles. Pull the current `tpg-fleet` (the chart no longer writes them and the ApplicationSet ignores those two paths) and sync again |
| `The blob endpoint of <account> presents a chain that is not issued under the Azure root certificate authorities` | Terraform apply | Azure moved the storage endpoints to a root that `terraform/modules/storage/azure-ca-roots.pem` does not hold. Add it from https://learn.microsoft.com/azure/security/fundamentals/azure-ca-details and apply again |
| `<account>.blob.core.windows.net does not verify against <file>` | hub-secrets | The CA bundle does not hold the root of the account's chain. Pre-created account: set `backup.caBundleFile` to a bundle that does; Terraform account: pull the current repository and apply (the check at apply uses the same file) |
| `CA_BUNDLE_MISSING` | tpg-day0, tpg-create-instance | `enableSSL: true` requested and `tpg-settings` has no `backupCaBundle`: re-run `--only hub-secrets` |
| `ACNS_NOT_ENABLED`, `CILIUM_NOT_AVAILABLE` | tpg-day0, tpg-create-instance, tpg-network-policy | `egressToFqdns` needs ACNS: Terraform `acns_enabled = true` (or `network.acnsEnabled: true` for pre-created clusters that run it), then `--only inventory` and `--only hub-secrets`. Network policies need Azure CNI powered by Cilium |
| `FOREIGN_CRD` when tpg-day0 runs again on a cluster it deployed | tpg-day0 | An older `tpg-fleet` that judged ownership by the tracking annotation alone, which the CRDs do not carry. Pull the current `tpg-fleet`: the pre-check reads the operator Application's resource list |
| `saving parameter ... dst=/var/run/argo/outputs/parameters//tmp/result` | any workflow | Not an error and not a path to fix: the Argo executor builds that line as `/var/run/argo` + `/outputs/parameters/` + the source path, so an absolute source path always shows two slashes. The failure in that log is the line above it (`sub-process exited ... exit status 1`); read the step's own `RESULT` line and `kubectl -n argo get configmap tpg-run-<workflow> -o yaml` |
