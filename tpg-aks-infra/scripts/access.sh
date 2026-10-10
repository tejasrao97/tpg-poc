#!/usr/bin/env bash
# Print every UI endpoint and login of the fleet, to the terminal only.
#   scripts/access.sh                       (reads env.sh and the inventory)
#   scripts/run.sh --hub <mode> --targets <mode> --only access
#   make access
# Nothing is written to a file: run it again whenever you need a credential.
#
#   Argo CD             UI, user admin, initial password (or ARGOCD_ADMIN_PASSWORD, or a note)
#   Argo Workflows      UI and the argo-ui-admin bearer token
#   Vault               UI, userpass account tpg-admin and its password (Vault tpg/admin/vault-ui),
#                       unseal mode and seal state
#   Grafana             UI and the admin password (Secret monitoring/grafana-admin)
#   Prometheus          UI (no login)
#   Alertmanager        UI (no login)
#   Azure Managed Grafana  endpoint (monitoring option azure; sign in with Entra ID)
#   Postgres instances  service host and port per instance, and how to read its credentials
#
# ROTATE_VAULT_ADMIN=1 (or --rotate-vault-admin) sets a new Vault UI password first.
# Load balancers accept only their loadBalancerSourceRanges; private ones are
# printed with a ready-to-run kubectl port-forward command.
source "$(dirname "$0")/lib/common.sh"
source "$(dirname "$0")/lib/vault.sh"

require_cmd kubectl jq yq
require_inventory
HUB="$(hub_name)"
require_context "$HUB"
[[ "${1:-}" != "--rotate-vault-admin" ]] || ROTATE_VAULT_ADMIN=1

hr() { printf '\n\033[1;35m== %s\033[0m\n' "$*"; }
kv() { printf '  %-22s %s\n' "$1" "$2"; }

# url NAMESPACE SERVICE SCHEME PORT [PATH]: public URL, or a port-forward command
url() {
  local ns="$1" svc="$2" scheme="$3" port="$4" path="${5:-}" json ip type
  json="$(kubectl --context "$HUB" -n "$ns" get svc "$svc" -o json 2>/dev/null)" || { printf 'not installed'; return; }
  type="$(jq -r '.spec.type' <<<"$json")"
  ip="$(jq -r '.status.loadBalancer.ingress[0].ip // ""' <<<"$json")"
  if [[ "$type" == "LoadBalancer" && -n "$ip" ]]; then
    if [[ "$(jq -r '(.metadata.annotations["service.beta.kubernetes.io/azure-load-balancer-internal"] // "")' <<<"$json")" == "true" ]]; then
      printf '%s://%s:%s%s  (private IP in the VNet; from outside: kubectl --context %s -n %s port-forward svc/%s %s:%s then %s://localhost:%s%s)' \
        "$scheme" "$ip" "$port" "$path" "$HUB" "$ns" "$svc" "$port" "$port" "$scheme" "$port" "$path"
    else
      printf '%s://%s:%s%s' "$scheme" "$ip" "$port" "$path"
    fi
  else
    printf 'kubectl --context %s -n %s port-forward svc/%s %s:%s then %s://localhost:%s%s' \
      "$HUB" "$ns" "$svc" "$port" "$port" "$scheme" "$port" "$path"
  fi
}

# ---------------------------------------------------------------- Argo CD
hr "Argo CD"
kv "UI" "$(url argocd argocd-server https 443)"
kv "user" "admin"
if pw="$(kubectl --context "$HUB" -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)" && [[ -n "$pw" ]]; then
  kv "password" "$pw"
  kv "note" "initial password; change it in the UI and delete Secret argocd/argocd-initial-admin-secret"
elif [[ -n "${ARGOCD_ADMIN_PASSWORD:-}" ]]; then
  kv "password" "$ARGOCD_ADMIN_PASSWORD"
  kv "note" "from ARGOCD_ADMIN_PASSWORD in your shell"
else
  kv "password" "changed by you and not stored anywhere"
  kv "reset it" "argocd account bcrypt --password <new> then: kubectl --context $HUB -n argocd patch secret argocd-secret -p '{\"stringData\":{\"admin.password\":\"<hash>\",\"admin.passwordMtime\":\"'\$(date +%FT%T%Z)'\"}}'"
fi
kv "CLI" "argocd login <UI host> --username admin --insecure --grpc-web"

# ---------------------------------------------------------------- Argo Workflows
hr "Argo Workflows"
WF_SVC="$(argo_wf_server_svc "$HUB" 2>/dev/null || true)"
if [[ -n "$WF_SVC" ]]; then
  kv "UI" "$(url argo "$WF_SVC" https 2746)"
  tok="$(kubectl --context "$HUB" -n argo get secret argo-ui-admin.service-account-token -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)"
  if [[ -n "$tok" ]]; then
    kv "UI login" "paste this whole value in the client authentication field:"
    printf '  %s\n' "Bearer ${tok}"
    kv "CLI" "export ARGO_SERVER=<host>:2746 ARGO_SECURE=true ARGO_INSECURE_SKIP_VERIFY=true ARGO_NAMESPACE=argo ARGO_TOKEN=\"Bearer <token above>\""
  else
    kv "UI login" "Secret argo/argo-ui-admin.service-account-token missing: run scripts/hub/ui-admin.sh"
  fi
else
  kv "UI" "argo-server not found in namespace argo"
fi

# ---------------------------------------------------------------- Vault
hr "Vault"
ST="$(vault_status)"
if [[ -z "$ST" ]]; then
  kv "state" "pod vault/vault-0 not reachable (run scripts/run.sh --only vault)"
else
  mode="$(vault_unseal_mode)"
  kv "unseal mode" "${mode:-not set in the inventory (vault.unsealMode)} (seal type $(jq -r '.type' <<<"$ST"))"
  kv "state" "initialized=$(jq -r '.initialized' <<<"$ST") sealed=$(jq -r '.sealed' <<<"$ST")"
  if [[ "$(vault_exposure)" == "internal" ]] && kubectl --context "$HUB" -n vault get svc vault-ui >/dev/null 2>&1; then
    kv "UI" "$(url vault vault-ui https 8200 /ui)"
  else
    kv "UI" "$(url vault vault-fleet https 8200 /ui)"
  fi
  kv "targets address" "$(vault_fleet_ip >/dev/null && vault_fleet_addr || echo 'no load balancer IP yet')"
  kv "CA certificate" "${VAULT_CA_LOCAL} (self-signed: accept the warning, or trust this file)"
  if [[ "$(jq -r '.sealed' <<<"$ST")" == "false" ]]; then
    vault_login
    [[ "${ROTATE_VAULT_ADMIN:-0}" != "1" ]] || log "rotating the Vault UI password of tpg-admin"
    pw="$(vault_admin_user "$( [[ "${ROTATE_VAULT_ADMIN:-0}" == "1" ]] && echo rotate )")"
    kv "UI login" "method Username, user tpg-admin, policy tpg-admin"
    kv "password" "${pw:-not set; run scripts/run.sh --only vault}"
    kv "rotate it" "scripts/run.sh --hub <mode> --targets <mode> --only access --rotate-vault-admin"
  else
    kv "UI login" "unseal Vault first: scripts/run.sh --only vault-unseal"
  fi
fi

# ---------------------------------------------------------------- workflow logs
hr "Archived workflow logs"
arch="$(kubectl --context "$HUB" -n argo get cm artifact-repositories -o json 2>/dev/null \
  | jq -r '(.metadata.annotations["workflows.argoproj.io/default-artifact-repository"] // "") as $d | .data[$d] // ""' || true)"
if [[ -n "$arch" ]]; then
  kv "storage" "$(jq -r '.azure.endpoint + "/" + .azure.container' <<<"$arch" 2>/dev/null || echo "$arch")"
  kv "read" "Argo UI (while the Workflow exists), or scripts/wf-logs.sh <workflow> (also after the 7-day TTL)"
else
  kv "storage" "not configured: run scripts/run.sh --only hub-secrets"
fi

# ---------------------------------------------------------------- monitoring
MON="$(kubectl --context "$HUB" -n argo get cm tpg-settings -o jsonpath='{.data.monitoringOption}' 2>/dev/null || true)"
hr "Monitoring (option ${MON:-unknown})"
case "$MON" in
  standalone)
    graf="tpg-grafana-public"; kubectl --context "$HUB" -n monitoring get svc "$graf" >/dev/null 2>&1 || graf="kps-grafana"
    kv "Grafana" "$(url monitoring "$graf" http 80)"
    kv "  user" "admin"
    gpw="$(kubectl --context "$HUB" -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d || true)"
    kv "  password" "${gpw:-Secret monitoring/grafana-admin not found}"
    prom="tpg-prometheus-public"; kubectl --context "$HUB" -n monitoring get svc "$prom" >/dev/null 2>&1 || prom="kps-kube-prometheus-stack-prometheus"
    kv "Prometheus" "$(url monitoring "$prom" http 9090)"
    kv "  login" "none (anyone who reaches it can query every metric)"
    am="tpg-alertmanager-public"; kubectl --context "$HUB" -n monitoring get svc "$am" >/dev/null 2>&1 || am="kps-kube-prometheus-stack-alertmanager"
    kv "Alertmanager" "$(url monitoring "$am" http 9093)"
    kv "  login" "none (anyone who reaches it can silence alerts)"
    kv "public UIs" "created only with --expose-ui; sources: $(admin_cidrs_json)"
    kv "dashboards" "folder Tanzu Postgres: Fleet, Instance overview, Replication and HA, Backup WAL and restore, Alerts"
    kv "remote write" "$(url monitoring tpg-remote-write https 8443 /api/v1/write) (targets only; basic auth from Vault tpg/shared/monitoring-remote-write)"
    ;;
  azure)
    ep=""
    if [[ "${TF_BIN:-terraform}" ]] && ep="$(tf_raw grafana_endpoint 2>/dev/null)" && [[ -n "$ep" ]]; then
      kv "Azure Managed Grafana" "$ep"
    else
      rg="$(cluster_field "$HUB" resourceGroup)"
      kv "Azure Managed Grafana" "az resource list --subscription $(subscription) -g ${rg} --resource-type Microsoft.Dashboard/grafana --query '[].properties.endpoint' -o tsv"
    fi
    kv "  login" "Microsoft Entra ID (Grafana Admin role on the workspace); no local password"
    kv "Prometheus" "Azure Monitor workspace: query through Managed Grafana or the workspace query endpoint"
    kv "dashboards" "folder Tanzu Postgres (imported by the addons step, or monitoring/grafana/import-azure-grafana.sh)"
    ;;
  *)
    kv "monitoring" "option ${MON:-none}: no Grafana or Prometheus installed by this fleet"
    ;;
esac

# ---------------------------------------------------------------- Postgres instances
hr "Postgres instances"
for c in $(target_names); do
  if ! kubectl config get-contexts "$c" >/dev/null 2>&1; then
    kv "$c" "no kubeconfig context (run the kubeconfigs step)"; continue
  fi
  rows="$(kubectl --context "$c" get postgres -A -o json 2>/dev/null \
    | jq -r '.items[]? | "\(.metadata.namespace)/\(.metadata.name) \(.status.currentState // "unknown")"' || true)"
  if [[ -z "$rows" ]]; then
    kv "$c" "no Postgres instances"
    continue
  fi
  printf '  %s\n' "$c"
  while read -r ref state; do
    ns="${ref%%/*}"; name="${ref##*/}"
    printf '    %-28s %s\n' "$ref" "state ${state}"
    printf '      %s\n' "host ${name}.${ns}.svc.cluster.local:5432 (Service ${name}, type $(kubectl --context "$c" -n "$ns" get svc "$name" -o jsonpath='{.spec.type}' 2>/dev/null || echo unknown))"
    printf '      %s\n' "credentials: kubectl --context ${c} -n ${ns} get secret ${name}-db-secret -o jsonpath='{.data.password}' | base64 -d (list them with: kubectl --context ${c} -n ${ns} get secret)"
  done <<<"$rows"
done

hr "Kubernetes"
kv "kubeconfig" "$KUBECONFIG (contexts: $(kubectl config get-contexts -o name | paste -sd, -))"
printf '\nNothing above was written to a file. Run this again whenever you need a credential.\n'
