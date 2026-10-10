#!/usr/bin/env bash
# Submit tpg-restore interactively: mandatory inputs first, then a menu of the
# optional ones, each with its type and an example. See submit-lib.sh.
#   HUB_CONTEXT=<hub kubectl context> [TPG_FLEET_DIR=<tpg-fleet clone>] scripts/submit/tpg-restore.sh
WF_TEMPLATE=tpg-restore
WF_TITLE="restore a Postgres instance"
TARGETS="none"
TARGET_LISTS=""
MANDATORY="sourceCluster instance mode"
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
# The recovery point depends on the mode
sl_hook_mandatory() {
  case "$(sl_val mode)" in
    time) sl_prompt targetTime mandatory; SL_ASKED="${SL_ASKED} targetTime" ;;
    backup) sl_prompt backupName mandatory; sl_prompt targetInstance mandatory; sl_prompt confirm mandatory
            SL_ASKED="${SL_ASKED} backupName targetInstance confirm" ;;
    lsn) sl_prompt lsn mandatory; SL_ASKED="${SL_ASKED} lsn" ;;
    xid) sl_prompt xid mandatory; SL_ASKED="${SL_ASKED} xid" ;;
  esac
}
sl_main "$@"
