#!/usr/bin/env bash
# Prerequisite runner for the four supported scenarios.
#
#   --hub install      hub has no Argo CD / Argo Workflows: install both
#   --hub existing     hub already runs both: check, additive patches, opt-ins
#   --targets terraform   clusters from this repository's Terraform
#   --targets precreated  clusters created elsewhere, described in an inventory
#
# Examples
#   scripts/run.sh --hub install  --targets terraform
#   scripts/run.sh --hub existing --targets precreated --inventory inventory/clusters.yaml --fix-authorized-ips
#   scripts/run.sh --hub existing --targets precreated --only hub --check-only
#   scripts/run.sh --hub install  --targets terraform --from register
#   MONITORING_OPTION=standalone scripts/run.sh --hub install --targets terraform --only addons
#   scripts/run.sh --hub install  --targets terraform --only vault-unseal
#   scripts/run.sh --hub install  --targets terraform --only access
#   scripts/run.sh --hub install  --targets terraform --expose-ui --save-vault-recovery-keys
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPTS_DIR}/.." && pwd)"

STEPS=(inventory preflight kubeconfigs hub vault service-accounts register hub-secrets addons bootstrap verify)
# Run only with --only (not part of the sequence)
EXTRA_STEPS=(vault-unseal access)

usage() {
  cat <<USAGE
Usage: $0 --hub install|existing --targets terraform|precreated [options]

Options
  --inventory PATH            Inventory for --targets precreated (default inventory/clusters.yaml)
  --from STEP                 Start at STEP
  --only STEP                 Run only STEP
  --fix-authorized-ips        precreated: add hub egress CIDRs to target API server authorized IP ranges
  --check-only                existing hub: run the checks, change nothing
  --set-tracking-annotation   existing hub: set application.resourceTrackingMethod to annotation
  --expose-ui                 existing hub: expose argocd-server and argo-server as LoadBalancer;
                              every hub: expose the Vault UI (load balancer limited to adminAllowedCidrs)
  --rotate-vault-admin        with --only access: set a new Vault UI password for tpg-admin
  --save-vault-recovery-keys  vault step, first run (vault operator init): write the 5 unseal or
                              recovery keys to VAULT_RECOVERY_KEYS_FILE (default
                              \$HOME/.tpg/vault-keys.txt, mode 600; an existing file is kept and a
                              copy with a UTC timestamp suffix is written) instead of showing them;
                              no "stored" prompt and no terminal needed. The root token is not saved.
  --yes                       upgrade Helm releases that are already installed without asking
                              (hub Argo CD and Argo Workflows, Vault, add-ons; same as
                              ADDONS_EXISTING=upgrade; default: ask on a terminal, skip without one);
                              existing hub: append the tpg-fleet deny block to argocd-rbac-cm
  --dry-run                   Print the steps and exit
  -h, --help                  Show this help

Steps: ${STEPS[*]}
  inventory         terraform: .work/inventory.yaml from outputs; precreated: validate the inventory file
  preflight         precreated only: az checks (clusters, authorized IPs, storage containers)
  kubeconfigs       .work/kubeconfig with one context per cluster
  hub               install: Argo CD + Argo Workflows (pre-check: up to date, upgrade/skip/abort,
                    blocked when installed another way); existing: check-argo.sh
  vault             Vault (Helm), TLS, init/unseal, KV, auth, policies; Vault Secrets Operator on the hub
  service-accounts  argocd-manager ServiceAccount and token on every target
  register          Argo CD cluster Secrets and Argo Workflows kubeconfig Secrets on the hub
  hub-secrets       check the tokens, store them in Vault, Argo CD repositories (VSO), workflow log
                    archive (argo-logs), tpg-settings, workflow-bot token
  addons            Helm releases (after a pre-check): cert-manager and VSO on targets; monitoring
                    (standalone: kps, remote-write gateway, metrics flow check; azure: managed Prometheus)
  bootstrap         tpg-fleet bootstrap and monitoring option
  verify            read-only checks; ends with a summary of every issue, grouped by resource
  vault-unseal      only with --only: unseal Vault (unseal mode shamir) after vault-0 restarted
  access            only with --only: print every UI endpoint and login (terminal only)
USAGE
}

HUB_MODE="" TARGETS_MODE="" INVENTORY_ARG="" FROM="" ONLY="" DRY_RUN=0
export FIX_AUTHORIZED_IPS=0 CHECK_ONLY=0 SET_TRACKING_ANNOTATION=0 EXPOSE_UI=0 SAVE_VAULT_RECOVERY_KEYS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hub) HUB_MODE="${2:-}"; shift 2 ;;
    --targets) TARGETS_MODE="${2:-}"; shift 2 ;;
    --inventory) INVENTORY_ARG="${2:-}"; shift 2 ;;
    --from) FROM="${2:-}"; shift 2 ;;
    --only) ONLY="${2:-}"; shift 2 ;;
    --fix-authorized-ips) FIX_AUTHORIZED_IPS=1; shift ;;
    --check-only) CHECK_ONLY=1; shift ;;
    --set-tracking-annotation) SET_TRACKING_ANNOTATION=1; shift ;;
    --expose-ui) EXPOSE_UI=1; shift ;;
    --yes) export ADDONS_EXISTING=upgrade ASSUME_YES=1; shift ;;
    --rotate-vault-admin) export ROTATE_VAULT_ADMIN=1; shift ;;
    --save-vault-recovery-keys) SAVE_VAULT_RECOVERY_KEYS=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ "$HUB_MODE" == "install" || "$HUB_MODE" == "existing" ]] || { usage >&2; exit 2; }
[[ "$TARGETS_MODE" == "terraform" || "$TARGETS_MODE" == "precreated" ]] || { usage >&2; exit 2; }
[[ -z "$FROM" || " ${STEPS[*]} " == *" $FROM "* ]] || { echo "unknown step: $FROM" >&2; exit 2; }
[[ -z "$ONLY" || " ${STEPS[*]} ${EXTRA_STEPS[*]} " == *" $ONLY "* ]] || { echo "unknown step: $ONLY" >&2; exit 2; }

if [[ "$TARGETS_MODE" == "terraform" ]]; then
  export INVENTORY="${REPO_ROOT}/.work/inventory.yaml"
  [[ -z "$INVENTORY_ARG" ]] || echo "--inventory is ignored with --targets terraform" >&2
else
  INVENTORY_ARG="${INVENTORY_ARG:-${REPO_ROOT}/inventory/clusters.yaml}"
  INVENTORY="$(cd "$(dirname "$INVENTORY_ARG")" && pwd)/$(basename "$INVENTORY_ARG")"
  export INVENTORY
fi

script_for() {
  case "$1" in
    inventory)
      if [[ "$TARGETS_MODE" == "terraform" ]]; then echo "targets/terraform/inventory-from-terraform.sh"
      else echo "targets/precreated/validate-inventory.sh"; fi ;;
    preflight)        [[ "$TARGETS_MODE" == "precreated" ]] && echo "targets/precreated/preflight.sh" || echo "" ;;
    kubeconfigs)      echo "steps/10-kubeconfigs.sh" ;;
    hub)
      if [[ "$HUB_MODE" == "install" ]]; then echo "hub/install/install-argo.sh"
      else echo "hub/existing/check-argo.sh"; fi ;;
    vault)            echo "steps/35-vault.sh" ;;
    vault-unseal)     echo "steps/vault-unseal.sh" ;;
    access)           echo "access.sh" ;;
    service-accounts) echo "steps/20-target-service-accounts.sh" ;;
    register)         echo "steps/30-register-clusters.sh" ;;
    hub-secrets)      echo "steps/40-hub-secrets.sh" ;;
    addons)           echo "steps/45-helm-addons.sh" ;;
    bootstrap)        echo "steps/50-bootstrap-fleet.sh" ;;
    verify)           echo "steps/60-verify.sh" ;;
  esac
}

if [[ " ${EXTRA_STEPS[*]} " == *" $ONLY "* && -n "$ONLY" ]]; then
  printf '\n\033[1;35m== %-17s scripts/%s\033[0m\n' "$ONLY" "$(script_for "$ONLY")"
  [[ "$DRY_RUN" -eq 1 ]] || "${SCRIPTS_DIR}/$(script_for "$ONLY")"
  exit 0
fi

started=0
[[ -z "$FROM" ]] && started=1
printf '\033[1;34mScenario:\033[0m hub=%s targets=%s inventory=%s\n' "$HUB_MODE" "$TARGETS_MODE" "$INVENTORY"
for step in "${STEPS[@]}"; do
  [[ "$step" == "$FROM" ]] && started=1
  [[ "$started" -eq 1 ]] || continue
  [[ -z "$ONLY" || "$step" == "$ONLY" ]] || continue
  script="$(script_for "$step")"
  if [[ -z "$script" ]]; then
    printf '\033[1;90m-- %-17s skipped for --targets %s\033[0m\n' "$step" "$TARGETS_MODE"
    continue
  fi
  printf '\n\033[1;35m== %-17s scripts/%s\033[0m\n' "$step" "$script"
  [[ "$DRY_RUN" -eq 1 ]] && continue
  "${SCRIPTS_DIR}/${script}"
  if [[ "$step" == "hub" && "$HUB_MODE" == "existing" && "$CHECK_ONLY" -eq 1 && -z "$ONLY" ]]; then
    echo "--check-only: stopping after the hub checks" >&2
    exit 0
  fi
done
printf '\n\033[1;32mDone.\033[0m\n'
