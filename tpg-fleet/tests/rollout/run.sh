#!/usr/bin/env bash
# workflows/scripts/plan-batches.sh: the rolloutMode of tpg-day0 and tpg-upgrade.
#   canary   (default) the wave-0 cluster alone first, then batches of maxParallel per wave
#   batches  no canary: every cluster, by wave, in batches of maxParallel
#   all      one batch with every cluster
# and, with P_PAIRS (tpg-restore, Round 23), the same three modes over the pairs of clusterMap.
# Runs the script with a stub lib.sh (inventory c0 wave 0, c1 and c2 wave 1, c3 wave 2).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
command -v jq >/dev/null || { echo "SKIP tests/rollout: jq not installed" >&2; exit 0; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
cat > "$TMP/lib.sh" <<'LIB'
log() { printf '%s\n' "$*" >&2; }
run_data() { printf '%s' "${INVENTORY_JSON}"; }
record_status() { echo PASSED; }
LIB
sed "s#source /scripts/lib.sh#source $TMP/lib.sh#" "$ROOT/workflows/scripts/plan-batches.sh" > "$TMP/plan.sh"

plan() {  # plan INVENTORY_JSON MAX_PARALLEL MODE -> batches JSON (or ERROR)
  (cd "$TMP" && INVENTORY_JSON="$1" bash "$TMP/plan.sh" wf false "$2" ${3:+"$3"} 2>/dev/null) || { echo ERROR; return; }
  jq -c '.' /tmp/batches.json
}
expect() {  # expect NAME GOT WANT
  if [[ "$2" == "$3" ]]; then printf 'ok   %-44s %s\n' "$1" "$2"; PASS=$((PASS + 1))
  else printf 'FAIL %-44s got %s, expected %s\n' "$1" "$2" "$3"; FAIL=$((FAIL + 1)); fi
}
INV='[{"name":"c0","wave":0},{"name":"c1","wave":1},{"name":"c2","wave":1},{"name":"c3","wave":2}]'
expect "default is canary"               "$(plan "$INV" 2 "")"        '[["c0"],["c1","c2"],["c3"]]'
expect "canary, maxParallel 2"           "$(plan "$INV" 2 canary)"    '[["c0"],["c1","c2"],["c3"]]'
expect "batches, maxParallel 2"          "$(plan "$INV" 2 batches)"   '[["c0","c1"],["c2","c3"]]'
expect "batches, maxParallel 1"          "$(plan "$INV" 1 batches)"   '[["c0"],["c1"],["c2"],["c3"]]'
expect "all: one batch"                  "$(plan "$INV" 1 all)"       '[["c0","c1","c2","c3"]]'
expect "all with no cluster: no batch"   "$(plan '[]' 2 all)"         '[]'
expect "canary without a wave-0 cluster" "$(plan '[{"name":"c1","wave":1},{"name":"c2","wave":1}]' 2 canary)" '[["c1","c2"]]'
expect "an unknown mode fails"           "$(plan "$INV" 2 fast)"      'ERROR'

# ---- tpg-restore (Round 23, phase 6a): the same script batches the normalized pairs of clusterMap
# (P_PAIRS, from the validate step) instead of clusters: canary = the first pair alone, batches = chunks of
# maxParallel in the order of the list (no waves), all = one batch. An item carries what the step needs.
pairs_plan() {  # pairs_plan PAIRS_JSON MAX_PARALLEL MODE -> batches as lists of pair indexes (or ERROR)
  (cd "$TMP" && P_PAIRS="$1" bash "$TMP/plan.sh" wf false "$2" ${3:+"$3"} 2>/dev/null) || { echo ERROR; return; }
  jq -c 'map(map(.index))' /tmp/batches.json
}
mkpairs() {  # mkpairs N -> N normalized pairs (only the fields the batching reads)
  jq -cn --argjson n "$1" '[range(0; $n) | {index: ., method: (if . == 0 then "latest" else "time" end), source: {cluster: "c1", namespace: "pg-a", instance: "a"},
    target: {cluster: ("t" + (. % 2 | tostring)), namespace: "pg-t", instance: ("t" + (. | tostring))}}]'
}
P4="$(mkpairs 4)"
expect "pairs: canary is the first pair alone, then batches of maxParallel" "$(pairs_plan "$P4" 2 canary)" '[[0],[1,2],[3]]'
expect "pairs: batches, maxParallel 2, in list order"                          "$(pairs_plan "$P4" 2 batches)" '[[0,1],[2,3]]'
expect "pairs: batches, maxParallel 1"                                         "$(pairs_plan "$P4" 1 batches)" '[[0],[1],[2],[3]]'
expect "pairs: all is one batch (maxParallel ignored)"                         "$(pairs_plan "$P4" 1 all)" '[[0,1,2,3]]'
expect "pairs: one pair with canary is one batch"                              "$(pairs_plan "$(mkpairs 1)" 2 canary)" '[[0]]'
expect "pairs: no pair, no batch"                                              "$(pairs_plan '[]' 2 all)" '[]'
expect "pairs: an unknown mode fails"                                          "$(pairs_plan "$P4" 2 fast)" 'ERROR'
expect "pairs: a maxParallel that is not a number fails"                       "$(pairs_plan "$P4" x all)" 'ERROR'
(cd "$TMP" && P_PAIRS="$P4" bash "$TMP/plan.sh" wf false 2 canary >/dev/null 2>&1)
expect "pairs: an item carries index, cluster, instance, method and the pair as JSON" \
  "$(jq -c '.[0][0] | [.index, .cluster, .instance, .method, (.pair | fromjson | .target.instance)]' /tmp/batches.json)" '[0,"t0","t0","latest","t0"]'
expect "pairs: has-batches is true" "$(cat /tmp/has-batches)" 'true'
(cd "$TMP" && P_PAIRS='[]' bash "$TMP/plan.sh" wf false 2 all >/dev/null 2>&1)
expect "pairs: has-batches is false without a pair" "$(cat /tmp/has-batches)" 'false'
# without P_PAIRS the script still plans clusters (the inventory above): one script, two item kinds
expect "clusters are still planned when P_PAIRS is empty" "$(P_PAIRS='' plan "$INV" 2 batches)" '[["c0","c1"],["c2","c3"]]'
echo
echo "rollout: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
