#!/usr/bin/env python3
"""Consistency of the workflow input types (tests/params/run.sh).

  1 workflows/admission/workflow-parameters.yaml is what generate.py makes of
    workflows/params/types.yaml
  2 every input of every WorkflowTemplate has a type, every typed input exists,
    enums agree, and every default satisfies its type
  2b the discover step of every template with clusterMap receives the filter,
     the clusterMap and (filters pairs and any) the instances inputs
  3 workflows/params/cluster-map-keys.yaml: the workflows it names take
    clusterMap, the types exist, and every default input ("flag") is an input
    of that workflow
  4 docs/workflow-commands.md: every input table row carries the Type of that
    input as types.yaml declares it
  5 the clusterMap schemas, examples and the key reference of the docs are what
    workflows/params/clustermap_schema.py makes of cluster-map-keys.yaml; every
    example passes clustermap.py validate and its schema; maps the validate step
    refuses for their shape are refused by the schema as well (jsonschema, when
    installed)
  6 the write step of tpg-rotate-credential (ServiceAccount tpg-credential-writer)
    runs a fixed image equal to the default of toolsImage, and no other template
    names that ServiceAccount
  7 no YAML file under workflows/params repeats a mapping key (dupkeys.py): the
    parsers keep the last duplicate silently, which hid the fleet path of
    backupEnableSSL under disableInitialBackup
Prints one line per problem; exit 1 when there is any.
"""
import glob
import os
import re
import subprocess
import sys

import yaml

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dupkeys  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
problems = []

# 1
r = subprocess.run([sys.executable, os.path.join(ROOT, "workflows/params/generate.py"), "--check"],
                   capture_output=True, text=True)
if r.returncode != 0:
    problems.append(r.stderr.strip() or "generate.py --check failed")

src = yaml.safe_load(open(os.path.join(ROOT, "workflows/params/types.yaml")))
types, typed = src["types"], src["templates"]


def type_ok(spec, value):
    t = spec["type"]
    if value == "" and spec.get("allowEmpty"):
        return True
    if t == "string":
        return True
    if t == "enum":
        return value in [str(v) for v in spec["values"]]
    pat = types[t]["pattern"]
    # CEL uses RE2; these patterns are also valid Python regular expressions
    if not re.search(pat, value):
        return False
    # excludeAll: all is a keyword, not a name, inside the brackets ([a, all]); a bare all is valid
    # where the type has bare: all (the CEL of generate.py does the same)
    if types[t].get("excludeAll") and not (types[t].get("bare") == "all" and value.strip() == "all") \
            and any(re.match(r'^[\[\s"\x27]*all[\]\s"\x27]*$', x) for x in value.split(",")):
        return False
    return True


# 2
templates = {}
for f in sorted(glob.glob(os.path.join(ROOT, "workflows/templates/*.yaml"))):
    doc = yaml.safe_load(open(f))
    name = doc["metadata"]["name"]
    if name == "tpg-lib":
        continue
    params = {p["name"]: p for p in doc["spec"].get("arguments", {}).get("parameters", [])}
    templates[name] = params
    if name not in typed:
        problems.append(f"{name}: no entry in workflows/params/types.yaml")
        continue
    for p, spec in params.items():
        if p not in typed[name]:
            problems.append(f"{name}.{p}: input without a type in types.yaml")
            continue
        ts = typed[name][p]
        default = str(spec.get("value", ""))
        if not type_ok(ts, default):
            problems.append(f"{name}.{p}: default '{default}' is not {types[ts['type']]['describe']}")
        if "enum" in spec:
            tenum = [str(v) for v in spec["enum"] if str(v) != ""]
            if ts["type"] == "enum":
                if sorted(tenum) != sorted(str(v) for v in ts["values"]):
                    problems.append(f"{name}.{p}: enum {tenum} differs from types.yaml {ts['values']}")
            elif ts["type"] == "boolean":
                if sorted(tenum) != ["false", "true"]:
                    problems.append(f"{name}.{p}: boolean enum {tenum}")
            else:
                problems.append(f"{name}.{p}: the template has an enum but types.yaml says {ts['type']}")
            if "" in [str(v) for v in spec["enum"]] and not ts.get("allowEmpty"):
                problems.append(f"{name}.{p}: the enum allows empty but types.yaml has no allowEmpty")
    for p in typed[name]:
        if p not in params:
            problems.append(f"{name}.{p}: typed in types.yaml but not an input of the template")
for name in typed:
    if name not in templates:
        problems.append(f"types.yaml: {name} is not a WorkflowTemplate")

# 2b the discover step of a template that selects instances receives the selection
def _discover_steps(x):
    if isinstance(x, dict):
        if x.get("templateRef", {}).get("template") == "discover":
            yield {p["name"]: str(p.get("value", "")) for p in x.get("arguments", {}).get("parameters", [])}
        for v in x.values():
            yield from _discover_steps(v)
    elif isinstance(x, list):
        for v in x:
            yield from _discover_steps(v)


for f in sorted(glob.glob(os.path.join(ROOT, "workflows/templates/*.yaml"))):
    doc = yaml.safe_load(open(f))
    name = doc["metadata"]["name"]
    params = templates.get(name, {})
    if "clusterMap" not in params:
        continue
    for args in _discover_steps(doc):
        flt = args.get("filter", "")
        if not flt:
            problems.append(f"{name}: the discover step has no filter, so instances and clusterMap are ignored")
            continue
        if flt != "off" and "clusterMap" not in args:
            problems.append(f"{name}: the discover step (filter {flt}) does not receive clusterMap")
        if flt in ("pairs", "any") and "instances" in params and "instances" not in args:
            problems.append(f"{name}: the discover step (filter {flt}) does not receive instances")

# 3
keys = yaml.safe_load(open(os.path.join(ROOT, "workflows/params/cluster-map-keys.yaml")))
tmpl = {"scale": "tpg-scale-instance"}
known_types = {"string", "name", "azureName", "boolean", "integer", "posint", "quantity", "enum", "operatorVersion",
               "postgresVersion", "patchFile", "patchFileList", "kindList", "caFile", "nameList", "cidrList", "fqdnList", "stringMap",
               "cron", "k8sName"}
# tpg-upgrade takes the default of operatorVersion and postgresVersion from
# targetVersion (validate-params.sh upgrade), not from inputs of those names
# maxReadReplicas: the input of that name exists on tpg-scale-instance only;
# tpg-day0 and tpg-create-instance take the map key alone (Round 14)
flag_exceptions = {("tpg-upgrade", "operatorVersion"), ("tpg-upgrade", "postgresVersion"),
                   ("tpg-day0", "maxReadReplicas"), ("tpg-create-instance", "maxReadReplicas")}
for w in keys["workflows"]:
    t = tmpl.get(w, "tpg-" + w)
    if "clusterMap" not in templates.get(t, {}):
        problems.append(f"cluster-map-keys.yaml: {t} has no clusterMap input")
for level in ("cluster", "instance"):
    for k, spec in keys[level].items():
        if spec["type"] not in known_types:
            problems.append(f"cluster-map-keys.yaml {level}.{k}: unknown type {spec['type']}")
        for w in spec.get("workflows", {}):
            if w not in keys["workflows"]:
                problems.append(f"cluster-map-keys.yaml {level}.{k}: unknown workflow {w}")
                continue
            t = tmpl.get(w, "tpg-" + w)
            flag = spec.get("flag", k)
            if flag and (t, k) not in flag_exceptions and flag not in templates.get(t, {}) \
                    and spec["workflows"][w] != "guard":
                problems.append(f"cluster-map-keys.yaml {level}.{k}: default input {flag} is not an input of {t}")

# 4 input tables: a table whose header starts with "| Input | Type |", inside the
# section "## N. tpg-<name>" of that WorkflowTemplate
md = open(os.path.join(ROOT, "docs/workflow-commands.md")).read()
section, in_table = None, False
documented = {s: set() for s in typed}
for line in md.splitlines():
    m = re.match(r"^## \d+\. (tpg-[a-z0-9-]+)", line)
    if line.startswith("## "):
        section = m.group(1) if m else None
        in_table = False
        continue
    if not line.startswith("|"):
        in_table = False
        continue
    if re.match(r"^\| Input \| Type \|", line):
        in_table = True
        if section not in typed:
            problems.append(f"docs/workflow-commands.md: an input table outside a tpg-<name> section ({section})")
        continue
    if not in_table or section not in typed or line.startswith("|---"):
        continue
    cells = [c.strip() for c in line.strip().strip("|").split("|")]
    names = re.findall(r"`([A-Za-z]+)`", cells[0])
    if not names:
        problems.append(f"docs/workflow-commands.md {section}: input row without an input name: {line}")
    for n in names:
        documented[section].add(n)
        if n not in typed[section]:
            problems.append(f"docs/workflow-commands.md {section}: `{n}` is not an input of the template")
            continue
        want = types[typed[section][n]["type"]]["display"]
        if cells[1].strip("`") != want:
            problems.append(f"docs/workflow-commands.md {section}: `{n}` Type is '{cells[1]}', types.yaml says '{want}'")
for s, params in typed.items():
    missing = [p for p in params if p != "toolsImage" and p not in documented.get(s, set())]
    if missing:
        problems.append(f"docs/workflow-commands.md {s}: inputs without a row in an input table: {', '.join(missing)}")

# 5
r = subprocess.run([sys.executable, os.path.join(ROOT, "workflows/params/clustermap_schema.py"), "--check"],
                   capture_output=True, text=True)
if r.returncode != 0:
    problems.append(r.stderr.strip() or "clustermap_schema.py --check failed")
import importlib.util
import json
import tempfile
_s = importlib.util.spec_from_file_location("clustermap", os.path.join(ROOT, "workflows/scripts/clustermap.py"))
cmod = importlib.util.module_from_spec(_s)
_s.loader.exec_module(cmod)
try:
    import jsonschema
except ImportError:
    jsonschema = None
    print("note: python3 jsonschema not installed: the examples and maps are not checked against the schemas", file=sys.stderr)
if jsonschema is not None and not hasattr(jsonschema, "Draft202012Validator"):
    # the schemas are draft 2020-12: jsonschema before 4.0 cannot check them
    print(f"note: python3 jsonschema {getattr(jsonschema, '__version__', '?')} is older than 4.0 (no Draft202012Validator): the examples and maps are not checked against the schemas (pip install 'jsonschema>=4')", file=sys.stderr)
    jsonschema = None
sdir = os.path.join(ROOT, "workflows/params/schemas")
keys_json = json.loads(json.dumps(keys))
for w in keys["workflows"]:
    ex = yaml.safe_load(open(os.path.join(sdir, f"clustermap-{w}.example.yaml")))
    with tempfile.TemporaryDirectory() as td:
        mp, kp, rp = (os.path.join(td, n) for n in ("m.json", "k.json", "r"))
        json.dump(ex, open(mp, "w")); json.dump(keys_json, open(kp, "w")); open(rp, "w").write("aks-tpg-poc-01\n")
        r = subprocess.run([sys.executable, os.path.join(ROOT, "workflows/scripts/clustermap.py"), "validate",
                            "--workflow", w, "--map", mp, "--keys", kp, "--registered", rp, "--out", os.path.join(td, "o.json")],
                           capture_output=True, text=True)
        if r.returncode != 0:
            problems.append(f"clustermap-{w}.example.yaml is refused by clustermap.py: {(r.stdout + r.stderr).strip()}")
    sch = json.load(open(os.path.join(sdir, f"clustermap-{w}.schema.json")))
    inst_keys = {k for k, v in keys["instance"].items() if w in v["workflows"]}
    got = set(sch["additionalProperties"]["properties"]["instances"]["additionalProperties"]["properties"])
    if got != inst_keys:
        problems.append(f"clustermap-{w}.schema.json: instance keys differ from cluster-map-keys.yaml: {sorted(got ^ inst_keys)}")
    if jsonschema is None:
        continue
    v = jsonschema.Draft202012Validator(sch)
    for e in v.iter_errors(ex):
        problems.append(f"clustermap-{w}.example.yaml does not match its schema: {e.message}")
    # shapes the validate step refuses: the schema refuses them too
    bad = {
        "a misspelled key": {"aks-tpg-poc-01": {"instances": {"orders-db": {"postgresVerison": "17.6"}}}},
        "an instance name with _": {"aks-tpg-poc-01": {"instances": {"orders_db": {}}}},
        "a key set to null": {"aks-tpg-poc-01": {"instances": {"orders-db": {"postgresVersion": None}}}},
    }
    if w in ("day0", "create-instance", "network-policy"):
        # Round 23: a list is a sequence, also with one value; a string is refused
        bad["a comma-separated string for a list"] = {"c1": {"instances": {"i1": {"ingressFromNamespaces": "app,batch"}}}}
        bad["one bare name for a list"] = {"c1": {"instances": {"i1": {"ingressFromCidrs": "10.1.0.0/16"}}}}
        bad["a bracketed string for a list (a string, not a sequence)"] = {"c1": {"instances": {"i1": {"egressToFqdns": "[api.example.com]"}}}}
        bad["an empty list"] = {"c1": {"instances": {"i1": {"egressToCidrs": []}}}}
    if w == "patch":
        bad.update({
            "the renamed valuesPatchFilePath": {"c1": {"instances": {"i1": {"valuesPatchFilePath": ["v.yaml"]}}}},
            "two postgresValues files": {"c1": {"instances": {"i1": {"postgresValuesPatchFilePath": ["a.yaml", "b.yaml"]}}}},
            "clearKinds all with a kind": {"c1": {"instances": {"i1": {"clearKinds": ["all", "Postgres"]}}}},
            "a repo: file outside helm_artifacts/instance/tpg-instance/patches": {"c1": {"instances": {"i1": {"postgresPatchFilePath": ["repo:clusters/fleet.yaml"]}}}},
            "an operator file under helm_artifacts/operator/patches/clusters": {"c1": {"operatorValuesPatchFilePath": ["repo:helm_artifacts/operator/patches/clusters/c1.yaml"]}},
            "an operator patch file under helm_artifacts/operator/overlays/clusters": {"c1": {"operatorValuesPatchFilePath": ["repo:helm_artifacts/operator/overlays/clusters/c1.yaml"]}},
            "an empty postgres file list": {"c1": {"instances": {"i1": {"postgresPatchFilePath": []}}}},
            "a comma-separated string of postgres files": {"c1": {"instances": {"i1": {"postgresPatchFilePath": "a.yaml,b.yaml"}}}},
            "a single file that is a string": {"c1": {"instances": {"i1": {"postgresValuesPatchFilePath": "v.yaml"}}}},
            "a repo: entry YAML reads as a mapping ([repo: x.yaml])": {"c1": {"instances": {"i1": {"postgresPatchFilePath": [{"repo": "helm_artifacts/instance/tpg-instance/patches/x.yaml"}]}}}},
            "clearKinds as a comma-separated string": {"c1": {"clearKinds": "Postgres,postgresValues"}},
        })
    if w == "day0":
        bad["the renamed enableSSL"] = {"c1": {"instances": {"i1": {"enableSSL": True}}}}
        bad["a CA bundle that is not a PEM file"] = {"c1": {"instances": {"i1": {"backupCaBundleFile": ["ca.txt"]}}}}
        bad["a cluster without instances"] = {"c1": {"operatorVersion": "v4.5.0"}}
        bad["the old postgresPatchFilePath (Round 22: postgresOverlayFilePath)"] = {"c1": {"operatorVersion": "v4.5.0", "instances": {"i1": {"postgresPatchFilePath": ["a.yaml"]}}}}
        bad["an operator overlay file under helm_artifacts/operator/overlays/clusters"] = {"c1": {"operatorVersion": "v4.5.0", "operatorValuesOverlayFilePath": ["repo:helm_artifacts/operator/overlays/clusters/c1.yaml"], "instances": {"i1": {}}}}
        bad["an operator overlay file under helm_artifacts/operator/patches/clusters"] = {"c1": {"operatorVersion": "v4.5.0", "operatorValuesOverlayFilePath": ["repo:helm_artifacts/operator/patches/clusters/c1.yaml"], "instances": {"i1": {}}}}
        bad["the old operatorValuesPatchFilePath (Round 22: operatorValuesOverlayFilePath)"] = {"c1": {"operatorVersion": "v4.5.0", "operatorValuesPatchFilePath": ["o.yaml"], "instances": {"i1": {}}}}
    for what, m in bad.items():
        if v.is_valid(m):
            problems.append(f"clustermap-{w}.schema.json accepts {what}")
    good = {}
    if w == "patch":
        good = {"lists and every path form": {"c1": {"clearKinds": ["operatorValues"], "instances": {"i1": {
            "postgresPatchFilePath": ["/tmp/a.yaml", "~/b.yml", "../c.yaml", "repo:helm_artifacts/instance/tpg-instance/patches/d.yaml"],
            "postgresValuesPatchFilePath": ["repo:helm_artifacts/instance/tpg-instance/patches/v.yaml"], "backupCaBundleFile": ["../ca.crt"]}}}},
            "clearKinds all stays bare": {"c1": {"clearKinds": "all", "instances": {"i1": {"clearKinds": ["all"]}}}},
            "one value in a list": {"c1": {"instances": {"i1": {"postgresPatchFilePath": ["a.yaml"]}}}}}
    if w == "day0":
        good = {"YAML numbers and booleans as strings": {"c1": {"operatorVersion": "4.5.0", "instances": {"i1": {
            "postgresVersion": 16.10, "highAvailability": "true", "readReplicas": "2", "cpu": 2,
            "operatorIncrementalSchedule": "none"}}}},
            "every overlay form": {"c1": {"operatorVersion": "v4.5.0", "operatorValuesOverlayFilePath": ["repo:helm_artifacts/operator/overlays/t.yaml"], "instances": {"i1": {
                "postgresOverlayFilePath": ["/tmp/a.yaml", "~/b.yml", "repo:helm_artifacts/instance/tpg-instance/overlays/d.yaml"],
                "postgresValuesOverlayFilePath": ["repo:helm_artifacts/instance/tpg-instance/overlays/v.yaml"],
                "ingressFromNamespaces": ["app"], "allowedSourceRanges": ["10.0.0.0/8"], "egressToFqdns": ["api.example.com", "*.example.org"]}}}}}
    for what, m in good.items():
        for e in v.iter_errors(m):
            problems.append(f"clustermap-{w}.schema.json refuses {what}: {e.message}")

# 6 the writer step: a fixed image, the only template that runs as the writer
for f in sorted(glob.glob(os.path.join(ROOT, "workflows", "templates", "*.yaml"))):
    doc = yaml.safe_load(open(f))
    spec = doc.get("spec", {})
    tools = next((p.get("value") for p in spec.get("arguments", {}).get("parameters", []) if p.get("name") == "toolsImage"), None)
    for t in spec.get("templates", []):
        if t.get("serviceAccountName") != "tpg-credential-writer":
            continue
        where = f"{os.path.basename(f)} template {t.get('name')}"
        if doc["metadata"]["name"] != "tpg-rotate-credential" or t.get("name") != "write-secret":
            problems.append(f"{where}: only tpg-rotate-credential write-secret may run as tpg-credential-writer")
        img = (t.get("container") or {}).get("image", "")
        if "{{" in img or img != tools:
            problems.append(f"{where}: image {img!r} must be fixed and equal to the toolsImage default {tools!r}")

# 7
try:
    yaml.load("a: 1\nb: 2\na: 3\n", Loader=dupkeys.UniqueKeyLoader)
    problems.append("dupkeys.UniqueKeyLoader accepts a repeated mapping key")
except dupkeys.DuplicateKey:
    pass
for f in sorted(glob.glob(os.path.join(ROOT, "workflows", "params", "**", "*.y*ml"), recursive=True)):
    msg = dupkeys.check_file(f)
    if msg:
        problems.append(os.path.relpath(msg, ROOT) if msg.startswith(ROOT) else msg)

for p in problems:
    print(p)
sys.exit(1 if problems else 0)
