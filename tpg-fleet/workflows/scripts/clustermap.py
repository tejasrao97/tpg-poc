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
  clustermap.py normalize --map M.json --keys K.json [--normalized]
      Writes the normalized map without checking workflows or clusters. --normalized: the map holds
      values that validate (or an earlier normalize) already wrote, in which a single-file key is
      the bare path, not [path]; every rule on the path still applies (fleet-day0.sh and
      network-policy.sh read the validated clusterMap and add the inputs to it).
  clustermap.py restore   --map M.json --keys K.json [--registered FILE] [--confirm-required] [--out N.json]
      The clusterMap of tpg-restore (Round 23, phase 6): a LIST of pairs, not a map of clusters (see
      "Restore pairs" below). Prints one error per line and exits 1 when it is invalid; otherwise
      writes the normalized pairs (a JSON array) to --out (or stdout). --confirm-required: the run
      is a real restore (dryRun=false), so an in-place pair needs its confirm.
  clustermap.py list NAME VALUE [--bare WORD]... [--files] [--one] [--json|--csv]
      The strict list parser of the workflow inputs (Round 23): VALUE is the text of an
      input, a bracketed list "[a, b]" (YAML flow) or '["a","b"]' (JSON), also for one
      value. Prints one item per line (--json: a JSON array, --csv: comma-separated);
      an empty VALUE prints nothing. --bare WORD: a value that is exactly WORD stays
      bare (all, auto). --files: the items are file paths (the whitespace message for
      "repo: path"). --one: exactly one item. A bad value prints the message on stderr
      and exits 1; the shell reaches this through lib.sh list_items, list_csv and file_item.

Normalized map: {cluster: {<cluster key>: value, instances: {instance: {<key>: value}}}}
with every scalar as a string ("true", "3", "v4.5.0", "postgres-17.6"); a patchFile
is one .yaml or .yml path: a file of the submitting machine (absolute or relative;
its contents come in patchFiles) or repo:<path> in the fleet repository (Round 15);
a patchFileList is a list of them, a kindList a list of patch kinds.

Restore pairs (Round 23, phase 6; keys in the "restore" section of cluster-map-keys.yaml): the
clusterMap of tpg-restore is a list, each element a pair
  - sourceClusterConfig: {<cluster>: {<namespace>: {<instance>: {sourceBackupName}}}}
    targetClusterConfig: {<cluster>: {<namespace>: {<instance>: {pitrEnabled, pitrConfig, ...}}}}
with exactly one cluster, namespace and instance on each side (namespaces are mandatory). The
normalized pair, one JSON object per pair, is what the restore steps read (documented field names,
all always present; a missing text is "", a missing flag false):
  index                  position in the list, from 0
  label                  "<cluster>/<namespace>/<instance> -> <cluster>/<namespace>/<instance>"
  method                 backup (pitrEnabled false, also when pitrEnabled is absent) | latest | time | lsn | transaction
  inPlace                source and target are the same cluster, namespace and instance
  sameCluster            same cluster on both sides
  sameNamespace          same cluster and namespace on both sides
  source                 {cluster, namespace, instance, backupName}   backupName: sourceBackupName
  target                 {cluster, namespace, instance, specFile, confirm, skipMinorVersionCheck,
                          postRestoreBackup}   specFile: targetInstanceSpecFilePath as given ("" none);
                          confirm: only for an in-place pair (refused on any other), "" without it
  pitr                   {enabled, type, timestamp, target, bestEffort, backupLocation, stanza,
                          backupLabel}   backupLocation, stanza, backupLabel: pitrConfig.sourceBackupConfig
                          srcBackupLocationName, srcStanzaName, srcBackupLabel (never derived here)
pitrEnabled defaults to false, so a target without it restores the named backup and the source then needs
sourceBackupName. A named backup is valid into the same namespace, another namespace and another cluster
(Round 23, phase 6a follow-up); the normalized pair did not need a new field for it (method backup,
inPlace, sameCluster and sameNamespace say where). targetInstanceSpecFilePath as repo:<path> is limited to
helm_artifacts/instance/tpg-instance/restore-specs/ (repoDir of the key; one .yaml or .yml file, no .., no
absolute or empty segment, the README of the folder is not a .yaml file).
Booleans are JSON booleans. What needs the clusters (a live source, whether the target exists, derived
location and stanza, the recovery window, the matrix) is checked by the restore steps; allowInPlaceRestore
(clusters/fleet.yaml) is read by validate-params.sh, which refuses the whole run (IN_PLACE_NOT_ALLOWED).

Lists are strict (Round 23): in the map a key of a list type is a YAML/JSON sequence,
also with one value ([tpg-poc-01]); a single-file key (patchFile, caFile) is a
sequence of exactly one path ([./a.yaml], normalized to the path). A string where a
list belongs ("a,b", "a") is refused with the list syntax; kindList alone also takes
the bare word all (and refuses [all]: all stands alone, without brackets). A file entry that is not repo:<file path> or a local path, and
"repo: path" with whitespace (which YAML reads as the map {repo: path}), fail with
repo:<file path> "check for white spaces in between".
"""
import argparse
import datetime
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
# the per-cluster copies the workflows write of the operator files: never a source
OPERATOR_COPY = re.compile(r"^repo:helm_artifacts/operator/(patches|overlays)/clusters/")
PATCH_KINDS = ["Postgres", "PostgresBackupLocation", "PostgresBackupSchedule", "PostgresFerretDocumentDB",
               "postgresValues", "operatorValues"]
# Kubernetes annotation/label key: optional DNS prefix, then a name
MAP_KEY = re.compile(r"^([a-z0-9]([-a-z0-9]*[a-z0-9])?(\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*/)?[A-Za-z0-9]([-A-Za-z0-9_.]{0,61}[A-Za-z0-9])?$")
AZURE_NAME = re.compile(r"^[A-Za-z0-9]([-A-Za-z0-9_.]{0,78}[A-Za-z0-9_])?$")
FQDN = re.compile(r"^(\*\.)?([a-z0-9]([-a-z0-9]*[a-z0-9])?\.)+[a-z]{2,}$")
CRON = re.compile(r"^[0-9*/,A-Za-z-]+(\s+[0-9*/,A-Za-z-]+){4}$")
K8S_NAME = re.compile(r"^[a-z0-9]([-a-z0-9.]{0,251}[a-z0-9])?$")
# a namespace: a DNS-1123 label, at most 63 characters (Round 23); the reserved ones are listed
# in cluster-map-keys.yaml (key namespace, "reserved")
NAMESPACE = re.compile(r"^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$")

# tpg-restore pairs (the "restore" section of cluster-map-keys.yaml)
TIMESTAMP = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
LSN = re.compile(r"^[0-9A-Fa-f]+/[0-9A-Fa-f]+$")
TRANSACTION_ID = re.compile(r"^[0-9]+$")
STANZA = re.compile(r"^[A-Za-z0-9][-A-Za-z0-9_.]{0,127}$")
# a pgBackRest backup label: a full 20260915-020000F, or an incremental or differential after it
BACKUP_LABEL = re.compile(r"^[0-9]{8}-[0-9]{6}F(_[0-9]{8}-[0-9]{6}[DI])?$")

# Workflows where every cluster needs at least one instance, and the cluster keys
# that make an instance-less cluster meaningful in the others.
INSTANCES_REQUIRED = {"day0", "create-instance", "backup", "delete-instance", "network-policy", "backup-expire"}
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


class ListError(ValueError):
    """A value that is not a well-formed list; the message names the input and the fix."""


LIST_SYNTAX = ('write a list in brackets, even with one value: [a] or [a, b] (YAML flow list) '
               'or ["a", "b"] (JSON array)')
FILE_SPACE = 'repo:<file path> "check for white spaces in between"'


def list_syntax_error(where, text, bare=()):
    """The message for a string where a list belongs: shows the bracketed form of what was written."""
    t = text.strip()
    if t == "all" and "all" not in bare:
        return f"{where}: 'all' is not a list, and this input does not take all; {LIST_SYNTAX}"
    pieces = [p.strip().strip("\"'") for p in t.split(",") if p.strip()]
    fix = "[" + ", ".join(pieces) + "]" if pieces else "[a, b]"
    more = f"; {' or '.join(bare)} stay{'s' if len(bare) == 1 else ''} bare" if bare else ""
    return f"{where}: '{t}' is not a list; {LIST_SYNTAX}{more}. Did you mean {fix}?"


def parse_list_text(text, where, bare=()):
    """The elements of the text of a list input: '[a, b]' (YAML flow) or '["a","b"]' (JSON).
    Quotes are removed; an empty element stays "" so as_list can name it. Not bracketed: ListError."""
    s = text.strip()
    if not (s.startswith("[") and s.endswith("]")):
        raise ListError(list_syntax_error(where, s, bare))
    try:
        v = json.loads(s)
    except ValueError:
        v = None
    if isinstance(v, list):
        return v
    inner = s[1:-1]
    items, cur, quote, quoted = [], "", None, False
    for ch in inner:
        if quote:
            if ch == quote:
                quote = None
            else:
                cur += ch
        elif ch in "[]" and not quoted:
            raise ListError(f"{where}: a list entry must be a plain value, not a nested list")
        elif ch in "\"'" and not cur.strip() and not quoted:
            quote, quoted = ch, True
        elif ch == ",":
            items.append(cur if quoted else cur.strip())
            cur, quoted = "", False
        elif quoted and not ch.isspace():
            raise ListError(f"{where}: text after a closing quote in {s}; {LIST_SYNTAX}")
        elif not quoted:
            cur += ch
    if quote:
        raise ListError(f"{where}: unterminated quote in {s}; {LIST_SYNTAX}")
    if items or cur.strip() or quoted:
        items.append(cur if quoted else cur.strip())
    out = []
    for it in items:
        if it.startswith("{"):       # YAML flow mapping, as in [repo: x.yaml] or {repo: x.yaml}
            try:
                it = json.loads(it)
            except ValueError:
                it = {it: None}
        out.append(it)
    return out


def as_list(value, where="list", text=False, files=False, bare=()):
    """A list value as a list of strings (Round 23: strict).

    value  a list (a clusterMap sequence, or parsed JSON), or with text=True the text of an
           input: "[a, b]" or '["a","b"]'. A string that is not bracketed ("a,b", "a") is not
           a list: ListError with the syntax. An empty list, an empty element ([a, , b]), a
           nested list and a mapping are refused too.
    files  the items are file paths: an element with whitespace, or a mapping (YAML reads
           [repo: x.yaml] as [{repo: x.yaml}]), fails with repo:<file path> "check for white
           spaces in between".
    bare   words that stay bare as a whole value (all, auto); the caller handles them.
    Raises ListError."""
    if isinstance(value, str):
        if files and re.match(r"^\s*\{?\s*repo:\s", value):
            raise ListError(f"{where}: {FILE_SPACE}")
        if not text:
            raise ListError(list_syntax_error(where, value, bare))
        items = parse_list_text(value, where, bare)
    elif isinstance(value, list):
        items = value
    else:
        raise ListError(f"{where}: a list is expected, not a {type(value).__name__}; {LIST_SYNTAX}")
    if not items:
        raise ListError(f"{where}: the list is empty; name at least one value, for example [a, b] "
                        "(leave the input empty, or remove the key, to use the default)")
    out = []
    for p in items:
        if isinstance(p, dict):
            if files:
                raise ListError(f"{where}: {FILE_SPACE}")
            raise ListError(f"{where}: a list entry must be a plain value, not a mapping")
        if isinstance(p, list):
            raise ListError(f"{where}: a list entry must be a plain value, not a nested list")
        s = "" if p is None else scalar(p).strip()
        if re.search(r"[\r\n]", s):
            raise ListError(f"{where}: a list entry holds a line break; write each value on one line: [a, b]")
        if not s:
            raise ListError(f"{where}: the list has an empty element (a doubled or trailing comma); "
                            "write each value once: [a, b]")
        if files and re.search(r"\s", s):
            raise ListError(f"{where}: {FILE_SPACE}")
        out.append(s)
    return out


def check_list(t, value, where):
    try:
        items = as_list(value, where)
    except ListError as e:
        return [], str(e)
    for p in items:
        if t == "nameList" and not NAME.match(p):
            return items, f"{where}: '{p}' must be a lowercase DNS label"
        if t == "k8sNameList" and not K8S_NAME.match(p):
            return items, f"{where}: '{p}' must be a Kubernetes object name (lowercase letters, digits, '-' and '.')"
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
        if OPERATOR_COPY.match(p):
            return p, f"{where}: '{p}' is a copy the workflows write per cluster; name the stored file under {d or 'helm_artifacts/operator/'}"
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


def check_namespace(spec, s, where, hint):
    """None when s is a namespace name the spec allows, else the message (hint: what to do instead)."""
    if not NAMESPACE.match(s):
        return f"{where}: '{s}' must be a namespace name: a lowercase DNS label of at most 63 characters (letters, digits and '-')"
    reserved = spec.get("reserved", [])
    prefixes = spec.get("reservedPrefixes", [])
    if s in reserved or any(s.startswith(x) for x in prefixes):
        names = ", ".join(reserved + [x + "*" for x in prefixes])
        return f"{where}: namespace '{s}' is reserved ({names}); {hint}"
    return None


def check_value(spec, value, where, normalized=False):
    """Return (normalized value, error or None). normalized: value may be the output of an earlier
    check_value, where a single-file key (patchFile, caFile) is the bare path."""
    t = spec["type"]
    if value is None:
        return None, f"{where}: null is not a value; remove the key to use the default"
    if t in ("nameList", "k8sNameList", "cidrList", "fqdnList"):
        return check_list(t, value, where)
    if t == "stringMap":
        return check_map(value, where)
    if t in ("patchFile", "caFile"):
        # one file, but still a list (Round 23): [./a.yaml]; normalized to the path
        if normalized and isinstance(value, str):
            value = [value]   # the path an earlier check wrote: the same rules apply to it
        try:
            items = as_list(value, where, files=True)
        except ListError as e:
            return value, str(e)
        if len(items) != 1:
            return items, f"{where}: exactly one file is expected, in brackets: [path] (one current file of this kind)"
        return check_patch_file(spec, items[0], where)
    if t == "patchFileList":
        try:
            items = as_list(value, where, files=True)
        except ListError as e:
            return value, str(e)
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
        if isinstance(value, str) and value.strip() == "all":
            return ["all"], None            # all stays bare (Round 23)
        try:
            items = as_list(value, where, bare=("all",))
        except ListError as e:
            return value, str(e)
        for k in items:
            if k != "all" and k not in PATCH_KINDS:
                return items, f"{where}: '{k}' must be one of {', '.join(PATCH_KINDS)}, or all{suggest(k, PATCH_KINDS)}"
        if "all" in items:
            return items, f"{where}: all stands alone, without brackets (write the bare word all, not a list)"
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
    if t == "namespace":
        return s, check_namespace(spec, s, where, "choose another, or leave the key out for pg-<instance>")
    if t == "timestamp":
        if not TIMESTAMP.match(s):
            return s, f"{where}: '{s}' must be a UTC time such as 2026-09-15T08:30:00Z"
        try:
            datetime.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ")
        except ValueError:
            return s, f"{where}: '{s}' is not a real date and time (a UTC time such as 2026-09-15T08:30:00Z)"
        return s, None
    if t == "lsn":
        return s, None if LSN.match(s) else f"{where}: '{s}' must be a log sequence number such as 0/3000060"
    if t == "stanzaName":
        return s, None if STANZA.match(s) else f"{where}: '{s}' must be a pgBackRest stanza name (letters, digits, '-', '_' and '.', at most 128 characters), for example pg-orders-orders-db-0000"
    if t == "backupLabel":
        return s, None if BACKUP_LABEL.match(s) else f"{where}: '{s}' must be a pgBackRest backup label such as 20260915-020000F or 20260915-020000F_20260916-010000I (pgbackrest info lists them)"
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


def process(raw, keys, workflow=None, registered=None, flags=None, normalized=False):
    """Return (normalized map, [errors]). workflow=None: normalize only. normalized: see check_value."""
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
            ncluster[k], err = check_value(ckeys[k], v, f"{where_c}.{k}", normalized)
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
                ninst[k], err = check_value(ikeys[k], v, f"{where_i}.{k}", normalized)
                if err:
                    errors.append(err)
            required_missing(ikeys, ninst, where_i)
            ncluster["instances"][inst] = ninst
        norm[cluster] = ncluster
    return norm, errors


# ----------------------------------------------------------------- tpg-restore pairs
RESTORE_SIDES = ("sourceClusterConfig", "targetClusterConfig")
PITR_TYPES = ("latest", "time", "lsn", "transaction")


def restore_specs(keys):
    """(source specs, target specs): the 'restore' section of cluster-map-keys.yaml, key path -> spec."""
    r = keys.get("restore") or {}
    return r.get("source", {}), r.get("target", {})


def restore_side(value, where, label):
    """One side of a pair: <cluster>: <namespace>: <instance>: {keys}, exactly one of each.
    Returns ((cluster, namespace, instance, keys entry) or None, [errors])."""
    errors = []
    levels = ("cluster", "namespace", "instance")
    node, names = value, []
    for n, level in enumerate(levels):
        here = ".".join([where] + names)
        if not isinstance(node, dict):
            errors.append(f"{here}: must be a mapping {label} (exactly one cluster, namespace and instance)")
            return None, errors
        if not node:
            errors.append(f"{here}: names no {level}; write {label}")
            return None, errors
        if len(node) != 1:
            found = ", ".join(scalar(k) for k in node)
            errors.append(f"{here}: exactly one {level} is expected, found {len(node)} ({found}); "
                          f"one pair per restore: write a second pair for each further {level}")
            return None, errors
        k = scalar(next(iter(node)))
        names.append(k)
        node = node[next(iter(node))]
    if node is None:
        node = {}
    return (names[0], names[1], names[2], node), errors


def restore_entry(entry, specs, where, side, errors, other_specs):
    """The keys of one instance entry: unknown, misplaced or wrongly typed keys are errors. Returns the
    checked values by key path ('pitrConfig.type'); leaf values are strings (a flag: 'true' or 'false')."""
    out = {}
    other = "target" if side == "source" else "source"

    def walk(node, prefix, w):
        for k, v in node.items():
            k = scalar(k)
            path, wk = prefix + k, f"{w}.{k}"
            if path in specs:
                val, err = check_value(specs[path], v, wk)
                if err:
                    errors.append(err)
                else:
                    out[path] = val
            elif any(p.startswith(path + ".") for p in specs):
                if not isinstance(v, dict):
                    errors.append(f"{wk}: a mapping is expected (keys: "
                                  f"{', '.join(sorted({p[len(path) + 1:].split('.')[0] for p in specs if p.startswith(path + '.')}))})")
                    continue
                walk(v, path + ".", wk)
            else:
                here = sorted({p[len(prefix):].split(".")[0] for p in specs if p.startswith(prefix)})
                hint = suggest(k, here)
                if not prefix and any(p.split(".")[0] == k for p in other_specs):
                    hint = f" ({k} is a {other} key: put it under {other}ClusterConfig)"
                errors.append(f"{w}: unknown key {k}{hint}")

    walk(entry, "", where)
    return out


def restore_pair_errors(i, pair, keys, registered, confirm_required):
    """Check one pair. Returns (normalized pair or None, [errors])."""
    errors = []
    w = f"clusterMap[{i}]"
    if not isinstance(pair, dict):
        return None, [f"{w}: a pair must be a mapping with sourceClusterConfig and targetClusterConfig"]
    for k in pair:
        if k not in RESTORE_SIDES:
            errors.append(f"{w}: unknown key {k}{suggest(k, RESTORE_SIDES)}")
    sides = {}
    for side in RESTORE_SIDES:
        if side not in pair:
            errors.append(f"{w}: {side} is required (<cluster>: <namespace>: <instance>: {{...}})")
            continue
        got, errs = restore_side(pair[side], f"{w}.{side}", "<cluster>: <namespace>: <instance>: {...}")
        errors += errs
        if got:
            sides[side] = got
    src_specs, tgt_specs = restore_specs(keys)
    ns_spec = keys.get("instance", {}).get("namespace", {"type": "namespace"})
    vals = {}
    for side, got in sides.items():
        c, ns, inst, entry = got
        where_c = f"{w}.{side}.{c}"
        if not CLUSTER_NAME.match(c):
            errors.append(f"{where_c}: '{c}' is not a valid cluster name")
        elif registered is not None and c not in registered:
            errors.append(f"{where_c}: cluster '{c}' is not registered{suggest(c, registered)}. "
                          f"Registered clusters: {', '.join(sorted(registered)) or 'none'}")
        where_n = f"{where_c}.{ns}"
        # only a target namespace follows the reserved list: an instance cannot live in a reserved one
        err = check_namespace(ns_spec if side == "targetClusterConfig" else {}, ns, where_n,
                              "choose another namespace for the restored instance")
        if err:
            errors.append(err)
        where_i = f"{where_n}.{inst}"
        known = {p.split(".")[0] for p in list(src_specs) + list(tgt_specs)}
        # an instance level that is a key of an instance: the namespace level was left out
        missing_ns = (f" ('{inst}' is a key of an instance, so the namespace level is missing: namespaces are "
                      "mandatory, <cluster>: <namespace>: <instance>: {keys})") if inst in known else ""
        if not NAME.match(inst):
            errors.append(f"{where_i}: '{inst}' must be a lowercase DNS label of at most 40 characters: "
                          f"letters, digits and '-'{instance_name_hint(inst)}{missing_ns}")
        if not isinstance(entry, dict):
            errors.append(f"{where_i}: must be a mapping of keys (or empty){missing_ns}")
            continue
        vals[side] = (restore_entry(entry, src_specs if side == "sourceClusterConfig" else tgt_specs, where_i,
                                    "source" if side == "sourceClusterConfig" else "target", errors,
                                    tgt_specs if side == "sourceClusterConfig" else src_specs), entry, where_i)
    if len(vals) < 2:
        return None, errors
    (sc, sns, si, _), (tc, tns, ti, _) = sides["sourceClusterConfig"], sides["targetClusterConfig"]
    (sv, _, sw), (tv, tentry, tw) = vals["sourceClusterConfig"], vals["targetClusterConfig"]
    same_cluster = sc == tc
    same_ns = same_cluster and sns == tns
    in_place = same_ns and si == ti

    en = tv.get("pitrEnabled")
    # pitrEnabled defaults to false: a pair that does not say is a named-backup restore
    implied = "pitrEnabled" not in tentry
    if implied:
        en = "false"
    typ = tv.get("pitrConfig.type")
    if en == "false":
        how = "pitrEnabled: false" + (" (pitrEnabled is absent and defaults to false)" if implied else "")
        if "pitrConfig" in tentry and any(p.startswith("pitrConfig") for p in tv):
            errors.append(f"{tw}.pitrConfig: not allowed with {how}: the restore uses the backup "
                          "sourceBackupName names; remove pitrConfig, or set pitrEnabled: true")
        if "bestEffort" in tv:
            errors.append(f"{tw}.bestEffort: not allowed with {how} (it belongs to a point-in-time recovery; "
                          "set pitrEnabled: true)")
        if "sourceBackupName" not in sv:
            errors.append(f"{sw}.sourceBackupName is required with {how}: give sourceBackupName, or set pitrEnabled: true with pitrConfig (point-in-time recovery)")
    elif en == "true":
        if "pitrConfig" not in tentry:
            errors.append(f"{tw}.pitrConfig is required with pitrEnabled: true (at least pitrConfig: {{type: latest}})")
        elif typ is None:
            errors.append(f"{tw}.pitrConfig.type is required with pitrEnabled: true (latest, time, lsn or transaction)")
        if typ == "latest":
            for path in ("pitrConfig.target", "pitrConfig.timestamp", "pitrConfig.sourceBackupConfig.srcBackupLabel", "bestEffort"):
                if path in tv:
                    errors.append(f"{tw}.{path}: not allowed with pitrConfig.type: latest")
        elif typ in ("time", "lsn", "transaction"):
            if "bestEffort" not in tv:
                errors.append(f"{tw}.bestEffort is required with pitrConfig.type: {typ} (true: recover as far as the WAL "
                              "allows when the target is not reached; false: fail instead)")
            if typ == "time":
                if "pitrConfig.timestamp" not in tv:
                    errors.append(f"{tw}.pitrConfig.timestamp is required with pitrConfig.type: time (a UTC time such as 2026-09-15T08:30:00Z)")
                if "pitrConfig.target" in tv:
                    errors.append(f"{tw}.pitrConfig.target: not allowed with pitrConfig.type: time (use pitrConfig.timestamp)")
            else:
                if "pitrConfig.target" not in tv:
                    errors.append(f"{tw}.pitrConfig.target is required with pitrConfig.type: {typ} "
                                  f"({'a log sequence number such as 0/3000060' if typ == 'lsn' else 'a transaction ID'})")
                elif typ == "lsn" and not LSN.match(tv["pitrConfig.target"]):
                    errors.append(f"{tw}.pitrConfig.target: '{tv['pitrConfig.target']}' must be a log sequence number such as 0/3000060")
                elif typ == "transaction" and not TRANSACTION_ID.match(tv["pitrConfig.target"]):
                    errors.append(f"{tw}.pitrConfig.target: '{tv['pitrConfig.target']}' must be a transaction ID (a number)")
                if "pitrConfig.timestamp" in tv:
                    errors.append(f"{tw}.pitrConfig.timestamp: not allowed with pitrConfig.type: {typ} (use pitrConfig.target)")

    conf = tv.get("confirm", "")
    if conf and not in_place:
        # confirm guards the overwrite of an instance's own data; a restore into another instance never overwrites one
        # (a target that exists is refused at plan time, TARGET_EXISTS), so there is nothing to confirm
        errors.append(f"{tw}.confirm: not allowed: confirm is only for an in-place restore (source and target are the same "
                      f"cluster, namespace and instance); this restore creates {ti} as a new instance, so there is nothing to "
                      f"confirm: remove confirm (a target that already exists is refused at plan time, TARGET_EXISTS: restore in place "
                      f"or choose a new instance name)")
    elif conf and conf != ti:
        errors.append(f"{tw}.confirm: '{conf}' must repeat the target instance name {ti}")
    elif in_place and not conf and confirm_required:
        errors.append(f"{tw}.confirm is required: the restore is in place (source and target are the same instance) and "
                      f"overwrites its data; repeat the instance name, confirm: {ti}")

    label = f"{sc}/{sns}/{si} -> {tc}/{tns}/{ti}"
    method = "backup" if en == "false" else (typ or "")
    flag = lambda d, k: d.get(k) == "true"
    pair_out = {
        "index": i, "label": label, "method": method,
        "inPlace": in_place, "sameCluster": same_cluster, "sameNamespace": same_ns,
        "source": {"cluster": sc, "namespace": sns, "instance": si, "backupName": sv.get("sourceBackupName", "")},
        "target": {"cluster": tc, "namespace": tns, "instance": ti,
                   "specFile": tv.get("targetInstanceSpecFilePath", ""), "confirm": conf,
                   "skipMinorVersionCheck": flag(tv, "skipMinorVersionCheck"), "postRestoreBackup": flag(tv, "postRestoreBackup")},
        "pitr": {"enabled": en == "true", "type": typ or "" if en == "true" else "",
                 "timestamp": tv.get("pitrConfig.timestamp", ""), "target": tv.get("pitrConfig.target", ""),
                 "bestEffort": flag(tv, "bestEffort"),
                 "backupLocation": tv.get("pitrConfig.sourceBackupConfig.srcBackupLocationName", ""),
                 "stanza": tv.get("pitrConfig.sourceBackupConfig.srcStanzaName", ""),
                 "backupLabel": tv.get("pitrConfig.sourceBackupConfig.srcBackupLabel", "")},
    }
    return pair_out, errors


def process_restore(raw, keys, registered=None, confirm_required=False):
    """Return (normalized pairs, [errors]) for the clusterMap of tpg-restore."""
    if raw is None or raw == "":
        return [], ["clusterMap is empty: a list of pairs is expected, one per restore"]
    if isinstance(raw, dict):
        return [], ["clusterMap must be a list of pairs (YAML or JSON), one per restore: "
                    "- {sourceClusterConfig: {<cluster>: {<namespace>: {<instance>: {sourceBackupName: ...}}}}, "
                    "targetClusterConfig: {<cluster>: {<namespace>: {<instance>: {pitrEnabled: ..., pitrConfig: ...}}}}}; "
                    "a mapping of clusters is the clusterMap of the other workflows"]
    if not isinstance(raw, list):
        return [], ["clusterMap must be a list of pairs (YAML or JSON), one per restore: "
                    "- {sourceClusterConfig: ..., targetClusterConfig: ...}"]
    if not raw:
        return [], ["clusterMap: the list is empty; name at least one pair, one pair per restore"]
    errors, pairs = [], []
    for i, pair in enumerate(raw):
        p, errs = restore_pair_errors(i, pair, keys, registered, confirm_required)
        errors += errs
        if p:
            pairs.append(p)
    # rules between the pairs: a target is restored once, and is not the source another pair reads
    for a in pairs:
        t = (a["target"]["cluster"], a["target"]["namespace"], a["target"]["instance"])
        for b in pairs:
            if a is b:
                continue
            if (b["target"]["cluster"], b["target"]["namespace"], b["target"]["instance"]) == t and b["index"] > a["index"]:
                errors.append(f"clusterMap[{b['index']}].targetClusterConfig: {'/'.join(t)} is also the target of "
                              f"clusterMap[{a['index']}]; restore into an instance once per run")
            if (b["source"]["cluster"], b["source"]["namespace"], b["source"]["instance"]) == t:
                errors.append(f"clusterMap[{a['index']}].targetClusterConfig: {'/'.join(t)} is the source of "
                              f"clusterMap[{b['index']}]; restoring into it would overwrite what that pair restores from")
    return pairs, errors



def list_command(argv):
    """clustermap.py list NAME VALUE [--bare WORD]... [--files] [--one] [--json|--csv]"""
    ap = argparse.ArgumentParser(prog="clustermap.py list")
    ap.add_argument("name")
    ap.add_argument("value")
    ap.add_argument("--bare", action="append", default=[])
    ap.add_argument("--files", action="store_true")
    ap.add_argument("--one", action="store_true")
    fmt = ap.add_mutually_exclusive_group()
    fmt.add_argument("--json", action="store_true")
    fmt.add_argument("--csv", action="store_true")
    a = ap.parse_args(argv)
    v = a.value.strip()
    if not v:
        if a.json:
            print("[]")
        return 0                       # an empty input is an unset input
    if v in a.bare:
        items = [v]
    else:
        try:
            items = as_list(a.value, a.name, text=True, files=a.files, bare=tuple(a.bare))
        except ListError as e:
            print(str(e), file=sys.stderr)
            return 1
        if a.one and len(items) != 1:
            print(f"{a.name}: exactly one file is expected, in brackets: [path] (one current file of this kind)",
                  file=sys.stderr)
            return 1
    if a.json:
        print(json.dumps(items, separators=(",", ":")))
    elif a.csv:
        print(",".join(items))
    else:
        print("\n".join(items))
    return 0


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "list":
        return list_command(sys.argv[2:])
    ap = argparse.ArgumentParser()
    ap.add_argument("command", choices=["validate", "normalize", "restore"])
    ap.add_argument("--workflow")
    ap.add_argument("--map", required=True)
    ap.add_argument("--keys", required=True)
    ap.add_argument("--registered")
    ap.add_argument("--flags")
    ap.add_argument("--out")
    ap.add_argument("--confirm-required", action="store_true")
    ap.add_argument("--normalized", action="store_true")
    a = ap.parse_args()
    with open(a.map) as f:
        text = f.read().strip()
    raw = json.loads(text) if text else None
    with open(a.keys) as f:
        keys = json.load(f)
    if a.command == "restore":
        registered = None
        if a.registered:
            with open(a.registered) as f:
                registered = {line.strip() for line in f if line.strip()}
        norm, errors = process_restore(raw, keys, registered, a.confirm_required)
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
        norm, errors = process(raw, keys, normalized=a.normalized)
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
