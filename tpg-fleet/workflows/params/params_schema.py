#!/usr/bin/env python3
"""The parameter-file schema of each workflow, generated from types.yaml and the WorkflowTemplates
(Round 23, phase 7a; locked decision 6).

  python3 workflows/params/params_schema.py          write the files below
  python3 workflows/params/params_schema.py --check  exit 1 when one is out of date

Writes, per WorkflowTemplate tpg-W (W = the name without tpg-: day0, create-instance, upgrade, patch,
scale-instance, network-policy, delete-apps, delete-instance, helm-addons, backup, restore,
rotate-credential, backup-expire):
  workflows/params/schemas/params-W.schema.json   JSON Schema (draft 2020-12) of the parameter file
  workflows/params/schemas/params-W.schema.yaml   the same schema as YAML
  workflows/params/schemas/params-W.example.yaml  worked example 1: a dry run (the least-impact valid run
                                                  for a workflow without dryRun) with flat inputs
and, in the section "## N. tpg-W" of docs/workflow-commands.md, the block between
  <!-- BEGIN GENERATED: params-W --> and <!-- END GENERATED: params-W -->
right after the input table of the section (the schema path, the check-jsonschema command and the
example file). The section is found by its workflow name, so renumbering the document changes nothing;
when the block is missing, the generator inserts it after the input table (--check reports it).

A parameter file is what `argo submit --parameter-file` reads: a YAML mapping of input name to value.
The schema describes it as the run accepts it, which was verified against argo 4.1.3 (tests/params):
  - the argo CLI turns every value into a string: true -> "true", 5 -> "5", a YAML sequence -> its
    compact JSON text (["a","b"]), a mapping -> its compact JSON text; the schema therefore accepts the
    quoted string and the YAML boolean or integer for Boolean and Integer inputs, and a list input as
    its bracketed string or a YAML sequence of the element (a YAML flow list [a, b] is a sequence);
  - an unquoted decimal is not accepted for versions and quantities: argo reads 17.10 as the float 17.1
    and 1.0 as 1, so versions and decimals are quoted strings;
  - clusterMap, and every other Map input, is a string (a block, clusterMap: |); patchFiles and apps,
    the JSON inputs, are the JSON text or a mapping;
  - patterns are the ones of the admission policy (types.yaml), so both accept the same strings.
`required` lists the inputs that are mandatory in every case (types.yaml mandatory: always); inputs that
are mandatory only in some cases (without clusterMap, for one mode, ...) and the combinations of inputs
(types.yaml rules) are left to the validate step of the workflow and the admission policy, which remain
the authority. Needs PyYAML.
"""
import argparse
import json
import os
import re
import sys

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
SRC = os.path.join(HERE, "types.yaml")
TEMPLATES = os.path.join(ROOT, "workflows", "templates")
OUT_DIR = os.path.join(HERE, "schemas")
DOC = os.path.join(ROOT, "docs", "workflow-commands.md")
SCHEMA_URL = "https://github.com/<org>/tpg-fleet/workflows/params/schemas/params-{w}.schema.json"

# the quote characters an element of a bracketed list may carry, as in the patterns of types.yaml
Q = r'["\x27]?'
# a list element that is the keyword all (inside the brackets it is not a name), as the CEL of generate.py reads it
ALL_ELEMENT = r'(^|,)[\[\s"\x27]*all[\]\s"\x27]*(,|$)'


def w_of(template):
    return template[len("tpg-"):]


# ---- worked example 1 of each workflow (the dry run, or the least-impact valid run)
# (key, value[, comment]): a list is written as a YAML flow sequence, "true", "false" and numbers quoted
# (section 2 of docs/workflow-commands.md), a Block as a literal block (clusterMap: |).
class Block(str):
    pass


EXAMPLES = {
    "tpg-day0": ("A dry run on one cluster: validation, the fleet.yaml diff and the pre-check; nothing is written.", [
        ("clusters", ["aks-tpg-poc-01"]), ("instances", ["orders-db"]),
        ("highAvailability", "true"), ("readReplicas", "1"),
        ("operatorVersion", "v4.5.0"), ("postgresVersion", "postgres-17.6"),
        ("pushMode", "direct"), ("dryRun", "true")]),
    "tpg-create-instance": ("A dry run: one single-node instance on one cluster.", [
        ("clusters", ["aks-tpg-poc-01"]), ("instances", ["reports-db"]),
        ("highAvailability", "false"), ("postgresVersion", "postgres-17.6"),
        ("pushMode", "direct"), ("dryRun", "true")]),
    "tpg-upgrade": ("A dry run: the operator of one cluster.", [
        ("component", "operator"), ("targetVersion", "v4.5.1"),
        ("clusters", ["aks-tpg-poc-01"]), ("pushMode", "direct"), ("dryRun", "true")]),
    "tpg-patch": ("A dry run: remove the schedule documents of one instance (no files to pack).", [
        ("clusters", ["aks-tpg-poc-01"]), ("instances", ["orders-db"]),
        ("patchMode", "clear"), ("clearKinds", ["PostgresBackupSchedule"]),
        ("pushMode", "direct"), ("dryRun", "true")]),
    "tpg-scale-instance": ("A dry run: scale one instance to 2 read replicas.", [
        ("clusters", ["aks-tpg-poc-01"]), ("instances", ["orders-db"]),
        ("replicas", "2"), ("pushMode", "direct"), ("dryRun", "true")]),
    "tpg-network-policy": ("A dry run: the baseline policy for one instance, clients from the namespace orders-app.", [
        ("clusters", ["aks-tpg-poc-01"]), ("instances", ["orders-db"]),
        ("mode", "apply"), ("ingressFromNamespaces", ["orders-app"]),
        ("pushMode", "direct"), ("dryRun", "true")]),
    "tpg-delete-apps": ("A dry run: the plan to remove one instance of one cluster, keeping its volumes and namespace.", [
        ("clusters", ["aks-tpg-poc-01"]),
        ("apps", '{"aks-tpg-poc-01": ["tpg-instances:orders-db"]}'),
        ("confirm", ["aks-tpg-poc-01"]),
        ("purgePvcs", "false"), ("purgeNamespace", "false"),
        ("pushMode", "direct"), ("dryRun", "true")]),
    "tpg-delete-instance": ("No dryRun input. The least-impact run: one instance, a final backup, volumes and namespace kept.", [
        ("clusters", ["aks-tpg-poc-01"]), ("instances", ["orders-db"]),
        ("confirm", ["orders-db"]), ("finalBackup", "true"),
        ("purgePvcs", "false"), ("purgeNamespace", "false"), ("pushMode", "direct")]),
    "tpg-helm-addons": ("A dry run: cert-manager on one cluster.", [
        ("clusters", ["aks-tpg-poc-01"]), ("components", ["cert-manager"]), ("dryRun", "true")]),
    "tpg-backup": ("No dryRun input. The least-impact run: a full backup of one instance.", [
        ("clusters", ["aks-tpg-poc-01"]), ("instances", ["orders-db"]), ("backupType", "full")]),
    "tpg-restore": ("A dry run: one pair, a named backup restored into a new instance of the same namespace "
                    "(dryRun is true by default; nothing changes).", [
        ("clusterMap", Block("""\
- sourceClusterConfig:
    aks-tpg-poc-01:
      pg-orders-db:
        orders-db:
          sourceBackupName: orders-db-full-20260914000000
  targetClusterConfig:
    aks-tpg-poc-01:
      pg-orders-db:
        orders-db-restored: {}
""")), ("dryRun", "true")]),
    "tpg-rotate-credential": ("No dryRun input. The least-impact run: verify a value that was written in Vault by hand, on one cluster.", [
        ("secretType", "git-read"), ("clusters", ["aks-tpg-poc-01"])]),
    "tpg-backup-expire": ("A dry run: the plan to expire one backup with its dependents (dryRun is true by default).", [
        ("clusterMap", Block("""\
aks-tpg-poc-01:
  instances:
    orders-db:
      backups: [orders-db-full-202609010100]
      includeDependents: true
""")), ("dryRun", "true")]),
}


def scalar(v):
    """A YAML scalar: "true", "false" and numbers in double quotes (section 2 of the docs), else as dumped."""
    if v in ("true", "false") or re.fullmatch(r"[0-9]+", v):
        return f'"{v}"'
    return yaml.safe_dump(v, width=10000, default_flow_style=True).replace("\n...\n", "").rstrip("\n")


def example_of(template):
    w = w_of(template)
    intro, items = EXAMPLES[template]
    lines = [f"# yaml-language-server: $schema=params-{w}.schema.json",
             f"# {template}: {intro}",
             "# A parameter file of the argo CLI (generated by workflows/params/params_schema.py; see",
             f"# params-{w}.schema.json). Submit it with:",
             f"#   argo submit -n argo --from workflowtemplate/{template} --parameter-file params-{w}.example.yaml --watch"]
    for key, value in items:
        if isinstance(value, Block):
            lines.append(f"{key}: |")
            lines += [("  " + ln) if ln else ln for ln in value.rstrip("\n").split("\n")]
        elif isinstance(value, list):
            lines.append(f"{key}: [{', '.join(value)}]")
        else:
            lines.append(f"{key}: {scalar(value)}")
    return "\n".join(lines) + "\n"


# ---- the schema
def list_shape(pattern):
    """(element pattern, one element only, bare keyword) of a list type pattern of types.yaml.
    The pattern is rebuilt from the parts and must equal the original, so a new shape fails loudly."""
    m = re.search(r'\\\[\\s\*\["\\x27\]\?(.+?)\["\\x27\]\?(?:\(\\s\*,|\\s\*\\\])', pattern)
    if not m:
        raise SystemExit(f"types.yaml: no list shape in the pattern {pattern}")
    item = m.group(1)
    one = rf'\[\s*{Q}{item}{Q}\s*\]'
    many = rf'\[\s*{Q}{item}{Q}(\s*,\s*{Q}{item}{Q})*\s*\]'
    for bracket, single in ((many, False), (one, True)):
        if pattern == rf'^\s*{bracket}\s*$':
            return item, single, None
        m2 = re.fullmatch(r'\^\\s\*\((\w+)\|' + re.escape(bracket) + r'\)\\s\*\$', pattern)
        if m2:
            return item, single, m2.group(1)
    raise SystemExit(f"types.yaml: the list pattern {pattern} is not the shape params_schema.py knows (element {item})")


def string_schema(pattern):
    return {"type": "string", "pattern": pattern}


def boolean_schema(allow_empty):
    return {"enum": [True, False, "true", "false"] + ([""] if allow_empty else [])}


def value_schema(spec, types, name):
    """The schema of one input's value, without description and default."""
    t = spec["type"]
    ty = types[t]
    empty = bool(spec.get("allowEmpty"))
    if t == "string":
        return {"type": "string"}
    if t == "enum":
        vals = [str(v) for v in spec["values"]]
        vals += [v == "true" for v in vals if v in ("true", "false")]
        return {"enum": vals + ([""] if empty else [])}
    if t == "boolean":
        return boolean_schema(empty)
    if t in ("integer", "posint"):
        lo = 1 if t == "posint" else 0
        alts = [{"type": "integer", "minimum": lo}, string_schema(ty["pattern"])]
    elif t == "quantity":
        # a YAML integer is "2"; a decimal must be quoted ("0.5"): argo prints a float its own way
        alts = [{"type": "integer", "minimum": 0}, string_schema(ty["pattern"])]
    elif t == "jsonMap":
        # the JSON text, or a mapping (argo sends it as its compact JSON text); pack-patch-files.sh writes the text
        obj = {"type": "object", "minProperties": 1}
        if name == "patchFiles":
            obj["additionalProperties"] = {"type": "string"}
        elif name == "apps":
            obj["additionalProperties"] = {"type": "array", "items": {"type": "string"}}
        alts = [string_schema(ty["pattern"]), obj]
    elif ty["display"].startswith("List") and "[" in ty["pattern"] and t != "pairList":
        item, single, bare = list_shape(ty["pattern"])
        item_s = {"type": "string", "pattern": f"^{item}$"}
        brackets = string_schema(ty["pattern"])
        alts = []
        if ty.get("excludeAll"):
            item_s["not"] = {"const": "all"}
            brackets["not"] = {"pattern": ALL_ELEMENT}
            if ty.get("bare") == "all":
                alts.append(string_schema(r"^\s*all\s*$"))
        alts.append(brackets)
        arr = {"type": "array", "minItems": 1, "items": item_s}
        if single:
            arr["maxItems"] = 1
        alts.append(arr)
    else:
        # strings: the pattern of the type (a Map or a list of pairs is the block string, clusterMap: |)
        s = string_schema(ty["pattern"]) if ty["pattern"] else {"type": "string"}
        alts = [s]
    if empty:
        alts = [{"const": ""}] + alts
    return alts[0] if len(alts) == 1 else {"anyOf": alts}


def collapse(text):
    return re.sub(r"\s+", " ", str(text or "")).strip()


def schema_of(template, params, typed, types):
    props, required = {}, []
    for p in params:
        name = p["name"]
        spec = typed[name]
        s = value_schema(spec, types, name)
        tag = types[spec["type"]]["display"]
        if spec.get("mandatory") == "always":
            required.append(name)
            tag += "; mandatory"
        elif spec.get("mandatory") == "conditional":
            tag += "; mandatory in some cases (the validate step decides)"
        text = collapse(p.get("description"))
        s["description"] = f"{text} [{tag}]" if text else f"[{tag}]"
        if str(p.get("value", "")) != "":
            s["default"] = str(p["value"])
        props[name] = s
    w = w_of(template)
    out = {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "$id": SCHEMA_URL.format(w=w),
        "title": f"Parameter file of {template}",
        "description": (f"The parameter file of `argo submit --from workflowtemplate/{template} --parameter-file`: the inputs of "
                        f"the WorkflowTemplate {template}. Generated from workflows/params/types.yaml and the template by "
                        "workflows/params/params_schema.py. The shape, the types, the allowed values and the mandatory inputs; "
                        "the validate step of the workflow and the admission policy tpg-workflow-parameters remain the "
                        "authority (inputs that are mandatory in some cases only, combinations, registered clusters, "
                        "the inside of clusterMap)."),
        "type": "object",
        "additionalProperties": False,
        "properties": props,
    }
    if required:
        out["required"] = required
    return out


# ---- the block of docs/workflow-commands.md
def doc_block(template, example):
    w = w_of(template)
    rel = f"workflows/params/schemas/params-{w}.schema.json"
    return "\n".join([
        f"<!-- BEGIN GENERATED: params-{w} -->",
        "<!-- written by workflows/params/params_schema.py; do not edit by hand -->",
        "",
        f"Parameter file schema: `{rel}` (also `params-{w}.schema.yaml`). Check a parameter file with it:",
        "",
        "```bash",
        f"check-jsonschema --schemafile {rel} <parameter file>",
        "```",
        "",
        f"Worked example 1, `workflows/params/schemas/params-{w}.example.yaml`:",
        "",
        "```yaml",
        example.rstrip("\n"),
        "```",
        "",
        f"<!-- END GENERATED: params-{w} -->"])


def put_block(doc, template, block):
    """The doc text with the generated block of the workflow in place (inserted after the input table)."""
    w = w_of(template)
    begin, end = f"<!-- BEGIN GENERATED: params-{w} -->", f"<!-- END GENERATED: params-{w} -->"
    if doc.count(begin) > 1 or doc.count(end) > 1 or doc.count(begin) != doc.count(end):
        raise SystemExit(f"{DOC}: the markers {begin} and {end} must appear once each")
    if begin in doc:
        a, rest = doc.split(begin)
        _, b = rest.split(end)
        return a + block + b
    lines = doc.split("\n")
    start = next((i for i, ln in enumerate(lines) if re.match(rf"^## (\d+\. )?{re.escape(template)}\s*$", ln)), None)
    if start is None:
        raise SystemExit(f"{DOC}: no section '## N. {template}'")
    nxt = next((i for i in range(start + 1, len(lines)) if lines[i].startswith("## ")), len(lines))
    head = next((i for i in range(start + 1, nxt) if lines[i].startswith("| Input | Type |")), None)
    if head is None:
        raise SystemExit(f"{DOC}: section {template} has no input table (| Input | Type |)")
    last = head
    while last + 1 < nxt and lines[last + 1].startswith("|"):
        last += 1
    return "\n".join(lines[:last + 1] + ["", block] + lines[last + 1:])


def outputs():
    src = yaml.safe_load(open(SRC))
    types, typed = src["types"], src["templates"]
    names = []
    templates = {}
    for fn in sorted(os.listdir(TEMPLATES)):
        d = yaml.safe_load(open(os.path.join(TEMPLATES, fn)))
        n = d["metadata"]["name"]
        if n == "tpg-lib":
            continue
        names.append(n)
        templates[n] = d["spec"]["arguments"]["parameters"]
    if sorted(names) != sorted(typed) or sorted(names) != sorted(EXAMPLES):
        raise SystemExit("templates, types.yaml and the EXAMPLES of params_schema.py must name the same workflows: "
                         f"{sorted(set(names) ^ set(typed) | set(names) ^ set(EXAMPLES))}")
    files = {}
    doc = open(DOC).read()
    for tpl in names:
        w = w_of(tpl)
        sch = schema_of(tpl, templates[tpl], typed[tpl], types)
        base = os.path.join(OUT_DIR, f"params-{w}")
        files[base + ".schema.json"] = json.dumps(sch, indent=2) + "\n"
        files[base + ".schema.yaml"] = ("# generated by workflows/params/params_schema.py; do not edit\n"
                                        + yaml.safe_dump(sch, sort_keys=False, width=1000, allow_unicode=True))
        example = example_of(tpl)
        files[base + ".example.yaml"] = example
        doc = put_block(doc, tpl, doc_block(tpl, example))
    files[DOC] = doc
    return files


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true", help="exit 1 when a generated file is out of date")
    args = ap.parse_args()
    files = outputs()
    stale = []
    if os.path.isdir(OUT_DIR):
        for f in sorted(os.listdir(OUT_DIR)):
            p = os.path.join(OUT_DIR, f)
            if f.startswith("params-") and p not in files:
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
            print("out of date (run python3 workflows/params/params_schema.py):\n  "
                  + "\n  ".join(os.path.relpath(p, ROOT) if os.path.isabs(p) and p.startswith(ROOT) else p for p in stale),
                  file=sys.stderr)
            sys.exit(1)
        print(f"up to date: {len(files)} generated files")


if __name__ == "__main__":
    main()
