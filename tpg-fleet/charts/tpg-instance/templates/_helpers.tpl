{{- define "tpg.required" -}}
{{- if not .Values.instance.name }}{{ fail "instance.name is required" }}{{ end -}}
{{- if not .Values.instance.postgresVersion }}{{ fail "instance.postgresVersion is required" }}{{ end -}}
{{- if not .Values.backup.container }}{{ fail "backup.container is required" }}{{ end -}}
{{- if hasKey .Values.instance "serviceType" }}{{ fail "instance.serviceType is replaced by instance.exposure (clusterIP, internalLoadBalancer or loadBalancer)" }}{{ end -}}
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
tpg.patchFile (dict "root" $ "file" PATH "what" LABEL): an overlay or patch file of this
chart parsed as YAML (a map). Patch files live in charts/tpg-instance/patches/, overlay
files in charts/tpg-instance/overlays/.
Returns YAML; fails the render when the file is missing or not a YAML map.
*/ -}}
{{- define "tpg.patchFile" -}}
{{- $raw := .root.Files.Get .file -}}
{{- if not $raw }}{{ fail (printf "%s file %s not found in the chart (charts/tpg-instance/%s)" .what .file .file) }}{{ end -}}
{{- $p := fromYaml $raw -}}
{{- if hasKey $p "Error" }}{{ fail (printf "%s file %s is not a YAML map: %s" .what .file $p.Error) }}{{ end -}}
{{- toYaml $p -}}
{{- end -}}

{{- /*
tpg.kindPatch (dict "root" $ "key" KEY): the spec fragment the instance's current
postgres overlay file and then its current postgres patch file hold for one object
(Round 15, D81; Round 22), as YAML ({} when none; where both set a field the patch wins).
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
{{- range $grp := list "overlays" "patches" -}}
{{- $f := include "tpg.patchRef" (dict "root" $.root "kind" "postgres" "group" $grp) -}}
{{- $what := ternary "postgres overlay" "postgres patch" (eq $grp "overlays") -}}
{{- if $f -}}
{{-   $raw := $.root.Files.Get $f -}}
{{-   if not $raw }}{{ fail (printf "%s file %s not found in the chart (charts/tpg-instance/%s)" $what $f $f) }}{{ end -}}
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
