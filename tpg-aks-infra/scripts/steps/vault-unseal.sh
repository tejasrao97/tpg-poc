#!/usr/bin/env bash
# Unseal Vault on the hub (unseal mode shamir) after vault-0 restarted: node
# drain, AKS upgrade, Helm upgrade of the vault release or a pod eviction.
# Prompts for 3 of the 5 unseal keys without echoing them. Run it with
#   scripts/run.sh --hub <mode> --targets <mode> --only vault-unseal   (or make vault-unseal)
# Workflows fail fast with VAULT_SEALED and the Vault Secrets Operator retries
# until Vault is unsealed. With vault.unsealMode azure-keyvault Vault unseals
# itself; this step then only reports the status.
source "$(dirname "$0")/../lib/common.sh"
source "$(dirname "$0")/../lib/vault.sh"

require_cmd kubectl jq yq
require_inventory
HUB="$(hub_name)"
require_context "$HUB"

ST="$(vault_status)"
[[ -n "$ST" ]] || die "Vault is not reachable in ${VAULT_NS}/${VAULT_POD} (kubectl -n vault get pod vault-0)"
[[ "$(jq -r '.initialized' <<<"$ST")" == "true" ]] || die "Vault is not initialized: run the vault step"
log "Vault on ${HUB}: seal type $(jq -r '.type' <<<"$ST"), sealed $(jq -r '.sealed' <<<"$ST")"
vault_unseal_prompt
