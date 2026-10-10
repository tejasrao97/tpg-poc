#!/usr/bin/env python3
"""The clusterMap schema of each workflow, generated from cluster-map-keys.yaml
(Round 15, design decision D88).

  python3 workflows/params/clustermap_schema.py          write the files below
  python3 workflows/params/clustermap_schema.py --check  exit 1 when one is out of date

Writes, per workflow W of cluster-map-keys.yaml:
  workflows/params/schemas/clustermap-W.schema.json   JSON Schema (draft 2020-12)
  workflows/params/schemas/clustermap-W.schema.yaml   the same schema as YAML
  workflows/params/schemas/clustermap-W.example.yaml  a map that uses every key W takes
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
    "string": "String", "name": "String (name)", "azureName": "String (Azure name)", "k8sName": "String (name)",
    "boolean": "Boolean", "integer": "Integer", "posint": "Integer", "quantity": "String (quantity)",
    "enum": "Enum", "operatorVersion": "String (version)", "postgresVersion": "String (version)",
    "patchFile": "String (file path)", "patchFileList": "List (file paths)", "caFile": "String (file path)",
    "kindList": "List (kinds)", "nameList": "List", "cidrList": "List (CIDRs)", "fqdnList": "List (host names)",
    "stringMap": "Map", "cron": "String (cron)",
}

# Example values: every key a workflow takes appears in its example map. Where two
# keys exclude each other on one level (the CA bundle sources, patchMode apply and
# clear), the example names the other one in a comment (COMMENTED).
EXAMPLE = {
    "cluster": {
        "operatorVersion": "v4.5.0", "maxReadReplicas": 3,
        "operatorValuesPatchFilePath": "./operator-resources.yaml", "operatorValuesOverlayFilePath": "./operator-resources.yaml",
        "patchMode": "apply",
        "backupCaBundleVaultSecret": "azure-storage", "deleteOperator": True, "force": False,
    },
    "instance": {
        "postgresVersion": "postgres-17.6", "highAvailability": True, "readReplicas": 1,
        "storageSize": "50Gi", "walStorageSize": "10Gi", "storageClass": "tpg-data-retain", "cpu": "2", "memory": "8Gi",
        "backupSchedule": "operator", "operatorFullSchedule": "0 1 * * 0", "operatorIncrementalSchedule": "0 1 * * 1-6",
        "ferret": True, "ferretReplicas": 2, "ferretReadOnlyReplicas": 1, "ferretExposure": "clusterIP",
        "ferretSecretName": "orders-db-app-user-db-secret", "ferretReadOnlySecretName": "orders-db-read-only-user-db-secret",
        "backupEnableSSL": True, "backupCaBundleFile": "repo:ca-bundles/azure-storage.pem",
        "disableInitialBackup": False,
        "backupFullRetention": 4, "backupFullRetentionType": "count",
        "postgresPatchFilePath": ["./orders-resources.yaml", "repo:helm_artifacts/instance/tpg-instance/patches/team-backup-schedule.yaml"],
        "postgresValuesPatchFilePath": "~/patches/orders-values.yaml",
        "postgresOverlayFilePath": ["./orders-resources.yaml", "repo:helm_artifacts/instance/tpg-instance/overlays/team-backup-schedule.yaml"],
        "postgresValuesOverlayFilePath": "~/overlays/orders-values.yaml", "patchMode": "apply",
        "backupType": "full", "backupTimeoutSeconds": 3600, "replicas": 2, "enableHAIfNeeded": True,
        "preUpgradeBackup": True, "allowMajor": False, "purgePvcs": True, "purgeNamespace": True, "finalBackup": "required",
        "exposure": "internalLoadBalancer", "serviceAnnotations": {"service.beta.kubernetes.io/azure-dns-label-name": "orders"},
        "readOnlyExposure": "clusterIP", "readOnlyServiceAnnotations": {"team": "orders"},
        "allowedSourceRanges": ["10.20.0.0/16"], "internalLoadBalancerSubnet": "snet-apps",
        "networkPolicy": "baseline", "ingressFromNamespaces": ["orders-app"], "ingressFromPodLabels": {"app": "orders-api"},
        "ingressFromCidrs": ["10.30.0.0/24"], "egressToCidrs": ["10.40.0.0/24"], "egressToFqdns": ["api.example.com"],
    },
}
COMMENTED = {
    "cluster": {"backupCaBundleFile": "backupCaBundleFile: ./azure-ca.pem   # or this instead of backupCaBundleVaultSecret (one source per level)",
                "clearKinds": "clearKinds: [operatorValues]   # with patchMode: clear"},
    "instance": {"backupCaBundleVaultSecret": "backupCaBundleVaultSecret: azure-storage   # or this instead of backupCaBundleFile (one source per level)",
                 "clearKinds": "clearKinds: [PostgresBackupSchedule, postgresValues]   # with patchMode: clear"},
}


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
        local, repo = _file_alternatives(spec)
        s = {"type": "string", "pattern": f"^({local}|{repo})$"}
        if t == "patchFile":
            s["not"] = {"pattern": _p(cm.OPERATOR_COPY)}
        return s
    if t == "patchFileList":
        local, repo = _file_alternatives(spec)
        one = f"({local}|{repo})"
        return {"anyOf": [
            {"type": "array", "minItems": 1, "uniqueItems": True,
             "items": {"type": "string", "pattern": f"^{one}$"}},
            {"type": "string", "pattern": rf"^\s*{one}(\s*,\s*{one})*\s*$"}]}
    if t == "kindList":
        kinds = "|".join(cm.PATCH_KINDS)
        return {"anyOf": [
            {"const": "all"}, {"const": ["all"]},
            {"type": "array", "minItems": 1, "uniqueItems": True, "items": {"enum": list(cm.PATCH_KINDS)}},
            {"type": "string", "pattern": rf"^\s*({kinds})(\s*,\s*({kinds}))*\s*$"}]}
    if t in ("nameList", "cidrList", "fqdnList"):
        item = {"nameList": _p(cm.NAME), "fqdnList": _p(cm.FQDN),
                "cidrList": r"^[0-9A-Fa-f:.]+/[0-9]{1,3}$"}[t]
        inner = item[1:-1]
        return {"anyOf": [
            {"type": "array", "minItems": 1, "uniqueItems": True, "items": {"type": "string", "pattern": item}},
            {"type": "string", "pattern": rf"^\s*{inner}(\s*,\s*{inner})*\s*$"}]}
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
        "description": "The instances of the cluster (namespace pg-<instance>)"
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
        if k in EXAMPLE["instance"]:
            lines.append(f"      {k}: {_yaml_value(EXAMPLE['instance'][k])}")
        else:
            lines.append(f"      # {COMMENTED['instance'][k]}")
    if not inst:
        lines[-1] = "    orders-db: {}"
    return "\n".join(lines) + "\n"


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
