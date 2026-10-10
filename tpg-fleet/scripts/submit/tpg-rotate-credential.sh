#!/usr/bin/env bash
# Submit tpg-rotate-credential interactively: mandatory inputs first, then a menu of the
# optional ones, each with its type and an example. See submit-lib.sh.
#   HUB_CONTEXT=<hub kubectl context> [TPG_FLEET_DIR=<tpg-fleet clone>] scripts/submit/tpg-rotate-credential.sh
WF_TEMPLATE=tpg-rotate-credential
WF_TITLE="rotate a credential held in Vault"
TARGETS="none"
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
# a CA bundle file (secretType ca-bundle) is read here and sent in patchFiles (Round 15)
sl_hook_mandatory() { SL_ASKED="${SL_ASKED} patchFiles"; }
sl_hook_check() {
  case "$(sl_val secretType)" in
    ca-bundle|custom) sl_isset secretName || { sl_err "secretType $(sl_val secretType) needs secretName"; return 1; } ;;
  esac
  sl_pack_patch_files
}
sl_main "$@"
