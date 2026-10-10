#!/usr/bin/env python3
"""Keys that nothing evaluates (Round 15, 1g; design decision D89).

  python3 tools/unused-keys/audit.py [--infra PATH] [--report]

A key a person can set but nothing reads is a trap: retentionDays looked like a
retention setting after the operator took over retention. This lint finds such
keys in five places and fails when one is not explained in allow-list.yaml:

  chart      every leaf of charts/tpg-instance/values.yaml and clusters/_template/*.yaml
             is changed, one at a time, in three value profiles; the key is evaluated
             when the rendered manifests (or the render error) change in one of them
  fleet      every leaf of clusters/fleet.example.yaml under an instance or cluster
             entry is a chart value (above), or a key the workflows read (allow-list)
  inputs     every input of every WorkflowTemplate is used by the template (a
             {{...parameters.<name>}} reference) or read from the Workflow object by
             a step script; every P_* variable a template sets is read by a script
  terraform  every variable of the tpg-aks-infra root module and its modules is
             referenced as var.<name> (with --infra, or the sibling clone)
  inventory  every leaf key of tpg-aks-infra inventory/clusters.example.yaml appears in
             a script or in the Terraform inventory generator

allow-list.yaml names each key read by something other than the chart render
(the workflows on the hub, for example backup.scheduled) with the file that reads
it; the lint checks that the file still mentions the key. --report prints every
finding with its category, also the allowed ones. Needs PyYAML and helm (the chart
check is skipped with a note without helm).
"""
import argparse
import copy
import glob
import os
import re
import subprocess
import sys
import tempfile

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HERE = os.path.dirname(os.path.abspath(__file__))


def leaves(d, prefix=()):
    """(path tuple, value) of every leaf; an empty map or list is a leaf."""
    if isinstance(d, dict) and d:
        for k, v in d.items():
            yield from leaves(v, prefix + (str(k),))
    else:
        yield prefix, d


def setp(d, path, v):
    for k in path[:-1]:
        d = d.setdefault(k, {})
    d[path[-1]] = v


def mutate(v, path):
    """Another value of the same shape (a render error also counts as evaluated)."""
    if isinstance(v, bool):
        return not v
    if isinstance(v, int):
        return v + 1
    if isinstance(v, list):
        return v + ["10.99.0.0/16"] if not v else v[:-1] or ["mutated"]
    if isinstance(v, dict):
        return {"mutated": "x"} if not v else {}
    if v == "":
        return "mutated-value"
    return str(v) + "-mutated" if not re.fullmatch(r"[0-9]+(\.[0-9]+)?(Gi|Mi|m)?", str(v)) else "3Gi" if str(v) != "3Gi" else "4Gi"


CA = None


def profiles():
    """Base values (the third value file) that switch the optional parts of the chart on."""
    base = {"cluster": {"name": "c1"}, "instance": {"name": "i1", "postgresVersion": "postgres-17.6"},
            "backup": {"container": "pg-backups-c1"}}
    full = copy.deepcopy(base)
    full["instance"].update({"exposure": "internalLoadBalancer", "readOnlyExposure": "internalLoadBalancer",
                             "allowedSourceRanges": ["10.20.0.0/16"], "internalLoadBalancerSubnet": "snet-apps",
                             "serviceAnnotations": {"a": "b"}, "readOnlyServiceAnnotations": {"c": "d"},
                             "highAvailability": {"enabled": True, "readReplicas": 2}})
    full["backup"].update({"enableSSL": True, "caBundle": CA, "scheduled": False,
                           "operatorSchedules": {"full": "0 1 * * 0", "incremental": "0 1 * * 1-6"},
                           "additionalParameters": {"process-max": "4"}, "forcePathStyle": True})
    full["ferret"] = {"enabled": True, "replicas": 2, "readOnlyReplicas": 1, "exposure": "internalLoadBalancer"}
    full["network"] = {"policy": "baseline", "ingressFromNamespaces": ["app"], "ingressFromPodLabels": {"app": "x"},
                       "ingressFromCidrs": ["10.30.0.0/24"], "egressToCidrs": ["10.40.0.0/24"],
                       "egressToFqdns": ["api.example.com"], "acns": True}
    public = copy.deepcopy(full)
    public["instance"].update({"exposure": "loadBalancer", "readOnlyExposure": "loadBalancer"})
    public["ferret"]["exposure"] = "loadBalancer"
    public["network"]["acns"] = False
    return {"default": base, "full": full, "public": public}


def render(chart, files, extra):
    with tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False) as f:
        yaml.safe_dump(extra, f)
        name = f.name
    args = ["helm", "template", "i1", chart, "--namespace", "pg-i1"]
    for v in files + [name]:
        args += ["-f", v]
    r = subprocess.run(args, capture_output=True, text=True)
    os.unlink(name)
    return r.returncode, r.stdout if r.returncode == 0 else r.stderr.split("\n")[0]


def chart_check(findings):
    global CA
    chart = os.path.join(ROOT, "charts", "tpg-instance")
    tpl = [os.path.join(ROOT, "clusters", "_template", "cluster.yaml"), os.path.join(ROOT, "clusters", "_template", "instance.yaml")]
    ca = subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2", "-subj", "/CN=audit",
                         "-keyout", "/dev/null"], capture_output=True, text=True)
    CA = ca.stdout if ca.returncode == 0 else "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n"
    vals = {}
    for f in [os.path.join(chart, "values.yaml")] + tpl:
        for p, v in leaves(yaml.safe_load(open(f)) or {}):
            vals.setdefault(p, (v, os.path.relpath(f, ROOT)))
    profs = profiles()
    base_out = {n: render(chart, tpl, p) for n, p in profs.items()}
    for n, (rc, out) in base_out.items():
        if rc != 0:
            findings.append(("chart", f"profile:{n}", f"the {n} profile does not render: {out}"))
    evaluated = set()
    for path, (v, src) in sorted(vals.items()):
        for n, prof in profs.items():
            p = copy.deepcopy(prof)
            cur = prof
            for k in path:
                cur = cur.get(k) if isinstance(cur, dict) else None
            setp(p, path, mutate(cur if cur is not None else v, path))
            if render(chart, tpl, p) != base_out[n]:
                evaluated.add(path)
                break
        if path not in evaluated:
            findings.append(("chart", ".".join(path), f"{src}: changing it changes no rendered object"))
    return {p for p in vals}


def fleet_check(findings, chart_paths):
    fleet = yaml.safe_load(open(os.path.join(ROOT, "clusters", "fleet.example.yaml")))
    for c, cv in (fleet.get("clusters") or {}).items():
        for i, iv in ((cv or {}).get("instances") or {}).items():
            for p, _ in leaves(iv or {}):
                if p not in chart_paths and not any(p[:n] in chart_paths for n in range(1, len(p))):
                    findings.append(("fleet", "instance." + ".".join(p), "clusters/fleet.example.yaml: not a chart value"))
        for p, _ in leaves({k: v for k, v in (cv or {}).items() if k != "instances"}):
            if p not in chart_paths and not any(p[:n] in chart_paths for n in range(1, len(p))):
                findings.append(("fleet", "cluster." + ".".join(p), "clusters/fleet.example.yaml: not a chart value"))


def scripts_text(paths):
    out = ""
    for pat in paths:
        for f in glob.glob(pat, recursive=True):
            if os.path.isfile(f):
                out += open(f, errors="replace").read() + "\n"
    return out


def inputs_check(findings):
    scripts = scripts_text([os.path.join(ROOT, "workflows", "scripts", "*")])
    for f in sorted(glob.glob(os.path.join(ROOT, "workflows", "templates", "*.yaml"))):
        doc = yaml.safe_load(open(f))
        if not doc or doc.get("kind") != "WorkflowTemplate":
            continue
        name = doc["metadata"]["name"]
        spec = dict(doc["spec"])
        params = [p["name"] for p in (spec.get("arguments") or {}).get("parameters", [])]
        spec.pop("arguments", None)
        body = yaml.safe_dump(spec, width=100000)
        for p in params:
            ref = re.search(r"parameters\." + re.escape(p) + r"\b", body)
            obj = re.search(r'select\(\.name == "' + re.escape(p) + r'"\)', scripts)
            if not ref and not obj:
                findings.append(("inputs", f"{name}.{p}", "the template never references it and no script reads it from the Workflow"))
        for env in sorted(set(re.findall(r"name: (P_[A-Z0-9_]+)", body))):
            if not re.search(r"\b" + env + r"\b", scripts):
                findings.append(("inputs", f"{name}.{env}", "set by the template, read by no script"))


def terraform_check(findings, infra):
    for d in [os.path.join(infra, "terraform")] + sorted(glob.glob(os.path.join(infra, "terraform", "modules", "*"))):
        text = scripts_text([os.path.join(d, "*.tf"), os.path.join(d, "*.tftpl")])
        for v in re.findall(r'^variable "([A-Za-z0-9_]+)"', text, re.M):
            if not re.search(r"\bvar\." + v + r"\b", text):
                findings.append(("terraform", f"{os.path.relpath(d, infra)}:{v}", "declared, never referenced as var." + v))


def inventory_check(findings, infra):
    inv = yaml.safe_load(open(os.path.join(infra, "inventory", "clusters.example.yaml")))
    readers = scripts_text([os.path.join(infra, "scripts", "**", "*.sh"), os.path.join(infra, "scripts", "**", "*.py")])
    keys = set()

    def walk(d):
        if isinstance(d, dict):
            for k, v in d.items():
                keys.add(str(k))
                walk(v)
        elif isinstance(d, list):
            for v in d:
                walk(v)
    walk(inv)
    for k in sorted(keys):
        # .key in a yq/jq program, or cluster_field <cluster> key (scripts/lib/common.sh)
        if not re.search(r"\." + re.escape(k) + r"\b|cluster_field\s+\S+\s+" + re.escape(k) + r"\b", readers):
            findings.append(("inventory", k, "inventory/clusters.example.yaml: no script reads ." + k))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--infra", default=os.environ.get("INFRA_DIR", os.path.join(os.path.dirname(ROOT), "tpg-aks-infra")))
    ap.add_argument("--report", action="store_true", help="print every finding, also the allowed ones")
    a = ap.parse_args()
    allow = yaml.safe_load(open(os.path.join(HERE, "allow-list.yaml"))) or {}
    findings = []
    if subprocess.run(["which", "helm"], capture_output=True).returncode == 0:
        chart_paths = chart_check(findings)
        fleet_check(findings, chart_paths)
    else:
        print("note: helm not installed: chart and fleet checks skipped", file=sys.stderr)
    inputs_check(findings)
    if os.path.isdir(os.path.join(a.infra, "terraform")):
        terraform_check(findings, a.infra)
        inventory_check(findings, a.infra)
    else:
        print(f"note: no tpg-aks-infra clone at {a.infra}: terraform and inventory checks skipped", file=sys.stderr)
    bad = 0
    findings = list(dict.fromkeys(findings))   # one line per key (fleet.example repeats keys per cluster)
    for cat, key, why in findings:
        entry = (allow.get(cat) or {}).get(key)
        if entry:
            reader = os.path.join(a.infra if cat in ("terraform", "inventory") else ROOT, entry.get("readBy", ""))
            short = key.split(".")[-1].split(":")[-1]
            if entry.get("readBy") and not (os.path.isfile(reader) and short in open(reader, errors="replace").read()):
                print(f"FAIL {cat} {key}: allow-list says {entry['readBy']} reads it, but that file does not mention {short}")
                bad += 1
            elif a.report:
                print(f"ok   {cat} {key}: {entry['reason']}")
            continue
        print(f"FAIL {cat} {key}: {why}")
        bad += 1
    for cat, entries in allow.items():
        for key in entries or {}:
            if not any(c == cat and k == key for c, k, _ in findings):
                print(f"FAIL allow-list {cat} {key}: no longer a finding; remove it from allow-list.yaml")
                bad += 1
    print(f"unused keys: {len(findings)} finding(s), {bad} not explained")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
