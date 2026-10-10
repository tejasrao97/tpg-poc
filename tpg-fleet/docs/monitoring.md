# Monitoring

How the Tanzu Postgres fleet is monitored: the two monitoring options, how target
clusters are connected to the hub, how to check that their metrics arrive, how to
rotate the remote-write credential, how to extend the dashboards, alerts and scrapes,
and (section 7, generated) every alert rule, dashboard, panel and PromQL query.

The option is chosen once per fleet with `MONITORING_OPTION` (`none`, `standalone` or
`azure`) in `tpg-aks-infra/env.sh`. The `addons` step of `tpg-aks-infra/scripts/run.sh`
stores it in `argo/tpg-settings` (`monitoringOption`), where `tpg-day0` and
`tpg-helm-addons` read it for new clusters. With `none` nothing is installed.

Examples use the hub `aks-tpg-hub`, the targets `aks-tpg-poc-01` to `aks-tpg-poc-03`
(and `aks-tpg-poc-04` as a new one), the resource group `rg-tpgpoc` in `eastus2`, the
Azure Monitor workspace `amw-tpgpoc` and Azure Managed Grafana `amg-tpgpoc` (the names
Terraform gives them with `prefix = "tpgpoc"`). Secrets are exported in the shell or
typed at a hidden prompt, never written to files; `<password from Vault
tpg/shared/monitoring-remote-write>` and similar placeholders stand for them.

## Contents

1. [Overview](#1-overview)
2. [Onboarding the targets to the hub](#2-onboarding-the-targets-to-the-hub)
3. [Verifying that metrics arrive](#3-verifying-that-metrics-arrive)
4. [Troubleshooting](#4-troubleshooting)
5. [Rotating the remote-write credential](#5-rotating-the-remote-write-credential)
6. [Extending](#6-extending)
7. [Reference: alert rules, dashboards and queries](#7-reference-alert-rules-dashboards-and-queries) (generated)

## 1. Overview

### 1.1 The two options

| | `standalone` (option B) | `azure` (option A) |
|---|---|---|
| Metrics store | Prometheus on the hub (Helm release `kps`, kube-prometheus-stack 91.4.0, 15 days, 100 GiB `managed-csi-premium`) | Azure Monitor workspace `amw-<prefix>` (managed Prometheus) |
| Collection on each target | Prometheus agent (release `kps`, 2 hours local retention) that remote-writes everything to the hub | Managed Prometheus add-on (`ama-metrics` pods in `kube-system`) that sends to the workspace |
| Grafana | Grafana of `kps` on the hub (internal load balancer, folder **Tanzu Postgres**) | Azure Managed Grafana `amg-<prefix>` (folder uid `tpg-postgres`) |
| Alerting | Grafana-managed rules on the hub Grafana, and the same rules as PrometheusRule `monitoring/tpg-rules` for the hub Alertmanager | Grafana-managed rules in Azure Managed Grafana |
| Label that tells clusters apart | `cluster`, set on each target as `prometheus.prometheusSpec.externalLabels.cluster` | `cluster`, added by the add-on (the AKS cluster name) |
| Installed by | `tpg-aks-infra` `addons` step (hub and targets); `tpg-day0` and `tpg-helm-addons` for targets | Terraform (`enable_azure_monitor = true`) or the `addons` step (add-on); the `bootstrap` step (Argo CD Applications); the `addons` step (Grafana import) |

Both options use the same dashboards and the same alert rules, generated from one
definition by `monitoring/grafana/generate.py` (section 7), and the same scrape
targets:

- the `postgres-exporter` sidecar (port `metrics`, 9187, TLS) of every Postgres data
  pod, through the PodMonitor `postgres-instances` (pods labelled `type: data`,
  `app: postgres`, every 10 seconds, timeout 8 seconds). The pod label
  `postgres-instance` becomes the metric label `postgres_instance`;
- kube-state-metrics release `tpg-ksm` (chart 8.5.0, `monitoring/ksm/values.yaml`) on
  every target: the standard `kube_*` metrics and the custom resource metrics
  `tanzu_postgres_instance_*`, `tanzu_postgres_backup_*` and `tanzu_postgres_restore_*`
  (Postgres, PostgresBackup, PostgresRestore);
- on the hub, the Argo Workflows controller (the `argo_workflows_tpg_*_result_total`
  counters that the WorkflowTemplates declare) and Vault (`/v1/sys/metrics`, for the
  `tpg-vault-sealed` rule).

### 1.2 What runs where

**Standalone, hub** (namespace `monitoring` unless noted):

| Object | Source |
|---|---|
| Helm release `kps`: Prometheus (remote-write receiver on, Service `prometheus-operated` ClusterIP only), Grafana, Alertmanager | `monitoring/standalone/hub/kps-values.yaml`, `monitoring/grafana/alerts/grafana-alerting-values.yaml` (generated), and any `KPS_HUB_EXTRA_VALUES` files |
| Secret `grafana-admin` (keys `admin-user`, `admin-password`) | `workflows/scripts/helm-addons.sh`: `GRAFANA_ADMIN_PASSWORD` when exported, otherwise a generated 24-character password |
| ServiceMonitors `argo-workflows-controller` (scrapes namespace `argo`) and `vault` (scrapes namespace `vault`), PrometheusRule `tpg-rules`, the five dashboard ConfigMaps `tpg-*-dashboard` | `kubectl apply -k monitoring/standalone/hub` |
| Remote-write gateway: ConfigMap `tpg-remote-write-nginx`, Deployment `tpg-remote-write` (nginx, 2 replicas) | `monitoring/standalone/hub/remote-write-gateway.yaml` (same kustomization) |
| Service `tpg-remote-write` (LoadBalancer, port 8443), Secret `tpg-remote-write-tls` (server certificate from the Vault CA), Secret `tpg-remote-write-htpasswd` (apr1 hash of the credential) | `tpg-aks-infra/scripts/steps/45-helm-addons.sh` |
| Role and RoleBinding `tpg-workflow-prometheus-query` (`get` on `services/proxy` of `prometheus-operated`, for `argo/tpg-workflow`) | `45-helm-addons.sh`; the workflows use it for the metrics flow check |
| `argo/tpg-settings`: `hubPrometheusRemoteWriteUrl=https://<gateway IP>:8443/api/v1/write`, `monitoringOption=standalone` | `45-helm-addons.sh` |

**Standalone, each target** (namespace `monitoring`):

| Object | Source |
|---|---|
| Helm release `kps`: Prometheus only (no Grafana, Alertmanager, kube-state-metrics or default rules), retention 2 hours, `externalLabels.cluster=<cluster>`, `remoteWrite` to `hubPrometheusRemoteWriteUrl` with basic auth from Secret `tpg-remote-write` and the CA from Secret `tpg-remote-write-ca`. The chart's default scrapes (kubelet and cAdvisor, node-exporter) stay on | `monitoring/standalone/targets/kps-values.yaml` plus the per-cluster overlay in `helm-addons.sh` |
| Helm release `tpg-ksm` with its ServiceMonitor (`prometheus.monitor.enabled=true`) | `monitoring/ksm/values.yaml` |
| PodMonitor `postgres-instances` | `kubectl apply -k monitoring/standalone/targets -n monitoring` |
| ServiceAccount `tpg-vso` and VaultStaticSecret `tpg-remote-write`: the Vault Secrets Operator keeps Secret `tpg-remote-write` (`username`, `password`) equal to Vault `tpg/shared/monitoring-remote-write` (refresh every 60 seconds), through VaultAuth `tpg-vault/tpg-vault` (auth mount `k8s-<cluster>`, role `tpg-vso`, policy `tpg-target`) | `monitoring/standalone/targets/remote-write-credentials.yaml` |
| Secret `tpg-remote-write-ca` (key `ca.crt`): a copy of `tpg-vault/vault-ca` | `helm-addons.sh` |

**Azure**:

| Where | Object | Source |
|---|---|---|
| Azure | Azure Monitor workspace `amw-<prefix>`, data collection endpoint and rule `MSProm-<location>-<prefix>` with one association per cluster, Azure Managed Grafana `amg-<prefix>` (Standard, linked to the workspace), roles `Monitoring Data Reader` (Grafana identity on the workspace) and `Grafana Admin` (the deploying identity) | Terraform `modules/monitoring` with `enable_azure_monitor = true`; with `create_role_assignments = false` (the default since Round 19) the role commands are in the output `role_assignments_to_create` |
| Every cluster | Managed Prometheus add-on (`ama-metrics` pods in `kube-system`) | Terraform (`monitor_metrics`), or the `addons` step for a cluster that does not have it |
| Hub | Argo CD Application `tpg-hub-monitoring` (project `tpg-hub`, automated sync): `azmonitoring.coreos.com` ServiceMonitors `argo-workflows-controller` and `vault` in `kube-system` | `bootstrap/monitoring/azure/app-monitoring-hub.yaml`, path `monitoring/azure/hub` |
| Each target | Argo CD Application `tpg-<cluster>-monitoring` from the ApplicationSet `tpg-monitoring-azure` (project `tpg`, automated sync, one per cluster Secret labelled `tpg.fleet/managed: "true"`): Helm release `tpg-ksm` in `monitoring` (ServiceMonitor off), PodMonitor `postgres-instances` and ServiceMonitor `tpg-kube-state-metrics` (`azmonitoring.coreos.com`) in `kube-system` | `bootstrap/monitoring/azure/appset-monitoring-targets.yaml`, path `monitoring/azure/targets` |
| Azure Managed Grafana | The five dashboards and the Grafana-managed rules | `monitoring/grafana/import-azure-grafana.sh`, run by the `addons` step |

### 1.3 Metric flow

Standalone:

```text
 target cluster aks-tpg-poc-0N, namespace monitoring              hub aks-tpg-hub, namespace monitoring
 +-------------------------------------------+                   +------------------------------------------------+
 | postgres-exporter :9187 in each data pod  |                   | Service tpg-remote-write (LoadBalancer :8443)  |
 |   <- PodMonitor postgres-instances        |                   |   internal, or public with                     |
 | tpg-ksm (kube_*, tanzu_postgres_*)        |                   |   loadBalancerSourceRanges = target egress     |
 | kubelet / cAdvisor, node-exporter         |                   |               |                                |
 |               |                           |   https :8443     |               v                                |
 |               v                           |   POST            | Deployment tpg-remote-write (nginx)            |
 | Prometheus (kps, 2h)                      |   /api/v1/write   |   TLS: Secret tpg-remote-write-tls (Vault CA)  |
 |   externalLabels.cluster=aks-tpg-poc-0N   | ----------------> |   basic auth: Secret tpg-remote-write-htpasswd |
 |   remoteWrite basicAuth:                  |                   |   only /api/v1/write is forwarded              |
 |     Secret tpg-remote-write <- VSO <- Vault                   |               |                                |
 |   tlsConfig.ca: Secret tpg-remote-write-ca|                   |               v                                |
 +-------------------------------------------+                   | Prometheus (kps, receiver, 15d)                |
                                                                 |   <- ServiceMonitors argo-workflows, vault     |
                                                                 |   -> PrometheusRule tpg-rules -> Alertmanager  |
                                                                 | Grafana (dashboards, Grafana-managed rules)    |
                                                                 +------------------------------------------------+
```

Azure:

```text
 every cluster (hub and targets)                     Azure, eastus2
 +------------------------------------------+        +----------------------------------+
 | ama-metrics (kube-system)                |  DCR   | Azure Monitor workspace          |
 |   default targets (kubelet, cAdvisor...) | -----> |   amw-tpgpoc                     |
 |   azmonitoring PodMonitor/ServiceMonitor |        +----------------------------------+
 |     postgres-instances, tpg-ksm (targets)|                        ^ Monitoring Data Reader
 |     argo-workflows, vault (hub)          |        +----------------------------------+
 +------------------------------------------+        | Azure Managed Grafana amg-tpgpoc |
                                                     |   dashboards, Grafana-managed    |
                                                     |   alert rules (folder tpg-postgres)
                                                     +----------------------------------+
```

On the standalone hub, the series that the hub Prometheus scrapes itself (Argo
Workflows, Vault, the hub's own kube-state-metrics and kubelet) have no `cluster`
label: `externalLabels.cluster: aks-tpg-hub` in `kps-values.yaml` is added only to
what the hub sends out (alerts), not to its stored series. The `argo_workflows_tpg_*`
counters carry a `cluster` label of their own: the target cluster of the workflow run.

## 2. Onboarding the targets to the hub

### 2.1 What `scripts/run.sh --only addons` does

Run from `tpg-aks-infra`, with the same `--hub` and `--targets` as the deployment:

```bash
cd ~/src/tpg-aks-infra
source env.sh                      # MONITORING_OPTION, FLEET_LOCAL_DIR, MONITORING_FLOW_TIMEOUT, KPS_HUB_EXTRA_VALUES
scripts/run.sh --hub install --targets terraform --only addons
# existing releases that differ are upgraded without a prompt with --yes (ADDONS_EXISTING=upgrade)
# ADDONS_SKIP_TARGETS=1 does the hub part only
```

`scripts/steps/45-helm-addons.sh`, standalone:

1. **Credential.** When Vault `tpg/shared/monitoring-remote-write` does not exist it is
   created once: `username` `tpg-remote-write`, `password` 32 random letters and
   digits. It is then read back; both keys must be set.
2. **Load balancer.** Service `monitoring/tpg-remote-write` (LoadBalancer, port 8443):
   - `monitoring.remoteWriteExposure: internal`: an Azure internal load balancer
     (annotation `service.beta.kubernetes.io/azure-load-balancer-internal: "true"`);
     the targets need a network path to the hub subnet (same VNet or peering);
   - `public` (the default): a public load balancer with `loadBalancerSourceRanges` =
     the egress CIDRs of every target in the inventory plus
     `monitoring.extraSourceCidrs`. A target's egress comes from
     `targets[].egressCidrs`, or, when that is empty and the cluster has `access: az`,
     from `az aks show` (the outbound IPs of the load balancer or managed NAT gateway).
     The step fails when the list is empty.
3. **TLS.** Secret `tpg-remote-write-tls` (`tls.crt`, `tls.key`, `ca.crt`): a 2-year
   server certificate signed by the Vault CA (Secret `vault/vault-ca-keypair`) for
   `IP:<load balancer IP>` and the in-cluster names of the Service. It is reissued
   when the names or the IP change, or 30 days before it expires.
4. **htpasswd.** Secret `tpg-remote-write-htpasswd` (key `htpasswd`,
   `tpg-remote-write:<apr1 hash>`), annotated with the SHA-256 of `username:password`
   (`tpg.fleet/credential-sha256`). It is rebuilt, and the gateway restarted, only
   when the credential in Vault changed.
5. **Query access for the workflows.** Role and RoleBinding
   `monitoring/tpg-workflow-prometheus-query`.
6. **Hub releases.** `tpg-fleet/workflows/scripts/helm-addons.sh --role hub
   --components monitoring`: Secret `grafana-admin` when it is missing, release `kps`,
   `kubectl apply -k monitoring/standalone/hub`, then a wait for the gateway pods.
7. **Settings.** `argo/tpg-settings` gets `hubPrometheusRemoteWriteUrl` and
   `monitoringOption: standalone`.
8. With `--expose-ui` (`EXPOSE_UI=1`): public Services `tpg-grafana-public`,
   `tpg-prometheus-public` and `tpg-alertmanager-public`, limited to
   `adminAllowedCidrs`. Prometheus and Alertmanager have no login.
9. **Every target.** `helm-addons.sh --role target --components
   cert-manager,vso,monitoring --remote-write-url <url>`: the Vault Secrets Operator
   and VaultAuth `tpg-vault/tpg-vault` first, then for monitoring: the ServiceAccount
   and VaultStaticSecret from `remote-write-credentials.yaml`, Secret
   `tpg-remote-write-ca`, a wait of up to 150 seconds for Secret `tpg-remote-write`
   (the step fails with the VaultStaticSecret conditions when it is not synced),
   release `kps` with `externalLabels.cluster` and `remoteWrite`, release `tpg-ksm`,
   `kubectl apply -k monitoring/standalone/targets`, and a wait for the Prometheus pod.
10. **Flow check.** For each target, `count(up{cluster="<target>"})` is queried on the
    hub Prometheus through the Kubernetes API service proxy every 15 seconds, for up to
    `MONITORING_FLOW_TIMEOUT` seconds (300). On timeout the target Prometheus log lines
    about remote write are printed and the target is reported `MONITORING_NOT_FLOWING`;
    after the last target the step fails with the list of those targets (the add-ons
    stay installed).

`45-helm-addons.sh`, azure:

1. `argo/tpg-settings` gets `monitoringOption: azure`.
2. For the hub and then every target: when the cluster has `access: az` and
   `az aks show --query azureMonitorProfile.metrics.enabled` is not `true`, the step
   runs `az aks update --enable-azure-monitor-metrics
   --azure-monitor-workspace-resource-id <monitoring.azureMonitorWorkspaceId>` (it
   fails when the inventory has no workspace). Clusters with `access: kubeconfig` are
   not changed; the step prints the command. Then it waits up to 600 seconds for the
   `ama-metrics` pods (`rsName=ama-metrics`) to be ready (`MONITORING_NOT_FLOWING`
   otherwise). Targets get `cert-manager` and `vso` only; nothing of monitoring is
   installed with Helm.
3. With `monitoring.grafanaName` and `monitoring.azureMonitorWorkspaceId` set: checks
   that the Grafana identity has `Monitoring Data Reader` on the workspace (and prints
   the `az role assignment create` command for an owner when it does not), then runs
   `monitoring/grafana/import-azure-grafana.sh <grafanaResourceGroup> <grafanaName>`.

The kube-state-metrics release and the `azmonitoring` monitors come from Argo CD: the
`bootstrap` step applies `bootstrap/monitoring/azure/`, and the ApplicationSet creates
one Application per registered cluster.

### 2.2 Manual equivalent: standalone hub

The same as step 2.1 by hand; `tpg-aks-infra/docs/README-manual-steps.md` sections
10.2 to 10.4 has the Vault helper `vt()` these steps can use instead of the UI.

```bash
export KUBECONFIG=~/src/tpg-aks-infra/.work/kubeconfig
export HUB=aks-tpg-hub
cd ~/src/tpg-fleet

# 1. Credential (only when tpg/shared/monitoring-remote-write does not exist yet).
#    In a shell in the Vault pod; the password is read from stdin (password=-), so it
#    never appears in a command line or a file:
kubectl --context $HUB -n vault exec -it vault-0 -- sh
#   vault login -method=userpass username=tpg-admin
#   vault kv get tpg/shared/monitoring-remote-write            # exists already: stop here
#   tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32 \
#     | vault kv put tpg/shared/monitoring-remote-write username=tpg-remote-write password=-
#   exit

# 2. Load balancer (public here; internal: the annotation
#    service.beta.kubernetes.io/azure-load-balancer-internal: "true" and no source ranges)
kubectl --context $HUB create namespace monitoring --dry-run=client -o yaml | kubectl --context $HUB apply -f -
cat <<'EOF' | kubectl --context $HUB apply -f -
apiVersion: v1
kind: Service
metadata:
  name: tpg-remote-write
  namespace: monitoring
  labels: {app.kubernetes.io/name: tpg-remote-write, tpg.fleet/managed: "true"}
spec:
  type: LoadBalancer
  selector: {app.kubernetes.io/name: tpg-remote-write}
  ports: [{name: https, port: 8443, targetPort: 8443, protocol: TCP}]
  loadBalancerSourceRanges: ["20.85.112.14/32", "20.85.113.201/32", "20.96.40.7/32"]   # target egress
EOF
kubectl --context $HUB -n monitoring get svc tpg-remote-write -w      # until EXTERNAL-IP is set
RW_IP="$(kubectl --context $HUB -n monitoring get svc tpg-remote-write -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"

# 3. TLS: Secret monitoring/tpg-remote-write-tls with tls.crt, tls.key and ca.crt, a server
#    certificate for IP:$RW_IP and DNS:tpg-remote-write, tpg-remote-write.monitoring,
#    tpg-remote-write.monitoring.svc, tpg-remote-write.monitoring.svc.cluster.local, signed
#    by the CA in Secret vault/vault-ca-keypair (README-manual-steps.md 6.2 shows the openssl
#    commands; vault_ca_issue in tpg-aks-infra/scripts/lib/vault.sh keeps the CA key in a
#    mode-700 temporary directory that is removed on exit).

# 4. htpasswd from the credential, typed at a hidden prompt (copy it from the Vault UI)
read -rsp 'remote-write password: ' RW_PASSWORD; echo
printf 'tpg-remote-write:%s\n' "$(printf '%s' "$RW_PASSWORD" | openssl passwd -apr1 -stdin)" \
  | kubectl --context $HUB -n monitoring create secret generic tpg-remote-write-htpasswd \
      --from-file=htpasswd=/dev/stdin --dry-run=client -o yaml | kubectl --context $HUB apply -f -
kubectl --context $HUB -n monitoring annotate secret tpg-remote-write-htpasswd --overwrite \
  "tpg.fleet/credential-sha256=$(printf 'tpg-remote-write:%s' "$RW_PASSWORD" | openssl dgst -sha256 -r | cut -d' ' -f1)"
unset RW_PASSWORD

# 5. Query access for the workflows (the metrics flow check)
cat <<'EOF' | kubectl --context $HUB apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: {name: tpg-workflow-prometheus-query, namespace: monitoring}
rules:
  - apiGroups: [""]
    resources: [services/proxy]
    resourceNames: [prometheus-operated, "http:prometheus-operated:9090"]
    verbs: [get]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: {name: tpg-workflow-prometheus-query, namespace: monitoring}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: Role, name: tpg-workflow-prometheus-query}
subjects: [{kind: ServiceAccount, name: tpg-workflow, namespace: argo}]
EOF

# 6. Grafana admin Secret (only when it is missing), kube-prometheus-stack, the kustomization
read -rsp 'Grafana admin password: ' GRAFANA_ADMIN_PASSWORD; echo; export GRAFANA_ADMIN_PASSWORD
kubectl --context $HUB -n monitoring create secret generic grafana-admin \
  --from-literal=admin-user=admin --from-literal=admin-password="$GRAFANA_ADMIN_PASSWORD"
helm --kube-context $HUB upgrade --install kps kube-prometheus-stack \
  --repo https://prometheus-community.github.io/helm-charts --version 91.4.0 \
  -n monitoring --create-namespace \
  -f monitoring/standalone/hub/kps-values.yaml \
  -f monitoring/grafana/alerts/grafana-alerting-values.yaml --wait --timeout 15m
kubectl --context $HUB apply -k monitoring/standalone/hub
kubectl --context $HUB -n monitoring rollout restart deploy/tpg-remote-write   # the gateway reads htpasswd at start
kubectl --context $HUB -n monitoring rollout status deploy/tpg-remote-write

# 7. The URL the targets write to
kubectl --context $HUB -n argo patch configmap tpg-settings --type merge \
  -p "{\"data\":{\"hubPrometheusRemoteWriteUrl\":\"https://${RW_IP}:8443/api/v1/write\",\"monitoringOption\":\"standalone\"}}"
```

The egress IPs of a target, for `loadBalancerSourceRanges` (what the step discovers
when `targets[].egressCidrs` is empty):

```bash
az aks show -g rg-tpgpoc -n aks-tpg-poc-01 --query networkProfile.outboundType -o tsv    # loadBalancer
az aks show -g rg-tpgpoc -n aks-tpg-poc-01 \
  --query 'networkProfile.loadBalancerProfile.effectiveOutboundIPs[].id' -o tsv \
  | while read -r id; do echo "$(az network public-ip show --ids "$id" --query ipAddress -o tsv)/32"; done
# managedNATGateway: networkProfile.natGatewayProfile.effectiveOutboundIPs[].id
# userDefinedRouting (firewall): not discoverable, set targets[].egressCidrs in the inventory
```

### 2.3 Manual equivalent: standalone target

Prerequisites on the target: the Vault Secrets Operator with VaultConnection and
VaultAuth `tpg-vault/tpg-vault` and Secret `tpg-vault/vault-ca` (component `vso`, or
README-manual-steps.md 10.1), and the Vault auth mount `auth/k8s-<target>` from the
`register` step.

```bash
c=aks-tpg-poc-04
RW="$(kubectl --context $HUB -n argo get cm tpg-settings -o jsonpath='{.data.hubPrometheusRemoteWriteUrl}')"
cd ~/src/tpg-fleet

kubectl --context $c create namespace monitoring --dry-run=client -o yaml | kubectl --context $c apply -f -
kubectl --context $c apply -f monitoring/standalone/targets/remote-write-credentials.yaml
kubectl --context $c -n tpg-vault get secret vault-ca -o jsonpath='{.data.ca\.crt}' | base64 -d \
  | kubectl --context $c -n monitoring create secret generic tpg-remote-write-ca \
      --from-file=ca.crt=/dev/stdin --dry-run=client -o yaml | kubectl --context $c apply -f -
kubectl --context $c -n monitoring wait --for=create secret/tpg-remote-write --timeout=150s   # synced from Vault (kubectl 1.31+)

helm --kube-context $c upgrade --install kps kube-prometheus-stack \
  --repo https://prometheus-community.github.io/helm-charts --version 91.4.0 -n monitoring \
  -f monitoring/standalone/targets/kps-values.yaml \
  --set-string prometheus.prometheusSpec.externalLabels.cluster=$c \
  --set-json "prometheus.prometheusSpec.remoteWrite=[{\"url\":\"$RW\",
    \"basicAuth\":{\"username\":{\"name\":\"tpg-remote-write\",\"key\":\"username\"},\"password\":{\"name\":\"tpg-remote-write\",\"key\":\"password\"}},
    \"tlsConfig\":{\"ca\":{\"secret\":{\"name\":\"tpg-remote-write-ca\",\"key\":\"ca.crt\"}}}}]" \
  --wait --timeout 15m
helm --kube-context $c upgrade --install tpg-ksm kube-state-metrics \
  --repo https://prometheus-community.github.io/helm-charts --version 8.5.0 -n monitoring \
  -f monitoring/ksm/values.yaml --set prometheus.monitor.enabled=true --wait --timeout 15m
kubectl --context $c apply -k monitoring/standalone/targets -n monitoring
kubectl --context $c -n monitoring get pods -l app.kubernetes.io/name=prometheus
```

The workflows do the same for one or more registered clusters, followed by the flow
check of step 10 (`MONITORING_NOT_FLOWING` when it fails):

```bash
argo submit -n argo --from workflowtemplate/tpg-helm-addons -p 'clusters=[aks-tpg-poc-04]' --watch
argo submit -n argo --from workflowtemplate/tpg-helm-addons -p 'clusters=[aks-tpg-poc-04]' \
  -p 'components=[monitoring]' -p existingAddons=upgrade --watch        # re-apply changed values
```

`tpg-day0` runs the same installation (`installAddons=true`, the default) before it
deploys the operator.

### 2.4 Manual equivalent: azure

```bash
AMW="$(az monitor account show -g rg-tpgpoc -n amw-tpgpoc --query id -o tsv)"
c=aks-tpg-poc-04

# The add-on, when it is off (Terraform clusters have it)
az aks show -g rg-tpgpoc -n $c --query azureMonitorProfile.metrics.enabled -o tsv
az aks update -g rg-tpgpoc -n $c --enable-azure-monitor-metrics --azure-monitor-workspace-resource-id "$AMW"
kubectl --context $c -n kube-system get pods -l rsName=ama-metrics

# kube-state-metrics and the monitors: the Argo CD Applications (once per fleet; the bootstrap step)
kubectl --context $HUB apply -f bootstrap/monitoring/azure/
kubectl --context $HUB -n argocd get application tpg-hub-monitoring tpg-$c-monitoring
kubectl --context $c -n kube-system get podmonitors.azmonitoring.coreos.com,servicemonitors.azmonitoring.coreos.com
helm --kube-context $c -n monitoring list          # tpg-ksm, installed by Argo CD

# Grafana: read access to the workspace (an owner creates it), then the import
PID="$(az grafana show -g rg-tpgpoc -n amg-tpgpoc --query identity.principalId -o tsv)"
az role assignment list --scope "$AMW" --assignee "$PID" --query "[].roleDefinitionName" -o tsv
az role assignment create --assignee-object-id "$PID" --assignee-principal-type ServicePrincipal \
  --role "Monitoring Data Reader" --scope "$AMW"
monitoring/grafana/import-azure-grafana.sh rg-tpgpoc amg-tpgpoc   # needs Grafana Admin on amg-tpgpoc
```

Without Argo CD, the same objects are `helm upgrade --install tpg-ksm kube-state-metrics
--repo https://prometheus-community.github.io/helm-charts --version 8.5.0 -n monitoring
--create-namespace -f monitoring/ksm/values.yaml` and `kubectl apply -k
monitoring/azure/targets` on each target, and `kubectl apply -k monitoring/azure/hub`
on the hub.

### 2.5 Adding a newly registered target

**Standalone.** A new target needs three things from the hub side: a network path to
Vault (for its Vault Secrets Operator), a network path to the gateway, and a Vault
login that can read `tpg/shared/monitoring-remote-write`.

1. Add the cluster: Terraform (`target_cluster_count`) or `inventory/clusters.yaml`
   (`wave: 1` or higher; `egressCidrs` when its egress cannot be discovered with `az`:
   `access: kubeconfig`, user-defined routing, a firewall). Then run the whole
   sequence, which is idempotent for the existing clusters:

   ```bash
   scripts/run.sh --hub install --targets terraform
   ```

   - `register` creates `auth/k8s-<cluster>` (role `tpg-vso`, policy `tpg-target`,
     which may read `tpg/data/shared/monitoring-remote-write`) and, with
     `vault.exposure: public`, recomputes the `loadBalancerSourceRanges` of Service
     `vault/vault-fleet` from every target's egress plus `vault.extraSourceCidrs`;
   - `addons` recomputes the source ranges of Service `monitoring/tpg-remote-write`
     (every target's egress plus `monitoring.extraSourceCidrs`), installs the new
     target's add-ons and checks that its metrics arrive.
2. When the cluster is registered already and only its monitoring is missing,
   `tpg-helm-addons -p 'clusters=[<cluster>]'` (or `tpg-day0`) is enough, but the
   workflows do not change any load balancer: with public exposure the new egress CIDR
   must already be in both source range lists (`--only register` and `--only addons`
   put it there). Check:

   ```bash
   kubectl --context $HUB -n monitoring get svc tpg-remote-write -o jsonpath='{.spec.loadBalancerSourceRanges}'; echo
   kubectl --context $HUB -n vault get svc vault-fleet -o jsonpath='{.spec.loadBalancerSourceRanges}'; echo
   ```

   A range patched in by hand (`kubectl patch svc ... loadBalancerSourceRanges`) is
   replaced by the next `--only register` or `--only addons`, which rebuild the lists
   from the inventory: put the CIDR in `targets[].egressCidrs`,
   `monitoring.extraSourceCidrs` or `vault.extraSourceCidrs` instead.
3. The credential needs no action: the VaultStaticSecret on the target reads it with
   the cluster's own Vault login, and every target uses the same credential.

**Azure.** Terraform clusters get the add-on and the data collection rule association
from `terraform apply`; a pre-created cluster gets the add-on from `--only addons`.
The ApplicationSet generates `tpg-<cluster>-monitoring` as soon as the `register` step
has created the cluster Secret with the label `tpg.fleet/managed: "true"`. No load
balancer or credential is involved; `tpg-day0` and `tpg-helm-addons` check that the
`ama-metrics` pods run and fail with `MONITORING_NOT_FLOWING` when there are none.

## 3. Verifying that metrics arrive

### 3.1 Standalone: query the hub Prometheus

The hub Prometheus has no public endpoint. The Kubernetes API service proxy reaches it
with the kubeconfig you already use, which is what the `addons` step and the workflows
do:

```bash
# promq CONTEXT QUERY: instant query against the Prometheus of that cluster
promq() {
  kubectl --context "$1" get --raw \
    "/api/v1/namespaces/monitoring/services/http:prometheus-operated:9090/proxy/api/v1/query?query=$(jq -rn --arg q "$2" '$q | @uri')" \
    | jq -r '.data.result[] | "\(.metric | to_entries | map("\(.key)=\(.value)") | join(",")) \(.value[1])"'
}

promq aks-tpg-hub 'count(up{cluster="aks-tpg-poc-01"})'   # the check of the addons step and the workflows: > 0
promq aks-tpg-hub 'count by (cluster) (up)'               # one line per target; the empty cluster is the hub itself
promq aks-tpg-hub 'count by (cluster, job) (up == 0)'     # targets that cannot be scraped
promq aks-tpg-hub 'count by (cluster) (up{postgres_instance!=""})'                     # postgres-exporter pods
promq aks-tpg-hub 'count by (cluster) (tanzu_postgres_instance_state{state="Running"})' # Postgres instances
promq aks-tpg-hub 'count by (cluster) (kube_statefulset_replicas{namespace=~"pg-.*"})'  # Postgres StatefulSets
promq aks-tpg-hub 'count by (job) (up{cluster=""})'       # series without a cluster label (section 4.3)
```

The same queries work in Grafana Explore (data source `Prometheus`). The gateway
access log shows each write: `kubectl --context aks-tpg-hub -n monitoring logs
deploy/tpg-remote-write --tail=20` prints `"POST /api/v1/write HTTP/1.1" 204` lines
when the writes are accepted. `tpg-aks-infra/scripts/steps/60-verify.sh` (`--only
verify`) runs the same `up{cluster="<target>"}` query once per target, without waiting.

### 3.2 Azure: query the Azure Monitor workspace

```bash
QE="$(az monitor account show -g rg-tpgpoc -n amw-tpgpoc --query metrics.prometheusQueryEndpoint -o tsv)"
# https://amw-tpgpoc-<suffix>.eastus2.prometheus.monitor.azure.com
TOKEN="$(az account get-access-token --resource https://prometheus.monitor.azure.com --query accessToken -o tsv)"
curl -sS -H "Authorization: Bearer $TOKEN" --data-urlencode 'query=count by (cluster) (up)' "$QE/api/v1/query" \
  | jq -r '.data.result[] | "\(.metric.cluster) \(.value[1])"'
curl -sS -H "Authorization: Bearer $TOKEN" --data-urlencode 'query=count by (cluster) (up{postgres_instance!=""})' \
  "$QE/api/v1/query" | jq -r '.data.result[] | "\(.metric.cluster) \(.value[1])"'
unset TOKEN
```

Your identity needs `Monitoring Data Reader` on the workspace. Grafana Explore on
`amg-tpgpoc` (data source `Managed_Prometheus_...`) runs the same queries.

### 3.3 In the dashboards

The dashboard variable `cluster` lists the values of `label_values(tanzu_postgres_instance_state, cluster)`:
a cluster appears there once `tpg-ksm` reports at least one Postgres object on it. A new
target without instances has metrics (`up`) but is not in the list yet.

## 4. Troubleshooting

### 4.1 Where the errors show

| What | Command |
|---|---|
| Remote-write errors of a target (the lines the flow check prints) | `kubectl --context aks-tpg-poc-01 -n monitoring logs -l app.kubernetes.io/name=prometheus -c prometheus --tail=500 \| grep -iE 'remote\|write\|401\|403\|x509\|tls\|dial'` |
| Status code of every write at the gateway | `kubectl --context aks-tpg-hub -n monitoring logs deploy/tpg-remote-write --tail=50` |
| The credential the target has, from Vault | `kubectl --context aks-tpg-poc-01 -n monitoring get vaultstaticsecret tpg-remote-write -o json \| jq '.status'` |
| The URL, labels and credential references the target Prometheus uses | `kubectl --context aks-tpg-poc-01 -n monitoring get prometheus -o json \| jq '.items[0].spec \| {externalLabels, remoteWrite}'` |

### 4.2 Gateway answers 401 or 403

nginx answers **401** when the basic-auth user or password does not match
`tpg-remote-write-htpasswd`. Prometheus treats a 401 as not recoverable and does not
retry it: every rejected batch is lost, and the dashboards show a gap for that cluster.

1. Compare the credential on both sides without printing it. The hub Secret carries
   the SHA-256 of `username:password` it was built from; compute the same over the
   target's Secret:

   ```bash
   kubectl --context aks-tpg-hub -n monitoring get secret tpg-remote-write-htpasswd \
     -o jsonpath='{.metadata.annotations.tpg\.fleet/credential-sha256}'; echo
   kubectl --context aks-tpg-poc-01 -n monitoring get secret tpg-remote-write -o json \
     | jq -j '.data | (.username | @base64d) + ":" + (.password | @base64d)' \
     | openssl dgst -sha256 -r | cut -d' ' -f1
   ```

2. Different hashes:
   - after a rotation (`tpg-rotate-credential secretType=monitoring-remote-write`, or a
     change in the Vault UI), the gateway still has the old one: run
     `scripts/run.sh ... --only addons` (section 5);
   - the target's Secret is older than Vault: the VaultStaticSecret is not syncing.
     Its status and `kubectl --context aks-tpg-poc-01 -n vault-secrets-operator-system
     logs deploy/vault-secrets-operator-controller-manager` show why (Vault sealed:
     `tpg-vault-sealed` fires; the Vault load balancer does not accept the target's
     egress; `auth/k8s-<cluster>` missing: run `--only register`).
3. Same hashes but still 401: the gateway pods started before the htpasswd Secret
   changed. `kubectl --context aks-tpg-hub -n monitoring rollout restart
   deploy/tpg-remote-write`.

The gateway itself never answers **403**: its configuration has no allow or deny
rules. A 403 in the target log comes from something between the target and the hub
(an egress proxy or firewall). A target whose egress IP is not in the public load
balancer's `loadBalancerSourceRanges` gets no answer at all: `dial tcp
<ip>:8443: i/o timeout` or `context deadline exceeded` (section 4.4).

Other answers of the gateway: **404** for any path other than `/api/v1/write`
(`hubPrometheusRemoteWriteUrl` must end with `/api/v1/write`); **502** or **504** when it
cannot reach `prometheus-operated:9090` (the hub Prometheus pod is down or restarting:
`kubectl --context aks-tpg-hub -n monitoring get pods -l app.kubernetes.io/name=prometheus`);
**413** for a request over 64 MiB (`client_max_body_size`); **400** is the hub
Prometheus rejecting samples (`out of order sample`, `duplicate sample`), which happens
when two senders use the same `cluster` label value.

### 4.3 Missing `cluster` label

Symptoms: the gateway logs 204 for a target, but `count(up{cluster="<target>"})` is 0
and the cluster is missing from the dashboards; on the hub,
`count by (job) (up{cluster=""})` lists jobs that only targets run, such as
`monitoring/postgres-instances` or `tpg-ksm-kube-state-metrics`.

Cause: the target Prometheus has no `externalLabels.cluster`. `helm-addons.sh` always
sets it; a `kps` release installed or upgraded by hand without
`--set-string prometheus.prometheusSpec.externalLabels.cluster=<target>` loses it.

```bash
kubectl --context aks-tpg-poc-01 -n monitoring get prometheus -o jsonpath='{.items[0].spec.externalLabels}'; echo
helm --kube-context aks-tpg-poc-01 -n monitoring get values kps -o json | jq '.prometheus.prometheusSpec.externalLabels'
```

Fix: `argo submit -n argo --from workflowtemplate/tpg-helm-addons -p
'clusters=[aks-tpg-poc-01]' -p 'components=[monitoring]' -p existingAddons=upgrade --watch`, or
`scripts/run.sh ... --only addons --yes`. The series written without the label stay
in the hub Prometheus until its retention (15 days) removes them.

Azure: the add-on sets `cluster` to the AKS cluster name. When the
`cluster_alias` setting of `kube-system/ama-metrics-settings-configmap` is set on a
cluster, the label carries the alias instead, and the dashboards show that value.

### 4.4 Remote-write queue errors on a target

The target Prometheus keeps its samples in its write-ahead log and sends them from a
queue per remote-write URL. Recoverable failures (network errors, 5xx answers) are
retried with backoff and show as `Failed to send batch, retrying`; the queue then
grows. With 2 hours of local retention, an outage of more than about two hours loses
the oldest samples. Non-recoverable answers (4xx such as 400 and 401) drop the batch.

Query the target's own Prometheus (its samples may not reach the hub):

```bash
promq aks-tpg-poc-01 'rate(prometheus_remote_storage_samples_failed_total[5m])'     # dropped, non-recoverable
promq aks-tpg-poc-01 'rate(prometheus_remote_storage_samples_retried_total[5m])'    # retried, recoverable
promq aks-tpg-poc-01 'prometheus_remote_storage_samples_pending'                     # waiting in the queue
promq aks-tpg-poc-01 'max_over_time(prometheus_remote_storage_highest_timestamp_in_seconds[5m]) - ignoring(remote_name, url) group_right max_over_time(prometheus_remote_storage_queue_highest_sent_timestamp_seconds[5m])'   # seconds behind
promq aks-tpg-poc-01 'prometheus_remote_storage_shards_desired / prometheus_remote_storage_shards_max'   # > 1: throughput limit
```

| Log line on the target | Cause | Fix |
|---|---|---|
| `server returned HTTP status 401 Unauthorized` | Credential mismatch | Section 4.2 |
| `x509: certificate signed by unknown authority` | `tpg-remote-write-ca` is not the CA that signed `tpg-remote-write-tls` | Re-run the target's add-ons (`tpg-helm-addons`), which copy `tpg-vault/vault-ca` again |
| `x509: certificate is valid for <ip>, not <other ip>` | The gateway load balancer got a new IP (Service recreated) | `--only addons --yes`: it reissues the certificate for the new IP, updates `hubPrometheusRemoteWriteUrl` and upgrades every target's `kps` to the new URL (without `--yes` the changed release is skipped or asked about) |
| `dial tcp <ip>:8443: i/o timeout`, `context deadline exceeded` | No network path: public exposure and the target's egress not in `loadBalancerSourceRanges`; internal exposure without peering or with an NSG rule in the way | Section 2.5; compare the Service's ranges with the target's egress IPs (section 2.2) |
| `connection refused` | No gateway pod ready | `kubectl --context aks-tpg-hub -n monitoring get pods -l app.kubernetes.io/name=tpg-remote-write` (a missing `tpg-remote-write-tls` or `tpg-remote-write-htpasswd` Secret keeps them from starting: `--only addons`) |
| `Remote storage resharding` | The queue adapts its parallelism | Nothing, unless `shards_desired / shards_max` stays above 1 |

A pod that is not scraped (`up == 0` for the PodMonitor `postgres-instances`) is a
target-side problem, not a remote-write one: with the network policy `baseline`
(`tpg-network-policy`), port 9187 accepts only the namespaces `monitoring` and
`kube-system`, which is where both options scrape from.

### 4.5 Azure

| Symptom | Check |
|---|---|
| No data at all in Azure Managed Grafana | The Grafana identity needs `Monitoring Data Reader` on the workspace (section 2.4); the `Managed_Prometheus_...` data source must exist (the import script stops with `No Managed_Prometheus data source found` otherwise) |
| One cluster missing | `az aks show -g rg-tpgpoc -n <cluster> --query azureMonitorProfile.metrics.enabled`; `kubectl --context <cluster> -n kube-system get pods -l rsName=ama-metrics` |
| `tanzu_postgres_*` or `pg_*` missing for a cluster | `kubectl --context aks-tpg-hub -n argocd get application tpg-<cluster>-monitoring` must be `Synced/Healthy`; the monitors in `kube-system` (section 2.4) |
| Argo Workflows or Vault panels empty | Application `tpg-hub-monitoring` (`Synced/Healthy`), and the add-on on the hub |

## 5. Rotating the remote-write credential

The credential in Vault `tpg/shared/monitoring-remote-write` (`username`,
`password`) is used in two places: the targets read it through their Vault Secrets
Operator (within 60 seconds), and the hub gateway checks it against the htpasswd
Secret, which only `tpg-aks-infra` rebuilds.

```bash
# 1. The new value, wrapped in Vault (single use, 10 minutes). The script asks for the
#    password at a hidden prompt, or takes REMOTE_WRITE_PASSWORD when it is exported
#    (16 characters or more); the username stays tpg-remote-write.
cd ~/src/tpg-aks-infra
TOKEN="$(scripts/vault-secret.sh wrap monitoring-remote-write)"

# 2. The workflow unwraps it, checks the length and writes a new version of the path
argo submit -n argo --from workflowtemplate/tpg-rotate-credential \
  -p secretType=monitoring-remote-write -p wrappingToken="$TOKEN" --watch
unset TOKEN

# 3. At once: rebuild the gateway's htpasswd from Vault, restart the gateway and check
#    that every target's metrics arrive
scripts/run.sh --hub install --targets terraform --only addons
```

The run ends with the result `UPDATED` for the hub and the warning
`GATEWAY_NOT_UPDATED`: until step 3 has run, the gateway accepts only the previous
credential, and every target whose Vault Secrets Operator has already picked up the
new one is refused with 401 (its samples of that period are lost, section 4.2). Step 3
compares the SHA-256 of the credential in Vault with the annotation on
`tpg-remote-write-htpasswd`, so it rebuilds the Secret only when the credential
changed. Without `wrappingToken` (a value changed in the Vault UI), the workflow only
records the same warning.

## 6. Extending

All dashboards and alert rules are defined in `monitoring/grafana/generate.py`. Its
outputs are committed; never edit them by hand:

| Output | Used by |
|---|---|
| `monitoring/grafana/alerts/grafana-alerting-values.yaml` | Standalone hub: Helm values of `kps` (`grafana.alerting`) |
| `monitoring/grafana/alerts/api/<uid>.json` | Azure: `import-azure-grafana.sh` (POST or PUT per uid) |
| `monitoring/standalone/hub/prometheusrule-tpg.yaml` | Standalone hub: PrometheusRule `tpg-rules` |
| `monitoring/standalone/hub/dashboards/<uid>.json` | Standalone hub (ConfigMaps of the kustomization) and Azure (import) |
| `docs/monitoring.md`, section 7 | This page |

After every change:

```bash
cd ~/src/tpg-fleet
python3 monitoring/grafana/generate.py            # writes every output above
python3 monitoring/grafana/generate.py --check    # exit 1 when an output is out of date
tests/monitoring/run.sh                           # --check, rule and dashboard names in this page, promtool
scripts/validate.sh                               # kubeconform of the PrometheusRule, dashboards in the kustomization
```

Commit the definitions and the generated files together.

### 6.1 Add a panel

Add a `b.panel(...)` call to the dashboard's block in section 5 of `generate.py`
(`panel(...)` in section 4 for the fleet dashboard):

```python
b.panel("Temporary file bytes per second", "timeseries",
        [('sum by (cluster, postgres_instance) (rate(pg_stat_database_temp_bytes{%s}[5m]))' % PG,
          "{{cluster}}/{{postgres_instance}}")],
        0, 12, 8, unit("Bps"),
        description="Queries that spill to disk (work_mem too small for their sorts and hashes).")
```

Arguments: title, panel type, a list of `(PromQL, legend)` (refIds A, B, ...; `stat`,
`table`, `bargauge` and `gauge` run instant queries, `timeseries`, `barchart` and
`state-timeline` range queries), x, width and height on the 24-column grid, then the
field config. A panel whose `x + width` reaches 24 (or `newline=True`) ends the grid
row. Use the selectors `PG` (exporter metrics), `CR` (custom resource metrics) and
`NSX` (pod and volume metrics in `pg-<instance>`) so the `cluster` and `instance`
variables apply. A metric family that `METRIC_SOURCES` in `generate.py` does not know
is listed as "not classified" in section 7, which `tests/monitoring` refuses: add its
source there.

Check the query first (section 3.1), then regenerate and deploy:

- standalone: `kubectl --context aks-tpg-hub apply -k monitoring/standalone/hub` (the
  Grafana sidecar reloads the dashboard ConfigMaps);
- azure: `monitoring/grafana/import-azure-grafana.sh rg-tpgpoc amg-tpgpoc`.

### 6.2 Add an alert rule

Append a `dict` to `ALERTS`:

```python
dict(uid="tpg-volume-almost-full", title="Postgres volume above 90%",
     expr='max by (cluster, namespace, persistentvolumeclaim) (kubelet_volume_stats_used_bytes{namespace=~"pg-.*"}) / max by (cluster, namespace, persistentvolumeclaim) (kubelet_volume_stats_capacity_bytes{namespace=~"pg-.*"})',
     op="gt", threshold=0.9, for_="15m", severity="warning",
     summary="{{ $labels.cluster }}/{{ $labels.persistentvolumeclaim }} is more than 90% full"),
```

- `uid`: the Grafana rule uid and the file `alerts/api/<uid>.json`; the PrometheusRule
  alert is `TanzuPostgres` plus the uid without `tpg-` in CamelCase
  (`TanzuPostgresVolumeAlmostFull`).
- `expr`: the value, without the comparison; `op` (`gt` or `lt`) and `threshold` make
  the condition. Aggregate `by` the labels the `summary` uses.
- `for_`: `"0m"` fires at the first evaluation.
- The Alerts dashboard gets a panel for the rule automatically.

Deploy:

- standalone: the Grafana rules are Helm values of `kps`, so the release must be
  upgraded: `scripts/run.sh ... --only addons --yes` (without `--yes` the changed
  release is reported `SKIPPED_EXISTS` or asked about). It also applies the
  kustomization with the PrometheusRule and the Alerts dashboard;
- azure: `monitoring/grafana/import-azure-grafana.sh rg-tpgpoc amg-tpgpoc`.

Removing a rule: delete its `dict`, regenerate, and delete
`monitoring/grafana/alerts/api/<uid>.json` (`--check` fails while the file is there,
because the import would keep creating the rule). The import script never deletes a
rule in Azure Managed Grafana: remove it there with `DELETE
/api/v1/provisioning/alert-rules/<uid>` or in the UI. On the standalone hub Grafana,
a rule that disappears from the provisioning file is removed only when the file lists
it under `deleteRules` (Grafana alerting provisioning), or by hand in the UI.

### 6.3 Add a dashboard

```python
b = Board("tpg-vacuum", "Tanzu Postgres - Vacuum", "Autovacuum activity and dead tuples per instance.",
          [V_DS, V_CLUSTER, V_INSTANCE])
b.row("Dead tuples")
b.panel(...)
b.write()
```

Then add it to the hub kustomization, which turns every dashboard file into a
ConfigMap for the Grafana sidecar:

```yaml
# monitoring/standalone/hub/kustomization.yaml, configMapGenerator
  - name: tpg-vacuum-dashboard
    files:
      - dashboards/tpg-vacuum.json
```

`import-azure-grafana.sh` imports every file in `dashboards/`. The dashboard names
are also listed in `scripts/validate.sh` (dashboards exist and are in the
kustomization) and in `tpg-aks-infra/scripts/steps/60-verify.sh` (ConfigMap
`<uid>-dashboard` on the hub): add the new uid to both lists.

### 6.4 Add a metric scrape

Scrape objects are applied per option and per cluster role; each directory is a
kustomization:

| Option | Where the metric is | Directory | Kind | Applied by |
|---|---|---|---|---|
| standalone | targets | `monitoring/standalone/targets/` | `monitoring.coreos.com/v1` PodMonitor or ServiceMonitor, namespace `monitoring` (the kustomization is applied with `-n monitoring`) | `helm-addons.sh` (`tpg-helm-addons -p components=monitoring`, `tpg-day0`, `--only addons`) |
| standalone | hub | `monitoring/standalone/hub/` | `monitoring.coreos.com/v1`, namespace `monitoring` (set by the kustomization) | `helm-addons.sh --role hub` (`--only addons`), or `kubectl apply -k monitoring/standalone/hub` |
| azure | targets | `monitoring/azure/targets/` | `azmonitoring.coreos.com/v1` PodMonitor or ServiceMonitor in `kube-system`, like the existing ones | Argo CD Application `tpg-<cluster>-monitoring` (automated sync from `main`) |
| azure | hub | `monitoring/azure/hub/` | `azmonitoring.coreos.com/v1`, `kube-system` | Argo CD Application `tpg-hub-monitoring` (automated sync) |

Add the file to the directory's `kustomization.yaml` (`resources:`); both Prometheus
releases select monitors in every namespace (`podMonitorSelectorNilUsesHelmValues:
false`, `serviceMonitorSelectorNilUsesHelmValues: false`). On the standalone option
the target's series get the `cluster` label from the external label; series scraped
by the hub Prometheus itself do not have one (section 1.3). When the new target is a
namespace with the `baseline` network policy, its port must be open to the scraping
namespace. For a new custom resource metric, extend `customResourceState` in
`monitoring/ksm/values.yaml` (and the RBAC `extraRules`) instead: both options use
that file.

Then check the series (section 3), use it in a panel or rule (6.1, 6.2), and run
`scripts/validate.sh` (kustomize build and kubeconform of every monitoring directory).

## 7. Reference: alert rules, dashboards and queries

<!-- BEGIN GENERATED: monitoring-reference -->
Generated by `monitoring/grafana/generate.py` from the same definitions as the dashboards, the Grafana alert rules and the PrometheusRule. Do not edit it by hand: change the definitions, run `python3 monitoring/grafana/generate.py`, and `python3 monitoring/grafana/generate.py --check` passes again.

14 alert rules, 5 dashboards with 68 panels, 70 distinct PromQL expressions.

### Alert rules

Each rule is defined once and generated twice, with the same expression, threshold, `for` and severity:

- Grafana-managed rule `<uid>` in the folder Tanzu Postgres (uid `tpg-postgres`), rule group `tpg-postgres`, evaluated every 1m (standalone hub: `monitoring/grafana/alerts/grafana-alerting-values.yaml`; Azure Managed Grafana: `monitoring/grafana/alerts/api/<uid>.json`). Query A runs the expression as an instant query over the last 900 seconds, B reduces it to the last value (mode `dropNN`), and C compares B with the threshold. No data: `OK`; evaluation error: `Error`.
- PrometheusRule `monitoring/tpg-rules` (label `release: kps`), group `tanzu-postgres`, alert `TanzuPostgres<Name>` with the expression `(<expression>) <op> <threshold>`, evaluated by the standalone hub Prometheus and sent to its Alertmanager. A `for` of `0m` is left out of the rule (it fires at the first evaluation).

Every rule carries the label `severity` and the annotation `summary`; there is no `description` annotation. `{{ $labels.<name> }}` in a summary is the value of that label on the alerting series.

| Grafana rule uid | Title | PrometheusRule alert | Severity | Fires when | For |
|---|---|---|---|---|---|
| `tpg-instance-not-running` | Postgres instance not Running | `TanzuPostgresInstanceNotRunning` | critical | value `> 0` | `5m` |
| `tpg-instance-count-dropped` | Postgres instance count dropped | `TanzuPostgresInstanceCountDropped` | warning | value `> 0` | `0m` |
| `tpg-replicas-below-desired` | Postgres pod replicas below desired | `TanzuPostgresReplicasBelowDesired` | warning | value `> 0` | `10m` |
| `tpg-backup-failed` | Postgres backup failed (24h) | `TanzuPostgresBackupFailed` | critical | value `> 0` | `0m` |
| `tpg-backup-running-long` | Postgres backup running too long | `TanzuPostgresBackupRunningLong` | warning | value `> 0` | `3h` |
| `tpg-no-recent-backup` | No successful Postgres backup in 26h | `TanzuPostgresNoRecentBackup` | critical | value `> 26` | `0m` |
| `tpg-backup-skipped` | Postgres backup skipped (previous still running) | `TanzuPostgresBackupSkipped` | warning | value `> 0` | `0m` |
| `tpg-restore-failed` | Postgres restore failed (24h) | `TanzuPostgresRestoreFailed` | critical | value `> 0` | `0m` |
| `tpg-replication-lag` | Postgres replication lag high | `TanzuPostgresReplicationLag` | warning | value `> 30` | `5m` |
| `tpg-wal-archiving-failing` | Postgres WAL archiving failing | `TanzuPostgresWalArchivingFailing` | critical | value `> 0` | `0m` |
| `tpg-connections-high` | Postgres connections above 80% | `TanzuPostgresConnectionsHigh` | warning | value `> 0.8` | `10m` |
| `tpg-delete-failed` | Instance delete failed | `TanzuPostgresDeleteFailed` | warning | value `> 0` | `0m` |
| `tpg-vault-sealed` | Vault sealed or not reporting | `TanzuPostgresVaultSealed` | critical | value `> 0` | `2m` |
| `tpg-exporter-down` | postgres-exporter target down | `TanzuPostgresExporterDown` | warning | value `> 0` | `5m` |

#### tpg-instance-not-running

**Postgres instance not Running**: severity `critical`, fires when the value is `> 0` for `5m`. PrometheusRule alert `TanzuPostgresInstanceNotRunning`.

Summary: `{{ $labels.cluster }}/{{ $labels.instance_name }} is not in the Running state`

Metrics: `tanzu_postgres_instance_state`

```promql
# Grafana rule tpg-instance-not-running, query A (instant)
1 - max by (cluster, instance_namespace, instance_name) (tanzu_postgres_instance_state{state="Running"})
# PrometheusRule alert TanzuPostgresInstanceNotRunning
(1 - max by (cluster, instance_namespace, instance_name) (tanzu_postgres_instance_state{state="Running"})) > 0
```

#### tpg-instance-count-dropped

**Postgres instance count dropped**: severity `warning`, fires when the value is `> 0` for `0m`. PrometheusRule alert `TanzuPostgresInstanceCountDropped`.

Summary: `Fewer Postgres instances on {{ $labels.cluster }} than one hour ago`

Metrics: `tanzu_postgres_instance_state`

```promql
# Grafana rule tpg-instance-count-dropped, query A (instant)
count by (cluster) (tanzu_postgres_instance_state{state="Running"} offset 1h) - count by (cluster) (tanzu_postgres_instance_state{state="Running"})
# PrometheusRule alert TanzuPostgresInstanceCountDropped
(count by (cluster) (tanzu_postgres_instance_state{state="Running"} offset 1h) - count by (cluster) (tanzu_postgres_instance_state{state="Running"})) > 0
```

#### tpg-replicas-below-desired

**Postgres pod replicas below desired**: severity `warning`, fires when the value is `> 0` for `10m`. PrometheusRule alert `TanzuPostgresReplicasBelowDesired`.

Summary: `{{ $labels.cluster }}/{{ $labels.statefulset }} has fewer ready pods than desired`

Metrics: `kube_statefulset_replicas`, `kube_statefulset_status_replicas_ready`

```promql
# Grafana rule tpg-replicas-below-desired, query A (instant)
max by (cluster, namespace, statefulset) (kube_statefulset_replicas{namespace=~"pg-.*"}) - max by (cluster, namespace, statefulset) (kube_statefulset_status_replicas_ready{namespace=~"pg-.*"})
# PrometheusRule alert TanzuPostgresReplicasBelowDesired
(max by (cluster, namespace, statefulset) (kube_statefulset_replicas{namespace=~"pg-.*"}) - max by (cluster, namespace, statefulset) (kube_statefulset_status_replicas_ready{namespace=~"pg-.*"})) > 0
```

#### tpg-backup-failed

**Postgres backup failed (24h)**: severity `critical`, fires when the value is `> 0` for `0m`. PrometheusRule alert `TanzuPostgresBackupFailed`.

Summary: `A backup of {{ $labels.cluster }}/{{ $labels.instance_name }} failed in the last 24 hours`

Metrics: `tanzu_postgres_backup_created_timestamp`, `tanzu_postgres_backup_phase`

```promql
# Grafana rule tpg-backup-failed, query A (instant)
count by (cluster, instance_namespace, instance_name) ((tanzu_postgres_backup_phase{phase="Failed"} == 1) and on (cluster, instance_namespace, backup_name) ((time() - tanzu_postgres_backup_created_timestamp) < 86400))
# PrometheusRule alert TanzuPostgresBackupFailed
(count by (cluster, instance_namespace, instance_name) ((tanzu_postgres_backup_phase{phase="Failed"} == 1) and on (cluster, instance_namespace, backup_name) ((time() - tanzu_postgres_backup_created_timestamp) < 86400))) > 0
```

#### tpg-backup-running-long

**Postgres backup running too long**: severity `warning`, fires when the value is `> 0` for `3h`. PrometheusRule alert `TanzuPostgresBackupRunningLong`.

Summary: `Backup {{ $labels.backup_name }} on {{ $labels.cluster }} has been running for more than 3 hours`

Metrics: `tanzu_postgres_backup_phase`

```promql
# Grafana rule tpg-backup-running-long, query A (instant)
max by (cluster, instance_namespace, instance_name, backup_name) (tanzu_postgres_backup_phase{phase="Running"})
# PrometheusRule alert TanzuPostgresBackupRunningLong
(max by (cluster, instance_namespace, instance_name, backup_name) (tanzu_postgres_backup_phase{phase="Running"})) > 0
```

#### tpg-no-recent-backup

**No successful Postgres backup in 26h**: severity `critical`, fires when the value is `> 26` for `0m`. PrometheusRule alert `TanzuPostgresNoRecentBackup`.

Summary: `No successful backup of {{ $labels.cluster }}/{{ $labels.instance_name }} for more than 26 hours`

Metrics: `tanzu_postgres_backup_completed_timestamp`, `tanzu_postgres_backup_phase`

```promql
# Grafana rule tpg-no-recent-backup, query A (instant)
(time() - max by (cluster, instance_namespace, instance_name) (tanzu_postgres_backup_completed_timestamp and on (cluster, instance_namespace, backup_name) (tanzu_postgres_backup_phase{phase="Succeeded"} == 1))) / 3600
# PrometheusRule alert TanzuPostgresNoRecentBackup
((time() - max by (cluster, instance_namespace, instance_name) (tanzu_postgres_backup_completed_timestamp and on (cluster, instance_namespace, backup_name) (tanzu_postgres_backup_phase{phase="Succeeded"} == 1))) / 3600) > 26
```

#### tpg-backup-skipped

**Postgres backup skipped (previous still running)**: severity `warning`, fires when the value is `> 0` for `0m`. PrometheusRule alert `TanzuPostgresBackupSkipped`.

Summary: `The backup workflow skipped {{ $labels.cluster }}/{{ $labels.instance_name }} because the previous backup was still running`

Metrics: `argo_workflows_tpg_backup_result_total`

```promql
# Grafana rule tpg-backup-skipped, query A (instant)
sum by (cluster, instance_name) (increase(argo_workflows_tpg_backup_result_total{result="SKIPPED_IN_PROGRESS"}[1h]))
# PrometheusRule alert TanzuPostgresBackupSkipped
(sum by (cluster, instance_name) (increase(argo_workflows_tpg_backup_result_total{result="SKIPPED_IN_PROGRESS"}[1h]))) > 0
```

#### tpg-restore-failed

**Postgres restore failed (24h)**: severity `critical`, fires when the value is `> 0` for `0m`. PrometheusRule alert `TanzuPostgresRestoreFailed`.

Summary: `A restore to {{ $labels.cluster }}/{{ $labels.target_instance }} failed in the last 24 hours`

Metrics: `tanzu_postgres_restore_created_timestamp`, `tanzu_postgres_restore_phase`

```promql
# Grafana rule tpg-restore-failed, query A (instant)
count by (cluster, instance_namespace, target_instance) ((tanzu_postgres_restore_phase{phase="Failed"} == 1) and on (cluster, instance_namespace, restore_name) ((time() - tanzu_postgres_restore_created_timestamp) < 86400))
# PrometheusRule alert TanzuPostgresRestoreFailed
(count by (cluster, instance_namespace, target_instance) ((tanzu_postgres_restore_phase{phase="Failed"} == 1) and on (cluster, instance_namespace, restore_name) ((time() - tanzu_postgres_restore_created_timestamp) < 86400))) > 0
```

#### tpg-replication-lag

**Postgres replication lag high**: severity `warning`, fires when the value is `> 30` for `5m`. PrometheusRule alert `TanzuPostgresReplicationLag`.

Summary: `Replication lag on {{ $labels.cluster }}/{{ $labels.postgres_instance }} is above 30 seconds`

Metrics: `pg_replication_lag_seconds`

```promql
# Grafana rule tpg-replication-lag, query A (instant)
max by (cluster, postgres_instance) (pg_replication_lag_seconds)
# PrometheusRule alert TanzuPostgresReplicationLag
(max by (cluster, postgres_instance) (pg_replication_lag_seconds)) > 30
```

#### tpg-wal-archiving-failing

**Postgres WAL archiving failing**: severity `critical`, fires when the value is `> 0` for `0m`. PrometheusRule alert `TanzuPostgresWalArchivingFailing`.

Summary: `WAL archiving is failing on {{ $labels.cluster }}/{{ $labels.postgres_instance }}; point-in-time recovery is at risk`

Metrics: `pg_stat_archiver_failed_count`

```promql
# Grafana rule tpg-wal-archiving-failing, query A (instant)
sum by (cluster, postgres_instance) (increase(pg_stat_archiver_failed_count[15m]))
# PrometheusRule alert TanzuPostgresWalArchivingFailing
(sum by (cluster, postgres_instance) (increase(pg_stat_archiver_failed_count[15m]))) > 0
```

#### tpg-connections-high

**Postgres connections above 80%**: severity `warning`, fires when the value is `> 0.8` for `10m`. PrometheusRule alert `TanzuPostgresConnectionsHigh`.

Summary: `{{ $labels.cluster }}/{{ $labels.postgres_instance }} uses more than 80% of max_connections`

Metrics: `pg_settings_max_connections`, `pg_stat_activity_count`

```promql
# Grafana rule tpg-connections-high, query A (instant)
sum by (cluster, postgres_instance) (pg_stat_activity_count) / max by (cluster, postgres_instance) (pg_settings_max_connections)
# PrometheusRule alert TanzuPostgresConnectionsHigh
(sum by (cluster, postgres_instance) (pg_stat_activity_count) / max by (cluster, postgres_instance) (pg_settings_max_connections)) > 0.8
```

#### tpg-delete-failed

**Instance delete failed**: severity `warning`, fires when the value is `> 0` for `0m`. PrometheusRule alert `TanzuPostgresDeleteFailed`.

Summary: `A delete of {{ $labels.cluster }}/{{ $labels.instance_name }} did not succeed; the instance may be half deleted`

Metrics: `argo_workflows_tpg_delete_result_total`

```promql
# Grafana rule tpg-delete-failed, query A (instant)
sum by (cluster, instance_name) (increase(argo_workflows_tpg_delete_result_total{result!="SUCCEEDED"}[1h]))
# PrometheusRule alert TanzuPostgresDeleteFailed
(sum by (cluster, instance_name) (increase(argo_workflows_tpg_delete_result_total{result!="SUCCEEDED"}[1h]))) > 0
```

#### tpg-vault-sealed

**Vault sealed or not reporting**: severity `critical`, fires when the value is `> 0` for `2m`. PrometheusRule alert `TanzuPostgresVaultSealed`.

Summary: `Vault on the hub is sealed (or its metrics are missing): workflows fail with VAULT_SEALED and secrets are not refreshed. Unseal it with tpg-aks-infra scripts/run.sh ... --only vault-unseal`

Metrics: `vault_core_unsealed`

```promql
# Grafana rule tpg-vault-sealed, query A (instant)
(1 - max(vault_core_unsealed)) or absent(vault_core_unsealed)
# PrometheusRule alert TanzuPostgresVaultSealed
((1 - max(vault_core_unsealed)) or absent(vault_core_unsealed)) > 0
```

#### tpg-exporter-down

**postgres-exporter target down**: severity `warning`, fires when the value is `> 0` for `5m`. PrometheusRule alert `TanzuPostgresExporterDown`.

Summary: `postgres-exporter on {{ $labels.cluster }}/{{ $labels.postgres_instance }} cannot be scraped`

Metrics: `up`

```promql
# Grafana rule tpg-exporter-down, query A (instant)
1 - max by (cluster, postgres_instance) (up{postgres_instance!=""})
# PrometheusRule alert TanzuPostgresExporterDown
(1 - max by (cluster, postgres_instance) (up{postgres_instance!=""})) > 0
```

### Dashboards

Every dashboard is a file `monitoring/standalone/hub/dashboards/<uid>.json`: provisioned in the folder Tanzu Postgres on the standalone hub Grafana, imported into the folder uid `tpg-postgres` of Azure Managed Grafana by `monitoring/grafana/import-azure-grafana.sh`. The variable `datasource` selects the Prometheus data source (`prometheus` on the hub, `Managed_Prometheus_*` on Azure Managed Grafana).

| uid | Title | Panels | Variables | Refresh | Default time range |
|---|---|---|---|---|---|
| `tpg-fleet` | Tanzu Postgres Fleet | 19 | `datasource`, `cluster` | 1m | now-24h to now |
| `tpg-instance` | Tanzu Postgres - Instance overview | 16 | `datasource`, `cluster`, `instance` | 30s | now-6h to now |
| `tpg-replication` | Tanzu Postgres - Replication and HA | 7 | `datasource`, `cluster`, `instance` | 30s | now-6h to now |
| `tpg-backup` | Tanzu Postgres - Backup, WAL and restore | 10 | `datasource`, `cluster`, `instance` | 30s | now-6h to now |
| `tpg-alerts` | Tanzu Postgres - Alerts | 16 | `datasource` | 30s | now-6h to now |

#### tpg-fleet: Tanzu Postgres Fleet

Variables:

- `datasource`: a data source of type `prometheus`
- `cluster` (Cluster): `label_values(tanzu_postgres_instance_state, cluster)`, several values, All = `.*`

##### Row: Fleet overview

**Postgres instances per AKS cluster** (bargauge, panel id 2)

```promql
# A, instant, legend {{cluster}}
count by (cluster) (tanzu_postgres_instance_state{state="Running",cluster=~"$cluster"})
```

**Healthy instances** (stat, panel id 3)

```promql
# A, instant, legend {{cluster}}
sum by (cluster) (tanzu_postgres_instance_state{state="Running",cluster=~"$cluster"})
```

**Unhealthy instances** (stat, panel id 4)

```promql
# A, instant, legend {{cluster}}
count by (cluster) (tanzu_postgres_instance_state{state="Running",cluster=~"$cluster"} == 0) or on (cluster) (count by (cluster) (tanzu_postgres_instance_state{state="Running",cluster=~"$cluster"}) * 0)
```

**Instance state** (table, panel id 5)

```promql
# A, instant
tanzu_postgres_instance_state{cluster=~"$cluster"} == 1
```

##### Row: Replicas

**Pod replicas: ready vs desired** (table, panel id 7)

```promql
# A, instant, legend ready
max by (cluster, namespace, statefulset) (kube_statefulset_status_replicas_ready{namespace=~"pg-.*",cluster=~"$cluster"})
# B, instant, legend desired
max by (cluster, namespace, statefulset) (kube_statefulset_replicas{namespace=~"pg-.*",cluster=~"$cluster"})
```

**Desired read replicas** (table, panel id 8)

```promql
# A, instant
max by (cluster, instance_namespace, instance_name) (tanzu_postgres_instance_read_replicas{cluster=~"$cluster"})
```

##### Row: Backup and restore

**Backups succeeded** (stat, panel id 10)

```promql
# A, instant, legend {{cluster}}
sum by (cluster) (tanzu_postgres_backup_phase{phase="Succeeded",cluster=~"$cluster"})
```

**Backups failed** (stat, panel id 11)

```promql
# A, instant, legend {{cluster}}
sum by (cluster) (tanzu_postgres_backup_phase{phase="Failed",cluster=~"$cluster"})
```

**Backups in progress** (stat, panel id 12)

```promql
# A, instant, legend {{cluster}}
sum by (cluster) (tanzu_postgres_backup_phase{phase=~"Pending|Running",cluster=~"$cluster"})
```

**Restores succeeded** (stat, panel id 13)

```promql
# A, instant, legend {{cluster}}
sum by (cluster) (tanzu_postgres_restore_phase{phase="Succeeded",cluster=~"$cluster"})
```

**Restores failed** (stat, panel id 14)

```promql
# A, instant, legend {{cluster}}
sum by (cluster) (tanzu_postgres_restore_phase{phase="Failed",cluster=~"$cluster"})
```

**Restores in progress** (stat, panel id 15)

```promql
# A, instant, legend {{cluster}}
sum by (cluster) (tanzu_postgres_restore_phase{phase!~"Succeeded|Failed",cluster=~"$cluster"})
```

**Backup workflow results (24h)** (table, panel id 16)

```promql
# A, instant
sum by (cluster, instance_name, backup_type, result) (increase(argo_workflows_tpg_backup_result_total[24h]))
```

**Hours since last successful backup** (table, panel id 17)

```promql
# A, instant
(time() - max by (cluster, instance_namespace, instance_name) (tanzu_postgres_backup_completed_timestamp{cluster=~"$cluster"} and on (cluster, instance_namespace, backup_name) (tanzu_postgres_backup_phase{phase="Succeeded"} == 1))) / 3600
```

##### Row: Database

**Replication lag (seconds)** (timeseries, panel id 19)

```promql
# A, range, legend {{cluster}}/{{postgres_instance}}
max by (cluster, postgres_instance) (pg_replication_lag_seconds{cluster=~"$cluster"})
```

**WAL archive failures (15m)** (timeseries, panel id 20)

```promql
# A, range, legend {{cluster}}/{{postgres_instance}}
sum by (cluster, postgres_instance) (increase(pg_stat_archiver_failed_count{cluster=~"$cluster"}[15m]))
```

**Connections used (%)** (timeseries, panel id 21)

```promql
# A, range, legend {{cluster}}/{{postgres_instance}}
100 * sum by (cluster, postgres_instance) (pg_stat_activity_count{cluster=~"$cluster"}) / max by (cluster, postgres_instance) (pg_settings_max_connections{cluster=~"$cluster"})
```

**Active alerts** (alertlist, panel id 24)

Lists the Grafana alert rules of the folder Tanzu Postgres (uid `tpg-postgres`) in the states firing, pending, error, at most 50.

##### Row: Delete

**Instance deletes (7d)** (table, panel id 23)

```promql
# A, instant
sum by (cluster, instance_name, purge_pvcs, result) (increase(argo_workflows_tpg_delete_result_total[7d]))
```

#### tpg-instance: Tanzu Postgres - Instance overview

Per cluster and instance: availability, connections, throughput, cache, size, locks and the resources of the Postgres pods.

Variables:

- `datasource`: a data source of type `prometheus`
- `cluster` (Cluster): `label_values(tanzu_postgres_instance_state, cluster)`, several values, All = `.*`
- `instance` (Instance): `label_values(tanzu_postgres_instance_state{cluster=~"$cluster"}, instance_name)`, several values, All = `.*`

##### Row: Availability

**Instance state (operator)** (table, panel id 2)

status.currentState of every Postgres object (kube-state-metrics custom resource metrics).

```promql
# A, instant
tanzu_postgres_instance_state{cluster=~"$cluster", instance_name=~"$instance"} == 1
```

**Exporter up per pod** (stat, panel id 3)

1 when the postgres-exporter sidecar of the pod is scraped. The tpg-exporter-down alert fires after 5 minutes at 0.

```promql
# A, instant, legend {{cluster}}/{{pod}}
max by (cluster, postgres_instance, pod) (up{cluster=~"$cluster", postgres_instance=~"$instance"})
```

**Postgres reachable (pg_up)** (stat, panel id 4)

```promql
# A, instant, legend {{cluster}}/{{pod}}
max by (cluster, postgres_instance, pod) (pg_up{cluster=~"$cluster", postgres_instance=~"$instance"})
```

##### Row: Connections and throughput

**Connections used (% of max_connections)** (timeseries, panel id 6)

The tpg-connections-high alert fires above 80% for 10 minutes.

```promql
# A, range, legend {{cluster}}/{{postgres_instance}}
100 * sum by (cluster, postgres_instance) (pg_stat_activity_count{cluster=~"$cluster", postgres_instance=~"$instance"}) / max by (cluster, postgres_instance) (pg_settings_max_connections{cluster=~"$cluster", postgres_instance=~"$instance"})
```

**Connections by state** (timeseries, panel id 7)

```promql
# A, range, legend {{cluster}}/{{postgres_instance}} {{state}}
sum by (cluster, postgres_instance, state) (pg_stat_activity_count{cluster=~"$cluster", postgres_instance=~"$instance"})
```

**Transactions per second** (timeseries, panel id 8)

```promql
# A, range, legend {{cluster}}/{{postgres_instance}} commit
sum by (cluster, postgres_instance) (rate(pg_stat_database_xact_commit{cluster=~"$cluster", postgres_instance=~"$instance"}[5m]))
# B, range, legend {{cluster}}/{{postgres_instance}} rollback
sum by (cluster, postgres_instance) (rate(pg_stat_database_xact_rollback{cluster=~"$cluster", postgres_instance=~"$instance"}[5m]))
```

**Cache hit ratio** (timeseries, panel id 9)

```promql
# A, range, legend {{cluster}}/{{postgres_instance}}
sum by (cluster, postgres_instance) (rate(pg_stat_database_blks_hit{cluster=~"$cluster", postgres_instance=~"$instance"}[5m])) / clamp_min(sum by (cluster, postgres_instance) (rate(pg_stat_database_blks_hit{cluster=~"$cluster", postgres_instance=~"$instance"}[5m])) + sum by (cluster, postgres_instance) (rate(pg_stat_database_blks_read{cluster=~"$cluster", postgres_instance=~"$instance"}[5m])), 1)
```

**Rows per second** (timeseries, panel id 10)

Rows per second, summed over the databases of the instance.

```promql
# A, range, legend {{cluster}}/{{postgres_instance}} fetched
sum by (cluster, postgres_instance) (rate(pg_stat_database_tup_fetched{cluster=~"$cluster", postgres_instance=~"$instance"}[5m]))
# B, range, legend {{cluster}}/{{postgres_instance}} inserted
sum by (cluster, postgres_instance) (rate(pg_stat_database_tup_inserted{cluster=~"$cluster", postgres_instance=~"$instance"}[5m]))
# C, range, legend {{cluster}}/{{postgres_instance}} updated
sum by (cluster, postgres_instance) (rate(pg_stat_database_tup_updated{cluster=~"$cluster", postgres_instance=~"$instance"}[5m]))
# D, range, legend {{cluster}}/{{postgres_instance}} deleted
sum by (cluster, postgres_instance) (rate(pg_stat_database_tup_deleted{cluster=~"$cluster", postgres_instance=~"$instance"}[5m]))
```

##### Row: Storage, locks and long transactions

**Database size** (timeseries, panel id 12)

```promql
# A, range, legend {{cluster}}/{{postgres_instance}} {{datname}}
sum by (cluster, postgres_instance, datname) (pg_database_size_bytes{cluster=~"$cluster", postgres_instance=~"$instance", datname!~"template.*"})
```

**Locks by mode** (timeseries, panel id 13)

```promql
# A, range, legend {{cluster}}/{{postgres_instance}} {{mode}}
sum by (cluster, postgres_instance, mode) (pg_locks_count{cluster=~"$cluster", postgres_instance=~"$instance"})
```

**Deadlocks (15m)** (timeseries, panel id 14)

```promql
# A, range, legend {{cluster}}/{{postgres_instance}}
sum by (cluster, postgres_instance) (increase(pg_stat_database_deadlocks{cluster=~"$cluster", postgres_instance=~"$instance"}[15m]))
```

**Longest running transaction** (timeseries, panel id 15)

```promql
# A, range, legend {{cluster}}/{{postgres_instance}}
max by (cluster, postgres_instance) (pg_stat_activity_max_tx_duration{cluster=~"$cluster", postgres_instance=~"$instance"})
```

**Volume usage (data and WAL)** (bargauge, panel id 16)

```promql
# A, instant, legend {{cluster}} {{persistentvolumeclaim}}
max by (cluster, namespace, persistentvolumeclaim) (kubelet_volume_stats_used_bytes{cluster=~"$cluster", namespace=~"pg-($instance)"}) / max by (cluster, namespace, persistentvolumeclaim) (kubelet_volume_stats_capacity_bytes{cluster=~"$cluster", namespace=~"pg-($instance)"})
```

##### Row: Postgres pods

**CPU per pod** (timeseries, panel id 18)

CPU cores used (rate of container_cpu_usage_seconds_total).

```promql
# A, range, legend {{cluster}}/{{pod}}
sum by (cluster, namespace, pod) (rate(container_cpu_usage_seconds_total{cluster=~"$cluster", namespace=~"pg-($instance)", container!="", container!="POD"}[5m]))
```

**Memory per pod (working set)** (timeseries, panel id 19)

```promql
# A, range, legend {{cluster}}/{{pod}}
sum by (cluster, namespace, pod) (container_memory_working_set_bytes{cluster=~"$cluster", namespace=~"pg-($instance)", container!="", container!="POD"})
```

**Container restarts (1h)** (timeseries, panel id 20)

```promql
# A, range, legend {{cluster}}/{{pod}}
sum by (cluster, namespace, pod) (increase(kube_pod_container_status_restarts_total{cluster=~"$cluster", namespace=~"pg-($instance)"}[1h]))
```

#### tpg-replication: Tanzu Postgres - Replication and HA

Primary and standby roles, replication lag, replicas ready against desired, and WAL archiving.

Variables:

- `datasource`: a data source of type `prometheus`
- `cluster` (Cluster): `label_values(tanzu_postgres_instance_state, cluster)`, several values, All = `.*`
- `instance` (Instance): `label_values(tanzu_postgres_instance_state{cluster=~"$cluster"}, instance_name)`, several values, All = `.*`

##### Row: Roles and replicas

**Role per pod (1 = replica, 0 = primary)** (table, panel id 2)

pg_replication_is_replica from the exporter: 0 on the primary, 1 on a standby or read replica.

```promql
# A, instant
max by (cluster, postgres_instance, pod) (pg_replication_is_replica{cluster=~"$cluster", postgres_instance=~"$instance"})
```

**Pods ready vs desired** (table, panel id 3)

The tpg-replicas-below-desired alert fires when ready stays below desired for 10 minutes.

```promql
# A, instant, legend ready
max by (cluster, namespace, statefulset) (kube_statefulset_status_replicas_ready{cluster=~"$cluster", namespace=~"pg-($instance)"})
# B, instant, legend desired
max by (cluster, namespace, statefulset) (kube_statefulset_replicas{cluster=~"$cluster", namespace=~"pg-($instance)"})
```

**Desired read replicas (spec)** (stat, panel id 4)

```promql
# A, instant, legend {{cluster}}/{{instance_name}}
max by (cluster, instance_name) (tanzu_postgres_instance_read_replicas{cluster=~"$cluster", instance_name=~"$instance"})
```

##### Row: Replication lag

**Replication lag (seconds)** (timeseries, panel id 6)

The tpg-replication-lag alert fires above 30 seconds for 5 minutes.

```promql
# A, range, legend {{cluster}}/{{pod}}
max by (cluster, postgres_instance, pod) (pg_replication_lag_seconds{cluster=~"$cluster", postgres_instance=~"$instance"})
```

##### Row: WAL archiving

**WAL segments archived (1h)** (timeseries, panel id 8)

```promql
# A, range, legend {{cluster}}/{{postgres_instance}}
sum by (cluster, postgres_instance) (increase(pg_stat_archiver_archived_count{cluster=~"$cluster", postgres_instance=~"$instance"}[1h]))
```

**WAL archive failures (15m)** (timeseries, panel id 9)

The tpg-wal-archiving-failing alert fires on any failure: point-in-time recovery is at risk.

```promql
# A, range, legend {{cluster}}/{{postgres_instance}}
sum by (cluster, postgres_instance) (increase(pg_stat_archiver_failed_count{cluster=~"$cluster", postgres_instance=~"$instance"}[15m]))
```

**Pod restarts (24h)** (bargauge, panel id 10)

A failover restarts or replaces pods; a count that keeps growing points at a crash loop.

```promql
# A, instant, legend {{cluster}}/{{pod}}
sum by (cluster, pod) (increase(kube_pod_container_status_restarts_total{cluster=~"$cluster", namespace=~"pg-($instance)"}[24h]))
```

#### tpg-backup: Tanzu Postgres - Backup, WAL and restore

Backups by phase and type, age of the newest full and incremental backup and of the oldest kept backup, WAL archiving and restores.

Variables:

- `datasource`: a data source of type `prometheus`
- `cluster` (Cluster): `label_values(tanzu_postgres_instance_state, cluster)`, several values, All = `.*`
- `instance` (Instance): `label_values(tanzu_postgres_instance_state{cluster=~"$cluster"}, instance_name)`, several values, All = `.*`

##### Row: Backups

**Hours since the newest successful full backup** (table, panel id 2)

The fleet schedule takes a full backup every Sunday (tpg-backup-full): more than 7 days (168 h) means a weekly full was missed.

```promql
# A, instant
(time() - max by (cluster, instance_namespace, instance_name) (tanzu_postgres_backup_completed_timestamp{cluster=~"$cluster", instance_name=~"$instance", backup_type="full"} and on (cluster, instance_namespace, backup_name) (tanzu_postgres_backup_phase{phase="Succeeded"} == 1))) / 3600
```

**Hours since the newest successful backup (any type)** (table, panel id 3)

The tpg-no-recent-backup alert fires above 26 hours.

```promql
# A, instant
(time() - max by (cluster, instance_namespace, instance_name) (tanzu_postgres_backup_completed_timestamp{cluster=~"$cluster", instance_name=~"$instance"} and on (cluster, instance_namespace, backup_name) (tanzu_postgres_backup_phase{phase="Succeeded"} == 1))) / 3600
```

**Backups by phase and type** (table, panel id 4)

```promql
# A, instant
sum by (cluster, instance_name, backup_type, phase) (tanzu_postgres_backup_phase{cluster=~"$cluster", instance_name=~"$instance"} == 1)
```

**Backups completed in the last 24 hours** (timeseries, panel id 5)

One full backup on Sunday and one incremental on the other days is the fleet schedule.

```promql
# A, range, legend {{cluster}}/{{instance_name}} {{backup_type}}
count by (cluster, instance_name, backup_type) ((time() - tanzu_postgres_backup_completed_timestamp{cluster=~"$cluster", instance_name=~"$instance"}) < 86400)
```

**Backup workflow results (24h)** (table, panel id 6)

Results of the tpg-backup runs (CronWorkflows tpg-backup-full and tpg-backup-incr, and manual runs).

```promql
# A, instant
sum by (cluster, instance_name, backup_type, result) (increase(argo_workflows_tpg_backup_result_total{cluster=~"$cluster", instance_name=~"$instance"}[24h]))
```

**Oldest kept backup (days)** (table, panel id 7)

Age of the oldest backup that still exists. The backup location's retentionPolicy expires older backups (fullRetentionType count: the newest fullRetention full backups; time: fullRetention days) and the operator deletes their PostgresBackup objects.

```promql
# A, instant
(time() - min by (cluster, instance_name) (tanzu_postgres_backup_completed_timestamp{cluster=~"$cluster", instance_name=~"$instance"} and on (cluster, instance_namespace, backup_name) (tanzu_postgres_backup_phase{phase="Succeeded"} == 1))) / 86400
```

##### Row: WAL archiving

**WAL archive failures (15m)** (timeseries, panel id 9)

```promql
# A, range, legend {{cluster}}/{{postgres_instance}}
sum by (cluster, postgres_instance) (increase(pg_stat_archiver_failed_count{cluster=~"$cluster", postgres_instance=~"$instance"}[15m]))
```

**WAL segments archived (1h)** (timeseries, panel id 10)

```promql
# A, range, legend {{cluster}}/{{postgres_instance}}
sum by (cluster, postgres_instance) (increase(pg_stat_archiver_archived_count{cluster=~"$cluster", postgres_instance=~"$instance"}[1h]))
```

##### Row: Restores

**Restores by phase** (table, panel id 12)

```promql
# A, instant
sum by (cluster, instance_namespace, target_instance, phase) (tanzu_postgres_restore_phase{cluster=~"$cluster"} == 1)
```

**Restore workflow results (7d)** (table, panel id 13)

```promql
# A, instant
sum by (cluster, instance_name, mode, result) (increase(argo_workflows_tpg_restore_result_total{cluster=~"$cluster", instance_name=~"$instance"}[7d]))
```

#### tpg-alerts: Tanzu Postgres - Alerts

The 14 configured alert rules (monitoring/grafana/generate.py): current state, and each rule's expression over time with its threshold.

Variables:

- `datasource`: a data source of type `prometheus`

##### Row: State

**Firing and pending** (alertlist, panel id 2)

Lists the Grafana alert rules of the folder Tanzu Postgres (uid `tpg-postgres`) in the states firing, pending, error, at most 100.

**Rules firing in Prometheus (standalone PrometheusRule)** (timeseries, panel id 3)

ALERTS series of the PrometheusRule tpg-rules (hub Prometheus, standalone option). Empty on Azure Managed Grafana, whose rules are Grafana-managed: see the list above.

```promql
# A, range, legend {{alertname}} {{cluster}}
count by (alertname, cluster) (ALERTS{alertname=~"TanzuPostgres.*", alertstate="firing"})
```

##### Row: Rule values (threshold shown as a line)

**Postgres instance not Running (> 0, for 5m, critical)** (timeseries, panel id 5)

\<cluster>/\<instance_name> is not in the Running state

```promql
# A, range
1 - max by (cluster, instance_namespace, instance_name) (tanzu_postgres_instance_state{state="Running"})
```

**Postgres instance count dropped (> 0, for 0m, warning)** (timeseries, panel id 6)

Fewer Postgres instances on \<cluster> than one hour ago

```promql
# A, range
count by (cluster) (tanzu_postgres_instance_state{state="Running"} offset 1h) - count by (cluster) (tanzu_postgres_instance_state{state="Running"})
```

**Postgres pod replicas below desired (> 0, for 10m, warning)** (timeseries, panel id 7)

\<cluster>/\<statefulset> has fewer ready pods than desired

```promql
# A, range
max by (cluster, namespace, statefulset) (kube_statefulset_replicas{namespace=~"pg-.*"}) - max by (cluster, namespace, statefulset) (kube_statefulset_status_replicas_ready{namespace=~"pg-.*"})
```

**Postgres backup failed (24h) (> 0, for 0m, critical)** (timeseries, panel id 8)

A backup of \<cluster>/\<instance_name> failed in the last 24 hours

```promql
# A, range
count by (cluster, instance_namespace, instance_name) ((tanzu_postgres_backup_phase{phase="Failed"} == 1) and on (cluster, instance_namespace, backup_name) ((time() - tanzu_postgres_backup_created_timestamp) < 86400))
```

**Postgres backup running too long (> 0, for 3h, warning)** (timeseries, panel id 9)

Backup \<backup_name> on \<cluster> has been running for more than 3 hours

```promql
# A, range
max by (cluster, instance_namespace, instance_name, backup_name) (tanzu_postgres_backup_phase{phase="Running"})
```

**No successful Postgres backup in 26h (> 26, for 0m, critical)** (timeseries, panel id 10)

No successful backup of \<cluster>/\<instance_name> for more than 26 hours

```promql
# A, range
(time() - max by (cluster, instance_namespace, instance_name) (tanzu_postgres_backup_completed_timestamp and on (cluster, instance_namespace, backup_name) (tanzu_postgres_backup_phase{phase="Succeeded"} == 1))) / 3600
```

**Postgres backup skipped (previous still running) (> 0, for 0m, warning)** (timeseries, panel id 11)

The backup workflow skipped \<cluster>/\<instance_name> because the previous backup was still running

```promql
# A, range
sum by (cluster, instance_name) (increase(argo_workflows_tpg_backup_result_total{result="SKIPPED_IN_PROGRESS"}[1h]))
```

**Postgres restore failed (24h) (> 0, for 0m, critical)** (timeseries, panel id 12)

A restore to \<cluster>/\<target_instance> failed in the last 24 hours

```promql
# A, range
count by (cluster, instance_namespace, target_instance) ((tanzu_postgres_restore_phase{phase="Failed"} == 1) and on (cluster, instance_namespace, restore_name) ((time() - tanzu_postgres_restore_created_timestamp) < 86400))
```

**Postgres replication lag high (> 30, for 5m, warning)** (timeseries, panel id 13)

Replication lag on \<cluster>/\<postgres_instance> is above 30 seconds

```promql
# A, range
max by (cluster, postgres_instance) (pg_replication_lag_seconds)
```

**Postgres WAL archiving failing (> 0, for 0m, critical)** (timeseries, panel id 14)

WAL archiving is failing on \<cluster>/\<postgres_instance>; point-in-time recovery is at risk

```promql
# A, range
sum by (cluster, postgres_instance) (increase(pg_stat_archiver_failed_count[15m]))
```

**Postgres connections above 80% (> 0.8, for 10m, warning)** (timeseries, panel id 15)

\<cluster>/\<postgres_instance> uses more than 80% of max_connections

```promql
# A, range
sum by (cluster, postgres_instance) (pg_stat_activity_count) / max by (cluster, postgres_instance) (pg_settings_max_connections)
```

**Instance delete failed (> 0, for 0m, warning)** (timeseries, panel id 16)

A delete of \<cluster>/\<instance_name> did not succeed; the instance may be half deleted

```promql
# A, range
sum by (cluster, instance_name) (increase(argo_workflows_tpg_delete_result_total{result!="SUCCEEDED"}[1h]))
```

**Vault sealed or not reporting (> 0, for 2m, critical)** (timeseries, panel id 17)

Vault on the hub is sealed (or its metrics are missing): workflows fail with VAULT_SEALED and secrets are not refreshed. Unseal it with tpg-aks-infra scripts/run.sh ... --only vault-unseal

```promql
# A, range
(1 - max(vault_core_unsealed)) or absent(vault_core_unsealed)
```

**postgres-exporter target down (> 0, for 5m, warning)** (timeseries, panel id 18)

postgres-exporter on \<cluster>/\<postgres_instance> cannot be scraped

```promql
# A, range
1 - max by (cluster, postgres_instance) (up{postgres_instance!=""})
```

### Metrics

Every metric the queries above read, where it comes from, and the alert rules (uid) and dashboards (uid) that use it.

| Metric | Source | Used by |
|---|---|---|
| `ALERTS` | the hub Prometheus: alerts of the PrometheusRule `tpg-rules` (standalone option) | `tpg-alerts` |
| `argo_workflows_tpg_backup_result_total` | Argo Workflows controller on the hub (ServiceMonitor `argo-workflows-controller`): metrics declared in the WorkflowTemplates | `tpg-backup-skipped`, `tpg-fleet`, `tpg-backup`, `tpg-alerts` |
| `argo_workflows_tpg_delete_result_total` | Argo Workflows controller on the hub (ServiceMonitor `argo-workflows-controller`): metrics declared in the WorkflowTemplates | `tpg-delete-failed`, `tpg-fleet`, `tpg-alerts` |
| `argo_workflows_tpg_restore_result_total` | Argo Workflows controller on the hub (ServiceMonitor `argo-workflows-controller`): metrics declared in the WorkflowTemplates | `tpg-backup` |
| `container_cpu_usage_seconds_total` | kubelet and cAdvisor (kube-prometheus-stack on standalone targets, managed Prometheus defaults on azure) | `tpg-instance` |
| `container_memory_working_set_bytes` | kubelet and cAdvisor (kube-prometheus-stack on standalone targets, managed Prometheus defaults on azure) | `tpg-instance` |
| `kube_pod_container_status_restarts_total` | kube-state-metrics (release `tpg-ksm`) | `tpg-instance`, `tpg-replication` |
| `kube_statefulset_replicas` | kube-state-metrics (release `tpg-ksm`) | `tpg-replicas-below-desired`, `tpg-fleet`, `tpg-replication`, `tpg-alerts` |
| `kube_statefulset_status_replicas_ready` | kube-state-metrics (release `tpg-ksm`) | `tpg-replicas-below-desired`, `tpg-fleet`, `tpg-replication`, `tpg-alerts` |
| `kubelet_volume_stats_capacity_bytes` | kubelet and cAdvisor (kube-prometheus-stack on standalone targets, managed Prometheus defaults on azure) | `tpg-instance` |
| `kubelet_volume_stats_used_bytes` | kubelet and cAdvisor (kube-prometheus-stack on standalone targets, managed Prometheus defaults on azure) | `tpg-instance` |
| `pg_database_size_bytes` | postgres-exporter sidecar of every Postgres data pod (PodMonitor `postgres-instances`) | `tpg-instance` |
| `pg_locks_count` | postgres-exporter sidecar of every Postgres data pod (PodMonitor `postgres-instances`) | `tpg-instance` |
| `pg_replication_is_replica` | postgres-exporter sidecar of every Postgres data pod (PodMonitor `postgres-instances`) | `tpg-replication` |
| `pg_replication_lag_seconds` | postgres-exporter sidecar of every Postgres data pod (PodMonitor `postgres-instances`) | `tpg-replication-lag`, `tpg-fleet`, `tpg-replication`, `tpg-alerts` |
| `pg_settings_max_connections` | postgres-exporter sidecar of every Postgres data pod (PodMonitor `postgres-instances`) | `tpg-connections-high`, `tpg-fleet`, `tpg-instance`, `tpg-alerts` |
| `pg_stat_activity_count` | postgres-exporter sidecar of every Postgres data pod (PodMonitor `postgres-instances`) | `tpg-connections-high`, `tpg-fleet`, `tpg-instance`, `tpg-alerts` |
| `pg_stat_activity_max_tx_duration` | postgres-exporter sidecar of every Postgres data pod (PodMonitor `postgres-instances`) | `tpg-instance` |
| `pg_stat_archiver_archived_count` | postgres-exporter sidecar of every Postgres data pod (PodMonitor `postgres-instances`) | `tpg-replication`, `tpg-backup` |
| `pg_stat_archiver_failed_count` | postgres-exporter sidecar of every Postgres data pod (PodMonitor `postgres-instances`) | `tpg-wal-archiving-failing`, `tpg-fleet`, `tpg-replication`, `tpg-backup`, `tpg-alerts` |
| `pg_stat_database_blks_hit` | postgres-exporter sidecar of every Postgres data pod (PodMonitor `postgres-instances`) | `tpg-instance` |
| `pg_stat_database_blks_read` | postgres-exporter sidecar of every Postgres data pod (PodMonitor `postgres-instances`) | `tpg-instance` |
| `pg_stat_database_deadlocks` | postgres-exporter sidecar of every Postgres data pod (PodMonitor `postgres-instances`) | `tpg-instance` |
| `pg_stat_database_tup_deleted` | postgres-exporter sidecar of every Postgres data pod (PodMonitor `postgres-instances`) | `tpg-instance` |
| `pg_stat_database_tup_fetched` | postgres-exporter sidecar of every Postgres data pod (PodMonitor `postgres-instances`) | `tpg-instance` |
| `pg_stat_database_tup_inserted` | postgres-exporter sidecar of every Postgres data pod (PodMonitor `postgres-instances`) | `tpg-instance` |
| `pg_stat_database_tup_updated` | postgres-exporter sidecar of every Postgres data pod (PodMonitor `postgres-instances`) | `tpg-instance` |
| `pg_stat_database_xact_commit` | postgres-exporter sidecar of every Postgres data pod (PodMonitor `postgres-instances`) | `tpg-instance` |
| `pg_stat_database_xact_rollback` | postgres-exporter sidecar of every Postgres data pod (PodMonitor `postgres-instances`) | `tpg-instance` |
| `pg_up` | postgres-exporter sidecar of every Postgres data pod (PodMonitor `postgres-instances`) | `tpg-instance` |
| `tanzu_postgres_backup_completed_timestamp` | kube-state-metrics custom resource metrics (release `tpg-ksm`, `monitoring/ksm/values.yaml`) | `tpg-no-recent-backup`, `tpg-fleet`, `tpg-backup`, `tpg-alerts` |
| `tanzu_postgres_backup_created_timestamp` | kube-state-metrics custom resource metrics (release `tpg-ksm`, `monitoring/ksm/values.yaml`) | `tpg-backup-failed`, `tpg-alerts` |
| `tanzu_postgres_backup_phase` | kube-state-metrics custom resource metrics (release `tpg-ksm`, `monitoring/ksm/values.yaml`) | `tpg-backup-failed`, `tpg-backup-running-long`, `tpg-no-recent-backup`, `tpg-fleet`, `tpg-backup`, `tpg-alerts` |
| `tanzu_postgres_instance_read_replicas` | kube-state-metrics custom resource metrics (release `tpg-ksm`, `monitoring/ksm/values.yaml`) | `tpg-fleet`, `tpg-replication` |
| `tanzu_postgres_instance_state` | kube-state-metrics custom resource metrics (release `tpg-ksm`, `monitoring/ksm/values.yaml`) | `tpg-instance-not-running`, `tpg-instance-count-dropped`, `tpg-fleet`, `tpg-instance`, `tpg-alerts` |
| `tanzu_postgres_restore_created_timestamp` | kube-state-metrics custom resource metrics (release `tpg-ksm`, `monitoring/ksm/values.yaml`) | `tpg-restore-failed`, `tpg-alerts` |
| `tanzu_postgres_restore_phase` | kube-state-metrics custom resource metrics (release `tpg-ksm`, `monitoring/ksm/values.yaml`) | `tpg-restore-failed`, `tpg-fleet`, `tpg-backup`, `tpg-alerts` |
| `up` | scrape status of every target; the queries keep the exporter targets (label `postgres_instance`) | `tpg-exporter-down`, `tpg-instance`, `tpg-alerts` |
| `vault_core_unsealed` | Vault on the hub (ServiceMonitor `vault`, `/v1/sys/metrics`) | `tpg-vault-sealed`, `tpg-alerts` |
<!-- END GENERATED: monitoring-reference -->
