#!/usr/bin/env bash
# helm_artifacts/instance/tpg-instance rendering of the Round 12 values (design decisions D63 to D65):
#   exposure        serviceType and the Azure load balancer annotations; an empty
#                   map is never rendered (F7); instance.serviceType is refused
#   caBundle        written with enableSSL: true, and only then; enableSSL: true
#                   without a bundle fails the render
#   network policy  none renders nothing; baseline renders NetworkPolicy
#                   tpg-ingress-<instance> and CiliumNetworkPolicy
#                   tpg-egress-<instance>; a rule is rendered only for a
#                   non-empty input, and no peer list is empty (an empty peer
#                   list allows every source: F9)
#   Round 13 (D69 to D71)
#   zero defaults   highAvailability only for an HA instance (enabled true,
#                   readReplicas 1 or more), refused combinations, tpg.prune on
#                   patch file content, required fields kept, enableSSL false kept
#   schedules       PostgresBackupSchedule objects only with backup.scheduled false
#   FerretDB        PostgresFerretDocumentDB (version, read-only proxies, exposure)
#                   and its client rule on 27017
#   reference       every rendered object is what helm_artifacts/instance/crd-reference renders
#                   for the same spec (already pruned), and passes kubeconform
#                   -strict against the CRD schemas when kubeconform is installed
#   Round 14 (D78), Round 15 (D81, D84)
#   patch files     only the current file of each kind is applied; with
#                   clusters/fleet.yaml as a value file (the tpg-instances
#                   ApplicationSet) the instance's entry there decides, not the
#                   patches the inline values carry; an entry that is not
#                   {current, previous} fails the render (no migration); the
#                   postgres file holds one document per object (Postgres,
#                   PostgresBackupLocation, PostgresBackupSchedule, FerretDB), each
#                   merged into its object and winning over the chart values;
#                   fullRetentionType count or time
#   Round 23 phase 3 (the instance namespace): the release namespace is the
#                   instance namespace; the shared Secrets (ServiceAccount
#                   tpg-vso, VaultStaticSecrets regsecret and backup-storage) only
#                   from the instance with sharedSecretsOwner true, the network
#                   policies named and selected by instance, the ApplicationSet
#                   destination.namespace from instance.namespace
#   Round 23 review: the owner flag is read from the clusters/fleet.yaml value file
#                   (the synced commit) before the inline values; the FerretDB pods
#                   (app ferretdb-rw-<i>, ferretdb-ro-<i>) have their own policy pair
# Requires: helm (v3 or v4), yq (mikefarah), python3 with PyYAML; skipped without them.
# shellcheck disable=SC2015
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
for t in helm yq; do command -v "$t" >/dev/null || { echo "SKIP tests/chart: $t not installed" >&2; exit 0; }; done
python3 -c "import yaml" 2>/dev/null || { echo "SKIP tests/chart: python3 PyYAML not installed" >&2; exit 0; }
yq --version 2>&1 | grep -q mikefarah || { echo "SKIP tests/chart: yq is not mikefarah yq v4" >&2; exit 0; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { printf 'ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL %s\n' "$1"; [[ -z "${2:-}" ]] || printf '%s\n' "$2" | sed 's/^/       | /' | tail -12; FAIL=$((FAIL + 1)); }
CHART="$ROOT/helm_artifacts/instance/tpg-instance"
render() {  # render VALUES_YAML -> $OUT (rendered manifests) and $RC
  printf 'cluster: {name: c1}\ninstance: {name: i1, postgresVersion: postgres-17.6}\nbackup: {container: pg-backups-c1}\n' > "$TMP/base.yaml"
  printf '%s\n' "$1" > "$TMP/v.yaml"
  RC=0
  OUT="$(helm template i1 "$CHART" -f "$ROOT/clusters/_template/cluster.yaml" \
    -f "$ROOT/clusters/_template/instance.yaml" -f "$TMP/base.yaml" -f "$TMP/v.yaml" --namespace pg-i1 2>&1)" || RC=$?
}
pg() { yq "select(.kind == \"Postgres\") | $1" <<<"$OUT"; }
f9() {  # every NetworkPolicy ingress rule has a non-empty from, and no peer is all
        # empty selectors ({namespaceSelector: {}} alone would admit every pod of
        # every namespace); {podSelector: {}} alone is the instance namespace itself
  pycheck 'all(r.get("from") and all(p == {"podSelector": {}} or any(p.values()) for p in r["from"])
           for r in K("NetworkPolicy")["spec"]["ingress"])'
}

pycheck() {  # pycheck PYTHON_EXPR: true when the expression holds; K(kind) is the rendered object of that kind
  python3 -c '
import sys, yaml
docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
def K(kind):
    return next(d for d in docs if d.get("kind") == kind)
def N(kind, name):
    return next(d for d in docs if d.get("kind") == kind and d.get("metadata", {}).get("name") == name)
def egress(): return K("CiliumNetworkPolicy")["spec"]["egress"]
def ports(rule): return [p["port"] for p in rule["toPorts"][0]["ports"]]
sys.exit(0 if eval("(" + sys.argv[1] + ")") else 1)
' "$1" <<<"$OUT" 2>/dev/null
}

# ---- exposure
render ''
[[ "$(pg '.spec.serviceType')" == "ClusterIP" && "$(pg '.spec | has("serviceAnnotations")')" == "false" \
   && "$(pg '.spec | has("readOnlyServiceType")')" == "false" ]] \
  && ok "default: ClusterIP, no annotations, no readOnlyServiceType (existing specs unchanged)" || bad "default" "$OUT"
render 'instance: {exposure: internalLoadBalancer, internalLoadBalancerSubnet: apps-subnet, allowedSourceRanges: [10.0.0.0/8, 192.168.0.0/16]}'
pg '.spec' | yq -e '.serviceType == "LoadBalancer"
  and .serviceAnnotations["service.beta.kubernetes.io/azure-load-balancer-internal"] == "true"
  and .serviceAnnotations["service.beta.kubernetes.io/azure-load-balancer-internal-subnet"] == "apps-subnet"
  and .serviceAnnotations["service.beta.kubernetes.io/azure-allowed-ip-ranges"] == "10.0.0.0/8,192.168.0.0/16"' >/dev/null \
  && ok "internalLoadBalancer: internal annotation, subnet and allowed ranges" || bad "internal" "$(pg '.spec')"
render 'instance: {exposure: loadBalancer, serviceAnnotations: {service.beta.kubernetes.io/azure-dns-label-name: orders}, readOnlyExposure: loadBalancer}'
pg '.spec' | yq -e '.serviceType == "LoadBalancer" and .readOnlyServiceType == "LoadBalancer"
  and (.serviceAnnotations | has("service.beta.kubernetes.io/azure-load-balancer-internal") | not)
  and .serviceAnnotations["service.beta.kubernetes.io/azure-dns-label-name"] == "orders"
  and (has("readOnlyServiceAnnotations") | not)' >/dev/null \
  && ok "loadBalancer: public, extra annotations kept, no empty read-only annotations" || bad "public" "$(pg '.spec')"
render 'instance: {exposure: nodePort}'
[[ "$RC" -ne 0 ]] && grep -q "must be clusterIP, internalLoadBalancer or loadBalancer" <<<"$OUT" && ok "an unknown exposure fails the render" || bad "unknown exposure" "$OUT"
render 'instance: {serviceType: LoadBalancer}'
[[ "$RC" -ne 0 ]] && grep -q "instance.serviceType is replaced by instance.exposure" <<<"$OUT" && ok "instance.serviceType fails with the replacement named" || bad "serviceType" "$OUT"

# ---- caBundle
render 'backup: {enableSSL: true}'
[[ "$RC" -ne 0 ]] && grep -q "caBundle is empty" <<<"$OUT" && ok "enableSSL: true without caBundle fails the render" || bad "no bundle" "$OUT"
render 'backup: {enableSSL: true, caBundle: "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n"}'
pycheck 'K("PostgresBackupLocation")["spec"]["storage"]["azure"]["enableSSL"] is True and K("PostgresBackupLocation")["spec"]["storage"]["azure"]["caBundle"].startswith("-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----")' \
  && ok "enableSSL: true writes the bundle" || bad "bundle" "$(yq 'select(.kind == "PostgresBackupLocation")' <<<"$OUT")"
render 'backup: {enableSSL: false, caBundle: "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n"}'
pycheck 'K("PostgresBackupLocation")["spec"]["storage"]["azure"]["enableSSL"] is False and "caBundle" not in K("PostgresBackupLocation")["spec"]["storage"]["azure"]' \
  && ok "enableSSL: false writes no caBundle" || bad "no ca with ssl false" "$OUT"

# ---- network policy
render ''
[[ -z "$(yq 'select(.kind == "NetworkPolicy" or .kind == "CiliumNetworkPolicy") | .kind' <<<"$OUT")" ]] \
  && ok "policy none: no policy objects" || bad "none" "$OUT"
render 'network: {policy: baseline}'
[[ "$(yq 'select(.kind == "NetworkPolicy") | .spec.ingress | length' <<<"$OUT")" == "3" ]] && f9 \
  && ok "baseline: ingress rules for the namespace, the operator and metrics only, no empty peer list" || bad "baseline ingress" "$OUT"
pycheck 'any(r.get("toEntities") == ["kube-apiserver"] for r in egress())
  and any(r.get("toEntities") == ["world"] and ports(r) == ["443", "80"] for r in egress())
  and not any("toFQDNs" in r for r in egress())' \
  && ok "baseline: API server, and backup egress to any address on 443 and 80 (enableSSL false, no ACNS)" || bad "baseline egress" "$(yq 'select(.kind == "CiliumNetworkPolicy")' <<<"$OUT")"
render 'network: {policy: baseline, acns: true}
backup: {enableSSL: true, caBundle: "x"}'
pycheck 'any(r.get("toFQDNs") == [{"matchPattern": "*.blob.core.windows.net"}] and ports(r) == ["443"] for r in egress())
  and any(r.get("toPorts", [{}])[0].get("rules", {}).get("dns") == [{"matchPattern": "*"}] for r in egress())
  and not any(r.get("toEntities") == ["world"] for r in egress())' \
  && ok "ACNS: backup egress by FQDN on 443 only (enableSSL true), with the DNS proxy rule" || bad "acns" "$(yq 'select(.kind == "CiliumNetworkPolicy")' <<<"$OUT")"
render 'network: {policy: baseline, ingressFromNamespaces: [app], ingressFromPodLabels: {role: api}, ingressFromCidrs: [10.1.0.0/16], egressToCidrs: [10.2.0.0/24], egressToFqdns: [api.example.com, "*.example.org"]}
instance: {exposure: loadBalancer, allowedSourceRanges: [10.1.0.0/16]}'
pycheck 'K("NetworkPolicy")["spec"]["ingress"][3] == {"from": [
    {"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "app"}}, "podSelector": {"matchLabels": {"role": "api"}}},
    {"ipBlock": {"cidr": "10.1.0.0/16"}}, {"ipBlock": {"cidr": "168.63.129.16/32"}}],
  "ports": [{"protocol": "TCP", "port": 5432}]}' && f9 \
  && ok "client rules: namespace with pod labels, CIDR, and the Azure health probe for a load balancer" || bad "client rules" "$(yq 'select(.kind == "NetworkPolicy")' <<<"$OUT")"
pycheck 'any(r.get("toCIDR") == ["10.2.0.0/24"] for r in egress())
  and any(r.get("toFQDNs") == [{"matchName": "api.example.com"}, {"matchPattern": "*.example.org"}] for r in egress())' \
  && ok "egress rules: toCIDR and toFQDNs (matchName and matchPattern)" || bad "egress rules" "$(yq 'select(.kind == "CiliumNetworkPolicy")' <<<"$OUT")"
render 'network: {policy: baseline, ingressFromNamespaces: [], ingressFromPodLabels: {}, ingressFromCidrs: [], egressToCidrs: [], egressToFqdns: [], monitoringNamespaces: []}'
[[ "$(yq 'select(.kind == "NetworkPolicy") | .spec.ingress | length' <<<"$OUT")" == "2" ]] && f9 \
  && pycheck 'not any("toFQDNs" in r or ("toCIDR" in r and r["toCIDR"] != ["169.254.10.0/24"]) for r in egress())' \
  && ok "empty rule lists and maps render no rule at all (F9)" || bad "empty lists" "$OUT"
render 'network: {policy: baseline, ingressFromPodLabels: {role: api}}'
pycheck 'K("NetworkPolicy")["spec"]["ingress"][3]["from"] == [{"namespaceSelector": {}, "podSelector": {"matchLabels": {"role": "api"}}}]' \
  && ok "pod labels without namespaces: those pods in any namespace" || bad "labels only" "$(yq 'select(.kind == "NetworkPolicy")' <<<"$OUT")"

# ---- Round 13: zero defaults (D69)
kindspec() { yq "select(.kind == \"$1\") | .spec" <<<"$OUT"; }
render 'instance: {highAvailability: {enabled: false, readReplicas: 0}}'
[[ "$RC" -eq 0 && "$(pg '.spec | has("highAvailability")')" == "false" ]] \
  && ok "single node (false, 0): no highAvailability block (D69)" || bad "single node" "$OUT"
render 'instance: {highAvailability: {enabled: true, readReplicas: 2}}'
[[ "$(pg '.spec.highAvailability' | yq '.enabled == true and .readReplicas == 2')" == "true" ]] \
  && ok "HA: enabled true and readReplicas 2 are written" || bad "ha" "$OUT"
render 'instance: {highAvailability: {enabled: true, readReplicas: 0}}'
[[ "$RC" -ne 0 ]] && grep -q "an HA instance needs readReplicas 1 or more" <<<"$OUT" && ok "enabled true with readReplicas 0 fails the render" || bad "ha 0" "$OUT"
render 'instance: {highAvailability: {enabled: false, readReplicas: 2}}'
[[ "$RC" -ne 0 ]] && grep -q "read replicas need highAvailability.enabled true" <<<"$OUT" && ok "readReplicas without enabled fails the render" || bad "rr only" "$OUT"
# patch file content is pruned too; a required field inside a kept object stays
CHART="$TMP/tpg-instance"; cp -r "$ROOT/helm_artifacts/instance/tpg-instance" "$CHART"
printf 'kind: Postgres\nspec:\n  dataPodConfig: {tolerations: []}\n  deploymentOptions: {continuousRestoreTarget: false}\n  customConfig: {initDb: {checksum: false}}\n' > "$CHART/patches/zero.yaml"
printf 'kind: Postgres\nspec:\n  deploymentOptions: {continuousRestoreTarget: false, sourceStanzaName: pg-src-0}\n' > "$CHART/patches/keep.yaml"
render 'patches: {postgres: {current: patches/zero.yaml}}'
[[ "$(pg '.spec' | yq 'has("dataPodConfig") or has("deploymentOptions") or has("customConfig")')" == "false" ]] \
  && ok "patch content holding zero defaults is left out, with the parents it empties" || bad "patch prune" "$(pg '.spec')"
render 'patches: {postgres: {current: patches/keep.yaml}}'
[[ "$(pg '.spec.deploymentOptions' | yq '.continuousRestoreTarget == false and .sourceStanzaName == "pg-src-0"')" == "true" ]] \
  && ok "continuousRestoreTarget false is kept when deploymentOptions holds more (required by the schema)" || bad "required kept" "$(pg '.spec')"
CHART="$ROOT/helm_artifacts/instance/tpg-instance"
render 'backup: {additionalParameters: {}, forcePathStyle: false}'
pycheck 'K("PostgresBackupLocation")["spec"]["storage"]["azure"]["enableSSL"] is False
  and "forcePathStyle" not in K("PostgresBackupLocation")["spec"]["storage"]["azure"]
  and "additionalParameters" not in K("PostgresBackupLocation")["spec"]
  and K("PostgresBackupLocation")["spec"]["backupSync"] == {"enabled": True}' \
  && ok "backup location: enableSSL false kept (CRD default true), forcePathStyle false and {} left out" || bad "bl" "$(kindspec PostgresBackupLocation)"

# ---- Round 13: operator backup schedules (D70)
render 'backup: {scheduled: false, operatorSchedules: {full: "0 0 * * 0", incremental: "0 0 * * 1-6"}}'
[[ "$(yq 'select(.kind == "PostgresBackupSchedule") | (.metadata.name + " " + .spec.schedule + " " + .spec.backupTemplate.spec.type)' <<<"$OUT" | grep -v '^---' | paste -sd';')" \
   == "i1-backup-full 0 0 * * 0 full;i1-backup-incremental 0 0 * * 1-6 incremental" ]] \
  && ok "operatorSchedules: a full and an incremental PostgresBackupSchedule (sync wave 2)" || bad "schedules" "$OUT"
render 'backup: {scheduled: false, operatorSchedules: {full: "0 0 * * 0"}}'
[[ "$(yq 'select(.kind == "PostgresBackupSchedule") | .metadata.name' <<<"$OUT")" == "i1-backup-full" ]] \
  && ok "operatorSchedules without incremental: the full schedule only" || bad "full only" "$OUT"
render 'backup: {operatorSchedules: {full: "0 0 * * 0"}}'
[[ "$RC" -ne 0 ]] && grep -q "needs backup.scheduled: false" <<<"$OUT" && ok "operatorSchedules while the CronWorkflows still back up: refused" || bad "both" "$OUT"
render 'backup: {scheduled: false, operatorSchedules: {full: "weekly"}}'
[[ "$RC" -ne 0 ]] && grep -q "is not a cron schedule of 5 fields" <<<"$OUT" && ok "a schedule that is not cron fails the render" || bad "cron" "$OUT"
render ''
[[ -z "$(yq 'select(.kind == "PostgresBackupSchedule") | .kind' <<<"$OUT")" ]] && ok "no operatorSchedules: no PostgresBackupSchedule" || bad "none" "$OUT"

# ---- Round 13: FerretDB (D71)
render 'ferret: {enabled: true}'
[[ "$(kindspec PostgresFerretDocumentDB | yq '.readWrite.replicas == 1 and (has("readOnly") | not)
   and .postgres.connectionDetails.readWrite.secretName == "i1-app-user-db-secret" and .service.serviceType == "ClusterIP"
   and (.service | has("serviceAnnotations") | not)')" == "true" ]] \
  && ok "ferret: one read-write proxy, no readOnly section, the operator Secret by default, ClusterIP" || bad "ferret" "$OUT"
render 'instance: {postgresVersion: postgres-17.4}
ferret: {enabled: true}'
[[ "$RC" -ne 0 ]] && grep -q "needs Postgres 17.5 or later" <<<"$OUT" && ok "ferret below Postgres 17.5 fails the render" || bad "ferret version" "$OUT"
render 'instance: {highAvailability: {enabled: false, readReplicas: 0}}
ferret: {enabled: true, readOnlyReplicas: 1}'
[[ "$RC" -ne 0 ]] && grep -q "needs highAvailability" <<<"$OUT" && ok "read-only proxies on a single node fail the render" || bad "ferret ro" "$OUT"
render 'instance: {highAvailability: {enabled: true, readReplicas: 1}, allowedSourceRanges: [10.0.0.0/8]}
ferret: {enabled: true, replicas: 2, readOnlyReplicas: 1, exposure: internalLoadBalancer, readOnlySecretName: ro-secret}'
[[ "$(kindspec PostgresFerretDocumentDB | yq '.readWrite.replicas == 2 and .readOnly.replicas == 1
   and .postgres.connectionDetails.readOnly.secretName == "ro-secret" and .service.readOnlyServiceType == "LoadBalancer"
   and .service.serviceAnnotations["service.beta.kubernetes.io/azure-load-balancer-internal"] == "true"
   and .service.serviceAnnotations["service.beta.kubernetes.io/azure-allowed-ip-ranges"] == "10.0.0.0/8"')" == "true" ]] \
  && ok "ferret: read-only proxies with their Secret, internal load balancers with the instance's ranges" || bad "ferret ha" "$OUT"
render 'network: {policy: baseline, ingressFromNamespaces: [app]}
ferret: {enabled: true, exposure: loadBalancer}'
pycheck 'N("NetworkPolicy", "tpg-ingress-ferretdb-i1")["spec"]["ingress"][2] == {"from": [
    {"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "app"}}}, {"ipBlock": {"cidr": "168.63.129.16/32"}}],
  "ports": [{"protocol": "TCP", "port": 27017}]}' \
  && ok "ferret with baseline: 27017 from the same clients, with the probe address for its load balancer (Round 23: in the policy of the FerretDB pods)" || bad "ferret netpol" "$(yq 'select(.kind == "NetworkPolicy")' <<<"$OUT")"
render 'network: {policy: baseline, ingressFromNamespaces: [app]}'
pycheck 'not any(p["port"] == 27017 for r in K("NetworkPolicy")["spec"]["ingress"] for p in r.get("ports", []))' \
  && ok "no FerretDB: no 27017 rule" || bad "no ferret rule" "$OUT"

# ---- Round 13: the reference chart renders the same objects (already pruned) and they pass the CRD schemas
render 'instance: {highAvailability: {enabled: true, readReplicas: 1}}
backup: {scheduled: false, operatorSchedules: {full: "0 0 * * 0", incremental: "0 0 * * 1-6"}}
ferret: {enabled: true, readOnlyReplicas: 1}'
same=1
for k in Postgres PostgresBackupLocation PostgresBackupSchedule PostgresFerretDocumentDB; do
  key="$(python3 -c 'import sys; k=sys.argv[1]; print(k[0].lower() + k[1:])' "$k")"
  K="$k" yq 'select(.kind == strenv(K)) | {"'"$key"'": {"enabled": true, "name": .metadata.name, "spec": .spec}}' <<<"$OUT" | head -n 200 > "$TMP/ref-$k.yaml"
  [[ "$k" != PostgresBackupSchedule ]] || K="$k" yq 'select(.kind == strenv(K) and .metadata.name == "i1-backup-full")
    | {"postgresBackupSchedule": {"enabled": true, "name": .metadata.name, "spec": .spec}}' <<<"$OUT" > "$TMP/ref-$k.yaml"
  want="$(K="$k" yq 'select(.kind == strenv(K)) | .spec' <<<"$OUT" | head -n 400)"
  [[ "$k" != PostgresBackupSchedule ]] || want="$(yq 'select(.metadata.name == "i1-backup-full") | .spec' <<<"$OUT")"
  got="$(helm template ref "$ROOT/helm_artifacts/instance/crd-reference" -f "$TMP/ref-$k.yaml" | K="$k" yq 'select(.kind == strenv(K)) | .spec')"
  [[ "$got" == "$want" ]] || { same=0; bad "reference $k" "$(diff <(echo "$want") <(echo "$got"))"; }
done
[[ "$same" -eq 1 ]] && ok "Postgres, backup location, schedule and FerretDB are what helm_artifacts/instance/crd-reference renders (nothing left to prune)"
if command -v kubeconform >/dev/null; then
  yq 'select(.apiVersion == "sql.tanzu.vmware.com/v1")' <<<"$OUT" > "$TMP/sql.yaml"
  kc="$(kubeconform -strict -summary -schema-location "$ROOT/helm_artifacts/instance/crd-reference/schemas/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json" "$TMP/sql.yaml" 2>&1)" \
    && grep -q "Valid: 5, Invalid: 0, Errors: 0, Skipped: 0" <<<"$kc" \
    && ok "the 5 rendered sql.tanzu.vmware.com objects pass kubeconform -strict against the live CRD schemas" || bad "kubeconform" "$kc"
else
  echo "skip kubeconform (not installed)"
fi


# ---- valuesOverride (tpg-restore) wins over a values patch file that turns FerretDB on
cp -r "$ROOT/helm_artifacts/instance/tpg-instance" "$TMP/chart-copy"
printf 'ferret: {enabled: true}\n' > "$TMP/chart-copy/patches/t-ferret-on.yaml"
CHART="$TMP/chart-copy"
render 'patches: {postgresValues: {current: patches/t-ferret-on.yaml}}'
[[ "$RC" -eq 0 ]] && grep -q 'kind: PostgresFerretDocumentDB' <<<"$OUT" && ok "a values patch turns FerretDB on" || bad "values patch ferret" "$OUT"
render 'patches: {postgresValues: {current: patches/t-ferret-on.yaml}}
valuesOverride: {ferret: {enabled: false}}'
[[ "$RC" -eq 0 ]] && ! grep -q 'kind: PostgresFerretDocumentDB' <<<"$OUT" \
  && ok "valuesOverride (a restored copy) wins over the values patch: no FerretDB" || bad "valuesOverride" "$OUT"
CHART="$ROOT/helm_artifacts/instance/tpg-instance"

# ---- Round 14 and 15: the current patch file, read from clusters/fleet.yaml when it is a value file
cp -r "$ROOT/helm_artifacts/instance/tpg-instance" "$TMP/chart-r14"
CHART="$TMP/chart-r14"
printf 'backup: {fullRetention: 11}\n' > "$CHART/patches/cur-aaaaa.yaml"
printf 'backup: {fullRetention: 22}\n' > "$CHART/patches/prev-bbbbb.yaml"
printf 'backup: {fullRetention: 33}\n' > "$CHART/patches/inline-ccccc.yaml"
retention() { yq 'select(.kind == "PostgresBackupLocation") | .spec.retentionPolicy.fullRetention.number' <<<"$OUT"; }
render 'patches: {postgresValues: {current: patches/cur-aaaaa.yaml, previous: {path: patches/prev-bbbbb.yaml, commit: abc}}}'
[[ "$RC" -eq 0 && "$(retention)" == 11 ]] && ok "only current is applied; previous is a record" || bad "current" "$OUT"
render 'patches: {postgresValues: [patches/cur-aaaaa.yaml]}'
[[ "$RC" -ne 0 ]] && grep -q "patches.postgresValues of i1 must be {current: <file>, previous: {path, commit}} (a fleet repository written before Round 15: start a new one)" <<<"$OUT" \
  && ok "a list (the Round 11 shape) fails the render: no migration" || bad "list" "$OUT"
render 'patches: {values: {current: patches/cur-aaaaa.yaml}}'
[[ "$RC" -eq 0 && "$(retention)" == 4 ]] && ok "the Round 14 key patches.values is not read any more (postgresValues)" || bad "old key" "$OUT"
render 'patches: {postgresValues: {current: patches/inline-ccccc.yaml}}
clusters:
  c1:
    instances:
      i1:
        patches: {postgresValues: {current: patches/cur-aaaaa.yaml}}'
[[ "$RC" -eq 0 && "$(retention)" == 11 ]] \
  && ok "with clusters/fleet.yaml as a value file its entry wins (a sync at a pull request commit sees the branch)" || bad "fleet file" "$OUT"
render 'patches: {postgresValues: {current: patches/inline-ccccc.yaml}}
clusters:
  c1:
    instances:
      i1: {instance: {postgresVersion: postgres-17.6}}'
[[ "$RC" -eq 0 && "$(retention)" == 4 ]] \
  && ok "an entry without patches there: no patch file, whatever the inline values say" || bad "fleet file no patches" "$OUT"
render 'clusters:
  c1:
    instances:
      i1:
        patches: {postgresValues: {previous: {path: patches/cur-aaaaa.yaml, commit: abc}}}'
[[ "$RC" -eq 0 && "$(retention)" == 4 ]] && ok "a cleared patch (previous only) renders the chart values" || bad "cleared" "$OUT"
# Round 15: one multi-document postgres file, each document merged into its object
cat > "$CHART/patches/multi-ddddd.yaml" <<'YAML'
apiVersion: sql.tanzu.vmware.com/v1
kind: Postgres
spec:
  logLevel: Debug
---
apiVersion: sql.tanzu.vmware.com/v1
kind: PostgresBackupLocation
spec:
  retentionPolicy:
    fullRetention: {number: 12}
---
apiVersion: sql.tanzu.vmware.com/v1
kind: PostgresBackupSchedule
metadata: {name: i1-backup-full}
spec:
  schedule: "0 3 * * 6"
YAML
render 'patches: {postgres: {current: patches/multi-ddddd.yaml}}
backup: {scheduled: false, fullRetention: 6, operatorSchedules: {full: "0 1 * * 0", incremental: "0 */6 * * *"}}'
[[ "$RC" -eq 0 && "$(retention)" == 12 ]] && [[ "$(pg '.spec.logLevel')" == Debug ]] \
  && [[ "$(yq 'select(.kind == "PostgresBackupSchedule" and .metadata.name == "i1-backup-full") | .spec.schedule' <<<"$OUT")" == "0 3 * * 6" ]] \
  && [[ "$(yq 'select(.kind == "PostgresBackupSchedule" and .metadata.name == "i1-backup-incremental") | .spec.schedule' <<<"$OUT")" == "0 */6 * * *" ]] \
  && ok "1c: each document patches its object; the kind patch wins over backup.fullRetention (12 over 6); the incremental schedule keeps its value" \
  || bad "multi-document" "$OUT"
printf 'apiVersion: v1\nkind: ConfigMap\nmetadata: {name: x}\n' > "$CHART/patches/bad-eeeee.yaml"
render 'patches: {postgres: {current: patches/bad-eeeee.yaml}}'
[[ "$RC" -ne 0 ]] && grep -q 'kind "ConfigMap" is not a kind the tpg-instance chart renders' <<<"$OUT" \
  && ok "a document of another kind fails the render" || bad "bad kind" "$OUT"
# Round 22: overlay files (initial deployment) are read before the patch files, which win
printf 'backup: {fullRetention: 5}\n' > "$CHART/overlays/ov-aaaaa.yaml"
printf 'backup: {fullRetention: 7}\n' > "$CHART/patches/pt-bbbbb.yaml"
render 'clusters:
  c1:
    instances:
      i1:
        overlays: {postgresValues: {current: overlays/ov-aaaaa.yaml}}'
[[ "$RC" -eq 0 && "$(retention)" == 5 ]] && ok "22: the current values overlay is applied (overlays.postgresValues)" || bad "overlay values" "$OUT"
render 'clusters:
  c1:
    instances:
      i1:
        overlays: {postgresValues: {current: overlays/ov-aaaaa.yaml}}
        patches: {postgresValues: {current: patches/pt-bbbbb.yaml}}'
[[ "$RC" -eq 0 && "$(retention)" == 7 ]] && ok "22: a values patch stacks on top of the overlay and wins" || bad "overlay then patch" "$OUT"
render 'clusters:
  c1:
    instances:
      i1:
        overlays: {postgresValues: [overlays/ov-aaaaa.yaml]}'
[[ "$RC" -ne 0 ]] && grep -q "overlays.postgresValues of i1 must be {current" <<<"$OUT" \
  && ok "22: an overlays entry that is not {current, previous} fails the render" || bad "overlay shape" "$OUT"
cat > "$CHART/overlays/pgov-ccccc.yaml" <<'YAML'
apiVersion: sql.tanzu.vmware.com/v1
kind: Postgres
spec:
  logLevel: Debug
  sharedMemorySize: 1Gi
---
apiVersion: sql.tanzu.vmware.com/v1
kind: PostgresBackupLocation
spec:
  retentionPolicy:
    fullRetention: {number: 9}
YAML
cat > "$CHART/patches/pgpt-ddddd.yaml" <<'YAML'
apiVersion: sql.tanzu.vmware.com/v1
kind: Postgres
spec:
  logLevel: Info
YAML
render 'clusters:
  c1:
    instances:
      i1:
        overlays: {postgres: {current: overlays/pgov-ccccc.yaml}}
        patches: {postgres: {current: patches/pgpt-ddddd.yaml}}'
[[ "$RC" -eq 0 && "$(pg '.spec.logLevel')" == Info && "$(pg '.spec.sharedMemorySize')" == 1Gi && "$(retention)" == 9 ]] \
  && ok "22: postgres overlay and patch documents merge per object: the patch wins where both set a field, the overlay's other fields stay" \
  || bad "postgres overlay then patch" "$OUT"
# Round 22: backup repository path and the skip-initial-backup annotation
blpath() { yq 'select(.kind == "PostgresBackupLocation") | .spec.storage.azure.repoPath' <<<"$OUT"; }
render ''
[[ "$RC" -eq 0 && "$(blpath)" == "/pg-i1/i1" ]] && ok "22: without backup.repoPath the path is /<namespace>/<instance>" || bad "repoPath default" "$OUT"
render 'backup: {repoPath: /pg-i1}'
[[ "$RC" -eq 0 && "$(blpath)" == "/pg-i1" ]] && ok "22: backup.repoPath pins the old /<namespace> of an instance created before Round 22" || bad "repoPath pinned" "$OUT"
render 'backup: {repoPath: pg-i1/i1}'
[[ "$RC" -ne 0 ]] && grep -q 'backup.repoPath "pg-i1/i1" must start with /' <<<"$OUT" && ok "22: a repoPath without the leading slash fails the render" || bad "repoPath slash" "$OUT"
two="$(for n in i1 i2; do printf 'cluster: {name: c1}\ninstance: {name: %s, postgresVersion: postgres-17.6}\nbackup: {container: pg-backups-c1}\n' "$n" > "$TMP/two-$n.yaml"
  helm template "$n" "$CHART" -f "$ROOT/clusters/_template/cluster.yaml" -f "$ROOT/clusters/_template/instance.yaml" -f "$TMP/two-$n.yaml" --namespace "pg-$n" \
    | yq 'select(.kind == "PostgresBackupLocation") | .spec.storage.azure.repoPath'; done | sort | uniq -d)"
[[ -z "$two" ]] && ok "22: two instances never share a repository path" || bad "repoPath shared" "$two"
# the same instance name in two namespaces would still differ by namespace
render ''
[[ "$RC" -eq 0 && "$(pg '.metadata.annotations | has("sql.tanzu.vmware.com/skip-initial-backup")')" == false ]] \
  && ok "22: disableInitialBackup false (default): no skip-initial-backup annotation" || bad "annotation default" "$OUT"
render 'instance: {disableInitialBackup: true}'
[[ "$RC" -eq 0 && "$(pg '.metadata.annotations["sql.tanzu.vmware.com/skip-initial-backup"]')" == "true" ]] \
  && ok "22: disableInitialBackup true writes sql.tanzu.vmware.com/skip-initial-backup: \"true\" on the Postgres object" || bad "annotation true" "$OUT"
render 'backup: {fullRetention: 30, fullRetentionType: time}'
[[ "$RC" -eq 0 && "$(yq 'select(.kind == "PostgresBackupLocation") | .spec.retentionPolicy.fullRetention.type' <<<"$OUT")" == time && "$(retention)" == 30 ]] \
  && ok "1g: fullRetentionType time is rendered (retentionDays is gone)" || bad "retention type" "$OUT"
render 'backup: {fullRetentionType: days}'
[[ "$RC" -ne 0 ]] && ok "fullRetentionType other than count or time fails the render" || bad "retention type bad" "$OUT"
CHART="$ROOT/helm_artifacts/instance/tpg-instance"

# ---- Round 23: the values the tpg-instances ApplicationSet builds. The valueFiles list and the
# `values` template are read from bootstrap/appsets/tpg-instances.yaml; the template is evaluated
# with helm's tpl (sprig, as the ApplicationSet controller has it) against a context made like the
# generator's: name, instance.{name,values} and the clusters of fleet.yaml
APPSET="$ROOT/bootstrap/appsets/tpg-instances.yaml"
AS="$TMP/appset"; mkdir -p "$AS/helm_artifacts/instance" "$AS/clusters" "$AS/tplchart/templates"
cp -r "$ROOT/helm_artifacts/instance/tpg-instance" "$AS/helm_artifacts/instance/"; cp -r "$ROOT/clusters/_template" "$AS/clusters/"
printf 'apiVersion: v2\nname: tplvalues\nversion: 0.0.0\n' > "$AS/tplchart/Chart.yaml"
printf '%s\n' '{{ tpl .Values.tmpl .Values.ctx }}' > "$AS/tplchart/templates/values.yaml"
appset_render() {  # appset_render ENTRY_YAML: the chart rendered for clusters.c1.instances.i1 = ENTRY -> $OUT, $RC
  local fleet f
  printf 'clusters:\n  c1:\n    operator: {version: v4.5.0}\n    instances:\n      i1: %s\n' "$1" > "$AS/clusters/fleet.yaml"
  fleet="$(yq -o=json -I=0 '.' "$AS/clusters/fleet.yaml")"
  jq -n --arg t "$(yq -r '.spec.template.spec.source.helm.values' "$APPSET")" --argjson f "$fleet" \
    '{tmpl: $t, ctx: {name: "c1", instance: {name: "i1", values: $f.clusters.c1.instances.i1}, clusters: $f.clusters}}' > "$AS/tpl-values.json"
  RC=0
  helm template tplvalues "$AS/tplchart" -f "$AS/tpl-values.json" 2>&1 | yq '.' > "$AS/values.yaml" || RC=$?
  [[ "$RC" -eq 0 && -s "$AS/values.yaml" ]] || { OUT="the appset values template did not evaluate: $(cat "$AS/values.yaml" 2>/dev/null)"; RC=1; return; }
  local args=()
  while IFS= read -r f; do args+=(-f "$AS/helm_artifacts/instance/tpg-instance/$f"); done < <(yq -r '.spec.template.spec.source.helm.valueFiles[]' "$APPSET")
  OUT="$(helm template i1 "$AS/helm_artifacts/instance/tpg-instance" "${args[@]}" -f "$AS/values.yaml" --namespace pg-i1 2>&1)" || RC=$?
}
skip_ann='sql.tanzu.vmware.com/skip-initial-backup'
appset_render '{instance: {postgresVersion: postgres-17.6, disableInitialBackup: true}}'
[[ "$RC" -eq 0 && "$(yq '.instance.name' "$AS/values.yaml")" == i1 && "$(pg ".metadata.annotations[\"$skip_ann\"]")" == "true" ]] \
  && ok "23: ApplicationSet values with instance.disableInitialBackup true: the Postgres object carries $skip_ann: \"true\"" || bad "appset annotation true" "$OUT"
appset_render '{instance: {postgresVersion: postgres-17.6, disableInitialBackup: false}}'
[[ "$RC" -eq 0 && "$(pg ".metadata.annotations | has(\"$skip_ann\")")" == false ]] \
  && ok "23: ApplicationSet values with instance.disableInitialBackup false: no skip-initial-backup annotation" || bad "appset annotation false" "$OUT"
appset_render '{instance: {postgresVersion: postgres-17.6}}'
[[ "$RC" -eq 0 && "$(pg ".metadata.annotations | has(\"$skip_ann\")")" == false ]] \
  && ok "23: ApplicationSet values without the key (and the chart default false): no skip-initial-backup annotation" || bad "appset annotation absent" "$OUT"

# ---- Round 23 phase 3: the instance namespace (locked decision 8). The chart renders in the
# namespace Argo CD gives it (.Release.Namespace = instance.namespace, default pg-<instance>);
# instances may share a namespace, and then the namespace-scoped objects with a fixed name are
# rendered once: the ServiceAccount tpg-vso and the VaultStaticSecrets regsecret and
# backup-storage by the owner (instance.sharedSecretsOwner, default true) only, and the network
# policies carry the instance name and select the pods of their instance by the
# postgres-instance label
render_ns() {  # render_ns INSTANCE NAMESPACE [VALUES_YAML] -> $OUT, $RC
  printf 'cluster: {name: c1}\ninstance: {name: %s, postgresVersion: postgres-17.6}\nbackup: {container: pg-backups-c1}\n' "$1" > "$TMP/ns-$1.yaml"
  printf '%s\n' "${3:-}" > "$TMP/ns-v-$1.yaml"
  RC=0
  OUT="$(helm template "$1" "$CHART" -f "$ROOT/clusters/_template/cluster.yaml" -f "$ROOT/clusters/_template/instance.yaml" \
    -f "$TMP/ns-$1.yaml" -f "$TMP/ns-v-$1.yaml" --namespace "$2" 2>&1)" || RC=$?
}
names() { yq -r '.kind + "/" + .metadata.name' <<<"$OUT" | grep -E '^[A-Za-z]+/' | sort; }
render_ns i1 pg-i1 'network: {policy: baseline}'
[[ "$RC" -eq 0 && "$(names | grep -c -E '^(ServiceAccount/tpg-vso|VaultStaticSecret/(regsecret|backup-storage))$')" == 3 ]] \
  && ok "23: by default (sharedSecretsOwner true) the instance renders the ServiceAccount tpg-vso and the VaultStaticSecrets regsecret and backup-storage" || bad "owner default" "$OUT"
render_ns i1 pg-i1 'instance: {sharedSecretsOwner: true}
network: {policy: baseline}'
[[ "$RC" -eq 0 && "$(names | grep -c -E '^(ServiceAccount/tpg-vso|VaultStaticSecret/(regsecret|backup-storage))$')" == 3 ]] \
  && ok "23: sharedSecretsOwner true renders them as well" || bad "owner true" "$OUT"
pycheck 'K("NetworkPolicy")["metadata"]["name"] == "tpg-ingress-i1" and K("CiliumNetworkPolicy")["metadata"]["name"] == "tpg-egress-i1"' \
  && ok "23: the network policies are named tpg-ingress-<instance> and tpg-egress-<instance>" || bad "policy names" "$(names)"
pycheck 'K("NetworkPolicy")["spec"]["podSelector"] == {"matchLabels": {"postgres-instance": "i1"}}
  and K("CiliumNetworkPolicy")["spec"]["endpointSelector"] == {"matchLabels": {"postgres-instance": "i1"}}' \
  && ok "23: both policies select the pods of the instance by the postgres-instance label (not every pod of the namespace)" \
  || bad "policy selectors" "$(yq 'select(.kind == "NetworkPolicy" or .kind == "CiliumNetworkPolicy") | .spec | pick(["podSelector", "endpointSelector"])' <<<"$OUT")"
render_ns i2 shared 'instance: {sharedSecretsOwner: false}
network: {policy: baseline}'
[[ "$RC" -eq 0 ]] && ! names | grep -qE '^(ServiceAccount|VaultStaticSecret)/' \
  && ok "23: sharedSecretsOwner false: no ServiceAccount and no VaultStaticSecret is rendered" || bad "owner false" "$OUT"
pycheck 'any(r.get("toEndpoints") == [{"matchLabels": {"k8s:io.kubernetes.pod.namespace": "shared"}},
  {"matchLabels": {"k8s:io.kubernetes.pod.namespace": "tanzu-postgres-operator"}}] for r in egress())' \
  && ok "23: the egress rule for the own namespace names the release namespace, not pg-<instance>" || bad "egress namespace" "$(yq 'select(.kind == "CiliumNetworkPolicy")' <<<"$OUT")"
[[ "$(yq 'select(.kind == "PostgresBackupLocation") | .spec.storage.azure.repoPath' <<<"$OUT")" == "/shared/i2" ]] \
  && ok "23: repoPath default /<namespace>/<instance> uses the real namespace" || bad "repoPath in shared" "$OUT"
# the pair in one namespace: every kind/name once, the shared objects from the owner only
render_ns i1 shared 'network: {policy: baseline}'; own="$OUT"; own_rc="$RC"
render_ns i2 shared 'instance: {sharedSecretsOwner: false}
network: {policy: baseline}'; nonown="$OUT"; non_rc="$RC"
pair="$(printf '%s\n---\n%s\n' "$own" "$nonown")"
[[ "$own_rc" -eq 0 && "$non_rc" -eq 0 && -z "$(yq -r '.kind + "/" + .metadata.name' <<<"$pair" | grep -E '^[A-Za-z]+/' | sort | uniq -d)" ]] \
  && ok "23: two instances in one namespace render distinct objects: no kind/name twice" || bad "pair distinct" "$(yq -r '.kind + "/" + .metadata.name' <<<"$pair" | sort | uniq -c)"
[[ "$(yq -r '.kind + "/" + .metadata.name' <<<"$pair" | grep -c -E '^(ServiceAccount/tpg-vso|VaultStaticSecret/(regsecret|backup-storage))$')" == 3 ]] \
  && ok "23: exactly one of the two renders the shared Secrets (the owner)" || bad "pair one owner" "$(yq -r '.kind + "/" + .metadata.name' <<<"$pair" | sort | uniq -c)"
render_ns i1 pg-other 'instance: {namespace: pg-i1}'
[[ "$RC" -ne 0 ]] && grep -q 'instance.namespace "pg-i1" differs from the release namespace "pg-other"' <<<"$OUT" \
  && ok "23: instance.namespace that differs from the release namespace fails the render" || bad "namespace mismatch" "$OUT"
render_ns i1 pg-i1 'instance: {namespace: pg-i1}'
[[ "$RC" -eq 0 ]] && ok "23: instance.namespace equal to the release namespace renders" || bad "namespace equal" "$OUT"
render_ns i1 pg-i1 'instance: {sharedSecretsOwner: maybe}'
[[ "$RC" -ne 0 ]] && grep -q 'instance.sharedSecretsOwner "maybe" must be true or false' <<<"$OUT" \
  && ok "23: sharedSecretsOwner other than true or false fails the render" || bad "owner invalid" "$OUT"
# the ApplicationSet: destination.namespace from the entry, owner flag passed through its values
appset_dest() {  # appset_dest ENTRY_YAML -> the destination namespace the template builds
  local fleet
  printf 'clusters:\n  c1:\n    instances:\n      i1: %s\n' "$1" > "$AS/clusters/fleet.yaml"
  fleet="$(yq -o=json -I=0 '.' "$AS/clusters/fleet.yaml")"
  jq -n --arg t "dest: $(yq -r '.spec.template.spec.destination.namespace' "$APPSET")" --argjson f "$fleet" \
    '{tmpl: $t, ctx: {name: "c1", instance: {name: "i1", values: $f.clusters.c1.instances.i1}, clusters: $f.clusters}}' > "$AS/tpl-dest.json"
  helm template tplvalues "$AS/tplchart" -f "$AS/tpl-dest.json" 2>&1 | yq '.dest' | tr -d '[:space:]'
}
[[ "$(appset_dest '{instance: {postgresVersion: postgres-17.6}}')" == "pg-i1" ]] \
  && ok "23: ApplicationSet destination.namespace defaults to pg-<instance>" || bad "appset dest default" "$(appset_dest '{instance: {postgresVersion: postgres-17.6}}')"
[[ "$(appset_dest '{instance: {postgresVersion: postgres-17.6, namespace: team-db}}')" == "team-db" ]] \
  && ok "23: ApplicationSet destination.namespace is the entry's instance.namespace" || bad "appset dest explicit" "$(appset_dest '{instance: {postgresVersion: postgres-17.6, namespace: team-db}}')"
appset_render '{instance: {postgresVersion: postgres-17.6, namespace: pg-i1, sharedSecretsOwner: false}}'
[[ "$RC" -eq 0 ]] && ! names | grep -qE '^(ServiceAccount|VaultStaticSecret)/' \
  && ok "23: ApplicationSet values pass instance.sharedSecretsOwner false to the chart: no shared Secrets" || bad "appset non-owner" "$OUT"
appset_render '{instance: {postgresVersion: postgres-17.6, namespace: pg-i1}}'
[[ "$RC" -eq 0 && "$(names | grep -c -E '^(ServiceAccount/tpg-vso|VaultStaticSecret/(regsecret|backup-storage))$')" == 3 ]] \
  && ok "23: ApplicationSet values without the flag: the instance owns the shared Secrets" || bad "appset owner" "$OUT"

# ---- Round 23 review: the owner flag follows the fleet.yaml value file at the synced revision, not the inline values
# The tpg-instances ApplicationSet builds the inline values from the fleet branch and refreshes them
# asynchronously; tpg-delete-instance syncs the successor at the commit that moved the flag, so the file at that
# commit decides (the way the patch records are read). Without the file (a render by hand) the inline value is used.
render_fleet() {  # render_fleet INSTANCE NAMESPACE FLEET_ENTRIES_YAML INLINE_VALUES_YAML -> $OUT, $RC (fleet.yaml as a value file, like the ApplicationSet)
  printf 'clusters:\n  c1:\n    instances:\n%s\n' "$3" > "$TMP/fl-fleet.yaml"
  printf 'cluster: {name: c1}\ninstance: {name: %s, postgresVersion: postgres-17.6}\nbackup: {container: pg-backups-c1}\n' "$1" > "$TMP/fl-$1.yaml"
  printf '%s\n' "$4" > "$TMP/fl-v-$1.yaml"
  RC=0
  OUT="$(helm template "$1" "$CHART" -f "$ROOT/clusters/_template/cluster.yaml" -f "$ROOT/clusters/_template/instance.yaml" \
    -f "$TMP/fl-fleet.yaml" -f "$TMP/fl-$1.yaml" -f "$TMP/fl-v-$1.yaml" --namespace "$2" 2>&1)" || RC=$?
}
FLEET_PAIR='      i1: {instance: {namespace: shared, postgresVersion: postgres-17.6}}
      i2: {instance: {namespace: shared, sharedSecretsOwner: false, postgresVersion: postgres-17.6}}'
# the successor of a hand-over: the file (rev1) says owner, the inline values (the old main) still say false
render_fleet i1 shared "$FLEET_PAIR" 'instance: {namespace: shared, sharedSecretsOwner: false}'
[[ "$RC" -eq 0 && "$(names | grep -c -E '^(ServiceAccount/tpg-vso|VaultStaticSecret/(regsecret|backup-storage))$')" == 3 ]] \
  && ok "23 review: the successor renders the shared Secrets when fleet.yaml at the synced commit makes it the owner, whatever the stale inline values say" || bad "race successor" "$(names)"
# the old owner: the file says false, the inline values (the old main) still say owner
render_fleet i2 shared "$FLEET_PAIR" 'instance: {namespace: shared, sharedSecretsOwner: true}'
[[ "$RC" -eq 0 ]] && ! names | grep -qE '^(ServiceAccount|VaultStaticSecret)/' \
  && ok "23 review: the old owner stops rendering them when fleet.yaml at the synced commit says false, whatever the inline values say" || bad "race old owner" "$(names)"
# an entry without the key owns them (the default), also against an inline false
render_fleet i1 shared '      i1: {instance: {namespace: shared, postgresVersion: postgres-17.6}}' 'instance: {sharedSecretsOwner: false}'
[[ "$RC" -eq 0 && "$(names | grep -c -E '^(ServiceAccount/tpg-vso|VaultStaticSecret/(regsecret|backup-storage))$')" == 3 ]] \
  && ok "23 review: an entry in fleet.yaml without sharedSecretsOwner is an owner" || bad "race default" "$(names)"
# an instance that is not in the file (a render by hand with another fleet.yaml): the inline value
render_fleet i9 shared "$FLEET_PAIR" 'instance: {namespace: shared, sharedSecretsOwner: false}'
[[ "$RC" -eq 0 ]] && ! names | grep -qE '^(ServiceAccount|VaultStaticSecret)/' \
  && ok "23 review: an instance with no entry in the fleet.yaml value file falls back to the inline value" || bad "race fallback" "$(names)"
render_fleet i1 shared '      i1: {instance: {namespace: shared, sharedSecretsOwner: maybe, postgresVersion: postgres-17.6}}' ''
[[ "$RC" -ne 0 ]] && grep -q 'instance.sharedSecretsOwner "maybe" must be true or false' <<<"$OUT" \
  && ok "23 review: a sharedSecretsOwner in fleet.yaml that is not true or false fails the render" || bad "race invalid" "$OUT"

# ---- Round 23 review: the FerretDB pods have their own policy pair (they lack the postgres-instance label)
render_ns i1 pg-i1 'network: {policy: baseline, ingressFromNamespaces: [app], egressToCidrs: [10.9.0.0/16]}
ferret: {enabled: true}'
pols="$(yq -r 'select(.kind == "NetworkPolicy" or .kind == "CiliumNetworkPolicy") | .metadata.name' <<<"$OUT" | grep '^tpg-' | sort | paste -sd,)"
[[ "$RC" -eq 0 && "$pols" == "tpg-egress-ferretdb-i1,tpg-egress-i1,tpg-ingress-ferretdb-i1,tpg-ingress-i1" ]] \
  && ok "23 review: with FerretDB there are two more policies: tpg-ingress-ferretdb-<instance> and tpg-egress-ferretdb-<instance>" || bad "ferret policy names" "$pols $OUT"
pycheck 'N("NetworkPolicy", "tpg-ingress-ferretdb-i1")["spec"]["podSelector"] == {"matchExpressions": [{"key": "app", "operator": "In", "values": ["ferretdb-rw-i1", "ferretdb-ro-i1"]}]}
  and N("CiliumNetworkPolicy", "tpg-egress-ferretdb-i1")["spec"]["endpointSelector"] == {"matchExpressions": [{"key": "app", "operator": "In", "values": ["ferretdb-rw-i1", "ferretdb-ro-i1"]}]}' \
  && ok "23 review: they select the FerretDB pods: app in (ferretdb-rw-<instance>, ferretdb-ro-<instance>)" || bad "ferret selector" "$(yq 'select(.kind == "NetworkPolicy" or .kind == "CiliumNetworkPolicy") | .spec | pick(["podSelector", "endpointSelector"])' <<<"$OUT")"
pycheck '[r for r in N("NetworkPolicy", "tpg-ingress-ferretdb-i1")["spec"]["ingress"]] == [
    {"from": [{"podSelector": {}}]},
    {"from": [{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "tanzu-postgres-operator"}}}]},
    {"from": [{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "app"}}}], "ports": [{"protocol": "TCP", "port": 27017}]}]
  and N("NetworkPolicy", "tpg-ingress-ferretdb-i1")["spec"]["policyTypes"] == ["Ingress"]' \
  && ok "23 review: the FerretDB ingress policy denies by default and allows the namespace, the operator and 27017 from the clients" || bad "ferret ingress" "$(yq 'select(.metadata.name == "tpg-ingress-ferretdb-i1")' <<<"$OUT")"
pycheck 'N("CiliumNetworkPolicy", "tpg-egress-ferretdb-i1")["spec"]["egress"] == N("CiliumNetworkPolicy", "tpg-egress-i1")["spec"]["egress"]' \
  && ok "23 review: the FerretDB egress rules are those of the instance's egress policy (what the pods had before Round 23)" || bad "ferret egress" "$(yq 'select(.metadata.name == "tpg-egress-ferretdb-i1")' <<<"$OUT")"
pycheck 'not any(p.get("port") == 27017 for r in N("NetworkPolicy", "tpg-ingress-i1")["spec"]["ingress"] for p in r.get("ports", []))
  and N("NetworkPolicy", "tpg-ingress-i1")["spec"]["podSelector"] == {"matchLabels": {"postgres-instance": "i1"}}' \
  && ok "23 review: the Postgres pods' policy keeps the postgres-instance selector and carries no 27017 rule" || bad "pg policy with ferret" "$(yq 'select(.metadata.name == "tpg-ingress-i1")' <<<"$OUT")"
render_ns i1 pg-i1 'network: {policy: baseline}'
! names | grep -q 'ferretdb' && ok "23 review: no FerretDB policies without FerretDB" || bad "no ferret policies" "$(names)"
render_ns i1 pg-i1 'network: {policy: baseline}
ferret: {enabled: true}'
pycheck 'len(N("NetworkPolicy", "tpg-ingress-ferretdb-i1")["spec"]["ingress"]) == 2' \
  && ok "23 review: FerretDB without client rules: the deny and the namespace and operator rules only (no empty peer list)" || bad "ferret no clients" "$(yq 'select(.metadata.name == "tpg-ingress-ferretdb-i1")' <<<"$OUT")"

echo
echo "chart: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
