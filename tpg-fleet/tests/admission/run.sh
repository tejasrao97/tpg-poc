#!/usr/bin/env bash
# The three hub admission policies in workflows/admission/, evaluated by a real
# kube-apiserver (tests/envtest/apiserver.sh) with the real CRDs of Argo
# Workflows v4.1.3 (Workflow) and Argo CD v3.5.3 (Application):
#
#   workflow-parameters.yaml  input types of the tpg WorkflowTemplates
#     - a correct run is accepted; the default of every input of every template
#       passes (a Workflow with all defaults is created per template)
#     - a wrong type, an unknown input, an old input name and a malformed
#       clusterMap are rejected, with the input and its type in the message
#     - Workflows of other templates are not affected
#   credential-writer.yaml    only the WorkflowTemplate tpg-rotate-credential runs
#                             as the ServiceAccount tpg-credential-writer, and only
#                             Argo CD writes that template (Round 15, D87)
#   application-sync.yaml     only the workflows sync tpg target Applications
#     - a new operation is accepted only from argocd-server on behalf of
#       workflow-bot (or workflow-bot:apiKey)
#     - the controller clearing the operation, status and annotation updates and
#       hub Applications are not affected; automated sync is refused
#
# Requires the envtest binaries (etcd, kube-apiserver, kubectl; KUBEBUILDER_ASSETS
# or PATH), openssl, python3, yq (mikefarah) and jq. Skipped when envtest is missing.
# ok() and bad() always return 0; single-quoted jq and yq programs are not shell.
# shellcheck disable=SC2015,SC2016
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
# shellcheck source=tests/envtest/apiserver.sh
source "${ROOT}/tests/envtest/apiserver.sh"
if ! envtest_find; then
  echo "SKIP tests/admission: envtest binaries not found (set KUBEBUILDER_ASSETS)" >&2
  exit 0
fi
for t in openssl python3 yq jq; do command -v "$t" >/dev/null || { echo "SKIP tests/admission: $t not installed" >&2; exit 0; }; done
k() { "$ENVTEST_BIN/kubectl" "$@"; }
ENVTEST_TMP="$(mktemp -d)"
envtest_start "$ENVTEST_TMP"
PASS=0; FAIL=0
ok()  { printf 'ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL %s\n' "$1"; [[ -z "${2:-}" ]] || printf '%s\n' "$2" | sed 's/^/       | /' | tail -8; FAIL=$((FAIL + 1)); }

k apply -f "$HERE/crds/" >/dev/null
k wait --for=condition=Established crd/workflows.argoproj.io crd/workflowtemplates.argoproj.io crd/cronworkflows.argoproj.io crd/applications.argoproj.io --timeout=60s >/dev/null
k create namespace argo >/dev/null
k create namespace argocd >/dev/null
k apply -f "$ROOT/workflows/admission/workflow-parameters.yaml" -f "$ROOT/workflows/admission/application-sync.yaml" \
  -f "$ROOT/workflows/admission/credential-writer.yaml" >/dev/null
# the policies are enforced shortly after they are created
sleep 3

# ------------------------------------------------------------------ Workflow parameters
N=0
wf() {  # wf TEMPLATE PARAMS_JSON -> creates a Workflow; output in $OUT, status in $RC
  N=$((N + 1))
  local doc
  doc="$(jq -cn --arg t "$1" --argjson p "$2" --arg n "t-${N}" '{apiVersion: "argoproj.io/v1alpha1", kind: "Workflow",
    metadata: {name: $n, namespace: "argo"}, spec: {workflowTemplateRef: {name: $t}, arguments: {parameters: $p}}}')"
  RC=0; OUT="$(k create -f - <<<"$doc" 2>&1)" || RC=$?
}
params() {  # params NAME=VALUE... -> JSON list of parameters
  local a out="[]"
  for a in "$@"; do out="$(jq -c --arg n "${a%%=*}" --arg v "${a#*=}" '. + [{name: $n, value: $v}]' <<<"$out")"; done
  printf '%s' "$out"
}
accepted() { [[ "$RC" -eq 0 ]] && ok "$1" || bad "$1" "$OUT"; }
rejected() {  # rejected LABEL TEXT...: refused, and the message has every TEXT
  local t
  if [[ "$RC" -eq 0 ]]; then bad "$1 (accepted)" "$OUT"; return; fi
  for t in "${@:2}"; do grep -qF -- "$t" <<<"$OUT" || { bad "$1 (message lacks '$t')" "$OUT"; return; }; done
  ok "$1"
}

wf tpg-day0 "$(params clusters=all instances=orders-db,billing-db highAvailability=true operatorVersion=v4.5.0 \
  postgresVersion=postgres-17.6 pushMode=direct maxParallel=2 storageSize=50Gi rolloutMode=batches)"
accepted "tpg-day0: a correct run is accepted"
wf tpg-day0 "$(params clusters=all maxParallel=abc)"
rejected "tpg-day0: maxParallel=abc is refused as an Integer" 'maxParallel="abc" must be an Integer (1 or more)'
wf tpg-day0 "$(params highAvailability=yes)"
rejected "tpg-day0: highAvailability=yes is refused as a Boolean" 'highAvailability="yes" must be a Boolean (true or false)'
wf tpg-day0 "$(params clusters=Aks_01)"
rejected "tpg-day0: clusters=Aks_01 is refused as a List" 'clusters="Aks_01" must be a List'
wf tpg-day0 "$(params clusters=all instances=orders_db)"
rejected "tpg-day0: instances=orders_db is refused" 'instances="orders_db" must be a List'
wf tpg-day0 "$(params clusters=all fooBar=1)"
rejected "tpg-day0: an unknown input is refused" 'fooBar is not an input of tpg-day0'
wf tpg-day0 "$(params 'clusterMap=aks-tpg-poc-01:
  operatorVersion: v4.5.0
  instances:
    orders-db: {postgresVersion: "17.6", highAvailability: true}' pushMode=direct)"
accepted "tpg-day0: a YAML clusterMap is accepted"
wf tpg-day0 "$(params 'clusterMap={"aks-tpg-poc-01": {"instances": {"orders-db": {}}}}' pushMode=pr)"
accepted "tpg-day0: a JSON clusterMap is accepted"
wf tpg-day0 "$(params 'clusterMap=just some text')"
rejected "tpg-day0: clusterMap that is not a map is refused" 'clusterMap="just some text" must be a Map'
wf tpg-day0 "$(params clusters=all pushMode=)"
accepted "tpg-day0: an empty mandatory input passes the type check (the validate step reports it)"
# Round 13 (D69 to D71): combination rules, cron and FerretDB types
wf tpg-day0 "$(params clusters=all instances=orders-db highAvailability=true readReplicas=0)"
rejected "tpg-day0: highAvailability=true with readReplicas=0 is refused" 'highAvailability=true needs readReplicas 1 or more'
wf tpg-day0 "$(params clusters=all instances=orders-db highAvailability=false readReplicas=0)"
accepted "tpg-day0: highAvailability=false with readReplicas=0 (a single node) is accepted"
wf tpg-day0 "$(params clusters=all instances=orders-db highAvailability=false readReplicas=2)"
rejected "tpg-day0: readReplicas=2 with highAvailability=false is refused" 'readReplicas above 0 needs highAvailability=true'
wf tpg-create-instance "$(params clusters=aks-tpg-poc-01 instances=docs-db highAvailability=false readReplicas=1)"
rejected "tpg-create-instance: readReplicas=1 with highAvailability=false is refused" 'readReplicas above 0 needs highAvailability=true'
wf tpg-day0 "$(params clusters=all instances=orders-db highAvailability=true)"
accepted "tpg-day0: highAvailability=true without readReplicas (1) is accepted"
wf tpg-create-instance "$(params clusters=aks-tpg-poc-01 instances=docs-db highAvailability=false ferret=true ferretReadOnlyReplicas=2)"
rejected "tpg-create-instance: read-only FerretDB proxies without highAvailability are refused" 'ferretReadOnlyReplicas above 0 needs highAvailability=true'
wf tpg-create-instance "$(params clusters=aks-tpg-poc-01 instances=docs-db highAvailability=true ferret=true ferretReadOnlyReplicas=1 ferretExposure=internalLoadBalancer ferretSecretName=docs-db-app-user-db-secret)"
accepted "tpg-create-instance: FerretDB inputs of an HA instance are accepted"
wf tpg-day0 "$(params clusters=all backupSchedule=operator 'operatorFullSchedule=0 1 * * 0' operatorIncrementalSchedule=)"
accepted "tpg-day0: backupSchedule=operator with a full schedule and no incremental one"
wf tpg-day0 "$(params clusters=all backupSchedule=operator 'operatorFullSchedule=every sunday' ferretReplicas=0)"
rejected "tpg-day0: a schedule that is not cron and ferretReplicas=0 are refused" 'operatorFullSchedule="every sunday" must be a cron schedule of 5 fields' 'ferretReplicas="0" must be an Integer (1 or more)'
wf tpg-scale-instance "$(params cluster=aks-tpg-poc-01 instance=orders-db replicas=2 pushMode=direct)"
rejected "tpg-scale-instance: the old single cluster/instance inputs are refused" 'cluster is not an input of tpg-scale-instance' 'instance is not an input'
wf tpg-scale-instance "$(params clusters=aks-tpg-poc-01,aks-tpg-poc-02 instances=orders-db replicas=2 pushMode=direct)"
accepted "tpg-scale-instance: clusters and instances lists are accepted"
wf tpg-scale-instance "$(params clusters=all instances=orders-db replicas=2)"
rejected "tpg-scale-instance: clusters=all is refused (a list of names only)" 'clusters="all" must be a List (comma-separated names)'
wf tpg-patch "$(params clusters=aks-tpg-poc-01 instances=orders-db postgresPatchFilePath=./patches/mem.yaml 'patchFiles={"./patches/mem.yaml":"YQ=="}' pushMode=direct)"
accepted "tpg-patch: a local file path and patchFiles are accepted"
wf tpg-patch "$(params postgresPatchFilePath=/etc/passwd)"
rejected "tpg-patch: a path that is not a .yaml or .yml file is refused" 'postgresPatchFilePath="/etc/passwd" must be a List of .yaml or .yml files'
wf tpg-patch "$(params clusters=aks-tpg-poc-01 instances=orders-db 'postgresPatchFilePath=/home/me/pg.yaml, ~/sched.yaml, ../loc.yaml, repo:charts/tpg-instance/patches/team.yaml' pushMode=direct)"
accepted "tpg-patch 1c/1d: a list of absolute, ~/, ../ and repo: files is accepted"
wf tpg-patch "$(params valuesPatchFilePath=a.yaml)"
rejected "tpg-patch 1b: valuesPatchFilePath was renamed" 'valuesPatchFilePath was renamed postgresValuesPatchFilePath (Round 15)'
wf tpg-patch "$(params postgresValuesPatchFilePath=a.yaml,b.yaml)"
rejected "tpg-patch: postgresValuesPatchFilePath takes one file" 'postgresValuesPatchFilePath="a.yaml,b.yaml" must be the path of one .yaml or .yml file'
wf tpg-patch "$(params patchMode=clear clearKinds=all,Postgres)"
rejected "tpg-patch: clearKinds all stands alone" 'clearKinds="all,Postgres" must be a List of Postgres'
wf tpg-patch "$(params patchMode=clear clearKinds=PostgresBackupSchedule,postgresValues)"
accepted "tpg-patch: clearKinds lists kinds"
wf tpg-day0 "$(params clusters=all backupEnableSSL=true backupCaBundleFile=./azure.pem backupFullRetention=14 backupFullRetentionType=time)"
accepted "tpg-day0 3.i/1g: backupCaBundleFile, backupFullRetention and backupFullRetentionType are accepted"
wf tpg-day0 "$(params backupCaBundleFile=azure.txt backupFullRetentionType=days)"
rejected "tpg-day0: a CA bundle that is not a PEM file name and an unknown retention type are refused" 'backupCaBundleFile="azure.txt" must be the path of one PEM file' 'backupFullRetentionType="days"'
wf tpg-backup-retention "$(params clusters=all)"
rejected "Round 15: tpg-backup-retention is gone (a Workflow of it is refused)" 'WorkflowTemplate tpg-backup-retention has no parameter types in workflows/params/types.yaml'
wf tpg-rotate-credential "$(params secretType=ca-bundle secretName=azure-storage caBundleFile=./azure.pem)"
accepted "tpg-rotate-credential 3.ii: a ca-bundle from a file is accepted"
wf tpg-rotate-credential "$(params secretType=git-push wrappingToken='hvs.bad token')"
rejected "tpg-rotate-credential: a wrapping token with a space is refused" 'wrappingToken="hvs.bad token" must be a Vault wrapping token (tpg-aks-infra scripts/vault-secret.sh wrap prints it)'
wf tpg-patch "$(params operatorManifestPatchFilePath=patches/operator/x.yaml)"
rejected "tpg-patch: operatorManifestPatchFilePath is no longer an input" 'operatorManifestPatchFilePath is not an input of tpg-patch'
wf tpg-day0 "$(params clusters=all instances=orders-db 'postgresOverlayFilePath=./ov/pg.yaml, repo:charts/tpg-instance/overlays/team.yaml' postgresValuesOverlayFilePath=./ov/v.yaml operatorValuesOverlayFilePath=repo:overlays/operator/team.yaml)"
accepted "22: tpg-day0 takes the overlay inputs"
wf tpg-create-instance "$(params clusters=aks-tpg-poc-01 instances=docs-db postgresOverlayFilePath=./ov/pg.yaml postgresValuesOverlayFilePath=repo:charts/tpg-instance/overlays/v.yaml)"
accepted "22: tpg-create-instance takes the overlay inputs"
wf tpg-day0 "$(params postgresPatchFilePath=./a.yaml)"
rejected "22: tpg-day0 no longer takes postgresPatchFilePath (renamed postgresOverlayFilePath)" 'postgresPatchFilePath is not an input of tpg-day0'
wf tpg-create-instance "$(params postgresValuesPatchFilePath=./a.yaml)"
rejected "22: tpg-create-instance no longer takes postgresValuesPatchFilePath" 'postgresValuesPatchFilePath is not an input of tpg-create-instance'
wf tpg-delete-apps "$(params clusters=aks-tpg-poc-01 forceDeleteStuckApps=false)"
accepted "22: tpg-delete-apps takes forceDeleteStuckApps"
wf tpg-delete-instance "$(params clusters=aks-tpg-poc-01 forceDeleteStuckApps=maybe)"
rejected "22: forceDeleteStuckApps is true or false" 'forceDeleteStuckApps="maybe" must be a Boolean (true or false)'
wf tpg-patch "$(params patchMode=append)"
rejected "tpg-patch: patchMode takes apply or clear" 'patchMode="append" must be one of apply, clear'
wf tpg-patch "$(params patchFiles=not-json)"
rejected "tpg-patch: patchFiles must be a JSON object" 'patchFiles="not-json" must be a JSON object'
wf tpg-restore "$(params sourceCluster=aks-tpg-poc-01 instance=orders-db mode=time targetTime=2026-09-15)"
rejected "tpg-restore: targetTime without the time of day is refused" 'targetTime="2026-09-15" must be a UTC time'
wf tpg-upgrade "$(params component=operator targetVersion=4.5.1 clusters=all pushMode=direct operatorPatches=keep)"
rejected "tpg-upgrade: operatorPatches is gone with the manifest patches (Round 14)" 'operatorPatches is not an input of tpg-upgrade'
wf tpg-scale-instance "$(params clusters=aks-tpg-poc-01 maxReadReplicas=0 rolloutMode=canary)"
rejected "tpg-scale-instance: maxReadReplicas is an Integer of 1 or more" 'maxReadReplicas="0" must be an Integer (1 or more)'
wf tpg-scale-instance "$(params clusters=aks-tpg-poc-01 maxReadReplicas=4 rolloutMode=batches maxParallel=2 pushMode=direct)"
accepted "tpg-scale-instance: maxReadReplicas, rolloutMode and maxParallel are accepted"
wf tpg-upgrade "$(params component=database)"
rejected "tpg-upgrade: component outside its enum is refused" 'component="database" must be one of operator, postgres'
# A value written as a YAML number in a manifest is read as its text
N=$((N + 1))
RC=0; OUT="$(k create -f - <<YAML 2>&1
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata: {name: t-${N}, namespace: argo}
spec:
  workflowTemplateRef: {name: tpg-backup}
  arguments:
    parameters:
      - {name: backupTimeoutSeconds, value: 3600}
      - {name: scheduledOnly, value: true}
YAML
)" || RC=$?
accepted "tpg-backup: numbers and booleans written unquoted are accepted"
wf other-template "$(params anything=goes)"
accepted "a Workflow of a non-tpg template is not affected"
wf tpg-unknown "$(params x=1)"
rejected "a tpg-* template without declared types is refused" 'has no parameter types'

# Every template's defaults pass the policy
for f in "$ROOT"/workflows/templates/*.yaml; do
  t="$(yq -r '.metadata.name' "$f")"
  [[ "$t" == "tpg-lib" ]] && continue
  wf "$t" "$(yq -o=json -I=0 '[.spec.arguments.parameters[] | {"name": .name, "value": (.value // "")}]' "$f")"
  accepted "${t}: a Workflow with every input at its default is accepted"
done

# ------------------------------------------------------------------ tpg-credential-writer (Round 15, D87)
obj() {  # obj KIND NAME SPEC_JSON [kubectl args...] -> creates the object; $OUT, $RC
  local doc
  doc="$(jq -cn --arg k "$1" --arg n "$2" --argjson s "$3" '{apiVersion: "argoproj.io/v1alpha1", kind: $k,
    metadata: {name: $n, namespace: "argo"}, spec: $s}')"
  RC=0; OUT="$(k create "${@:4}" -f - <<<"$doc" 2>&1)" || RC=$?
}
W='tpg-credential-writer'
obj Workflow cw-1 "{\"serviceAccountName\": \"$W\", \"entrypoint\": \"m\", \"templates\": [{\"name\": \"m\"}]}"
rejected "writer: a Workflow that runs as tpg-credential-writer is refused" 'only the WorkflowTemplate tpg-rotate-credential may run as the ServiceAccount tpg-credential-writer'
obj Workflow cw-2 "{\"entrypoint\": \"m\", \"templates\": [{\"name\": \"m\", \"serviceAccountName\": \"$W\"}]}"
rejected "writer: a template of a Workflow that runs as the writer is refused" 'Workflow cw-2: only the WorkflowTemplate'
obj Workflow cw-3 "{\"entrypoint\": \"m\", \"templates\": [{\"name\": \"m\", \"podSpecPatch\": \"serviceAccountName: $W\"}]}"
rejected "writer: a podSpecPatch that names the writer is refused" 'Workflow cw-3'
obj Workflow cw-4 "{\"entrypoint\": \"m\", \"templateDefaults\": {\"serviceAccountName\": \"$W\"}, \"templates\": [{\"name\": \"m\"}]}"
rejected "writer: templateDefaults that run as the writer are refused" 'Workflow cw-4'
obj Workflow cw-5 "{\"entrypoint\": \"m\", \"executor\": {\"serviceAccountName\": \"$W\"}, \"templates\": [{\"name\": \"m\"}]}"
rejected "writer: an executor that runs as the writer is refused" 'Workflow cw-5'
obj CronWorkflow cw-6 "{\"schedules\": [\"0 1 * * *\"], \"workflowSpec\": {\"serviceAccountName\": \"$W\", \"entrypoint\": \"m\", \"templates\": [{\"name\": \"m\"}]}}"
rejected "writer: a CronWorkflow whose Workflows run as the writer is refused" 'CronWorkflow cw-6'
obj WorkflowTemplate tpg-other "{\"entrypoint\": \"m\", \"templates\": [{\"name\": \"m\", \"serviceAccountName\": \"$W\"}]}"
rejected "writer: another WorkflowTemplate may not name the writer" 'WorkflowTemplate tpg-other'
obj Workflow cw-7 '{"workflowTemplateRef": {"name": "tpg-rotate-credential"}, "arguments": {"parameters": [{"name": "secretType", "value": "git-push"}]}}'
accepted "writer: a Workflow submitted from tpg-rotate-credential is accepted"
obj Workflow cw-8 '{"serviceAccountName": "tpg-workflow", "entrypoint": "m", "templates": [{"name": "m"}]}'
accepted "writer: other ServiceAccounts are not affected"
# Round 15 review: the ways around the first check
R='"templateRef": {"name": "tpg-rotate-credential", "template": "write-secret"}'
obj Workflow cw-9 "{\"entrypoint\": \"m\", \"templates\": [{\"name\": \"m\", \"steps\": [[{\"name\": \"w\", $R}]]}]}"
rejected "writer: a step with templateRef to tpg-rotate-credential is refused" 'only tpg-rotate-credential itself may reference its templates'
obj Workflow cw-10 "{\"entrypoint\": \"m\", \"templates\": [{\"name\": \"m\", \"dag\": {\"tasks\": [{\"name\": \"w\", $R}]}}]}"
rejected "writer: a DAG task with templateRef to tpg-rotate-credential is refused" 'Workflow cw-10: only tpg-rotate-credential itself'
obj Workflow cw-11 "{\"entrypoint\": \"m\", \"hooks\": {\"exit\": {$R}}, \"templates\": [{\"name\": \"m\"}]}"
rejected "writer: a lifecycle hook with templateRef to tpg-rotate-credential is refused" 'Workflow cw-11: only tpg-rotate-credential itself'
obj WorkflowTemplate tpg-wrapper "{\"entrypoint\": \"m\", \"templates\": [{\"name\": \"m\", \"steps\": [[{\"name\": \"w\", $R}]]}]}"
rejected "writer: another WorkflowTemplate may not reference tpg-rotate-credential" 'WorkflowTemplate tpg-wrapper'
REF='"workflowTemplateRef": {"name": "tpg-rotate-credential"}, "arguments": {"parameters": [{"name": "secretType", "value": "git-push"}]}'
obj Workflow cw-12 "{$REF, \"podSpecPatch\": \"{\\\"containers\\\":[{\\\"name\\\":\\\"main\\\",\\\"command\\\":[\\\"sh\\\"]}]}\"}"
rejected "writer: a run of tpg-rotate-credential with a podSpecPatch is refused" 'a run of tpg-rotate-credential takes only workflowTemplateRef and arguments' 'podSpecPatch'
obj Workflow cw-13 "{$REF, \"templateDefaults\": {\"sidecars\": [{\"name\": \"x\", \"image\": \"evil\"}]}, \"volumes\": [{\"name\": \"scripts\", \"configMap\": {\"name\": \"evil\"}}]}"
rejected "writer: a run of tpg-rotate-credential with templateDefaults and volumes is refused" 'takes only workflowTemplateRef and arguments; remove' 'templateDefaults' 'volumes'
obj Workflow cw-14 "{$REF, \"entrypoint\": \"write-secret\"}"
rejected "writer: a run of tpg-rotate-credential with its own entrypoint is refused" 'remove entrypoint'
obj CronWorkflow cw-15 "{\"schedules\": [\"0 1 * * *\"], \"workflowSpec\": {$REF, \"podSpecPatch\": \"{}\"}}"
rejected "writer: a CronWorkflow of tpg-rotate-credential with a podSpecPatch is refused" 'CronWorkflow cw-15: a run of tpg-rotate-credential'
obj Workflow cw-16 "{\"entrypoint\": \"m\", \"templates\": [{\"name\": \"m\", \"podSpecPatch\": \"{\\\"serviceAccountName\\\":\\\"tpg-\\\\u0063redential-writer\\\"}\"}]}"
rejected "writer: a podSpecPatch that spells the name with an escape is refused" 'a podSpecPatch may not set a ServiceAccount'
obj Workflow cw-17 "{\"entrypoint\": \"m\", \"templates\": [{\"name\": \"m\", \"podSpecPatch\": \"SERVICEACCOUNTNAME: other\"}]}"
rejected "writer: a podSpecPatch that sets any ServiceAccount, in any letter case, is refused" 'Workflow cw-17: a podSpecPatch'
obj Workflow cw-18 "{\"entrypoint\": \"m\", \"templates\": [{\"name\": \"m\", \"steps\": [[{\"name\": \"s\", \"inline\": {\"container\": {\"image\": \"x\"}, \"serviceAccountName\": \"$W\"}}]]}]}"
rejected "writer: an inline template that runs as the writer is refused" 'Workflow cw-18: only the WorkflowTemplate tpg-rotate-credential may run as'
obj Workflow cw-19 "{\"entrypoint\": \"m\", \"templates\": [{\"name\": \"m\", \"steps\": [[{\"name\": \"s\", \"inline\": {\"steps\": [[{\"name\": \"t\", \"template\": \"m\"}]]}}]]}]}"
rejected "writer: an inline template that nests steps is refused" 'an inline template may not nest steps or a DAG'
obj Workflow cw-20 '{"entrypoint": "m", "templates": [{"name": "m", "podSpecPatch": "{\"containers\":[{\"name\":\"main\",\"resources\":{\"limits\":{\"memory\":\"1Gi\"}}}]}"}]}'
accepted "writer: an ordinary podSpecPatch is accepted"
obj Workflow cw-21 "{$REF, \"shutdown\": \"Stop\"}"
accepted "writer: a run of tpg-rotate-credential that argo stop marks (spec.shutdown) is accepted"
RC=0; OUT="$(k create -f - <<<"$(jq -cn --arg w "$W" '{apiVersion: "argoproj.io/v1alpha1", kind: "ClusterWorkflowTemplate",
  metadata: {name: "tpg-cluster-writer"}, spec: {entrypoint: "m", templates: [{name: "m", serviceAccountName: $w}]}}')" 2>&1)" || RC=$?
rejected "writer: a ClusterWorkflowTemplate that runs as the writer is refused" 'ClusterWorkflowTemplate tpg-cluster-writer'
RT="{\"entrypoint\": \"m\", \"templates\": [{\"name\": \"m\"}, {\"name\": \"write\", \"serviceAccountName\": \"$W\"}]}"
obj WorkflowTemplate tpg-rotate-credential "$RT"
rejected "writer: tpg-rotate-credential written by a person is refused" 'the WorkflowTemplate tpg-rotate-credential is written by Argo CD only'
obj WorkflowTemplate tpg-rotate-credential "$RT" --as=system:serviceaccount:argocd:argocd-application-controller
accepted "writer: tpg-rotate-credential written by Argo CD (argocd ServiceAccount) is accepted"
RC=0; OUT="$(k -n argo patch workflowtemplate tpg-rotate-credential --type=merge -p '{"metadata": {"labels": {"x": "y"}}}' 2>&1)" || RC=$?
rejected "writer: a person cannot change tpg-rotate-credential afterwards" 'written by Argo CD only'

# the workflow ServiceAccounts write run records only, and pod metadata only
# (Round 15 review: tpg-scripts and tpg-settings feed the write step)
k apply -f "$ROOT/workflows/rbac.yaml" >/dev/null
SA_WF=system:serviceaccount:argo:tpg-workflow
SA_W="system:serviceaccount:argo:$W"
k -n argo create configmap tpg-scripts --from-literal=rotate-write.sh='echo ok' >/dev/null
k -n argo create configmap tpg-settings --from-literal=registryHost=tanzu-sql-postgres.packages.broadcom.com >/dev/null
RC=0; OUT="$(k -n argo create configmap tpg-run-cw-1 --from-literal=a=b --as="$SA_WF" 2>&1)" || RC=$?
accepted "writer: tpg-workflow may create a run record (tpg-run-*)"
RC=0; OUT="$(k -n argo patch configmap tpg-run-cw-1 --type merge -p '{"data":{"a":"c"}}' --as="$SA_W" 2>&1)" || RC=$?
accepted "writer: the workflow ServiceAccounts may update a run record"
RC=0; OUT="$(k -n argo patch configmap tpg-scripts --type merge -p '{"data":{"rotate-write.sh":"curl evil"}}' --as="$SA_WF" 2>&1)" || RC=$?
rejected "writer: tpg-workflow may not change tpg-scripts (the write step's script)" 'ConfigMap tpg-scripts: the workflow ServiceAccounts write only run records'
RC=0; OUT="$(k -n argo patch configmap tpg-settings --type merge -p '{"data":{"registryHost":"evil.example"}}' --as="$SA_W" 2>&1)" || RC=$?
rejected "writer: tpg-credential-writer may not change tpg-settings (registry host, fleet URL)" 'ConfigMap tpg-settings: the workflow ServiceAccounts write only run records'
RC=0; OUT="$(k -n argo create configmap other --from-literal=a=b --as="$SA_WF" 2>&1)" || RC=$?
rejected "writer: tpg-workflow may not create another ConfigMap" 'ConfigMap other:'
RC=0; OUT="$(k -n argo patch configmap tpg-settings --type merge -p '{"data":{"acnsEnabled":"false"}}' 2>&1)" || RC=$?
accepted "writer: an administrator (tpg-aks-infra) may still change tpg-settings"
k -n argo run cw-pod --image=alpine/k8s:1.35.8 --restart=Never >/dev/null
RC=0; OUT="$(k -n argo patch pod cw-pod --type merge -p '{"metadata":{"annotations":{"workflows.argoproj.io/outputs":"{}"}}}' --as="$SA_WF" 2>&1)" || RC=$?
accepted "writer: the executor may change pod metadata"
RC=0; OUT="$(k -n argo patch pod cw-pod --type json -p '[{"op":"replace","path":"/spec/containers/0/image","value":"evil/image:1"}]' --as="$SA_WF" 2>&1)" || RC=$?
rejected "writer: tpg-workflow may not change a pod's image" 'Pod cw-pod: the workflow ServiceAccounts may change pod metadata only'
RC=0; OUT="$(k -n argo patch pod cw-pod --type json -p '[{"op":"replace","path":"/spec/containers/0/image","value":"alpine/k8s:1.35.9"}]' 2>&1)" || RC=$?
accepted "writer: an administrator may still change a pod's image"

# every WorkflowTemplate and CronWorkflow of the repository passes, written as Argo CD writes them
for f in "$ROOT"/workflows/templates/*.yaml "$ROOT"/workflows/cron/*.yaml; do
  RC=0; OUT="$(k apply --dry-run=server -n argo -f "$f" --as=system:serviceaccount:argocd:argocd-application-controller 2>&1)" || RC=$?
  accepted "writer: $(basename "$f") passes the admission policies"
done

# ------------------------------------------------------------------ Application sync
app_doc() {  # app_doc NAME COMPONENT -> Application JSON
  jq -cn --arg n "$1" --arg c "$2" '{apiVersion: "argoproj.io/v1alpha1", kind: "Application",
    metadata: ({name: $n, namespace: "argocd"} + (if $c != "" then {labels: {"tpg.fleet/component": $c}} else {} end)),
    spec: {project: "tpg", destination: {server: "https://example.invalid", namespace: "pg-orders-db"},
           source: {repoURL: "https://github.com/example/tpg-fleet.git", path: "charts/tpg-instance", targetRevision: "main"}}}'
}
op() {  # op APP USER AS [automated]: set a new sync operation initiated by USER, as AS (a kubectl --as user or "")
  local who="$2" as="$3" auto="${4:-false}" patch
  patch="$(jq -cn --arg u "$who" --argjson a "$auto" '{operation: {sync: {revision: "HEAD"},
    initiatedBy: (if $a then {automated: true} else {username: $u} end)}}')"
  RC=0; OUT="$(k -n argocd patch application "$1" --type merge -p "$patch" ${as:+--as="$as"} 2>&1)" || RC=$?
}
clear_op() { k -n argocd patch application "$1" --type json -p '[{"op":"remove","path":"/operation"}]' \
  --as=system:serviceaccount:argocd:argocd-application-controller >/dev/null 2>&1 || true; }
SERVER=system:serviceaccount:argocd:argocd-server

RC=0; OUT="$(k create -f - <<<"$(app_doc tpg-aks-tpg-poc-01-orders-db instance)" 2>&1)" || RC=$?
accepted "Application: a target Application without an operation can be created (ApplicationSet controller)"
op tpg-aks-tpg-poc-01-orders-db workflow-bot "$SERVER"
accepted "Application: argocd-server may start a sync for workflow-bot"
RC=0; OUT="$(k -n argocd patch application tpg-aks-tpg-poc-01-orders-db --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}' --as="$SERVER" 2>&1)" || RC=$?
accepted "Application: an update that keeps the running operation is not affected"
RC=0; OUT="$(k -n argocd patch application tpg-aks-tpg-poc-01-orders-db --type json \
  -p '[{"op":"remove","path":"/operation"}]' --as=system:serviceaccount:argocd:argocd-application-controller 2>&1)" || RC=$?
accepted "Application: the controller may remove the finished operation"
op tpg-aks-tpg-poc-01-orders-db workflow-bot:apiKey "$SERVER"
accepted "Application: workflow-bot:apiKey (API token subject) is accepted"
clear_op tpg-aks-tpg-poc-01-orders-db
op tpg-aks-tpg-poc-01-orders-db admin "$SERVER"
rejected "Application: a sync started by admin in the UI or CLI is refused" 'only the tpg workflows (Argo CD account workflow-bot) may sync tpg-aks-tpg-poc-01-orders-db' 'requested by admin'
op tpg-aks-tpg-poc-01-orders-db workflow-bot ""
rejected "Application: an operation written with kubectl, even naming workflow-bot, is refused" 'through admin'
op tpg-aks-tpg-poc-01-orders-db "" "system:serviceaccount:argocd:argocd-application-controller" true
rejected "Application: an automated operation is refused" 'requested by an unknown user'
RC=0; OUT="$(k -n argocd patch application tpg-aks-tpg-poc-01-orders-db --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":false}}}}' 2>&1)" || RC=$?
rejected "Application: switching on automated sync is refused" 'automated sync cannot be enabled on tpg-aks-tpg-poc-01-orders-db'
RC=0; OUT="$(k -n argocd patch application tpg-aks-tpg-poc-01-orders-db --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"enabled":false}}}}' 2>&1)" || RC=$?
accepted "Application: automated with enabled=false is accepted"
RC=0; OUT="$(k create -f - <<<"$(app_doc tpg-aks-tpg-poc-01-operator operator | jq -c '.operation = {sync: {revision: "HEAD"}, initiatedBy: {username: "admin"}}')" 2>&1)" || RC=$?
rejected "Application: creating a target Application with an operation by someone else is refused" 'only the tpg workflows'
RC=0; OUT="$(k create -f - <<<"$(app_doc tpg-hub-workflows "")" 2>&1)" || RC=$?
accepted "Application: a hub Application (no tpg.fleet/component) can be created"
op tpg-hub-workflows admin "$SERVER"
accepted "Application: a hub Application can still be synced by an admin"

echo
echo "tests/admission: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
