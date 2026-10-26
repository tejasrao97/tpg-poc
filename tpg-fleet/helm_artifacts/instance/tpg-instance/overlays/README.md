# Instance overlay files

tpg-create-instance and tpg-day0 shape a new instance from its first render with
overlay files they store in this folder (Round 22; before that they were called
patch files, `postgresPatchFilePath` and `postgresValuesPatchFilePath`). An overlay
applies at the initial deployment. tpg-patch changes the instance afterwards with
patch files (`helm_artifacts/instance/tpg-instance/patches/`), which stack on top of the overlay: the
chart merges the overlay first and the patch after it, so a patch wins over an
overlay and an overlay wins over the chart values. The chart reads the files itself
(`.Files.Get`), so they must live inside the chart.

Two kinds of file live here:

- **Stored files**, written by the workflows. Do not add or edit them by hand.
  - `<instance>-postgres-<hash>.yaml`: the postgres documents of one instance, one
    document per object, named by the hash of the contents. A run may send several
    files (`postgresOverlayFilePath` is a list); the documents it sends replace those
    of the same objects, and the others are carried over from the current file.
  - `<name>-<uid>.yaml`: a values file (`postgresValuesOverlayFilePath`), under its
    own name plus a unique 5-character UID.
- **Team files** that runs name with `repo:helm_artifacts/instance/tpg-instance/overlays/<file>`
  instead of a file of the submitting machine. Add them through a reviewed commit,
  with a name that is not a stored name (for example
  `team-orders-backup-location.yaml`). A run copies such a file to a stored file, so
  editing it later changes no instance until a run names it again.

The instance entry in `clusters/fleet.yaml` records one current file per kind and
the one before it, relative to `helm_artifacts/instance/tpg-instance/`, under `overlays:` (the same
shape as `patches:`):

```yaml
clusters:
  aks-tpg-poc-01:
    instances:
      orders-db:
        overlays:
          postgres:
            current: overlays/orders-db-postgres-3f9a1.yaml     # postgresOverlayFilePath
          postgresValues:
            current: overlays/orders-backup-k3x9q.yaml          # postgresValuesOverlayFilePath
```

| Kind of file | Input and clusterMap key | Content | Applied |
|---|---|---|---|
| Postgres overlay | `postgresOverlayFilePath` | YAML documents of the kinds `Postgres`, `PostgresBackupLocation`, `PostgresBackupSchedule` (with `metadata.name: <instance>-backup-full` or `<instance>-backup-incremental`) and `PostgresFerretDocumentDB`: `apiVersion: sql.tanzu.vmware.com/v1`, `kind` and a `spec` fragment, every field checked against the CRD of its kind; one document per object | each document is merged into the `spec` of the object of its kind, after the chart values and before the patch (the warning `OVERLAY_OVERRIDES_VALUE` names a chart value it overrides) |
| Values overlay | `postgresValuesOverlayFilePath` | a fragment of the chart values; every key must exist in `values.yaml` or `clusters/_template/` | merged into the values before the chart renders, before the values patch |

The rules are those of the patch files (see `helm_artifacts/instance/tpg-instance/patches/README.md`
and `docs/workflow-commands.md`) with the creation rules of a new instance: sizes
and the storage class may be set, and the fields that come from inputs
(`instance.name`, `instance.postgresVersion`, `instance.highAvailability`, the
exposure, `backup.enableSSL`, the CA bundle) are refused. An instance that already
runs keeps its current overlay when a run sends an identical file; a run that would
change it is refused (`OVERLAY_USE_TPG_PATCH` in tpg-day0, `INSTANCE_EXISTS` in
tpg-create-instance): use tpg-patch. Operator overlay files live in
`helm_artifacts/operator/overlays/` at the repository root.
