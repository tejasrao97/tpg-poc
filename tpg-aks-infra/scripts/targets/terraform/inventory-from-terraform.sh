#!/usr/bin/env bash
# Scenario: clusters created by the Terraform in this repository.
# Writes .work/inventory.yaml from the Terraform outputs, so every later step
# works the same way for Terraform-created and pre-created clusters.
#
# INVENTORY_PREBUILT=true (the jumpbox; Round 16): Terraform rendered the same
# inventory from its outputs and uploaded it with the CA bundle, so no
# terraform output is read here (the jumpbox has no state). The file is only
# checked. backup.keySource is az there: the jumpbox identity is Contributor
# on the resource group.
source "$(dirname "$0")/../../lib/common.sh"

OUT="${INVENTORY}"
if [[ "${INVENTORY_PREBUILT:-false}" == "true" ]]; then
  require_cmd yq
  log "INVENTORY_PREBUILT=true: using the inventory Terraform wrote, ${OUT}"
  [[ -s "$OUT" ]] || die "${OUT} not found: Terraform uploads it to the jumpbox (terraform_data.jumpbox_setup); re-run terraform apply"
  [[ -s "${WORK_DIR}/backup-ca-bundle.pem" ]] || die "${WORK_DIR}/backup-ca-bundle.pem not found: Terraform uploads it with the inventory; re-run terraform apply"
  for f in .subscriptionId .hub.name .backup.storageAccount; do
    [[ -n "$(yq -r "$f // \"\"" "$OUT")" ]] || die "${OUT}: ${f} is empty"
  done
  [[ "$(yq -r '.targets | length' "$OUT")" -gt 0 ]] || die "${OUT}: no targets"
  chmod 600 "${OUT}"
  ok "inventory ${OUT} (written by Terraform)"
  yq '.hub.name, .targets[].name' "${OUT}" | sed 's/^/     /'
  exit 0
fi

require_cmd jq yq "${TF_BIN}"

log "Reading Terraform outputs from ${TF_DIR}"
tf_json resource_group_name >/dev/null 2>&1 \
  || die "no Terraform outputs in ${TF_DIR}: run terraform apply first"

"${TF_BIN}" -chdir="${TF_DIR}" output -json \
  | jq '. as $o | {
      subscriptionId: .subscription_id.value,
      adminAllowedCidrs: .admin_allowed_cidrs.value,
      source: "terraform",
      hub: {
        name: .hub_cluster_name.value,
        resourceGroup: .resource_group_name.value,
        access: "az",
        adminCredentials: true,
        kubeconfig: "",
        context: "",
        egressCidrs: (if .hub_egress_ip.value then [.hub_egress_ip.value + "/32"] else [] end)
      },
      targets: [ .target_cluster_names.value[] as $t | {
        name: $t,
        resourceGroup: $o.resource_group_name.value,
        wave: $o.target_cluster_waves.value[$t],
        access: "az",
        adminCredentials: true,
        kubeconfig: "",
        context: "",
        backupContainer: $o.backup_containers.value[$t]
      } ],
      backup: {
        storageAccount: .backup_storage_account_name.value,
        resourceGroup: .resource_group_name.value,
        createContainers: false,
        keySource: "terraform",
        logsContainer: (.argo_logs_container.value // "argo-logs"),
        httpsOnly: (if .backup_storage_https_only.value == null then false else .backup_storage_https_only.value end),
        caBundleFile: ".work/backup-ca-bundle.pem"
      },
      network: {
        acnsEnabled: (if .acns_enabled.value == null then false else .acns_enabled.value end)
      },
      monitoring: {
        # byo: every cluster is in vnet-tpgpoc, so an internal load balancer works
        remoteWriteExposure: (if .network_mode.value == "byo" then "internal" else "public" end),
        extraSourceCidrs: [],
        azureMonitorWorkspaceId: (.azure_monitor_workspace_id.value // ""),
        grafanaResourceGroup: (if .grafana_name.value then .resource_group_name.value else "" end),
        grafanaName: (.grafana_name.value // "")
      },
      storage: {
        dataDiskSku: (.postgres_data_disk_sku.value // "Premium_ZRS")
      },
      nodePools: (.node_pool_zones.value // {}),
      vault: ({
        unsealMode: (.vault_unseal_mode.value // ""),
        # byo: the hub and targets share vnet-tpgpoc, so an internal load balancer works
        exposure: (if .network_mode.value == "byo" then "internal" else "public" end),
        extraSourceCidrs: []
      } + (if .vault_azure_key_vault.value then {azureKeyVault: {
        name: .vault_azure_key_vault.value.name,
        keyName: .vault_azure_key_vault.value.key_name,
        tenantId: .vault_azure_key_vault.value.tenant_id,
        clientId: .vault_azure_key_vault.value.client_id
      }} else {} end))
    }' | yq -P '.' > "${OUT}.tmp"
mv "${OUT}.tmp" "${OUT}"
# The CA bundle of the backup storage account (Terraform checked the blob endpoint against it)
"${TF_BIN}" -chdir="${TF_DIR}" output -raw backup_storage_ca_bundle > "${WORK_DIR}/backup-ca-bundle.pem" \
  || die "Terraform output backup_storage_ca_bundle is missing: run terraform apply with this version of the repository"
chmod 600 "${OUT}"
ok "inventory written to ${OUT}"
yq '.hub.name, .targets[].name' "${OUT}" | sed 's/^/     /'
