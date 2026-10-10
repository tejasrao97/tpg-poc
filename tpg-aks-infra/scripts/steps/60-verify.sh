#!/usr/bin/env bash
# Read-only verification that every prerequisite is in place before running
# any Argo Workflow.
#
# Every check that reads a field of a Kubernetes object first asks whether that
# object exists. A missing object is reported as "<kind>/<name> not found on
# <cluster>" instead of an empty field comparison, so the WARN line says what to
# create rather than only that a value did not match.
#
# The run does not stop at the first problem. At the end it prints a summary:
#   ISSUES    every failed check, grouped by resource, with the clusters it fails
#             on and the reason per cluster (for example "StorageClass
#             tpg-data-retain: aks-tpg-poc-01, aks-tpg-poc-02, aks-tpg-poc-03")
#   WARNINGS  advisory findings that do not fail the run (a data pool that cannot
#             hold highAvailability=true instances, existing Tanzu Postgres CRDs,
#             a target StorageClass tpg-data-retain that the first tpg-day0 run
#             has not created yet)
# Exit 1 when there is at least one issue; otherwise "All checks passed" and exit 0.
source "$(dirname "$0")/../lib/common.sh"
source "$(dirname "$0")/../lib/vault.sh"
# shellcheck source=scripts/lib/argo-rbac.sh
source "$(dirname "$0")/../lib/argo-rbac.sh"

require_cmd kubectl jq yq helm
require_inventory
HUB="$(hub_name)"
FAILED=0
MON="$(kubectl --context "$HUB" -n argo get cm tpg-settings -o jsonpath='{.data.monitoringOption}' 2>/dev/null || true)"
CUR="$HUB"

# Findings (issue, advisory) and the summary
# shellcheck source=scripts/lib/findings.sh
source "$(dirname "$0")/../lib/findings.sh"

# ----------------------------------------------------------------- check helpers
# check DESC COMMAND
#   Generic check for anything that is not a single Kubernetes object.
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else issue "$1" "${3:-check failed}"; fi; }

# _obj_missing CTX NS OBJ -> 0 when the object does not exist (or the cluster is
# unreachable), and prints the reason.
_obj_missing() {
  local ctx="$1" ns="$2" obj="$3" err
  local -a nsargs=() objargs=()
  [[ -z "$ns" ]] || nsargs=(-n "$ns")
  read -r -a objargs <<<"$obj"
  err="$(kubectl --context "$ctx" "${nsargs[@]}" get "${objargs[@]}" -o name 2>&1 >/dev/null)" && return 1
  case "$err" in
    *"the server doesn't have a resource type"*|*"no matches for kind"*|*"could not find the requested resource"*)
      printf '%s is not a resource type on %s (its CRD or API is missing)' "$obj" "$ctx" ;;
    *"NotFound"*|*"not found"*)
      printf '%s not found on %s%s' "$obj" "$ctx" "${ns:+ (namespace ${ns})}" ;;
    *"Unauthorized"*|*"forbidden"*|*"Forbidden"*)
      printf 'cannot read %s on %s: %s' "$obj" "$ctx" "${err##*: }" ;;
    *) printf 'cannot read %s on %s: %s' "$obj" "$ctx" "$(tr '\n' ' ' <<<"$err")" ;;
  esac
  return 0
}

# exists DESC CTX NS OBJ
#   The object must exist. NS empty for cluster-scoped objects.
exists() {
  local desc="$1" ctx="$2" ns="$3" obj="$4" why
  if why="$(_obj_missing "$ctx" "$ns" "$obj")"; then issue "$desc" "$why"; return 0; fi
  ok "$desc"
}

# field DESC CTX NS OBJ JSONPATH EXPECTED
#   The object must exist and the field must equal EXPECTED exactly. A mismatch
#   reports the value that is there.
field() {
  local desc="$1" ctx="$2" ns="$3" obj="$4" path="$5" want="$6" got why
  local -a nsargs=() objargs=()
  [[ -z "$ns" ]] || nsargs=(-n "$ns")
  read -r -a objargs <<<"$obj"
  if why="$(_obj_missing "$ctx" "$ns" "$obj")"; then issue "$desc" "$why"; return 0; fi
  got="$(kubectl --context "$ctx" "${nsargs[@]}" get "${objargs[@]}" -o jsonpath="$path" 2>/dev/null || true)"
  if [[ "$got" == "$want" ]]; then ok "$desc"; return 0; fi
  issue "$desc" "${obj} has '${got:-<empty>}' where '${want}' is expected"; return 0
}

# match DESC CTX NS OBJ JSONPATH EGREP_PATTERN WHAT
#   Like field, for a value that is matched rather than compared.
match() {
  local desc="$1" ctx="$2" ns="$3" obj="$4" path="$5" pat="$6" what="$7" got why
  local -a nsargs=() objargs=()
  [[ -z "$ns" ]] || nsargs=(-n "$ns")
  read -r -a objargs <<<"$obj"
  if why="$(_obj_missing "$ctx" "$ns" "$obj")"; then issue "$desc" "$why"; return 0; fi
  got="$(kubectl --context "$ctx" "${nsargs[@]}" get "${objargs[@]}" -o jsonpath="$path" 2>/dev/null || true)"
  if grep -Eq "$pat" <<<"$got"; then ok "$desc"; return 0; fi
  issue "$desc" "${obj} has '${got:-<empty>}', expected ${what}"; return 0
}

# jq_check DESC CTX NS OBJ JQ_EXPRESSION WHAT
#   Like field, for a condition that needs jq over the whole object.
jq_check() {
  local desc="$1" ctx="$2" ns="$3" obj="$4" expr="$5" what="$6" why
  local -a nsargs=() objargs=()
  [[ -z "$ns" ]] || nsargs=(-n "$ns")
  read -r -a objargs <<<"$obj"
  if why="$(_obj_missing "$ctx" "$ns" "$obj")"; then issue "$desc" "$why"; return 0; fi
  if kubectl --context "$ctx" "${nsargs[@]}" get "${objargs[@]}" -o json 2>/dev/null | jq -e "$expr" >/dev/null 2>&1; then
    ok "$desc"; return 0
  fi
  issue "$desc" "${obj} exists but ${what}"; return 0
}

# rollout DESC CTX NS deploy/NAME
#   The Deployment must exist and its rollout must be complete.
rollout() {
  local desc="$1" ctx="$2" ns="$3" obj="$4" why
  if why="$(_obj_missing "$ctx" "$ns" "$obj")"; then issue "$desc" "$why"; return 0; fi
  if kubectl --context "$ctx" -n "$ns" rollout status "$obj" --timeout=10s >/dev/null 2>&1; then ok "$desc"; return 0; fi
  issue "$desc" "${obj} exists but is not rolled out ($(kubectl --context "$ctx" -n "$ns" get "$obj" \
    -o jsonpath='{.status.readyReplicas}/{.spec.replicas} ready' 2>/dev/null || echo 'status unavailable'))"
  return 0
}

# helm_release DESC CTX NS RELEASE
#   The Helm release must exist and be deployed.
helm_release() {
  local desc="$1" ctx="$2" ns="$3" rel="$4" st
  if ! st="$(helm --kube-context "$ctx" -n "$ns" status "$rel" -o json 2>/dev/null)"; then
    issue "$desc" "Helm release ${ns}/${rel} is not installed on ${ctx}"; return 0
  fi
  st="$(jq -r '.info.status' <<<"$st")"
  if [[ "$st" == "deployed" ]]; then ok "$desc"; return 0; fi
  issue "$desc" "Helm release ${ns}/${rel} is ${st}, not deployed"; return 0
}

# ----------------------------------------------------------------- hub
log "Hub: $HUB"
CUR="$HUB"
rollout "argocd-server ready" "$HUB" argocd deploy/argocd-server
rollout "argocd-applicationset-controller ready" "$HUB" argocd deploy/argocd-applicationset-controller
if [[ -n "$(kubectl --context "$HUB" -n argo get deploy -l app.kubernetes.io/component=workflow-controller \
      -o name 2>/dev/null)" ]]; then
  match "workflow-controller ready" "$HUB" argo \
    "deploy -l app.kubernetes.io/component=workflow-controller" \
    '{.items[0].status.readyReplicas}' '^[1-9][0-9]*$' "at least one ready replica"
else
  issue "workflow-controller ready" "no Deployment labelled app.kubernetes.io/component=workflow-controller in argo on ${HUB}"
fi
match "argocd-cm accounts.workflow-bot has apiKey" "$HUB" argocd cm/argocd-cm \
  '{.data.accounts\.workflow-bot}' 'apiKey' "a value containing apiKey"
match "argocd-rbac-cm grants role:tpg-sync to workflow-bot" "$HUB" argocd cm/argocd-rbac-cm \
  '{.data.policy\.csv}' '^[[:space:]]*g, workflow-bot, role:tpg-sync[[:space:]]*$' "a line 'g, workflow-bot, role:tpg-sync'"
match "argocd-rbac-cm lets role:tpg-sync read repositories (tpg-rotate-credential)" "$HUB" argocd cm/argocd-rbac-cm \
  '{.data.policy\.csv}' '^[[:space:]]*p, role:tpg-sync, repositories, get, \*, allow[[:space:]]*$' "a line 'p, role:tpg-sync, repositories, get, *, allow'"
# Only workflow-bot may sync the tpg target Applications: the tpg-fleet deny
# block in argocd-rbac-cm, evaluated with the Argo CD permission checker
if command -v argocd >/dev/null 2>&1; then
  rbac_file="$(mktemp)"
  if kubectl --context "$HUB" -n argocd get cm argocd-rbac-cm -o yaml > "$rbac_file" 2>/dev/null \
     && yq -e '.data["policy.csv"]' "$rbac_file" >/dev/null 2>&1; then
    offenders="$(tpg_rbac_offenders "$rbac_file")"
    if [[ -z "$offenders" ]]; then
      ok "argocd-rbac-cm: only workflow-bot may sync, override, update or delete tpg Applications"
    else
      issue "argocd-rbac-cm tpg-fleet deny block" "these subjects may still sync, override, update or delete tpg Applications: $(paste -sd' ' <<<"$offenders") (hub install: re-run --only hub; existing hub: --only hub --yes)"
    fi
    if tpg_rbac_can "$rbac_file" workflow-bot sync; then
      ok "argocd-rbac-cm: workflow-bot may sync tpg Applications"
    else
      issue "argocd-rbac-cm workflow-bot sync" "workflow-bot may not sync tpg Applications (role:tpg-sync missing or denied)"
    fi
  else
    issue "argocd-rbac-cm tpg-fleet deny block" "cannot read policy.csv of argocd-rbac-cm on ${HUB}"
  fi
  rm -f "$rbac_file"
else
  advisory "Argo CD RBAC" "not checked: the argocd CLI is not installed on this workstation"
fi
for kind in secrets.hashicorp.com_VaultStaticSecret sql.tanzu.vmware.com_Postgres; do
  jq_check "argocd-cm health check ${kind#*_}" "$HUB" argocd cm/argocd-cm \
    ".data[\"resource.customizations.health.${kind}\"] // \"\" | length > 0" \
    "has no resource.customizations.health.${kind} (hub install: re-run --only hub and upgrade argocd; existing hub: --only hub adds it)"
done
exists "secret argo/argocd-workflow-token" "$HUB" argo secret/argocd-workflow-token
for s in tpg-src-broadcom-registry tpg-src-backup-storage tpg-git-push; do
  if kubectl --context "$HUB" -n argo get secret "$s" >/dev/null 2>&1; then
    issue "former Secret argo/$s" "still exists: re-run the hub-secrets step (credentials live in Vault now)"
  fi
done
exists "configmap argo/tpg-settings" "$HUB" argo cm/tpg-settings
jq_check "tpg-settings vaultAddr and vaultFleetAddr set" "$HUB" argo cm/tpg-settings \
  '.data.vaultAddr and .data.vaultFleetAddr' "vaultAddr or vaultFleetAddr is missing (re-run the hub-secrets step)"
jq_check "tpg-settings backupCaBundle (Azure Storage CA bundle for enableSSL: true)" "$HUB" argo cm/tpg-settings \
  '(.data.backupCaBundle // "") | test("BEGIN CERTIFICATE")' "backupCaBundle is missing or holds no certificate (re-run the hub-secrets step)"
jq_check "tpg-settings acnsEnabled" "$HUB" argo cm/tpg-settings \
  '(.data.acnsEnabled // "") | test("^(true|false)$")' "acnsEnabled is missing (re-run the hub-secrets step)"
# Archived workflow logs (artifact repository with archiveLogs)
# shellcheck disable=SC2016  # jq variables
jq_check "archived workflow logs: ConfigMap argo/artifact-repositories" "$HUB" argo cm/artifact-repositories \
  '(.metadata.annotations["workflows.argoproj.io/default-artifact-repository"] // "") as $d | $d != "" and ((.data[$d] // "") | test("archiveLogs.*true"))' \
  "has no default repository with archiveLogs: true (re-run the hub-secrets step)"
exists "archived workflow logs: Secret argo/argo-artifacts (from Vault)" "$HUB" argo secret/argo-artifacts

# ----------------------------------------------------------------- Vault
log "Vault"
VST="$(vault_status)"
if [[ -n "$VST" ]]; then
  ok "Vault $(jq -r '.version' <<<"$VST"), seal type $(jq -r '.type' <<<"$VST")"
  if [[ "$(jq -r '.initialized' <<<"$VST")" == "true" && "$(jq -r '.sealed' <<<"$VST")" == "false" ]]; then
    ok "Vault initialized and unsealed"
    if vault_login try; then
      paths=(shared/broadcom-registry shared/github-read shared/github-push shared/backup-storage)
      [[ "$MON" != "standalone" ]] || paths+=(shared/monitoring-remote-write)
      for p in "${paths[@]}"; do
        check "Vault secret tpg/$p" "vault_kv_exists $p" "not found in Vault (re-run the hub-secrets or addons step)"
      done
      AUTHS="$(vt auth list -format=json </dev/null)"
      for c in $(target_names); do
        CUR="$c"
        if jq -e --arg m "k8s-$c/" 'has($m)' <<<"$AUTHS" >/dev/null; then ok "Vault auth/k8s-$c"
        else issue "Vault auth/k8s-$c" "missing: run the register step"; fi
      done
      CUR="$HUB"
    else
      issue "Vault login with role tpg-setup" "refused although Vault is unsealed: auth/kubernetes is not configured (a vault step ended after init): run --only vault"
    fi
  else
    issue "Vault initialized and unsealed" "Vault is not initialized or is sealed: run the vault step or --only vault-unseal"
  fi
else
  issue "Vault pod vault/vault-0" "not reachable"
fi
helm_release "Helm release vault/vault" "$HUB" vault vault
rollout "Vault Agent Injector ready" "$HUB" vault deploy/vault-agent-injector
match "Service vault/vault-fleet has an IP" "$HUB" vault svc/vault-fleet \
  '{.status.loadBalancer.ingress[0].ip}' '.' "an external IP (the load balancer is still being created)"
exists "secret argo/vault-ca (Vault Agent CA)" "$HUB" argo secret/vault-ca
field "StorageClass tpg-data-retain (disk SKU $(data_disk_sku))" "$HUB" "" \
  storageclass/tpg-data-retain '{.parameters.skuName}' "$(data_disk_sku)"
if [[ -n "$(kubectl --context "$HUB" -n vault-secrets-operator-system get deploy -o name 2>/dev/null)" ]]; then
  ok "Vault Secrets Operator on the hub"
else
  issue "Vault Secrets Operator on the hub" "no Deployment in namespace vault-secrets-operator-system on ${HUB}"
fi
for s in argocd/repo-tpg-fleet argocd/repo-tanzu-postgres-oci argo/argo-artifacts; do
  jq_check "VaultStaticSecret $s synced" "$HUB" "${s%%/*}" "vaultstaticsecret/${s##*/}" \
    '[.status.conditions[]? | select(.type == "Ready" or .type == "SecretSynced")] | ((map(select(.type == "Ready")) + .)[0].status // "") == "True"' \
    "neither Ready nor SecretSynced is True (check the VaultAuth and the Vault path)"
done
for s in repo-tpg-fleet repo-tanzu-postgres-oci; do
  exists "secret argocd/$s" "$HUB" argocd "secret/$s"
done
exists "AppProject tpg" "$HUB" argocd appproject/tpg
exists "AppProject tpg-hub" "$HUB" argocd appproject/tpg-hub
field "tpg-hub-workflows in project tpg-hub" "$HUB" argocd application/tpg-hub-workflows '{.spec.project}' tpg-hub
# Hub admission policies (tpg-fleet workflows/admission): input types of the
# workflows, only the workflows sync the target Applications, and only
# tpg-rotate-credential runs as tpg-credential-writer (Round 15)
for pol in tpg-workflow-parameters tpg-application-sync tpg-credential-writer; do
  exists "ValidatingAdmissionPolicy ${pol}" "$HUB" "" "validatingadmissionpolicy/${pol}"
  exists "ValidatingAdmissionPolicyBinding ${pol}" "$HUB" "" "validatingadmissionpolicybinding/${pol}"
done
for t in tpg-lib tpg-day0 tpg-create-instance tpg-upgrade tpg-patch tpg-scale-instance tpg-backup tpg-restore tpg-rotate-credential tpg-delete-instance tpg-delete-apps tpg-helm-addons tpg-network-policy; do
  exists "WorkflowTemplate $t" "$HUB" argo "workflowtemplate/$t"
done
exists "ServiceAccount argo/tpg-workflow" "$HUB" argo sa/tpg-workflow
exists "ServiceAccount argo/tpg-credential-writer" "$HUB" argo sa/tpg-credential-writer

# ----------------------------------------------------------------- monitoring (hub)
case "$MON" in
  standalone)
    log "Monitoring (standalone) on the hub"
    helm_release "Helm release monitoring/kps" "$HUB" monitoring kps
    exists "Secret monitoring/grafana-admin" "$HUB" monitoring secret/grafana-admin
    rollout "Grafana ready" "$HUB" monitoring deploy/kps-grafana
    if [[ -n "$(kubectl --context "$HUB" -n monitoring get cm -l grafana_datasource=1 -o name 2>/dev/null)" ]]; then
      ok "Grafana data sources provisioned"
    else
      issue "Grafana data sources" "no ConfigMap labelled grafana_datasource=1 in monitoring: Grafana shows no data source (re-run --only addons)"
    fi
    for d in tpg-fleet tpg-instance tpg-replication tpg-backup tpg-alerts; do
      exists "Grafana dashboard ${d}" "$HUB" monitoring "cm/${d}-dashboard"
    done
    rollout "remote-write gateway ready" "$HUB" monitoring deploy/tpg-remote-write
    match "Service monitoring/tpg-remote-write has an IP" "$HUB" monitoring svc/tpg-remote-write \
      '{.status.loadBalancer.ingress[0].ip}' '.' "an external IP (re-run --only addons)"
    exists "remote-write TLS certificate" "$HUB" monitoring secret/tpg-remote-write-tls
    exists "remote-write htpasswd" "$HUB" monitoring secret/tpg-remote-write-htpasswd
    match "tpg-settings hubPrometheusRemoteWriteUrl" "$HUB" argo cm/tpg-settings \
      '{.data.hubPrometheusRemoteWriteUrl}' '^https://' "the https URL of the remote-write gateway (re-run --only addons)" ;;
  azure)
    log "Monitoring (azure) on the hub"
    jq_check "Azure Monitor metrics agent (ama-metrics)" "$HUB" kube-system "pods -l rsName=ama-metrics" \
      '(.items | length) > 0 and all(.items[]; any(.status.conditions[]?; .type == "Ready" and .status == "True"))' \
      "is not running and ready: run --only addons with MONITORING_OPTION=azure" ;;
esac

# ----------------------------------------------------------------- targets
hkq() { kubectl --context "$HUB" "$@"; }

# platform_sync_state CLUSTER -> synced | never | unknown: has the target's
# tpg-platform Application ever completed a sync? Argo CD adds a status.history
# entry for every successful sync; operationState covers a first sync whose
# history is not written yet. An Application not generated yet has never synced;
# any other read error is unknown (the StorageClass check then stays an issue).
platform_sync_state() {
  local j err
  if ! j="$(kubectl --context "$HUB" -n argocd get application "tpg-$1-platform" -o json 2>"$VERIFY_TMP_ERR")"; then
    err="$(cat "$VERIFY_TMP_ERR" 2>/dev/null)"
    case "$err" in *NotFound*|*"not found"*) echo never ;; *) echo unknown ;; esac
    return 0
  fi
  if jq -e '((.status.history // []) | length) > 0
            or ((.status.operationState.phase // "") == "Succeeded")' >/dev/null 2>&1 <<<"$j"; then
    echo synced
  else
    echo never
  fi
}

# target_storageclass CLUSTER
#   tpg-data-retain on a target comes from the tpg-platform Application, which
#   only tpg-day0 syncs (day0-deploy.sh). Not found before that first sync is
#   expected: a warning naming the step that creates it. Not found after it, not
#   readable, a platform Application the hub cannot read, or a wrong disk SKU at
#   any time, is an issue.
VERIFY_TMP_ERR="$(mktemp)"; cleanup_add "rm -f '$VERIFY_TMP_ERR'"
target_storageclass() {
  local c="$1" desc why
  desc="StorageClass tpg-data-retain (disk SKU $(data_disk_sku))"
  if why="$(_obj_missing "$c" "" storageclass/tpg-data-retain)" && [[ "$why" == *" not found on "* ]] \
     && [[ "$(platform_sync_state "$c")" == never ]]; then
    advisory "$desc" "${why}; this object will be created when the tpg-day0 workflow runs (day0-deploy.sh syncs the cluster's tpg-platform Application, which has not synced yet)"
    return 0
  fi
  field "$desc" "$c" "" storageclass/tpg-data-retain '{.parameters.skuName}' "$(data_disk_sku)"
}
# target_instances CLUSTER
#   The instances declared for CLUSTER in clusters/fleet.yaml of the tpg-fleet clone (FLEET_LOCAL_DIR), each
#   in its namespace: instance.namespace, default pg-<instance> (Round 23). The namespace is not reserved;
#   exactly one instance of a namespace renders the Secrets the chart names the same in every instance
#   (instance.sharedSecretsOwner is not false); a namespace or Postgres object that does not exist yet is
#   a warning (tpg-day0 and tpg-create-instance create them). Skipped without a clone.
target_instances() {
  local c="$1" f="${FLEET_LOCAL_DIR:-}/clusters/fleet.yaml" keysf="${FLEET_LOCAL_DIR:-}/workflows/params/cluster-map-keys.yaml" i ns own reserved prefixes pfx why is_reserved
  local -A owners=() members=()
  [[ -n "${FLEET_LOCAL_DIR:-}" && -f "$f" ]] || return 0
  # the one list of reserved namespaces, in the fleet clone: names and prefixes (cluster-map-keys.yaml)
  reserved="$(yq -r '.instance.namespace.reserved[]' "$keysf" 2>/dev/null || true)"
  prefixes="$(yq -r '.instance.namespace.reservedPrefixes[]?' "$keysf" 2>/dev/null || true)"
  for i in $(C="$c" yq -r '.clusters[strenv(C)].instances // {} | keys | .[]' "$f"); do
    ns="$(C="$c" I="$i" yq -r '.clusters[strenv(C)].instances[strenv(I)].instance.namespace // ""' "$f")"; ns="${ns:-pg-$i}"
    own="$(C="$c" I="$i" yq -r '.clusters[strenv(C)].instances[strenv(I)].instance.sharedSecretsOwner | select(. != null)' "$f")"   # (// would turn false into true)
    members[$ns]="${members[$ns]:+${members[$ns]}, }${i}"
    [[ "$own" == false ]] || owners[$ns]=$(( ${owners[$ns]:-0} + 1 ))
    is_reserved=false
    grep -Fqx -- "$ns" <<<"$reserved" && is_reserved=true
    for pfx in $prefixes; do [[ "$ns" == "$pfx"* ]] && is_reserved=true; done
    if [[ "$is_reserved" == true ]]; then
      issue "instance ${c}/${i} namespace ${ns}" "${ns} is a reserved namespace: instance.namespace of clusters.${c}.instances.${i} in clusters/fleet.yaml must be another one"
    elif why="$(_obj_missing "$c" "" "namespace/${ns}")"; then
      advisory "namespace ${ns} of instance ${c}/${i}" "${why}; tpg-day0 or tpg-create-instance creates it"
    elif kubectl --context "$c" get crd postgres.sql.tanzu.vmware.com >/dev/null 2>&1 \
         && why="$(_obj_missing "$c" "$ns" "postgres/${i}")"; then
      advisory "Postgres ${c}/${i}" "${why}; declared in clusters/fleet.yaml, not deployed yet"
    else
      ok "instance ${c}/${i} in namespace ${ns}"
    fi
  done
  for ns in "${!members[@]}"; do
    [[ "${owners[$ns]:-0}" -eq 1 ]] \
      || issue "namespace ${ns} shared Secrets" "${owners[$ns]:-0} of the instances ${members[$ns]} render the shared Secrets (ServiceAccount tpg-vso, VaultStaticSecrets regsecret and backup-storage); exactly one must (instance.sharedSecretsOwner false on the others in clusters/fleet.yaml)"
  done
  return 0
}
for c in $(target_names); do
  log "Target: $c"
  CUR="$c"
  exists "cluster Secret argocd/cluster-$c" "$HUB" argocd "secret/cluster-$c"
  exists "kubeconfig Secret argo/kubeconfig-$c" "$HUB" argo "secret/kubeconfig-$c"
  match "kubeconfig-$c has the tpg.fleet/wave label" "$HUB" argo "secret/kubeconfig-$c" \
    '{.metadata.labels.tpg\.fleet/wave}' '^[0-9]+$' "a numeric wave label (re-run the register step)"
  exists "cert-manager available" "$c" "" crd/certificates.cert-manager.io
  exists "Vault Secrets Operator available" "$c" "" crd/vaultstaticsecrets.secrets.hashicorp.com
  target_storageclass "$c"
  target_instances "$c"
  field "VaultAuth tpg-vault/tpg-vault (auth/k8s-$c)" "$c" tpg-vault vaultauth/tpg-vault \
    '{.spec.mount}' "k8s-$c"
  exists "ServiceAccount kube-system/tpg-vault-reviewer" "$c" kube-system secret/tpg-vault-reviewer-token
  case "$MON" in
    standalone)
      helm_release "Helm release monitoring/kps" "$c" monitoring kps
      helm_release "Helm release monitoring/tpg-ksm" "$c" monitoring tpg-ksm
      exists "remote-write credential monitoring/tpg-remote-write (from Vault)" "$c" monitoring secret/tpg-remote-write
      exists "remote-write CA monitoring/tpg-remote-write-ca" "$c" monitoring secret/tpg-remote-write-ca
      # One query, no wait: are this cluster's metrics on the hub?
      if monitoring_flowing hkq "$c" 0 >/dev/null 2>&1; then
        ok "metrics reach the hub Prometheus"
      else
        issue "metrics reach the hub Prometheus" "no up{cluster=\"$c\"} series on the hub Prometheus: check the target Prometheus remote-write errors and the gateway, then re-run --only addons"
      fi ;;
    azure)
      jq_check "Azure Monitor metrics agent (ama-metrics)" "$c" kube-system "pods -l rsName=ama-metrics" \
        '(.items | length) > 0 and all(.items[]; any(.status.conditions[]?; .type == "Ready" and .status == "True"))' \
        "is not running and ready: run --only addons with MONITORING_OPTION=azure" ;;
  esac
  check "argocd-manager is cluster-admin" "kubectl --context $c auth can-i '*' '*' --as=system:serviceaccount:kube-system:argocd-manager | grep -q yes" \
    "kube-system/argocd-manager is not cluster-admin (re-run the service-accounts step)"
  # Data pool shape. 3 Ready nodes across 3 zones is what highAvailability=true
  # needs; a smaller pool is a valid choice, so this is advisory only.
  pool="$(kubectl --context "$c" get nodes -l tpg.fleet/pool=postgres -o json 2>/dev/null | jq -c '.items')"
  [[ "$(jq 'length' <<<"${pool:-[]}")" -gt 0 ]] \
    || pool="$(kubectl --context "$c" get nodes -l agentpool=pgdata -o json 2>/dev/null | jq -c '.items')"
  nready="$(jq '[.[] | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | length' <<<"${pool:-[]}")"
  nzones="$(jq -r '[.[] | .metadata.labels["topology.kubernetes.io/zone"] // empty] | unique | length' <<<"${pool:-[]}")"
  if [[ "${nready:-0}" -ge 3 && "${nzones:-0}" -ge 3 ]]; then
    ok "data pool: $nready Ready nodes across $nzones zones (highAvailability can be scheduled)"
  else
    advisory "data pool not HA-capable" "${nready:-0} Ready node(s) in ${nzones:-0} zone(s); tpg-day0 refuses highAvailability=true on this cluster"
  fi
  apps="$(kubectl --context "$HUB" -n argocd get applications -l "tpg.fleet/cluster=$c" -o name 2>/dev/null | wc -l)"
  # tpg-platform is generated for every registered cluster; operator and instances after tpg-day0
  if [[ "$apps" -gt 0 ]]; then ok "$apps Argo CD Applications generated"
  else issue "Argo CD Applications generated" "none for this cluster yet (the tpg-platform ApplicationSet generates one per registered cluster: check the bootstrap step and the cluster Secret label tpg.fleet/managed)"; fi
  # Informational pre-check (the Day 0 workflow makes the real decision)
  if kubectl --context "$c" get crd postgres.sql.tanzu.vmware.com >/dev/null 2>&1; then
    advisory "existing Tanzu Postgres CRDs" "found; the Day 0 pre-check marks the cluster MANAGED or BLOCKED"
    # Azure Blob backups rest on the live CRD: the 4.5 documentation lists S3 and GCS only (D63)
    # spec.storage.azure is required; caBundle only for enableSSL: true (advisory)
    jq_check "PostgresBackupLocation CRD offers spec.storage.azure" "$c" "" crd/postgresbackuplocations.sql.tanzu.vmware.com \
      '[.spec.versions[] | select(.storage)][0].schema.openAPIV3Schema.properties.spec.properties.storage.properties.azure.properties // {} | has("container")' \
      "the operator's PostgresBackupLocation CRD has no spec.storage.azure: Azure Blob backups are not available with this operator version"
    if kubectl --context "$c" get crd postgresbackuplocations.sql.tanzu.vmware.com -o json 2>/dev/null \
         | jq -e '[.spec.versions[] | select(.storage)][0].schema.openAPIV3Schema.properties.spec.properties.storage.properties.azure.properties // {} | has("caBundle")' >/dev/null; then
      ok "PostgresBackupLocation CRD offers spec.storage.azure.caBundle (enableSSL: true)"
    else
      advisory "no spec.storage.azure.caBundle" "instances with backup.enableSSL: true are BLOCKED by the Day 0 pre-check on this cluster; enableSSL: false still works"
    fi
  else
    ok "no existing Tanzu Postgres CRDs"
  fi
  # Network policies (tpg-network-policy, networkPolicy=baseline) need CiliumNetworkPolicy
  if kubectl --context "$c" get crd ciliumnetworkpolicies.cilium.io >/dev/null 2>&1; then
    ok "CiliumNetworkPolicy available (network policies)"
  else
    advisory "CiliumNetworkPolicy not available" "networkPolicy=baseline and tpg-network-policy need Azure CNI powered by Cilium"
  fi
done
CUR="$HUB"

print_summary
log "Next (dry run): argo submit -n argo --from workflowtemplate/tpg-day0 -p clusters=all -p 'instances=[orders-db]' -p highAvailability=true -p operatorVersion=v4.5.0 -p postgresVersion=postgres-17.6 -p pushMode=direct -p dryRun=true"
