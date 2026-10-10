#!/usr/bin/env bash
# scripts/submit/tpg-*.sh (submit-lib.sh), driven through the plain numbered
# menus (stdin is not a terminal) with stub argo and kubectl:
#   - every script loads its WorkflowTemplate inputs and types
#   - mandatory inputs first, a wrong value is refused with its type and asked again
#   - an optional input picked from the menu, a map input given as one YAML line
#   - clusterMap pasted as several lines, checked with clustermap.py (the
#     registered clusters come from the hub), then submitted with kubectl
#     create when the argo CLI is not installed
#   - an invalid clusterMap is shown with the reasons; leaving it unset falls
#     back to the lists
#   - Cancel submits nothing
# Requires: bash, python3, jq, yq (mikefarah); skipped without them.
# shellcheck disable=SC2015,SC2016
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
for t in python3 jq yq; do command -v "$t" >/dev/null || { echo "SKIP tests/submit: $t not installed" >&2; exit 0; }; done
yq --version 2>&1 | grep -q mikefarah || { echo "SKIP tests/submit: yq is not mikefarah yq v4" >&2; exit 0; }
TMP="$(mktemp -d)"; trap '[[ -n "${KEEP_TMP:-}" ]] || rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { printf 'ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL %s\n' "$1"; [[ -z "${2:-}" ]] || printf '%s\n' "$2" | sed 's/^/       | /' | tail -15; FAIL=$((FAIL + 1)); }

# ---- stubs: a PATH with only the tools the scripts need, argo optional
mkdir -p "$TMP/bin" "$TMP/bin-argo"
for t in bash sh env python3 jq yq sed tr cut sort grep cat cp mktemp rm dirname head tail paste printf date sleep base64 wc mv readlink openssl; do
  p="$(command -v "$t" 2>/dev/null)" || continue
  [[ "$p" == /* ]] && ln -sf "$p" "$TMP/bin/$t"
done
cat > "$TMP/bin/kubectl" <<STUB
#!/usr/bin/env bash
case "\$*" in
  *"get secret -l tpg.fleet/cluster"*) printf 'aks-tpg-poc-01\naks-tpg-poc-02\n' ;;
  *"create -f"*) a="\$*"; f="\${a##*-f }"; f="\${f%% *}"; cp "\$f" "$TMP/created.json"; echo "workflow.argoproj.io/tpg-create-instance-abc12" ;;
esac
STUB
cat > "$TMP/bin-argo/argo" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$TMP/argo-args"
echo "tpg-day0-xyz89"
STUB
chmod +x "$TMP/bin/kubectl" "$TMP/bin-argo/argo"

sub() {  # sub SCRIPT WITH_ARGO(yes|no) INPUT_LINES -> OUT (stderr and stdout), RC
  rm -f "$TMP/argo-args" "$TMP/created.json"
  local path="$TMP/bin"; [[ "$2" == yes ]] && path="$TMP/bin-argo:$TMP/bin"
  RC=0
  OUT="$(printf '%s\n' "$3" | env -i PATH="$path" HOME="$TMP" TMPDIR="$TMP" TPG_NO_WATCH=1 \
    bash "$ROOT/scripts/submit/$1.sh" 2>&1)" || RC=$?
}
argo_has() { grep -qxF -- "$1" "$TMP/argo-args" 2>/dev/null; }
optnum() {  # optnum TEMPLATE NAME ASKED... -> the number of NAME in the optional-input menu
  T="$1" yq -r '.spec.arguments.parameters[].name' "$ROOT/workflows/templates/$1.yaml" \
    | grep -vxF -f <(printf '%s\n' "${@:3}") | grep -nxF "$2" | cut -d: -f1 | awk '{print $1 + 1}'
}

# ---- every script loads its template (Cancel right away where it can)
loaded=0; failed=""
for s in "$ROOT"/scripts/submit/tpg-*.sh; do
  n="$(basename "$s" .sh)"
  grep -q "^WF_TEMPLATE=${n}$" "$s" && [[ -f "$ROOT/workflows/templates/${n}.yaml" ]] && loaded=$((loaded + 1)) || failed="$failed $n"
done
[[ -z "$failed" && "$loaded" -eq 12 ]] && ok "12 submit scripts, each named after its WorkflowTemplate (tpg-backup-retention removed in Round 15)" || bad "scripts" "$failed"
sub tpg-backup yes "1
3"
[[ "$RC" -eq 0 ]] && grep -q "cancelled: nothing submitted" <<<"$OUT" && [[ ! -f "$TMP/argo-args" ]] \
  && ok "Cancel submits nothing" || bad "cancel" "$OUT"

# ---- tpg-day0 with the lists; a wrong operatorVersion is asked again; an optional enum and a map
ASKED=(clusterMap clusters instances pushMode highAvailability operatorVersion postgresVersion)
n_exp="$(optnum tpg-day0 exposure "${ASKED[@]}")"
n_ann="$(optnum tpg-day0 serviceAnnotations "${ASKED[@]}")"
sub tpg-day0 yes "2
aks-tpg-poc-01,aks-tpg-poc-02
orders-db
1
1
4.x
v4.5.0
17.6
${n_exp}
2
y
${n_ann}
1
service.beta.kubernetes.io/azure-load-balancer-internal-subnet: apps-subnet
n
1"
[[ "$RC" -eq 0 ]] && grep -q "'4.x' is not an operator version such as v4.5.0" <<<"$OUT" \
  && ok "day0: a wrong operatorVersion is refused with its type and asked again" || bad "day0 retry" "$OUT"
grep -q "Type:    enum (one of direct, pr)" <<<"$OUT" && grep -q "Example: internalLoadBalancer" <<<"$OUT" \
  && ok "day0: each prompt shows the type and an example" || bad "day0 prompt text" "$OUT"
argo_has "workflowtemplate/tpg-day0" && argo_has "clusters=aks-tpg-poc-01,aks-tpg-poc-02" && argo_has "instances=orders-db" \
  && argo_has "pushMode=direct" && argo_has "highAvailability=true" && argo_has "operatorVersion=v4.5.0" && argo_has "postgresVersion=17.6" \
  && argo_has "exposure=internalLoadBalancer" \
  && argo_has 'serviceAnnotations={"service.beta.kubernetes.io/azure-load-balancer-internal-subnet":"apps-subnet"}' \
  && ! grep -q '^clusterMap=' "$TMP/argo-args" \
  && ok "day0: argo submit with the mandatory inputs, the enum and the map (as JSON), nothing else" || bad "day0 argo args" "$(cat "$TMP/argo-args" 2>/dev/null) $OUT"
grep -qF "argo submit -n argo --from workflowtemplate/tpg-day0 -p clusters=aks-tpg-poc-01,aks-tpg-poc-02 -p instances=orders-db" <<<"$OUT" \
  && grep -qF -- "-p 'serviceAnnotations={\"service.beta.kubernetes.io/azure-load-balancer-internal-subnet\":\"apps-subnet\"}'" <<<"$OUT" \
  && ok "day0: the equivalent argo command is printed, single-quoted where the shell needs it" || bad "day0 command" "$OUT"

# ---- tpg-create-instance with a pasted clusterMap, submitted with kubectl (no argo CLI)
sub tpg-create-instance no "1
3
2
aks-tpg-poc-01:
  instances:
    reports-db: {postgresVersion: \"17.6\", highAvailability: false, ingressFromNamespaces: [app], networkPolicy: baseline}
END
1
n
n
1
1"
jq -e '.kind == "Workflow" and .spec.workflowTemplateRef.name == "tpg-create-instance" and .metadata.generateName == "tpg-create-instance-"
  and (.spec.arguments.parameters | from_entries
       | .pushMode == "direct" and (.clusterMap | fromjson | .["aks-tpg-poc-01"].instances["reports-db"].ingressFromNamespaces == ["app"])
       and (has("highAvailability") | not))' "$TMP/created.json" >/dev/null 2>&1 \
  && grep -q "submitted: tpg-create-instance-abc12" <<<"$OUT" \
  && ok "create-instance: pasted clusterMap, kubectl create of a Workflow when argo is missing" || bad "create-instance" "$(cat "$TMP/created.json" 2>/dev/null) $OUT"

# ---- an invalid clusterMap is explained; leaving it unset falls back to the lists
sub tpg-network-policy yes "1
3
1
{aks-tpg-poc-09: {instances: {orders-db: {ingressFromNamspaces: [app]}}}}
n
4
aks-tpg-poc-01
orders-db
1
1
1
1"
grep -q "clusterMap is not valid for tpg-network-policy" <<<"$OUT" && grep -q "aks-tpg-poc-09" <<<"$OUT" && grep -q "ingressFromNamespaces" <<<"$OUT" \
  && ok "network-policy: an invalid clusterMap lists the reasons (unregistered cluster, misspelt key)" || bad "np invalid map" "$OUT"
argo_has "clusters=aks-tpg-poc-01" && argo_has "instances=orders-db" && argo_has "mode=apply" && ! grep -q '^clusterMap=' "$TMP/argo-args" \
  && ok "network-policy: clusterMap left unset, the lists select the targets" || bad "np lists" "$(cat "$TMP/argo-args" 2>/dev/null) $OUT"

# tpg-scale-instance (Round 14): a run that only changes the cap asks for neither
# instances nor replicas; scaling asks for both
sub tpg-scale-instance yes "2
aks-tpg-poc-01
1
2
4
1
1"
argo_has "workflowtemplate/tpg-scale-instance" && argo_has "clusters=aks-tpg-poc-01" && argo_has "maxReadReplicas=4" \
  && argo_has "pushMode=direct" && ! grep -qE '^(instances|replicas)=' "$TMP/argo-args" \
  && ok "scale: only maxReadReplicas, without instances or replicas" || bad "scale cap only" "$(cat "$TMP/argo-args" 2>/dev/null) $OUT"
sub tpg-scale-instance yes "2
aks-tpg-poc-01
1
1
orders-db
2
1
1"
argo_has "instances=orders-db" && argo_has "replicas=2" && ! grep -q '^maxReadReplicas=' "$TMP/argo-args" \
  && ok "scale: instances and replicas, the cap untouched" || bad "scale instances" "$(cat "$TMP/argo-args" 2>/dev/null) $OUT"

# ---- Round 15 (1f): the scripts run from any directory, through a link, or with TPG_FLEET_DIR
mkdir -p "$TMP/elsewhere" "$TMP/links" "$TMP/copy"
ln -sf "$ROOT/scripts/submit/tpg-backup.sh" "$TMP/links/tpg-backup"
RC=0; OUT="$(cd "$TMP/elsewhere" && printf '1\n3\n' | env -i PATH="$TMP/bin-argo:$TMP/bin" HOME="$TMP" TMPDIR="$TMP" TPG_NO_WATCH=1 bash "$TMP/links/tpg-backup" 2>&1)" || RC=$?
[[ "$RC" -eq 0 ]] && grep -q "cancelled: nothing submitted" <<<"$OUT" \
  && ok "1f: a link to a submit script, run from another directory, finds its clone" || bad "link" "$OUT"
cp "$ROOT/scripts/submit/tpg-backup.sh" "$TMP/copy/"
RC=0; OUT="$(cd "$TMP/elsewhere" && printf '1\n3\n' | env -i PATH="$TMP/bin" HOME="$TMP" TMPDIR="$TMP" bash "$TMP/copy/tpg-backup.sh" 2>&1)" || RC=$?
[[ "$RC" -ne 0 ]] && grep -q "no tpg-fleet clone found: set TPG_FLEET_DIR" <<<"$OUT" && ! grep -q "command not found" <<<"$OUT" \
  && ok "1f: a copy outside a clone stops with the TPG_FLEET_DIR hint" || bad "copy" "$OUT"
RC=0; OUT="$(cd "$TMP/elsewhere" && printf '1\n3\n' | env -i PATH="$TMP/bin" HOME="$TMP" TMPDIR="$TMP" TPG_NO_WATCH=1 TPG_FLEET_DIR="$ROOT" bash "$TMP/copy/tpg-backup.sh" 2>&1)" || RC=$?
[[ "$RC" -eq 0 ]] && grep -q "cancelled: nothing submitted" <<<"$OUT" \
  && ok "1f: the same copy works with TPG_FLEET_DIR" || bad "TPG_FLEET_DIR" "$OUT"
RC=0; OUT="$(env -i PATH="$TMP/bin" HOME="$TMP" TPG_FLEET_DIR="$TMP/elsewhere" bash "$TMP/copy/tpg-backup.sh" </dev/null 2>&1)" || RC=$?
[[ "$RC" -ne 0 ]] && grep -q "no tpg-fleet clone found at TPG_FLEET_DIR=$TMP/elsewhere" <<<"$OUT" \
  && ok "1f: a TPG_FLEET_DIR that is not a clone is named" || bad "bad TPG_FLEET_DIR" "$OUT"

# ---- Round 15 (2ii): pack-patch-files.sh -o reads the parameter file itself
PK="$ROOT/scripts/submit/pack-patch-files.sh"
W="$TMP/work2"; mkdir -p "$W/run" "$W/up" "$TMP/home/p"
printf 'apiVersion: sql.tanzu.vmware.com/v1\nkind: Postgres\nspec:\n  logLevel: Debug\n' > "$W/run/pg.yaml"
printf 'apiVersion: sql.tanzu.vmware.com/v1\nkind: PostgresBackupSchedule\nmetadata: {name: orders-db-backup-full}\nspec:\n  schedule: "0 1 * * 0"\n' > "$W/up/sched.yaml"
printf 'backup:\n  fullRetention: 9\n' > "$TMP/home/p/vals.yaml"
openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj /CN=t -keyout "$W/k.pem" -out "$W/run/ca.pem" 2>/dev/null
cat > "$W/run/patch-map.yaml" <<'YAML'
pushMode: direct
clusterMap: |
  aks-tpg-poc-01:
    instances:
      orders-db:
        postgresPatchFilePath: [pg.yaml, ../up/sched.yaml, repo:helm_artifacts/instance/tpg-instance/patches/team.yaml]
        postgresValuesPatchFilePath: ~/p/vals.yaml
        backupCaBundleFile: ./ca.pem
YAML
pack_o() { RC=0; OUT="$(cd "$W/run" && env -i PATH="$TMP/bin" HOME="$TMP/home" TMPDIR="$TMP" bash "$PK" -o patch-map.yaml 2>&1)" || RC=$?; }
pack_o
pf="$(yq -r '.patchFiles' "$W/run/patch-map.yaml")"
[[ "$RC" -eq 0 ]] && [[ "$(jq -c 'keys' <<<"$pf")" == '["../up/sched.yaml","./ca.pem","pg.yaml","~/p/vals.yaml"]' ]] \
  && [[ "$(jq -r '.["~/p/vals.yaml"]' <<<"$pf" | base64 -d)" == "$(cat "$TMP/home/p/vals.yaml")" ]] \
  && [[ "$(yq -r '.pushMode' "$W/run/patch-map.yaml")" == direct ]] \
  && ok "2ii: -o reads every local path of the file (list, ../, ~/, CA), skips repo:, keys are the paths as written" || bad "pack -o" "$OUT $(cat "$W/run/patch-map.yaml")"
pack_o
[[ "$RC" -eq 0 && "$(grep -c '^patchFiles:' "$W/run/patch-map.yaml")" == 1 ]] \
  && ok "2ii: packing again replaces the patchFiles line (one line, the file stays usable)" || bad "pack twice" "$(cat "$W/run/patch-map.yaml")"
cp "$W/run/pg.yaml" "$W/run/pg-as-values.yaml"
yq -i '.clusterMap |= sub("~/p/vals.yaml"; "pg-as-values.yaml")' "$W/run/patch-map.yaml"
pack_o
[[ "$RC" -ne 0 ]] && grep -q "postgresValuesPatchFilePath: pg-as-values.yaml" <<<"$OUT" && grep -q "nothing packed" <<<"$OUT" \
  && ok "2ii: a file that does not fit its key is refused before anything is submitted" || bad "pack wrong kind" "$OUT"
yq -i '.clusterMap |= sub("pg-as-values.yaml"; "missing.yaml")' "$W/run/patch-map.yaml"
pack_o
[[ "$RC" -ne 0 ]] && grep -q "missing.yaml: no such file (relative paths start at $W/run)" <<<"$OUT" \
  && ok "2ii: a missing file names the directory relative paths start from" || bad "pack missing" "$OUT"
printf 'pushMode: direct\npostgresPatchFilePath: repo:helm_artifacts/instance/tpg-instance/patches/team.yaml\n' > "$W/run/repo-only.yaml"
RC=0; OUT="$(cd "$W/run" && env -i PATH="$TMP/bin" HOME="$TMP/home" TMPDIR="$TMP" bash "$PK" -o repo-only.yaml 2>&1)" || RC=$?
[[ "$RC" -eq 0 ]] && ! grep -q '^patchFiles:' "$W/run/repo-only.yaml" && grep -q "no local file named" <<<"$OUT" \
  && ok "2iii: only repo: files: nothing to pack, patchFiles not written" || bad "pack repo only" "$OUT"
printf 'pushMode: direct\npostgresPatchFilePath: [pg.yaml]\n' > "$W/run/list.yaml"
RC=0; OUT="$(cd "$W/run" && env -i PATH="$TMP/bin" HOME="$TMP/home" TMPDIR="$TMP" bash "$PK" -o list.yaml 2>&1)" || RC=$?
[[ "$RC" -ne 0 ]] && grep -q "postgresPatchFilePath is a YAML list; a workflow input is one string" <<<"$OUT" \
  && ok "2ii: a YAML list as a top-level input is refused with the comma-separated form" || bad "pack list input" "$OUT"
# Round 22: tpg-day0 and tpg-create-instance name overlay files; packed like patch files
printf 'resources:\n  limits: {cpu: 500m}\n' > "$W/run/ov-op.yaml"
cat > "$W/run/overlay-map.yaml" <<'YAML'
pushMode: direct
clusterMap: |
  aks-tpg-poc-01:
    operatorValuesOverlayFilePath: ./ov-op.yaml
    instances:
      orders-db:
        postgresOverlayFilePath: [pg.yaml, repo:helm_artifacts/instance/tpg-instance/overlays/team.yaml]
        postgresValuesOverlayFilePath: ~/p/vals.yaml
YAML
RC=0; OUT="$(cd "$W/run" && env -i PATH="$TMP/bin" HOME="$TMP/home" TMPDIR="$TMP" bash "$PK" -o overlay-map.yaml 2>&1)" || RC=$?
[[ "$RC" -eq 0 && "$(yq -r '.patchFiles' "$W/run/overlay-map.yaml" | jq -c 'keys')" == '["./ov-op.yaml","pg.yaml","~/p/vals.yaml"]' ]] \
  && ok "22: -o packs the overlay keys (operator, postgres list, values), skips repo:" || bad "pack overlay map" "$OUT $(cat "$W/run/overlay-map.yaml")"
yq -i '.clusterMap |= sub("~/p/vals.yaml"; "pg-as-values.yaml")' "$W/run/overlay-map.yaml"
RC=0; OUT="$(cd "$W/run" && env -i PATH="$TMP/bin" HOME="$TMP/home" TMPDIR="$TMP" bash "$PK" -o overlay-map.yaml 2>&1)" || RC=$?
[[ "$RC" -ne 0 ]] && grep -q "postgresValuesOverlayFilePath: pg-as-values.yaml" <<<"$OUT" && grep -q "pass it as postgresOverlayFilePath" <<<"$OUT" \
  && ok "22: a manifest passed as an overlay values file is refused with the overlay input names" || bad "pack overlay wrong kind" "$OUT"

echo
echo "submit: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
