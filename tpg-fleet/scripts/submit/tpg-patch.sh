#!/usr/bin/env bash
# Submit tpg-patch interactively: mandatory inputs first, then a menu of the
# optional ones, each with its type and an example. See submit-lib.sh.
#   HUB_CONTEXT=<hub kubectl context> [TPG_FLEET_DIR=<tpg-fleet clone>] scripts/submit/tpg-patch.sh
# Patch files are paths of this machine (absolute, ~/ or relative to the current
# directory; their contents are read here and sent in patchFiles), or repo:<path>
# in the fleet repository (Round 15).
WF_TEMPLATE=tpg-patch
WF_TITLE="patch operators and instances with files from this machine"
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
# patchFiles is filled from the files, never typed
sl_hook_mandatory() { SL_ASKED="${SL_ASKED} patchFiles"; }
# Without clusterMap: patchMode apply needs a patch file input (instance files also
# need instances); patchMode clear needs clearKinds and takes no files
sl_hook_check() {
  if [[ "${SL_MAP:-0}" -eq 0 ]]; then
    local f any=0
    for f in postgresPatchFilePath postgresValuesPatchFilePath operatorValuesPatchFilePath; do
      sl_isset "$f" && any=1
    done
    if [[ "$(sl_val patchMode)" == clear ]]; then
      if [[ "$any" -eq 1 ]]; then sl_err "patchMode=clear takes no patch files: clearKinds names the kinds to remove"; return 1; fi
      if ! sl_isset clearKinds; then sl_err "patchMode=clear needs clearKinds (for example PostgresBackupLocation, postgresValues, or all)"; return 1; fi
      return 0
    fi
    if [[ "$any" -eq 0 ]]; then sl_err "choose at least one patch file input (postgresPatchFilePath, postgresValuesPatchFilePath or operatorValuesPatchFilePath)"; return 1; fi
    if { sl_isset postgresPatchFilePath || sl_isset postgresValuesPatchFilePath; } && ! sl_isset instances; then
      sl_err "instance patch files need the instances input"; return 1
    fi
  fi
  sl_pack_patch_files
}
sl_main "$@"
