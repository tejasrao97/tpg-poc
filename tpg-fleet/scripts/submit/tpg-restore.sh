#!/usr/bin/env bash
# Submit tpg-restore interactively: mandatory inputs first, then a menu of the
# optional ones, each with its type and an example. See submit-lib.sh.
#   HUB_CONTEXT=<hub kubectl context> [TPG_FLEET_DIR=<tpg-fleet clone>] scripts/submit/tpg-restore.sh
WF_TEMPLATE=tpg-restore
WF_TITLE="restore a Postgres instance"
TARGETS="map"
TARGET_LISTS=""
MANDATORY=""
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
# clusterMap is a list of pairs (Round 23), not a map of clusters: it is loaded from a file or pasted
# (the step-by-step builder of the other workflows does not apply). Phase 6c rewrites this script.
sl_clustermap() {  # -> SL_LINE, 1 to ask again
  sl_menu "clusterMap (a list of pairs, section 15 of docs/workflow-commands.md):" "Load it from a YAML or JSON file" "Paste or type it"
  case "$SL_PICK" in
    0) sl_read "  file path: "; [[ -f "$SL_LINE" ]] || { sl_err "  not a file"; return 1; }
       SL_LINE="$(yq -o=json -I=0 '.' "$SL_LINE" 2>/dev/null)" || { sl_err "  not YAML or JSON"; return 1; } ;;
    1) sl_read_map clusterMap || return 1 ;;
  esac
  [[ -n "$SL_LINE" ]] || return 1
  sl_map_validate "$SL_LINE" || { sl_yes "Keep it anyway (the workflow's validate step decides)?" n || return 1; }
  return 0
}
sl_main "$@"
