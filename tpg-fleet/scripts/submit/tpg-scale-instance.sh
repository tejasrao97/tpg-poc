#!/usr/bin/env bash
# Submit tpg-scale-instance interactively: mandatory inputs first, then a menu of the
# optional ones, each with its type and an example. See submit-lib.sh.
#   HUB_CONTEXT=<hub kubectl context> [TPG_FLEET_DIR=<tpg-fleet clone>] scripts/submit/tpg-scale-instance.sh
# Without clusterMap a run scales instances (instances and replicas), changes only
# the cap of the clusters (maxReadReplicas), or both (Round 14).
# clusterMap example (the guided builder asks for the same keys):
#   {aks-tpg-poc-01: {maxReadReplicas: 4, instances: {orders-db: {replicas: 3}, billing-db: {replicas: 0}}},
#    aks-tpg-poc-02: {instances: {reporting-db: {replicas: 1, enableHAIfNeeded: false}}},
#    aks-tpg-poc-03: {maxReadReplicas: 2}}
WF_TEMPLATE=tpg-scale-instance
WF_TITLE="scale the read replicas of Postgres instances"
TARGETS="map-or-lists"
TARGET_LISTS="clusters"
MANDATORY="pushMode"
MANDATORY_WITHOUT_MAP=""
# the tpg-fleet clone: TPG_FLEET_DIR, else the clone this script sits in (links followed)
tpg_submit_lib() {
  local s="$0" d
  if [[ -n "${TPG_FLEET_DIR:-}" ]]; then d="$TPG_FLEET_DIR"
  else
    while [[ -L "$s" ]]; do d="$(cd "$(dirname "$s")" && pwd)"; s="$(readlink "$s")"; [[ "$s" == /* ]] || s="$d/$s"; done
    d="$(cd "$(dirname "$s")/../.." 2>/dev/null && pwd)"
  fi
  if [[ ! -f "$d/scripts/submit/submit-lib.sh" || ! -f "$d/workflows/params/types.yaml" ]]; then
    echo "no tpg-fleet clone found$( [[ -n "${TPG_FLEET_DIR:-}" ]] && printf ' at TPG_FLEET_DIR=%s' "$TPG_FLEET_DIR" ): set TPG_FLEET_DIR to your tpg-fleet clone (this script reads its templates, types and checks)" >&2
    exit 1
  fi
  printf '%s/scripts/submit/submit-lib.sh' "$d"
}
TPG_SUBMIT_LIB="$(tpg_submit_lib)" || exit 1
# shellcheck source=scripts/submit/submit-lib.sh
source "$TPG_SUBMIT_LIB"
sl_hook_mandatory() {
  [[ "${SL_MAP:-0}" -eq 1 ]] && return 0
  sl_menu "What does this run change on ${WF_TEMPLATE}?" \
    "Scale instances (instances and replicas)" \
    "Only the cap of the clusters (maxReadReplicas)" \
    "Both"
  case "$SL_PICK" in
    0) sl_prompt instances mandatory; sl_prompt replicas mandatory; SL_ASKED="${SL_ASKED} instances replicas" ;;
    1) sl_prompt maxReadReplicas mandatory; SL_ASKED="${SL_ASKED} instances replicas maxReadReplicas" ;;
    2) sl_prompt instances mandatory; sl_prompt replicas mandatory; sl_prompt maxReadReplicas mandatory
       SL_ASKED="${SL_ASKED} instances replicas maxReadReplicas" ;;
  esac
}
# Without clusterMap: instances need replicas, and a run needs instances or maxReadReplicas
sl_hook_check() {
  [[ "${SL_MAP:-0}" -eq 1 ]] && return 0
  if sl_isset instances && ! sl_isset replicas; then sl_err "instances need replicas"; return 1; fi
  if sl_isset replicas && ! sl_isset instances; then sl_err "replicas needs instances"; return 1; fi
  if ! sl_isset instances && ! sl_isset maxReadReplicas; then
    sl_err "set instances and replicas, or maxReadReplicas, or both"; return 1
  fi
  return 0
}
sl_main "$@"
