#!/usr/bin/env bash
# The tpg-fleet Argo CD RBAC (scripts/lib/argo-rbac.sh and the policy in
# argo/argocd-values.yaml), evaluated by the real Argo CD permission checker
# (argocd admin settings rbac can, the same enforcer as argocd-server) against
# argocd-rbac-cm files:
#   1 the installed-hub policy: role:admin and the admin user are denied sync,
#     override, update and delete on project tpg; workflow-bot may sync; the hub
#     project tpg-hub and other projects are not affected
#   2 policy.default: role:admin does not reopen it (the deny is on the role)
#   3 a customer hub: tpg_rbac_offenders finds every subject that may act on
#     project tpg (a custom role, an SSO group bound to it, direct grants); after
#     tpg_rbac_merge nobody but workflow-bot can, and the customer's lines stay
#   4 the merge is idempotent (one marked block after two runs)
#   5 policy.matchMode regex: the block uses tpg/.* and still holds
# Requires the argocd CLI (v3.x), yq (mikefarah), jq and python3; skipped without argocd.
# The permission checker builds a Kubernetes client even for a local file, so a
# placeholder kubeconfig is used; no cluster is contacted.
# shellcheck disable=SC2015
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
command -v argocd >/dev/null || { echo "SKIP tests/argocd-rbac: argocd CLI not installed" >&2; exit 0; }
for t in yq jq python3; do command -v "$t" >/dev/null || { echo "SKIP tests/argocd-rbac: $t not installed" >&2; exit 0; }; done
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/kubeconfig" <<'KC'
apiVersion: v1
kind: Config
clusters: [{name: none, cluster: {server: "https://127.0.0.1:1"}}]
users: [{name: none, user: {token: none}}]
contexts: [{name: none, context: {cluster: none, user: none, namespace: argocd}}]
current-context: none
KC
export KUBECONFIG="$TMP/kubeconfig"
# shellcheck source=scripts/lib/argo-rbac.sh
source "$ROOT/scripts/lib/argo-rbac.sh"
PASS=0; FAIL=0
ok()  { printf 'ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL %s\n' "$1"; [[ -z "${2:-}" ]] || printf '%s\n' "$2" | sed 's/^/       | /' | tail -8; FAIL=$((FAIL + 1)); }
can() { argocd admin settings rbac can "$2" "$3" applications "$4" --policy-file "$1" -q >/dev/null 2>&1; }
cm() {  # cm FILE POLICY_CSV [DEFAULT] [MATCH_MODE]
  POLICY="$2" DEF="${3:-}" MODE="${4:-}" yq -n '.apiVersion = "v1" | .kind = "ConfigMap"
    | .metadata = {"name": "argocd-rbac-cm", "namespace": "argocd"}
    | .data["policy.csv"] = strenv(POLICY)
    | (select(strenv(DEF) != "") | .data["policy.default"] = strenv(DEF)) // .
    | (select(strenv(MODE) != "") | .data["policy.matchMode"] = strenv(MODE)) // .' > "$1"
}

# ---- 1 installed hub
INSTALLED="$(yq -r '.configs.rbac["policy.csv"]' "$ROOT/argo/argocd-values.yaml")"
cm "$TMP/installed.yaml" "$INSTALLED"
for s in admin role:admin; do
  for a in sync override update delete; do
    can "$TMP/installed.yaml" "$s" "$a" tpg/tpg-aks-tpg-poc-01-operator && bad "1 $s may $a a tpg Application" || ok "1 $s may not $a a tpg Application"
  done
done
can "$TMP/installed.yaml" workflow-bot sync tpg/tpg-aks-tpg-poc-01-orders-db && ok "1 workflow-bot may sync a tpg Application" || bad "1 workflow-bot sync"
can "$TMP/installed.yaml" workflow-bot delete tpg/tpg-aks-tpg-poc-01-orders-db && bad "1 workflow-bot may delete" || ok "1 workflow-bot may not delete"
can "$TMP/installed.yaml" admin sync tpg-hub/tpg-hub-workflows && ok "1 admin may still sync tpg-hub-workflows (project tpg-hub)" || bad "1 admin tpg-hub sync"
can "$TMP/installed.yaml" admin get tpg/tpg-aks-tpg-poc-01-operator && ok "1 admin may still read tpg Applications" || bad "1 admin get"
[[ -z "$(tpg_rbac_offenders "$TMP/installed.yaml")" ]] && ok "1 tpg_rbac_offenders finds nobody on the installed policy" || bad "1 offenders" "$(tpg_rbac_offenders "$TMP/installed.yaml")"

# ---- 2 policy.default role:admin
cm "$TMP/default.yaml" "$INSTALLED" role:admin
can "$TMP/default.yaml" alice sync tpg/tpg-aks-tpg-poc-01-operator && bad "2 policy.default role:admin reopens sync" || ok "2 policy.default role:admin: alice may not sync"
can "$TMP/default.yaml" alice sync other/app && ok "2 policy.default role:admin: alice may sync other projects" || bad "2 other project"

# ---- 3 customer hub
CUSTOMER='# customer policy
p, role:dba, applications, *, */*, allow
g, corp:dba-team, role:dba
p, corp:platform, applications, sync, tpg/*, allow
p, role:tpg-sync, applications, get, tpg/*, allow
p, role:tpg-sync, applications, sync, tpg/*, allow
g, workflow-bot, role:tpg-sync'
cm "$TMP/customer.yaml" "$CUSTOMER" role:readonly
off="$(tpg_rbac_offenders "$TMP/customer.yaml" | sort | paste -sd' ')"
read -r -a offa <<<"$off"
[[ "$off" == "admin corp:dba-team corp:platform role:admin role:dba" ]] \
  && ok "3 offenders: the admin user, role:admin, a custom role, its SSO group and a direct grant" || bad "3 offenders" "$off"
merged="$(tpg_rbac_merge "$CUSTOMER" "$(tpg_rbac_block glob role:admin "${offa[@]}")")"
cm "$TMP/customer2.yaml" "$merged" role:readonly
[[ -z "$(tpg_rbac_offenders "$TMP/customer2.yaml")" ]] && ok "3 after the merge nobody but workflow-bot acts on tpg" || bad "3 still" "$(tpg_rbac_offenders "$TMP/customer2.yaml")"
can "$TMP/customer2.yaml" workflow-bot sync tpg/x && ok "3 workflow-bot still syncs" || bad "3 workflow-bot"
can "$TMP/customer2.yaml" corp:dba-team sync other/app && ok "3 the customer's grants outside tpg are kept" || bad "3 outside tpg"
grep -qxF 'p, role:dba, applications, *, */*, allow' <<<"$merged" && ok "3 the customer's lines are kept" || bad "3 lines" "$merged"

# ---- 4 idempotent
again="$(tpg_rbac_merge "$merged" "$(tpg_rbac_block glob role:admin "${offa[@]}")")"
[[ "$(grep -c "^${TPG_RBAC_BEGIN}$" <<<"$again")" -eq 1 && "$again" == "$merged" ]] \
  && ok "4 a second merge leaves one identical block" || bad "4 idempotent" "$again"

# ---- 5 regex match mode
REGEX_CUSTOMER='p, role:ops, applications, .*, .*/.*, allow
p, role:tpg-sync, applications, sync, tpg/.*, allow
g, workflow-bot, role:tpg-sync'
cm "$TMP/regex.yaml" "$REGEX_CUSTOMER" "" regex
mapfile -t offa < <(tpg_rbac_offenders "$TMP/regex.yaml" | sort)
merged="$(tpg_rbac_merge "$REGEX_CUSTOMER" "$(tpg_rbac_block regex role:admin "${offa[@]}")")"
grep -q 'tpg/\.\*, deny' <<<"$merged" && ok "5 regex mode: the block uses tpg/.*" || bad "5 pattern" "$merged"
cm "$TMP/regex2.yaml" "$merged" "" regex
[[ -z "$(tpg_rbac_offenders "$TMP/regex2.yaml")" ]] && ok "5 regex mode: nobody but workflow-bot acts on tpg" || bad "5 regex" "$(tpg_rbac_offenders "$TMP/regex2.yaml")"
can "$TMP/regex2.yaml" workflow-bot sync tpg/x && ok "5 regex mode: workflow-bot still syncs" || bad "5 regex workflow-bot"

echo
echo "tests/argocd-rbac: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
