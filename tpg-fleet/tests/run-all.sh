#!/usr/bin/env bash
# Every offline test suite. Usage: tests/run-all.sh [--against-cli]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ARG="${1:-}"

echo "=== tests/cli-flags"
bash "${HERE}/cli-flags/run.sh" ${ARG:+"$ARG"}
for suite in regex-limits waits git-merge stuck-app helm4 shared-lib sync-engine rollout params cluster-map restore-map restore scale patch chart crd-reference day0-plan network-policy delete backup-expire submit rotate pgdata admission monitoring unused-keys; do
  echo
  echo "=== tests/${suite}"
  bash "${HERE}/${suite}/run.sh"
done

INFRA="${FLEET_SIBLING:-$(cd "${HERE}/../.." && pwd)/tpg-aks-infra}"
if [[ -x "${INFRA}/tests/verify/run.sh" ]]; then
  echo
  echo "=== tpg-aks-infra tests/verify"
  FLEET_LOCAL_DIR="$(cd "${HERE}/.." && pwd)" bash "${INFRA}/tests/verify/run.sh"
fi
if [[ -f "${INFRA}/tests/preflight/run.sh" ]]; then
  echo
  echo "=== tpg-aks-infra tests/preflight"
  bash "${INFRA}/tests/preflight/run.sh"
fi
if [[ -f "${INFRA}/tests/argocd-rbac/run.sh" ]]; then
  echo
  echo "=== tpg-aks-infra tests/argocd-rbac"
  bash "${INFRA}/tests/argocd-rbac/run.sh"
fi
if [[ -f "${INFRA}/tests/jumpbox/run.sh" ]]; then
  echo
  echo "=== tpg-aks-infra tests/jumpbox"
  bash "${INFRA}/tests/jumpbox/run.sh"
fi
if [[ -f "${INFRA}/tests/deploy-scripts/run.sh" ]]; then
  echo
  echo "=== tpg-aks-infra tests/deploy-scripts"
  bash "${INFRA}/tests/deploy-scripts/run.sh"
fi
if [[ -f "${INFRA}/tests/vault-secret/run.sh" ]]; then
  echo
  echo "=== tpg-aks-infra tests/vault-secret"
  bash "${INFRA}/tests/vault-secret/run.sh"
fi
echo
echo "All test suites passed"
