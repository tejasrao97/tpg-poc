#!/usr/bin/env bash
# Scenario: hub that already runs Argo CD and Argo Workflows.
#
# 1. Read-only checks of the existing installation.
# 2. Additive changes the fleet needs (never removes or rewrites your settings):
#      argocd-cm        accounts.workflow-bot: apiKey        (only if missing)
#      argocd-cm        health checks for VaultStaticSecret and Postgres (each only if missing)
#      argocd-rbac-cm   role:tpg-sync lines appended to policy.csv (only if missing)
#      argocd-rbac-cm   the marked "tpg-fleet rbac" block: deny lines (sync, override,
#                       update, delete on project tpg) for role:admin and every other
#                       subject the Argo CD permission checker finds able to act on
#                       project tpg; written with --yes (ASSUME_YES=1) only, otherwise
#                       the lines are printed and the step fails with ARGO_RBAC_MISSING
#      argo             argo-ui-admin ServiceAccount
# 3. Opt-in changes (flags of run.sh):
#      SET_TRACKING_ANNOTATION=1  application.resourceTrackingMethod: annotation
#      EXPOSE_UI=1                argocd-server and Argo Workflows server as LoadBalancer
# CHECK_ONLY=1 skips 2 and 3.
#
# Because Helm owns these objects, the script also writes the equivalent Helm
# values to .work/hub-existing-*.yaml. Merge them into your values files, or the
# next helm upgrade reverts the changes.
source "$(dirname "$0")/../../lib/common.sh"
# shellcheck source=scripts/lib/argo-rbac.sh
source "$(dirname "$0")/../../lib/argo-rbac.sh"

for arg in "$@"; do
  case "$arg" in
    --yes) ASSUME_YES=1 ;;          # same as run.sh --yes
    --check-only) CHECK_ONLY=1 ;;
    *) die "check-argo.sh: unknown argument '$arg' (accepted: --yes, --check-only)" ;;
  esac
done
require_cmd kubectl jq yq argocd python3
require_inventory
HUB="$(hub_name)"
CHECK_ONLY="${CHECK_ONLY:-0}"
ASSUME_YES="${ASSUME_YES:-0}"
SET_TRACKING_ANNOTATION="${SET_TRACKING_ANNOTATION:-0}"
EXPOSE_UI="${EXPOSE_UI:-0}"
FAILED=0
fail() { warn "$*"; FAILED=1; }
require_context "$HUB"

image_tag() {
  kubectl --context "$HUB" -n "$1" get "$2" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null \
    | sed 's/.*://'
}

ready() {
  local ns="$1" obj="$2" want have
  want="$(kubectl --context "$HUB" -n "$ns" get "$obj" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "")"
  have="$(kubectl --context "$HUB" -n "$ns" get "$obj" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "")"
  [[ -n "$want" && "${have:-0}" -ge 1 && "${have:-0}" -eq "$want" ]]
}

# ---------------------------------------------------------------- Argo CD
log "Argo CD in namespace argocd"
kubectl --context "$HUB" get ns argocd >/dev/null 2>&1 \
  || die "namespace argocd not found. The fleet manifests expect Argo CD in argocd and Argo Workflows in argo; use --hub install or move the installation"

for obj in deploy/argocd-server deploy/argocd-repo-server deploy/argocd-applicationset-controller statefulset/argocd-application-controller; do
  if ready argocd "$obj"; then ok "$obj ready"; else fail "$obj missing or not ready"; fi
done

tag="$(image_tag argocd deploy/argocd-server)"
case "$tag" in
  v3.*) ok "Argo CD $tag" ;;
  "")   fail "cannot read the Argo CD version" ;;
  *)    fail "Argo CD $tag: the fleet is tested with v3.5.x (ApplicationSet goTemplate, annotation tracking)" ;;
esac

CM="$(kubectl --context "$HUB" -n argocd get cm argocd-cm -o json)"
tracking="$(jq -r '.data["application.resourceTrackingMethod"] // "annotation (default)"' <<<"$CM")"
bot="$(jq -r '.data["accounts.workflow-bot"] // ""' <<<"$CM")"
# Lua health checks the fleet relies on, read from argo/argocd-values.yaml:
#   VaultStaticSecret  Healthy once the Secret is synced from Vault
#   Postgres           Healthy only when status.currentState is Running
HEALTH_KEYS=(resource.customizations.health.secrets.hashicorp.com_VaultStaticSecret
             resource.customizations.health.sql.tanzu.vmware.com_Postgres)
declare -A HEALTH_WANT=() HEALTH_HAVE=()
for key in "${HEALTH_KEYS[@]}"; do
  HEALTH_WANT[$key]="$(K="$key" yq -r '.configs.cm[strenv(K)]' "${REPO_ROOT}/argo/argocd-values.yaml")"
  HEALTH_HAVE[$key]="$(jq -r --arg k "$key" '.data[$k] // ""' <<<"$CM")"
done
RBAC="$(kubectl --context "$HUB" -n argocd get cm argocd-rbac-cm -o json)"
policy="$(jq -r '.data["policy.csv"] // ""' <<<"$RBAC")"

if [[ "$tracking" == annotation* ]]; then
  ok "resource tracking: $tracking"
else
  warn "resource tracking is $tracking: the Day 0 pre-check reports existing objects as BLOCKED instead of MANAGED (fix with --set-tracking-annotation)"
fi

TPG_POLICY='p, role:tpg-sync, applications, get, tpg/*, allow
p, role:tpg-sync, applications, sync, tpg/*, allow
p, role:tpg-sync, projects, get, tpg, allow
p, role:tpg-sync, repositories, get, *, allow
g, workflow-bot, role:tpg-sync'

# ---------------------------------------------------------------- Argo Workflows
log "Argo Workflows in namespace argo"
WFC="$(kubectl --context "$HUB" -n argo get deploy -l app.kubernetes.io/component=workflow-controller -o name 2>/dev/null | head -1)"
WFS="$(kubectl --context "$HUB" -n argo get deploy -l app.kubernetes.io/component=server -o name 2>/dev/null | head -1)"
if [[ -n "$WFC" ]] && ready argo "$WFC"; then ok "$WFC ready"; else fail "workflow-controller not found or not ready in argo"; fi
if [[ -n "$WFS" ]] && ready argo "$WFS"; then ok "$WFS ready"; else fail "argo-server not found or not ready in argo"; fi

if [[ -n "$WFC" ]]; then
  tag="$(image_tag argo "$WFC")"
  if [[ "$tag" == v4.* ]]; then
    ok "Argo Workflows $tag"
  else
    fail "Argo Workflows $tag: the fleet CronWorkflows use spec.schedules (v3.6+) and are tested with v4.1.x"
  fi
  args="$(kubectl --context "$HUB" -n argo get "$WFC" -o jsonpath='{.spec.template.spec.containers[0].args}')"
  if grep -q -- '--managed-namespace' <<<"$args" && ! grep -q -- '--managed-namespace=argo\|"--managed-namespace","argo"' <<<"$args"; then
    fail "workflow-controller manages a single namespace other than argo"
  else
    ok "workflow-controller watches namespace argo"
  fi
  wcm="$(kubectl --context "$HUB" -n argo get cm -l app.kubernetes.io/component=workflow-controller -o json 2>/dev/null | jq -r '.items[0].data.config // ""')"
  [[ -n "$wcm" ]] || wcm='{}'
  if [[ "$(yq -r '.metricsConfig.enabled' <<<"$wcm")" == "false" ]]; then
    fail "workflow-controller metricsConfig.enabled is false: the fleet dashboard and alerts use workflow metrics"
  else
    ok "workflow-controller metrics enabled"
  fi
fi
if [[ -n "$WFS" ]]; then
  sargs="$(kubectl --context "$HUB" -n argo get "$WFS" -o jsonpath='{.spec.template.spec.containers[0].args}')"
  if grep -q 'client' <<<"$sargs"; then
    ok "argo-server accepts client (bearer token) auth"
  else
    fail "argo-server auth modes do not include client: the runbook logs in with a ServiceAccount token (add --auth-mode=client)"
  fi
fi

# ---------------------------------------------------------------- values to persist
# The RBAC block in the values file starts as the role:admin lines in the hub's
# match mode; persist_rbac_block replaces it with the block the hub carries.
RBAC_MATCH_MODE="$(kubectl --context "$HUB" -n argocd get cm argocd-rbac-cm -o jsonpath='{.data.policy\.matchMode}' 2>/dev/null || true)"
RBAC_MATCH_MODE="${RBAC_MATCH_MODE:-glob}"
VALUES_CD="${WORK_DIR}/hub-existing-argocd-values.yaml"
VALUES_WF="${WORK_DIR}/hub-existing-argo-workflows-values.yaml"
cat > "$VALUES_CD" <<YAML
# Merge into your Argo CD Helm values so helm upgrade keeps the fleet settings.
configs:
  cm:
    application.resourceTrackingMethod: annotation
    accounts.workflow-bot: apiKey
$(for key in "${HEALTH_KEYS[@]}"; do
    printf '    %s: |\n' "$key"
    while IFS= read -r l; do printf '      %s\n' "$l"; done <<<"${HEALTH_WANT[$key]}"
  done)
  rbac:
    policy.csv: |
$(while IFS= read -r l; do printf '      %s\n' "$l"; done <<<"$TPG_POLICY")
$(while IFS= read -r l; do printf '      %s\n' "$l"; done <<<"$(tpg_rbac_block "$RBAC_MATCH_MODE" role:admin)")
server:
  service:
    type: LoadBalancer
    loadBalancerSourceRanges: $(admin_cidrs_json)
YAML
cat > "$VALUES_WF" <<YAML
# Merge into your Argo Workflows Helm values.
controller:
  metricsConfig:
    enabled: true
server:
  serviceType: LoadBalancer
  loadBalancerSourceRanges: $(admin_cidrs_json)
  authModes:
    - client
YAML
ok "Helm values to persist: $VALUES_CD, $VALUES_WF"

persist_rbac_block() {  # persist_rbac_block BLOCK: the marked block of VALUES_CD becomes BLOCK
  VALUES="$VALUES_CD" BLOCK="$1" BEGIN="$TPG_RBAC_BEGIN" END="$TPG_RBAC_END" python3 -c '
import os
path = os.environ["VALUES"]
lines = open(path).read().split("\n")
block = ["      " + l for l in os.environ["BLOCK"].split("\n")]
out, skip = [], False
for line in lines:
    if line.strip() == os.environ["BEGIN"]:
        skip = True
        out.extend(block)
        continue
    if skip:
        skip = line.strip() != os.environ["END"]
        continue
    out.append(line)
open(path, "w").write("\n".join(out))
'
}

if [[ "$CHECK_ONLY" == "1" ]]; then
  [[ "$FAILED" -eq 0 ]] || die "existing hub checks failed"
  log "Check only: no changes made"
  exit 0
fi
[[ "$FAILED" -eq 0 ]] || die "existing hub checks failed; fix them before the additive changes run"

# ---------------------------------------------------------------- additive changes
log "Additive changes"
if [[ -z "$bot" ]]; then
  kubectl --context "$HUB" -n argocd patch cm argocd-cm --type merge \
    -p '{"data":{"accounts.workflow-bot":"apiKey"}}' >/dev/null
  ok "argocd-cm: added accounts.workflow-bot: apiKey"
elif [[ "$bot" == *apiKey* ]]; then
  ok "argocd-cm: accounts.workflow-bot already has apiKey"
else
  die "argocd-cm: accounts.workflow-bot is '$bot' (no apiKey); change it manually to include apiKey"
fi

for key in "${HEALTH_KEYS[@]}"; do
  kind="${key##*_}"
  if [[ -z "${HEALTH_HAVE[$key]}" ]]; then
    kubectl --context "$HUB" -n argocd patch cm argocd-cm --type merge \
      -p "$(jq -cn --arg k "$key" --arg v "${HEALTH_WANT[$key]}" '{data: {($k): $v}}')" >/dev/null
    ok "argocd-cm: added the ${kind} health check"
  else
    ok "argocd-cm: ${kind} health check already set (kept as is)"
  fi
done

if grep -qF 'g, workflow-bot, role:tpg-sync' <<<"$policy"; then
  ok "argocd-rbac-cm: role:tpg-sync already present"
  # Round 21: tpg-rotate-credential reads the Argo CD repository list as workflow-bot
  if ! grep -qE '^[[:space:]]*p, role:tpg-sync, repositories, get, \*, allow[[:space:]]*$' <<<"$policy"; then
    newpolicy="$(printf '%s\n# tpg-fleet: workflow-bot reads repository connection states (tpg-rotate-credential)\n%s\n' "$policy" 'p, role:tpg-sync, repositories, get, *, allow')"
    kubectl --context "$HUB" -n argocd patch cm argocd-rbac-cm --type merge \
      -p "$(jq -cn --arg p "$newpolicy" '{data:{"policy.csv":$p}}')" >/dev/null
    ok "argocd-rbac-cm: added repositories get to role:tpg-sync"
  fi
else
  newpolicy="$(printf '%s\n# tpg-fleet: Argo Workflows sync account\n%s\n' "$policy" "$TPG_POLICY")"
  kubectl --context "$HUB" -n argocd patch cm argocd-rbac-cm --type merge \
    -p "$(jq -cn --arg p "$newpolicy" '{data:{"policy.csv":$p}}')" >/dev/null
  ok "argocd-rbac-cm: appended role:tpg-sync to policy.csv"
fi

# ---- people may not sync the tpg target Applications (marked block, --yes)
rbac_file="$(mktemp)"
kubectl --context "$HUB" -n argocd get cm argocd-rbac-cm -o yaml > "$rbac_file"
match_mode="$(yq -r '.data["policy.matchMode"] // "glob"' "$rbac_file")"
offenders="$(tpg_rbac_offenders "$rbac_file")"
if [[ -z "$offenders" ]]; then
  ok "argocd-rbac-cm: nobody but workflow-bot may sync, override, update or delete tpg Applications"
else
  mapfile -t subjects < <({ echo role:admin; printf '%s\n' "$offenders"; } | sort -u)
  block="$(tpg_rbac_block "$match_mode" "${subjects[@]}")"
  if [[ "$ASSUME_YES" != "1" ]]; then
    warn "argocd-rbac-cm: these subjects may still sync, override, update or delete the tpg target Applications: $(paste -sd' ' <<<"$offenders")"
    printf '%s\n' "$block" >&2
    rm -f "$rbac_file"
    die "ARGO_RBAC_MISSING: add the block above to policy.csv in argocd-rbac-cm, or re-run with --yes to append it (your own lines are kept)"
  fi
  policy_now="$(yq -r '.data["policy.csv"] // ""' "$rbac_file")"
  newpolicy="$(tpg_rbac_merge "$policy_now" "$block")"
  kubectl --context "$HUB" -n argocd patch cm argocd-rbac-cm --type merge \
    -p "$(jq -cn --arg p "$newpolicy" '{data:{"policy.csv":$p}}')" >/dev/null
  kubectl --context "$HUB" -n argocd get cm argocd-rbac-cm -o yaml > "$rbac_file"
  left="$(tpg_rbac_offenders "$rbac_file")"
  [[ -z "$left" ]] || { rm -f "$rbac_file"; die "argocd-rbac-cm: after the tpg-fleet block, these subjects can still act on tpg Applications: $(paste -sd' ' <<<"$left")"; }
  ok "argocd-rbac-cm: tpg-fleet rbac block written for ${subjects[*]}"
  warn "merge $VALUES_CD (its policy.csv carries the block) into your Argo CD Helm values, or the next helm upgrade removes it"
fi
# The block now on the hub (written above or by an earlier run) is what the values file keeps
live_block="$(yq -r '.data["policy.csv"] // ""' "$rbac_file" \
  | awk -v b="$TPG_RBAC_BEGIN" -v e="$TPG_RBAC_END" '{ l = $0; sub(/^[ \t]+/, "", l); sub(/[ \t]+$/, "", l) }
      l == b { on = 1 } on { print l } l == e { on = 0 }')"
[[ -z "$live_block" ]] || persist_rbac_block "$live_block"
tpg_rbac_can "$rbac_file" workflow-bot sync || { rm -f "$rbac_file"; die "argocd-rbac-cm: workflow-bot may not sync tpg Applications (role:tpg-sync missing or denied)"; }
ok "argocd-rbac-cm: workflow-bot may sync tpg Applications"
rm -f "$rbac_file"

"${SCRIPTS_DIR}/hub/ui-admin.sh"

# ---------------------------------------------------------------- opt-in changes
if [[ "$SET_TRACKING_ANNOTATION" == "1" && "$tracking" != annotation* ]]; then
  warn "Switching resource tracking to annotation affects every Application on this Argo CD; resources may show OutOfSync until the next sync"
  kubectl --context "$HUB" -n argocd patch cm argocd-cm --type merge \
    -p '{"data":{"application.resourceTrackingMethod":"annotation"}}' >/dev/null
  ok "argocd-cm: application.resourceTrackingMethod: annotation"
fi

if [[ "$EXPOSE_UI" == "1" ]]; then
  CIDRS="$(admin_cidrs_json)"
  patch="$(jq -cn --argjson r "$CIDRS" '{spec:{type:"LoadBalancer", loadBalancerSourceRanges:$r}}')"
  kubectl --context "$HUB" -n argocd patch svc argocd-server --type merge -p "$patch" >/dev/null
  kubectl --context "$HUB" -n argo patch svc "$(argo_wf_server_svc "$HUB")" --type merge -p "$patch" >/dev/null
  ok "UI Services exposed as LoadBalancer for $(jq -r 'join(", ")' <<<"$CIDRS")"
fi

"${SCRIPTS_DIR}/hub/print-ui.sh"
