# Instance restore-patch files

tpg-restore stores here the spec of every instance it restored with a **spec file**
(`targetInstanceSpecFilePath` of the pair, section 15 of `docs/workflow-commands.md`), so that the
Argo CD render of the instance equals the Postgres object the PostgresRestore created (Round 23).
The chart reads the files itself (`.Files.Get`), so they must live inside the chart, and
`.helmignore` must not list this folder.

- **Stored files only**, written by tpg-restore. Do not add or edit them by hand. A pair without a
  spec file stores nothing.
  - `<instance>-restore-<uid>.yaml`: one `kind: Postgres` document, `apiVersion:
    sql.tanzu.vmware.com/v1`, `kind: Postgres` and the `spec` of the spec file as it was given to the
    PostgresRestore (`spec.targetInstance.spec`). No `metadata`: the name and namespace come from the
    chart. The name carries a unique 5-character UID.
- The input spec files that runs name with `repo:` live in `../restore-specs/`; this folder holds
  what a run stored from them.

The instance entry in `clusters/fleet.yaml` records the current file and the one before it, relative
to `helm_artifacts/instance/tpg-instance/`, under `restorePatch:` (the shape of `patches:`, without the
kind level):

```yaml
clusters:
  aks-tpg-poc-02:
    instances:
      orders-db-dr:
        restorePatch:
          current: restore-patch/orders-db-dr-restore-k3x9q.yaml
          previous: {path: restore-patch/orders-db-dr-restore-a81zd.yaml, commit: 4f2c1e9a...}
```

How it is applied: the chart merges the document into the `spec` of the Postgres object **last**:
chart values, values overlay and patch, then the Postgres overlay document, then the Postgres patch
document, then the restore-patch (`tpg.kindPatch`). Maps merge key by key, any other value (including
`false`, `0` and `""`) replaces the rendered one, a list replaces the whole list. So every field the
spec file sets is what Argo CD renders, whatever the entry's values or an earlier patch say; a field
the spec file leaves out keeps the value the chart renders for it (the entry's, and the operator's
defaults on the object).

When it is written and retired:

- tpg-restore into a **new** target writes it in the same commit as the new entry in
  `clusters/fleet.yaml`; into an **existing** target (in place, or an instance declared in
  `clusters/fleet.yaml` but not deployed) in a commit of its own after the restore succeeded
  (`pushMode` applies to both). A restore with a spec file replaces the current restore-patch of the
  instance: the former current becomes `previous` and the file that was `previous` is deleted (the
  commit stays in Git).
- A later **tpg-patch** that sets a patch file on the instance (a Postgres patch or a values patch)
  replaces the restore-patch as the instance's change: `restorePatch.current` moves to
  `restorePatch.previous` in the same commit, so the chart stops applying it and the patch is the
  newest word. The values that the restore-patch fixed (for example `storageSize`) then come from the
  entry and the patch again; tpg-patch refuses a patch that would shrink a volume or change the
  storage class (set them in the patch). `patchMode=clear` keeps the restore-patch.
- Deleting the instance keeps its files, like the audit copy of the entry in `clusters/deleted/`
  that records them.

`scripts/validate.sh` checks that every file `clusters/fleet.yaml` and `clusters/fleet.example.yaml`
(and the audit copies in `clusters/deleted/`) record exists and fits the Postgres patch schema, and
that every file in this folder is recorded. A values patch may not set `restorePatch`.

`example-restore-orders-db-dr1x7.yaml` is an example in the stored form, referenced by
`clusters/fleet.example.yaml`.
