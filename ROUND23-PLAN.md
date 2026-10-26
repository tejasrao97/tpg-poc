# Round 23 plan: tpg-fleet and tpg-aks-infra (V16 to V17)

## Context

Round 23 is seven requested changes to the Tanzu for Postgres on AKS fleet automation, plus one that came out of the clarification rounds (a free `namespace` per instance). The baseline is `/Users/tejas/Downloads/V16` (the `tpg-fleet` and `tpg-aks-infra` folders are identical to their zips). Results go to a new sibling folder `/Users/tejas/Downloads/V17`; V16 is never edited.

Labels for this round start at D95, I33, V108 (POV lab items), V86 (README) and T146 (Runbook tests). DR stays out. No key, input or value is removed except the ones this round replaces (the flat `tpg-restore` inputs).

## Locked decisions (from the clarification rounds)

1. **Folders:** `helm_artifacts/instance/tpg-instance`, `helm_artifacts/instance/crd-reference`, `helm_artifacts/operator/overlays`, `helm_artifacts/operator/patches` (flattened; the old `overlays/operator/` and `patches/operator/` levels disappear). Fresh deploy only, no migration script.
2. **Lists:** strict. Every list input is bracketed, even with one value (`[tpg-poc-01]`); only `all` (and `auto` for `components`) stays bare. A comma-separated string is rejected with the list syntax in the message. Single-file inputs are bracketed and hold exactly one file. A file entry that is not `repo:<file path>` or a local path, including `repo: <path>` with whitespace (which YAML reads as a map), fails with: `repo:<file path> "check for white spaces in between"`. List values inside `clusterMap` follow the same rule. In the `apps` map of `tpg-delete-apps` each instance is its own element (`tpg-instances:orders-db`).
3. **`disableInitialBackup`:** fails on the `clusterMap` key path. See phase 4 for the suspected cause.
4. **`purgeBackups` on `tpg-delete-instance` and `tpg-delete-apps`** (input and `clusterMap` instance key): expire every PostgresBackup of the instance while it runs, then after the instance is gone delete every blob left under its container and `repoPath`. A `repoPath` shared with another PostgresBackupLocation on any registered cluster: expire only, blobs kept, reported. `purgeBackups=true` with `finalBackup` `true` or `required` is refused.
5. **`tpg-backup-expire`** (new): `clusterMap` only; per instance `backups: [..]` or `purgeBackups: true` (not both), optional `includeDependents: true` (required to expire a full backup that has dependents; otherwise that instance is BLOCKED with the list). Purge here expires all backups and never deletes blobs. `dryRun` default `true`; `confirm` list of the cluster names.
6. **Parameter files:** all 13 workflows (12 existing plus `tpg-backup-expire`) get a generated parameter-file JSON Schema, a generated example file, and in `workflow-commands.md` a schema block plus two worked examples.
7. **Restore:**
   - `clusterMap` is a list of pairs `{sourceClusterConfig, targetClusterConfig}`, each `<cluster>: <namespace>: <instance>: {...}`, exactly one source instance and one target instance per pair. Namespaces mandatory. The flat inputs (`sourceCluster`, `instance`, `mode`, `targetTime`, `backupName`, `lsn`, `xid`, `targetCluster`, `targetInstance`, `confirm`, `bestEffort`) are removed.
   - Source keys: `sourceBackupName` (mandatory when `pitrEnabled: false`; with PITR used only to derive location and stanza when the instance is gone).
   - Target keys: `pitrEnabled`; `pitrConfig.type` (`latest|time|lsn|transaction`), `pitrConfig.target` (lsn, transaction), `pitrConfig.timestamp` (time), `pitrConfig.sourceBackupConfig.{srcBackupLocationName, srcStanzaName, srcBackupLabel}` (first two optional and derived; a difference from what the cluster reports is a warning; mandatory when there is neither a live source instance nor a `sourceBackupName`; `srcBackupLabel` is `pitr.sourceBackupLocation.set`, refused with `latest`); `bestEffort` (mandatory for `time`, `lsn`, `transaction`; refused with `latest`); `targetInstanceSpecFilePath` (one `kind: Postgres` document, local or `[repo:<path>]`; refused for an existing target; without it a new target copies the source's `fleet.yaml` entry, and it is mandatory when the source is not in `fleet.yaml`); `confirm` (the target instance name, mandatory when the target exists); `skipMinorVersionCheck` (annotation `sql.tanzu.vmware.com/skip-minor-version-check: "true"` on the PostgresRestore); `postRestoreBackup` (default false).
   - PostgresRestore: `targetInstance.name` always; `targetInstance.spec` only for a new target; `pitr` and `sourceBackup` never together.
   - Prerequisites for another namespace or cluster: the source PostgresBackupLocation is re-created in the target namespace (namespace replaced, source metadata and annotations dropped, retention set so no expiry runs through it); its Secret comes from Vault when it is `backup-storage`, otherwise it is copied in memory (never a file, never the log).
   - Every new target is written to `clusters/fleet.yaml` (`pushMode`) and adopted by Argo CD.
   - In-place restore: `clusters.<c>.cluster.allowInPlaceRestore: true` (default false) and `confirm`.
   - Matrix: lite is a PostgresVersion name ending in `-lite` (one pattern in `types.yaml`). Standard to lite, or a lower minor version, BLOCKS that restore only (`RESTORE_FLAVOUR_UNSUPPORTED`, `RESTORE_VERSION_LOWER`).
   - Workflow inputs: `clusterMap`, `rolloutMode` (default `all`; `batches`; `canary` = first pair alone, a failed canary stops the run), `pushMode`, `dryRun`, `maxParallel`, `restoreTimeoutSeconds`, `prTimeoutSeconds`, `patchFiles`, `keepSourceLocation` (default true). Results are independent per pair; the run fails if any pair failed.
   - Success: PostgresRestore `Succeeded` and the target instance Running.
8. **`namespace`:** optional `clusterMap` instance key on `tpg-day0` and `tpg-create-instance`, default `pg-<instance>`, stored as `instance.namespace` in `clusters/fleet.yaml`, immutable, reserved namespaces refused (`kube-system`, `kube-public`, `kube-node-lease`, `default`, `argocd`, `argo`, `vault`, `cert-manager`, `monitoring`, the operator namespace). Every other workflow reads it from `fleet.yaml`. Shared namespaces allowed with guards: one owner of the shared Secrets per namespace, network policy selected by instance label, `purgeNamespace` refused while another fleet instance remains (except `tpg-delete-apps` with `deleteOperator: true`).

## Step 0: workspace and toolchain (approved)

- Copy `V16/tpg-fleet`, `V16/tpg-aks-infra` and the loose `.md`/`.docx` files to `V17` (no `__pycache__`, no `.DS_Store`). `git init` each repository folder in V17 with one baseline commit, so every phase is one reviewable commit. The delivered zips contain no `.git`.
- Homebrew: `bash`, `helm` (4.x), `yq`, `shellcheck`, `yamllint`, `kubeconform`, `kustomize`, `argo` (4.1.3), `argocd` (3.5.3), `opentofu`. Python venv in the scratchpad: PyYAML, python-docx, check-jsonschema. `setup-envtest` with Kubernetes 1.34.1 (release binary if available, else via Go; stated before installing).
- Run `tests/run-all.sh` on the untouched V17 copy first and record the baseline result. Any suite that fails before a change is reported as a baseline failure, not hidden.

## Phases (one Sonnet 5.5 agent each, in order, same V17 tree)

Each phase: write or extend the tests first, implement, regenerate generated files (`workflows/params/generate.py`, `clustermap_schema.py`, `patch_schemas.py`, `tools/crd-defaults/generate.py`, `monitoring/grafana/generate.py`), run `tests/run-all.sh` and `scripts/validate.sh`, commit. Then an Opus 5.5 review of that commit's diff; findings are fixed before the next phase starts.

### Phase 1: folder move (item 1)
- `git mv` `charts/tpg-instance`, `charts/crd-reference`, `overlays/operator/*`, `patches/operator/*` and the READMEs to the new layout.
- Rewrite every path reference (about 70 fleet files): `bootstrap/appsets/tpg-instances.yaml` (`path`, and the relative `valueFiles`, now three levels up), `bootstrap/appsets/tpg-operator.yaml`, `workflows/scripts/{lib.sh,patch-lib.sh,patch-plan.sh,patch-cluster.sh,fleet-day0.sh,fleet-commit.sh,day0-deploy.sh,operator-upgrade.sh,restore.sh,validate-params.sh,clustermap.py}` (`CHART_PREFIX`, the `repoDir` prefixes of `repo:` paths, the `patches/operator/clusters/` guard), `workflows/params/{cluster-map-keys.yaml,clustermap_schema.py,patch_schemas.py}`, `tools/crd-defaults/generate.py`, `tools/unused-keys/*`, `.yamllint`, `scripts/validate.sh`, `scripts/submit/submit-lib.sh`, every test suite, `clusters/*`, READMEs and docs.
- `tpg-aks-infra`: `scripts/steps/60-verify.sh`, `scripts/vault-secret.sh`, `tests/verify/run.sh`.
- Check: a grep for the old top-level `charts/`, `overlays/` and `patches/` paths over both repositories returns only paths under `helm_artifacts/`.

### Phase 2: strict lists (item 2)
- One parser, reused everywhere: extend `as_list` in `workflows/scripts/clustermap.py` (flow list `[a, b]` and JSON `["a","b"]`; reject bare comma strings; detect a `{repo: ...}` map element and raise the whitespace message) and expose it to shell through a small `lib.sh` function (`list_items NAME VALUE`) that replaces the comma splitting in `validate-params.sh` (`clusters_check`, `instances_check`, `kinds_check`, `patch_path`, `same_set`), `discover.sh`, `plan-batches.sh`, `fleet-day0.sh`, `helm-addons.sh`, `rotate-*.sh`, `network-policy.sh`.
- `workflows/params/types.yaml`: new patterns for `list`, `listOrAll`, `components`, `cidrList`, `fqdnList`, `patchFileList`, `kindList`, and bracketed single-file types; `generate.py` (the `split(',')` in the CEL for `all`); regenerate `admission/workflow-parameters.yaml`.
- Template defaults and descriptions in all `workflows/templates/*.yaml`; `cron/tpg-backup-*.yaml` (`clusters: all` stays).
- `scripts/submit/*.sh` and `submit-lib.sh`: prompts accept names and send the bracketed form; `pack-patch-files.sh` reads bracketed paths.
- Tests: `params`, `cluster-map`, `admission`, `submit`, `regex-limits`, `cli-flags` fixtures; new cases for a comma string, a one-element list, `[repo: x.yaml]`, an empty element (`[a, , b]`), `[]`.

### Phase 3: `namespace` key
- `cluster-map-keys.yaml`: instance key `namespace` (day0, create-instance; `fleet: [.instance.namespace]`); `helm_artifacts/instance/tpg-instance/values.yaml` and `clusters/_template/instance.yaml` document it.
- One accessor in `lib.sh`, `instance_ns CLUSTER INSTANCE` (from `fleet.yaml`, default `pg-<instance>`), built on the existing `instance_effective`; replace every derived `pg-$i` in `lib.sh`, `network-policy.sh`, `delete-apps.sh`, `delete-instance.sh`, `day0-deploy.sh`, `day0-precheck.sh`, `patch-lib.sh`, `patch-cluster.sh`, `scale-instance.sh`, `operator-upgrade.sh`, `backup-instance.sh`, `fleet-day0.sh`, `validate-params.sh`, `tools/pgdata/pgdata.py`.
- `bootstrap/appsets/tpg-instances.yaml`: `destination.namespace` from the entry's `instance.namespace`.
- Chart: shared Secrets (`regsecret`, `backup-storage` VaultStaticSecrets) rendered by the first instance of the namespace only (a chart value `sharedSecretsOwner`, written by the plan step and moved by the delete step when the owner leaves); `networkpolicy.yaml` selects pods by the `postgres-instance` label.
- Guards: immutable namespace, reserved list, `purgeNamespace` rule in `delete-instance.sh`/`delete-apps.sh`.
- Monitoring: dashboards and alert rules that filter on `pg-.*` namespaces switch to the instance label (`monitoring/grafana/generate.py`, regenerate).
- `tpg-aks-infra/scripts/steps/60-verify.sh`: per-instance checks read the namespace from `fleet.yaml`.
- Tests: `chart`, `day0-plan`, `cluster-map`, `network-policy`, `monitoring`, verify; new cases for two instances in one namespace and the owner hand-over.

### Phase 4: `disableInitialBackup` (item 3)
- Leading suspect, found while reading: in `workflows/params/cluster-map-keys.yaml` the `disableInitialBackup` entry has duplicate `fleet:` and `format:` keys. The lines `format: boolean` / `fleet: [.backup.enableSSL]` belong to `backupEnableSSL` (which has none) and sit under `disableInitialBackup`, where the last duplicate wins. The effect would be that `disableInitialBackup: true` writes `backup.enableSSL: true` and never `instance.disableInitialBackup`, and `backupEnableSSL` is written nowhere. This is not proven yet: no `yq` on this machine. Step one of the phase is to reproduce it.
- The user's observation: `values.yaml` has no `instance.disableInitialBackup`. The template reads it with `default false` and `clusters/_template/instance.yaml` sets it, so a missing chart default should not by itself drop the annotation; it is added anyway (`disableInitialBackup: false`, documented) so the chart is complete on its own.
- Work: a failing `tests/day0-plan` case that sets the key in `clusterMap` (and one for `backupEnableSSL`), fix the registry entry, add a duplicate-key check to `tests/params` (a PyYAML loader that rejects duplicates, over every YAML file under `workflows/params`), a `tests/chart` render through the ApplicationSet-style merged values, and trace the remaining path (`fleet-commit.sh`, the ApplicationSet `values` template) if the test still fails after the registry fix.
- Whether the operator honours the annotation stays a lab item (V81 already says so).

### Phase 5: purge and `tpg-backup-expire` (items 4, 5)
- `lib.sh`: `backup_expire NS NAME` (patch `spec.expire=true`, wait for the expire job, record what pgBackRest declined), `backup_dependents`, `repo_shared C NS LOCATION` (scan PostgresBackupLocations on every registered cluster for the same container and `repoPath`), `blob_delete_prefix` built on the existing SharedKey helper (the Blob GET at `lib.sh` lines 236-257; add List Blobs and Delete Blob, key from Vault as today, never logged).
- `delete-instance.sh`: expire step before the delete, blob step after; `delete-apps.sh` passes it through. Inputs and `clusterMap` key `purgeBackups` in both templates, `types.yaml` (rule: `purgeBackups=true` with `finalBackup` true or required), `cluster-map-keys.yaml`, submit scripts.
- New: `workflows/templates/tpg-backup-expire.yaml`, `workflows/scripts/backup-expire.sh` (plan with dependents, dry run, confirm, per-instance result), `scripts/submit/tpg-backup-expire.sh`, `kustomization.yaml` (template and script), `rbac.yaml` if the patch verb on `postgresbackups` is missing, `clustermap-backup-expire` schema and example.
- `tpg-aks-infra`: `60-verify.sh` checks the new template; Vault policy unchanged (same storage key).
- Tests: new `tests/backup-expire` (stub `kubectl` and `curl`): expire named, dependents BLOCKED, purge all, shared repo keeps blobs, refused pair, dry run changes nothing.

### Phase 6: restore (item 7)
- Rewrite `workflows/templates/tpg-restore.yaml` (validate, plan-batches, one restore step per pair, report) and `workflows/scripts/restore.sh` around one pair; reuse `plan-batches.sh` (extended to batch pairs), `latest_cr`, `pg_wait_ready`, `sync_instance_app`, `git_commit_push`, `patch_fetch`/`patchcheck.py` (for the spec file), `record`/`result_guard`.
- New `workflows/scripts/restore-map.py` (or a `restore` mode of `clustermap.py`): validate the list of pairs, cardinality, the key rules above, and normalize to one JSON object per pair. Schema and example `clustermap-restore.*`.
- `restore.sh` steps per pair: resolve source (instance or backup object; stanza, location, version, flavour), matrix and in-place checks, prepare target (namespace, fleet entry, location and Secret hand-over), render the PostgresRestore, dry run stops here, apply and wait, instance Running, adoption sync, optional post-restore backup, optional removal of the source location copy.
- `clusters/_template/cluster.yaml`: `allowInPlaceRestore: false`. `types.yaml`: restore inputs, the `-lite` pattern. `scripts/submit/tpg-restore.sh` rewritten.
- Tests: new `tests/restore` (stub `kubectl`): the three methods with and without PITR, each PITR type, derived and given stanza, every refusal, matrix blocks, canary stop, dry run; `crd-reference` compares the rendered PostgresRestore with the CRD schema.

### Phase 7: parameter files and docs (item 6 and all references)
- `workflows/params/params_schema.py` (new, in the style of `clustermap_schema.py`): from `types.yaml` and the templates generate `schemas/params-<workflow>.schema.{json,yaml}` and `params-<workflow>.example.yaml`; `--check` mode; `tests/params` validates every example against its schema and against the admission policy.
- `docs/workflow-commands.md`: section 2 (types, list syntax, the whitespace error), section 3 (generated blocks), a parameter-file subsection with schema and two examples in every workflow section, new section for `tpg-backup-expire`, section 15 rewritten for restore (methods a, b, c, the matrix, the prerequisites the workflow performs), sections 10 and 11 for `purgeBackups`, `namespace` throughout, renumbered contents.
- `tpg-fleet/README.md`, `tests/README.md`, `docs/monitoring.md`, chart READMEs; `tpg-aks-infra/README.md`, `docs/README-manual-steps.md`, `docs/README-argo-on-aks.md`.

### Phase 8: documents and delivery
- Copies at the V17 root: `workflow-commands.md`, `monitoring.md`, `README-manual-steps.md` (identical to the repository files).
- `Tanzu-Postgres-AKS-POV-Design.docx` and `Tanzu-Postgres-AKS-POC-Runbook.docx` updated with python-docx in the `tanzu-doc-style` look: decisions D95 onward, lab items V108 onward, tests T146 onward (restore methods, expire, purge, namespace, lists, the lab-only items below).
- `HANDOFF.md`: Round 23 section, next labels, the open lab items.
- Zips `tpg-fleet.zip` and `tpg-aks-infra.zip` (branch `main` content, no `.git`), then unzip into a scratch folder and run `tests/run-all.sh` from the unzipped copy.

## Lab-only items (stated in the Runbook as tests, not as facts)

- A `sourceBackup` restore into another namespace through `backupSync` (refused today as `UNSUPPORTED_COMBINATION`).
- Whether pgBackRest refuses to expire the last full backup, and what the expire job reports.
- Whether operator 4.5 honours `skip-initial-backup` and `skip-minor-version-check`.
- The `-lite` naming of PostgresVersion objects.

## Verification

- After every phase: `tests/run-all.sh` (fleet and infra suites), `scripts/validate.sh`, generators with `--check`, `shellcheck` and `yamllint` clean, `helm template` of the chart for a single-node, an HA and a shared-namespace instance.
- Opus 5.5 review after each phase (diff of the phase commit) and one final review of `diff -r V16 V17` against this plan and the locked decisions, including a search for leftovers: comma-separated examples, `pg-<instance>` derivations, old folder paths, the removed restore inputs.
- Final report: per phase what was built, the test counts as run, anything not verified locally, and the lab items.
