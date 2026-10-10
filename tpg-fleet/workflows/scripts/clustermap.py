#!/usr/bin/env python3
"""clusterMap: validation and normalization for the tpg workflows.

The map is the optional clusterMap input (YAML or JSON). The step scripts turn
it into JSON with yq first, so this file needs the Python standard library only
(the workflow tools image has no PyYAML). The accepted keys, their types and
the workflows that use them come from workflows/params/cluster-map-keys.yaml,
also converted to JSON by the caller.

  clustermap.py validate  --workflow W --map M.json --keys K.json
                          [--registered FILE] [--flags F.json] [--out N.json]
      Prints one error per line and exits 1 when the map is invalid; otherwise
      writes the normalized map to --out (or stdout) and exits 0.
  clustermap.py normalize --map M.json --keys K.json
      Writes the normalized map without checking workflows or clusters.

Normalized map: {cluster: {<cluster key>: value, instances: {instance: {<key>: value}}}}
with every scalar as a string ("true", "3", "v4.5.0", "postgres-17.6"); a patchFile
is one .yaml or .yml path: a file of the submitting machine (absolute or relative;
its contents come in patchFiles) or repo:<path> in the fleet repository (Round 15);
a patchFileList is a list of them, a kindList a list of patch kinds.
"""
import argparse
import difflib
import ipaddress
import json
import re
import sys

NAME = re.compile(r"^[a-z]([-a-z0-9]{0,38}[a-z0-9])?$")
CLUSTER_NAME = re.compile(r"^[a-z0-9]([-a-z0-9]*[a-z0-9])?$")
QUANTITY = re.compile(r"^[0-9]+(\.[0-9]+)?(m|Ki|Mi|Gi|Ti|Pi|k|M|G|T|P)?$")
OPERATOR_VERSION = re.compile(r"^v?[0-9]+\.[0-9]+\.[0-9]+([-+.][0-9A-Za-z.-]+)?$")
POSTGRES_VERSION = re.compile(r"^(postgres-)?[0-9]+(\.[0-9]+)?$")
_SEG = r"[A-Za-z0-9_@+][A-Za-z0-9_.@+-]*"
# a file of the submitting machine: absolute (/...), home (~/...) or relative; .. allowed
LOCAL_FILE = re.compile(r"^(/|~/)?((\.\.?|" + _SEG + r")/)*" + _SEG + r"\.ya?ml$")
LOCAL_CA = re.compile(r"^(/|~/)?((\.\.?|" + _SEG + r")/)*" + _SEG + r"\.(pem|crt|cer)$")
# repo:<path>: a file of the fleet repository, relative to its root, no .. and no ./
REPO_FILE = re.compile(r"^(" + _SEG + r"/)*" + _SEG + r"\.ya?ml$")
REPO_CA = re.compile(r"^(" + _SEG + r"/)*" + _SEG + r"\.(pem|crt|cer)$")
PATCH_KINDS = ["Postgres", "PostgresBackupLocation", "PostgresBackupSchedule", "PostgresFerretDocumentDB",
               "postgresValues", "operatorValues"]
# Kubernetes annotation/label key: optional DNS prefix, then a name
MAP_KEY = re.compile(r"^([a-z0-9]([-a-z0-9]*[a-z0-9])?(\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*/)?[A-Za-z0-9]([-A-Za-z0-9_.]{0,61}[A-Za-z0-9])?$")
AZURE_NAME = re.compile(r"^[A-Za-z0-9]([-A-Za-z0-9_.]{0,78}[A-Za-z0-9_])?$")
FQDN = re.compile(r"^(\*\.)?([a-z0-9]([-a-z0-9]*[a-z0-9])?\.)+[a-z]{2,}$")
CRON = re.compile(r"^[0-9*/,A-Za-z-]+(\s+[0-9*/,A-Za-z-]+){4}$")
K8S_NAME = re.compile(r"^[a-z0-9]([-a-z0-9.]{0,251}[a-z0-9])?$")

# Workflows where every cluster needs at least one instance, and the cluster keys
# that make an instance-less cluster meaningful in the others.
INSTANCES_REQUIRED = {"day0", "create-instance", "backup", "delete-instance", "network-policy"}
CLUSTER_ACTION_KEYS = {
    "upgrade": ["operatorVersion"],
    "scale": ["maxReadReplicas"],
    "patch": ["operatorValuesPatchFilePath", "clearKinds"],
    "delete-apps": ["deleteOperator"],
}


# Round 22: tpg-day0 and tpg-create-instance take overlay files; the old names are tpg-patch keys now
OVERLAY_RENAMED = {"postgresPatchFilePath": "postgresOverlayFilePath",
                   "postgresValuesPatchFilePath": "postgresValuesOverlayFilePath",
                   "operatorValuesPatchFilePath": "operatorValuesOverlayFilePath"}


def overlay_hint(workflow, key):
    """' (renamed X in Round 22)' for a patch key used with tpg-day0 or tpg-create-instance."""
    if workflow in ("day0", "create-instance") and key in OVERLAY_RENAMED:
        return f" (renamed {OVERLAY_RENAMED[key]} in Round 22: overlay files apply at the initial deployment)"
    return ""


TEMPLATES = {"scale": "tpg-scale-instance"}


def template(w):
    """The WorkflowTemplate name of a workflow id of cluster-map-keys.yaml."""
    return TEMPLATES.get(w, "tpg-" + w)


def scalar(v):
    """A map value as a string; booleans lower-case, integers without .0."""
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, float) and v.is_integer():
        return str(int(v))
    return str(v)


def as_list(value):
    """A list value: a YAML/JSON list or a comma-separated string -> list of strings."""
    items = value if isinstance(value, list) else scalar(value).split(",")
    return [scalar(p).strip() for p in items if p is not None and scalar(p).strip()]


def check_list(t, value, where):
    items = as_list(value)
    if not items:
        return [], f"{where}: a non-empty list is expected (remove the key instead of setting it empty)"
    for p in items:
        if t == "nameList" and not NAME.match(p):
            return items, f"{where}: '{p}' must be a lowercase DNS label"
        if t == "cidrList":
            try:
                ipaddress.ip_network(p, strict=True)
            except ValueError:
                return items, f"{where}: '{p}' must be a CIDR such as 10.20.0.0/16 (host bits zero)"
        if t == "fqdnList" and not FQDN.match(p):
            return items, f"{where}: '{p}' must be a host name such as db.example.com or *.example.com"
    if len(set(items)) != len(items):
        return items, f"{where}: duplicate entries"
    return items, None


def check_patch_file(spec, value, where):
    """One patch (or CA) file path: local (absolute, ~/ or relative) or repo:<path> under spec repoDir."""
    p = scalar(value).strip()
    ca = spec.get("type") == "caFile"
    what = "PEM file (.pem, .crt or .cer)" if ca else ".yaml or .yml file"
    if p.startswith("repo:"):
        r = p[len("repo:"):]
        d = spec.get("repoDir", "")
        if not (REPO_CA if ca else REPO_FILE).match(r) or ".." in r.split("/"):
            return p, (f"{where}: '{p}' must be repo:<path of a {what} in the fleet repository>, "
                       f"relative to its root (no leading /, no ..)")
        if d and not r.startswith(d):
            return p, f"{where}: '{p}' must be a file under {d} of the fleet repository (repo:{d}<file>)"
        if r.startswith("patches/operator/clusters/"):
            return p, f"{where}: '{p}' is a copy the workflows write per cluster; name the stored file under patches/operator/"
        return p, None
    if not (LOCAL_CA if ca else LOCAL_FILE).match(p):
        return p, (f"{where}: '{p}' must be the path of one {what} on the submitting machine "
                   f"(absolute or relative), or repo:<path> in the fleet repository")
    return p, None


def check_map(value, where):
    if isinstance(value, str) and value.strip().startswith("{"):
        try:
            value = json.loads(value)
        except ValueError:
            return value, f"{where}: not a valid JSON object"
    if not isinstance(value, dict):
        return value, f"{where}: a mapping of keys to string values is expected"
    if not value:
        return {}, f"{where}: a non-empty mapping is expected (remove the key instead of setting it empty)"
    out = {}
    for k, v in value.items():
        k = scalar(k)
        if not MAP_KEY.match(k):
            return value, f"{where}: '{k}' is not a valid annotation or label key"
        if v is None or isinstance(v, (dict, list)):
            return value, f"{where}.{k}: a string value is expected"
        out[k] = scalar(v)
    return out, None


def check_value(spec, value, where):
    """Return (normalized value, error or None)."""
    t = spec["type"]
    if value is None:
        return None, f"{where}: null is not a value; remove the key to use the default"
    if t in ("nameList", "cidrList", "fqdnList"):
        return check_list(t, value, where)
    if t == "stringMap":
        return check_map(value, where)
    if t in ("patchFile", "caFile"):
        if isinstance(value, (dict, list)):
            return value, f"{where}: one file path is expected (one current file of this kind)"
        return check_patch_file(spec, value, where)
    if t == "patchFileList":
        if isinstance(value, dict):
            return value, f"{where}: a list of file paths is expected"
        items = as_list(value)
        if not items:
            return [], f"{where}: a non-empty list is expected (remove the key instead of setting it empty)"
        out = []
        for p in items:
            n, err = check_patch_file(spec, p, where)
            if err:
                return items, err
            out.append(n)
        if len(set(out)) != len(out):
            return out, f"{where}: duplicate entries"
        return out, None
    if t == "kindList":
        items = as_list(value)
        if not items:
            return [], f"{where}: a non-empty list is expected (remove the key instead of setting it empty)"
        for k in items:
            if k != "all" and k not in PATCH_KINDS:
                return items, f"{where}: '{k}' must be one of {', '.join(PATCH_KINDS)}, or all{suggest(k, PATCH_KINDS)}"
        if "all" in items and len(items) > 1:
            return items, f"{where}: all stands alone"
        if len(set(items)) != len(items):
            return items, f"{where}: duplicate entries"
        return items, None
    if isinstance(value, (dict, list)):
        return value, f"{where}: a single value is expected, not a {type(value).__name__}"
    s = scalar(value).strip()
    if t == "string":
        return s, None
    if t == "name":
        return s, None if NAME.match(s) else f"{where}: '{s}' must be a lowercase DNS label"
    if t == "azureName":
        return s, None if AZURE_NAME.match(s) else f"{where}: '{s}' must be an Azure resource name (letters, digits, '-', '_', '.', at most 80 characters)"
    if t == "boolean":
        return s, None if s in ("true", "false") else f"{where}: '{s}' must be true or false"
    if t == "cron":
        if spec.get("allowNone") and s in ("", "none"):
            return "", None
        s = " ".join(s.split())
        return s, None if CRON.match(s) else f"{where}: '{s}' must be a cron schedule of 5 fields (minute hour day month weekday), for example 0 0 * * 0"
    if t == "k8sName":
        return s, None if K8S_NAME.match(s) else f"{where}: '{s}' must be a Kubernetes object name (lowercase letters, digits, '-' and '.')"
    if t == "integer":
        return s, None if re.fullmatch(r"[0-9]+", s) else f"{where}: '{s}' must be a non-negative integer"
    if t == "posint":
        return s, None if re.fullmatch(r"[1-9][0-9]*", s) else f"{where}: '{s}' must be a positive integer"
    if t == "quantity":
        return s, None if QUANTITY.match(s) else f"{where}: '{s}' must be a Kubernetes quantity such as 20Gi or 500m"
    if t == "enum":
        vals = [scalar(v) for v in spec["values"]]
        return s, None if s in vals else f"{where}: '{s}' must be one of {', '.join(vals)}"
    if t == "operatorVersion":
        if not OPERATOR_VERSION.match(s):
            return s, f"{where}: '{s}' must be an operator chart version such as v4.5.0"
        return "v" + s.lstrip("v"), None
    if t == "postgresVersion":
        if not POSTGRES_VERSION.match(s):
            return s, f"{where}: '{s}' must be a Postgres version such as postgres-17.6 or 17.6"
        return "postgres-" + s[len("postgres-"):] if s.startswith("postgres-") else "postgres-" + s, None
    return s, f"{where}: unknown type {t} in cluster-map-keys.yaml"


def suggest(word, choices):
    close = difflib.get_close_matches(word, list(choices), n=1, cutoff=0.6)
    return f" (did you mean {close[0]}?)" if close else ""


def instance_name_hint(name):
    fixed = re.sub(r"[^a-z0-9-]", "-", name.lower()).strip("-")
    return f" (for example {fixed})" if fixed and NAME.match(fixed) else ""


def process(raw, keys, workflow=None, registered=None, flags=None):
    """Return (normalized map, [errors]). workflow=None: normalize only."""
    errors = []
    norm = {}
    if raw is None or raw == "" or raw == {}:
        return {}, ["clusterMap is empty"] if workflow else []
    if not isinstance(raw, dict):
        return {}, ["clusterMap must be a mapping of cluster names to {instances: {...}} (YAML or JSON)"]
    flags = flags or {}
    ckeys, ikeys = keys.get("cluster", {}), keys.get("instance", {})
    renamed = keys.get("renamed", {}) or {}

    def allowed(spec):
        return workflow is None or workflow in spec.get("workflows", {})

    def keys_for(level):
        return {k for k, s in level.items() if allowed(s)}

    def required_missing(level, entry, where):
        if workflow is None:
            return
        for k, spec in level.items():
            if spec.get("workflows", {}).get(workflow) != "required":
                continue
            flag = spec.get("flag", k)
            if k not in entry and not (flag and scalar(flags.get(flag, "")).strip()):
                src = f"the map key {k} or the workflow input {flag}" if flag else f"the map key {k}"
                errors.append(f"{where}: {k} is required ({src})")

    for cluster, centry in raw.items():
        cluster = scalar(cluster)
        where_c = f"clusterMap.{cluster}"
        if not CLUSTER_NAME.match(cluster):
            errors.append(f"{where_c}: '{cluster}' is not a valid cluster name")
        elif registered is not None and cluster not in registered:
            errors.append(f"{where_c}: cluster '{cluster}' is not registered{suggest(cluster, registered)}. "
                          f"Registered clusters: {', '.join(sorted(registered)) or 'none'}")
        if centry is None:
            centry = {}
        if not isinstance(centry, dict):
            errors.append(f"{where_c}: must be a mapping with an instances key")
            continue
        ncluster = {"instances": {}}
        for k, v in centry.items():
            if k == "instances":
                continue
            if k not in ckeys:
                hint = suggest(k, keys_for(ckeys) | {"instances"})
                if k in renamed:
                    hint = f" (renamed {renamed[k]} in Round 15)"
                if k in ikeys:
                    hint = f" ({k} is an instance key: put it under instances.<instance>)"
                errors.append(f"{where_c}: unknown key {k}{hint}")
                continue
            if not allowed(ckeys[k]):
                errors.append(f"{where_c}.{k}: not used by {template(workflow)} "
                              f"(used by {', '.join(template(w) for w in ckeys[k]['workflows'])}){overlay_hint(workflow, k)}")
                continue
            ncluster[k], err = check_value(ckeys[k], v, f"{where_c}.{k}")
            if err:
                errors.append(err)
        required_missing(ckeys, ncluster, where_c)

        insts = centry.get("instances", {})
        if insts is None:
            insts = {}
        if not isinstance(insts, dict):
            errors.append(f"{where_c}.instances: must be a mapping of instance names to their keys")
            insts = {}
        if workflow in INSTANCES_REQUIRED and not insts:
            errors.append(f"{where_c}: at least one instance is required under instances")
        if workflow in CLUSTER_ACTION_KEYS and not insts \
                and not any(k in ncluster or scalar(flags.get(k, "")).strip()
                            for k in CLUSTER_ACTION_KEYS[workflow]):
            errors.append(f"{where_c}: no instances and none of {', '.join(CLUSTER_ACTION_KEYS[workflow])}: "
                          f"nothing to do on this cluster")
        for inst, ientry in insts.items():
            inst = scalar(inst)
            where_i = f"{where_c}.instances.{inst}"
            if not NAME.match(inst):
                errors.append(f"{where_i}: '{inst}' must be a lowercase DNS label of at most 40 characters: "
                              f"letters, digits and '-'{instance_name_hint(inst)}")
            if ientry is None:
                ientry = {}
            if not isinstance(ientry, dict):
                errors.append(f"{where_i}: must be a mapping of keys (or empty)")
                continue
            ninst = {}
            for k, v in ientry.items():
                if k not in ikeys:
                    hint = suggest(k, keys_for(ikeys))
                    if k in renamed:
                        hint = f" (renamed {renamed[k]} in Round 15)"
                    if k in ckeys:
                        hint = f" ({k} is a cluster key: put it next to instances)"
                    errors.append(f"{where_i}: unknown key {k}{hint}")
                    continue
                if not allowed(ikeys[k]):
                    errors.append(f"{where_i}.{k}: not used by {template(workflow)} "
                                  f"(used by {', '.join(template(w) for w in ikeys[k]['workflows'])}){overlay_hint(workflow, k)}")
                    continue
                ninst[k], err = check_value(ikeys[k], v, f"{where_i}.{k}")
                if err:
                    errors.append(err)
            required_missing(ikeys, ninst, where_i)
            ncluster["instances"][inst] = ninst
        norm[cluster] = ncluster
    return norm, errors


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("command", choices=["validate", "normalize"])
    ap.add_argument("--workflow")
    ap.add_argument("--map", required=True)
    ap.add_argument("--keys", required=True)
    ap.add_argument("--registered")
    ap.add_argument("--flags")
    ap.add_argument("--out")
    a = ap.parse_args()
    with open(a.map) as f:
        text = f.read().strip()
    raw = json.loads(text) if text else None
    with open(a.keys) as f:
        keys = json.load(f)
    if a.command == "validate":
        if a.workflow not in keys.get("workflows", []):
            print(f"clusterMap is not accepted by {template(a.workflow)}")
            return 1
        registered = None
        if a.registered:
            with open(a.registered) as f:
                registered = {line.strip() for line in f if line.strip()}
        flags = {}
        if a.flags:
            with open(a.flags) as f:
                flags = json.load(f)
        norm, errors = process(raw, keys, a.workflow, registered, flags)
    else:
        norm, errors = process(raw, keys)
    if errors:
        print("\n".join(errors))
        return 1
    out = json.dumps(norm, sort_keys=True, separators=(",", ":"))
    if a.out:
        with open(a.out, "w") as f:
            f.write(out)
    else:
        print(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
