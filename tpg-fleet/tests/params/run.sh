#!/usr/bin/env bash
# Workflow input types and parameter files.
#
# 1 workflows/params/types.yaml against the generated admission policy, the WorkflowTemplates,
#   workflows/params/cluster-map-keys.yaml and the input tables of docs/workflow-commands.md: Type,
#   Mandatory, Default and enum values (check_params.py).
# 2 The parameter files (check_param_files.py): the generated example of every workflow and every
#   parameter-file example of docs/workflow-commands.md, through
#     the schema          workflows/params/schemas/params-W.schema.json (jsonschema, check-jsonschema)
#     the admission policy  evaluated by a real kube-apiserver (tests/envtest/apiserver.sh) with the Argo
#                         CRDs, the 13 WorkflowTemplates and workflows/admission/workflow-parameters.yaml,
#                         through the real argo CLI (`argo submit --from workflowtemplate/W --parameter-file`)
#     the validate step   workflows/scripts/validate-params.sh of the workflow, offline (stub kubectl)
#   plus the negative cases (unknown key, wrong type, comma-separated list, malformed element), both list
#   forms, and a table of values that the schema and the policy must judge alike. The rule that finds the
#   examples of the docs is in the header of check_param_files.py.
#
# Skipped, and listed at the end of the output: the admission checks without envtest binaries or the argo CLI
# (the schema and the validate step still run), and the validate step of examples that name local files (their
# contents travel in patchFiles). Not testable offline, so not checked: everything after the validate step
# (discover, the pre-check, the commits, the Argo CD syncs, the verification on the clusters).
# Requires python3 with PyYAML and jsonschema (check-jsonschema for the docs' command); envtest, argo, openssl for
# the admission part.
# ok() and bad() always return 0.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
python3 -c 'import yaml' 2>/dev/null || { echo "SKIP tests/params: python3 PyYAML not installed" >&2; exit 0; }
PASS=0; FAIL=0
ok()  { printf 'ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL %s\n' "$1"; [[ -z "${2:-}" ]] || printf '%s\n' "$2" | sed 's/^/       | /' | tail -12; FAIL=$((FAIL + 1)); }

# ---- 1 types.yaml, the policy, the templates and the docs
if out="$(python3 "$HERE/check_params.py")"; then
  ok "types.yaml, the admission policy, the templates, cluster-map-keys.yaml and the docs agree"
else
  bad "types.yaml, the admission policy, the templates, cluster-map-keys.yaml and the docs disagree" "$out"
fi

# ---- 2 the parameter files
# the admission policy needs a kube-apiserver: envtest (etcd, kube-apiserver, kubectl) and the argo CLI
# shellcheck source=tests/envtest/apiserver.sh
source "${ROOT}/tests/envtest/apiserver.sh"
export TPG_PARAMS_ARGO=0
if envtest_find && command -v argo >/dev/null && command -v openssl >/dev/null; then
  ENVTEST_TMP="$(mktemp -d)"
  envtest_start "$ENVTEST_TMP"
  k() { "$ENVTEST_BIN/kubectl" "$@"; }
  k apply -f "$ROOT/tests/admission/crds/" >/dev/null
  k wait --for=condition=Established crd/workflows.argoproj.io crd/workflowtemplates.argoproj.io --timeout=60s >/dev/null
  k create namespace argo >/dev/null
  k -n argo apply -f "$ROOT/workflows/templates/" >/dev/null
  k apply -f "$ROOT/workflows/admission/workflow-parameters.yaml" >/dev/null
  sleep 3   # the policy is enforced shortly after it is created
  TPG_PARAMS_ARGO=1
  export TPG_PARAMS_KUBECTL="$ENVTEST_BIN/kubectl"
else
  echo "SKIP tests/params admission: envtest binaries or the argo CLI not found (set KUBEBUILDER_ASSETS); the schema and the validate step still run" >&2
fi
export TPG_PARAMS_ARGO
RC=0; out="$(python3 "$HERE/check_param_files.py" 2>&1)" || RC=$?
printf '%s\n' "$out"
n_ok="$(grep -c '^ok   ' <<<"$out" || true)"; n_bad="$(grep -c '^FAIL ' <<<"$out" || true)"
PASS=$((PASS + n_ok)); FAIL=$((FAIL + n_bad))
if [[ "$RC" -ne 0 && "$n_bad" -eq 0 ]]; then bad "check_param_files.py exited with status ${RC}" "$out"; fi
grep -q '^SKIP tests/params parameter files' <<<"$out" && echo "SKIP: python3 jsonschema is not installed; the parameter files were not checked" >&2

echo
echo "tests/params: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
