#!/usr/bin/env bash
# fleet-merge3.sh BASE OURS THEIRS OUT: three-way merge of YAML files key by key (Round 22).
# BASE is the file where OURS and THEIRS diverged. A key changed on one side only takes that
# side's value (a deleted key stays deleted); a key changed on both sides must have the same
# value, or the merge fails (exit 1) and OUT is not written. Maps are merged recursively; lists
# and scalars are values. Needs yq (mikefarah) and jq, as the other workflow scripts.
set -euo pipefail
[[ $# -eq 4 ]] || { echo "usage: fleet-merge3.sh BASE OURS THEIRS OUT" >&2; exit 2; }
b="$(yq -o=json -I=0 '.' "$1")"; o="$(yq -o=json -I=0 '.' "$2")"; t="$(yq -o=json -I=0 '.' "$3")"
merged="$(jq -n --argjson b "$b" --argjson o "$o" --argjson t "$t" '
  def A: "\u0000absent";
  def m3($b; $o; $t):
    if $o == $t then $o
    elif $o == $b then $t
    elif $t == $b then $o
    elif ($o | type) == "object" and ($t | type) == "object" then
      (if ($b | type) == "object" then $b else {} end) as $bb
      | reduce (($bb | keys) + ($o | keys) + ($t | keys) | unique[]) as $k ({};
          m3(($bb | if has($k) then .[$k] else A end);
             ($o | if has($k) then .[$k] else A end);
             ($t | if has($k) then .[$k] else A end)) as $v
          | if $v == A then . else .[$k] = $v end)
    else error("conflict")
    end;
  m3($b; $o; $t)' 2>/dev/null)" || exit 1
printf '%s\n' "$merged" | yq -P '.' > "$4"
