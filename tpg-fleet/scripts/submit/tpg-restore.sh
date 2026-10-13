#!/usr/bin/env bash
# Submit tpg-restore interactively: clusterMap first (a LIST of pairs, one restore each), then a menu of
# the optional inputs, each with its type and an example. See submit-lib.sh.
#   HUB_CONTEXT=<hub kubectl context> [TPG_FLEET_DIR=<tpg-fleet clone>] scripts/submit/tpg-restore.sh
# The pairs are built one by one (or loaded from a file, or pasted); every pair is checked with
# clustermap.py restore as it is added and the whole list again at the end, and the normalized plan of
# each pair (index, method, in place, recovery point, spec file) is printed before anything is
# submitted. This script reads the hub (the registered clusters) and the tpg-fleet clone
# (clusters/fleet.yaml, the restore-specs folder) only: it never talks to a member cluster. What needs
# the clusters (the source backup exists and is Succeeded, the target does not exist, the matrix) is
# checked by the plan step of the workflow, which dryRun=true (the default) runs without changing anything.
# Keys (workflows/params/cluster-map-keys.yaml, section restore):
#   source  sourceBackupName
#   target  pitrEnabled, pitrConfig.type, pitrConfig.target, pitrConfig.timestamp,
#           pitrConfig.sourceBackupConfig.{srcBackupLocationName, srcStanzaName, srcBackupLabel}, bestEffort,
#           targetInstanceSpecFilePath, confirm (in place only), skipMinorVersionCheck, postRestoreBackup
WF_TEMPLATE=tpg-restore
WF_TITLE="restore Postgres instances from a list of pairs"
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

SL_RS_FLEET="${SL_ROOT}/clusters/fleet.yaml"
SL_RS_SPECS="helm_artifacts/instance/tpg-instance/restore-specs"

# ------------------------------------------------------------------ small prompts
sl_rs_ask() {  # sl_rs_ask PROMPT [DEFAULT] -> SL_LINE: a non-empty answer (Enter takes the default); the end of the input stops the script
  while true; do
    printf '  %s%s: ' "$1" "$( [[ -n "${2:-}" ]] && printf ' [Enter: %s]' "$2")" >&2
    IFS= read -r SL_LINE || sl_die "input ended"
    SL_LINE="$(printf '%s' "$SL_LINE" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [[ -n "$SL_LINE" ]] || SL_LINE="${2:-}"
    [[ -z "$SL_LINE" ]] || return 0
    sl_err "  an answer is required"
  done
}
sl_rs_opt() {  # sl_rs_opt PROMPT -> SL_LINE: an optional answer (Enter: none)
  printf '  %s (Enter: none): ' "$1" >&2
  IFS= read -r SL_LINE || sl_die "input ended"
  SL_LINE="$(printf '%s' "$SL_LINE" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
}
sl_rs_cluster() {  # sl_rs_cluster PROMPT -> RS_C: a registered cluster of the hub, or typed
  local reg c opts=()
  reg="$(sl_registered)"
  while IFS= read -r c; do [[ -n "$c" ]] && opts+=("$c"); done <<<"$reg"
  opts+=("(type a cluster name)")
  sl_menu "$1" "${opts[@]}"
  if [[ "$SL_PICK" -eq $((${#opts[@]} - 1)) ]]; then sl_rs_ask "cluster name"; RS_C="$SL_LINE"; else RS_C="${opts[$SL_PICK]}"; fi
}
sl_rs_source_instance() {  # sl_rs_source_instance CLUSTER -> RS_NS RS_INST RS_DECLARED: an instance declared for the cluster in the clone's
  # clusters/fleet.yaml (its namespace: instance.namespace, else pg-<instance>), or a namespace and an instance typed
  local rows opts=() nss=() ins=() i n
  rows="$(C="$1" yq -r '.clusters[strenv(C)].instances // {} | to_entries | .[] | .key + " " + (.value.instance.namespace // ("pg-" + .key))' "$SL_RS_FLEET" 2>/dev/null || true)"
  while read -r i n; do
    [[ -n "$i" ]] || continue
    ins+=("$i"); nss+=("$n"); opts+=("${i} (namespace ${n}, declared in clusters/fleet.yaml)")
  done <<<"$rows"
  opts+=("(type a namespace and an instance name)")
  sl_menu "Source instance on ${1}:" "${opts[@]}"
  if [[ "$SL_PICK" -eq $((${#opts[@]} - 1)) ]]; then
    sl_rs_ask "source namespace"; RS_NS="$SL_LINE"
    sl_rs_ask "source instance"; RS_INST="$SL_LINE"
    RS_DECLARED=0
    for i in ${ins[@]+"${ins[@]}"}; do [[ "$i" == "$RS_INST" ]] && RS_DECLARED=1; done
  else
    RS_INST="${ins[$SL_PICK]}"; RS_NS="${nss[$SL_PICK]}"; RS_DECLARED=1
  fi
}
sl_rs_spec_file() {  # sl_rs_spec_file -> RS_SPEC (a JSON list of one path, or empty): a file of the restore-specs folder of the clone, or of this machine
  local f opts=() paths=()
  for f in "${SL_ROOT}/${SL_RS_SPECS}"/*.yaml "${SL_ROOT}/${SL_RS_SPECS}"/*.yml; do
    [[ -f "$f" ]] || continue
    paths+=("repo:${SL_RS_SPECS}/${f##*/}"); opts+=("repo:${SL_RS_SPECS}/${f##*/} (in the fleet repository)")
  done
  opts+=("(a file of this machine, sent with the run)")
  sl_menu "  Spec file (one kind: Postgres document: its spec is the restored instance's spec):" "${opts[@]}"
  if [[ "$SL_PICK" -eq $((${#opts[@]} - 1)) ]]; then
    sl_rs_ask "path of the file (.yaml or .yml, absolute or relative to this directory)"
    RS_SPEC="$(jq -cn --arg f "$SL_LINE" '[$f]')"
  else
    RS_SPEC="$(jq -cn --arg f "${paths[$SL_PICK]}" '[$f]')"
  fi
}

# ------------------------------------------------------------------ one pair
sl_rs_recovery() {  # sl_rs_recovery -> RS_SRC_KEYS RS_TGT_KEYS (JSON objects): the recovery point
  local typ best loc stz lab sb cfg='{}' keys
  RS_SRC_KEYS='{}'; RS_TGT_KEYS='{}'
  sl_menu "  Recovery point:" "A named backup (pitrEnabled: false)" "Point-in-time recovery (pitrEnabled: true)"
  if [[ "$SL_PICK" -eq 0 ]]; then
    sl_rs_ask "sourceBackupName (a PostgresBackup of ${RS_SI} in ${RS_SNS} on ${RS_SC}; the plan step checks that it exists and is Succeeded)"
    RS_SRC_KEYS="$(jq -cn --arg b "$SL_LINE" '{sourceBackupName: $b}')"
    RS_TGT_KEYS='{"pitrEnabled": false}'
    return 0
  fi
  sl_menu "  pitrConfig.type:" "latest (the newest WAL)" "time (a UTC time)" "lsn (a log sequence number)" "transaction (a transaction ID)"
  case "$SL_PICK" in 0) typ=latest ;; 1) typ="time" ;; 2) typ=lsn ;; *) typ=transaction ;; esac
  cfg="$(jq -cn --arg t "$typ" '{type: $t}')"
  case "$typ" in
    time) sl_rs_ask "pitrConfig.timestamp (UTC, such as 2026-09-15T08:30:00Z)"; cfg="$(jq -c --arg v "$SL_LINE" '. + {timestamp: $v}' <<<"$cfg")" ;;
    lsn) sl_rs_ask "pitrConfig.target (a log sequence number such as 0/3000060)"; cfg="$(jq -c --arg v "$SL_LINE" '. + {target: $v}' <<<"$cfg")" ;;
    transaction) sl_rs_ask "pitrConfig.target (a transaction ID, a number)"; cfg="$(jq -c --arg v "$SL_LINE" '. + {target: $v}' <<<"$cfg")" ;;
  esac
  keys='{"pitrEnabled": true}'
  if [[ "$typ" != latest ]]; then
    sl_menu "  bestEffort (true: recover as far as the WAL allows when the point is not reached; false: fail instead):" true false
    best=true; [[ "$SL_PICK" -eq 0 ]] || best=false
    keys="$(jq -c --argjson b "$best" '. + {bestEffort: $b}' <<<"$keys")"
  fi
  # the backup repository is derived from the source instance; name it when the source instance is gone or differs
  if sl_yes "  Name the backup repository (location, stanza, backup set) instead of deriving it from the source instance?" n; then
    sl_rs_opt "srcBackupLocationName (the PostgresBackupLocation that holds the backups)"; loc="$SL_LINE"
    sl_rs_opt "srcStanzaName (as pgbackrest info shows it)"; stz="$SL_LINE"
    lab=""
    if [[ "$typ" != latest ]]; then sl_rs_opt "srcBackupLabel (the pgBackRest backup to start from, such as 20260915-020000F)"; lab="$SL_LINE"; fi
    cfg="$(jq -c --arg l "$loc" --arg s "$stz" --arg b "$lab" '. + {sourceBackupConfig: (
      (if $l != "" then {srcBackupLocationName: $l} else {} end) + (if $s != "" then {srcStanzaName: $s} else {} end)
      + (if $b != "" then {srcBackupLabel: $b} else {} end))} | if .sourceBackupConfig == {} then del(.sourceBackupConfig) else . end' <<<"$cfg")"
  fi
  RS_TGT_KEYS="$(jq -c --argjson c "$cfg" '. + {pitrConfig: $c}' <<<"$keys")"
  # a backup of the source gives location and stanza when the source instance is gone
  sl_rs_opt "sourceBackupName (only to derive the repository when the source instance is gone)"; sb="$SL_LINE"
  [[ -z "$sb" ]] || RS_SRC_KEYS="$(jq -cn --arg b "$sb" '{sourceBackupName: $b}')"
}
sl_rs_pair() {  # sl_rs_pair -> SL_PAIR (the pair as JSON; sl_rs_build checks it)
  local in_place=0 sp=0
  sl_say ""
  sl_rs_cluster "Source cluster (the instance to restore from):"; RS_SC="$RS_C"
  sl_rs_source_instance "$RS_SC"; RS_SNS="$RS_NS"; RS_SI="$RS_INST"; RS_SRC_DECLARED="$RS_DECLARED"
  sl_rs_recovery
  sl_say "  Target (where the restored instance runs; the source's own cluster, namespace and instance restore it in place):"
  sl_rs_cluster "Target cluster:"; RS_TC="$RS_C"
  sl_rs_ask "target namespace" "$RS_SNS"; RS_TNS="$SL_LINE"
  sl_rs_ask "target instance"; RS_TI="$SL_LINE"
  if [[ "$RS_TC" == "$RS_SC" && "$RS_TNS" == "$RS_SNS" && "$RS_TI" == "$RS_SI" ]]; then
    in_place=1
    sl_err "  This restores ${RS_TC}/${RS_TNS}/${RS_TI} IN PLACE: its data is overwritten."
    sl_say "  It needs clusters.${RS_TC}.cluster.allowInPlaceRestore: true in clusters/fleet.yaml (the validate step refuses the whole run otherwise)."
    if [[ "$(C="$RS_TC" yq -r '.clusters[strenv(C)].cluster.allowInPlaceRestore // false' "$SL_RS_FLEET" 2>/dev/null || echo false)" != true ]]; then
      sl_err "  Your clone's clusters/fleet.yaml does not set it for ${RS_TC}."
    fi
    while true; do
      sl_rs_ask "confirm: repeat the target instance name (${RS_TI})"
      [[ "$SL_LINE" == "$RS_TI" ]] && break
      sl_err "  '${SL_LINE}' is not ${RS_TI}"
    done
    RS_TGT_KEYS="$(jq -c --arg c "$RS_TI" '. + {confirm: $c}' <<<"$RS_TGT_KEYS")"
  fi
  # the spec file: mandatory for a new instance whose source is not declared in clusters/fleet.yaml, otherwise optional
  RS_SPEC=""
  if [[ "$in_place" -eq 0 && "$RS_SRC_DECLARED" -eq 0 ]]; then
    sl_say "  ${RS_SC}/${RS_SI} is not declared in clusters/fleet.yaml, so there is no entry to copy for the new instance: a spec file is mandatory."
    sp=1
  elif sl_yes "  Give a spec file for the restored instance (targetInstanceSpecFilePath)? Without one the operator fills in the spec of a new instance." n; then sp=1; fi
  if [[ "$sp" -eq 1 ]]; then
    sl_rs_spec_file
    RS_TGT_KEYS="$(jq -c --argjson f "$RS_SPEC" '. + {targetInstanceSpecFilePath: $f}' <<<"$RS_TGT_KEYS")"
  fi
  sl_yes "  skipMinorVersionCheck (only for backups taken by operator v4.2.2 or older; sets the operator's annotation)?" n \
    && RS_TGT_KEYS="$(jq -c '. + {skipMinorVersionCheck: true}' <<<"$RS_TGT_KEYS")"
  sl_yes "  postRestoreBackup (a full backup once the restored instance runs)?" n \
    && RS_TGT_KEYS="$(jq -c '. + {postRestoreBackup: true}' <<<"$RS_TGT_KEYS")"
  SL_PAIR="$(jq -cn --arg sc "$RS_SC" --arg sns "$RS_SNS" --arg si "$RS_SI" --argjson sk "$RS_SRC_KEYS" \
    --arg tc "$RS_TC" --arg tns "$RS_TNS" --arg ti "$RS_TI" --argjson tk "$RS_TGT_KEYS" \
    '{sourceClusterConfig: {($sc): {($sns): {($si): $sk}}}, targetClusterConfig: {($tc): {($tns): {($ti): $tk}}}}')"
}

# ------------------------------------------------------------------ the plan of each pair
sl_rs_plan() {  # sl_rs_plan [FIRST_INDEX]: the normalized plan of each pair, from the pairs clustermap.py restore wrote (sl_map_validate)
  [[ -s "$SL_TMP/pairs.json" ]] || return 0
  jq -r --argjson from "${1:-0}" '
    def how: if .inPlace then "IN PLACE (the data of the source instance is overwritten)"
      elif .sameNamespace then "a new instance in the source namespace"
      elif .sameCluster then "a new instance in another namespace of the same cluster (the source backup location is copied there)"
      else "a new instance on another cluster (the source backup location is copied there)" end;
    def point: if .method == "backup" then "named backup \(.source.backupName)"
      elif .method == "latest" then "point-in-time recovery to the latest WAL"
      elif .method == "time" then "point-in-time recovery to \(.pitr.timestamp), bestEffort \(.pitr.bestEffort)"
      elif .method == "lsn" then "point-in-time recovery to LSN \(.pitr.target), bestEffort \(.pitr.bestEffort)"
      else "point-in-time recovery to transaction \(.pitr.target), bestEffort \(.pitr.bestEffort)" end;
    def repo: if .pitr.enabled then
        "backup repository: " + (if .pitr.backupLocation != "" then "location \(.pitr.backupLocation)" else "location derived" end)
        + ", " + (if .pitr.stanza != "" then "stanza \(.pitr.stanza)" else "stanza derived" end)
        + (if .pitr.backupLabel != "" then ", backup set \(.pitr.backupLabel)" else "" end)
        + (if .source.backupName != "" then " (a source backup, \(.source.backupName), can give them when the source instance is gone)" else "" end)
      else empty end;
    .[] | select(.index >= $from)
    | "  [\(.index)] \(.label)",
      "      method:    \(.method)  (\(point))",
      "      in place:  \(if .inPlace then "yes" else "no" end)  (\(how))",
      (repo | "      " + .),
      "      spec file: \(if .target.specFile != "" then .target.specFile elif .inPlace then "none (the PostgresRestore sends only the instance name; the instance keeps its spec)" else "none (a new instance copies the source entry of clusters/fleet.yaml; the operator fills in its spec)" end)",
      (if .target.confirm != "" then "      confirm:   \(.target.confirm)" else empty end),
      (if .target.skipMinorVersionCheck then "      skipMinorVersionCheck: true" else empty end),
      (if .target.postRestoreBackup then "      postRestoreBackup: true" else empty end)' "$SL_TMP/pairs.json" >&2
}

# ------------------------------------------------------------------ clusterMap
sl_rs_build() {  # the guided builder -> SL_LINE (the list of pairs as JSON), pair by pair
  local pairs='[]' n=0 try
  while true; do
    sl_rs_pair
    try="$(jq -c --argjson p "$SL_PAIR" '. + [$p]' <<<"$pairs")"
    if sl_map_validate "$try"; then
      pairs="$try"; n=$((n + 1))
      sl_ok "pair ${n} added; its plan:"
      sl_rs_plan $((n - 1))
    else
      if sl_yes "That pair is not valid. Enter it again?" y; then continue; fi
      [[ "$n" -gt 0 ]] || { sl_say "no pair yet: a restore needs at least one"; continue; }
      sl_say "that pair is left out"
    fi
    sl_menu "${n} pair(s) so far:" "Add another pair" "Done"
    [[ "$SL_PICK" -eq 1 ]] && break
  done
  SL_LINE="$pairs"
}
sl_rs_read_pairs() {  # the pairs from a file, or pasted -> SL_LINE (JSON list)
  local lines=() l j
  sl_menu "How do you want to give the pairs?" "Type or paste them on one line (YAML flow or JSON list)" \
    "Paste several lines of YAML or JSON (end with a line that says END)" "Read them from a file"
  case "$SL_PICK" in
    0) sl_read "  clusterMap: " ;;
    1) sl_say "  paste now; finish with a line END"
       while IFS= read -r l; do [[ "$l" == "END" ]] && break; lines+=("$l"); done
       SL_LINE="$(printf '%s\n' ${lines[@]+"${lines[@]}"})" ;;
    2) sl_read "  file path: "
       [[ -f "$SL_LINE" ]] || { sl_err "  ${SL_LINE}: not a file"; SL_LINE=""; return 1; }
       SL_LINE="$(cat "$SL_LINE")" ;;
  esac
  [[ -n "$(tr -d '[:space:]' <<<"$SL_LINE")" ]] || { SL_LINE=""; return 1; }
  # normalize to compact JSON: a LIST of pairs (the clusterMap of the other workflows is a mapping)
  if ! j="$(printf '%s\n' "$SL_LINE" | yq -o=json -I=0 '.' 2>/dev/null)" || [[ "${j:0:1}" != "[" ]]; then
    sl_err "  not a YAML or JSON list of pairs: - {sourceClusterConfig: ..., targetClusterConfig: ...}"; SL_LINE=""; return 1
  fi
  SL_LINE="$j"
}
sl_clustermap() {  # -> SL_LINE, 1 to ask again
  sl_menu "clusterMap (a list of pairs, section 16 of docs/workflow-commands.md):" "Build the pairs step by step (source, recovery point, target)" \
    "Load them from a YAML or JSON file" "Paste or type them"
  case "$SL_PICK" in
    0) sl_rs_build ;;
    1) sl_read "  file path: "; [[ -f "$SL_LINE" ]] || { sl_err "  not a file"; return 1; }
       SL_LINE="$(yq -o=json -I=0 '.' "$SL_LINE" 2>/dev/null)" || { sl_err "  not YAML or JSON"; return 1; }
       [[ "${SL_LINE:0:1}" == "[" ]] || { sl_err "  not a list of pairs: - {sourceClusterConfig: ..., targetClusterConfig: ...}"; return 1; } ;;
    2) sl_rs_read_pairs || return 1 ;;
  esac
  [[ -n "$SL_LINE" ]] || return 1
  if sl_map_validate "$SL_LINE"; then
    sl_say ""; sl_say "The pairs, as the workflow will read them:"; sl_rs_plan 0
  else
    sl_yes "Keep it anyway (the workflow's validate step decides)?" n || return 1
  fi
  return 0
}
# local spec files are read here and sent in patchFiles; the plan of every pair is shown again just before the submit menu
sl_hook_mandatory() { SL_ASKED="${SL_ASKED} patchFiles"; }
sl_hook_check() {
  if sl_isset clusterMap && sl_map_validate "$(sl_val clusterMap)" 2>/dev/null; then
    sl_say ""; sl_say "Each pair, as the workflow will plan it (dryRun $(sl_isset dryRun && sl_val dryRun || echo "true, the default")):"; sl_rs_plan 0
  fi
  sl_pack_patch_files
}
sl_main "$@"
