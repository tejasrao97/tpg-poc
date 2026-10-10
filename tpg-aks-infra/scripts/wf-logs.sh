#!/usr/bin/env bash
# Archived logs of an Argo Workflows run, read from Azure Blob.
#
# Every workflow step's log is archived when the step ends (artifact repository
# argo/artifact-repositories with archiveLogs: true, created by the hub-secrets
# step). The Argo UI shows those logs while the Workflow object exists (it is
# deleted 7 days after it finishes); this script reads them at any time, until
# the lifecycle rule deletes them (Terraform argo_logs_retention_days, 90).
#
# Usage
#   scripts/wf-logs.sh WORKFLOW                 print every step log of the run
#   scripts/wf-logs.sh WORKFLOW --list          list the archived logs only
#   scripts/wf-logs.sh WORKFLOW --grep RESULT   print only the matching lines, per step
#   scripts/wf-logs.sh WORKFLOW --out DIR       also keep the files in DIR
#                                               (default: .work/wf-logs/WORKFLOW)
#
# The storage account key is read from Secret argo/argo-artifacts on the hub
# (synced from Vault) and passed to az in the environment of that one command;
# it is never written to a file.
source "$(dirname "$0")/lib/common.sh"

WF="" LIST=0 PATTERN="" OUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --list) LIST=1; shift ;;
    --grep) PATTERN="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    -*) die "unknown option $1" ;;
    *) [[ -z "$WF" ]] || die "one workflow name only"; WF="$1"; shift ;;
  esac
done
[[ -n "$WF" ]] || die "usage: scripts/wf-logs.sh WORKFLOW [--list] [--grep PATTERN] [--out DIR]"
require_cmd kubectl jq az
require_inventory
HUB="$(hub_name)"
require_context "$HUB"

repo="$(kubectl --context "$HUB" -n argo get cm artifact-repositories -o json 2>/dev/null \
  | jq -r '(.metadata.annotations["workflows.argoproj.io/default-artifact-repository"] // "") as $d | .data[$d] // ""')" \
  || die "ConfigMap argo/artifact-repositories not found on $HUB: run scripts/run.sh --only hub-secrets"
[[ -n "$repo" ]] || die "argo/artifact-repositories has no default repository: run scripts/run.sh --only hub-secrets"
endpoint="$(jq -r '.azure.endpoint' <<<"$repo")"; container="$(jq -r '.azure.container' <<<"$repo")"
account="$(sed -E 's#^https?://([^.]+)\..*#\1#' <<<"$endpoint")"
key="$(kubectl --context "$HUB" -n argo get secret argo-artifacts -o jsonpath='{.data.accountKey}' | base64 -d)"
[[ -n "$key" ]] || die "Secret argo/argo-artifacts has no accountKey (VaultStaticSecret argo/argo-artifacts)"
blob() { AZURE_STORAGE_KEY="$key" az storage blob "$@" --account-name "$account" --container-name "$container" --only-show-errors; }

mapfile -t names < <(blob list --prefix "${WF}/" --query '[].name' -o tsv)
[[ "${#names[@]}" -gt 0 ]] || die "no archived logs for ${WF} in ${account}/${container} (a run from before the log archive, a mistyped name, or deleted by the lifecycle rule)"
log "${#names[@]} archived log(s) of ${WF} in ${account}/${container}"
if [[ "$LIST" -eq 1 ]]; then printf '  %s\n' "${names[@]}"; exit 0; fi

OUT="${OUT:-${WORK_DIR}/wf-logs/${WF}}"
mkdir -p "$OUT"
for n in "${names[@]}"; do
  f="${OUT}/${n#"${WF}"/}"
  mkdir -p "$(dirname "$f")"
  blob download --name "$n" --file "$f" -o none
  printf '\n\033[1;35m==== %s\033[0m\n' "${n#"${WF}"/}"
  if [[ -n "$PATTERN" ]]; then grep -E -- "$PATTERN" "$f" || true; else cat "$f"; fi
done
ok "logs kept in ${OUT}"
