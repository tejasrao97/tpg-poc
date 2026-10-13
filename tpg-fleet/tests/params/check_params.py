#!/usr/bin/env python3
"""Consistency of the workflow input types (tests/params/run.sh).

  1 workflows/admission/workflow-parameters.yaml is what generate.py makes of
    workflows/params/types.yaml
  1b the parameter-file schemas, examples and docs blocks are what
    workflows/params/params_schema.py makes of types.yaml and the templates
  2 every input of every WorkflowTemplate has a type, every typed input exists,
    enums agree, and every default satisfies its type
  2b the discover step of every template with clusterMap receives the filter,
     the clusterMap and (filters pairs and any) the instances inputs
  3 workflows/params/cluster-map-keys.yaml: the workflows it names take
    clusterMap, the types exist, and every default input ("flag") is an input
    of that workflow
  4 docs/workflow-commands.md: every input table row carries the Type of that
    input as types.yaml declares it, the Mandatory column (yes, no, or a condition)
    that types.yaml says (mandatory: always / conditional), the Default that the
    template declares (a cell of literals; prose needs an empty template default)
    and, for an Enum, every value of types.yaml in the Description
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
  8 no template passes a list or file input (clusters, instances, confirm, caBundleFile, ...)
    raw into a place that cannot take a bracketed list: a `when:` expression (a quote or
    bracket in an element breaks it) or a step argument (the discover step reads the
    comma-separated selection that the validate step writes, not the clusters input; the
    instances input is the one list discover parses itself)
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

# 1b the parameter-file schemas, examples and the generated blocks of the docs are what params_schema.py makes of
# types.yaml and the templates (tests/params/check_param_files.py runs the files through them)
r = subprocess.run([sys.executable, os.path.join(ROOT, "workflows/params/params_schema.py"), "--check"],
                   capture_output=True, text=True)
if r.returncode != 0:
    problems.append(r.stderr.strip() or "params_schema.py --check failed")

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
known_types = {"string", "name", "namespace", "azureName", "boolean", "integer", "posint", "quantity", "enum", "operatorVersion",
               "postgresVersion", "patchFile", "patchFileList", "kindList", "caFile", "nameList", "cidrList", "fqdnList", "stringMap",
               "cron", "k8sName", "k8sNameList", "timestamp", "lsn", "stanzaName", "backupLabel"}
# tpg-upgrade takes the default of operatorVersion and postgresVersion from
# targetVersion (validate-params.sh upgrade), not from inputs of those names
# maxReadReplicas: the input of that name exists on tpg-scale-instance only;
# tpg-day0 and tpg-create-instance take the map key alone (Round 14)
# purgeBackups: the input of that name exists on the delete workflows; tpg-backup-expire takes the map key alone (Round 23)
flag_exceptions = {("tpg-upgrade", "operatorVersion"), ("tpg-upgrade", "postgresVersion"),
                   ("tpg-day0", "maxReadReplicas"), ("tpg-create-instance", "maxReadReplicas"),
                   ("tpg-backup-expire", "purgeBackups")}
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

# 3b the restore section (tpg-restore pairs, Round 23): known types, a doc for every key, and a template with clusterMap
for side in ("source", "target"):
    for k, spec in keys["restore"][side].items():
        if spec["type"] not in known_types:
            problems.append(f"cluster-map-keys.yaml restore.{side}.{k}: unknown type {spec['type']}")
        if not spec.get("doc"):
            problems.append(f"cluster-map-keys.yaml restore.{side}.{k}: no doc")
if "clusterMap" not in templates.get("tpg-restore", {}):
    problems.append("cluster-map-keys.yaml: tpg-restore has no clusterMap input")

# 4 input tables: a table whose header starts with "| Input | Type |", inside the
# section "## N. tpg-<name>" of that WorkflowTemplate
md = open(os.path.join(ROOT, "docs/workflow-commands.md")).read()


def table_problems(md):
    """Problems of the input tables of a docs/workflow-commands.md text."""
    problems = []
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
            if len(cells) < 5:
                problems.append(f"docs/workflow-commands.md {section}: `{n}` row has no Mandatory, Default and Description cells")
                continue
            spec, tdef = typed[section][n], str(templates[section][n].get("value", ""))
            # Mandatory: yes = mandatory in every case (types.yaml mandatory: always, no default in the
            # template), no = optional, anything else = the condition (mandatory: conditional)
            got = "always" if cells[2] == "yes" else ("" if cells[2] == "no" else "conditional")
            if got != (spec.get("mandatory") or ""):
                problems.append(f"docs/workflow-commands.md {section}: `{n}` Mandatory is '{cells[2]}', types.yaml says "
                                f"'{spec.get('mandatory') or 'optional'}' (always = yes, conditional = a condition)")
            if spec.get("mandatory") == "always" and tdef != "":
                problems.append(f"{section}.{n}: mandatory: always in types.yaml but the template has the default '{tdef}'")
            # Default: a cell of literals (`a` or `a`, `b`) is the template default of the input (of each input of
            # a shared row, in order); an empty cell means the template default is empty; any other text is prose
            # (template, a computed default) and needs an empty template default
            lits = re.fullmatch(r"`([^`]*)`(?:, `([^`]*)`)*", cells[3]) and "<" not in cells[3] and re.findall(r"`([^`]*)`", cells[3])
            if lits:
                idx = names.index(n)
                exp = lits[idx] if len(lits) == len(names) else (lits[0] if len(lits) == 1 else None)
                if exp is None:
                    problems.append(f"docs/workflow-commands.md {section}: `{n}` Default '{cells[3]}' has {len(lits)} values for {len(names)} inputs")
                elif exp != tdef:
                    problems.append(f"docs/workflow-commands.md {section}: `{n}` Default is '{exp}', the template says '{tdef}'")
            elif tdef != "":
                problems.append(f"docs/workflow-commands.md {section}: `{n}` Default is '{cells[3]}', the template says '{tdef}'")
            # enum values: every value of the enum is named, in code font, in the Description
            if spec["type"] == "enum":
                for v in spec["values"]:
                    if f"`{v}`" not in cells[4]:
                        problems.append(f"docs/workflow-commands.md {section}: `{n}` Description does not name the value `{v}` (types.yaml)")
    for s, params in typed.items():
        missing = [p for p in params if p != "toolsImage" and p not in documented.get(s, set())]
        if missing:
            problems.append(f"docs/workflow-commands.md {s}: inputs without a row in an input table: {', '.join(missing)}")
    return problems


problems += table_problems(md)
# the table check finds a wrong Mandatory, Default and enum value, and a missing cell
_row = "| `pushMode` | `Enum` | yes | | `direct` or `pr` |"
assert _row in md and "| `maxParallel` | `Integer` | no | `2` |" in md
for _what, _old, _new, _want in (
        ("Mandatory", _row, _row.replace("| yes |", "| no |"), "Mandatory is 'no'"),
        ("Mandatory (condition)", _row, _row.replace("| yes |", "| yes, without `clusterMap` |"), "Mandatory is 'yes, without `clusterMap`'"),
        ("Default", "| `maxParallel` | `Integer` | no | `2` |", "| `maxParallel` | `Integer` | no | `3` |", "Default is '3', the template says '2'"),
        ("Default (empty)", _row, _row.replace("| yes | |", "| yes | `direct` |"), "Default is 'direct', the template says ''"),
        ("enum value", _row, _row.replace("`direct` or `pr`", "`direct`"), "does not name the value `pr`")):
    _found = table_problems(md.replace(_old, _new, 1))
    if not any(_want in m for m in _found):
        problems.append(f"the input table check misses a wrong {_what} ({_want}): {_found[:2]}")

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
    if w in ("day0", "create-instance"):
        # Round 23: reserved namespaces (cluster-map-keys.yaml reserved) and any name starting with kube-
        extra = {"operatorVersion": "v4.5.0"} if w == "day0" else {}
        for r in list(keys["instance"]["namespace"]["reserved"]) + ["kube-other"]:
            bad[f"the reserved namespace {r}"] = {"c1": {**extra, "instances": {"i1": {"namespace": r}}}}
    if w == "patch":
        bad.update({
            "the renamed valuesPatchFilePath": {"c1": {"instances": {"i1": {"valuesPatchFilePath": ["v.yaml"]}}}},
            "two postgresValues files": {"c1": {"instances": {"i1": {"postgresValuesPatchFilePath": ["a.yaml", "b.yaml"]}}}},
            "clearKinds all with a kind": {"c1": {"instances": {"i1": {"clearKinds": ["all", "Postgres"]}}}},
            "clearKinds [all] (all stays bare)": {"c1": {"clearKinds": ["all"]}},
            "an instance clearKinds [all]": {"c1": {"instances": {"i1": {"clearKinds": ["all"]}}}},
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
            "clearKinds all stays bare": {"c1": {"clearKinds": "all", "instances": {"i1": {"clearKinds": "all"}}}},
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

# 5b the clusterMap of tpg-restore: a list of pairs. The example passes the validator and the schema and shows
# every key of the section restore; the rules the schema can say agree with the validator on a table of maps
rsch = json.load(open(os.path.join(sdir, "clustermap-restore.schema.json")))
rex = yaml.safe_load(open(os.path.join(sdir, "clustermap-restore.example.yaml")))
rkeys = keys["restore"]
rregistered = {c for p_ in rex for side_ in p_.values() for c in side_}


def restore_validate(m):
    """The errors of clustermap.py restore for a map (a list of pairs), registered clusters c1, c2 and the example's."""
    return cmod.process_restore(json.loads(json.dumps(m)), keys_json, rregistered | {"c1", "c2"})[1]


errs = restore_validate(rex)
if errs:
    problems.append("clustermap-restore.example.yaml is refused by clustermap.py restore: " + "; ".join(errs))
shown = set()


def walk_paths(node, prefix=""):
    for k, v in node.items():
        if isinstance(v, dict) and any(x.startswith(prefix + k + ".") for x in list(rkeys["source"]) + list(rkeys["target"])):
            yield from walk_paths(v, prefix + k + ".")
        else:
            yield prefix + k


for p_ in rex:
    for side_ in p_.values():
        for ns_ in side_.values():
            for inst_ in ns_.values():
                for ns2 in inst_.values():
                    shown.update(walk_paths(ns2))
for side_ in ("source", "target"):
    for k in rkeys[side_]:
        if k not in shown:
            problems.append(f"clustermap-restore.example.yaml does not show the key {k}")
if jsonschema is not None:
    rv = jsonschema.Draft202012Validator(rsch)
    for e in rv.iter_errors(rex):
        problems.append(f"clustermap-restore.example.yaml does not match its schema: {e.message}")

    def rp(src_keys=None, tgt_keys=None, src=("c1", "pg-a", "a"), tgt=("c2", "pg-b", "b")):
        return {"sourceClusterConfig": {src[0]: {src[1]: {src[2]: src_keys or {}}}},
                "targetClusterConfig": {tgt[0]: {tgt[1]: {tgt[2]: tgt_keys or {}}}}}

    LATEST = {"pitrEnabled": True, "pitrConfig": {"type": "latest"}}
    TIME = {"pitrEnabled": True, "bestEffort": True, "pitrConfig": {"type": "time", "timestamp": "2026-09-15T08:30:00Z"}}
    LSN = {"pitrEnabled": True, "bestEffort": False, "pitrConfig": {"type": "lsn", "target": "0/3000060"}}
    XID = {"pitrEnabled": True, "bestEffort": True, "pitrConfig": {"type": "transaction", "target": "987654"}}

    def with_(base, **kw):
        out = json.loads(json.dumps(base))
        for k, v in kw.items():
            out[k] = v
        return out

    def with_cfg(base, **kw):
        out = json.loads(json.dumps(base))
        out["pitrConfig"].update(kw)
        return out

    RSD = "helm_artifacts/instance/tpg-instance/restore-specs/"
    good = {
        "latest": [rp(None, LATEST)], "time": [rp(None, TIME)], "lsn": [rp(None, LSN)], "transaction": [rp(None, XID)],
        "a named backup in the same namespace": [rp({"sourceBackupName": "b-full"}, {"pitrEnabled": False}, tgt=("c1", "pg-a", "b"), src=("c1", "pg-a", "a"))],
        "a named backup into another namespace": [rp({"sourceBackupName": "b-full"}, {"pitrEnabled": False}, tgt=("c1", "pg-b", "b"), src=("c1", "pg-a", "a"))],
        "a named backup into another cluster": [rp({"sourceBackupName": "b-full"}, {"pitrEnabled": False})],
        "a named backup with pitrEnabled absent (the default is false)": [rp({"sourceBackupName": "b-full"}, {})],
        "a named backup with pitrEnabled absent and other keys": [rp({"sourceBackupName": "b-full"}, {"skipMinorVersionCheck": True, "postRestoreBackup": True})],
        "in place": [rp(None, with_(LATEST, confirm="a"), src=("c1", "pg-a", "a"), tgt=("c1", "pg-a", "a"))],
        "a spec file for an in-place restore": [rp(None, with_(LATEST, confirm="a", targetInstanceSpecFilePath=["./a.yaml"]), src=("c1", "pg-a", "a"), tgt=("c1", "pg-a", "a"))],
        "a spec file": [rp(None, with_(LATEST, targetInstanceSpecFilePath=["./a.yaml"]))],
        "a repo spec file": [rp(None, with_(LATEST, targetInstanceSpecFilePath=["repo:" + RSD + "a.yaml"]))],
        "a repo spec file in a subfolder, .yml": [rp(None, with_(LATEST, targetInstanceSpecFilePath=["repo:" + RSD + "team/a.yml"]))],
        "a label, location and stanza": [rp(None, with_cfg(TIME, sourceBackupConfig={"srcBackupLabel": "20260915-020000F_20260916-010000I",
                                                                                  "srcBackupLocationName": "loc", "srcStanzaName": "pg-a-a-0000"}))],
        "flags as strings": [rp(None, with_(LATEST, skipMinorVersionCheck="true", postRestoreBackup=False))],
        "an integer transaction target": [rp(None, with_cfg(XID, target=987654))],
        "two pairs": [rp(None, LATEST), rp(None, LATEST, tgt=("c2", "pg-b", "b2"))],
    }
    bad = {
        "a mapping instead of a list": rp(None, LATEST),
        "an empty list": [],
        "a pair without a target": [{"sourceClusterConfig": rp()["sourceClusterConfig"]}],
        "a misspelled pair key": [{**rp(None, LATEST), "targetClusterConf": {}}],
        "two source clusters": [{"sourceClusterConfig": {"c1": {"pg-a": {"a": {}}}, "c2": {"pg-a": {"a": {}}}}, "targetClusterConfig": rp(None, LATEST)["targetClusterConfig"]}],
        "two target namespaces": [{"sourceClusterConfig": rp()["sourceClusterConfig"], "targetClusterConfig": {"c2": {"pg-b": {"b": LATEST}, "pg-c": {"b": LATEST}}}}],
        "two target instances": [{"sourceClusterConfig": rp()["sourceClusterConfig"], "targetClusterConfig": {"c2": {"pg-b": {"b": LATEST, "c": LATEST}}}}],
        "no target cluster": [{"sourceClusterConfig": rp()["sourceClusterConfig"], "targetClusterConfig": {}}],
        "an unknown source key": [rp({"sourceBackup": "x"}, LATEST)],
        "an unknown target key": [rp(None, with_(LATEST, pitrEnable=True))],
        "an unknown pitrConfig key": [rp(None, with_cfg(LATEST, taget="x"))],
        "pitrConfig with pitrEnabled absent (the default is false)": [rp({"sourceBackupName": "b-full"}, {"pitrConfig": {"type": "latest"}})],
        "bestEffort with pitrEnabled absent (the default is false)": [rp({"sourceBackupName": "b-full"}, {"bestEffort": True})],
        "pitrEnabled not a boolean": [rp(None, with_(LATEST, pitrEnabled="maybe"))],
        "pitrEnabled false with pitrConfig": [rp(None, {"pitrEnabled": False, "pitrConfig": {"type": "latest"}})],
        "pitrEnabled false with bestEffort": [rp(None, {"pitrEnabled": False, "bestEffort": True})],
        "pitrEnabled true without pitrConfig": [rp(None, {"pitrEnabled": True})],
        "pitrEnabled true without a type": [rp(None, {"pitrEnabled": True, "pitrConfig": {}})],
        "an unknown type": [rp(None, with_cfg(LATEST, type="lates"))],
        "latest with bestEffort": [rp(None, with_(LATEST, bestEffort=True))],
        "latest with a timestamp": [rp(None, with_cfg(LATEST, timestamp="2026-09-15T08:30:00Z"))],
        "latest with a target": [rp(None, with_cfg(LATEST, target="0/3000060"))],
        "latest with a backup label": [rp(None, with_cfg(LATEST, sourceBackupConfig={"srcBackupLabel": "20260915-020000F"}))],
        "time without a timestamp": [rp(None, {"pitrEnabled": True, "bestEffort": True, "pitrConfig": {"type": "time"}})],
        "time without bestEffort": [rp(None, {"pitrEnabled": True, "pitrConfig": TIME["pitrConfig"]})],
        "time with a target": [rp(None, with_cfg(TIME, target="0/3000060"))],
        "a timestamp without the time of day": [rp(None, with_cfg(TIME, timestamp="2026-09-15"))],
        "a timestamp with an offset": [rp(None, with_cfg(TIME, timestamp="2026-09-15T08:30:00+02:00"))],
        "lsn without a target": [rp(None, {"pitrEnabled": True, "bestEffort": False, "pitrConfig": {"type": "lsn"}})],
        "an lsn without a slash": [rp(None, with_cfg(LSN, target="3000060"))],
        "lsn with a timestamp": [rp(None, with_cfg(LSN, timestamp="2026-09-15T08:30:00Z"))],
        "lsn without bestEffort": [rp(None, {"pitrEnabled": True, "pitrConfig": LSN["pitrConfig"]})],
        "a transaction target that is not a number": [rp(None, with_cfg(XID, target="0/3"))],
        "transaction without a target": [rp(None, {"pitrEnabled": True, "bestEffort": True, "pitrConfig": {"type": "transaction"}})],
        "a bad backup label": [rp(None, with_cfg(TIME, sourceBackupConfig={"srcBackupLabel": "yesterday"}))],
        "a bad stanza": [rp(None, with_cfg(TIME, sourceBackupConfig={"srcStanzaName": "bad stanza"}))],
        "a spec file that is a string": [rp(None, with_(LATEST, targetInstanceSpecFilePath="./a.yaml"))],
        "two spec files": [rp(None, with_(LATEST, targetInstanceSpecFilePath=["./a.yaml", "./b.yaml"]))],
        "a spec file that is not yaml": [rp(None, with_(LATEST, targetInstanceSpecFilePath=["./a.txt"]))],
        "a repo spec file outside restore-specs": [rp(None, with_(LATEST, targetInstanceSpecFilePath=["repo:clusters/a.yaml"]))],
        "a repo spec file in the patches folder": [rp(None, with_(LATEST, targetInstanceSpecFilePath=["repo:helm_artifacts/instance/tpg-instance/patches/a.yaml"]))],
        "a repo spec file with ..": [rp(None, with_(LATEST, targetInstanceSpecFilePath=["repo:" + RSD + "../patches/a.yaml"]))],
        "an absolute repo spec file": [rp(None, with_(LATEST, targetInstanceSpecFilePath=["repo:/" + RSD + "a.yaml"]))],
        "a repo spec file with //": [rp(None, with_(LATEST, targetInstanceSpecFilePath=["repo:" + RSD + "/a.yaml"]))],
        "the README of restore-specs as spec file": [rp(None, with_(LATEST, targetInstanceSpecFilePath=["repo:" + RSD + "README.md"]))],
        "a spec file entry YAML reads as a mapping ([repo: x.yaml])": [rp(None, with_(LATEST, targetInstanceSpecFilePath=[{"repo": "a.yaml"}]))],
        "a confirm that is not a name": [rp(None, with_(LATEST, confirm="Bad_Name"))],
        "postRestoreBackup not a boolean": [rp(None, with_(LATEST, postRestoreBackup="yes please"))],
        "a cluster name in capitals": [rp(None, LATEST, tgt=("C2", "pg-b", "b"))],
        "an instance name with _": [rp(None, LATEST, tgt=("c2", "pg-b", "b_1"))],
        "a target namespace that is not a DNS label": [rp(None, LATEST, tgt=("c2", "PG_b", "b"))],
    }
    for ns_ in list(keys["instance"]["namespace"]["reserved"]) + ["kube-other"]:
        bad[f"the reserved target namespace {ns_}"] = [rp(None, LATEST, tgt=("c2", ns_, "b"))]
    # refused by the validator only: the schema cannot relate the two sides of a pair
    vbad = {
        "a named backup (pitrEnabled false) without sourceBackupName": [rp(None, {"pitrEnabled": False})],
        "a named backup (pitrEnabled absent) without sourceBackupName": [rp(None, {})],
    }
    for what, m in vbad.items():
        if not restore_validate(m):
            problems.append(f"clustermap.py restore accepts {what}")
    for what, m in good.items():
        for e in rv.iter_errors(m):
            problems.append(f"clustermap-restore.schema.json refuses {what}: {e.message}")
        ve = restore_validate(m)
        if ve:
            problems.append(f"clustermap.py restore refuses {what}: {'; '.join(ve)}")
    for what, m in bad.items():
        if rv.is_valid(m):
            problems.append(f"clustermap-restore.schema.json accepts {what}")
        if not restore_validate(m):
            problems.append(f"clustermap.py restore accepts {what}")

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

# 8 list and file inputs reach scripts through the environment only
def _list_input_problems(doc, list_names):
    """Problems of one WorkflowTemplate document: raw list inputs in when: expressions and step arguments."""
    out = []
    ref = re.compile(r"\{\{\s*workflow\.parameters\.([A-Za-z0-9_]+)\s*\}\}")

    def walk(x, path=""):
        if isinstance(x, dict):
            if isinstance(x.get("when"), str):
                for n in ref.findall(x["when"]):
                    if n in list_names:
                        out.append(f"{path or x.get('name', '?')}: when: interpolates the list input {n}; decide it in the validate step (an output parameter)")
            to = x.get("templateRef", {}).get("template") or x.get("template")
            for a in (x.get("arguments") or {}).get("parameters", []) if isinstance(x.get("arguments"), dict) else []:
                for n in ref.findall(str(a.get("value", ""))):
                    if n not in list_names:
                        continue
                    if to == "discover" and a.get("name") == "instances" and n == "instances":
                        continue         # the one list input discover.sh parses itself (lib.sh list_items)
                    out.append(f"{path or x.get('name', '?')}: step argument {a.get('name')} passes the list input {n} raw"
                               + (" to discover; pass {{steps.validate.outputs.parameters.selection}}" if to == "discover" and n == "clusters" else ""))
            for k, v in x.items():
                walk(v, x.get("name", path) if isinstance(x.get("name"), str) else path)
        elif isinstance(x, list):
            for v in x:
                walk(v, path)

    walk(doc.get("spec", {}))
    return out


for f in sorted(glob.glob(os.path.join(ROOT, "workflows", "templates", "*.yaml"))):
    doc = yaml.safe_load(open(f))
    name = doc["metadata"]["name"]
    list_names = {pn for pn, ts in typed.get(name, {}).items() if types[ts["type"]].get("display", "").startswith("List")}
    for msg in _list_input_problems(doc, list_names):
        problems.append(f"{name}: {msg}")
# the check itself finds the Round 23 review's two defects
_bad = yaml.safe_load("""
spec:
  templates:
  - name: main
    steps:
    - - name: write
        template: write-secret
        when: "'{{workflow.parameters.caBundleFile}}' != ''"
    - - name: discover
        templateRef: {name: tpg-lib, template: discover}
        arguments:
          parameters:
          - {name: clusters, value: "{{workflow.parameters.clusters}}"}
          - {name: instances, value: "{{workflow.parameters.instances}}"}
""")
_found = _list_input_problems(_bad, {"clusters", "instances", "caBundleFile"})
if len(_found) != 2 or not any("when: interpolates the list input caBundleFile" in m for m in _found) \
        or not any("passes the list input clusters raw to discover" in m for m in _found):
    problems.append(f"the list-input template check misses a raw when:/discover argument: {_found}")

for p in problems:
    print(p)
sys.exit(1 if problems else 0)
