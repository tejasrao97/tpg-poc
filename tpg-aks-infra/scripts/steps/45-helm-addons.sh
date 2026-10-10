#!/usr/bin/env bash
# Install or upgrade the fleet add-ons as Helm releases (helm list shows them):
#   targets  cert-manager                       every run
#   targets  vault-secrets-operator             every run (VaultAuth on auth/k8s-<cluster>, role tpg-vso)
#   hub      kps (kube-prometheus-stack)        MONITORING_OPTION=standalone
#            and the remote-write gateway       (https + basic auth in front of /api/v1/write)
#   targets  kps (agent) and tpg-ksm            MONITORING_OPTION=standalone
# Uses tpg-fleet workflows/scripts/helm-addons.sh, the same script the tpg-helm-addons
# and tpg-day0 workflows run for target clusters. Its pre-check reports every
# release as INSTALLED, UPGRADED, UP_TO_DATE, SKIPPED_EXISTS, SKIPPED_NEWER,
# REUSED_EXISTING or BLOCKED. For a release that already exists with changes it
# shows the chart version and values diff and asks upgrade / skip / abort; set
# ADDONS_EXISTING=upgrade|skip|abort (or run.sh --yes) to answer without a prompt.
# While helm --wait runs, the pods of the release namespace are printed every 5
# seconds, and the install stops when a pod cannot start.
# The hub releases vault and vault-secrets-operator come from the vault step.
#
# Monitoring, standalone option (every target sends its metrics to the hub):
#   1. Vault tpg/shared/monitoring-remote-write: the remote-write credential
#      (created once, random password); each target reads it through the
#      VaultStaticSecret monitoring/tpg-remote-write
#   2. hub Service monitoring/tpg-remote-write (load balancer: internal or public,
#      inventory monitoring.remoteWriteExposure), its TLS certificate from the
#      Vault CA and the htpasswd Secret for the gateway
#   3. hub kps and the gateway (helm-addons.sh), then tpg-settings
#      hubPrometheusRemoteWriteUrl = https://<gateway IP>:8443/api/v1/write
#   4. every target: kps agent with basic auth and the Vault CA, then a check that
#      its metrics reach the hub within 5 minutes (MONITORING_NOT_FLOWING otherwise)
# Monitoring, azure option (Azure Monitor managed Prometheus, Azure Managed Grafana):
#   every cluster gets the managed Prometheus add-on linked to the Azure Monitor
#   workspace (monitoring.azureMonitorWorkspaceId) when it does not have it, its
#   ama-metrics pods are checked, the Grafana role on the workspace is checked
#   (and printed as a command when it is missing: a Contributor cannot create
#   it), and the dashboards and alert rules are imported into Azure Managed Grafana.
#
# Grafana admin password (standalone): export GRAFANA_ADMIN_PASSWORD before this step, or
# let the script generate one. It is stored only in Secret monitoring/grafana-admin on the hub.
# ADDONS_SKIP_TARGETS=1 installs the hub releases only.
source "$(dirname "$0")/../lib/common.sh"
source "$(dirname "$0")/../lib/vault.sh"

require_cmd kubectl helm jq yq openssl
require_inventory
require_env FLEET_LOCAL_DIR
HUB="$(hub_name)"
require_context "$HUB"
ADDONS="${FLEET_LOCAL_DIR}/workflows/scripts/helm-addons.sh"
[[ -f "$ADDONS" ]] || die "$ADDONS not found: FLEET_LOCAL_DIR must point at a tpg-fleet clone"
MONITORING_OPTION="${MONITORING_OPTION:-none}"
case "$MONITORING_OPTION" in none|azure|standalone) ;; *) die "MONITORING_OPTION must be none, azure or standalone" ;; esac
RW_WAIT_SECONDS="${MONITORING_FLOW_TIMEOUT:-300}"

kubectl --context "$HUB" -n argo get configmap tpg-settings >/dev/null 2>&1 \
  || die "argo/tpg-settings not found: run the hub-secrets step first"
VAULT_FLEET_ADDR="$(vault_fleet_addr)"
CA_FILE="$(vault_ca_file)"
hk() { kubectl --context "$HUB" "$@"; }
# kubectl for the cluster in CUR_CTX (pods_watch and monitoring_flowing take a function name)
CUR_CTX=""
ck() { kubectl --context "$CUR_CTX" "$@"; }

# ---------------------------------------------------------------- standalone: hub
RW_URL=""
remote_write_hub() {
  local exposure ranges ann='{}' ip pw user hash sum have
  exposure="$(inv '.monitoring.remoteWriteExposure // "public"')"
  case "$exposure" in internal|public) ;; *) die "monitoring.remoteWriteExposure must be internal or public (got ${exposure})" ;; esac

  # 1. credential in Vault (created once)
  vault_login
  if ! vault_kv_exists shared/monitoring-remote-write; then
    pw="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32 || true)"
    [[ "${#pw}" -eq 32 ]] || die "could not generate the remote-write password"
    vault_kv_put shared/monitoring-remote-write "$(P="$pw" jq -cn '{username: "tpg-remote-write", password: env.P}')"
    pw=""
    ok "Vault tpg/shared/monitoring-remote-write created (random password)"
  fi
  user="$(vault_kv_get shared/monitoring-remote-write username)"
  pw="$(vault_kv_get shared/monitoring-remote-write password)"
  [[ -n "$user" && -n "$pw" ]] || die "tpg/shared/monitoring-remote-write must have username and password"

  # 2. load balancer, TLS, htpasswd
  hk create namespace monitoring --dry-run=client -o yaml | hk apply -f - >/dev/null
  ranges="[]"
  if [[ "$exposure" == "internal" ]]; then
    ann='{"service.beta.kubernetes.io/azure-load-balancer-internal": "true"}'
  else
    ranges="$(vault_target_source_cidrs .monitoring.extraSourceCidrs | jq -Rsc 'split("\n") | map(select(length > 0))')"
    [[ "$ranges" != "[]" ]] || die "no source CIDRs for the public remote-write load balancer (targets[].egressCidrs or monitoring.extraSourceCidrs)"
  fi
  jq -n --argjson a "$ann" --argjson r "$ranges" '{
    apiVersion: "v1", kind: "Service",
    metadata: {name: "tpg-remote-write", namespace: "monitoring", annotations: $a,
               labels: {"app.kubernetes.io/name": "tpg-remote-write", "tpg.fleet/managed": "true"}},
    spec: {type: "LoadBalancer", selector: {"app.kubernetes.io/name": "tpg-remote-write"},
           ports: [{name: "https", port: 8443, targetPort: 8443, protocol: "TCP"}]}
  } | if ($r | length) > 0 then .spec.loadBalancerSourceRanges = $r else . end' | hk apply -f - >/dev/null
  ip="$(wait_for_lb_ip "$HUB" monitoring tpg-remote-write)"
  ok "Service monitoring/tpg-remote-write (${exposure}) at ${ip}$( [[ "$exposure" == public ]] && printf ', sources %s' "$ranges")"
  vault_ca_issue "$HUB" monitoring tpg-remote-write-tls tpg-remote-write \
    "IP:${ip}" DNS:tpg-remote-write DNS:tpg-remote-write.monitoring DNS:tpg-remote-write.monitoring.svc \
    DNS:tpg-remote-write.monitoring.svc.cluster.local
  # htpasswd (apr1 hash, never the password). Regenerated only when the password
  # in Vault changes, so the gateway is not restarted on every run.
  sum="$(printf '%s:%s' "$user" "$pw" | openssl dgst -sha256 -r | cut -d' ' -f1)"
  have="$(hk -n monitoring get secret tpg-remote-write-htpasswd -o jsonpath='{.metadata.annotations.tpg\.fleet/credential-sha256}' 2>/dev/null || true)"
  if [[ "$have" != "$sum" ]]; then
    hash="$(printf '%s' "$pw" | openssl passwd -apr1 -stdin)"
    printf '%s:%s\n' "$user" "$hash" | hk -n monitoring create secret generic tpg-remote-write-htpasswd \
      --from-file=htpasswd=/dev/stdin --dry-run=client -o yaml | hk apply -f - >/dev/null
    hk -n monitoring annotate secret tpg-remote-write-htpasswd --overwrite "tpg.fleet/credential-sha256=${sum}" >/dev/null
    # The gateway reads the file at start
    hk -n monitoring rollout restart deploy/tpg-remote-write >/dev/null 2>&1 || true
    ok "Secret monitoring/tpg-remote-write-htpasswd (credential from Vault)"
  fi
  pw=""
  # The workflows check the metrics flow through the hub API service proxy
  jq -n '{apiVersion: "v1", kind: "List", items: [
    {apiVersion: "rbac.authorization.k8s.io/v1", kind: "Role",
     metadata: {name: "tpg-workflow-prometheus-query", namespace: "monitoring"},
     rules: [{apiGroups: [""], resources: ["services/proxy"],
              resourceNames: ["prometheus-operated", "http:prometheus-operated:9090"], verbs: ["get"]}]},
    {apiVersion: "rbac.authorization.k8s.io/v1", kind: "RoleBinding",
     metadata: {name: "tpg-workflow-prometheus-query", namespace: "monitoring"},
     roleRef: {apiGroup: "rbac.authorization.k8s.io", kind: "Role", name: "tpg-workflow-prometheus-query"},
     subjects: [{kind: "ServiceAccount", name: "tpg-workflow", namespace: "argo"}]}]}' | hk apply -f - >/dev/null

  # 3. kube-prometheus-stack and the gateway
  log "Hub $HUB: kube-prometheus-stack (release kps, namespace monitoring) and the remote-write gateway"
  bash "$ADDONS" --cluster "$HUB" --role hub --components monitoring \
    --context "$HUB" --fleet-dir "$FLEET_LOCAL_DIR" ${ADDONS_EXISTING:+--existing "$ADDONS_EXISTING"} \
    || die "hub monitoring install failed"
  RW_URL="https://${ip}:8443/api/v1/write"
  hk -n argo patch configmap tpg-settings --type merge \
    -p "$(jq -cn --arg u "$RW_URL" '{data: {hubPrometheusRemoteWriteUrl: $u, monitoringOption: "standalone"}}')" >/dev/null
  ok "targets remote write to $RW_URL (tpg-settings hubPrometheusRemoteWriteUrl)"
  if hk -n monitoring get cm -l grafana_datasource=1 -o name 2>/dev/null | grep -q .; then
    ok "Grafana data sources provisioned (Prometheus uid prometheus, Alertmanager uid alertmanager)"
  else
    warn "no ConfigMap with label grafana_datasource=1 in monitoring: Grafana will show no data source"
  fi
}

expose_monitoring_ui() {
  # Public load balancers for the monitoring UIs, limited to adminAllowedCidrs.
  # Prometheus and Alertmanager have no login: anyone in those CIDRs can read
  # the metrics and silence alerts.
  local cidrs pair src new
  cidrs="$(admin_cidrs_json)"
  for pair in "kps-grafana:tpg-grafana-public" \
              "kps-kube-prometheus-stack-prometheus:tpg-prometheus-public" \
              "kps-kube-prometheus-stack-alertmanager:tpg-alertmanager-public"; do
    src="${pair%%:*}"; new="${pair##*:}"
    if public_clone_service "$HUB" monitoring "$src" "$new" "$cidrs"; then
      ok "public UI Service monitoring/${new} (sources $(jq -r 'join(", ")' <<<"$cidrs"))"
    else
      warn "Service monitoring/${src} not found: no public Service ${new}"
    fi
  done
  warn "Prometheus and Alertmanager have no authentication: the CIDRs above can read metrics and silence alerts"
}

# ---------------------------------------------------------------- azure: every cluster
AMW="$(inv '.monitoring.azureMonitorWorkspaceId // ""')"
azure_monitor_cluster() {
  # azure_monitor_cluster CLUSTER: managed Prometheus add-on linked to the workspace,
  # and its ama-metrics pods running
  local c="$1" rg enabled
  if [[ "$(cluster_field "$c" access az)" != "az" ]]; then
    warn "$c: access kubeconfig, so the managed Prometheus add-on is not checked with az; enable it with: az aks update -g <rg> -n $c --enable-azure-monitor-metrics --azure-monitor-workspace-resource-id <workspace id>"
  else
    rg="$(cluster_field "$c" resourceGroup)"
    enabled="$(az aks show --subscription "$(subscription)" -g "$rg" -n "$c" --query 'azureMonitorProfile.metrics.enabled' -o tsv 2>/dev/null || true)"
    if [[ "$enabled" == "true" ]]; then
      ok "$c: Azure Monitor managed Prometheus add-on enabled"
    elif [[ -z "$AMW" ]]; then
      die "$c: the managed Prometheus add-on is off and monitoring.azureMonitorWorkspaceId is not set in the inventory (Terraform: enable_azure_monitor = true)"
    else
      log "$c: enabling the Azure Monitor managed Prometheus add-on (data collection rule and association for the workspace)"
      az aks update --subscription "$(subscription)" -g "$rg" -n "$c" --enable-azure-monitor-metrics \
        --azure-monitor-workspace-resource-id "$AMW" --only-show-errors -o none \
        || die "$c: az aks update --enable-azure-monitor-metrics failed"
      ok "$c: managed Prometheus add-on enabled, linked to the workspace"
    fi
  fi
  CUR_CTX="$c"
  pods_watch kube-system 600 --kubectl ck --selector rsName=ama-metrics \
    --label "Azure Monitor metrics agent on $c" \
    || die "MONITORING_NOT_FLOWING $c: the ama-metrics pods are not ready (${POD_WATCH_REASON}: ${POD_WATCH_DETAIL})"
}

azure_grafana() {
  local grg gname gid pid n
  grg="$(inv '.monitoring.grafanaResourceGroup // ""')"; gname="$(inv '.monitoring.grafanaName // ""')"
  if [[ -z "$gname" || -z "$AMW" ]]; then
    warn "monitoring.grafanaName or azureMonitorWorkspaceId not set: the Azure Managed Grafana checks and the dashboard import are skipped"
    return 0
  fi
  gid="$(az resource show --subscription "$(subscription)" -g "$grg" -n "$gname" \
    --resource-type Microsoft.Dashboard/grafana --query id -o tsv 2>/dev/null || true)"
  [[ -n "$gid" ]] || { warn "Azure Managed Grafana $grg/$gname not found"; return 0; }
  pid="$(az resource show --ids "$gid" --query identity.principalId -o tsv 2>/dev/null || true)"
  n="$(az role assignment list --scope "$AMW" --assignee "$pid" \
        --query "[?roleDefinitionName=='Monitoring Data Reader'] | length(@)" -o tsv 2>/dev/null || echo 0)"
  if [[ "${n:-0}" -gt 0 ]]; then
    ok "Azure Managed Grafana $gname can read the workspace (Monitoring Data Reader)"
  else
    warn "Azure Managed Grafana $gname has no Monitoring Data Reader role on the workspace, so it shows no Prometheus data source. A Contributor cannot create it; ask an owner to run:
    az role assignment create --assignee-object-id $pid --assignee-principal-type ServicePrincipal --role \"Monitoring Data Reader\" --scope $AMW"
  fi
  log "Importing the dashboards and alert rules into Azure Managed Grafana $gname"
  if bash "${FLEET_LOCAL_DIR}/monitoring/grafana/import-azure-grafana.sh" "$grg" "$gname"; then
    ok "dashboards and alert rules imported"
  else
    warn "the Grafana import failed (your identity needs the Grafana Admin role on $gname); re-run monitoring/grafana/import-azure-grafana.sh $grg $gname"
  fi
}

# ---------------------------------------------------------------- hub
case "$MONITORING_OPTION" in
  standalone)
    remote_write_hub
    [[ "${EXPOSE_UI:-0}" != "1" ]] || expose_monitoring_ui
    ip="$(hk -n monitoring get svc kps-grafana -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    [[ -z "$ip" ]] || ok "Grafana: http://${ip} (user admin; password in Secret monitoring/grafana-admin)"
    ;;
  azure)
    hk -n argo patch configmap tpg-settings --type merge -p '{"data":{"monitoringOption":"azure"}}' >/dev/null
    azure_monitor_cluster "$HUB"
    ;;
esac

# ---------------------------------------------------------------- targets
if [[ "${ADDONS_SKIP_TARGETS:-0}" == "1" ]]; then
  log "ADDONS_SKIP_TARGETS=1: target clusters skipped"
  exit 0
fi
components="cert-manager,vso"
[[ "$MONITORING_OPTION" == "standalone" ]] && components="cert-manager,vso,monitoring"
NOT_FLOWING=()
for c in $(target_names); do
  require_context "$c"
  log "Target $c: $components"
  args=(--cluster "$c" --role target --components "$components" --context "$c" --fleet-dir "$FLEET_LOCAL_DIR"
        --vault-addr "$VAULT_FLEET_ADDR" --vault-ca-file "$CA_FILE"
        --vault-auth-mount "k8s-$c" --vault-auth-role tpg-vso)
  [[ -z "$RW_URL" ]] || args+=(--remote-write-url "$RW_URL")
  [[ -z "${ADDONS_EXISTING:-}" ]] || args+=(--existing "$ADDONS_EXISTING")
  bash "$ADDONS" "${args[@]}" || die "Helm add-ons failed on $c"
  helm --kube-context "$c" list -A -o json \
    | jq -r '.[] | select(.name == "cert-manager" or .name == "vault-secrets-operator" or .name == "kps" or .name == "tpg-ksm") | "  " + .namespace + "/" + .name + " " + .chart + " " + .status'
  case "$MONITORING_OPTION" in
    standalone)
      CUR_CTX="$c"
      if monitoring_flowing hk "$c" "$RW_WAIT_SECONDS" ck; then
        ok "$c: metrics reach the hub Prometheus"
      else
        warn "MONITORING_NOT_FLOWING $c: no metrics from this cluster on the hub after ${RW_WAIT_SECONDS}s (remote-write errors above; check the gateway: kubectl --context $HUB -n monitoring logs deploy/tpg-remote-write)"
        NOT_FLOWING+=("$c")
      fi ;;
    azure) azure_monitor_cluster "$c" ;;
  esac
  ok "$c add-ons"
done
[[ "$MONITORING_OPTION" != "azure" ]] || azure_grafana
[[ "${#NOT_FLOWING[@]}" -eq 0 ]] || die "MONITORING_NOT_FLOWING: ${NOT_FLOWING[*]} (the add-ons are installed; fix the remote write and re-run --only addons)"
