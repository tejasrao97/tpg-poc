#!/usr/bin/env python3
"""Parameter files of the tpg workflows (tests/params/run.sh; Round 23, phase 7a).

What a parameter file may contain is described by workflows/params/schemas/params-W.schema.json, generated
by workflows/params/params_schema.py. This test checks that the schema, the admission policy
(workflows/admission/workflow-parameters.yaml) and the validate step of each workflow agree about the files
people write, by running the same files through all three:

  schema      jsonschema (Draft 2020-12) over the parameter file, with the -p overrides of the command applied
  admission   the policy, evaluated by a kube-apiserver of tests/envtest with the Argo CRDs, the 13
              WorkflowTemplates and the policy (TPG_PARAMS_ARGO=1 and KUBECONFIG, set by run.sh; skipped
              without envtest). The example files, the docs and the negative cases go through the real argo CLI
              (`argo submit --from workflowtemplate/W --parameter-file F -p ...`), which also proves how argo
              4.1.3 turns the values into strings, and python_str() mirrors that; the argo CLI needs about 4
              seconds per call, so those run in parallel. The tables of values and the other list forms create the
              Workflow with kubectl from python_str() (the policy sees the same Workflow)
  validate    workflows/scripts/validate-params.sh of the workflow, offline (stub kubectl with four registered
              clusters, a fleet repository fixture), with the inputs argo produced; skipped for a file that names
              local files (their contents travel in patchFiles, packed with pack-patch-files.sh)

Files checked:
  1 the generated example of each of the 13 workflows (workflows/params/schemas/params-W.example.yaml), also
    with check-jsonschema, the command the docs print
  2 every parameter-file example of docs/workflow-commands.md. A parameter file example is
      - a fenced yaml block whose first line is the comment `# NAME.yaml` (a plain file name), or
      - a heredoc `cat > NAME.yaml <<'TAG'` in a fenced bash block,
    and it belongs to every `argo submit --from workflowtemplate/W --parameter-file NAME.yaml [-p k=v ...]` command
    (the nearest definition of NAME.yaml before the command, else the first one after it). Blocks whose first line
    is `# ./path`, or that are not named this way (fleet.yaml excerpts, patch files), are not parameter files. A
    definition that no command submits, and a command whose file nothing defines (except the generic inputs.yaml
    and <placeholders>), are problems: the rule has to hold for the document to be checked.
  3 negative cases: an unknown key, a wrong type, a comma-separated list, an empty or malformed list element, a
    missing mandatory input; both list forms (the bracketed string and the YAML sequence) are accepted everywhere
  4 a table of values per type: the schema and the admission policy accept and refuse the same strings
  5 every input that types.yaml marks mandatory: always is refused by the validate step when it is missing, and
    is exactly what the schemas require
Prints one `ok` or `FAIL` line per check, then the skipped checks; exit 1 on a failure.
"""
import concurrent.futures
import glob
import itertools
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import threading

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SCHEMAS = os.path.join(ROOT, "workflows", "params", "schemas")
DOC = os.path.join(ROOT, "docs", "workflow-commands.md")

try:
    import jsonschema
except ImportError:
    print("SKIP tests/params parameter files: python3 jsonschema not installed")
    sys.exit(0)

ARGO = os.environ.get("TPG_PARAMS_ARGO") == "1" and shutil.which("argo") is not None
KUBECTL = os.environ.get("TPG_PARAMS_KUBECTL", "kubectl")
NO_ADMISSION = "admission (envtest binaries or the argo CLI not found; set KUBEBUILDER_ASSETS)"

# ---- results: every check runs as a task in a pool and reports into its own list; the lists are printed in order
_local = threading.local()
_skips, _skip_lock, _validate_lock = {}, threading.Lock(), threading.Lock()
_counter = itertools.count()
_pool = concurrent.futures.ThreadPoolExecutor(max_workers=8)
_futures = []


def ok(msg):
    _local.out.append(("ok  ", msg, ""))


def bad(msg, detail=""):
    _local.out.append(("FAIL", msg, detail))


def skip(what, why):
    with _skip_lock:
        _skips.setdefault(why, []).append(what)


def _run(fn, args, kw):
    _local.out = []
    try:
        fn(*args, **kw)
    except Exception as e:  # a crash of a check is a failure of that check
        bad(f"{getattr(fn, '__name__', fn)}{args[:1]}: {type(e).__name__}: {e}")
    return _local.out


def task(fn, *args, **kw):
    _futures.append(_pool.submit(_run, fn, args, kw))


src = yaml.safe_load(open(os.path.join(ROOT, "workflows", "params", "types.yaml")))
TYPES, TYPED = src["types"], src["templates"]
TEMPLATES = {}      # name -> {"params": {name: default}, "mode": validate mode, "env": {P_VAR: input}}
for f in sorted(glob.glob(os.path.join(ROOT, "workflows", "templates", "*.yaml"))):
    d = yaml.safe_load(open(f))
    n = d["metadata"]["name"]
    if n == "tpg-lib":
        continue
    params = {p["name"]: str(p.get("value", "")) for p in d["spec"]["arguments"]["parameters"]}
    vt = next(t for t in d["spec"]["templates"] if t["name"] == "validate")
    env = {}
    for e in vt["container"].get("env", []):
        m = re.fullmatch(r"\{\{workflow\.parameters\.([A-Za-z0-9]+)\}\}", str(e.get("value", "")))
        if m:
            env[e["name"]] = m.group(1)
    TEMPLATES[n] = {"params": params, "mode": vt["container"]["command"][-1], "env": env}
assert len(TEMPLATES) == 13, sorted(TEMPLATES)


def w_of(t):
    return t[len("tpg-"):]


VALIDATORS = {}


def validator(t):
    if t not in VALIDATORS:
        s = json.load(open(os.path.join(SCHEMAS, f"params-{w_of(t)}.schema.json")))
        jsonschema.Draft202012Validator.check_schema(s)
        VALIDATORS[t] = jsonschema.Draft202012Validator(s)
    return VALIDATORS[t]


def schema_errors(t, params):
    return sorted(f"{'/'.join(map(str, e.absolute_path)) or '<file>'}: {e.message[:160]}" for e in validator(t).iter_errors(params))


def python_str(v):
    """How the argo CLI 4.1.3 turns a parameter-file value into the string of the parameter (verified by the
    argo cases below: true -> "true", a number -> its digits, a sequence or mapping -> its compact JSON text)."""
    if isinstance(v, bool):
        return "true" if v else "false"
    if v is None:
        return "null"
    if isinstance(v, (list, dict)):
        return json.dumps(v, separators=(",", ":"), sort_keys=True)
    return str(v)


# ------------------------------------------------------------------ admission
def argo_submit(t, params_file, overrides=()):
    """(rc, output, {parameter: value} of the created Workflow): the real argo CLI."""
    cmd = ["argo", "submit", "-n", "argo", "--from", f"workflowtemplate/{t}", "--parameter-file", params_file]
    for o in overrides:
        cmd += ["-p", o]
    r = subprocess.run(cmd + ["-o", "json"], capture_output=True, text=True, timeout=300)
    got = {}
    if r.returncode == 0:
        got = {p["name"]: p.get("value", "") for p in json.loads(r.stdout)["spec"]["arguments"]["parameters"]}
    return r.returncode, (r.stdout + r.stderr), got


def kubectl_create(t, params):
    """(rc, output): the Workflow argo would create, created with kubectl (the policy sees the same object)."""
    wf = {"apiVersion": "argoproj.io/v1alpha1", "kind": "Workflow",
          "metadata": {"generateName": "t-", "namespace": "argo"},
          "spec": {"workflowTemplateRef": {"name": t},
                   "arguments": {"parameters": [{"name": k, "value": python_str(v)} for k, v in params.items()]}}}
    r = subprocess.run([KUBECTL, "create", "-f", "-"], input=json.dumps(wf), capture_output=True, text=True, timeout=120)
    return r.returncode, r.stdout + r.stderr


# ------------------------------------------------------------------ the validate step, offline
class ValidateStep:
    """validate-params.sh with the real lib.sh, a stub kubectl that lists four registered clusters and a
    fleet repository fixture (as tests/cluster-map/run.sh does)."""

    def __init__(self):
        self.tmp = tempfile.mkdtemp(prefix="tpg-params-")
        bindir = os.path.join(self.tmp, "bin")
        os.makedirs(bindir)
        kc = os.path.join(bindir, "kubectl")
        with open(kc, "w") as f:
            f.write("""#!/usr/bin/env bash
if [[ "$*" == *"get secret -l tpg.fleet/cluster"* ]]; then
  printf '{"items":[%s]}' "$(for c in aks-tpg-poc-01 aks-tpg-poc-02 aks-tpg-poc-03 aks-tpg-poc-04; do
    printf '{"metadata":{"labels":{"tpg.fleet/cluster":"%s"}}},' "$c"; done | sed 's/,$//')"
  exit 0
fi
exit 0
""")
        os.chmod(kc, 0o755)
        repo = os.path.join(self.tmp, "repo")
        os.makedirs(os.path.join(repo, "clusters"))
        shutil.copytree(os.path.join(ROOT, "clusters", "_template"), os.path.join(repo, "clusters", "_template"))
        fleet = {"clusters": {c: {"operator": {"version": "v4.5.0"}, "cluster": {"allowInPlaceRestore": True},
                                 "instances": {"orders-db": {"instance": {"highAvailability": {"enabled": True, "readReplicas": 2}}},
                                               "reports-db": {"instance": {"highAvailability": {"enabled": False, "readReplicas": 0}}}}}
                              for c in ("aks-tpg-poc-01", "aks-tpg-poc-02", "aks-tpg-poc-03", "aks-tpg-poc-04")}}
        with open(os.path.join(repo, "clusters", "fleet.yaml"), "w") as f:
            yaml.safe_dump(fleet, f, sort_keys=False)
        script = open(os.path.join(ROOT, "workflows", "scripts", "validate-params.sh")).read()
        script = script.replace("source /scripts/lib.sh", f"source {ROOT}/workflows/scripts/lib.sh")
        script = re.sub(r"(?m)^(source .*lib\.sh)$", lambda m: m.group(1) + f'\ngit_clone() {{ rm -rf "$1"; cp -r {repo} "$1"; }}', script, count=1)
        self.script = os.path.join(self.tmp, "validate.sh")
        open(self.script, "w").write(script)

    def run(self, template, inputs):
        """(rc, output) of the validate step of the template for the effective inputs {input: string}. The step
        writes fixed files under /tmp, so one runs at a time."""
        t = TEMPLATES[template]
        env = {"PATH": os.path.join(self.tmp, "bin") + os.pathsep + os.environ["PATH"], "HOME": self.tmp,
               "TPG_WORK": os.path.join(self.tmp, "work")}
        for var, name in t["env"].items():
            env[var] = inputs.get(name, t["params"].get(name, ""))
        with _validate_lock:
            shutil.rmtree(env["TPG_WORK"], ignore_errors=True)
            r = subprocess.run(["bash", self.script, t["mode"]], cwd=self.tmp, env=env, capture_output=True, text=True, timeout=120)
        return r.returncode, r.stdout + r.stderr

    def close(self):
        shutil.rmtree(self.tmp, ignore_errors=True)


VALIDATE = ValidateStep()
tmpdir = tempfile.mkdtemp(prefix="tpg-params-files-")

LOCAL_FILE = re.compile(r"(?<![\w:/.])(\./|~/|/)[A-Za-z0-9_./@+-]*\.(ya?ml|pem|crt|cer)")


def names_local_files(merged):
    return bool(LOCAL_FILE.search(json.dumps(merged))) or "patchFiles" in merged


def case_path(params):
    p = os.path.join(tmpdir, f"case-{next(_counter)}.yaml")
    with open(p, "w") as f:
        yaml.safe_dump(params, f, sort_keys=False, width=10000)
    return p


# ------------------------------------------------------------------ one parameter file through the three checks
def check_file(label, t, path, overrides=()):
    """The file (and the -p overrides of its command) must pass the schema, the admission policy and the validate step."""
    try:
        params = yaml.safe_load(open(path))
    except yaml.YAMLError as e:
        bad(f"{label}: not YAML", e)
        return
    if not isinstance(params, dict):
        bad(f"{label}: not a mapping", params)
        return
    merged = dict(params)
    for o in overrides:
        k, _, v = o.partition("=")
        merged[k] = v
    errs = schema_errors(t, merged)
    inputs = {k: python_str(v) for k, v in merged.items()}
    where = [] if errs else ["schema"]
    problems = [f"schema: {e}" for e in errs]
    if ARGO:
        rc, out, got = argo_submit(t, path, overrides)
        if rc != 0:
            problems.append(f"admission/argo: {out.strip()[-400:]}")
        else:
            where.append("admission")
            wrong = [f"{k}: argo made {got.get(k)!r}, python_str says {v!r}" for k, v in inputs.items() if got.get(k) != v]
            if wrong:
                problems.append("argo conversion differs from python_str: " + "; ".join(wrong))
            inputs.update({k: v for k, v in got.items() if k in inputs})
    else:
        skip(label, NO_ADMISSION)
    if names_local_files(merged):
        skip(label, "the validate step (the file names local files, whose contents travel in patchFiles)")
    else:
        rc, out = VALIDATE.run(t, inputs)
        if rc == 0:
            where.append("validate step")
        else:
            problems.append(f"validate step (rc={rc}): {out.strip()[-600:]}")
    if problems:
        bad(label, "\n".join(problems))
    else:
        ok(f"{label}: {', '.join(where)}")


# ------------------------------------------------------------------ 1 the generated examples
EXAMPLES = {t: os.path.join(SCHEMAS, f"params-{w_of(t)}.example.yaml") for t in sorted(TEMPLATES)}


def example_extra(t):
    path = EXAMPLES[t]
    first = open(path).readline().strip()
    if first != f"# yaml-language-server: $schema=params-{w_of(t)}.schema.json":
        bad(f"example {os.path.basename(path)}: first line is not the yaml-language-server schema line", first)
    r = subprocess.run(["check-jsonschema", "--schemafile", os.path.join(SCHEMAS, f"params-{w_of(t)}.schema.json"), path],
                       capture_output=True, text=True)
    if r.returncode == 0:
        ok(f"check-jsonschema accepts {os.path.basename(path)} (the command of the docs)")
    else:
        bad(f"check-jsonschema refuses {os.path.basename(path)}", r.stdout + r.stderr)


for t in sorted(TEMPLATES):
    task(check_file, f"example {os.path.basename(EXAMPLES[t])}", t, EXAMPLES[t])
    task(example_extra, t)


# ------------------------------------------------------------------ 2 the examples of docs/workflow-commands.md
def doc_examples(text):
    """(definitions [(name, body, line)], uses [(name, template, overrides, line)], problems)."""
    lines = text.split("\n")
    defs, uses, problems = [], [], []
    i = 0
    while i < len(lines):
        m = re.match(r"^```(\w*)\s*$", lines[i])
        if not m:
            i += 1
            continue
        lang, start = m.group(1), i + 1
        j = start
        while j < len(lines) and not lines[j].startswith("```"):
            j += 1
        body = lines[start:j]
        if lang in ("yaml", "yml") and body:
            h = re.match(r"^# ([A-Za-z0-9][A-Za-z0-9._-]*\.ya?ml)\s*$", body[0])
            if h:
                defs.append((h.group(1), "\n".join(body) + "\n", start + 1))
        elif lang in ("bash", "sh", "shell"):
            stmt, k = "", 0
            while k < len(body):
                ln = body[k]
                hd = re.search(r"cat\s*>\s*([A-Za-z0-9][A-Za-z0-9._-]*\.ya?ml)\s*<<-?\s*['\"]?(\w+)['\"]?\s*$", ln)
                if hd:
                    tag, doc = hd.group(2), []
                    k += 1
                    while k < len(body) and body[k].strip() != tag:
                        doc.append(body[k])
                        k += 1
                    defs.append((hd.group(1), "\n".join(doc) + "\n", start + k + 1))
                    k += 1
                    continue
                if ln.rstrip().endswith("\\"):
                    stmt += ln.rstrip()[:-1] + " "
                    k += 1
                    continue
                stmt += ln
                if "argo submit" in stmt and "--parameter-file" in stmt:
                    try:
                        words = shlex.split(stmt, comments=True)
                    except ValueError as e:
                        words = []
                        problems.append(f"line {start + k + 1}: cannot read the command: {e}")
                    tpl = next((w.split("/", 1)[1] for w in words if w.startswith("workflowtemplate/")), None)
                    pf = next((words[x + 1] for x, w in enumerate(words[:-1]) if w in ("--parameter-file", "-f")), None)
                    ov = [words[x + 1] for x, w in enumerate(words[:-1]) if w in ("-p", "--parameter")]
                    if tpl and pf:
                        uses.append((pf, tpl, ov, start + k + 1))
                stmt = ""
                k += 1
        i = j + 1
    return defs, uses, problems


def doc_cases():
    defs, uses, problems = doc_examples(open(DOC).read())
    for p in problems:
        task(bad, "docs/workflow-commands.md: " + p)
    by_name = {}
    for name, body, line in defs:
        by_name.setdefault(name, []).append((line, body))
    used = set()
    n = 0
    for name, tpl, ov, line in uses:
        if name in ("inputs.yaml",) or "<" in name:
            continue
        defined = by_name.get(name, [])
        # the nearest definition before the command; a command that comes first (in the text that introduces
        # the example) belongs to the first definition after it
        before = [d for d in defined if d[0] < line]
        pick = before[-1] if before else (defined[0] if defined else None)
        if pick is None:
            task(bad, f"docs/workflow-commands.md line {line}: --parameter-file {name} is not defined by a block "
                      f"(a yaml block that starts with `# {name}` or `cat > {name} <<'TAG'`)")
            continue
        used.add((name, pick[0]))
        if tpl not in TEMPLATES:
            task(bad, f"docs/workflow-commands.md line {line}: workflowtemplate/{tpl} is not a tpg workflow")
            continue
        path = os.path.join(tmpdir, f"doc-{pick[0]}-{name}")
        open(path, "w").write(pick[1])
        n += 1
        task(check_file, f"docs/workflow-commands.md {name} (line {pick[0]}, {tpl}"
             + (f", {' '.join('-p ' + o for o in ov)}" if ov else "") + f"; submitted at line {line})", tpl, path, ov)
    for name, body, line in defs:
        if (name, line) not in used and name != "inputs.yaml":
            task(bad, f"docs/workflow-commands.md line {line}: the parameter file {name} is never submitted with --parameter-file")
    if n == 0:
        task(bad, "docs/workflow-commands.md: no parameter-file example found")


doc_cases()


# ------------------------------------------------------------------ 3 negative cases, both list forms, 4 value table
def base(t):
    """The generated example of the workflow as a dict."""
    return yaml.safe_load(open(EXAMPLES[t]))


def with_(t, **kw):
    b = base(t)
    for k, v in kw.items():
        if v is KeyError:
            b.pop(k, None)
        else:
            b[k] = v
    return b


def both(label, t, params, accepted, via="argo", schema_only=False, want=None):
    """The schema and the admission policy must both accept (accepted) or both refuse the parameters. via: the real
    argo CLI, or kubectl from python_str()."""
    errs = schema_errors(t, params)
    res = {"schema": not errs}
    msg = ""
    if not schema_only:
        if not ARGO:
            skip(label, NO_ADMISSION)
        elif via == "argo":
            rc, msg, _ = argo_submit(t, case_path(params))
            res["admission"] = rc == 0
        else:
            rc, msg = kubectl_create(t, params)
            res["admission"] = rc == 0
    wrong = [f"{k} {'accepts' if v else 'refuses'}" for k, v in res.items() if v != accepted]
    detail = msg + "\n" + "\n".join(errs)
    if wrong:
        bad(f"{label} (expected {'accepted' if accepted else 'refused'}: {', '.join(wrong)})", detail)
    elif want and "admission" in res and not all(w in detail for w in want):   # the messages are the policy's
        bad(f"{label} (message lacks {want})", detail)
    else:
        ok(f"{label}: {' and '.join(res)} {'accept' if accepted else 'refuse'}")


D0 = "tpg-day0"
NEG = [
    ("unknown key (clustres)", D0, with_(D0, clustres=["aks-tpg-poc-01"]), dict(want=["clustres"])),
    ("an input that was renamed (valuesPatchFilePath of tpg-patch)", "tpg-patch", with_("tpg-patch", valuesPatchFilePath=["./a.yaml"]), dict(want=["renamed"])),
    ("wrong type: dryRun yes", D0, with_(D0, dryRun="yes"), dict(want=["must be a Boolean"])),
    ("wrong type: dryRun as a number", D0, with_(D0, dryRun=1), {}),
    ("wrong type: maxParallel abc", D0, with_(D0, maxParallel="abc"), dict(want=["must be an Integer"])),
    ("wrong type: maxParallel 0 (1 or more)", D0, with_(D0, maxParallel=0), {}),
    ("wrong type: readReplicas -1", D0, with_(D0, readReplicas=-1), {}),
    ("wrong type: pushMode other", D0, with_(D0, pushMode="push"), dict(want=["one of direct, pr"])),
    ("a comma-separated clusters string is refused", D0, with_(D0, clusters="aks-tpg-poc-01,aks-tpg-poc-02"), dict(want=["List in brackets"])),
    ("a bare instance name is refused", D0, with_(D0, instances="orders-db"), {}),
    ("an empty list [] is refused", D0, with_(D0, instances="[]"), {}),
    ("an empty YAML sequence is refused", D0, with_(D0, instances=[]), {}),
    ("an empty element is refused", D0, with_(D0, instances="[orders-db, , billing-db]"), {}),
    ("all inside the brackets is refused (string)", D0, with_(D0, clusters="[aks-tpg-poc-01, all]"), {}),
    ("all inside the brackets is refused (sequence)", D0, with_(D0, clusters=["aks-tpg-poc-01", "all"]), {}),
    ("a file entry with a space after repo: is refused (sequence)", D0, with_(D0, postgresOverlayFilePath=["repo: x.yaml"]), {}),
    ("a file entry with a space after repo: is refused (string)", D0, with_(D0, postgresOverlayFilePath="[repo: x.yaml]"), {}),
    ("two files in a single-file input are refused", D0, with_(D0, postgresValuesOverlayFilePath=["./a.yaml", "./b.yaml"]), {}),
    ("a single-file input is a list: a bare path is refused", D0, with_(D0, postgresValuesOverlayFilePath="./a.yaml"), {}),
    ("tpg-restore: a map of clusters instead of a list of pairs is refused", "tpg-restore",
     with_("tpg-restore", clusterMap="aks-tpg-poc-01:\n  instances:\n    orders-db: {}\n"), {}),
]
for label, t, params, kw in NEG:
    task(both, label, t, params, False, **kw)
# what only the schema refuses: the run accepts them, but they are not what a parameter file should hold
task(both, "wrong type: a version as a number is refused (17.10 would become 17.1)", D0, with_(D0, postgresVersion=17.6), False, schema_only=True)
task(both, "wrong type: null is refused (argo would send the string null)", D0, with_(D0, readReplicas=None), False, schema_only=True)
task(both, "clusterMap as a YAML mapping is refused (write the block string, clusterMap: |)", "tpg-scale-instance",
     with_("tpg-scale-instance", clusterMap={"aks-tpg-poc-01": {"instances": {"orders-db": {"replicas": 2}}}}), False, schema_only=True)
task(both, "an unquoted number as a list element is refused (YAML reads 1 as an integer; argo would send [1], which the run takes as the name 1)",
     D0, with_(D0, clusters=[1]), False, schema_only=True)
task(both, "a mandatory input is missing: pushMode (the schema requires it; check 5 shows the validate step does)", D0,
     with_(D0, pushMode=KeyError), False, schema_only=True)
task(both, "an unquoted number for a Boolean is refused", D0, with_(D0, highAvailability=1), False)


def list_forms(t, k):
    """A list value of a generated example as the YAML sequence (through the argo CLI), the bracketed string and the
    JSON text (through kubectl): all pass the schema and the policy, and give the validate step the same answer."""
    b = base(t)
    v = b[k]
    forms = {"YAML sequence": v, "bracketed string": "[" + ", ".join(v) + "]", "JSON text": json.dumps(v)}
    for form, val in forms.items():
        p = dict(b)
        p[k] = val
        problems = [f"schema: {e}" for e in schema_errors(t, p)]
        if ARGO:
            rc, out = (argo_submit(t, case_path(p))[:2]) if form == "YAML sequence" else kubectl_create(t, p)
            if rc != 0:
                problems.append(f"admission: {out.strip()[-300:]}")
        else:
            skip(f"{t} {k}", NO_ADMISSION)
        if not names_local_files(p):
            rc2, out2 = VALIDATE.run(t, {kk: python_str(vv) for kk, vv in p.items()})
            if rc2 != 0:
                problems.append(f"validate step: {out2.strip()[-400:]}")
        if problems:
            bad(f"{t} {k} as a {form}", "\n".join(problems))
        else:
            ok(f"{t} {k} as a {form}: accepted")


for t in sorted(TEMPLATES):
    for k, v in base(t).items():
        if isinstance(v, list):
            task(list_forms, t, k)

# 4 a table of values per type: the schema and the admission policy agree (True: accepted)
VALUES = [
    # (template, input, value, accepted)
    ("tpg-day0", "clusters", "all", True), ("tpg-day0", "clusters", "[all]", False), ("tpg-day0", "clusters", ["all"], False),
    ("tpg-day0", "clusters", "[aks-tpg-poc-01]", True), ("tpg-day0", "clusters", "['aks-tpg-poc-01', \"aks-tpg-poc-02\"]", True),
    ("tpg-day0", "clusters", '["aks-tpg-poc-01","aks-tpg-poc-02"]', True), ("tpg-day0", "clusters", "[Aks_01]", False),
    ("tpg-day0", "clusters", "aks-tpg-poc-01", False), ("tpg-day0", "clusters", "", True),
    ("tpg-day0", "clusters", ["aks-tpg-poc-01", "aks-tpg-poc-02"], True), ("tpg-day0", "clusters", ["Aks_01"], False),
    ("tpg-day0", "clusters", "[[a]]", False), ("tpg-day0", "clusters", "all, other", False),
    ("tpg-create-instance", "clusters", "all", False),
    ("tpg-day0", "instances", "[orders-db]", True), ("tpg-day0", "instances", "all", False), ("tpg-upgrade", "instances", "all", True),
    ("tpg-day0", "highAvailability", "true", True), ("tpg-day0", "highAvailability", True, True), ("tpg-day0", "highAvailability", False, True),
    ("tpg-day0", "highAvailability", "True", False), ("tpg-day0", "highAvailability", "", True), ("tpg-day0", "highAvailability", 1, False),
    ("tpg-day0", "readReplicas", 2, True), ("tpg-day0", "readReplicas", "2", True), ("tpg-day0", "readReplicas", "two", False),
    ("tpg-day0", "readReplicas", "2.5", False), ("tpg-day0", "readReplicas", "", True),
    ("tpg-day0", "maxParallel", 3, True), ("tpg-day0", "maxParallel", "03", False), ("tpg-day0", "maxParallel", "0", False),
    ("tpg-day0", "maxParallel", "", False),
    ("tpg-day0", "storageSize", "50Gi", True), ("tpg-day0", "storageSize", 50, True), ("tpg-day0", "storageSize", "0.5", True),
    ("tpg-day0", "storageSize", "50 Gi", False), ("tpg-day0", "storageSize", "Gi", False),
    ("tpg-day0", "cpu", 2, True), ("tpg-day0", "cpu", "500m", True), ("tpg-day0", "cpu", "-1", False),
    ("tpg-day0", "operatorVersion", "v4.5.0", True), ("tpg-day0", "operatorVersion", "4.5.0", True), ("tpg-day0", "operatorVersion", "4.5", False),
    ("tpg-day0", "operatorVersion", "latest", False),
    ("tpg-day0", "postgresVersion", "postgres-17.6", True), ("tpg-day0", "postgresVersion", "17.6", True),
    ("tpg-day0", "postgresVersion", "postgres-17.6-lite", False), ("tpg-day0", "postgresVersion", "pg17", False),
    ("tpg-day0", "pushMode", "pr", True), ("tpg-day0", "pushMode", "", True), ("tpg-day0", "pushMode", "PR", False),
    ("tpg-day0", "backupSchedule", "operator", True), ("tpg-day0", "backupSchedule", "", False), ("tpg-day0", "backupSchedule", "weekly", False),
    ("tpg-day0", "operatorFullSchedule", "0 1 * * 0", True), ("tpg-day0", "operatorFullSchedule", "0 1 * *", False),
    ("tpg-day0", "operatorFullSchedule", "weekly", False),
    ("tpg-day0", "storageClass", "tpg-data-retain", True), ("tpg-day0", "storageClass", "Tpg_Data", False),
    ("tpg-day0", "ferretSecretName", "orders-db-app-user-db-secret", True), ("tpg-day0", "ferretSecretName", "Orders", False),
    ("tpg-day0", "internalLoadBalancerSubnet", "snet-apps_1", True), ("tpg-day0", "internalLoadBalancerSubnet", "-bad", False),
    ("tpg-day0", "allowedSourceRanges", ["10.20.0.0/16"], True), ("tpg-day0", "allowedSourceRanges", "[10.20.0.0/16, 192.168.10.0/24]", True),
    ("tpg-day0", "allowedSourceRanges", "10.20.0.0/16", False), ("tpg-day0", "allowedSourceRanges", ["10.20.0.0"], False),
    ("tpg-day0", "egressToFqdns", ["db.example.com", "*.example.org"], True), ("tpg-day0", "egressToFqdns", ["localhost"], False),
    ("tpg-day0", "serviceAnnotations", "{service.beta.kubernetes.io/azure-dns-label-name: orders}", True),
    ("tpg-day0", "serviceAnnotations", "team: orders", True), ("tpg-day0", "serviceAnnotations", "just words", False),
    ("tpg-day0", "ingressFromNamespaces", ["orders-app", "reporting"], True), ("tpg-day0", "ingressFromNamespaces", "orders-app", False),
    ("tpg-day0", "postgresOverlayFilePath", ["./a.yaml", "repo:helm_artifacts/instance/tpg-instance/overlays/b.yaml"], True),
    ("tpg-day0", "postgresOverlayFilePath", "[./a.yaml, ~/b.yml, /abs/c.yaml, ../d.yaml]", True),
    ("tpg-day0", "postgresOverlayFilePath", ["./a.txt"], False), ("tpg-day0", "postgresOverlayFilePath", ["./a.yaml", ""], False),
    ("tpg-day0", "postgresValuesOverlayFilePath", ["repo:helm_artifacts/instance/tpg-instance/overlays/v.yaml"], True),
    ("tpg-day0", "backupCaBundleFile", ["./ca.pem"], True), ("tpg-day0", "backupCaBundleFile", ["repo:ca-bundles/azure.crt"], True),
    ("tpg-day0", "backupCaBundleFile", ["./ca.yaml"], False), ("tpg-day0", "backupCaBundleFile", ["./ca.pem", "./b.pem"], False),
    ("tpg-day0", "patchFiles", '{"./a.yaml": "YWJj"}', True), ("tpg-day0", "patchFiles", {"./a.yaml": "YWJj"}, True),
    ("tpg-day0", "patchFiles", '["./a.yaml"]', False), ("tpg-day0", "patchFiles", "", True),
    ("tpg-day0", "toolsImage", "alpine/k8s:1.35.8", True),
    ("tpg-day0", "installAddons", "false", True), ("tpg-day0", "existingAddons", "upgrade", True), ("tpg-day0", "existingAddons", "", False),
    ("tpg-delete-instance", "finalBackup", "required", True), ("tpg-delete-instance", "finalBackup", True, True),
    ("tpg-delete-instance", "finalBackup", "yes", False), ("tpg-delete-instance", "confirm", ["orders-db"], True),
    ("tpg-delete-apps", "apps", '{"aks-tpg-poc-01": ["tpg-instances:orders-db"]}', True),
    ("tpg-delete-apps", "apps", {"aks-tpg-poc-01": ["tpg-instances:orders-db"]}, True), ("tpg-delete-apps", "apps", '["tpg-operator"]', False),
    ("tpg-patch", "clearKinds", "all", True), ("tpg-patch", "clearKinds", ["Postgres", "postgresValues"], True),
    ("tpg-patch", "clearKinds", "[all]", False), ("tpg-patch", "clearKinds", ["Deployment"], False),
    ("tpg-patch", "clearKinds", "[Postgres, postgresValues]", True),
    ("tpg-patch", "patchMode", "clear", True), ("tpg-patch", "patchMode", "", False),
    ("tpg-helm-addons", "components", "auto", True), ("tpg-helm-addons", "components", ["cert-manager", "vso"], True),
    ("tpg-helm-addons", "components", "[auto]", False), ("tpg-helm-addons", "components", "[istio]", False),
    ("tpg-helm-addons", "components", "[cert-manager, monitoring]", True), ("tpg-helm-addons", "components", "", False),
    ("tpg-helm-addons", "clusters", "all", True), ("tpg-helm-addons", "clusters", ["aks-tpg-poc-01"], True),
    ("tpg-upgrade", "targetVersion", "v4.5.1", True), ("tpg-upgrade", "targetVersion", "postgres-17.7", True),
    ("tpg-upgrade", "targetVersion", "17.7", True), ("tpg-upgrade", "targetVersion", "seventeen", False),
    ("tpg-upgrade", "component", "operator", True), ("tpg-upgrade", "component", "Operator", False),
    ("tpg-restore", "clusterMap", "- sourceClusterConfig: {a: {b: {c: {}}}}\n  targetClusterConfig: {a: {b: {d: {}}}}\n", True),
    ("tpg-restore", "clusterMap", '[{"sourceClusterConfig": {}, "targetClusterConfig": {}}]', True), ("tpg-restore", "clusterMap", "just words", False),
    ("tpg-restore", "keepSourceLocation", "false", True), ("tpg-restore", "keepSourceLocation", "no", False),
    ("tpg-rotate-credential", "secretType", "ca-bundle", True), ("tpg-rotate-credential", "secretType", "password", False),
    ("tpg-rotate-credential", "wrappingToken", "hvs.CAESIJabcdefghijklmnopqrstuv", True), ("tpg-rotate-credential", "wrappingToken", "short", False),
    ("tpg-rotate-credential", "secretName", "azure-storage-2027", True), ("tpg-rotate-credential", "secretName", "Azure Storage", False),
    ("tpg-rotate-credential", "caBundleFile", ["~/certs/azure.pem"], True),
    ("tpg-rotate-credential", "clusters", "all", True), ("tpg-rotate-credential", "clusters", "", False),
    ("tpg-network-policy", "mode", "remove", True), ("tpg-network-policy", "mode", "delete", False),
    ("tpg-network-policy", "connectivityCheck", "false", True),
    ("tpg-backup", "backupType", "differential", True), ("tpg-backup", "backupType", "diff", False), ("tpg-backup", "scheduledOnly", True, True),
    ("tpg-backup", "instances", "all", True), ("tpg-backup", "instances", ["orders-db"], True),
    ("tpg-backup-expire", "confirm", ["aks-tpg-poc-01"], True), ("tpg-backup-expire", "confirm", "aks-tpg-poc-01", False),
    ("tpg-backup-expire", "dryRun", False, True),
    ("tpg-scale-instance", "replicas", 0, True), ("tpg-scale-instance", "maxReadReplicas", 0, False), ("tpg-scale-instance", "maxReadReplicas", 5, True),
]
for t, name, value, accepted in VALUES:
    p = base(t)
    p[name] = value
    if name == "highAvailability" and value in (False, "false"):
        p.pop("readReplicas")     # a single node has no read replicas (the rule of types.yaml)
    shown = value if isinstance(value, str) else json.dumps(value)
    task(both, f"{t} {name}={shown!r:.70}", t, p, accepted, via="kubectl")


# 5 mandatory: always is mandatory for the validate step too, and is what the schemas require
def mandatory(t):
    params = TYPED[t]
    always = {n for n, s in params.items() if s.get("mandatory") == "always"}
    req = set(validator(t).schema.get("required", []))
    if req != always:
        bad(f"{t}: schema required {sorted(req)} differs from the inputs with mandatory: always {sorted(always)}")
    else:
        ok(f"{t}: the schema requires {sorted(req) or 'no input'}, the inputs with mandatory: always, and no other")
    for name in sorted(always):
        inputs = {k: python_str(v) for k, v in base(t).items()}
        inputs.pop(name, None)
        rc, out = VALIDATE.run(t, inputs)
        if rc != 0 and name in out:
            ok(f"{t}: the validate step refuses a run without {name} (mandatory: always)")
        else:
            bad(f"{t}: the validate step does not refuse a run without {name}, which types.yaml marks mandatory: always (rc={rc})", out)


for t in sorted(TEMPLATES):
    task(mandatory, t)

# ---- report, in the order the checks were queued
n_ok = n_bad = 0
for fut in _futures:
    for kind, msg, detail in fut.result():
        print(f"{kind} {msg}")
        for ln in str(detail).strip().split("\n")[-8:]:
            if ln.strip():
                print(f"       | {ln}")
        if kind == "ok  ":
            n_ok += 1
        else:
            n_bad += 1
VALIDATE.close()
shutil.rmtree(tmpdir, ignore_errors=True)
for why, what in _skips.items():
    print(f"SKIP {why}: {len(what)} check(s)" + (f" ({', '.join(what[:2])}, ...)" if len(what) > 2 else f" ({', '.join(what)})"))
print("SKIP live only, never run offline: everything after the validate step of each workflow (discover, the pre-check, the "
      "fleet.yaml commit, the Argo CD syncs, the verification on the clusters), and the registered clusters and fleet.yaml "
      "of the real hub (the validate step runs against a fixture of four clusters)")
print()
print(f"parameter files: {n_ok} passed, {n_bad} failed")
sys.exit(1 if n_bad else 0)
