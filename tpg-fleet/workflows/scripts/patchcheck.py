#!/usr/bin/env python3
"""Check that a patch file fits the input it was passed to (Round 14, D77; Round 15, D81).

  patchcheck.py values|operator FILE.json --schemas patch-schemas.json [--name NAME]
  patchcheck.py postgres FILE.json... --schemas patch-schemas.json [--name NAME]... [--instance I]

values is postgresValuesPatchFilePath, postgres postgresPatchFilePath (a list of
files), operator operatorValuesPatchFilePath (tpg-day0 and tpg-create-instance:
postgresValuesOverlayFilePath, postgresOverlayFilePath, operatorValuesOverlayFilePath,
with --word Overlay; Round 22). FILE.json is the patch file as
JSON (the caller converts the YAML with yq); for postgres a JSON list of the
file's YAML documents (yq ea '[.]'). NAME is how each file is named in the
messages (the path the user gave; one --name per file). Prints one error per
line and exits 1 when there is any. Standard library only (it runs in the
validate step, in the tools image, and in scripts/submit/pack-patch-files.sh).

  values    a map of chart values: a Kubernetes manifest or an operator values
            file is refused with the input it belongs to; every key must exist
            in the chart values (workflows/params/patch-schemas.json, values.tree),
            with the closest known key suggested; a map where the chart has a
            single value (or the reverse) is refused
  postgres  every YAML document of every file is one partial manifest of a kind
            the tpg-instance chart renders (Postgres, PostgresBackupLocation,
            PostgresBackupSchedule, PostgresFerretDocumentDB): apiVersion
            sql.tanzu.vmware.com/v1, only apiVersion, kind and spec (a
            PostgresBackupSchedule also metadata.name: <instance>-backup-full or
            -incremental, or backup-full / backup-incremental for every instance);
            spec against the closed schema of the kind's CRD (unknown fields,
            types, enums, patterns, lengths, minimums; required fields are not
            asked for, because a patch sets only what it changes). At most one
            document per kind (per schedule object) across the files of a target
  operator  only the keys the operator values allow-list names, each with its type
The rules that need clusters/fleet.yaml or the cluster (fields other workflows
own, sizes that would shrink, the operator image tag against the cluster's
operator version, Secrets and issuers that must exist) are checked later by
workflows/scripts/patch-lib.sh.
"""
import argparse
import difflib
import json
import re
import sys

MANIFEST_KEYS = {"apiVersion", "kind", "metadata", "spec"}
DNS_LABEL = re.compile(r"^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$")
K8S_NAME = re.compile(r"^[a-z0-9]([-a-z0-9.]{0,251}[a-z0-9])?$")
QUANTITY = re.compile(r"^[0-9]+(\.[0-9]+)?(m|Ki|Mi|Gi|Ti|Pi|Ei|k|M|G|T|P|E)?$")
# <registry host[:port]>/<path>, no tag or digest on the last segment
REPOSITORY = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9.-]*(:[0-9]+)?(/[a-z0-9]+([._-][a-z0-9]+)*)+$")
IMAGE = re.compile(r"^(?P<repo>[a-zA-Z0-9][a-zA-Z0-9.-]*(:[0-9]+)?(/[a-z0-9]+([._-][a-z0-9]+)*)+):(?P<tag>[A-Za-z0-9_][A-Za-z0-9_.-]{0,127})$")


def suggest(word, choices):
    m = difflib.get_close_matches(word, list(choices), n=1, cutoff=0.6)
    return f" (did you mean {m[0]}?)" if m else ""


def kind_of(v):
    if isinstance(v, dict):
        return "a map"
    if isinstance(v, list):
        return "a list"
    return "a single value"


WORD = "Patch"   # Round 22: "Overlay" for the overlay files of tpg-day0 and tpg-create-instance


def inp(kind):
    """The input name of a kind: postgres, postgresValues or operatorValues + Patch|Overlay + FilePath."""
    return f"{kind}{WORD}FilePath"


def check_values(doc, schema, name, errors):
    if not isinstance(doc, dict):
        errors.append(f"{name}: a values patch must be a YAML map of chart values (got {kind_of(doc)})")
        return
    found = sorted(MANIFEST_KEYS & set(doc))
    if found:
        what = f"a Kubernetes manifest (kind: {doc.get('kind')})" if doc.get("kind") else "a Kubernetes manifest"
        hint = inp("postgres") if doc.get("kind") in (None, *schema["postgres"]["kinds"]) else "a patch input of its own kind"
        errors.append(f"{name}: is {what}, not chart values ({', '.join(found)} at the top): "
                      f"pass it as {hint}")
        return
    op = sorted(set(schema["operator"]) & set(doc))
    if op:
        errors.append(f"{name}: holds operator chart values ({', '.join(op)}): pass it as {inp('operatorValues')}")
        return
    owned = set(schema["values"]["owned"])

    def walk(node, t, path):
        for k, v in node.items():
            p = f"{path}.{k}" if path else k
            if not path and k in owned:
                continue
            if not isinstance(t, dict) or k not in t:
                known = t.keys() if isinstance(t, dict) else []
                errors.append(f"{name}: {p} is not a value of the tpg-instance chart{suggest(k, known)}")
                continue
            sub = t[k]
            if sub == "*":
                if not isinstance(v, dict) and v is not None:
                    errors.append(f"{name}: {p} must be a map (got {kind_of(v)})")
                continue
            if isinstance(sub, dict):
                if v is None:
                    continue  # null removes the key (tpg.deepMerge)
                if not isinstance(v, dict):
                    errors.append(f"{name}: {p} must be a map (got {kind_of(v)})")
                    continue
                walk(v, sub, p)
            elif sub == "list":
                if v is not None and not isinstance(v, list):
                    errors.append(f"{name}: {p} must be a list (got {kind_of(v)})")
            elif isinstance(v, (dict, list)):
                errors.append(f"{name}: {p} is a single value in the chart (got {kind_of(v)})")
    walk(doc, schema["values"]["tree"], "")


CURRENT_KIND = ["Postgres"]   # the kind whose schema check_schema walks (for the messages)


def type_ok(v, t):
    return {"object": isinstance(v, dict), "array": isinstance(v, list),
            "string": isinstance(v, str),
            "integer": isinstance(v, int) and not isinstance(v, bool),
            "number": isinstance(v, (int, float)) and not isinstance(v, bool),
            "boolean": isinstance(v, bool), "null": v is None}.get(t, True)


def check_schema(v, s, path, name, errors):
    """The subset of JSON schema the generated CRD schemas use; required is not checked."""
    if "oneOf" in s:
        ok = [alt for alt in s["oneOf"] if not _errs(v, alt, path)]
        if not ok:
            errors.append(f"{name}: {path} has {kind_of(v)} '{v}' of the wrong type"
                          f" ({' or '.join(a.get('type', '?') for a in s['oneOf'])} expected)")
        return
    t = s.get("type")
    if isinstance(t, list):
        if not any(type_ok(v, x) for x in t):
            errors.append(f"{name}: {path} must be {' or '.join(t)} (got {kind_of(v)})")
            return
    elif t and not type_ok(v, t):
        errors.append(f"{name}: {path} must be {'an ' if t[0] in 'aeiou' else 'a '}{t} (got {json.dumps(v)[:60]})")
        return
    if "enum" in s and v not in s["enum"]:
        errors.append(f"{name}: {path} '{v}' must be one of {', '.join(map(str, s['enum']))}")
    if isinstance(v, str):
        if "pattern" in s and not re.search(s["pattern"], v):
            errors.append(f"{name}: {path} '{v}' does not match {s['pattern']}")
        if "maxLength" in s and len(v) > s["maxLength"]:
            errors.append(f"{name}: {path} is longer than {s['maxLength']} characters")
    if isinstance(v, (int, float)) and not isinstance(v, bool) and "minimum" in s and v < s["minimum"]:
        errors.append(f"{name}: {path} {v} is below the minimum {s['minimum']}")
    if isinstance(v, dict):
        props = s.get("properties", {})
        extra = s.get("additionalProperties", True)
        for k, sub in v.items():
            p = f"{path}.{k}"
            if k in props:
                check_schema(sub, props[k], p, name, errors)
            elif extra is False:
                errors.append(f"{name}: {p} is not a field of the {CURRENT_KIND[0]} resource{suggest(k, props)}")
            elif isinstance(extra, dict):
                check_schema(sub, extra, p, name, errors)
    if isinstance(v, list) and isinstance(s.get("items"), dict):
        for n, item in enumerate(v):
            check_schema(item, s["items"], f"{path}[{n}]", name, errors)


def _errs(v, s, path):
    e = []
    check_schema(v, s, path, "", e)
    return e


SCHEDULE_NAME = re.compile(r"^(?:(?P<inst>[a-z0-9]([-a-z0-9]*[a-z0-9])?)-)?backup-(?P<type>full|incremental)$")


def doc_key(doc, instance=None):
    """The object a postgres patch document targets: its kind, or kind/<type> for a schedule."""
    if doc.get("kind") != "PostgresBackupSchedule":
        return doc.get("kind")
    m = SCHEDULE_NAME.match(str((doc.get("metadata") or {}).get("name", "")))
    return f"PostgresBackupSchedule/{m.group('type')}" if m else None


def check_postgres_doc(doc, schema, name, errors, instance=None):
    if not isinstance(doc, dict):
        errors.append(f"{name}: a postgres patch document must be a YAML map (got {kind_of(doc)})")
        return
    pg = schema["postgres"]
    kinds = pg["kinds"]
    if "kind" not in doc and "spec" not in doc:
        vals = sorted(set(doc) & set(schema["values"]["tree"]))
        if vals:
            errors.append(f"{name}: holds chart values ({', '.join(vals)}), not a Postgres manifest: "
                          f"pass it as {inp('postgresValues')}")
            return
        if set(schema["operator"]) & set(doc):
            errors.append(f"{name}: holds operator chart values: pass it as {inp('operatorValues')}")
            return
    kind = doc.get("kind")
    if kind not in kinds:
        errors.append(f"{name}: kind must be one of {', '.join(kinds)} (got {kind or 'none'}){suggest(str(kind), kinds)}")
        return
    if doc.get("apiVersion") != pg["apiVersion"]:
        errors.append(f"{name}: apiVersion must be {pg['apiVersion']} (got {doc.get('apiVersion', 'none')})")
    allowed = {"apiVersion", "kind", "spec"} | ({"metadata"} if kind == "PostgresBackupSchedule" else set())
    extra = sorted(set(doc) - allowed)
    if extra:
        only = "apiVersion, kind, metadata.name and spec" if kind == "PostgresBackupSchedule" else "apiVersion, kind and spec"
        errors.append(f"{name}: {kind}: only {only} can be patched (found {', '.join(extra)})")
    if kind == "PostgresBackupSchedule":
        md = doc.get("metadata") or {}
        n = str(md.get("name", "")) if isinstance(md, dict) else ""
        m = SCHEDULE_NAME.match(n)
        if not isinstance(md, dict) or set(md) - {"name"}:
            errors.append(f"{name}: PostgresBackupSchedule: metadata may hold only name")
        if not m:
            errors.append(f"{name}: PostgresBackupSchedule: metadata.name must be <instance>-backup-full or "
                          f"<instance>-backup-incremental (or backup-full / backup-incremental for every instance) "
                          f"(got '{n or 'none'}')")
        elif instance and m.group("inst") and m.group("inst") != instance:
            errors.append(f"{name}: PostgresBackupSchedule {n} belongs to the instance {m.group('inst')}, not {instance}")
    spec = doc.get("spec")
    if spec is None or spec == {}:
        errors.append(f"{name}: {kind}: spec is missing: nothing to patch")
    else:
        CURRENT_KIND[0] = kind
        check_schema(spec, kinds[kind], "spec", name, errors)


def check_postgres(docs_by_file, schema, names, errors, instance=None):
    """docs_by_file: [[doc, ...], ...] (one list per file); at most one document per target object."""
    seen = {}
    for docs, name in zip(docs_by_file, names):
        if isinstance(docs, dict):
            docs = [docs]
        if not isinstance(docs, list):
            errors.append(f"{name}: not a YAML document list")
            continue
        docs = [d for d in docs if d is not None and d != {}]
        if not docs:
            errors.append(f"{name}: the file holds no document: nothing to patch")
            continue
        for d in docs:
            before = len(errors)
            check_postgres_doc(d, schema, name, errors, instance)
            if len(errors) != before or not isinstance(d, dict):
                continue
            k = doc_key(d, instance)
            if k in seen:
                errors.append(f"{name}: a second {k.replace('/', ' ')} document (the first is in {seen[k]}): "
                              f"one document per kind (merge them into one)")
            else:
                seen[k] = name


def check_operator(doc, schema, name, errors):
    if not isinstance(doc, dict):
        errors.append(f"{name}: an operator values patch must be a YAML map (got {kind_of(doc)})")
        return
    allowed = schema["operator"]
    if MANIFEST_KEYS & set(doc):
        errors.append(f"{name}: is a Kubernetes manifest, not operator chart values: an operator values file "
                      f"sets only {', '.join(sorted(allowed))}")
        return
    vals = sorted(set(doc) & set(schema["values"]["tree"]))
    if vals:
        errors.append(f"{name}: holds tpg-instance chart values ({', '.join(vals)}): pass it as {inp('postgresValues')}")
        return
    for k, v in doc.items():
        if k not in allowed:
            errors.append(f"{name}: {k} cannot be patched; an operator values patch may set only "
                          f"{', '.join(sorted(allowed))}{suggest(k, allowed)}")
            continue
        t = allowed[k]["type"]
        empty_ok = allowed[k].get("allowEmpty", False)
        if t == "boolean":
            if not isinstance(v, bool):
                errors.append(f"{name}: {k} must be true or false (got {json.dumps(v)})")
        elif t == "resources":
            if v is None or v == {}:
                continue
            if not isinstance(v, dict):
                errors.append(f"{name}: resources must be a map of limits and requests (got {kind_of(v)})")
                continue
            for part, res in v.items():
                if part not in ("limits", "requests"):
                    errors.append(f"{name}: resources.{part} cannot be set (only limits and requests){suggest(part, ['limits', 'requests'])}")
                    continue
                if not isinstance(res, dict):
                    errors.append(f"{name}: resources.{part} must be a map of cpu and memory")
                    continue
                for r, q in res.items():
                    if r not in ("cpu", "memory"):
                        errors.append(f"{name}: resources.{part}.{r} cannot be set (only cpu and memory){suggest(r, ['cpu', 'memory'])}")
                    elif not QUANTITY.match(str(q)):
                        errors.append(f"{name}: resources.{part}.{r} '{q}' is not a Kubernetes quantity such as 500m or 300Mi")
        elif not isinstance(v, str):
            errors.append(f"{name}: {k} must be a string (got {kind_of(v)})")
        elif v == "":
            if not empty_ok:
                errors.append(f"{name}: {k} cannot be empty")
        elif t == "image":
            if not IMAGE.match(v):
                errors.append(f"{name}: operatorImage '{v}' must be <registry>/<path>:<tag> (a tag, not a digest)")
        elif t == "repository":
            if not REPOSITORY.match(v):
                errors.append(f"{name}: {k} '{v}' must be an image repository without a tag, such as "
                              f"myregistry.azurecr.io/postgres-instance")
        elif t == "k8sName":
            if not K8S_NAME.match(v):
                errors.append(f"{name}: {k} '{v}' is not a Kubernetes object name")
        elif t == "dnsLabel":
            if not DNS_LABEL.match(v):
                errors.append(f"{name}: {k} '{v}' is not a namespace name (a DNS label)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("kind", choices=["values", "postgres", "operator"])
    ap.add_argument("files", nargs="+")
    ap.add_argument("--schemas", required=True)
    ap.add_argument("--name", action="append", default=[])
    ap.add_argument("--instance")
    ap.add_argument("--word", choices=["Patch", "Overlay"], default="Patch",
                    help="the input names in the messages: ...PatchFilePath (tpg-patch) or ...OverlayFilePath")
    a = ap.parse_args()
    global WORD
    WORD = a.word
    with open(a.schemas) as f:
        schema = json.load(f)
    names = [a.name[n] if n < len(a.name) else f for n, f in enumerate(a.files)]
    docs = []
    for f, name in zip(a.files, names):
        try:
            with open(f) as fh:
                docs.append(json.load(fh))
        except ValueError as e:
            print(f"{name}: not valid YAML: {e}")
            return 1
    errors = []
    if a.kind == "postgres":
        check_postgres(docs, schema, names, errors, a.instance)
    else:
        if len(docs) != 1:
            print(f"{a.kind}: one file is checked at a time")
            return 1
        {"values": check_values, "operator": check_operator}[a.kind](docs[0], schema, names[0], errors)
    for e in errors:
        print(e)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
