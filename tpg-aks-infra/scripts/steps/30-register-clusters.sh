#!/usr/bin/env bash
# On the hub: register every target cluster with Argo CD (cluster Secret with
# tpg.fleet labels), store a kubeconfig Secret for Argo Workflows, and give the
# cluster its Vault Kubernetes auth mount auth/k8s-<cluster> (role tpg-vso, policy
# tpg-target) so its Vault Secrets Operator can read the registry and backup
# credentials. With vault.exposure public, the Vault load balancer source ranges
# are refreshed so new targets can reach Vault.
source "$(dirname "$0")/../lib/common.sh"
source "$(dirname "$0")/../lib/vault.sh"

require_cmd kubectl jq yq base64
require_inventory
HUB="$(hub_name)"
require_context "$HUB"
vault_require_unsealed
vault_login
if [[ "$(vault_exposure)" == "public" ]]; then
  log "Refreshing the Vault load balancer source ranges (vault.exposure public)"
  vault_apply_services
fi

kubectl --context "$HUB" get namespace argocd argo >/dev/null \
  || die "argocd and argo namespaces not found on $HUB: run the hub step first"

for c in $(target_names); do
  wave="$(target_wave "$c")"
  log "Registering $c (wave $wave)"
  token="$(kubectl --context "$c" -n kube-system get secret argocd-manager-token \
    -o jsonpath='{.data.token}' | base64 -d)"
  ca="$(kubectl --context "$c" -n kube-system get secret argocd-manager-token \
    -o jsonpath='{.data.ca\.crt}')"
  server="$(kubectl config view --raw -o json \
    | jq -r --arg c "$c" '(.contexts[] | select(.name==$c) | .context.cluster) as $cl
        | .clusters[] | select(.name==$cl) | .cluster.server')"
  [[ -n "$token" && -n "$ca" && "$server" == https://* ]] \
    || die "could not read token, CA or server URL for $c"

  if [[ -n "${FLEET_LOCAL_DIR:-}" && -f "${FLEET_LOCAL_DIR}/clusters/fleet.yaml" ]]; then
    C="$c" yq -e '.clusters | has(strenv(C))' "${FLEET_LOCAL_DIR}/clusters/fleet.yaml" >/dev/null 2>&1 \
      || log "$c has no entry in tpg-fleet clusters/fleet.yaml yet: tpg-day0 -p \"clusters=[$c]\" adds it"
  fi

  # the token reaches jq through the environment and kubectl on stdin, never as an argument
  T="$token" CA="$ca" jq -cn '{bearerToken: env.T, tlsClientConfig: {insecure: false, caData: env.CA}}' \
    | kubectl --context "$HUB" -n argocd create secret generic "cluster-$c" \
        --from-literal=name="$c" --from-literal=server="$server" \
        --from-file=config=/dev/stdin --dry-run=client -o yaml \
    | kubectl --context "$HUB" apply -f - >/dev/null
  kubectl --context "$HUB" -n argocd label secret "cluster-$c" --overwrite \
    argocd.argoproj.io/secret-type=cluster tpg.fleet/managed=true \
    "tpg.fleet/wave=$wave" >/dev/null
  # The tpg-platform ApplicationSet reads the disk SKU of tpg-data-retain from here
  kubectl --context "$HUB" -n argocd label secret "cluster-$c" --overwrite \
    "tpg.fleet/dataDiskSku=$(data_disk_sku)" >/dev/null

  kc="${WORK_DIR}/$c.kubeconfig"
  printf '%s' "$ca" | base64 -d > "${WORK_DIR}/$c.ca.crt"
  kubectl config set-cluster "$c" --server="$server" \
    --certificate-authority="${WORK_DIR}/$c.ca.crt" --embed-certs=true --kubeconfig="$kc" >/dev/null
  kubectl config set-credentials argocd-manager --token="$token" --kubeconfig="$kc" >/dev/null
  kubectl config set-context default --cluster="$c" --user=argocd-manager --kubeconfig="$kc" >/dev/null
  kubectl config use-context default --kubeconfig="$kc" >/dev/null
  upsert_generic_secret "$HUB" argo "kubeconfig-$c" --from-file=config="$kc"
  # The workflows read the registered clusters and their waves from these labels
  kubectl --context "$HUB" -n argo label secret "kubeconfig-$c" --overwrite \
    tpg.fleet/cluster="$c" "tpg.fleet/wave=$wave" >/dev/null
  rm -f "$kc" "${WORK_DIR}/$c.ca.crt"

  reviewer="$(kubectl --context "$c" -n kube-system get secret tpg-vault-reviewer-token \
    -o jsonpath='{.data.token}' 2>/dev/null | base64 -d)"
  [[ -n "$reviewer" ]] || die "Secret kube-system/tpg-vault-reviewer-token missing on $c: run the service-accounts step"
  vault_configure_target "$c" "$server" "$(printf '%s' "$ca" | base64 -d)" "$reviewer"
  reviewer=""
  ok "$c registered (Argo CD, Argo Workflows, Vault auth/k8s-$c)"
done
