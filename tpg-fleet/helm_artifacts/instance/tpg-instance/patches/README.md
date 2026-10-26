# Instance patch files

tpg-patch patches running Postgres instances with files the workflows store in this
folder (Round 14, design decisions D76 to D79; Round 15, D81 to D83). tpg-create-instance
and tpg-day0 shape new instances from their first render with **overlay files**
(Round 22), stored in `helm_artifacts/instance/tpg-instance/overlays/` (see its README); the chart
merges the overlay first and the patch after it, so a patch wins. The chart reads
the files itself (`.Files.Get`), so they must live inside the chart.

Two kinds of file live here:

- **Stored files**, written by the workflows. Do not add or edit them by hand.
  - `<instance>-postgres-<hash>.yaml`: the postgres documents of one instance, one
    document per object, named by the hash of the contents. A run may send several
    files (`postgresPatchFilePath` is a list); the documents it sends replace those
    of the same objects, and the others are carried over from the current file.
  - `<name>-<uid>.yaml`: a values file (`postgresValuesPatchFilePath`), under its own
    name plus a unique 5-character UID.
- **Team files** that runs name with `repo:helm_artifacts/instance/tpg-instance/patches/<file>` instead
  of a file of the submitting machine. Add them through a reviewed commit, with a
  name that is not a stored name (for example `team-orders-backup-location.yaml`).
  A run copies such a file to a stored file, so editing it later changes no instance
  until a run names it again.

The instance entry in `clusters/fleet.yaml` records one current file per kind and
the one before it, relative to `helm_artifacts/instance/tpg-instance/`:

```yaml
clusters:
  aks-tpg-poc-01:
    instances:
      orders-db:
        patches:
          postgres:
            current: patches/orders-db-postgres-3f9a1.yaml     # postgresPatchFilePath
          postgresValues:
            current: patches/orders-backup-k3x9q.yaml          # postgresValuesPatchFilePath
            previous: {path: patches/orders-retention-a81zd.yaml, commit: 4f2c1e9a...}
```

| Kind of file | Input and clusterMap key | Content | Applied |
|---|---|---|---|
| Postgres patch | `postgresPatchFilePath` (tpg-patch only; tpg-day0 and tpg-create-instance: `postgresOverlayFilePath`) | YAML documents of the kinds `Postgres`, `PostgresBackupLocation`, `PostgresBackupSchedule` (with `metadata.name: <instance>-backup-full` or `<instance>-backup-incremental`) and `PostgresFerretDocumentDB`: `apiVersion: sql.tanzu.vmware.com/v1`, `kind` and a `spec` fragment, every field checked against the CRD of its kind; one document per object | each document is merged into the `spec` of the object of its kind, after the chart values, so the document wins (the warning `PATCH_OVERRIDES_VALUE` names a chart value it overrides) |
| Values patch | `postgresValuesPatchFilePath` (tpg-patch only; tpg-day0 and tpg-create-instance: `postgresValuesOverlayFilePath`) | a fragment of the chart values; every key must exist in `values.yaml` or `clusters/_template/` | merged into the values before the chart renders |

Only the current file is applied: maps merge key by key, any other value
(including `false`, `0` and `""`) replaces the rendered one, a list replaces the
whole list, and `null` removes a key. The `tpg-instances` ApplicationSet passes
`clusters/fleet.yaml` as a value file, so a sync at the commit of a tpg-patch pull
request branch applies that branch's current file before the merge.

An instance restored by tpg-restore (`instance.restored: true` in its entry) is rendered from its
**restore-patch** (`../restore-patch/`, see its README). Its current **postgres** patch file is applied
over the restore-patch and over the entry's later changes, so a patch is the way to change a restored
instance's Postgres beyond the scale and upgrade workflows. tpg-patch never touches the restore-patch
(it also patches other kinds, and the restore-patch stays the initial source of truth); the `instance:`
keys of a **values** patch do not reach the Postgres of a restored instance: tpg-patch refuses a values
patch that sets one for such an instance (`PATCH_REFUSED`, `RESTORED_VALUES_PATCH`), and a values patch
cannot set `instance.restored` or `restorePatch`.

tpg-patch refuses a file of the wrong kind (a Postgres manifest passed as values,
and the reverse), unknown keys and fields, a second document for one object, fields
that another workflow or input owns, fields that cannot change on a running
instance, and fields the `tpg-instances` ApplicationSet ignores
(`backup.additionalParameters`, `backup.enableSSL`, `backup.forcePathStyle`); see
`docs/workflow-commands.md`, tpg-patch. The Service fields of the Postgres spec
(`serviceType`, `serviceAnnotations`, `readOnlyServiceType`,
`readOnlyServiceAnnotations`) come from the exposure values, so a Postgres document
may not set them: change the exposure with a values patch, for example
`instance: {exposure: internalLoadBalancer}`. The overlay files of tpg-create-instance
and tpg-day0 apply their own creation rules (sizes and the storage class may be set
there); see `docs/workflow-commands.md`, tpg-create-instance. A values file may not set
`backup.repoPath` or `instance.disableInitialBackup` (the workflows own them).

`example-postgres-resources-ex4m1.yaml` and `example-values-backup-ex4m2.yaml` are
examples in the stored form, referenced by `clusters/fleet.example.yaml`. Operator
values files live in `helm_artifacts/operator/patches/` at the repository root.
