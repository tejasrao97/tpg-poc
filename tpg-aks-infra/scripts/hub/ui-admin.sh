#!/usr/bin/env bash
# Create the argo-ui-admin ServiceAccount and token used to log in to the Argo
# Workflows UI (authModes: client). Additive and idempotent.
source "$(dirname "$0")/../lib/common.sh"

require_inventory
HUB="$(hub_name)"
log "argo/argo-ui-admin ServiceAccount (Argo Workflows UI login)"
apply_stdin "$HUB" <<'YAML' >/dev/null
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
YAML
ok "argo-ui-admin"
