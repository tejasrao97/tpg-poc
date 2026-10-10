#!/usr/bin/env bash
# On the hub: HashiCorp Vault (community edition) and the Vault Secrets Operator.
#
#   1. Namespace vault, StorageClass tpg-data-retain, Services vault-fleet
#      (targets; internal or public load balancer from vault.exposure) and, with
#      --expose-ui and internal exposure, vault-ui (adminAllowedCidrs)
#   2. TLS: CA (Secret vault/vault-ca-keypair) and server certificate (Secret vault/vault-tls)
#   3. Helm release vault (server + Agent Injector), after the add-on pre-check
#   4. First run: vault operator init. Shamir: unsealed with 3 of the 5 keys from
#      memory. Later runs: unseal prompt if sealed.
#   5. KV v2 mount tpg, hub Kubernetes auth (auth/kubernetes), the userpass account
#      tpg-admin for the UI (password kept in Vault at tpg/admin/vault-ui), policies
#      (tpg-fleet vault/policies) and roles tpg-setup, tpg-workflow,
#      tpg-credential-writer (Round 15: the write step of tpg-rotate-credential), tpg-argocd.
#      Only when all of it works (the tpg-setup login is proven) are the unseal or
#      recovery keys and the root token shown, once; then the root token is
#      revoked. Ctrl+C between init and "stored" does not end the step.
#      With run.sh --save-vault-recovery-keys (Round 16) the keys go to the file
#      VAULT_RECOVERY_KEYS_FILE (mode 600) instead: nothing is shown, there is
#      no "stored" prompt and no terminal is needed (Terraform remote-exec).
#      Resume: a Vault that is initialized but refuses the tpg-setup login (a run
#      that ended after init) is finished with the initial root token or with a
#      new one generated from 3 keys (vault operator generate-root).
#   6. Helm release vault-secrets-operator on the hub, VaultConnection/VaultAuth
#      tpg-vault (role tpg-argocd, for the Argo CD repository Secrets)
#
# Inventory: vault.unsealMode (shamir | azure-keyvault), vault.exposure
# (internal | public), vault.azureKeyVault (azure-keyvault), vault.extraSourceCidrs.
# Re-run safely at any time: every step checks what exists first.
source "$(dirname "$0")/../lib/common.sh"
source "$(dirname "$0")/../lib/vault.sh"

require_cmd kubectl helm jq yq openssl
require_inventory
require_env FLEET_LOCAL_DIR
HUB="$(hub_name)"
require_context "$HUB"
ADDONS="${FLEET_LOCAL_DIR}/workflows/scripts/helm-addons.sh"
[[ -f "$ADDONS" ]] || die "$ADDONS not found: FLEET_LOCAL_DIR must point at a tpg-fleet clone"
MODE="$(vault_unseal_mode)"
EXPOSURE="$(vault_exposure)"
case "$MODE" in
  shamir|azure-keyvault) ;;
  "") die "no unseal mode set. Choose one and re-run the inventory step:
    shamir          5 unseal key shares, shown once; unseal by hand after every vault-0 restart
    azure-keyvault  auto-unseal with an Azure Key Vault key through workload identity
  Terraform: vault_unseal_mode in terraform/terraform.tfvars (required, no default).
  Pre-created clusters: vault.unsealMode in the inventory file." ;;
  *) die "vault.unsealMode must be shamir or azure-keyvault (got ${MODE})" ;;
esac
kubectl --context "$HUB" get namespace argo argocd >/dev/null \
  || die "argo and argocd namespaces not found on $HUB: run the hub step first"

RUN_START="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ---------------------------------------------------------------- 1. namespace, storage, Services
log "Vault on $HUB: unseal mode ${MODE}, exposure ${EXPOSURE}"
kubectl --context "$HUB" create namespace "$VAULT_NS" --dry-run=client -o yaml | kubectl --context "$HUB" apply -f - >/dev/null
apply_storageclass "$HUB"
ok "namespace vault, StorageClass tpg-data-retain (disk SKU $(data_disk_sku))"
vault_apply_services
mapfile -t LB_IPS < <(vault_wait_ips vault-fleet)
if [[ "$EXPOSURE" == "internal" && "${EXPOSE_UI:-0}" == "1" ]]; then
  mapfile -t -O "${#LB_IPS[@]}" LB_IPS < <(vault_wait_ips vault-ui)
fi
ok "load balancer IPs: ${LB_IPS[*]}"

# ---------------------------------------------------------------- 2. TLS
vault_tls "${LB_IPS[@]}"
ok "Secrets vault/vault-tls and argo/vault-ca (CA copy: ${VAULT_CA_LOCAL})"

# ---------------------------------------------------------------- 3. Helm release vault
export VAULT_UNSEAL_MODE="$MODE"
if [[ "$MODE" == "azure-keyvault" ]]; then
  export VAULT_AKV_NAME VAULT_AKV_KEY_NAME VAULT_AKV_TENANT_ID VAULT_AKV_CLIENT_ID
  VAULT_AKV_NAME="$(inv '.vault.azureKeyVault.name // ""')"
  VAULT_AKV_KEY_NAME="$(inv '.vault.azureKeyVault.keyName // "vault-unseal"')"
  VAULT_AKV_TENANT_ID="$(inv '.vault.azureKeyVault.tenantId // ""')"
  VAULT_AKV_CLIENT_ID="$(inv '.vault.azureKeyVault.clientId // ""')"
  for v in VAULT_AKV_NAME VAULT_AKV_TENANT_ID VAULT_AKV_CLIENT_ID; do
    [[ -n "${!v}" ]] || die "vault.azureKeyVault is incomplete in the inventory (${v} empty)"
  done
fi
log "Helm release vault/vault (pre-check first)"
bash "$ADDONS" --cluster "$HUB" --role hub --components vault --context "$HUB" \
  --fleet-dir "$FLEET_LOCAL_DIR" ${ADDONS_EXISTING:+--existing "$ADDONS_EXISTING"} \
  || die "the vault release was not installed (see the ADDON line above)"

vault_wait_pod
if [[ "$VAULT_TLS_CHANGED" == "1" ]]; then
  # A pod that started before this run still serves the previous certificate.
  created="$(kubectl --context "$HUB" -n "$VAULT_NS" get pod "$VAULT_POD" -o jsonpath='{.metadata.creationTimestamp}')"
  if [[ "$created" < "$RUN_START" ]]; then
    log "The server certificate changed: restarting vault-0 to load it"
    kubectl --context "$HUB" -n "$VAULT_NS" delete pod "$VAULT_POD" --wait=true >/dev/null
    vault_wait_pod
  fi
fi

# ---------------------------------------------------------------- 4. init / unseal
# The unseal (shamir) or recovery (azure-keyvault) keys and the initial root
# token exist only in this shell's memory. Everything that uses the root token
# (step 5) runs BEFORE they are shown, so an interrupted run can no longer leave
# an initialized but unconfigured Vault behind. From "vault operator init" until
# the operator confirms that the keys are stored:
#   - Ctrl+C (INT), TERM and HUP do not end the script: the keys are shown and
#     the prompt asks again;
#   - if the script ends anyway (an error in step 5), the keys are shown on the
#     terminal before it exits, and the next run resumes with the root token.
ST="$(vault_status)"
ROOT_TOKEN=""
INIT=""
KEYS_SHOWN=0
KEYS_FIELD=""
KEYS_NAME=""
SAVE_KEYS="${SAVE_VAULT_RECOVERY_KEYS:-0}"
KEYS_FILE="${VAULT_RECOVERY_KEYS_FILE:-${HOME}/.tpg/vault-keys.txt}"
exec 9>&2   # stderr for the exit handler below

vault_keys_target() {
  # The file the keys go to: KEYS_FILE, or KEYS_FILE.<UTC time> when it exists
  # (an older file may hold the only copy of the keys of a live Vault).
  if [[ -e "$KEYS_FILE" ]]; then
    local base t n=1
    base="${KEYS_FILE}.$(date -u +%Y%m%dT%H%M%SZ)"
    t="$base"
    # a numbered name when that copy exists too (two inits in one second)
    while [[ -e "$t" ]]; do t="${base}.${n}"; n=$((n + 1)); done
    printf '%s' "$t"
  else
    printf '%s' "$KEYS_FILE"
  fi
}

vault_save_keys() {
  # --save-vault-recovery-keys: write the 5 key shares (never the root token) to
  # a new file, mode 600, in a directory of mode 700. Prints only the path.
  [[ -n "$INIT" && "$KEYS_SHOWN" -eq 0 ]] || return 0
  local dir target tmp
  dir="$(dirname "$KEYS_FILE")"
  ( umask 077; mkdir -p "$dir" ) || return 1
  chmod 700 "$dir" || return 1
  target="$(vault_keys_target)"
  [[ ! -e "$target" ]] || return 1
  tmp="$(mktemp "${dir}/.vault-keys.XXXXXX")" || return 1
  chmod 600 "$tmp"
  if ! {
    printf '# %s of Vault on %s (unseal mode %s), written %s by scripts/run.sh --save-vault-recovery-keys\n' \
      "$KEYS_NAME" "$HUB" "$MODE" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '# 5 shares, any 3 %s. The initial root token is not stored: it is revoked.\n' \
      "$( [[ "$MODE" == shamir ]] && echo "unseal Vault" || echo "authorize root token generation and seal migration")"
    printf '# Copy this file to a password manager or split the keys between people, then delete it.\n'
    jq -r --arg f "$KEYS_FIELD" '.[$f] | to_entries[] | "Key \(.key + 1): \(.value)"' <<<"$INIT"
  } > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  # ln + rm instead of mv: never replaces a file that appeared in the meantime
  if ! ln "$tmp" "$target" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  rm -f "$tmp"
  KEYS_SHOWN=1
  ok "${KEYS_NAME} saved to ${target} (mode 600; the root token is not in it). Copy the file off this machine and delete it."
}

vault_keys_precheck() {
  # Before vault operator init: the directory of KEYS_FILE can be created and
  # written to, so the keys are not lost after init.
  local dir probe
  dir="$(dirname "$KEYS_FILE")"
  ( umask 077; mkdir -p "$dir" ) 2>/dev/null \
    || die "--save-vault-recovery-keys: cannot create ${dir} (VAULT_RECOVERY_KEYS_FILE=${KEYS_FILE})"
  probe="$(mktemp "${dir}/.vault-keys.XXXXXX" 2>/dev/null)" \
    || die "--save-vault-recovery-keys: ${dir} is not writable (VAULT_RECOVERY_KEYS_FILE=${KEYS_FILE})"
  rm -f "$probe"
  [[ -e "$KEYS_FILE" ]] && warn "${KEYS_FILE} exists and is kept: the keys of this init go to a copy with a UTC timestamp suffix"
  return 0
}

vault_show_keys() {
  # --save-vault-recovery-keys: write the file instead. If that fails (it was
  # checked before init, so only a full disk or a permission change gets here),
  # fall back to the screen when a terminal is attached; without one, stop
  # before the root token is revoked, with the keys in no file and on no screen.
  if [[ "$SAVE_KEYS" == "1" ]]; then
    vault_save_keys && return 0
    [[ -n "$INIT" && "$KEYS_SHOWN" -eq 0 ]] || return 0
    if ! { : > /dev/tty; } 2>/dev/null; then
      KEYS_SHOWN=1   # the exit handler must not try again
      die "could not write the keys to ${KEYS_FILE} or a timestamped copy, and no terminal is attached to show them. This Vault cannot be unsealed again once vault-0 restarts: uninstall the vault release, delete its PersistentVolumeClaim data-vault-0, fix VAULT_RECOVERY_KEYS_FILE and re-run scripts/run.sh ... --only vault --save-vault-recovery-keys"
    fi
    warn "could not write the keys to ${KEYS_FILE}: showing them on the terminal instead"
  fi
  # Show the keys and the root token once, wait for "stored", clear the screen.
  [[ -n "$INIT" && "$KEYS_SHOWN" -eq 0 ]] || return 0
  KEYS_SHOWN=1
  {
    printf '\n\033[1;31m%s\033[0m\n' "=================== SHOWN ONCE: STORE THESE NOW ==================="
    printf '%s (5 shares, any 3 %s):\n' "$KEYS_NAME" "$( [[ "$MODE" == shamir ]] && echo "unseal Vault" || echo "authorize root token generation and seal migration")"
    jq -r --arg f "$KEYS_FIELD" '.[$f] | to_entries[] | "  Key \(.key + 1): \(.value)"' <<<"$INIT"
    if [[ -n "$ROOT_TOKEN" ]]; then
      printf 'Initial root token (revoked at the end of this step; generate a new one with vault operator generate-root and 3 keys):\n  %s\n' "$ROOT_TOKEN"
    fi
    printf '\033[1;31m%s\033[0m\n' "==================================================================="
    printf 'Store the keys in a password manager or split them between people. They are not written to any file.\n'
  } > /dev/tty
  local answer=""
  until [[ "$answer" == "stored" ]]; do
    answer=""
    read -r -p "Type 'stored' once the keys are saved: " answer < /dev/tty || true
  done
  printf '\033[2J\033[H' > /dev/tty   # clear the screen
}

vault_on_signal() {
  # Ctrl+C, TERM or HUP between init and the confirmation: keep going.
  if [[ "$SAVE_KEYS" == "1" ]]; then
    warn "signal ignored: the vault step continues until the keys are saved to ${KEYS_FILE}"
  else
    printf '\n\033[1;33m%s\033[0m\n' "The keys are shown only once and are not stored anywhere else: this step does not stop here. Save them and type 'stored'." > /dev/tty
  fi
}

vault_keys_on_exit() {
  # The script ends before the keys were shown (an error in step 5): show them
  # now, or with --save-vault-recovery-keys write them to the file.
  if [[ -n "$INIT" && "$KEYS_SHOWN" -eq 0 ]]; then
    if [[ "$SAVE_KEYS" == "1" ]]; then
      # cleanup_add handlers run with their output discarded: use the saved stderr (fd 9)
      {
        printf '\n%s\n' "The vault step failed after vault operator init. The keys are written to ${KEYS_FILE} (or a timestamped copy); re-run scripts/run.sh ... --only vault afterwards from a terminal: it generates a new root token from 3 of them."
        vault_show_keys
      } >&9 2>&9
    else
      printf '\n\033[1;31m%s\033[0m\n' "The vault step failed after vault operator init. The keys below are the only copy; re-run scripts/run.sh ... --only vault afterwards: it resumes with the root token." > /dev/tty
      vault_show_keys
    fi
  fi
}

if [[ "$(jq -r '.initialized' <<<"$ST")" != "true" ]]; then
  if [[ "$SAVE_KEYS" == "1" ]]; then
    vault_keys_precheck
  else
    [[ -t 0 && -t 1 ]] || die "Vault is not initialized. Run this step from an interactive terminal (the unseal keys are shown only once), or pass --save-vault-recovery-keys to write them to VAULT_RECOVERY_KEYS_FILE."
  fi
  log "Initializing Vault (${MODE})"
  trap vault_on_signal INT TERM HUP
  cleanup_add vault_keys_on_exit
  if [[ "$MODE" == "shamir" ]]; then
    INIT="$(vx operator init -key-shares=5 -key-threshold=3 -format=json </dev/null)" || die "vault operator init failed"
    KEYS_FIELD="unseal_keys_b64"; KEYS_NAME="Unseal keys"
  else
    INIT="$(vx operator init -recovery-shares=5 -recovery-threshold=3 -format=json </dev/null)" || die "vault operator init failed"
    KEYS_FIELD="recovery_keys_b64"; KEYS_NAME="Recovery keys"
  fi
  ROOT_TOKEN="$(jq -r '.root_token' <<<"$INIT")"
  if [[ "$MODE" == "shamir" ]]; then
    log "Unsealing with 3 of the 5 key shares (from memory, not from a file)"
    for i in 0 1 2; do
      jq -j --argjson i "$i" '.unseal_keys_b64[$i]' <<<"$INIT" | vx write -format=json sys/unseal key=- >/dev/null \
        || die "unseal with key $((i + 1)) failed"
    done
  fi
fi

ST="$(vault_status)"
if [[ "$(jq -r '.sealed' <<<"$ST")" == "true" ]]; then
  if [[ "$MODE" == "shamir" ]]; then
    vault_unseal_prompt
  else
    for _ in $(seq 1 30); do
      ST="$(vault_status)"; [[ "$(jq -r '.sealed' <<<"$ST")" == "false" ]] && break
      sleep 10
    done
    [[ "$(jq -r '.sealed' <<<"$ST")" == "false" ]] \
      || die "Vault did not auto-unseal with Azure Key Vault: check kubectl -n vault logs vault-0 (workload identity, the Key Vault access policy with get, wrapKey and unwrapKey, key ${VAULT_AKV_KEY_NAME:-})"
  fi
fi
ST="$(vault_status)"
[[ "$(jq -r '.sealed' <<<"$ST")" == "false" ]] || die "Vault is still sealed"
ok "Vault initialized and unsealed (seal type $(jq -r '.type' <<<"$ST"), version $(jq -r '.version' <<<"$ST"))"
# Second half of the pod watch (the first half ran during the Helm release, where
# vault-0 only had to start): unsealed, vault-0 must now become Ready
vk() { kubectl --context "$HUB" "$@"; }
pods_watch "$VAULT_NS" 300 --kubectl vk --selector "app.kubernetes.io/name=vault,component=server" \
  --label "vault-0 Ready after unseal" \
  || die "vault-0 is not Ready after the unseal: ${POD_WATCH_REASON:-POD_TIMEOUT} ${POD_WATCH_DETAIL}"

# ---------------------------------------------------------------- 5. configuration
kubectl --context "$HUB" -n "$VAULT_NS" create serviceaccount tpg-setup --dry-run=client -o yaml \
  | kubectl --context "$HUB" apply -f - >/dev/null
for ns in argocd argo; do
  # argocd: repository Secrets; argo: the key of the archived workflow logs
  kubectl --context "$HUB" -n "$ns" create serviceaccount tpg-vso --dry-run=client -o yaml \
    | kubectl --context "$HUB" apply -f - >/dev/null
done
if [[ -n "$ROOT_TOKEN" ]]; then
  VAULT_ADMIN_TOKEN="$ROOT_TOKEN"
elif ! vault_login try; then
  # Initialized and unsealed, but the Kubernetes login is refused: an earlier run
  # ended between "vault operator init" and the end of this step (for example
  # Ctrl+C at the "stored" prompt in a version without the protection above).
  # Resume with a root token: the initial one, or a new one from the keys.
  vault_resume_root_token
  ROOT_TOKEN="$VAULT_ADMIN_TOKEN"
fi

log "Configuring Vault: KV mount tpg, auth/kubernetes, policies and roles"
if ! vt secrets list -format=json </dev/null | jq -e 'has("tpg/")' >/dev/null; then
  vt secrets enable -path=tpg -version=2 -description="tpg fleet credentials" kv </dev/null >/dev/null \
    || die "could not enable the tpg KV mount"
fi
if ! vt auth list -format=json </dev/null | jq -e 'has("kubernetes/")' >/dev/null; then
  vt auth enable -description="hub (vault-0 reviews tokens with its own ServiceAccount)" kubernetes </dev/null >/dev/null \
    || die "could not enable auth/kubernetes"
fi
jq -cn '{kubernetes_host: "https://kubernetes.default.svc:443"}' | vt write auth/kubernetes/config - >/dev/null \
  || die "could not configure auth/kubernetes"
for f in "${FLEET_LOCAL_DIR}"/vault/policies/*.hcl; do
  name="$(basename "$f" .hcl)"
  vt policy write "$name" - < "$f" >/dev/null || die "could not write policy ${name}"
done
role() {  # role NAME SA_NAMESPACES(comma-separated) SA_NAME POLICY TTL [AUDIENCE]
  jq -cn --arg ns "$2" --arg sa "$3" --arg p "$4" --arg ttl "$5" --arg aud "${6:-}" \
    '{bound_service_account_names: [$sa], bound_service_account_namespaces: ($ns | split(",")),
      token_policies: [$p], token_ttl: $ttl, token_max_ttl: "4h"}
     | if $aud != "" then .audience = $aud else . end' \
    | vt write "auth/kubernetes/role/$1" - >/dev/null || die "could not write auth/kubernetes/role/$1"
}
role tpg-setup vault tpg-setup tpg-admin 30m
role tpg-workflow argo tpg-workflow tpg-workflow 1h
# the write step of tpg-rotate-credential (Round 15): 15 minutes are enough
role tpg-credential-writer argo tpg-credential-writer tpg-credential-writer 15m
role tpg-argocd argocd,argo tpg-vso tpg-argocd 1h vault
vault_admin_user >/dev/null
ok "userpass account tpg-admin for the Vault UI (password in Vault: tpg/admin/vault-ui; print it with scripts/run.sh --only access)"
ok "tpg KV v2, auth/kubernetes, policies $(basename -a "${FLEET_LOCAL_DIR}"/vault/policies/*.hcl | sed 's/\.hcl$//' | paste -sd, -), roles tpg-setup, tpg-workflow, tpg-credential-writer, tpg-argocd"

if [[ -n "$ROOT_TOKEN" ]]; then
  # Prove that the Kubernetes auth role works before the root token goes away:
  # drop it from this shell, so vault_login gets a fresh tpg-setup token.
  # (shellcheck does not see the use in scripts/lib/vault.sh.)
  # shellcheck disable=SC2034
  VAULT_ADMIN_TOKEN=""
  unset VAULT_TOKEN
  vault_login
  ok "login with role tpg-setup works"
  # Only now, with Vault fully configured, are the keys shown (first run only).
  vault_show_keys
  trap - INT TERM HUP
  VAULT_ADMIN_TOKEN="$ROOT_TOKEN" vt token revoke -self </dev/null >/dev/null || die "could not revoke the root token"
  ROOT_TOKEN=""
  INIT=""
  ok "root token revoked"
fi

# ---------------------------------------------------------------- 6. Vault Secrets Operator on the hub
log "Helm release vault-secrets-operator on $HUB (pre-check first)"
bash "$ADDONS" --cluster "$HUB" --role hub --components vso --context "$HUB" \
  --fleet-dir "$FLEET_LOCAL_DIR" ${ADDONS_EXISTING:+--existing "$ADDONS_EXISTING"} \
  --vault-addr "$VAULT_INCLUSTER_ADDR" --vault-ca-file "$VAULT_CA_LOCAL" \
  --vault-auth-mount kubernetes --vault-auth-role tpg-argocd \
  || die "the vault-secrets-operator release was not installed (see the ADDON line above)"

# tpg-settings exists after the hub-secrets step; keep its Vault keys current on re-runs
if kubectl --context "$HUB" -n argo get configmap tpg-settings >/dev/null 2>&1; then
  kubectl --context "$HUB" -n argo patch configmap tpg-settings --type merge \
    -p "$(jq -cn --arg a "$VAULT_INCLUSTER_ADDR" --arg f "$(vault_fleet_addr)" '{data: {vaultAddr: $a, vaultFleetAddr: $f}}')" >/dev/null
fi

log "Vault summary"
echo "  in-cluster address  ${VAULT_INCLUSTER_ADDR}"
echo "  targets address     $(vault_fleet_addr)  (vault.exposure ${EXPOSURE})"
if [[ "${EXPOSE_UI:-0}" == "1" ]]; then
  if [[ "$EXPOSURE" == "internal" ]]; then
    echo "  UI                  https://$(kubectl --context "$HUB" -n vault get svc vault-ui -o jsonpath='{.status.loadBalancer.ingress[0].ip}'):8200/ui"
  else
    echo "  UI                  $(vault_fleet_addr)/ui"
  fi
else
  echo "  UI                  kubectl -n vault port-forward svc/vault 8200:8200, then https://localhost:8200/ui (or re-run with --expose-ui)"
fi
echo "  CA certificate      ${VAULT_CA_LOCAL}"
echo "  unseal mode         ${MODE}$( [[ "$MODE" == shamir ]] && echo ": after every vault-0 restart run scripts/run.sh ... --only vault-unseal")"
