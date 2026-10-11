#!/usr/bin/env bash
# validate-params.sh MODE
# Validates workflow input parameters before anything changes. Parameters come
# from P_* environment variables set by the WorkflowTemplate. Mandatory inputs
# have no default: an empty value fails with the list of valid choices.
# The types of the inputs are enforced earlier, when the Workflow is created
# (ValidatingAdmissionPolicy workflows/admission/workflow-parameters.yaml); this
# step checks what a type cannot: mandatory inputs, combinations, registered
# clusters, and the clusterMap input (P_CLUSTER_MAP) against
# workflows/params/cluster-map-keys.yaml (clustermap.py).
# List inputs are strict (Round 23): bracketed even with one value, [tpg-poc-01] or
# [a, b] (YAML flow) or ["a","b"] (JSON); only all (and auto for components) stays
# bare. lib.sh list_items (clustermap.py as_list) parses them; a bad list is reported
# with the syntax. A comma in a value is never a separator here.
# Outputs:
#   /tmp/clusters.json   normalized cluster list (JSON array) for withParam loops
#   /tmp/selection       the cluster selection for the discover step: the clusterMap
#                        clusters (comma-separated, an internal value), else the clusters input
#   /tmp/approval        tpg-upgrade: true when a batch approval pause is needed
#   /tmp/hasWrite        tpg-rotate-credential: true when the run writes a value (a wrappingToken or a
#                        caBundleFile); the template's when: reads this, never the raw inputs
MODE="$1"
# shellcheck source=workflows/scripts/lib.sh
source /scripts/lib.sh
# the Workflow of this run: tpg-patch and tpg-create-instance read patchFiles from it
WF="${WF:-${P_WORKFLOW:-}}"

ERRORS=()
err() { ERRORS+=("$*"); }
REGISTERED="$(registered_clusters)"
REG_LIST="$(paste -sd, <<<"$REGISTERED")"

need() {        # need NAME VALUE HINT
  [[ -n "$2" ]] || err "$1 is mandatory: $3"
}
bool() {        # bool NAME VALUE
  [[ "$2" == "true" || "$2" == "false" ]] || err "$1 must be true or false (got '${2}')"
}
oneof() {       # oneof NAME VALUE CHOICE...
  local n="$1" v="$2" c; shift 2
  for c in "$@"; do [[ "$v" == "$c" ]] && return 0; done
  err "$n must be one of: $* (got '${v}')"
}
posint() {      # posint NAME VALUE
  [[ "$2" =~ ^[1-9][0-9]*$ ]] || err "$1 must be a positive integer (got '${2}')"
}
nonneg() {
  [[ "$2" =~ ^[0-9]+$ ]] || err "$1 must be a non-negative integer (got '${2}')"
}
quantity() {    # quantity NAME VALUE (empty allowed)
  [[ -z "$2" || "$2" =~ ^[0-9]+(\.[0-9]+)?(m|Ki|Mi|Gi|Ti|k|M|G|T)?$ ]] || err "$1 must be a Kubernetes quantity such as 20Gi or 500m (got '${2}')"
}
dnsname() {     # dnsname NAME VALUE
  [[ "$2" =~ ^[a-z]([-a-z0-9]{0,38}[a-z0-9])?$ ]] || err "$1 '${2}' must be a lowercase DNS label (letters, digits, '-', at most 40 characters)"
}
list_get() {    # list_get NAME VALUE [list_items options]: the items of a bracketed list input in LIST;
  # a bad list (a comma string, [], [a, , b], repo: with a space) is recorded as an error, status 1
  local out
  LIST=()
  [[ -n "$2" ]] || return 0
  if ! out="$(list_items "$@" 2>&1)"; then err "$out"; return 1; fi
  [[ -z "$out" ]] || mapfile -t LIST <<<"$out"
}
file_get() {    # file_get NAME VALUE: the one file of a single-file input, [./a.yaml], in FILE ("" when empty)
  local out
  FILE=""
  [[ -n "$2" ]] || return 0
  if ! out="$(file_item "$1" "$2" 2>&1)"; then err "$out"; return 0; fi   # (lib.sh runs with set -e: never fail here)
  FILE="$out"
}
no_all_item() { # no_all_item NAME ALLOW_ALL EXAMPLE: all is a bare word, not a name inside brackets (LIST from list_get)
  # where the input does not take all at all, the message says that (not "write it bare")
  local x
  for x in ${LIST[@]+"${LIST[@]}"}; do
    [[ "$x" != all ]] || {
      if [[ -n "${2:-}" ]]; then err "$1: all stands alone, without brackets: $1=all"
      else err "$1 does not accept all (bare or in brackets): list the names, for example ${3:-[a, b]}"; fi
      return 1
    }
  done
}
clusters_in() {  # clusters_in NAME VALUE ALLOW_ALL -> validates and writes /tmp/clusters.json
  local n="$1" v="$2" allow_all="${3:-}" c out="[]"
  v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"     # (the admission pattern lets white space surround all)
  if [[ -z "$v" ]]; then
    err "$n is mandatory: a list of cluster names in brackets, for example [aks-tpg-poc-01]${allow_all:+ or all} (or clusterMap). Registered clusters: ${REG_LIST:-none}"
    return
  fi
  if [[ "$v" == "all" ]]; then
    if [[ -z "$allow_all" ]]; then err "$n does not accept all: list the clusters in brackets, [aks-tpg-poc-01]. Registered clusters: ${REG_LIST:-none}"; return; fi
    printf '%s' "$(jq -cn --arg r "$REGISTERED" '$r | split("\n") | map(select(length > 0))')" > /tmp/clusters.json
    return
  fi
  # all is bare where the input takes it (the hint then says so); where it does not, it is no list item at all
  # shellcheck disable=SC2086  # the option is empty or two words
  list_get "$n" "$v" ${allow_all:+--bare all} || return 0       # (lib.sh runs with set -e: a failed list is already an error)
  no_all_item "$n" "$allow_all" "[aks-tpg-poc-01]" || return 0
  for c in ${LIST[@]+"${LIST[@]}"}; do
    grep -Fqx -- "$c" <<<"$REGISTERED" || err "$n: cluster '${c}' is not registered. Registered clusters: ${REG_LIST:-none}"
    out="$(jq -c --arg c "$c" 'if index($c) then . else . + [$c] end' <<<"$out")"
  done
  printf '%s' "$out" > /tmp/clusters.json
}
cluster_one() {  # cluster_one NAME VALUE: one registered cluster (a single-name input, not a list; empty allowed)
  [[ -n "$2" ]] || return 0
  grep -Fqx -- "$2" <<<"$REGISTERED" || err "$1: cluster '${2}' is not registered. Registered clusters: ${REG_LIST:-none}"
}
instances_in() { # instances_in NAME VALUE [ALLOW_ALL]
  local i allow="${3:-}" v="$2"
  v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
  if [[ -z "$v" ]]; then err "$1 is mandatory: a list of instance names in brackets, for example [orders-db]${allow:+ or all} (or clusterMap)"; return; fi
  if [[ "$v" == "all" ]]; then
    [[ -n "$allow" ]] || err "$1 does not accept all (bare or in brackets): list the instances, for example [orders-db]"
    return
  fi
  # shellcheck disable=SC2086  # the option is empty or two words
  list_get "$1" "$2" ${allow:+--bare all} || return 0
  no_all_item "$1" "$allow" "[orders-db]" || return 0
  for i in ${LIST[@]+"${LIST[@]}"}; do dnsname "$1" "$i"; done
}
opver() { [[ "$2" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+([-+.][0-9A-Za-z.-]+)?$ ]] || err "$1 must be an operator chart version such as v4.5.0 (got '${2}')"; }
pgver() { [[ "$2" =~ ^(postgres-)?[0-9]+(\.[0-9]+)?$ ]] || err "$1 must be a Postgres version such as postgres-17.6 or 17.6 (got '${2}')"; }
PATCH_LOCAL_RE='^(/|~/)?((\.\.?|[A-Za-z0-9_@+][A-Za-z0-9_.@+-]*)/)*[A-Za-z0-9_@+][A-Za-z0-9_.@+-]*\.ya?ml$'
# kinds_check NAME VALUE: a kindList (clearKinds), [Postgres, postgresValues] or all: known kinds, all alone, no repeats
PATCH_KIND_NAMES="Postgres PostgresBackupLocation PostgresBackupSchedule PostgresFerretDocumentDB postgresValues operatorValues"
kinds_check() {
  local k kseen=" " v="$2"
  v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
  list_get "$1" "$2" --bare all || return 0
  for k in ${LIST[@]+"${LIST[@]}"}; do
    if [[ "$k" != all && " ${PATCH_KIND_NAMES} " != *" ${k} "* ]]; then
      err "$1: '${k}' must be one of ${PATCH_KIND_NAMES// /, }, or all"
    fi
    [[ "$kseen" != *" ${k} "* ]] || err "$1: ${k} is named twice"
    kseen="${kseen}${k} "
  done
  # all is the bare word, as for clusters and instances: neither [all] nor [all, Postgres]
  [[ "$kseen" != *" all "* || "$v" == all ]] || err "$1: all stands alone, without brackets: $1=all"
}
PATCH_REPO_RE='^repo:([A-Za-z0-9_@+][A-Za-z0-9_.@+-]*/)*[A-Za-z0-9_@+][A-Za-z0-9_.@+-]*\.ya?ml$'
PATCH_LOCAL_CA_RE='^(/|~/)?((\.\.?|[A-Za-z0-9_@+][A-Za-z0-9_.@+-]*)/)*[A-Za-z0-9_@+][A-Za-z0-9_.@+-]*\.(pem|crt|cer)$'
PATCH_REPO_CA_RE='^repo:ca-bundles/([A-Za-z0-9_@+][A-Za-z0-9_.@+-]*/)*[A-Za-z0-9_@+][A-Za-z0-9_.@+-]*\.(pem|crt|cer)$'
ca_inputs_check() {
  # ca_inputs_check WORKFLOW: the CA bundle sources (Round 15, D86): one PEM file or
  # one Vault secret per level (inputs; clusterMap cluster and instance keys), and
  # for tpg-day0 and tpg-create-instance only on instances with backupEnableSSL=true
  local f="" v="${P_BACKUP_CA_VAULT:-}" bad
  file_get backupCaBundleFile "${P_BACKUP_CA_FILE:-}"; f="$FILE"
  if [[ -n "$f" ]]; then
    if [[ "$f" == repo:* ]]; then [[ "$f" =~ $PATCH_REPO_CA_RE && "/${f#repo:}/" != */../* ]] \
      || err "backupCaBundleFile: '${f}' must be repo:ca-bundles/<file>.pem (.crt, .cer) of the fleet repository"
    else [[ "$f" =~ $PATCH_LOCAL_CA_RE ]] || err "backupCaBundleFile: '${f}' must be the path of one PEM file (.pem, .crt or .cer) on the submitting machine, or repo:ca-bundles/<file>, in brackets: [path]"; fi
  fi
  [[ -z "$v" || "$v" =~ ^[a-z0-9]([-a-z0-9.]{0,251}[a-z0-9])?$ ]] || err "backupCaBundleVaultSecret: '${v}' must be a secret name under tpg/ca-bundles/ (lowercase letters, digits, '-' and '.')"
  [[ -z "$f" || -z "$v" ]] || err "backupCaBundleFile and backupCaBundleVaultSecret cannot be used together: name one source of the CA bundle"
  [[ "$1" != patch ]] || return 0
  if cmap_set && [[ -s "$WORK/cmap.json" ]]; then
    bad="$(jq -r --arg ssl "${P_BACKUP_ENABLE_SSL:-false}" --arg src "${f}${v}" '
      to_entries[] | .key as $c | .value as $cv
      | ($cv.backupCaBundleFile // "") as $cf | ($cv.backupCaBundleVaultSecret // "") as $cvs
      | (if $cf != "" and $cvs != "" then "clusterMap." + $c + ": backupCaBundleFile and backupCaBundleVaultSecret on one level: name one source" else empty end),
        (($cv.instances // {}) | to_entries[] | .key as $i | .value as $iv
         | ($iv.backupCaBundleFile // "") as $if | ($iv.backupCaBundleVaultSecret // "") as $ivs
         | (if $if != "" and $ivs != "" then "clusterMap." + $c + ".instances." + $i + ": backupCaBundleFile and backupCaBundleVaultSecret on one level: name one source" else empty end),
           (if ($if + $ivs + $cf + $cvs + $src) != "" and (($iv.backupEnableSSL // $ssl) | tostring) != "true"
            then "clusterMap." + $c + ".instances." + $i + ": a CA bundle source needs backupEnableSSL=true" else empty end))' "$WORK/cmap.json")"
    while IFS= read -r line; do [[ -z "$line" ]] || err "$line"; done <<<"$bad"
  elif [[ -n "${f}${v}" && "${P_BACKUP_ENABLE_SSL:-false}" != "true" ]]; then
    err "backupCaBundleFile and backupCaBundleVaultSecret need backupEnableSSL=true (the CA bundle is written for HTTPS backup locations only)"
  fi
}
patch_path() {  # patch_path NAME VALUE REPO_DIR [list]: one .yaml/.yml file in brackets, [./a.yaml] (several with "list"), local or repo:<REPO_DIR>...
  local n="$1" v="$2" d="$3" p
  [[ -z "$v" ]] && return 0
  if [[ "${4:-}" == list ]]; then list_get "$n" "$v" --files || return 0
  else
    file_get "$n" "$v"
    [[ -n "$FILE" ]] || return 0
    LIST=("$FILE")
  fi
  for p in ${LIST[@]+"${LIST[@]}"}; do
    if [[ "$p" == repo:* ]]; then
      if [[ ! "$p" =~ $PATCH_REPO_RE || "/${p#repo:}/" == */../* ]]; then
        err "$n: '${p}' must be repo:<path of a .yaml or .yml file in the fleet repository> (relative to its root, no ..)"
      elif [[ "${p#repo:}" != "$d"* ]]; then
        err "$n: '${p}' must be a file under ${d} of the fleet repository (repo:${d}<file>)"
      elif [[ "${p#repo:}" == helm_artifacts/operator/patches/clusters/* || "${p#repo:}" == helm_artifacts/operator/overlays/clusters/* ]]; then
        err "$n: '${p}' is a copy the workflows write per cluster; name the stored file under ${d}"
      fi
    elif [[ ! "$p" =~ $PATCH_LOCAL_RE ]]; then
      err "$n: '${p}' must be the path of a .yaml or .yml file on the submitting machine (absolute or relative), or repo:<path> in the fleet repository"
    fi
  done
}
# The word of the file inputs of the workflow: tpg-patch takes Patch files (postgresPatchFilePath, ...,
# folders patches/), tpg-day0 and tpg-create-instance Overlay files (postgresOverlayFilePath, ..., folders
# overlays/); set by the workflow's branch below (Round 22)
PW=Patch; PG=patches
PATCH_FILE_MAX=262144      # one decoded patch file
PATCH_FILES_MAX=524288     # the patchFiles input
patch_schemas_file() {
  if [[ -f "$TPG_LIB_DIR/patch-schemas.json" ]]; then printf '%s' "$TPG_LIB_DIR/patch-schemas.json"
  else printf '%s' "$TPG_LIB_DIR/../params/patch-schemas.json"; fi
}
patch_files_check() {
  # patch_files_check (Round 14, D77; Round 15, D81): every local file the run names
  # (the path inputs and the clusterMap keys; patchMode apply) must be in
  # patchFiles, parse as YAML and fit the input it was passed to (patchcheck.py;
  # the postgres files of one target together, at most one document per kind);
  # patchFiles may carry nothing else. repo: files are checked by the plan step,
  # which reads the fleet repository.
  local rows files used="[]" kind list where tmp out n p have
  if ! files="$(patch_files_json)"; then err "${PATCH_FILES_ERROR:-patchFiles could not be read}"; return; fi
  n="$(jq -c . <<<"$files" | wc -c)"
  (( n <= PATCH_FILES_MAX )) || err "patchFiles is ${n} bytes; at most ${PATCH_FILES_MAX} bytes in one run (split the patch into several runs)"
  have="$(jq -r 'keys | if length == 0 then "patchFiles is empty" else "patchFiles holds " + join(", ") end' <<<"$files")"
  # one row per group of files checked together: kind <TAB> comma-separated paths (internal form) <TAB> where
  rows="$(
    [[ -z "${P_POSTGRES_PATCH:-}" ]] || printf 'postgres\t%s\tpostgres%sFilePath\n' "$(list_csv "postgres${PW}FilePath" "$P_POSTGRES_PATCH" --files)" "$PW"
    [[ -z "${P_VALUES_PATCH:-}" ]] || printf 'values\t%s\tpostgresValues%sFilePath\n' "$(file_item "postgresValues${PW}FilePath" "$P_VALUES_PATCH")" "$PW"
    [[ -z "${P_OPERATOR_VALUES_PATCH:-}" ]] || printf 'operator\t%s\toperatorValues%sFilePath\n' "$(file_item "operatorValues${PW}FilePath" "$P_OPERATOR_VALUES_PATCH")" "$PW"
    [[ -z "${P_BACKUP_CA_FILE:-}" ]] || printf 'ca\t%s\tbackupCaBundleFile\n' "$(file_item backupCaBundleFile "$P_BACKUP_CA_FILE")"
    if cmap_set && [[ -s "$WORK/cmap.json" ]]; then
      jq -r --arg w "$PW" 'to_entries[] | .key as $c
        | (if .value["operatorValues" + $w + "FilePath"] then ["operator", .value["operatorValues" + $w + "FilePath"], ($c + ".operatorValues" + $w + "FilePath")] else empty end),
          (if .value.backupCaBundleFile then ["ca", .value.backupCaBundleFile, ($c + ".backupCaBundleFile")] else empty end),
          ((.value.instances // {}) | to_entries[] | .key as $i
           | (if .value["postgres" + $w + "FilePath"] then ["postgres", (.value["postgres" + $w + "FilePath"] | if type == "array" then join(",") else . end), ($c + ".instances." + $i + ".postgres" + $w + "FilePath")] else empty end),
             (if .value["postgresValues" + $w + "FilePath"] then ["values", .value["postgresValues" + $w + "FilePath"], ($c + ".instances." + $i + ".postgresValues" + $w + "FilePath")] else empty end),
             (if .value.backupCaBundleFile then ["ca", .value.backupCaBundleFile, ($c + ".instances." + $i + ".backupCaBundleFile")] else empty end))
        | @tsv' "$WORK/cmap.json"
    fi)"
  tmp="$(mktemp -d)"
  declare -A seen=()
  while IFS=$'\t' read -r kind list where; do
    [[ -n "$kind" ]] || continue
    local -a jf=() nm=()
    local k=0 bad=0
    for p in $(tr ',' ' ' <<<"$list"); do
      p="$(patch_norm "$p")"
      patch_is_repo "$p" && continue
      used="$(jq -c --arg p "$p" '. + [$p]' <<<"$used")"
      k=$((k + 1))
      if ! patch_file_write "$p" "$tmp/f$k.yaml"; then
        err "${where}: ${p}: its contents are not in patchFiles (${have}). Pack every local file of the run with <tpg-fleet clone>/scripts/submit/pack-patch-files.sh -o <parameter file> in the directory the relative paths start from, and submit with --parameter-file <parameter file>; or use scripts/submit/tpg-*.sh"
        bad=1; continue
      fi
      n="$(wc -c < "$tmp/f$k.yaml")"
      (( n <= PATCH_FILE_MAX )) || { err "${p}: ${n} bytes; a patch file may have at most ${PATCH_FILE_MAX}"; bad=1; continue; }
      if [[ "$kind" == ca ]]; then
        out="$(ca_check "$tmp/f$k.yaml")" || err "${where}: ${p}: ${out}"
        continue
      fi
      if [[ "$kind" == postgres ]]; then yq ea -o=json -I=0 '[.]' "$tmp/f$k.yaml" > "$tmp/f$k.json" 2>"$tmp/err"
      else yq -o=json -I=0 '.' "$tmp/f$k.yaml" > "$tmp/f$k.json" 2>"$tmp/err"; fi \
        || { err "${p}: not valid YAML: $(head -n 2 "$tmp/err" | tr '\n' ' ')"; bad=1; continue; }
      jf+=("$tmp/f$k.json"); nm+=(--name "${where}: ${p}")
    done
    [[ "$bad" -eq 0 && "${#jf[@]}" -gt 0 ]] || continue
    [[ -z "${seen[$kind|$list]:-}" ]] || continue
    seen[$kind|$list]=1
    if ! out="$(python3 "$TPG_LIB_DIR/patchcheck.py" "$kind" "${jf[@]}" --schemas "$(patch_schemas_file)" --word "$PW" "${nm[@]}")"; then
      while IFS= read -r line; do [[ -z "$line" ]] || err "$line"; done <<<"$out"
    fi
  done <<<"$rows"
  rm -rf "${tmp:?}"
  for p in $(jq -r --argjson u "$used" 'keys[] | select(. as $k | $u | index($k) | not)' <<<"$files"); do
    err "patchFiles carries ${p}, which no path input or clusterMap key names (patchMode=clear takes no contents)"
  done
}
patch_inputs_check() {
  # patch_inputs_check WORKFLOW: the path inputs of tpg-patch (Patch files), tpg-create-instance and
  # tpg-day0 (Overlay files) (the clusterMap keys are checked by clustermap.py)
  patch_path "postgres${PW}FilePath" "${P_POSTGRES_PATCH:-}" "helm_artifacts/instance/tpg-instance/${PG}/" list
  patch_path "postgresValues${PW}FilePath" "${P_VALUES_PATCH:-}" "helm_artifacts/instance/tpg-instance/${PG}/"
  [[ "$1" == create-instance ]] || patch_path "operatorValues${PW}FilePath" "${P_OPERATOR_VALUES_PATCH:-}" "helm_artifacts/operator/${PG}/"
  [[ -z "${P_POSTGRES_PATCH:-}" ]] || [[ "$(list_items "postgres${PW}FilePath" "$P_POSTGRES_PATCH" --files 2>/dev/null | sort | uniq -d)" == "" ]] \
    || err "postgres${PW}FilePath lists a file twice"
}
instance_inputs() {  # instance_inputs: the exposure and network policy inputs of tpg-day0 and tpg-create-instance
  # Lists and maps are checked with the clusterMap rules (clustermap.py), so an
  # input and the map key of the same name accept exactly the same values.
  local j out
  oneof exposure "${P_EXPOSURE:-}" "" clusterIP internalLoadBalancer loadBalancer
  oneof readOnlyExposure "${P_READ_ONLY_EXPOSURE:-}" "" clusterIP internalLoadBalancer loadBalancer
  oneof networkPolicy "${P_NETWORK_POLICY:-}" "" none baseline
  [[ -z "${P_INTERNAL_LB_SUBNET:-}" || "$P_INTERNAL_LB_SUBNET" =~ ^[A-Za-z0-9]([-A-Za-z0-9_.]{0,78}[A-Za-z0-9_])?$ ]] \
    || err "internalLoadBalancerSubnet '${P_INTERNAL_LB_SUBNET}' must be an Azure subnet name (letters, digits, '-', '_', '.', at most 80 characters)"
  j="$(jq -cn \
    --arg serviceAnnotations "${P_SERVICE_ANNOTATIONS:-}" --arg readOnlyServiceAnnotations "${P_READ_ONLY_SERVICE_ANNOTATIONS:-}" \
    --arg ingressFromPodLabels "${P_INGRESS_FROM_POD_LABELS:-}" \
    '$ARGS.named | with_entries(select(.value | test("\\S")))')"
  # the list inputs are bracketed ([a, b]): list_get parses them (the message names the input), the
  # clusterMap rules below then check the items as they do for a map sequence
  for k in allowedSourceRanges ingressFromNamespaces ingressFromCidrs egressToCidrs egressToFqdns; do
    case "$k" in
      allowedSourceRanges) v="${P_ALLOWED_SOURCE_RANGES:-}" ;; ingressFromNamespaces) v="${P_INGRESS_FROM_NAMESPACES:-}" ;;
      ingressFromCidrs) v="${P_INGRESS_FROM_CIDRS:-}" ;; egressToCidrs) v="${P_EGRESS_TO_CIDRS:-}" ;; *) v="${P_EGRESS_TO_FQDNS:-}" ;;
    esac
    [[ -n "${v//[[:space:]]/}" ]] || continue
    list_get "$k" "$v" || continue
    j="$(jq -c --arg k "$k" --argjson l "$(printf '%s\n' "${LIST[@]}" | jq -Rc '[., inputs]')" '.[$k] = $l' <<<"$j")"
  done
  [[ "$j" != "{}" ]] || return 0
  # maps may be written as YAML: turn them into JSON first
  for k in serviceAnnotations readOnlyServiceAnnotations ingressFromPodLabels; do
    v="$(jq -r --arg k "$k" '.[$k] // empty' <<<"$j")"
    [[ -n "$v" ]] || continue
    if m="$(printf '%s\n' "$v" | yq -o=json -I=0 '.' 2>/dev/null)" && [[ "$m" == "{"* ]]; then
      j="$(jq -c --arg k "$k" --argjson m "$m" '.[$k] = $m' <<<"$j")"
    else
      err "$k must be a map (YAML or JSON), for example {key: value} (got '${v}')"
      j="$(jq -c --arg k "$k" 'del(.[$k])' <<<"$j")"
    fi
  done
  jq -cn --argjson i "$j" '{"input-check": {instances: {"input-check": $i}}}' > "$WORK/inputs.json"
  yq -o=json -I=0 '.' "$(cmap_keys_file)" > "$WORK/cmap-keys.json"
  if ! out="$(python3 "$TPG_LIB_DIR/clustermap.py" normalize --map "$WORK/inputs.json" --keys "$WORK/cmap-keys.json")"; then
    while IFS= read -r line; do
      [[ -z "$line" ]] || err "$(sed -E 's/^clusterMap\.input-check\.instances\.input-check\.([A-Za-z]+)/input \1/' <<<"$line")"
    done <<<"$out"
  fi
  if [[ -z "${P_NETWORK_POLICY:-}" || "${P_NETWORK_POLICY}" == "none" ]] && ! cmap_set \
     && jq -e 'keys | any(test("^(ingress|egress)"))' <<<"$j" >/dev/null; then
    err "the ingressFrom*/egressTo* rules need networkPolicy=baseline (a rule without the default deny would change nothing)"
  fi
}

cron() {        # cron NAME VALUE: a cron schedule of 5 fields
  [[ "$2" =~ ^[[:space:]]*[0-9*/,A-Za-z-]+([[:space:]]+[0-9*/,A-Za-z-]+){4}[[:space:]]*$ ]] \
    || err "$1 must be a cron schedule of 5 fields (minute hour day month weekday), for example 0 0 * * 0 (got '${2}')"
}
k8sname() {     # k8sname NAME VALUE (empty allowed)
  [[ -z "$2" || "$2" =~ ^[a-z0-9]([-a-z0-9.]{0,251}[a-z0-9])?$ ]] || err "$1 '${2}' must be a Kubernetes object name (lowercase letters, digits, '-' and '.')"
}
backup_ferret_inputs() {  # the backup scheduler and FerretDB inputs of tpg-day0 and tpg-create-instance (D70, D71)
  oneof backupSchedule "${P_BACKUP_SCHEDULE:-fleet}" fleet none operator
  cron operatorFullSchedule "${P_OPERATOR_FULL_SCHEDULE-0 0 * * 0}"
  [[ -z "${P_OPERATOR_INCR_SCHEDULE:-}" ]] || cron operatorIncrementalSchedule "$P_OPERATOR_INCR_SCHEDULE"
  [[ -z "${P_FERRET:-}" ]] || bool ferret "$P_FERRET"
  posint ferretReplicas "${P_FERRET_REPLICAS:-1}"
  nonneg ferretReadOnlyReplicas "${P_FERRET_RO_REPLICAS:-0}"
  oneof ferretExposure "${P_FERRET_EXPOSURE:-}" "" clusterIP internalLoadBalancer loadBalancer
  k8sname ferretSecretName "${P_FERRET_SECRET:-}"
  k8sname ferretReadOnlySecretName "${P_FERRET_RO_SECRET:-}"
}
instance_combinations() {  # the effective values of every instance (clusterMap keys over the inputs, D69, D71)
  # highAvailability and readReplicas depend on each other (Round 13 addendum):
  #   highAvailability=true needs readReplicas 1 or more (empty means 1);
  #   readReplicas above 0 needs highAvailability=true (a single node has none).
  # A pair is checked where it is set: both inputs, or one clusterMap entry (its
  # own keys, the inputs filling what it leaves out). An input readReplicas is
  # a default for HA instances only: it does not apply to an entry that sets
  # highAvailability: false itself. Read-only FerretDB proxies need
  # highAvailability (they connect to the standby).
  local bad
  bad="$(jq -rn --slurpfile m <(if [[ -s "$WORK/cmap.json" ]] && cmap_set; then cat "$WORK/cmap.json"; else echo '{"input": {"instances": {"input": {}}}}'; fi) \
    --arg ha "${P_HA:-}" --arg rr "${P_READ_REPLICAS:-}" --arg ro "${P_FERRET_RO_REPLICAS:-0}" '
    def val($o; $k; $d): if ($o | has($k)) and $o[$k] != null then ($o[$k] | tostring) else $d end;
    $m[0] | to_entries[] | .key as $c | (.value.instances // {}) | to_entries[] | .key as $i | .value as $v
    | (if $c == "input" then "inputs" else "clusterMap." + $c + ".instances." + $i end) as $w
    | val($v; "highAvailability"; $ha) as $h
    | (if ($v | has("readReplicas")) then val($v; "readReplicas"; "")
       elif val($v; "highAvailability"; "") == "false" then ""
       else $rr end) as $r
    | val($v; "ferretReadOnlyReplicas"; $ro) as $o
    | (if $h == "true" and ($r | test("^0+$")) then
         $w + ": highAvailability=true needs readReplicas 1 or more (readReplicas 0 is a single node: highAvailability=false)" else empty end),
      (if $h == "false" and ($r | test("^0*[1-9][0-9]*$")) then
         $w + ": readReplicas " + $r + " needs highAvailability=true (a single node, highAvailability=false, has no read replicas: set highAvailability=true or remove readReplicas)" else empty end),
      (if ($o | test("^0*[1-9][0-9]*$")) and $h != "true" then
         $w + ": ferretReadOnlyReplicas " + $o + " needs highAvailability=true (the read-only FerretDB proxies connect to the standby)" else empty end)')"
  while IFS= read -r line; do [[ -z "$line" ]] || err "$line"; done <<<"$bad"
}

scale_ha_check() {  # tpg-scale-instance (Round 13 addendum): replicas above 0 with
  # enableHAIfNeeded=false on an instance that clusters/fleet.yaml declares a single
  # node would fail per instance (HA_DISABLED) after the run started; refuse it here.
  # Reads the fleet repository only when such a pair is requested.
  local pairs c i n e ha
  if cmap_set; then
    [[ -s "$WORK/cmap.json" ]] || return 0
    pairs="$(jq -r --arg r "${P_REPLICAS:-}" --arg e "${P_ENABLE_HA:-true}" '
      to_entries[] | .key as $c | (.value.instances // {}) | to_entries[]
      | [$c, .key, (if .value.replicas != null then (.value.replicas | tostring) else $r end),
         (if .value.enableHAIfNeeded != null then (.value.enableHAIfNeeded | tostring) else $e end)] | @tsv' "$WORK/cmap.json")"
  else
    pairs="$(for c in $(list_items clusters "${P_CLUSTERS:-}"); do for i in $(list_items instances "${P_INSTANCES:-}"); do
      printf '%s\t%s\t%s\t%s\n' "$c" "$i" "${P_REPLICAS:-}" "${P_ENABLE_HA:-true}"; done; done)"
  fi
  local need=0
  while IFS=$'\t' read -r c i n e; do
    [[ "$e" == "false" && "$n" =~ ^0*[1-9][0-9]*$ ]] && need=1
  done <<<"$pairs"
  [[ "$need" -eq 1 ]] || return 0
  if ! git_clone "$WORK/repo" >/dev/null 2>&1; then
    err "enableHAIfNeeded=false with replicas above 0: clusters/fleet.yaml could not be read to check which instances are single nodes"
    return
  fi
  while IFS=$'\t' read -r c i n e; do
    [[ -n "$c" && "$e" == "false" && "$n" =~ ^0*[1-9][0-9]*$ ]] || continue
    fleet_has_instance "$WORK/repo" "$c" "$i" || continue   # undeclared: UNKNOWN_INSTANCE in the discover step
    ha="$(fleet_instance_value "$WORK/repo" "$c" "$i" '.instance.highAvailability.enabled' true)"
    [[ "$ha" == "true" ]] \
      || err "${c}/${i}: replicas ${n} needs highAvailability, and ${i} is declared a single node (highAvailability.enabled false in clusters/fleet.yaml): set enableHAIfNeeded=true to turn it on (HA_DISABLED)"
  done <<<"$pairs"
}

scale_cap_check() {  # tpg-scale-instance (Round 14): a new maxReadReplicas must hold
  # every instance of its cluster: the declared readReplicas, or the replicas this
  # run gives the instance. Reads the fleet repository only when a cap is set.
  local caps c cap i cur n below
  if cmap_set; then
    [[ -s "$WORK/cmap.json" ]] || return 0
    caps="$(jq -r --arg m "${P_MAX_READ_REPLICAS:-}" 'to_entries[]
      | [.key, (if .value.maxReadReplicas != null then (.value.maxReadReplicas | tostring) else $m end)]
      | select(.[1] != "") | @tsv' "$WORK/cmap.json")"
  else
    [[ -n "${P_MAX_READ_REPLICAS:-}" ]] || return 0
    caps="$(for c in $(list_items clusters "${P_CLUSTERS:-}"); do printf '%s\t%s\n' "$c" "$P_MAX_READ_REPLICAS"; done)"
  fi
  [[ -n "$caps" ]] || return 0
  if [[ ! -d "$WORK/repo/.git" ]] && ! git_clone "$WORK/repo" >/dev/null 2>&1; then
    err "maxReadReplicas: clusters/fleet.yaml could not be read to check the declared readReplicas against the new cap"
    return
  fi
  while IFS=$'\t' read -r c cap; do
    [[ -n "$c" ]] || continue
    if ! fleet_has_cluster "$WORK/repo" "$c"; then
      err "${c}: maxReadReplicas is written to clusters.${c}.cluster in clusters/fleet.yaml, which has no entry for ${c} (run tpg-day0 first)"
      continue
    fi
    below=()
    for i in $(C="$c" yq -r '.clusters[strenv(C)].instances // {} | keys | .[]' "$WORK/repo/$FLEET_REL"); do
      n=""
      if cmap_set; then
        n="$(jq -r --arg c "$c" --arg i "$i" --arg r "${P_REPLICAS:-}" '.[$c].instances[$i] // null
          | if . == null then "" elif .replicas != null then (.replicas | tostring) else $r end' "$WORK/cmap.json")"
      elif [[ ",$(list_csv instances "${P_INSTANCES:-}")," == *",${i},"* ]]; then
        n="${P_REPLICAS:-}"
      fi
      if [[ -z "$n" ]]; then
        cur="$(fleet_instance_value "$WORK/repo" "$c" "$i" '.instance.highAvailability.readReplicas' 0)"
        [[ "$(fleet_instance_value "$WORK/repo" "$c" "$i" '.instance.highAvailability.enabled' true)" == "true" ]] || cur=0
      else
        cur="$n"
      fi
      [[ "$cur" =~ ^[0-9]+$ ]] || continue
      (( cur <= cap )) || below+=("${i}=${cur}")
    done
    [[ "${#below[@]}" -eq 0 ]] \
      || err "${c}: maxReadReplicas ${cap} is below the read replicas of ${below[*]} (MAX_BELOW_CURRENT): scale them down in the same run or choose a larger cap"
  done <<<"$caps"
}

same_set() {    # same_set NAME1 LIST1 NAME2 LIST2 -> 0 when both bracketed lists hold the same names (any order)
  # (a bad list is reported by list_get; here it counts as different)
  local a b
  a="$(list_items "$1" "$2" 2>/dev/null | sort -u | paste -sd,)" || return 1
  b="$(list_items "$3" "$4" 2>/dev/null | sort -u | paste -sd,)" || return 1
  [[ "$a" == "$b" ]]
}
bracket_keys() { # bracket_keys FILE -> the cluster names of a normalized clusterMap as a list: [a, b]
  jq -r 'keys | "[" + join(", ") + "]"' "$1"
}

# ---- clusterMap
map_exclusive() {  # map_exclusive NAME=VALUE...: inputs that must be empty when clusterMap is set
  local a
  for a in "$@"; do
    [[ -z "${a#*=}" ]] || err "clusterMap and ${a%%=*} cannot be used together: the map selects the clusters and instances (got ${a%%=*}='${a#*=}')"
  done
}
map_validate() {   # map_validate WORKFLOW FLAGS_JSON: clustermap.py validate; writes /tmp/clusters.json
  local out
  if ! cmap_to_json "$P_CLUSTER_MAP" > "$WORK/cmap.raw.json" 2> "$WORK/cmap.err"; then
    err "clusterMap is not valid YAML or JSON: $(tr '\n' ' ' < "$WORK/cmap.err" | cut -c1-300)"
    return
  fi
  yq -o=json -I=0 '.' "$(cmap_keys_file)" > "$WORK/cmap-keys.json"
  printf '%s\n' "$REGISTERED" > "$WORK/registered"
  printf '%s' "$2" > "$WORK/flags.json"
  if ! out="$(python3 "$TPG_LIB_DIR/clustermap.py" validate --workflow "$1" --map "$WORK/cmap.raw.json" \
      --keys "$WORK/cmap-keys.json" --registered "$WORK/registered" --flags "$WORK/flags.json" --out "$WORK/cmap.json")"; then
    while IFS= read -r line; do [[ -z "$line" ]] || err "$line"; done <<<"$out"
    return
  fi
  jq -c 'keys' "$WORK/cmap.json" > /tmp/clusters.json
}
map_each_instance() {  # map_each_instance JQ_FILTER MESSAGE: an error for every instance entry where FILTER is false
  # FILTER sees {cluster, instance, v: <instance keys>}
  local bad
  [[ -s "$WORK/cmap.json" ]] || return 0
  bad="$(jq -r --arg m "$2" "to_entries[] | .key as \$c | (.value.instances // {}) | to_entries[]
    | {cluster: \$c, instance: .key, v: .value} | select(($1) | not) | \"clusterMap.\" + .cluster + \".instances.\" + .instance + \": \" + \$m" "$WORK/cmap.json")"
  while IFS= read -r line; do [[ -z "$line" ]] || err "$line"; done <<<"$bad"
}
flags_json() {  # flags_json NAME=VALUE... -> JSON object for clustermap.py --flags
  local a args=()
  for a in "$@"; do args+=(--arg "${a%%=*}" "${a#*=}"); done
  jq -cn "${args[@]}" '$ARGS.named'
}

echo '[]' > /tmp/clusters.json
: > /tmp/selection
echo false > /tmp/approval
echo false > /tmp/hasWrite
case "$MODE" in
  day0)
    PW=Overlay; PG=overlays
    if cmap_set; then
      map_exclusive "clusters=${P_CLUSTERS:-}" "instances=${P_INSTANCES:-}"
      map_validate day0 "$(flags_json "operatorVersion=${P_OPERATOR_VERSION:-}" "postgresVersion=${P_POSTGRES_VERSION:-}" \
        "highAvailability=${P_HA:-}" "backupEnableSSL=${P_BACKUP_ENABLE_SSL:-false}" \
        "operatorValuesOverlayFilePath=${P_OPERATOR_VALUES_OVERLAY_FILE:-}")"
      [[ -z "${P_HA:-}" ]] || bool highAvailability "$P_HA"
      [[ -z "${P_OPERATOR_VERSION:-}" ]] || opver operatorVersion "$P_OPERATOR_VERSION"
      [[ -z "${P_POSTGRES_VERSION:-}" ]] || pgver postgresVersion "$P_POSTGRES_VERSION"
    else
      clusters_in clusters "${P_CLUSTERS:-}" allow
      instances_in instances "${P_INSTANCES:-}"
      need highAvailability "${P_HA:-}" "true or false"; [[ -z "${P_HA:-}" ]] || bool highAvailability "$P_HA"
      need operatorVersion "${P_OPERATOR_VERSION:-}" "for example v4.5.0"; [[ -z "${P_OPERATOR_VERSION:-}" ]] || opver operatorVersion "$P_OPERATOR_VERSION"
      need postgresVersion "${P_POSTGRES_VERSION:-}" "for example postgres-17.6"; [[ -z "${P_POSTGRES_VERSION:-}" ]] || pgver postgresVersion "$P_POSTGRES_VERSION"
    fi
    need pushMode "${P_PUSH_MODE:-}" "direct or pr"; [[ -z "${P_PUSH_MODE:-}" ]] || oneof pushMode "$P_PUSH_MODE" direct pr
    [[ -z "${P_READ_REPLICAS:-}" ]] || nonneg readReplicas "$P_READ_REPLICAS"
    quantity storageSize "${P_STORAGE_SIZE:-}"; quantity walStorageSize "${P_WAL_STORAGE_SIZE:-}"
    quantity cpu "${P_CPU:-}"; quantity memory "${P_MEMORY:-}"
    [[ -z "${P_STORAGE_CLASS:-}" ]] || dnsname storageClass "$P_STORAGE_CLASS"
    backup_ferret_inputs
    oneof monitoringOption "${P_MONITORING_OPTION:-}" "" none azure standalone
    bool installAddons "${P_INSTALL_ADDONS:-true}"; bool dryRun "${P_DRY_RUN:-false}"
    oneof existingAddons "${P_EXISTING:-skip}" skip upgrade
    posint maxParallel "${P_MAX_PARALLEL:-2}"; posint syncTimeoutSeconds "${P_TIMEOUT:-1800}"; posint prTimeoutSeconds "${P_PR_TIMEOUT:-3600}"
    oneof rolloutMode "${P_ROLLOUT_MODE:-canary}" canary batches all
    bool backupEnableSSL "${P_BACKUP_ENABLE_SSL:-false}"; bool disableInitialBackup "${P_DISABLE_INITIAL_BACKUP:-false}"
    [[ -z "${P_BACKUP_FULL_RETENTION:-}" ]] || posint backupFullRetention "$P_BACKUP_FULL_RETENTION"
    oneof backupFullRetentionType "${P_BACKUP_FULL_RETENTION_TYPE:-}" "" count time
    P_POSTGRES_PATCH="${P_POSTGRES_OVERLAY_FILES:-}" P_VALUES_PATCH="${P_VALUES_OVERLAY_FILES:-}" \
      P_OPERATOR_VALUES_PATCH="${P_OPERATOR_VALUES_OVERLAY_FILE:-}" patch_inputs_check day0
    ca_inputs_check day0
    instance_inputs
    instance_combinations
    [[ "${#ERRORS[@]}" -gt 0 ]] || P_POSTGRES_PATCH="${P_POSTGRES_OVERLAY_FILES:-}" P_VALUES_PATCH="${P_VALUES_OVERLAY_FILES:-}" \
      P_OPERATOR_VALUES_PATCH="${P_OPERATOR_VALUES_OVERLAY_FILE:-}" patch_files_check
    ;;
  create-instance)
    PW=Overlay; PG=overlays
    if cmap_set; then
      map_exclusive "clusters=${P_CLUSTERS:-}" "instances=${P_INSTANCES:-}"
      map_validate create-instance "$(flags_json "postgresVersion=${P_POSTGRES_VERSION:-}" \
        "highAvailability=${P_HA:-}" "backupEnableSSL=${P_BACKUP_ENABLE_SSL:-false}")"
      [[ -z "${P_HA:-}" ]] || bool highAvailability "$P_HA"
      [[ -z "${P_POSTGRES_VERSION:-}" ]] || pgver postgresVersion "$P_POSTGRES_VERSION"
    else
      clusters_in clusters "${P_CLUSTERS:-}" ""
      instances_in instances "${P_INSTANCES:-}"
      need highAvailability "${P_HA:-}" "true or false"; [[ -z "${P_HA:-}" ]] || bool highAvailability "$P_HA"
      need postgresVersion "${P_POSTGRES_VERSION:-}" "for example postgres-17.6"; [[ -z "${P_POSTGRES_VERSION:-}" ]] || pgver postgresVersion "$P_POSTGRES_VERSION"
    fi
    need pushMode "${P_PUSH_MODE:-}" "direct or pr"; [[ -z "${P_PUSH_MODE:-}" ]] || oneof pushMode "$P_PUSH_MODE" direct pr
    [[ -z "${P_READ_REPLICAS:-}" ]] || nonneg readReplicas "$P_READ_REPLICAS"
    quantity storageSize "${P_STORAGE_SIZE:-}"; quantity walStorageSize "${P_WAL_STORAGE_SIZE:-}"
    quantity cpu "${P_CPU:-}"; quantity memory "${P_MEMORY:-}"
    [[ -z "${P_STORAGE_CLASS:-}" ]] || dnsname storageClass "$P_STORAGE_CLASS"
    backup_ferret_inputs
    bool dryRun "${P_DRY_RUN:-false}"; bool backupEnableSSL "${P_BACKUP_ENABLE_SSL:-false}"; bool disableInitialBackup "${P_DISABLE_INITIAL_BACKUP:-false}"
    [[ -z "${P_BACKUP_FULL_RETENTION:-}" ]] || posint backupFullRetention "$P_BACKUP_FULL_RETENTION"
    oneof backupFullRetentionType "${P_BACKUP_FULL_RETENTION_TYPE:-}" "" count time
    posint maxParallel "${P_MAX_PARALLEL:-2}"; posint syncTimeoutSeconds "${P_TIMEOUT:-1800}"; posint prTimeoutSeconds "${P_PR_TIMEOUT:-3600}"
    oneof rolloutMode "${P_ROLLOUT_MODE:-canary}" canary batches all
    P_POSTGRES_PATCH="${P_POSTGRES_OVERLAY_FILES:-}" P_VALUES_PATCH="${P_VALUES_OVERLAY_FILES:-}" patch_inputs_check create-instance
    ca_inputs_check create-instance
    instance_inputs
    instance_combinations
    [[ "${#ERRORS[@]}" -gt 0 ]] || P_POSTGRES_PATCH="${P_POSTGRES_OVERLAY_FILES:-}" P_VALUES_PATCH="${P_VALUES_OVERLAY_FILES:-}" \
      P_OPERATOR_VALUES_PATCH="" patch_files_check
    ;;
  network-policy)
    need mode "${P_NP_MODE:-}" "apply, update or remove"; [[ -z "${P_NP_MODE:-}" ]] || oneof mode "$P_NP_MODE" apply update remove
    if cmap_set; then
      map_exclusive "clusters=${P_CLUSTERS:-}" "instances=${P_INSTANCES:-}"
      map_validate network-policy "{}"
      if [[ "${P_NP_MODE:-}" == "remove" && -s "$WORK/cmap.json" ]] \
         && jq -e '[.[].instances[] | keys[] | select(. != "postgresVersion")] | length > 0' "$WORK/cmap.json" >/dev/null; then
        err "mode=remove deletes the whole policy: clusterMap may name the instances (and postgresVersion guards) but no rules"
      fi
    else
      clusters_in clusters "${P_CLUSTERS:-}" ""
      instances_in instances "${P_INSTANCES:-}"
    fi
    need pushMode "${P_PUSH_MODE:-}" "direct or pr"; [[ -z "${P_PUSH_MODE:-}" ]] || oneof pushMode "$P_PUSH_MODE" direct pr
    if [[ "${P_NP_MODE:-}" == "remove" ]]; then
      for v in "${P_INGRESS_FROM_NAMESPACES:-}" "${P_INGRESS_FROM_POD_LABELS:-}" "${P_INGRESS_FROM_CIDRS:-}" "${P_EGRESS_TO_CIDRS:-}" "${P_EGRESS_TO_FQDNS:-}"; do
        [[ -z "$v" ]] || { err "mode=remove deletes the whole policy: leave the rule inputs empty"; break; }
      done
    else
      P_NETWORK_POLICY=baseline instance_inputs
    fi
    bool dryRun "${P_DRY_RUN:-false}"; bool connectivityCheck "${CONNECTIVITY_CHECK:-true}"
    posint maxParallel "${P_MAX_PARALLEL:-2}"; posint timeoutSeconds "${P_TIMEOUT:-900}"; posint prTimeoutSeconds "${P_PR_TIMEOUT:-3600}"
    oneof rolloutMode "${P_ROLLOUT_MODE:-canary}" canary batches all
    ;;
  upgrade)
    [[ -z "${P_COMPONENT:-}" ]] || oneof component "$P_COMPONENT" operator postgres
    if cmap_set; then
      map_exclusive "clusters=${P_CLUSTERS:-}" "instances=${P_INSTANCES:-}"
      # targetVersion is the default of the one component the run is limited to
      opv=""; pgv=""
      case "${P_COMPONENT:-}" in
        operator) opv="${P_TARGET_VERSION:-}"; [[ -z "$opv" ]] || opver targetVersion "$opv" ;;
        postgres) pgv="${P_TARGET_VERSION:-}"; [[ -z "$pgv" ]] || pgver targetVersion "$pgv" ;;
        *) [[ -z "${P_TARGET_VERSION:-}" ]] || err "targetVersion needs component=operator or component=postgres with clusterMap (the map carries operatorVersion and postgresVersion)" ;;
      esac
      map_validate upgrade "$(flags_json "operatorVersion=${opv}" "postgresVersion=${pgv}")"
      if [[ -s "$WORK/cmap.json" ]]; then
        if [[ "${P_COMPONENT:-}" == "operator" && -z "$opv" ]] \
           && ! jq -e 'any(.[]; has("operatorVersion"))' "$WORK/cmap.json" >/dev/null; then
          err "component=operator: no cluster in clusterMap has operatorVersion and targetVersion is empty"
        fi
        if [[ "${P_COMPONENT:-}" == "postgres" && -z "$pgv" ]] \
           && ! jq -e 'any(.[]; any(.instances[]?; has("postgresVersion")))' "$WORK/cmap.json" >/dev/null; then
          err "component=postgres: no instance in clusterMap has postgresVersion and targetVersion is empty"
        fi
        if [[ -z "${P_COMPONENT:-}" ]] \
           && ! jq -e 'any(.[]; has("operatorVersion") or any(.instances[]?; has("postgresVersion")))' "$WORK/cmap.json" >/dev/null; then
          err "clusterMap sets no operatorVersion and no postgresVersion: nothing to upgrade"
        fi
      fi
      if [[ "${P_COMPONENT:-}" != "operator" ]] && { [[ "${P_ALLOW_MAJOR:-false}" == "true" ]] \
           || jq -e 'any(.[]; any(.instances[]?; .allowMajor == "true"))' "$WORK/cmap.json" >/dev/null 2>&1; }; then
        echo true > /tmp/approval
      fi
    else
      need component "${P_COMPONENT:-}" "operator or postgres (or clusterMap)"
      need targetVersion "${P_TARGET_VERSION:-}" "operator: v4.5.0; postgres: postgres-17.6"
      if [[ -n "${P_TARGET_VERSION:-}" ]]; then
        case "${P_COMPONENT:-}" in
          operator) opver targetVersion "$P_TARGET_VERSION" ;;
          postgres) pgver targetVersion "$P_TARGET_VERSION" ;;
        esac
      fi
      clusters_in clusters "${P_CLUSTERS:-}" allow
      if [[ "${P_COMPONENT:-}" == "postgres" ]]; then
        instances_in instances "${P_INSTANCES:-}" allow
        [[ "${P_ALLOW_MAJOR:-false}" != "true" ]] || echo true > /tmp/approval
      elif [[ -n "${P_INSTANCES:-}" ]]; then
        err "instances applies only to component=postgres (the operator is upgraded for the whole cluster)"
      fi
    fi
    need pushMode "${P_PUSH_MODE:-}" "direct or pr"; [[ -z "${P_PUSH_MODE:-}" ]] || oneof pushMode "$P_PUSH_MODE" direct pr
    bool preUpgradeBackup "${P_PRE_BACKUP:-true}"; bool allowMajor "${P_ALLOW_MAJOR:-false}"; bool dryRun "${P_DRY_RUN:-false}"
    posint maxParallel "${P_MAX_PARALLEL:-1}"; posint timeoutSeconds "${P_TIMEOUT:-1800}"; posint prTimeoutSeconds "${P_PR_TIMEOUT:-3600}"
    oneof rolloutMode "${P_ROLLOUT_MODE:-canary}" canary batches all
    [[ "$(cat /tmp/approval)" != "true" || "${P_DRY_RUN:-false}" != "true" ]] || echo false > /tmp/approval
    ;;
  patch)
    patch_inputs_check patch
    ca_inputs_check patch
    any_file="${P_POSTGRES_PATCH:-}${P_VALUES_PATCH:-}${P_OPERATOR_VALUES_PATCH:-}"
    any_ca="${P_BACKUP_CA_FILE:-}${P_BACKUP_CA_VAULT:-}"
    oneof patchMode "${P_PATCH_MODE:-apply}" apply clear
    if [[ "${P_PATCH_MODE:-apply}" == clear ]]; then
      [[ -z "$any_file$any_ca" ]] || err "patchMode=clear takes no path or CA bundle inputs: clearKinds names the kinds whose current file is removed"
    else
      [[ -z "${P_CLEAR_KINDS:-}" ]] || err "clearKinds applies to patchMode=clear only"
    fi
    if cmap_set; then
      map_exclusive "clusters=${P_CLUSTERS:-}" "instances=${P_INSTANCES:-}"
      map_validate patch "$(flags_json "operatorValuesPatchFilePath=${P_OPERATOR_VALUES_PATCH:-}" "clearKinds=${P_CLEAR_KINDS:-}")"
      if [[ -s "$WORK/cmap.json" ]]; then
        # patchMode per target: the instance key, the cluster key, the input
        bad="$(jq -r --arg m "${P_PATCH_MODE:-apply}" --arg ck "${P_CLEAR_KINDS:-}" --arg pp "${P_POSTGRES_PATCH:-}${P_VALUES_PATCH:-}${any_ca}" '
          def pm($x; $d): ($x.patchMode // $d);
          to_entries[] | .key as $c | .value as $cv | pm($cv; $m) as $cm
          | (if $cm == "clear" and ($cv.operatorValuesPatchFilePath != null) then "clusterMap." + $c + ": patchMode=clear takes no operatorValuesPatchFilePath (clearKinds operatorValues)" else empty end),
            (if $cm != "clear" and ($cv.clearKinds != null) then "clusterMap." + $c + ": clearKinds applies to patchMode=clear only" else empty end),
            (($cv.instances // {}) | to_entries[] | .key as $i | .value as $iv | pm($iv; $cm) as $im
             | "clusterMap." + $c + ".instances." + $i as $w
             | if $im == "clear" then
                 (if ($iv.postgresPatchFilePath != null or $iv.postgresValuesPatchFilePath != null) then $w + ": patchMode=clear takes no path keys (clearKinds names the kinds)" else empty end),
                 (if ($iv.clearKinds // $cv.clearKinds // $ck) == "" or ($iv.clearKinds // $cv.clearKinds // $ck) == null then $w + ": patchMode=clear needs clearKinds (map key or input)" else empty end)
               else
                 (if $iv.clearKinds != null then $w + ": clearKinds applies to patchMode=clear only" else empty end),
                 (if ($iv.postgresPatchFilePath == null and $iv.postgresValuesPatchFilePath == null
                      and $iv.backupCaBundleFile == null and $iv.backupCaBundleVaultSecret == null
                      and $cv.backupCaBundleFile == null and $cv.backupCaBundleVaultSecret == null and $pp == "")
                  then $w + ": no postgresPatchFilePath, postgresValuesPatchFilePath or CA bundle source (map key or workflow input)" else empty end)
               end)' "$WORK/cmap.json")"
        while IFS= read -r line; do [[ -z "$line" ]] || err "$line"; done <<<"$bad"
      fi
    else
      clusters_in clusters "${P_CLUSTERS:-}" allow
      [[ -z "${P_INSTANCES:-}" ]] || instances_in instances "$P_INSTANCES" allow
      if [[ "${P_PATCH_MODE:-apply}" == clear ]]; then
        need clearKinds "${P_CLEAR_KINDS:-}" "the kinds to clear: Postgres, PostgresBackupLocation, PostgresBackupSchedule, PostgresFerretDocumentDB, postgresValues, operatorValues, or all"
        if [[ -n "${P_CLEAR_KINDS:-}" ]]; then
          kinds_check clearKinds "$P_CLEAR_KINDS"
          ck=",$(list_csv clearKinds "$P_CLEAR_KINDS" --bare all 2>/dev/null || true),"
          if [[ "$ck" =~ ,(all|Postgres|PostgresBackupLocation|PostgresBackupSchedule|PostgresFerretDocumentDB|postgresValues), && -z "${P_INSTANCES:-}" ]]; then
            err "clearKinds ${P_CLEAR_KINDS} clears instance patches: set instances (a list in brackets, or all)"
          fi
          if [[ -n "${P_INSTANCES:-}" && ! "$ck" =~ ,(all|Postgres|PostgresBackupLocation|PostgresBackupSchedule|PostgresFerretDocumentDB|postgresValues), ]]; then
            err "instances is set but clearKinds names no instance kind"
          fi
        fi
      else
        [[ -n "$any_file$any_ca" ]] \
          || err "no patch file: set postgresPatchFilePath, postgresValuesPatchFilePath, operatorValuesPatchFilePath or a CA bundle source (or clusterMap)"
        [[ -z "${P_POSTGRES_PATCH:-}${P_VALUES_PATCH:-}${any_ca}" || -n "${P_INSTANCES:-}" ]] \
          || err "postgresPatchFilePath, postgresValuesPatchFilePath and the CA bundle sources need instances (a list in brackets, or all)"
        [[ -z "${P_INSTANCES:-}" || -n "${P_POSTGRES_PATCH:-}${P_VALUES_PATCH:-}${any_ca}" ]] \
          || err "instances is set but no instance patch file or CA bundle source"
      fi
    fi
    need pushMode "${P_PUSH_MODE:-}" "direct or pr"; [[ -z "${P_PUSH_MODE:-}" ]] || oneof pushMode "$P_PUSH_MODE" direct pr
    posint maxParallel "${P_MAX_PARALLEL:-1}"; posint timeoutSeconds "${P_TIMEOUT:-1800}"; posint prTimeoutSeconds "${P_PR_TIMEOUT:-3600}"
    oneof rolloutMode "${P_ROLLOUT_MODE:-canary}" canary batches all
    bool dryRun "${P_DRY_RUN:-false}"
    [[ "${#ERRORS[@]}" -gt 0 ]] || patch_files_check
    ;;
  scale)
    if cmap_set; then
      map_exclusive "clusters=${P_CLUSTERS:-}" "instances=${P_INSTANCES:-}"
      map_validate scale "$(flags_json "replicas=${P_REPLICAS:-}" "maxReadReplicas=${P_MAX_READ_REPLICAS:-}")"
    else
      clusters_in clusters "${P_CLUSTERS:-}" ""
      if [[ -n "${P_INSTANCES:-}" ]]; then
        instances_in instances "${P_INSTANCES}" ""
        need replicas "${P_REPLICAS:-}" "number of read replicas (0 to maxReadReplicas)"
      elif [[ -z "${P_MAX_READ_REPLICAS:-}" ]]; then
        err "instances is mandatory: the instances to scale on every listed cluster (with replicas), unless the run only sets maxReadReplicas"
      else
        [[ -z "${P_REPLICAS:-}" ]] || err "replicas needs instances: name the instances to scale, or leave replicas empty to set only maxReadReplicas"
      fi
    fi
    [[ -z "${P_REPLICAS:-}" ]] || nonneg replicas "$P_REPLICAS"
    [[ -z "${P_MAX_READ_REPLICAS:-}" ]] || posint maxReadReplicas "$P_MAX_READ_REPLICAS"
    need pushMode "${P_PUSH_MODE:-}" "direct or pr"; [[ -z "${P_PUSH_MODE:-}" ]] || oneof pushMode "$P_PUSH_MODE" direct pr
    bool enableHAIfNeeded "${P_ENABLE_HA:-true}"; bool dryRun "${P_DRY_RUN:-false}"
    posint maxParallel "${P_MAX_PARALLEL:-2}"; oneof rolloutMode "${P_ROLLOUT_MODE:-all}" canary batches all
    posint timeoutSeconds "${P_TIMEOUT:-900}"; posint prTimeoutSeconds "${P_PR_TIMEOUT:-3600}"
    [[ "${#ERRORS[@]}" -gt 0 ]] || scale_ha_check
    [[ "${#ERRORS[@]}" -gt 0 ]] || scale_cap_check
    ;;
  backup)
    if cmap_set; then
      map_exclusive "instances=${P_INSTANCES:-}"
      [[ -z "${P_CLUSTERS:-}" || "${P_CLUSTERS}" == "all" ]] \
        || err "clusterMap and clusters cannot be used together: the map selects the clusters and instances (got clusters='${P_CLUSTERS}')"
      map_validate backup "{}"
    else
      clusters_in clusters "${P_CLUSTERS:-all}" allow
      [[ -z "${P_INSTANCES:-}" ]] || instances_in instances "$P_INSTANCES" allow
    fi
    oneof backupType "${P_BACKUP_TYPE:-full}" full incremental differential
    posint backupTimeoutSeconds "${P_TIMEOUT:-10800}"
    bool scheduledOnly "${P_SCHEDULED_ONLY:-false}"
    ;;
  restore)
    need sourceCluster "${P_SOURCE_CLUSTER:-}" "one registered cluster. Registered clusters: ${REG_LIST:-none}"
    cluster_one sourceCluster "${P_SOURCE_CLUSTER:-}"
    need instance "${P_INSTANCE:-}" "the Postgres instance to restore from"; [[ -z "${P_INSTANCE:-}" ]] || dnsname instance "$P_INSTANCE"
    need mode "${P_MODE:-}" "time, latest, backup, lsn or xid"
    [[ -z "${P_MODE:-}" ]] || oneof mode "$P_MODE" time latest backup lsn xid
    case "${P_MODE:-}" in
      time)
        need targetTime "${P_TARGET_TIME:-}" "UTC timestamp such as 2026-09-01T10:30:00Z"
        [[ -z "${P_TARGET_TIME:-}" || "$P_TARGET_TIME" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
          || err "targetTime must look like 2026-09-01T10:30:00Z" ;;
      backup) need backupName "${P_BACKUP_NAME:-}" "a PostgresBackup name in the source namespace" ;;
      lsn) need lsn "${P_LSN:-}" "a log sequence number" ;;
      xid) need xid "${P_XID:-}" "a transaction ID"; [[ -z "${P_XID:-}" ]] || nonneg xid "$P_XID" ;;
    esac
    # Exactly one recovery point for the chosen mode
    given=""
    [[ -z "${P_TARGET_TIME:-}" ]] || given="${given}targetTime "
    [[ -z "${P_BACKUP_NAME:-}" ]] || given="${given}backupName "
    [[ -z "${P_LSN:-}" ]] || given="${given}lsn "
    [[ -z "${P_XID:-}" ]] || given="${given}xid "
    case "$(printf '%s' "$given" | wc -w)" in
      0|1) ;;  # 0 is already reported by the per-mode need above (mode=latest takes none)
      *) err "set only the recovery point of the chosen mode (given: ${given})" ;;
    esac
    [[ "${P_MODE:-}" != "latest" || -z "$given" ]] || err "mode=latest takes no recovery point (given: ${given})"
    if [[ -n "${P_TARGET_CLUSTER:-}" ]]; then
      cluster_one targetCluster "$P_TARGET_CLUSTER"
      [[ "${P_MODE:-}" != "backup" || "$P_TARGET_CLUSTER" == "${P_SOURCE_CLUSTER:-}" ]] \
        || err "mode=backup restores only inside the source namespace; use time, latest, lsn or xid for another cluster"
    fi
    [[ -z "${P_TARGET_INSTANCE:-}" ]] || dnsname targetInstance "$P_TARGET_INSTANCE"
    if [[ "${P_MODE:-}" == "backup" && -z "${P_TARGET_INSTANCE:-}" && -n "${P_INSTANCE:-}" ]]; then
      err "mode=backup restores only inside the source namespace, and the default target is a new instance in its own namespace: set targetInstance=${P_INSTANCE} and confirm=${P_INSTANCE} (in place), or use time, latest, lsn or xid"
    fi
    if [[ -n "${P_TARGET_INSTANCE:-}" && "${P_TARGET_INSTANCE}" != "${P_INSTANCE:-}" && "${P_MODE:-}" == "backup" ]]; then
      err "mode=backup restores only inside the source namespace (a new target is created in its own namespace, pg-${P_TARGET_INSTANCE}); use time, latest, lsn or xid"
    fi
    if [[ "${P_TARGET_INSTANCE:-}" == "${P_INSTANCE:-}" && -n "${P_INSTANCE:-}" ]]; then
      [[ "${P_CONFIRM:-}" == "${P_INSTANCE}" ]] || err "an in-place restore overwrites ${P_INSTANCE}: set confirm=${P_INSTANCE}"
    fi
    oneof pushMode "${P_PUSH_MODE:-direct}" direct pr
    bool bestEffort "${P_BEST_EFFORT:-false}"
    posint restoreTimeoutSeconds "${P_TIMEOUT:-7200}"; posint prTimeoutSeconds "${P_PR_TIMEOUT:-3600}"
    ;;
  delete-instance)
    oneof finalBackup "${P_FINAL_BACKUP:-true}" true false required
    bool purgePvcs "${P_PURGE_PVCS:-false}"; bool purgeNamespace "${P_PURGE_NS:-false}"; bool purgeBackups "${P_PURGE_BACKUPS:-false}"
    if cmap_set; then
      map_exclusive "clusters=${P_CLUSTERS:-}" "instances=${P_INSTANCES:-}"
      map_validate delete-instance "{}"
      need confirm "${P_CONFIRM:-}" "repeat the cluster names of clusterMap, in brackets"
      if [[ -n "${P_CONFIRM:-}" && -s "$WORK/cmap.json" ]]; then
        list_get confirm "$P_CONFIRM" \
          && { same_set confirm "$P_CONFIRM" clusterMap "$(bracket_keys "$WORK/cmap.json")" \
               || err "confirm must repeat the cluster names of clusterMap ($(bracket_keys "$WORK/cmap.json"))"; }
      fi
      map_each_instance "((.v.purgeNamespace // \"${P_PURGE_NS:-false}\") != \"true\") or ((.v.purgePvcs // \"${P_PURGE_PVCS:-false}\") == \"true\")" \
        "purgeNamespace=true needs purgePvcs=true"
      map_each_instance "((.v.purgeBackups // \"${P_PURGE_BACKUPS:-false}\") != \"true\") or ((.v.finalBackup // \"${P_FINAL_BACKUP:-true}\") == \"false\")" \
        "purgeBackups=true needs finalBackup=false (a final backup would be expired and its blobs deleted at once)"
    else
      clusters_in clusters "${P_CLUSTERS:-}" ""
      instances_in instances "${P_INSTANCES:-}" ""
      need confirm "${P_CONFIRM:-}" "repeat the instances value, in brackets"
      if [[ -n "${P_CONFIRM:-}" && -n "${P_INSTANCES:-}" ]]; then
        list_get confirm "$P_CONFIRM" \
          && { same_set confirm "$P_CONFIRM" instances "$P_INSTANCES" || err "confirm must repeat the instances value (${P_INSTANCES})"; }
      fi
      [[ "${P_PURGE_NS:-false}" != "true" || "${P_PURGE_PVCS:-false}" == "true" ]] || err "purgeNamespace=true needs purgePvcs=true"
      [[ "${P_PURGE_BACKUPS:-false}" != "true" || "${P_FINAL_BACKUP:-true}" == "false" ]] \
        || err "purgeBackups=true needs finalBackup=false (finalBackup is ${P_FINAL_BACKUP:-true}): a final backup would be expired and its blobs deleted at once"
    fi
    oneof pushMode "${P_PUSH_MODE:-direct}" direct pr
    posint timeoutSeconds "${P_TIMEOUT:-1800}"; posint prTimeoutSeconds "${P_PR_TIMEOUT:-3600}"
    ;;
  delete-apps)
    if cmap_set; then
      map_exclusive "clusters=${P_CLUSTERS:-}" "apps=${P_APPS:-}"
      map_validate delete-apps "{}"
      need confirm "${P_CONFIRM:-}" "repeat the cluster names of clusterMap, in brackets"
      if [[ -n "${P_CONFIRM:-}" && -s "$WORK/cmap.json" ]]; then
        list_get confirm "$P_CONFIRM" \
          && { same_set confirm "$P_CONFIRM" clusterMap "$(bracket_keys "$WORK/cmap.json")" \
               || err "confirm must repeat the cluster names of clusterMap ($(bracket_keys "$WORK/cmap.json"))"; }
      fi
      # purgePvcs and purgeNamespace have no default: the map key or the input for every instance
      map_each_instance "(.v.purgePvcs // \"${P_PURGE_PVCS:-}\") != \"\"" "purgePvcs is required (map key or workflow input: true deletes PVCs and Azure disks, false keeps them)"
      map_each_instance "(.v.purgeNamespace // \"${P_PURGE_NS:-}\") != \"\"" "purgeNamespace is required (map key or workflow input)"
      map_each_instance "((.v.purgeNamespace // \"${P_PURGE_NS:-}\") != \"true\") or ((.v.purgePvcs // \"${P_PURGE_PVCS:-}\") == \"true\")" \
        "purgeNamespace=true needs purgePvcs=true"
      map_each_instance "((.v.purgeBackups // \"${P_PURGE_BACKUPS:-false}\") != \"true\") or ((.v.finalBackup // \"${P_FINAL_BACKUP:-true}\") == \"false\")" \
        "purgeBackups=true needs finalBackup=false (a final backup would be expired and its blobs deleted at once)"
    else
      clusters_in clusters "${P_CLUSTERS:-}" ""
      need apps "${P_APPS:-}" 'JSON map, for example {"aks-tpg-poc-01":["tpg-instances:orders-db","tpg-instances:billing-db","tpg-operator"]} (or clusterMap)'
      if [[ -n "${P_APPS:-}" ]]; then
        if ! jq -e 'type == "object"' <<<"$P_APPS" >/dev/null 2>&1; then
          err "apps must be a JSON object that maps each cluster to a list of applications"
        else
          for c in $(jq -r '.[]' /tmp/clusters.json); do
            jq -e --arg c "$c" 'has($c) and (.[$c] | type == "array" and length > 0)' <<<"$P_APPS" >/dev/null \
              || err "apps has no application list for cluster ${c}"
          done
          for c in $(jq -r 'keys[]' <<<"$P_APPS"); do
            jq -e --arg c "$c" 'index($c)' /tmp/clusters.json >/dev/null || err "apps lists cluster ${c}, which is not in clusters"
          done
          while read -r a; do
            [[ -z "$a" ]] && continue
            case "$a" in
              tpg-operator|tpg-instances|tpg-instances:all) ;;
              tpg-instances:*,*) err "apps: '${a}' names several instances in one element; write one element per instance: \"tpg-instances:${a#tpg-instances:}\" becomes $(split_list "${a#tpg-instances:}" | sed 's/.*/"tpg-instances:&"/' | paste -sd, - | sed 's/,/, /g')" ;;
              tpg-instances:*) dnsname "apps instance" "${a#tpg-instances:}" ;;
              *) err "apps: unknown application '${a}'; use tpg-instances, tpg-instances:<instance> (one element per instance) or tpg-operator" ;;
            esac
          done < <(jq -r '.[] | .[]? | tostring' <<<"$P_APPS")
        fi
      fi
      need confirm "${P_CONFIRM:-}" "repeat the clusters value, in brackets"
      if [[ -n "${P_CONFIRM:-}" ]]; then
        list_get confirm "$P_CONFIRM" \
          && { same_set confirm "$P_CONFIRM" clusters "${P_CLUSTERS:-}" || err "confirm must repeat the clusters value (${P_CLUSTERS:-})"; }
      fi
      need purgePvcs "${P_PURGE_PVCS:-}" "true deletes PVCs and Azure disks, false keeps them"
      need purgeNamespace "${P_PURGE_NS:-}" "true deletes the instance namespaces (refused while another instance uses one), false keeps them"
      [[ "${P_PURGE_NS:-}" != "true" || "${P_PURGE_PVCS:-}" == "true" ]] || err "purgeNamespace=true needs purgePvcs=true"
      [[ "${P_PURGE_BACKUPS:-false}" != "true" || "${P_FINAL_BACKUP:-true}" == "false" ]] \
        || err "purgeBackups=true needs finalBackup=false (finalBackup is ${P_FINAL_BACKUP:-true}): a final backup would be expired and its blobs deleted at once"
    fi
    need dryRun "${P_DRY_RUN:-}" "true (plan only) or false"; [[ -z "${P_DRY_RUN:-}" ]] || bool dryRun "$P_DRY_RUN"
    [[ -z "${P_PURGE_PVCS:-}" ]] || bool purgePvcs "$P_PURGE_PVCS"
    [[ -z "${P_PURGE_NS:-}" ]] || bool purgeNamespace "$P_PURGE_NS"
    need pushMode "${P_PUSH_MODE:-}" "direct or pr"; [[ -z "${P_PUSH_MODE:-}" ]] || oneof pushMode "$P_PUSH_MODE" direct pr
    bool force "${P_FORCE:-false}"; oneof finalBackup "${P_FINAL_BACKUP:-true}" true false required
    bool purgeBackups "${P_PURGE_BACKUPS:-false}"
    posint timeoutSeconds "${P_TIMEOUT:-1800}"; posint prTimeoutSeconds "${P_PR_TIMEOUT:-3600}"
    ;;
  backup-expire)
    # tpg-backup-expire (Round 23, locked decision 5): clusterMap only. Per instance backups: [..] or
    # purgeBackups: true (not both); includeDependents: true only with backups; dryRun true by default;
    # confirm = the cluster names of the map when dryRun=false
    bool dryRun "${P_DRY_RUN:-true}"; posint timeoutSeconds "${P_TIMEOUT:-600}"
    if ! cmap_set; then
      err "clusterMap is mandatory: tpg-backup-expire takes its targets from the map, {aks-tpg-poc-01: {instances: {orders-db: {backups: [orders-db-full-202609010100]}}}} (or purgeBackups: true to expire every backup of the instance)"
    else
      map_validate backup-expire "{}"
      map_each_instance '(.v | has("backups")) or ((.v.purgeBackups // "false") == "true")' \
        "name the backups to expire, backups: [..], or purgeBackups: true to expire all of them"
      map_each_instance '((.v | has("backups")) and ((.v.purgeBackups // "false") == "true")) | not' \
        "backups and purgeBackups: true cannot be used together: list the backups, or purge all of them"
      map_each_instance '((.v.includeDependents // "false") != "true") or (.v | has("backups"))' \
        "includeDependents applies to backups: [..] only (purgeBackups: true expires every backup, dependents first)"
      if [[ -n "${P_CONFIRM:-}" ]]; then
        if list_get confirm "$P_CONFIRM" && [[ -s "$WORK/cmap.json" ]]; then
          same_set confirm "$P_CONFIRM" clusterMap "$(bracket_keys "$WORK/cmap.json")" \
            || err "confirm must repeat the cluster names of clusterMap ($(bracket_keys "$WORK/cmap.json"))"
        fi
      elif [[ "${P_DRY_RUN:-true}" == "false" && -s "$WORK/cmap.json" ]]; then
        err "confirm is mandatory with dryRun=false: repeat the cluster names of clusterMap, $(bracket_keys "$WORK/cmap.json") (run with dryRun=true first to see the plan)"
      fi
    fi
    ;;
  helm-addons)
    clusters_in clusters "${P_CLUSTERS:-}" allow
    # auto stays bare; the others are a bracketed list, [cert-manager, vso]
    if [[ "${P_COMPONENTS:-auto}" != auto ]]; then
      list_get components "${P_COMPONENTS:-auto}" --bare auto \
        && for comp in ${LIST[@]+"${LIST[@]}"}; do
          if [[ "$comp" == auto ]]; then err "components: auto stands alone, without brackets: components=auto"
          else oneof components "$comp" cert-manager vso monitoring; fi
        done
    fi
    bool dryRun "${P_DRY_RUN:-false}"
    oneof existingAddons "${P_EXISTING:-skip}" skip upgrade
    ;;
  rotate)
    # tpg-rotate-credential (Round 15, D87)
    oneof secretType "${P_SECRET_TYPE:-}" broadcom-registry backup-storage git-push git-read monitoring-remote-write ca-bundle custom
    case "${P_SECRET_TYPE:-}" in
      ca-bundle|custom)
        need secretName "${P_SECRET_NAME:-}" "the name under tpg/${P_SECRET_TYPE/ca-bundle/ca-bundles}/"
        [[ -z "${P_SECRET_NAME:-}" ]] || k8sname secretName "$P_SECRET_NAME" ;;
      *) [[ -z "${P_SECRET_NAME:-}" ]] || err "secretName applies to secretType ca-bundle and custom only (${P_SECRET_TYPE:-} has a fixed path)" ;;
    esac
    clusters_in clusters "${P_CLUSTERS:-all}" allow
    posint maxParallel "${P_MAX_PARALLEL:-5}"
    tokenv="$(kubectl -n "$ARGO_NS" get workflow "$WF" -o json 2>/dev/null \
      | jq -r '[.spec.arguments.parameters[]? | select(.name == "wrappingToken") | (.value // "")][0] // ""')" || tokenv=""
    # the length apart from the pattern: a POSIX regex repeat count is limited to 255 (musl in the
    # tools image refuses {16,512}: "Invalid contents of {}")
    [[ -z "$tokenv" || ( ${#tokenv} -ge 16 && ${#tokenv} -le 512 && "$tokenv" =~ ^[A-Za-z0-9._-]+$ ) ]] || err "wrappingToken is not a Vault token (16 to 512 letters, digits, '.', '_', '-')"
    file_get caBundleFile "${P_CA_FILE:-}"
    if [[ -n "$FILE" ]]; then
      ca_path="$FILE"
      [[ "${P_SECRET_TYPE:-}" == ca-bundle ]] || err "caBundleFile applies to secretType ca-bundle only"
      [[ -z "$tokenv" ]] || err "caBundleFile and wrappingToken cannot be used together: the CA bundle comes from one of them"
      # a file of the submitting machine only: the write step runs without the Git
      # credential, and a bundle kept in the fleet repository needs no copy in Vault
      # (tpg-day0, tpg-create-instance and tpg-patch read backupCaBundleFile=[repo:...] directly)
      if [[ "$ca_path" == repo:* ]]; then
        err "caBundleFile: '${ca_path}': tpg-rotate-credential takes a PEM file of the submitting machine, not a repo: file; use backupCaBundleFile=[${ca_path}] in tpg-day0, tpg-create-instance or tpg-patch instead"
      else
        [[ "$ca_path" =~ $PATCH_LOCAL_CA_RE ]] || err "caBundleFile: '${ca_path}' must be the path of one PEM file (.pem, .crt or .cer), in brackets: [path]"
        [[ "${#ERRORS[@]}" -gt 0 ]] || P_BACKUP_CA_FILE="$P_CA_FILE" patch_files_check
      fi
    fi
    # the write step runs for a value to write: the template's when: reads this file, not the raw
    # inputs (a caBundleFile element may hold quotes and brackets)
    [[ -z "$tokenv" && -z "$FILE" ]] || echo true > /tmp/hasWrite
    if [[ "${P_SECRET_TYPE:-}" == custom && -z "$tokenv" ]]; then
      err "secretType=custom needs wrappingToken (tpg-aks-infra scripts/vault-secret.sh wrap custom ${P_SECRET_NAME:-<name>})"
    fi
    ;;
  *) err "unknown validation mode ${MODE}" ;;
esac

if [[ "${#ERRORS[@]}" -gt 0 ]]; then
  echo "Invalid input parameters:" >&2
  printf '  - %s\n' "${ERRORS[@]}" >&2
  exit 1
fi
[[ "$(jq 'length' /tmp/clusters.json)" -gt 0 || "$MODE" == "restore" ]] \
  || { echo "no registered clusters selected (registered: ${REG_LIST:-none})" >&2; exit 1; }
# The selection the discover step reads: "all" keeps its meaning there (every
# registered cluster with an entry in clusters/fleet.yaml)
if cmap_set; then
  jq -r 'join(",")' /tmp/clusters.json > /tmp/selection
elif sel_in="${P_CLUSTERS:-}"; sel_in="${sel_in//[[:space:]]/}"; [[ "$sel_in" == "all" || -z "$sel_in" ]]; then
  printf '%s' "${sel_in:-all}" > /tmp/selection
else
  jq -r 'join(",")' /tmp/clusters.json > /tmp/selection
fi
log "parameters valid (${MODE}); clusters $(cat /tmp/clusters.json)$(cmap_set && printf ' from clusterMap')"
