#!/usr/bin/env bash
# patch-lib.sh: the per-cluster work of tpg-patch (Round 14, design decisions D76
# to D79). Sourced after lib.sh by patch-plan.sh (every cluster, before anything
# changes) and patch-cluster.sh (one cluster, under its mutex, on a fresh clone of
# the fleet branch), so both steps check, render and diff the same way.
#
# The caller sets REPO (a fleet repository checkout) and C_ERRS=() per cluster.
#   patch_targets CLUSTER INVENTORY   what the inputs ask for on the cluster (JSON):
#                                     {operator: null | {path, mode},
#                                      instances: [{name, postgres: null | {paths, mode, clear},
#                                                   postgresValues: null | {path, mode}}]}
#   patch_render_all CLUSTER TARGETS WHEN
#                                     render every target from REPO into
#                                     $WORK/render/<WHEN>-<cluster>-<target>.yaml
#                                     (WHEN before or after)
#   patch_prepare CLUSTER TARGETS     store the files (postgresValues and operator under
#                                     their UID names; the postgres documents combined
#                                     with the kinds the current file carries, D81),
#                                     make them current (the old current becomes
#                                     previous), write the operator's effective values
#                                     file; check each file against clusters/fleet.yaml
#                                     and the cluster. Sets PREP_PLAN {instances: [...],
#                                     operator: bool} and PREP_POSTGRES
#   patch_warnings CLUSTER            after the render: PATCH_OVERRIDES_VALUE and
#                                     PATCH_TARGET_NOT_RENDERED (D82)
#   patch_dry_run CLUSTER             the after renders through the API server
#                                     (--dry-run=server): the render and admission errors
#   patch_diff CLUSTER                what a sync would change, printed to the log:
#                                     objects the patch no longer renders (the sync
#                                     prunes them) and kubectl diff --server-side of the
#                                     rendered objects against the live ones. Sets
#                                     PATCH_CHANGED (targets with a change)
# Every refusal is appended to C_ERRS; the caller records it (PATCH_REFUSED).
PATCH_CHART_PREFIX="helm_artifacts/instance/tpg-instance/"
patch_schemas_file() {
  if [[ -f "$TPG_LIB_DIR/patch-schemas.json" ]]; then printf '%s' "$TPG_LIB_DIR/patch-schemas.json"
  else printf '%s' "$TPG_LIB_DIR/../params/patch-schemas.json"; fi
}
# The Argo CD field manager (server-side apply) and tracking method of the hub
ARGOCD_MANAGER="argocd-controller"

patch_targets() {  # patch_targets CLUSTER INVENTORY_JSON -> the targets of the cluster (JSON)
  # {operator: null | {path, mode, clear},
  #  instances: [{name, postgres: null | {paths, mode, clear}, postgresValues: null | {path, mode, clear}}]}
  # apply: the path inputs and clusterMap keys (paths: comma-separated);
  # clear: clearKinds (instance key, cluster key, input), whose instance kinds clear
  # the instance's files and operatorValues the cluster's operator file (D82)
  local c="$1" inv="$2" op opm ock out i pg val m ik ca
  opm="$(cmap_cval "$c" patchMode "${P_PATCH_MODE:-apply}")"
  ock="$(cmap_cval "$c" clearKinds "${P_CLEAR_KINDS:-}")"
  if [[ "$opm" == clear ]]; then
    op=""
    if [[ ",${ock// /}," == *",all,"* || ",${ock// /}," == *",operatorValues,"* ]]; then op="clear"; fi
    out="$(jq -cn --arg p "$op" '{operator: (if $p == "" then null else {path: "", mode: "clear"} end), instances: []}')"
  else
    op="$(cmap_cval "$c" operatorValuesPatchFilePath "${P_OPERATOR_VALUES_PATCH:-}")"
    out="$(jq -cn --arg p "$op" '{operator: (if $p == "" then null else {path: $p, mode: "apply"} end), instances: []}')"
  fi
  for i in $(jq -r --arg c "$c" '.[] | select(.name == $c) | .instances[].name' <<<"$inv"); do
    m="$(cmap_ival "$c" "$i" patchMode "$opm")"
    if [[ "$m" == clear ]]; then
      ik="$(cmap_ival "$c" "$i" clearKinds "$ock")"; ik="${ik// /}"
      pg="$(tr ',' '\n' <<<"$ik" | grep -E '^(all|Postgres|PostgresBackupLocation|PostgresBackupSchedule|PostgresFerretDocumentDB)$' | paste -sd, - || true)"
      val=""; [[ ",${ik}," == *",all,"* || ",${ik}," == *",postgresValues,"* ]] && val=clear
      [[ -n "$pg$val" ]] || continue
      out="$(jq -c --arg i "$i" --arg pg "$pg" --arg v "$val" '.instances += [{name: $i,
        postgres: (if $pg == "" then null else {paths: "", mode: "clear", clear: $pg} end),
        postgresValues: (if $v == "" then null else {path: "", mode: "clear"} end)}]' <<<"$out")"
    else
      pg="$(cmap_ival "$c" "$i" postgresPatchFilePath "${P_POSTGRES_PATCH:-}")"
      val="$(cmap_ival "$c" "$i" postgresValuesPatchFilePath "${P_VALUES_PATCH:-}")"
      # a CA bundle source of the instance, its cluster or the inputs (Round 15, D86)
      ca="$(cmap_ival "$c" "$i" backupCaBundleFile)$(cmap_ival "$c" "$i" backupCaBundleVaultSecret)$(cmap_cval "$c" backupCaBundleFile)$(cmap_cval "$c" backupCaBundleVaultSecret)${P_BACKUP_CA_FILE:-}${P_BACKUP_CA_VAULT:-}"
      [[ -n "$pg$val$ca" ]] || continue
      pg="$(split_list "$pg" | paste -sd, -)"
      out="$(jq -c --arg i "$i" --arg pg "$pg" --arg v "$val" --arg ca "$ca" '.instances += [{name: $i,
        postgres: (if $pg == "" then null else {paths: $pg, mode: "apply", clear: ""} end),
        postgresValues: (if $v == "" then null else {path: $v, mode: "apply"} end),
        ca: ($ca != "")}]' <<<"$out")"
    fi
  done
  printf '%s' "$out"
}

# ---- checks that need clusters/fleet.yaml or the cluster (the validate step has
# checked the type and shape of every file already: workflows/scripts/patchcheck.py;
# the field rules are lib.sh patch_postgres_errors and patch_values_errors)
patch_check_postgres() {  # patch_check_postgres FILE(repo path) NAME CLUSTER INSTANCE [CURRENT(chart-relative)]
  local line
  while IFS= read -r line; do [[ -z "$line" ]] || C_ERRS+=("$line"); done \
    < <(patch_postgres_errors "$REPO/$1" "$2" "$3" "$4" running ${5:+"$REPO/${PATCH_CHART_PREFIX}$5"})
}

patch_check_values() {  # patch_check_values FILE(repo path) NAME CLUSTER INSTANCE
  local line
  while IFS= read -r line; do [[ -z "$line" ]] || C_ERRS+=("$line"); done \
    < <(patch_values_errors "$REPO/$1" "$2" "$3" "$4" running)
}

patch_check_operator() {  # patch_check_operator FILE(repo path) NAME CLUSTER (use_cluster first)
  local line want
  want="$(C="$3" yq -r '.clusters[strenv(C)].operator.version // ""' "$REPO/$FLEET_REL")"
  while IFS= read -r line; do [[ -z "$line" ]] || C_ERRS+=("$line"); done \
    < <(patch_operator_errors "$REPO/$1" "$2" "$3" "$want")
}

patch_repo_check() {
  # patch_repo_check KIND PATH...: the repo: files exist on the fleet branch and fit
  # their input (the validate step cannot read the repository; patchcheck.py)
  local kind="$1" p tmp out line
  shift
  tmp="$(mktemp -d)"
  for p in "$@"; do
    patch_is_repo "$p" || continue
    if [[ ! -f "$REPO/${p#repo:}" ]]; then C_ERRS+=("${p}: no such file on the fleet branch"); continue; fi
    if [[ "$kind" == postgres ]]; then yq ea -o=json -I=0 '[.]' "$REPO/${p#repo:}" > "$tmp/f.json" 2>/dev/null
    else yq -o=json -I=0 '.' "$REPO/${p#repo:}" > "$tmp/f.json" 2>/dev/null; fi || { C_ERRS+=("${p}: not valid YAML"); continue; }
    if ! out="$(python3 "$TPG_LIB_DIR/patchcheck.py" "$kind" "$tmp/f.json" --schemas "$(patch_schemas_file)" --name "$p")"; then
      while IFS= read -r line; do [[ -z "$line" ]] || C_ERRS+=("$line"); done <<<"$out"
    fi
  done
  rm -rf "${tmp:?}"
}

patch_prepare() {  # patch_prepare CLUSTER TARGETS (use_cluster first)
  local c="$1" t="$2" p m stored i n cl rc cur
  PREP_PLAN='{"instances":[],"operator":false}'
  PREP_POSTGRES='{}'   # instance -> the stored postgres file it gets (for the warnings after the render)
  # ---- operator
  if jq -e '.operator != null' <<<"$t" >/dev/null; then
    p="$(jq -r '.operator.path' <<<"$t")"; m="$(jq -r '.operator.mode' <<<"$t")"
    rc=0; patch_ref "$REPO/$FLEET_REL" "$c" "" operator >/dev/null || rc=$?
    if ! fleet_has_cluster "$REPO" "$c"; then
      C_ERRS+=("no clusters.${c} in ${FLEET_REL} (run tpg-day0 first)")
    elif [[ "$rc" -eq 2 ]]; then
      C_ERRS+=("${c}: operator.patches.values is not {current, previous}: a fleet repository written before Round 15; start a new one")
    elif [[ "$m" == clear ]]; then
      patch_set_current "$REPO" "$c" "" operator "" && operator_effective_write "$REPO" "$c"
      PREP_PLAN="$(jq -c '.operator = true' <<<"$PREP_PLAN")"
    else
      patch_repo_check operator "$p"
      if [[ "${#C_ERRS[@]}" -eq 0 ]] && stored="$(patch_store "$REPO" "$p" operator)"; then
        patch_check_operator "$stored" "$p" "$c"
        patch_set_current "$REPO" "$c" "" operator "$stored" && operator_effective_write "$REPO" "$c"
        PREP_PLAN="$(jq -c '.operator = true' <<<"$PREP_PLAN")"
      elif [[ "${#C_ERRS[@]}" -eq 0 ]]; then
        C_ERRS+=("${p}: the file was not received (patchFiles)")
      fi
    fi
  fi
  # ---- instances
  for i in $(jq -r '.instances[].name' <<<"$t"); do
    if ! n="$(cmap_guard "$c" "$i")"; then
      record_entry "result.${c}.${i}" SKIPPED_VERSION_MISMATCH "" "$n"
      continue
    fi
    for kind in postgres postgresValues; do
      jq -e --arg i "$i" --arg k "$kind" '.instances[] | select(.name == $i) | .[$k] != null' <<<"$t" >/dev/null || continue
      rc=0; patch_ref "$REPO/$FLEET_REL" "$c" "$i" "$kind" >/dev/null || rc=$?
      if [[ "$rc" -eq 2 ]]; then
        C_ERRS+=("${c}/${i}: patches.${kind} is not {current, previous}: a fleet repository written before Round 15; start a new one")
        continue
      fi
      m="$(jq -r --arg i "$i" --arg k "$kind" '.instances[] | select(.name == $i) | .[$k].mode' <<<"$t")"
      if [[ "$kind" == postgres ]]; then
        p="$(jq -r --arg i "$i" '.instances[] | select(.name == $i) | .postgres.paths' <<<"$t")"
        cl="$(jq -r --arg i "$i" '.instances[] | select(.name == $i) | .postgres.clear' <<<"$t")"
        # shellcheck disable=SC2046  # comma-separated paths without spaces
        [[ "$m" == clear ]] || patch_repo_check postgres $(tr ',' ' ' <<<"$p")
        [[ "${#C_ERRS[@]}" -eq 0 ]] || continue
        cur="$(patch_ref "$REPO/$FLEET_REL" "$c" "$i" postgres 2>/dev/null || true)"
        if ! stored="$(patch_combine "$REPO" "$c" "$i" "$p" "$cl")"; then
          C_ERRS+=("${p}: a file was not received (patchFiles)"); continue
        fi
        if [[ -n "$stored" ]]; then
          log "${c}/${i}: postgres patch file ${PATCH_CHART_PREFIX}${stored} (documents: $(_docs_json "$REPO/${PATCH_CHART_PREFIX}${stored}" | jq -r 'map(.kind) | join(",")'))"
          patch_check_postgres "${PATCH_CHART_PREFIX}${stored}" "${p:-${i} postgres patch}" "$c" "$i" "$cur"
          PREP_POSTGRES="$(jq -c --arg i "$i" --arg f "${PATCH_CHART_PREFIX}${stored}" '. + {($i): $f}' <<<"$PREP_POSTGRES")"
        fi
        [[ -n "$stored" ]] || log "${c}/${i}: no postgres patch file any more (every document cleared)"
        patch_set_current "$REPO" "$c" "$i" postgres "$stored"
        continue
      fi
      p="$(jq -r --arg i "$i" '.instances[] | select(.name == $i) | .postgresValues.path' <<<"$t")"
      if [[ "$m" == clear ]]; then
        patch_set_current "$REPO" "$c" "$i" postgresValues ""
        continue
      fi
      patch_repo_check values "$p"
      [[ "${#C_ERRS[@]}" -eq 0 ]] || continue
      if ! stored="$(patch_store "$REPO" "$p" postgresValues)"; then
        C_ERRS+=("${p}: the file was not received (patchFiles)"); continue
      fi
      patch_check_values "${PATCH_CHART_PREFIX}${stored}" "$p" "$c" "$i"
      # a values file that turns FerretDB on lifts the valuesOverride tpg-restore
      # wrote for a restored copy (D71), which would otherwise win over it
      if [[ "$(yq -r '.ferret.enabled // ""' "$REPO/${PATCH_CHART_PREFIX}${stored}")" == "true" ]]; then
        C="$c" I="$i" yq -i 'del(.clusters[strenv(C)].instances[strenv(I)].valuesOverride.ferret)
          | del(.clusters[strenv(C)].instances[strenv(I)].valuesOverride | select(length == 0))' "$REPO/$FLEET_REL"
      fi
      patch_set_current "$REPO" "$c" "$i" postgresValues "$stored"
    done
    # ---- the CA bundle of an enableSSL instance (Round 15, D86): a file, a Vault secret
    if jq -e --arg i "$i" '.instances[] | select(.name == $i) | .ca == true' <<<"$t" >/dev/null; then
      if [[ "$(fleet_instance_value "$REPO" "$c" "$i" '.backup.enableSSL' "$(fleet_cluster_value "$REPO" "$c" '.backup.enableSSL' false)")" != "true" ]]; then
        C_ERRS+=("${c}/${i}: a CA bundle source needs backup.enableSSL true in ${FLEET_REL}; enableSSL is set when the instance is created (tpg-day0, tpg-create-instance backupEnableSSL)")
      elif ! ca_bundle_resolve "$c" "$i" "$(jq -c --arg c "$c" --arg i "$i" '.[$c].instances[$i] // {}' "$WORK/cmap.json" 2>/dev/null || echo '{}')" "$REPO"; then
        C_ERRS+=("$CA_ERR")
      else
        V="$CA_PEM" C="$c" I="$i" yq -i '.clusters[strenv(C)].instances[strenv(I)].backup.caBundle = strenv(V)
          | .clusters[strenv(C)].instances[strenv(I)].backup.caBundle style="literal"' "$REPO/$FLEET_REL"
        log "${c}/${i}: the backup CA bundle from ${CA_SOURCE}"
      fi
    fi
    PREP_PLAN="$(jq -c --arg i "$i" '.instances += [$i]' <<<"$PREP_PLAN")"
  done
}

patch_warnings() {  # patch_warnings CLUSTER: after the render, the overrides and unrendered targets of each instance's postgres file
  local c="$1" i f pp="${PREP_POSTGRES:-}"
  [[ -n "$pp" ]] || pp='{}'
  for i in $(jq -r 'keys[]' <<<"$pp"); do
    f="$(jq -r --arg i "$i" '.[$i]' <<<"$PREP_POSTGRES")"
    patch_overrides "$REPO/$f" "$c" "$i"
    patch_unrendered_warnings "$WORK/render/after-${c}-${i}.yaml" "$REPO/$f" "$c" "$i"
  done
}

# ---- rendering
patch_operator_render() {  # patch_operator_render CLUSTER OUT_FILE: the operator chart with the effective values file
  local c="$1" opv eff ovl host
  opv="$(C="$c" yq -r '.clusters[strenv(C)].operator.version // ""' "$REPO/$FLEET_REL")"
  eff="$REPO/$(operator_effective_rel "$c")"
  ovl="$REPO/$(patch_group overlays; operator_effective_rel "$c")"   # the subshell leaves the current patch_group alone
  host="tanzu-sql-postgres.packages.broadcom.com"
  local -a vf=()
  # the overlay values file (initial deployment) first, the patch file on top: the order of the
  # tpg-operator ApplicationSet's valueFiles
  [[ -f "$ovl" ]] && vf=(-f "$ovl")
  [[ -f "$eff" ]] && vf+=(-f "$eff")
  vault_secret broadcom-registry password \
    | helm registry login "$host" --username "$(vault_secret broadcom-registry username)" --password-stdin >/dev/null 2>&1 || true
  helm template "tpg-${c}-operator" "oci://${host}/vmware-sql-postgres-operator" --version "$opv" \
    --namespace "$OPERATOR_NS" ${vf[@]+"${vf[@]}"} > "$2" 2>"$2.err"
}

patch_render_all() {  # patch_render_all CLUSTER TARGETS WHEN
  local c="$1" t="$2" w="$3" i out
  mkdir -p "$WORK/render"
  for i in $(jq -r '.instances[].name' <<<"$t"); do
    out="$WORK/render/${w}-${c}-${i}.yaml"
    if ! instance_render "$REPO" "$c" "$i" > "$out" 2>"$out.err"; then
      [[ "$w" == before ]] && : > "$out" || C_ERRS+=("${i}: the chart does not render: $(tail -n 3 "$out.err" | tr '\n' ' ')")
    fi
    # values the workflows read on the hub and the chart does not render: a values
    # patch with only backup.scheduled moves the instance in or out of the backup
    # CronWorkflows (discover.sh) without a change on the cluster
    printf 'backup.scheduled=%s\n' "$(instance_effective "$REPO" "$c" "$i" '.backup.scheduled' true)" > "$WORK/render/${w}-${c}-${i}.hub"
    [[ "$w" != after ]] || patch_size_check "$c" "$i"
  done
  if jq -e '.operator != null' <<<"$t" >/dev/null; then
    out="$WORK/render/${w}-${c}-operator.yaml"
    if ! patch_operator_render "$c" "$out"; then
      [[ "$w" == before ]] && : > "$out" \
        || C_ERRS+=("operator values: the operator chart does not render with the values file: $(tail -n 3 "$out.err" | tr '\n' ' ')")
    fi
  fi
}

patch_size_check() {  # patch_size_check CLUSTER INSTANCE: a volume of the rendered Postgres
  # object may not shrink and its storage class may not change, whichever file sets
  # them (a postgres document, a values patch, or a new document that no longer sets
  # a field of the current one and so falls back to the chart value)
  local c="$1" i="$2" b="$WORK/render/before-${1}-${2}.yaml" a="$WORK/render/after-${1}-${2}.yaml" k line bc ac
  [[ -s "$b" && -s "$a" ]] || return 0
  for k in storageSize walStorageSize; do
    line="$(patch_size_not_smaller "${i}" "Postgres spec.${k}" \
      "$(K="$k" yq -r 'select(.kind == "Postgres") | .spec[strenv(K)] // ""' "$a" | head -n1)" \
      "$(K="$k" yq -r 'select(.kind == "Postgres") | .spec[strenv(K)] // ""' "$b" | head -n1)")"
    [[ -z "$line" ]] || C_ERRS+=("${line} (the rendered instance after the patch)")
  done
  bc="$(yq -r 'select(.kind == "Postgres") | .spec.storageClassName // ""' "$b" | head -n1)"
  ac="$(yq -r 'select(.kind == "Postgres") | .spec.storageClassName // ""' "$a" | head -n1)"
  [[ "$bc" == "$ac" ]] \
    || C_ERRS+=("${i}: Postgres spec.storageClassName cannot change on a running instance: ${bc:-(not set)} before the patch, ${ac:-(not set)} after it (the rendered instance after the patch)")
}

patch_dry_run() {  # patch_dry_run CLUSTER (use_cluster first): the after renders through the API server
  local c="$1" i f docs dr
  for i in $(jq -r '.instances[]' <<<"$PREP_PLAN"); do
    f="$WORK/render/after-${c}-${i}.yaml"
    [[ -s "$f" ]] || continue
    docs="$(yq 'select(.kind == "Postgres" or .kind == "PostgresBackupLocation"
               or .kind == "PostgresBackupSchedule" or .kind == "PostgresFerretDocumentDB")' "$f")"
    exposure_warning_rendered "$c" "$i" "$(cat "$f")"
    # FerretDB switched on by a values patch (D71): the documentdb extension is a manual step
    if yq -e 'select(.kind == "PostgresFerretDocumentDB") | .metadata.name' "$f" >/dev/null 2>&1 \
       && ! tk -n "pg-${i}" get postgresferretdocumentdb "$i" >/dev/null 2>&1; then
      record_entry "warning.${c}.${i}.ferret" WARNING FERRET_EXTENSION_REQUIRED \
        "${i}: FerretDB (Tech Preview) needs the documentdb extension in the instance; prepare it by hand (Runbook, FerretDB) or the FerretDB proxies do not start"
    fi
    if [[ -n "$docs" ]] && ! dr="$(tk -n "pg-${i}" apply --server-side --dry-run=server --field-manager="$ARGOCD_MANAGER" \
        --force-conflicts -f - <<<"$docs" 2>&1)"; then
      C_ERRS+=("${i}: the API server rejects the patched instance: $(tr '\n' ' ' <<<"$dr" | cut -c1-400)")
    fi
  done
  if [[ "$(jq -r '.operator' <<<"$PREP_PLAN")" == "true" ]]; then
    f="$WORK/render/after-${c}-operator.yaml"
    docs="$(yq 'select(.kind == "Deployment")' "$f" 2>/dev/null)"
    if [[ -n "$docs" ]] && ! dr="$(tk -n "$OPERATOR_NS" apply --server-side --dry-run=server \
        --field-manager="$ARGOCD_MANAGER" --force-conflicts -f - <<<"$docs" 2>&1)"; then
      C_ERRS+=("operator values: the API server rejects the operator Deployment: $(tr '\n' ' ' <<<"$dr" | cut -c1-400)")
    fi
  fi
}

patch_tracked_list() {  # patch_tracked_list FILE APP NAMESPACE -> the rendered objects as a List, each
  # with the tracking annotation Argo CD writes (annotation tracking), so the diff
  # shows only what the sync changes. Argo CD names the namespace in the id of every
  # object, a cluster-scoped one too: its own namespace, else the one of the
  # Application. No object gets a namespace it does not render with, and no list of
  # cluster-scoped kinds is needed (patch_diff_list leaves the scope to kubectl).
  yq -o=json -I=0 'select(. != null and .kind != null)' "$1" | jq -sc --arg app "$2" --arg ns "$3" '{apiVersion: "v1", kind: "List", items: map(
      ((.apiVersion | split("/")) as $a | if ($a | length) == 2 then $a[0] else "" end) as $g
      | .metadata.annotations["argocd.argoproj.io/tracking-id"] = "\($app):\($g)/\(.kind):\(.metadata.namespace // $ns)/\(.metadata.name)")}'
}

patch_diff_list() {  # patch_diff_list NAMESPACE: stdin List -> PATCH_DIFF_OUT, PATCH_DIFF_RC
  # kubectl diff of the List, in the exit codes of kubectl (0 no difference, 1 a
  # difference, 2 or more an error; the highest of the calls wins). An object that
  # renders with a namespace of its own goes without -n, which kubectl refuses when
  # the namespaces differ (the operator chart renders objects in cert-manager); the
  # others go with -n NAMESPACE, which kubectl ignores for a cluster-scoped kind. So
  # kubectl decides the scope, and no list of kinds needs a new entry.
  local ns="$1" list body part o r
  local -a nsarg
  list="$(cat)"
  PATCH_DIFF_OUT=""; PATCH_DIFF_RC=0
  for part in own rest; do
    if [[ "$part" == own ]]; then
      body="$(jq -c '.items |= map(select(.metadata.namespace != null))' <<<"$list")"; nsarg=()
    else
      body="$(jq -c '.items |= map(select(.metadata.namespace == null))' <<<"$list")"; nsarg=(-n "$ns")
    fi
    [[ "$(jq '.items | length' <<<"$body")" -gt 0 ]] || continue
    r=0
    o="$(tk ${nsarg[@]+"${nsarg[@]}"} diff --server-side --force-conflicts --field-manager="$ARGOCD_MANAGER" -f - <<<"$body" 2>&1)" || r=$?
    [[ -z "$o" ]] || PATCH_DIFF_OUT+="${PATCH_DIFF_OUT:+$'\n'}${o}"
    [[ "$r" -le "$PATCH_DIFF_RC" ]] || PATCH_DIFF_RC="$r"
  done
}

# The ignoreDifferences of the tpg-instances ApplicationSet (bootstrap/appsets/
# tpg-instances.yaml; tests/patch compares the two): Argo CD does not count these
# fields, so neither does the diff of tpg-patch.
PATCH_IGNORED_PATHS='{"PostgresBackupLocation": [["spec","additionalParameters"], ["spec","storage","azure","forcePathStyle"], ["spec","storage","azure","enableSSL"]], "Postgres": [["spec","postgresVersion"]]}'

patch_ignore_live() {  # patch_ignore_live NAMESPACE: stdin List -> stdout List
  # every ignored field of an object that runs takes its live value (or goes, when
  # the live object has none), so kubectl diff shows only what Argo CD compares
  local ns="$1" list n i kind name live
  list="$(cat)"
  n="$(jq '.items | length' <<<"$list")"
  for ((i = 0; i < n; i++)); do
    kind="$(jq -r --argjson i "$i" '.items[$i].kind' <<<"$list")"
    jq -e --arg k "$kind" 'has($k)' <<<"$PATCH_IGNORED_PATHS" >/dev/null || continue
    name="$(jq -r --argjson i "$i" '.items[$i].metadata.name' <<<"$list")"
    live="$(tk -n "$ns" get "$kind" "$name" -o json 2>/dev/null)" || continue
    [[ -n "$live" ]] || continue
    list="$(jq -c --argjson i "$i" --argjson live "$live" --argjson ps "$PATCH_IGNORED_PATHS" '
      .items[$i] |= (reduce $ps[.kind][] as $p (.;
        ($live | getpath($p)) as $v | if $v == null then delpaths([$p]) else setpath($p; $v) end))' <<<"$list")"
  done
  printf '%s\n' "$list"
}

patch_removed() {  # patch_removed BEFORE AFTER -> kind/name of objects only BEFORE renders
  comm -23 <(yq -r 'select(.kind != null) | .kind + "/" + .metadata.name' "$1" 2>/dev/null | sort -u) \
           <(yq -r 'select(.kind != null) | .kind + "/" + .metadata.name' "$2" 2>/dev/null | sort -u)
}

patch_diff() {
  # patch_diff CLUSTER (use_cluster first) -> PATCH_CHANGED (targets with a change on
  # the cluster), PATCH_HUB_ONLY (instances where only values the workflows read on
  # the hub change: committed, not synced), the diff in the log and $WORK/diff-<cluster>.txt
  local c="$1" t app ns before after removed rc out hub list
  PATCH_CHANGED=(); PATCH_HUB_ONLY=()
  : > "$WORK/diff-${c}.txt"
  for t in $(jq -r '.instances[]' <<<"$PREP_PLAN") $( [[ "$(jq -r '.operator' <<<"$PREP_PLAN")" == "true" ]] && echo operator); do
    before="$WORK/render/before-${c}-${t}.yaml"; after="$WORK/render/after-${c}-${t}.yaml"
    if [[ "$t" == operator ]]; then app="tpg-${c}-operator"; ns="$OPERATOR_NS"; else app="tpg-${c}-${t}"; ns="pg-${t}"; fi
    [[ -f "$before" ]] || : > "$before"
    removed="$(patch_removed "$before" "$after")"
    list="$(patch_tracked_list "$after" "$app" "$ns" | patch_ignore_live "$ns")"
    patch_diff_list "$ns" <<<"$list"   # not the end of a pipeline: it sets PATCH_DIFF_*
    rc="$PATCH_DIFF_RC"; out="$PATCH_DIFF_OUT"
    log "==================== diff ${c}/${t} (${app}) ===================="
    if [[ "$rc" -gt 1 ]]; then
      C_ERRS+=("${t}: kubectl diff failed: $(tr '\n' ' ' <<<"$out" | cut -c1-400)")
      continue
    fi
    {
      printf '==== %s/%s (%s)\n' "$c" "$t" "$app"
      [[ -z "$removed" ]] || printf 'objects the patch no longer renders (the sync prunes them):\n  - %s\n' "${removed//$'\n'/$'\n'  - }"
      [[ "$rc" -ne 1 ]] || printf '%s\n' "$out"
    } | tee -a "$WORK/diff-${c}.txt" >&2
    if [[ "$rc" -eq 0 && -z "$removed" ]]; then
      hub=""
      [[ "$t" == operator ]] || hub="$(diff "$WORK/render/before-${c}-${t}.hub" "$WORK/render/after-${c}-${t}.hub" 2>/dev/null | sed -n 's/^> //p' | paste -sd' ' -)"
      if [[ -n "$hub" ]]; then
        printf '%s/%s: nothing changes on the cluster; the workflows read %s\n' "$c" "$t" "$hub" | tee -a "$WORK/diff-${c}.txt" >&2
        PATCH_HUB_ONLY+=("$t")
      else
        log "${c}/${t}: no difference; the patch renders the objects that run"
      fi
    else
      PATCH_CHANGED+=("$t")
    fi
  done
}
