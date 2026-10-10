#!/usr/bin/env bash
# Print the Argo CD and Argo Workflows UI endpoints and login commands.
source "$(dirname "$0")/../lib/common.sh"

require_inventory
HUB="$(hub_name)"

endpoint() {
  local ns="$1" svc="$2" type ip
  type="$(kubectl --context "$HUB" -n "$ns" get svc "$svc" -o jsonpath='{.spec.type}')"
  if [[ "$type" == "LoadBalancer" ]]; then
    ip="$(wait_for_lb_ip "$HUB" "$ns" "$svc")"
    printf '%s' "$ip"
  else
    printf 'not exposed (%s): kubectl --context %s -n %s port-forward svc/%s <local-port>:<port>' "$type" "$HUB" "$ns" "$svc"
  fi
}

ARGOCD_EP="$(endpoint argocd argocd-server)"
WF_SVC="$(argo_wf_server_svc "$HUB")"
WF_EP="$(endpoint argo "$WF_SVC")"

cat <<INFO

Argo CD UI:         https://${ARGOCD_EP}
  user:             admin
  password:         kubectl --context ${HUB} -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo

Argo Workflows UI:  https://${WF_EP}:2746
  token:            echo "Bearer \$(kubectl --context ${HUB} -n argo get secret argo-ui-admin.service-account-token -o jsonpath='{.data.token}' | base64 -d)"

Load balancers accept connections only from their loadBalancerSourceRanges.
INFO
