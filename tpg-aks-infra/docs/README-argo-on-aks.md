# Argo CD and Argo Workflows on AKS

This guide gives the step-by-step commands to install Argo CD and Argo Workflows on the management (hub) AKS cluster of the Tanzu for Postgres GitOps POC. Both UIs are exposed through Azure LoadBalancer Services that only accept connections from allowlisted IP ranges.

| Component | Helm chart | App version | Namespace | UI endpoint |
|---|---|---|---|---|
| Argo CD | `argo/argo-cd` 10.9.1 | v3.5.3 | `argocd` | `https://<ARGOCD_IP>` (port 443) |
| Argo Workflows | `argo/argo-workflows` 2.0.6 | v4.1.3 | `argo` | `https://<ARGO_WF_IP>:2746` |

The same steps are automated by `tpg-aks-infra/scripts/hub/install/install-argo.sh` (run through `scripts/run.sh --hub install`). If the hub already runs Argo CD and Argo Workflows, use `scripts/run.sh --hub existing` instead; see `docs/README-manual-steps.md`, section 5. Use this guide to understand each step, to run it by hand, or to troubleshoot.

## Contents

1. [Prerequisites](#1-prerequisites)
2. [Connect to the hub cluster](#2-connect-to-the-hub-cluster)
3. [Prepare the values files](#3-prepare-the-values-files)
4. [Install Argo CD](#4-install-argo-cd)
5. [Install Argo Workflows](#5-install-argo-workflows)
6. [Get the LoadBalancer IP addresses](#6-get-the-loadbalancer-ip-addresses)
7. [Log in to the Argo CD UI and CLI](#7-log-in-to-the-argo-cd-ui-and-cli)
8. [Log in to the Argo Workflows UI and CLI](#8-log-in-to-the-argo-workflows-ui-and-cli)
9. [Verify the installation](#9-verify-the-installation)
10. [Next steps for the POC](#10-next-steps-for-the-poc)
11. [Troubleshooting](#11-troubleshooting)
12. [Upgrade and uninstall](#12-upgrade-and-uninstall)

---

## 1. Prerequisites

### 1.1 Azure resources

- The hub AKS cluster exists. With `tpg-aks-infra`, run `terraform apply` first; it creates `aks-tpg-hub` in `eastus2` with at least 3 nodes spread across availability zones 1, 2 and 3. A pre-created hub works the same way.
- Your public IP is in the API server authorized IP ranges (`admin_allowed_cidrs` in `terraform.tfvars`), or the API server is public (`api_access_mode = "public"`).
- Your Azure identity can run `az aks get-credentials --admin` on the cluster (for example, the Owner or Azure Kubernetes Service Cluster Admin Role on the cluster).

Find your public IP:

```bash
curl -s https://ifconfig.me; echo
```

### 1.2 Workstation tools

| Tool | Minimum version | Install (Linux amd64 shown) |
|---|---|---|
| Azure CLI | 2.60 | https://learn.microsoft.com/cli/azure/install-azure-cli |
| kubectl | Matches the cluster minor version | `az aks install-cli` |
| Helm | 3.8.0 | https://helm.sh/docs/intro/install/ |
| argocd CLI | v3.5.3 | see below |
| argo CLI | v4.1.3 | see below |
| jq | 1.6 | package manager |

```bash
# argocd CLI v3.5.3
curl -sSL -o argocd https://github.com/argoproj/argo-cd/releases/download/v3.5.3/argocd-linux-amd64
sudo install -m 555 argocd /usr/local/bin/argocd && rm argocd

# argo CLI v4.1.3
curl -sSL -o argo.gz https://github.com/argoproj/argo-workflows/releases/download/v4.1.3/argo-linux-amd64.gz
gunzip argo.gz && sudo install -m 555 argo /usr/local/bin/argo && rm argo

argocd version --client --short
argo version --short
```

On macOS, replace `linux-amd64` with `darwin-arm64` (Apple silicon) or `darwin-amd64`.

### 1.3 Set shell variables

Every command below uses these variables. Adjust them to your environment.

```bash
export SUBSCRIPTION_ID="<subscription-id>"
export RESOURCE_GROUP="rg-tpgpoc"
export HUB_CLUSTER="aks-tpg-hub"
# One or more CIDRs allowed to reach the UIs, as a JSON array
export ALLOWED_CIDRS='["203.0.113.10/32"]'
```

If you used Terraform, read the values from its outputs instead:

```bash
cd tpg-aks-infra/terraform
export SUBSCRIPTION_ID="$(terraform output -raw subscription_id)"
export RESOURCE_GROUP="$(terraform output -raw resource_group_name)"
export HUB_CLUSTER="$(terraform output -raw hub_cluster_name)"
export ALLOWED_CIDRS="$(terraform output -json admin_allowed_cidrs)"
cd -
```

## 2. Connect to the hub cluster

```bash
az login
az account set --subscription "$SUBSCRIPTION_ID"

kubectl config delete-context "${HUB_CLUSTER}-admin" >/dev/null 2>&1 || true
az aks get-credentials \
  --resource-group "$RESOURCE_GROUP" \
  --name "$HUB_CLUSTER" \
  --admin \
  --context "$HUB_CLUSTER" \
  --overwrite-existing

# --admin appends -admin to the context name, even with --context: rename it
kubectl config delete-context "$HUB_CLUSTER" >/dev/null 2>&1 || true
kubectl config rename-context "${HUB_CLUSTER}-admin" "$HUB_CLUSTER"
kubectl config use-context "$HUB_CLUSTER"
kubectl get nodes -L topology.kubernetes.io/zone
```

Expected result: at least 3 `Ready` nodes, with zones `eastus2-1`, `eastus2-2` and `eastus2-3`.

## 3. Prepare the values files

The values files live in `tpg-aks-infra/argo/`. They are reproduced here so this guide stands on its own.

### 3.1 `argocd-values.yaml`

```yaml
dex:
  enabled: false

configs:
  cm:
    application.resourceTrackingMethod: annotation
    accounts.workflow-bot: apiKey
    timeout.reconciliation: 60s
    # Health checks (shortened here; argo/argocd-values.yaml has the full Lua scripts)
    resource.customizations.health.secrets.hashicorp.com_VaultStaticSecret: |
      ... Healthy once the condition Ready (or SecretSynced) is True ...
    resource.customizations.health.sql.tanzu.vmware.com_Postgres: |
      ... Healthy when status.currentState is Running; Failed, Unavailable: Degraded ...
  params:
    server.insecure: false
  rbac:
    policy.csv: |
      p, role:tpg-sync, applications, get, tpg/*, allow
      p, role:tpg-sync, applications, sync, tpg/*, allow
      p, role:tpg-sync, projects, get, tpg, allow
      p, role:tpg-sync, repositories, get, *, allow
      g, workflow-bot, role:tpg-sync
      # >>> tpg-fleet rbac >>>
      p, role:admin, applications, sync, tpg/*, deny
      p, role:admin, applications, override, tpg/*, deny
      p, role:admin, applications, update, tpg/*, deny
      p, role:admin, applications, delete, tpg/*, deny
      # <<< tpg-fleet rbac <<<

server:
  service:
    type: LoadBalancer
    servicePortHttps: 443
    loadBalancerSourceRanges: []
```

| Setting | Why |
|---|---|
| `server.service.type: LoadBalancer` | AKS creates a public Azure Standard Load Balancer frontend for `argocd-server`. |
| `server.service.loadBalancerSourceRanges` | AKS turns the ranges into Network Security Group rules, so only these CIDRs reach the UI. Set on the command line from `ALLOWED_CIDRS`. |
| `server.insecure: false` | The Argo CD server keeps serving HTTPS with its self-signed certificate. |
| `accounts.workflow-bot` + `policy.csv` | API-only account that Argo Workflows uses to trigger syncs in the `tpg` project. |
| `tpg-fleet rbac` block in `policy.csv` | People may not sync (which also covers rollback), override, update or delete the tpg target Applications; only `workflow-bot` syncs them. A deny is evaluated before any allow and also removes what `policy.default` grants. On an existing hub, `scripts/hub/existing/check-argo.sh --yes` adds deny lines for every subject that can still act on project `tpg`. The hub Applications are in project `tpg-hub` and are not affected. |
| `resourceTrackingMethod: annotation` | The Day 0 pre-check reads the `argocd.argoproj.io/tracking-id` annotation. |
| `resource.customizations.health...VaultStaticSecret` | Argo CD reports a `VaultStaticSecret` as Healthy only once the Secret is synced from Vault, so the Postgres sync wave waits for the image pull and backup credentials. |
| `resource.customizations.health...Postgres` | Without it Argo CD knows nothing about the `Postgres` kind and reports an instance Healthy as soon as it is applied, while its pods are still starting or failing. With it: `Running` is Healthy, `Failed` and `Unavailable` are Degraded, anything else is Progressing. |
| `timeout.reconciliation: 60s` | How often Argo CD re-reads Git and compares every Application (default 180s). A shorter interval makes a new cluster's CRDs and a fresh fleet commit visible sooner; the workflows also check the target directly and hard-refresh, so they do not depend on it. |

### 3.2 `argo-workflows-values.yaml`

```yaml
controller:
  workflowNamespaces:
    - argo
  metricsConfig:
    enabled: true
  serviceMonitor:
    enabled: false
  workflowDefaults:
    spec:
      serviceAccountName: tpg-workflow
      ttlStrategy:
        secondsAfterCompletion: 604800
      podGC:
        strategy: OnPodSuccess

server:
  serviceType: LoadBalancer
  servicePort: 2746
  loadBalancerSourceRanges: []
  secure: true
  authModes:
    - client

workflow:
  serviceAccount:
    create: false
  rbac:
    create: false
```

| Setting | Why |
|---|---|
| `server.serviceType: LoadBalancer` | Public Azure Load Balancer frontend for the Argo Workflows server on port 2746. |
| `server.secure: true` | The server generates a self-signed certificate and serves HTTPS. |
| `server.authModes: [client]` | Users log in with a Kubernetes bearer token. There is no anonymous access. |
| `controller.workflowNamespaces: [argo]` | Workflows run only in the `argo` namespace. |
| `controller.metricsConfig.enabled` | Exposes controller and custom `tpg_*` metrics for the monitoring stack. |
| `workflow.serviceAccount.create: false` | The `tpg-workflow` ServiceAccount and RBAC come from the `tpg-fleet` repository. |
| `podGC: OnPodSuccess`, `ttlStrategy` 7 days | Pods of successful steps are deleted, Workflows after 7 days. The step logs stay readable because they are archived (below). |

**Archived logs.** The step logs are archived to Azure Blob through a namespace default artifact repository, not through these values: `tpg-aks-infra` creates ConfigMap `argo/artifact-repositories` (annotation `workflows.argoproj.io/default-artifact-repository`, `archiveLogs: true`, container `argo-logs` of the backup storage account) and the key Secret `argo/argo-artifacts` from Vault in its `hub-secrets` step, so an existing Argo Workflows installation needs no change. The UI shows an archived log after the pod is gone; `tpg-aks-infra/scripts/wf-logs.sh` reads it after the Workflow is deleted.

## 4. Install Argo CD

`scripts/run.sh --hub install` does sections 4 and 5 with `scripts/hub/install/install-argo.sh`. It runs the same Helm release pre-check as the fleet add-ons: an up-to-date release is left alone, a release with another chart version or other values shows the diff and asks to upgrade, skip or abort (`--yes` upgrades), and Argo installed another way stops the step (use `--hub existing`). While `helm --wait` runs, the pods of the namespace are printed every 5 seconds, and the install stops when one cannot start. By hand:

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update argo

helm upgrade --install argocd argo/argo-cd \
  --kube-context "$HUB_CLUSTER" \
  --namespace argocd --create-namespace \
  --version 10.9.1 \
  -f tpg-aks-infra/argo/argocd-values.yaml \
  --set-json "server.service.loadBalancerSourceRanges=${ALLOWED_CIDRS}" \
  --wait --timeout 15m
```

Check the pods and the Service:

```bash
kubectl -n argocd get pods
kubectl -n argocd get svc argocd-server -o wide
```

All pods must be `Running` and ready. The `argocd-server` Service type is `LoadBalancer`.

## 5. Install Argo Workflows

```bash
helm upgrade --install argo-workflows argo/argo-workflows \
  --kube-context "$HUB_CLUSTER" \
  --namespace argo --create-namespace \
  --version 2.0.6 \
  -f tpg-aks-infra/argo/argo-workflows-values.yaml \
  --set-json "server.loadBalancerSourceRanges=${ALLOWED_CIDRS}" \
  --wait --timeout 15m

kubectl -n argo get pods
kubectl -n argo get svc -l app.kubernetes.io/component=server -o wide
```

Create a ServiceAccount whose token you use to log in to the Argo Workflows UI. It gets the built-in `admin` role in the `argo` namespace, which includes the Argo Workflows permissions through the chart's aggregated roles.

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: argo-ui-admin
  namespace: argo
---
apiVersion: v1
kind: Secret
metadata:
  name: argo-ui-admin.service-account-token
  namespace: argo
  annotations:
    kubernetes.io/service-account.name: argo-ui-admin
type: kubernetes.io/service-account-token
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: argo-ui-admin
  namespace: argo
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: admin
subjects:
  - kind: ServiceAccount
    name: argo-ui-admin
    namespace: argo
EOF
```

## 6. Get the LoadBalancer IP addresses

Azure usually assigns the public IPs within one to two minutes.

```bash
kubectl -n argocd get svc argocd-server -w
# Press Ctrl+C when EXTERNAL-IP is no longer <pending>

export ARGOCD_IP="$(kubectl -n argocd get svc argocd-server \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"

export ARGO_WF_SVC="$(kubectl -n argo get svc -l app.kubernetes.io/component=server \
  -o jsonpath='{.items[0].metadata.name}')"
export ARGO_WF_IP="$(kubectl -n argo get svc "$ARGO_WF_SVC" \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"

echo "Argo CD:        https://${ARGOCD_IP}"
echo "Argo Workflows: https://${ARGO_WF_IP}:2746"
```

Confirm that the allowlist reached Azure. The Service lists the ranges, and AKS writes matching inbound rules into the node resource group's Network Security Group:

```bash
kubectl -n argocd get svc argocd-server -o jsonpath='{.spec.loadBalancerSourceRanges}'; echo
kubectl -n argo get svc "$ARGO_WF_SVC" -o jsonpath='{.spec.loadBalancerSourceRanges}'; echo

NODE_RG="$(az aks show -g "$RESOURCE_GROUP" -n "$HUB_CLUSTER" --query nodeResourceGroup -o tsv)"
az network nsg list -g "$NODE_RG" --query "[].securityRules[?direction=='Inbound'].{name:name,port:destinationPortRange,source:sourceAddressPrefixes||sourceAddressPrefix}" -o table
```

## 7. Log in to the Argo CD UI and CLI

Read the initial admin password:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

### 7.1 UI

1. Open `https://<ARGOCD_IP>` in a browser from an allowlisted IP.
2. Accept the self-signed certificate warning.
3. Log in as `admin` with the password above.
4. Change the password under **User Info**, **Update Password**, then delete the initial secret:

   ```bash
   kubectl -n argocd delete secret argocd-initial-admin-secret
   ```

### 7.2 CLI

```bash
argocd login "$ARGOCD_IP" --username admin --insecure --grpc-web
argocd account list
argocd cluster list
```

`--insecure` skips verification of the self-signed certificate, and `--grpc-web` works well through the Azure Load Balancer.

### 7.3 API token for Argo Workflows

The POC workflows call the Argo CD API as `workflow-bot`. Generate its token and store it in the `argo` namespace:

```bash
TOKEN="$(argocd account generate-token --account workflow-bot --grpc-web)"
kubectl -n argo create secret generic argocd-workflow-token \
  --from-literal=token="$TOKEN" --dry-run=client -o yaml | kubectl apply -f -
unset TOKEN
```

## 8. Log in to the Argo Workflows UI and CLI

Read the bearer token of `argo-ui-admin`:

```bash
echo "Bearer $(kubectl -n argo get secret argo-ui-admin.service-account-token \
  -o jsonpath='{.data.token}' | base64 -d)"
```

### 8.1 UI

1. Open `https://<ARGO_WF_IP>:2746` from an allowlisted IP and accept the certificate warning.
2. Paste the whole string, including the `Bearer ` prefix, into the **client authentication** field and select **Login**.
3. Select the `argo` namespace.

### 8.2 CLI

```bash
export ARGO_SERVER="${ARGO_WF_IP}:2746"
export ARGO_SECURE=true
export ARGO_INSECURE_SKIP_VERIFY=true
export ARGO_NAMESPACE=argo
export ARGO_TOKEN="Bearer $(kubectl -n argo get secret argo-ui-admin.service-account-token \
  -o jsonpath='{.data.token}' | base64 -d)"

argo list
argo template list
```

To test the installation, submit the hello-world workflow. It runs as `default` explicitly, because the default `tpg-workflow` ServiceAccount only exists after the fleet repository is bootstrapped:

```bash
kubectl -n argo apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: hello-executor
  namespace: argo
rules:
  - apiGroups: ["argoproj.io"]
    resources: ["workflowtaskresults"]
    verbs: ["create", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: hello-executor
  namespace: argo
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: hello-executor
subjects:
  - kind: ServiceAccount
    name: default
    namespace: argo
EOF

argo submit --serviceaccount default --watch \
  https://raw.githubusercontent.com/argoproj/argo-workflows/v4.1.3/examples/hello-world.yaml
argo logs @latest
```

Clean up afterwards: `argo delete @latest && kubectl -n argo delete role,rolebinding hello-executor`.

## 9. Verify the installation

| Check | Command | Expected |
|---|---|---|
| Argo CD pods | `kubectl -n argocd get pods` | All `Running`, all containers ready |
| Argo Workflows pods | `kubectl -n argo get pods` | `workflow-controller` and `server` `Running` |
| Argo CD UI reachable | `curl -sk -o /dev/null -w '%{http_code}\n' https://$ARGOCD_IP/healthz` | `200` |
| Argo Workflows UI reachable | `curl -sk -o /dev/null -w '%{http_code}\n' https://$ARGO_WF_IP:2746/` | `200` |
| Allowlist enforced | Run the same curl from a non-allowlisted network | Timeout |
| Argo CD CLI | `argocd account list` | `admin` and `workflow-bot` listed |
| Argo CD settings | `kubectl -n argocd get cm argocd-cm -o json \| jq -r '(.data \| keys[] \| select(startswith("resource.customizations.health"))), .data["timeout.reconciliation"]'` | The two health keys and `60s` |
| Argo Workflows CLI | `argo list` | No error |
| Controller metrics | `kubectl -n argo get svc -l app.kubernetes.io/component=workflow-controller` | Service with port `metrics` (8080) |

## 10. Next steps for the POC

Continue with the remaining prerequisite steps in `tpg-aks-infra` (see its README). Every step is idempotent, so starting again from `service-accounts` is safe:

```bash
cd tpg-aks-infra
./scripts/run.sh --hub install --targets terraform --from vault
# pre-created clusters:
# ./scripts/run.sh --hub install --targets precreated --inventory inventory/clusters.yaml --from vault
argo submit -n argo --from workflowtemplate/tpg-day0 \
  -p clusters=all -p 'instances=[orders-db]' -p highAvailability=true \
  -p operatorVersion=v4.5.0 -p postgresVersion=postgres-17.6 -p pushMode=direct -p dryRun=true --watch
```

Every list input is written in brackets (`'instances=[orders-db]'`; Round 23), and `tpg-fleet/docs/workflow-commands.md` has a parameter-file schema and two worked examples for each workflow.

## 11. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `EXTERNAL-IP` stays `<pending>` | Public IP quota reached, or the cluster identity cannot create load balancer rules | `kubectl -n argocd describe svc argocd-server` shows the event. Check the Public IP quota in `eastus2` with `az network list-usages -l eastus2 -o table`. Confirm the cluster identity has Network Contributor on the cluster subnet. |
| Browser or curl times out | Your IP is not in `loadBalancerSourceRanges`, or it changed | Update `ALLOWED_CIDRS` and re-run the `helm upgrade --install` commands, or update `adminAllowedCidrs` in the inventory and run `scripts/run.sh --hub install --targets <mode> --only hub`. |
| `kubectl` returns `Unable to connect to the server` | Your IP is not in the AKS API server authorized IP ranges | `az aks update -g $RESOURCE_GROUP -n $HUB_CLUSTER --api-server-authorized-ip-ranges <cidrs>`, or update Terraform. |
| Certificate warning in the browser | Both servers use self-signed certificates | Expected in the POC. For trusted certificates, add an ingress controller with cert-manager and a DNS name. |
| `argocd login` hangs or fails with a gRPC error | gRPC over HTTP/2 through the load balancer | Add `--grpc-web`. |
| Argo Workflows UI shows `Unauthorized` | Token pasted without `Bearer `, or the token Secret was not populated | Re-read the token with the command in step 8, including the `Bearer ` prefix. |
| Argo Workflows UI shows `Forbidden` for the namespace | Missing RoleBinding for `argo-ui-admin` | Re-apply the manifest in step 5. |
| Applications stay `Progressing` on a `VaultStaticSecret` | Vault sealed, or the Vault Secrets Operator cannot log in | `kubectl -n vault exec vault-0 -- vault status`; unseal with `scripts/run.sh ... --only vault-unseal`, then check `kubectl -n <namespace> get vaultstaticsecret <name> -o yaml` |
| Workflow pods fail with `workflowtaskresults ... forbidden` | The ServiceAccount running the workflow lacks executor permissions | For POC workflows, bootstrap `tpg-fleet` (creates `tpg-workflow`). For tests, use the hello-executor Role in step 8. |
| `helm upgrade` times out | Nodes not ready, or images cannot be pulled | `kubectl get events -A --sort-by=.lastTimestamp | tail -30` |
| An instance Application is Healthy while its pods do not run | `argocd-cm` has no `Postgres` health check (installed with older values) | Re-run the `helm upgrade --install` in section 4, or `scripts/run.sh ... --only hub` and answer `u`. On an existing hub, `check-argo.sh` adds it and prints the Helm values to merge. |
| A new cluster's operator Application stays OutOfSync for minutes after its CRDs exist | Argo CD's cache refreshes on `timeout.reconciliation` | The workflows hard-refresh after checking the CRDs on the target; by hand: `argocd app get <app> --hard-refresh`. |

## 12. Upgrade and uninstall

### 12.1 Upgrade

Read the release notes and upgrade guides first (Argo CD `docs/operator-manual/upgrading/`, Argo Workflows `docs/upgrading.md`), then change `--version` and re-run the same `helm upgrade --install` command:

```bash
helm search repo argo/argo-cd --versions | head -5
helm search repo argo/argo-workflows --versions | head -5
```

### 12.2 Uninstall

```bash
helm uninstall argo-workflows -n argo
helm uninstall argocd -n argocd
helm uninstall vault -n vault                                   # deletes the Vault server
helm uninstall vault-secrets-operator -n vault-secrets-operator-system

# CRDs are kept by Helm; remove them only if nothing else uses them
kubectl get crd -o name | grep argoproj.io | xargs kubectl delete

kubectl delete namespace argo argocd vault vault-secrets-operator-system
```

Deleting the LoadBalancer Services releases their Azure public IPs automatically. The Vault PersistentVolumeClaim uses the `Retain` StorageClass: delete the PVC and the released PersistentVolume by hand when you want the storage back. Deleting Vault without the unseal or recovery keys leaves the data unreadable.
