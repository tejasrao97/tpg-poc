#!/usr/bin/env bash
# pack-patch-files.sh [-o PARAMETER_FILE] [FILE...]
# The patchFiles input of tpg-patch, tpg-create-instance, tpg-day0 and
# tpg-rotate-credential (Round 14;
# Round 15, design decision D83): {"<path as given>": "<base64 of the file>"}. The
# workflow runs on the hub and cannot read files of this machine, so the contents
# travel in the Workflow. Files of the fleet repository (repo:<path>) are read by the
# workflow itself and are never packed.
#
#   -o PARAMETER_FILE without FILE (the usual way):
#       reads every local path the parameter file names - the inputs
#       postgresPatchFilePath (a list), postgresValuesPatchFilePath,
#       operatorValuesPatchFilePath (tpg-patch) and postgresOverlayFilePath,
#       postgresValuesOverlayFilePath, operatorValuesOverlayFilePath (tpg-day0,
#       tpg-create-instance; Round 22), backupCaBundleFile and caBundleFile
#       (tpg-rotate-credential), and the clusterMap keys of the same names at
#       cluster and instance level - checks each file, and
#       writes (or replaces) the line patchFiles: '...' in the parameter file:
#         pack-patch-files.sh -o patch-map.yaml
#         argo submit -n argo --from workflowtemplate/tpg-patch --parameter-file patch-map.yaml --watch
#   FILE...: packs exactly these files (with -o into the parameter file, without it
#       the JSON is printed, for -p on the command line; Linux limits one
#       command-line argument to 128 KiB, about 90 KiB of files).
# Lists are strict (Round 23): an input is a quoted string that holds a bracketed list,
# postgresPatchFilePath: '[./a.yaml, ./b.yaml]', or a YAML sequence (argo sends it as the JSON
# text ["./a.yaml","./b.yaml"]), and a single-file input is a list of one, backupCaBundleFile:
# '[./ca.pem]' or [./ca.pem]; in the clusterMap they are YAML sequences. "repo: x.yaml"
# (a space after the colon) fails with repo:<file path> "check for white spaces in between".
# The bracketed lists are read with workflows/scripts/clustermap.py of the tpg-fleet clone
# (TPG_FLEET_DIR, else the clone this script sits in) and python3.
# Paths may be absolute, start with ~/ or be relative to the current directory
# (the directory argo submit runs in: the same path is the key). Each file is
# checked before it is packed: it exists, has at most 256 KiB, a patch file is
# .yaml or .yml YAML and fits the input it is named in (workflows/scripts/
# patchcheck.py of the tpg-fleet clone: TPG_FLEET_DIR, else the clone this script
# sits in; skipped with a note when there is none), a CA bundle is PEM
# certificates (openssl, when installed). All files together may have 512 KiB of
# base64. Requirements: bash 3.2 or later, coreutils (base64, wc, mktemp, mv),
# jq, mikefarah yq v4 for -o without FILE; python3 for the patch file check.
set -euo pipefail
MAX=262144
TOTAL_MAX=524288
out_file=""
if [[ "${1:-}" == "-o" ]]; then out_file="${2:-}"; shift 2 || true; [[ -n "$out_file" ]] || { echo "-o needs a file name" >&2; exit 2; }; fi
[[ $# -gt 0 || -n "$out_file" ]] || { echo "usage: $0 -o PARAMETER_FILE | [-o PARAMETER_FILE] FILE..." >&2; exit 2; }
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

# the tpg-fleet clone for the patch file check: TPG_FLEET_DIR, else the clone this script sits in
fleet_dir() {
  local src="${BASH_SOURCE[0]}" d
  if [[ -n "${TPG_FLEET_DIR:-}" ]]; then
    [[ -f "$TPG_FLEET_DIR/workflows/scripts/patchcheck.py" ]] && { printf '%s' "$TPG_FLEET_DIR"; return 0; }
    echo "TPG_FLEET_DIR=${TPG_FLEET_DIR} is not a tpg-fleet clone (no workflows/scripts/patchcheck.py)" >&2
    return 1
  fi
  while [[ -L "$src" ]]; do d="$(cd "$(dirname "$src")" && pwd)"; src="$(readlink "$src")"; [[ "$src" == /* ]] || src="$d/$src"; done
  d="$(cd "$(dirname "$src")/../.." 2>/dev/null && pwd)" || return 1
  [[ -f "$d/workflows/scripts/patchcheck.py" ]] && printf '%s' "$d"
}
FLEET="$(fleet_dir || true)"

local_file() {  # local_file PATH -> the file on this machine (~/ expanded)
  # shellcheck disable=SC2088  # the literal ~/ the user wrote
  case "$1" in "~/"*) printf '%s/%s' "$HOME" "${1#\~/}" ;; *) printf '%s' "$1" ;; esac
}

# KIND<TAB>PATH<TAB>WHERE rows: postgres | values | operator | ca
rows=""
if [[ $# -eq 0 ]]; then
  [[ -f "$out_file" ]] || { echo "${out_file}: no such parameter file" >&2; exit 1; }
  if ! command -v yq >/dev/null || ! yq --version 2>&1 | grep -q mikefarah; then
    echo "reading ${out_file} needs mikefarah yq v4" >&2; exit 1
  fi
  if [[ "$(yq -r '.patchMode // "apply"' "$out_file")" == clear ]]; then
    echo "patchMode=clear takes no files: nothing to pack" >&2
  fi
  if [[ -z "$FLEET" || ! -f "$FLEET/workflows/scripts/clustermap.py" ]] || ! command -v python3 >/dev/null; then
    echo "reading the bracketed lists of ${out_file} needs python3 and a tpg-fleet clone (TPG_FLEET_DIR=<clone>)" >&2; exit 1
  fi
  # input -> kind; list: several files; one: exactly one file
  for kk in postgres:postgresPatchFilePath:list values:postgresValuesPatchFilePath:one operator:operatorValuesPatchFilePath:one \
            postgres:postgresOverlayFilePath:list values:postgresValuesOverlayFilePath:one operator:operatorValuesOverlayFilePath:one \
            ca:backupCaBundleFile:one ca:caBundleFile:one; do
    kind="${kk%%:*}"; k="${kk#*:}"; shape="${k#*:}"; k="${k%%:*}"
    t="$(K="$k" yq -r '.[strenv(K)] | tag' "$out_file" 2>/dev/null || true)"
    case "$t" in
      ""|"!!null") continue ;;
      "!!str") v="$(K="$k" yq -r '.[strenv(K)]' "$out_file")" ;;
      # argo 4.1.3 sends a YAML sequence of a parameter file as its JSON text (["a","b"]), which the
      # workflow reads like the bracketed string
      "!!seq") v="$(K="$k" yq -o=json -I=0 '.[strenv(K)]' "$out_file")" ;;
      *) echo "${out_file}: ${k} must be a string or a list, not ${t#!!}" >&2; exit 1 ;;
    esac
    [[ -n "$(tr -d '[:space:]' <<<"$v")" ]] || continue
    lopts=(--files); [[ "$shape" != one ]] || lopts+=(--one)
    if ! items="$(python3 "$FLEET/workflows/scripts/clustermap.py" list "$k" "$v" "${lopts[@]}" 2>&1)"; then
      echo "${out_file}: ${items}" >&2; exit 1
    fi
    while IFS= read -r p; do
      [[ -z "$p" ]] || rows="${rows}${kind}"$'\t'"${p}"$'\t'"${k}"$'\n'
    done <<<"$items"
  done
  map="$(yq -r '.clusterMap // ""' "$out_file")"
  if [[ -n "$(tr -d '[:space:]' <<<"$map")" ]]; then
    # the clusterMap lists are YAML sequences (Round 23), a single file is a sequence of one; a string is a
    # mistake (kind "bad"), a mapping or an entry with whitespace is "repo: x.yaml" (kind "ws")
    # shellcheck disable=SC2016  # jq program
    if ! crows="$(printf '%s\n' "$map" | yq -o=json -I=0 '.' 2>&1 | jq -r '
      def rows($o; $pairs; $w):
        $pairs[] as $p | ($o[$p[0]]) as $v | select($v != null)
        | ($w + "." + $p[0]) as $where
        | if ($v | type) == "array" then
            $v[] | if type == "object" or (type == "string" and test("\\s")) then ["ws", "-", $where]
                   elif type == "string" then [$p[1], ., $where] else ["bad", tostring, $where] end
          else ["bad", ($v | tostring), $where] end
        | @tsv;
      to_entries[] | .key as $c | .value as $cv
      | rows($cv; [["operatorValuesPatchFilePath","operator"], ["operatorValuesOverlayFilePath","operator"], ["backupCaBundleFile","ca"]]; $c),
        (($cv.instances // {}) | to_entries[] | .key as $i | .value as $iv
         | rows($iv; [["postgresPatchFilePath","postgres"], ["postgresOverlayFilePath","postgres"], ["postgresValuesPatchFilePath","values"],
                      ["postgresValuesOverlayFilePath","values"], ["backupCaBundleFile","ca"]]; $c + ".instances." + $i))' 2>&1)"; then
      echo "${out_file}: clusterMap is not valid YAML or JSON: ${crows}" >&2; exit 1
    fi
    rows="${rows}"$'\n'"${crows}"
  fi
else
  for f in "$@"; do
    case "$f" in *.pem|*.crt|*.cer) rows="${rows}"$'\n'"ca	${f}	${f}" ;; *) rows="${rows}"$'\n'"-	${f}	${f}" ;; esac
  done
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/tpg-pack.XXXXXX")"
trap 'rm -rf "${tmp:?}"' EXIT
errors=0
declare_seen=" "
n=0
: > "$tmp/list"
while IFS=$'\t' read -r kind p where; do
  if [[ "$kind" == ws ]]; then echo "${where}: repo:<file path> \"check for white spaces in between\"" >&2; errors=1; continue; fi
  if [[ "$kind" == bad ]]; then echo "${where}: '${p}' is not a list; write it as a YAML sequence, [path] (a single file too)" >&2; errors=1; continue; fi
  [[ -n "$p" ]] || continue
  case "$p" in repo:*) continue ;; esac   # read by the workflow from the fleet branch
  f="$(local_file "$p")"
  if [[ ! -f "$f" ]]; then echo "${where}: ${p}: no such file (relative paths start at $(pwd))" >&2; errors=1; continue; fi
  size="$(wc -c < "$f" | tr -d ' ')"
  (( size <= MAX )) || { echo "${where}: ${p}: ${size} bytes; a file may have at most ${MAX}" >&2; errors=1; continue; }
  case "$kind" in
    ca)
      case "$p" in *.pem|*.crt|*.cer) ;; *) echo "${where}: ${p}: a CA bundle ends in .pem, .crt or .cer" >&2; errors=1; continue ;; esac
      if ! grep -q -- '-----BEGIN CERTIFICATE-----' "$f"; then echo "${where}: ${p}: no PEM certificate (-----BEGIN CERTIFICATE-----)" >&2; errors=1; continue; fi
      if command -v openssl >/dev/null && ! openssl crl2pkcs7 -nocrl -certfile "$f" -out /dev/null 2>/dev/null; then
        echo "${where}: ${p}: openssl cannot read the certificates" >&2; errors=1; continue
      fi ;;
    *)
      case "$p" in *.yaml|*.yml) ;; *) echo "${where}: ${p}: a patch or overlay file ends in .yaml or .yml" >&2; errors=1; continue ;; esac
      if [[ "$kind" != "-" && -n "$FLEET" ]] && command -v yq >/dev/null && command -v python3 >/dev/null; then
        if [[ "$kind" == postgres ]]; then yq ea -o=json -I=0 '[.]' "$f" > "$tmp/c.json" 2>"$tmp/e"; else yq -o=json -I=0 '.' "$f" > "$tmp/c.json" 2>"$tmp/e"; fi \
          || { echo "${where}: ${p}: not valid YAML: $(head -n 2 "$tmp/e" | tr '\n' ' ')" >&2; errors=1; continue; }
        word=Patch; [[ "$where" == *Overlay* ]] && word=Overlay   # the input names in the messages (Round 22)
        python3 "$FLEET/workflows/scripts/patchcheck.py" "$kind" "$tmp/c.json" --schemas "$FLEET/workflows/params/patch-schemas.json" \
          --word "$word" --name "${where}: ${p}" >&2 || { errors=1; continue; }
      fi ;;
  esac
  [[ "$declare_seen" == *" ${p} "* ]] && continue
  declare_seen="${declare_seen}${p} "
  printf '%s\t%s\n' "$p" "$f" >> "$tmp/list"
  n=$((n + 1))
done <<<"$rows"
[[ "$errors" -eq 0 ]] || { echo "nothing packed: fix the files above" >&2; exit 1; }
if [[ "$n" -eq 0 && -n "$out_file" && $# -eq 0 ]]; then
  echo "no local file named in ${out_file} (repo: files are read by the workflow): patchFiles not written" >&2
  exit 0
fi
[[ -n "$FLEET" ]] || echo "note: no tpg-fleet clone found (TPG_FLEET_DIR): the patch files were not checked against their inputs here; the validate step of the workflow checks them" >&2

# the contents go through pipes, never through a command-line argument
json="$(while IFS=$'\t' read -r p f; do base64 < "$f" | tr -d '\n' | jq -Rc --arg p "$p" '{($p): .}'; done < "$tmp/list" | jq -sc 'add // {}')"
total="$(printf '%s' "$json" | wc -c | tr -d ' ')"
(( total <= TOTAL_MAX )) || { echo "patchFiles would be ${total} bytes; at most ${TOTAL_MAX} in one run (split the patch into several runs)" >&2; exit 1; }
if [[ -z "$out_file" ]]; then
  printf '%s\n' "$json"
  exit 0
fi
out_tmp="${out_file}.tmp.$$"
{ grep -v '^patchFiles:' "$out_file" 2>/dev/null || true
  printf "patchFiles: '%s'\n" "$json"; } > "$out_tmp"
mv "$out_tmp" "$out_file"
echo "patchFiles: ${n} file(s), ${total} bytes, written to ${out_file}; submit with --parameter-file ${out_file}" >&2
