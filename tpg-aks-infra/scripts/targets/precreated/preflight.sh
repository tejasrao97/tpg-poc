#!/usr/bin/env bash
# Scenario: target (and optionally hub) clusters created outside this
# repository. Read-only checks with az; changes only with explicit flags:
#   FIX_AUTHORIZED_IPS=1   add the hub egress CIDRs to target authorized IP ranges
#   backup.createContainers: true in the inventory creates missing containers
#   (one per target, and backup.logsContainer for the archived workflow logs)
#   CHECK_ONLY=1           report only, even when the options above are set
source "$(dirname "$0")/../../lib/common.sh"

require_cmd az jq yq
require_inventory
FIX_AUTHORIZED_IPS="${FIX_AUTHORIZED_IPS:-0}"
CHECK_ONLY="${CHECK_ONLY:-0}"
[[ "$CHECK_ONLY" == "1" ]] && FIX_AUTHORIZED_IPS=0
SUB="$(subscription)"
FAILED=0
fail() { warn "$*"; FAILED=1; }

az account show >/dev/null 2>&1 || die "not logged in to Azure: run az login"
az account set --subscription "$SUB"
ok "subscription $SUB"

HUB="$(hub_name)"
HUB_RG="$(cluster_field "$HUB" resourceGroup)"

# ---------------------------------------------------------------- hub egress
log "Hub $HUB: egress CIDRs"
mapfile -t HUB_EGRESS < <(inv '.hub.egressCidrs[]?')
if [[ ${#HUB_EGRESS[@]} -eq 0 ]]; then
  if [[ "$(cluster_field "$HUB" access az)" == "az" ]]; then
    outbound="$(az aks show -g "$HUB_RG" -n "$HUB" --query networkProfile.outboundType -o tsv)"
    if [[ "$outbound" == "loadBalancer" ]]; then
      mapfile -t ids < <(az aks show -g "$HUB_RG" -n "$HUB" \
        --query 'networkProfile.loadBalancerProfile.effectiveOutboundIPs[].id' -o tsv)
      for id in "${ids[@]}"; do
        HUB_EGRESS+=("$(az network public-ip show --ids "$id" --query ipAddress -o tsv)/32")
      done
    else
      fail "hub outbound type is $outbound: set hub.egressCidrs in the inventory"
    fi
  else
    warn "hub access is kubeconfig and hub.egressCidrs is empty: authorized IP checks are skipped"
  fi
fi
[[ ${#HUB_EGRESS[@]} -gt 0 ]] && ok "hub egress: ${HUB_EGRESS[*]}"

# ---------------------------------------------------------------- clusters
for c in $(all_clusters); do
  rg="$(cluster_field "$c" resourceGroup)"
  access="$(cluster_field "$c" access az)"
  log "Cluster $c ($access)"
  if [[ "$access" == "kubeconfig" ]]; then
    kc="$(cluster_field "$c" kubeconfig)"; ctx="$(cluster_field "$c" context)"
    [[ -f "${kc/#\~/$HOME}" ]] || fail "$c: kubeconfig file $kc not found"
    [[ -n "$ctx" ]] || fail "$c: context is empty"
    ok "$c: kubeconfig ${kc} context ${ctx}"
    continue
  fi

  if ! json="$(az aks show -g "$rg" -n "$c" -o json 2>/dev/null)"; then
    fail "$c: cluster not found in resource group $rg"
    continue
  fi
  state="$(jq -r '.powerState.code' <<<"$json")"
  if [[ "$state" == "Running" ]]; then ok "$c: power state Running"; else fail "$c: power state $state"; fi

  if [[ "$(jq -r '.apiServerAccessProfile.enablePrivateCluster // false' <<<"$json")" == "true" ]]; then
    fail "$c: private API server; the hub and this workstation need network line of sight (not covered by these scripts)"
  fi

  if [[ "$(cluster_field "$c" adminCredentials true)" == "true" && \
        "$(jq -r '.disableLocalAccounts // false' <<<"$json")" == "true" ]]; then
    fail "$c: local accounts are disabled; set adminCredentials: false (requires kubelogin)"
  fi

  # Node pools. The 3-nodes-across-3-zones rule covers the Postgres data pool
  # only, and only for instances deployed with highAvailability=true; a User
  # pool that is smaller is reported as a warning naming that consequence.
  # System pools run no Postgres data and are only reported.
  jq -r '.agentPoolProfiles[] | [.name, .mode, (.minCount // .count), ((.availabilityZones // []) | length)] | @tsv' <<<"$json" |
    while IFS=$'\t' read -r pool mode count zones; do
      if [[ "$mode" != "User" ]]; then
        ok "$c: pool $pool ($mode) min $count nodes, $zones zones"
      elif [[ "$count" -ge 3 && "$zones" -eq 3 ]]; then
        ok "$c: pool $pool ($mode) min $count nodes, $zones zones (high availability possible)"
      else
        warn "$c: pool $pool ($mode) has min $count nodes in $zones zones: tpg-day0 refuses highAvailability=true on this cluster (PGDATA_POOL_NOT_HA_CAPABLE); single-node instances are unaffected"
      fi
    done

  # Authorized IP ranges: targets must allow the hub egress CIDRs
  [[ "$c" == "$HUB" ]] && continue
  mapfile -t ranges < <(jq -r '.apiServerAccessProfile.authorizedIpRanges // [] | .[]' <<<"$json")
  if [[ ${#ranges[@]} -eq 0 ]]; then
    ok "$c: public API server (no authorized IP ranges)"
  elif [[ ${#HUB_EGRESS[@]} -gt 0 ]]; then
    missing=()
    for e in "${HUB_EGRESS[@]}"; do
      printf '%s\n' "${ranges[@]}" | grep -qxF "$e" || missing+=("$e")
    done
    if [[ ${#missing[@]} -eq 0 ]]; then
      ok "$c: authorized IP ranges include the hub egress"
    elif [[ "$FIX_AUTHORIZED_IPS" == "1" ]]; then
      new="$(printf '%s\n' "${ranges[@]}" "${missing[@]}" | sort -u | paste -sd, -)"
      log "$c: adding ${missing[*]} to authorized IP ranges"
      az aks update -g "$rg" -n "$c" --api-server-authorized-ip-ranges "$new" --only-show-errors >/dev/null
      ok "$c: authorized IP ranges updated"
    else
      fail "$c: authorized IP ranges miss the hub egress ${missing[*]} (re-run with --fix-authorized-ips)"
    fi
  fi
done

# ---------------------------------------------------------------- Vault auto-unseal (azure-keyvault)
if [[ "$(inv '.vault.unsealMode // ""')" == "azure-keyvault" ]]; then
  KV="$(inv '.vault.azureKeyVault.name')"; KEY="$(inv '.vault.azureKeyVault.keyName // "vault-unseal"')"
  CID="$(inv '.vault.azureKeyVault.clientId')"
  log "Vault auto-unseal: Key Vault $KV, key $KEY, identity $CID"
  if [[ "$(cluster_field "$HUB" access az)" == "az" ]]; then
    hub_json="$(az aks show -g "$HUB_RG" -n "$HUB" -o json)"
    issuer="$(jq -r '.oidcIssuerProfile.issuerUrl // ""' <<<"$hub_json")"
    if [[ "$(jq -r '.oidcIssuerProfile.enabled // false' <<<"$hub_json")" == "true" && \
          "$(jq -r '.securityProfile.workloadIdentity.enabled // false' <<<"$hub_json")" == "true" ]]; then
      ok "hub $HUB: OIDC issuer and workload identity enabled"
    else
      fail "hub $HUB: enable them with: az aks update -g $HUB_RG -n $HUB --enable-oidc-issuer --enable-workload-identity"
    fi
  else
    issuer=""
    warn "hub access is kubeconfig: OIDC issuer and workload identity not checked"
  fi
  if kv_json="$(az keyvault show -n "$KV" -o json 2>/dev/null)"; then
    kv_id="$(jq -r '.id' <<<"$kv_json")"
    kv_rbac="$(jq -r '.properties.enableRbacAuthorization' <<<"$kv_json")"
    if [[ "$kv_rbac" == "true" ]]; then
      ok "$KV: Azure RBAC authorization (a role assignment grants the identity its crypto role)"
    else
      ok "$KV: access policies (no Microsoft.Authorization/roleAssignments/write needed)"
    fi
    if az keyvault key show --vault-name "$KV" -n "$KEY" -o none 2>/dev/null; then
      ok "$KV: key $KEY exists"
    else
      warn "$KV: key $KEY not readable with your identity (missing, or no data-plane access); create it with: az keyvault key create --vault-name $KV -n $KEY --kty RSA --size 2048 --ops wrapKey unwrapKey"
    fi
    if id_json="$(az identity list --query "[?clientId=='${CID}'] | [0]" -o json 2>/dev/null)" && [[ "$id_json" != "null" && -n "$id_json" ]]; then
      pid="$(jq -r '.principalId' <<<"$id_json")"; id_name="$(jq -r '.name' <<<"$id_json")"; id_rg="$(jq -r '.resourceGroup' <<<"$id_json")"
      if [[ "$kv_rbac" == "true" ]]; then
        roles="$(az role assignment list --assignee "$pid" --scope "$kv_id" --include-inherited --query '[].roleDefinitionName' -o tsv 2>/dev/null || true)"
        if grep -qE '^(Key Vault Crypto User|Key Vault Crypto Officer|Key Vault Administrator)$' <<<"$roles"; then
          ok "identity $id_name has a Key Vault crypto role on $KV"
        else
          fail "identity $id_name has no crypto role on $KV: az role assignment create --assignee-object-id $pid --assignee-principal-type ServicePrincipal --role 'Key Vault Crypto User' --scope $kv_id
     (that command needs Microsoft.Authorization/roleAssignments/write; an access-policy Key Vault avoids it)"
        fi
      else
        if az keyvault show -n "$KV" -o json \
            | jq -e --arg p "$pid" '.properties.accessPolicies[]? | select((.objectId | ascii_downcase) == ($p | ascii_downcase))
                 | select([.permissions.keys[]? | ascii_downcase] | (index("get") and index("wrapkey") and index("unwrapkey")))' >/dev/null; then
          ok "identity $id_name has an access policy on $KV with get, wrapKey and unwrapKey"
        else
          fail "identity $id_name has no usable access policy on $KV: az keyvault set-policy -n $KV --object-id $pid --key-permissions get wrapKey unwrapKey"
        fi
      fi
      if [[ -n "$issuer" ]]; then
        if az identity federated-credential list --identity-name "$id_name" -g "$id_rg" -o json \
            | jq -e --arg i "$issuer" '.[] | select(.issuer == $i and .subject == "system:serviceaccount:vault:vault")' >/dev/null; then
          ok "identity $id_name is federated to system:serviceaccount:vault:vault on the hub issuer"
        else
          fail "identity $id_name has no federated credential for the hub: az identity federated-credential create --name vault-server --identity-name $id_name -g $id_rg --issuer $issuer --subject system:serviceaccount:vault:vault --audiences api://AzureADTokenExchange"
        fi
      fi
    else
      fail "no user-assigned identity with client ID $CID in subscription $SUB"
    fi
  else
    fail "Key Vault $KV not found in subscription $SUB"
  fi
fi

# ---------------------------------------------------------------- backup storage
SA="$(inv '.backup.storageAccount')"
SA_RG="$(inv '.backup.resourceGroup')"
log "Backup storage account $SA"
if sa_json="$(az storage account show -g "$SA_RG" -n "$SA" -o json 2>/dev/null)"; then
  if [[ "$(jq -r '.allowSharedKeyAccess' <<<"$sa_json")" != "false" ]]; then
    ok "$SA: shared key access enabled"
  else
    fail "$SA: shared key access is disabled; the operator uses keyType: shared"
  fi
  # enableSSL: false (the fleet default) sends pgBackRest traffic over plain
  # HTTP, which an account with "Secure transfer required" refuses.
  # An explicit null test, not a true fallback after //: jq's // also replaces false, which read
  # "Secure transfer required: false" as true (design decision I22).
  https_only="$(jq -r 'if .enableHttpsTrafficOnly != null then .enableHttpsTrafficOnly
                       elif .supportsHttpsTrafficOnly != null then .supportsHttpsTrafficOnly
                       else true end' <<<"$sa_json")"
  if [[ "$https_only" == "true" && "$(inv '.backup.httpsOnly // false')" != "true" ]]; then
    fail "$SA requires secure transfer (HTTPS only), but the fleet default is enableSSL: false (plain HTTP). Either turn it off: az storage account update -g $SA_RG -n $SA --https-only false, or set backup.httpsOnly: true here and backup.enableSSL: true in tpg-fleet clusters/_template/cluster.yaml (or backupEnableSSL=true in tpg-day0)"
  elif [[ "$https_only" == "true" ]]; then
    ok "$SA: HTTPS only (backup.httpsOnly: true; instances must use enableSSL: true)"
  else
    ok "$SA: HTTP and HTTPS accepted (enableSSL false or true both work)"
  fi
  KEY="$(backup_key)"
  logs_container="$(inv '.backup.logsContainer // "argo-logs"')"
  for c in $(target_names) "$logs_container"; do
    if [[ "$c" == "$logs_container" ]]; then container="$c"
    else container="$(cluster_field "$c" backupContainer "pg-backups-$c")"; fi
    if [[ "$(az storage container exists --account-name "$SA" --account-key "$KEY" \
          --name "$container" --query exists -o tsv)" == "true" ]]; then
      ok "$SA/$container exists"
    elif [[ "$CHECK_ONLY" != "1" && "$(inv '.backup.createContainers // false')" == "true" ]]; then
      az storage container create --account-name "$SA" --account-key "$KEY" \
        --name "$container" --public-access off --only-show-errors >/dev/null
      ok "$SA/$container created"
    else
      fail "$SA/$container missing (set backup.createContainers: true)"
    fi
  done
else
  fail "storage account $SA not found in $SA_RG"
fi

[[ "$FAILED" -eq 0 ]] || die "preflight found problems (see WARN lines)"
log "Preflight passed"
