#!/usr/bin/env bash
# Scenario: hub without Argo. Install Argo CD and Argo Workflows and expose both
# UIs through Azure LoadBalancer Services restricted to adminAllowedCidrs.
# Follows docs/README-argo-on-aks.md. Safe to re-run.
#
# Each release goes through the same pre-check as the fleet add-ons (hr_* in
# scripts/lib/common.sh, shared with tpg-fleet helm-addons.sh):
#   NOT_INSTALLED   install
#   UP_TO_DATE      our release, same chart version and values: nothing to do
#   SKIPPED_EXISTS  our release differs: on a terminal you are asked to upgrade,
#                   skip or abort (the chart version change and the values diff
#                   are shown first); without a terminal it is skipped.
#                   ADDONS_EXISTING=upgrade|skip|abort or run.sh --yes answer it.
#   SKIPPED_NEWER   the installed chart is newer than the pinned one: never downgraded
#   BLOCKED         Argo CD or Argo Workflows installed another way (another Helm
#                   release, or plain manifests): use --hub existing instead
# While helm --wait runs, the pods of the namespace are printed every 5 seconds
# and the install stops as soon as one cannot start.
source "$(dirname "$0")/../../lib/common.sh"

require_cmd kubectl helm jq yq
require_inventory
HUB="$(hub_name)"
CIDRS="$(admin_cidrs_json)"
ARGOCD_CHART_VERSION="${ARGOCD_CHART_VERSION:-10.9.1}"
ARGO_WORKFLOWS_CHART_VERSION="${ARGO_WORKFLOWS_CHART_VERSION:-2.0.6}"
ARGO_REPO="https://argoproj.github.io/argo-helm"
require_context "$HUB"

hr_setup --cluster "$HUB" --context "$HUB" --log-name hub
cleanup_add "rm -rf '$HR_TMP'"

# hr_foreign_hook RELEASE NS: NOT_HELM when the namespace already runs Argo
# workloads that no Helm release of that name owns.
hr_foreign_hook() {
  local ns="$2" pattern
  case "$1" in
    argocd) pattern='argoproj/argocd|argo-cd' ;;
    argo-workflows) pattern='argoproj/workflow-controller|argoproj/argocli' ;;
    *) return 0 ;;
  esac
  if hr_k -n "$ns" get deploy,statefulset -o json 2>/dev/null \
      | jq -e --arg p "$pattern" '[.items[].spec.template.spec.containers[].image | select(test($p))] | length > 0' >/dev/null; then
    echo NOT_HELM
  fi
}
# hr_reuse_hook RELEASE CLASS: never reuse, point at the existing-hub scenario
hr_reuse_hook() {
  echo "$(hr_class_text "$2") in namespace $( [[ "$1" == argocd ]] && echo argocd || echo argo): run scripts/run.sh --hub existing, which checks that installation and adds only what the fleet needs"
  return 1
}

log "Argo Helm repository ${ARGO_REPO}"
cd_values="$HR_TMP/argocd.yaml"
hr_merge_values "$cd_values" "${REPO_ROOT}/argo/argocd-values.yaml" \
  "$(R="$CIDRS" hr_overlay argocd-ranges '.server.service.loadBalancerSourceRanges = (strenv(R) | from_yaml)')"
log "Argo CD chart ${ARGOCD_CHART_VERSION} on ${HUB} (pre-check first)"
hr_release argocd argo-cd "$ARGOCD_CHART_VERSION" "$ARGO_REPO" argocd "$cd_values" ""

wf_values="$HR_TMP/argo-workflows.yaml"
hr_merge_values "$wf_values" "${REPO_ROOT}/argo/argo-workflows-values.yaml" \
  "$(R="$CIDRS" hr_overlay argo-workflows-ranges '.server.loadBalancerSourceRanges = (strenv(R) | from_yaml)')"
log "Argo Workflows chart ${ARGO_WORKFLOWS_CHART_VERSION} on ${HUB} (pre-check first)"
hr_release argo-workflows argo-workflows "$ARGO_WORKFLOWS_CHART_VERSION" "$ARGO_REPO" argo "$wf_values" ""

"${SCRIPTS_DIR}/hub/ui-admin.sh"
"${SCRIPTS_DIR}/hub/print-ui.sh"
