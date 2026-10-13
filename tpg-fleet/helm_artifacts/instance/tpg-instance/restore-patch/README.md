# Instance restore-patch files

tpg-restore stores here the spec of every instance it restored into a **new** instance or **in place**
(section 16 of `docs/workflow-commands.md`), so that the Argo CD render of the instance equals the
Postgres object the restore made (Round 23). The chart reads the files itself (`.Files.Get`), so they
must live inside the chart, and `.helmignore` must not list this folder.

- **Stored files only**, written by tpg-restore. Do not add or edit them by hand.
  - `<instance>-restore-<uid>.yaml`: one `kind: Postgres` document, `apiVersion:
    sql.tanzu.vmware.com/v1`, `kind: Postgres` and the `spec`. No `metadata`: the name and namespace
    come from the chart. The name carries a unique 5-character UID.
  - The `spec` is where the instance really is:
    - the spec file of the pair (`targetInstanceSpecFilePath`) as it was given to the PostgresRestore
      (`spec.targetInstance.spec`), or
    - without a spec file, the `.spec` of the Postgres read from the target cluster after the restore
      succeeded and the instance runs (the **live snapshot**). Only `.spec` is taken, so `status`,
      `metadata` (annotations, managed fields, `resourceVersion`, `uid`, ...) and the like are not in
      it; fields with a `null` value are dropped; **nothing else is stripped**: the live spec is the
      truth, including whatever the operator defaulted into it. It must fit the Postgres schema
      (`workflows/scripts/patchcheck.py spec`, the same check as for a spec file); when it does not,
      or cannot be read, nothing is stored (warning `RESTORE_PATCH_NOT_RECORDED`, which names the
      unknown or invalid fields, for example `spec.noSuchField is not a field of the Postgres
      resource`) and a new instance's Application is not synced by that run.
- The input spec files that runs name with `repo:` live in `../restore-specs/`; this folder holds
  what a run stored.

The instance entry in `clusters/fleet.yaml` marks the instance and records the files:

```yaml
clusters:
  aks-tpg-poc-02:
    instances:
      orders-db-dr:
        instance:
          restored: true                    # workflow-owned: tpg-restore writes it, a values patch may not
          postgresVersion: postgres-17.6    # the fleet-equivalent fields of the restore-patch (below)
          storageSize: 100Gi
          highAvailability: {enabled: false, readReplicas: 0}
          exposure: clusterIP
        restorePatch:
          current: restore-patch/orders-db-dr-restore-k3x9q.yaml
          mode: base                        # base | over, see below
          previous: {path: restore-patch/orders-db-dr-restore-a81zd.yaml, commit: 4f2c1e9a...}
          postgresPatch: patches/orders-db-dr-postgres-m2k1x.yaml   # mode over only
```

Paths are relative to `helm_artifacts/instance/tpg-instance/`. Only `current` is applied; `previous`
is the record of the restore before (no longer applied).

## How the chart renders a restored instance

The Postgres object of an instance with `instance.restored: true` is built by `tpg.restoredPostgres`
(`templates/_helpers.tpl`, which has the same text in its comment). The other objects of the instance
(backup location, schedules, secrets, network policies, FerretDB) render as for any instance.
`R` is the `spec` of the current restore-patch file.

**mode `base`** (a new instance, with or without a spec file; an in-place restore without one): `R` is
the whole truth. In this order:

1. `R` as it is. A field `R` does not set **stays unset**: nothing of the chart defaults
   (`storageClassName`, `walStorageSize`, `resources`, `highAvailability`, `persistentVolumeClaimPolicy`,
   ...) and nothing of the entry is filled in.
2. The fleet-managed references, **only where `R` omits them**: `backupLocation:
   {name: <instance>-backup-location}` and `imagePullSecret: {name: regsecret}` (the
   PostgresBackupLocation and the Secret this chart renders). When `R` sets its own `backupLocation` or
   `imagePullSecret` (a spec file or a snapshot), `R`'s value wins, each one on its own. A
   `backupLocation` a spec file names must exist in the target namespace
   (tpg-restore: `BACKUP_LOCATION_MISSING`).
3. **Later changes**: the entry's fleet-equivalent fields that **differ** from `R` (below).
4. The instance's **current postgres patch file** (tpg-patch), merged over everything. The overlays of
   the creation (`postgresOverlayFilePath`), the values overlay and the `instance:` keys of a values
   patch do **not** apply to the Postgres of a restored instance (a values patch still renders the other
   objects; change the Postgres with a postgres patch file, tpg-scale-instance or tpg-upgrade).

**mode `over`** (an in-place restore **with** a spec file: the operator merges the file into the existing
Postgres, overwriting the fields it sets): the normal render (chart defaults, the entry, the postgres
overlay file, the postgres patch file that was current at the restore, `restorePatch.postgresPatch`),
then `R` merged over it (maps key by key, anything else replaces; a `highAvailability` block that does
not say `enabled: true` is removed; `R`'s own `backupLocation` and `imagePullSecret` win over the
render's), the later changes for the fields `R` sets, and last the current postgres patch file if it is not the one of the restore (a file
tpg-patch set later is applied after `R`; the one of the restore was already under it).

Last, `tpg.prune` leaves out every field that holds its zero default (as for every instance).

### What "differs" means (later changes)

The fleet-equivalent fields are read from the entry's `instance:` block only (never from the chart
defaults, the templates or the cluster), for the keys that are **present** in it:

| Entry (`instance:`) | Postgres spec |
|---|---|
| `postgresVersion` | `postgresVersion.name` |
| `storageClassName`, `storageSize`, `walStorageSize` | the same fields |
| `resources` | `resources` (as a whole) |
| `highAvailability.enabled`, `.readReplicas` | `highAvailability` |
| `exposure`, `readOnlyExposure`, `serviceAnnotations`, `readOnlyServiceAnnotations` | `serviceType`, `serviceAnnotations`, `readOnlyServiceType`, `readOnlyServiceAnnotations` (`allowedSourceRanges` and `internalLoadBalancerSubnet` are not read: a restored instance keeps the annotations of its restore-patch as `serviceAnnotations`) |

A field **differs** when `tpg.restoredNorm` of the entry's value and of `R`'s value are not equal,
compared as JSON; `R` lacking the field differs from any value the entry sets, except these defaults,
which equal "not set": `highAvailability` absent is `{enabled: false, readReplicas: 0}`, `serviceType`
and `readOnlyServiceType` absent is `ClusterIP`, empty annotations are absent. A differing field
replaces `R`'s (a map is replaced as a whole; `highAvailability` is merged key by key); an equal one
changes nothing. In mode `over` only the fields `R` sets are compared (the render already carries the
entry's values for the others).

tpg-restore writes the fleet-equivalent fields of `R` into the entry (and, in mode `base`, removes the
ones `R` lacks, so no value of the source's entry or of an earlier deployment survives), so right after a
restore nothing differs. Afterwards:

- **tpg-scale-instance** writes `instance.highAvailability`, **tpg-upgrade component=postgres** writes
  `instance.postgresVersion`: the entry then differs from `R` and the render follows the entry.
- **tpg-patch** postgres patch files apply after `R` and the later changes.
- Nothing else changes the Postgres of a restored instance: **tpg-day0** (and tpg-create-instance) block
  it with `INSTANCE_RESTORED` (that instance only), a values patch cannot set `instance.restored` or
  `restorePatch`, and a values patch that sets an `instance:` key which reaches the Postgres
  (`storageSize`, `walStorageSize`, `resources`, `exposure`, `readOnlyExposure`, `serviceAnnotations`,
  `readOnlyServiceAnnotations`, `allowedSourceRanges`, `internalLoadBalancerSubnet`) is refused by
  tpg-patch (`RESTORED_VALUES_PATCH`, naming tpg-scale-instance, tpg-upgrade and postgres patch files);
  keys that do not reach it stay allowed. tpg-network-policy does not touch the Postgres.
- Without `clusters/fleet.yaml` as a value file (a render by hand) there is no entry to compare:
  `.Values.instance.restored` and `.Values.restorePatch` are read and the restore-patch renders alone.

## When it is written

- tpg-restore into a **new** target with a spec file writes it in the same commit as the new entry
  (copied from the source's, minus `restorePatch`, `instance.restored`, `ferret`, `backup.repoPath`,
  `instance.disableInitialBackup` and the source's postgres patch and overlay files, which changed the
  source's Postgres, not this one), with `instance.restored: true`, `mode: base` and the seeded fields.
- In every other case (a new target without a spec file, an instance declared in `clusters/fleet.yaml`
  but not deployed, an in-place restore) in a commit of its own after the restore succeeded and the
  instance runs (`pushMode` applies): the spec file's spec, or the live snapshot. In place with a spec
  file is mode `over` (and records `postgresPatch`), everything else mode `base`. A restore never goes
  into another existing instance (`TARGET_EXISTS`). An in-place instance that has no entry in
  `clusters/fleet.yaml` records nothing.
- A **re-restore** writes the new file as `restorePatch.current`, the former current becomes `previous`
  (no longer applied), and the file that was `previous` is deleted (its commit stays in Git). The
  source's restore-patch is never copied to a new target.
- tpg-patch never touches this folder or `restorePatch`: it also patches other kinds, and the
  restore-patch stays the initial source of truth. Deleting the instance keeps its files, like the audit
  copy of the entry in `clusters/deleted/` that records them.

`scripts/validate.sh` checks that every file `clusters/fleet.yaml` and `clusters/fleet.example.yaml`
(and the audit copies in `clusters/deleted/`) record exists and fits the Postgres schema, that every file
in this folder is recorded, that `restorePatch.mode` is `base` or `over` and that `instance.restored` and
`restorePatch.current` go together.

`example-restore-orders-db-dr1x7.yaml` is an example in the stored form, referenced by
`clusters/fleet.example.yaml`.
