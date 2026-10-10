#!/usr/bin/env bash
# HashiCorp Vault helpers for the hub. Source after common.sh.
#
# Every Vault command runs inside the vault-0 pod with kubectl exec, so the
# workstation needs no vault CLI and no network path to Vault. Tokens and secret
# values reach the pod on stdin, never in command-line arguments or files.
# shellcheck disable=SC2034

VAULT_NS="vault"
VAULT_POD="vault-0"
VAULT_INCLUSTER_ADDR="https://vault.vault.svc:8200"
VAULT_CA_LOCAL="${WORK_DIR}/vault-ca.crt"   # public CA certificate (not a secret)

# No default: the deployment states the choice (Terraform vault_unseal_mode, or
# vault.unsealMode in the inventory of pre-created clusters).
vault_unseal_mode() { inv '.vault.unsealMode // ""'; }
vault_exposure()    { inv '.vault.exposure // "public"'; }

# vx ARGS...: vault CLI in vault-0 without a token (status, init, unseal)
vx() { kubectl --context "$HUB" -n "$VAULT_NS" exec -i "$VAULT_POD" -c vault -- vault "$@"; }

# vt ARGS...: vault CLI in vault-0 with VAULT_ADMIN_TOKEN. The token is the first
# line on stdin; the rest of stdin (JSON bodies, policy files) is passed to vault.
vt() {
  [[ -n "${VAULT_ADMIN_TOKEN:-}" ]] || die "internal: no Vault token (vault_login first)"
  { printf '%s\n' "$VAULT_ADMIN_TOKEN"; cat; } \
    | kubectl --context "$HUB" -n "$VAULT_NS" exec -i "$VAULT_POD" -c vault -- \
        sh -c 'IFS= read -r VAULT_TOKEN; export VAULT_TOKEN; exec vault "$@"' vault "$@"
}

vault_status() {
  # vault status exits 2 when sealed but still prints the JSON
  vx status -format=json 2>/dev/null </dev/null || true
}

vault_wait_pod() {
  local phase="" _
  for _ in $(seq 1 60); do
    phase="$(kubectl --context "$HUB" -n "$VAULT_NS" get pod "$VAULT_POD" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    if [[ "$phase" == "Running" ]] && [[ -n "$(vault_status)" ]]; then return 0; fi
    sleep 10
  done
  die "pod ${VAULT_NS}/${VAULT_POD} is not running after 10 minutes (phase: ${phase:-none}); check: kubectl -n vault describe pod vault-0"
}

# vault_unseal_prompt: ask for Shamir key shares (not echoed) until Vault is unsealed
vault_unseal_prompt() {
  local st key progress threshold
  st="$(vault_status)"
  [[ "$(jq -r '.sealed' <<<"$st")" == "true" ]] || { ok "Vault is unsealed"; return 0; }
  [[ "$(jq -r '.type' <<<"$st")" == "shamir" ]] \
    || die "Vault is sealed but its seal type is $(jq -r '.type' <<<"$st"): auto-unseal failed; check kubectl -n vault logs vault-0"
  threshold="$(jq -r '.t' <<<"$st")"
  [[ -t 0 ]] || die "Vault is sealed: run scripts/run.sh --only vault-unseal from a terminal and enter ${threshold} unseal keys"
  log "Vault is sealed: enter ${threshold} of the unseal keys (input is hidden)"
  while [[ "$(jq -r '.sealed' <<<"$st")" == "true" ]]; do
    progress="$(jq -r '.progress' <<<"$st")"
    read -r -s -p "Unseal key $((progress + 1)) of ${threshold}: " key; echo
    [[ -n "$key" ]] || continue
    if ! printf '%s' "$key" | vx write -format=json sys/unseal key=- >/dev/null; then
      warn "the key was rejected; try another key"
    fi
    key=""
    st="$(vault_status)"
  done
  ok "Vault unsealed"
}

# vault_login [try]: VAULT_ADMIN_TOKEN from VAULT_TOKEN, or a 30-minute tpg-admin
# token from the Kubernetes auth role tpg-setup (ServiceAccount vault/tpg-setup).
# With "try" it returns 1 instead of exiting when the login is refused.
vault_login() {
  local mode="${1:-}" jwt st out
  if [[ -n "${VAULT_ADMIN_TOKEN:-}" ]]; then return 0; fi
  if [[ -n "${VAULT_TOKEN:-}" ]]; then
    VAULT_ADMIN_TOKEN="$VAULT_TOKEN"
    vt token lookup -format=json </dev/null >/dev/null || die "VAULT_TOKEN is not a valid Vault token"
    return 0
  fi
  jwt="$(kubectl --context "$HUB" -n "$VAULT_NS" create token tpg-setup --duration=10m 2>/dev/null)" \
    || { [[ "$mode" == try ]] && return 1; die "cannot create a token for ServiceAccount vault/tpg-setup: run the vault step first"; }
  if out="$(printf '%s' "$jwt" | vx write -field=token auth/kubernetes/login role=tpg-setup jwt=- 2>&1)" && [[ -n "$out" ]]; then
    VAULT_ADMIN_TOKEN="$out"
    return 0
  fi
  [[ "$mode" == try ]] && return 1
  st="$(vault_status)"
  if [[ -z "$st" ]]; then
    die "Vault login with role tpg-setup failed: vault-0 does not answer (kubectl -n vault get pods)"
  elif [[ "$(jq -r '.sealed' <<<"$st")" == "true" ]]; then
    die "Vault login with role tpg-setup failed: Vault is sealed. Unseal it with scripts/run.sh ... --only vault-unseal"
  fi
  die "Vault login with role tpg-setup failed although Vault is unsealed: $(tr '\n' ' ' <<<"$out")
  auth/kubernetes or the role tpg-setup is not configured. This happens when a vault step ended after
  'vault operator init' and before its configuration finished. Run scripts/run.sh ... --only vault:
  it asks for the initial root token (or generates a new one from 3 keys) and finishes the configuration."
}

# vault_resume_root_token: VAULT_ADMIN_TOKEN = a root token for finishing the
# configuration of an initialized Vault that refuses the tpg-setup login. Asks
# for the initial root token (hidden input); an empty answer generates a new root
# token with vault operator generate-root and 3 unseal keys (shamir) or recovery
# keys (azure-keyvault), entered one at a time. The caller revokes the token.
vault_resume_root_token() {
  local tok st t nonce otp key progress enc out
  [[ -t 0 ]] || die "Vault is initialized but not configured (the tpg-setup login is refused). Run scripts/run.sh ... --only vault from a terminal: it asks for the initial root token"
  warn "Vault is initialized and unsealed, but the tpg-setup login is refused: the configuration of an earlier run did not finish"
  read -r -s -p "Initial root token (hidden; press Enter to generate a new root token from 3 keys instead): " tok; echo
  if [[ -n "$tok" ]]; then
    VAULT_ADMIN_TOKEN="$tok"; tok=""
    vt token lookup -format=json </dev/null >/dev/null || die "that root token is not valid (revoked, or mistyped)"
    ok "root token accepted"
    return 0
  fi
  st="$(vault_status)"
  # vault status reports the threshold of the unseal keys (shamir) or of the
  # recovery keys (auto-unseal) as t
  t="$(jq -r '.t // empty' <<<"$st" 2>/dev/null)"
  [[ "$t" =~ ^[0-9]+$ ]] || t=3
  vx operator generate-root -cancel >/dev/null 2>&1 </dev/null || true
  out="$(vx operator generate-root -init -format=json </dev/null)" || die "vault operator generate-root -init failed"
  nonce="$(jq -r '.nonce' <<<"$out")"; otp="$(jq -r '.otp // empty' <<<"$out")"
  [[ -n "$nonce" && -n "$otp" ]] || die "vault operator generate-root -init returned no nonce or OTP"
  log "Generating a root token: enter ${t} $( [[ "$(jq -r '.type' <<<"$st")" == shamir ]] && echo unseal || echo recovery) keys (input is hidden)"
  progress=0; enc=""
  while [[ -z "$enc" ]]; do
    read -r -s -p "Key $((progress + 1)) of ${t}: " key; echo
    [[ -n "$key" ]] || continue
    if ! out="$(printf '%s' "$key" | vx write -format=json sys/generate-root/update nonce="$nonce" key=- 2>&1)"; then
      warn "the key was rejected: $(tr '\n' ' ' <<<"$out")"; key=""; continue
    fi
    key=""
    progress="$(jq -r '.progress // 0' <<<"$out")"
    enc="$(jq -r '.encoded_token // .encoded_root_token // empty' <<<"$out")"
  done
  VAULT_ADMIN_TOKEN="$(vx operator generate-root -decode="$enc" -otp="$otp" </dev/null)" \
    || die "could not decode the generated root token"
  otp=""; enc=""
  ok "new root token generated (revoked at the end of this step)"
}

vault_require_unsealed() {
  local st
  st="$(vault_status)"
  [[ -n "$st" ]] || die "Vault is not reachable in ${VAULT_NS}/${VAULT_POD}: run the vault step first"
  [[ "$(jq -r '.initialized' <<<"$st")" == "true" ]] || die "Vault is not initialized: run the vault step first"
  [[ "$(jq -r '.sealed' <<<"$st")" == "false" ]] \
    || die "Vault is sealed: run scripts/run.sh --hub <mode> --targets <mode> --only vault-unseal"
}

# vault_kv_put PATH JSON: write one secret under the tpg KV v2 mount (JSON on stdin)
vault_kv_put() {
  printf '%s' "$2" | vt kv put -mount=tpg "$1" - >/dev/null || die "could not write tpg/$1 to Vault"
}

vault_kv_exists() { vt kv metadata get -mount=tpg -format=json "$1" </dev/null >/dev/null 2>&1; }

vault_kv_get() {
  # vault_kv_get PATH FIELD -> value of one field of a tpg KV v2 secret
  vt kv get -mount=tpg -field="$2" "$1" </dev/null 2>/dev/null || true
}

# vault_admin_user [rotate]: userpass account tpg-admin for the Vault UI. The
# password is generated once and kept in Vault itself (tpg/admin/vault-ui, only
# readable with the tpg-admin policy), never in a file. "rotate" sets a new one.
vault_admin_user() {
  local rotate="${1:-}" pw
  if ! vt auth list -format=json </dev/null | jq -e 'has("userpass/")' >/dev/null; then
    vt auth enable -description="Vault UI logins" userpass </dev/null >/dev/null \
      || die "could not enable auth/userpass"
  fi
  pw="$(vault_kv_get admin/vault-ui password)"
  if [[ -z "$pw" || "$rotate" == "rotate" ]]; then
    pw="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24 || true)"
    [[ "${#pw}" -ge 12 ]] || die "could not generate a Vault UI password"
    P="$pw" jq -cn '{password: env.P, token_policies: "tpg-admin"}' \
      | vt write auth/userpass/users/tpg-admin - >/dev/null || die "could not create the userpass user tpg-admin"
    vault_kv_put admin/vault-ui "$(P="$pw" jq -cn '{username: "tpg-admin", password: env.P}')"
  fi
  printf '%s' "$pw"
}

# vault_configure_target CLUSTER SERVER CA_PEM REVIEWER_JWT: Kubernetes auth mount
# auth/k8s-<cluster> for the Vault Secrets Operator on that target (role tpg-vso).
vault_configure_target() {
  local c="$1" server="$2" ca="$3" jwt="$4" mount="k8s-$1"
  if ! vt auth list -format=json </dev/null | jq -e --arg m "${mount}/" 'has($m)' >/dev/null; then
    vt auth enable -path="$mount" -description="tpg target ${c}" kubernetes </dev/null >/dev/null \
      || die "could not enable auth/${mount}"
  fi
  H="$server" CA="$ca" J="$jwt" jq -cn \
    '{kubernetes_host: env.H, kubernetes_ca_cert: env.CA, token_reviewer_jwt: env.J, disable_local_ca_jwt: true}' \
    | vt write "auth/${mount}/config" - >/dev/null || die "could not configure auth/${mount}"
  jq -cn '{bound_service_account_names: ["tpg-vso"], bound_service_account_namespaces: ["*"],
           audience: "vault", token_policies: ["tpg-target"], token_ttl: "1h", token_max_ttl: "4h"}' \
    | vt write "auth/${mount}/role/tpg-vso" - >/dev/null || die "could not write auth/${mount}/role/tpg-vso"
}

# ----------------------------------------------------------------- exposure
# vault_target_source_cidrs: CIDRs a public hub load balancer (Vault, the
# metrics remote-write gateway) accepts:
# every target's egress (inventory targets[].egressCidrs, else discovered with
# az for load balancer and managed NAT gateway egress) plus vault.extraSourceCidrs.
vault_target_source_cidrs() {
  # vault_target_source_cidrs [EXTRA_YQ_PATH]: extra CIDRs from EXTRA_YQ_PATH
  # (default .vault.extraSourceCidrs; the remote-write gateway passes
  # .monitoring.extraSourceCidrs)
  local extra="${1:-.vault.extraSourceCidrs}"
  local c out=() cidr rg json outbound id ip explicit=() ids=()
  for c in $(target_names); do
    mapfile -t explicit < <(N="$c" yq -r '.targets[] | select(.name == env(N)) | .egressCidrs[]?' "$INVENTORY")
    if [[ ${#explicit[@]} -gt 0 ]]; then out+=("${explicit[@]}"); continue; fi
    if [[ "$(cluster_field "$c" access az)" != "az" ]]; then
      die "$c: set targets[].egressCidrs in the inventory (vault.exposure public needs the target egress CIDRs)"
    fi
    rg="$(cluster_field "$c" resourceGroup)"
    json="$(az aks show --subscription "$(subscription)" -g "$rg" -n "$c" -o json)" || die "$c: az aks show failed"
    outbound="$(jq -r '.networkProfile.outboundType' <<<"$json")"
    case "$outbound" in
      loadBalancer) mapfile -t ids < <(jq -r '.networkProfile.loadBalancerProfile.effectiveOutboundIPs[]?.id' <<<"$json") ;;
      managedNATGateway) mapfile -t ids < <(jq -r '.networkProfile.natGatewayProfile.effectiveOutboundIPs[]?.id' <<<"$json") ;;
      *) die "$c: outbound type ${outbound}: set targets[].egressCidrs in the inventory" ;;
    esac
    [[ ${#ids[@]} -gt 0 ]] || die "$c: no outbound IPs found: set targets[].egressCidrs in the inventory"
    for id in "${ids[@]}"; do
      # not inside out+=(...): there a failure would only give "/32"
      ip="$(az network public-ip show --ids "$id" --query ipAddress -o tsv)" \
        || die "$c: cannot read outbound IP ${id} (the identity needs Reader on the node resource group; set targets[].egressCidrs in the inventory otherwise)"
      [[ "$ip" =~ ^[0-9.]+$ ]] || die "$c: outbound IP ${id} has no address (got '${ip}')"
      out+=("${ip}/32")
    done
  done
  while read -r cidr; do [[ -z "$cidr" ]] || out+=("$cidr"); done < <(inv "${extra}[]?")
  printf '%s\n' "${out[@]}" | sort -u
}

vault_fleet_ip() {
  kubectl --context "$HUB" -n "$VAULT_NS" get svc vault-fleet -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true
}

vault_fleet_addr() {
  local ip
  ip="$(vault_fleet_ip)"
  [[ -n "$ip" ]] || die "Service vault/vault-fleet has no load balancer IP: run the vault step"
  printf 'https://%s:8200' "$ip"
}

# vault_apply_services: vault-fleet (targets) and, with EXPOSE_UI=1 and internal
# exposure, vault-ui (admin CIDRs). Public exposure adds the admin CIDRs to
# vault-fleet with EXPOSE_UI=1 instead.
vault_apply_services() {
  local exposure ranges="[]" ann='{}' admin
  exposure="$(vault_exposure)"
  admin="$(admin_cidrs_json)"
  case "$exposure" in
    internal)
      ann='{"service.beta.kubernetes.io/azure-load-balancer-internal": "true"}' ;;
    public)
      ranges="$(vault_target_source_cidrs .vault.extraSourceCidrs | jq -Rsc 'split("\n") | map(select(length > 0))')"
      [[ "${EXPOSE_UI:-0}" == "1" ]] && ranges="$(jq -cn --argjson a "$ranges" --argjson b "$admin" '$a + $b | unique')"
      [[ "$ranges" != "[]" ]] || die "no source CIDRs for the public Vault load balancer" ;;
    *) die "vault.exposure must be internal or public (got ${exposure})" ;;
  esac
  vault_service_manifest vault-fleet "$ann" "$ranges" | kubectl --context "$HUB" apply -f - >/dev/null
  ok "Service vault/vault-fleet (${exposure}$( [[ "$exposure" == public ]] && printf ', sources %s' "$ranges"))"
  if [[ "$exposure" == "internal" && "${EXPOSE_UI:-0}" == "1" ]]; then
    vault_service_manifest vault-ui '{}' "$admin" | kubectl --context "$HUB" apply -f - >/dev/null
    ok "Service vault/vault-ui (public, sources ${admin})"
  fi
}

vault_service_manifest() {
  # vault_service_manifest NAME ANNOTATIONS_JSON SOURCE_RANGES_JSON
  jq -n --arg n "$1" --argjson a "$2" --argjson r "$3" '{
    apiVersion: "v1", kind: "Service",
    metadata: {name: $n, namespace: "vault", annotations: $a,
               labels: {"app.kubernetes.io/part-of": "tpg-fleet", "tpg.fleet/managed": "true"}},
    spec: {type: "LoadBalancer", publishNotReadyAddresses: true,
           selector: {"app.kubernetes.io/name": "vault", "app.kubernetes.io/instance": "vault", component: "server"},
           ports: [{name: "https", port: 8200, targetPort: 8200, protocol: "TCP"}]}
    } | if ($r | length) > 0 then .spec.loadBalancerSourceRanges = $r else . end'
}

vault_wait_ips() {
  local svc ip
  for svc in "$@"; do
    ip="$(wait_for_lb_ip "$HUB" "$VAULT_NS" "$svc")"
    printf '%s\n' "$ip"
  done
}

# ----------------------------------------------------------------- TLS
# vault_tls IP...: make sure Secret vault/vault-tls holds a server certificate
# for the in-cluster names and the given load balancer IPs, signed by the CA in
# Secret vault/vault-ca-keypair (created once, 10 years). Sets VAULT_TLS_CHANGED=1
# when the certificate was (re)issued. Also publishes the CA certificate to
# argo/vault-ca (Vault Agent) and ${VAULT_CA_LOCAL}. The CA key is written only to
# a mode-700 temporary directory that is removed when the script exits.
vault_tls() {
  local ips=("$@") sans want have tmp days=0
  VAULT_TLS_CHANGED=0
  sans="DNS:vault,DNS:vault.vault,DNS:vault.vault.svc,DNS:vault.vault.svc.cluster.local"
  sans+=",DNS:vault-0.vault-internal,DNS:vault-0.vault-internal.vault.svc.cluster.local,DNS:localhost,IP:127.0.0.1"
  local ip
  for ip in "${ips[@]}"; do [[ -z "$ip" ]] || sans+=",IP:${ip}"; done
  want="$(tr ',' '\n' <<<"$sans" | sort | paste -sd, -)"
  tmp="$(mktemp -d)"
  cleanup_add "rm -rf '$tmp'"

  if ! kubectl --context "$HUB" -n "$VAULT_NS" get secret vault-ca-keypair >/dev/null 2>&1; then
    log "Creating the Vault CA (Secret vault/vault-ca-keypair, 10 years)"
    cat > "$tmp/ca.cnf" <<'CNF'
[req]
distinguished_name = dn
prompt = no
x509_extensions = v3_ca
[dn]
CN = tpg-vault-ca
[v3_ca]
basicConstraints = critical, CA:TRUE
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
CNF
    openssl req -x509 -newkey rsa:3072 -sha256 -days 3650 -nodes -config "$tmp/ca.cnf" \
      -keyout "$tmp/ca.key" -out "$tmp/ca.crt" 2>/dev/null || die "openssl could not create the Vault CA"
    kubectl --context "$HUB" -n "$VAULT_NS" create secret tls vault-ca-keypair \
      --cert="$tmp/ca.crt" --key="$tmp/ca.key" >/dev/null
  fi
  kubectl --context "$HUB" -n "$VAULT_NS" get secret vault-ca-keypair -o jsonpath='{.data.tls\.crt}' | base64 -d > "$tmp/ca.crt"

  have="$(kubectl --context "$HUB" -n "$VAULT_NS" get secret vault-tls -o jsonpath='{.metadata.annotations.tpg\.fleet/sans}' 2>/dev/null || true)"
  if [[ -n "$have" ]]; then
    kubectl --context "$HUB" -n "$VAULT_NS" get secret vault-tls -o jsonpath='{.data.tls\.crt}' | base64 -d > "$tmp/cur.crt"
    openssl x509 -checkend $((30 * 86400)) -noout -in "$tmp/cur.crt" >/dev/null 2>&1 && days=31
  fi
  if [[ "$have" != "$want" || "$days" -lt 30 ]]; then
    log "Issuing the Vault server certificate (2 years) for: ${want}"
    kubectl --context "$HUB" -n "$VAULT_NS" get secret vault-ca-keypair -o jsonpath='{.data.tls\.key}' | base64 -d > "$tmp/ca.key"
    chmod 600 "$tmp/ca.key"
    cat > "$tmp/srv.cnf" <<CNF
[req]
distinguished_name = dn
prompt = no
[dn]
CN = vault.vault.svc
[v3_srv]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = ${want}
CNF
    openssl req -new -newkey rsa:2048 -nodes -config "$tmp/srv.cnf" -keyout "$tmp/tls.key" -out "$tmp/tls.csr" 2>/dev/null \
      || die "openssl could not create the Vault server key"
    openssl x509 -req -in "$tmp/tls.csr" -CA "$tmp/ca.crt" -CAkey "$tmp/ca.key" -CAcreateserial \
      -days 730 -sha256 -extfile "$tmp/srv.cnf" -extensions v3_srv -out "$tmp/tls.crt" 2>/dev/null \
      || die "openssl could not sign the Vault server certificate"
    kubectl --context "$HUB" -n "$VAULT_NS" create secret generic vault-tls \
      --from-file=tls.crt="$tmp/tls.crt" --from-file=tls.key="$tmp/tls.key" --from-file=ca.crt="$tmp/ca.crt" \
      --dry-run=client -o yaml | kubectl --context "$HUB" apply -f - >/dev/null
    kubectl --context "$HUB" -n "$VAULT_NS" annotate secret vault-tls --overwrite "tpg.fleet/sans=${want}" >/dev/null
    VAULT_TLS_CHANGED=1
  fi
  # CA certificate for Vault Agent (argo/vault-ca) and for the VSO connections
  kubectl --context "$HUB" -n argo create secret generic vault-ca --from-file=ca.crt="$tmp/ca.crt" \
    --dry-run=client -o yaml | kubectl --context "$HUB" apply -f - >/dev/null
  cp "$tmp/ca.crt" "$VAULT_CA_LOCAL"
  rm -rf "$tmp"
}

vault_ca_file() {
  # vault_ca_file -> path of the local copy of the Vault CA certificate (refreshed from the hub)
  kubectl --context "$HUB" -n "$VAULT_NS" get secret vault-tls -o jsonpath='{.data.ca\.crt}' 2>/dev/null \
    | base64 -d > "${VAULT_CA_LOCAL}.tmp" || true
  if [[ ! -s "${VAULT_CA_LOCAL}.tmp" ]]; then
    rm -f "${VAULT_CA_LOCAL}.tmp"
    die "Secret vault/vault-tls not found: run the vault step first"
  fi
  mv "${VAULT_CA_LOCAL}.tmp" "$VAULT_CA_LOCAL"
  printf '%s' "$VAULT_CA_LOCAL"
}

# vault_ca_issue CONTEXT NAMESPACE SECRET CN SAN...: make sure Secret NAMESPACE/SECRET
# (tls.crt, tls.key, ca.crt) holds a server certificate for the SANs (DNS:... or
# IP:...), signed by the Vault CA (Secret vault/vault-ca-keypair). Reissued when
# the SANs change or the certificate expires within 30 days; 2 years. Used for
# the metrics remote-write gateway, so the target Prometheus agents verify it
# with the Vault CA they already have (tpg-vault/vault-ca).
vault_ca_issue() {
  local ctx="$1" ns="$2" secret="$3" cn="$4" want have tmp days=0
  shift 4
  want="$(printf '%s\n' "$@" | sort | paste -sd, -)"
  kubectl --context "$HUB" -n "$VAULT_NS" get secret vault-ca-keypair >/dev/null 2>&1 \
    || die "Secret vault/vault-ca-keypair not found: run the vault step first"
  have="$(kubectl --context "$ctx" -n "$ns" get secret "$secret" -o jsonpath='{.metadata.annotations.tpg\.fleet/sans}' 2>/dev/null || true)"
  tmp="$(mktemp -d)"; chmod 700 "$tmp"
  cleanup_add "rm -rf '$tmp'"
  if [[ -n "$have" ]]; then
    kubectl --context "$ctx" -n "$ns" get secret "$secret" -o jsonpath='{.data.tls\.crt}' | base64 -d > "$tmp/cur.crt"
    openssl x509 -checkend $((30 * 86400)) -noout -in "$tmp/cur.crt" >/dev/null 2>&1 && days=31
  fi
  if [[ "$have" == "$want" && "$days" -ge 30 ]]; then rm -rf "$tmp"; return 0; fi
  log "Issuing a server certificate for ${ns}/${secret} (2 years): ${want}"
  kubectl --context "$HUB" -n "$VAULT_NS" get secret vault-ca-keypair -o jsonpath='{.data.tls\.crt}' | base64 -d > "$tmp/ca.crt"
  kubectl --context "$HUB" -n "$VAULT_NS" get secret vault-ca-keypair -o jsonpath='{.data.tls\.key}' | base64 -d > "$tmp/ca.key"
  chmod 600 "$tmp/ca.key"
  cat > "$tmp/srv.cnf" <<CNF
[req]
distinguished_name = dn
prompt = no
[dn]
CN = ${cn}
[v3_srv]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = ${want}
CNF
  openssl req -new -newkey rsa:2048 -nodes -config "$tmp/srv.cnf" -keyout "$tmp/tls.key" -out "$tmp/tls.csr" 2>/dev/null \
    || die "openssl could not create the key for ${ns}/${secret}"
  openssl x509 -req -in "$tmp/tls.csr" -CA "$tmp/ca.crt" -CAkey "$tmp/ca.key" -CAcreateserial \
    -days 730 -sha256 -extfile "$tmp/srv.cnf" -extensions v3_srv -out "$tmp/tls.crt" 2>/dev/null \
    || die "openssl could not sign the certificate for ${ns}/${secret}"
  kubectl --context "$ctx" -n "$ns" create secret generic "$secret" \
    --from-file=tls.crt="$tmp/tls.crt" --from-file=tls.key="$tmp/tls.key" --from-file=ca.crt="$tmp/ca.crt" \
    --dry-run=client -o yaml | kubectl --context "$ctx" apply -f - >/dev/null
  kubectl --context "$ctx" -n "$ns" annotate secret "$secret" --overwrite "tpg.fleet/sans=${want}" >/dev/null
  rm -rf "$tmp"
}
