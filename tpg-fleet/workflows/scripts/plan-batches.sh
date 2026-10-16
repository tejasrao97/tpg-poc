#!/usr/bin/env bash
# plan-batches.sh WORKFLOW_NAME REQUIRE_PRECHECK MAX_PARALLEL [ROLLOUT_MODE]
# ROLLOUT_MODE
#   canary   (default) wave 0 clusters run one at a time first; later waves run
#            in batches of MAX_PARALLEL, wave by wave
#   batches  no canary: every cluster, ordered by wave, in batches of MAX_PARALLEL
#   all      one batch with every selected cluster at once (waves and
#            MAX_PARALLEL ignored; the template's parallelism still caps how
#            many clusters run at the same time)
# With REQUIRE_PRECHECK=true only PASSED or MANAGED clusters are planned.
# P_PAIRS (tpg-restore, Round 23): the normalized pairs of clusterMap as a JSON array
# (/tmp/pairs.json of validate-params.sh restore). The script then plans the pairs, not the
# clusters (REQUIRE_PRECHECK is ignored: there is no pre-check, and waves do not apply): the
# modes mean canary = the first pair alone, then batches of MAX_PARALLEL; batches = chunks of
# MAX_PARALLEL in the order of the list; all = one batch. A batch is a list of items
#   {index, cluster, namespace, instance, method, pair}   cluster, namespace and instance: the target (the
#   restore step holds a mutex per target cluster and namespace); pair: the normalized pair as base64 of
#   its JSON, which restore-pair.sh decodes. Not JSON text: Argo puts the JSON-escaped text of an item
#   field into {{item.pair}}, a backslash before every quote, which is not JSON. Base64 has none.
# Outputs /tmp/batches.json and /tmp/has-batches.
WF="$1"; REQUIRE="$2"; MAXP="$3"; MODE="${4:-canary}"
# shellcheck source=workflows/scripts/lib.sh
source /scripts/lib.sh

[[ "$MAXP" =~ ^[1-9][0-9]*$ ]] || { log "maxParallel must be a positive integer"; exit 1; }
case "$MODE" in canary|batches|all) ;; *) log "rolloutMode must be canary, batches or all (got ${MODE})"; exit 1 ;; esac

if [[ -n "${P_PAIRS:-}" ]]; then
  jq -c --argjson n "$MAXP" --arg mode "$MODE" '
    def chunks($size): [range(0; length; $size) as $i | .[$i:($i + $size)]];
    map({index, cluster: .target.cluster, namespace: .target.namespace, instance: .target.instance, method, pair: (tojson | @base64)})
    | if $mode == "all" then (if length > 0 then [.] else [] end)
      elif $mode == "batches" then chunks($n)
      else (if length > 0 then [.[0:1]] + (.[1:] | chunks($n)) else [] end) end
  ' <<<"$P_PAIRS" > /tmp/batches.json
  if [[ "$(jq 'length' /tmp/batches.json)" -gt 0 ]]; then echo true > /tmp/has-batches; else echo false > /tmp/has-batches; fi
  log "rolloutMode ${MODE}, pairs in batches: $(jq -c 'map(map(.index))' /tmp/batches.json)"
  exit 0
fi

inv="$(run_data inventory)"
[[ -n "$inv" ]] || inv="[]"

eligible="[]"
for c in $(jq -r '.[].name' <<<"$inv"); do
  if [[ "$REQUIRE" == "true" ]]; then
    s="$(record_status "precheck.${c}")"
    [[ "$s" == "PASSED" || "$s" == "MANAGED" ]] || { log "skipping ${c} (precheck ${s:-missing})"; continue; }
  fi
  eligible="$(jq -c --argjson inv "$inv" --arg c "$c" '. + [$inv[] | select(.name == $c)]' <<<"$eligible")"
done

jq -c --argjson n "$MAXP" --arg mode "$MODE" '
  def chunks($size): [range(0; length; $size) as $i | .[$i:($i + $size)]];
  if $mode == "all" then
    (if length > 0 then [map(.name)] else [] end)
  elif $mode == "batches" then
    (sort_by(.wave) | map(.name) | chunks($n))
  else
    (map(select(.wave == 0)) | map([.name])) as $canary
    | (map(select(.wave != 0)) | sort_by(.wave) | group_by(.wave)
       | map(map(.name) | chunks($n)) | add // []) as $rest
    | $canary + $rest
  end
' <<<"$eligible" > /tmp/batches.json

if [[ "$(jq 'length' /tmp/batches.json)" -gt 0 ]]; then echo true > /tmp/has-batches; else echo false > /tmp/has-batches; fi
log "rolloutMode ${MODE}, batches: $(cat /tmp/batches.json)"
