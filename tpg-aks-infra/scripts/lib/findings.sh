#!/usr/bin/env bash
# Findings of scripts/steps/60-verify.sh and the summary printed at its end.
# Source after common.sh. Kept apart so tests/verify can exercise the summary
# without a cluster.
#
# CUR is the cluster a finding belongs to: the hub in the hub section, the
# target in the target loop (also for its objects on the hub, such as the Argo
# CD cluster Secret). The resource key is the check description with that
# cluster's name replaced by <cluster>, so one resource failing on three
# clusters is one summary entry listing the three clusters.
# shellcheck disable=SC2034
: "${CUR:=}"
FAILED="${FAILED:-0}"
declare -a ISSUE_KEYS=() WARN_KEYS=()
declare -A ISSUE_CLUSTERS=() ISSUE_WHY=() WARN_CLUSTERS=() WARN_WHY=()
_finding() {  # _finding ISSUE|WARN DESC WHY
  local kind="$1" key="${2//$CUR/<cluster>}" why="${3//$CUR/<cluster>}"
  if [[ "$kind" == ISSUE ]]; then
    [[ -n "${ISSUE_CLUSTERS[$key]+x}" ]] || { ISSUE_KEYS+=("$key"); ISSUE_CLUSTERS[$key]=""; }
    [[ " ${ISSUE_CLUSTERS[$key]} " == *" $CUR "* ]] || ISSUE_CLUSTERS[$key]+=" $CUR"
    ISSUE_WHY["$key|$CUR"]="$why"
    FAILED=1
  else
    [[ -n "${WARN_CLUSTERS[$key]+x}" ]] || { WARN_KEYS+=("$key"); WARN_CLUSTERS[$key]=""; }
    [[ " ${WARN_CLUSTERS[$key]} " == *" $CUR "* ]] || WARN_CLUSTERS[$key]+=" $CUR"
    WARN_WHY["$key|$CUR"]="$why"
  fi
}
# issue DESC WHY: a failed check (printed now, listed in the summary, exit 1)
issue() { warn "${1}: ${2}"; _finding ISSUE "$1" "$2"; }
# advisory DESC WHY: printed now and listed under WARNINGS; does not fail the run
advisory() { warn "${1}: ${2}"; _finding WARN "$1" "$2"; }

_summary_block() {  # _summary_block ISSUE|WARN
  local kind="$1" key c n=0 why first same line shown
  local -a keys=() cl=()
  if [[ "$kind" == ISSUE ]]; then keys=("${ISSUE_KEYS[@]}"); else keys=("${WARN_KEYS[@]}"); fi
  for key in "${keys[@]}"; do
    n=$((n + 1))
    if [[ "$kind" == ISSUE ]]; then read -r -a cl <<<"${ISSUE_CLUSTERS[$key]}"; else read -r -a cl <<<"${WARN_CLUSTERS[$key]}"; fi
    # One cluster: its name goes back into the description; several: <cluster> stays
    shown="$key"
    [[ "${#cl[@]}" -ne 1 ]] || shown="${key//<cluster>/${cl[0]}}"
    printf '  %2d. %s\n      clusters: %s\n' "$n" "$shown" "$(IFS=,; printf '%s' "${cl[*]}" | sed 's/,/, /g')"
    first=""; same=1
    for c in "${cl[@]}"; do
      if [[ "$kind" == ISSUE ]]; then why="${ISSUE_WHY[$key|$c]}"; else why="${WARN_WHY[$key|$c]}"; fi
      [[ -n "$first" ]] || first="$why"
      [[ "$why" == "$first" ]] || same=0
    done
    if [[ "$same" -eq 1 ]]; then
      if [[ "${#cl[@]}" -eq 1 ]]; then line="${first//<cluster>/${cl[0]}}"
      else line="${first//<cluster>/each cluster listed}"; fi
      printf '      %s\n' "$line"
    else
      for c in "${cl[@]}"; do
        if [[ "$kind" == ISSUE ]]; then why="${ISSUE_WHY[$key|$c]}"; else why="${WARN_WHY[$key|$c]}"; fi
        printf '      %s: %s\n' "$c" "${why//<cluster>/$c}"
      done
    fi
  done
}

print_summary() {
  local ntargets
  ntargets="$(target_names | wc -l | tr -d ' ')"
  printf '\n\033[1m==================== verify summary ====================\033[0m\n'
  if [[ "${#ISSUE_KEYS[@]}" -gt 0 ]]; then
    printf '\033[1;31mISSUES (%d)\033[0m resources that are missing or wrong, and where:\n' "${#ISSUE_KEYS[@]}"
    _summary_block ISSUE
  fi
  if [[ "${#WARN_KEYS[@]}" -gt 0 ]]; then
    printf '\033[1;33mWARNINGS (%d)\033[0m advisory, the run does not fail on these:\n' "${#WARN_KEYS[@]}"
    _summary_block WARN
  fi
  if [[ "$FAILED" -eq 0 ]]; then
    printf '\033[1;32mAll checks passed\033[0m on the hub %s and %s target cluster(s)%s.\n' "$HUB" "$ntargets" \
      "$( [[ "${#WARN_KEYS[@]}" -gt 0 ]] && printf ' (%d warning(s) above)' "${#WARN_KEYS[@]}")"
  else
    printf '\n'
    die "verify found ${#ISSUE_KEYS[@]} issue(s); fix them and re-run: scripts/run.sh ... --only verify"
  fi
}

