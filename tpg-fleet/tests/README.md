# tests

Offline tests. None of them need a cluster, a Helm repository or Azure; they run
from a clone and are part of `scripts/validate.sh`.

```bash
tests/run-all.sh              # everything that runs without extra binaries
tests/run-all.sh --against-cli   # also compare every flag with the installed CLIs
```

| Suite | What it covers | Requires |
|---|---|---|
| `cli-flags/` | Flags the pinned CLI version no longer accepts, in shell scripts, WorkflowTemplates and Markdown; jq and yq alternatives whose fallback is `true` or a non-zero number, in both repositories (`check_zero_defaults.py`, I22) | python3 (PyYAML) |
| `helm4/` | `workflows/scripts/helm-addons.sh` end to end against a Helm 4 CLI | python3, jq, yq (mikefarah) |
| `git-merge/` | Round 22: the writers of `clusters/fleet.yaml` (`git_push_head`, `git_merge_remote`, `fleet_lock_*` in `workflows/scripts/lib.sh`, `fleet-merge3.sh`): the lock is waited for, taken over when stale and released; a push rejected after another run changed the same file merges key by key (a text rebase conflict included), a conflict of values fails | git, jq, yq |
| `stuck-app/` | Round 22: `app_removed_or_force` and `app_stuck_reason`: an Application stuck with a ComparisonError is forced (finalizer cleared, `FORCED:` note), a healthy one never, `forceDeleteStuckApps=false` and a failed patch are reported | jq |
| `shared-lib/` | The shared library block in `workflows/scripts/common.sh`: identical to the copy in tpg-aks-infra, retries, pod watch (including `--started-ok` for Vault) | jq |
| `sync-engine/` | The Argo CD sync engine (`app_sync_wait` in `workflows/scripts/lib.sh`) against a scripted Argo CD API, including a sync off the fleet branch (`--off-branch`) and one source of a multi-source Application (`--revisions`) | jq |
| `rollout/` | `rolloutMode` of tpg-day0, tpg-upgrade, tpg-patch and tpg-scale-instance (`workflows/scripts/plan-batches.sh`) | jq |
| `params/` | Input types: `workflows/params/types.yaml`, the generated policy, the WorkflowTemplates, the clusterMap key registry and the Type columns of `docs/workflow-commands.md` agree; the clusterMap JSON and YAML schemas and examples per workflow (`workflows/params/schemas/`, Round 15, D88) are current and agree with `clustermap.py` | python3 (PyYAML, jsonschema) |
| `cluster-map/` | clusterMap validation (`clustermap.py`, `validate-params.sh` per workflow), the `lib.sh` accessors, the tpg-day0 version rule (FLEET_OVERRIDDEN, UPGRADE_REQUIRED, DOWNGRADE_NOT_ALLOWED, VERSION_UNKNOWN), the input combination rules (`highAvailability=true` with `readReplicas=0`, `readReplicas` above 0 with `highAvailability=false` where both are set, an input `readReplicas` not applied to an entry with `highAvailability: false`, `ferretReadOnlyReplicas` without HA), the `fleet-day0.sh` backstop for the same pairs, the tpg-scale-instance validate check (`replicas` above 0 with `enableHAIfNeeded=false` on an instance declared a single node), the `cron` and `k8sName` types, what `fleet-day0.sh` writes for `backupSchedule=operator` and the `ferret*` inputs, the tpg-scale-instance `maxReadReplicas`, `rolloutMode` and `maxParallel` inputs (`MAX_BELOW_CURRENT` at validation), the patch files of tpg-patch and tpg-create-instance: contents in `patchFiles`, a list of postgres patch files, absolute, `~/`, relative and `repo:` paths, a file of the wrong kind, unknown values and Postgres fields, operator keys outside the allow-list, unnamed contents, `patchMode=clear`, `clearKinds`, the renamed keys (`postgresValuesPatchFilePath`, `backupEnableSSL`); the backup CA sources (`caBundleFile`, `backupCaBundleVaultSecret`); `backupFullRetention` and `backupFullRetentionType` (Round 15) | python3, jq, yq (mikefarah) |
| `scale/` | `scale-instance.sh plan`: `maxReadReplicas` alone or with a scale in one commit, the new cap bounding `replicas`, a cap kept when a scale does not happen (`MAX_BELOW_CURRENT`), the pre-check records that drive the rollout, and `plan-batches.sh` with the template's `batch-items` step | python3, jq, yq (mikefarah) |
| `patch/` | tpg-patch: `patch-plan.sh` (stored names, current and previous with its commit, refused fields, the operator image tag and Secrets, the dry run, the diff with tracking annotations, `NO_CHANGE`, `patchMode=clear`, the postgresVersion guard, a Round 11 list; Round 15: one multi-document postgres file per instance, carry-over of kinds not named, `clearKinds`, `repo:` files, `PATCH_OVERRIDES_VALUE`, `PATCH_TARGET_NOT_RENDERED`, the backup CA bundle from a file or from Vault; documents carried over from creation, sizes and the storage class compared on the rendered instance) and `patch-cluster.sh` (the direct commit, the pull request synced before the merge, the merge without a second sync, the revert of a closed or timed-out pull request and of a failed sync, the operator's effective values file, `MERGED_CONTENT_DIFFERS`) | git, helm (skipped without it), python3, jq, yq |
| `chart/` | `charts/tpg-instance`: Service exposure and its Azure annotations, `instance.serviceType` refused, `caBundle` only with `enableSSL: true` (and required then), the network policy objects, no empty NetworkPolicy peer list, the `highAvailability` block (only for enabled with read replicas), zero defaults left out, PostgresBackupSchedule and PostgresFerretDocumentDB, the patch map shapes, a multi-document postgres file (one document per kind, an unknown kind refused), `backup.fullRetentionType`, and kubeconform against the CRD schemas | helm (skipped without it), python3 (PyYAML), yq |
| `day0-plan/` | tpg-day0 and tpg-create-instance: the plan (`fleet-day0.sh`, the CA bundle placeholder), ownership from the Argo CD Application's resource list (`day0-precheck.sh`), `ORPHAN_CRD`, `OPERATOR_NOT_INSTALLED`, `HA_NODES_EXCEED_ZONES`, `AZURE_BACKUP_UNSUPPORTED`, the creation rules, `ALREADY_EXISTS`, `INSTANCE_EXISTS`, `fleet-commit.sh` (passed clusters only, `FLEET_CHANGED_DURING_RUN`), `blocked-gate.sh`, the upgrade guard for absent instances, the patch files of tpg-day0 and tpg-create-instance (combined per instance as `<instance>-postgres-<hash>.yaml`, committed by `fleet-commit.sh`, written by `discover.sh`, kept for a repeated run), the CA bundle from a file or from Vault, and `FLEET_ENTRY_INVALID` for a fleet entry written before Round 15 | helm (skipped without it), python3, jq, yq |
| `network-policy/` | tpg-network-policy planning (`network-policy.sh plan`): `apply`, `update`, `remove`, clusterMap rules over the inputs, the postgresVersion guard, `CILIUM_NOT_AVAILABLE`, `DRY_RUN_REJECTED`, `ACNS_NOT_ENABLED`, `INSTANCE_NOT_FOUND`, invalid CIDRs, dry run | helm (skipped without it), python3, jq, yq |
| `submit/` | `scripts/submit/tpg-*.sh` through the numbered menus with stub `argo` and `kubectl`: type checks, optional inputs, map inputs, a pasted clusterMap, the kubectl fallback, Cancel, the tpg-scale-instance run kinds (scale, cap only), the patch files read and sent as `patchFiles`, the scripts run from any directory, through a link or with `TPG_FLEET_DIR` (Round 15, 1f), and `pack-patch-files.sh -o` reading the parameter file itself (2ii) | python3, jq, yq |
| `rotate/` | `workflows/scripts/rotate-write.sh`, the write step of tpg-rotate-credential, with stub `kubectl` and `curl` (the Vault API): a wrapped value checked and written without `_secretName`, and in no file, log line or record of the step; a value wrapped for another `secretName`; a used token (`WRAPPING_TOKEN_INVALID`); an unwrap that breaks off (curl's error, never the response); password length; a CA bundle from `caBundleFile` and an expired one; an unexpected exit still recorded | jq, python3, openssl |
| `pgdata/` | `tools/pgdata/pgdata.py` against a throwaway local PostgreSQL (initdb on a free port): every command and format, and the refused input (types, identifiers, `--where`, writes through `--sql`) | PostgreSQL server binaries and psycopg 3 (skipped without them) |
| `crd-reference/` | `charts/crd-reference` and `tools/crd-defaults/generate.py`: the generated files are current, the zero-default registry, `tpg.prune` per kind, the examples against the JSON schemas, and parity of the objects written inline by `backup-instance.sh`, `postgres-upgrade.sh` and `restore.sh` with the reference templates | helm (skipped without it), python3 (PyYAML), yq, kubeconform (skipped without it) |
| `admission/` | The three ValidatingAdmissionPolicies on a real kube-apiserver: the Workflow parameter types, the input combination rules, the Application sync policy, and `tpg-credential-writer` (Round 15, D87, with the ways around it the review found); every template of the repository passes them | envtest binaries (skipped without them), openssl |
| `monitoring/` | `monitoring/grafana/generate.py --check` (alert rules, API payloads, PrometheusRule, dashboards and the reference section of `docs/monitoring.md`), the check mode on a copy, every alert, rule and dashboard named in `docs/monitoring.md`, and `promtool check rules` | python3 (PyYAML), promtool (skipped without it) |
| `unused-keys/` | `tools/unused-keys/audit.py` (Round 15, D89): no chart value, `fleet.example.yaml` key, template input, `P_*` variable, Terraform variable or inventory key that nothing evaluates, except the entries of `allow-list.yaml`; a planted key fails the lint | python3 (PyYAML), helm (skipped without it) |

`ssa/` (operator manifest patches and server-side apply field ownership) was
removed in Round 14 with the operator manifest patches.

`tpg-aks-infra/tests/verify/run.sh` covers `scripts/steps/60-verify.sh` and its
summary, and uses the stubs in `helm4/bin`, so both repositories test against
the same fakes. `tpg-aks-infra/tests/argocd-rbac/run.sh` checks the Argo CD
RBAC block with the real `argocd` CLI (skipped without it).
`tpg-aks-infra/tests/preflight/run.sh` runs the storage check of
`scripts/targets/precreated/preflight.sh` against a stubbed `az` (secure transfer
read as reported, I22). `tpg-aks-infra/tests/vault-secret/run.sh` runs
`scripts/vault-secret.sh` against a fake `vault` CLI (over `kubectl exec`) and an
HTTPS mock of the Vault API (`--vault-addr`). `tpg-aks-infra/tests/jumpbox/run.sh`
checks `scripts/jumpbox/setup-jumpbox.sh` (shellcheck, `--dry-run` per OS) and the
jumpbox Terraform (fmt, validate, `tofu test` with mocked providers). `run-all.sh`
runs these five when tpg-aks-infra is a sibling. `tpg-aks-infra/tests/shared-lib/run.sh`
is the same file as `shared-lib/run.sh` here.

The envtest binaries (etcd, kube-apiserver, kubectl) come from
`setup-envtest use 1.34.1` (controller-runtime); set `KUBEBUILDER_ASSETS` to
their folder.

## cli-flags

A removed CLI flag is invisible to yamllint, shellcheck and kubeconform. It
fails at run time, inside a workflow step, halfway through a deployment. That is
how `helm list -a` reached the fleet: the workflow tools image moved to
`alpine/k8s:1.35.8`, which ships Helm 4, and Helm 4 removed `-a`.

`check_cli_flags.py` reads the commands out of the repository and applies
`rules.yaml`, which lists per tool and subcommand the flags that are gone or
renamed, why, and what to write instead. Add a rule whenever a pinned image
moves to a new major CLI version, and add a line to
`fixtures/violations.sh` for it: `run.sh` asserts that every rule fires exactly
once there and that nothing fires in `fixtures/clean.md`, so a rule that stops
matching, or one that matches too much, fails the suite.

`--against-cli` goes further and asks every installed binary for its own flags
(`<tool> <subcommand> --help`), then reports each flag the repository uses that
the binary does not know. It catches changes nobody has written a rule for yet.
Tools that are not installed are skipped, so it is safe to run anywhere.

`check_zero_defaults.py` fails on a jq or yq alternative whose fallback is
`true` or a non-zero number, such as `.enableHttpsTrafficOnly` with a `true`
fallback. `//` takes the
right side when the left side is `null` or `false`, so such a line turns an
explicit `false` into `true`: that is how the pre-created preflight read an
account with secure transfer turned off as HTTPS only (Round 12 finding F3,
design decision I22). Write the null test out instead
(`if .x == null then true else .x end`). A fallback of `false`, `0`, `""` or `[]`
is safe. It scans the same folders as the flag rules in both repositories, and
`fixtures/zero-defaults.sh` must give exactly its two planted findings.

## helm4

`bin/helm` and `bin/kubectl` are stubs. The helm stub parses flags the way Helm
4 does: `helm list -a` exits 1 with `unknown shorthand flag: 'a'`, exactly as
the real binary does in the tools image, and `helm registry login` rejects a
host with a path. Cluster and release state come from JSON files, so the add-on
pre-check can be driven through all of its outcomes: `DRY_RUN`, `UP_TO_DATE`,
`SKIPPED_EXISTS`, `SKIPPED_NEWER`, `REUSED_EXISTING` and `BLOCKED`.

The last case in the suite runs `helm list -a` against the stub and fails if it
is accepted, so a green suite cannot mean "the stub accepts anything".

## shared-lib

`workflows/scripts/common.sh` (tpg-fleet) and `scripts/lib/common.sh`
(tpg-aks-infra) carry the same block, between `# >>> tpg-shared >>>` and
`# <<< tpg-shared <<<`: the retrying `kubectl`, `helm`, `az` and `argocd`
wrappers (`tpg_retry`), `pods_watch`, the Helm release pre-check and install
(`hr_*`) and `monitoring_flowing`. The suite

1. fails when the two copies differ (edit one, then run `tests/shared-lib/sync.sh`
   in that repository to copy the block to the other);
2. drives `tpg_retry` with stub commands: a transient API error is retried and
   the output appears once; a NotFound or a `helm --wait` timeout is not
   retried; `-f -` input is given to every attempt, while a command that does
   not read standard input leaves the caller's loop input alone; a `create` that
   reached the server before the connection dropped counts as created;
   `kubectl exec` is never retried; the retry log does not print arguments;
3. drives `pods_watch` with pod lists: ready pods pass,
   `CreateContainerConfigError` fails at once, `CrashLoopBackOff` is tolerated
   for `POD_WATCH_PERSIST_SECONDS` (60) and then fails, an unschedulable pod fails
   after `POD_WATCH_PENDING_SECONDS` (300) with the scheduler's message, an init
   container failure is named, and the failure prints the pod's events and logs
   (with `--previous` for a restarted container).

## sync-engine

The workflows sync Applications through `app_sync_wait`. The suite scripts the
Argo CD API responses and proves that the previous operation's `Succeeded` is
not taken as the answer, that an admission webhook denial fails at once with
`SYNC_REJECTED` after one request (the upgrade used to record `SUCCEEDED`
there), that a transient error is synced again, that an Application that stays
OutOfSync fails with `SYNC_DRIFT`, and that a stuck operation ends with
`SYNC_TIMEOUT`. Round 14: with `--off-branch` (tpg-patch syncing a pull request
branch) the end check is that the operation synced that commit, not Synced, and
an operation at another commit fails; `--revisions 2 SHA` sends `revisions` and
`sourcePositions` for the fleet source of the operator Application.

## rollout

`plan-batches.sh` with a stub `lib.sh`: `canary` (the wave-0 cluster alone,
then batches of `maxParallel` per wave), `batches` (no canary) and `all` (one
batch), and an unknown mode fails.

The sync-engine suite also covers `MANUAL_SYNC_DETECTED`: an Application whose
last operation was started by someone other than `workflow-bot` is reported as
a warning and the sync goes ahead.

## params

Argo Workflows parameters have no type, so `workflows/params/types.yaml`
declares one per input and `workflows/params/generate.py` turns it into the
ValidatingAdmissionPolicy `workflows/admission/workflow-parameters.yaml`. The
suite fails when:

- the generated file is out of date (`generate.py --check`);
- a WorkflowTemplate input has no type, or a type names an input the template
  does not have;
- a template default does not match its own type, or an enum differs from the
  template's `enum`;
- `workflows/params/cluster-map-keys.yaml` names a workflow without a
  `clusterMap` input, a key has an unknown type, or its default input ("flag")
  is not an input of that workflow;
- a row of an input table in `docs/workflow-commands.md` shows a Type other than
  the `display` of its type, or an input has no row;
- the clusterMap schemas (Round 15, D88) are out of date
  (`workflows/params/clustermap_schema.py --check`: the JSON and YAML schema and
  the example per workflow in `workflows/params/schemas/`, and the generated key
  tables in section 3 of `docs/workflow-commands.md`), an example fails
  `clustermap.py validate` or its schema, or a map that `clustermap.py` refuses for
  its shape passes the schema (checked with jsonschema when installed).

## cluster-map

`clustermap.py` and `validate-params.sh` for every workflow that takes
`clusterMap`: unknown keys with a suggestion, wrong types, keys a workflow does
not accept, missing required values (map key or input), a cluster without
instances, `clusterMap` together with `clusters` or `instances`, `confirm` of
the delete workflows (in any order), a `mode=backup` restore without an in-place target, YAML and JSON input, and a Postgres version written as a
number (`16.10`). It also runs `fleet-day0.sh` with stub clusters to prove the
version rule of tpg-day0: an input that nothing runs yet replaces the value in
`fleet.yaml`, and a running operator or instance of another version blocks the
cluster.

## scale

Runs `scale-instance.sh plan` with the real `lib.sh` and `clustermap.py`, and
stubs for Git, the run ConfigMap and the target cluster: `maxReadReplicas` for
every selected cluster with no instance synced, an unchanged cap
(`ALREADY_AT_TARGET`, nothing pushed), a cap and a scale in one commit (the new
cap bounds `replicas`; without it the default 3 does), a cap that would leave an
instance above it when that instance's scale does not happen (`MAX_BELOW_CURRENT`,
the cap stays), a cap-only cluster next to a scaled one in `clusterMap`, and the
rollout: `precheck.<cluster>` PASSED only for clusters with an instance to sync,
`plan-batches.sh` for `all`, `canary` and `batches`, and the `batch-items` step of
the template. Case 7 runs `scale-instance.sh restore` (the exit handler of a run
that did not succeed): a target the rollout did not reach gets its previous
`highAvailability` back in one commit and is `NOT_RUN`, a target that ran keeps
its count, and a second restore finds nothing to do.

## patch

Runs `patch-plan.sh` and `patch-cluster.sh` with the real `lib.sh`,
`patch-lib.sh` and chart, a fleet repository that is a git repository with a bare
local origin (pushes, fetches and reverts are real), and stubs
for Git hosting (pull request, merge), the run ConfigMap, the Argo
CD API and the target cluster (server-side dry run and `kubectl diff`). The plan:
each received file gets `<name>-<uid>.yaml`, the dry run carries the new current
files, the diff is printed and its objects carry the Argo CD tracking annotation,
nothing is committed; no difference is `NO_CHANGE`; the diff gives the fields the
`tpg-instances` ApplicationSet ignores their live values (and the ignored paths
equal the ApplicationSet's); a values patch that only changes `backup.scheduled`,
which the chart does not render, is planned to commit, and committed without a
sync; fields other workflows own,
a smaller volume, ignored backup fields, missing contents, another operator
version in `operatorImage` and a pull Secret that does not exist are refused;
`patchMode=clear` must name the current file; the postgresVersion guard; a
Round 11 list of several files is refused. Round 15 (cases 12 and 13, design
decisions D81 to D83 and D86): several postgres patch files of different kinds
become one multi-document stored file per instance, kinds not named are carried
over from the current file, a kind named twice is refused, `clearKinds` removes
kinds (and the whole file when every document is cleared), `repo:` files are read
from the fleet repository, absolute, `~/` and relative paths are accepted, a patch
field over a chart value warns `PATCH_OVERRIDES_VALUE`, a document for an object
the chart does not render warns `PATCH_TARGET_NOT_RENDERED`; the backup CA bundle
from `caBundleFile` or from a Vault secret, their precedence, and a CA on an
instance without SSL. Case 14 (the review): documents carried over from creation
(a `storageClassName`, `forcePathStyle`) do not block a later run, a
`storageClassName` equal to the current one is no change and another one is refused,
a volume is compared on the rendered instance before and after (a smaller size, or a
Postgres document that drops the size of the current one), and the same resources in
another key order are no override. The cluster step: with
`pushMode=direct` one commit with the stored file (`current`, and `previous` with
the commit that added the old file) and a sync at it, or a revert commit when the
sync fails; with `pushMode=pr` a branch and pull request per cluster, the sync at
the branch commit (`--off-branch`) before the merge, then the merge and Synced
without a second sync; a closed or timed-out pull request and a failed sync sync
the cluster back (at the commit it ran, or at the fleet branch head when the
Application was Synced), close the pull request and delete the branch; a pull
request merged before the failure is closed first, then its merge is reverted on
the fleet branch and synced; a direct revert keeps a stored file another
cluster's commit still names; a merge that leaves the Application OutOfSync is `MERGED_CONTENT_DIFFERS`;
the operator's effective values file is committed and its Application synced
with source position 2; no difference on the fleet branch head commits nothing.
The operator chart render is stubbed (it comes from the Broadcom registry). It
is skipped when `helm` is not installed. `scripts/validate.sh` also renders the
chart with the example patch files of `clusters/fleet.example.yaml`.

## chart

Renders `charts/tpg-instance` with `helm template` for each case and checks the
objects with PyYAML: the three exposures and their annotations, the refusal of
`instance.serviceType` and of an unknown exposure, `caBundle` with and without
`enableSSL`, the network policy objects with and without ACNS, and that every
NetworkPolicy ingress rule has a non-empty peer list and that no peer is made of
empty selectors only (an empty peer list, an empty peer or `namespaceSelector: {}`
alone allows every source; `podSelector: {}` alone, the instance namespace, is
the one exception).

Round 13 (design decisions D69 to D71) adds: no `highAvailability` block for a
single-node instance (`enabled: false`, `readReplicas: 0`), the render refused for
`enabled: true` with `readReplicas: 0` and for read replicas without `enabled`;
fields at their zero default left out of Postgres and PostgresBackupLocation,
patch file content included; the PostgresBackupSchedule objects of
`backup.operatorSchedules` (refused while `backup.scheduled` is true, without
`full` or with a malformed cron); the PostgresFerretDocumentDB (refused below
Postgres 17.5 and for read-only proxies without HA; Services published like the
instance; port 27017 in the network policy). Every rendered object is checked
with `kubeconform -strict` against the schemas in `charts/crd-reference/schemas`,
and `valuesOverride` (written by tpg-restore) wins over a values patch that turns
FerretDB on.

Round 14 (D78) adds the current patch file: only `current` is applied (`previous`
is a record), a Round 11 list of one file counts as current and a longer list
fails the render, `clusters/fleet.yaml` given as a value file decides over the
patches of the inline values (what a sync at a pull request commit relies on), an
entry without patches there renders none, and a cleared patch renders the chart
values.

Round 15 (D81, D84) adds the map shape of `patches.postgres` and
`patches.postgresValues` (a fleet entry of the older shape fails the render with
"start a new one"), one multi-document postgres file whose documents are merged
into their objects (Postgres, PostgresBackupLocation, PostgresBackupSchedule,
PostgresFerretDocumentDB; an unknown kind fails the render), and
`backup.fullRetentionType`.

## crd-reference

`charts/crd-reference` holds the 9 Tanzu for Postgres CRDs (`source-crds/`), one
reference template per kind and the registry of fields that hold a zero default
(`files/zero-defaults.yaml`, also in `charts/tpg-instance/files/`), all generated
by `tools/crd-defaults/generate.py` (design decisions D69 and D73). The suite:

1. runs the generator with `--check`: a CRD or `defaults-overlay.yaml` changed
   without regenerating fails;
2. checks the registry: the overlay entries, required fields never listed,
   non-zero defaults never listed;
3. renders each kind with every registry field at its zero default and checks
   that `tpg.prune` left them out, and that a required parent stays;
4. renders every `examples/<kind>.yaml` and validates it with
   `kubeconform -strict`, and checks that the schemas are closed (an unknown
   field fails);
5. runs the inline objects of `backup-instance.sh` (PostgresBackup),
   `postgres-upgrade.sh` (PostgresVersionUpgrade) and `restore.sh` (the source
   PostgresBackupLocation copy and the PostgresRestore, in five modes) and
   compares each with the reference template rendered from the same spec: a
   zero default written by a script fails the suite.

## day0-plan

Runs `fleet-day0.sh`, `day0-precheck.sh`, `fleet-commit.sh`, `blocked-gate.sh`,
`operator-upgrade.sh` and `discover.sh` with the real `lib.sh`, `clustermap.py` and chart, and
a stub target selected per case by scenario variables (`S_OPERATOR`,
`S_TRACKED`, `S_CRD_TRACKED`, `S_APPRES`, `S_RUNNING`, `S_ZONES`, `S_AZURE`,
`S_CRDS`, `S_CA`, `S_ACNS`, `S_API_ERR`, `S_FERRET_CRD`, described at the top of
the file). The
case that started Round 12 is case 1: a tpg-day0 re-run adding an instance to a
cluster whose Postgres CRDs carry no tracking annotation but are listed by the
operator Application (the operator Deployment itself must carry the annotation).
Case 7 checks that the plan carries the CA bundle as a placeholder (21 instances
stay under 16 KiB) and that the commit writes the PEM; case 11 runs `discover.sh`
after a plan that blocked an instance; case 10b checks that `operator-upgrade.sh`
stores the operator values file with the new `operatorImage` tag under a new UID
name as current (the old file unchanged, as previous) and stops on a Round 11
list of several operator files (`OPERATOR_PATCH_LIST`); case 12 covers Round 13:
`backupSchedule=operator`, the `ferret` inputs (true, false, empty keeps),
`FERRET_VERSION_UNSUPPORTED`, `FERRET_CRD_MISSING`, the
`FERRET_EXTENSION_REQUIRED` warning, and the HA combination refusals. Case 1
also checks that the commit writes `clusters/fleet.yaml` in block YAML (no flow
maps, no JSON quotes) and that `fleet_yaml_style` keeps comments, the literal
`caBundle` and quoted strings. Round 15: case 7 carries every distinct CA bundle
once as `@ca:<sha12>@` (a trailing newline does not make a second one) and checks
the bundles (`ca_check`); the bundle comes from `caBundleFile`, from a Vault
secret or from `tpg-settings`; case 9 combines the patch files of an instance into
`<instance>-postgres-<hash>.yaml`, renders both kinds and records them in
`patch.files`; case 10b stops on a fleet entry of the older patch shape
(`FLEET_ENTRY_INVALID`); case 12 uses `postgresValues`.

## network-policy

Runs `network-policy.sh plan` with the real chart; the rendered policies are
sent to a stub `kubectl apply --dry-run=server` that can refuse them
(`S_REJECT`). Checks the `network` entry written for each mode, the records
(`precheck`, `plan`, `result`) and that a blocked cluster is not written.
The apply phase (`network-policy.sh apply`: the sync, `archive_check`, the probe
pods) needs a cluster with Cilium and is covered by the lab checks V48 to V50
of the tpg-fleet README, not by this suite.

## submit

Runs the submit scripts with stdin from a here-document, so they use the
numbered menus, in a `PATH` that holds only the tools they need, a stub
`kubectl` (registered clusters, `create -f`) and, where the case wants it, a stub
`argo` that records its arguments. Round 15: the 12 scripts (tpg-backup-retention
is gone); a script run through a link or from another directory finds its clone,
a copy outside a clone stops with the `TPG_FLEET_DIR` hint and works with it
(1f); `pack-patch-files.sh -o` reads the paths from a parameter file (relative to
that file, `~/`, `..`, `repo:` left to the workflow, a CA file) and writes
`patchFiles` into it (2ii).

## rotate

Runs `rotate-write.sh` with the library of this repository, a stub `kubectl` that
serves the Workflow object (`wrappingToken`, `patchFiles`), `tpg-settings` and the Vault
CA, and a stub `curl` for the Vault API (unwrap once, then the token is void; the KV v2
write is recorded). The Kubernetes auth login is replaced, because it reads the pod's
ServiceAccount token. Besides the results, the suite checks that the unwrapped value is
in no file of the step's work directory, in no log line and in no record, that a
partial response never reaches an error message, and that an unexpected exit (a write
answered with something that is not JSON) is still recorded by `result_guard`.

## pgdata

Starts a PostgreSQL server with `initdb` and `pg_ctl` in a temporary directory
(as `nobody` when the suite runs as root), on a free port, UTF8, and runs every
`pgdata.py` command against it. Skipped without the server binaries or psycopg.

## admission

The suite starts etcd and kube-apiserver from the envtest binaries
(`tests/envtest/apiserver.sh`) with the Argo CD v3.5.3 Application CRD and the
Argo Workflows v4.1.3 Workflow CRD.

`admission` applies the two policies and submits Workflows and Application
updates as different users: a Workflow with every default passes for each
template; a wrong type, an unknown input, an old input name and a malformed
`clusterMap` are rejected with the input and its type, and `clusters=all` is
refused where a list of names is expected; the combination rules of
`workflows/params/types.yaml` refuse `highAvailability=true` with
`readReplicas=0`, `readReplicas` above 0 with `highAvailability=false` and
`ferretReadOnlyReplicas` above 0 with `highAvailability=false`; Workflows of other templates are not
affected. A new operation on a target Application is accepted only from
argocd-server on behalf of `workflow-bot` (or `workflow-bot:apiKey`); switching
on automated sync is refused; the controller clearing the operation, status and
annotation updates, and hub Applications are not affected.

Round 15 adds the WorkflowTemplate and CronWorkflow CRDs of Argo Workflows
v4.1.3 and the policy `tpg-credential-writer` (D87): a Workflow, CronWorkflow or
other WorkflowTemplate that names the ServiceAccount `tpg-credential-writer` in
`spec`, a template, `templateDefaults`, an executor or a `podSpecPatch` is
refused; a Workflow submitted from `tpg-rotate-credential` and Workflows of other
ServiceAccounts are accepted; `tpg-rotate-credential` itself may be written only
by an `argocd` ServiceAccount. The ways around that check, found by the independent
review of Round 15, are refused as well: a step, a DAG task or a lifecycle hook with a
`templateRef` to `tpg-rotate-credential`, another WorkflowTemplate that references it,
a run of it with a `podSpecPatch`, `templateDefaults`, `volumes` or its own
`entrypoint` (also as a CronWorkflow), a `podSpecPatch` that spells the name with a
JSON escape or sets any ServiceAccount in another letter case, an inline template that
runs as the writer or nests steps, and a ClusterWorkflowTemplate that names it (a
ClusterWorkflowTemplate CRD is applied for that). An ordinary `podSpecPatch` and a run
that `argo stop` marks stay accepted, and every WorkflowTemplate and CronWorkflow of
the repository passes the three policies as Argo CD writes them. With the Role of
`workflows/rbac.yaml` applied, the workflow ServiceAccounts may create and update
`tpg-run-*` ConfigMaps and change pod metadata, and are refused a change of
`tpg-scripts` or `tpg-settings`, another ConfigMap and a pod's image; an
administrator is not affected. The input cases add
the renamed keys, a Workflow of the removed `tpg-backup-retention`, `clearKinds`,
`wrappingToken` and the CA inputs.

## monitoring

`monitoring/grafana/generate.py --check` must find the Grafana alert rules, the
API payloads, the PrometheusRule, the dashboards and the generated reference
section of `docs/monitoring.md` current. On a copy, the check mode fails on a hand
edit of the reference, on missing markers and on a JSON file that nothing
generates, and writes nothing. Every PrometheusRule alert, Grafana rule uid and
dashboard uid must be named in `docs/monitoring.md`, and every metric there must
have a source. `promtool check rules` runs on the PrometheusRule's groups when
promtool is installed.

## unused-keys

`tools/unused-keys/audit.py` (Round 15, 1g, D89) looks for keys that nothing
evaluates: a chart value whose change changes no rendered object (over three
value profiles), a key of `clusters/fleet.example.yaml` that no chart value,
template or script reads, a WorkflowTemplate input that no step uses, a `P_*`
variable that its script never reads, and, with the sibling tpg-aks-infra clone
(`INFRA_DIR`), a Terraform variable or inventory key nothing reads. Findings that
are intended (a key read by the hub rather than the chart, for example) are
listed with a reason in `tools/unused-keys/allow-list.yaml`; an allow-list entry
that is no longer a finding fails too. The suite runs the audit and then plants a
chart value, a template input and a stale allow-list entry in a copy of the
repository and expects each to fail. `scripts/validate.sh` runs the audit as well.

