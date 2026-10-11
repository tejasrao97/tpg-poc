#!/usr/bin/env python3
"""The clusterMap schema of each workflow, generated from cluster-map-keys.yaml
(Round 15, design decision D88).

  python3 workflows/params/clustermap_schema.py          write the files below
  python3 workflows/params/clustermap_schema.py --check  exit 1 when one is out of date

Writes, per workflow W of cluster-map-keys.yaml:
  workflows/params/schemas/clustermap-W.schema.json   JSON Schema (draft 2020-12)
  workflows/params/schemas/clustermap-W.schema.yaml   the same schema as YAML
  workflows/params/schemas/clustermap-W.example.yaml  a map that uses every key W takes
and the same three files for W = restore (Round 23, phase 6): the clusterMap of tpg-restore is a list
of pairs, described by the section "restore" of cluster-map-keys.yaml (restore_schema, RESTORE_EXAMPLE).
and the key reference of docs/workflow-commands.md, section 3, between
  <!-- BEGIN GENERATED: clustermap-keys --> and <!-- END GENERATED: clustermap-keys -->

The schemas describe the shape and the value types, for editors and linters
(yaml-language-server, check-jsonschema). The validate step of every workflow
(workflows/scripts/clustermap.py and validate-params.sh) remains the authority:
it also checks what a schema cannot: registered clusters, required values that
a workflow input may supply, host bits of CIDRs, and the combinations of values.
The patterns come from clustermap.py itself, so both accept the same values.
Needs PyYAML.
"""
import argparse
import importlib.util
import json
import os
import sys

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
KEYS = os.path.join(HERE, "cluster-map-keys.yaml")
OUT_DIR = os.path.join(HERE, "schemas")
DOC = os.path.join(ROOT, "docs", "workflow-commands.md")
BEGIN = "<!-- BEGIN GENERATED: clustermap-keys -->"
END = "<!-- END GENERATED: clustermap-keys -->"

_spec = importlib.util.spec_from_file_location("clustermap", os.path.join(ROOT, "workflows", "scripts", "clustermap.py"))
cm = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cm)

DISPLAY = {
    "string": "String", "name": "String (name)", "namespace": "String (namespace)", "azureName": "String (Azure name)", "k8sName": "String (name)",
    "boolean": "Boolean", "integer": "Integer", "posint": "Integer", "quantity": "String (quantity)",
    "enum": "Enum", "operatorVersion": "String (version)", "postgresVersion": "String (version)",
    "patchFile": "List (one file path)", "patchFileList": "List (file paths)", "caFile": "List (one file path)",
    "kindList": "List (kinds)", "nameList": "List", "k8sNameList": "List (names)", "cidrList": "List (CIDRs)", "fqdnList": "List (host names)",
    "stringMap": "Map", "cron": "String (cron)",
    "timestamp": "String (UTC time)", "lsn": "String (LSN)", "stanzaName": "String (stanza)", "backupLabel": "String (backup label)",
}

# Example values: every key a workflow takes appears in its example map. Where two
# keys exclude each other on one level (the CA bundle sources, patchMode apply and
# clear), the example names the other one in a comment (COMMENTED).
EXAMPLE = {
    "cluster": {
        "operatorVersion": "v4.5.0", "maxReadReplicas": 3,
        "operatorValuesPatchFilePath": ["./operator-resources.yaml"], "operatorValuesOverlayFilePath": ["./operator-resources.yaml"],
        "patchMode": "apply",
        "backupCaBundleVaultSecret": "azure-storage", "deleteOperator": True, "force": False,
    },
    "instance": {
        "postgresVersion": "postgres-17.6", "highAvailability": True, "readReplicas": 1,
        "storageSize": "50Gi", "walStorageSize": "10Gi", "storageClass": "tpg-data-retain", "cpu": "2", "memory": "8Gi",
        "backupSchedule": "operator", "operatorFullSchedule": "0 1 * * 0", "operatorIncrementalSchedule": "0 1 * * 1-6",
        "ferret": True, "ferretReplicas": 2, "ferretReadOnlyReplicas": 1, "ferretExposure": "clusterIP",
        "ferretSecretName": "orders-db-app-user-db-secret", "ferretReadOnlySecretName": "orders-db-read-only-user-db-secret",
        "namespace": "orders-db", "backupEnableSSL": True, "backupCaBundleFile": ["repo:ca-bundles/azure-storage.pem"],
        "disableInitialBackup": False,
        "backupFullRetention": 4, "backupFullRetentionType": "count",
        "postgresPatchFilePath": ["./orders-resources.yaml", "repo:helm_artifacts/instance/tpg-instance/patches/team-backup-schedule.yaml"],
        "postgresValuesPatchFilePath": ["~/patches/orders-values.yaml"],
        "postgresOverlayFilePath": ["./orders-resources.yaml", "repo:helm_artifacts/instance/tpg-instance/overlays/team-backup-schedule.yaml"],
        "postgresValuesOverlayFilePath": ["~/overlays/orders-values.yaml"], "patchMode": "apply",
        "backupType": "full", "backupTimeoutSeconds": 3600, "replicas": 2, "enableHAIfNeeded": True,
        "preUpgradeBackup": True, "allowMajor": False, "purgePvcs": True, "purgeNamespace": True, "finalBackup": "required",
        "purgeBackups": False, "backups": ["orders-db-full-202609010100"], "includeDependents": True,
        "exposure": "internalLoadBalancer", "serviceAnnotations": {"service.beta.kubernetes.io/azure-dns-label-name": "orders"},
        "readOnlyExposure": "clusterIP", "readOnlyServiceAnnotations": {"team": "orders"},
        "allowedSourceRanges": ["10.20.0.0/16"], "internalLoadBalancerSubnet": "snet-apps",
        "networkPolicy": "baseline", "ingressFromNamespaces": ["orders-app"], "ingressFromPodLabels": {"app": "orders-api"},
        "ingressFromCidrs": ["10.30.0.0/24"], "egressToCidrs": ["10.40.0.0/24"], "egressToFqdns": ["api.example.com"],
    },
}
# per workflow: a key the example shows as a comment because it excludes another key of that workflow
COMMENTED_WF = {
    "backup-expire": {"instance": {"purgeBackups": "purgeBackups: true   # instead of backups: expire every backup of the instance (not both; blobs are never deleted here)"}},
}
COMMENTED = {
    "cluster": {"backupCaBundleFile": "backupCaBundleFile: [./azure-ca.pem]   # or this instead of backupCaBundleVaultSecret (one source per level)",
                "clearKinds": "clearKinds: [operatorValues]   # with patchMode: clear"},
    "instance": {"backupCaBundleVaultSecret": "backupCaBundleVaultSecret: azure-storage   # or this instead of backupCaBundleFile (one source per level)",
                 "clearKinds": "clearKinds: [PostgresBackupSchedule, postgresValues]   # with patchMode: clear"},
}


# keys whose input of the same name exists in some workflows only: tpg-backup-expire has no input purgeBackups
NO_INPUT = {("backup-expire", "purgeBackups")}


def _p(rx):
    return rx.pattern


def _file_alternatives(spec):
    """(local pattern, repo pattern) of a patchFile or caFile, without anchors."""
    ca = spec["type"] == "caFile"
    local = _p(cm.LOCAL_CA if ca else cm.LOCAL_FILE)[1:-1]
    repo = _p(cm.REPO_CA if ca else cm.REPO_FILE)[1:-1]
    d = spec.get("repoDir", "")
    return local, "repo:" + d + repo


def value_schema(spec):
    t = spec["type"]
    if t == "string":
        return {"type": "string", "minLength": 1}
    if t in ("name", "azureName", "k8sName"):
        rx = {"name": cm.NAME, "azureName": cm.AZURE_NAME, "k8sName": cm.K8S_NAME}[t]
        return {"type": "string", "pattern": _p(rx)}
    if t == "namespace":
        prefixes = list(spec.get("reservedPrefixes", []))   # DNS label characters only: nothing to escape
        out = {"type": "string", "pattern": _p(cm.NAMESPACE), "not": {"enum": list(spec.get("reserved", []))}}
        if prefixes:
            out["not"] = {"anyOf": [out["not"], {"pattern": "^(" + "|".join(prefixes) + ")"}]}
        return out
    if t == "timestamp":
        return {"type": "string", "pattern": _p(cm.TIMESTAMP)}
    if t == "lsn":
        return {"type": "string", "pattern": _p(cm.LSN)}
    if t == "stanzaName":
        return {"type": "string", "pattern": _p(cm.STANZA)}
    if t == "backupLabel":
        return {"type": "string", "pattern": _p(cm.BACKUP_LABEL)}
    if t == "boolean":
        return {"enum": [True, False, "true", "false"]}
    if t in ("integer", "posint"):
        lo = 1 if t == "posint" else 0
        return {"anyOf": [{"type": "integer", "minimum": lo},
                          {"type": "string", "pattern": "^[1-9][0-9]*$" if lo else "^[0-9]+$"}]}
    if t == "quantity":
        return {"anyOf": [{"type": "number", "exclusiveMinimum": 0}, {"type": "string", "pattern": _p(cm.QUANTITY)}]}
    if t == "enum":
        vals = list(spec["values"])
        vals += [v == "true" for v in vals if v in ("true", "false")]
        return {"enum": vals}
    if t == "operatorVersion":
        return {"type": "string", "pattern": _p(cm.OPERATOR_VERSION)}
    if t == "postgresVersion":
        return {"anyOf": [{"type": "number"}, {"type": "string", "pattern": _p(cm.POSTGRES_VERSION)}]}
    if t == "cron":
        s = {"type": "string", "pattern": _p(cm.CRON)}
        return {"anyOf": [s, {"enum": ["", "none"]}]} if spec.get("allowNone") else s
    if t in ("patchFile", "caFile"):
        # one file, but still a list (Round 23): [./a.yaml]
        local, repo = _file_alternatives(spec)
        item = {"type": "string", "pattern": f"^({local}|{repo})$"}
        if t == "patchFile":
            item["not"] = {"pattern": _p(cm.OPERATOR_COPY)}
        return {"type": "array", "minItems": 1, "maxItems": 1, "items": item}
    if t == "patchFileList":
        local, repo = _file_alternatives(spec)
        return {"type": "array", "minItems": 1, "uniqueItems": True,
                "items": {"type": "string", "pattern": f"^({local}|{repo})$"}}
    if t == "kindList":
        return {"anyOf": [
            {"const": "all"},   # all stays bare; [all] is refused (Round 23)
            {"type": "array", "minItems": 1, "uniqueItems": True, "items": {"enum": list(cm.PATCH_KINDS)}}]}
    if t in ("nameList", "k8sNameList", "cidrList", "fqdnList"):
        item = {"nameList": _p(cm.NAME), "k8sNameList": _p(cm.K8S_NAME), "fqdnList": _p(cm.FQDN),
                "cidrList": r"^[0-9A-Fa-f:.]+/[0-9]{1,3}$"}[t]
        return {"type": "array", "minItems": 1, "uniqueItems": True, "items": {"type": "string", "pattern": item}}
    if t == "stringMap":
        return {"type": "object", "minProperties": 1, "propertyNames": {"pattern": _p(cm.MAP_KEY)},
                "additionalProperties": {"type": ["string", "number", "boolean"]}}
    raise SystemExit(f"cluster-map-keys.yaml: no schema for type {t}")


def keys_of(keys, level, wf):
    return [(k, s) for k, s in keys[level].items() if wf in s.get("workflows", {})]


def need(spec, wf, key):
    """How the workflow uses the key, as the reference says it."""
    use = spec["workflows"][wf]
    flag = spec.get("flag", key)
    if (wf, key) in NO_INPUT:
        flag = ""
    if use == "required":
        return f"required (this key, or the input {flag})" if flag else "required"
    if not flag and key.startswith("backupCaBundle"):
        return "optional (the instance key, else the cluster key, else the inputs)"
    if use == "guard":
        return "guard (skip an instance that runs another version)"
    return f"optional (default: the input {flag})" if flag else "optional"


def schema_of(keys, wf):
    tpl = cm.template(wf)

    def props(level):
        out = {}
        for k, s in keys_of(keys, level, wf):
            v = value_schema(s)
            v["description"] = f"{s.get('doc', '')} [{DISPLAY[s['type']]}; {need(s, wf, k)}]".strip()
            out[k] = v
        return out

    instance = {"type": "object", "additionalProperties": False, "properties": props("instance")}
    inst_min = 1 if wf in cm.INSTANCES_REQUIRED else 0
    cluster_props = props("cluster")
    cluster_props["instances"] = {
        "type": "object", "minProperties": inst_min,
        "description": "The instances of the cluster (namespace: the key namespace of tpg-day0 and tpg-create-instance, default pg-<instance>)"
                       + ("; at least one" if inst_min else ""),
        "propertyNames": {"pattern": _p(cm.NAME)},
        "additionalProperties": instance,
    }
    cluster = {"type": "object", "additionalProperties": False, "properties": cluster_props}
    if inst_min:
        cluster["required"] = ["instances"]
    return {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "$id": f"https://github.com/<org>/tpg-fleet/workflows/params/schemas/clustermap-{wf}.schema.json",
        "title": f"clusterMap of {tpl}",
        "description": (f"The clusterMap input of the WorkflowTemplate {tpl}: registered clusters, their keys and "
                        "their instances. Generated from workflows/params/cluster-map-keys.yaml by "
                        "workflows/params/clustermap_schema.py; the validate step of the workflow is the authority "
                        "(registered clusters, required values an input may supply, combinations of values)."),
        "type": "object",
        "minProperties": 1,
        "propertyNames": {"pattern": _p(cm.CLUSTER_NAME)},
        "additionalProperties": cluster,
    }


def _yaml_value(v):
    t = yaml.safe_dump(v, default_flow_style=True, sort_keys=False, width=1000).strip()
    return t[:-3].rstrip() if t.endswith("\n...") else t   # a plain scalar ends the document with ...


def example_of(keys, wf):
    tpl = cm.template(wf)
    lines = [f"# clusterMap of {tpl}: every key the workflow takes (generated; see",
             f"# workflows/params/schemas/clustermap-{wf}.schema.json). Local files are packed",
             "# into patchFiles with scripts/submit/pack-patch-files.sh -o <parameter file>.",
             f"# yaml-language-server: $schema=clustermap-{wf}.schema.json",
             "aks-tpg-poc-01:"]
    for k, s in keys_of(keys, "cluster", wf):
        if k in EXAMPLE["cluster"]:
            lines.append(f"  {k}: {_yaml_value(EXAMPLE['cluster'][k])}")
        else:
            lines.append(f"  # {COMMENTED['cluster'][k]}")
    lines += ["  instances:", "    orders-db:"]
    inst = keys_of(keys, "instance", wf)
    for k, s in inst:
        if k in COMMENTED_WF.get(wf, {}).get("instance", {}):
            lines.append(f"      # {COMMENTED_WF[wf]['instance'][k]}")
        elif k in EXAMPLE["instance"]:
            lines.append(f"      {k}: {_yaml_value(EXAMPLE['instance'][k])}")
        else:
            lines.append(f"      # {COMMENTED['instance'][k]}")
    if not inst:
        lines[-1] = "    orders-db: {}"
    return "\n".join(lines) + "\n"


# ---- tpg-restore: a list of pairs (Round 23, phase 6)
# The example shows every restore key and the three kinds of target (in place, another namespace,
# another cluster), with and without point-in-time recovery. The pairs use different instances, because
# a target is restored once per run and is not the source of another pair. Timestamps are quoted, so
# that no YAML parser turns them into dates.
RESTORE_EXAMPLE = """\
# clusterMap of tpg-restore: a list of pairs, one restore each (generated; see
# workflows/params/schemas/clustermap-restore.schema.json). Each side is
# <cluster>: <namespace>: <instance>: {keys}, exactly one of each. Local spec files are packed
# into patchFiles with scripts/submit/pack-patch-files.sh -o <parameter file>.
# yaml-language-server: $schema=clustermap-restore.schema.json

# 1. In place, from a named backup (no point-in-time recovery): the source and the target are the same
#    instance; confirm repeats its name (needed when dryRun is false)
- sourceClusterConfig:
    aks-tpg-poc-01:
      pg-orders:
        orders-db:
          sourceBackupName: orders-db-full-20260914000000
  targetClusterConfig:
    aks-tpg-poc-01:
      pg-orders:
        orders-db:
          pitrEnabled: false
          confirm: orders-db

# 2. A copy in another namespace of the same cluster, up to the newest WAL (type latest takes no
#    timestamp, target, bestEffort or srcBackupLabel); the source instance gives location and stanza
- sourceClusterConfig:
    aks-tpg-poc-01:
      pg-billing:
        billing-db: {}
  targetClusterConfig:
    aks-tpg-poc-01:
      pg-billing-copy:
        billing-db-copy:
          pitrEnabled: true
          pitrConfig:
            type: latest

# 3. A new instance on another cluster at a point in time, from one chosen backup of the repository,
#    with its own spec file (a local file of the submitting machine, or [repo:<path>])
- sourceClusterConfig:
    aks-tpg-poc-01:
      pg-reports:
        reports-db:
          sourceBackupName: reports-db-full-20260914000000
  targetClusterConfig:
    aks-tpg-poc-02:
      pg-reports:
        reports-db-dr:
          pitrEnabled: true
          bestEffort: true
          pitrConfig:
            type: time
            timestamp: "2026-09-15T08:30:00Z"
            sourceBackupConfig:
              srcBackupLocationName: reports-db-backup-location
              srcStanzaName: pg-reports-reports-db-0000
              srcBackupLabel: 20260914-000000F
          targetInstanceSpecFilePath: [./reports-db-dr.yaml]
          skipMinorVersionCheck: true
          postRestoreBackup: true

# 4. In place, point-in-time recovery to a log sequence number (type lsn, or transaction with a
#    transaction ID in target)
- sourceClusterConfig:
    aks-tpg-poc-02:
      pg-shop:
        shop-db: {}
  targetClusterConfig:
    aks-tpg-poc-02:
      pg-shop:
        shop-db:
          pitrEnabled: true
          bestEffort: false
          pitrConfig:
            type: lsn
            target: 0/3000060
          confirm: shop-db

# 5. A named backup into a new instance of the same namespace
- sourceClusterConfig:
    aks-tpg-poc-01:
      pg-orders:
        archive-db:
          sourceBackupName: archive-db-full-20260914000000
  targetClusterConfig:
    aks-tpg-poc-01:
      pg-orders:
        archive-db-restored:
          pitrEnabled: false
"""


def _restore_tree(specs):
    """{'pitrConfig': {'type': ('leaf', spec), ...}, 'bestEffort': ('leaf', spec)} from the dotted key paths."""
    tree = {}
    for path, spec in specs.items():
        parts = path.split(".")
        node = tree
        for part in parts[:-1]:
            node = node.setdefault(part, {})
        node[parts[-1]] = ("leaf", spec)
    return tree


def _restore_object(tree, doc_of):
    props = {}
    for k, v in tree.items():
        if isinstance(v, tuple):
            spec = v[1]
            sch = value_schema(spec)
            sch["description"] = f"{spec.get('doc', '')} [{DISPLAY[spec['type']]}]".strip()
        else:
            sch = _restore_object(v, doc_of)
            sch["description"] = doc_of.get(k, "")
        props[k] = sch
    return {"type": "object", "additionalProperties": False, "properties": props}


def restore_schema(keys):
    src, tgt = cm.restore_specs(keys)
    ns = keys["instance"]["namespace"]

    def one(inner, names):
        return {"type": "object", "minProperties": 1, "maxProperties": 1, "propertyNames": names, "additionalProperties": inner}

    def side(instance_schema, ns_names):
        return one(one(one(instance_schema, {"pattern": _p(cm.NAME)}), ns_names), {"pattern": _p(cm.CLUSTER_NAME)})

    source = _restore_object(_restore_tree(src), {})
    target = _restore_object(_restore_tree(tgt), {"pitrConfig": "Point-in-time recovery: the type and what it needs (pitrEnabled true)",
                                                  "sourceBackupConfig": "The backup repository to recover from; every key is optional where it can be derived"})
    target["required"] = ["pitrEnabled"]

    def pitr(on):
        return {"required": ["pitrEnabled"], "properties": {"pitrEnabled": {"enum": [True, "true"] if on else [False, "false"]}}}

    def typ(t):
        return {"required": ["pitrConfig"], "properties": {"pitrConfig": {"required": ["type"], "properties": {"type": {"const": t}}}}}

    def has(*path):
        """The key path is present: {required: [a], properties: {a: {required: [b], ...}}}."""
        node = {"required": [path[-1]]}
        for k in reversed(path[:-1]):
            node = {"required": [k], "properties": {k: node}}
        return node

    # the rules between the keys that a schema can say; the validate step (clustermap.py restore) has all of them
    target["allOf"] = [
        {"if": pitr(False), "then": {"not": {"anyOf": [has("pitrConfig"), has("bestEffort")]}}},
        {"if": pitr(True), "then": {"required": ["pitrConfig"], "properties": {"pitrConfig": {"required": ["type"]}}}},
        {"if": typ("latest"), "then": {"not": {"anyOf": [has("bestEffort"), has("pitrConfig", "target"), has("pitrConfig", "timestamp"),
                                                           has("pitrConfig", "sourceBackupConfig", "srcBackupLabel")]}}},
        {"if": typ("time"), "then": {"required": ["bestEffort"], "properties": {"pitrConfig": {"required": ["timestamp"], "not": has("target")}}}},
        {"if": typ("lsn"), "then": {"required": ["bestEffort"], "properties": {"pitrConfig": {
            "required": ["target"], "not": has("timestamp"), "properties": {"target": {"type": "string", "pattern": _p(cm.LSN)}}}}}},
        {"if": typ("transaction"), "then": {"required": ["bestEffort"], "properties": {"pitrConfig": {
            "required": ["target"], "not": has("timestamp"), "properties": {"target": {"anyOf": [
                {"type": "integer", "minimum": 0}, {"type": "string", "pattern": _p(cm.TRANSACTION_ID)}]}}}}}},
    ]
    # pitrConfig.target is an LSN or a transaction ID: the type decides (above), here both forms
    target["properties"]["pitrConfig"]["properties"]["target"] = {
        "anyOf": [{"type": "string", "pattern": _p(cm.LSN)}, {"type": "string", "pattern": _p(cm.TRANSACTION_ID)}, {"type": "integer", "minimum": 0}],
        "description": tgt["pitrConfig.target"]["doc"] + " [String]"}
    pair = {
        "type": "object", "additionalProperties": False, "required": ["sourceClusterConfig", "targetClusterConfig"],
        "properties": {
            "sourceClusterConfig": dict(side(source, {"pattern": _p(cm.NAMESPACE)}),
                                        description="The instance to restore from: <cluster>: <namespace>: <instance>: {sourceBackupName}, exactly one of each"),
            "targetClusterConfig": dict(side(target, value_schema(ns)),
                                        description="The instance to restore into: <cluster>: <namespace>: <instance>: {keys}, exactly one of each. "
                                                    "Namespaces are mandatory; a new target namespace follows the reserved list of tpg-day0"),
        },
    }
    return {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "$id": "https://github.com/<org>/tpg-fleet/workflows/params/schemas/clustermap-restore.schema.json",
        "title": "clusterMap of tpg-restore",
        "description": ("The clusterMap input of the WorkflowTemplate tpg-restore: a list of pairs, one restore each. Generated from "
                        "the section restore of workflows/params/cluster-map-keys.yaml by workflows/params/clustermap_schema.py; the "
                        "validate step of the workflow (workflows/scripts/clustermap.py restore) is the authority: registered clusters, "
                        "the rules between the pairs (a target once, not the source of another pair), the source keys that depend on "
                        "pitrEnabled of the target, and the rules that need the clusters."),
        "type": "array",
        "minItems": 1,
        "items": pair,
    }



def md_cell(s):
    return s.replace("|", "\\|")


def reference(keys):
    wfs = keys["workflows"]
    out = [BEGIN,
           "<!-- written by workflows/params/clustermap_schema.py from workflows/params/cluster-map-keys.yaml; do not edit by hand -->",
           ""]
    for level, title in (("cluster", "Cluster keys"), ("instance", "Instance keys")):
        out += [f"{title}:", "", "| Key | Type | Workflows | Meaning |", "|---|---|---|---|"]
        for k, s in keys[level].items():
            use = ", ".join(f"{w}" + ("" if u == "optional" else f" ({u})") for w, u in s["workflows"].items())
            out.append(f"| `{k}` | `{DISPLAY[s['type']]}` | {use} | {md_cell(s.get('doc', ''))} |")
        out.append("")
    out += ["Keys per workflow (`required`: the key, or the workflow input named; `guard`: when set, an instance",
            "that runs another version is skipped). The schema of each map is",
            "`workflows/params/schemas/clustermap-<workflow>.schema.json` (also `.schema.yaml`), with an example",
            "map that uses every key in `clustermap-<workflow>.example.yaml`:", ""]
    for wf in wfs:
        tpl = cm.template(wf)
        rows = [("<cluster>:", "", "")]
        for k, s in keys_of(keys, "cluster", wf):
            rows.append((f"  {k}", DISPLAY[s["type"]], need(s, wf, k)))
        inst_note = "at least one" if wf in cm.INSTANCES_REQUIRED else ""
        rows.append(("  instances:", "", inst_note))
        rows.append(("    <instance>:", "", ""))
        for k, s in keys_of(keys, "instance", wf):
            rows.append((f"      {k}", DISPLAY[s["type"]], need(s, wf, k)))
        w1 = max(len(r[0]) for r in rows) + 2
        w2 = max(len(r[1]) for r in rows) + 2
        out += [f"`{tpl}` (`clustermap-{wf}.schema.json`):", "", "```text"]
        out += [(r[0].ljust(w1) + r[1].ljust(w2) + r[2]).rstrip() for r in rows]
        out += ["```", ""]
    out.append(END)
    return "\n".join(out)


def outputs():
    keys = yaml.safe_load(open(KEYS))
    files = {}
    for wf in keys["workflows"]:
        sch = schema_of(keys, wf)
        base = os.path.join(OUT_DIR, f"clustermap-{wf}")
        files[base + ".schema.json"] = json.dumps(sch, indent=2) + "\n"
        files[base + ".schema.yaml"] = ("# generated by workflows/params/clustermap_schema.py; do not edit\n"
                                        + yaml.safe_dump(sch, sort_keys=False, width=1000, allow_unicode=True))
        files[base + ".example.yaml"] = example_of(keys, wf)
    sch = restore_schema(keys)
    base = os.path.join(OUT_DIR, "clustermap-restore")
    files[base + ".schema.json"] = json.dumps(sch, indent=2) + "\n"
    files[base + ".schema.yaml"] = ("# generated by workflows/params/clustermap_schema.py; do not edit\n"
                                    + yaml.safe_dump(sch, sort_keys=False, width=1000, allow_unicode=True))
    files[base + ".example.yaml"] = RESTORE_EXAMPLE
    doc = open(DOC).read()
    if doc.count(BEGIN) != 1 or doc.count(END) != 1:
        raise SystemExit(f"{DOC}: the markers {BEGIN} and {END} must appear once each")
    a, rest = doc.split(BEGIN)
    _, b = rest.split(END)
    files[DOC] = a + reference(keys) + b
    return files


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true", help="exit 1 when a generated file is out of date")
    args = ap.parse_args()
    files = outputs()
    stale = []
    expected = set(files)
    if os.path.isdir(OUT_DIR):
        for f in os.listdir(OUT_DIR):
            p = os.path.join(OUT_DIR, f)
            if p not in expected:
                stale.append(p + " (no longer generated)")
                if not args.check:
                    os.remove(p)
    for path, text in files.items():
        cur = open(path).read() if os.path.exists(path) else None
        if cur == text:
            continue
        if args.check:
            stale.append(path)
        else:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w") as f:
                f.write(text)
    if args.check:
        if stale:
            print("out of date (run python3 workflows/params/clustermap_schema.py):\n  "
                  + "\n  ".join(os.path.relpath(p, ROOT) for p in stale), file=sys.stderr)
            sys.exit(1)
        print(f"up to date: {len(files)} generated files")


if __name__ == "__main__":
    main()
