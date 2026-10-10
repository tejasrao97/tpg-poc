#!/usr/bin/env bash
# Validate inventory/clusters.yaml for pre-created clusters (structure only; no
# Azure or cluster calls).
source "$(dirname "$0")/../../lib/common.sh"

require_inventory
FAILED=0
fail() { warn "$*"; FAILED=1; }

[[ "$(subscription)" =~ ^[0-9a-f-]{36}$ ]] || fail "subscriptionId is not a subscription GUID"
[[ "$(inv '.adminAllowedCidrs | length')" -gt 0 ]] || fail "adminAllowedCidrs is empty"
[[ -n "$(hub_name)" && "$(hub_name)" != "null" ]] || fail "hub.name is empty"
[[ "$(inv '.targets | length')" -gt 0 ]] || fail "targets is empty"

dups="$(yq -r '([.hub] + .targets)[].name' "$INVENTORY" | sort | uniq -d)"
[[ -z "$dups" ]] || fail "duplicate cluster names: $dups"

for c in $(all_clusters); do
  access="$(cluster_field "$c" access az)"
  case "$access" in
    az) [[ -n "$(cluster_field "$c" resourceGroup)" ]] || fail "$c: resourceGroup is required for access: az" ;;
    kubeconfig)
      [[ -n "$(cluster_field "$c" kubeconfig)" && -n "$(cluster_field "$c" context)" ]] \
        || fail "$c: kubeconfig and context are required for access: kubeconfig" ;;
    *) fail "$c: access must be az or kubeconfig" ;;
  esac
done

canaries="$(yq -r '[.targets[] | select(.wave == 0)] | length' "$INVENTORY")"
[[ "$canaries" -eq 1 ]] || warn "$canaries targets have wave 0; the design uses exactly one canary"

for f in storageAccount resourceGroup; do
  [[ -n "$(inv ".backup.$f // \"\"")" ]] || fail "backup.$f is required"
done

sku="$(inv '.storage.dataDiskSku // "Premium_ZRS"')"
case "$sku" in
  StandardSSD_LRS|StandardSSD_ZRS|Premium_LRS|Premium_ZRS|PremiumV2_LRS) ;;
  *) fail "storage.dataDiskSku must be StandardSSD_LRS, StandardSSD_ZRS, Premium_LRS, Premium_ZRS or PremiumV2_LRS (got ${sku})" ;;
esac

mode="$(inv '.vault.unsealMode // ""')"
case "$mode" in
  "") fail "vault.unsealMode is required: shamir (unseal keys shown once, unseal by hand after a restart) or azure-keyvault (auto-unseal with a Key Vault key)" ;;
  shamir) ;;
  azure-keyvault)
    for f in name tenantId clientId; do
      [[ -n "$(inv ".vault.azureKeyVault.$f // \"\"")" ]] || fail "vault.azureKeyVault.$f is required for vault.unsealMode azure-keyvault"
    done ;;
  *) fail "vault.unsealMode must be shamir or azure-keyvault (got $mode)" ;;
esac
exposure="$(inv '.vault.exposure // "public"')"
case "$exposure" in
  internal) warn "vault.exposure internal: the target clusters must reach the hub node subnet (same VNet or peering)" ;;
  public)
    for c in $(target_names); do
      if [[ "$(cluster_field "$c" access az)" != "az" && -z "$(N="$c" yq -r '.targets[] | select(.name == env(N)) | .egressCidrs[]?' "$INVENTORY")" ]]; then
        fail "$c: targets[].egressCidrs is required with access kubeconfig and vault.exposure public"
      fi
    done ;;
  *) fail "vault.exposure must be internal or public (got $exposure)" ;;
esac
rw="$(inv '.monitoring.remoteWriteExposure // "public"')"
case "$rw" in
  internal) warn "monitoring.remoteWriteExposure internal: the target clusters must reach the hub node subnet for the metrics remote write" ;;
  public)
    for c in $(target_names); do
      if [[ "$(cluster_field "$c" access az)" != "az" && -z "$(N="$c" yq -r '.targets[] | select(.name == env(N)) | .egressCidrs[]?' "$INVENTORY")" ]]; then
        fail "$c: targets[].egressCidrs is required with access kubeconfig and monitoring.remoteWriteExposure public"
      fi
    done ;;
  *) fail "monitoring.remoteWriteExposure must be internal or public (got $rw)" ;;
esac

ca="$(inv '.backup.caBundleFile // ""')"
if [[ -n "$ca" ]]; then
  [[ "$ca" = /* ]] || ca="${REPO_ROOT}/${ca}"
  if [[ ! -s "$ca" ]]; then fail "backup.caBundleFile ${ca} does not exist or is empty"
  elif ! grep -q -- '-----BEGIN CERTIFICATE-----' "$ca"; then fail "backup.caBundleFile ${ca} holds no PEM certificate"; fi
fi
case "$(inv '.network.acnsEnabled // false')" in true|false) ;; *) fail "network.acnsEnabled must be true or false" ;; esac

[[ "$FAILED" -eq 0 ]] || die "inventory $INVENTORY is not valid"
ok "inventory $INVENTORY: hub $(hub_name), $(inv '.targets | length') targets"
