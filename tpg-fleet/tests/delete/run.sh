#!/usr/bin/env bash
# tpg-delete-instance and tpg-delete-apps with instances that share a namespace (Round 23,
# locked decision 8; workflows/scripts/delete-instance.sh, delete-apps.sh, lib.sh ns_handover) and the
# namespace helpers they and the other workflows use:
#   hand-over     the owner of the shared Secrets leaves: the successor's Application exists first, the
#                 owner flags move in one commit, only the shared objects of the successor's Application
#                 (ServiceAccount tpg-vso, VaultStaticSecrets regsecret and backup-storage) are synced
#                 (it adopts them), the tracking annotation and the health of the Secrets are checked,
#                 and only then the entry leaves Git and the Application is removed - so exactly one
#                 Application tracks the shared Secrets at every step, and they are never deleted. A
#                 failure after the flag commit pushes a revert (the old owner owns them again)
#   successor     tpg-delete-apps: the successor is an instance that stays, never one of the run
#   purge         purgeNamespace is refused while another instance of the namespace remains
#                 (NAMESPACE_SHARED, nothing changes); allowed for the last one; PVCs are the ones of
#                 the instance; tpg-delete-apps defers the namespace to after the last instance of the
#                 run (only when every instance of it in the run purges it), and with deleteOperator
#                 removes everything
#   audit copy    a re-run finds the namespace in clusters/deleted/<cluster>/<instance>-<yyyymmddHHMM>.yaml,
#                 matched by exactly that name (orders is not orders-db), checked against the live Postgres
#   instance_ns   the chain: a checkout, the run inventory, a clone; FLEET_UNREADABLE when none works
#   day0-deploy   a non-owner of the shared Secrets syncs only after they exist (the owner's shared
#                 objects are synced first, or SHARED_SECRETS_MISSING)
# Runs the scripts with the real lib.sh, clustermap.py and chart, and stubs for Git, the Argo CD
# Applications (a sync renders the real chart and moves the tracking annotation to the Application
# whose chart renders the VaultStaticSecret) and the target cluster.
# Requires: bash 4, python3, jq, yq (mikefarah), helm; skipped without them.
# shellcheck disable=SC2015,SC2016
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
for t in python3 jq yq helm; do command -v "$t" >/dev/null || { echo "SKIP tests/delete: $t not installed" >&2; exit 0; }; done
yq --version 2>&1 | grep -q mikefarah || { echo "SKIP tests/delete: yq is not mikefarah yq v4" >&2; exit 0; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
export BLOB_RETRY_BASE=0   # the waits between the tries of a blob request (lib.sh blob_retry): none in the tests
ok()  { printf 'ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL %s\n' "$1"; [[ -z "${2:-}" ]] || printf '%s\n' "$2" | sed 's/^/       | /' | tail -25; FAIL=$((FAIL + 1)); }

REPO="$TMP/repo"
mkdir -p "$REPO/clusters" "$REPO/helm_artifacts"
cp -r "$ROOT/helm_artifacts/instance" "$REPO/helm_artifacts/"
cp -r "$ROOT/clusters/_template" "$REPO/clusters/"
# app-a owns the Secrets of the namespace "shared"; app-b and app-c share it; orders-db is alone in pg-orders-db
cat > "$TMP/fleet.base.yaml" <<'YAML'
clusters:
  c1:
    operator: {version: v4.5.0}
    instances:
      app-a: {instance: {namespace: shared, postgresVersion: postgres-17.6}}
      app-b: {instance: {namespace: shared, sharedSecretsOwner: false, postgresVersion: postgres-17.6}}
      app-c: {instance: {namespace: shared, sharedSecretsOwner: false, postgresVersion: postgres-17.6}}
      orders-db: {instance: {postgresVersion: postgres-17.6}}
YAML

cat > "$TMP/prelude.tmpl" <<'PRELUDE'
export TPG_WORK="@TMP@/work"
source "@ROOT@/workflows/scripts/lib.sh"
CMAP_KEYS="@ROOT@/workflows/params/cluster-map-keys.yaml"
set +e
EV="@TMP@/events"
ev() { printf '%s\n' "$*" >> "$EV"; }
record() { printf '%s|%s|%s|%s\n' "$1" "$2" "${3:-}" "${4:-}" >> "@TMP@/records"; RESULT_RECORDED=1; }
record_entry() { printf '%s|%s|%s|%s\n' "$1" "$2" "${3:-}" "${4:-}" >> "@TMP@/records"; }
run_data() {   # a result key: the last record of it as the JSON delete-instance.sh reads (the final backup); anything else: nothing
  [[ "$1" == result.* ]] || return 0
  grep -F "$1|" "@TMP@/records" | tail -n1 | jq -Rc 'split("|") | {status: .[1], reason: .[2], detail: .[3]}'
}
setting() { :; }
use_cluster() { [[ ! -f "@TMP@/unusable.$1" ]] || return 1; CLUSTER="$1"; }   # $TMP/unusable.<cluster>: its kubeconfig is not there
registered_clusters() { cat "@TMP@/registered"; }
git_clone() { rm -rf "$1"; mkdir -p "$1"; cp -r "@REPO@/." "$1/"; cp "@TMP@/fleet.yaml" "$1/clusters/fleet.yaml"
  [[ ! -d "@TMP@/deleted" ]] || cp -r "@TMP@/deleted" "$1/clusters/deleted"; }
git_commit_push() {
  local dir="$1" n
  # $TMP/pr-timeout: PUSH_MODE=pr, the pull request of the revert is opened and not merged in time
  if [[ -f "@TMP@/pr-timeout" && "$2" == revert* ]]; then PR_NUMBER=42; PR_URL="https://github.example/o/r/pull/42"; ev "pr opened #42 (not merged)"; return 1; fi
  if [[ "${FLEET_CLONE:-}" == "$dir" && -d "$WORK/fleet" ]]; then fleet_flush "$dir"; fi
  fleet_yaml_style "$dir/clusters/fleet.yaml"
  cp "$dir/clusters/fleet.yaml" "@TMP@/fleet.yaml"
  [[ ! -d "$dir/clusters/deleted" ]] || { rm -rf "@TMP@/deleted"; cp -r "$dir/clusters/deleted" "@TMP@/deleted"; }
  n=$(( $(cat "@TMP@/rev" 2>/dev/null || echo 0) + 1 )); echo "$n" > "@TMP@/rev"
  PUSHED_REVISION="rev$n"
  ev "commit rev$n|$2|owners-in-shared=$(yq '[.clusters.c1.instances[] | select(.instance.namespace == "shared") | select(.instance.sharedSecretsOwner != false)] | length' "@TMP@/fleet.yaml")"
  if [[ "${FLEET_CLONE:-}" == "$dir" && -d "$WORK/fleet" ]]; then fleet_materialize "$dir"; fi
}
fleet_head() { echo "rev$(cat "@TMP@/rev" 2>/dev/null || echo 0)"; }
appset_refresh() { :; }
app_exists() { [[ " $(cat "@TMP@/removed" 2>/dev/null | tr '\n' ' ') " != *" $1 "* ]]; }
app_stuck_reason() { :; }
app_removed_or_force() { ev "removed $1|tracked-by=$(cat "@TMP@/tracked")"; echo "$1" >> "@TMP@/removed"; FORCED_NOTE=""; return 0; }
# a sync renders the chart of the instance from the pushed fleet.yaml; the Application whose chart renders
# the shared VaultStaticSecret becomes the one Argo CD tracks it with (the apply writes the annotation).
# --resources: a selective sync (the event says which objects). $TMP/sync-fail: the sync fails;
# $TMP/no-move: it succeeds and changes nothing; $TMP/partial: the sync of app-b moves ServiceAccount tpg-vso
# only and fails (a selective sync applied part of its objects); $TMP/late: the sync of app-b times out and its
# operation keeps running (op-running) - it finishes after the next sync of another Application and then
# takes all three objects; $TMP/stuck-sa: a sync of an owner leaves tpg-vso with the Application that had it
# $TMP/tracked.<object>: an object with its own tracking Application (else $TMP/tracked)
sleep() { :; }
export SYNC_OP_WAIT_SECONDS=0 SYNC_TERMINATE_WAIT_SECONDS=5
app_get() { if [[ -s "@TMP@/op-running" && "$1" == "$(cat "@TMP@/op-running")" ]]; then echo '{"status":{"operationState":{"phase":"Running"}}}'; else echo '{}'; fi; }
acd() {
  local app
  if [[ "$1" == DELETE && "$2" == */operation ]]; then app="${2#/api/v1/applications/}"; app="${app%/operation}"; ev "terminate $app"; : > "@TMP@/op-running"; fi
}
app_sync_wait() {
  local app="$1" inst sel="full" tail
  inst="${app#tpg-c1-}"
  shift 2
  while [[ $# -gt 0 ]]; do case "$1" in --resources) sel="selective:$2"; shift 2 ;; --revision) shift 2 ;; *) shift ;; esac; done
  if [[ -f "@TMP@/partial" && "$app" == tpg-c1-app-b ]]; then
    echo "$app" > "@TMP@/tracked.tpg-vso"
    SYNC_FAIL_REASON=SYNC_FAILED; SYNC_FAIL_DETAIL="$app: VaultStaticSecret regsecret failed to apply"
    ev "sync $app|partly applied (tpg-vso moved)|tracked-by=$(cat "@TMP@/tracked")|$sel"
    return 1
  fi
  if [[ -f "@TMP@/late" && "$app" == tpg-c1-app-b ]]; then
    echo "$app" > "@TMP@/op-running"
    SYNC_FAIL_REASON=SYNC_TIMEOUT; SYNC_FAIL_DETAIL="$app: the sync operation did not finish in 600s"
    ev "sync $app|timeout, the operation keeps running|tracked-by=$(cat "@TMP@/tracked")|$sel"
    return 2
  fi
  if [[ -f "@TMP@/sync-fail" ]]; then
    SYNC_FAIL_REASON=SYNC_FAILED; SYNC_FAIL_DETAIL="$app: sync failed"
    ev "sync $app|failed|tracked-by=$(cat "@TMP@/tracked")|$sel"
    return 1
  fi
  rm -rf "@TMP@/render-repo"; mkdir -p "@TMP@/render-repo/clusters" "@TMP@/render-repo/helm_artifacts"
  cp -r "@REPO@/helm_artifacts/instance" "@TMP@/render-repo/helm_artifacts/"; cp -r "@REPO@/clusters/_template" "@TMP@/render-repo/clusters/"
  cp "@TMP@/fleet.yaml" "@TMP@/render-repo/clusters/fleet.yaml"
  if instance_render "@TMP@/render-repo" c1 "$inst" 2>/dev/null | yq -e 'select(.kind == "VaultStaticSecret" and .metadata.name == "regsecret")' >/dev/null 2>&1; then
    if [[ ! -f "@TMP@/no-move" ]]; then
      echo "$app" > "@TMP@/tracked"
      [[ -f "@TMP@/stuck-sa" ]] && echo tpg-c1-app-b > "@TMP@/tracked.tpg-vso" || rm -f "@TMP@"/tracked.*
    fi
    ev "sync $app|renders the shared Secrets|tracked-by=$(cat "@TMP@/tracked")|$sel"
  else
    ev "sync $app|renders no shared Secrets|tracked-by=$(cat "@TMP@/tracked")|$sel"
  fi
  if [[ -s "@TMP@/op-running" && "$(cat "@TMP@/op-running")" != "$app" ]]; then   # the operation that timed out finishes now
    cp "@TMP@/op-running" "@TMP@/tracked"; rm -f "@TMP@"/tracked.*; : > "@TMP@/op-running"
    ev "late operation finished after the sync of $app: all three objects are tracked by $(cat "@TMP@/tracked")"
  fi
  return 0
}
live_items() {  # live_items [NAMESPACE]: the Postgres objects as the kubectl list JSON
  jq -Rn '[inputs | split(" ") | select(length == 2) | {metadata: {name: .[0], namespace: .[1]}}]' < "@TMP@/live" \
    | jq -c --arg ns "${1:-}" '{items: [.[] | select($ns == "" or .metadata.namespace == $ns)]}'
}
# Azure Blob (purgeBackups): curl is stubbed by a fake storage account, @TMP@/blobserver.py. It checks the SharedKey
# signature of every request against the documented algorithm (its own implementation: the string to sign, the
# canonicalized headers and resource), serves List Blobs with prefix and marker paging ($STUB_PAGE names a page) and
# Delete Blob over the blobs in @TMP@/blobs ("container/name" lines), and writes "blob ..." events. The Authorization
# header arrives on stdin (-H @-), the way lib.sh sends it
curl() {
  local out="" url="" verb=GET hdrs="" auth=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -o) out="$2"; shift 2 ;;
      -w|--max-time) shift 2 ;;
      -X) verb="$2"; shift 2 ;;
      -H) if [[ "$2" == "@-" ]]; then auth="$(cat)"; else hdrs+="$2"$'\n'; fi; shift 2 ;;
      -*) shift ;;
      *) url="$1"; shift ;;
    esac
  done
  STUB_VERB="$verb" STUB_URL="$url" STUB_AUTH="$auth" STUB_HEADERS="$hdrs" STUB_OUT="$out" STUB_KEY="$(cat "@VAULTD@/server-key")" \
    STUB_BLOBS="@TMP@/blobs" STUB_EV="@TMP@/events" STUB_FAIL="@TMP@/blob-fail" STUB_PAGE="${STUB_PAGE:-3}" python3 "@TMP@/blobserver.py"
}

tk() {
  local ns="" args="$*" name
  [[ "$1" != "-n" ]] || ns="$2"
  case "$args" in
    *readyz*) return 0 ;;
    *"get crd postgres.sql.tanzu.vmware.com"*) return 0 ;;
    *"get crd postgresbackuplocations"*)   # $TMP/crd-error.<cluster>: the API server of that cluster does not answer (not a NotFound); $TMP/crd-notfound.<cluster>: the CRD is not there
      if [[ -f "@TMP@/crd-error.$CLUSTER" ]]; then echo "Unable to connect to the server: net/http: request canceled (Client.Timeout exceeded)" >&2; return 1; fi
      if [[ -f "@TMP@/crd-notfound.$CLUSTER" ]]; then echo "Error from server (NotFound): customresourcedefinitions.apiextensions.k8s.io \"postgresbackuplocations.sql.tanzu.vmware.com\" not found" >&2; return 1; fi
      return 0 ;;
    *"get crd -o name"*) return 0 ;;
    *"get postgresbackuplocation -A -o json"*)   # the locations of CLUSTER: $TMP/locations lines cluster|namespace|name|container|repoPath|endpoint|secret
      jq -Rn --arg c "$CLUSTER" '[inputs | split("|") | select(length >= 5 and .[0] == $c)
        | {metadata: {namespace: .[1], name: .[2]}, spec: {storage: {azure: ({container: .[3], repoPath: .[4], secret: {name: (.[6] // "backup-storage")}}
            + (if (.[5] // "") != "" then {endpoint: .[5]} else {} end))}}}] | {items: .}' < "@TMP@/locations" | jq -c . ;;
    *" get postgresbackuplocation "*"--ignore-not-found"*)
      jq -Rn --arg c "$CLUSTER" --arg ns "$ns" --arg n "$5" '[inputs | split("|") | select(length >= 5 and .[0] == $c and .[1] == $ns and .[2] == $n)
        | {metadata: {namespace: .[1], name: .[2]}, spec: {storage: {azure: ({container: .[3], repoPath: .[4], secret: {name: (.[6] // "backup-storage")}}
            + (if (.[5] // "") != "" then {endpoint: .[5]} else {} end))}}}] | .[0] // empty' < "@TMP@/locations" | jq -c . ;;
    *" delete postgresbackuplocation "*)
      ev "delete postgresbackuplocation $ns/$5"; grep -vF "$CLUSTER|$ns|$5|" "@TMP@/locations" > "@TMP@/locations.n" || true; mv "@TMP@/locations.n" "@TMP@/locations" ;;
    *" get secret "*accountName*)   # $TMP/secret-unreadable.<name>: that Secret cannot be read
      [[ ! -f "@TMP@/secret-unreadable.$5" ]] || return 1
      printf '%s' "$(cat "@TMP@/acct.$CLUSTER.$ns" 2>/dev/null || printf 'acct1')" | base64 ;;
    *" get postgresbackup -o json"*)   # the backups of $TMP/backups.json plus the unfinished operations of $TMP/busyops
      jq -cn --slurpfile b "@TMP@/backups.json" --argjson busy "$(jq -Rn --arg ns "$ns" '[inputs | split(" ") | select(length == 2 and .[0] == $ns and .[1] == "postgresbackup")
        | {metadata: {name: "op"}, status: {phase: "Running"}}]' < "@TMP@/busyops")" '{items: ($b[0].items + $busy)}' ;;
    *" get postgresbackup "*"--ignore-not-found"*)
      jq -c --arg n "$5" '.items[] | select(.metadata.name == $n)' "@TMP@/backups.json" ;;
    *" patch postgresbackup "*)   # an expire: the stub plays the operator (removes the backup and, for a full one, its chain); $TMP/decline.<name>, $TMP/silent.<name>
      name="$5"; ev "expire $name"
      if [[ -f "@TMP@/patch-error.$name" ]]; then echo "Error from server (Forbidden): postgresbackups \"$name\" is forbidden" >&2; return 1; fi
      if [[ -f "@TMP@/silent.$name" ]]; then
        jq --arg n "$name" '(.items[] | select(.metadata.name == $n) | .spec.expire) = true' "@TMP@/backups.json" > "@TMP@/b.n"
      elif [[ -f "@TMP@/decline.$name" ]]; then
        jq --arg n "$name" '(.items[] | select(.metadata.name == $n)) |= (.spec.expire = true | .status.conditions = [{type: "Expired", reason: "ExpireFailed", status: "False", message: "pgBackRest: unable to remove the latest full backup"}])' "@TMP@/backups.json" > "@TMP@/b.n"
      else
        jq --arg n "$name" '([.items[] | select(.metadata.name == $n) | .status.restoreLabel][0] // "") as $l
          | .items |= map(select(.metadata.name != $n and (($l | endswith("F")) and ((.status.restoreLabel // "") | startswith($l + "_")) | not)))' "@TMP@/backups.json" > "@TMP@/b.n"
      fi
      mv "@TMP@/b.n" "@TMP@/backups.json" ;;
    *" apply -f -"*) cat > "@TMP@/applied"; ev "apply $ns|$(awk '/^kind:/ {print $2}' "@TMP@/applied")" ;;   # the final backup: a PostgresBackup in the namespace it is asked in
    *" get postgresbackup -o json"*|*" get postgresrestore -o json"*|*" get postgresversionupgrade -o json"*)   # $TMP/busyops: "<namespace> <kind>" lines of unfinished operations
      jq -Rn --arg ns "$ns" --arg k "${args##* get }" '[inputs | split(" ") | select(length == 2 and .[0] == $ns and .[1] == ($k | split(" ")[0]))
        | {metadata: {name: "op"}, status: {phase: "Running"}}] | {items: .}' < "@TMP@/busyops" | jq -c . ;;
    *"get vaultstaticsecret "*|*"get serviceaccount "*)   # the shared objects: tracked by the Application $TMP/tracked (or tracked.<name>) names
      jq -cn --arg t "$(cat "@TMP@/tracked.${5}" 2>/dev/null || cat "@TMP@/tracked"):apiextensions/Shared:${ns}/${5}" --arg r "$([[ -f "@TMP@/vss-not-ready" ]] && echo False || echo True)" \
        '{metadata: {annotations: {"argocd.argoproj.io/tracking-id": $t}}, status: {conditions: [{type: "Ready", status: $r}]}}' ;;
    *" get postgresbackup "*"-o json"*) echo '{"status":{"phase":"Succeeded","size":"1GB"}}' ;;
    "get postgres -A -o json"*) live_items ;;
    *" get postgres -o json"*) live_items "$ns" ;;
    *" get postgres "*)
      name="$5"
      grep -qx "$name $ns" "@TMP@/live" || { echo "Error from server (NotFound): postgres \"$name\" not found" >&2; return 1; }
      case "$args" in *currentState*) if [[ -f "@TMP@/pgstate" ]]; then cat "@TMP@/pgstate"; else printf 'Running'; fi ;; *stanzaName*) printf 'stanza-%s' "$name" ;; esac ;;
    *" get pvc"*)
      sel=""; [[ "$args" != *"-l postgres-instance="* ]] || sel="$(sed -E 's/.*-l postgres-instance=([^ ]+).*/\1/' <<<"$args")"
      jq -Rn --arg ns "$ns" --arg sel "$sel" '[inputs | split(" ") | select(length == 3 and .[1] == $ns and ($sel == "" or .[2] == $sel))
        | {metadata: {name: .[0]}, spec: {volumeName: ("pv-" + .[0])}}] | {items: .}' < "@TMP@/pvcs" | jq -c . ;;
    *" delete postgres "*)
      name="$5"; ev "delete postgres $ns/$name"; grep -vx "$name $ns" "@TMP@/live" > "@TMP@/live.n"; mv "@TMP@/live.n" "@TMP@/live"
      # $TMP/late-location: another cluster gets a location on the repository after the first check (and before the blobs)
      if [[ -f "@TMP@/late-location" ]]; then echo c2 >> "@TMP@/registered"; echo 'c2|team-x|late|pg-backups-c1|/pg-orders-db/orders-db' >> "@TMP@/locations"; fi ;;
    *" delete pvc "*)
      ev "delete pvc $ns|$(sed -E 's/.* delete pvc //' <<<"$args")"
      sel=""; [[ "$args" != *"-l postgres-instance="* ]] || sel="$(sed -E 's/.*-l postgres-instance=([^ ]+).*/\1/' <<<"$args")"
      awk -v ns="$ns" -v sel="$sel" '!($2 == ns && (sel == "" || $3 == sel))' "@TMP@/pvcs" > "@TMP@/pvcs.n"; mv "@TMP@/pvcs.n" "@TMP@/pvcs" ;;
    "delete namespace "*) ev "delete namespace $3"; echo "$3" >> "@TMP@/nsgone" ;;
    "get namespace "*) ! grep -qx "$3" "@TMP@/nsgone" ;;
    *" get "*"-o json"*) echo '{"items":[]}' ;;
    *) return 0 ;;
  esac
}
PRELUDE

# ---- the fake storage account behind curl (purgeBackups): SharedKey checked per the Azure documentation
cat > "$TMP/blobserver.py" <<'PY'
import base64, fcntl, hashlib, hmac, os, sys, urllib.parse
import xml.etree.ElementTree as ET

verb, url, auth = os.environ["STUB_VERB"], os.environ["STUB_URL"], os.environ["STUB_AUTH"].strip()
headers = {}
for line in os.environ["STUB_HEADERS"].splitlines():
    if ":" in line:
        k, v = line.split(":", 1)
        headers[k.strip().lower()] = v.strip()
u = urllib.parse.urlparse(url)
account = u.netloc.split(".")[0]
query = urllib.parse.parse_qs(u.query, keep_blank_values=True)

def reply(code, body=""):
    out = os.environ["STUB_OUT"]
    if out and body:
        with open(out, "w") as f:
            f.write(body)
    elif out and out != "/dev/null":
        open(out, "w").close()
    print(code, end="")
    sys.exit(0)

def ev(line):
    with open(os.environ["STUB_EV"], "a") as f:
        f.write(line + "\n")

# the string to sign, from the documentation of the Blob service (Shared Key, version 2021-08-06)
canon_headers = "".join(f"{k}:{v}\n" for k, v in sorted(headers.items()) if k.startswith("x-ms-"))
canon_res = "/" + account + u.path
for k in sorted(query):
    canon_res += "\n" + k.lower() + ":" + ",".join(query[k])
sts = verb + "\n" + "\n" * 11 + canon_headers + canon_res
sig = base64.b64encode(hmac.new(base64.b64decode(os.environ["STUB_KEY"]), sts.encode(), hashlib.sha256).digest()).decode()
if auth != f"Authorization: SharedKey {account}:{sig}":
    ev("blob 403 bad signature")
    reply(403, "<Error><Code>AuthenticationFailed</Code></Error>")
if headers.get("x-ms-version") != "2021-08-06":
    reply(400)

container = u.path.strip("/").split("/")[0]
blobs = [l.rstrip("\n") for l in open(os.environ["STUB_BLOBS"]) if l.strip()]
if verb == "GET" and query.get("comp") == ["list"]:
    prefix = query.get("prefix", [""])[0]
    marker = query.get("marker", [""])[0]
    if query.get("maxresults") == ["1"] and os.path.exists(os.environ["STUB_FAIL"] + ".badcheck"):    # the check listing after the delete: an answer that is no XML
        ev("blob LIST check -> garbage")
        reply(200, "<html>bad gateway")
    page = min(int(query.get("maxresults", ["5000"])[0]), int(os.environ["STUB_PAGE"]))
    names = sorted(b[len(container) + 1:] for b in blobs if b.startswith(container + "/"))
    names = [n for n in names if n.startswith(prefix) and n >= marker]
    ev(f"blob LIST {container} prefix={prefix} marker={marker} -> {len(names[:page])}")
    root = ET.Element("EnumerationResults")
    bl = ET.SubElement(root, "Blobs")
    for n in names[:page]:
        ET.SubElement(ET.SubElement(bl, "Blob"), "Name").text = n
    ET.SubElement(root, "NextMarker").text = names[page] if len(names) > page else ""
    reply(200, ET.tostring(root, encoding="unicode"))
if verb == "DELETE":
    name = urllib.parse.unquote(u.path.strip("/")[len(container) + 1:])
    full = container + "/" + name
    fail = os.environ["STUB_FAIL"]
    if os.path.exists(fail) and open(fail).read().strip() == full:
        ev(f"blob DELETE {full} -> 500")
        reply(500)
    flaky = os.environ["STUB_FAIL"] + ".flaky"      # "<blob> <status> <times>": that many answers with the status, then the real one
    if os.path.exists(flaky):
        fb, fcode, ftimes = open(flaky).read().split()
        if fb == full:
            seen = int(open(flaky + ".n").read()) if os.path.exists(flaky + ".n") else 0
            if seen < int(ftimes):
                open(flaky + ".n", "w").write(str(seen + 1))
                ev(f"blob DELETE {full} -> {fcode}")
                reply(int(fcode))
    if full not in blobs:
        ev(f"blob DELETE {full} -> 404")
        reply(404)
    with open(os.environ["STUB_BLOBS"] + ".lock", "w") as lock:    # the client deletes 8 blobs at a time
        fcntl.flock(lock, fcntl.LOCK_EX)
        blobs = [l.rstrip("\n") for l in open(os.environ["STUB_BLOBS"]) if l.strip()]
        if full not in blobs:
            ev(f"blob DELETE {full} -> 404")
            reply(404)
        blobs.remove(full)
        with open(os.environ["STUB_BLOBS"] + ".new", "w") as f:    # replaced whole: a reader never sees half a file
            f.write("".join(b + "\n" for b in blobs))
        os.replace(os.environ["STUB_BLOBS"] + ".new", os.environ["STUB_BLOBS"])
    ev(f"blob DELETE {full}")
    reply(202)
reply(400)
PY
STORAGE_KEY="$(printf 'storage-account-key-0123456789ab' | base64)"   # the fleet's key (Vault tpg/shared/backup-storage)
VAULTD="$TMP-vault"; mkdir -p "$VAULTD"; trap 'rm -rf "$TMP" "$VAULTD"' EXIT
export VAULT_SECRETS_DIR="$VAULTD"
jq -n --arg k "$STORAGE_KEY" '{accountName: "acct1", accountKey: $k}' > "$VAULTD/backup-storage.json"
sed -e "s#@TMP@#$TMP#g" -e "s#@ROOT@#$ROOT#g" -e "s#@REPO@#$REPO#g" -e "s#@VAULTD@#$VAULTD#g" "$TMP/prelude.tmpl" > "$TMP/prelude.sh"
for s in delete-instance delete-apps backup-instance; do
  sed -e "s#source /scripts/lib.sh#source $TMP/prelude.sh#" -e "s#bash /scripts/delete-instance.sh#bash $TMP/delete-instance.sh#" -e "s#bash /scripts/backup-instance.sh#bash $TMP/backup-instance.sh#" \
    "$ROOT/workflows/scripts/$s.sh" > "$TMP/$s.sh"
done

cat > "$TMP/backups.base.json" <<'JSON'
{"items": [
 {"metadata": {"name": "orders-full-1"},  "spec": {"sourceInstance": {"name": "orders-db"}}, "status": {"phase": "Succeeded", "restoreLabel": "20260101-000000F"}},
 {"metadata": {"name": "orders-incr-1a"}, "spec": {"sourceInstance": {"name": "orders-db"}}, "status": {"phase": "Succeeded", "restoreLabel": "20260101-000000F_20260102-000000I"}},
 {"metadata": {"name": "orders-full-2"},  "spec": {"sourceInstance": {"name": "orders-db"}}, "status": {"phase": "Succeeded", "restoreLabel": "20260110-000000F"}},
 {"metadata": {"name": "orders-failed"},  "spec": {"sourceInstance": {"name": "orders-db"}}, "status": {"phase": "Failed"}},
 {"metadata": {"name": "app-a-full-1"},   "spec": {"sourceInstance": {"name": "app-a"}},     "status": {"phase": "Succeeded", "restoreLabel": "20260101-000000F"}}
]}
JSON
# the fake storage account: the repository of orders-db (7 blobs: paging with 3 a page), its neighbours that must stay
# (orders-db-2 shares the prefix text, app-a is another instance), a container of another cluster
cat > "$TMP/blobs.base" <<'BLOBS'
pg-backups-c1/pg-orders-db/orders-db/archive/stanza/17-1/0000000100000000/000000010000000000000001-aa.gz
pg-backups-c1/pg-orders-db/orders-db/archive/stanza/17-1/0000000100000000/000000010000000000000002-bb.gz
pg-backups-c1/pg-orders-db/orders-db/archive/stanza/archive.info
pg-backups-c1/pg-orders-db/orders-db/backup/stanza/20260101-000000F/backup.manifest
pg-backups-c1/pg-orders-db/orders-db/backup/stanza/20260101-000000F/pg_data/base 1
pg-backups-c1/pg-orders-db/orders-db/backup/stanza/backup.info
pg-backups-c1/pg-orders-db/orders-db/backup/stanza/backup.info.copy
pg-backups-c1/pg-orders-db/orders-db-2/archive/stanza/archive.info
pg-backups-c1/pg-orders-db/orders-db-2/backup/stanza/backup.info
pg-backups-c1/shared/app-a/archive/stanza/archive.info
pg-backups-c1/pg-orders-dbx/archive.info
pg-backups-c2/pg-orders-db/orders-db/archive/stanza/archive.info
BLOBS
reset() {  # reset [REMOVE_INSTANCES...]: the base fleet, every instance running, one PVC each, app-a tracks the shared Secrets
  rm -rf "$TMP/work" "$TMP/deleted" "$TMP/render-repo"; rm -f "$TMP/sync-fail" "$TMP/no-move" "$TMP/vss-not-ready" "$TMP/partial" "$TMP/late" "$TMP/stuck-sa" "$TMP/pr-timeout" "$TMP"/tracked.*; : > "$TMP/op-running"; : > "$TMP/busyops"; : > "$TMP/nsgone"; : > "$TMP/records"; : > "$TMP/events"; : > "$TMP/removed"; echo 0 > "$TMP/rev"
  cp "$TMP/fleet.base.yaml" "$TMP/fleet.yaml"
  printf 'app-a shared\napp-b shared\napp-c shared\norders-db pg-orders-db\n' > "$TMP/live"
  printf 'data-app-a-0 shared app-a\ndata-app-b-0 shared app-b\ndata-app-c-0 shared app-c\ndata-orders-db-0 pg-orders-db orders-db\n' > "$TMP/pvcs"
  echo tpg-c1-app-a > "$TMP/tracked"
  # purgeBackups: the backup locations of every instance (their repoPath is /<namespace>/<instance>), the registered
  # clusters, the backups of orders-db, the blobs of the fake storage account, and the key the server checks
  rm -f "$TMP/pgstate" "$TMP"/unusable.* "$TMP"/silent.* "$TMP"/decline.* "$TMP/blob-fail" "$TMP"/blob-fail.* "$TMP"/acct.* "$TMP"/crd-error.* "$TMP"/crd-notfound.* \
    "$TMP"/secret-unreadable.* "$TMP"/patch-error.* "$TMP/late-location"
  printf 'c1|shared|app-a-backup-location|pg-backups-c1|/shared/app-a\nc1|shared|app-b-backup-location|pg-backups-c1|/shared/app-b\nc1|shared|app-c-backup-location|pg-backups-c1|/shared/app-c\nc1|pg-orders-db|orders-db-backup-location|pg-backups-c1|/pg-orders-db/orders-db\n' > "$TMP/locations"
  echo c1 > "$TMP/registered"; cp "$TMP/backups.base.json" "$TMP/backups.json"; cp "$TMP/blobs.base" "$TMP/blobs"; printf '%s' "$STORAGE_KEY" > "$VAULTD/server-key"
  local i
  for i in "$@"; do
    I="$i" yq -i 'del(.clusters.c1.instances[strenv(I)])' "$TMP/fleet.yaml"
    grep -vE "^$i " "$TMP/live" > "$TMP/live.n"; mv "$TMP/live.n" "$TMP/live"
    grep -vE " $i\$" "$TMP/pvcs" > "$TMP/pvcs.n"; mv "$TMP/pvcs.n" "$TMP/pvcs"
  done
}
del() {  # del INSTANCE FINAL PVCS NS -> tpg-delete-instance; output in $OUT, status in $RC
  RC=0; OUT="$(bash "$TMP/delete-instance.sh" wf c1 "$1" "$1" "$2" "$3" "$4" 600 2>&1)" || RC=$?
}
apps() {  # apps JSON PVCS NS [DRY] -> tpg-delete-apps
  RC=0; OUT="$(P_APPS="$1" P_DRY_RUN="${4:-false}" P_PURGE_PVCS="$2" P_PURGE_NS="$3" P_FINAL_BACKUP=false P_FORCE=false P_TIMEOUT=600 \
    bash "$TMP/delete-apps.sh" wf c1 2>&1)" || RC=$?
}
appsmap() {  # appsmap CLUSTERMAP_JSON [DRY] -> tpg-delete-apps with a clusterMap (the normalized map, as clustermap.py makes it)
  mkdir -p "$TMP/work"; printf '%s' "$1" > "$TMP/work/cmap.json"
  RC=0; OUT="$(P_CLUSTER_MAP=map P_DRY_RUN="${2:-false}" P_FINAL_BACKUP=false P_PURGE_PVCS=false P_PURGE_NS=false P_FORCE=false P_TIMEOUT=600 \
    bash "$TMP/delete-apps.sh" wf c1 2>&1)" || RC=$?
}
rec() { grep -F "$1" "$TMP/records" || true; }
lineno() { { grep -n -F -- "$1" "$TMP/events" || true; } | head -n1 | cut -d: -f1; }   # first line of the events file with the text, empty when none
has_ev() { grep -qF -- "$1" "$TMP/events"; }
owners_now() { yq '[.clusters.c1.instances[] | select(.instance.namespace == "shared") | select(.instance.sharedSecretsOwner != false)] | length' "$TMP/fleet.yaml"; }

# ---- the owner leaves: hand-over
reset
del app-a false false false
c1="$(lineno 'commit rev1|move the shared Secrets of c1/shared from app-a to app-b')"
s1="$(lineno 'sync tpg-c1-app-b|renders the shared Secrets|tracked-by=tpg-c1-app-b')"
c2="$(lineno 'commit rev2|delete c1/app-a')"
r1="$(lineno 'removed tpg-c1-app-a|tracked-by=tpg-c1-app-b')"
[[ "$RC" -eq 0 && -n "$c1" && -n "$s1" && -n "$c2" && -n "$r1" && "$c1" -lt "$s1" && "$s1" -lt "$c2" && "$c2" -lt "$r1" ]] \
  && ok "hand-over: commit the owner flags, sync the successor (it adopts the Secrets), then remove the entry and the Application of the old owner" \
  || bad "hand-over order" "$(cat "$TMP/events") $OUT"
has_ev 'commit rev1|move the shared Secrets of c1/shared from app-a to app-b|owners-in-shared=1' && has_ev 'commit rev2|delete c1/app-a (wf)|owners-in-shared=1' \
  && ok "hand-over: exactly one instance of the namespace is the owner in both commits" || bad "one owner per commit" "$(cat "$TMP/events")"
grep -q '^tpg-c1-app-b$' "$TMP/tracked" && [[ "$(grep -c 'tracked-by=' "$TMP/events")" -ge 2 ]] && ! grep -q 'tracked-by=$' "$TMP/events" \
  && ok "hand-over: the tracking annotation names one Application at every step (app-a, then app-b from the sync on)" || bad "tracked" "$(cat "$TMP/events")"
! has_ev 'delete postgres shared/app-b' && ! has_ev 'delete postgres shared/app-c' && ! has_ev 'delete namespace' \
  && ok "hand-over: nothing of the other instances is deleted (the shared Secrets stay)" || bad "nothing else deleted" "$(cat "$TMP/events")"
yq -e '.clusters.c1.instances | has("app-a") | not' "$TMP/fleet.yaml" >/dev/null \
  && [[ "$(yq '.clusters.c1.instances["app-b"].instance | has("sharedSecretsOwner")' "$TMP/fleet.yaml")" == false \
        && "$(yq '.clusters.c1.instances["app-c"].instance.sharedSecretsOwner' "$TMP/fleet.yaml")" == false ]] \
  && ok "hand-over: app-b is the owner now (no flag), app-c stays a non-owner, app-a is gone from fleet.yaml" || bad "flags after" "$(cat "$TMP/fleet.yaml")"
ls "$TMP/deleted/c1/"app-a-*.yaml >/dev/null 2>&1 && [[ "$(yq '.instance.namespace' "$TMP"/deleted/c1/app-a-*.yaml)" == shared ]] \
  && ok "the audit copy keeps the namespace" || bad "audit copy" "$(ls -R "$TMP/deleted" 2>&1)"
rec "result.c1.app-a|SUCCEEDED" | grep -q "shared Secrets of shared moved to app-b" \
  && ok "hand-over: the result names the move" || bad "hand-over result" "$(cat "$TMP/records")"

# a hand-over that failed half way: app-a is not the owner any more, app-b is, but still app-a tracks the Secrets
reset
yq -i '.clusters.c1.instances["app-a"].instance.sharedSecretsOwner = false | del(.clusters.c1.instances["app-b"].instance.sharedSecretsOwner)' "$TMP/fleet.yaml"
del app-a false false false
has_ev 'sync tpg-c1-app-b|renders the shared Secrets|tracked-by=tpg-c1-app-b' && ! has_ev 'move the shared Secrets' && [[ "$RC" -eq 0 ]] \
  && ok "hand-over: a run after a half-done hand-over only syncs the owner (no second commit) and goes on" || bad "half-done" "$(cat "$TMP/events") $OUT"

# the successor cannot take over (its sync fails): the owner flag commit is reverted, the instance stays
reset
touch "$TMP/sync-fail"
del app-a false false false
rec "result.c1.app-a|FAILED|HANDOVER_FAILED" | grep -q "SYNC_FAILED" && has_ev 'commit rev1|move the shared Secrets of c1/shared from app-a to app-b' \
  && has_ev 'commit rev2|revert the hand-over of the shared Secrets of c1/shared from app-a to app-b|owners-in-shared=1' \
  && ! has_ev 'commit rev3' && ! has_ev 'removed' && ! has_ev 'delete c1/app-a' && yq -e '.clusters.c1.instances | has("app-a")' "$TMP/fleet.yaml" >/dev/null \
  && ok "hand-over: when the successor does not sync, the flag commit is reverted (rev2) and the delete stops before app-a leaves Git (HANDOVER_FAILED)" \
  || bad "hand-over failed" "$(cat "$TMP/events") $(cat "$TMP/records")"
[[ "$(owners_now)" == 1 && "$(yq '.clusters.c1.instances["app-a"].instance | has("sharedSecretsOwner")' "$TMP/fleet.yaml")" == false \
   && "$(yq '.clusters.c1.instances["app-b"].instance.sharedSecretsOwner' "$TMP/fleet.yaml")" == false ]] && grep -q '^tpg-c1-app-a$' "$TMP/tracked" \
  && ok "hand-over: after the revert Git has app-a as the owner again (app-b a non-owner) and Argo CD still tracks the Secrets with app-a" || bad "revert state" "$(cat "$TMP/fleet.yaml") $(cat "$TMP/tracked")"
rec "result.c1.app-a|FAILED|HANDOVER_FAILED" | grep -q "owner flags were reverted in Git" \
  && ok "hand-over: the failure says the flags were reverted" || bad "revert text" "$(cat "$TMP/records")"
# the sync succeeds but the Secrets are not taken over / not healthy: the same revert
reset
touch "$TMP/no-move"
del app-a false false false
has_ev 'commit rev2|revert the hand-over' && ! has_ev 'delete c1/app-a' && rec "result.c1.app-a|FAILED|HANDOVER_FAILED" | grep -q "tracked by" \
  && ok "hand-over: a sync that does not move the tracking annotation is reverted as well" || bad "no-move" "$(cat "$TMP/events") $(cat "$TMP/records")"
# the sync moved the annotation but a VaultStaticSecret is not healthy: reverted, and the annotation goes back to app-a
reset
touch "$TMP/vss-not-ready"
del app-a false false false
c1="$(lineno 'sync tpg-c1-app-b|renders the shared Secrets|tracked-by=tpg-c1-app-b')"
c2="$(lineno 'commit rev2|revert the hand-over')"
c3="$(lineno 'sync tpg-c1-app-a|renders the shared Secrets|tracked-by=tpg-c1-app-a|selective:')"
[[ -n "$c1" && -n "$c2" && -n "$c3" && "$c1" -lt "$c2" && "$c2" -lt "$c3" ]] && grep -q '^tpg-c1-app-a$' "$TMP/tracked" && [[ "$(owners_now)" == 1 ]] \
  && ok "hand-over: Secrets not healthy after the successor's sync: reverted, and the objects are synced back to app-a (the annotation returns)" \
  || bad "unhealthy revert" "$(cat "$TMP/events") $(cat "$TMP/records")"
# the revert re-syncs the old owner whatever regsecret says (Round 23 re-review): a selective sync that applied
# ServiceAccount tpg-vso and failed on a VaultStaticSecret leaves regsecret with app-a and tpg-vso with app-b
trk() { local n out=""; for n in tpg-vso regsecret backup-storage; do out+="$(cat "$TMP/tracked.$n" 2>/dev/null || cat "$TMP/tracked") "; done; printf '%s' "${out% }"; }
reset
touch "$TMP/partial"
del app-a false false false
r2="$(lineno 'commit rev2|revert the hand-over')"; r3="$(lineno 'sync tpg-c1-app-a|renders the shared Secrets|tracked-by=tpg-c1-app-a|selective:')"
[[ -n "$r2" && -n "$r3" && "$r2" -lt "$r3" && "$(trk)" == "tpg-c1-app-a tpg-c1-app-a tpg-c1-app-a" ]] && ! has_ev 'delete c1/app-a' \
  && rec "result.c1.app-a|FAILED|HANDOVER_FAILED" | grep -q "ServiceAccount tpg-vso and VaultStaticSecrets regsecret and backup-storage are tracked by tpg-c1-app-a again" \
  && ok "hand-over revert: a partly applied selective sync (tpg-vso moved, regsecret not) is repaired - old owner synced again, all three objects tracked by it, said in the report" \
  || bad "partial apply revert" "$(trk) $(cat "$TMP/events") $(cat "$TMP/records")"
# a sync that timed out keeps running in Argo CD and would finish after the revert: it is terminated first
reset
touch "$TMP/late"
del app-a false false false
t1="$(lineno 'terminate tpg-c1-app-b')"; r3="$(lineno 'sync tpg-c1-app-a|renders the shared Secrets|tracked-by=tpg-c1-app-a|selective:')"
[[ -n "$t1" && -n "$r3" && "$t1" -lt "$r3" && "$(trk)" == "tpg-c1-app-a tpg-c1-app-a tpg-c1-app-a" ]] && ! has_ev 'late operation finished' \
  && rec "result.c1.app-a|FAILED|HANDOVER_FAILED" | grep -q "SYNC_TIMEOUT" \
  && ok "hand-over revert: the successor's sync timed out (SYNC_TIMEOUT) and still runs: its operation is terminated before the old owner is synced, so it cannot finish later" \
  || bad "late timeout revert" "$(trk) $(cat "$TMP/events") $(cat "$TMP/records")"
# an operation that ends by itself within the wait is not terminated
reset
echo tpg-c1-app-b > "$TMP/op-running"
touch "$TMP/sync-fail"
del app-a false false false
has_ev 'terminate tpg-c1-app-b' && ok "hand-over revert: an operation still running when the wait is over is terminated" || bad "terminate when busy" "$(cat "$TMP/events")"
reset
touch "$TMP/sync-fail"
del app-a false false false
! has_ev 'terminate' && ok "hand-over revert: no operation running, nothing to terminate" || bad "no terminate when idle" "$(cat "$TMP/events")"
# the old owner is synced but one object stays with the successor: said clearly, per object
reset
touch "$TMP/partial" "$TMP/stuck-sa"
del app-a false false false
rec "result.c1.app-a|FAILED|HANDOVER_FAILED" | grep -q "NOT every shared object is tracked by tpg-c1-app-a (serviceaccount/tpg-vso=tpg-c1-app-b, vaultstaticsecret/regsecret=tpg-c1-app-a, vaultstaticsecret/backup-storage=tpg-c1-app-a)" \
  && ok "hand-over revert: an object that is still tracked by the successor is named in the report (per-object check)" || bad "per-object report" "$(cat "$TMP/records")"
# PUSH_MODE=pr: the revert pull request is not merged in time - the report names it and says to close it
reset
touch "$TMP/sync-fail" "$TMP/pr-timeout"
export PUSH_MODE=pr
del app-a false false false
unset PUSH_MODE
rec "result.c1.app-a|FAILED|HANDOVER_FAILED" | grep -q "pull request #42 (https://github.example/o/r/pull/42) - close it" && yq -e '.clusters.c1.instances | has("app-a")' "$TMP/fleet.yaml" >/dev/null \
  && ok "hand-over revert in PUSH_MODE=pr: the HANDOVER_FAILED detail names the revert pull request #42 and says to close it" || bad "pr revert detail" "$(cat "$TMP/records")"
# the successor has no Application: refused before anything is pushed
reset
echo tpg-c1-app-b >> "$TMP/removed"
del app-a false false false
! has_ev 'commit' && ! has_ev 'sync ' && rec "result.c1.app-a|FAILED|HANDOVER_FAILED" | grep -q "tpg-c1-app-b does not exist" && [[ "$(owners_now)" == 1 ]] \
  && [[ "$(yq '.clusters.c1.instances["app-b"].instance.sharedSecretsOwner' "$TMP/fleet.yaml")" == false ]] \
  && ok "hand-over: a successor whose Application does not exist is found before the flag commit (nothing pushed, nothing synced)" || bad "no app" "$(cat "$TMP/events") $(cat "$TMP/records")"

# the sync of the hand-over is selective: the shared objects of the successor, not its whole Application
reset
del app-a false false false
sel="$(grep -F 'sync tpg-c1-app-b|' "$TMP/events" | head -n1)"
[[ "$sel" == *'|selective::ServiceAccount:shared/tpg-vso,secrets.hashicorp.com:VaultStaticSecret:shared/regsecret,secrets.hashicorp.com:VaultStaticSecret:shared/backup-storage' \
   && "$(grep -c '^sync ' "$TMP/events")" == 1 ]] \
  && ok "hand-over: one selective sync of tpg-vso, regsecret and backup-storage (no Postgres, backup location or the rest of the Application)" || bad "selective" "$(cat "$TMP/events")"

# ---- a non-owner leaves: no hand-over
reset
del app-c false false false
[[ "$RC" -eq 0 && "$(grep -c '^commit' "$TMP/events")" == 1 ]] && has_ev 'commit rev1|delete c1/app-c' && ! has_ev 'sync ' && grep -q '^tpg-c1-app-a$' "$TMP/tracked" \
  && ok "a non-owner leaves with one commit and no sync; app-a keeps the Secrets" || bad "non-owner" "$(cat "$TMP/events") $OUT"

# ---- purgeNamespace
reset
del app-b true true true
rec "result.c1.app-b|FAILED|NAMESPACE_SHARED" | grep -q "which app-a, app-c also use(s)" && [[ ! -s "$TMP/events" ]] \
  && ok "purgeNamespace=true is refused while other instances remain in the namespace (NAMESPACE_SHARED), nothing changed" || bad "purge refused" "$(cat "$TMP/records") $(cat "$TMP/events")"
reset
del orders-db false true true
has_ev 'delete namespace pg-orders-db' && [[ "$RC" -eq 0 ]] \
  && ok "purgeNamespace=true on an instance that is alone in its namespace deletes the namespace as before" || bad "purge alone" "$(cat "$TMP/events") $OUT"
reset
del app-b false true false
has_ev 'delete pvc shared|-l postgres-instance=app-b' && ! has_ev 'delete pvc shared|--all' && grep -q 'data-app-a-0 shared' "$TMP/pvcs" && grep -q 'data-app-c-0 shared' "$TMP/pvcs" && ! grep -q 'data-app-b-0' "$TMP/pvcs" \
  && ok "purgePvcs in a shared namespace deletes only the PVCs of the instance (label postgres-instance)" || bad "pvc selector" "$(cat "$TMP/events") $(cat "$TMP/pvcs")"
# one after the other: the last one of the namespace may purge it
reset
del app-c false true false; del app-b false true false; del app-a false true true
has_ev 'delete namespace shared' && [[ "$RC" -eq 0 ]] && ! has_ev 'move the shared Secrets' \
  && ok "the last instance of the namespace can purge it (no other instance remains; nothing to hand over)" || bad "last purge" "$(cat "$TMP/events") $OUT"

# ---- tpg-delete-apps
reset app-c
apps '{"c1":["tpg-instances:app-a","tpg-instances:app-b"]}' true true
has_ev 'delete namespace shared' && [[ "$(grep -c 'delete namespace shared' "$TMP/events")" == 1 ]] \
  && [[ "$(lineno 'delete namespace shared')" -gt "$(lineno 'delete postgres shared/app-b')" && "$(lineno 'delete namespace shared')" -gt "$(lineno 'delete postgres shared/app-a')" ]] \
  && ! has_ev 'sync ' && ! has_ev 'move the shared Secrets' && [[ "$RC" -eq 0 ]] \
  && ok "delete-apps: both instances of a shared namespace are in the run: the namespace is deleted once, after the last, with no hand-over" || bad "apps shared run" "$(cat "$TMP/events") $(cat "$TMP/records") $OUT"
reset
apps '{"c1":["tpg-instances:app-a","tpg-instances:app-b"]}' true true
rec "result.c1.app-a|FAILED|NAMESPACE_SHARED" | grep -q "app-c" && [[ ! -s "$TMP/events" ]] && [[ "$RC" -ne 0 ]] \
  && ok "delete-apps: purgeNamespace on a namespace that app-c (not in the run) still uses is refused up front, nothing changed" || bad "apps refused" "$(cat "$TMP/records") $(cat "$TMP/events")"
reset
apps '{"c1":["tpg-instances:app-a","tpg-instances:app-b"]}' true false
[[ "$RC" -eq 0 ]] && ! has_ev 'delete namespace' && has_ev 'sync tpg-c1-app-c|renders the shared Secrets' \
  && ! has_ev 'sync tpg-c1-app-b' && [[ "$(grep -c 'commit rev.*move the shared Secrets' "$TMP/events")" == 1 ]] \
  && has_ev 'move the shared Secrets of c1/shared from app-a to app-c' && ! has_ev 'move the shared Secrets of c1/shared from app-b' \
  && ok "delete-apps: without purgeNamespace the owner hands over to the instance that stays (app-c) - exactly one hand-over, never to app-b, which leaves in the same run" \
  || bad "apps handover" "$(cat "$TMP/events") $OUT"
yq -e '.clusters.c1.instances | has("app-a") or has("app-b") | not' "$TMP/fleet.yaml" >/dev/null && [[ "$(owners_now)" == 1 ]] \
  && ok "delete-apps: app-a and app-b are gone from fleet.yaml, app-c is the one owner" || bad "apps handover fleet" "$(cat "$TMP/fleet.yaml")"
# the owner is the second of the run (app-b owns, app-a does not): app-a leaves without a hand-over, app-b hands over to app-c
reset
yq -i '.clusters.c1.instances["app-a"].instance.sharedSecretsOwner = false | del(.clusters.c1.instances["app-b"].instance.sharedSecretsOwner)' "$TMP/fleet.yaml"
echo tpg-c1-app-b > "$TMP/tracked"
apps '{"c1":["tpg-instances:app-a","tpg-instances:app-b"]}' true false
[[ "$RC" -eq 0 && "$(grep -c 'commit rev.*move the shared Secrets' "$TMP/events")" == 1 ]] && has_ev 'move the shared Secrets of c1/shared from app-b to app-c' \
  && ! has_ev 'sync tpg-c1-app-a' && ! has_ev 'sync tpg-c1-app-b' && grep -q '^tpg-c1-app-c$' "$TMP/tracked" \
  && ok "delete-apps: the owner is the last of the run: one hand-over, to the instance that stays" || bad "apps handover order" "$(cat "$TMP/events") $OUT"
reset
apps '{"c1":["tpg-instances","tpg-operator"]}' true true
[[ "$RC" -eq 0 ]] && [[ "$(grep -c 'delete namespace shared' "$TMP/events")" == 1 ]] \
  && [[ "$(lineno 'delete namespace shared')" -gt "$(lineno 'delete postgres shared/app-c')" && "$(lineno 'delete namespace shared')" -gt "$(lineno 'delete postgres shared/app-b')" ]] \
  && has_ev 'delete namespace pg-orders-db' && has_ev 'delete namespace tanzu-postgres-operator' && ! has_ev 'sync ' \
  && ok "delete-apps with deleteOperator removes everything: every instance first, each purged namespace once after its last instance, then the operator namespace" || bad "apps operator" "$(cat "$TMP/events") $(cat "$TMP/records") $OUT"
reset
apps '{"c1":["tpg-instances:app-a"]}' true true true
rec "result.c1.app-a|FAILED|NAMESPACE_SHARED" | grep -q . && ok "delete-apps dry run: a purge that would be refused fails in the plan as well" || bad "apps dry run" "$(cat "$TMP/records") $OUT"

# ---- the audit copy of a deleted entry is matched by exactly <instance>-<yyyymmddHHMM>.yaml (Round 23 review)
# "orders" is re-run (entry gone, Postgres still live in team-o); "orders-db" was deleted earlier from the namespace
# legacy with purgePvcs=false (its PVC kept on purpose). A prefix glob took the copy of orders-db for orders.
copy_fixture() {  # copy_fixture: the audit copies of orders (team-o) and orders-db (legacy), orders live, one PVC each
  reset
  mkdir -p "$TMP/deleted/c1"
  printf 'instance: {namespace: team-o, postgresVersion: postgres-17.6}\ndeleted: {workflow: w}\n' > "$TMP/deleted/c1/orders-202610100000.yaml"
  printf 'instance: {namespace: legacy, postgresVersion: postgres-17.6}\ndeleted: {workflow: w}\n' > "$TMP/deleted/c1/orders-db-202610100100.yaml"
  echo "orders team-o" >> "$TMP/live"
  echo "data-orders-0 team-o orders" >> "$TMP/pvcs"
  echo "data-orders-db-0 legacy orders-db" >> "$TMP/pvcs"
}
copy_fixture
del orders false true false
[[ "$RC" -eq 0 ]] && has_ev 'delete postgres team-o/orders' && has_ev 'delete pvc team-o|' && ! grep -q legacy "$TMP/events" && grep -q 'data-orders-db-0 legacy orders-db' "$TMP/pvcs" \
  && ! grep -q 'data-orders-0' "$TMP/pvcs" \
  && ok "audit copy: a re-run of orders uses its own copy (team-o); the kept PVC of orders-db in legacy is not touched" || bad "orders re-run" "$(cat "$TMP/events") $(cat "$TMP/pvcs") $OUT"
# the namespace purge of the re-run deletes team-o, never legacy
copy_fixture
del orders false true true
has_ev 'delete namespace team-o' && ! has_ev 'delete namespace legacy' && [[ "$RC" -eq 0 ]] \
  && ok "audit copy: purgeNamespace of the re-run deletes the namespace of the instance (team-o), not the one of orders-db" || bad "orders re-run purge" "$(cat "$TMP/events") $OUT"
# only the copy of another instance whose name starts like this one: the instance is unknown, nothing happens
reset
mkdir -p "$TMP/deleted/c1"
printf 'instance: {namespace: legacy, postgresVersion: postgres-17.6}\ndeleted: {workflow: w}\n' > "$TMP/deleted/c1/orders-db-202610100100.yaml"
printf 'instance: {namespace: legacy}\n' > "$TMP/deleted/c1/orders-1234.yaml"
del orders false true false
rec "result.c1.orders|FAILED|UNKNOWN_INSTANCE" | grep -q . && [[ ! -s "$TMP/events" ]] \
  && ok "audit copy: the copy of orders-db (and a file that is not <instance>-<12 digits>.yaml) is no copy of orders: UNKNOWN_INSTANCE, nothing changed" \
  || bad "prefix copy" "$(cat "$TMP/events") $(cat "$TMP/records") $OUT"
# the newest copy of the exact name wins
reset
mkdir -p "$TMP/deleted/c1"
printf 'instance: {namespace: old-ns}\n' > "$TMP/deleted/c1/orders-202601010000.yaml"
printf 'instance: {namespace: team-o}\n' > "$TMP/deleted/c1/orders-202610100000.yaml"
echo "orders team-o" >> "$TMP/live"
del orders false false false
has_ev 'delete postgres team-o/orders' && ok "audit copy: of several copies of the instance the newest decides" || bad "newest copy" "$(cat "$TMP/events") $OUT"
# the copy says team-o, a Postgres of that name lives elsewhere: refused (not the same instance)
copy_fixture
grep -vx "orders team-o" "$TMP/live" > "$TMP/live.n"; mv "$TMP/live.n" "$TMP/live"; echo "orders other-ns" >> "$TMP/live"
del orders false true true
rec "result.c1.orders|FAILED|NAMESPACE_MISMATCH" | grep -q "other-ns" && [[ ! -s "$TMP/events" ]] \
  && ok "audit copy: a live Postgres of that name in another namespace than the copy says is refused (NAMESPACE_MISMATCH), nothing deleted" || bad "mismatch" "$(cat "$TMP/events") $(cat "$TMP/records") $OUT"
# no copy, ALLOW_UNTRACKED: the one live Postgres of that name decides; two of them are ambiguous, never pg-<instance>
reset
echo "ghost team-g" >> "$TMP/live"
ALLOW_UNTRACKED=true del ghost false false false
has_ev 'delete postgres team-g/ghost' && ok "no entry, no copy (ALLOW_UNTRACKED): the namespace of the one live Postgres of that name" || bad "live lookup" "$(cat "$TMP/events") $OUT"
reset
printf 'ghost team-g\nghost team-h\n' >> "$TMP/live"
ALLOW_UNTRACKED=true del ghost false false false
rec "result.c1.ghost|FAILED|NAMESPACE_AMBIGUOUS" | grep -q "team-g,team-h" && [[ ! -s "$TMP/events" ]] \
  && ok "no entry, no copy, two live Postgres of that name: NAMESPACE_AMBIGUOUS (no pg-<instance> guess), nothing deleted" || bad "ambiguous" "$(cat "$TMP/events") $(cat "$TMP/records") $OUT"
# with a copy the ambiguity is settled by the copy's namespace
reset
mkdir -p "$TMP/deleted/c1"; printf 'instance: {namespace: team-h}\n' > "$TMP/deleted/c1/ghost-202610100000.yaml"
printf 'ghost team-g\nghost team-h\n' >> "$TMP/live"
ALLOW_UNTRACKED=true del ghost false false false
has_ev 'delete postgres team-h/ghost' && ! has_ev 'team-g' && ok "two live Postgres of that name: the audit copy picks its own namespace" || bad "ambiguous copy" "$(cat "$TMP/events") $OUT"
# deleted_copy itself
rm -rf "$TMP/dc"; mkdir -p "$TMP/dc/clusters/deleted/c1"
: > "$TMP/dc/clusters/deleted/c1/orders-db-202610100100.yaml"; : > "$TMP/dc/clusters/deleted/c1/orders-1.yaml"; : > "$TMP/dc/clusters/deleted/c1/orders-202610100000.yaml.bak"
dcp() { bash -c "source '$ROOT/workflows/scripts/lib.sh'; deleted_copy '$TMP/dc' c1 $1 || echo none" 2>/dev/null; }
[[ "$(dcp orders)" == none && "$(dcp orders-db)" == "$TMP/dc/clusters/deleted/c1/orders-db-202610100100.yaml" && "$(dcp order)" == none ]] \
  && ok "deleted_copy: orders-db-<stamp> is no copy of orders; orders-1.yaml and *.yaml.bak are no copies at all" || bad "deleted_copy" "$(dcp orders) $(dcp orders-db)"
: > "$TMP/dc/clusters/deleted/c1/orders-202610100000.yaml"; : > "$TMP/dc/clusters/deleted/c1/orders-202701010000.yaml"
[[ "$(dcp orders)" == "$TMP/dc/clusters/deleted/c1/orders-202701010000.yaml" ]] && ok "deleted_copy: the newest stamp of the instance" || bad "deleted_copy newest" "$(dcp orders)"

# ---- tpg-delete-apps: purgeNamespace with a clusterMap (Round 23 review)
# one instance of a shared namespace purges it, another one of the run says false (its PVCs are meant to stay)
cm_ns() {  # cm_ns A_PURGE B_PURGE [OPERATOR] -> clusterMap JSON for app-a and app-b (both purgePvcs true)
  jq -cn --arg a "$1" --arg b "$2" --arg op "${3:-false}" '{c1: {deleteOperator: $op, instances: {
    "app-a": {finalBackup: "false", purgePvcs: "true", purgeNamespace: $a},
    "app-b": {finalBackup: "false", purgePvcs: ($b | if . == "keep" then "false" else "true" end), purgeNamespace: ($b | if . == "keep" then "false" else . end)}}}}'
}
reset app-c
appsmap "$(cm_ns true false)"
rec "result.c1.app-a|FAILED|NAMESPACE_SHARED" | grep -q "app-b" && [[ ! -s "$TMP/events" && "$RC" -ne 0 ]] \
  && ok "delete-apps: purgeNamespace=true for app-a while app-b (same run, same namespace) says false: refused up front, NAMESPACE_SHARED names app-b, nothing deleted" \
  || bad "mixed purge" "$(cat "$TMP/events") $(cat "$TMP/records") $OUT"
reset app-c
appsmap "$(cm_ns true false true)"
rec "result.c1.app-a|FAILED|NAMESPACE_SHARED" | grep -q "app-b" && [[ ! -s "$TMP/events" ]] \
  && ok "delete-apps: the same with deleteOperator (everything goes, but not the PVCs app-b keeps): refused" || bad "mixed purge operator" "$(cat "$TMP/events") $(cat "$TMP/records") $OUT"
reset app-c
appsmap "$(cm_ns true true)"
[[ "$RC" -eq 0 && "$(grep -c 'delete namespace shared' "$TMP/events")" == 1 ]] \
  && [[ "$(lineno 'delete namespace shared')" -gt "$(lineno 'delete postgres shared/app-b')" && "$(lineno 'delete namespace shared')" -gt "$(lineno 'delete postgres shared/app-a')" ]] \
  && ok "delete-apps: every instance of the namespace in the run purges it: the namespace is deleted once, after the last" || bad "all purge" "$(cat "$TMP/events") $(cat "$TMP/records") $OUT"
reset app-c
appsmap "$(cm_ns false false)"
[[ "$RC" -eq 0 ]] && ! has_ev 'delete namespace' && ok "delete-apps: nobody purges: the namespace stays" || bad "none purge" "$(cat "$TMP/events") $OUT"
reset app-c
appsmap "$(cm_ns false true)"
rec "result.c1.app-b|FAILED|NAMESPACE_SHARED" | grep -q "app-a" && [[ ! -s "$TMP/events" ]] \
  && ok "delete-apps: the instance that purges is the second one: refused as well, naming app-a" || bad "second purges" "$(cat "$TMP/events") $(cat "$TMP/records") $OUT"

# ---- tpg-delete-apps: a live instance whose entry is gone (Round 23 review)
# orders: entry gone, audit copy says team-o, the Postgres is live there: it is one of ours (before: expected pg-orders, skipped silently)
copy_fixture
yq -i 'del(.clusters.c1.instances["app-c"])' "$TMP/fleet.yaml"
apps '{"c1":["tpg-instances"]}' true false
has_ev 'delete postgres team-o/orders' && ! grep -q legacy "$TMP/events" \
  && ok "delete-apps: a live instance whose entry is gone is found in the namespace of its audit copy (team-o) and deleted" || bad "gone live" "$(cat "$TMP/events") $(cat "$TMP/records") $OUT"
# ghost: live in team-g, no entry, no copy: not ours, left alone with a message in the report
reset
echo "ghost team-g" >> "$TMP/live"
apps '{"c1":["tpg-instances"]}' true false
! has_ev 'team-g' && rec "warning.c1.team-g.ghost|WARNING|POSTGRES_SKIPPED" | grep -q "team-g/ghost is not in the namespace its fleet.yaml entry or audit copy gives (pg-ghost)" \
  && ok "delete-apps: a Postgres outside the namespace of its entry or copy is skipped with a report line (POSTGRES_SKIPPED), not silently" || bad "ghost skipped" "$(cat "$TMP/events") $(cat "$TMP/records") $OUT"
# the hint is by case: tpg-instances:<name> reaches a Postgres only when no entry and no audit copy names another namespace
# and the name runs in one namespace. Otherwise it must be deleted by hand, in the namespace the message names
reset
echo "orders-db other-ns" >> "$TMP/live"
apps '{"c1":["tpg-instances"]}' true false
w="$(rec 'warning.c1.other-ns.orders-db|WARNING|POSTGRES_SKIPPED')"
[[ "$w" == *"the entry in clusters/fleet.yaml says pg-orders-db, so tpg-instances:orders-db cannot reach it: delete it by hand in namespace other-ns"* && "$w" != *"select it with"* ]] && has_ev 'delete postgres pg-orders-db/orders-db' && ! has_ev 'other-ns' \
  && ok "delete-apps: a Postgres outside the namespace its entry gives: POSTGRES_SKIPPED says the selection cannot reach it and to delete it by hand in other-ns" || bad "skipped entry hint" "$w $(cat "$TMP/events")"
copy_fixture
grep -vx "orders team-o" "$TMP/live" > "$TMP/live.n"; mv "$TMP/live.n" "$TMP/live"; echo "orders other-ns" >> "$TMP/live"
apps '{"c1":["tpg-instances"]}' true false
w="$(rec 'warning.c1.other-ns.orders|WARNING|POSTGRES_SKIPPED')"
[[ "$w" == *"the audit copy in clusters/deleted/c1 says team-o, so tpg-instances:orders cannot reach it (NAMESPACE_MISMATCH): delete it by hand in namespace other-ns"* && "$w" != *"select it with"* ]] && ! has_ev 'other-ns' \
  && ok "delete-apps: the audit copy names another namespace: the hint says by hand in other-ns, not the selection" || bad "skipped copy hint" "$w $(cat "$TMP/events")"
reset
printf 'ghost team-g\nghost team-h\n' >> "$TMP/live"
apps '{"c1":["tpg-instances"]}' true false
w="$(rec 'warning.c1.team-g.ghost|WARNING|POSTGRES_SKIPPED')"
[[ "$w" == *"ghost runs in team-g, team-h, so tpg-instances:ghost refuses it (NAMESPACE_AMBIGUOUS): delete it by hand in namespace team-g"* && "$w" != *"select it with"* ]] \
  && ok "delete-apps: the same name in two namespaces and no record: the hint says the selection is ambiguous and to delete it by hand" || bad "skipped ambiguous hint" "$w"
# and the explicit selection deletes it (ALLOW_UNTRACKED: the one live Postgres of that name)
reset
echo "ghost team-g" >> "$TMP/live"
apps '{"c1":["tpg-instances:ghost"]}' true false
has_ev 'delete postgres team-g/ghost' && ok "delete-apps: tpg-instances:ghost deletes it, in the namespace the live lookup finds" || bad "ghost selected" "$(cat "$TMP/events") $(cat "$TMP/records") $OUT"

# ---- the namespace the delete resolved is the one every helper uses (Round 23 re-review)
# orders: entry gone (a re-run), audit copy says team-o, the Postgres is live there. busy_operations, pg_state and
# backup-instance.sh used to call instance_ns again, which gives pg-orders for an entry that is not in the checkout:
# finalBackup=required failed with currentState=, finalBackup=true deleted without a backup
copy_fixture
del orders true false false
a="$(lineno 'apply team-o|PostgresBackup')"; d="$(lineno 'delete postgres team-o/orders')"
[[ "$RC" -eq 0 && -n "$a" && -n "$d" && "$a" -lt "$d" ]] && ! grep -q 'pg-orders' "$TMP/events" && rec "result.c1.orders|SUCCEEDED" | grep -q 'final backup orders-full-' \
  && ok "re-run in a custom namespace, finalBackup=true: the final backup is taken in team-o and the Postgres is deleted only after it" || bad "re-run backup true" "$(cat "$TMP/events") $(cat "$TMP/records") $OUT"
copy_fixture
del orders required false false
a="$(lineno 'apply team-o|PostgresBackup')"; d="$(lineno 'delete postgres team-o/orders')"
[[ "$RC" -eq 0 && -n "$a" && -n "$d" && "$a" -lt "$d" ]] && ! rec "result.c1.orders|FAILED" | grep -q . \
  && ok "re-run in a custom namespace, finalBackup=required: the Postgres is Running in team-o, the backup is taken there (no FINAL_BACKUP_IMPOSSIBLE)" || bad "re-run backup required" "$(cat "$TMP/events") $(cat "$TMP/records") $OUT"
# a backup, restore or upgrade running in team-o blocks the delete (busy_operations looked at pg-orders)
copy_fixture
echo "team-o postgresrestore" > "$TMP/busyops"
del orders true false false
rec "result.c1.orders|FAILED|OPERATION_IN_PROGRESS" | grep -q 'postgresrestore' && [[ ! -s "$TMP/events" ]] \
  && ok "re-run in a custom namespace: an unfinished operation in team-o blocks the delete (OPERATION_IN_PROGRESS), nothing changed" || bad "re-run busy" "$(cat "$TMP/events") $(cat "$TMP/records") $OUT"
# the live lookup (no entry, no copy, ALLOW_UNTRACKED) is used by the helpers as well
reset
echo "ghost team-g" >> "$TMP/live"
ALLOW_UNTRACKED=true del ghost required false false
a="$(lineno 'apply team-g|PostgresBackup')"; d="$(lineno 'delete postgres team-g/ghost')"
[[ "$RC" -eq 0 && -n "$a" && -n "$d" && "$a" -lt "$d" ]] \
  && ok "untracked Postgres in team-g (finalBackup=required): backed up in team-g, then deleted" || bad "untracked required" "$(cat "$TMP/events") $(cat "$TMP/records") $OUT"
# tpg-delete-apps: the untracked ghost outside pg-<instance> with the default finalBackup (P_FINAL_BACKUP unset: true)
reset
echo "ghost team-g" >> "$TMP/live"
RC=0; OUT="$(P_APPS='{"c1":["tpg-instances:ghost"]}' P_DRY_RUN=false P_PURGE_PVCS=false P_PURGE_NS=false P_FORCE=false P_TIMEOUT=600 bash "$TMP/delete-apps.sh" wf c1 2>&1)" || RC=$?
a="$(lineno 'apply team-g|PostgresBackup')"; d="$(lineno 'delete postgres team-g/ghost')"
[[ "$RC" -eq 0 && -n "$a" && -n "$d" && "$a" -lt "$d" ]] && ! grep -q 'pg-ghost' "$TMP/events" \
  && ok "delete-apps: an untracked Postgres in a custom namespace with the default finalBackup is backed up in that namespace before it is deleted" || bad "apps ghost backup" "$(cat "$TMP/events") $(cat "$TMP/records") $OUT"
# an entry that is there: the same helpers, the namespace of the entry (unchanged)
reset
del app-b true false false
a="$(lineno 'apply shared|PostgresBackup')"; d="$(lineno 'delete postgres shared/app-b')"
[[ "$RC" -eq 0 && -n "$a" && -n "$d" && "$a" -lt "$d" ]] \
  && ok "an instance with an entry (namespace shared): the final backup is taken in shared, as before" || bad "entry backup" "$(cat "$TMP/events") $(cat "$TMP/records") $OUT"
# instance_ns honours the per-instance override first, and only for that cluster/instance
reset
rm -rf "$TMP/ov-repo"; mkdir -p "$TMP/ov-repo/clusters"; cp "$TMP/fleet.yaml" "$TMP/ov-repo/clusters/fleet.yaml"
ov="$(bash -c "
  export TPG_WORK='$TMP/ov-work'
  source '$ROOT/workflows/scripts/lib.sh'
  INSTANCE_NS_REPO='$TMP/ov-repo'
  instance_ns_override c1 orders team-o
  echo \"\$(instance_ns c1 orders)|\$(instance_ns c1 orders-db)|\$(instance_ns c2 orders)\"" 2>/dev/null)"
[[ "$ov" == "team-o|pg-orders-db|pg-orders" ]] && ok "instance_ns_override: honoured first for that cluster/instance only (others unchanged)" || bad "override" "$ov"

# ---- the namespace of an instance: a checkout, the run inventory, a clone (Round 23 review)
# instance_ns reads, in this order: a checkout the step has, the inventory, a clone; nothing readable: rc 1, no pg-<instance> guess
chain() {  # chain SETUP_SNIPPET INSTANCE -> prints "<ns>|rc=<n>|clones=<n>" of instance_ns c1 INSTANCE in a fresh step with a working clone
  rm -rf "$TMP/chain"; mkdir -p "$TMP/chain"; : > "$TMP/chain/clones"
  bash -c "
    export TPG_WORK='$TMP/chain/work'
    source '$ROOT/workflows/scripts/lib.sh'
    set +e
    git_clone() { echo clone >> '$TMP/chain/clones'; rm -rf \"\$1\"; mkdir -p \"\$1\"; cp -r '$REPO/.' \"\$1/\"; cp '$TMP/fleet.yaml' \"\$1/clusters/fleet.yaml\"; }
    run_data() { return 1; }
    $1
    ns=\"\$(instance_ns c1 $2)\"; rc=\$?
    echo \"\${ns}|rc=\${rc}|clones=\$(wc -l < '$TMP/chain/clones' | tr -d ' ')\"" 2>/dev/null
}
reset
yq -i '.clusters.c1.instances["app-a"].instance.namespace = "team-x" | del(.clusters.c1.instances["orders-db"].instance.namespace)' "$TMP/fleet.yaml"
mkdir -p "$TMP/chain-repo"; rm -rf "$TMP/chain-repo"; mkdir -p "$TMP/chain-repo/clusters"; cp "$TMP/fleet.yaml" "$TMP/chain-repo/clusters/fleet.yaml"
[[ "$(chain "INSTANCE_NS_REPO='$TMP/chain-repo'" app-a)" == "team-x|rc=0|clones=0" ]] && ok "instance_ns: a checkout the step has: the namespace of the entry, no clone" || bad "chain checkout" "$(chain "INSTANCE_NS_REPO='$TMP/chain-repo'" app-a)"
[[ "$(chain "INSTANCE_NS_REPO='$TMP/chain-repo'" orders-db)" == "pg-orders-db|rc=0|clones=0" ]] && ok "instance_ns: a checkout was read and the entry has no namespace: pg-<instance>" || bad "chain default" "$(chain "INSTANCE_NS_REPO='$TMP/chain-repo'" orders-db)"
[[ "$(chain "INSTANCE_NS_REPO='$TMP/chain-repo'" not-declared)" == "pg-not-declared|rc=0|clones=0" ]] && ok "instance_ns: a checkout was read and the instance is not declared in it: pg-<instance>" || bad "chain undeclared" "$(chain "INSTANCE_NS_REPO='$TMP/chain-repo'" not-declared)"
chain_inv() {  # chain_inv INSTANCE: with the inventory file in place
  rm -rf "$TMP/chain"; mkdir -p "$TMP/chain"; : > "$TMP/chain/clones"
  printf '[{"name":"c1","instances":[{"name":"app-a","namespace":"from-inventory"}]}]' > "$TMP/chain/inventory.json"
  bash -c "
    export TPG_WORK='$TMP/chain/work'
    source '$ROOT/workflows/scripts/lib.sh'
    set +e
    git_clone() { echo clone >> '$TMP/chain/clones'; return 128; }
    run_data() { [[ \"\$1\" == inventory ]] && cat '$TMP/chain/inventory.json'; return 0; }
    ns=\"\$(instance_ns c1 $1)\"; rc=\$?
    echo \"\${ns}|rc=\${rc}|clones=\$(wc -l < '$TMP/chain/clones' | tr -d ' ')\"" 2>/dev/null
}
[[ "$(chain_inv app-a)" == "from-inventory|rc=0|clones=0" ]] && ok "instance_ns: no checkout, the instance is in the run inventory: its namespace, no clone" || bad "chain inventory" "$(chain_inv app-a)"
[[ "$(chain_inv app-zz)" == "|rc=1|clones=1" ]] && ok "instance_ns: the instance is not in the inventory and the clone fails: no output, rc 1 (FLEET_UNREADABLE for the caller), never pg-<instance>" || bad "chain inventory miss" "$(chain_inv app-zz)"
[[ "$(chain "true" app-a)" == "team-x|rc=0|clones=1" ]] && ok "instance_ns: no checkout and no inventory: one clone is made and read" || bad "chain clone" "$(chain "true" app-a)"
[[ "$(chain "true" orders-db)" == "pg-orders-db|rc=0|clones=1" ]] && ok "instance_ns: a clone was read and the entry has no namespace: pg-<instance>" || bad "chain clone default" "$(chain "true" orders-db)"
chain_fail() {
  rm -rf "$TMP/chain"; mkdir -p "$TMP/chain"; : > "$TMP/chain/clones"
  bash -c "
    export TPG_WORK='$TMP/chain/work'
    source '$ROOT/workflows/scripts/lib.sh'
    set +e
    git_clone() { echo clone >> '$TMP/chain/clones'; echo 'clone failed (Vault down)' >&2; return 128; }
    run_data() { return 1; }
    ns=\"\$(instance_ns c1 orders)\"; rc=\$?
    echo \"\${ns}|rc=\${rc}|clones=\$(wc -l < '$TMP/chain/clones' | tr -d ' ')\"" 2>/dev/null
}
[[ "$(chain_fail)" == "|rc=1|clones=1" ]] && ok "instance_ns: no checkout, no inventory, the clone fails (the review's probe): nothing printed, rc 1 - not pg-orders" || bad "chain failure" "$(chain_fail)"
# the callers stop with FLEET_UNREADABLE
RC=0; OUT="$(bash -c "
  export TPG_WORK='$TMP/chain/work2'
  record() { printf '%s|%s|%s|%s\n' \"\$1\" \"\$2\" \"\${3:-}\" \"\${4:-}\"; RESULT_RECORDED=1; }
  source '$ROOT/workflows/scripts/lib.sh'
  git_clone() { return 128; }; run_data() { return 1; }
  use_cluster() { CLUSTER=\"\$1\"; }
  rc=0; sync_instance_app c1 orders 60 abc || rc=\$?; echo \"rc=\$rc reason=\$SYNC_FAIL_REASON\"
  [[ -z \"\$(pg_state orders)\" ]] && echo pg_state-empty
  [[ -n \"\$(busy_operations orders)\" ]] && echo busy" 2>/dev/null)" || RC=$?
grep -q 'rc=4 reason=FLEET_UNREADABLE' <<<"$OUT" && grep -q pg_state-empty <<<"$OUT" && grep -q '^busy$' <<<"$OUT" \
  && ok "lib callers: sync_instance_app fails with FLEET_UNREADABLE, pg_state reads nothing, busy_operations reports busy - no kubectl runs against a guessed namespace" || bad "lib callers" "$OUT"
# backup-instance.sh records FLEET_UNREADABLE and exits 0 (one instance never blocks the others)
sed -e "s#source /scripts/lib.sh#source $TMP/prelude-unreadable.sh#" "$ROOT/workflows/scripts/backup-instance.sh" > "$TMP/backup-instance.sh"
cat > "$TMP/prelude-unreadable.sh" <<PRELUDE
export TPG_WORK="$TMP/work-unreadable"
source "$ROOT/workflows/scripts/lib.sh"
set +e
record() { printf '%s|%s|%s|%s\n' "\$1" "\$2" "\${3:-}" "\${4:-}" >> "$TMP/records"; RESULT_RECORDED=1; }
git_clone() { return 128; }
run_data() { return 1; }
tk() { echo "tk must not run: \$*" >> "$TMP/events"; return 0; }
PRELUDE
reset
RC=0; OUT="$(bash "$TMP/backup-instance.sh" wf c1 orders full 600 2>&1)" || RC=$?
rec "result.c1.orders|FAILED|FLEET_UNREADABLE" | grep -q . && [[ "$RC" -eq 0 && ! -s "$TMP/events" ]] \
  && ok "backup-instance.sh: an unreadable fleet repository is FAILED FLEET_UNREADABLE (exit 0), nothing runs on the cluster" || bad "backup unreadable" "$(cat "$TMP/records" "$TMP/events") $OUT"

# ---- inventory_instances: the owner of the shared Secrets first, only where the sync asks for it
inv_order() {  # inv_order [owners-first] -> the instances of c1 in the order inventory_instances gives
  bash -c "
    export TPG_WORK='$TMP/chain/work3'
    source '$ROOT/workflows/scripts/lib.sh'
    run_data() { echo '[{\"name\":\"c1\",\"instances\":[{\"name\":\"app-b\",\"secretsOwner\":false},{\"name\":\"orders-db\",\"secretsOwner\":true},{\"name\":\"app-c\",\"secretsOwner\":false},{\"name\":\"app-a\",\"secretsOwner\":true}]}]'; }
    inventory_instances c1 ${1:-} | paste -sd' '" 2>/dev/null
}
[[ "$(inv_order)" == "app-b orders-db app-c app-a" ]] && ok "inventory_instances: the inventory order is kept (upgrades and the pre-check)" || bad "inventory order" "$(inv_order)"
[[ "$(inv_order owners-first)" == "orders-db app-a app-b app-c" ]] \
  && ok "inventory_instances owners-first (the sync): the owners first, each group in the inventory order" || bad "owners first" "$(inv_order owners-first)"
grep -q 'inventory_instances "\$C" owners-first' "$ROOT/workflows/scripts/day0-deploy.sh" \
  && ! grep -nE 'inventory_instances "\$C" owners-first' "$ROOT/workflows/scripts/operator-upgrade.sh" "$ROOT/workflows/scripts/postgres-upgrade.sh" "$ROOT/workflows/scripts/day0-precheck.sh" | grep -q . \
  && ok "only day0-deploy.sh asks for the owners first; operator-upgrade, postgres-upgrade and the pre-check keep the inventory order" || bad "callers of owners-first"

# ---- fleet_ns_members / fleet_ns_owners read the fleet file once, whatever the number of instances
reset
nsy="$TMP/ns-many.yaml"; { echo "clusters:"; echo "  c1:"; echo "    instances:"; for n in $(seq 1 60); do echo "      i$n: {instance: {namespace: ns$((n % 3)), sharedSecretsOwner: $([[ $((n % 20)) -eq 0 ]] && echo true || echo false), postgresVersion: postgres-17.6}}"; done; } > "$nsy"
mkdir -p "$TMP/many/clusters"; cp "$nsy" "$TMP/many/clusters/fleet.yaml"
t0=$SECONDS
out="$(bash -c "source '$ROOT/workflows/scripts/lib.sh'; fleet_ns_owners '$TMP/many' c1 ns0 | paste -sd,; fleet_ns_members '$TMP/many' c1 ns1 | wc -l | tr -d ' '" 2>/dev/null)"
[[ "$out" == "i60,20"* || "$out" == $'i60\n20' ]] && (( SECONDS - t0 <= 5 )) \
  && ok "fleet_ns_owners / fleet_ns_members: 60 instances in one pass (the owners of ns0 and the members of ns1 as the entries say)" || bad "ns many" "$out in $((SECONDS - t0))s"

# an empty instance.namespace counts as absent (pg-<instance>), in fleet_ns_table as in instance_ns_in
mkdir -p "$TMP/empty-ns/clusters"
cat > "$TMP/empty-ns/clusters/fleet.yaml" <<'YAML'
clusters:
  c1:
    instances:
      e1: {instance: {namespace: "", postgresVersion: postgres-17.6}}
      e2: {instance: {postgresVersion: postgres-17.6}}
      e3: {instance: {namespace: team-e, postgresVersion: postgres-17.6}}
YAML
out="$(bash -c "source '$ROOT/workflows/scripts/lib.sh'; fleet_ns_table '$TMP/empty-ns' c1 | cut -f1,2 | paste -sd' '; fleet_ns_members '$TMP/empty-ns' c1 pg-e1; instance_ns_in '$TMP/empty-ns' c1 e1" 2>/dev/null | paste -sd'|')"
[[ "$out" == "e1	pg-e1 e2	pg-e2 e3	team-e|e1|pg-e1" ]] \
  && ok "fleet_ns_table: instance.namespace \"\" is absent (pg-<instance>), the same as instance_ns_in says" || bad "empty namespace" "$out"

# ---- tpg-day0 / tpg-create-instance: a non-owner syncs only when the shared Secrets exist (Round 23 review)
cat > "$TMP/prelude-day0.sh" <<PRELUDE
source "$TMP/prelude.sh"
use_cluster() { CLUSTER="\$1"; }
record_status() { :; }
record_entry() { printf '%s|%s|%s|%s\n' "\$1" "\$2" "\${3:-}" "\${4:-}" >> "$TMP/records"; }
operator_wait_ready() { return 0; }
azure_backup_supported() { return 0; }
fleet_head() { echo rev0; }
sync_instance_app() { ev "sync_instance_app \$2"; return 0; }
pg_wait_ready() { return 0; }
exposure_follow() { EXPOSURE_DETAIL=ClusterIP; return 0; }
secret_present() { return 0; }
app_exists() { [[ " \$(cat "$TMP/removed" 2>/dev/null | tr '\n' ' ') " != *" \$1 "* ]]; }
tk() {
  case "\$*" in
    *" get secret "*)   # -n NS get secret NAME: the Secrets in \$TMP/secrets as "ns/name" lines
      grep -qx "\$2/\$5" "$TMP/secrets" ;;
    *"get postgres "*) printf 'stanza-x' ;;
    *) return 0 ;;
  esac
}
PRELUDE
sed -e "s#source /scripts/lib.sh#source $TMP/prelude-day0.sh#" "$ROOT/workflows/scripts/day0-deploy.sh" > "$TMP/day0-deploy.sh"
deploy() {  # deploy INSTANCES_JSON: day0-deploy.sh for c1 (tpg-create-instance scope) with this inventory
  mkdir -p "$TMP/work"
  jq -cn --argjson i "$1" '[{name: "c1", instances: $i}]' > "$TMP/inventory-day0.json"
  RC=0; OUT="$(DEPLOY_SCOPE=instances bash -c "run_data() { cat '$TMP/inventory-day0.json'; }; export -f run_data; exec bash '$TMP/day0-deploy.sh' wf c1 600" 2>&1)" || RC=$?
}
INV_B='[{"name":"app-b","namespace":"shared","secretsOwner":false,"postgresVersion":"postgres-17.6"}]'
# the inventory comes from run_data: the day0 prelude reads the file
sed -i "s#^record_status() { :; }#record_status() { :; }\nrun_data() { cat \"$TMP/inventory-day0.json\"; }#" "$TMP/prelude-day0.sh"
reset
: > "$TMP/secrets"   # the namespace has no regsecret / backup-storage yet
deploy "$INV_B"
c_sel="$(lineno 'sync tpg-c1-app-a|renders the shared Secrets|tracked-by=tpg-c1-app-a|selective:')"; c_app="$(lineno 'sync_instance_app app-b')"
[[ -n "$c_sel" && -n "$c_app" && "$c_sel" -lt "$c_app" ]] \
  && ok "day0-deploy: a non-owner with no shared Secrets in its namespace: the owner's shared objects are synced first (selective), then the instance" || bad "non-owner syncs owner first" "$(cat "$TMP/events") $(cat "$TMP/records") $OUT"
reset
printf 'shared/regsecret\nshared/backup-storage\n' > "$TMP/secrets"
deploy "$INV_B"
! has_ev 'sync tpg-c1-app-a' && has_ev 'sync_instance_app app-b' \
  && ok "day0-deploy: the shared Secrets exist: the non-owner syncs at once, no sync of the owner" || bad "secrets there" "$(cat "$TMP/events") $OUT"
reset
: > "$TMP/secrets"; echo tpg-c1-app-a >> "$TMP/removed"
deploy "$INV_B"
rec "result.c1|FAILED|SHARED_SECRETS_MISSING" | grep -q "tpg-c1-app-a, the instance that owns the shared Secrets there, has no Argo CD Application" && ! has_ev 'sync_instance_app' \
  && ok "day0-deploy: the owner has no Application: SHARED_SECRETS_MISSING names it, the instance is not synced" || bad "owner no app" "$(cat "$TMP/events") $(cat "$TMP/records") $OUT"
reset
yq -i '.clusters.c1.instances["app-a"].instance.sharedSecretsOwner = false' "$TMP/fleet.yaml"
: > "$TMP/secrets"
deploy "$INV_B"
rec "result.c1|FAILED|SHARED_SECRETS_MISSING" | grep -q "no other instance of the namespace does" && ! has_ev 'sync_instance_app' \
  && ok "day0-deploy: no instance of the namespace owns the shared Secrets: SHARED_SECRETS_MISSING says so" || bad "no owner" "$(cat "$TMP/events") $(cat "$TMP/records") $OUT"
reset
INV_AB='[{"name":"app-b","namespace":"shared","secretsOwner":false,"postgresVersion":"postgres-17.6"},{"name":"app-a","namespace":"shared","secretsOwner":true,"postgresVersion":"postgres-17.6"}]'
printf 'shared/regsecret\nshared/backup-storage\n' > "$TMP/secrets"
deploy "$INV_AB"
[[ "$(grep -F 'sync_instance_app' "$TMP/events" | paste -sd' ')" == "sync_instance_app app-a sync_instance_app app-b" ]] \
  && ok "day0-deploy: the owner of the namespace is synced before the instance that shares it (inventory order b, a)" || bad "owner first in deploy" "$(cat "$TMP/events") $OUT"


# ---- purgeBackups (Round 23, locked decision 4): expire every backup while the instance runs, then delete the blobs
delp() {  # delp INSTANCE PURGE_BACKUPS [FINAL_BACKUP] -> tpg-delete-instance; output in $OUT, status in $RC
  RC=0; OUT="$(bash "$TMP/delete-instance.sh" wf c1 "$1" "$1" "${3:-false}" false false 600 "$2" 2>&1)" || RC=$?
}
blobs_left() { grep -c "^$1" "$TMP/blobs" || true; }
orders_prefix='pg-backups-c1/pg-orders-db/orders-db/'
reset
delp orders-db true
e1="$(lineno 'expire orders-incr-1a')"; e2="$(lineno 'expire orders-full-1')"; e3="$(lineno 'expire orders-full-2')"
d1="$(lineno 'delete postgres pg-orders-db/orders-db')"; d2="$(lineno 'delete postgresbackuplocation pg-orders-db/orders-db-backup-location')"; b1="$(lineno 'blob DELETE')"
[[ "$RC" -eq 0 && -n "$e1" && -n "$e2" && -n "$e3" && -n "$d1" && -n "$d2" && -n "$b1" ]] \
  && [[ "$e3" -lt "$e1" && "$e1" -lt "$e2" && "$e2" -lt "$d1" && "$d1" -lt "$d2" && "$d2" -lt "$b1" ]] \
  && ok "purgeBackups: every backup is expired first (newest first, incremental before its full), then the Postgres and the location are deleted, then the blobs" \
  || bad "purge order" "$(cat "$TMP/events") $OUT"
! has_ev 'expire orders-failed' && ! has_ev 'expire app-a-full-1' \
  && ok "purgeBackups: a backup without a pgBackRest label and the backups of other instances are not expired" || bad "expire scope" "$(cat "$TMP/events")"
[[ "$(blobs_left "$orders_prefix")" == 0 && "$(blobs_left 'pg-backups-c1/pg-orders-db/orders-db-2/')" == 2 && "$(blobs_left 'pg-backups-c1/shared/app-a/')" == 1 \
   && "$(blobs_left 'pg-backups-c1/pg-orders-dbx/')" == 1 && "$(blobs_left 'pg-backups-c2/')" == 1 ]] \
  && ok "purgeBackups: every blob under container/repoPath is gone; orders-db-2 (same text prefix), another instance, a sibling folder and another container stay" \
  || bad "blobs left" "$(cat "$TMP/blobs")"
[[ "$(grep -c '^blob LIST pg-backups-c1 prefix=pg-orders-db/orders-db/ marker= ' "$TMP/events")" == 2 && "$(grep -c '^blob LIST pg-backups-c1 prefix=pg-orders-db/orders-db/ marker=[^ ]' "$TMP/events")" == 2 ]] \
  && ok "blob listing pages with NextMarker (3 names a page: the first listing, two marker pages, then the check listing)" || bad "paging" "$(grep '^blob LIST' "$TMP/events")"
grep -q '^blob LIST .* -> 0$' "$TMP/events" && [[ "$(grep '^blob LIST' "$TMP/events" | tail -n1)" == *'-> 0' ]] \
  && ok "the prefix is listed again at the end and found empty" || bad "check listing" "$(grep '^blob LIST' "$TMP/events")"
! grep -q 'bad signature' "$TMP/events" \
  && ok "every List Blobs and Delete Blob request carries a valid SharedKey signature (checked by the fake account against the documented string to sign)" || bad "signature" "$(cat "$TMP/events")"
rec "result.c1.orders-db|SUCCEEDED" | grep -q "3 backups expired, 1 without a pgBackRest label skipped" && rec "result.c1.orders-db|SUCCEEDED" | grep -q "7 blobs deleted under pg-backups-c1/pg-orders-db/orders-db" \
  && ! rec "result.c1.orders-db|SUCCEEDED" | grep -q "backup repository kept" \
  && ok "purgeBackups: the result says what was expired and how many blobs were deleted where" || bad "purge result" "$(cat "$TMP/records")"
ls "$TMP"/deleted/c1/orders-db-*.yaml >/dev/null 2>&1 && [[ "$(yq '.deleted.backupLocation.container' "$TMP"/deleted/c1/orders-db-*.yaml)" == pg-backups-c1 \
   && "$(yq '.deleted.backupLocation.repoPath' "$TMP"/deleted/c1/orders-db-*.yaml)" == /pg-orders-db/orders-db ]] \
  && ok "the audit copy records the container and repoPath of the backup location (a re-run finds them after the object is gone)" || bad "audit location" "$(cat "$TMP"/deleted/c1/*.yaml)"
# the storage key: not in any log, record, event, file of the run, nor in the output
if grep -rqF -- "$STORAGE_KEY" "$TMP" 2>/dev/null || grep -qF -- "$STORAGE_KEY" <<<"$OUT"; then
  bad "the storage key appears in the output, a record, an event or a file" "$(grep -rlF -- "$STORAGE_KEY" "$TMP" | head)"
else
  ok "the storage key is in no log line, record, event or file of the run (it lives in the Vault Agent file and the fake server's key file, both outside the work area)"
fi

# the key never reaches an argument of a program: the stubbed curl sees URL and header names only
reset
delp orders-db true
if grep -qF -- "$STORAGE_KEY" "$TMP/events"; then bad "key in curl events"; else ok "purgeBackups: the Authorization header goes to curl on stdin, the key is in no curl argument"; fi

# ---- a repoPath another PostgresBackupLocation uses: expire only, blobs kept, reported
reset
echo c2 >> "$TMP/registered"
echo 'c2|team-x|restored-source|pg-backups-c1|/pg-orders-db/orders-db' >> "$TMP/locations"
delp orders-db true
rec "result.c1.orders-db|SUCCEEDED" | grep -q "3 backups expired" && rec "result.c1.orders-db|SUCCEEDED" | grep -q "backups expired, blobs KEPT: repository pg-backups-c1/pg-orders-db/orders-db is also used by c2/team-x/restored-source (/pg-orders-db/orders-db)" \
  && rec "warning.c1.orders-db.repo|WARNING|BACKUP_REPO_SHARED" | grep -q "were not deleted" \
  && [[ "$(blobs_left "$orders_prefix")" == 7 ]] && ! has_ev 'blob DELETE' && ! has_ev 'blob LIST' && has_ev 'expire orders-full-2' && has_ev 'delete postgres pg-orders-db/orders-db' \
  && ok "shared repoPath on another registered cluster: every backup is expired, the instance is deleted, the blobs stay; the result and a warning name the other location" \
  || bad "shared repo" "$(cat "$TMP/events") $(cat "$TMP/records")"
reset
echo 'c1|team-y|parent-repo|pg-backups-c1|/pg-orders-db' >> "$TMP/locations"
delp orders-db true
rec "result.c1.orders-db|SUCCEEDED" | grep -q "blobs KEPT" && [[ "$(blobs_left "$orders_prefix")" == 7 ]] \
  && ok "shared repoPath: a location whose repoPath contains this one (the pre-Round 22 /<namespace> path) counts as sharing" || bad "parent repo" "$(cat "$TMP/records")"
reset
echo 'c1|team-y|child-repo|pg-backups-c1|/pg-orders-db/orders-db/old' >> "$TMP/locations"
delp orders-db true
rec "result.c1.orders-db|SUCCEEDED" | grep -q "blobs KEPT" && ok "shared repoPath: a location inside this repository counts as sharing" || bad "child repo" "$(cat "$TMP/records")"
reset
echo 'c1|team-y|other-container|pg-backups-c9|/pg-orders-db/orders-db' >> "$TMP/locations"
echo 'c1|team-y|other-account|pg-backups-c1|/pg-orders-db/orders-db||backup-storage-2' >> "$TMP/locations"
echo acct2 > "$TMP/acct.c1.team-y"
delp orders-db true
[[ "$(blobs_left "$orders_prefix")" == 0 ]] && rec "result.c1.orders-db|SUCCEEDED" | grep -q "blobs deleted" \
  && ok "not shared: the same repoPath in another container, or behind another storage account, is another repository" || bad "not shared" "$(cat "$TMP/records") $OUT"
reset
echo c2 >> "$TMP/registered"; touch "$TMP/unusable.c2"
delp orders-db true
rec "result.c1.orders-db|SUCCEEDED" | grep -q "blobs KEPT: repository .* also used by cluster c2 (kubeconfig unavailable: not scanned)" && [[ "$(blobs_left "$orders_prefix")" == 7 ]] \
  && ok "a registered cluster that cannot be scanned counts as sharing: expire only, blobs kept, the report says which cluster was not scanned" || bad "unscannable" "$(cat "$TMP/records")"
reset
: > "$TMP/registered"
delp orders-db true
rec "result.c1.orders-db|SUCCEEDED" | grep -q "blobs KEPT: repository .* the registered clusters cannot be listed (or c1 is not among them)" && [[ "$(blobs_left "$orders_prefix")" == 7 ]] \
  && ok "an empty cluster registry (or one without the cluster itself) proves nothing: counts as sharing, blobs kept" || bad "empty registry" "$(cat "$TMP/records")"
reset
echo 'c1|shared|app-a-backup-location2|pg-backups-c1|/pg-orders-db/orders-db' >> "$TMP/locations"
delp orders-db true
rec "result.c1.orders-db|SUCCEEDED" | grep -q "also used by c1/shared/app-a-backup-location2" && ok "a second location on the same cluster counts as sharing" || bad "same cluster" "$(cat "$TMP/records")"

# ---- refused: finalBackup true or required, nothing changes
reset
delp orders-db true true
rec "result.c1.orders-db|FAILED|INVALID_OPTIONS" | grep -q "purgeBackups=true needs finalBackup=false" && [[ ! -s "$TMP/events" ]] && cmp -s "$TMP/blobs" "$TMP/blobs.base" \
  && ok "purgeBackups=true with finalBackup=true is refused before anything changes" || bad "refused true" "$(cat "$TMP/records") $(cat "$TMP/events")"
reset
delp orders-db true required
rec "result.c1.orders-db|FAILED|INVALID_OPTIONS" | grep -q "finalBackup=required" && [[ ! -s "$TMP/events" ]] \
  && ok "purgeBackups=true with finalBackup=required is refused as well" || bad "refused required" "$(cat "$TMP/records") $(cat "$TMP/events")"

# ---- more refusals, all before anything changes
reset
sed -i '/orders-db-backup-location/d' "$TMP/locations"
delp orders-db true
rec "result.c1.orders-db|FAILED|PURGE_LOCATION_UNKNOWN" | grep -q "no audit copy" && [[ ! -s "$TMP/events" ]] \
  && ok "no backup location object and no audit copy: PURGE_LOCATION_UNKNOWN, nothing deleted" || bad "location unknown" "$(cat "$TMP/records") $(cat "$TMP/events")"
reset
sed -i 's#|/pg-orders-db/orders-db$#|/#' "$TMP/locations"
delp orders-db true
rec "result.c1.orders-db|FAILED|PURGE_REPOPATH_REFUSED" | grep -q "never deletes a whole container" && [[ ! -s "$TMP/events" ]] && cmp -s "$TMP/blobs" "$TMP/blobs.base" \
  && ok "a repoPath that is the root of the container is refused (PURGE_REPOPATH_REFUSED)" || bad "root repoPath" "$(cat "$TMP/records") $(cat "$TMP/events")"
reset
rm -f "$VAULTD/backup-storage.json"
delp orders-db true
rec "result.c1.orders-db|FAILED|NO_VAULT_SECRET" | grep -q "backup-storage" && [[ ! -s "$TMP/events" ]] \
  && ok "no storage key in Vault (the pod has no Vault Agent file): NO_VAULT_SECRET before anything is expired or deleted" || bad "no vault" "$(cat "$TMP/records") $(cat "$TMP/events")"
jq -n --arg k "$STORAGE_KEY" '{accountName: "acct1", accountKey: $k}' > "$VAULTD/backup-storage.json"
reset
echo acct9 > "$TMP/acct.c1.pg-orders-db"
delp orders-db true
rec "result.c1.orders-db|FAILED|PURGE_ACCOUNT_MISMATCH" | grep -q "acct9" && [[ ! -s "$TMP/events" ]] \
  && ok "the location's Secret names another storage account than the fleet's key: PURGE_ACCOUNT_MISMATCH, nothing deleted" || bad "account mismatch" "$(cat "$TMP/records") $(cat "$TMP/events")"

# ---- what pgBackRest declines is reported; no answer stops the run before the delete
reset
touch "$TMP/decline.orders-full-2"
delp orders-db true
rec "result.c1.orders-db|SUCCEEDED" | grep -q "pgBackRest declined to expire 1: orders-full-2: pgBackRest: unable to remove the latest full backup" \
  && rec "warning.c1.orders-db|WARNING|BACKUP_EXPIRE_DECLINED" | grep -q "orders-full-2" && [[ "$RC" -eq 0 && "$(blobs_left "$orders_prefix")" == 0 ]] \
  && ok "declined by pgBackRest: reported in the result and as a warning, not a failure; the blobs are deleted" || bad "declined" "$(cat "$TMP/records") $OUT"
reset
touch "$TMP/silent.orders-full-2"
delp orders-db true
rec "result.c1.orders-db|FAILED|BACKUP_EXPIRE_TIMEOUT" | grep -q "nothing was deleted" && ! has_ev 'delete postgres' && ! has_ev 'blob DELETE' && yq -e '.clusters.c1.instances | has("orders-db")' "$TMP/fleet.yaml" >/dev/null \
  && ok "no answer to an expire: BACKUP_EXPIRE_TIMEOUT before the Postgres is deleted or the entry leaves Git" || bad "expire timeout" "$(cat "$TMP/records") $(cat "$TMP/events")"

# an instance that is not Running cannot have its backups expired: its own repository is deleted anyway, a shared one is not touched
reset
printf 'Failed' > "$TMP/pgstate"
delp orders-db true
rec "result.c1.orders-db|SUCCEEDED" | grep -q "no backups expired: currentState=Failed (the blobs are deleted anyway)" && ! has_ev 'expire ' && [[ "$(blobs_left "$orders_prefix")" == 0 ]] \
  && ok "purgeBackups on an instance that is not Running: no expire is possible, its own blobs are deleted, the note says so" || bad "not running purge" "$(cat "$TMP/records") $(cat "$TMP/events")"
reset
printf 'Failed' > "$TMP/pgstate"
echo c2 >> "$TMP/registered"
echo 'c2|team-x|restored-source|pg-backups-c1|/pg-orders-db/orders-db' >> "$TMP/locations"
delp orders-db true
rec "result.c1.orders-db|FAILED|BACKUP_EXPIRE_IMPOSSIBLE" | grep -q "nothing was deleted" && ! has_ev 'delete postgres' && ! has_ev 'blob ' \
  && ok "purgeBackups on an instance that is not Running with a shared repoPath: BACKUP_EXPIRE_IMPOSSIBLE before anything is deleted" || bad "not running shared" "$(cat "$TMP/records") $(cat "$TMP/events")"

# ---- a blob that cannot be deleted: the run fails after the instance is gone, and a re-run finishes from the audit copy
reset
printf '%s\n' "pg-backups-c1/pg-orders-db/orders-db/archive/stanza/archive.info" > "$TMP/blob-fail"
delp orders-db true
rec "result.c1.orders-db|FAILED|BLOB_PURGE_FAILED" | grep -q "pg-backups-c1/pg-orders-db/orders-db/archive/stanza/archive.info answered HTTP 500" \
  && has_ev 'delete postgres pg-orders-db/orders-db' && [[ "$(blobs_left "$orders_prefix")" == 5 ]] \
  && ok "a blob that cannot be deleted: BLOB_PURGE_FAILED names it and the HTTP status; the instance is already deleted" || bad "blob fail" "$(cat "$TMP/records") $(cat "$TMP/blobs")"
rm -f "$TMP/blob-fail"; : > "$TMP/events"; : > "$TMP/records"
grep -vE '^orders-db ' "$TMP/live" > "$TMP/live.n"; mv "$TMP/live.n" "$TMP/live"
delp orders-db true
rec "result.c1.orders-db|SUCCEEDED" | grep -q "5 blobs deleted under pg-backups-c1/pg-orders-db/orders-db" && rec "result.c1.orders-db|SUCCEEDED" | grep -q "no backups expired: Postgres orders-db does not run" \
  && [[ "$(blobs_left "$orders_prefix")" == 0 && "$RC" -eq 0 ]] \
  && ok "a re-run (entry and location gone) finds the container and repoPath in the audit copy and deletes what is left" || bad "re-run" "$(cat "$TMP/records") $OUT"
reset
WRONG="$(printf 'another-key-0123456789abcdefghij' | base64)"; printf '%s' "$WRONG" > "$VAULTD/server-key"
delp orders-db true
rec "result.c1.orders-db|FAILED|BLOB_PURGE_FAILED" | grep -q "HTTP 403 (the storage key was rejected)" && [[ "$(blobs_left "$orders_prefix")" == 7 ]] \
  && ok "a rejected storage key: BLOB_PURGE_FAILED says HTTP 403, key rejected; nothing deleted" || bad "403" "$(cat "$TMP/records")"
! grep -rqF -- "$WRONG" "$TMP/records" "$TMP/events" "$TMP/work" 2>/dev/null && ok "a failed run does not leak the key either (records, events, work directory)" || bad "key in a failed run" "$(grep -rlF -- "$WRONG" "$TMP")"

# ---- tpg-delete-apps passes it through: the input, the clusterMap key, the dry run
reset
RC=0; OUT="$(P_APPS='{"c1":["tpg-instances:orders-db"]}' P_DRY_RUN=false P_PURGE_PVCS=false P_PURGE_NS=false P_FINAL_BACKUP=false P_PURGE_BACKUPS=true P_FORCE=false P_TIMEOUT=600 \
  bash "$TMP/delete-apps.sh" wf c1 2>&1)" || RC=$?
has_ev 'expire orders-full-2' && has_ev 'blob DELETE' && [[ "$(blobs_left "$orders_prefix")" == 0 && "$RC" -eq 0 ]] \
  && ok "delete-apps: the input purgeBackups=true reaches delete-instance (expire, delete, blobs)" || bad "apps purge" "$(cat "$TMP/events") $(cat "$TMP/records") $OUT"
reset
appsmap '{"c1":{"instances":{"orders-db":{"purgeBackups":"true","finalBackup":"false"}}}}'
has_ev 'expire orders-full-2' && [[ "$(blobs_left "$orders_prefix")" == 0 && "$RC" -eq 0 ]] \
  && ok "delete-apps: the clusterMap key purgeBackups of the instance reaches delete-instance" || bad "apps map purge" "$(cat "$TMP/events") $(cat "$TMP/records") $OUT"
reset
appsmap '{"c1":{"instances":{"orders-db":{"purgeBackups":"true","finalBackup":"true"}}}}'
rec "result.c1.orders-db|FAILED|INVALID_OPTIONS" | grep -q "purgeBackups=true needs finalBackup=false" && ! has_ev 'expire' \
  && ok "delete-apps with a clusterMap: purgeBackups without finalBackup=false (the input default is true) is refused for that instance, nothing expired" || bad "apps map refused" "$(cat "$TMP/records") $(cat "$TMP/events")"
reset
RC=0; OUT="$(P_APPS='{"c1":["tpg-instances:orders-db"]}' P_DRY_RUN=true P_PURGE_PVCS=false P_PURGE_NS=false P_FINAL_BACKUP=false P_PURGE_BACKUPS=true P_FORCE=false P_TIMEOUT=600 \
  bash "$TMP/delete-apps.sh" wf c1 2>&1)" || RC=$?
rec "result.c1.orders-db|SUCCEEDED|DRY_RUN" | grep -q "purgeBackups=true" && [[ ! -s "$TMP/events" ]] && ok "delete-apps dry run: the plan says purgeBackups=true and changes nothing" || bad "apps dry run purge" "$(cat "$TMP/records") $(cat "$TMP/events")"

# ---- Round 23 phase 5 review: re-run after a failed blob delete, retries, fail-closed sharing check, late sharing,
#      the account of the repository, the check listing
cat > "$TMP/prelude-disc.sh" <<PRELUDE
source "$TMP/prelude.sh"
kubectl() { :; }
registered_wave() { echo 0; }
run_records() { echo '{}'; }
PRELUDE
sed "s#source /scripts/lib.sh#source $TMP/prelude-disc.sh#" "$ROOT/workflows/scripts/discover.sh" > "$TMP/discover.sh"
disc_run() {  # disc_run INSTANCES_INPUT [PURGE_BACKUPS] -> discover.sh as tpg-delete-instance runs it (filter pairs); the items in $ITEMS, the records in $DREC
  rm -rf "$TMP/work"; : > "$TMP/records"; rm -f /tmp/inventory.json /tmp/instance-items.json
  RC=0; OUT="$(P_FILTER=pairs P_INSTANCES="$1" P_PURGE_BACKUPS="${2:-false}" bash "$TMP/discover.sh" wf c1 2>&1)" || RC=$?
  ITEMS="$(cat /tmp/instance-items.json 2>/dev/null || true)"; DREC="$(cat "$TMP/records")"
}
rerun_state() {  # a purgeBackups run that failed at the blobs: the instance, its entry and its location are gone; the audit copy has the repository
  reset
  printf '%s\n' "pg-backups-c1/pg-orders-db/orders-db/archive/stanza/archive.info" > "$TMP/blob-fail"
  delp orders-db true
  rm -f "$TMP/blob-fail"; : > "$TMP/events"; : > "$TMP/records"
}
acopy() { local f=("$TMP"/deleted/c1/orders-db-*.yaml); printf '%s' "${f[0]}"; }   # the audit copy of orders-db

rerun_state
[[ "$(blobs_left "$orders_prefix")" == 5 ]] && [[ "$(yq '.clusters.c1.instances | has("orders-db")' "$TMP/fleet.yaml")" == false ]] && ! grep -qx 'orders-db pg-orders-db' "$TMP/live" \
  || bad "re-run state is not what the tests assume" "$(cat "$TMP/blobs")"
disc_run '[orders-db]' false
[[ "$RC" -ne 0 ]] && grep -q 'result.c1.orders-db|FAILED|UNKNOWN_INSTANCE' <<<"$DREC" \
  && ok "re-run through discover without purgeBackups: the gone instance is still UNKNOWN_INSTANCE" || bad "discover without purge" "$DREC $OUT"
disc_run '[orders-db]' true
[[ "$RC" -eq 0 && "$(jq -c '[.[] | select(.instance == "orders-db")] | length' <<<"$ITEMS")" == 1 ]] && jq -e '.[0].instances[] | select(.name == "orders-db" and .namespace == "pg-orders-db")' /tmp/inventory.json >/dev/null \
  && ok "re-run through discover (tpg-delete-instance) with purgeBackups=true: an instance with an audit copy that has deleted.backupLocation is accepted, with the namespace of the copy" \
  || bad "discover re-run" "$ITEMS $DREC $OUT"
mkdir -p "$TMP/work"; printf '%s' '{"c1":{"instances":{"orders-db":{"purgeBackups":"true","finalBackup":"false"}}}}' > "$TMP/work/cmap.json"
RC=0; rm -f /tmp/instance-items.json; : > "$TMP/records"
OUT="$(P_FILTER=pairs P_CLUSTER_MAP=map bash "$TMP/discover.sh" wf c1 2>&1)" || RC=$?
[[ "$RC" -eq 0 && "$(jq -c 'map(.instance)' /tmp/instance-items.json)" == '["orders-db"]' ]] \
  && ok "re-run through discover with a clusterMap: purgeBackups of the instance key is enough" || bad "discover map re-run" "$(cat /tmp/instance-items.json) $OUT"
printf '%s' '{"c1":{"instances":{"orders-db":{"purgeBackups":"false"}}}}' > "$TMP/work/cmap.json"
RC=0; : > "$TMP/records"
OUT="$(P_FILTER=pairs P_CLUSTER_MAP=map P_PURGE_BACKUPS=true bash "$TMP/discover.sh" wf c1 2>&1)" || RC=$?
[[ "$RC" -ne 0 ]] && grep -q 'result.c1.orders-db|FAILED|UNKNOWN_INSTANCE' "$TMP/records" \
  && ok "re-run through discover: purgeBackups=false of the instance in the clusterMap overrides the input (still UNKNOWN_INSTANCE)" || bad "discover map override" "$(cat "$TMP/records") $OUT"
disc_run '[ghost-db]' true
[[ "$RC" -ne 0 ]] && grep -q 'result.c1.ghost-db|FAILED|UNKNOWN_INSTANCE' <<<"$DREC" \
  && ok "re-run through discover: an instance that never existed (no audit copy) is UNKNOWN_INSTANCE even with purgeBackups=true" || bad "discover ghost" "$DREC"
yq -i 'del(.deleted.backupLocation)' "$(acopy)"
cp "$(acopy)" "$TMP/copy.nolocation"
disc_run '[orders-db]' true
[[ "$RC" -ne 0 ]] && grep -q 'result.c1.orders-db|FAILED|UNKNOWN_INSTANCE' <<<"$DREC" \
  && ok "re-run through discover: an audit copy without deleted.backupLocation has nothing to purge: UNKNOWN_INSTANCE" || bad "discover copy without location" "$DREC"
# the whole chain: discover, then delete-instance for what discover found
rerun_state
disc_run '[orders-db]' true
inst="$(jq -r '.[0].instance' <<<"$ITEMS")"
delp "$inst" true
rec "result.c1.orders-db|SUCCEEDED" | grep -q "re-run: the Postgres and its fleet.yaml entry are already deleted; only the blob purge is finished" \
  && rec "result.c1.orders-db|SUCCEEDED" | grep -q "5 blobs deleted under pg-backups-c1/pg-orders-db/orders-db" && [[ "$(blobs_left "$orders_prefix")" == 0 && "$RC" -eq 0 ]] \
  && ! has_ev 'delete postgres pg-orders-db/orders-db' && ! has_ev 'expire ' && ! has_ev 'commit ' \
  && ok "re-run (discover, then delete-instance): the result says only the blob purge was finished; nothing else is deleted, expired or committed" || bad "re-run result" "$(cat "$TMP/records") $(cat "$TMP/events") $OUT"

# the re-run through tpg-delete-apps (the instance, its entry and its location are gone)
rerun_state
RC=0; OUT="$(P_APPS='{"c1":["tpg-instances:orders-db"]}' P_DRY_RUN=false P_PURGE_PVCS=false P_PURGE_NS=false P_FINAL_BACKUP=false P_PURGE_BACKUPS=true P_FORCE=false P_TIMEOUT=600 \
  bash "$TMP/delete-apps.sh" wf c1 2>&1)" || RC=$?
rec "result.c1.orders-db|SUCCEEDED" | grep -q "only the blob purge is finished" && [[ "$(blobs_left "$orders_prefix")" == 0 && "$RC" -eq 0 ]] \
  && ok "re-run through tpg-delete-apps with purgeBackups=true: the audit copy is enough, the remaining blobs are deleted" || bad "apps re-run" "$(cat "$TMP/records") $OUT"
rerun_state
RC=0; OUT="$(P_APPS='{"c1":["tpg-instances:orders-db"]}' P_DRY_RUN=false P_PURGE_PVCS=false P_PURGE_NS=false P_FINAL_BACKUP=false P_PURGE_BACKUPS=false P_FORCE=false P_TIMEOUT=600 \
  bash "$TMP/delete-apps.sh" wf c1 2>&1)" || RC=$?
rec "result.c1.orders-db|FAILED|UNKNOWN_INSTANCE" | grep -q . && [[ "$RC" -ne 0 && "$(blobs_left "$orders_prefix")" == 5 ]] \
  && ok "re-run through tpg-delete-apps without purgeBackups: still UNKNOWN_INSTANCE" || bad "apps re-run without purge" "$(cat "$TMP/records") $OUT"
RC=0; : > "$TMP/records"; OUT="$(P_APPS='{"c1":["tpg-instances:orders-db"]}' P_DRY_RUN=true P_PURGE_PVCS=false P_PURGE_NS=false P_FINAL_BACKUP=false P_PURGE_BACKUPS=true P_FORCE=false P_TIMEOUT=600 \
  bash "$TMP/delete-apps.sh" wf c1 2>&1)" || RC=$?
rec "result.c1.orders-db|SUCCEEDED|DRY_RUN" | grep -q "would only finish the blob purge" && [[ "$(blobs_left "$orders_prefix")" == 5 ]] \
  && ok "re-run through tpg-delete-apps, dry run: the plan says it would only finish the blob purge" || bad "apps re-run dry run" "$(cat "$TMP/records") $OUT"
cp "$TMP/copy.nolocation" "$(acopy)"
RC=0; : > "$TMP/records"; OUT="$(P_APPS='{"c1":["tpg-instances:orders-db"]}' P_DRY_RUN=false P_PURGE_PVCS=false P_PURGE_NS=false P_FINAL_BACKUP=false P_PURGE_BACKUPS=true P_FORCE=false P_TIMEOUT=600 \
  bash "$TMP/delete-apps.sh" wf c1 2>&1)" || RC=$?
rec "result.c1.orders-db|FAILED|UNKNOWN_INSTANCE" | grep -q . && [[ "$RC" -ne 0 && "$(blobs_left "$orders_prefix")" == 5 ]] \
  && ok "re-run through tpg-delete-apps: a copy without deleted.backupLocation is UNKNOWN_INSTANCE" || bad "apps re-run no location" "$(cat "$TMP/records") $OUT"

# ---- retries per blob (429, 5xx, curl failure), bounded, with a backoff
reset
echo 'pg-backups-c1/pg-orders-db/orders-db/archive/stanza/archive.info 503 2' > "$TMP/blob-fail.flaky"
delp orders-db true
[[ "$RC" -eq 0 && "$(blobs_left "$orders_prefix")" == 0 && "$(grep -c 'archive/stanza/archive.info -> 503' "$TMP/events")" == 2 ]] && rec "result.c1.orders-db|SUCCEEDED" | grep -q "7 blobs deleted" \
  && ok "a transient 503 on one blob is retried and the purge succeeds (two 503, then 202)" || bad "retry 503" "$(grep blob "$TMP/events") $(cat "$TMP/records")"
reset
echo 'pg-backups-c1/pg-orders-db/orders-db/archive/stanza/archive.info 429 1' > "$TMP/blob-fail.flaky"
delp orders-db true
[[ "$RC" -eq 0 && "$(blobs_left "$orders_prefix")" == 0 ]] && ok "HTTP 429 (throttled) is retried as well" || bad "retry 429" "$(grep blob "$TMP/events") $(cat "$TMP/records")"
reset
echo 'pg-backups-c1/pg-orders-db/orders-db/archive/stanza/archive.info 403 1' > "$TMP/blob-fail.flaky"
delp orders-db true
rec "result.c1.orders-db|FAILED|BLOB_PURGE_FAILED" | grep -q "archive.info answered HTTP 403" && [[ "$(grep -c 'archive/stanza/archive.info -> 403' "$TMP/events")" == 1 ]] \
  && ok "an HTTP 403 on a blob is not retried" || bad "no retry 403" "$(grep blob "$TMP/events") $(cat "$TMP/records")"
reset
printf '%s\n' "pg-backups-c1/pg-orders-db/orders-db/archive/stanza/archive.info" > "$TMP/blob-fail"
delp orders-db true
[[ "$(grep -c 'archive/stanza/archive.info -> 500' "$TMP/events")" == 4 ]] && rec "result.c1.orders-db|FAILED|BLOB_PURGE_FAILED" | grep -q "answered HTTP 500" \
  && ok "a blob that keeps answering 500 is tried 4 times, then BLOB_PURGE_FAILED (bounded)" || bad "bounded retries" "$(grep blob "$TMP/events") $(cat "$TMP/records")"
# the backoff and the curl failure (000), straight on the function
( export TPG_WORK="$TMP/work-retry"; mkdir -p "$TPG_WORK"; source "$ROOT/workflows/scripts/lib.sh"
  : > "$TMP/curl-n"; : > "$TMP/slept"
  # shellcheck disable=SC2317  # called by blob_delete_one
  curl() { cat > /dev/null; echo x >> "$TMP/curl-n"; if [[ "$(wc -l < "$TMP/curl-n")" -le 3 ]]; then printf '000'; return 6; fi; printf '202'; }
  sleep() { echo "$1" >> "$TMP/slept"; }
  BLOB_RETRY_BASE=1
  printf 'code=%s\n' "$(blob_delete_one acct "$(printf 'k' | base64)" cont a/b blob.core.windows.net)" > "$TMP/retry.out" )
[[ "$(cat "$TMP/retry.out")" == "code=202" && "$(paste -sd' ' "$TMP/slept")" == "1 2 4" && "$(wc -l < "$TMP/curl-n")" == 4 ]] \
  && ok "a curl failure (HTTP 000) is retried with a 1, 2, 4 second backoff and the fourth try succeeds" || bad "backoff" "$(cat "$TMP/retry.out") slept=$(paste -sd' ' "$TMP/slept") tries=$(wc -l < "$TMP/curl-n")"

# ---- the check listing after the delete must be readable and empty
reset
: > "$TMP/blob-fail.badcheck"
delp orders-db true
rec "result.c1.orders-db|FAILED|BLOB_PURGE_FAILED" | grep -q "check listing" && ! rec "result.c1.orders-db|SUCCEEDED" | grep -q . \
  && ok "a check listing that cannot be parsed is BLOB_PURGE_FAILED, never a success (an empty count is not zero)" || bad "bad check listing" "$(cat "$TMP/records") $(grep blob "$TMP/events")"

# ---- the sharing check fails closed
reset
echo c2 >> "$TMP/registered"; touch "$TMP/crd-error.c2"
delp orders-db true
rec "result.c1.orders-db|SUCCEEDED" | grep -q "blobs KEPT: repository .* also used by cluster c2 (.*not scanned)" && [[ "$(blobs_left "$orders_prefix")" == 7 ]] && ! has_ev 'blob DELETE' \
  && ok "a registered cluster whose CRD lookup fails (not a NotFound) with a reachable /readyz is not scanned: shared, blobs kept" || bad "crd error fails open" "$(cat "$TMP/records") $(cat "$TMP/events")"
reset
echo c2 >> "$TMP/registered"; touch "$TMP/crd-notfound.c2"
delp orders-db true
[[ "$(blobs_left "$orders_prefix")" == 0 && "$RC" -eq 0 ]] \
  && ok "a registered cluster whose answer is NotFound for the CRD has no locations: not shared, blobs deleted" || bad "crd notfound" "$(cat "$TMP/records")"

# ---- a location that appears between the first check and the blob delete
reset
touch "$TMP/late-location"
delp orders-db true
rec "result.c1.orders-db|SUCCEEDED" | grep -q "blobs KEPT: repository .* now also used by c2/team-x/late" && rec "warning.c1.orders-db.repo|WARNING|BACKUP_REPO_SHARED" | grep -q "c2/team-x/late" \
  && [[ "$(blobs_left "$orders_prefix")" == 7 && "$RC" -eq 0 ]] && ! has_ev 'blob DELETE' && has_ev 'delete postgres pg-orders-db/orders-db' \
  && ok "a location that uses the repository appears after the first check: it is checked again before the blobs, they are kept and a warning names the other location" \
  || bad "late location" "$(cat "$TMP/records") $(cat "$TMP/events")"

# ---- the result texts
rerun_state
echo c2 >> "$TMP/registered"; echo 'c2|team-x|restored-source|pg-backups-c1|/pg-orders-db/orders-db' >> "$TMP/locations"
delp orders-db true
rec "result.c1.orders-db|SUCCEEDED" | grep -q "no backups expired, blobs KEPT: repository" && ! rec "result.c1.orders-db|SUCCEEDED" | grep -q "; backups expired, blobs KEPT" \
  && ok "shared repository on a re-run (nothing was expired): the note says no backups expired, not 'backups expired'" || bad "kept wording, nothing expired" "$(cat "$TMP/records")"
reset
touch "$TMP/patch-error.orders-full-2"
delp orders-db true
rec "result.c1.orders-db|FAILED|BACKUP_EXPIRE_ERROR" | grep -q "nothing was deleted" && grep -q "cannot be set" "$TMP/records" && ! has_ev 'delete postgres' \
  && ok "an API error on the expire is BACKUP_EXPIRE_ERROR (not BACKUP_EXPIRE_TIMEOUT); nothing was deleted" || bad "expire error code" "$(cat "$TMP/records") $(cat "$TMP/events")"

# ---- the storage account of the repository: recorded, compared on a re-run, refused when unknown
reset
delp orders-db true
[[ "$(yq '.deleted.backupLocation.accountName' "$(acopy)")" == acct1 && "$(yq '.deleted.backupLocation.secret' "$(acopy)")" == backup-storage ]] \
  && ok "the audit copy records the storage account and the Secret name of the backup location" || bad "audit account" "$(cat "$(acopy)")"
reset
delp orders-db false
[[ "$(yq '.deleted.backupLocation.accountName' "$(acopy)")" == acct1 ]] \
  && ok "the audit copy records the account also without purgeBackups (a later re-run needs it)" || bad "audit account without purge" "$(cat "$(acopy)")"
rerun_state
yq -i '.deleted.backupLocation.accountName = "acct9"' "$(acopy)"
delp orders-db true
rec "result.c1.orders-db|FAILED|PURGE_ACCOUNT_MISMATCH" | grep -q "acct9" && [[ "$(blobs_left "$orders_prefix")" == 5 ]] \
  && ok "re-run: the account in the audit copy is compared with the fleet's account (PURGE_ACCOUNT_MISMATCH), nothing deleted" || bad "rerun mismatch" "$(cat "$TMP/records")"
rerun_state
yq -i '.deleted.backupLocation.secret = "backup-storage-2" | del(.deleted.backupLocation.accountName)' "$(acopy)"
touch "$TMP/secret-unreadable.backup-storage-2"   # the namespace and its Secret are gone as well
delp orders-db true
rec "result.c1.orders-db|FAILED|PURGE_ACCOUNT_UNKNOWN" | grep -q "backup-storage-2" && [[ "$(blobs_left "$orders_prefix")" == 5 ]] \
  && ok "re-run: a non-default Secret whose account the audit copy does not record is refused (PURGE_ACCOUNT_UNKNOWN)" || bad "rerun unknown" "$(cat "$TMP/records")"
rerun_state
yq -i 'del(.deleted.backupLocation.accountName) | del(.deleted.backupLocation.secret)' "$(acopy)"
delp orders-db true
[[ "$RC" -eq 0 && "$(blobs_left "$orders_prefix")" == 0 ]] \
  && ok "re-run: an audit copy of an older run (no account, the default Secret) still finishes (the Secret is the fleet's backup-storage)" || bad "rerun old copy" "$(cat "$TMP/records")"
reset
sed -i 's#^c1|pg-orders-db|orders-db-backup-location|pg-backups-c1|/pg-orders-db/orders-db$#&||backup-storage-2#' "$TMP/locations"
touch "$TMP/secret-unreadable.backup-storage-2"
delp orders-db true
rec "result.c1.orders-db|FAILED|PURGE_ACCOUNT_UNKNOWN" | grep -q "backup-storage-2" && [[ ! -s "$TMP/events" ]] && [[ "$(blobs_left "$orders_prefix")" == 7 ]] \
  && ok "a live location with a non-default Secret that cannot be read: PURGE_ACCOUNT_UNKNOWN before anything changes" || bad "live unknown" "$(cat "$TMP/records") $(cat "$TMP/events")"
reset
touch "$TMP/secret-unreadable.backup-storage"
delp orders-db true
[[ "$RC" -eq 0 && "$(blobs_left "$orders_prefix")" == 0 ]] \
  && ok "the default Secret backup-storage that cannot be read is the fleet's (synced from Vault): the purge goes on" || bad "default unreadable" "$(cat "$TMP/records")"

echo
echo "delete: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
