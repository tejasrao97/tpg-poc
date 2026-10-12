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
printf '%s\n' "\$*" >> "$TMP/kubectl.log"
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
  OUT="$(printf '%s\n' "$3" | env -i PATH="$path" HOME="$TMP" TMPDIR="$TMP" TPG_NO_WATCH=1 ${SUB_FLEET:+TPG_FLEET_DIR="$SUB_FLEET"} \
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
[[ -z "$failed" && "$loaded" -eq 13 ]] && ok "13 submit scripts, each named after its WorkflowTemplate (tpg-backup-retention removed in Round 15, tpg-backup-expire added in Round 23)" || bad "scripts" "$failed"
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
argo_has "workflowtemplate/tpg-day0" && argo_has "clusters=[aks-tpg-poc-01, aks-tpg-poc-02]" && argo_has "instances=[orders-db]" \
  && argo_has "pushMode=direct" && argo_has "highAvailability=true" && argo_has "operatorVersion=v4.5.0" && argo_has "postgresVersion=17.6" \
  && argo_has "exposure=internalLoadBalancer" \
  && argo_has 'serviceAnnotations={"service.beta.kubernetes.io/azure-load-balancer-internal-subnet":"apps-subnet"}' \
  && ! grep -q '^clusterMap=' "$TMP/argo-args" \
  && ok "day0: argo submit with the mandatory inputs, the enum and the map (as JSON), nothing else" || bad "day0 argo args" "$(cat "$TMP/argo-args" 2>/dev/null) $OUT"
grep -qF "argo submit -n argo --from workflowtemplate/tpg-day0 -p 'clusters=[aks-tpg-poc-01, aks-tpg-poc-02]' -p 'instances=[orders-db]'" <<<"$OUT" \
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
argo_has "clusters=[aks-tpg-poc-01]" && argo_has "instances=[orders-db]" && argo_has "mode=apply" && ! grep -q '^clusterMap=' "$TMP/argo-args" \
  && ok "network-policy: clusterMap left unset, the lists select the targets" || bad "np lists" "$(cat "$TMP/argo-args" 2>/dev/null) $OUT"

# Round 23: lists are bracketed; the prompts accept plain names and send the bracketed form
ASKED_NP=(clusterMap clusters instances mode pushMode)
n_ns="$(optnum tpg-network-policy ingressFromNamespaces "${ASKED_NP[@]}")"
n_cd="$(optnum tpg-network-policy ingressFromCidrs "${ASKED_NP[@]}")"
sub tpg-network-policy yes "2
aks-tpg-poc-01 , aks-tpg-poc-02
all
[orders-db]
1
1
${n_ns}
app,  batch
y
${n_cd}
10.1.0.0/16
n
1"
argo_has "clusters=[aks-tpg-poc-01, aks-tpg-poc-02]" && argo_has "instances=[orders-db]" && argo_has "ingressFromNamespaces=[app, batch]" \
  && argo_has "ingressFromCidrs=[10.1.0.0/16]" && ! grep -q '^clusters=aks' "$TMP/argo-args" \
  && ok "R23 np: plain names get their brackets (a comma list, one value), a typed [orders-db] stays" || bad "R23 np brackets" "$(cat "$TMP/argo-args" 2>/dev/null) $OUT"
grep -q "'all' is not a List in brackets" <<<"$OUT" \
  && ok "R23 np: all is refused for a list input that does not take it, and asked again" || bad "R23 np all" "$OUT"
grep -q "Lists are written in brackets" <<<"$OUT" && grep -q "Example: \[aks-tpg-poc-01, aks-tpg-poc-02\]" <<<"$OUT" \
  && ok "R23 np: the prompt shows the bracketed example and says that plain names are accepted" || bad "R23 np prompt" "$OUT"

# tpg-scale-instance (Round 14): a run that only changes the cap asks for neither
# instances nor replicas; scaling asks for both
sub tpg-scale-instance yes "2
aks-tpg-poc-01
1
2
4
1
1"
argo_has "workflowtemplate/tpg-scale-instance" && argo_has "clusters=[aks-tpg-poc-01]" && argo_has "maxReadReplicas=4" \
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
argo_has "instances=[orders-db]" && argo_has "replicas=2" && ! grep -q '^maxReadReplicas=' "$TMP/argo-args" \
  && ok "scale: instances and replicas, the cap untouched" || bad "scale instances" "$(cat "$TMP/argo-args" 2>/dev/null) $OUT"

# ---- tpg-backup-expire (Round 23): clusterMap only; dryRun true by default; dryRun=false asks for confirm
MAP_EXP='{aks-tpg-poc-01: {instances: {orders-db: {backups: [orders-db-full-202609010100], includeDependents: true}}}}'
sub tpg-backup-expire yes "3
1
${MAP_EXP}
1
1"
argo_has "workflowtemplate/tpg-backup-expire" && grep -q '^clusterMap=' "$TMP/argo-args" && ! grep -qE '^(dryRun|confirm|clusters|instances)=' "$TMP/argo-args" \
  && grep -q 'includeDependents' "$TMP/argo-args" \
  && ok "backup-expire: only clusterMap is asked (no clusters or instances list); dryRun keeps its default true, no confirm" || bad "backup-expire dry" "$(cat "$TMP/argo-args" 2>/dev/null) $OUT"
grep -q "Example: {aks-tpg-poc-01: {instances: {orders-db: {backups: \[orders-db-full-202609010100\], includeDependents: true}, billing-db: {purgeBackups: true}}}}" <<<"$OUT" \
  && ok "backup-expire: the clusterMap prompt shows an example with backups and includeDependents" || bad "backup-expire example" "$OUT"
n_dry="$(optnum tpg-backup-expire dryRun clusterMap)"
sub tpg-backup-expire yes "3
1
${MAP_EXP}
${n_dry}
2
n
[aks-tpg-poc-01]
1"
argo_has "dryRun=false" && argo_has "confirm=[aks-tpg-poc-01]" \
  && ok "backup-expire: dryRun=false asks for confirm (the cluster names), sent in brackets" || bad "backup-expire real" "$(cat "$TMP/argo-args" 2>/dev/null) $OUT"
sub tpg-backup-expire yes "3
1
{aks-tpg-poc-01: {instances: {orders-db: {backups: [orders-db-full-202609010100], purgeBackups: true, finalBackup: false}}}}
n
4
1"
grep -q "not used by tpg-backup-expire" <<<"$OUT" \
  && ok "backup-expire: a key of another workflow in clusterMap is explained" || bad "backup-expire bad key" "$OUT"

# ---- purgeBackups on tpg-delete-instance needs finalBackup=false: asked again until it holds
n_pb="$(optnum tpg-delete-instance purgeBackups clusterMap clusters instances confirm)"
n_fb="$(optnum tpg-delete-instance finalBackup clusterMap clusters instances confirm)"
sub tpg-delete-instance yes "2
aks-tpg-poc-01
orders-db
orders-db
${n_pb}
2
n
${n_fb}
2
n
1"
grep -q "purgeBackups=true needs finalBackup=false (finalBackup is true)" <<<"$OUT" && argo_has "purgeBackups=true" && argo_has "finalBackup=false" \
  && ok "delete-instance: purgeBackups=true with the default finalBackup=true is refused in the menu; with finalBackup=false it is submitted" || bad "delete purge" "$(cat "$TMP/argo-args" 2>/dev/null) $OUT"

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
        postgresValuesPatchFilePath: [~/p/vals.yaml]
        backupCaBundleFile: [./ca.pem]
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
printf "pushMode: direct\npostgresPatchFilePath: '[repo:helm_artifacts/instance/tpg-instance/patches/team.yaml]'\n" > "$W/run/repo-only.yaml"
RC=0; OUT="$(cd "$W/run" && env -i PATH="$TMP/bin" HOME="$TMP/home" TMPDIR="$TMP" bash "$PK" -o repo-only.yaml 2>&1)" || RC=$?
[[ "$RC" -eq 0 ]] && ! grep -q '^patchFiles:' "$W/run/repo-only.yaml" && grep -q "no local file named" <<<"$OUT" \
  && ok "2iii: only repo: files: nothing to pack, patchFiles not written" || bad "pack repo only" "$OUT"
# Round 23 review: argo 4.1.3 accepts a YAML sequence in --parameter-file and sends it as a JSON array string
# (["a","b"]); the pack script reads that form as well as the quoted bracketed string
cat > "$W/run/seq.yaml" <<'YAML'
pushMode: direct
postgresPatchFilePath: [pg.yaml, ../up/sched.yaml, repo:helm_artifacts/instance/tpg-instance/patches/team.yaml]
postgresValuesPatchFilePath: [~/p/vals.yaml]
backupCaBundleFile:
  - ./ca.pem
YAML
RC=0; OUT="$(cd "$W/run" && env -i PATH="$TMP/bin" HOME="$TMP/home" TMPDIR="$TMP" bash "$PK" -o seq.yaml 2>&1)" || RC=$?
[[ "$RC" -eq 0 && "$(yq -r '.patchFiles' "$W/run/seq.yaml" | jq -c 'keys')" == '["../up/sched.yaml","./ca.pem","pg.yaml","~/p/vals.yaml"]' ]] \
  && ok "R23 review: -o reads YAML sequences for list and single-file inputs (the same files as the quoted bracketed form)" || bad "pack sequence inputs" "$OUT $(cat "$W/run/seq.yaml")"
[[ "$(yq -o=json -I=0 '.postgresPatchFilePath' "$W/run/seq.yaml")" == '["pg.yaml","../up/sched.yaml","repo:helm_artifacts/instance/tpg-instance/patches/team.yaml"]' ]] \
  && ok "R23 review: the parameter file keeps the sequence (argo sends it as a JSON array string)" || bad "pack keeps sequence" "$(head -5 "$W/run/seq.yaml")"
printf 'pushMode: direct\npostgresPatchFilePath: [pg.yaml, pg.yaml]\n' > "$W/run/seqdup.yaml"
RC=0; OUT="$(cd "$W/run" && env -i PATH="$TMP/bin" HOME="$TMP/home" TMPDIR="$TMP" bash "$PK" -o seqdup.yaml 2>&1)" || RC=$?
[[ "$RC" -eq 0 && "$(yq -r '.patchFiles' "$W/run/seqdup.yaml" | jq -c 'keys')" == '["pg.yaml"]' ]] \
  && ok "R23 review: a file named twice is packed once" || bad "pack sequence dup" "$OUT"
printf 'pushMode: direct\npostgresValuesPatchFilePath: [pg.yaml, ../up/sched.yaml]\n' > "$W/run/seqtwo.yaml"
RC=0; OUT="$(cd "$W/run" && env -i PATH="$TMP/bin" HOME="$TMP/home" TMPDIR="$TMP" bash "$PK" -o seqtwo.yaml 2>&1)" || RC=$?
[[ "$RC" -ne 0 ]] && grep -q "postgresValuesPatchFilePath: exactly one file is expected" <<<"$OUT" \
  && ok "R23 review: a sequence of two for a single-file input is refused" || bad "pack sequence two" "$OUT"
printf 'pushMode: direct\npostgresPatchFilePath: []\n' > "$W/run/seqempty.yaml"
RC=0; OUT="$(cd "$W/run" && env -i PATH="$TMP/bin" HOME="$TMP/home" TMPDIR="$TMP" bash "$PK" -o seqempty.yaml 2>&1)" || RC=$?
[[ "$RC" -ne 0 ]] && grep -q "postgresPatchFilePath: the list is empty" <<<"$OUT" \
  && ok "R23 review: an empty sequence is refused" || bad "pack sequence empty" "$OUT"
printf 'pushMode: direct\npostgresPatchFilePath:\n  - repo: helm_artifacts/instance/tpg-instance/patches/team.yaml\n' > "$W/run/seqrepo.yaml"
RC=0; OUT="$(cd "$W/run" && env -i PATH="$TMP/bin" HOME="$TMP/home" TMPDIR="$TMP" bash "$PK" -o seqrepo.yaml 2>&1)" || RC=$?
[[ "$RC" -ne 0 ]] && grep -q 'postgresPatchFilePath: repo:<file path> "check for white spaces in between"' <<<"$OUT" \
  && ok "R23 review: a sequence entry repo: x.yaml (a mapping in YAML) fails with the whitespace message" || bad "pack sequence repo space" "$OUT"
printf 'pushMode: direct\npostgresPatchFilePath: {a: b}\n' > "$W/run/seqmap.yaml"
RC=0; OUT="$(cd "$W/run" && env -i PATH="$TMP/bin" HOME="$TMP/home" TMPDIR="$TMP" bash "$PK" -o seqmap.yaml 2>&1)" || RC=$?
[[ "$RC" -ne 0 ]] && grep -q "postgresPatchFilePath must be a string or a list" <<<"$OUT" \
  && ok "R23 review: a mapping where a list belongs is refused" || bad "pack mapping input" "$OUT"
# Round 23: the input is a quoted string that holds a bracketed list; a single file is a list of one
cat > "$W/run/inputs.yaml" <<'YAML'
pushMode: direct
postgresPatchFilePath: '[pg.yaml, ../up/sched.yaml, repo:helm_artifacts/instance/tpg-instance/patches/team.yaml]'
postgresValuesPatchFilePath: '[~/p/vals.yaml]'
backupCaBundleFile: '["./ca.pem"]'
YAML
RC=0; OUT="$(cd "$W/run" && env -i PATH="$TMP/bin" HOME="$TMP/home" TMPDIR="$TMP" bash "$PK" -o inputs.yaml 2>&1)" || RC=$?
[[ "$RC" -eq 0 && "$(yq -r '.patchFiles' "$W/run/inputs.yaml" | jq -c 'keys')" == '["../up/sched.yaml","./ca.pem","pg.yaml","~/p/vals.yaml"]' ]] \
  && ok "R23: -o reads the bracketed list inputs (YAML flow and JSON), single files as lists of one, skips repo:" || bad "pack bracketed inputs" "$OUT $(cat "$W/run/inputs.yaml")"
printf "pushMode: direct\npostgresPatchFilePath: 'pg.yaml,../up/sched.yaml'\n" > "$W/run/comma.yaml"
RC=0; OUT="$(cd "$W/run" && env -i PATH="$TMP/bin" HOME="$TMP/home" TMPDIR="$TMP" bash "$PK" -o comma.yaml 2>&1)" || RC=$?
[[ "$RC" -ne 0 ]] && grep -q "postgresPatchFilePath: 'pg.yaml,../up/sched.yaml' is not a list" <<<"$OUT" && grep -q "Did you mean \[pg.yaml, ../up/sched.yaml\]?" <<<"$OUT" \
  && ok "R23: a comma-separated input is refused with the bracketed form" || bad "pack comma input" "$OUT"
printf "pushMode: direct\npostgresValuesPatchFilePath: '[pg.yaml, ../up/sched.yaml]'\n" > "$W/run/two.yaml"
RC=0; OUT="$(cd "$W/run" && env -i PATH="$TMP/bin" HOME="$TMP/home" TMPDIR="$TMP" bash "$PK" -o two.yaml 2>&1)" || RC=$?
[[ "$RC" -ne 0 ]] && grep -q "postgresValuesPatchFilePath: exactly one file is expected" <<<"$OUT" \
  && ok "R23: a single-file input with two files is refused" || bad "pack two files" "$OUT"
printf "pushMode: direct\npostgresPatchFilePath: '[repo: helm_artifacts/instance/tpg-instance/patches/team.yaml]'\n" > "$W/run/space.yaml"
RC=0; OUT="$(cd "$W/run" && env -i PATH="$TMP/bin" HOME="$TMP/home" TMPDIR="$TMP" bash "$PK" -o space.yaml 2>&1)" || RC=$?
[[ "$RC" -ne 0 ]] && grep -q 'postgresPatchFilePath: repo:<file path> "check for white spaces in between"' <<<"$OUT" \
  && ok "R23: [repo: x.yaml] in an input fails with the whitespace message" || bad "pack repo space" "$OUT"
cat > "$W/run/space-map.yaml" <<'YAML'
pushMode: direct
clusterMap: |
  aks-tpg-poc-01:
    instances:
      orders-db:
        postgresPatchFilePath: [repo: helm_artifacts/instance/tpg-instance/patches/team.yaml]
YAML
RC=0; OUT="$(cd "$W/run" && env -i PATH="$TMP/bin" HOME="$TMP/home" TMPDIR="$TMP" bash "$PK" -o space-map.yaml 2>&1)" || RC=$?
[[ "$RC" -ne 0 ]] && grep -q 'aks-tpg-poc-01.instances.orders-db.postgresPatchFilePath: repo:<file path> "check for white spaces in between"' <<<"$OUT" \
  && ok "R23: [repo: x.yaml] in the clusterMap (a YAML mapping) fails with the whitespace message" || bad "pack map repo space" "$OUT"
cat > "$W/run/string-map.yaml" <<'YAML'
pushMode: direct
clusterMap: |
  aks-tpg-poc-01:
    instances:
      orders-db:
        postgresValuesPatchFilePath: vals.yaml
YAML
RC=0; OUT="$(cd "$W/run" && env -i PATH="$TMP/bin" HOME="$TMP/home" TMPDIR="$TMP" bash "$PK" -o string-map.yaml 2>&1)" || RC=$?
[[ "$RC" -ne 0 ]] && grep -q "aks-tpg-poc-01.instances.orders-db.postgresValuesPatchFilePath: 'vals.yaml' is not a list" <<<"$OUT" \
  && ok "R23: a clusterMap file key written as a string is refused" || bad "pack map string" "$OUT"
# Round 22: tpg-day0 and tpg-create-instance name overlay files; packed like patch files
printf 'resources:\n  limits: {cpu: 500m}\n' > "$W/run/ov-op.yaml"
cat > "$W/run/overlay-map.yaml" <<'YAML'
pushMode: direct
clusterMap: |
  aks-tpg-poc-01:
    operatorValuesOverlayFilePath: [./ov-op.yaml]
    instances:
      orders-db:
        postgresOverlayFilePath: [pg.yaml, repo:helm_artifacts/instance/tpg-instance/overlays/team.yaml]
        postgresValuesOverlayFilePath: [~/p/vals.yaml]
YAML
RC=0; OUT="$(cd "$W/run" && env -i PATH="$TMP/bin" HOME="$TMP/home" TMPDIR="$TMP" bash "$PK" -o overlay-map.yaml 2>&1)" || RC=$?
[[ "$RC" -eq 0 && "$(yq -r '.patchFiles' "$W/run/overlay-map.yaml" | jq -c 'keys')" == '["./ov-op.yaml","pg.yaml","~/p/vals.yaml"]' ]] \
  && ok "22: -o packs the overlay keys (operator, postgres list, values), skips repo:" || bad "pack overlay map" "$OUT $(cat "$W/run/overlay-map.yaml")"
yq -i '.clusterMap |= sub("~/p/vals.yaml"; "pg-as-values.yaml")' "$W/run/overlay-map.yaml"
RC=0; OUT="$(cd "$W/run" && env -i PATH="$TMP/bin" HOME="$TMP/home" TMPDIR="$TMP" bash "$PK" -o overlay-map.yaml 2>&1)" || RC=$?
[[ "$RC" -ne 0 ]] && grep -q "postgresValuesOverlayFilePath: pg-as-values.yaml" <<<"$OUT" && grep -q "pass it as postgresOverlayFilePath" <<<"$OUT" \
  && ok "22: a manifest passed as an overlay values file is refused with the overlay input names" || bad "pack overlay wrong kind" "$OUT"

# ---- tpg-restore (Round 23, phase 6c): a guided pair-by-pair builder, load-file and paste, the plan of each pair printed
# before the submit. A tpg-fleet clone of its own: the registered clusters come from the hub (stub kubectl), the declared
# instances from its clusters/fleet.yaml, the spec files from its restore-specs folder.
CLONE="$TMP/clone"
mkdir -p "$CLONE/clusters" "$CLONE/helm_artifacts/instance/tpg-instance/restore-specs"
for d in scripts workflows; do ln -s "$ROOT/$d" "$CLONE/$d"; done
cat > "$CLONE/clusters/fleet.yaml" <<'YAML'
clusters:
  aks-tpg-poc-01:
    operator: {version: v4.5.0}
    cluster: {allowInPlaceRestore: true}
    instances:
      orders-db: {instance: {namespace: pg-orders, postgresVersion: postgres-17.6}}
      reports-db: {instance: {postgresVersion: postgres-17.6}}
  aks-tpg-poc-02:
    operator: {version: v4.5.0}
    instances: {}
YAML
printf 'apiVersion: sql.tanzu.vmware.com/v1\nkind: Postgres\nspec:\n  postgresVersion:\n    name: postgres-17.6\n  storageSize: 50Gi\n' \
  > "$CLONE/helm_artifacts/instance/tpg-instance/restore-specs/orders-dr.yaml"
printf '# restore specs\n' > "$CLONE/helm_artifacts/instance/tpg-instance/restore-specs/README.md"
RSPEC=helm_artifacts/instance/tpg-instance/restore-specs
SUB_FLEET="$CLONE"
rmap() { grep '^clusterMap=' "$TMP/argo-args" | sed 's/^clusterMap=//'; }   # the submitted clusterMap (JSON)

# two pairs, built step by step: an in place restore of a named backup (a wrong confirm is asked again), and point-in-time recovery
# to a time onto a new instance on another cluster, with a spec file of the restore-specs folder and a post-restore backup
: > "$TMP/kubectl.log"
sub tpg-restore yes "1
1
1
1
orders-db-full-20260914000000
1

orders-db
x
orders-db
n
n
n
1
1
2
2
2
2026-09-15T08:30:00Z
1
n

2
pg-orders-dr
orders-db-dr
y
1
n
y
2
1
1"
argo_has "workflowtemplate/tpg-restore" && grep -q '^clusterMap=' "$TMP/argo-args" && ! grep -qE '^(dryRun|confirm|sourceCluster|instance|mode)=' "$TMP/argo-args" \
  && ok "restore: argo submit with clusterMap only (dryRun keeps its default true, none of the removed flat inputs)" || bad "restore argo args" "$(cat "$TMP/argo-args" 2>/dev/null) $OUT"
jq -e 'length == 2
  and .[0] == {sourceClusterConfig: {"aks-tpg-poc-01": {"pg-orders": {"orders-db": {sourceBackupName: "orders-db-full-20260914000000"}}}},
               targetClusterConfig: {"aks-tpg-poc-01": {"pg-orders": {"orders-db": {pitrEnabled: false, confirm: "orders-db"}}}}}
  and .[1] == {sourceClusterConfig: {"aks-tpg-poc-01": {"pg-reports-db": {"reports-db": {}}}},
               targetClusterConfig: {"aks-tpg-poc-02": {"pg-orders-dr": {"orders-db-dr": {pitrEnabled: true, bestEffort: true,
                 pitrConfig: {type: "time", timestamp: "2026-09-15T08:30:00Z"},
                 targetInstanceSpecFilePath: ["repo:'"$RSPEC"'/orders-dr.yaml"], postRestoreBackup: true}}}}}' <<<"$(rmap)" >/dev/null 2>&1 \
  && ok "restore builder: the pairs use the real keys (sourceBackupName; pitrEnabled, pitrConfig.type/timestamp, bestEffort, confirm, targetInstanceSpecFilePath as a one-element list, postRestoreBackup)" \
  || bad "restore builder pairs" "$(rmap) $OUT"
grep -q "orders-db (namespace pg-orders, declared in clusters/fleet.yaml)" <<<"$OUT" && grep -q "reports-db (namespace pg-reports-db, declared in clusters/fleet.yaml)" <<<"$OUT" \
  && ok "restore builder: the source instances come from the clone's clusters/fleet.yaml with their namespaces (default pg-<instance>)" || bad "restore builder instances" "$OUT"
grep -q "aks-tpg-poc-02" <<<"$OUT" && grep -q "IN PLACE: its data is overwritten" <<<"$OUT" && grep -q "'x' is not orders-db" <<<"$OUT" \
  && ok "restore builder: an in-place pair is announced and its confirm must repeat the instance name (a wrong one is asked again)" || bad "restore builder in place" "$OUT"
grep -q "It needs clusters.aks-tpg-poc-01.cluster.allowInPlaceRestore: true in clusters/fleet.yaml" <<<"$OUT" && ! grep -q "does not set it for aks-tpg-poc-01" <<<"$OUT" \
  && ok "restore builder: the in-place note names allowInPlaceRestore, with no warning when the clone's fleet.yaml sets it" || bad "restore builder allowInPlaceRestore note" "$OUT"
grep -q "pair 1 added; its plan:" <<<"$OUT" && grep -q "pair 2 added; its plan:" <<<"$OUT" \
  && grep -qF "[0] aks-tpg-poc-01/pg-orders/orders-db -> aks-tpg-poc-01/pg-orders/orders-db" <<<"$OUT" \
  && grep -qF "[1] aks-tpg-poc-01/pg-reports-db/reports-db -> aks-tpg-poc-02/pg-orders-dr/orders-db-dr" <<<"$OUT" \
  && ok "restore builder: every pair is validated as it is added and its plan printed (index, source -> target)" || bad "restore builder plan" "$OUT"
grep -qF "method:    backup  (named backup orders-db-full-20260914000000)" <<<"$OUT" && grep -qF "in place:  yes  (IN PLACE (the data of the source instance is overwritten))" <<<"$OUT" \
  && grep -qF "method:    time  (point-in-time recovery to 2026-09-15T08:30:00Z, bestEffort true)" <<<"$OUT" \
  && grep -qF "in place:  no  (a new instance on another cluster (the source backup location is copied there))" <<<"$OUT" \
  && grep -qF "backup repository: location derived, stanza derived" <<<"$OUT" \
  && grep -qF "spec file: repo:$RSPEC/orders-dr.yaml" <<<"$OUT" && grep -qF "spec file: none (the PostgresRestore sends only the instance name; the instance keeps its spec)" <<<"$OUT" \
  && grep -qF "postRestoreBackup: true" <<<"$OUT" && grep -qF "confirm:   orders-db" <<<"$OUT" \
  && ok "restore builder: the plan shows method, in place or not, the PITR summary and repository, the spec file and the flags" || bad "restore builder plan lines" "$OUT"
grep -qF "The pairs, as the workflow will read them:" <<<"$OUT" && grep -qF "Each pair, as the workflow will plan it (dryRun true, the default):" <<<"$OUT" \
  && ok "restore builder: the whole list is checked and its plan printed again before the submit menu" || bad "restore builder final plan" "$OUT"
awk '!/get secret -l tpg.fleet\/cluster/ {bad=1} END {exit bad}' "$TMP/kubectl.log" && [[ -s "$TMP/kubectl.log" ]] \
  && ok "restore builder: kubectl is only used for the hub's registered clusters (nothing is read from a member cluster)" || bad "restore builder kubectl" "$(cat "$TMP/kubectl.log")"

# an in-place pair on a cluster whose clone entry lacks allowInPlaceRestore is warned about (the validate step refuses the run)
sub tpg-restore yes "1
2
1
ns-a
inst-a
1
backup-a
2

inst-a
inst-a
n
n
n
2
1
1"
grep -q "Your clone's clusters/fleet.yaml does not set it for aks-tpg-poc-02" <<<"$OUT" \
  && ok "restore builder: an in-place pair on a cluster without allowInPlaceRestore in the clone is warned about" || bad "restore builder allowInPlaceRestore warning" "$OUT"

# a pair clustermap.py refuses is shown with the reasons and asked again (a time without the time of day)
sub tpg-restore yes "1
1
1
2
2
2026-09-15
1
n

1
pg-orders
orders-copy
n
n
n
y
1
1
2
2
2026-09-15T08:30:00Z
1
n

1
pg-orders
orders-copy
n
n
n
2
1
1"
grep -q "clusterMap is not valid for tpg-restore" <<<"$OUT" && grep -q "pitrConfig.timestamp: '2026-09-15' must be a UTC time" <<<"$OUT" && grep -q "That pair is not valid" <<<"$OUT" \
  && ok "restore builder: an invalid pair is explained (clustermap.py restore) and entered again" || bad "restore builder invalid pair" "$OUT"
jq -e 'length == 1 and .[0].targetClusterConfig["aks-tpg-poc-01"]["pg-orders"]["orders-copy"].pitrConfig.timestamp == "2026-09-15T08:30:00Z"' <<<"$(rmap)" >/dev/null 2>&1 \
  && ok "restore builder: only the corrected pair is in the list" || bad "restore builder corrected" "$(rmap) $OUT"

# the source is not declared in clusters/fleet.yaml: a new instance needs a spec file, and one of this machine is sent with the run
mkdir -p "$TMP/specs"
printf 'apiVersion: sql.tanzu.vmware.com/v1\nkind: Postgres\nspec:\n  postgresVersion:\n    name: postgres-17.6\n' > "$TMP/specs/legacy-dr.yaml"
sub tpg-restore yes "1
1
3
legacy-ns
legacy-db
2
1
n

2
pg-dr
legacy-dr
2
$TMP/specs/legacy-dr.yaml
n
n
2
1
1"
grep -q "aks-tpg-poc-01/legacy-db is not declared in clusters/fleet.yaml, so there is no entry to copy for the new instance: a spec file is mandatory" <<<"$OUT" \
  && grep -q "files read from this machine: $TMP/specs/legacy-dr.yaml" <<<"$OUT" \
  && jq -e '.[0].sourceClusterConfig["aks-tpg-poc-01"]["legacy-ns"]["legacy-db"] == {}
    and .[0].targetClusterConfig["aks-tpg-poc-02"]["pg-dr"]["legacy-dr"].targetInstanceSpecFilePath == ["'"$TMP"'/specs/legacy-dr.yaml"]
    and .[0].targetClusterConfig["aks-tpg-poc-02"]["pg-dr"]["legacy-dr"].pitrConfig == {type: "latest"}
    and (.[0].targetClusterConfig["aks-tpg-poc-02"]["pg-dr"]["legacy-dr"] | has("bestEffort") | not)' <<<"$(rmap)" >/dev/null 2>&1 \
  && ok "restore builder: a typed source that is not declared makes the spec file mandatory; a local file is packed into patchFiles; latest takes no bestEffort" || bad "restore builder undeclared source" "$(rmap) $OUT"

# the repository named by hand (location, stanza, backup set), an lsn, and a source backup that derives them when the source instance is gone
sub tpg-restore yes "1
1
2
2
3
0/3000060
2
y
orders-backups
pg-orders-orders-db-0000
20260915-020000F
orders-db-full-20260914000000
1

orders-lsn
n
n
n
2
1
1"
jq -e '(.[0].sourceClusterConfig["aks-tpg-poc-01"]["pg-reports-db"]["reports-db"] == {sourceBackupName: "orders-db-full-20260914000000"})
  and (.[0].targetClusterConfig["aks-tpg-poc-01"]["pg-reports-db"]["orders-lsn"] | .bestEffort == false
       and .pitrConfig == {type: "lsn", target: "0/3000060", sourceBackupConfig: {srcBackupLocationName: "orders-backups", srcStanzaName: "pg-orders-orders-db-0000", srcBackupLabel: "20260915-020000F"}})' <<<"$(rmap)" >/dev/null 2>&1 \
  && ok "restore builder: lsn target, bestEffort false, srcBackupLocationName/srcStanzaName/srcBackupLabel and a source backup name for PITR" || bad "restore builder repository keys" "$(rmap) $OUT"
grep -qF "backup repository: location orders-backups, stanza pg-orders-orders-db-0000, backup set 20260915-020000F" <<<"$OUT" \
  && grep -qF "spec file: none (a new instance copies the source entry of clusters/fleet.yaml; the operator fills in its spec)" <<<"$OUT" \
  && ok "restore builder: the plan names the repository that was given, and that a new instance without a spec file copies the source entry" || bad "restore builder repository plan" "$OUT"

# the other ways in: a file with a list of pairs, pasted lines, and a clusterMap of the wrong shape
cat > "$TMP/pairs.yaml" <<'YAML'
- sourceClusterConfig:
    aks-tpg-poc-01:
      pg-orders:
        orders-db: {sourceBackupName: orders-db-full-20260914000000}
  targetClusterConfig:
    aks-tpg-poc-02:
      pg-orders-dr:
        orders-db-dr: {pitrEnabled: false}
YAML
sub tpg-restore yes "2
$TMP/pairs.yaml
1
1"
jq -e 'length == 1 and .[0].targetClusterConfig["aks-tpg-poc-02"]["pg-orders-dr"]["orders-db-dr"].pitrEnabled == false' <<<"$(rmap)" >/dev/null 2>&1 \
  && grep -qF "[0] aks-tpg-poc-01/pg-orders/orders-db -> aks-tpg-poc-02/pg-orders-dr/orders-db-dr" <<<"$OUT" \
  && ok "restore: a YAML file with a list of pairs is loaded, checked and its plan printed" || bad "restore load file" "$(rmap) $OUT"
sub tpg-restore yes "3
2
- sourceClusterConfig:
    aks-tpg-poc-01:
      pg-orders:
        orders-db: {}
  targetClusterConfig:
    aks-tpg-poc-02:
      pg-orders-dr:
        orders-db-dr: {pitrEnabled: true, pitrConfig: {type: latest}}
END
1
1"
jq -e 'length == 1 and .[0].targetClusterConfig["aks-tpg-poc-02"]["pg-orders-dr"]["orders-db-dr"].pitrConfig.type == "latest"' <<<"$(rmap)" >/dev/null 2>&1 \
  && ok "restore: several pasted lines of YAML (a list) are accepted" || bad "restore paste" "$(rmap) $OUT"
sub tpg-restore yes "3
1
{aks-tpg-poc-01: {instances: {orders-db: {}}}}
3
1
[{sourceClusterConfig: {aks-tpg-poc-01: {pg-orders: {orders-db: {}}}}, targetClusterConfig: {aks-tpg-poc-02: {pg-orders-dr: {orders-db-dr: {pitrEnabled: true, pitrConfig: {type: latest}}}}}}]
1
1"
grep -q "not a YAML or JSON list of pairs" <<<"$OUT" && jq -e 'length == 1' <<<"$(rmap)" >/dev/null 2>&1 \
  && ok "restore: a map of clusters (the clusterMap of the other workflows) is refused and asked again; a one-line list is accepted" || bad "restore paste wrong shape" "$(rmap) $OUT"
sub tpg-restore yes "2
$TMP/nope.yaml
3
1
[{sourceClusterConfig: {aks-tpg-poc-01: {pg-orders: {orders-db: {}}}}, targetClusterConfig: {aks-tpg-poc-09: {pg-x: {x-db: {pitrEnabled: true, pitrConfig: {type: latest}}}}}}]
n
3
1
[{sourceClusterConfig: {aks-tpg-poc-01: {pg-orders: {orders-db: {}}}}, targetClusterConfig: {aks-tpg-poc-02: {pg-x: {x-db: {pitrEnabled: true, pitrConfig: {type: latest}}}}}}]
1
1"
grep -q "not a file" <<<"$OUT" && grep -q "cluster 'aks-tpg-poc-09' is not registered" <<<"$OUT" && jq -e 'length == 1' <<<"$(rmap)" >/dev/null 2>&1 \
  && ok "restore: a file that does not exist and an unregistered cluster are explained (the pair is not kept) and asked again" || bad "restore errors" "$(rmap) $OUT"

# dryRun=false: an in-place pair without confirm is shown as refused before the submit (as the validate step does)
cat > "$TMP/inplace.yaml" <<'YAML'
- sourceClusterConfig:
    aks-tpg-poc-01:
      pg-orders:
        orders-db: {sourceBackupName: orders-db-full-20260914000000}
  targetClusterConfig:
    aks-tpg-poc-01:
      pg-orders:
        orders-db: {pitrEnabled: false}
YAML
n_dry="$(optnum tpg-restore dryRun clusterMap)"
sub tpg-restore yes "2
$TMP/inplace.yaml
${n_dry}
2
n
1
1"
argo_has "dryRun=false" && grep -q "orders-db.confirm is required" <<<"$OUT" && grep -q "the workflow's validate step will refuse this map" <<<"$OUT" \
  && ok "restore: with dryRun=false an in-place pair without confirm is reported as refused (clustermap.py restore --confirm-required)" || bad "restore dryRun false confirm" "$(cat "$TMP/argo-args" 2>/dev/null) $OUT"
SUB_FLEET=""

echo
echo "submit: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
