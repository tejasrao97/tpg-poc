#!/usr/bin/env bash
# helm_artifacts/instance/crd-reference and the zero-default rule (design decisions D69, D73):
#   generator    tools/crd-defaults/generate.py --check: the registry, the
#                reference templates, the _prune.tpl copy and the JSON schemas
#                match helm_artifacts/instance/crd-reference/source-crds and defaults-overlay.yaml
#   registry     fields whose default is not zero are never skipped
#                (enableSSL, backupSync, backupIntegrityValidation,
#                dedicatedWalLogVolume); required fields without a default are
#                never skipped alone
#   prune        per kind: zero defaults left out, parents emptied by them too,
#                required objects kept; FerretDB readOnly {replicas: 0} dropped
#                whole; the Postgres spec embedded in PostgresRestore
#   parity       the objects the workflow scripts write inline (backup-instance.sh,
#                postgres-upgrade.sh) equal what the reference template renders for the
#                same spec: they carry no zero default. restore-pair.sh writes none inline:
#                it renders the PostgresRestore and the location copy through this chart
#                (checked below; tests/restore checks the rendered objects)
#   schemas      every reference render and inline object passes kubeconform
#                -strict against the live CRD schemas (when kubeconform is installed)
#   restore      the PostgresRestore and the location copy that restore-pair.sh renders for every pair
#                shape (a new instance on another cluster, in another namespace of the cluster, in the
#                source namespace, in place) x a named backup and each PITR type x with and without a
#                spec file pass kubeconform -strict, the embedded targetInstance.spec included. The
#                objects are captured from tests/restore (RESTORE_RENDER_DIR, section 0), not rendered again here
# Requires: helm, yq (mikefarah), python3 with PyYAML; skipped without them.
# shellcheck disable=SC2015,SC2016
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
for t in helm yq python3; do command -v "$t" >/dev/null || { echo "SKIP tests/crd-reference: $t not installed" >&2; exit 0; }; done
python3 -c "import yaml" 2>/dev/null || { echo "SKIP tests/crd-reference: python3 PyYAML not installed" >&2; exit 0; }
yq --version 2>&1 | grep -q mikefarah || { echo "SKIP tests/crd-reference: yq is not mikefarah yq v4" >&2; exit 0; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { printf 'ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL %s\n' "$1"; [[ -z "${2:-}" ]] || printf '%s\n' "$2" | sed 's/^/       | /' | tail -15; FAIL=$((FAIL + 1)); }
REF="$ROOT/helm_artifacts/instance/crd-reference"
REG="$ROOT/helm_artifacts/instance/tpg-instance/files/zero-defaults.yaml"
SCHEMAS="$REF/schemas/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json"

# ---- generator
python3 "$ROOT/tools/crd-defaults/generate.py" --check 2>"$TMP/gen" && ok "generate.py --check: every generated file is up to date" || bad "generator" "$(cat "$TMP/gen")"
cmp -s "$REG" "$REF/files/zero-defaults.yaml" && ok "the chart and the reference chart carry the same registry" || bad "registry copies differ"

# ---- registry
nz="$(yq -r '.kinds[] | .skip[] | .path' "$REG" | grep -E '(^|\.)(enableSSL|backupSync\.enabled|backupIntegrityValidation\.enabled|dedicatedWalLogVolume|readWrite\.replicas|readOnly\.replicas)$' || true)"
[[ -z "$nz" ]] && ok "non-zero defaults are never skipped (enableSSL, backupSync, backupIntegrityValidation, dedicatedWalLogVolume, FerretDB replicas)" || bad "non-zero in registry" "$nz"
yq -e '.kinds.Postgres.skip[] | select(.path == "highAvailability.enabled" and .default == false)' "$REG" >/dev/null \
  && yq -e '.kinds.Postgres.skip[] | select(.path == "highAvailability.readReplicas" and .default == 0)' "$REG" >/dev/null \
  && ok "highAvailability.enabled false and readReplicas 0 are skipped (docs overlay)" || bad "ha in registry"
if yq -e '.kinds.Postgres.skip[] | select(.path == "deploymentOptions.continuousRestoreTarget")' "$REG" >/dev/null 2>&1; then
  bad "continuousRestoreTarget (required, no default) must not be skipped alone"
else ok "continuousRestoreTarget (required without a default) is not skipped alone; deploymentOptions {continuousRestoreTarget: false} is dropped whole"; fi
[[ "$(yq '[.kinds[]] | length' "$REG")" == "9" ]] && ok "the registry covers the 9 kinds" || bad "kinds" "$(yq '.kinds | keys' "$REG")"

# ---- prune per kind, through the reference chart
refrender() {  # refrender VALUES_YAML -> $OUT (a failed render leaves its error there)
  printf '%s\n' "$1" > "$TMP/v.yaml"
  OUT="$(helm template ref "$REF" -f "$TMP/v.yaml" 2>&1)" || true
}
spec() { K="$1" yq 'select(.kind == strenv(K)) | .spec' <<<"$OUT"; }
speccheck() {  # speccheck KIND PYTHON_EXPR: the expression holds for S, the rendered spec
  K="$1" yq -o=json 'select(.kind == strenv(K)) | .spec' <<<"$OUT" \
    | python3 -c 'import json, sys; S = json.load(sys.stdin); sys.exit(0 if eval("(" + sys.argv[1] + ")") else 1)' "$2" 2>/dev/null
}
refrender 'postgres:
  enabled: true
  name: x
  spec:
    highAvailability: {enabled: false, readReplicas: 0, podDisruptionBudget: {enabled: false}}
    dedicatedWalLogVolume: false
    deploymentOptions: {continuousRestoreTarget: false}
    serviceAnnotations: {}
    ldapSync: {enabled: false, ldapTLS: false, ldapUrl: "ldap://x", bindSecret: {name: b}, ldap2pgConfig: {name: c}}'
speccheck Postgres '"highAvailability" not in S and S["dedicatedWalLogVolume"] is False and "deploymentOptions" not in S
  and "serviceAnnotations" not in S and S["ldapSync"] == {"ldapUrl": "ldap://x", "bindSecret": {"name": "b"}, "ldap2pgConfig": {"name": "c"}}' \
  && ok "Postgres: HA false/0 and PDB false go with their parent; dedicatedWalLogVolume false (default true) stays; ldapSync defaults go" \
  || bad "postgres prune" "$OUT"
refrender 'postgresBackupLocation:
  enabled: true
  name: x
  spec:
    storage: {azure: {container: c, enableSSL: false, forcePathStyle: false, secret: {name: s}}}
    additionalParameters: {}
    backupSync: {enabled: false}
    backupIntegrityValidation: {enabled: false}'
speccheck PostgresBackupLocation 'S["storage"]["azure"] == {"container": "c", "enableSSL": False, "secret": {"name": "s"}}
  and "additionalParameters" not in S and S["backupSync"] == {"enabled": False} and S["backupIntegrityValidation"] == {"enabled": False}' \
  && ok "PostgresBackupLocation: enableSSL, backupSync and backupIntegrityValidation false stay (defaults true); forcePathStyle false and {} go" \
  || bad "bl prune" "$OUT"
refrender 'postgresFerretDocumentDB:
  enabled: true
  name: x
  spec:
    readWrite: {replicas: 1}
    readOnly: {replicas: 0}
    postgres: {connectionDetails: {readWrite: {secretName: s}}}
    service: {serviceAnnotations: {}}'
speccheck PostgresFerretDocumentDB '"readOnly" not in S and S["service"] == {} and S["readWrite"] == {"replicas": 1}' \
  && ok "PostgresFerretDocumentDB: readOnly {replicas: 0} dropped whole (schema default 1); the required service kept even when empty" \
  || bad "ferret prune" "$OUT"
refrender 'postgresRestore:
  enabled: true
  name: x
  spec:
    pitr: {type: latest, bestEffort: false, sourceBackupLocation: {name: l, stanzaName: s}}
    targetInstance: {name: t, spec: {postgresVersion: {name: postgres-17.6}, highAvailability: {enabled: false, readReplicas: 0}}}'
speccheck PostgresRestore '"bestEffort" not in S["pitr"] and "highAvailability" not in S["targetInstance"]["spec"]
  and S["targetInstance"]["spec"]["postgresVersion"] == {"name": "postgres-17.6"}' \
  && ok "PostgresRestore: bestEffort false goes; the embedded Postgres spec is pruned like a Postgres" || bad "restore prune" "$OUT"
refrender 'postgresBackup: {enabled: true, name: x, spec: {sourceInstance: {name: i}, type: full, expire: false}}
postgresBackupSchedule: {enabled: true, name: x, spec: {schedule: "0 0 * * 0", backupTemplate: {spec: {sourceInstance: {name: i}, type: full, expire: false}}}}
postgresMigration: {enabled: true, name: x, spec: {migrateAll: false, instances: []}}
postgresVersionUpgrade: {enabled: true, name: x, spec: {omitBackup: false, postgresInstance: {name: i}, postgresVersion: {name: postgres-18.1}}}
postgresVersion: {enabled: true, name: x, spec: {dbVersion: "17.6", instanceImage: img}}'
[[ "$(spec PostgresBackup | yq 'has("expire")')" == "false" && "$(spec PostgresBackupSchedule | yq '.backupTemplate.spec | has("expire")')" == "false" \
   && "$(spec PostgresMigration | yq 'length')" == "0" && "$(spec PostgresVersionUpgrade | yq 'has("omitBackup")')" == "false" \
   && "$(spec PostgresVersion | yq '.dbVersion')" == "17.6" ]] \
  && ok "PostgresBackup, PostgresBackupSchedule, PostgresMigration, PostgresVersionUpgrade: expire, migrateAll, instances [] and omitBackup false go" \
  || bad "other kinds" "$OUT"
refrender ''
! grep -q '[^[:space:]]' <<<"$OUT" && ok "every kind is off by default: the reference chart renders nothing" || bad "default render" "$OUT"
# every kind with its example (helm_artifacts/instance/crd-reference/examples): kubeconform against the CRD schemas
args=(); for f in "$REF"/examples/*.yaml; do args+=(-f "$f"); done
helm template ref "$REF" "${args[@]}" > "$TMP/all.yaml"
[[ "$(yq '.kind' "$TMP/all.yaml" | grep -vc '^---')" == "9" ]] && ok "the 9 examples render" || bad "examples" "$(cat "$TMP/all.yaml")"
if command -v kubeconform >/dev/null; then
  kc="$(kubeconform -strict -summary -schema-location "$SCHEMAS" "$TMP/all.yaml" 2>&1)" && grep -q "Valid: 9, Invalid: 0" <<<"$kc" \
    && ok "the 9 examples pass kubeconform -strict against the live CRD schemas" || bad "kubeconform examples" "$kc"
  printf 'apiVersion: sql.tanzu.vmware.com/v1\nkind: PostgresBackup\nmetadata: {name: x}\nspec: {sourceInstance: {name: i}, typo: full}\n' > "$TMP/typo.yaml"
  kubeconform -strict -schema-location "$SCHEMAS" "$TMP/typo.yaml" >/dev/null 2>&1 && bad "a misspelled field must fail the schema" \
    || ok "a misspelled spec field fails kubeconform -strict (the schemas are closed)"
fi

# ---- the objects restore-pair.sh renders for every pair shape: captured from tests/restore (its dry-run matrix), checked against the CRD schemas
if command -v kubeconform >/dev/null; then
  if [[ ! -f "$ROOT/tests/restore/run.sh" ]]; then bad "restore render: tests/restore/run.sh is missing"
  else
    RD="$TMP/restore-shapes"; mkdir -p "$RD"
    RC=0; RLOG="$(RESTORE_RENDER_DIR="$RD" bash "$ROOT/tests/restore/run.sh" 2>&1)" || RC=$?
    nr="$(find "$RD" -name '*.restore.yaml' | wc -l | tr -d ' ')"; nl="$(find "$RD" -name '*.location.yaml' | wc -l | tr -d ' ')"
    if [[ "$RC" -ne 0 ]]; then bad "restore render: tests/restore in render-only mode failed" "$RLOG"
    elif [[ "$nr" -eq 0 ]] && grep -q '^SKIP' <<<"$RLOG"; then echo "SKIP the restore shapes: $(grep '^SKIP' <<<"$RLOG" | head -1)"
    elif [[ "$nr" != 40 || "$nl" != 20 ]]; then bad "restore render: expected 40 PostgresRestore and 20 location copies (4 shapes x 5 recovery points x 2 spec files; 2 shapes copy the location), got ${nr} and ${nl}" "$(ls "$RD")"
    else
      kc_group() {  # kc_group LABEL GLOB...: the captured objects matching the globs all pass kubeconform -strict
        local label="$1" files=() g f n
        shift
        for g in "$@"; do for f in "$RD"/$g; do [[ -f "$f" ]] && files+=("$f"); done; done
        n="${#files[@]}"
        [[ "$n" -gt 0 ]] || { bad "restore render ${label}: no object matches"; return; }
        kubeconform -strict -summary -schema-location "$SCHEMAS" "${files[@]}" >"$TMP/kc" 2>&1 && grep -q "Valid: ${n}, Invalid: 0, Errors: 0" "$TMP/kc" \
          && ok "restore render, ${label}: ${n} objects pass kubeconform -strict against the CRD schemas" || bad "restore render ${label}" "$(cat "$TMP/kc")"
      }
      kc_group "a new instance on another cluster" 'newcluster-*'
      kc_group "a new instance in another namespace of the cluster" 'othernamespace-*'
      kc_group "a new instance in the source namespace" 'samenamespace-*'
      kc_group "in place" 'inplace-*'
      kc_group "a named backup" '*-backup-*'
      for k in latest time lsn transaction; do kc_group "pitr ${k}" "*-${k}-*"; done
      kc_group "without a spec file" '*-nospec.*'
      kc_group "with a spec file (the embedded targetInstance.spec)" '*-spec.*'
      # the embedded Postgres spec is checked as well: a misspelled field in it fails
      yq '.spec.targetInstance.spec.noSuchField = 1' "$RD/newcluster-latest-spec.restore.yaml" > "$TMP/typo-restore.yaml"
      kubeconform -strict -schema-location "$SCHEMAS" "$TMP/typo-restore.yaml" >/dev/null 2>&1 \
        && bad "an unknown field in the embedded targetInstance.spec must fail the schema" \
        || ok "an unknown field in the embedded targetInstance.spec fails kubeconform -strict (the schema reaches into it)"
    fi
  fi
fi

# ---- parity: the objects the workflow scripts write inline (D69, hand-applied skip rule)
heredoc() {  # heredoc SCRIPT MARKER_LINE -> the lines between MARKER_LINE (a <<YAML line) and YAML
  awk -v m="$2" 'index($0, m) {on=1; next} on && /^YAML$/ {exit} on {print}' "$ROOT/workflows/scripts/$1"
}
expand() {  # expand FILE: the heredoc text with the shell variables of the environment
  local body; body="$(cat "$1")"
  eval "cat <<YAML
${body}
YAML"
}
parity() {  # parity LABEL KEY OBJECT_FILE: the reference template renders the same spec
  local kind name got want
  kind="$(yq '.kind' "$3")"; name="$(yq '.metadata.name' "$3")"
  yq "{\"$2\": {\"enabled\": true, \"name\": .metadata.name, \"spec\": .spec}}" "$3" > "$TMP/pv.yaml"
  want="$(yq -o=json -I=0 '.spec | sort_keys(..)' "$3")"
  got="$(helm template ref "$REF" -f "$TMP/pv.yaml" | K="$kind" yq -o=json -I=0 'select(.kind == strenv(K)) | .spec | sort_keys(..)')"
  if [[ "$got" != "$want" ]]; then bad "$1: the inline ${kind} carries a zero default" "inline:    ${want}
reference: ${got}"; return; fi
  if command -v kubeconform >/dev/null; then
    kubeconform -strict -schema-location "$SCHEMAS" "$3" >"$TMP/kc" 2>&1 || { bad "$1: kubeconform" "$(cat "$TMP/kc")"; return; }
  fi
  ok "$1: ${kind} ${name} equals the reference render and passes the CRD schema"
}
heredoc backup-instance.sh 'apply -f - >/dev/null <<YAML' > "$TMP/bk.tpl"
for TYPE in full incremental differential; do
  NAME="orders-db-${TYPE}-20260926" WF=tpg-backup-abc I=orders-db expand "$TMP/bk.tpl" > "$TMP/bk.yaml"
  parity "backup-instance.sh (${TYPE})" postgresBackup "$TMP/bk.yaml"
done
heredoc postgres-upgrade.sh 'apply -f - >/dev/null <<YAML || { ifail CREATE_FAILED; return; }' > "$TMP/pvu.tpl"
[[ -s "$TMP/pvu.tpl" ]] || bad "postgres-upgrade.sh: the PostgresVersionUpgrade heredoc was not found"
name=orders-db-upgrade WF=tpg-upgrade-abc i=orders-db TARGET=postgres-18.1 expand "$TMP/pvu.tpl" > "$TMP/pvu.yaml"
parity "postgres-upgrade.sh" postgresVersionUpgrade "$TMP/pvu.yaml"
# restore-pair.sh (tpg-restore) has no inline object: it renders the PostgresRestore and the copy of the source
# backup location through this reference chart, so tpg.prune is the one place that leaves zero defaults out
RP="$ROOT/workflows/scripts/restore-pair.sh"
[[ "$(grep -c 'helm template ref "\$REPO/helm_artifacts/instance/crd-reference"' "$RP")" -ge 1 ]] \
  && grep -q 'render_obj PostgresRestore' "$RP" && grep -q 'render_obj PostgresBackupLocation' "$RP" \
  && ok "restore-pair.sh renders the PostgresRestore and the source location copy through the reference chart" || bad "restore-pair.sh does not render through crd-reference"
! grep -qE '^kind: (PostgresRestore|PostgresBackupLocation)' "$RP" && ok "restore-pair.sh writes no PostgresRestore or PostgresBackupLocation inline" || bad "restore-pair.sh still writes an inline object"

echo
echo "crd-reference: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
