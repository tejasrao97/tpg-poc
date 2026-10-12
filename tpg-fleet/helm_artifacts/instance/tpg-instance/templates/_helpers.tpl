{{- define "tpg.required" -}}
{{- if not .Values.instance.name }}{{ fail "instance.name is required" }}{{ end -}}
{{- if not .Values.instance.postgresVersion }}{{ fail "instance.postgresVersion is required" }}{{ end -}}
{{- if not .Values.backup.container }}{{ fail "backup.container is required" }}{{ end -}}
{{- if hasKey .Values.instance "serviceType" }}{{ fail "instance.serviceType is replaced by instance.exposure (clusterIP, internalLoadBalancer or loadBalancer)" }}{{ end -}}
{{- /* Round 23: the instance namespace. Argo CD deploys into instance.namespace (default pg-<instance>); a render in another namespace is a mistake in the values */ -}}
{{- $ns := toString (default "" .Values.instance.namespace) -}}
{{- if and $ns (ne $ns .Release.Namespace) }}{{ fail (printf "instance.namespace %q differs from the release namespace %q: render with --namespace %s (the tpg-instances ApplicationSet deploys into instance.namespace)" $ns .Release.Namespace $ns) }}{{ end -}}
{{- if not (has (include "tpg.sharedSecretsOwnerValue" .) (list "true" "false")) }}{{ fail (printf "instance.sharedSecretsOwner %q must be true or false" (include "tpg.sharedSecretsOwnerValue" .)) }}{{ end -}}
{{- end -}}

{{- /*
tpg.sharedSecretsOwnerValue: the instance.sharedSecretsOwner the chart acts on, as the string
"true" or "false" (or whatever the entry holds, for tpg.required to refuse). When the entry of the
instance is in the fleet.yaml value file (.Values.clusters, the way tpg.patchRef reads the patch
records), the flag comes from that entry: the file is read from Git at the commit being synced.
The inline Helm values of the tpg-instances ApplicationSet are built from the fleet branch by the
generator and refreshed asynchronously, so right after tpg-delete-instance moved the shared Secrets
to another instance they still hold the old owner; the ownership must follow the synced commit, or
the successor would render as a non-owner and the old owner would keep tracking objects it no
longer renders. An entry without the key owns them (the default, true). Without fleet.yaml (a
render by hand) the inline value is used.
*/ -}}
{{- define "tpg.sharedSecretsOwnerValue" -}}
{{- $v := .Values -}}
{{- $flag := $v.instance.sharedSecretsOwner -}}
{{- if hasKey $v "clusters" -}}
{{- /* dig on the nested map: .Values itself is chartutil.Values, which dig cannot read */ -}}
{{-   $ent := dig (toString $v.cluster.name) "instances" (toString $v.instance.name) "" (default dict $v.clusters) -}}
{{-   if kindIs "map" $ent -}}
{{-     $ins := default dict (get $ent "instance") -}}
{{-     $flag = ternary (get $ins "sharedSecretsOwner") true (hasKey $ins "sharedSecretsOwner") -}}
{{-   end -}}
{{- end -}}
{{- toString $flag -}}
{{- end -}}

{{- /*
tpg.sharedSecretsOwner: "true" when this instance renders the objects of its namespace that two
instances would both name the same (ServiceAccount tpg-vso, VaultStaticSecrets regsecret and
backup-storage), "false" otherwise (Round 23). Read from the chart values (tpg.sharedSecretsOwnerValue),
not from the context the patch files are merged into: a patch file cannot move the ownership.
*/ -}}
{{- define "tpg.sharedSecretsOwner" -}}
{{- ternary "false" "true" (eq (include "tpg.sharedSecretsOwnerValue" .) "false") -}}
{{- end -}}

{{- /*
tpg.exposure (dict "exposure" E "subnet" S "ranges" LIST "extra" MAP): the Service
type and annotations of one exposure (design decision D64):
  clusterIP             ClusterIP, no annotations
  internalLoadBalancer  LoadBalancer + azure-load-balancer-internal: "true"
                        (+ azure-load-balancer-internal-subnet when a subnet is set)
  loadBalancer          LoadBalancer on the public frontend of the cluster
Both load balancer kinds get azure-allowed-ip-ranges from allowedSourceRanges.
extra (serviceAnnotations) is added last. An empty map or list is never rendered:
the CRD drops it and Argo CD would report a difference forever (F7).
Returns YAML {type: ..., annotations: {...}}.
*/ -}}
{{- define "tpg.exposure" -}}
{{- $e := default "clusterIP" .exposure -}}
{{- if not (has $e (list "clusterIP" "internalLoadBalancer" "loadBalancer")) }}{{ fail (printf "exposure %q must be clusterIP, internalLoadBalancer or loadBalancer" $e) }}{{ end -}}
{{- $a := dict -}}
{{- if eq $e "internalLoadBalancer" -}}
{{-   $_ := set $a "service.beta.kubernetes.io/azure-load-balancer-internal" "true" -}}
{{-   with .subnet }}{{ $_ := set $a "service.beta.kubernetes.io/azure-load-balancer-internal-subnet" . }}{{ end -}}
{{- end -}}
{{- if and (ne $e "clusterIP") .ranges -}}
{{-   $_ := set $a "service.beta.kubernetes.io/azure-allowed-ip-ranges" (join "," .ranges) -}}
{{- end -}}
{{- range $k, $v := (default dict .extra) }}{{ $_ := set $a $k (toString $v) }}{{ end -}}
{{- toYaml (dict "type" (ternary "ClusterIP" "LoadBalancer" (eq $e "clusterIP")) "annotations" $a) -}}
{{- end -}}

{{- /*
tpg.services: the Service fields of the Postgres spec. readOnlyServiceType is
written only when the read-only Service is not ClusterIP (the CRD default), so
the specs of existing instances do not change.
*/ -}}
{{- define "tpg.services" -}}
{{- $i := .Values.instance -}}
{{- $rw := include "tpg.exposure" (dict "exposure" $i.exposure "subnet" $i.internalLoadBalancerSubnet "ranges" $i.allowedSourceRanges "extra" $i.serviceAnnotations) | fromYaml -}}
{{- $ro := include "tpg.exposure" (dict "exposure" $i.readOnlyExposure "subnet" $i.internalLoadBalancerSubnet "ranges" $i.allowedSourceRanges "extra" $i.readOnlyServiceAnnotations) | fromYaml -}}
serviceType: {{ $rw.type }}
{{- with $rw.annotations }}
serviceAnnotations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- if ne $ro.type "ClusterIP" }}
readOnlyServiceType: {{ $ro.type }}
{{- end }}
{{- with $ro.annotations }}
readOnlyServiceAnnotations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end -}}

{{- /*
tpg.deepMerge (dict "dst" MAP "src" MAP): merge src into dst, in place.
Maps are merged key by key; any other value in src replaces the one in dst,
including false, 0 and "" (unlike mergeOverwrite, which skips empty values);
a list replaces the whole list; a key set to null in src is removed from dst.
*/ -}}
{{- define "tpg.deepMerge" -}}
{{- $dst := .dst -}}
{{- range $k, $v := .src -}}
{{-   if kindIs "invalid" $v -}}
{{-     $_ := unset $dst $k -}}
{{-   else if and (kindIs "map" $v) (kindIs "map" (get $dst $k)) -}}
{{-     $_ := include "tpg.deepMerge" (dict "dst" (get $dst $k) "src" $v) -}}
{{-   else -}}
{{-     $_ := set $dst $k $v -}}
{{-   end -}}
{{- end -}}
{{- end -}}

{{- /*
tpg.patchRef (dict "root" $ "kind" "postgresValues"|"postgres" ["group" "overlays"|"patches"]):
the current overlay or patch file of the instance for that kind, a path relative to
this chart, or "" (Round 14, D78; Round 15, D81; Round 22 overlays). The group is
"patches" when not given. tpg-patch, tpg-create-instance and tpg-day0 record them in
clusters/fleet.yaml:
  clusters.<cluster>.instances.<instance>.overlays.postgresValues  chart values fragment
  clusters.<cluster>.instances.<instance>.overlays.postgres        partial manifests
  clusters.<cluster>.instances.<instance>.patches.postgresValues   chart values fragment
  clusters.<cluster>.instances.<instance>.patches.postgres         partial manifests, one
                                                                   YAML document per kind
each as {current: <overlays|patches>/<file>.yaml, previous: {path, commit}}; only current is
applied. Overlays are written at the initial deployment (tpg-day0, tpg-create-instance);
patches (tpg-patch) are applied after them and win over them. The tpg-instances
ApplicationSet passes clusters/fleet.yaml as a value file, so the entry is read from Git
at the commit being synced (a pull request branch before the merge), not from the copy
the ApplicationSet made of the fleet branch; without that file (a render by hand)
.Values.overlays / .Values.patches is used.
*/ -}}
{{- define "tpg.patchRef" -}}
{{- $v := .root.Values -}}
{{- $grp := default "patches" .group -}}
{{- $node := "" -}}
{{- if hasKey $v "clusters" -}}
{{- /* dig on the nested map: .Values itself is chartutil.Values, which dig cannot read */ -}}
{{-   $node = dig (toString $v.cluster.name) "instances" (toString $v.instance.name) $grp .kind "" (default dict $v.clusters) -}}
{{- else -}}
{{-   $node = get (default dict (get $v $grp)) .kind -}}
{{- end -}}
{{- if kindIs "map" $node -}}
{{-   default "" $node.current -}}
{{- else if $node -}}
{{-   fail (printf "%s.%s of %s must be {current: <file>, previous: {path, commit}} (a fleet repository written before Round 15: start a new one)" $grp .kind (toString $v.instance.name)) -}}
{{- end -}}
{{- end -}}

{{- /*
Restored instances (Round 23, tpg-restore). tpg-restore marks the entry of an instance it restored
  clusters.<cluster>.instances.<instance>.instance.restored   true
  clusters.<cluster>.instances.<instance>.restorePatch        {current: restore-patch/<file>.yaml,
                                                               previous: {path, commit},
                                                               mode: base | over,
                                                               postgresPatch: patches/<file>.yaml}
and stores the spec of the restored Postgres in restore-patch/ (the spec file of the pair, or the spec
read from the cluster after the restore: one kind: Postgres document, no metadata). The entry is read
like the patch records (tpg.patchRef): from the clusters value file at the synced commit, else (a
render by hand) from .Values.instance.restored and .Values.restorePatch. Only restorePatch.current is
applied; previous is the record of the restore before. The Postgres object of a restored instance is
built by tpg.restoredPostgres (below); the other objects render as for any instance.
*/ -}}
{{- /* tpg.restoredEntry (root): the entry of the instance in the clusters value file as YAML ({} without one) */ -}}
{{- define "tpg.restoredEntry" -}}
{{- $v := .Values -}}
{{- $ent := dict -}}
{{- if hasKey $v "clusters" -}}
{{- /* dig on the nested map: .Values itself is chartutil.Values, which dig cannot read */ -}}
{{-   $ent = dig (toString $v.cluster.name) "instances" (toString $v.instance.name) (dict) (default dict $v.clusters) -}}
{{- end -}}
{{- toYaml (default dict $ent) -}}
{{- end -}}

{{- /* tpg.restorePatchNode (root): the restorePatch record of the instance as YAML ({} when it has none) */ -}}
{{- define "tpg.restorePatchNode" -}}
{{- $v := .Values -}}
{{- $node := "" -}}
{{- if hasKey $v "clusters" -}}
{{-   $node = dig (toString $v.cluster.name) "instances" (toString $v.instance.name) "restorePatch" "" (default dict $v.clusters) -}}
{{- else -}}
{{-   $node = get $v "restorePatch" -}}
{{- end -}}
{{- if kindIs "map" $node -}}
{{-   toYaml $node -}}
{{- else if $node -}}
{{-   fail (printf "restorePatch of %s must be {current: <file>, previous: {path, commit}, mode: base|over}" (toString $v.instance.name)) -}}
{{- else -}}
{{-   "{}" -}}
{{- end -}}
{{- end -}}

{{- /* tpg.restorePatchRef (root): the current restore-patch file, a path relative to this chart, or "" */ -}}
{{- define "tpg.restorePatchRef" -}}
{{- default "" (include "tpg.restorePatchNode" . | fromYaml).current -}}
{{- end -}}

{{- /*
tpg.restoredMode (root): "" for an instance that is not restored; "base" or "over" for a restored one
(restorePatch.mode, default base). instance.restored true without a current restore-patch fails the
render: there is nothing to render the Postgres from.
  base  the restore-patch IS the spec of the Postgres (a new instance restored with or without a spec
        file, an in-place restore without one): nothing of the chart defaults, the entry, the overlays
        or the values patches is filled in
  over  an in-place restore with a spec file: the operator merged the file into the existing Postgres,
        so the render is the normal one with the restore-patch over it
*/ -}}
{{- define "tpg.restoredMode" -}}
{{- $v := .Values -}}
{{- $flag := default false (get (default dict $v.instance) "restored") -}}
{{- if hasKey $v "clusters" -}}
{{-   $flag = default false (dig "instance" "restored" false (include "tpg.restoredEntry" . | fromYaml)) -}}
{{- end -}}
{{- if eq (toString $flag) "true" -}}
{{-   $rp := include "tpg.restorePatchNode" . | fromYaml -}}
{{-   if not $rp.current }}{{ fail (printf "instance.restored is true for %s but restorePatch.current is empty: tpg-restore records both (a restored instance is rendered from its restore-patch file)" (toString $v.instance.name)) }}{{ end -}}
{{-   $m := toString (default "base" $rp.mode) -}}
{{-   if not (has $m (list "base" "over")) }}{{ fail (printf "restorePatch.mode of %s must be base or over, got %q" (toString $v.instance.name) $m) }}{{ end -}}
{{-   $m -}}
{{- end -}}
{{- end -}}

{{- /*
tpg.restorePatchSpec (root): the spec of the current restore-patch file as YAML. The file holds one
kind: Postgres document (apiVersion, kind, spec); anything else fails the render.
*/ -}}
{{- define "tpg.restorePatchSpec" -}}
{{- $f := include "tpg.restorePatchRef" . -}}
{{- $raw := .Files.Get $f -}}
{{- if not $raw }}{{ fail (printf "restore-patch file %s not found in the chart (helm_artifacts/instance/tpg-instance/%s)" $f $f) }}{{ end -}}
{{- $spec := dict -}}
{{- $n := 0 -}}
{{- range $doc := regexSplit "(?m)^---[ \t]*$" $raw -1 -}}
{{-   $p := fromYaml $doc -}}
{{-   if hasKey $p "Error" }}{{ fail (printf "restore-patch file %s: a document is not a YAML map: %s" $f $p.Error) }}{{ end -}}
{{-   if $p -}}
{{-     $k := toString (default "" $p.kind) -}}
{{-     if not (has $k (list "Postgres" "PostgresBackupLocation" "PostgresBackupSchedule" "PostgresFerretDocumentDB")) }}{{ fail (printf "restore-patch file %s: kind %q is not a kind the tpg-instance chart renders" $f $k) }}{{ end -}}
{{-     if ne $k "Postgres" }}{{ fail (printf "restore-patch file %s: kind %q is not Postgres: a restore-patch holds the one Postgres document of the restored instance" $f $k) }}{{ end -}}
{{-     $n = add1 $n -}}
{{-     $spec = deepCopy (default dict $p.spec) -}}
{{-   end -}}
{{- end -}}
{{- if gt $n 1 }}{{ fail (printf "restore-patch file %s holds %d Postgres documents: a restore-patch holds one" $f $n) }}{{ end -}}
{{- toYaml $spec -}}
{{- end -}}

{{- /*
tpg.patchFile (dict "root" $ "file" PATH "what" LABEL): an overlay or patch file of this
chart parsed as YAML (a map). Patch files live in helm_artifacts/instance/tpg-instance/patches/, overlay
files in helm_artifacts/instance/tpg-instance/overlays/.
Returns YAML; fails the render when the file is missing or not a YAML map.
*/ -}}
{{- define "tpg.patchFile" -}}
{{- $raw := .root.Files.Get .file -}}
{{- if not $raw }}{{ fail (printf "%s file %s not found in the chart (helm_artifacts/instance/tpg-instance/%s)" .what .file .file) }}{{ end -}}
{{- $p := fromYaml $raw -}}
{{- if hasKey $p "Error" }}{{ fail (printf "%s file %s is not a YAML map: %s" .what .file $p.Error) }}{{ end -}}
{{- toYaml $p -}}
{{- end -}}

{{- /*
tpg.kindPatch (dict "root" $ "key" KEY ["groups" LIST]): the spec fragment the instance's current
postgres overlay file and then its current postgres patch file hold for one object
(Round 15, D81; Round 22), as YAML ({} when none; where both set a field the patch wins).
groups says which of them ("overlays", "patches"; default both): the restored Postgres of an
instance asks for its patch file alone, or for the overlay and the patch of different moments.
KEY is the kind (Postgres, PostgresBackupLocation, PostgresFerretDocumentDB) or
PostgresBackupSchedule/full | PostgresBackupSchedule/incremental. The file holds one
YAML document per object: apiVersion, kind and spec (a schedule also
metadata.name: <instance>-backup-<type> or backup-<type>). The workflows check the
documents before they reference the file (workflows/scripts/patchcheck.py); an
unknown kind fails the render here as well. The templates merge the fragment into
the object they render (tpg.deepMerge), so an overlay or patch wins over the values it
overlaps (the workflows report PATCH_OVERRIDES_VALUE).
*/ -}}
{{- define "tpg.kindPatch" -}}
{{- $out := dict -}}
{{- range $grp := (default (list "overlays" "patches") .groups) -}}
{{- $f := include "tpg.patchRef" (dict "root" $.root "kind" "postgres" "group" $grp) -}}
{{- $what := ternary "postgres overlay" "postgres patch" (eq $grp "overlays") -}}
{{- if $f -}}
{{-   $raw := $.root.Files.Get $f -}}
{{-   if not $raw }}{{ fail (printf "%s file %s not found in the chart (helm_artifacts/instance/tpg-instance/%s)" $what $f $f) }}{{ end -}}
{{-   range $doc := regexSplit "(?m)^---[ \t]*$" $raw -1 -}}
{{-     $p := fromYaml $doc -}}
{{-     if hasKey $p "Error" }}{{ fail (printf "%s file %s: a document is not a YAML map: %s" $what $f $p.Error) }}{{ end -}}
{{-     if $p -}}
{{-       $k := toString (default "" $p.kind) -}}
{{-       if not (has $k (list "Postgres" "PostgresBackupLocation" "PostgresBackupSchedule" "PostgresFerretDocumentDB")) }}{{ fail (printf "%s file %s: kind %q is not a kind the tpg-instance chart renders" $what $f $k) }}{{ end -}}
{{-       if eq $k "PostgresBackupSchedule" -}}
{{-         $n := toString (dig "metadata" "name" "" $p) -}}
{{-         $t := regexFind "(full|incremental)$" $n -}}
{{-         if not (regexMatch "(^|-)backup-(full|incremental)$" $n) }}{{ fail (printf "%s file %s: PostgresBackupSchedule metadata.name %q must end in backup-full or backup-incremental" $what $f $n) }}{{ end -}}
{{-         $k = printf "PostgresBackupSchedule/%s" $t -}}
{{-       end -}}
{{-       if hasKey $out $k -}}
{{-         $_ := include "tpg.deepMerge" (dict "dst" (get $out $k) "src" (default dict $p.spec)) -}}
{{-       else -}}
{{-         $_ := set $out $k (deepCopy (default dict $p.spec)) -}}
{{-       end -}}
{{-     end -}}
{{-   end -}}
{{- end -}}
{{- end -}}
{{- toYaml (default dict (get $out .key)) -}}
{{- end -}}

{{- /*
tpg.ctx: a context like the root one - .Values and .Release - whose values have
the instance's current values overlay file and then its current values patch file
(tpg.patchRef postgresValues) merged in, then
valuesOverride (written by tpg-restore only). clusters (clusters/fleet.yaml as a
value file) is left out of it. Templates render from it:
  {{- with (include "tpg.ctx" . | fromYaml) }} ... {{- end }}
*/ -}}
{{- define "tpg.ctx" -}}
{{- $v := omit (deepCopy .Values) "clusters" -}}
{{- range $grp := list "overlays" "patches" -}}
{{- $f := include "tpg.patchRef" (dict "root" $ "kind" "postgresValues" "group" $grp) -}}
{{- if $f -}}
{{-   $_ := include "tpg.deepMerge" (dict "dst" $v "src" (include "tpg.patchFile" (dict "root" $ "file" $f "what" (ternary "values overlay" "values patch" (eq $grp "overlays"))) | fromYaml)) -}}
{{- end -}}
{{- end -}}
{{- $_ := include "tpg.deepMerge" (dict "dst" $v "src" (default dict .Values.valuesOverride)) -}}
{{- toYaml (dict "Values" $v "Release" (dict "Namespace" .Release.Namespace "Name" .Release.Name)) -}}
{{- end -}}

{{- /*
tpg.restoredEntrySpec (dict "ins" MAP): the Postgres spec fields the entry's instance block (MAP, the
instance: of clusters.<cluster>.instances.<instance>, nothing of the chart defaults, the templates or
the cluster) says, for the keys that are present in it, as YAML. The fleet-equivalent fields:
  instance.postgresVersion                    spec.postgresVersion.name
  instance.storageClassName                   spec.storageClassName
  instance.storageSize                        spec.storageSize
  instance.walStorageSize                     spec.walStorageSize
  instance.resources                          spec.resources
  instance.highAvailability.{enabled,readReplicas}   spec.highAvailability {enabled, readReplicas}
  instance.exposure, readOnlyExposure,        spec.serviceType, serviceAnnotations,
    serviceAnnotations, readOnlyServiceAnnotations    readOnlyServiceType, readOnlyServiceAnnotations
                                                     (tpg.services; allowedSourceRanges and
                                                     internalLoadBalancerSubnet are not read: a
                                                     restored instance keeps the annotations of its
                                                     restore-patch as serviceAnnotations)
*/ -}}
{{- define "tpg.restoredEntrySpec" -}}
{{- $e := .ins -}}
{{- $c := dict -}}
{{- if $e.postgresVersion }}{{ $_ := set $c "postgresVersion" (dict "name" (toString $e.postgresVersion)) }}{{ end -}}
{{- range $k := list "storageClassName" "storageSize" "walStorageSize" -}}
{{-   with get $e $k }}{{ $_ := set $c $k . }}{{ end -}}
{{- end -}}
{{- if kindIs "map" $e.resources }}{{ if $e.resources }}{{ $_ := set $c "resources" (deepCopy $e.resources) }}{{ end }}{{ end -}}
{{- if kindIs "map" $e.highAvailability -}}
{{-   $_ := set $c "highAvailability" (dict "enabled" (eq (toString $e.highAvailability.enabled) "true") "readReplicas" (int (default 0 $e.highAvailability.readReplicas))) -}}
{{- end -}}
{{- $svc := false -}}
{{- range $k := list "exposure" "readOnlyExposure" "serviceAnnotations" "readOnlyServiceAnnotations" }}{{ if hasKey $e $k }}{{ $svc = true }}{{ end }}{{ end -}}
{{- if $svc -}}
{{-   $s := include "tpg.services" (dict "Values" (dict "instance" (pick $e "exposure" "readOnlyExposure" "serviceAnnotations" "readOnlyServiceAnnotations"))) | fromYaml -}}
{{-   range $k, $v := $s }}{{ $_ := set $c $k $v }}{{ end -}}
{{-   range $k := list "serviceAnnotations" "readOnlyServiceAnnotations" }}{{ if not (hasKey $c $k) }}{{ $_ := set $c $k (dict) }}{{ end }}{{ end -}}
{{-   if not (hasKey $c "readOnlyServiceType") }}{{ $_ := set $c "readOnlyServiceType" "ClusterIP" }}{{ end -}}
{{- end -}}
{{- toYaml $c -}}
{{- end -}}

{{- /*
tpg.restoredNorm (dict "key" K "spec" MAP): the value of the spec field K in MAP as the JSON string two
values are compared by (tpg.restoredPostgres): the field as it is, except that a value the operator or
the chart treats as the default is the same as no value:
  highAvailability       {enabled: bool (absent: false), readReplicas: int (absent: 0)}
  serviceType, readOnlyServiceType   absent is ClusterIP
  serviceAnnotations, readOnlyServiceAnnotations   absent is {}
  any other field        absent is null
*/ -}}
{{- define "tpg.restoredNorm" -}}
{{- $v := get .spec .key -}}
{{- if eq .key "highAvailability" -}}
{{-   $h := dict -}}
{{-   if kindIs "map" $v }}{{ $h = $v }}{{ end -}}
{{-   toJson (dict "enabled" (eq (toString (default false $h.enabled)) "true") "readReplicas" (int (default 0 $h.readReplicas))) -}}
{{- else if or (eq .key "serviceType") (eq .key "readOnlyServiceType") -}}
{{-   toJson (toString (default "ClusterIP" $v)) -}}
{{- else if or (eq .key "serviceAnnotations") (eq .key "readOnlyServiceAnnotations") -}}
{{-   toJson (default dict $v) -}}
{{- else -}}
{{-   toJson $v -}}
{{- end -}}
{{- end -}}

{{- /*
tpg.restoredPostgres (dict "root" $ "mode" "base"|"over" "ctx" CTX): the spec of the Postgres object of a
restored instance (Round 23, tpg-restore), as YAML. R is the spec of the current restore-patch file.

mode base (R is the spec of the restored Postgres: the spec file of the pair, or the spec read from the
cluster after the restore), in this order:
  1 R as it is. A field R does not set stays unset: no chart default (storageClassName, walStorageSize,
    resources, highAvailability, persistentVolumeClaimPolicy, ...), no value of the entry is filled in.
  2 the fleet-managed references, only where R omits them: backupLocation {name: <instance>-backup-location}
    and imagePullSecret {name: regsecret} (the PostgresBackupLocation and the Secret this chart renders).
    When R sets its own backupLocation or imagePullSecret, R's value is the value (each one on its own)
  3 later changes: for every field of tpg.restoredEntrySpec (the entry's instance block, nothing else):
    the field is DIFFERENT when tpg.restoredNorm of the entry's value and of R's value are not equal
    (compared as JSON; a field R lacks differs from any value the entry sets, except the defaults of
    tpg.restoredNorm: highAvailability false/0, serviceType ClusterIP, empty annotations). A different
    field replaces R's (a map is replaced as a whole; highAvailability is merged key by key). An equal
    one changes nothing. tpg-restore writes the fleet-equivalent fields of R into the entry (and removes
    the ones R lacks), so right after a restore nothing differs; tpg-scale-instance (highAvailability)
    and tpg-upgrade component=postgres (postgresVersion) write the entry afterwards, and that is a
    later change.
  4 the instance's current postgres patch file (tpg-patch), merged over everything (tpg.kindPatch). The
    overlays of the creation (postgresOverlayFilePath), the values overlay and the instance: keys of a
    values patch do not apply to the Postgres of a restored instance.
mode over (an in-place restore with a spec file: the operator merged the file into the existing
Postgres, overwriting the fields it sets): the normal render (tpg.postgres), then
  1 the postgres overlay file and the postgres patch file that was current at the restore
    (restorePatch.postgresPatch); a patch file that tpg-patch set after the restore is not applied here
  2 R merged over it (maps key by key, anything else replaces); a highAvailability block that does not
    say enabled true is removed (a single node has no block, and the render's readReplicas must not
    survive an R that says enabled false)
  3 the later changes as in base 3, but only for the fields R sets (the render already carries the entry's
    values for the others). The fleet-managed references are those of the render (tpg.postgres) unless R sets
    its own backupLocation or imagePullSecret, which win
  4 the current postgres patch file when it is not the one of the restore
Last, tpg.prune (postgres.yaml) leaves out every field that holds its zero default.
*/ -}}
{{- define "tpg.restoredPostgres" -}}
{{- $root := .root -}}
{{- $mode := .mode -}}
{{- $name := toString $root.Values.instance.name -}}
{{- $rp := include "tpg.restorePatchSpec" $root | fromYaml -}}
{{- $node := include "tpg.restorePatchNode" $root | fromYaml -}}
{{- $patch := include "tpg.patchRef" (dict "root" $root "kind" "postgres" "group" "patches") -}}
{{- $patchAtRestore := eq $patch (toString (default "" $node.postgresPatch)) -}}
{{- $spec := dict -}}
{{- if eq $mode "over" -}}
{{-   $spec = (include "tpg.postgres" .ctx | fromYaml).spec -}}
{{-   $_ := include "tpg.deepMerge" (dict "dst" $spec "src" (include "tpg.kindPatch" (dict "root" $root "key" "Postgres" "groups" (ternary (list "overlays" "patches") (list "overlays") $patchAtRestore)) | fromYaml)) -}}
{{- end -}}
{{- $_ := include "tpg.deepMerge" (dict "dst" $spec "src" (deepCopy $rp)) -}}
{{- if and (eq $mode "over") (hasKey $spec "highAvailability") (kindIs "map" $spec.highAvailability) (ne (toString (dig "enabled" "" $spec.highAvailability)) "true") }}{{ $_ := unset $spec "highAvailability" }}{{ end -}}
{{- /* the fleet-managed references fill in only what the restore-patch omits: its own backupLocation / imagePullSecret win (mode over: the render already carries the fleet's, R was merged over it) */ -}}
{{- if eq $mode "base" -}}
{{-   if not (dig "backupLocation" "name" "" $spec) }}{{ $_ := set $spec "backupLocation" (dict "name" (printf "%s-backup-location" $name)) }}{{ end -}}
{{-   if not (dig "imagePullSecret" "name" "" $spec) }}{{ $_ := set $spec "imagePullSecret" (dict "name" "regsecret") }}{{ end -}}
{{- end -}}
{{- $ent := include "tpg.restoredEntry" $root | fromYaml -}}
{{- $ins := dict -}}
{{- if kindIs "map" $ent.instance }}{{ $ins = $ent.instance }}{{ end -}}
{{- $cand := include "tpg.restoredEntrySpec" (dict "ins" $ins) | fromYaml -}}
{{- range $k, $cv := $cand -}}
{{-   if and (ne (include "tpg.restoredNorm" (dict "key" $k "spec" $cand)) (include "tpg.restoredNorm" (dict "key" $k "spec" $rp))) (or (eq $mode "base") (hasKey $rp $k)) -}}
{{-     if eq $k "highAvailability" -}}
{{-       $rr := int $cv.readReplicas -}}
{{-       if and $cv.enabled (lt $rr 1) }}{{ fail (printf "instance.highAvailability.enabled is true with readReplicas %d: an HA instance needs readReplicas 1 or more (or set enabled false for a single node)" $rr) }}{{ end -}}
{{-       if and (not $cv.enabled) (gt $rr 0) }}{{ fail (printf "instance.highAvailability.readReplicas is %d but enabled is not true: read replicas need highAvailability.enabled true" $rr) }}{{ end -}}
{{-       if kindIs "map" (get $spec "highAvailability") -}}
{{-         $_ := include "tpg.deepMerge" (dict "dst" (get $spec "highAvailability") "src" $cv) -}}
{{-       else -}}
{{-         $_ := set $spec "highAvailability" (deepCopy $cv) -}}
{{-       end -}}
{{-     else if and (or (eq $k "serviceAnnotations") (eq $k "readOnlyServiceAnnotations")) (not $cv) -}}
{{-       $_ := unset $spec $k -}}
{{-     else if and (eq $k "readOnlyServiceType") (eq (toString $cv) "ClusterIP") -}}
{{-       $_ := unset $spec $k -}}
{{-     else -}}
{{-       $_ := set $spec $k (deepCopy $cv) -}}
{{-     end -}}
{{-   end -}}
{{- end -}}
{{- if or (eq $mode "base") (not $patchAtRestore) -}}
{{-   $_ := include "tpg.deepMerge" (dict "dst" $spec "src" (include "tpg.kindPatch" (dict "root" $root "key" "Postgres" "groups" (list "patches")) | fromYaml)) -}}
{{- end -}}
{{- toYaml $spec -}}
{{- end -}}
