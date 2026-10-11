# Instance spec files for tpg-restore

tpg-restore restores a source instance into a new target instance (another instance of the
same namespace, or an instance in another namespace or on another cluster). By default the new
target copies the source instance's entry of `clusters/fleet.yaml`. A **spec file** gives the new
target its own instance spec instead: name it in the pair of the `clusterMap` input with
`targetInstanceSpecFilePath: [repo:helm_artifacts/instance/tpg-instance/restore-specs/<file>]`
(Round 23, phase 6). The same key also takes a file of the submitting machine, `[./orders-dr.yaml]`,
which the submit scripts pack into `patchFiles`.

What goes here, and what does not:

- **One file per target shape**, with exactly **one** `kind: Postgres` document: `apiVersion:
  sql.tanzu.vmware.com/v1`, `kind: Postgres` and a `spec` fragment. No `metadata`: the name and
  the namespace come from the pair. The fragment is checked like a Postgres patch document, field by
  field against the CRD (`patchcheck.py spec`), and it becomes the instance spec of the new target
  (`postgresrestore.spec.targetInstance.spec`).
- Only tpg-restore reads this folder, and only for a **new** target. A pair whose target is an
  existing instance (in place, or an instance that already runs) refuses the key.
- **Not** a patch or an overlay: nothing in the chart reads these files (`.Files.Get` is never given a
  path in this folder, and `.helmignore` keeps the folder out of the packaged chart), no instance entry
  of `clusters/fleet.yaml` lists them, and editing a file changes no running instance. For a running
  instance use tpg-patch (`../patches/`); for the first render of a new instance use the overlays of
  tpg-day0 and tpg-create-instance (`../overlays/`).
- Add files through a reviewed commit, with a name that says what they are for (for example
  `orders-db-dr.yaml`). Only `.yaml` and `.yml` files of this folder are accepted by a run: no `..`, no
  absolute path, no `//` and no other folder, and this README is not a spec file.

```yaml
# restore-specs/orders-db-dr.yaml
apiVersion: sql.tanzu.vmware.com/v1
kind: Postgres
spec:
  postgresVersion:
    name: postgres-17.6
  highAvailability:
    enabled: false
```

See `docs/workflow-commands.md`, section 15 (tpg-restore).
