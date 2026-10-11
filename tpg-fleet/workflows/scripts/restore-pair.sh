#!/usr/bin/env bash
# restore-pair.sh WORKFLOW_NAME
# Restore one pair of the clusterMap of tpg-restore (Round 23, locked decision 7). The pair comes from
# the environment as the normalized JSON object that clustermap.py restore writes (fields in the header
# of clustermap.py; the plan-batches step hands it over whole):
#   P_PAIR                   the pair
#   P_DRY_RUN                true (default): record the plan and change nothing; false: restore
#   P_PUSH_MODE              direct | pr, for the clusters/fleet.yaml entry of a new target
#   P_KEEP_SOURCE_LOCATION   true (default): keep the copy of the source backup location in the target namespace
#   P_TIMEOUT, P_PR_TIMEOUT  seconds to wait for the restore, and for a pull request
#
# STUB of phase 6a: it makes the template, the validation and the batching testable end to end. It
# records the planned pair as SKIPPED (reason PENDING_6B) and changes nothing, whatever dryRun says.
# Phase 6b replaces the body: it resolves the source (instance or backup; stanza, location, version and
# flavour), checks the matrix (RESTORE_FLAVOUR_UNSUPPORTED, RESTORE_VERSION_LOWER) and the in-place
# rule (clusters.<cluster>.cluster.allowInPlaceRestore in clusters/fleet.yaml, default false, with
# confirm), prepares the target (namespace, fleet entry, backup location and its Secret), renders the
# PostgresRestore, stops there for a dry run, and otherwise applies it and waits for the restore and for
# the instance to run. The result key stays result.<target cluster>.<target instance>.
WF="$1"
# shellcheck source=workflows/scripts/lib.sh
source /scripts/lib.sh

PAIR="${P_PAIR:-}"
jq -e 'type == "object" and (.target.cluster | type == "string") and (.target.instance | type == "string")' <<<"$PAIR" >/dev/null 2>&1 \
  || { record result.restore FAILED INVALID_PAIR "P_PAIR is not a normalized pair: ${PAIR:0:200}"; exit 1; }
key="result.$(jq -r '.target.cluster + "." + .target.instance' <<<"$PAIR")"
result_guard "$key"
DRY="${P_DRY_RUN:-true}"
record "$key" SKIPPED PENDING_6B "$(jq -r '"pair \(.index): \(.label) (\(.method))"' <<<"$PAIR"); dryRun=${DRY}: restore-pair.sh is a stub, nothing was changed"
