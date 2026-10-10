#!/usr/bin/env bash
# On every target cluster:
#   argocd-manager      cluster-admin, long-lived token Secret (Argo CD and Argo Workflows)
#   tpg-vault-reviewer  system:auth-delegator, long-lived token Secret: Vault on the hub
#                       reviews the Vault Secrets Operator tokens of this cluster with it
#                       (auth/k8s-<cluster>, configured by the register step)
source "$(dirname "$0")/../lib/common.sh"

require_cmd kubectl yq
require_inventory

for c in $(target_names); do
  require_context "$c"
  log "Configuring argocd-manager on $c"
  apply_stdin "$c" <<'YAML' >/dev/null
apiVersion: v1
kind: ServiceAccount
metadata:
  name: argocd-manager
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: argocd-manager
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: ServiceAccount
    name: argocd-manager
    namespace: kube-system
---
apiVersion: v1
kind: Secret
metadata:
  name: argocd-manager-token
  namespace: kube-system
  annotations:
    kubernetes.io/service-account.name: argocd-manager
type: kubernetes.io/service-account-token
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: tpg-vault-reviewer
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: tpg-vault-reviewer
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:auth-delegator
subjects:
  - kind: ServiceAccount
    name: tpg-vault-reviewer
    namespace: kube-system
---
apiVersion: v1
kind: Secret
metadata:
  name: tpg-vault-reviewer-token
  namespace: kube-system
  annotations:
    kubernetes.io/service-account.name: tpg-vault-reviewer
type: kubernetes.io/service-account-token
YAML
  tok=""
  for _ in $(seq 1 30); do
    tok="$(kubectl --context "$c" -n kube-system get secret argocd-manager-token \
      -o jsonpath='{.data.token}' 2>/dev/null || true)"
    [[ -n "$tok" ]] && break
    sleep 2
  done
  [[ -n "$tok" ]] || die "token for argocd-manager on $c was not populated"
  tok=""
  for _ in $(seq 1 30); do
    tok="$(kubectl --context "$c" -n kube-system get secret tpg-vault-reviewer-token \
      -o jsonpath='{.data.token}' 2>/dev/null || true)"
    [[ -n "$tok" ]] && break
    sleep 2
  done
  [[ -n "$tok" ]] || die "token for tpg-vault-reviewer on $c was not populated"
  ok "$c tokens ready (argocd-manager, tpg-vault-reviewer)"
done
