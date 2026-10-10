#!/usr/bin/env bash
# Argo CD RBAC for the tpg target Applications (project tpg): people may not
# sync (which also covers rollback), override, update or delete them; only the
# workflows' account workflow-bot syncs them (role:tpg-sync). The hub admission
# policy tpg-application-sync in tpg-fleet workflows/admission/ refuses the same
# syncs at the Kubernetes API, including kubectl edits.
#
# Argo CD evaluates a deny before any allow (assets/model.conf: allow and not
# deny), and a deny on a role also removes what policy.default grants through
# that role. Every subject that can act on project tpg therefore gets its own
# deny lines, kept in a marked block of policy.csv:
#   # >>> tpg-fleet rbac >>>
#   p, role:admin, applications, sync, tpg/*, deny
#   ...
#   # <<< tpg-fleet rbac <<<
# Hubs installed by run.sh carry the block for role:admin in argo/argocd-values.yaml.
# On an existing hub, scripts/hub/existing/check-argo.sh finds the subjects with
# the Argo CD permission checker (argocd admin settings rbac can) and adds the
# block with --yes. Sourced by check-argo.sh and steps/60-verify.sh.

TPG_RBAC_BEGIN='# >>> tpg-fleet rbac >>>'
TPG_RBAC_END='# <<< tpg-fleet rbac <<<'
TPG_RBAC_ACTIONS=(sync override update delete)
# An object name the checker evaluates: an operator Application in project tpg
TPG_RBAC_PROBE="tpg/tpg-rbac-probe-operator"

tpg_rbac_object() {
  # tpg_rbac_object MATCH_MODE -> the object pattern for project tpg
  if [[ "$1" == "regex" ]]; then printf 'tpg/.*'; else printf 'tpg/*'; fi
}

tpg_rbac_block() {
  # tpg_rbac_block MATCH_MODE SUBJECT... -> the marked block with deny lines per subject
  local mode="$1" s a obj
  shift
  obj="$(tpg_rbac_object "$mode")"
  printf '%s\n' "$TPG_RBAC_BEGIN"
  printf '%s\n' "# People may not sync, override, update or delete the tpg target Applications:"
  printf '%s\n' "# the tpg workflows sync them as workflow-bot (role:tpg-sync). Written by tpg-aks-infra."
  for s in "$@"; do
    for a in "${TPG_RBAC_ACTIONS[@]}"; do
      printf 'p, %s, applications, %s, %s, deny\n' "$s" "$a" "$obj"
    done
  done
  printf '%s\n' "$TPG_RBAC_END"
}

tpg_rbac_merge() {
  # tpg_rbac_merge POLICY BLOCK -> POLICY with its marked block replaced by BLOCK
  # (appended when there is none); lines outside the markers are kept as they are
  POLICY="$1" BLOCK="$2" BEGIN="$TPG_RBAC_BEGIN" END="$TPG_RBAC_END" python3 - <<'PY'
import os
policy, block = os.environ["POLICY"].splitlines(), os.environ["BLOCK"].splitlines()
begin, end = os.environ["BEGIN"], os.environ["END"]
out, skip, placed = [], False, False
for line in policy:
    if line.strip() == begin:
        skip = True
        if not placed:
            out.extend(block); placed = True
        continue
    if skip:
        if line.strip() == end:
            skip = False
        continue
    out.append(line)
if not placed:
    while out and not out[-1].strip():
        out.pop()
    out.extend(block)
print("\n".join(out))
PY
}

tpg_rbac_subjects() {
  # tpg_rbac_subjects CM_JSON -> subjects to check: role:admin, the admin user,
  # policy.default, and every subject and group named in policy.csv, except the
  # workflows' own account and role
  jq -r '
    (.data["policy.csv"] // "") as $csv
    | ["role:admin", "admin", (.data["policy.default"] // empty)]
      + ([$csv | split("\n")[] | sub("#.*$"; "") | split(",") | map(gsub("^\\s+|\\s+$"; ""))
          | select(length >= 2)
          | if .[0] == "p" then [.[1]] elif .[0] == "g" then [.[1], .[2]] else [] end] | add // [])
    | map(select(length > 0 and . != "workflow-bot" and . != "role:tpg-sync")) | unique | .[]' <<<"$1"
}

tpg_rbac_can() {
  # tpg_rbac_can CM_FILE SUBJECT ACTION -> 0 when SUBJECT may do ACTION on a tpg
  # Application according to the argocd-rbac-cm in CM_FILE (built-in policy included)
  argocd admin settings rbac can "$2" "$3" applications "$TPG_RBAC_PROBE" --policy-file "$1" -q >/dev/null 2>&1
}

tpg_rbac_offenders() {
  # tpg_rbac_offenders CM_FILE -> subjects (one per line) that may still sync,
  # override, update or delete a tpg Application
  local cm_json s a
  cm_json="$(yq -o=json '.' "$1")"
  while IFS= read -r s; do
    [[ -n "$s" ]] || continue
    for a in "${TPG_RBAC_ACTIONS[@]}"; do
      if tpg_rbac_can "$1" "$s" "$a"; then printf '%s\n' "$s"; break; fi
    done
  done < <(tpg_rbac_subjects "$cm_json")
}
