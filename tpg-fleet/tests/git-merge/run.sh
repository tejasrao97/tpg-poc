#!/usr/bin/env bash
# Concurrent writers of clusters/fleet.yaml (Round 22): the fleet lock, git_merge_remote and
# git_push_head of workflows/scripts/lib.sh against a local bare repository, and fleet-merge3.sh.
# Regression of the tpg-delete-apps run in which `git pull --rebase` stopped on a text conflict in
# fleet.yaml and the operator delete was never pushed. Needs bash, git and jq; yq (mikefarah) is
# replaced by a small ruby shim for `yq -o=json -I=0 FILE` and `yq -P` when it is not installed.
# shellcheck disable=SC2015  # ok/bad: A && ok || bad, as in the other suites
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
for t in git jq; do command -v "$t" >/dev/null || { echo "SKIP tests/git-merge: $t not installed" >&2; exit 0; }; done
if ! command -v yq >/dev/null; then
  command -v ruby >/dev/null || { echo "SKIP tests/git-merge: neither yq nor ruby" >&2; exit 0; }
  SHIM="$(mktemp -d)"
  cat > "$SHIM/yq" <<'RUBY'
#!/usr/bin/env ruby
require 'yaml'; require 'json'
args = ARGV.dup
if args.include?('-P') then puts YAML.dump(JSON.parse($stdin.read)).sub(/\A---\n/, '')
else file = args.last; puts JSON.generate(YAML.load_file(file)) end
RUBY
  chmod +x "$SHIM/yq"; export PATH="$SHIM:$PATH"
fi
PASS=0; FAIL=0
ok()  { printf 'ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL %s\n' "$1"; [[ -z "${2:-}" ]] || printf '       %s\n' "$2"; FAIL=$((FAIL + 1)); }
T="$(mktemp -d)"; trap 'rm -rf "$T" "${SHIM:-}"' EXIT

# --- the helpers of lib.sh and fleet-merge3.sh
awk '/^# -+ writers of clusters\/fleet.yaml/ {p=1} /^github_repo\(\) \{/ {exit} p {print}' "$ROOT/workflows/scripts/lib.sh" > "$T/helpers.sh"
grep -q "^git_push_head()" "$T/helpers.sh" && ok "the push helpers are in lib.sh" || { bad "helpers not found"; exit 1; }
# read by the helpers of lib.sh
# shellcheck disable=SC2034
SCRIPTS_DIR="$ROOT/workflows/scripts"
# shellcheck disable=SC2034
ARGO_NS=argo
# shellcheck disable=SC2034
WF=wf-test
log() { printf '%s\n' "$*" >> "$T/step.log"; }
setting() { echo main; }
sleep() { :; }
# the lock: a ConfigMap kept in a file; patch honours the resourceVersion like the API server
KCM="$T/cm.json"
kubectl() {
  case " $* " in
    *" create configmap "*) [[ -f "$KCM" ]] || echo '{"metadata":{"resourceVersion":"1"},"data":{"holder":"","time":"0"}}' > "$KCM" ;;
    *" get configmap "*jsonpath*) jq -j '.data.holder' "$KCM" ;;
    *" get configmap "*) cat "$KCM" ;;
    *" patch configmap "*)
      local patch="${*: -1}" cur rv
      cur="$(jq -r '.metadata.resourceVersion' "$KCM")"
      rv="$(jq -r '.metadata.resourceVersion // ""' <<<"$patch")"
      [[ -z "$rv" || "$rv" == "$cur" ]] || return 1
      jq -c --argjson p "$patch" '.data += ($p.data // {}) | .metadata.resourceVersion = ((.metadata.resourceVersion | tonumber) + 1 | tostring)' "$KCM" > "$KCM.n" && mv "$KCM.n" "$KCM" ;;
  esac
}
source "$T/helpers.sh"

# --- fleet-merge3.sh on its own
cat > "$T/base.yaml" <<'Y'
clusters:
  c1:
    operator: {version: v4.5.0}
    instances:
      orders: {instance: {postgresVersion: 16.10}}
      billing: {instance: {postgresVersion: 17.6}}
  c2:
    operator: {version: v4.5.0}
    instances:
      orders: {instance: {postgresVersion: 16.10}}
Y
# yq_edit FILE JQ: read the file first, then rewrite it (a redirect in the same pipeline truncates it early)
yq_edit() { local j; j="$(yq -o=json -I=0 "$1" | jq -c "$2")"; printf '%s' "$j" | yq -P > "$1.new"; mv "$1.new" "$1"; }
ours="$(yq -o=json -I=0 "$T/base.yaml" | jq -c 'del(.clusters.c1.instances.orders)')"; printf '%s' "$ours" | yq -P > "$T/ours.yaml"
theirs="$(yq -o=json -I=0 "$T/base.yaml" | jq -c 'del(.clusters.c2.operator)')"; printf '%s' "$theirs" | yq -P > "$T/theirs.yaml"
bash "$ROOT/workflows/scripts/fleet-merge3.sh" "$T/base.yaml" "$T/ours.yaml" "$T/theirs.yaml" "$T/out.yaml" && ok "fleet-merge3.sh merges two deletions of different keys" || bad "merge of different keys"
[[ "$(yq -o=json -I=0 "$T/out.yaml" | jq -c '[(.clusters.c1.instances | keys), (.clusters.c2 | keys)]')" == '[["billing"],["instances"]]' ]] && ok "the result holds both deletions and keeps the rest" || bad "merged content" "$(cat "$T/out.yaml")"
printf '%s' "$(yq -o=json -I=0 "$T/base.yaml" | jq -c '.clusters.c1.operator.version = "v4.6.0"')" | yq -P > "$T/ours2.yaml"
printf '%s' "$(yq -o=json -I=0 "$T/base.yaml" | jq -c '.clusters.c1.operator.version = "v4.7.0"')" | yq -P > "$T/theirs2.yaml"
bash "$ROOT/workflows/scripts/fleet-merge3.sh" "$T/base.yaml" "$T/ours2.yaml" "$T/theirs2.yaml" "$T/out2.yaml" 2>/dev/null && bad "a real conflict merged" || ok "the same value changed differently on both sides is a conflict (exit 1, nothing written)"
[[ ! -e "$T/out2.yaml" ]] && ok "and no output file is written" || bad "output written on conflict"

# --- git: two clones of a bare origin delete different things from fleet.yaml and push
git init -q --bare -b main "$T/origin.git"
git clone -q "$T/origin.git" "$T/seed" 2>/dev/null
mkdir -p "$T/seed/clusters"; cp "$T/base.yaml" "$T/seed/clusters/fleet.yaml"
git -C "$T/seed" -c user.name=t -c user.email=t@t add -A && git -C "$T/seed" -c user.name=t -c user.email=t@t commit -q -m base && git -C "$T/seed" push -q origin HEAD:main
clone() { git clone -q "$T/origin.git" "$1" 2>/dev/null; git -C "$1" config user.name t; git -C "$1" config user.email t@t; }
clone "$T/A"; clone "$T/B"
yq_edit "$T/A/clusters/fleet.yaml" '.clusters.c2.instances.alpha = {instance: {postgresVersion: "17.6"}}'
# B edits one line of the flow-style file by hand; A's yq rewrite reformatted the whole file, so the two commits overlap as text
sed -i.bak 's/billing: {instance: {postgresVersion: 17.6}}/billing: {instance: {postgresVersion: 18.0}}/' "$T/B/clusters/fleet.yaml" && rm -f "$T/B/clusters/fleet.yaml.bak"
git -C "$T/A" commit -qam "add c2/alpha"; git -C "$T/B" commit -qam "billing to 18.0"
: > "$T/step.log"
git_push_head "$T/A" && ok "writer A pushes" || bad "A push"
# a plain rebase would conflict here: both commits rewrite the same lines of the file
git clone -q "$T/B" "$T/Bprobe" 2>/dev/null; git -C "$T/Bprobe" remote set-url origin "$T/origin.git"; git -C "$T/Bprobe" fetch -q origin main
git -C "$T/Bprobe" config user.name t; git -C "$T/Bprobe" config user.email t@t
if git -C "$T/Bprobe" rebase -q origin/main >/dev/null 2>&1; then bad "the text rebase of B does not conflict (test needs a harder case)"; else ok "the text rebase of B stops on a conflict (as in the tpg-delete-apps log)"; fi
git_push_head "$T/B" && ok "writer B pushes after merging key by key" || bad "B push" "$(cat "$T/step.log")"
git -C "$T/seed" pull -q origin main 2>/dev/null
# compared as a number: yq prints 18.0 as 18, the ruby shim keeps 18.0
final="$(yq -o=json -I=0 "$T/seed/clusters/fleet.yaml" | jq -c '[(.clusters.c2.instances | keys), (.clusters.c1.instances.billing.instance.postgresVersion == 18)]')"
[[ "$final" == '[["alpha","orders"],true]' ]] && ok "origin holds both changes: A's new instance and B's version bump" || bad "origin content" "$final"
[[ "$(git -C "$T/origin.git" log --format=%s main | head -3 | paste -sd'|' -)" == "billing to 18.0|add c2/alpha|base" ]] && ok "history: three commits, none lost, no merge commit" || bad "history" "$(git -C "$T/origin.git" log --format=%s main)"
grep -q "merging the changed files key by key" "$T/step.log" && grep -q "pushed: billing to 18.0" "$T/step.log" && ok "the step log says what it did" || bad "log" "$(cat "$T/step.log")"
[[ -z "$(git -C "$T/B" status --porcelain)" && ! -d "$T/B/.git/rebase-merge" && ! -d "$T/B/.git/rebase-apply" ]] && ok "no half-finished rebase is left in the clone" || bad "rebase state left"

# --- a real conflict fails clearly, with no loop
clone "$T/C"; clone "$T/D"
yq_edit "$T/C/clusters/fleet.yaml" '.clusters.c1.operator.version = "v4.6.0"'
yq_edit "$T/D/clusters/fleet.yaml" '.clusters.c1.operator.version = "v4.7.0"'
git -C "$T/C" commit -qam "upgrade to 4.6"; git -C "$T/D" commit -qam "upgrade to 4.7"
git_push_head "$T/C" >/dev/null 2>&1
: > "$T/step.log"
git_push_head "$T/D" && bad "a real conflict was pushed" || ok "two different values for one key: the push fails (GIT_PUSH_FAILED for the caller)"
grep -q "GIT_MERGE_FAILED" "$T/step.log" && grep -q "changed the same value differently" "$T/step.log" && ok "and the log names the file and the reason" || bad "conflict log" "$(cat "$T/step.log")"

# --- the lock
jq -r '.data.holder' "$KCM" | grep -q '^$' && ok "the lock is released after every push" || bad "lock still held" "$(cat "$KCM")"
echo '{"metadata":{"resourceVersion":"50"},"data":{"holder":"other-run","time":"'"$(date +%s)"'"}}' > "$KCM"
# shellcheck disable=SC2034  # read by fleet_lock_acquire
FLEET_LOCK_HELD=0; : > "$T/step.log"
# shellcheck disable=SC2317  # sleep is called by fleet_lock_acquire
( sleep() { jq -c '.data.holder = "" | .metadata.resourceVersion = "51"' "$KCM" > "$KCM.n" && mv "$KCM.n" "$KCM"; }; fleet_lock_acquire ) && ok "a held lock is waited for and taken when released" || bad "lock wait"
echo '{"metadata":{"resourceVersion":"60"},"data":{"holder":"dead-run","time":"1000"}}' > "$KCM"
fleet_lock_acquire && grep -q "took over a stale lock of dead-run" "$T/step.log" && ok "a lock older than 3 minutes is taken over" || bad "stale lock" "$(cat "$T/step.log")"

echo
echo "tests/git-merge: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
