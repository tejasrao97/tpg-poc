# Instance spec files for tpg-restore

tpg-restore restores a source instance into a new target instance (another instance of the
same namespace, or an instance in another namespace or on another cluster) or into the instance itself
(in place). A **spec file** gives the restored instance its spec: name it in the pair of the
`clusterMap` input with
`targetInstanceSpecFilePath: [repo:helm_artifacts/instance/tpg-instance/restore-specs/<file>]`
(Round 23, phase 6). The same key also takes a file of the submitting machine, `[./orders-dr.yaml]`,
which the submit scripts pack into `patchFiles`. Without it a new target copies the source instance's
entry of `clusters/fleet.yaml`, and the PostgresRestore sends the operator only the instance name.

What goes here, and what does not:

- **One file per target shape**, with exactly **one** `kind: Postgres` document: `apiVersion:
  sql.tanzu.vmware.com/v1`, `kind: Postgres` and a `spec` fragment. No `metadata`: the name and
  the namespace come from the pair. The fragment is checked like a Postgres patch document, field by
  field against the CRD (`patchcheck.py spec`), and it is the spec of the restored instance
  (`postgresrestore.spec.targetInstance.spec`, as it is, not merged over a chart render). Give a complete
  instance spec: Argo CD renders the restored instance from this spec (as its restore-patch), so a field
  the file leaves out stays unset, the chart does not fill it in from its defaults. The fleet's
  `backupLocation` (`<instance>-backup-location`) and `imagePullSecret` (`regsecret`) are filled in only
  when the file omits them; a `backupLocation` or `imagePullSecret` the file sets wins (a location it names
  must exist in the target namespace).
- Only tpg-restore reads this folder, and it accepts a spec file for a **new** target and for an
  **in-place** restore (a restore never goes into any other existing instance: `TARGET_EXISTS`).
- **Not** a patch or an overlay: nothing in the chart reads these files (`.Files.Get` is never given a
  path in this folder, and `.helmignore` keeps the folder out of the packaged chart), no instance entry
  of `clusters/fleet.yaml` lists them, and editing a file changes no running instance. What a run stores
  from a spec file is a copy in `../restore-patch/` (the instance's **restore-patch**, which the chart does
  read and renders the restored instance from, see its README). For a running instance use tpg-patch (`../patches/`); for the
  first render of a new instance use the overlays of tpg-day0 and tpg-create-instance (`../overlays/`).
- Add files through a reviewed commit, with a name that says what they are for (for example
  `orders-db-dr.yaml`). Only `.yaml` and `.yml` files of this folder are accepted by a run: no `..`, no
  absolute path, no `//`, no other folder and no symbolic link (a link, or a path that resolves outside this
  folder, is refused with `SPEC_FILE_INVALID`), and this README is not a spec file.

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
