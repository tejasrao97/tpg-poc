# Workflow command reference

Every tpg operation is an Argo Workflows `WorkflowTemplate` in the `argo` namespace on the hub. You start a run with the **argo CLI** (`argo submit --from workflowtemplate/<name>`). Argo CD does not start workflows: the workflows call the Argo CD API to refresh and sync Applications. The **argocd CLI** commands at the end of this page inspect what the workflows did; people cannot sync the tpg target Applications themselves (section 21).

Every input has a type (section 2). A Workflow whose inputs do not match their types is rejected when it is submitted, and no Workflow is created. Mandatory inputs have no default: a run without them fails in its first step (`validate`), which lists every missing or invalid input, including the registered cluster names.

Every workflow can also be started with an interactive script, `scripts/submit/tpg-<workflow>.sh`, that asks for the mandatory inputs first and then offers the optional ones in a menu (section 18).

Round 23 added a parameter-file schema and two worked examples to every workflow section: the generated block after the input table (`workflows/params/schemas/params-<workflow>.schema.json`, `check-jsonschema`, the example file) and the examples that follow, each with its `argo submit` command (section 2, Parameter files). The restore is rebuilt around a list of source and target pairs (section 16), `tpg-backup-expire` is new (section 14), and an instance may have a namespace of its own (`namespace`, section 3).

## Contents

1. [Set up the CLIs](#1-set-up-the-clis)
2. [Input types and conventions](#2-input-types-and-conventions)
3. [clusterMap](#3-clustermap)
4. [tpg-day0](#4-tpg-day0)
5. [tpg-create-instance](#5-tpg-create-instance)
6. [tpg-upgrade](#6-tpg-upgrade)
7. [tpg-patch](#7-tpg-patch)
8. [tpg-scale-instance](#8-tpg-scale-instance)
9. [tpg-network-policy](#9-tpg-network-policy)
10. [tpg-delete-apps](#10-tpg-delete-apps)
11. [tpg-delete-instance](#11-tpg-delete-instance)
12. [tpg-helm-addons](#12-tpg-helm-addons)
13. [tpg-backup](#13-tpg-backup)
14. [tpg-backup-expire](#14-tpg-backup-expire)
15. [CA bundles and new credential values in Vault](#15-ca-bundles-and-new-credential-values-in-vault)
16. [tpg-restore](#16-tpg-restore)
17. [tpg-rotate-credential](#17-tpg-rotate-credential)
18. [Interactive submit scripts](#18-interactive-submit-scripts)
19. [Test data: pgdata](#19-test-data-pgdata)
20. [Follow, approve, stop and clean up runs](#20-follow-approve-stop-and-clean-up-runs)
21. [argocd CLI: inspect the sync steps behind the workflows](#21-argocd-cli-inspect-the-sync-steps-behind-the-workflows)

---

## 1. Set up the CLIs

```bash
# Kubeconfig written by tpg-aks-infra/scripts/run.sh (context aks-tpg-hub)
export KUBECONFIG=~/src/tpg-aks-infra/.work/kubeconfig
# On the jumpbox, where Terraform copied the scripts to ~/scripts (run_fleet_setup), or
# after tpg-aks-infra deploy-scripts/deploy.sh copy (the fleet repository in ~/tpg-fleet,
# the submit scripts in ~/tpg-fleet/scripts/submit):
# export KUBECONFIG=~/.work/kubeconfig
export ARGO_NAMESPACE=argo            # every command below then works without -n argo

argo version
argo template list
```

To use the Argo Workflows server instead of the Kubernetes API (for example from a laptop without cluster access), see `tpg-aks-infra/docs/README-argo-on-aks.md` and set `ARGO_SERVER`, `ARGO_HTTP1=true`, `ARGO_SECURE=true` and `ARGO_TOKEN`.

```bash
# argocd CLI against the hub (port-forward works without a public UI)
kubectl --context aks-tpg-hub -n argocd port-forward svc/argocd-server 18080:443 >/dev/null 2>&1 &
argocd login localhost:18080 --username admin --insecure --grpc-web \
  --password "$(kubectl --context aks-tpg-hub -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
```

## 2. Input types and conventions

Argo Workflows passes every input as a string. The types below are declared once in `workflows/params/types.yaml` and enforced by the hub's Kubernetes API server (ValidatingAdmissionPolicy `tpg-workflow-parameters`, generated from that file). The check applies to `argo submit`, the Argo UI, the API and CronWorkflows alike. A rejected submission names every wrong input and its type, for example:

```text
tpg-day0: maxParallel="abc" must be an Integer (1 or more); dryRun="yes" must be a Boolean (true or false). See docs/workflow-commands.md
tpg-scale-instance: cluster is not an input of tpg-scale-instance. See docs/workflow-commands.md
```

| Type | Accepted values | Example |
|---|---|---|
| `List` | A list in brackets of names (lowercase DNS labels), also with one value. Both YAML flow lists and JSON arrays are accepted: `[a, b]`, `["a","b"]`. A comma-separated string without brackets, an empty list `[]` and an empty element `[a, , b]` are refused, with the list syntax in the message. Where the table says so, the bare word `all` (never in brackets) selects every registered cluster or every declared instance. `components` takes the bare word `auto`, or a list of `cert-manager`, `vso` and `monitoring` | `[aks-tpg-poc-01]`, `[aks-tpg-poc-01, aks-tpg-poc-02]`, `all` |
| `List (one file path)` | A list that holds exactly one file: a path of the machine that submits the run (absolute, `~/` or relative, `..` allowed), whose contents go in `patchFiles`, or `repo:<path>` in the fleet repository (Round 15). A patch file is `.yaml` or `.yml`, a CA bundle `.pem`, `.crt` or `.cer`. `repo: <path>` with a space after the colon fails with `repo:<file path> "check for white spaces in between"` | `[./orders-backup.yaml]`, `[~/certs/azure.pem]`, `[repo:ca-bundles/azure.pem]` |
| `List (file paths)` | A list of `.yaml` or `.yml` files, each written as in `List (one file path)` | `[./orders.yaml, repo:helm_artifacts/instance/tpg-instance/patches/team.yaml]` |
| `List (kinds)` | A list of patch kinds, or `all` alone (bare): `Postgres`, `PostgresBackupLocation`, `PostgresBackupSchedule`, `PostgresFerretDocumentDB`, `postgresValues`, `operatorValues` | `[PostgresBackupSchedule, postgresValues]`, `all` |
| `String (Vault token)` | A Vault wrapping token, as `tpg-aks-infra/scripts/vault-secret.sh wrap` prints it | `hvs.CAESIJ...` |
| `List (CIDRs)` | A list of IPv4 or IPv6 networks with the host bits zero | `[10.20.0.0/16, 192.168.10.0/24]` |
| `List (host names)` | A list of DNS names; `*.` in front matches every subdomain | `[api.example.com, *.example.org]` |
| `List (pairs)` | tpg-restore `clusterMap` (section 16): a list of pairs, one restore each, `{sourceClusterConfig, targetClusterConfig}`, as a YAML block list or a JSON array. A map of clusters (the `clusterMap` of the other workflows) is refused | `- sourceClusterConfig: ...` |
| `String` | Any text | `alpine/k8s:1.35.8` |
| `String (name)` | One lowercase DNS label (a Kubernetes object name for `backupName`, `ferretSecretName` and `ferretReadOnlySecretName`) | `orders-db` |
| `String (cron)` | A cron schedule of 5 fields: minute, hour, day of month, month, day of week (UTC) | `0 0 * * 0` |
| `String (Azure name)` | An Azure resource name: letters, digits, `-`, `_` and `.`, at most 80 characters | `aks-apps_subnet` |
| `String (version)` | Operator: `v4.5.0` (`4.5.0` is accepted). Postgres: `postgres-17.6` (`17.6` is accepted; the version must exist in `kubectl get postgresversion`). In a parameter file a bare number is quoted (`"17.10"`, see Parameter files below) | `v4.5.1`, `postgres-16.10` |
| `String (quantity)` | A Kubernetes quantity. In a parameter file a decimal is quoted (`"0.5"`); a whole number is exact | `20Gi`, `500m`, `2` |
| `String (UTC time)` | `YYYY-MM-DDThh:mm:ssZ` | `2026-09-15T08:30:00Z` |
| `String (LSN)` | A log sequence number | `0/3000060` |
| `Boolean` | `true` or `false`; written `"true"` or `"false"` in a parameter file | `true` |
| `Integer` | Digits only. Counts can be 0; timeouts and `maxParallel` start at 1 | `3`, `1800` |
| `Enum` | One of the values in the Description column | `direct` |
| `Map` | YAML or JSON (section 3) | `{"aks-tpg-poc-01": {"instances": {"orders-db": {"replicas": 2}}}}` |
| `Map (JSON)` | A JSON object | `{"aks-tpg-poc-01": ["tpg-operator"]}` |

**List syntax** (Round 23; lists were comma-separated strings before). Every `List` input is written in brackets, also with one value: `[aks-tpg-poc-01]`, `[a, b]` (a YAML flow list) or `["a", "b"]` (a JSON array). Only two words stay bare: `all` where the table of the workflow says so, and `auto` for `components`. These are refused, with the list syntax and a corrected form (`Did you mean [a, b]?`) in the message: a comma-separated string without brackets (`a,b`), a bare name (`orders-db`), `[]`, an empty element (`[a, , b]`), a nested list and `all` inside brackets (`[a, all]`). The admission policy refuses them when the run is submitted, the `validate` step again for a run created another way, and one parser reads every list (`clustermap.py list`, `list_items` in the shell scripts): the inputs, the list values of `clusterMap` (YAML sequences, section 3) and the paths that `pack-patch-files.sh` packs. The submit scripts take plain names at their prompts and send the bracketed form. A single-file input (`List (one file path)`) is a list of exactly one path.

A file path has one more rule. YAML reads `repo: helm_artifacts/x.yaml` (a space after the colon) as a mapping and not as text, so `[repo: x.yaml]` is a list of one mapping, and a path with a space in it is no path. Both fail with `repo:<file path> "check for white spaces in between"`. That message is for whitespace and `repo: path` map entries only. Every other malformed path keeps the message that names the input and the fix: a file that is not `.yaml` or `.yml` (CA bundles: `.pem`, `.crt`, `.cer`), a `repo:` path with `..` or outside the folder the input accepts (for example `targetInstanceSpecFilePath` takes `repo:helm_artifacts/instance/tpg-instance/restore-specs/<file>` only), a per-cluster copy the workflows write themselves, a local file whose contents are not in `patchFiles`.

Inputs used by several workflows:

| Common input | Type | Values | Used by |
|---|---|---|---|
| `clusters` | `List` | Registered clusters, or `all` where accepted | every workflow except restore and backup-expire |
| `instances` | `List` | Declared instances, or `all` where accepted (new instances for create-instance) | day0, create-instance, upgrade, patch, scale, network-policy, backup, delete-instance |
| `clusterMap` | `Map` | Targets with per-cluster and per-instance values (section 3); replaces `clusters` and `instances`. tpg-restore takes a list of pairs instead (`List (pairs)`, section 16) | day0, create-instance, upgrade, patch, scale, network-policy, backup, delete-instance, delete-apps, backup-expire (the only target input), restore |
| `pushMode` | `Enum` | `direct`: push the `clusters/fleet.yaml` change to the fleet branch. `pr`: push a branch, open a GitHub pull request and continue once it is merged (`prTimeoutSeconds`, default 3600). tpg-patch syncs the pull request branch before the merge (section 7) | day0, create-instance, upgrade, patch, scale, network-policy, delete-apps, delete-instance, restore |
| `dryRun` | `Boolean` | `true`: validate and record the plan; change nothing (tpg-restore and tpg-backup-expire: `true` is the default) | day0, create-instance, upgrade, patch, scale, network-policy, delete-apps, helm-addons, backup-expire, restore |
| `rolloutMode` | `Enum` | `canary` (default): the wave-0 cluster alone, then the other waves in batches of `maxParallel`. `batches`: no canary, batches of `maxParallel` in wave order. `all`: every selected cluster in one batch. tpg-restore: the unit is a pair of `clusterMap` and the default is `all` (section 16) | day0, create-instance, upgrade, patch, network-policy, restore |

- Put values that contain brackets (every list: `-p 'clusters=[aks-tpg-poc-01]'`; the shell reads `[...]` as a file pattern), spaces or JSON in single quotes.
- `-p name=value` sets one input. `--parameter-file inputs.yaml` reads several from a file (Parameter files below; every workflow section has two worked examples). A `-p` adds an input the file does not set (for example `-p dryRun=true`); it does not override one the file sets (see Parameter files below). Files of your machine that the parameter file names are packed into it with `scripts/submit/pack-patch-files.sh -o <parameter file>` (section 7).
- `--watch` follows the run in the terminal. Without it, the command prints the workflow name.
- `--name` or `--generate-name` sets the workflow name, which is also the results ConfigMap `tpg-run-<name>`.
- Every run ends with a report (exit handler). `argo logs @latest -c main | sed -n '/tpg run report/,$p'` prints it again. Warnings (section 20) have their own part of the report.
- Instance lists are checked against `clusters/fleet.yaml` before anything changes: an instance that is not declared on a selected cluster fails the run with `UNKNOWN_INSTANCE` and the list of declared instances.
- While a step waits for pods (Helm releases, the operator, instances, upgrades, scale, patch, restore), it prints the pod table of the namespace every 5 seconds and stops as soon as a pod cannot start. The failure reason is `POD_<REASON>` (for example `POD_CRASHLOOPBACKOFF`, `POD_CREATECONTAINERCONFIGERROR`, `POD_UNSCHEDULABLE`), followed in the log by the pod's status, events and the logs of the failing container. `CreateContainerConfigError`, `CreateContainerError`, `InvalidImageName` and `RunContainerError` fail at once; `CrashLoopBackOff`, `ImagePullBackOff`/`ErrImagePull`, `Error` and `OOMKilled` after 60 seconds; an unschedulable or Pending pod after 5 minutes.
- Transient API errors (timeouts, connection resets, HTTP 429/502/503/504) of `kubectl`, `helm`, `az` and the Argo CD API are retried up to 5 times with 5, 10, 20 and 40 seconds between attempts (`TPG_RETRY_ATTEMPTS`, `TPG_RETRY_DELAY`); the log shows `<tool> <verb>: transient error (attempt n/5), retrying in Ns: <error>`.
- Argo CD syncs are made at the fleet commit the run pushed; a sync the API server rejects (admission webhook, invalid field) fails the step at once with Argo CD's message.
- `toolsImage` (`String`, default `alpine/k8s:1.35.8`) is the image every step runs in. It is an input of every workflow and is not listed in the tables below.
- Some combinations are refused as well, by the same admission policy (`rules` in `workflows/params/types.yaml`), by the submit scripts and by the `validate` step (which also checks the values `clusterMap` gives each instance): `highAvailability=true` with `readReplicas=0` (a single node is `highAvailability=false`), `readReplicas` above 0 with `highAvailability=false` (read replicas need high availability), and `ferretReadOnlyReplicas` above 0 with `highAvailability=false` (the read-only FerretDB proxies connect to the standby). `highAvailability` and `readReplicas` are checked where they are set: both as inputs, or both on one `clusterMap` entry (an entry's own keys, the inputs filling what it leaves out). An input `readReplicas` is a default for HA instances only: it does not apply to an entry that sets `highAvailability: false` itself. `fleet-day0.sh` refuses the same pairs again before it writes anything (it no longer turns a `readReplicas` above 0 into 0).
- `clusters/fleet.yaml` is written in block YAML. Every workflow that commits it (the tpg-day0 and tpg-create-instance commit step included, which copies each cluster from its JSON plan) turns every flow map and list in the file into block style first, so an entry written as JSON by an earlier version, or a hand-written `{a: b}`, becomes block YAML with the next commit. Quotes stay only where YAML needs them (`"true"`, `"0"`), a comment at the end of a flow line moves above its content, and `caBundle` stays a literal block.
- **Zero defaults are not written** (design decision D69). The tpg-instance chart leaves out of every object it renders the fields that hold their zero default (`false`, `0`, `[]`, `{}`): a single-node instance gets no `spec.highAvailability` block at all (the operator's defaults are `enabled: false` and `readReplicas: 0`). A field left out takes the same default, so declaring it gains nothing, and a declared field that a writer drops leaves the Application OutOfSync (the PostgresBackupLocation drift of Round 9, the single-node reports of Round 12). `clusters/fleet.yaml` keeps the explicit values (`enabled: false`, `readReplicas: 0`), since `clusters/_template/instance.yaml` defaults to `true` and `1`. The fields come from the registry `helm_artifacts/instance/tpg-instance/files/zero-defaults.yaml`, generated from the 9 live CRDs in `helm_artifacts/instance/crd-reference` (`helm_artifacts/instance/crd-reference/README.md`, section 3). A field whose default is not zero is always written: `enableSSL: false` stays, because its CRD default is `true`.
- **Namespace of an instance** (Round 23). An instance runs in the namespace `pg-<instance>` unless the `clusterMap` key `namespace` of tpg-day0 or tpg-create-instance names another one (section 3). The namespace is stored in `clusters/fleet.yaml` as `instance.namespace` and every other workflow reads it from there; the examples of this page write `pg-orders-db` where the namespace is the default.

**Parameter files** (Round 23). `argo submit --parameter-file <file>` reads a YAML mapping of input name to value. For each workflow, `workflows/params/schemas/` holds `params-<workflow>.schema.json` (also `.schema.yaml`; JSON Schema, draft 2020-12) and `params-<workflow>.example.yaml`, both generated by `python3 workflows/params/params_schema.py` from `workflows/params/types.yaml` and the WorkflowTemplates (`<workflow>` is the template name without `tpg-`: `params-day0`, `params-create-instance`, `params-backup-expire`, ...). The block after the input table of each workflow section (between `BEGIN GENERATED` and `END GENERATED`, written by the generator, never by hand) names the schema, the command that checks a file with it and the example, which is worked example 1 of the section. Check a file with `check-jsonschema`, or let an editor with the YAML language server do it when the file starts with `# yaml-language-server: $schema=<path to the schema>`:

```bash
check-jsonschema --schemafile workflows/params/schemas/params-day0.schema.json my-inputs.yaml
```

The schema checks the shape of the file: only the inputs of that workflow, their types and allowed values, and the inputs that are mandatory in every case. It does not check what depends on the cluster or on other inputs (the combinations above, an input that is mandatory only in some cases, registered clusters, the inside of `clusterMap`): the admission policy and the `validate` step of the run remain the authority. `tests/params` runs every example through the schema, the admission policy (a real API server) and the `validate` step.

How the values are written:

- **A list input**: a YAML sequence (preferred), `clusters: [aks-tpg-poc-01, aks-tpg-poc-02]`, or the quoted bracketed string, `clusters: '[aks-tpg-poc-01, aks-tpg-poc-02]'`. The argo CLI sends a sequence as its JSON text, `["aks-tpg-poc-01","aks-tpg-poc-02"]` (verified with argo 4.1.3), which the workflow reads as the same list. `all` and `auto` stay plain words (`clusters: all`). An empty sequence is refused.
- **`clusterMap` and the other Map inputs** are strings, written as a block: `clusterMap: |` and the map indented below it (the map itself is checked by the `clustermap-<workflow>` schema, section 3). A YAML mapping in place of the block is refused by the schema. `patchFiles` is written by `scripts/submit/pack-patch-files.sh -o <parameter file>`, never typed.
- **Quote versions, quantities and Booleans** (YAML 1.1). Argo reads the file as YAML, which turns an unquoted number into a number before the workflow sees it: `postgresVersion: 17.10` arrives as `17.1` (a different PostgreSQL release) and `1.0` as `1`. Write a version that is a bare number and a decimal quantity as strings, `postgresVersion: "17.10"`, `storageSize: "0.5"`. `postgres-17.10`, `v4.5.1`, `20Gi` and `500m` are strings already, and a whole number (`cpu: 2`, `maxParallel: 3`) is exact. Write Booleans as `"true"` and `"false"`, as the generated examples do: YAML 1.1 readers also take `yes`, `no`, `on` and `off` for Booleans, and the workflow accepts `true` and `false` only. The generated schemas refuse an unquoted version or decimal, because after the YAML reader has changed `17.10` into `17.1` nothing can tell the two apart; they accept the YAML booleans `true` and `false` and whole numbers. `-p name=value` on the command line is always a string and has no such problem.
- **Set an input in one place.** With an input in the file and in a `-p`, argo 4.1.3 puts both into the Workflow (the input is listed twice, the `-p` value first): the `-p` does not replace the file's value, and the run is not guaranteed to use the one you typed. Use `-p` for inputs the file does not set (the examples submit a file without `dryRun` with `-p dryRun=true`), or change the file. `tests/params` fails a command of this page that does this.

---

## 3. clusterMap

`clusterMap` selects the targets of a run (clusters, and the instances on each) and carries values that differ per cluster or per instance. It is optional. A run takes either `clusterMap` or the `clusters` and `instances` inputs, not both. The other inputs stay the defaults of every target, and a map key overrides them for one cluster or one instance.

```yaml
<cluster>:                  # a registered cluster
  <cluster key>: <value>
  instances:
    <instance>:             # an instance (namespace: its key namespace, default pg-<instance>)
      <instance key>: <value>
```

It is written as YAML or JSON. Values can be YAML booleans and numbers (`true`, `2`); a Postgres version written as a number (`16.10`) keeps its trailing zero. List values are YAML sequences, also with one value (`ingressFromNamespaces: [orders-app]`); a comma-separated string (`orders-app,reporting`) or a bare name is refused with the list syntax, and so is `[]`, an empty element (`[a, , b]`) and a file entry such as `repo: x.yaml` (YAML reads it as a mapping; it fails with `repo:<file path> "check for white spaces in between"`). A single-file key is a sequence of exactly one path (`[./ca.pem]`); `clearKinds` also takes the bare word `all`. Map values are YAML or JSON maps of strings. A key set to `null`, or to an empty list or map, is refused: remove the key to use the default. The accepted keys are listed in `workflows/params/cluster-map-keys.yaml`; adding a key is one entry there. The `validate` step checks the whole map before anything changes:

- every cluster is registered, and every name is a DNS label;
- every key exists and the workflow accepts it (an unknown key names the closest known one: `replica` gives "did you mean replicas?"; an invalid name shows a valid form: `orders_db` gives "for example orders-db"; an unregistered cluster names the closest registered one);
- every value has the key's type;
- every required value is present, from the map key or from the workflow input of the same name;
- day0, create-instance, network-policy, backup and delete-instance need at least one instance per cluster. In upgrade, patch, scale and delete-apps, a cluster without instances must carry its cluster-level action (`operatorVersion`, an operator values file or `clearKinds`, `maxReadReplicas`, `deleteOperator`).
- the keys renamed in Round 15 (`valuesPatchFilePath`, `enableSSL`) are refused with their new names (`postgresValuesPatchFilePath`, `backupEnableSSL`).

Every key below comes from `workflows/params/cluster-map-keys.yaml`, as do the JSON Schema of each workflow's map (`workflows/params/schemas/clustermap-<workflow>.schema.json`, and the same schema as `.schema.yaml`) and an example map per workflow (`clustermap-<workflow>.example.yaml`). An editor with the YAML language server checks a map file against its schema when the file starts with `# yaml-language-server: $schema=<path to the schema>`; `check-jsonschema --schemafile workflows/params/schemas/clustermap-patch.schema.json map.yaml` checks it on the command line. A map in a parameter file is a string (`clusterMap: |`): check the map itself, not the parameter file. The schema checks the shape and the value types; the `validate` step of the run also checks what a schema cannot (registered clusters, values a workflow input supplies, CIDR host bits, the combinations below).

<!-- BEGIN GENERATED: clustermap-keys -->
<!-- written by workflows/params/clustermap_schema.py from workflows/params/cluster-map-keys.yaml; do not edit by hand -->

Cluster keys:

| Key | Type | Workflows | Meaning |
|---|---|---|---|
| `operatorVersion` | `String (version)` | day0 (required), upgrade | Operator chart version of the cluster. tpg-day0: required (the key or the input operatorVersion); tpg-upgrade: the version to upgrade this cluster to |
| `maxReadReplicas` | `Integer` | day0, create-instance, scale | The cap on readReplicas of every instance of the cluster (clusters.<c>.cluster.maxReadReplicas, template default 3), 1 or more. tpg-scale-instance: the input maxReadReplicas is its default, and a cluster entry may carry it without instances (only the cap changes) |
| `operatorValuesPatchFilePath` | `List (one file path)` | patch | An operator values file: a path of the submitting machine (its contents in patchFiles) or repo:helm_artifacts/operator/patches/<file>. tpg-patch: it becomes the current operator values patch file, applied on top of the operator overlay of tpg-day0 |
| `operatorValuesOverlayFilePath` | `List (one file path)` | day0 | An operator values overlay file (Round 22; tpg-day0 only; was operatorValuesPatchFilePath): a path of the submitting machine (its contents in patchFiles) or repo:helm_artifacts/operator/overlays/<file>. Applied when the run installs the operator, recorded as clusters.<c>.operator.overlays.values; an operator that runs with another overlay is BLOCKED OVERLAY_USE_TPG_PATCH (use tpg-patch operatorValuesPatchFilePath, which stacks on top) |
| `patchMode` | `Enum` | patch | apply or clear, for the operator file of this cluster and the default of its instances |
| `backupCaBundleFile` | `List (one file path)` | day0, create-instance, patch | The backup CA bundle of the cluster's instances with backupEnableSSL: a PEM file of the submitting machine (its contents in patchFiles) or repo:ca-bundles/<file>. Not together with backupCaBundleVaultSecret on this level; an instance key wins |
| `backupCaBundleVaultSecret` | `String (name)` | day0, create-instance, patch | The backup CA bundle from Vault tpg/ca-bundles/<name> (key caBundle; tpg-aks-infra scripts/vault-secret.sh ca put). Not together with backupCaBundleFile on this level; an instance key wins |
| `clearKinds` | `List (kinds)` | patch | patchMode=clear: the kinds whose current file is removed. operatorValues clears the operator file of the cluster; instance kinds are the default of its instances |
| `deleteOperator` | `Boolean` | delete-apps | true deletes the operator and its CRDs after the listed instances |
| `force` | `Boolean` | delete-apps | As the force input, for this cluster |

Instance keys:

| Key | Type | Workflows | Meaning |
|---|---|---|---|
| `postgresVersion` | `String (version)` | day0 (required), create-instance (required), upgrade, patch (guard), backup (guard), scale (guard), delete-instance (guard), delete-apps (guard), network-policy (guard) | tpg-day0, tpg-create-instance and tpg-upgrade: the version to deploy or upgrade to. Guard in the other workflows: when set, an instance that runs another version is skipped (SKIPPED_VERSION_MISMATCH) and nothing is changed for it |
| `highAvailability` | `Boolean` | day0 (required), create-instance (required) | true: primary and standby (plus readReplicas); false: a single node |
| `readReplicas` | `Integer` | day0, create-instance | Read replicas: 1 or more with highAvailability true, 0 with false |
| `storageSize` | `String (quantity)` | day0, create-instance | Size of the data volume |
| `walStorageSize` | `String (quantity)` | day0, create-instance | Size of the WAL volume |
| `storageClass` | `String (name)` | day0, create-instance | StorageClass of the volumes |
| `cpu` | `String (quantity)` | day0, create-instance | CPU request and limit of the database container |
| `memory` | `String (quantity)` | day0, create-instance | Memory request and limit of the database container |
| `backupSchedule` | `Enum` | day0, create-instance | fleet: the backup CronWorkflows; none: no scheduled backups; operator: PostgresBackupSchedule objects (operatorFullSchedule, operatorIncrementalSchedule) |
| `operatorFullSchedule` | `String (cron)` | day0, create-instance | backupSchedule operator: the cron of the full backups (UTC) |
| `operatorIncrementalSchedule` | `String (cron)` | day0, create-instance | backupSchedule operator: the cron of the incremental backups (UTC); none or an empty value: no incremental schedule |
| `ferret` | `Boolean` | day0, create-instance | true: a FerretDB for the instance; false: none (removes it) |
| `ferretReplicas` | `Integer` | day0, create-instance | FerretDB read-write proxies, 1 or more |
| `ferretReadOnlyReplicas` | `Integer` | day0, create-instance | FerretDB read-only proxies (above 0 needs highAvailability true) |
| `ferretExposure` | `Enum` | day0, create-instance | FerretDB Services: clusterIP, internalLoadBalancer or loadBalancer |
| `ferretSecretName` | `String (name)` | day0, create-instance | FerretDB connection Secret (default: the operator's <instance>-app-user-db-secret) |
| `ferretReadOnlySecretName` | `String (name)` | day0, create-instance | FerretDB read-only connection Secret (default: <instance>-read-only-user-db-secret) |
| `backupEnableSSL` | `Boolean` | day0, create-instance | Backups over HTTPS (spec.storage.azure.enableSSL); the CA bundle comes from backupCaBundleFile, backupCaBundleVaultSecret or ConfigMap tpg-settings backupCaBundle. Renamed from enableSSL in Round 15 |
| `namespace` | `String (namespace)` | day0, create-instance | Round 23: the namespace of the instance, default pg-<instance>; written to clusters/fleet.yaml as instance.namespace and immutable (a different value for an instance that exists is refused). Instances may share a namespace: the first one owns the shared Secrets (regsecret, backup-storage, ServiceAccount tpg-vso), each has its own network policy selected by the postgres-instance label, and purgeNamespace is refused while another instance of the namespace remains. Reserved namespaces (every namespace the fleet installs into, and any name starting with kube-) are refused. Every other workflow reads the namespace from clusters/fleet.yaml |
| `disableInitialBackup` | `Boolean` | day0, create-instance | Round 22: true writes the annotation sql.tanzu.vmware.com/skip-initial-backup: "true" on the new Postgres instance, so the operator takes no initial backup at creation; false (the default) leaves the operator's behaviour. Only new instances |
| `backupCaBundleFile` | `List (one file path)` | day0, create-instance, patch | The backup CA bundle of this instance (backupEnableSSL true): a PEM file of the submitting machine (its contents in patchFiles) or repo:ca-bundles/<file>. Wins over the cluster level and the inputs; not together with backupCaBundleVaultSecret |
| `backupCaBundleVaultSecret` | `String (name)` | day0, create-instance, patch | The backup CA bundle of this instance from Vault tpg/ca-bundles/<name> (key caBundle). Wins over the cluster level and the inputs; not together with backupCaBundleFile |
| `backupFullRetention` | `Integer` | day0, create-instance | Full backups the backup location keeps (retentionPolicy.fullRetention.number), 1 or more |
| `backupFullRetentionType` | `Enum` | day0, create-instance | count: backupFullRetention is a number of full backups; time: a number of days |
| `postgresPatchFilePath` | `List (file paths)` | patch | One or more files (a list) of Postgres, PostgresBackupLocation, PostgresBackupSchedule and PostgresFerretDocumentDB documents, one document per object: paths of the submitting machine (their contents in patchFiles) or repo:helm_artifacts/instance/tpg-instance/patches/<file>. Combined into one stored file helm_artifacts/instance/tpg-instance/patches/<instance>-postgres-<hash>.yaml; the objects a run does not send are carried over from the current file. Applied on top of the overlay of tpg-day0 and tpg-create-instance |
| `postgresOverlayFilePath` | `List (file paths)` | create-instance, day0 | Round 22 (tpg-day0, tpg-create-instance; was postgresPatchFilePath): one or more files (a list) of Postgres, PostgresBackupLocation, PostgresBackupSchedule and PostgresFerretDocumentDB documents, one document per object: paths of the submitting machine (their contents in patchFiles) or repo:helm_artifacts/instance/tpg-instance/overlays/<file>. Combined into one stored file helm_artifacts/instance/tpg-instance/overlays/<instance>-postgres-<hash>.yaml, recorded as overlays.postgres.current and applied at the initial deployment |
| `postgresValuesPatchFilePath` | `List (one file path)` | patch | A tpg-instance chart values file: a path of the submitting machine or repo:helm_artifacts/instance/tpg-instance/patches/<file>, stored as helm_artifacts/instance/tpg-instance/patches/<name>-<uid>.yaml. Renamed from valuesPatchFilePath in Round 15; applied on top of the overlay |
| `postgresValuesOverlayFilePath` | `List (one file path)` | create-instance, day0 | Round 22 (tpg-day0, tpg-create-instance; was postgresValuesPatchFilePath): a tpg-instance chart values file: a path of the submitting machine or repo:helm_artifacts/instance/tpg-instance/overlays/<file>, stored as helm_artifacts/instance/tpg-instance/overlays/<name>-<uid>.yaml and recorded as overlays.postgresValues.current |
| `patchMode` | `Enum` | patch | apply or clear, for the patch files of this instance |
| `clearKinds` | `List (kinds)` | patch | patchMode=clear: the kinds whose current file or documents are removed: Postgres, PostgresBackupLocation, PostgresBackupSchedule, PostgresFerretDocumentDB, postgresValues, or all |
| `backupType` | `Enum` | backup | As the backupType input |
| `backupTimeoutSeconds` | `Integer` | backup | As the backupTimeoutSeconds input, for this instance |
| `replicas` | `Integer` | scale (required) | Read replicas to scale to (required: the key or the input replicas) |
| `enableHAIfNeeded` | `Boolean` | scale | As the input: turn high availability on when replicas is above 0 |
| `preUpgradeBackup` | `Boolean` | upgrade | As the input |
| `allowMajor` | `Boolean` | upgrade | As the input: allow a major Postgres upgrade |
| `purgePvcs` | `Boolean` | delete-instance, delete-apps | As the input: delete the volumes |
| `purgeNamespace` | `Boolean` | delete-instance, delete-apps | As the input: delete the namespace (needs purgePvcs true). Refused (NAMESPACE_SHARED) while another instance of clusters/fleet.yaml, or another Postgres, uses the namespace; tpg-delete-apps deletes a shared namespace after the last instance of the run, and with deleteOperator whoever else is there |
| `finalBackup` | `Enum` | delete-instance, delete-apps | As the input: true (a final backup, best effort), false (none) or required (fail when the instance is not Running) |
| `purgeBackups` | `Boolean` | delete-instance, delete-apps, backup-expire | Round 23. tpg-delete-instance, tpg-delete-apps: as the input - expire every PostgresBackup of the instance while it runs, then delete every blob left under its container and repoPath after it is gone (irreversible; needs finalBackup false; a repoPath another PostgresBackupLocation on any registered cluster uses is expired only, blobs kept and reported). tpg-backup-expire: true expires every backup of the instance and never deletes blobs; not together with backups |
| `backups` | `List (names)` | backup-expire | Round 23, tpg-backup-expire: the PostgresBackup names to expire (a list in brackets, [orders-db-full-202609010100]). A full backup that has dependent differential or incremental backups needs includeDependents: true (else the instance is BLOCKED and the dependents are listed). Not together with purgeBackups |
| `includeDependents` | `Boolean` | backup-expire | Round 23, tpg-backup-expire: true also expires the differential and incremental backups that depend on the listed ones (dependents first); required to expire a backup that has dependents. With backups only |
| `exposure` | `Enum` | day0, create-instance | Read-write Service: clusterIP, internalLoadBalancer or loadBalancer |
| `serviceAnnotations` | `Map` | day0, create-instance | Extra annotations of the read-write Service |
| `readOnlyExposure` | `Enum` | day0, create-instance | Read-only Service: clusterIP, internalLoadBalancer or loadBalancer |
| `readOnlyServiceAnnotations` | `Map` | day0, create-instance | Extra annotations of the read-only Service |
| `allowedSourceRanges` | `List (CIDRs)` | day0, create-instance | Client ranges a load balancer accepts |
| `internalLoadBalancerSubnet` | `String (Azure name)` | day0, create-instance | Subnet of an internal load balancer |
| `networkPolicy` | `Enum` | day0, create-instance | none or baseline (default deny with the allowed clients) |
| `ingressFromNamespaces` | `List` | day0, create-instance, network-policy | Namespaces whose pods may reach 5432 |
| `ingressFromPodLabels` | `Map` | day0, create-instance, network-policy | Pod labels allowed to reach 5432 |
| `ingressFromCidrs` | `List (CIDRs)` | day0, create-instance, network-policy | Client ranges allowed to reach 5432 |
| `egressToCidrs` | `List (CIDRs)` | day0, create-instance, network-policy | Extra egress ranges |
| `egressToFqdns` | `List (host names)` | day0, create-instance, network-policy | Egress host names (needs ACNS) |

Keys per workflow (`required`: the key, or the workflow input named; `guard`: when set, an instance
that runs another version is skipped). The schema of each map is
`workflows/params/schemas/clustermap-<workflow>.schema.json` (also `.schema.yaml`), with an example
map that uses every key in `clustermap-<workflow>.example.yaml`:

`tpg-day0` (`clustermap-day0.schema.json`):

```text
<cluster>:
  operatorVersion                    String (version)      required (this key, or the input operatorVersion)
  maxReadReplicas                    Integer               optional (default: the input maxReadReplicas)
  operatorValuesOverlayFilePath      List (one file path)  optional (default: the input operatorValuesOverlayFilePath)
  backupCaBundleFile                 List (one file path)  optional (the instance key, else the cluster key, else the inputs)
  backupCaBundleVaultSecret          String (name)         optional (the instance key, else the cluster key, else the inputs)
  instances:                                               at least one
    <instance>:
      postgresVersion                String (version)      required (this key, or the input postgresVersion)
      highAvailability               Boolean               required (this key, or the input highAvailability)
      readReplicas                   Integer               optional (default: the input readReplicas)
      storageSize                    String (quantity)     optional (default: the input storageSize)
      walStorageSize                 String (quantity)     optional (default: the input walStorageSize)
      storageClass                   String (name)         optional (default: the input storageClass)
      cpu                            String (quantity)     optional (default: the input cpu)
      memory                         String (quantity)     optional (default: the input memory)
      backupSchedule                 Enum                  optional (default: the input backupSchedule)
      operatorFullSchedule           String (cron)         optional (default: the input operatorFullSchedule)
      operatorIncrementalSchedule    String (cron)         optional (default: the input operatorIncrementalSchedule)
      ferret                         Boolean               optional (default: the input ferret)
      ferretReplicas                 Integer               optional (default: the input ferretReplicas)
      ferretReadOnlyReplicas         Integer               optional (default: the input ferretReadOnlyReplicas)
      ferretExposure                 Enum                  optional (default: the input ferretExposure)
      ferretSecretName               String (name)         optional (default: the input ferretSecretName)
      ferretReadOnlySecretName       String (name)         optional (default: the input ferretReadOnlySecretName)
      backupEnableSSL                Boolean               optional (default: the input backupEnableSSL)
      namespace                      String (namespace)    optional
      disableInitialBackup           Boolean               optional (default: the input disableInitialBackup)
      backupCaBundleFile             List (one file path)  optional (the instance key, else the cluster key, else the inputs)
      backupCaBundleVaultSecret      String (name)         optional (the instance key, else the cluster key, else the inputs)
      backupFullRetention            Integer               optional (default: the input backupFullRetention)
      backupFullRetentionType        Enum                  optional (default: the input backupFullRetentionType)
      postgresOverlayFilePath        List (file paths)     optional (default: the input postgresOverlayFilePath)
      postgresValuesOverlayFilePath  List (one file path)  optional (default: the input postgresValuesOverlayFilePath)
      exposure                       Enum                  optional (default: the input exposure)
      serviceAnnotations             Map                   optional (default: the input serviceAnnotations)
      readOnlyExposure               Enum                  optional (default: the input readOnlyExposure)
      readOnlyServiceAnnotations     Map                   optional (default: the input readOnlyServiceAnnotations)
      allowedSourceRanges            List (CIDRs)          optional (default: the input allowedSourceRanges)
      internalLoadBalancerSubnet     String (Azure name)   optional (default: the input internalLoadBalancerSubnet)
      networkPolicy                  Enum                  optional (default: the input networkPolicy)
      ingressFromNamespaces          List                  optional (default: the input ingressFromNamespaces)
      ingressFromPodLabels           Map                   optional (default: the input ingressFromPodLabels)
      ingressFromCidrs               List (CIDRs)          optional (default: the input ingressFromCidrs)
      egressToCidrs                  List (CIDRs)          optional (default: the input egressToCidrs)
      egressToFqdns                  List (host names)     optional (default: the input egressToFqdns)
```

`tpg-create-instance` (`clustermap-create-instance.schema.json`):

```text
<cluster>:
  maxReadReplicas                    Integer               optional (default: the input maxReadReplicas)
  backupCaBundleFile                 List (one file path)  optional (the instance key, else the cluster key, else the inputs)
  backupCaBundleVaultSecret          String (name)         optional (the instance key, else the cluster key, else the inputs)
  instances:                                               at least one
    <instance>:
      postgresVersion                String (version)      required (this key, or the input postgresVersion)
      highAvailability               Boolean               required (this key, or the input highAvailability)
      readReplicas                   Integer               optional (default: the input readReplicas)
      storageSize                    String (quantity)     optional (default: the input storageSize)
      walStorageSize                 String (quantity)     optional (default: the input walStorageSize)
      storageClass                   String (name)         optional (default: the input storageClass)
      cpu                            String (quantity)     optional (default: the input cpu)
      memory                         String (quantity)     optional (default: the input memory)
      backupSchedule                 Enum                  optional (default: the input backupSchedule)
      operatorFullSchedule           String (cron)         optional (default: the input operatorFullSchedule)
      operatorIncrementalSchedule    String (cron)         optional (default: the input operatorIncrementalSchedule)
      ferret                         Boolean               optional (default: the input ferret)
      ferretReplicas                 Integer               optional (default: the input ferretReplicas)
      ferretReadOnlyReplicas         Integer               optional (default: the input ferretReadOnlyReplicas)
      ferretExposure                 Enum                  optional (default: the input ferretExposure)
      ferretSecretName               String (name)         optional (default: the input ferretSecretName)
      ferretReadOnlySecretName       String (name)         optional (default: the input ferretReadOnlySecretName)
      backupEnableSSL                Boolean               optional (default: the input backupEnableSSL)
      namespace                      String (namespace)    optional
      disableInitialBackup           Boolean               optional (default: the input disableInitialBackup)
      backupCaBundleFile             List (one file path)  optional (the instance key, else the cluster key, else the inputs)
      backupCaBundleVaultSecret      String (name)         optional (the instance key, else the cluster key, else the inputs)
      backupFullRetention            Integer               optional (default: the input backupFullRetention)
      backupFullRetentionType        Enum                  optional (default: the input backupFullRetentionType)
      postgresOverlayFilePath        List (file paths)     optional (default: the input postgresOverlayFilePath)
      postgresValuesOverlayFilePath  List (one file path)  optional (default: the input postgresValuesOverlayFilePath)
      exposure                       Enum                  optional (default: the input exposure)
      serviceAnnotations             Map                   optional (default: the input serviceAnnotations)
      readOnlyExposure               Enum                  optional (default: the input readOnlyExposure)
      readOnlyServiceAnnotations     Map                   optional (default: the input readOnlyServiceAnnotations)
      allowedSourceRanges            List (CIDRs)          optional (default: the input allowedSourceRanges)
      internalLoadBalancerSubnet     String (Azure name)   optional (default: the input internalLoadBalancerSubnet)
      networkPolicy                  Enum                  optional (default: the input networkPolicy)
      ingressFromNamespaces          List                  optional (default: the input ingressFromNamespaces)
      ingressFromPodLabels           Map                   optional (default: the input ingressFromPodLabels)
      ingressFromCidrs               List (CIDRs)          optional (default: the input ingressFromCidrs)
      egressToCidrs                  List (CIDRs)          optional (default: the input egressToCidrs)
      egressToFqdns                  List (host names)     optional (default: the input egressToFqdns)
```

`tpg-upgrade` (`clustermap-upgrade.schema.json`):

```text
<cluster>:
  operatorVersion       String (version)  optional (default: the input operatorVersion)
  instances:
    <instance>:
      postgresVersion   String (version)  optional (default: the input postgresVersion)
      preUpgradeBackup  Boolean           optional (default: the input preUpgradeBackup)
      allowMajor        Boolean           optional (default: the input allowMajor)
```

`tpg-patch` (`clustermap-patch.schema.json`):

```text
<cluster>:
  operatorValuesPatchFilePath      List (one file path)  optional (default: the input operatorValuesPatchFilePath)
  patchMode                        Enum                  optional (default: the input patchMode)
  backupCaBundleFile               List (one file path)  optional (the instance key, else the cluster key, else the inputs)
  backupCaBundleVaultSecret        String (name)         optional (the instance key, else the cluster key, else the inputs)
  clearKinds                       List (kinds)          optional (default: the input clearKinds)
  instances:
    <instance>:
      postgresVersion              String (version)      guard (skip an instance that runs another version)
      backupCaBundleFile           List (one file path)  optional (the instance key, else the cluster key, else the inputs)
      backupCaBundleVaultSecret    String (name)         optional (the instance key, else the cluster key, else the inputs)
      postgresPatchFilePath        List (file paths)     optional (default: the input postgresPatchFilePath)
      postgresValuesPatchFilePath  List (one file path)  optional (default: the input postgresValuesPatchFilePath)
      patchMode                    Enum                  optional (default: the input patchMode)
      clearKinds                   List (kinds)          optional (default: the input clearKinds)
```

`tpg-backup` (`clustermap-backup.schema.json`):

```text
<cluster>:
  instances:                                  at least one
    <instance>:
      postgresVersion       String (version)  guard (skip an instance that runs another version)
      backupType            Enum              optional (default: the input backupType)
      backupTimeoutSeconds  Integer           optional (default: the input backupTimeoutSeconds)
```

`tpg-scale-instance` (`clustermap-scale.schema.json`):

```text
<cluster>:
  maxReadReplicas       Integer           optional (default: the input maxReadReplicas)
  instances:
    <instance>:
      postgresVersion   String (version)  guard (skip an instance that runs another version)
      replicas          Integer           required (this key, or the input replicas)
      enableHAIfNeeded  Boolean           optional (default: the input enableHAIfNeeded)
```

`tpg-delete-instance` (`clustermap-delete-instance.schema.json`):

```text
<cluster>:
  instances:                             at least one
    <instance>:
      postgresVersion  String (version)  guard (skip an instance that runs another version)
      purgePvcs        Boolean           optional (default: the input purgePvcs)
      purgeNamespace   Boolean           optional (default: the input purgeNamespace)
      finalBackup      Enum              optional (default: the input finalBackup)
      purgeBackups     Boolean           optional (default: the input purgeBackups)
```

`tpg-delete-apps` (`clustermap-delete-apps.schema.json`):

```text
<cluster>:
  deleteOperator       Boolean           optional
  force                Boolean           optional (default: the input force)
  instances:
    <instance>:
      postgresVersion  String (version)  guard (skip an instance that runs another version)
      purgePvcs        Boolean           optional (default: the input purgePvcs)
      purgeNamespace   Boolean           optional (default: the input purgeNamespace)
      finalBackup      Enum              optional (default: the input finalBackup)
      purgeBackups     Boolean           optional (default: the input purgeBackups)
```

`tpg-network-policy` (`clustermap-network-policy.schema.json`):

```text
<cluster>:
  instances:                                    at least one
    <instance>:
      postgresVersion        String (version)   guard (skip an instance that runs another version)
      ingressFromNamespaces  List               optional (default: the input ingressFromNamespaces)
      ingressFromPodLabels   Map                optional (default: the input ingressFromPodLabels)
      ingressFromCidrs       List (CIDRs)       optional (default: the input ingressFromCidrs)
      egressToCidrs          List (CIDRs)       optional (default: the input egressToCidrs)
      egressToFqdns          List (host names)  optional (default: the input egressToFqdns)
```

`tpg-backup-expire` (`clustermap-backup-expire.schema.json`):

```text
<cluster>:
  instances:                           at least one
    <instance>:
      purgeBackups       Boolean       optional
      backups            List (names)  optional
      includeDependents  Boolean       optional
```

<!-- END GENERATED: clustermap-keys -->

**The `namespace` key** (Round 23). Without it an instance runs in `pg-<instance>`. With it (tpg-day0 and tpg-create-instance only) the instance runs in that namespace, which is written to `clusters/fleet.yaml` as `instance.namespace` and cannot change afterwards. Reserved namespaces are refused (the list is `reserved` and `reservedPrefixes` of `namespace` in `cluster-map-keys.yaml`), and instances may share a namespace under the rules in the table above and in section 4. Every key of a map for any other workflow addresses the instance by its name; the namespace is read from `clusters/fleet.yaml`. The restore is the exception: it names the namespace of both sides of a pair.

**tpg-restore takes no map of clusters.** Its `clusterMap` is a list of pairs, `{sourceClusterConfig, targetClusterConfig}`, each side `<cluster>: <namespace>: <instance>: {keys}`. Its keys (`sourceBackupName`, `pitrEnabled`, `pitrConfig`, `bestEffort`, `targetInstanceSpecFilePath`, `confirm`, ...) are the `restore` section of `workflows/params/cluster-map-keys.yaml`, are not in the tables above, and have their own schema (`workflows/params/schemas/clustermap-restore.schema.json`) and example (`clustermap-restore.example.yaml`). They are described in section 16.

A map in a parameter file:

```yaml
# scale.yaml
pushMode: direct
clusterMap: |
  aks-tpg-poc-01:
    instances:
      orders-db: {replicas: 2}
      billing-db: {replicas: 0}
  aks-tpg-poc-02:
    maxReadReplicas: 4                 # a new cap, written with the scale
    instances:
      orders-db: {replicas: 4, postgresVersion: postgres-17.6}
```

```bash
argo submit --from workflowtemplate/tpg-scale-instance --parameter-file scale.yaml --watch
# the same map inline as JSON
argo submit --from workflowtemplate/tpg-scale-instance -p pushMode=direct \
  -p clusterMap='{"aks-tpg-poc-01":{"instances":{"orders-db":{"replicas":2},"billing-db":{"replicas":0}}}}' --watch
```

---

## 4. tpg-day0

Plans the inputs into `clusters/fleet.yaml`, pre-checks every selected cluster, writes the plan of the clusters that passed (one commit), installs cert-manager (and the standalone monitoring agent) as Helm releases, then syncs the operator and instance Applications: by default wave 0 alone first, then the other waves in batches of `maxParallel` (`rolloutMode`). Each cluster is deployed under the mutex `tpg-cluster-<cluster>`, so no other tpg workflow changes it at the same time. A cluster that fails the pre-check gets no `fleet.yaml` entries and is not changed; the others go ahead, and the run ends `Failed` in its last step (`gate`), with the blocked clusters and their reasons in the report.

The operator step waits until the Postgres CRDs are Established and the operator Deployment is available on the target, then hard-refreshes the Application, so it does not wait for the Argo CD cache. An instance is ready when the Postgres resource reports `Running` and its StatefulSets are ready; Argo CD shows it Progressing until then.

| Input | Type | Mandatory | Default | Description |
|---|---|---|---|---|
| `clusters` | `List` | yes, without `clusterMap` | | Registered clusters or `all` |
| `instances` | `List` | yes, without `clusterMap` | | Instances to deploy on every selected cluster (namespace `pg-<instance>`; the `clusterMap` key `namespace` sets another) |
| `clusterMap` | `Map` | no | | Targets and per-target values (section 3); replaces `clusters` and `instances` |
| `highAvailability` | `Boolean` | yes (input or map key) | | `true` (primary and standby, plus `readReplicas`) or `false` (single node) |
| `operatorVersion` | `String (version)` | yes (input or map key) | | Operator chart version |
| `postgresVersion` | `String (version)` | yes (input or map key) | | PostgresVersion name |
| `pushMode` | `Enum` | yes | | `direct` or `pr` |
| `readReplicas` | `Integer` | no | `1` with `highAvailability=true` | Read replicas, only with `highAvailability=true`: 1 to `maxReadReplicas` (default 3); empty means 1, 0 is refused. With `highAvailability=false` leave it empty (or 0): the instance is a single node, written as `readReplicas: 0`, and a value above 0 is refused |
| `storageSize`, `walStorageSize` | `String (quantity)` | no | template (`20Gi`, `10Gi`) | Volume sizes |
| `storageClass` | `String (name)` | no | template (`tpg-data-retain`) | StorageClass |
| `cpu`, `memory` | `String (quantity)` | no | template (requests 1/2Gi, limits 2/4Gi) | Request and limit per Postgres pod |
| `backupSchedule` | `Enum` | no | `fleet` | `fleet`: included in `tpg-backup-full` and `tpg-backup-incr`; `none`: excluded; `operator`: excluded, and the operator backs the instance up on its own PostgresBackupSchedule objects (`operatorFullSchedule`, `operatorIncrementalSchedule`; section 13). A re-run writes this input too: repeat `backupSchedule=operator` (or `none`) for the instances that use it, or the entry returns to `fleet` and the sync removes the schedules |
| `operatorFullSchedule` | `String (cron)` | no | `0 0 * * 0` | `backupSchedule=operator`: cron (UTC) of the full backups |
| `operatorIncrementalSchedule` | `String (cron)` | no | `0 0 * * 1-6` | `backupSchedule=operator`: cron (UTC) of the incremental backups; empty: full backups only |
| `installAddons` | `Boolean` | no | `true` | Install or upgrade cert-manager (and the standalone monitoring agent) |
| `existingAddons` | `Enum` | no | `skip` | A Helm release that differs: `skip` or `upgrade` (section 12) |
| `monitoringOption` | `Enum` | no | empty (`tpg-settings`) | Override: `none`, `azure`, `standalone` |
| `backupEnableSSL` | `Boolean` | no | `false` | `enableSSL` of the instances' `PostgresBackupLocation`: `false` uses HTTP to Azure Blob (the storage account must accept HTTP, Terraform `backup_storage_https_only = false`); `true` uses HTTPS and writes a CA bundle as `caBundle` (the two inputs below, else `tpg-settings` `backupCaBundle` from Terraform). Round 23: the value is written per instance (`clusters.<cluster>.instances.<instance>.backup.enableSSL`, `false` unless this input or the map key says `true`), so a cluster-level `clusters.<cluster>.backup.enableSSL: true` in `fleet.yaml` does not reach the instances this workflow creates; set the input or the `clusterMap` key. A re-run of tpg-day0 writes it again: repeat `backupEnableSSL=true` for the instances that use HTTPS, or their entry returns to `false` |
| `disableInitialBackup` | `Boolean` | no | `false` | `true` writes the annotation `sql.tanzu.vmware.com/skip-initial-backup: "true"` on the new Postgres objects, so the operator takes no initial backup at creation (Round 22; the first backup then comes from the schedule or tpg-backup). Only new instances: a running instance is not changed. The 4.5 CRDs and documentation do not list this annotation: confirm in the lab that the operator honours it (HANDOFF, lab items) |
| `backupCaBundleFile` | `List (one file path)` | no | | `backupEnableSSL=true`: the CA bundle, a PEM file (`.pem`, `.crt`, `.cer`) of the submitting machine (its contents in `patchFiles`) or `repo:ca-bundles/<file>` in the fleet repository. Not with `backupCaBundleVaultSecret`; a `clusterMap` key of the instance or its cluster wins (section 15) |
| `backupCaBundleVaultSecret` | `String (name)` | no | | `backupEnableSSL=true`: the CA bundle from Vault `tpg/ca-bundles/<name>` (key `caBundle`; `tpg-aks-infra/scripts/vault-secret.sh ca put`). Not with `backupCaBundleFile` (section 15) |
| `backupFullRetention` | `Integer` | no | template (`4`) | Full backups the backup location keeps (`retentionPolicy.fullRetention.number`, applied by the operator), 1 or more |
| `backupFullRetentionType` | `Enum` | no | template (`count`) | `count`: `backupFullRetention` is a number of full backups; `time`: a number of days. A change restarts the instances that use the backup location (operator 4.5 documentation) |
| `postgresOverlayFilePath` | `List (file paths)` | no | | New instances (Round 22; was `postgresPatchFilePath`): files of `Postgres`, `PostgresBackupLocation`, `PostgresBackupSchedule` and `PostgresFerretDocumentDB` documents (section 7), paths of the submitting machine (absolute, `~/` or relative, contents in `patchFiles`) or `repo:helm_artifacts/instance/tpg-instance/overlays/<file>`. An instance that already runs with other overlay files is `BLOCKED` `OVERLAY_USE_TPG_PATCH` |
| `postgresValuesOverlayFilePath` | `List (one file path)` | no | | New instances (Round 22; was `postgresValuesPatchFilePath`): a tpg-instance chart values file (section 7), a local path or `repo:helm_artifacts/instance/tpg-instance/overlays/<file>` |
| `operatorValuesOverlayFilePath` | `List (one file path)` | no | | The operator values overlay (Round 22; was `operatorValuesPatchFilePath`), applied when the run installs the operator (a local path or `repo:helm_artifacts/operator/overlays/<file>`). A running operator with another file is `BLOCKED` `OVERLAY_USE_TPG_PATCH` |
| `patchFiles` | `Map (JSON)` | no | | The contents of the local files the path inputs and `clusterMap` name, `{"<path as given>": "<base64>"}`. Written by `scripts/submit/pack-patch-files.sh -o <parameter file>` (section 7), never typed |
| `exposure` | `Enum` | no | empty (`clusterIP`) | Read-write Service of each instance: `clusterIP` (inside the cluster), `internalLoadBalancer` (Azure internal load balancer, an IP of the cluster VNet) or `loadBalancer` (public IP) |
| `serviceAnnotations` | `Map` | no | | Extra annotations of the read-write Service, for example `{service.beta.kubernetes.io/azure-dns-label-name: orders}` |
| `readOnlyExposure` | `Enum` | no | empty (`clusterIP`) | Read-only Service of an HA instance: `clusterIP`, `internalLoadBalancer` or `loadBalancer` |
| `readOnlyServiceAnnotations` | `Map` | no | | Extra annotations of the read-only Service |
| `allowedSourceRanges` | `List (CIDRs)` | no | | Client ranges a load balancer accepts (annotation `service.beta.kubernetes.io/azure-allowed-ip-ranges`) |
| `internalLoadBalancerSubnet` | `String (Azure name)` | no | | `internalLoadBalancer`: subnet of the cluster VNet for the load balancer IP (empty: the node subnet) |
| `networkPolicy` | `Enum` | no | empty (`none`) | `none`, or `baseline`: default deny plus the flows the instance needs, then the rules below (section 9) |
| `ingressFromNamespaces` | `List` | no | | `baseline`: namespaces whose pods may connect on 5432 |
| `ingressFromPodLabels` | `Map` | no | | `baseline`: pod labels allowed on 5432, in `ingressFromNamespaces` or in any namespace |
| `ingressFromCidrs` | `List (CIDRs)` | no | | `baseline`: client ranges allowed on 5432 (clients through a load balancer) |
| `egressToCidrs` | `List (CIDRs)` | no | | `baseline`: extra ranges the instance pods may reach |
| `egressToFqdns` | `List (host names)` | no | | `baseline`: host names the instance pods may reach; needs ACNS (Terraform `acns_enabled`) |
| `ferret` | `Boolean` | no | | `true`: a FerretDB (MongoDB wire protocol on 27017, PostgresFerretDocumentDB, Tech Preview) for each instance; `false`: none (removes it); empty: an existing instance keeps what it has. Needs Postgres 17.5 or later and the documentdb extension, which you prepare by hand (below) |
| `ferretReplicas` | `Integer` | no | `1` | FerretDB read-write proxies (1 or more) |
| `ferretReadOnlyReplicas` | `Integer` | no | `0` | FerretDB read-only proxies on the standby; above 0 needs `highAvailability=true` |
| `ferretExposure` | `Enum` | no | empty (`clusterIP`) | FerretDB Services `ferretdb-rw-<instance>` and `ferretdb-ro-<instance>`: `clusterIP`, `internalLoadBalancer` or `loadBalancer`, with the instance's `allowedSourceRanges` and `internalLoadBalancerSubnet` |
| `ferretSecretName` | `String (name)` | no | `<instance>-app-user-db-secret` | Connection Secret of the read-write proxies (created by the operator with the instance) |
| `ferretReadOnlySecretName` | `String (name)` | no | `<instance>-read-only-user-db-secret` | Connection Secret of the read-only proxies |
| `maxParallel` | `Integer` | no | `2` | Clusters per batch after the canary |
| `rolloutMode` | `Enum` | no | `canary` | `canary`, `batches` or `all` (section 2) |
| `dryRun` | `Boolean` | no | `false` | Show the `fleet.yaml` change and run the pre-check only |
| `syncTimeoutSeconds`, `prTimeoutSeconds` | `Integer` | no | `1800`, `3600` | Timeouts |

<!-- BEGIN GENERATED: params-day0 -->
<!-- written by workflows/params/params_schema.py; do not edit by hand -->

Parameter file schema: `workflows/params/schemas/params-day0.schema.json` (also `params-day0.schema.yaml`). Check a parameter file with it:

```bash
check-jsonschema --schemafile workflows/params/schemas/params-day0.schema.json <parameter file>
```

Worked example 1, `workflows/params/schemas/params-day0.example.yaml`:

```yaml
# yaml-language-server: $schema=params-day0.schema.json
# tpg-day0: A dry run on one cluster: validation, the fleet.yaml diff and the pre-check; nothing is written.
# A parameter file of the argo CLI (generated by workflows/params/params_schema.py; see
# params-day0.schema.json). Submit it with:
#   argo submit -n argo --from workflowtemplate/tpg-day0 --parameter-file params-day0.example.yaml --watch
clusters: [aks-tpg-poc-01]
instances: [orders-db]
highAvailability: "true"
readReplicas: "1"
operatorVersion: v4.5.0
postgresVersion: postgres-17.6
pushMode: direct
dryRun: "true"
```

<!-- END GENERATED: params-day0 -->

The pre-check is read-only and runs before anything is written to Git. A cluster that fails it is `BLOCKED`:

| Reason | The cluster is blocked when |
|---|---|
| `FOREIGN_OPERATOR`, `FOREIGN_CRD` | An operator Deployment or a Postgres CRD exists that the cluster's operator Application (`tpg-<cluster>-operator`) does not manage. The operator Deployment (found by its label `app=postgres-operator` or by its image) is ours when its Argo CD tracking annotation names that Application. A CRD is ours when the Application lists it in its resource list or its annotation names it, because the CRDs, installed from the chart's `crds/` directory, carry no annotation. A cluster the fleet deployed is `MANAGED`, never foreign |
| `INSTANCE_NAME_IN_USE` | A Postgres of a requested name exists that its instance Application does not manage |
| `NAMESPACE_SECRET_CONFLICT` | Round 23: the namespace of a requested instance already has a Secret `regsecret` or `backup-storage` that the fleet does not manage (neither created by a VaultStaticSecret that an Application `tpg-<cluster>-*` tracks nor tracked by such an Application itself); Vault Secrets Operator would overwrite it. Rename that Secret or choose another namespace with the `namespace` key. Only NotFound counts as "no such Secret"; any other answer (Forbidden, a timeout) blocks with `CLUSTER_API_ERROR` |
| `VERSION_NOT_AVAILABLE` | A requested Postgres version is not offered by the running operator (`kubectl get postgresversion`) |
| `AZURE_BACKUP_UNSUPPORTED` | The PostgresBackupLocation CRD on the target has no `spec.storage.azure` (or no `caBundle` for `backupEnableSSL=true`). The 4.5 documentation lists S3 and GCS only; the workflows rely on the live CRD |
| `PGDATA_POOL_NOT_HA_CAPABLE` | `highAvailability=true` and the pool labelled `tpg.fleet/pool=postgres` has fewer than 3 Ready nodes across zones 1, 2 and 3 |
| `CILIUM_NOT_AVAILABLE` | `networkPolicy=baseline` and the cluster has no CiliumNetworkPolicy (Azure CNI powered by Cilium) |
| `ACNS_NOT_ENABLED` | `egressToFqdns` is set and `tpg-settings` `acnsEnabled` is not `true` |
| `FERRET_VERSION_UNSUPPORTED` | `ferret=true` for an instance below Postgres 17.5 |
| `FERRET_CRD_MISSING` | `ferret=true` and the running operator has no PostgresFerretDocumentDB CRD (a new operator is checked again after its sync, and the deploy step fails `FERRET_CRD_MISSING`) |
| `UPGRADE_REQUIRED`, `DOWNGRADE_NOT_ALLOWED`, `VERSION_UNKNOWN` | The target runs other versions (below) |
| `OVERLAY_USE_TPG_PATCH` | A running operator or instance would get other overlay files than it runs with (Round 22; `PATCH_USE_TPG_PATCH` before): an identical overlay is left alone, another one is refused: use tpg-patch |
| `UNREACHABLE` | The API server does not answer the hub |

Warnings (the run goes on): `ORPHAN_CRD` (Postgres CRDs without any operator: the operator sync adopts them), `HA_NODES_EXCEED_ZONES` (an HA instance has more database pods, 1 + `readReplicas`, than the data pool has zones: the 4.5 release notes say that Patroni does not fail over automatically when the zone holding the leader and the synchronous standby is lost), `EXPOSURE_UNRESTRICTED` (`loadBalancer` without `allowedSourceRanges`), `FERRET_EXTENSION_REQUIRED` (a run with `ferret=true`: FerretDB needs the documentdb extension in the instance, which the workflows do not install).

**FerretDB** (design decision D71, Tech Preview in operator 4.5). With `ferret=true` the chart renders a PostgresFerretDocumentDB named like the instance, in sync wave 2 (after the instance is Healthy). The deploy step then checks that the connection Secrets it names exist (`FERRET_SECRET_MISSING`, with the db Secrets found in the namespace of the instance; set `ferretSecretName` when the operator names them differently) and that the FerretDB Deployments become available (`FERRET_NOT_READY`, usually the missing documentdb extension). The documentdb extension (`shared_preload_libraries = 'pg_cron,pg_documentdb_core,pg_documentdb'`, `cron.database_name`, the `documentdb` database) is prepared by the DBA as the 4.5 documentation shows ("Using FerretDB for PostgreSQL for Kubernetes"); extensions are out of scope of the fleet. With `networkPolicy=baseline`, port 27017 is open to the same clients as 5432 (section 9).

**Backups by the operator** (`backupSchedule=operator`, design decision D70). The instance leaves the CronWorkflows (`backup.scheduled: false`) and the chart renders `PostgresBackupSchedule` `<instance>-backup-full` (and `<instance>-backup-incremental` when `operatorIncrementalSchedule` is set), in sync wave 2. The chart refuses the schedules while `backup.scheduled` is not `false`, so an instance is never backed up by both. The backup location's retention policy (`backupFullRetention`, `backupFullRetentionType`) expires the operator's backups like the others: the operator applies it.

`backupEnableSSL=true` needs a CA bundle: `backupCaBundleFile` or `backupCaBundleVaultSecret` (the instance's `clusterMap` key, else its cluster's, else the inputs), else `tpg-settings` `backupCaBundle` (written by `tpg-aks-infra/scripts/run.sh` from Terraform). The plan checks that the bundle holds PEM certificates that have not expired; without any bundle it fails with `CA_BUNDLE_MISSING` before anything changes. Between the steps the plan carries each bundle as `@ca:<first 12 characters of its sha256>@` (one workflow parameter is limited to 128 KiB) and records the PEM once in the run record `ca.<hash>`; the commit writes the PEM itself, and fails `CA_BUNDLE_MISSING` when a bundle is in neither the run record nor `tpg-settings`. The report names the source of every bundle that does not come from `tpg-settings` (`CA_BUNDLE <cluster>/<instance> from file ...` or `from Vault tpg/ca-bundles/<name>`).

**Backup repository path** (Round 22). `spec.storage.azure.repoPath` is `/<namespace>/<instance>` by default (for example `/pg-orders-db/orders-db`), so no two instances share a pgBackRest repository. `backup.repoPath` in the instance entry of `clusters/fleet.yaml` overrides it and must start with `/`. **An instance created before Round 22 used `/<namespace>`: pin it with `backup.repoPath: /pg-<instance>` before the next sync**, or the sync moves it to an empty repository and its stanza and backups are left behind. The cross-cluster copy of tpg-restore does not inherit the source's pinned path. A values overlay or patch file may not set `backup.repoPath` or `instance.disableInitialBackup`.

**Namespace** (Round 23). The `clusterMap` instance key `namespace` (tpg-day0, tpg-create-instance; default `pg-<instance>`) is written to `clusters/fleet.yaml` as `instance.namespace`, is immutable (a different value for a declared instance is refused: `NAMESPACE_IMMUTABLE`, which blocks the cluster in tpg-day0 and the instance in tpg-create-instance) and may not be a reserved namespace: every namespace the fleet installs into (`argocd`, `argo`, `vault`, `vault-secrets-operator-system`, `tpg-vault`, `cert-manager`, `monitoring`, `tanzu-postgres-operator`, `default`) and any name that starts with `kube-` (`kube-system`, `kube-public`, `kube-node-lease`, ...); the list is `reserved` and `reservedPrefixes` of `namespace` in `workflows/params/cluster-map-keys.yaml`, which the validate step, the clusterMap schemas and the verify step of tpg-aks-infra all read. A requested namespace that already holds a Secret named `regsecret` or `backup-storage` that the fleet does not manage (not created by a VaultStaticSecret, not tracked by an Application of the fleet) blocks the cluster in the pre-check: `NAMESPACE_SECRET_CONFLICT` names the namespace and the Secret (Vault Secrets Operator would overwrite it); rename that Secret or choose another namespace. Every other workflow reads the namespace from `clusters/fleet.yaml`; the `tpg-instances` ApplicationSet deploys into it. Instances may share a namespace: the first instance planned owns the Secrets the chart names the same in every instance (ServiceAccount `tpg-vso`, VaultStaticSecrets `regsecret` and `backup-storage`; chart value `instance.sharedSecretsOwner`, `false` on the others; the chart reads it from `clusters/fleet.yaml` at the synced commit), each instance has its own network policy, and `purgeNamespace` is refused while another instance uses the namespace. An instance that does not own the Secrets is synced only when they exist in its namespace: tpg-day0 and tpg-create-instance sync the owner's shared objects first, or stop with `SHARED_SECRETS_MISSING` naming the owner. When the owner is deleted, tpg-delete-instance hands the Secrets to a remaining instance first (in tpg-delete-apps one that stays, never one that leaves in the same run): the successor's Application must exist, the owner flags move in one commit, only the shared objects of the successor's Application (`tpg-vso`, `regsecret`, `backup-storage`) are synced (its Postgres is not touched and the rest of its Application is not waited for; it adopts the objects, Argo CD tracks an object with one annotation, so exactly one Application owns them at any moment and they are never deleted), the tracking annotation and the health of the VaultStaticSecrets are checked, and only then the entry and the Application of the old owner go. A failure after the flag commit is reverted in Git (the old owner owns the Secrets again, `HANDOVER_FAILED`). A re-run of tpg-delete-instance for an entry that is already gone takes the namespace from the audit copy `clusters/deleted/<cluster>/<instance>-<yyyymmddHHMM>.yaml` (exactly that name) and checks it against the live Postgres: another namespace is `NAMESPACE_MISMATCH`, and without a copy two Postgres of that name are `NAMESPACE_AMBIGUOUS`.

**Overlay files at Day 0** (Round 15, design decision D83; renamed in Round 22). `postgresOverlayFilePath`, `postgresValuesOverlayFilePath` and `operatorValuesOverlayFilePath` (inputs or `clusterMap` keys; the old `...PatchFilePath` names are no longer accepted by tpg-day0 and tpg-create-instance, which answer with the new name) work like the patch files of tpg-patch, with the creation rules of a new target: the files are checked in the validate step, stored in `helm_artifacts/instance/tpg-instance/overlays/` (the operator file in `helm_artifacts/operator/overlays/`), recorded as `current` under `overlays:` in `clusters/fleet.yaml` and rendered with the new instances and the operator. They apply at the initial deployment, before any patch: tpg-patch stacks its patch files on top of the overlays (a patch wins over an overlay, an overlay over the chart values). An instance or an operator that already runs with another overlay is `BLOCKED` `OVERLAY_USE_TPG_PATCH`; an identical overlay is left alone (change running objects with tpg-patch, which shows the diff and can revert). Local files travel in `patchFiles`: pack them with `scripts/submit/pack-patch-files.sh -o <parameter file>` and submit the parameter file (section 7).

**Re-running tpg-day0** on clusters it deployed is safe. The operator and its CRDs are `MANAGED`, instances that run the requested versions are left as they are, new instances are added, and every instance is checked after the sync: `Running`, backup stanza initialized, and its Services following `exposure` (`EXPOSURE_NOT_APPLIED` when the load balancer addresses do not appear within 5 minutes). To add instances to a running cluster without the operator and add-on steps, use tpg-create-instance (section 5).

**Versions: the cluster decides, not `fleet.yaml`.** `clusters/fleet.yaml` starts empty (`clusters: {}`); `clusters/fleet.example.yaml` shows a filled-in file. For each cluster, tpg-day0 compares the requested operator and Postgres versions with what runs on the target:

| On the target | Result |
|---|---|
| The operator (or the instance) does not run yet | The input is written to `fleet.yaml`, replacing any version declared there. The result carries `FLEET_OVERRIDDEN` with the old value |
| It runs the requested version | Nothing to change on the cluster; a different version declared in `fleet.yaml` is replaced (`FLEET_OVERRIDDEN`) |
| It runs an older version | `BLOCKED` `UPGRADE_REQUIRED`: use tpg-upgrade |
| It runs a newer version | `BLOCKED` `DOWNGRADE_NOT_ALLOWED` |
| The running version cannot be read | `BLOCKED` `VERSION_UNKNOWN`, unless `fleet.yaml` already declares the requested operator version |

A blocked cluster keeps its `fleet.yaml` entry as it was; the other clusters go ahead.

**Restored instances** (Round 23). An instance that tpg-restore restored has `instance.restored: true` in its `fleet.yaml` entry (workflow-owned: a values patch or an overlay cannot set it) and is rendered from its restore-patch, not from the values (section 16). When it is in the `instances` input or in the `clusterMap` of tpg-day0 (and of tpg-create-instance), that instance only is `BLOCKED` `INSTANCE_RESTORED`: the detail names the workflows that change a restored instance, tpg-scale-instance (read replicas), tpg-upgrade `component=postgres` (the version) and tpg-patch (patch files). Its entry is not written, it is not synced or verified (discover leaves it out), the other instances and the cluster go ahead, and the run ends `Failed` at the gate. `dryRun` and the plan show the same record.

**Worked examples** (Round 23). Example 1 is the generated file above: a dry run of orders-db (high availability, one read replica) on one cluster with flat inputs. It validates the inputs, shows the `fleet.yaml` change and runs the pre-check; nothing is written. From your tpg-fleet clone:

```bash
argo submit -n argo --from workflowtemplate/tpg-day0 \
  --parameter-file workflows/params/schemas/params-day0.example.yaml --watch
```

For a real run, copy the file and change `dryRun: "true"` to `dryRun: "false"`. An input that the file sets cannot be changed with `-p` (section 2, Parameter files).

Example 2 deploys different instances on several clusters with `clusterMap`. The inputs are the defaults (here `operatorVersion`, `postgresVersion` and `highAvailability`), and each map key overrides them for one cluster or one instance. `billing-db` runs in a namespace of its own (`namespace`, section 3), the others in `pg-<instance>`:

```yaml
# day0-map.yaml
pushMode: direct
operatorVersion: v4.5.0
postgresVersion: postgres-17.6
highAvailability: "true"
clusterMap: |
  aks-tpg-poc-01:
    instances:
      orders-db: {readReplicas: 2, memory: 8Gi, exposure: internalLoadBalancer}
      billing-db: {highAvailability: false, backupSchedule: none, namespace: billing}
  aks-tpg-poc-02:
    maxReadReplicas: 5
    instances:
      orders-db:
        postgresVersion: postgres-16.10
        storageSize: 50Gi
        networkPolicy: baseline
        ingressFromNamespaces: [orders-app, reporting]
        ingressFromPodLabels: {app.kubernetes.io/part-of: orders}
```

```bash
argo submit --from workflowtemplate/tpg-day0 --parameter-file day0-map.yaml -p dryRun=true --watch
argo submit --from workflowtemplate/tpg-day0 --parameter-file day0-map.yaml --watch
```

Example 2 with local files (Round 15): several clusters, each with its own overlay files and CA bundle source, from one parameter file. The local paths are relative to the directory you run the commands in; `pack-patch-files.sh -o` reads every path of the file (inputs and `clusterMap` keys), checks each file and adds the `patchFiles` line:

```yaml
# day0-fleet.yaml
pushMode: direct
operatorVersion: v4.5.0
postgresVersion: postgres-17.6
highAvailability: "true"
backupEnableSSL: "true"
backupCaBundleVaultSecret: azure-storage          # default of every cluster below
clusterMap: |
  aks-tpg-poc-01:
    operatorValuesOverlayFilePath: [./operator/resources.yaml]
    instances:
      orders-db:
        postgresOverlayFilePath: [./orders/postgres.yaml, ./orders/backup-schedule.yaml]
        postgresValuesOverlayFilePath: [./orders/values.yaml]
        backupSchedule: operator
  aks-tpg-poc-02:
    backupCaBundleFile: [repo:ca-bundles/azure-storage-2026.pem]   # this cluster: a bundle from Git
    instances:
      orders-db:
        postgresOverlayFilePath: [repo:helm_artifacts/instance/tpg-instance/overlays/team-orders-postgres.yaml]
      billing-db:
        highAvailability: false
        postgresValuesOverlayFilePath: [~/overlays/billing-values.yaml]
  aks-tpg-poc-03:
    instances:
      orders-db: {}
```

```bash
<tpg-fleet clone>/scripts/submit/pack-patch-files.sh -o day0-fleet.yaml
argo submit -n argo --from workflowtemplate/tpg-day0 --parameter-file day0-fleet.yaml -p dryRun=true --watch
argo submit -n argo --from workflowtemplate/tpg-day0 --parameter-file day0-fleet.yaml --watch
```

**More commands.**

```bash
# 1. Dry run on every registered cluster: validation, fleet.yaml diff, pre-check
argo submit --from workflowtemplate/tpg-day0 \
  -p clusters=all -p 'instances=[orders-db]' -p highAvailability=true \
  -p operatorVersion=v4.5.0 -p postgresVersion=postgres-17.6 \
  -p pushMode=direct -p dryRun=true --watch

# 2. Deploy orders-db with HA and 2 read replicas on all clusters, direct push
argo submit --from workflowtemplate/tpg-day0 \
  -p clusters=all -p 'instances=[orders-db]' -p highAvailability=true -p readReplicas=2 \
  -p operatorVersion=v4.5.0 -p postgresVersion=postgres-17.6 -p pushMode=direct --watch

# 3. Two single-node instances on one new cluster, sized, reviewed through a pull request
argo submit --from workflowtemplate/tpg-day0 \
  -p 'clusters=[aks-tpg-poc-04]' -p 'instances=[billing-db, reporting-db]' -p highAvailability=false \
  -p operatorVersion=4.5.0 -p postgresVersion=17.6 \
  -p storageSize=100Gi -p walStorageSize=20Gi -p cpu=2 -p memory=8Gi \
  -p pushMode=pr -p prTimeoutSeconds=7200 --watch

# 4. Lab instance excluded from scheduled backups; cert-manager already installed
argo submit --from workflowtemplate/tpg-day0 \
  -p 'clusters=[aks-tpg-poc-03]' -p 'instances=[scratch-db]' -p highAvailability=false \
  -p operatorVersion=v4.5.0 -p postgresVersion=postgres-17.6 -p pushMode=direct \
  -p backupSchedule=none -p installAddons=false --watch

# 5. Three batches of 3 clusters after the canary, longer sync timeout
argo submit --from workflowtemplate/tpg-day0 \
  -p clusters=all -p 'instances=[orders-db]' -p highAvailability=true \
  -p operatorVersion=v4.5.0 -p postgresVersion=postgres-17.6 -p pushMode=direct \
  -p maxParallel=3 -p syncTimeoutSeconds=3600 --watch

# 6. Every cluster at once (no canary), backups over HTTPS (caBundle from tpg-settings)
argo submit --from workflowtemplate/tpg-day0 \
  -p clusters=all -p 'instances=[orders-db]' -p highAvailability=true \
  -p operatorVersion=v4.5.0 -p postgresVersion=postgres-17.6 -p pushMode=direct \
  -p rolloutMode=all -p backupEnableSSL=true --watch

# 7. Internal load balancer in a subnet of the cluster VNet, open to one client range
argo submit --from workflowtemplate/tpg-day0 \
  -p 'clusters=[aks-tpg-poc-01]' -p 'instances=[orders-db]' -p highAvailability=true \
  -p operatorVersion=v4.5.0 -p postgresVersion=postgres-17.6 -p pushMode=direct \
  -p exposure=internalLoadBalancer -p internalLoadBalancerSubnet=apps-subnet \
  -p 'allowedSourceRanges=[10.20.0.0/16]' --watch

# 8. Default-deny network policy: only pods of namespace orders-app reach the database
argo submit --from workflowtemplate/tpg-day0 \
  -p 'clusters=[aks-tpg-poc-01]' -p 'instances=[orders-db]' -p highAvailability=true \
  -p operatorVersion=v4.5.0 -p postgresVersion=postgres-17.6 -p pushMode=direct \
  -p networkPolicy=baseline -p 'ingressFromNamespaces=[orders-app]' --watch

# 9. Backups by the operator (full on Sunday 01:00 UTC, no incrementals) and FerretDB
#    with one read-only proxy on an HA instance, behind an internal load balancer
argo submit --from workflowtemplate/tpg-day0 \
  -p 'clusters=[aks-tpg-poc-01]' -p 'instances=[docs-db]' -p highAvailability=true -p readReplicas=1 \
  -p operatorVersion=v4.5.0 -p postgresVersion=postgres-17.6 -p pushMode=direct \
  -p backupSchedule=operator -p operatorFullSchedule='0 1 * * 0' -p operatorIncrementalSchedule= \
  -p ferret=true -p ferretReadOnlyReplicas=1 -p ferretExposure=internalLoadBalancer --watch

# 10. HTTPS backups with a CA bundle kept in Vault, 14 days of full backups
argo submit --from workflowtemplate/tpg-day0 \
  -p clusters=all -p 'instances=[orders-db]' -p highAvailability=true \
  -p operatorVersion=v4.5.0 -p postgresVersion=postgres-17.6 -p pushMode=direct \
  -p backupEnableSSL=true -p backupCaBundleVaultSecret=azure-storage \
  -p backupFullRetention=14 -p backupFullRetentionType=time --watch
```

With a parameter file:

```yaml
# day0-orders.yaml
clusters: [aks-tpg-poc-01, aks-tpg-poc-02, aks-tpg-poc-03]
instances: [orders-db]
highAvailability: "true"
readReplicas: "1"
operatorVersion: v4.5.0
postgresVersion: postgres-17.6
pushMode: direct
```

```bash
argo submit --from workflowtemplate/tpg-day0 --parameter-file day0-orders.yaml --watch
```

---

## 5. tpg-create-instance

Adds Postgres instances to clusters that already run the fleet's operator (deployed by tpg-day0). Each cluster can get its own instances and values (`clusterMap`), or every listed instance goes to every listed cluster. The instance inputs are those of tpg-day0; postgres patch files and a values patch file can be given as well (paths of the machine that submits the run, their contents in `patchFiles`, or `repo:` files of the fleet repository, as for tpg-patch, section 7) and shape the instance from its first render. The postgres files are combined into `helm_artifacts/instance/tpg-instance/patches/<instance>-postgres-<hash>.yaml`, the values file is stored as `helm_artifacts/instance/tpg-instance/patches/<name>-<uid>.yaml`, and both are recorded as the instance's current patches. The operator, the add-ons and instances that already run are not touched. Each new instance runs in `pg-<instance>` or in the `namespace` of its `clusterMap` entry (Round 23; immutable, reserved names refused, instances may share a namespace: section 4, Namespace).

| Input | Type | Mandatory | Default | Description |
|---|---|---|---|---|
| `clusters` | `List` | yes, without `clusterMap` | | Registered clusters that run the fleet's operator (`all` is not accepted) |
| `instances` | `List` | yes, without `clusterMap` | | New instances, created on every listed cluster (namespace `pg-<instance>`; the `clusterMap` key `namespace` sets another) |
| `clusterMap` | `Map` | no | | Each cluster with its own instances and values (section 3); replaces `clusters` and `instances` |
| `highAvailability` | `Boolean` | yes (input or map key) | | `true` (primary and standby, plus `readReplicas`) or `false` (single node) |
| `postgresVersion` | `String (version)` | yes (input or map key) | | A PostgresVersion the cluster's operator offers |
| `pushMode` | `Enum` | yes | | `direct` or `pr` |
| `readReplicas` | `Integer` | no | `1` with `highAvailability=true` | Read replicas, only with `highAvailability=true` (1 to `maxReadReplicas`; empty means 1, 0 is refused). Above 0 with `highAvailability=false` is refused |
| `storageSize`, `walStorageSize` | `String (quantity)` | no | template (`20Gi`, `10Gi`) | Volume sizes |
| `storageClass` | `String (name)` | no | template (`tpg-data-retain`) | StorageClass |
| `cpu`, `memory` | `String (quantity)` | no | template | Request and limit per Postgres pod |
| `backupSchedule` | `Enum` | no | `fleet` | `fleet`, `none` (excluded from the backup CronWorkflows) or `operator` (PostgresBackupSchedule objects instead, section 4) |
| `operatorFullSchedule`, `operatorIncrementalSchedule` | `String (cron)` | no | `0 0 * * 0`, `0 0 * * 1-6` | As tpg-day0 |
| `backupEnableSSL` | `Boolean` | no | `false` | As tpg-day0, per instance (a cluster-level `clusters.<cluster>.backup.enableSSL` does not reach instances created here); `true` writes a CA bundle as `caBundle` |
| `disableInitialBackup` | `Boolean` | no | `false` | As tpg-day0 |
| `backupCaBundleFile` | `List (one file path)` | no | | As tpg-day0: the CA bundle as a PEM file (section 15) |
| `backupCaBundleVaultSecret` | `String (name)` | no | | As tpg-day0: the CA bundle from Vault `tpg/ca-bundles/<name>` (section 15) |
| `backupFullRetention` | `Integer` | no | template (`4`) | As tpg-day0 |
| `backupFullRetentionType` | `Enum` | no | template (`count`) | As tpg-day0: `count` or `time` |
| `exposure`, `readOnlyExposure` | `Enum` | no | empty (`clusterIP`) | As tpg-day0: `clusterIP`, `internalLoadBalancer` or `loadBalancer` |
| `serviceAnnotations`, `readOnlyServiceAnnotations` | `Map` | no | | As tpg-day0 |
| `allowedSourceRanges` | `List (CIDRs)` | no | | As tpg-day0 |
| `internalLoadBalancerSubnet` | `String (Azure name)` | no | | As tpg-day0 |
| `networkPolicy` | `Enum` | no | empty (`none`) | As tpg-day0 (section 9): `none` or `baseline` |
| `ingressFromNamespaces` | `List` | no | | As tpg-day0 |
| `ingressFromPodLabels` | `Map` | no | | As tpg-day0 |
| `ingressFromCidrs`, `egressToCidrs` | `List (CIDRs)` | no | | As tpg-day0 |
| `egressToFqdns` | `List (host names)` | no | | As tpg-day0; needs ACNS |
| `ferret` | `Boolean` | no | | As tpg-day0: a FerretDB for each new instance (Postgres 17.5 or later) |
| `ferretReplicas`, `ferretReadOnlyReplicas` | `Integer` | no | `1`, `0` | As tpg-day0 |
| `ferretExposure` | `Enum` | no | empty (`clusterIP`) | As tpg-day0: `clusterIP`, `internalLoadBalancer` or `loadBalancer` |
| `ferretSecretName`, `ferretReadOnlySecretName` | `String (name)` | no | | As tpg-day0 |
| `postgresOverlayFilePath` | `List (file paths)` | no | | Files of Postgres, PostgresBackupLocation, PostgresBackupSchedule and PostgresFerretDocumentDB documents, merged into the new instance's objects (creation rules below; section 7). Renamed from `postgresPatchFilePath` in Round 22; local paths or `repo:helm_artifacts/instance/tpg-instance/overlays/<file>` |
| `postgresValuesOverlayFilePath` | `List (one file path)` | no | | A tpg-instance chart values file. Renamed from `postgresValuesPatchFilePath` in Round 22; a local path or `repo:helm_artifacts/instance/tpg-instance/overlays/<file>` |
| `patchFiles` | `Map (JSON)` | with a local file | | The contents of the local files, `{"<path as given>": "<base64>"}`: `scripts/submit/pack-patch-files.sh -o <parameter file>` writes it into the parameter file, `scripts/submit/tpg-create-instance.sh` fills it |
| `maxParallel` | `Integer` | no | `2` | Clusters per batch after the canary |
| `rolloutMode` | `Enum` | no | `canary` | `canary`, `batches` or `all` (section 2) |
| `dryRun` | `Boolean` | no | `false` | Validate, plan, pre-check and dry-run; push and deploy nothing |
| `syncTimeoutSeconds`, `prTimeoutSeconds` | `Integer` | no | `1800`, `3600` | Per cluster, pull request |

<!-- BEGIN GENERATED: params-create-instance -->
<!-- written by workflows/params/params_schema.py; do not edit by hand -->

Parameter file schema: `workflows/params/schemas/params-create-instance.schema.json` (also `params-create-instance.schema.yaml`). Check a parameter file with it:

```bash
check-jsonschema --schemafile workflows/params/schemas/params-create-instance.schema.json <parameter file>
```

Worked example 1, `workflows/params/schemas/params-create-instance.example.yaml`:

```yaml
# yaml-language-server: $schema=params-create-instance.schema.json
# tpg-create-instance: A dry run: one single-node instance on one cluster.
# A parameter file of the argo CLI (generated by workflows/params/params_schema.py; see
# params-create-instance.schema.json). Submit it with:
#   argo submit -n argo --from workflowtemplate/tpg-create-instance --parameter-file params-create-instance.example.yaml --watch
clusters: [aks-tpg-poc-01]
instances: [reports-db]
highAvailability: "false"
postgresVersion: postgres-17.6
pushMode: direct
dryRun: "true"
```

<!-- END GENERATED: params-create-instance -->

The run, in order:

1. **Validate** the inputs and `clusterMap`; each patch file must be in `patchFiles` and fit its input (section 7, step 1).
2. **Plan** `clusters/fleet.yaml` (nothing is pushed yet). Per cluster: the operator must run (`OPERATOR_NOT_INSTALLED` otherwise) and be declared in `fleet.yaml` (`NOT_IN_FLEET`). Per instance: the patch files are stored under their UID names and checked against the creation rules (a declared instance whose current file holds the same contents keeps it, so a repeated run stays `ALREADY_EXISTS`), the instance is rendered with the chart, and the rendered Postgres object is sent to the cluster with `--dry-run=server` (in namespace `default`, under the name `tpg-create-probe`, because the namespace of the instance does not exist yet), so the operator's admission webhooks judge it before anything is written.
3. **Pre-check** as tpg-day0, with the operator required to be `MANAGED` (section 4).
4. **Commit** the plan of the clusters that passed, without the instances that were blocked, with the stored patch files their entries reference.
5. **Deploy** the new instance Applications, canary first, one run at a time per cluster (the mutex `tpg-cluster-<cluster>`, shared with tpg-day0, tpg-patch, tpg-network-policy and tpg-delete-apps). Each instance is checked like in tpg-day0: `Running`, backup stanza, FerretDB when `ferret=true`, Services following `exposure`.
6. **Gate:** the run ends `Failed` when a cluster or an instance was `BLOCKED`.

| Result of an instance | When |
|---|---|
| `SUCCEEDED` | Created and checked |
| `SUCCEEDED` `ALREADY_EXISTS` | Declared in `fleet.yaml` and running with the requested values: nothing changed, so a re-run is safe |
| `BLOCKED` `INSTANCE_EXISTS` | It runs with other values or another version: use tpg-patch, tpg-scale-instance or tpg-upgrade |
| `BLOCKED` `INSTANCE_NAME_IN_USE` | A Postgres of that name runs but is not declared in `fleet.yaml` |
| `BLOCKED` `INSTANCE_RESTORED` | Round 23: the instance was restored by tpg-restore (`instance.restored`): use tpg-scale-instance, tpg-upgrade `component=postgres` or tpg-patch |
| `BLOCKED` `OVERLAY_REFUSED` | An overlay file (Round 22; `PATCH_REFUSED` before) breaks a creation rule (the detail names the file and the field), or a `repo:` file is not on the fleet branch |
| `BLOCKED` `RENDER_FAILED`, `DRY_RUN_REJECTED` | The chart cannot render the instance, or the API server or the operator's webhooks refuse it |

An instance that is declared in `fleet.yaml` but absent on the cluster (for example after a blocked tpg-day0) is deployed from its entry, with the note `DECLARED_NOT_DEPLOYED`.

**Creation rules for patch files.** Nothing runs yet, so a patch file may set more than in tpg-patch: sizes and `spec.storageClassName` are allowed. Refused, because each of these values has one source:

| Document or file | Refused |
|---|---|
| Every postgres patch document | Anything but `apiVersion: sql.tanzu.vmware.com/v1`, `kind` and `spec` (a PostgresBackupSchedule also `metadata.name`); a field the CRD of its kind does not have; a second document for the same object (in one file or across the files of the run) |
| `Postgres` | `spec.postgresVersion`, `spec.highAvailability` (the inputs); `spec.serviceType`, `spec.serviceAnnotations`, `spec.readOnlyServiceType`, `spec.readOnlyServiceAnnotations` (the exposure inputs) |
| `PostgresBackupLocation` | `spec.storage.s3`, `gcs`, `pvc` (the fleet backs up to Azure Blob); `spec.storage.azure.secret` (from Vault); `spec.storage.azure.enableSSL`, `caBundle` (the inputs `backupEnableSSL`, `backupCaBundleFile`, `backupCaBundleVaultSecret`) |
| `PostgresBackupSchedule` | A `metadata.name` other than `<instance>-backup-full` or `<instance>-backup-incremental` (or `backup-full`, `backup-incremental`); `spec.backupTemplate.spec.sourceInstance`, `type` (set by the chart); `expire` (it would expire every scheduled backup; the backup location's retention policy expires backups) |
| Values patch | A key the chart does not have; `instance.name`, `instance.postgresVersion`, `instance.highAvailability`, `instance.serviceType` (replaced by `instance.exposure`), `cluster`, `patches`, `valuesOverride` (tpg-restore) |

**Worked examples** (Round 23). Example 1 is the generated file above: a dry run that plans one single-node instance (reports-db) on one cluster with flat inputs. It validates, plans `fleet.yaml`, renders the chart and sends the Postgres object through the API server with `--dry-run=server`; nothing is pushed or deployed. From your tpg-fleet clone:

```bash
argo submit -n argo --from workflowtemplate/tpg-create-instance \
  --parameter-file workflows/params/schemas/params-create-instance.example.yaml --watch
```

For a real run, copy the file and change `dryRun: "true"` to `dryRun: "false"`. An input that the file sets cannot be changed with `-p` (section 2, Parameter files).

Example 2 creates different instances on several clusters with `clusterMap`; `audit-db` gets a namespace of its own (`namespace`, section 3):

```yaml
# create-map.yaml
pushMode: direct
postgresVersion: postgres-17.6
highAvailability: "false"
clusterMap: |
  aks-tpg-poc-01:
    instances:
      reports-db: {storageSize: 100Gi}
      audit-db:
        highAvailability: true
        readReplicas: 1
        namespace: audit
        networkPolicy: baseline
        ingressFromNamespaces: [audit-app]
  aks-tpg-poc-02:
    instances:
      reports-db: {postgresVersion: postgres-16.10, backupSchedule: none}
```

```bash
argo submit --from workflowtemplate/tpg-create-instance --parameter-file create-map.yaml -p dryRun=true --watch
argo submit --from workflowtemplate/tpg-create-instance --parameter-file create-map.yaml --watch
```

Example 2 with local files: overlay files per cluster and instance, local paths (packed first) and `repo:` files side by side, and a CA bundle from a file of your machine for the HTTPS instances:

```yaml
# create-patched.yaml
pushMode: direct
postgresVersion: postgres-17.6
highAvailability: "true"
clusterMap: |
  aks-tpg-poc-01:
    instances:
      audit-db:
        postgresOverlayFilePath: [./audit/postgres.yaml, repo:helm_artifacts/instance/tpg-instance/overlays/team-backup-location.yaml]
        backupEnableSSL: true
        backupCaBundleFile: [./certs/azure-storage.pem]
  aks-tpg-poc-02:
    instances:
      audit-db:
        postgresValuesOverlayFilePath: [./audit/values-small.yaml]
        highAvailability: false
```

```bash
~/src/tpg-fleet/scripts/submit/pack-patch-files.sh -o create-patched.yaml
argo submit -n argo --from workflowtemplate/tpg-create-instance --parameter-file create-patched.yaml -p dryRun=true --watch
argo submit -n argo --from workflowtemplate/tpg-create-instance --parameter-file create-patched.yaml --watch
```

**More commands.**

```bash
# 1. Dry run: a single-node instance on two clusters (flags instead of a parameter file)
argo submit --from workflowtemplate/tpg-create-instance \
  -p 'clusters=[aks-tpg-poc-01, aks-tpg-poc-02]' -p 'instances=[reports-db]' \
  -p highAvailability=false -p postgresVersion=postgres-17.6 -p pushMode=direct -p dryRun=true --watch

# 2. An HA instance behind an internal load balancer, with its own resources and
#    backup location patches (run from the directory that holds the two files)
cat > audit.yaml <<'YAML'
clusters: [aks-tpg-poc-01]
instances: [audit-db]
highAvailability: "true"
readReplicas: "1"
postgresVersion: postgres-17.6
exposure: internalLoadBalancer
allowedSourceRanges: [10.20.0.0/16]
postgresOverlayFilePath: [./audit-resources.yaml, ./audit-backup-location.yaml]
pushMode: pr
YAML
~/src/tpg-fleet/scripts/submit/pack-patch-files.sh -o audit.yaml
argo submit -n argo --from workflowtemplate/tpg-create-instance --parameter-file audit.yaml --watch
```

---

## 6. tpg-upgrade

Upgrades the operator (`component=operator`) or Postgres instances (`component=postgres`), canary first, and writes the new version to `clusters/fleet.yaml`. With `clusterMap`, one run can upgrade the operator and instances to versions that differ per cluster and per instance. An instance that tpg-restore restored (`instance.restored`, section 16) is upgraded like any other: the new `instance.postgresVersion` differs from its restore-patch's version, so the chart renders the new version (and the rest of the restore-patch as it is).

| Input | Type | Mandatory | Default | Description |
|---|---|---|---|---|
| `component` | `Enum` | yes, without `clusterMap` | | `operator` or `postgres`. With `clusterMap`: limits the run to that part, and makes `targetVersion` its default version |
| `targetVersion` | `String (version)` | yes, without `clusterMap` | | Operator: `v4.5.1`; Postgres: `postgres-17.6` |
| `clusters` | `List` | yes, without `clusterMap` | | Registered clusters or `all` |
| `instances` | `List` | yes for `postgres`, without `clusterMap` | | Instances or `all`; not allowed for `operator` |
| `clusterMap` | `Map` | no | | `operatorVersion` per cluster, `postgresVersion`, `preUpgradeBackup` and `allowMajor` per instance (section 3) |
| `pushMode` | `Enum` | yes | | `direct` or `pr` |
| `preUpgradeBackup` | `Boolean` | no | `true` | Full backup of each affected instance first |
| `allowMajor` | `Boolean` | no | `false` | Allow major Postgres upgrades; pauses for approval before every batch after the canary |
| `maxParallel` | `Integer` | no | `1` | Clusters per batch after the canary |
| `rolloutMode` | `Enum` | no | `canary` | `canary`, `batches` or `all` (section 2). With `allowMajor=true`, the approval pause comes before every batch after the first |
| `dryRun` | `Boolean` | no | `false` | Record the planned upgrade (minor or major, current and target) per target |
| `timeoutSeconds`, `prTimeoutSeconds` | `Integer` | no | `1800`, `3600` | Per cluster (operator) or per instance (Postgres) |

<!-- BEGIN GENERATED: params-upgrade -->
<!-- written by workflows/params/params_schema.py; do not edit by hand -->

Parameter file schema: `workflows/params/schemas/params-upgrade.schema.json` (also `params-upgrade.schema.yaml`). Check a parameter file with it:

```bash
check-jsonschema --schemafile workflows/params/schemas/params-upgrade.schema.json <parameter file>
```

Worked example 1, `workflows/params/schemas/params-upgrade.example.yaml`:

```yaml
# yaml-language-server: $schema=params-upgrade.schema.json
# tpg-upgrade: A dry run: the operator of one cluster.
# A parameter file of the argo CLI (generated by workflows/params/params_schema.py; see
# params-upgrade.schema.json). Submit it with:
#   argo submit -n argo --from workflowtemplate/tpg-upgrade --parameter-file params-upgrade.example.yaml --watch
component: operator
targetVersion: v4.5.1
clusters: [aks-tpg-poc-01]
pushMode: direct
dryRun: "true"
```

<!-- END GENERATED: params-upgrade -->

Minor or major is detected per instance. Downgrades fail. Instances not selected are reported as `SKIPPED_NOT_SELECTED`. An operator upgrade requires every instance that exists on the cluster to be `Running`; an instance declared in `fleet.yaml` that does not exist on the cluster (never deployed, for example after a blocked tpg-day0) is left out with the warning `INSTANCE_NOT_DEPLOYED`. Only a NotFound answer counts as absent: any other error reading the instance (API timeout, permissions) fails the cluster with `CLUSTER_API_ERROR`. With `clusterMap`, every listed instance must be declared on its cluster, and on each cluster the operator is upgraded first; the Postgres part does not start on a cluster whose operator upgrade failed.

A Postgres upgrade of one instance runs in this order:

1. Full backup (`preUpgradeBackup=true`).
2. `PostgresVersionUpgrade` created on the target and followed with the instance pods printed every 5 seconds; `Failed` or `PreCheckFailed` ends the instance as `FAILED` with the operator's message.
3. The instance is `Running` with the target `status.dbVersion` (`DB_VERSION_MISMATCH` otherwise).
4. The workflow waits up to 5 minutes for the operator to set `spec.postgresVersion.name` to the target (each poll is logged); if it does not, it logs that and goes on, because Argo CD ignores that field.
5. The version is written to `clusters/fleet.yaml`, pushed, and the Application is synced at that commit.
6. `SUCCEEDED` only when the Application is Synced. Otherwise the instance is `FAILED` with the sync reason (`SYNC_REJECTED`, `SYNC_DRIFT`, ...) and the detail "database upgraded to ..., but the Application did not sync", and the later batches do not run.

The `tpg-instances` ApplicationSet ignores `Postgres spec.postgresVersion` (`RespectIgnoreDifferences=true`), so the operator's admission webhook (`postgresVersion.name cannot be changed ...`) does not reject the sync.

**The operator image of a values patch.** A current operator values patch (section 7) that sets `operatorImage` carries the tag of the running version. The version commit stores a copy of that file with the new tag under a new UID name and makes it current (the old file is never changed and becomes `previous` with its commit), and rewrites its copy `helm_artifacts/operator/patches/clusters/<cluster>.yaml`, so the image follows the chart. A tag that is not the running version stops the upgrade before anything changes (`OPERATOR_IMAGE_PINNED`); so does an `operator.patches.values` entry that is not `{current, previous}` (`FLEET_ENTRY_INVALID`: a fleet repository written before Round 15).

**Worked examples** (Round 23). Example 1 is the generated file above: a dry run of the operator upgrade of one cluster with flat inputs. The run records the planned upgrade (current and target version) and changes nothing. From your tpg-fleet clone:

```bash
argo submit -n argo --from workflowtemplate/tpg-upgrade \
  --parameter-file workflows/params/schemas/params-upgrade.example.yaml --watch
```

For a real run, copy the file and change `dryRun: "true"` to `dryRun: "false"`. An input that the file sets cannot be changed with `-p` (section 2, Parameter files).

Example 2 upgrades the operator and instances to versions that differ per cluster and instance, with `clusterMap` (on each cluster the operator goes first; the Postgres part does not start on a cluster whose operator upgrade failed). Put `-p dryRun=true` in front for the plan:

```yaml
# upgrade-map.yaml
pushMode: direct
clusterMap: |
  aks-tpg-poc-01:
    operatorVersion: v4.5.1              # operator first, then the instances below
    instances:
      orders-db: {postgresVersion: postgres-17.7}
  aks-tpg-poc-02:
    instances:
      orders-db: {postgresVersion: postgres-17.6, allowMajor: true}
      billing-db: {postgresVersion: postgres-16.10, preUpgradeBackup: false}
```

```bash
argo submit --from workflowtemplate/tpg-upgrade --parameter-file upgrade-map.yaml -p dryRun=true --watch
argo submit --from workflowtemplate/tpg-upgrade --parameter-file upgrade-map.yaml --watch
```

**More commands.**

```bash
# 1. Operator: dry run on all clusters
argo submit --from workflowtemplate/tpg-upgrade \
  -p component=operator -p targetVersion=v4.5.1 -p clusters=all -p pushMode=direct -p dryRun=true --watch

# 2. Operator: canary cluster only, through a pull request
argo submit --from workflowtemplate/tpg-upgrade \
  -p component=operator -p targetVersion=v4.5.1 -p 'clusters=[aks-tpg-poc-01]' -p pushMode=pr --watch

# 3. Operator: remaining clusters two at a time, without pre-upgrade backups
argo submit --from workflowtemplate/tpg-upgrade \
  -p component=operator -p targetVersion=v4.5.1 -p 'clusters=[aks-tpg-poc-02, aks-tpg-poc-03]' \
  -p pushMode=direct -p maxParallel=2 -p preUpgradeBackup=false --watch

# 4. Postgres minor upgrade of every instance on every cluster
argo submit --from workflowtemplate/tpg-upgrade \
  -p component=postgres -p targetVersion=postgres-16.10 -p clusters=all -p instances=all \
  -p pushMode=direct --watch

# 5. Postgres major upgrade of orders-db, with approval between batches
argo submit --from workflowtemplate/tpg-upgrade \
  -p component=postgres -p targetVersion=postgres-17.6 -p clusters=all -p 'instances=[orders-db]' \
  -p allowMajor=true -p pushMode=pr -p timeoutSeconds=7200 --watch
argo resume @latest          # approve the next batch after checking the canary

# 6. Postgres minor upgrade of two instances on one cluster
argo submit --from workflowtemplate/tpg-upgrade \
  -p component=postgres -p targetVersion=17.7 -p 'clusters=[aks-tpg-poc-02]' \
  -p 'instances=[orders-db, billing-db]' -p pushMode=direct --watch
```

---

## 7. tpg-patch

Changes settings of deployed operators and instances that no other workflow owns (Round 14, design decisions D76 to D79; Round 15, D81 to D83 and D86). You write patch files, pass their paths (files of your machine, or files of the fleet repository), and the workflow stores them in the fleet repository, checks them, shows what they change, and syncs them. There are three kinds of patch file, each with its own input and `clusterMap` key. tpg-day0 and tpg-create-instance take the same three kinds as **overlay files** (`postgresOverlayFilePath`, `postgresValuesOverlayFilePath`, `operatorValuesOverlayFilePath`, Round 22), stored in `helm_artifacts/instance/tpg-instance/overlays/` and `helm_artifacts/operator/overlays/` and recorded under `overlays:`; they apply at the initial deployment and the patch files of this section stack on top of them:

On an instance that tpg-restore restored (`instance.restored`, section 16) a **postgres** patch file is applied over the restore-patch and over the entry's later changes (the instance's Postgres is rendered from its restore-patch, not from the values); tpg-patch never retires or changes the restore-patch, and a **values** patch that sets an `instance:` key which reaches the Postgres (`storageSize`, `walStorageSize`, `resources`, `exposure`, `readOnlyExposure`, `serviceAnnotations`, `readOnlyServiceAnnotations`, `allowedSourceRanges`, `internalLoadBalancerSubnet`) for such an instance is refused (`PATCH_REFUSED`, detail `RESTORED_VALUES_PATCH`): the detail names tpg-scale-instance (read replicas), tpg-upgrade `component=postgres` (the version) and postgres patch files, the ways to change a restored instance. Keys that do not reach the Postgres (`backup`, `network`, `ferret`, ...) stay allowed. A values patch cannot set `restorePatch` or `instance.restored`.

| Input and map key | Level | Stored as | Content | How it is applied |
|---|---|---|---|---|
| `postgresPatchFilePath` | instance | one file per instance, `helm_artifacts/instance/tpg-instance/patches/<instance>-postgres-<hash>.yaml` | One or more files (a list). Each holds one or more YAML documents, `apiVersion: sql.tanzu.vmware.com/v1`, `kind` and a `spec` fragment, of the kinds `Postgres`, `PostgresBackupLocation`, `PostgresBackupSchedule` (with `metadata.name: <instance>-backup-full` or `<instance>-backup-incremental`) and `PostgresFerretDocumentDB`; every field is checked against the CRD of its kind; one document per object | The tpg-instance chart merges each document into the object of its kind (after the chart values, so the document wins) |
| `postgresValuesPatchFilePath` | instance | `helm_artifacts/instance/tpg-instance/patches/<name>-<uid>.yaml` | A fragment of the chart values; every key must exist in `helm_artifacts/instance/tpg-instance/values.yaml` or `clusters/_template/`, for example `backup.fullRetention`. Renamed from `valuesPatchFilePath` in Round 15 | Merged into the instance's values before the chart renders |
| `operatorValuesPatchFilePath` | cluster | `helm_artifacts/operator/patches/<name>-<uid>.yaml` | Only these operator chart values: `operatorImage`, `instanceRegistryRepo`, `ferretDBImageRepo`, `dockerRegistrySecretName`, `certManagerClusterIssuerName`, `certManagerNamespace`, `resources` (`limits` and `requests`, `cpu` and `memory`), `enableSecurityContext`. Any other key fails the run | Copied to `helm_artifacts/operator/patches/clusters/<cluster>.yaml`, which the `tpg-operator` Application reads as `$fleet/helm_artifacts/operator/patches/clusters/<cluster>.yaml`, after the overlay copy `$fleet/helm_artifacts/operator/overlays/clusters/<cluster>.yaml` of tpg-day0 |

`backupCaBundleFile` and `backupCaBundleVaultSecret` (inputs and `clusterMap` keys, section 15) replace the CA bundle of running instances with `backup.enableSSL: true`; a run may carry them alone, without patch files.

**Where the files come from** (D83). A path is one of:

- a file of the machine that submits the run: absolute (`/home/me/patches/orders.yaml`), in your home directory (`~/patches/orders.yaml`) or relative to the directory you run the commands in (`./orders.yaml`, `../shared/orders.yaml`). The workflow runs on the hub and cannot read your files, so their contents travel in the input `patchFiles`, a JSON map of the path as you wrote it to the file's base64;
- `repo:<path>`: a file of the fleet repository on the fleet branch, read by the workflow: `repo:helm_artifacts/instance/tpg-instance/patches/<file>` for the postgres and values files, `repo:helm_artifacts/operator/patches/<file>` for operator values, `repo:ca-bundles/<file>` for CA bundles. It is not packed. Like a local file, it is checked and then copied to its stored name, so a later change of the repository file changes no instance until the next tpg-patch.

A file is `.yaml` or `.yml` (a CA bundle `.pem`, `.crt` or `.cer`), at most 256 KiB; `patchFiles` holds at most 512 KiB of base64. The stored name is the file's own name plus a unique 5-character UID (`orders-backup.yaml` becomes `orders-backup-k3x9q.yaml`); the postgres documents of an instance are stored together, named by the hash of their contents.

**Packing the local files: one parameter file, two commands** (Round 15, 2ii). Put the inputs, and the `clusterMap` when the targets differ, in a parameter file, then let `scripts/submit/pack-patch-files.sh -o` of your tpg-fleet clone read every local path the file names (the path inputs and every `clusterMap` key that names a file), check each file (it exists, has a valid size and YAML, and fits its input, with the same checks as the validate step; a CA bundle holds PEM certificates) and write the `patchFiles` line into the same file:

```bash
cd ~/work/orders-change              # the directory the relative paths start from
~/src/tpg-fleet/scripts/submit/pack-patch-files.sh -o patch-map.yaml
argo submit -n argo --from workflowtemplate/tpg-patch --parameter-file patch-map.yaml --watch
```

Run `pack-patch-files.sh -o` again after every change of a path or a file: it replaces the `patchFiles` line. It stops before anything is submitted when a file is missing (naming the directory the relative paths start from) or does not fit its input. The earlier way, `pack-patch-files.sh -o FILE.yaml FILE...` with the files listed on the command line, failed when a listed path was not written exactly as in the parameter file (`orders.yaml` against `./patches/orders.yaml`), or when a later edit of the parameter file dropped the `patchFiles` line: the run then refused the files with "its contents are not in patchFiles". Listing files still works (`pack-patch-files.sh FILE...` prints the JSON for `-p patchFiles='...'`, for a few small files, since Linux limits one command-line argument to 128 KiB), but the parameter file is the reliable form. `scripts/submit/tpg-patch.sh` packs for you. The helper needs bash, jq and mikefarah yq v4; it reads the checks from the clone it sits in, or from `TPG_FLEET_DIR`.

**One current file per kind.** `clusters/fleet.yaml` records, per target and kind, the file that is applied (`current`) and the one before it with the commit that added it (`previous`):

```yaml
clusters:
  aks-tpg-poc-01:
    operator:
      version: v4.5.0
      patches:
        values:
          current: helm_artifacts/operator/patches/operator-resources-q7m2d.yaml   # repository path
    instances:
      orders-db:
        patches:
          postgres:
            current: patches/orders-db-postgres-3f9a1.yaml          # relative to helm_artifacts/instance/tpg-instance/
            previous:
              path: patches/orders-db-postgres-c02e7.yaml
              commit: 9b1d4e7a2c5f8b0d3e6a9c2f5b8e1d4a7c0f3b6e
          postgresValues:
            current: patches/orders-backup-k3x9q.yaml
            previous:
              path: patches/orders-retention-a81zd.yaml
              commit: 4f2c1e9a7b3d5c8e0f1a2b3c4d5e6f7a8b9c0d1e
```

Only `current` is applied, so a new values or operator file must hold every override you still want: the diff the workflow prints shows what the old file loses. The postgres file is different (D81): its documents are kept per object, and a run replaces only the objects it sends. A run with a `PostgresBackupLocation` document keeps the `Postgres` and schedule documents of the current file, so a team can own the backup location patch and another the resources patch. An entry of another shape (a list, or `patches.values` of an instance) is refused: it was written before Round 15, and a Round 15 fleet starts from a new repository.

**Removing patches: `patchMode=clear` with `clearKinds`** (D82). `clearKinds` (input or map key) names what is removed: `Postgres`, `PostgresBackupLocation`, `PostgresBackupSchedule` (both schedules) and `PostgresFerretDocumentDB` remove those documents from the instance's postgres file (a new stored file holds the rest; with no document left, the file stops being current); `postgresValues` removes the values file and `operatorValues` the operator file of the cluster; `all` removes every patch of the targets. The removed file becomes `previous`. A clear run takes no paths and no `patchFiles`.

**When a patch overlaps the chart values** (D82). Some fields of a postgres document are also chart values, for example `PostgresBackupLocation` `spec.retentionPolicy.fullRetention.number` and `backup.fullRetention`, or `Postgres` `spec.resources` and `instance.resources` (the list is `workflows/params/patch-overlaps.yaml`). The document wins. When the values the chart would render differ, the plan records the warning `PATCH_OVERRIDES_VALUE` with both values, and `scripts/validate.sh` prints it for every current file, so a later change of the value (for example `backupFullRetention` in tpg-day0) is not silently overridden. A document for an object the instance does not render (a schedule without `backupSchedule=operator`, a FerretDB patch without FerretDB) is kept as current, changes nothing now, and is the warning `PATCH_TARGET_NOT_RENDERED`.

| Input | Type | Mandatory | Default | Description |
|---|---|---|---|---|
| `clusters` | `List` | yes, without `clusterMap` | | Registered clusters or `all` |
| `instances` | `List` | with an instance patch file, CA bundle source or instance kind in `clearKinds`, without `clusterMap` | | Instances or `all`, on every selected cluster |
| `clusterMap` | `Map` | no | | Targets, with the patch file keys, `patchMode`, `clearKinds` and the CA bundle keys per cluster and per instance (section 3) |
| `postgresPatchFilePath` | `List (file paths)` | one patch file input, CA bundle source or map key (`patchMode=apply`) | | Postgres patch files for every selected instance: local paths or `repo:helm_artifacts/instance/tpg-instance/patches/<file>` |
| `postgresValuesPatchFilePath` | `List (one file path)` | as above | | A values patch file for every selected instance |
| `operatorValuesPatchFilePath` | `List (one file path)` | as above | | An operator values file for every selected cluster (local, or `repo:helm_artifacts/operator/patches/<file>`) |
| `backupCaBundleFile` | `List (one file path)` | no | | The CA bundle of the selected `enableSSL` instances: a PEM file of your machine or `repo:ca-bundles/<file>` (section 15) |
| `backupCaBundleVaultSecret` | `String (name)` | no | | The CA bundle from Vault `tpg/ca-bundles/<name>`; not with `backupCaBundleFile` |
| `patchFiles` | `Map (JSON)` | with a local file | | The contents of the local files: `{"<path as given>": "<base64>"}`, written by `pack-patch-files.sh -o` or the submit script |
| `patchMode` | `Enum` | no | `apply` | `apply`: the files become the current patches. `clear`: `clearKinds` are removed |
| `clearKinds` | `List (kinds)` | with `patchMode=clear` | | `Postgres`, `PostgresBackupLocation`, `PostgresBackupSchedule`, `PostgresFerretDocumentDB`, `postgresValues`, `operatorValues`, or `all` alone |
| `pushMode` | `Enum` | yes | | `pr`: per cluster a branch and pull request, synced before a person merges it. `direct`: per cluster a commit on the fleet branch |
| `maxParallel` | `Integer` | no | `1` | Clusters per batch after the canary |
| `rolloutMode` | `Enum` | no | `canary` | `canary`, `batches` or `all` (section 2) |
| `dryRun` | `Boolean` | no | `false` | Check, render, dry-run and print the diff; commit and sync nothing |
| `timeoutSeconds` | `Integer` | no | `1800` | Per operator and per instance |
| `prTimeoutSeconds` | `Integer` | no | `3600` | `pushMode=pr`: how long each cluster's pull request may wait for the merge before the cluster is synced back |

<!-- BEGIN GENERATED: params-patch -->
<!-- written by workflows/params/params_schema.py; do not edit by hand -->

Parameter file schema: `workflows/params/schemas/params-patch.schema.json` (also `params-patch.schema.yaml`). Check a parameter file with it:

```bash
check-jsonschema --schemafile workflows/params/schemas/params-patch.schema.json <parameter file>
```

Worked example 1, `workflows/params/schemas/params-patch.example.yaml`:

```yaml
# yaml-language-server: $schema=params-patch.schema.json
# tpg-patch: A dry run: remove the schedule documents of one instance (no files to pack).
# A parameter file of the argo CLI (generated by workflows/params/params_schema.py; see
# params-patch.schema.json). Submit it with:
#   argo submit -n argo --from workflowtemplate/tpg-patch --parameter-file params-patch.example.yaml --watch
clusters: [aks-tpg-poc-01]
instances: [orders-db]
patchMode: clear
clearKinds: [PostgresBackupSchedule]
pushMode: direct
dryRun: "true"
```

<!-- END GENERATED: params-patch -->

The run, in order:

1. **Validate** (before anything is read from Git). The inputs and `clusterMap`; every local file must be in `patchFiles` and fit the input it was passed to: a Postgres manifest passed as `postgresValuesPatchFilePath` is refused with the input it belongs to, chart values passed as `postgresPatchFilePath` likewise, an unknown value or CRD field is named with the closest known key, a second document for the same object is refused, and an operator key outside the list above is refused. When `patchFiles` lacks a file, the message lists the paths `patchFiles` holds and the command that packs them. `repo:` files are checked in the next step, on the clone.
2. **Plan** (every cluster, nothing committed). On a clone of the fleet branch: the targets are rendered as they are, the `repo:` files are read and checked, the files are stored and made current (the postgres documents combined with the kinds the current file keeps), the checks that need `clusters/fleet.yaml` or the cluster run (refused fields below, smaller volumes, the operator image tag, Secrets and issuers that must exist), the targets are rendered again with helm and sent through the API server with `--dry-run=server`, and the diff is printed: objects the patch no longer renders (the sync prunes them) and `kubectl diff --server-side` of the rendered objects against the live ones. The warnings `PATCH_OVERRIDES_VALUE` and `PATCH_TARGET_NOT_RENDERED` (below) are recorded here. A render or admission error blocks the cluster (`BLOCKED` `PATCH_REFUSED`, named in the log and the report). The fields the `tpg-instances` ApplicationSet ignores (`ignoreDifferences`) take their live values first, so the diff shows what Argo CD compares. A target with no difference is `NO_CHANGE` and is not synced; a cluster with none is not planned. A values patch that changes only what the workflows read on the hub and the chart does not render (`backup.scheduled`, which takes the instance out of the backup CronWorkflows) is committed and not synced.
3. **Apply**, canary first like tpg-day0, one cluster at a time per mutex. On a fresh clone of the fleet branch the step checks, renders and diffs again, then makes one commit with the stored files, `clusters/fleet.yaml` and, for the operator, `helm_artifacts/operator/patches/clusters/<cluster>.yaml`:
   - `pushMode=pr`: on the branch `tpg/patch/<workflow>/<cluster>`, with a pull request into the fleet branch whose body carries the diff. The Applications are synced at the branch commit **before the merge** (the operator first, source 2 of its multi-source Application; then each instance, with prune) and verified: the operator pods and CRD, the instance pods until `Running`, FerretDB and the Services. Then the workflow waits for a person to merge the pull request. Merged: the Applications compare the new fleet branch head with the objects synced from the branch, which are the same, so they turn Synced without a second sync. Closed without merging, or not merged within `prTimeoutSeconds`: the cluster is reverted (below) and the targets are `FAILED` `PR_NOT_MERGED`.
   - `pushMode=direct`: the commit goes to the fleet branch and the Applications are synced at it and verified the same way.
4. **Revert** when the sync or a check fails (or `PR_NOT_MERGED`): with `pushMode=pr` the pull request is closed first, so nobody can merge it any more; then each Application is synced back (at the fleet branch head of the step when it was Synced before, otherwise at the commit it was last synced at) and the branch deleted, so its commit is gone. A pull request a person merged before the failure is undone like `pushMode=direct`: a `git revert` of the commit (of the merge) is pushed to the fleet branch and the Applications are synced at it. The revert keeps every stored patch file `clusters/fleet.yaml` still names, because clusters of one run share the stored name of a file. The targets are `FAILED` with the reason of the failure, and later batches do not run.

With a `postgresVersion` key in `clusterMap`, an instance that runs another version is `SKIPPED_VERSION_MISMATCH` and left out. When a person merges the pull request with changes of their own and an Application stays OutOfSync after the merge, the target is `FAILED` `MERGED_CONTENT_DIFFERS` and nothing is synced or reverted: compare the pull request with the fleet branch.

**Refused fields.** A field that another workflow or input owns, or that cannot change on a running instance, is refused, and the message names the workflow to use. The fields that cannot change are compared with the instance's current postgres file, so documents carried over from creation (where they are allowed) and a value sent again unchanged pass:

| Document or file | Refused |
|---|---|
| Every postgres patch document | Anything but `apiVersion: sql.tanzu.vmware.com/v1`, `kind` and `spec` (a PostgresBackupSchedule also `metadata.name`); a field the CRD of its kind does not have; a second document for the same object |
| `Postgres` | `spec.postgresVersion` (tpg-upgrade); `spec.highAvailability` (tpg-scale-instance); a `spec.storageClassName` other than the current file's, or a document that leaves out the current file's class so that another class renders (compared on the rendered object); a `storageSize` or `walStorageSize` smaller than the instance renders now (compared on the rendered object, whichever file sets it); `spec.serviceType`, `spec.serviceAnnotations`, `spec.readOnlyServiceType`, `spec.readOnlyServiceAnnotations` (set the exposure values in a values patch) |
| `PostgresBackupLocation` | `spec.storage.s3`, `gcs`, `pvc`; `spec.storage.azure.secret`; `spec.storage.azure.enableSSL` and `caBundle` (`backupCaBundleFile`, `backupCaBundleVaultSecret`); `spec.additionalParameters` and `spec.storage.azure.forcePathStyle` other than the current file's, which the `tpg-instances` ApplicationSet ignores on a running instance |
| `PostgresBackupSchedule` | A name other than `<instance>-backup-full` or `<instance>-backup-incremental`; `spec.backupTemplate.spec.sourceInstance` and `type` (set by the chart); `expire` (the retention policy of the backup location expires backups) |
| Values patch | A key the chart does not have; `instance.name`, `instance.postgresVersion` (tpg-upgrade), `instance.highAvailability` (tpg-scale-instance), `instance.storageClassName`, `instance.serviceType` (replaced by `instance.exposure`), `cluster`, `patches`, `valuesOverride` (tpg-restore); smaller sizes; `backup.additionalParameters`, `backup.enableSSL` and `backup.forcePathStyle`, which the `tpg-instances` ApplicationSet ignores on a running instance (set them when the instance is created) |
| Operator values | Every key but the eight above; `operatorImage` with another tag than the cluster's operator version (the image may move to another registry, its version changes with tpg-upgrade, which also moves the tag in the current file); a `dockerRegistrySecretName` other than `regsecret` without that Secret in `tanzu-postgres-operator`; a `certManagerClusterIssuerName` other than the default without that ClusterIssuer; a `certManagerNamespace` that does not exist |

**Switching the backup scheduler or FerretDB of a running instance** (D70, D71). A values patch may set `backup.scheduled` with `backup.operatorSchedules` (`{full: "0 0 * * 0", incremental: "0 0 * * 1-6"}`), and the `ferret` keys (`enabled`, `replicas`, `readOnlyReplicas`, `exposure`, `secretName`, `readOnlySecretName`). The chart refuses what the workflow inputs refuse (schedules while `backup.scheduled` is not `false`, FerretDB below Postgres 17.5, read-only proxies without HA), so the plan reports `PATCH_REFUSED`; FerretDB switched on is the warning `FERRET_EXTENSION_REQUIRED`. The CronWorkflows follow the values patch too: an instance whose current values patch sets `backup.scheduled: false` leaves them. The instance sync of tpg-patch prunes, so a patch that turns the schedules or FerretDB off removes those objects (the Postgres object and its backup location are `Prune=false` and stay).

```yaml
# ./orders-operator-backups.yaml, on your machine
backup:
  scheduled: false
  operatorSchedules: {full: "0 0 * * 0", incremental: "0 0 * * 1-6"}
```

**Changing the exposure of a running instance.** A values patch may set `instance.exposure`, `instance.readOnlyExposure`, `instance.serviceAnnotations`, `instance.readOnlyServiceAnnotations`, `instance.allowedSourceRanges` and `instance.internalLoadBalancerSubnet`, for example `instance: {exposure: internalLoadBalancer}`. After the sync the workflow waits until the Services match (`EXPOSURE_NOT_APPLIED` after 5 minutes); `loadBalancer` without `allowedSourceRanges` is the warning `EXPOSURE_UNRESTRICTED`. The network policy is changed with tpg-network-policy, not with a patch.

```yaml
# ./orders/postgres.yaml, on your machine: two documents, one file
apiVersion: sql.tanzu.vmware.com/v1
kind: Postgres
spec:
  resources:
    data:
      limits: {memory: 8Gi}
      requests: {memory: 8Gi}
---
apiVersion: sql.tanzu.vmware.com/v1
kind: PostgresBackupLocation
spec:
  retentionPolicy:
    fullRetention: {number: 8, type: count}
```

```bash
# Run from the directory that holds the patch files.
PACK=~/src/tpg-fleet/scripts/submit/pack-patch-files.sh   # the helper of your tpg-fleet clone

# 1. Dry run: the two documents above for orders-db on every cluster (prints the diff per cluster)
cat > orders.yaml <<'YAML'
clusters: all
instances: [orders-db]
postgresPatchFilePath: [./orders/postgres.yaml]
pushMode: pr
YAML
$PACK -o orders.yaml
argo submit -n argo --from workflowtemplate/tpg-patch --parameter-file orders.yaml -p dryRun=true --watch

# 2. Apply it through pull requests, canary first, then two clusters at a time;
#    merge each cluster's pull request when the workflow waits for it
argo submit -n argo --from workflowtemplate/tpg-patch --parameter-file orders.yaml -p maxParallel=2 --watch

# 3. A schedule patch kept in the fleet repository, for two instances (nothing to pack)
argo submit -n argo --from workflowtemplate/tpg-patch \
  -p 'clusters=[aks-tpg-poc-02]' -p 'instances=[orders-db, billing-db]' \
  -p 'postgresPatchFilePath=[repo:helm_artifacts/instance/tpg-instance/patches/team-weekly-full-backup.yaml]' \
  -p pushMode=direct --watch

# 4. Operator resources on two clusters, from a file in your home directory
cat > operator.yaml <<'YAML'
clusters: [aks-tpg-poc-01, aks-tpg-poc-02]
operatorValuesPatchFilePath: [~/patches/operator-resources.yaml]
pushMode: pr
YAML
$PACK -o operator.yaml
argo submit -n argo --from workflowtemplate/tpg-patch --parameter-file operator.yaml --watch

# 5. Remove the schedule documents and the values file of orders-db (no files, no patchFiles)
argo submit -n argo --from workflowtemplate/tpg-patch \
  -p 'clusters=[aks-tpg-poc-02]' -p 'instances=[orders-db]' -p patchMode=clear \
  -p 'clearKinds=[PostgresBackupSchedule, postgresValues]' -p pushMode=direct --watch

# 6. A new CA bundle for the HTTPS instance orders-db, read from Vault (section 15);
#    an instance without backup.enableSSL true is refused, so name the HTTPS instances
argo submit -n argo --from workflowtemplate/tpg-patch \
  -p clusters=all -p 'instances=[orders-db]' -p backupCaBundleVaultSecret=azure-storage-2027 \
  -p pushMode=pr --watch
```

```yaml
# ./operator-resources.yaml, on your machine
resources:
  limits: {cpu: 500m, memory: 300Mi}
  requests: {cpu: 500m, memory: 300Mi}
enableSecurityContext: true
```

**Worked examples** (Round 23). They use the patch files shown above. Example 1 is the generated file in the block after the input table: a dry run that clears the schedule documents of one instance with flat inputs (no files to pack). It prints the diff and changes nothing. From your tpg-fleet clone:

```bash
argo submit -n argo --from workflowtemplate/tpg-patch \
  --parameter-file workflows/params/schemas/params-patch.example.yaml --watch
```

For a real run, copy the file and change `dryRun: "true"` to `dryRun: "false"`. An input that the file sets cannot be changed with `-p` (section 2, Parameter files).

Example 2 patches different files per cluster and instance, with `clusterMap`, for several clusters from one parameter file. The local files are packed into it first:

```yaml
# patch-map.yaml
pushMode: pr
clusterMap: |
  aks-tpg-poc-01:
    operatorValuesPatchFilePath: [./operator-resources.yaml]
    instances:
      orders-db:
        postgresPatchFilePath: [./orders/postgres.yaml, ../shared/backup-schedule.yaml]
        postgresVersion: postgres-17.6          # guard: skipped when it runs another version
  aks-tpg-poc-02:
    instances:
      orders-db:
        postgresValuesPatchFilePath: [~/patches/backup-retention.yaml]
      billing-db:
        postgresPatchFilePath: [repo:helm_artifacts/instance/tpg-instance/patches/team-billing-postgres.yaml]
  aks-tpg-poc-03:
    patchMode: clear
    clearKinds: [operatorValues]                # this cluster: remove the operator file
```

```bash
$PACK -o patch-map.yaml                         # reads every local path above, adds patchFiles
argo submit -n argo --from workflowtemplate/tpg-patch --parameter-file patch-map.yaml -p dryRun=true --watch
argo submit -n argo --from workflowtemplate/tpg-patch --parameter-file patch-map.yaml --watch
```

---

## 8. tpg-scale-instance

Sets the read replica count of the selected instances in `clusters/fleet.yaml` (one commit for the run), then syncs and verifies each instance, cluster by cluster as `rolloutMode` says. It also changes `maxReadReplicas`, the cap on read replicas of a cluster, with a scale or alone (Round 14, D80). On an instance that tpg-restore restored (`instance.restored`, section 16) the `instance.highAvailability` the scale writes differs from the restore-patch's, so the chart renders it over the restore-patch.

| Input | Type | Mandatory | Default | Description |
|---|---|---|---|---|
| `clusters` | `List` | yes, without `clusterMap` | | Registered clusters (`all` is not accepted) |
| `instances` | `List` | with `replicas`, without `clusterMap` | | Instances to scale on every listed cluster (`all` is not accepted). Each instance must be declared on each listed cluster. Leave it empty to change only `maxReadReplicas` |
| `clusterMap` | `Map` | no | | `maxReadReplicas` per cluster, `replicas` and `enableHAIfNeeded` per instance (section 3; examples below) |
| `replicas` | `Integer` | with `instances` (input or map key) | | Read replicas, 1 to `maxReadReplicas`; `0` makes the instance a single node (high availability off) |
| `maxReadReplicas` | `Integer` | no | | The new cap for every selected cluster (`clusters.<cluster>.cluster.maxReadReplicas`, default 3), 1 or more; empty keeps it. It bounds the `replicas` of the same run. A cap below the read replicas an instance of the cluster has, or gets in this run, is refused in the validate step (`MAX_BELOW_CURRENT`) |
| `pushMode` | `Enum` | yes | | `direct` or `pr` |
| `enableHAIfNeeded` | `Boolean` | no | `true` | `replicas > 0` on an instance without HA: turn HA on (`true`), or refuse it (`false`): the validate step reads `clusters/fleet.yaml` and fails before any change for every single-node instance that would get `replicas` above 0 (`HA_DISABLED`) |
| `rolloutMode` | `Enum` | no | `all` | `all`: every cluster at once. `canary`: one wave-0 cluster first, then batches of `maxParallel`. `batches`: batches of `maxParallel`, no canary. A failed batch stops the later ones |
| `maxParallel` | `Integer` | no | `2` | Clusters per batch for `canary` and `batches` |
| `dryRun` | `Boolean` | no | `false` | Record the change only |
| `timeoutSeconds`, `prTimeoutSeconds` | `Integer` | no | `900`, `3600` | Per instance, pull request |

<!-- BEGIN GENERATED: params-scale-instance -->
<!-- written by workflows/params/params_schema.py; do not edit by hand -->

Parameter file schema: `workflows/params/schemas/params-scale-instance.schema.json` (also `params-scale-instance.schema.yaml`). Check a parameter file with it:

```bash
check-jsonschema --schemafile workflows/params/schemas/params-scale-instance.schema.json <parameter file>
```

Worked example 1, `workflows/params/schemas/params-scale-instance.example.yaml`:

```yaml
# yaml-language-server: $schema=params-scale-instance.schema.json
# tpg-scale-instance: A dry run: scale one instance to 2 read replicas.
# A parameter file of the argo CLI (generated by workflows/params/params_schema.py; see
# params-scale-instance.schema.json). Submit it with:
#   argo submit -n argo --from workflowtemplate/tpg-scale-instance --parameter-file params-scale-instance.example.yaml --watch
clusters: [aks-tpg-poc-01]
instances: [orders-db]
replicas: "2"
pushMode: direct
dryRun: "true"
```

<!-- END GENERATED: params-scale-instance -->

An instance that is not declared on one of the listed clusters fails the run with `UNKNOWN_INSTANCE` before anything changes. `replicas=0` scales the instance down to a single node, as the 4.5 documentation does: `clusters/fleet.yaml` gets `enabled: false` and `readReplicas: 0`, and the chart renders no `highAvailability` block (design decision D72). It is refused with `FERRET_READONLY_NEEDS_HA` while the instance runs read-only FerretDB proxies (set `ferret.readOnlyReplicas` to 0 with a tpg-patch values file first). The sync removes `spec.highAvailability` from the live object only when Argo CD is the only field manager of those fields; when another manager (the operator) co-owns `enabled` and it stays `true`, the step applies `enabled: false` and `readReplicas: 0` with a server-side apply as field manager `tpg-scale` and records the warning `HA_FIELD_CO_OWNED` with the managers it found. When the new count gives an instance more database pods (1 + `replicas`) than its data pool has zones, the run warns `HA_NODES_EXCEED_ZONES` (section 4) and goes on.

The plan step writes every count and cap in one commit. A cap is written after the counts: when the scale of an instance does not happen (not `Running`, for example) and the instance would be left above the new cap, the cap stays as it was (`MAX_BELOW_CURRENT` on `result.<cluster>.maxReadReplicas`). A run that only changes caps syncs nothing, because the cap is read by the workflows, not by the cluster. When a batch fails, the later batches do not run; the exit handler then gives every instance the rollout did not reach its previous `highAvailability` back in `clusters/fleet.yaml` (one commit) and records it `NOT_RUN`, so no later sync scales it unasked. Instances that ran keep what they got, as their result says.

Then the rollout: the clusters with an instance to sync are put into batches by `rolloutMode` and `maxParallel` (as in tpg-day0, section 2); within a batch every instance of its clusters runs in parallel, one run at a time per instance. Each instance Application is synced at the pushed commit and waited on until the Postgres resource is `Running`; after a 30-second settle (logged) the workflow checks the pods and StatefulSets with the pod watch.

**Worked examples** (Round 23). Example 1 is the generated file above: a dry run that scales one instance to 2 read replicas with flat inputs; the run records the change only. From your tpg-fleet clone:

```bash
argo submit -n argo --from workflowtemplate/tpg-scale-instance \
  --parameter-file workflows/params/schemas/params-scale-instance.example.yaml --watch
```

For a real run, copy the file and change `dryRun: "true"` to `dryRun: "false"`. An input that the file sets cannot be changed with `-p` (section 2, Parameter files).

Example 2 sets different counts per cluster and instance, with `clusterMap` (and the new cap of the first cluster):

```yaml
# scale-map.yaml
pushMode: pr
rolloutMode: batches
maxParallel: "2"
clusterMap: |
  aks-tpg-poc-01:
    maxReadReplicas: 4                   # the new cap of this cluster
    instances:
      orders-db: {replicas: 3}
      billing-db: {replicas: 0}          # single node
  aks-tpg-poc-02:
    instances:
      orders-db: {replicas: 2, postgresVersion: postgres-17.6}   # guard: skipped when it runs another version
      reporting-db: {replicas: 1, enableHAIfNeeded: false}      # refused if reporting-db is a single node
  aks-tpg-poc-03:
    maxReadReplicas: 2                   # cap only: no instance of this cluster is synced
```

```bash
argo submit --from workflowtemplate/tpg-scale-instance --parameter-file scale-map.yaml -p dryRun=true --watch
argo submit --from workflowtemplate/tpg-scale-instance --parameter-file scale-map.yaml --watch
```

**More commands.**

```bash
# 1. Scale out to 2 read replicas
argo submit --from workflowtemplate/tpg-scale-instance \
  -p 'clusters=[aks-tpg-poc-02]' -p 'instances=[orders-db]' -p replicas=2 -p pushMode=direct --watch

# 2. Dry run of scaling two instances on two clusters to 3
argo submit --from workflowtemplate/tpg-scale-instance \
  -p 'clusters=[aks-tpg-poc-01, aks-tpg-poc-02]' -p 'instances=[orders-db, billing-db]' \
  -p replicas=3 -p pushMode=direct -p dryRun=true --watch

# 3. Scale down to a single node (high availability off) through a pull request
argo submit --from workflowtemplate/tpg-scale-instance \
  -p 'clusters=[aks-tpg-poc-01]' -p 'instances=[orders-db]' -p replicas=0 -p pushMode=pr --watch

# 4. Refuse to turn HA on for a single-node instance
argo submit --from workflowtemplate/tpg-scale-instance \
  -p 'clusters=[aks-tpg-poc-04]' -p 'instances=[reporting-db]' -p replicas=1 \
  -p enableHAIfNeeded=false -p pushMode=direct --watch

# 5. Raise the cap to 5 on two clusters and scale orders-db to 4, canary first
argo submit --from workflowtemplate/tpg-scale-instance \
  -p 'clusters=[aks-tpg-poc-01, aks-tpg-poc-02]' -p 'instances=[orders-db]' -p replicas=4 \
  -p maxReadReplicas=5 -p rolloutMode=canary -p maxParallel=1 -p pushMode=direct --watch

# 6. Only the cap (no instances, nothing synced)
argo submit --from workflowtemplate/tpg-scale-instance \
  -p 'clusters=[aks-tpg-poc-03]' -p maxReadReplicas=2 -p pushMode=direct --watch

# replicas as the default of every map instance that has no replicas key
argo submit --from workflowtemplate/tpg-scale-instance -p pushMode=direct -p replicas=2 \
  -p clusterMap='{"aks-tpg-poc-01":{"instances":{"orders-db":{},"billing-db":{"replicas":1}}}}' --watch
```

---

## 9. tpg-network-policy

Creates, changes or removes the network policy of Postgres instances. The rules are written to `clusters/fleet.yaml` (`clusters.<c>.instances.<i>.network`) and rendered by the tpg-instance chart, so Argo CD owns the two objects in the namespace of the instance (`instance.namespace`, default `pg-<instance>`) like the rest of the instance. Both are named after the instance and select its pods by the label `postgres-instance=<instance>` (Round 23; before, one pair `tpg-ingress` and `tpg-egress` covered every pod of the namespace), so instances that share a namespace each have their own pair:

- **NetworkPolicy `tpg-ingress-<instance>`** (the pods of the instance): selecting the pods makes ingress default deny.
- **CiliumNetworkPolicy `tpg-egress-<instance>`** (the endpoints of the instance): an egress section makes egress default deny. AKS runs Azure CNI powered by Cilium (Terraform `network_policy = "cilium"`), which enforces both kinds and adds up their allow rules.
- With FerretDB (`ferret=true`) a second pair covers the FerretDB pods, which do not carry the `postgres-instance` label: **NetworkPolicy `tpg-ingress-ferretdb-<instance>`** (the pods of the namespace, the operator namespace, port 27017 from the client rules) and **CiliumNetworkPolicy `tpg-egress-ferretdb-<instance>`** (the egress rules of `tpg-egress-<instance>`), selecting `app in (ferretdb-rw-<instance>, ferretdb-ro-<instance>)`.

Lab item: the policies select pods by labels the chart does not write itself, the operator does. The Postgres pods are assumed to carry `postgres-instance=<instance>` (the monitoring PodMonitor, the workflows' pod watches and these policies rely on it) and the FerretDB pods `app=ferretdb-rw-<instance>` or `ferretdb-ro-<instance>`; confirm both in the lab with `kubectl -n <namespace> get pods --show-labels` before relying on the policies, because a selector that matches no pod leaves those pods without the deny and without the rules.

**Upgrade note** (Round 23; before it one pair `tpg-ingress` and `tpg-egress` covered every pod of the namespace). Round 23 is for fresh deployments: there is no migration step. A lab that ran an earlier version keeps the two old objects until a sync with prune removes them (tpg-day0, tpg-patch, or tpg-network-policy `mode=remove`) or until you delete them by hand (`kubectl -n <namespace> delete networkpolicy tpg-ingress` and `kubectl -n <namespace> delete ciliumnetworkpolicy tpg-egress`); while they exist, the old and the new policies both apply. A fresh deployment never has them.

`networkPolicy=baseline` on tpg-day0 and tpg-create-instance sets the same policy when an instance is created.

| Direction | Allowed by the baseline | Added by the inputs |
|---|---|---|
| Ingress | The pods of the namespace (replication, Patroni REST API, pgBackRest, FerretDB to Postgres); the operator namespace; port 9187 (metrics) from `monitoring` and `kube-system`; the Azure load balancer health probe address `168.63.129.16/32` when a Service is a load balancer | Port 5432 from `ingressFromNamespaces`, `ingressFromPodLabels` (in those namespaces, or in any namespace when no namespace is given) and `ingressFromCidrs`; with FerretDB (D71), port 27017 from the same clients, plus the probe address when `ferretExposure` is a load balancer |
| Egress | The namespace and the operator namespace; DNS (kube-dns, AKS LocalDNS `169.254.10.0/24` and the node, UDP and TCP 53); the Kubernetes API server (Patroni keeps its leader lock there); Azure Blob for pgBackRest: `*.blob.core.windows.net` on 443 with ACNS, otherwise any address on 443 (and 80 while `enableSSL` is `false`) | `egressToCidrs`; `egressToFqdns` (needs ACNS) |

A rule is rendered only for a non-empty input, and no peer list is ever empty: an empty list in a NetworkPolicy peer allows every source.

| Input | Type | Mandatory | Default | Description |
|---|---|---|---|---|
| `clusters` | `List` | yes, without `clusterMap` | | Registered clusters (`all` is not accepted) |
| `instances` | `List` | yes, without `clusterMap` | | Instances on every listed cluster; each must be declared there and exist |
| `clusterMap` | `Map` | no | | Rules per instance (section 3); a `postgresVersion` key is a guard |
| `mode` | `Enum` | yes | | `apply`: the baseline policy with exactly the rules given (a rule that is not given is removed). `update`: only the rules given change, the others stay. `remove`: delete both policies (no rules may be given) |
| `pushMode` | `Enum` | yes | | `direct` or `pr` |
| `ingressFromNamespaces` | `List` | no | | Namespaces whose pods may connect on 5432 |
| `ingressFromPodLabels` | `Map` | no | | Pod labels allowed on 5432, in `ingressFromNamespaces` or in any namespace |
| `ingressFromCidrs`, `egressToCidrs` | `List (CIDRs)` | no | | Client ranges allowed on 5432 (clients through a load balancer); extra ranges the pods may reach |
| `egressToFqdns` | `List (host names)` | no | | Host names the pods may reach (`toFQDNs`); needs ACNS |
| `connectivityCheck` | `Boolean` | no | `true` | After the sync, check WAL archiving and client access (below) |
| `maxParallel` | `Integer` | no | `2` | Clusters per batch after the canary |
| `rolloutMode` | `Enum` | no | `canary` | `canary`, `batches` or `all` (section 2) |
| `dryRun` | `Boolean` | no | `false` | Plan and dry-run the policies on each cluster; push and sync nothing |
| `timeoutSeconds`, `prTimeoutSeconds` | `Integer` | no | `900`, `3600` | Per cluster, pull request |

<!-- BEGIN GENERATED: params-network-policy -->
<!-- written by workflows/params/params_schema.py; do not edit by hand -->

Parameter file schema: `workflows/params/schemas/params-network-policy.schema.json` (also `params-network-policy.schema.yaml`). Check a parameter file with it:

```bash
check-jsonschema --schemafile workflows/params/schemas/params-network-policy.schema.json <parameter file>
```

Worked example 1, `workflows/params/schemas/params-network-policy.example.yaml`:

```yaml
# yaml-language-server: $schema=params-network-policy.schema.json
# tpg-network-policy: A dry run: the baseline policy for one instance, clients from the namespace orders-app.
# A parameter file of the argo CLI (generated by workflows/params/params_schema.py; see
# params-network-policy.schema.json). Submit it with:
#   argo submit -n argo --from workflowtemplate/tpg-network-policy --parameter-file params-network-policy.example.yaml --watch
clusters: [aks-tpg-poc-01]
instances: [orders-db]
mode: apply
ingressFromNamespaces: [orders-app]
pushMode: direct
dryRun: "true"
```

<!-- END GENERATED: params-network-policy -->

The run, in order:

1. **Validate** the inputs and `clusterMap`.
2. **Plan.** The rules of each instance (map keys over the inputs) are written to `fleet.yaml`, the two policies are rendered and applied to the instance namespace with `--dry-run=server`. A cluster without CiliumNetworkPolicy (`CILIUM_NOT_AVAILABLE`) or whose dry run fails (`DRY_RUN_REJECTED`, `RENDER_FAILED`) is `BLOCKED` and not written. An instance with `egressToFqdns` on clusters without ACNS fails (`ACNS_NOT_ENABLED`); one that does not exist fails (`INSTANCE_NOT_FOUND`). One commit.
3. **Apply**, canary first, one cluster at a time per mutex: each instance Application is synced at the pushed commit (with prune for `mode=remove`), then:
   - both objects exist, or both are gone for `remove` (`POLICY_NOT_APPLIED`, `POLICY_NOT_REMOVED`);
   - WAL archiving still reaches the backup storage: `txid_current()` (so an idle instance has a WAL segment to switch) and `pg_switch_wal()` on the primary, then `pg_stat_archiver` must show a new archived WAL within 2 minutes (`BACKUP_EGRESS_BLOCKED` when it does not, or when `failed_count` grows);
   - a probe pod in the first `ingressFromNamespaces` namespace (with the `ingressFromPodLabels` labels) must reach port 5432 (`CLIENT_BLOCKED`), and a probe pod in namespace `default` must not, unless `default` is allowed (`NOT_ISOLATED`). A probe pod that cannot run is the warning `PROBE_NOT_RUN`.
4. **Gate:** the run ends `Failed` when a cluster was `BLOCKED`, after the other clusters were applied.

Clients outside the cluster reach the database through a load balancer and are matched by `ingressFromCidrs` on their source address. Check in the lab that the client address reaches the pod unchanged before relying on it (it depends on the Service's `externalTrafficPolicy`).

**Worked examples** (Round 23). Example 1 is the generated file above: a dry run of the baseline policy for one instance, clients from the namespace `orders-app`, with flat inputs. The policies are rendered and sent to the API server with `--dry-run=server`; nothing is pushed or synced. From your tpg-fleet clone:

```bash
argo submit -n argo --from workflowtemplate/tpg-network-policy \
  --parameter-file workflows/params/schemas/params-network-policy.example.yaml --watch
```

For a real run, copy the file and change `dryRun: "true"` to `dryRun: "false"`. An input that the file sets cannot be changed with `-p` (section 2, Parameter files).

Example 2 gives different rules to the instances of several clusters, with `clusterMap`:

```yaml
# netpol-map.yaml
mode: apply
pushMode: direct
clusterMap: |
  aks-tpg-poc-01:
    instances:
      orders-db: {ingressFromNamespaces: [orders-app], egressToCidrs: [10.30.0.0/24]}
      billing-db: {ingressFromNamespaces: [billing], ingressFromPodLabels: {role: api}}
  aks-tpg-poc-02:
    instances:
      orders-db: {ingressFromNamespaces: [orders-app], ingressFromCidrs: [10.20.0.0/16]}
```

```bash
argo submit --from workflowtemplate/tpg-network-policy --parameter-file netpol-map.yaml -p dryRun=true --watch
argo submit --from workflowtemplate/tpg-network-policy --parameter-file netpol-map.yaml --watch
```

**More commands.**

```bash
# 1. Dry run: baseline policy for orders-db, clients from namespace orders-app
argo submit --from workflowtemplate/tpg-network-policy \
  -p 'clusters=[aks-tpg-poc-01]' -p 'instances=[orders-db]' -p mode=apply \
  -p 'ingressFromNamespaces=[orders-app]' -p pushMode=direct -p dryRun=true --watch

# 2. Apply it on every listed cluster, canary first
argo submit --from workflowtemplate/tpg-network-policy \
  -p 'clusters=[aks-tpg-poc-01, aks-tpg-poc-02]' -p 'instances=[orders-db]' -p mode=apply \
  -p 'ingressFromNamespaces=[orders-app]' -p ingressFromPodLabels='{app: orders-api}' -p pushMode=direct --watch

# 3. Add a client range, keep the other rules
argo submit --from workflowtemplate/tpg-network-policy \
  -p 'clusters=[aks-tpg-poc-01]' -p 'instances=[orders-db]' -p mode=update \
  -p 'ingressFromCidrs=[10.20.0.0/16]' -p pushMode=pr --watch

# 4. Remove the policy
argo submit --from workflowtemplate/tpg-network-policy \
  -p 'clusters=[aks-tpg-poc-01]' -p 'instances=[orders-db]' -p mode=remove -p pushMode=direct --watch
```

---

## 10. tpg-delete-apps

Deletes Tanzu Postgres applications per cluster: Postgres instances (`tpg-instances`) and the operator with its CRDs (`tpg-operator`). Deleting the operator removes these CRDs: `postgres`, `postgresbackups`, `postgresbackuplocations`, `postgresbackupschedules`, `postgresferretdocumentdbs`, `postgresmigrations`, `postgresrestores`, `postgresversions` and `postgresversionupgrades` (all `.sql.tanzu.vmware.com`).

The applications per cluster come from `apps` (JSON) or from `clusterMap`: the instances listed under a cluster are deleted, and `deleteOperator: true` deletes the operator after them.

| Input | Type | Mandatory | Default | Description |
|---|---|---|---|---|
| `clusters` | `List` | yes, without `clusterMap` | | Registered clusters to clean up |
| `apps` | `Map (JSON)` | yes, without `clusterMap` | | Cluster to list of `tpg-instances`, `tpg-instances:<i>` (Round 23: one element per instance, `"tpg-instances:orders-db", "tpg-instances:billing-db"`, never `tpg-instances:orders-db,billing-db`), `tpg-operator`. Every cluster in `clusters` needs an entry |
| `clusterMap` | `Map` | no | | Instances per cluster, `deleteOperator` and `force` per cluster, `finalBackup`, `purgePvcs`, `purgeNamespace` and `purgeBackups` per instance (section 3) |
| `confirm` | `List` | yes | | Repeat the cluster names (`clusters`, or the clusters of `clusterMap`) |
| `dryRun` | `Boolean` | no | `true` | `true` records the plan; `false` deletes (set `false` explicitly to delete) |
| `purgePvcs` | `Boolean` | yes (input or map key per instance) | | `true` deletes PVCs and Azure disks; `false` keeps them |
| `purgeNamespace` | `Boolean` | yes (input or map key per instance) | | `true` deletes the namespace of the instance (needs `purgePvcs=true`; refused while another instance uses it); `false` keeps it |
| `pushMode` | `Enum` | yes | | `direct` or `pr` |
| `force` | `Boolean` | no | `false` | With the operator: also delete Postgres instances not listed, and do not wait for running backups or restores |
| `forceDeleteStuckApps` | `Boolean` | no | `true` | An Application that cannot be rendered (`ComparisonError`, for example an expired Broadcom registry token: 401) stays in `Deleting` for ever. `true`: after the delete wait the condition is logged, the Argo CD finalizer is removed (nothing is rendered), the leftovers are cleaned up as usual and the result carries `FORCED: Application removed without rendering (...)`; `false`: the run fails `APPLICATION_NOT_REMOVED` |
| `finalBackup` | `Enum` | no | `true` | `true`, `false` or `required` (fail when the instance is not Running) |
| `purgeBackups` | `Boolean` | no | `false` | `true` expires every PostgresBackup of each instance while it runs and, after the instance is gone, deletes every blob left under its container and `repoPath` (irreversible; needs `finalBackup=false`; a `repoPath` another PostgresBackupLocation on any registered cluster also uses is expired only, the blobs stay and the result says so). Also a `clusterMap` key per instance |
| `timeoutSeconds`, `prTimeoutSeconds` | `Integer` | no | `1800`, `3600` | Timeouts |

<!-- BEGIN GENERATED: params-delete-apps -->
<!-- written by workflows/params/params_schema.py; do not edit by hand -->

Parameter file schema: `workflows/params/schemas/params-delete-apps.schema.json` (also `params-delete-apps.schema.yaml`). Check a parameter file with it:

```bash
check-jsonschema --schemafile workflows/params/schemas/params-delete-apps.schema.json <parameter file>
```

Worked example 1, `workflows/params/schemas/params-delete-apps.example.yaml`:

```yaml
# yaml-language-server: $schema=params-delete-apps.schema.json
# tpg-delete-apps: A dry run: the plan to remove one instance of one cluster, keeping its volumes and namespace.
# A parameter file of the argo CLI (generated by workflows/params/params_schema.py; see
# params-delete-apps.schema.json). Submit it with:
#   argo submit -n argo --from workflowtemplate/tpg-delete-apps --parameter-file params-delete-apps.example.yaml --watch
clusters: [aks-tpg-poc-01]
apps: '{"aks-tpg-poc-01": ["tpg-instances:orders-db"]}'
confirm: [aks-tpg-poc-01]
purgePvcs: "false"
purgeNamespace: "false"
pushMode: direct
dryRun: "true"
```

<!-- END GENERATED: params-delete-apps -->

Order per cluster: instances (final backup, `fleet.yaml` removal, Application removal without cascade, Postgres objects, optional PVC and namespace purge), remaining Tanzu Postgres custom resources, operator (`fleet.yaml`, Application, leftover cluster-scoped objects, namespace `tanzu-postgres-operator`), CRDs. The Azure Blob backup repository is kept unless `purgeBackups` is true. With a `postgresVersion` key in `clusterMap`, an instance that runs another version is `SKIPPED_VERSION_MISMATCH` and kept. The namespace of an instance is the one in its `clusters/fleet.yaml` entry (`namespace`, default `pg-<instance>`; the audit copy in `clusters/deleted/` when the entry is gone): the delete is done instance by instance in that namespace, and `purgeNamespace` is refused (`NAMESPACE_SHARED`) while an instance outside the run still uses it (Round 23).

**purgeBackups** (Round 23; the work is done by the per-instance step of section 11, where the failure reasons are described). For each instance the run expires every PostgresBackup while the instance runs, then, once the instance and its backup location are gone, deletes every blob under the container and `repoPath` of the location. The rules:

- It is irreversible and refused before anything changes with `finalBackup` `true` (the default) or `required`: the final backup would be deleted at once. Set `finalBackup=false` (input, or the instance's `clusterMap` key). The admission policy refuses the inputs, the `validate` step refuses the inputs and the map keys, and the instance step checks once more (`INVALID_OPTIONS`).
- An instance that does not run (its Postgres is not `Running`) cannot be asked to expire: its own repository is purged anyway, without the expire. If another PostgresBackupLocation also uses the repository, the run fails that instance with `BACKUP_EXPIRE_IMPOSSIBLE` and deletes nothing.
- A `repoPath` that another PostgresBackupLocation on any registered cluster also uses, also as a folder inside or around it (a cluster that cannot be scanned counts as sharing), keeps its blobs: the backups are expired, the result and the warning `BACKUP_REPO_SHARED` say so. While a copy of the location made by tpg-restore exists (`keepSourceLocation`), the repository counts as shared.
- The check runs per instance, at the start and again before the blobs are deleted. Two instances of one run that share one pinned `backup.repoPath` (the default path `/<namespace>/<instance>` never shares) therefore see each other only while both locations exist: the second one deletes the blobs of the pair. Do not purge such instances in one run.
- It needs the storage key in Vault (`tpg/shared/backup-storage`) and refuses a location on another storage account (`PURGE_ACCOUNT_MISMATCH`), the root of a container as `repoPath` (`PURGE_REPOPATH_REFUSED`) and a location it cannot find (`PURGE_LOCATION_UNKNOWN`).

**Worked examples** (Round 23). Example 1 is the generated file above: a dry run that plans the removal of one instance of one cluster, keeping its volumes and namespace. `dryRun` is `true` by default, so a command that names no `dryRun` plans only. From your tpg-fleet clone:

```bash
argo submit -n argo --from workflowtemplate/tpg-delete-apps \
  --parameter-file workflows/params/schemas/params-delete-apps.example.yaml --watch
```

For a real run, copy the file and change `dryRun: "true"` to `dryRun: "false"`. An input that the file sets cannot be changed with `-p` (section 2, Parameter files).

Example 2 deletes different things on two clusters, with `clusterMap`: on the first, the operator after its instances, one scratch instance with volumes, namespace and backups, and one kept as it is; on the second, a final backup that must succeed. `purgeBackups` needs `finalBackup: false` of its instance. Plan it first (the file has no `dryRun`), then run it:

```yaml
# delete-map.yaml
confirm: [aks-tpg-poc-03, aks-tpg-poc-04]
pushMode: direct
purgePvcs: "false"            # default of every instance
purgeNamespace: "false"
clusterMap: |
  aks-tpg-poc-03:
    deleteOperator: true
    force: true
    instances:
      scratch-db: {purgePvcs: true, purgeNamespace: true, finalBackup: false, purgeBackups: true}
      test-db: {}
  aks-tpg-poc-04:
    instances:
      billing-db: {finalBackup: required}
```

```bash
argo submit --from workflowtemplate/tpg-delete-apps --parameter-file delete-map.yaml --watch
argo submit --from workflowtemplate/tpg-delete-apps --parameter-file delete-map.yaml -p dryRun=false --watch
```

**More commands.**

```bash
# 1. Plan (dry run) a full clean-up of two clusters
argo submit --from workflowtemplate/tpg-delete-apps \
  -p 'clusters=[aks-tpg-poc-03, aks-tpg-poc-04]' \
  -p apps='{"aks-tpg-poc-03":["tpg-instances","tpg-operator"],"aks-tpg-poc-04":["tpg-instances","tpg-operator"]}' \
  -p 'confirm=[aks-tpg-poc-03, aks-tpg-poc-04]' \
  -p dryRun=true -p purgePvcs=false -p purgeNamespace=false -p pushMode=direct --watch

# 2. Run it: remove everything, including volumes and namespaces
argo submit --from workflowtemplate/tpg-delete-apps \
  -p 'clusters=[aks-tpg-poc-03, aks-tpg-poc-04]' \
  -p apps='{"aks-tpg-poc-03":["tpg-instances","tpg-operator"],"aks-tpg-poc-04":["tpg-instances","tpg-operator"]}' \
  -p 'confirm=[aks-tpg-poc-03, aks-tpg-poc-04]' \
  -p dryRun=false -p purgePvcs=true -p purgeNamespace=true -p pushMode=direct --watch

# 3. Different applications per cluster: one instance on 01, all instances on 02 (keep volumes)
argo submit --from workflowtemplate/tpg-delete-apps \
  -p 'clusters=[aks-tpg-poc-01, aks-tpg-poc-02]' \
  -p apps='{"aks-tpg-poc-01":["tpg-instances:billing-db"],"aks-tpg-poc-02":["tpg-instances"]}' \
  -p 'confirm=[aks-tpg-poc-01, aks-tpg-poc-02]' \
  -p dryRun=false -p purgePvcs=false -p purgeNamespace=false -p pushMode=pr --watch

# 4. Operator only, forcing removal of instances created outside Git, no final backups
argo submit --from workflowtemplate/tpg-delete-apps \
  -p 'clusters=[aks-tpg-poc-04]' -p apps='{"aks-tpg-poc-04":["tpg-operator"]}' -p 'confirm=[aks-tpg-poc-04]' \
  -p dryRun=false -p purgePvcs=true -p purgeNamespace=true -p pushMode=direct \
  -p force=true -p finalBackup=false --watch
```

With a parameter file (easier for JSON):

```yaml
# delete-lab.yaml
clusters: [aks-tpg-poc-03]
apps: '{"aks-tpg-poc-03": ["tpg-instances:scratch-db", "tpg-instances:test-db", "tpg-operator"]}'
confirm: [aks-tpg-poc-03]
dryRun: "false"
purgePvcs: "true"
purgeNamespace: "true"
pushMode: direct
```

```bash
argo submit --from workflowtemplate/tpg-delete-apps --parameter-file delete-lab.yaml --watch
```

---

## 11. tpg-delete-instance

Guarded delete of instances (the per-instance step that `tpg-delete-apps` uses). Instances are deleted one at a time.

| Input | Type | Mandatory | Default | Description |
|---|---|---|---|---|
| `clusters` | `List` | yes, without `clusterMap` | | Registered clusters (`all` is not accepted) |
| `instances` | `List` | yes, without `clusterMap` | | Instances to delete on every listed cluster. Each instance must be declared on each listed cluster |
| `clusterMap` | `Map` | no | | Instances per cluster, with `finalBackup`, `purgePvcs`, `purgeNamespace` and `purgeBackups` per instance (section 3) |
| `confirm` | `List` | yes | | Repeat the `instances` value; with `clusterMap`, repeat its cluster names |
| `forceDeleteStuckApps` | `Boolean` | no | `true` | As tpg-delete-apps: an Application stuck in `Deleting` with a `ComparisonError` is removed by clearing its Argo CD finalizer, and the result carries `FORCED:`; `false` fails `APPLICATION_NOT_REMOVED` |
| `finalBackup` | `Enum` | no | `true` | `true`, `false` or `required` (fail when the instance is not Running) |
| `purgePvcs` | `Boolean` | no | `false` | `true` deletes PVCs and Azure disks |
| `purgeNamespace` | `Boolean` | no | `false` | `true` deletes the namespace of the instance (needs `purgePvcs=true`; refused while another instance uses it) |
| `purgeBackups` | `Boolean` | no | `false` | `true` expires every PostgresBackup of the instance while it runs (step log: each expire and the operator's answer), then deletes every blob left under its container and `repoPath` once the instance and its backup location are gone (irreversible). Needs `finalBackup=false` (`true` or `required` is refused: the final backup would be deleted at once). A `repoPath` that another PostgresBackupLocation on any registered cluster also uses (also a folder inside or around it; a cluster that cannot be scanned counts as sharing) is expired only: the blobs stay, the result and a warning (`BACKUP_REPO_SHARED`) say so. What pgBackRest declines to expire is reported (`BACKUP_EXPIRE_DECLINED`), not a failure; no answer in time fails the run before anything is deleted (`BACKUP_EXPIRE_TIMEOUT`), and so does an API error on a backup (`BACKUP_EXPIRE_ERROR`). The sharing check runs at the start and again right before the blobs are deleted (a location that appeared meanwhile keeps them). A blob request that answers HTTP 429, 5xx or fails is tried 4 times (1, 2, 4 seconds apart). The container, `repoPath`, Secret name and storage account are copied into the audit copy in `clusters/deleted/`: after a failed blob delete (`BLOB_PURGE_FAILED`) run the same workflow again with `purgeBackups=true`; the instance, its entry and its location are gone, but the audit copy is enough (the discover step and `tpg-delete-apps` accept it), and the run finishes the blob purge only and says so. Needs the storage key in Vault (`tpg/shared/backup-storage`). Also a `clusterMap` key per instance |
| `pushMode` | `Enum` | no | `direct` | `direct` or `pr` |
| `timeoutSeconds`, `prTimeoutSeconds` | `Integer` | no | `1800`, `3600` | Per instance, pull request |

<!-- BEGIN GENERATED: params-delete-instance -->
<!-- written by workflows/params/params_schema.py; do not edit by hand -->

Parameter file schema: `workflows/params/schemas/params-delete-instance.schema.json` (also `params-delete-instance.schema.yaml`). Check a parameter file with it:

```bash
check-jsonschema --schemafile workflows/params/schemas/params-delete-instance.schema.json <parameter file>
```

Worked example 1, `workflows/params/schemas/params-delete-instance.example.yaml`:

```yaml
# yaml-language-server: $schema=params-delete-instance.schema.json
# tpg-delete-instance: No dryRun input. The least-impact run: one instance, a final backup, volumes and namespace kept.
# A parameter file of the argo CLI (generated by workflows/params/params_schema.py; see
# params-delete-instance.schema.json). Submit it with:
#   argo submit -n argo --from workflowtemplate/tpg-delete-instance --parameter-file params-delete-instance.example.yaml --watch
clusters: [aks-tpg-poc-01]
instances: [orders-db]
confirm: [orders-db]
finalBackup: "true"
purgePvcs: "false"
purgeNamespace: "false"
pushMode: direct
```

<!-- END GENERATED: params-delete-instance -->

An instance that is not declared on one of the listed clusters fails the run with `UNKNOWN_INSTANCE` before anything is deleted. The instance's FerretDB and its operator backup schedules (D70, D71) are deleted after the final backup and before the entry leaves `clusters/fleet.yaml`: FerretDB would lose its backend, and no scheduled backup may start during the delete. A run that stops earlier (a guard, a failed final backup) leaves both in place.

**Namespace** (Round 23). The instance is deleted in the namespace of its `clusters/fleet.yaml` entry (`namespace`, default `pg-<instance>`). `purgeNamespace` is refused (`NAMESPACE_SHARED`, nothing changes) while another instance of `clusters/fleet.yaml`, or another Postgres, uses the namespace. The owner of the shared Secrets of a namespace hands them to a remaining instance before its entry leaves Git (`HANDOVER_FAILED` reverts the flags and keeps the instance). The PVCs purged are the ones of this instance (label `postgres-instance`), not every PVC of a shared namespace.

**purgeBackups** (Round 23). The input and the `clusterMap` key of an instance (table above) do this, in this order: (1) refused before anything changes with `finalBackup` `true` or `required` (`INVALID_OPTIONS`; the admission policy and the `validate` step refuse it first); (2) while the instance runs, every PostgresBackup is expired (`spec.expire=true`, newest first; what pgBackRest declines is the warning `BACKUP_EXPIRE_DECLINED`, not a failure; no answer in time or an API error stops the run before anything is deleted, `BACKUP_EXPIRE_TIMEOUT`, `BACKUP_EXPIRE_ERROR`); (3) the instance and its backup location are deleted as usual; (4) every blob under the container and `repoPath` of the location is deleted with the storage key from Vault. An instance that is not `Running` cannot expire anything: when the repository is its own, the blobs are deleted without an expire; when another location also uses it, the instance is `FAILED` `BACKUP_EXPIRE_IMPOSSIBLE` and nothing is deleted. A `repoPath` shared with another PostgresBackupLocation on any registered cluster keeps its blobs (`BACKUP_REPO_SHARED`). The reasons `PURGE_LOCATION_UNKNOWN`, `PURGE_REPOPATH_REFUSED`, `PURGE_ACCOUNT_MISMATCH`, `PURGE_ACCOUNT_UNKNOWN` and `BLOB_PURGE_FAILED` are in the table of section 20.

**Worked examples** (Round 23). This workflow has no `dryRun`: example 1 is the generated file above, the least-impact run. It deletes one instance after a final backup and keeps its volumes and its namespace. From your tpg-fleet clone:

```bash
argo submit -n argo --from workflowtemplate/tpg-delete-instance \
  --parameter-file workflows/params/schemas/params-delete-instance.example.yaml --watch
```

Example 2 deletes different instances on two clusters with `clusterMap`; `confirm` repeats the cluster names of the map. On the first cluster the scratch instance goes with its volumes, its namespace and its backups (no final backup: `purgeBackups` needs `finalBackup: false`), on the second one the final backup must succeed:

```yaml
# delete-instance-map.yaml
confirm: [aks-tpg-poc-03, aks-tpg-poc-04]
pushMode: direct
clusterMap: |
  aks-tpg-poc-03:
    instances:
      scratch-db: {finalBackup: false, purgePvcs: true, purgeNamespace: true, purgeBackups: true}
      test-db: {}
  aks-tpg-poc-04:
    instances:
      billing-db: {finalBackup: required}
```

```bash
argo submit --from workflowtemplate/tpg-delete-instance --parameter-file delete-instance-map.yaml --watch
```

**More commands.**

```bash
# 1. Delete billing-db, keep volumes and namespace
argo submit --from workflowtemplate/tpg-delete-instance \
  -p 'clusters=[aks-tpg-poc-01]' -p 'instances=[billing-db]' -p 'confirm=[billing-db]' --watch

# 2. Require a final backup, purge volumes and namespace, through a pull request
argo submit --from workflowtemplate/tpg-delete-instance \
  -p 'clusters=[aks-tpg-poc-02]' -p 'instances=[orders-db]' -p 'confirm=[orders-db]' \
  -p finalBackup=required -p purgePvcs=true -p purgeNamespace=true -p pushMode=pr --watch

# 3. Two lab instances on two clusters
argo submit --from workflowtemplate/tpg-delete-instance \
  -p 'clusters=[aks-tpg-poc-03, aks-tpg-poc-04]' -p 'instances=[scratch-db, test-db]' \
  -p 'confirm=[scratch-db, test-db]' -p finalBackup=false --watch

# 4. Per instance settings, with clusterMap
argo submit --from workflowtemplate/tpg-delete-instance -p 'confirm=[aks-tpg-poc-01, aks-tpg-poc-02]' \
  -p clusterMap='{"aks-tpg-poc-01":{"instances":{"billing-db":{}}},"aks-tpg-poc-02":{"instances":{"scratch-db":{"purgePvcs":true,"purgeNamespace":true}}}}' --watch
```

---

## 12. tpg-helm-addons

Installs or upgrades the Helm releases on target clusters: `cert-manager`, `vault-secrets-operator`, and for the standalone monitoring option `kps` (Prometheus agent) and `tpg-ksm`. The hub releases (`vault`, `vault-secrets-operator`, `kps`) are installed by `tpg-aks-infra/scripts/run.sh --only vault` and `--only addons`. The `vault` release shows its pod table like the others; it is done when `vault-0` has started (shown as `Started`), because Vault turns Ready only after it is initialized and unsealed, which the next part of the step does.

The steps run `alpine/k8s:1.35.8`, which ships **Helm 4**. Helm 4 removed
the `-a` flag from `helm list` (it lists every release state by default), renamed `--atomic` to
`--rollback-on-failure` and `--force` to `--force-replace`, and takes a registry
domain without a path for `helm registry login`. The shared Helm helpers
(`workflows/scripts/common.sh`, the same block as `tpg-aks-infra/scripts/lib/common.sh`)
select the release states with `--deployed --failed --pending --superseded --uninstalled
--uninstalling` (`HR_LIST_ALL`), which Helm 3 and Helm 4 both accept, so the same script runs on
a workstation with either version. `tpg-fleet/tests/cli-flags` fails the build
when a removed flag comes back.

| Input | Type | Mandatory | Default | Description |
|---|---|---|---|---|
| `clusters` | `List` | yes | | Registered clusters or `all` |
| `components` | `List` | no | `auto` | `auto` (cert-manager and vso, plus monitoring when `tpg-settings monitoringOption=standalone`), or a list of `cert-manager`, `vso`, `monitoring` |
| `existingAddons` | `Enum` | no | `skip` | A release that exists with another chart version or other values: `skip` (report `SKIPPED_EXISTS`) or `upgrade` |
| `dryRun` | `Boolean` | no | `false` | `helm upgrade --install --dry-run=server` |

<!-- BEGIN GENERATED: params-helm-addons -->
<!-- written by workflows/params/params_schema.py; do not edit by hand -->

Parameter file schema: `workflows/params/schemas/params-helm-addons.schema.json` (also `params-helm-addons.schema.yaml`). Check a parameter file with it:

```bash
check-jsonschema --schemafile workflows/params/schemas/params-helm-addons.schema.json <parameter file>
```

Worked example 1, `workflows/params/schemas/params-helm-addons.example.yaml`:

```yaml
# yaml-language-server: $schema=params-helm-addons.schema.json
# tpg-helm-addons: A dry run: cert-manager on one cluster.
# A parameter file of the argo CLI (generated by workflows/params/params_schema.py; see
# params-helm-addons.schema.json). Submit it with:
#   argo submit -n argo --from workflowtemplate/tpg-helm-addons --parameter-file params-helm-addons.example.yaml --watch
clusters: [aks-tpg-poc-01]
components: [cert-manager]
dryRun: "true"
```

<!-- END GENERATED: params-helm-addons -->

Every component is classified before anything is installed, and the result is reported per release:

| Status | Meaning |
|---|---|
| `INSTALLED`, `UPGRADED` | The release was created or upgraded by this run |
| `UP_TO_DATE` | Our release, same chart version, same values |
| `SKIPPED_EXISTS` | Our release differs; rerun with `existingAddons=upgrade` to apply |
| `SKIPPED_NEWER` | The installed chart is newer than the pinned version; never downgraded |
| `REUSED_EXISTING` | A cert-manager or Vault Secrets Operator installed by someone else is recent enough and is used as it is |
| `BLOCKED` | Another installation that cannot be reused (a foreign `kps` or Vault, an operation in progress, a controller too old). The cluster is not changed |

While `helm --wait` runs, the pod watch prints the pods of the release's namespace every 5 seconds and stops the install when one cannot start (section 2).

With standalone monitoring, the target's `kps` writes to the hub gateway over https with basic auth: the step first creates the `VaultStaticSecret monitoring/tpg-remote-write` (Vault `tpg/shared/monitoring-remote-write`) and copies the Vault CA to `monitoring/tpg-remote-write-ca`. After the install, the run checks for 5 minutes (`MONITORING_FLOW_TIMEOUT`) that the hub Prometheus receives series labelled `cluster=<cluster>`; if none arrive the cluster ends `FAILED` with `MONITORING_NOT_FLOWING`, and the step log names what to check (the gateway Service, the target's Prometheus logs, the credential). With the Azure option it checks that the `ama-metrics` pods run.

**Worked examples** (Round 23). This workflow takes no `clusterMap`: the clusters and components are lists. Example 1 is the generated file above: a dry run of cert-manager on one cluster (`helm upgrade --install --dry-run=server`). From your tpg-fleet clone:

```bash
argo submit -n argo --from workflowtemplate/tpg-helm-addons \
  --parameter-file workflows/params/schemas/params-helm-addons.example.yaml --watch
```

For a real run, copy the file and change `dryRun: "true"` to `dryRun: "false"`. An input that the file sets cannot be changed with `-p` (section 2, Parameter files).

Example 2 brings the releases of several clusters up to the pinned chart versions and values (`existingAddons: upgrade`); plan it first:

```yaml
# addons-fleet.yaml
clusters: [aks-tpg-poc-01, aks-tpg-poc-02, aks-tpg-poc-03]
components: [cert-manager, vso]
existingAddons: upgrade
```

```bash
argo submit --from workflowtemplate/tpg-helm-addons --parameter-file addons-fleet.yaml -p dryRun=true --watch
argo submit --from workflowtemplate/tpg-helm-addons --parameter-file addons-fleet.yaml --watch
```

**More commands.**

```bash
# 1. Everything the cluster needs, on every cluster
argo submit --from workflowtemplate/tpg-helm-addons -p clusters=all --watch

# 2. cert-manager only on a new cluster
argo submit --from workflowtemplate/tpg-helm-addons -p 'clusters=[aks-tpg-poc-04]' -p 'components=[cert-manager]' --watch

# 3. Dry run of the monitoring agent upgrade on two clusters
argo submit --from workflowtemplate/tpg-helm-addons \
  -p 'clusters=[aks-tpg-poc-01, aks-tpg-poc-02]' -p 'components=[monitoring]' -p dryRun=true --watch

# 4. Bring existing releases up to the pinned chart versions and values
argo submit --from workflowtemplate/tpg-helm-addons -p clusters=all -p existingAddons=upgrade --watch
```

---

## 13. tpg-backup

Creates one `PostgresBackup` per selected instance and waits for it.

| Input | Type | Mandatory | Default | Description |
|---|---|---|---|---|
| `backupType` | `Enum` | no | `full` | `full` starts a new chain; `incremental` holds the changes since the previous backup (the daily schedule); `differential` holds the changes since the last full backup |
| `clusters` | `List` | no | `all` | Registered clusters or `all` |
| `instances` | `List` | no | every instance | Instances or `all`; each must be declared on at least one selected cluster |
| `clusterMap` | `Map` | no | | Instances per cluster, with `backupType` and `backupTimeoutSeconds` per instance (section 3) |
| `scheduledOnly` | `Boolean` | no | `false` | `true` (used by the CronWorkflows): skip instances with `backup.scheduled: false` |
| `backupTimeoutSeconds` | `Integer` | no | `10800` | Time to wait per backup |

<!-- BEGIN GENERATED: params-backup -->
<!-- written by workflows/params/params_schema.py; do not edit by hand -->

Parameter file schema: `workflows/params/schemas/params-backup.schema.json` (also `params-backup.schema.yaml`). Check a parameter file with it:

```bash
check-jsonschema --schemafile workflows/params/schemas/params-backup.schema.json <parameter file>
```

Worked example 1, `workflows/params/schemas/params-backup.example.yaml`:

```yaml
# yaml-language-server: $schema=params-backup.schema.json
# tpg-backup: No dryRun input. The least-impact run: a full backup of one instance.
# A parameter file of the argo CLI (generated by workflows/params/params_schema.py; see
# params-backup.schema.json). Submit it with:
#   argo submit -n argo --from workflowtemplate/tpg-backup --parameter-file params-backup.example.yaml --watch
clusters: [aks-tpg-poc-01]
instances: [orders-db]
backupType: full
```

<!-- END GENERATED: params-backup -->

The schedule is one full backup a week and an incremental one on the other days:

| CronWorkflow | Schedule (UTC) | Type |
|---|---|---|
| `tpg-backup-full` | Sunday 00:00 | full |
| `tpg-backup-incr` | Monday to Saturday 00:00 | incremental |

An instance with `backupSchedule=operator` (section 4) is not in the CronWorkflows: its PostgresBackupSchedule objects back it up on their own crons (UTC, the operator's clock). tpg-backup without `scheduledOnly` still backs it up on demand, and the retention policy of its backup location expires its backups like the others.

```bash
# The operator schedules of an instance, and the backups they created
# the namespace of docs-db is the default, pg-docs-db (Round 23: an instance may have a namespace of its own, section 3)
kubectl --context aks-tpg-poc-01 -n pg-docs-db get postgresbackupschedule
kubectl --context aks-tpg-poc-01 -n pg-docs-db get postgresbackup -o custom-columns=NAME:.metadata.name,TYPE:.spec.type,PHASE:.status.phase
```

**Retention is applied by the operator** (Round 15, design decision D84). The PostgresBackupLocation of every instance carries `spec.retentionPolicy`: `fullRetention` with `number` (`backup.fullRetention`, default 4) and `type` (`backup.fullRetentionType`: `count` keeps the newest `number` full backups, `time` keeps full backups for `number` days), and `diffRetention.number` (`backup.diffRetention`, default 6). pgBackRest expires the older backups after each backup, chain by chain: an incremental depends on the full backup and on every incremental before it, so the full backup and its incrementals expire together. Set the values per cluster or instance in `clusters/fleet.yaml` (tpg-day0 and tpg-create-instance inputs `backupFullRetention`, `backupFullRetentionType`, or a tpg-patch values file), or patch `spec.retentionPolicy` with a `PostgresBackupLocation` document (section 7). A change restarts the instances that use the backup location (operator 4.5 documentation): plan it like a maintenance. The workflow tpg-backup-retention, its CronWorkflow and the key `retentionDays` were removed in Round 15: the operator already applied the policy, so the workflow's own window was a second, conflicting rule. A differential backup depends only on its full backup; the POC uses incrementals and keeps `differential` available for a manual run.

**Worked examples** (Round 23). This workflow has no `dryRun`: example 1 is the generated file above, the least-impact run, one full backup of one instance with flat inputs. From your tpg-fleet clone:

```bash
argo submit -n argo --from workflowtemplate/tpg-backup \
  --parameter-file workflows/params/schemas/params-backup.example.yaml --watch
```

Example 2 takes different backups on several clusters with `clusterMap`: a full backup of `orders-db` and the default type (here incremental) for `billing-db` on the first cluster, a longer wait for `orders-db` on the second:

```yaml
# backup-map.yaml
backupType: incremental
clusterMap: |
  aks-tpg-poc-01:
    instances:
      orders-db: {backupType: full}
      billing-db: {}
  aks-tpg-poc-02:
    instances:
      orders-db: {backupTimeoutSeconds: 21600}
```

```bash
argo submit --from workflowtemplate/tpg-backup --parameter-file backup-map.yaml --watch
```

To expire backups, see section 14 (tpg-backup-expire).

**More commands.**

```bash
# 1. Full backup of every instance on every cluster
argo submit --from workflowtemplate/tpg-backup -p backupType=full -p clusters=all --watch

# 2. Incremental backup on one cluster
argo submit --from workflowtemplate/tpg-backup -p backupType=incremental -p 'clusters=[aks-tpg-poc-01]' --watch

# 3. Same selection as the CronWorkflows (skips backup.scheduled=false instances)
argo submit --from workflowtemplate/tpg-backup -p backupType=full -p clusters=all -p scheduledOnly=true --watch

# 4. Two instances, wherever they are declared
argo submit --from workflowtemplate/tpg-backup -p 'instances=[orders-db, billing-db]' --watch

# 5. Different instances and types per cluster
argo submit --from workflowtemplate/tpg-backup \
  -p clusterMap='{"aks-tpg-poc-01":{"instances":{"orders-db":{"backupType":"full"}}},"aks-tpg-poc-02":{"instances":{"billing-db":{"backupType":"incremental"}}}}' --watch

# Run a CronWorkflow now
argo cron list
argo submit --from cronwf/tpg-backup-full --watch
```

```bash
# What exists, per instance
kubectl --context aks-tpg-poc-01 -n pg-orders-db get postgresbackup \
  -o custom-columns=NAME:.metadata.name,TYPE:.spec.type,PHASE:.status.phase,STARTED:.status.timeStarted
```

---

## 14. tpg-backup-expire

Expires PostgresBackups (Round 23). `clusterMap` is the only way to name the targets. Per instance, one of:

- `backups: [orders-db-full-202609010100, ...]`: the PostgresBackup names to expire (a list in brackets, also with one name).
- `purgeBackups: true`: every backup of the instance. The blobs of the repository are never deleted here (that is `purgeBackups` of `tpg-delete-instance` and `tpg-delete-apps`).

Not both. `includeDependents: true` (with `backups`) is required to expire a backup that has dependents: a full backup takes the differential and incremental backups of its chain with it, a differential the incrementals after it. Without it the instance is `BLOCKED` (`HAS_DEPENDENTS`) with the list of dependents, nothing is expired, and the run ends `Failed` after the other instances ran; naming every dependent in `backups` is the other way. Dependents go first, newest first. A backup is expired by `spec.expire=true` on its PostgresBackup; the operator runs pgBackRest expire and the step waits for its answer (`timeoutSeconds` per backup, every poll logged).

| Input | Type | Mandatory | Default | Description |
|---|---|---|---|---|
| `clusterMap` | `Map` | yes | | Cluster to instances to `backups` or `purgeBackups`, `includeDependents` (section 3) |
| `dryRun` | `Boolean` | no | `true` | `true` records the plan (what would be expired, dependents included, what is `BLOCKED`) and changes nothing; `false` expires |
| `confirm` | `List` | with `dryRun=false` | | The cluster names of `clusterMap`, for example `[aks-tpg-poc-01]` |
| `timeoutSeconds` | `Integer` | no | `600` | How long to wait for the operator's answer to the expire of one backup |

<!-- BEGIN GENERATED: params-backup-expire -->
<!-- written by workflows/params/params_schema.py; do not edit by hand -->

Parameter file schema: `workflows/params/schemas/params-backup-expire.schema.json` (also `params-backup-expire.schema.yaml`). Check a parameter file with it:

```bash
check-jsonschema --schemafile workflows/params/schemas/params-backup-expire.schema.json <parameter file>
```

Worked example 1, `workflows/params/schemas/params-backup-expire.example.yaml`:

```yaml
# yaml-language-server: $schema=params-backup-expire.schema.json
# tpg-backup-expire: A dry run: the plan to expire one backup with its dependents (dryRun is true by default).
# A parameter file of the argo CLI (generated by workflows/params/params_schema.py; see
# params-backup-expire.schema.json). Submit it with:
#   argo submit -n argo --from workflowtemplate/tpg-backup-expire --parameter-file params-backup-expire.example.yaml --watch
clusterMap: |
  aks-tpg-poc-01:
    instances:
      orders-db:
        backups: [orders-db-full-202609010100]
        includeDependents: true
dryRun: "true"
```

<!-- END GENERATED: params-backup-expire -->

Results per instance: `SUCCEEDED` (`DRY_RUN` for the plan; `DECLINED_SOME` when `purgeBackups` ran and pgBackRest declined some), `BLOCKED` (`HAS_DEPENDENTS`), `FAILED` (`UNKNOWN_BACKUP`, `NOT_EXPIRABLE`, `INSTANCE_NOT_RUNNING`, `OPERATION_IN_PROGRESS`, `BACKUP_EXPIRE_DECLINED`: a backup you named, or a dependent of it, was declined; the detail is the operator's message and the later backups are not attempted), `TIMEOUT`. Lab item: how the operator reports an expire, and what it does when pgBackRest refuses (for example the last full backup), is a lab item of Round 23 (verify it on the lab cluster). Two points of the guess: (1) an object the operator keeps after an expire (phase `Expired` or `Expiring`, or any PostgresBackup with `spec.expire=true`) is not an unfinished operation, so it never makes a later backup, restore, scale or delete fail with `OPERATION_IN_PROGRESS`; (2) only conditions written after this run's patch count as the answer: with `observedGeneration`, it must be at least `metadata.generation`; without it, `lastTransitionTime` must not be older than the patch (less 2 minutes for clock skew), and with neither field the condition counts only when this run set `spec.expire`. So on a re-run where `spec.expire` is already `true` an old `Expired=False` is not read as a refusal; without a fresh signal the step waits and times out like for any expire (`TIMEOUT`). Both depend on how the operator really writes status; confirm them together with the rest of this item.

**Worked examples** (Round 23). Example 1 is the generated file above: the plan to expire one full backup with its dependents (`dryRun` is `true` by default; nothing is expired). From your tpg-fleet clone:

```bash
argo submit -n argo --from workflowtemplate/tpg-backup-expire \
  --parameter-file workflows/params/schemas/params-backup-expire.example.yaml --watch
```

For a real run, copy the file and change `dryRun: "true"` to `dryRun: "false"` and add `confirm: [aks-tpg-poc-01]` (the cluster names of the map). An input that the file sets cannot be changed with `-p` (section 2, Parameter files).

Example 2 expires on two clusters: the named full backup with its chain on the first, every backup of `billing-db` on the second (the blobs stay; deleting them is `purgeBackups` of the delete workflows). Plan it, then run it:

```yaml
# expire-map.yaml
clusterMap: |
  aks-tpg-poc-01:
    instances:
      orders-db:
        backups: [orders-db-full-202609010100]
        includeDependents: true
  aks-tpg-poc-02:
    instances:
      billing-db: {purgeBackups: true}
```

```bash
argo submit --from workflowtemplate/tpg-backup-expire --parameter-file expire-map.yaml --watch
argo submit --from workflowtemplate/tpg-backup-expire --parameter-file expire-map.yaml \
  -p dryRun=false -p 'confirm=[aks-tpg-poc-01, aks-tpg-poc-02]' --watch
```

**More commands.**

```bash
# 1. Plan: the full backup with its chain
argo submit --from workflowtemplate/tpg-backup-expire \
  -p clusterMap='{"aks-tpg-poc-01":{"instances":{"orders-db":{"backups":["orders-db-full-202609010100"],"includeDependents":true}}}}' --watch

# 2. Run it
argo submit --from workflowtemplate/tpg-backup-expire -p dryRun=false -p 'confirm=[aks-tpg-poc-01]' \
  -p clusterMap='{"aks-tpg-poc-01":{"instances":{"orders-db":{"backups":["orders-db-full-202609010100"],"includeDependents":true}}}}' --watch
```

---

## 15. CA bundles and new credential values in Vault

**The backup CA bundle** (Round 15, design decision D86). An instance with `backup.enableSSL: true` verifies the storage account's certificate with the PEM bundle in its PostgresBackupLocation `spec.storage.azure.caBundle`. The workflows write it from one of three sources, the most specific first:

1. `backupCaBundleFile` or `backupCaBundleVaultSecret` of the instance (`clusterMap` key);
2. the same keys of its cluster;
3. the inputs `backupCaBundleFile` or `backupCaBundleVaultSecret` of the run;
4. otherwise ConfigMap `argo/tpg-settings` `backupCaBundle` (written by `tpg-aks-infra/scripts/run.sh` from the Terraform output `backup_storage_ca_bundle`).

A file and a Vault secret on the same level are refused. `backupCaBundleFile` is a PEM file (`.pem`, `.crt` or `.cer`) of the machine that submits the run (packed into `patchFiles`, section 7) or `repo:ca-bundles/<file>` in the fleet repository (`ca-bundles/README.md`). `backupCaBundleVaultSecret=<name>` reads Vault `tpg/ca-bundles/<name>`, key `caBundle` (the workflows' Vault policy `tpg-workflow` may read `tpg/data/ca-bundles/*`). Every bundle is checked before it is written: at least one certificate, none expired. The bundle is written into `clusters/fleet.yaml` (`backup.caBundle`), so a later change in Vault or in the file changes no instance until tpg-patch writes it. tpg-day0 and tpg-create-instance take the sources for new instances, tpg-patch replaces the bundle of running instances; a source for an instance without `backupEnableSSL=true` is refused.

**Named bundles in Vault** are kept with `tpg-aks-infra/scripts/vault-secret.sh`, which talks to Vault through `kubectl exec` into `vault/vault-0` on the hub (the default; no Vault CLI or network path needed) or over HTTPS with `--vault-addr` (the `vault-ui` or `vault-fleet` load balancer, with the Vault CA). It logs in with `VAULT_TOKEN` when exported, otherwise as the Kubernetes auth role `tpg-setup` (kubectl exec) or the userpass account `tpg-admin` (`--vault-addr`; password `VAULT_UI_PASSWORD` or a hidden prompt; `scripts/access.sh` prints it):

```bash
cd ~/src/tpg-aks-infra
# the Azure root CAs from Terraform, as bundle azure-storage
terraform -chdir=terraform output -raw backup_storage_ca_bundle | scripts/vault-secret.sh ca put azure-storage -
scripts/vault-secret.sh ca put azure-storage-2027 ~/certs/azure-storage-2027.pem
scripts/vault-secret.sh ca list
scripts/vault-secret.sh ca get azure-storage | openssl x509 -noout -subject -enddate
scripts/vault-secret.sh --vault-addr https://<vault-ui IP>:8200 --vault-ca-file .work/vault-ca.crt ca list
scripts/vault-secret.sh --yes ca delete azure-storage-2025
```

`tpg-rotate-credential` with `secretType=ca-bundle` writes a named bundle as well, from a PEM file (`caBundleFile`) or a wrapping token (section 17).

**New credential values: wrapping tokens** (design decision D87). A new password or token must never travel as a workflow input: inputs are stored in the Workflow object and shown in the Argo UI. `scripts/vault-secret.sh wrap <secretType> [<name> [<key>...]]` reads the new value from the shell environment (exported variables) or a hidden prompt, sends it to Vault `sys/wrapping/wrap`, and prints only a wrapping token: a reference to the value, valid for 10 minutes and for one read. The value itself is never in a command-line argument or a file:

| `secretType` | The value, from | Written to |
|---|---|---|
| `broadcom-registry` | `BROADCOM_USER`, `BROADCOM_TOKEN` | `tpg/shared/broadcom-registry` (`username`, `password`) |
| `git-read`, `git-push` | `GITHUB_USER`, `GIT_READ_PAT` or `GIT_PUSH_PAT` | `tpg/shared/github-read`, `tpg/shared/github-push` (`username`, `token`) |
| `backup-storage` | the inventory's `backup.storageAccount` (or `BACKUP_STORAGE_ACCOUNT`), `BACKUP_STORAGE_KEY` | `tpg/shared/backup-storage` (`accountName`, `accountKey`) |
| `monitoring-remote-write` | `REMOTE_WRITE_PASSWORD` (16 characters or more) | `tpg/shared/monitoring-remote-write` (`username` `tpg-remote-write`, `password`) |
| `ca-bundle <name> <file>` | the PEM file | `tpg/ca-bundles/<name>` (`caBundle`) |
| `custom <name> <key>...` | one hidden prompt per key | `tpg/custom/<name>` |

```bash
cd ~/src/tpg-aks-infra
read -rs GIT_PUSH_PAT && export GIT_PUSH_PAT        # typed, not echoed, not in the shell history
export GITHUB_USER=tpg-bot
T="$(scripts/vault-secret.sh wrap git-push)"
argo submit -n argo --from workflowtemplate/tpg-rotate-credential -p secretType=git-push -p wrappingToken="$T" --watch
unset GIT_PUSH_PAT T
```

The workflow unwraps the token once. Whoever unwraps it first gets the value, and the token is then void: a run that finds it used or expired fails with `WRAPPING_TOKEN_INVALID` and writes nothing, which also shows that someone else read it. Wrap again and resubmit within 10 minutes.

---

## 16. tpg-restore

Restores Postgres instances from a list of pairs (Round 23; the flat inputs of earlier versions, `sourceCluster`, `instance`, `mode`, `targetTime`, `backupName`, `lsn`, `xid`, `targetCluster`, `targetInstance`, `confirm` and `bestEffort`, are gone, and the admission policy refuses them as unknown inputs). Each pair is one restore: `sourceClusterConfig` names the instance to restore from and `targetClusterConfig` the instance to restore into, each as `<cluster>: <namespace>: <instance>: {keys}` with exactly one cluster, one namespace and one instance (namespaces are mandatory). The recovery point is a named backup (`pitrEnabled: false`, the default when `pitrEnabled` is absent) or point-in-time recovery (`pitrEnabled: true`, `pitrConfig.type` `latest`, `time`, `lsn` or `transaction`). The pairs are independent of each other: a failed pair does not stop the others, and the run ends `Failed` when any pair failed, timed out or was blocked. A target is restored once per run and cannot be the source of another pair of the run. This section describes the three methods, the keys of a pair and how they become the PostgresRestore, the version matrix, what the workflow does for each pair, every reason it records, the restore-patch that keeps Argo CD from undoing the restore, `dryRun`, the submit script and two worked examples.

| Input | Type | Mandatory | Default | Description |
|---|---|---|---|---|
| `clusterMap` | `List (pairs)` | yes | | The pairs (Keys of a pair, below). A map of clusters is refused |
| `dryRun` | `Boolean` | no | `true` | `true`: each pair records its plan (source resolution, matrix, the PostgresRestore that would be created, preparation of the target) and nothing changes; `false`: restore |
| `rolloutMode` | `Enum` | no | `all` | `all`: every pair at once; `batches`: `maxParallel` pairs at a time, in list order; `canary`: the first pair alone, a failed canary stops the run, then batches. The pairs are independent: a failed pair does not stop the others, and the run ends Failed when any pair failed |
| `maxParallel` | `Integer` | no | `2` | Pairs per batch for `canary` and `batches` |
| `pushMode` | `Enum` | no | `direct` | A new instance is added to `clusters/fleet.yaml`: `direct` pushes, `pr` opens a pull request |
| `keepSourceLocation` | `Boolean` | no | `true` | Keep the copy of the source backup location that a restore into another namespace or cluster needs; `false` removes it after a successful restore |
| `patchFiles` | `Map (JSON)` | with a local `targetInstanceSpecFilePath` | | The contents of the local spec files; `scripts/submit/pack-patch-files.sh -o <parameter file>` writes it |
| `restoreTimeoutSeconds`, `prTimeoutSeconds` | `Integer` | no | `7200`, `3600` | Timeouts: `restoreTimeoutSeconds` covers the restore phase of one pair (the wait for synced backups and for the PostgresRestore); waiting for the restored instance to run has its own timeout (1800 s) and the post-restore backup another; `prTimeoutSeconds` is the wait for a pull request (`pushMode=pr`) |

<!-- BEGIN GENERATED: params-restore -->
<!-- written by workflows/params/params_schema.py; do not edit by hand -->

Parameter file schema: `workflows/params/schemas/params-restore.schema.json` (also `params-restore.schema.yaml`). Check a parameter file with it:

```bash
check-jsonschema --schemafile workflows/params/schemas/params-restore.schema.json <parameter file>
```

Worked example 1, `workflows/params/schemas/params-restore.example.yaml`:

```yaml
# yaml-language-server: $schema=params-restore.schema.json
# tpg-restore: A dry run: one pair, a named backup restored into a new instance of the same namespace (dryRun is true by default; nothing changes).
# A parameter file of the argo CLI (generated by workflows/params/params_schema.py; see
# params-restore.schema.json). Submit it with:
#   argo submit -n argo --from workflowtemplate/tpg-restore --parameter-file params-restore.example.yaml --watch
clusterMap: |
  - sourceClusterConfig:
      aks-tpg-poc-01:
        pg-orders-db:
          orders-db:
            sourceBackupName: orders-db-full-20260914000000
    targetClusterConfig:
      aks-tpg-poc-01:
        pg-orders-db:
          orders-db-restored: {}
dryRun: "true"
```

<!-- END GENERATED: params-restore -->

### The three methods

The method follows from the two sides of the pair. A restore never goes into an instance that already exists unless it is the source itself (in place); a live Postgres of the target's name that is not the source is refused with `TARGET_EXISTS`.

| Method | The pair | What the workflow does | What it needs |
|---|---|---|---|
| 1. New cluster | The target is on another cluster than the source, in any namespace that is not reserved | Adds the target to `clusters/fleet.yaml` (a copy of the source's entry, or a skeleton built from the spec file), copies the source backup location and its Secret into the target namespace, restores, and lets Argo CD adopt the new instance | The target cluster has an entry `clusters.<cluster>` in `clusters/fleet.yaml` and a running operator (tpg-day0 first; `UNKNOWN_TARGET_CLUSTER` otherwise) |
| 2. Same cluster, another namespace, or a new instance in the source namespace | The target is on the source's cluster: in another namespace, or in the same namespace under another instance name | Same as method 1. Inside the source namespace there is nothing to copy: the backup location is the source's own, and a named backup is used where it is | A name that no live Postgres of the cluster uses (`TARGET_EXISTS`, `INSTANCE_NAME_IN_USE`) |
| 3. In place | The source and the target are the same cluster, namespace and instance | Overwrites the data of the live instance with the recovery point. Nothing is added to `clusters/fleet.yaml`; the restore-patch is recorded for an instance that has an entry | `clusters.<cluster>.cluster.allowInPlaceRestore: true` in `clusters/fleet.yaml` (default `false`, `clusters/_template/cluster.yaml`) and, for a real run, `confirm: <instance>` in the target. Either missing refuses the pair (`IN_PLACE_NOT_ALLOWED` refuses the whole run) |

Into another namespace or cluster a named backup works too: the PostgresRestore still names `sourceBackup.name`, and the operator of the target must see a PostgresBackup of that name, which it gets from the copy of the source backup location (`backupSync`). Point-in-time recovery needs no PostgresBackup of the target: it reads the repository through the copy.

### Keys of a pair and the PostgresRestore

Keys of a pair (`workflows/params/cluster-map-keys.yaml`, section `restore`; schema `workflows/params/schemas/clustermap-restore.schema.json`, example `clustermap-restore.example.yaml`):

| Side | Key | Meaning |
|---|---|---|
| source | `sourceBackupName` | The PostgresBackup to restore, in the namespace of the source instance. Mandatory when the target restores a named backup (`pitrEnabled: false` or absent), into the same namespace, another namespace or another cluster. Optional with PITR: it then only gives the backup location and the stanza when the source instance is gone |
| target | `pitrEnabled` | Default `false`. `true`: point-in-time recovery (`pitrConfig` says to where). `false` or absent: restore `sourceBackupName`, which is then mandatory (the error names both ways out: give `sourceBackupName`, or set `pitrEnabled: true` with `pitrConfig`) |
| target | `pitrConfig.type` | `latest`, `time`, `lsn` or `transaction` |
| target | `pitrConfig.timestamp`, `pitrConfig.target` | `time`: a UTC time such as `2026-09-15T08:30:00Z`; `lsn`: a log sequence number such as `0/3000060`; `transaction`: a transaction ID (a number). Mandatory for those types, refused for the others |
| target | `pitrConfig.sourceBackupConfig.srcBackupLocationName`, `srcStanzaName`, `srcBackupLabel` | The backup repository to recover from. Location and stanza are optional where they can be derived from the live source instance, or from the PostgresBackup `sourceBackupName` names (a given value that differs from what they report is a warning and wins); mandatory when there is neither (`PITR_SOURCE_UNKNOWN`). `srcBackupLabel` is a pgBackRest label such as `20260915-020000F`, the backup the recovery starts from; refused with `latest` |
| target | `bestEffort` | Mandatory for `time`, `lsn` and `transaction`; refused for `latest` and for a named-backup restore |
| target | `targetInstanceSpecFilePath` | The spec of the restored Postgres instance: one file with one `kind: Postgres` document, `[./orders-dr.yaml]` (a file of the submitting machine, packed into `patchFiles`) or `[repo:helm_artifacts/instance/tpg-instance/restore-specs/<file>]` (that folder only, `.yaml` or `.yml`, see its README; no `..`, no absolute path, no `//`; a symbolic link, or a path that resolves outside that folder, is refused with `SPEC_FILE_INVALID`). Its `spec` is the source of truth: it is `spec.targetInstance.spec` of the PostgresRestore as it is (never merged over a chart render) and is stored as the instance's restore-patch (below). Allowed for a new target and for an in-place restore (its values override the existing instance's). Optional: without it a new target copies the source's `clusters/fleet.yaml` entry (the file is mandatory when the source is not in `clusters/fleet.yaml`: `SPEC_FILE_REQUIRED`) and the PostgresRestore sends only `spec.targetInstance.name`, so the operator creates the instance and fills in its spec (**lab item**: how operator 4.5 does that is not verified) |
| target | `confirm` | The target instance name. **Only for an in-place pair**, where it is mandatory when `dryRun` is `false`. On any other pair the validate step refuses it as meaningless (`confirm: not allowed: confirm is only for an in-place restore`, also in a dry run) |
| target | `skipMinorVersionCheck`, `postRestoreBackup` | Flags, default `false`: the annotation `sql.tanzu.vmware.com/skip-minor-version-check: "true"` on the PostgresRestore (for backups taken by operator 4.2.2 or older); a full backup of the target after the restore |

How the keys become the PostgresRestore (checked against the live CRD `helm_artifacts/instance/crd-reference/source-crds/postgresrestores...yaml` by `tests/crd-reference`):

| Key of the pair | Field of the PostgresRestore |
|---|---|
| `sourceBackupName` (`pitrEnabled` false) | `spec.sourceBackup.name` |
| `pitrConfig.type` | `spec.pitr.type` |
| `pitrConfig.target` (`lsn`, `transaction`) | `spec.pitr.target` |
| `pitrConfig.timestamp` (`time`) | `spec.pitr.timestamp` |
| `bestEffort` | `spec.pitr.bestEffort` |
| `srcBackupLocationName` | `spec.pitr.sourceBackupLocation.name` (inside the source namespace; into another namespace or cluster the name of the copy, `restore-src-<source cluster>-<source namespace>-<source instance>`, or of the location that is reused instead) |
| `srcStanzaName` | `spec.pitr.sourceBackupLocation.stanzaName` |
| `srcBackupLabel` | `spec.pitr.sourceBackupLocation.set` |
| the target instance, `targetInstanceSpecFilePath` | `spec.targetInstance.name`, `spec.targetInstance.spec` (the file's spec, or absent) |
| `skipMinorVersionCheck` | the annotation `sql.tanzu.vmware.com/skip-minor-version-check: "true"` |

`spec.sourceBackup` and `spec.pitr` are never sent together. The object is named `<target instance>-restore-<yyyymmddHHMMSS>`, carries the label `tpg.fleet/workflow` and is rendered through the reference chart `helm_artifacts/instance/crd-reference`.

The validate step checks everything that needs no cluster, and names the pair and the key path of each error, for example `clusterMap[1].targetClusterConfig.aks-tpg-poc-02.pg-orders-dr.orders-db-dr.bestEffort is required with pitrConfig.type: time`: the list shape, one cluster, namespace and instance per side, registered clusters, namespaces (a DNS label; the reserved namespaces of tpg-day0 are refused for a target), the key rules above, `[repo: x.yaml]` with a space (`repo:<file path> "check for white spaces in between"`), a target that is restored twice or is the source of another pair, and a named-backup restore without `sourceBackupName`. An in-place pair needs `confirm` when `dryRun` is `false`; `confirm` on any other pair is refused. A local spec file must be in `patchFiles`. In place also needs `allowInPlaceRestore` (above): the validate step reads it from the fleet repository, and when any in-place pair is on a cluster without it the whole run is refused before any pair starts (`IN_PLACE_NOT_ALLOWED`, naming the cluster and the setting); `dryRun` does not skip this check, and a fleet repository that cannot be read refuses the run as well.

### The version matrix

Applied to each pair (that pair only is stopped, `BLOCKED`). A PostgresVersion is **lite** when its name ends in `-lite` (the pattern `liteVersion` in `workflows/params/types.yaml`). The version of the backup is, in this order, the named backup's `status.fullPostgresVersion`, the live source's `status.postgresVersion`, or the version of the source's PostgresVersion (its `dbVersion`, else read from the name).

| Source | Target | Result |
|---|---|---|
| standard | lite | `BLOCKED` `RESTORE_FLAVOUR_UNSUPPORTED` |
| lite | lite, or standard | Not stopped by the workflow |
| any | A lower version: a lower minor version of the same major, or a lower major | `BLOCKED` `RESTORE_VERSION_LOWER` |
| any | The same or a higher minor version of the same major | Allowed |
| any | A higher major version | Passed on: the operator refuses a restore across major versions itself |
| A version that is not known (not live, not in `clusters/fleet.yaml`) | any | Warning `MATRIX_UNVERIFIED`; the matrix is not checked |

`skipMinorVersionCheck` only sets the operator's annotation `sql.tanzu.vmware.com/skip-minor-version-check: "true"` on the PostgresRestore; it relaxes none of these checks. The PostgresVersion of the target must exist on the target cluster (`kubectl get postgresversion`; `VERSION_NOT_AVAILABLE`).

### What the workflow does for each pair

`workflows/scripts/restore-pair.sh` runs one pair; the validate step and `plan-batches.sh` come before it. The pairs are batched by `rolloutMode` and `maxParallel` (`canary`: the first pair alone, then batches). Pairs with the same target instance, and pairs with the same target cluster and namespace, run one after another (Argo mutexes `tpg-instance-<cluster>-<instance>` and `tpg-restore-ns-<cluster>-<namespace>`); pairs of other namespaces run in parallel up to `maxParallel`.

1. **Plan checks** (read-only; they also run in a dry run).
   - **Source.** The instance on its cluster (live or gone), its entry in `clusters/fleet.yaml` (its namespace must be the pair's: `SOURCE_NAMESPACE_MISMATCH`), its PostgresVersion and flavour, its backup location (container, `repoPath`, Secret) and stanza.
   - **Named backup.** Inside the source namespace the PostgresBackup must exist and be `Succeeded` now (`BACKUP_NOT_FOUND`, `BACKUP_NOT_SUCCEEDED`). Into another namespace or cluster the source PostgresBackup is read first and must be `Succeeded` (`SOURCE_BACKUP_UNVERIFIED` when it is missing or the cluster cannot be read, `BACKUP_NOT_SUCCEEDED`). A backup of another instance than the pair's source instance is refused (`BACKUP_OF_OTHER_INSTANCE`: a pair has one source instance).
   - **PITR.** The location and stanza are resolved (above); the recovery time is checked against the `Succeeded` full backups (`NO_FULL_BACKUP`, `INVALID_TIMESTAMP`, `OUTSIDE_RECOVERY_WINDOW`).
   - **Target.** A live Postgres of the target's name is accepted only in place (`TARGET_EXISTS`, `INSTANCE_NAME_IN_USE`). A target that is only declared in `clusters/fleet.yaml` and not deployed is a new target: its entry is replaced as a whole by the one below (the declared namespace is kept, `NAMESPACE_IMMUTABLE` otherwise; nothing else of the declared entry survives, neither `ferret`, patch files, `disableInitialBackup` nor a `sharedSecretsOwner`). A new target is a copy of the source's entry (without `disableInitialBackup`, `backup.repoPath`, `ferret`, `restorePatch`, `instance.restored` and the postgres patch and overlay files), or, when the source is not there, a skeleton built from the spec file. A new namespace must not hold a Secret `regsecret` or `backup-storage` that the fleet does not manage (`NAMESPACE_SECRET_CONFLICT`: the owner's VaultStaticSecrets would overwrite it). Who owns the shared objects of the namespace (ServiceAccount `tpg-vso`, VaultStaticSecrets `regsecret` and `backup-storage`) is decided as in tpg-day0: exactly one instance per namespace (`sharedSecretsOwner`).
   - **Matrix**, then the restore-patch plan and the PostgresRestore as YAML.
2. **Location copy and per-copy Secret** (another namespace or cluster; real run). The source backup location is copied into the target namespace as `restore-src-<source cluster>-<source namespace>-<source instance>` (`backupSync` on, retention so high that no expiry runs through it, label `tpg.fleet/restore-source`). A location there for the same container and `repoPath` with `backupSync` on is reused instead, never removed by this run; one with `backupSync` off is `SOURCE_LOCATION_CONFLICT`; a list of the target namespace's locations that cannot be read fails the pair (`TARGET_UNREADABLE`, also in a dry run: it is not taken for an empty list). The Secret `backup-storage` is the namespace's own (Vault Secrets Operator) or comes from Vault. Any other Secret is copied from the source cluster into a Secret of the copy's **own name**, `<copy name>-creds` (the copy's `spec.storage.azure.secret.name`, label `tpg.fleet/restore-source`), so the copies of different sources in one namespace never share or overwrite a Secret. A reused copy keeps the Secret it has; when its contents differ from the source's it is updated only if its label names this pair's source (`<cluster>.<instance>`), otherwise the pair fails with `SOURCE_SECRET_CONFLICT` and nothing is overwritten. The values are held in memory only, never in a file, an argument or the log.
3. **backupSync wait** (named backup into another namespace or cluster). The step waits for the PostgresBackup of the same name in the target namespace to appear `Succeeded` (`BACKUPS_NOT_SYNCED` at the timeout; `Failed` stops at once with `BACKUP_NOT_SUCCEEDED`). The wait counts against `restoreTimeoutSeconds`.
4. **Render.** The PostgresRestore is rendered through the reference chart. `dryRun` stops here (below).
5. **Apply and wait.** For a new target the entry is first pushed to `clusters/fleet.yaml` (`pushMode`; `GIT_PUSH_FAILED`; with a spec file the restore-patch is in the same commit), the namespace is created, and the Application `tpg-<cluster>-<instance>` syncs only the shared objects and the backup location of the new instance (`APP_NOT_GENERATED`, `SHARED_SECRETS_MISSING`, `SECRET_NOT_SYNCED`, `TARGET_PREPARE_FAILED`). Then the PostgresRestore is applied and waited for within `restoreTimeoutSeconds` (`RESTORE_FAILED`, `TIMEOUT`). An unfinished restore of the same target is waited for 2 minutes, then the pair is left alone (`SKIPPED_IN_PROGRESS`); an unfinished backup, restore or upgrade of an in-place target refuses the pair (`OPERATION_IN_PROGRESS`).
6. **Running.** The target must be `Running` with its pods ready (its own timeout of 1800 seconds; `TARGET_POD_<REASON>` names a pod that cannot start). Success is the PostgresRestore `Succeeded` and the target `Running`.
7. **Restore-patch record.** The spec of the restored Postgres is recorded in `clusters/fleet.yaml` and the chart (below): the spec file's, or, without one, the live spec read from the cluster now.
8. **Adoption sync.** A new instance is adopted by syncing its Application (`ADOPTION_NOT_SYNCED` is a warning). The Application of a new instance whose restore-patch could not be recorded is not synced (the chart would render the copied entry over the restored Postgres).
9. **Post-restore backup** (`postRestoreBackup`). A full backup of the target as tpg-backup takes it. When it fails, the pair stays `SUCCEEDED` with the warning `POST_RESTORE_BACKUP_FAILED`.
10. **`keepSourceLocation`.** With `false`, the copy of the source backup location that this run created is removed, with the copy's own Secret and no other, and never a reused one. It is kept (the pair stays `SUCCEEDED`) when any Postgres of the target namespace names it as its `spec.backupLocation` (`SOURCE_LOCATION_IN_USE`, naming the instance, which can be the restored instance itself), when those instances cannot be listed or the delete fails (`SOURCE_LOCATION_NOT_REMOVED`), or while another restore of the namespace is unfinished. While a copy exists, the repository counts as shared for `purgeBackups` of the delete workflows (section 10, section 11).

The result is `result.<target cluster>.<target instance>`; every failure records its reason code, a crash `UNEXPECTED_ERROR`. The plan of every pair, the PostgresRestore as YAML included, is in the step log and in the run record `plan.restore.<target cluster>.<target instance>`.

### Reasons the restore records

`FAILED` and `BLOCKED` stop that pair and nothing further is attempted for it; the other pairs go on, and the run ends `Failed` at the last step (`gate`) when a pair is `FAILED`, `TIMEOUT` or `BLOCKED`. A warning is shown in the Warnings part of the report and does not change the result. "Plan" means the reason also appears in a dry run; "run" only in a real run. The `validate` step (before any pair) answers with the key path of the key to fix instead of a code, except `IN_PLACE_NOT_ALLOWED`.

| Code | Result, when | Cause | Fix |
|---|---|---|---|
| `IN_PLACE_NOT_ALLOWED` | The whole run is refused, validate | An in-place pair on a cluster without `clusters.<cluster>.cluster.allowInPlaceRestore: true`, or `clusters/fleet.yaml` could not be read | Set it in `clusters/fleet.yaml`, merge, submit again; or restore into another instance |
| `INVALID_PAIR` | `FAILED`, plan | The step did not get a normalized pair (cannot happen after a passed validate step) | Submit again |
| `NOT_REGISTERED` | `FAILED`, plan | The kubeconfig Secret `kubeconfig-<cluster>` of a cluster of the pair is missing on the hub | Register the cluster (`tpg-aks-infra` `run.sh --only register`) |
| `FLEET_UNREADABLE` | `FAILED`, plan; also run (the second clone before the push) | The fleet repository could not be cloned | The Git credentials in Vault (`tpg/shared/github-push`), GitHub reachability; submit again |
| `SOURCE_NAMESPACE_MISMATCH` | `FAILED`, plan | `clusters/fleet.yaml` declares the source in another namespace than the pair says | Correct the source namespace (an instance's namespace cannot change) |
| `SOURCE_UNREADABLE` | `FAILED`, plan | The source Postgres could not be read (an API error other than NotFound) | The detail has the API message; check the source cluster |
| `BACKUP_OF_OTHER_INSTANCE` | `FAILED`, plan | The named PostgresBackup belongs to another instance than the pair's source | Name the instance the backup belongs to as the source, or give a backup of the source |
| `BACKUP_NOT_FOUND` | `FAILED`, plan | Same namespace: the named PostgresBackup does not exist or cannot be read | `kubectl -n <namespace> get postgresbackup` |
| `SOURCE_BACKUP_UNVERIFIED` | `FAILED`, plan | Another namespace or cluster: the source PostgresBackup is missing or the source cluster cannot be read, so the source check cannot pass | As above, on the source cluster |
| `BACKUP_NOT_SUCCEEDED` | `FAILED`, plan; also run | The PostgresBackup is not `Succeeded` (plan), or the synced copy in the target namespace is `Failed` (run) | Choose a `Succeeded` backup |
| `PITR_SOURCE_UNKNOWN` | `FAILED`, plan | PITR, but the source is gone and no readable `sourceBackupName` gives the location and stanza | Set `srcBackupLocationName` and `srcStanzaName` (the stanza is shown by `pgbackrest info`), or name a PostgresBackup of the source |
| `BACKUP_LOCATION_NOT_INITIALIZED` | `FAILED`, plan | The live source has no backup location or stanza yet (it never backed up) | Give `srcBackupLocationName` and `srcStanzaName` if the repository is known |
| `SOURCE_LOCATION_UNKNOWN` | `FAILED`, plan | A named backup into another namespace or cluster: the PostgresBackup reports no location and the source is not live | Start the source, or restore from a backup that reports its location |
| `SOURCE_LOCATION_UNREADABLE` | `FAILED`, plan | The source PostgresBackupLocation cannot be read, does not exist, or is not an Azure location | Only Azure Blob locations are copied; check `kubectl -n <namespace> get postgresbackuplocation` |
| `NO_FULL_BACKUP` | `FAILED`, plan | PITR from a live source that has no `Succeeded` full backup | Take a full backup first (tpg-backup) |
| `INVALID_TIMESTAMP` | `FAILED`, plan | `pitrConfig.timestamp` is in the future | A time in the past |
| `OUTSIDE_RECOVERY_WINDOW` | `FAILED`, plan | `pitrConfig.timestamp` is older than the oldest full backup | A time after the oldest full backup, or the detail's time |
| `NAMESPACE_IMMUTABLE` | `FAILED`, plan | The target is declared in `clusters/fleet.yaml` in another namespace than the pair says | Use the declared namespace, or another instance name |
| `TARGET_UNREADABLE` | `FAILED`, plan | The target Postgres, a Secret of the target namespace, or the list of its backup locations cannot be read (not NotFound) | The detail has the API message |
| `TARGET_EXISTS` | `FAILED`, plan | A live Postgres of the target's name exists and is not the source (not in place) | Restore in place, or choose a new instance name |
| `INSTANCE_NAME_IN_USE` | `FAILED`, plan | A Postgres of that name runs in another namespace of the target cluster; instance names are unique per cluster | Choose another target instance name |
| `UNKNOWN_TARGET_CLUSTER` | `FAILED`, plan | New target: `clusters/fleet.yaml` has no `clusters.<cluster>` | tpg-day0 for the cluster first |
| `SPEC_FILE_REQUIRED` | `FAILED`, plan | New target, the source is not in `clusters/fleet.yaml` and there is no spec file | Give `targetInstanceSpecFilePath` with at least `spec.postgresVersion.name` |
| `SPEC_FILE_NOT_FOUND` | `FAILED`, plan | A `repo:` spec file is not on the fleet branch | Commit it under `helm_artifacts/instance/tpg-instance/restore-specs/` |
| `SPEC_FILE_NOT_RECEIVED` | `FAILED`, plan | A local spec file is not in `patchFiles` | `pack-patch-files.sh -o <parameter file>` |
| `SPEC_FILE_INVALID` | `FAILED`, plan | Not valid YAML, not one `kind: Postgres` document, an empty spec, a field the Postgres CRD does not have, a symbolic link or a path outside `restore-specs/`, or no `spec.postgresVersion.name` for a new target | The detail names the file and the field |
| `FLEET_EDIT_FAILED` | `FAILED`, plan | The entry or the restore-patch could not be written into the clone of the fleet repository | The detail names the step |
| `CHART_RENDER_FAILED` | `FAILED`, plan | The chart cannot render the entry, or the PostgresRestore | The detail has the helm message |
| `VERSION_NOT_AVAILABLE` | `FAILED`, plan | The target's PostgresVersion does not exist on the target cluster | `kubectl get postgresversion` there; choose one it offers |
| `RESTORE_FLAVOUR_UNSUPPORTED` | `BLOCKED`, plan | A standard backup into a lite target (the matrix) | A standard PostgresVersion for the target |
| `RESTORE_VERSION_LOWER` | `BLOCKED`, plan | The target version is lower than the version of the backup (the matrix) | The version of the backup or newer |
| `NAMESPACE_SECRET_CONFLICT` | `FAILED`, plan; also run | The namespace of a new target already has a Secret `regsecret` or `backup-storage` that the fleet does not manage, or a `backup-storage` that does not hold the fleet's key and that the copied location reads | Rename that Secret or choose another target namespace |
| `BACKUP_LOCATION_MISSING` | `FAILED`, plan | The spec file names a `backupLocation` that does not exist in the target namespace, or names the copy while another location for that repository is reused | Create it, name the location the detail gives, or leave `backupLocation` out of the spec file |
| `SOURCE_LOCATION_CONFLICT` | `FAILED`, plan | A location in the target namespace for the same repository has `backupSync` off, or the name of the copy is taken by a location of another repository | Enable `backupSync` on it, delete it, or choose another target namespace |
| `SOURCE_SECRET_UNREADABLE` | `FAILED`, plan; also run | The Secret of the source backup location cannot be read on the source cluster (the contents are not read in a dry run) | Restore the Secret |
| `CONFIRMATION_MISMATCH` | `FAILED`, run | A real in-place restore without `confirm: <instance>` (the validate step refuses it first) | Set `confirm` in the target |
| `OPERATION_IN_PROGRESS` | `FAILED`, run; warning in a dry run | An in-place target has an unfinished backup, restore or upgrade | Wait for it (`kubectl -n <namespace> get postgresbackup,postgresrestore,postgresversionupgrade`) |
| `SKIPPED_IN_PROGRESS` | Left alone, run | A restore of the same target is still unfinished after 2 minutes; the run does not fail on it | Run again when it has finished |
| `GIT_PUSH_FAILED` | `FAILED`, run | The entry or the restore-patch of a new target could not be pushed or merged (`pushMode`) | The push token (`tpg/shared/github-push`), branch protection, the pull request |
| `NAMESPACE_OWNER_CONFLICT` | `FAILED`, run | After the push, two instances of the namespace own the shared Secrets (concurrent pull requests) | `instance.sharedSecretsOwner: false` on all but one |
| `TARGET_PREPARE_FAILED` | `FAILED`, run | The namespace, a Secret or the backup location of the new instance could not be created or synced | The detail names the object |
| `APP_NOT_GENERATED` | `FAILED`, run | The ApplicationSet did not generate `tpg-<cluster>-<instance>` after the push | `argocd appset get tpg-instances` |
| `SHARED_SECRETS_MISSING`, `SECRET_NOT_SYNCED` | `FAILED`, run | The shared objects of the namespace were not synced, or Vault Secrets Operator did not create `regsecret` and `backup-storage` | The detail names the owner and the Vault state |
| `NO_VAULT_SECRET` | `FAILED`, run | The copy needs the fleet's storage account from Vault (`tpg/shared/backup-storage`, keys `accountName` and `accountKey`) and Vault Agent did not render it: Vault sealed or unreachable, `vault-agent-injector` down, or the keys missing | Unseal Vault; write the Secret with tpg-rotate-credential `secretType=backup-storage` (section 17) |
| `SOURCE_SECRET_CONFLICT` | `FAILED`, run | A reused copy's Secret has other contents and was not made for this source | Restore from that source, or delete the Secret and the copy if they are not needed |
| `SOURCE_LOCATION_FAILED` | `FAILED`, run | The copy of the source backup location could not be applied | The detail names the object |
| `BACKUPS_NOT_SYNCED` | `FAILED`, run | The PostgresBackup of the same name did not appear `Succeeded` in the target namespace within `restoreTimeoutSeconds` | `backupSync` of the copy has not listed it: check the copy and its Secret |
| `CREATE_FAILED`, `RESTORE_FAILED` | `FAILED`, run | The PostgresRestore could not be created, or ended `Failed` (the detail has the operator's message) | The operator's message |
| `TIMEOUT` | `TIMEOUT`, run | The PostgresRestore did not finish within `restoreTimeoutSeconds` | Raise `restoreTimeoutSeconds`; the detail has the phase |
| `TARGET_POD_<REASON>` | `FAILED`, run | The restore succeeded, but a pod of the target cannot start or the instance is not `Running` in time (for example `TARGET_POD_CRASHLOOPBACKOFF`, `TARGET_POD_TIMEOUT`) | The pod status, events and logs below the pod table of the step log |
| `UNEXPECTED_ERROR` | `FAILED` | The step crashed (the detail has the script and line) | The step log |
| `SRC_LOCATION_DIFFERS`, `SRC_STANZA_DIFFERS` | Warning, plan | A given `srcBackupLocationName` or `srcStanzaName` differs from what the source reports; the given value is used | Check the value |
| `RECOVERY_WINDOW_UNVERIFIED`, `BACKUP_LABEL_UNVERIFIED` | Warning, plan | The PostgresBackups of the source cannot be read (or none is listed for a gone source), so the recovery time is not checked; no PostgresBackup carries the `srcBackupLabel` | Check the repository with `pgbackrest info` |
| `MATRIX_UNVERIFIED` | Warning, plan | The version of the source or the target is not known: the matrix was not checked | The detail |
| `CONFIRMATION_MISSING` | Warning, plan | A dry run of an in-place pair without `confirm`; a real run is refused | Set `confirm` |
| `RESTORE_PATCH_NOT_RECORDED` | Warning, run | The restore succeeded, but the spec could not be read or recorded as the restore-patch (the detail names the unknown or invalid fields of the live spec, for example `spec.noSuchField is not a field of the Postgres resource`, or the push failure) | The next sync of the Application renders the entry without it; a new instance's Application is not synced by this run. Record it with a spec file and a new restore |
| `ADOPTION_NOT_SYNCED` | Warning, run | The Application of the new instance did not sync after the restore | Check the Application in Argo CD |
| `POST_RESTORE_BACKUP_FAILED` | Warning, run | The full backup after the restore failed; the pair stays `SUCCEEDED` | tpg-backup |
| `SOURCE_LOCATION_IN_USE`, `SOURCE_LOCATION_NOT_REMOVED` | Warning, run | `keepSourceLocation=false`, but the copy was kept (an instance uses it as its backup location, or the instances could not be listed, or the delete failed) | Delete it by hand when nothing uses it |

### The restore-patch, and what may change a restored instance later

The Postgres that a restore leaves must be what Argo CD renders from then on, with no chart default and no entry value filled in. So the spec of the restored Postgres is stored in the chart as `helm_artifacts/instance/tpg-instance/restore-patch/<instance>-restore-<uid>.yaml` (one `kind: Postgres` document: `apiVersion`, `kind` and the spec, no `metadata`; see the README of the folder) and recorded in the instance's entry of `clusters/fleet.yaml` as `restorePatch.current` (with `mode`, and `previous: {path, commit}` when it replaces an earlier one; the file that was `previous` is deleted). The entry also gets `instance.restored: true` (workflow-owned: a values patch or an overlay cannot set it) and the fleet-equivalent fields of that spec (`postgresVersion`, `storageClassName`, `storageSize`, `walStorageSize`, `resources`, `highAvailability` (a single node as an explicit `false`/`0`), `exposure`, `readOnlyExposure` and the service annotations); in `mode: base` the ones the spec lacks are removed. Which spec, and which mode:

- **With a spec file**: the spec file's. A new target (one declared but not deployed included): `mode: base`, in the same commit as the entry. In place: `mode: over` (the operator merges the file into the existing Postgres, overwriting the fields it sets), in a commit of its own after the restore, with `restorePatch.postgresPatch` recording the postgres patch file that was current.
- **Without one**: after the restore succeeded and the instance runs, the `.spec` of the restored Postgres is **read from the target cluster** and stored the same way, `mode: base`, in a commit of its own. Only `.spec` is taken (`status`, `metadata`, annotations and managed fields are not part of it), `null` fields are dropped, and nothing else is stripped: the live spec is the truth, operator defaults included. It must fit the closed Postgres schema; when it cannot be read or does not fit, nothing is stored and the pair stays `SUCCEEDED` with the warning `RESTORE_PATCH_NOT_RECORDED`.

An in-place instance that is not in `clusters/fleet.yaml` records nothing. A re-restore makes the new file `current` and the old one `previous` (no longer applied); the source's restore-patch is never copied to a new target.

**The render** (`tpg.restoredPostgres` in `templates/_helpers.tpl`). `R` is the restore-patch's spec.

- *Mode base*: (1) `R` as it is; a field it omits stays unset. (2) The fleet-managed `backupLocation` (`<instance>-backup-location`) and `imagePullSecret` (`regsecret`), each one only where `R` omits it: a `backupLocation` or `imagePullSecret` that `R` sets wins, and a `backupLocation` that a spec file names must exist in the target namespace (`BACKUP_LOCATION_MISSING`), except the fixed name of the copy of the source backup location, which this run creates before the restore. (3) Later changes: every fleet-equivalent field of the entry that differs from `R` (compared as JSON; `R` lacking it differs, except `highAvailability` false/0, `serviceType` `ClusterIP` and empty annotations, which equal "unset") replaces `R`'s, an equal one changes nothing. (4) The current postgres patch file of tpg-patch. The overlays of the creation and the `instance:` keys of values patches do not reach a restored Postgres.
- *Mode over*: the normal render (values, overlay, the patch file current at the restore) with `R` over it (`R`'s own `backupLocation` and `imagePullSecret` win), then the later changes for the fields `R` sets, then a patch file set after the restore.

**Only three workflows change a restored instance afterwards**, and the entry records what they write:

| Workflow | Change | How it reaches the Postgres |
|---|---|---|
| tpg-scale-instance (section 8) | Read replicas (`instance.highAvailability`) | The entry now differs from `R`, so the render follows the entry |
| tpg-upgrade `component=postgres` (section 6) | The Postgres version (`instance.postgresVersion`) | Same |
| tpg-patch postgres patch files (section 7) | Any field of the Postgres, PostgresBackupLocation, schedule or FerretDB documents | Applied last, over `R` and the later changes; tpg-patch never retires or changes the restore-patch |

Everything else is refused for that instance, and only for that instance: a tpg-patch values patch that sets an `instance:` key that reaches the Postgres (`storageSize`, `walStorageSize`, `resources`, `exposure`, `readOnlyExposure`, `serviceAnnotations`, `readOnlyServiceAnnotations`, `allowedSourceRanges`, `internalLoadBalancerSubnet`) is `BLOCKED` `PATCH_REFUSED` with `RESTORED_VALUES_PATCH` in the detail, in both modes, naming the three ways above (keys that do not reach the Postgres, `backup`, `network`, `ferret`, ..., stay allowed; a values patch cannot set `restorePatch` or `instance.restored`); tpg-day0 and tpg-create-instance block it `BLOCKED` `INSTANCE_RESTORED` (the other instances and the cluster go ahead; its entry is not written, synced or verified, and the discover step leaves it out); tpg-network-policy does not touch the Postgres and stays allowed. Deleting the instance keeps its restore-patch files, like the audit copy of the entry in `clusters/deleted/` that records them.

### dryRun

`dryRun` is `true` by default and is read-only for every pair: nothing changes on a cluster, in Git or in Argo CD. Each pair runs all the plan checks (the source, the named backup or the recovery time, the matrix, the target, `TARGET_EXISTS`, the spec file, the namespace Secrets, the copy and the Secret it would use) and records the whole plan: what it would copy, the entry it would write, the restore-patch it would record, the PostgresRestore (and the copy of the backup location) as YAML, and the warnings. The pair ends `SUCCEEDED` with the reason `DRY_RUN`. Read it in the step log, or with `kubectl -n argo get configmap tpg-run-<workflow> -o json | jq -r '.data["plan.restore.<cluster>.<instance>"] | fromjson | .detail'`. A dry run does not read the Secret values of the source and does not wait for anything; what only a real run can show (the backupSync wait, the restore, the instance coming up, the live spec) is not in it. Run the plan, read it, then submit the same file with `dryRun` set to `false`.

### Submit script

`scripts/submit/tpg-restore.sh` (section 18) is a guided pair builder, with load-from-file and paste. `clusterMap` is built pair by pair: the source cluster (the registered clusters of the hub), the source instance (the instances declared for that cluster in your `clusters/fleet.yaml` with their namespaces, or a namespace and instance typed), the recovery point (a named backup, `sourceBackupName`; or point-in-time recovery with `pitrConfig.type` and its `timestamp` or `target`, `bestEffort` where it is mandatory, optionally `srcBackupLocationName`, `srcStanzaName` and `srcBackupLabel`), the target cluster, namespace and instance (the source's own cluster, namespace and instance is an in-place restore: the script says so, asks for `confirm` and warns when your clone's `clusters/fleet.yaml` does not set `allowInPlaceRestore` for the cluster), an optional `targetInstanceSpecFilePath` (a file of `helm_artifacts/instance/tpg-instance/restore-specs/` in your clone, or a file of your machine, which is sent with the run; mandatory when the source is not declared in `clusters/fleet.yaml` and the target is a new instance), `skipMinorVersionCheck` and `postRestoreBackup`. Every pair is checked with `clustermap.py restore` as it is added (an invalid pair is explained and can be entered again), then "Add another pair" or "Done". The pairs can also be loaded from a YAML or JSON file or pasted. Before anything is submitted the script prints the normalized plan of each pair (index, source and target, method, in place or not, the recovery point and repository, the spec file, the flags), again just before the submit menu, and re-checks the list with `--confirm-required` when `dryRun` is set to `false`. It reads only the hub and your clone, never a member cluster: whether the source backup exists and is `Succeeded`, whether the target exists and the version matrix are checked by the workflow, which `dryRun=true` (the default) runs without changing anything.

### Worked examples

Example 1 is the generated file above: a dry run of one pair with a named backup, restored into a new instance (`orders-db-restored`) of the namespace of the source (method 2). The plan checks that the backup exists and is `Succeeded`, the matrix and that the target does not exist, and prints the PostgresRestore; nothing changes. From your tpg-fleet clone:

```bash
argo submit -n argo --from workflowtemplate/tpg-restore \
  --parameter-file workflows/params/schemas/params-restore.example.yaml --watch
```

For a real run, copy the file and change `dryRun: "true"` to `dryRun: "false"`. An input that the file sets cannot be changed with `-p` (section 2, Parameter files).

Example 2 restores two instances in one run, both with point-in-time recovery: the first onto another cluster (method 1) to a time, with `bestEffort`; the second into another namespace of its own cluster (method 2) to a log sequence number, starting from the backup set the label names. `canary` runs the first pair alone and stops the run if it fails. The file sets no `dryRun`, so the first command plans; the second restores:

```yaml
# restore-pitr.yaml
rolloutMode: canary
clusterMap: |
  - sourceClusterConfig:
      aks-tpg-poc-01:
        pg-orders-db:
          orders-db: {}
    targetClusterConfig:
      aks-tpg-poc-02:
        pg-orders-dr:
          orders-db-dr:
            pitrEnabled: true
            bestEffort: true
            pitrConfig:
              type: time
              timestamp: "2026-09-15T08:30:00Z"
  - sourceClusterConfig:
      aks-tpg-poc-01:
        pg-billing-db:
          billing-db: {}
    targetClusterConfig:
      aks-tpg-poc-01:
        pg-billing-check:
          billing-db-check:
            pitrEnabled: true
            bestEffort: false
            pitrConfig:
              type: lsn
              target: "0/3000060"
              sourceBackupConfig: {srcBackupLabel: 20260915-020000F}
```

```bash
argo submit -n argo --from workflowtemplate/tpg-restore --parameter-file restore-pitr.yaml --watch
argo submit -n argo --from workflowtemplate/tpg-restore --parameter-file restore-pitr.yaml -p dryRun=false --watch
```

Example 2 with a spec file: a named backup restored onto another cluster as an instance with the spec of a file of your machine (`targetInstanceSpecFilePath`, which `pack-patch-files.sh -o` packs into `patchFiles`; a `repo:helm_artifacts/instance/tpg-instance/restore-specs/<file>` needs no packing). The file is the spec of the restored Postgres, one `kind: Postgres` document:

```yaml
# ./orders-dr.yaml, on your machine
apiVersion: sql.tanzu.vmware.com/v1
kind: Postgres
spec:
  postgresVersion:
    name: postgres-17.6
  highAvailability:
    enabled: false
```

```yaml
# restore-spec.yaml
clusterMap: |
  - sourceClusterConfig:
      aks-tpg-poc-01:
        pg-orders-db:
          orders-db: {sourceBackupName: orders-db-full-20260914000000}
    targetClusterConfig:
      aks-tpg-poc-02:
        pg-orders-dr:
          orders-db-dr: {targetInstanceSpecFilePath: [./orders-dr.yaml]}
```

```bash
<tpg-fleet clone>/scripts/submit/pack-patch-files.sh -o restore-spec.yaml
argo submit -n argo --from workflowtemplate/tpg-restore --parameter-file restore-spec.yaml --watch
```

**More commands.** An in-place restore of a named backup (the cluster needs `allowInPlaceRestore: true`; `confirm` repeats the instance name and is needed for the real run only):

```bash
# 1. Plan an in-place restore of a named backup (dryRun is true by default: nothing changes)
cat > restore.yaml <<'EOF'
clusterMap: |
  - sourceClusterConfig:
      aks-tpg-poc-01:
        pg-orders:
          orders-db:
            sourceBackupName: orders-db-full-20260914000000
    targetClusterConfig:
      aks-tpg-poc-01:
        pg-orders:
          orders-db:
            pitrEnabled: false
            confirm: orders-db
EOF
argo submit -n argo --from workflowtemplate/tpg-restore --parameter-file restore.yaml --watch

# 2. The same pair for real
argo submit -n argo --from workflowtemplate/tpg-restore --parameter-file restore.yaml -p dryRun=false --watch
```

---

## 17. tpg-rotate-credential

Creates or rotates a secret in Vault and verifies that the new value reached everything that uses it (Round 15, design decision D87). Nothing is edited in a Kubernetes Secret by hand.

The new value comes from a wrapping token (section 15), or for a CA bundle from a PEM file. The write step unwraps the token, checks the value before writing it (the registry login, a `git ls-remote` and for `git-push` a `git push --dry-run` to the fleet branch, every backup container with the storage key, the password length, the PEM certificates), and writes it as a new version of its KV v2 path. It runs as the ServiceAccount `argo/tpg-credential-writer`, the only identity with the Vault role and policy `tpg-credential-writer` (create, update and read back on the five shared credential paths, `tpg/ca-bundles/*` and `tpg/custom/*`; no delete). The admission policy `tpg-credential-writer` keeps that ServiceAccount to this WorkflowTemplate. In namespace `argo` it refuses a Workflow, WorkflowTemplate, CronWorkflow or ClusterWorkflowTemplate that names the ServiceAccount (in `spec`, `templateDefaults`, a template or an inline template, as `serviceAccountName` or the executor's); a `podSpecPatch` that mentions any ServiceAccount or holds a backslash or `!!` (an escape or a YAML tag could spell the name another way); a `templateRef` to `tpg-rotate-credential` from anything but the template itself; and a run of `tpg-rotate-credential` that brings more than `workflowTemplateRef` and `arguments` (a `podSpecPatch`, `templateDefaults`, `volumes` or its own `entrypoint` would reach the write step). Only Argo CD may change the WorkflowTemplate, and the write step's image is fixed in it, not the `toolsImage` parameter. The same policy keeps the write step's inputs out of reach of the workflow ServiceAccounts `tpg-workflow` and `tpg-credential-writer` (they share one Role): they may write only the run records `tpg-run-*` among the ConfigMaps of `argo` (the step runs its script from `tpg-scripts` and reads the registry host and the fleet repository URL from `tpg-settings`), and may change only the metadata of a pod, not its spec (a new image of a running write step would run as the writer). The policy checks these objects only: keep the right to create pods in `argo` to the Argo Workflows controller and the hub administrators. Without `wrappingToken` or `caBundleFile`, the value was written in Vault by hand, and the run only verifies it.

| Input | Type | Mandatory | Default | Description |
|---|---|---|---|---|
| `secretType` | `Enum` | no | `broadcom-registry` | `broadcom-registry`, `backup-storage`, `git-push`, `git-read`, `monitoring-remote-write`, `ca-bundle` or `custom` (table below) |
| `secretName` | `String (name)` | with `ca-bundle` or `custom` | | The name under `tpg/ca-bundles/` or `tpg/custom/`; the other types have a fixed path |
| `wrappingToken` | `String (Vault token)` | no (`custom`: yes) | | The wrapping token of the new value (`tpg-aks-infra/scripts/vault-secret.sh wrap`); single use, 10 minutes |
| `caBundleFile` | `List (one file path)` | no | | `ca-bundle` only, instead of `wrappingToken`: a PEM file of the submitting machine (packed into `patchFiles`). A `repo:` file is refused: a bundle kept in the fleet repository needs no copy in Vault, runs name it with `-p 'backupCaBundleFile=[repo:ca-bundles/<file>]'` |
| `patchFiles` | `Map (JSON)` | with a local `caBundleFile` | | The contents of the file, written by `scripts/submit/pack-patch-files.sh -o` |
| `clusters` | `List` | no | `all` | Registered clusters to verify, or `all` |
| `maxParallel` | `Integer` | no | `5` | Clusters verified at the same time |

<!-- BEGIN GENERATED: params-rotate-credential -->
<!-- written by workflows/params/params_schema.py; do not edit by hand -->

Parameter file schema: `workflows/params/schemas/params-rotate-credential.schema.json` (also `params-rotate-credential.schema.yaml`). Check a parameter file with it:

```bash
check-jsonschema --schemafile workflows/params/schemas/params-rotate-credential.schema.json <parameter file>
```

Worked example 1, `workflows/params/schemas/params-rotate-credential.example.yaml`:

```yaml
# yaml-language-server: $schema=params-rotate-credential.schema.json
# tpg-rotate-credential: No dryRun input. The least-impact run: verify a value that was written in Vault by hand, on one cluster.
# A parameter file of the argo CLI (generated by workflows/params/params_schema.py; see
# params-rotate-credential.schema.json). Submit it with:
#   argo submit -n argo --from workflowtemplate/tpg-rotate-credential --parameter-file params-rotate-credential.example.yaml --watch
secretType: git-read
clusters: [aks-tpg-poc-01]
```

<!-- END GENERATED: params-rotate-credential -->

**What the step logs while it waits (Round 21).** Every wait prints each poll (number and elapsed seconds), the command it runs, and what it found, so a slow sync can be followed with `argo logs -f` and a stuck one diagnosed from the log alone:

```text
[12:31:05] wait pg-orders-db/regsecret holds the Vault value: poll 3/30, 20s
[12:31:05]   $ kubectl -n pg-orders-db get secret regsecret -o json | jq -j '.data[".dockerconfigjson"] | @base64d | fromjson | .auths[].password' | sha256sum
[12:31:06]   checksum live 15ad3ddd != Vault 7c01b2e9: not yet; VaultStaticSecret: SecretSynced=True (Secret synced); Ready=True (VaultStaticSecretReady) | secretMAC S3atz4E1eWKh
```

Only the first 8 characters of the two checksums are logged, never a value. The operator namespace is checked first, then the namespaces of the instances declared for the cluster in `clusters/fleet.yaml`; each gets up to 5 minutes and ends as soon as the live Secret holds the Vault value, and the step fails `SECRET_NOT_SYNCED` only after checking all of them, naming every namespace that did not match. The hub part also logs the Argo CD repository poll and fails `RBAC_MISSING` when `workflow-bot` may read no repositories (it needs `p, role:tpg-sync, repositories, get, *, allow`). Up to Round 20 the live checksum was taken with a trailing newline that the Vault one lacked, so this step always failed `SECRET_NOT_SYNCED`. The Day 0 and restore waits for the `regsecret` and `backup-storage` Secrets log the same way.

**Worked examples** (Round 23). This workflow has no `dryRun` and no `clusterMap`. Example 1 is the generated file above, the least-impact run: it writes nothing and verifies a value that was put in Vault by hand, on one cluster. From your tpg-fleet clone:

```bash
argo submit -n argo --from workflowtemplate/tpg-rotate-credential \
  --parameter-file workflows/params/schemas/params-rotate-credential.example.yaml --watch
```

Example 2 writes a named CA bundle from a PEM file of your machine and verifies it on two clusters (`clusters` is a list; the file travels in `patchFiles`, packed into the parameter file first):

```yaml
# ca.yaml
secretType: ca-bundle
secretName: azure-storage-2027
caBundleFile: [~/certs/azure-storage-2027.pem]
clusters: [aks-tpg-poc-01, aks-tpg-poc-02]
```

```bash
~/src/tpg-fleet/scripts/submit/pack-patch-files.sh -o ca.yaml
argo submit -n argo --from workflowtemplate/tpg-rotate-credential --parameter-file ca.yaml --watch
```

**More commands.** A new value comes through a wrapping token (section 15), never as an input:

```bash
cd ~/src/tpg-aks-infra
# 1. A new Broadcom registry token: wrapped, written, verified on every cluster
read -rs BROADCOM_TOKEN && export BROADCOM_TOKEN
export BROADCOM_USER=me@example.com
T="$(scripts/vault-secret.sh wrap broadcom-registry)"
argo submit -n argo --from workflowtemplate/tpg-rotate-credential -p secretType=broadcom-registry -p wrappingToken="$T" --watch
unset BROADCOM_TOKEN T

# 2. A new storage account key (after az storage account keys renew)
read -rs BACKUP_STORAGE_KEY && export BACKUP_STORAGE_KEY
T="$(scripts/vault-secret.sh wrap backup-storage)"
argo submit -n argo --from workflowtemplate/tpg-rotate-credential -p secretType=backup-storage -p wrappingToken="$T" --watch
unset BACKUP_STORAGE_KEY T

# 3. Only verify a value written in Vault by hand, on every cluster
argo submit -n argo --from workflowtemplate/tpg-rotate-credential -p secretType=git-read --watch
```

| `secretType` | Vault path | What is checked after the write |
|---|---|---|
| `broadcom-registry` | `tpg/shared/broadcom-registry` | The hub `VaultStaticSecret` and the Argo CD OCI repository connection, then on every cluster: `regsecret` matches Vault, and a test pod pulls an image |
| `backup-storage` | `tpg/shared/backup-storage` | `backup-storage` matches Vault on every cluster, the backup locations are re-read by the operator, and the Blob container answers with HTTP 200 for the new key |
| `git-push` | `tpg/shared/github-push` | The workflow's own Git credential: a clone and a `git push --dry-run` to the fleet branch |
| `git-read` | `tpg/shared/github-read` | The Argo CD repository credential: `repo-tpg-fleet` matches Vault (Vault Secrets Operator) and the Argo CD connection to the fleet repository is Successful |
| `monitoring-remote-write` | `tpg/shared/monitoring-remote-write` | The value is in Vault; the targets receive it through the Vault Secrets Operator (`monitoring/tpg-remote-write`). The hub gateway still accepts the previous password until `tpg-aks-infra/scripts/run.sh --only addons` rebuilds its htpasswd from Vault, restarts it and checks that every target's metrics arrive: the run records the warning `GATEWAY_NOT_UPDATED` as that reminder. Run it right after the workflow (docs/monitoring.md) |
| `ca-bundle` | `tpg/ca-bundles/<secretName>` | The bundle reads back from Vault with certificates that have not expired. Runs use it with `backupCaBundleVaultSecret=<secretName>` (section 15); running instances keep their bundle until tpg-patch writes the new one |
| `custom` | `tpg/custom/<secretName>` | Nothing in the fleet reads it; the write step checks that every value is a non-empty string |

| Result | Meaning |
|---|---|
| `result.vault WRITTEN` | The value was checked and written (the detail names the path, the new KV version and the source) |
| `WRAPPING_TOKEN_INVALID` | The token was used already, expired, or is not a wrapping token: nothing was written; wrap the value again |
| `VALUE_INVALID`, `VALUE_REJECTED` | The value lacks a key of its type, or failed its check (login refused, HTTP 403 from a container, expired certificate); nothing was written |
| `VAULT_LOGIN_FAILED`, `VAULT_WRITE_FAILED`, `VAULT_UNREACHABLE` | The write step could not log in as `tpg-credential-writer` or write the path (the Vault role and policy come from `tpg-aks-infra` `scripts/run.sh --only vault`) |

---

## 18. Interactive submit scripts

`scripts/submit/tpg-<workflow>.sh` starts a workflow without composing the `argo submit` line by hand: one script per workflow (13 since Round 23, which added `tpg-backup-expire.sh`; `tpg-restore.sh` builds the list of pairs). Each script reads the inputs, defaults, allowed values and descriptions from `workflows/templates/<template>.yaml` and the types from `workflows/params/types.yaml`, so it stays in step with the template.

1. The targets first: `clusterMap` or the lists, where the workflow takes both. `clusterMap` can be built step by step (the registered clusters are listed from the hub, then the instances declared in your `clusters/fleet.yaml`, then the keys the workflow accepts, with their types), loaded from a file, or pasted. It is checked with the same `clustermap.py` as the `validate` step.
2. The mandatory inputs, each with its type and an example. A value that does not match its type is refused with the reason and asked again. A list input takes plain names (`aks-tpg-poc-01, aks-tpg-poc-02`) and a single-file input one path: the script sends them in brackets (`[aks-tpg-poc-01, aks-tpg-poc-02]`, `[./ca.pem]`), the form the hub requires; `all` and `auto` stay bare.
3. A menu of the optional inputs with their current values or defaults (arrow keys and Enter, or numbers). After each one the script asks whether to set another.
4. A summary, the equivalent `argo submit` command, then Submit, Change optional inputs, or Cancel.
5. The submit: `argo submit` when the argo CLI is installed, otherwise `kubectl create` of a Workflow object (the hub admission policy checks it the same way). The script can then follow the run and print its report.

Requirements: bash 3.2 or later (the macOS bash works), mikefarah `yq` v4, `jq`, `python3`, `kubectl` with a context for the hub; the argo CLI is optional.

| Variable | Meaning |
|---|---|
| `HUB_CONTEXT` | kubectl context of the hub (default: the current context) |
| `ARGO_NS` | Namespace of the WorkflowTemplates (default `argo`) |
| `TPG_PLAIN=1` | Numbered menus instead of arrow keys (also when the terminal is not interactive) |
| `TPG_NO_WATCH=1` | Do not offer to follow the run |

The scripts run from any directory (Round 15, design decision D85). A script finds its tpg-fleet clone through `TPG_FLEET_DIR` when set, otherwise as the clone it sits in (following symbolic links, so a link in `~/bin` works); a copy outside a clone stops with the hint to set `TPG_FLEET_DIR`. Relative patch file paths start from the current directory.

```bash
cd ~/src/tpg-fleet
HUB_CONTEXT=aks-tpg-hub scripts/submit/tpg-create-instance.sh
TPG_PLAIN=1 HUB_CONTEXT=aks-tpg-hub scripts/submit/tpg-network-policy.sh
# patch files: run the script from the directory that holds them
cd ~/patches && HUB_CONTEXT=aks-tpg-hub ~/src/tpg-fleet/scripts/submit/tpg-patch.sh
# from anywhere, through a link or with TPG_FLEET_DIR
ln -s ~/src/tpg-fleet/scripts/submit/tpg-patch.sh ~/bin/tpg-patch && tpg-patch
TPG_FLEET_DIR=~/src/tpg-fleet bash /opt/tools/tpg-patch.sh
```

Some inputs depend on an earlier answer: `tpg-restore.sh` builds the list of pairs for `clusterMap` (section 16), `tpg-upgrade.sh` asks `instances` for `component=postgres`, `tpg-scale-instance.sh` asks whether the run scales instances (`instances` and `replicas`), changes only the cap (`maxReadReplicas`), or both, and `tpg-patch.sh` does not submit before a patch file input is set (and `instances` for instance patch files).

**Local files (Round 14, Round 15).** `tpg-patch.sh`, `tpg-create-instance.sh`, `tpg-day0.sh`, `tpg-restore.sh` (the `targetInstanceSpecFilePath` of a pair) and `tpg-rotate-credential.sh` read every local file the path inputs and `clusterMap` name (absolute, `~/` or relative to the current directory; `repo:` files are left to the workflow; nothing with `patchMode=clear`) through `pack-patch-files.sh -o`; the prompts take plain names or one path and send the bracketed form (`[orders-db, billing-db]`, `[./ca.pem]`), so a file that is missing or does not fit its input is refused before anything is submitted, and send their contents as `patchFiles`; you never type that input. The equivalent commands they print are the parameter-file form of section 7:

```bash
<tpg-fleet clone>/scripts/submit/pack-patch-files.sh -o <parameter file>
argo submit -n argo --from workflowtemplate/tpg-patch --parameter-file <parameter file> --watch
```

The scripts submit `patchFiles` through a parameter file, so the Linux limit of 128 KiB per command-line argument does not apply to them.

---

## 19. Test data: pgdata

`tools/pgdata/pgdata.py` creates a database and tables on an instance, inserts random rows and reads them back, to try a deployment, a backup and restore, or a network policy with real data. It needs Python 3.9 or later and psycopg 3 (`pip install "psycopg[binary]"`).

The connection is given by hand; nothing is read from the cluster. Reach the instance through its load balancer address (`exposure`), or port-forward its Service first. The credentials are in the Secret `<namespace>/<instance>-db-secret`, keys `username` and `password` (the namespace is `pg-<instance>` unless the instance has a `namespace` of its own, section 3; the commands below use the default):

```bash
kubectl --context aks-tpg-poc-01 -n pg-orders-db port-forward svc/orders-db 5432 &
export PGPASSWORD="$(kubectl --context aks-tpg-poc-01 -n pg-orders-db get secret orders-db-db-secret -o jsonpath='{.data.password}' | base64 -d)"
PGUSER="$(kubectl --context aks-tpg-poc-01 -n pg-orders-db get secret orders-db-db-secret -o jsonpath='{.data.username}' | base64 -d)"
C=(--host 127.0.0.1 --port 5432 --user "$PGUSER" --sslmode require)
```

The password comes from `--password`, else `PGPASSWORD`, else a hidden prompt (`--password` is visible in the process list). Without a command, or with `--interactive`, the script asks for the connection and the action step by step.

| Command | Options |
|---|---|
| `create-db` | `--name NAME [--owner ROLE] [--if-not-exists]` |
| `create-table` | `--database DB --table [SCHEMA.]TABLE` with `--preset customers\|orders\|sales_events` or `--columns "name:type,..."`; `[--primary-key COLUMN] [--if-not-exists]`. A missing schema is created |
| `insert` | `--database DB --table TABLE [--rows 100] [--batch-size 1000] [--seed N]`: values generated from the column types, loaded with COPY |
| `read` | `--database DB --table TABLE [--limit 20] [--where "COLUMN OP VALUE"] [--order-by COLUMN [--desc]] [--count] [--format table\|csv\|json]`, or `--sql "SELECT ..."` in a READ ONLY transaction |

Column types: `smallint`, `integer`, `bigint`, `serial`, `bigserial`, `real`, `double precision`, `boolean`, `text`, `date`, `timestamp`, `timestamptz`, `uuid`, `json`, `jsonb`, `numeric` or `numeric(P,S)`, `varchar(N)`, `char(N)`, and `identity` for a generated `bigint` key. Identifiers are checked and quoted, values are passed as query parameters, and `--where` takes one comparison (`=`, `!=`, `<`, `<=`, `>`, `>=`, `like`, `ilike`, `is null`, `is not null`).

```bash
python3 tools/pgdata/pgdata.py "${C[@]}" create-db --name shop
python3 tools/pgdata/pgdata.py "${C[@]}" create-table --database shop --table customers --preset customers
python3 tools/pgdata/pgdata.py "${C[@]}" create-table --database shop --table sales.events \
  --columns "id:identity,at:timestamptz,amount:numeric(10,2),tag:varchar(20),doc:jsonb"
python3 tools/pgdata/pgdata.py "${C[@]}" insert --database shop --table customers --rows 10000 --seed 42
python3 tools/pgdata/pgdata.py "${C[@]}" read --database shop --table customers --where "city ilike b%" --order-by id --limit 5
python3 tools/pgdata/pgdata.py "${C[@]}" read --database shop --table customers --count
python3 tools/pgdata/pgdata.py "${C[@]}" read --database shop --sql "select tag, count(*) from sales.events group by tag" --format csv
```

---

## 20. Follow, approve, stop and clean up runs

```bash
argo list                                   # runs with status and duration
argo list --running
argo list -l workflows.argoproj.io/workflow-template=tpg-day0
argo get @latest                            # step tree of the newest run
argo watch @latest
argo logs @latest --follow
argo logs <workflow> -c main | sed -n '/tpg run report/,$p'
kubectl -n argo get configmap tpg-run-<workflow> -o yaml   # raw results per target

argo resume <workflow>                      # approve a suspended step (tpg-upgrade allowMajor=true)
argo suspend <workflow>
argo stop <workflow>                        # run exit handlers (report), then stop
argo terminate <workflow>                   # stop immediately, no exit handler
argo retry <workflow>                       # rerun failed steps
argo resubmit <workflow> --memoized         # new run with the same inputs
argo delete <workflow>                      # also deletes tpg-run-<workflow>
argo delete --older 7d
```

### Archived step logs

Every step's log is archived to Azure Blob when the step ends (container `argo-logs` of the backup storage account). The Argo UI shows the log of a finished step even after its pod has been deleted, for as long as the Workflow exists (7 days). After that, or from a terminal:

```bash
cd tpg-aks-infra
scripts/wf-logs.sh <workflow> --list              # the archived logs of a run
scripts/wf-logs.sh <workflow>                      # print every step log
scripts/wf-logs.sh <workflow> --grep 'RESULT|POD_' # only the matching lines, per step
make wf-logs WF=<workflow>
```

The logs are deleted by the storage lifecycle rule after 90 days (Terraform `argo_logs_retention_days`).

### Reading a failed step

Every step writes its own result: one line `RESULT <key> <status> <reason>
<detail>` in the step log, one key in `tpg-run-<workflow>`, and the output
parameter the report and the Prometheus metric read. A step that fails before it
gets that far records `UNEXPECTED_ERROR` with the script and line number, so a
run never ends with a bare `UNKNOWN`.

```bash
argo logs @latest -c main | grep RESULT
kubectl -n argo get configmap tpg-run-<workflow> -o json | jq '.data | map_values(fromjson)'
```

Reasons written by the sync engine, the pod watch and the checks before a change. `<namespace>` in the commands is the namespace of the instance: `pg-<instance>` unless its `clusters/fleet.yaml` entry says otherwise (section 3, `namespace`). Round 23 added these reasons: the namespace and shared Secrets (`SHARED_SECRETS_MISSING`, `HANDOVER_FAILED`, `NAMESPACE_SHARED`, `NAMESPACE_MISMATCH`, `NAMESPACE_AMBIGUOUS`, `FLEET_UNREADABLE`, `POSTGRES_SKIPPED`), purge and expire (`PURGE_LOCATION_UNKNOWN`, `PURGE_REPOPATH_REFUSED`, `PURGE_ACCOUNT_MISMATCH`, `PURGE_ACCOUNT_UNKNOWN`, `BACKUP_EXPIRE_IMPOSSIBLE`, `BACKUP_EXPIRE_TIMEOUT`, `BACKUP_EXPIRE_ERROR`, `BLOB_PURGE_FAILED`, `BACKUPS_UNREADABLE`, `EXPIRE_FAILED`, `BACKUP_REPO_SHARED`) and the restore (every reason it records is in the table of section 16).

| Reason | Meaning | Look at |
|---|---|---|
| `SYNC_REJECTED` | The API server or an admission webhook refused the manifests (invalid or immutable field). Not retried | The detail holds Argo CD's message; fix the spec in Git |
| `SYNC_FAILED` | The sync operation failed for another reason, after the retries | `argocd app get <app> --show-operation` |
| `SYNC_TIMEOUT` | The sync operation did not finish in time | `argocd app get <app>`, the pod table in the step log |
| `SYNC_BUSY` | Another operation on the Application did not end in time | `argocd app get <app> --show-operation`; ask the platform team if it is stuck (section 21) |
| `SYNC_DRIFT` | Synced, but resources stay OutOfSync (listed in the detail) | `argocd app diff <app>` |
| `HEALTH_TIMEOUT` | Synced, but not Healthy in time | The Postgres resource `status.currentState`, the pod table |
| `POD_<REASON>` | A pod could not start (`POD_CRASHLOOPBACKOFF`, `POD_IMAGEPULLBACKOFF`, `POD_UNSCHEDULABLE`, ...) | The status, events and logs printed below the pod table |
| `MONITORING_NOT_FLOWING` | A target's metrics did not reach the hub within 5 minutes | `kubectl -n monitoring logs deploy/tpg-remote-write` on the hub, the target's Prometheus logs |
| `UNKNOWN_INSTANCE` | A selected instance is not declared on the cluster in `clusters/fleet.yaml`. Nothing was changed | The detail lists the declared instances |
| `FLEET_UNREADABLE` | A step could not read the namespace of an instance: it has no checkout of the fleet repository, the instance is not in the run inventory and a clone failed. Nothing ran against a guessed `pg-<instance>` | The Git credentials in Vault (`tpg/github-push`), GitHub reachability; run again |
| `SHARED_SECRETS_MISSING` | tpg-day0, tpg-create-instance: an instance that does not own the shared Secrets of its namespace found `regsecret` or `backup-storage` missing there; the owner has no Application, the sync of its shared objects failed, or Vault Secrets Operator did not create them | The detail names the owner; `kubectl -n <namespace> get vaultstaticsecret` |
| `HANDOVER_FAILED` | tpg-delete-instance, tpg-delete-apps: the shared Secrets of a namespace could not be handed to a remaining instance (its Application is missing, the selective sync failed or the objects were not adopted). The owner flags are reverted in Git and the instance is not deleted | The detail; run again after the successor's Application syncs |
| `NAMESPACE_SHARED` | tpg-delete-instance, tpg-delete-apps: `purgeNamespace=true` for a namespace that other instances use, or that instances of the run share while one of them has `purgeNamespace=false`. Nothing was changed | The detail names the instances |
| `NAMESPACE_MISMATCH`, `NAMESPACE_AMBIGUOUS` | tpg-delete-instance, tpg-delete-apps: the entry is gone and the audit copy in `clusters/deleted` disagrees with the namespace of the live Postgres, or two Postgres of that name exist and there is no copy. Nothing was deleted | `kubectl get postgres -A` |
| `PURGE_LOCATION_UNKNOWN` | tpg-delete-instance, tpg-delete-apps with `purgeBackups=true`: the PostgresBackupLocation of the instance does not exist and no audit copy in `clusters/deleted/<cluster>` records its container and `repoPath`, so the backups cannot be found. Nothing was changed | Set `purgeBackups=false` (the blobs stay) or delete them by hand |
| `PURGE_REPOPATH_REFUSED` | `purgeBackups=true`: the `repoPath` of the location is the root of its container; a whole container is never deleted. Nothing was changed | `purgeBackups=false`, and delete the blobs by hand |
| `PURGE_ACCOUNT_MISMATCH` | `purgeBackups=true`: the Secret of the backup location (or the audit copy of a re-run) names another storage account than the key in Vault (`tpg/shared/backup-storage`). Nothing was deleted | The detail names both accounts |
| `PURGE_ACCOUNT_UNKNOWN` | `purgeBackups=true`: the storage account of a Secret other than `backup-storage` cannot be determined (the Secret cannot be read and the audit copy does not record it), so the key in Vault may not belong to it. Nothing was deleted | Restore the Secret, or delete the blobs by hand |
| `BACKUP_EXPIRE_IMPOSSIBLE` | `purgeBackups=true`: the instance is not Running, so the operator cannot expire its backups, and the repository is also used by another backup location (its blobs are not deleted). Nothing was deleted | The detail names the state and the other location; start the instance, or `purgeBackups=false` |
| `BACKUP_EXPIRE_TIMEOUT`, `BACKUP_EXPIRE_ERROR` | `purgeBackups=true`: the operator gave no answer to an expire in time, or an expire could not be set or read (API error). Nothing was deleted | The detail names the backup and the answer; `kubectl -n <namespace> get postgresbackup` |
| `BLOB_PURGE_FAILED` | `purgeBackups=true`: a blob could not be deleted (the detail names it and the HTTP status; 429, 5xx and curl failures were tried 4 times), the listing failed, or the check listing afterwards was not empty or could not be read. The instance is already deleted | Run the same workflow again with `purgeBackups=true`: the audit copy in `clusters/deleted/` is enough and only the blob purge is finished. HTTP 403: the key in Vault was rejected |
| `BACKUPS_UNREADABLE`, `EXPIRE_FAILED` | tpg-backup-expire: the PostgresBackups (or the dependents of one) of the instance could not be read; or an expire could not be set or read (API error) | The detail holds the API message; the instance is recorded `FAILED`, the others go on |
| `BACKUP_REPO_SHARED` | `purgeBackups=true` (warning, the run still succeeds): another PostgresBackupLocation on a registered cluster uses the repository, or a cluster could not be scanned (an error other than NotFound counts as not scanned), found at the start or again right before the blobs. The backups were expired and the blobs were kept | The warning names the other locations or the clusters; delete the blobs by hand once nothing uses them |
| `POSTGRES_SKIPPED` | tpg-delete-apps (warning): a live Postgres is not in the namespace of its `fleet.yaml` entry or audit copy and was left alone | The warning says which case it is. Nothing records another namespace for the name and it runs in one namespace only: select it with `tpg-instances:<instance>`. The entry or the audit copy names another namespace, or the name runs in two namespaces: the selection cannot reach it (`NAMESPACE_MISMATCH`, `NAMESPACE_AMBIGUOUS`); delete it by hand in the namespace the warning names |
| `SKIPPED_VERSION_MISMATCH` | The `postgresVersion` key of `clusterMap` differs from the running version; the instance was left alone | The detail holds both versions |
| `FLEET_OVERRIDDEN` | tpg-day0: nothing ran on the target, so the input replaced the version declared in `fleet.yaml` | The detail holds the old value |
| `UPGRADE_REQUIRED`, `DOWNGRADE_NOT_ALLOWED`, `VERSION_UNKNOWN` | tpg-day0: the target runs another version (section 4) | tpg-upgrade, or the running operator and instances |
| `OVERLAY_REFUSED` | tpg-create-instance, tpg-day0 (Round 22; `PATCH_REFUSED` before): an overlay file holds a refused field or a second document for one object, or a `repo:` file is not on the fleet branch | The detail names the file, the field and the owning input |
| `APPLICATION_NOT_REMOVED` | tpg-delete-apps, tpg-delete-instance: the Application still exists after the wait. An Application whose source cannot be rendered (`ComparisonError`, for example the Broadcom registry token expired and the chart download answers 401) stays in `Deleting`; with `forceDeleteStuckApps=true` (default) the run logs the condition, removes the Argo CD finalizer and goes on (the result says `FORCED: Application removed without rendering (...)`); with `false` it fails here | Renew the registry token (tpg-rotate-credential), or re-run with `forceDeleteStuckApps=true`; the detail names the condition |
| `GIT_PUSH_FAILED` (step log line `GIT_MERGE_FAILED`) | Any workflow that writes `clusters/fleet.yaml` (Round 22): another run changed the same value differently, so the push could not be merged. Pushes are serialized by a lock (ConfigMap `tpg-run-fleet-lock` in `argo`; a holder older than 3 minutes is taken over) and a rejected push is merged key by key with the remote file instead of rebased as text | Re-run the workflow; two runs that change different keys never conflict |
| `PATCH_REFUSED` | tpg-patch: a file holds a refused field or a second document for one object, a `repo:` file is not on the fleet branch, a CA bundle source names an instance without `backup.enableSSL: true`, or the render or the server-side dry run failed on the target | The pre-check detail names the file, the field and the owning workflow; the step log holds the render error |
| `NO_CHANGE` | tpg-patch: the patch renders the objects that already run (no difference); nothing was committed or synced | The diff in the plan step log is empty |
| `PR_NOT_MERGED` | tpg-patch `pushMode=pr`: the pull request of the cluster was closed without merging, or not merged within `prTimeoutSeconds`; the cluster was synced back and the branch deleted | Run tpg-patch again and merge the pull request while the workflow waits |
| `OPERATION_IN_PROGRESS` | tpg-patch, tpg-scale-instance: an upgrade or a restore of the instance is still running; tpg-patch reverts the cluster | Run the workflow again when it has finished (`kubectl -n <namespace> get postgresversionupgrade,postgresrestore`) |
| `SKIPPED_NOT_PLANNED` | tpg-patch: the cluster was blocked in the plan, or none of its targets has a change | The pre-check of the cluster |
| `FLEET_ENTRY_INVALID` | tpg-upgrade: `clusters.<cluster>.operator.patches.values` is not `{current, previous}` (a fleet repository written before Round 15) | Start a Round 15 fleet from a new repository |
| `OVERLAY_USE_TPG_PATCH` | tpg-day0 (`PATCH_USE_TPG_PATCH` before Round 22): a running operator or instance would get other overlay files; an identical overlay is left alone | Change running objects with tpg-patch |
| `CA_BUNDLE_MISSING` | tpg-day0, tpg-create-instance: `backupEnableSSL=true` with no CA bundle source, or the commit found a bundle neither in the run record nor in `tpg-settings` | Section 15 |
| `WRAPPING_TOKEN_INVALID`, `VALUE_INVALID`, `VALUE_REJECTED` | tpg-rotate-credential: the new value could not be read or failed its check; nothing was written | Section 17 |
| `MERGED_CONTENT_DIFFERS` | tpg-patch `pushMode=pr`: after the merge the Application stays OutOfSync, so the fleet branch renders other objects than the ones synced from the pull request (changes made in the pull request, or merged with other commits); nothing was synced or reverted | Compare the pull request with the fleet branch; `argocd app diff <app>` |
| `GIT_PUSH_FAILED` | The commit or the branch could not be pushed, or the pull request not opened | The push token (`tpg/shared/github-push`), branch protection |
| `OPERATOR_IMAGE_PINNED` | tpg-upgrade: the current operator values patch sets `operatorImage` with a tag that is not the running version | Fix the file with tpg-patch first |
| `MAX_BELOW_CURRENT` | tpg-scale-instance: the new `maxReadReplicas` is below the read replicas of an instance of the cluster (in the validate step; in the plan when that instance's scale did not happen) | Scale the instances down in the same run, or choose a larger cap |
| `FOREIGN_OPERATOR`, `FOREIGN_CRD`, `INSTANCE_NAME_IN_USE` | tpg-day0, tpg-create-instance: an object the fleet's Applications do not manage (section 4) | `argocd app get tpg-<cluster>-operator` lists what the Application manages |
| `OPERATOR_NOT_INSTALLED`, `NOT_IN_FLEET` | tpg-create-instance: the cluster has no operator of the fleet, or `fleet.yaml` does not declare it | Run tpg-day0 for the cluster first |
| `INSTANCE_EXISTS` | tpg-create-instance: the instance runs with other values (section 5) | tpg-patch, tpg-scale-instance or tpg-upgrade |
| `RENDER_FAILED`, `DRY_RUN_REJECTED` | tpg-create-instance, tpg-network-policy: the chart cannot render the objects, or the API server refuses them in a server-side dry run | The detail holds the message |
| `SPEC_NOT_APPLIED` | tpg-scale-instance: the live `spec.highAvailability` does not match the request after the sync (and, for `replicas=0`, after the `tpg-scale` apply) | `kubectl -n <namespace> get postgres <instance> -o yaml --show-managed-fields` |
| `CA_BUNDLE_MISSING` | `backupEnableSSL=true` (or `backup.enableSSL: true`) and no CA bundle: no `backupCaBundleFile` or `backupCaBundleVaultSecret`, and `tpg-settings` has no `backupCaBundle` (at the plan), or at the commit a bundle in neither the run record nor `tpg-settings` | Section 15; `tpg-aks-infra/scripts/run.sh --only hub-secrets` writes the `tpg-settings` bundle |
| `CLUSTER_API_ERROR` | tpg-upgrade: a declared instance could not be read on the target (an error other than NotFound); tpg-day0 and tpg-create-instance pre-check: the Secret `regsecret` or `backup-storage` (or the VaultStaticSecret that owns it) could not be read in the namespace of an instance (an error other than NotFound) | The detail holds the API error; check the cluster's API server and its kubeconfig Secret |
| `AZURE_BACKUP_UNSUPPORTED` | The PostgresBackupLocation CRD on the target has no `spec.storage.azure` (or `caBundle`) | `kubectl explain postgresbackuplocation.spec.storage` on the target |
| `CILIUM_NOT_AVAILABLE`, `ACNS_NOT_ENABLED` | A network policy needs Cilium, or `egressToFqdns` needs ACNS | Terraform `acns_enabled = true`, then `run.sh --only hub-secrets` |
| `EXPOSURE_NOT_APPLIED` | The instance's Services did not reach the requested exposure (load balancer addresses) within 5 minutes | `kubectl -n <namespace> get svc`, the Service events (subnet, quota, annotations) |
| `FLEET_CHANGED_DURING_RUN` | tpg-day0, tpg-create-instance: `clusters/fleet.yaml` changed for that cluster between the plan and the commit; the plan was not written for it | Run again |
| `POLICY_NOT_APPLIED`, `POLICY_NOT_REMOVED`, `BACKUP_EGRESS_BLOCKED`, `CLIENT_BLOCKED`, `NOT_ISOLATED` | tpg-network-policy checks after the sync (section 9) | The detail; `kubectl -n <namespace> get networkpolicy,ciliumnetworkpolicy` |
| `INVALID_INPUT` (`highAvailability=true needs readReplicas 1 or more`) | tpg-day0, tpg-create-instance: an HA instance with 0 read replicas (D69) | Set `readReplicas`, or `highAvailability=false` for a single node |
| `INVALID_INPUT` (`readReplicas N needs highAvailability=true`) | tpg-day0, tpg-create-instance: read replicas for a single node, in the inputs or on one `clusterMap` entry | Set `highAvailability=true`, or remove `readReplicas` |
| `FERRET_VERSION_UNSUPPORTED`, `FERRET_CRD_MISSING` | FerretDB below Postgres 17.5, or an operator without the PostgresFerretDocumentDB CRD (section 4) | `postgresVersion`; `kubectl get crd postgresferretdocumentdbs.sql.tanzu.vmware.com` |
| `FERRET_SECRET_MISSING` | The connection Secret a FerretDB names does not exist 2 minutes after the instance runs | The detail lists the db Secrets of the instance's namespace; set `ferretSecretName` or `ferretReadOnlySecretName` |
| `FERRET_NOT_READY` | The FerretDB Deployments did not become available | `kubectl -n <namespace> get pods -l 'app in (ferretdb-rw-<instance>,ferretdb-ro-<instance>)'`; the documentdb extension |
| `FERRET_READONLY_NEEDS_HA` | tpg-scale-instance `replicas=0` while FerretDB runs read-only proxies | Set `ferret.readOnlyReplicas: 0` with a tpg-patch values file first |

A `BLOCKED` cluster or instance fails a tpg-day0, tpg-create-instance or tpg-network-policy run in its last step (`gate`), after the other targets were deployed, so a partial run never ends `Succeeded`.

Warnings do not fail a run. They are listed in the Warnings part of the report:

| Warning | Meaning |
|---|---|
| `MANUAL_SYNC_DETECTED` | The last operation on a tpg target Application was started by a named user other than `workflow-bot`, or was an automated sync. Section 21 explains why that is refused. The workflow syncs the Application itself at its commit and carries on |
| `BACKUP_REPO_SHARED` | tpg-delete-instance, tpg-delete-apps with `purgeBackups=true`: the blobs of the repository were kept because another backup location (or a cluster that could not be scanned) shares it |
| `BACKUP_EXPIRE_DECLINED` | `purgeBackups=true`, tpg-backup-expire with `purgeBackups`: pgBackRest declined to expire a backup (the operator's message is in the warning); the run goes on |
| `ORPHAN_CRD` | tpg-day0: Postgres CRDs exist without any operator; the operator sync adopts them |
| `HA_NODES_EXCEED_ZONES` | An HA instance has more database pods than its data pool has zones: Patroni does not fail over automatically when the zone of the leader and the synchronous standby is lost (section 4) |
| `EXPOSURE_UNRESTRICTED` | `loadBalancer` without `allowedSourceRanges`: port 5432 is open to the internet |
| `INSTANCE_NOT_DEPLOYED` | tpg-upgrade: an instance declared in `fleet.yaml` does not exist on the cluster and was left out (section 6) |
| `PROBE_NOT_RUN` | tpg-network-policy: a probe pod could not run; check that path by hand |
| `FERRET_EXTENSION_REQUIRED` | tpg-day0, tpg-create-instance, tpg-patch: FerretDB was switched on; it needs the documentdb extension in the instance, which the DBA prepares (section 4) |
| `HA_FIELD_CO_OWNED` | tpg-scale-instance `replicas=0`: `spec.highAvailability.enabled` stayed `true` after the sync because another field manager co-owns it; the step applied the single-node values as field manager `tpg-scale` (section 8) |
| `OVERLAY_OVERRIDES_VALUE` | tpg-create-instance, tpg-day0: a postgres overlay document sets a field that a chart value also sets, with another value; the document wins while it is current |
| `PATCH_OVERRIDES_VALUE` | tpg-patch: a postgres patch document sets a field that a chart value also sets, with another value; the document wins while it is current (section 7) |
| `OVERLAY_TARGET_NOT_RENDERED` | tpg-create-instance, tpg-day0: an overlay document targets an object the instance does not render now; it is kept and applies when the object is rendered |
| `PATCH_TARGET_NOT_RENDERED` | tpg-patch: a document patches an object the instance does not render now (a schedule without `backupSchedule=operator`, FerretDB off); it is kept and applies when the object is rendered |
| `GATEWAY_NOT_UPDATED` | tpg-rotate-credential `monitoring-remote-write`: run `tpg-aks-infra/scripts/run.sh --only addons` so the hub gateway accepts the new password (section 17) |

One line in the executor log is **not** an error, however it reads:

```text
level=INFO msg="saving parameter" argo=true src=/tmp/result dst=/var/run/argo/outputs/parameters//tmp/result
```

The Argo executor builds that destination as `/var/run/argo` +
`/outputs/parameters/` + the source path, so an absolute source path always
produces two slashes, and POSIX treats `//` inside a path as one separator. The
failure in such a log is the line above it (`sub-process exited ... exit status
1`): read the step's own `RESULT` line for what went wrong.

---

## 21. argocd CLI: inspect the sync steps behind the workflows

The workflows call the Argo CD API as the local account `workflow-bot`. Applications: `tpg-<cluster>-platform`, `tpg-<cluster>-operator`, `tpg-<cluster>-<instance>` (project `tpg`, the target Applications), and `tpg-hub-workflows` and `tpg-hub-monitoring` (project `tpg-hub`).

**Only the workflows sync the target Applications.** A sync started elsewhere would bypass the workflow gates: the pre-check, backups, the rollout order, the pod watch, and the revert of a failed patch. Three layers enforce this:

1. **Argo CD RBAC.** People are denied `sync` (which also covers rollback and terminating an operation), `override`, `update` and `delete` on `tpg/*`. `workflow-bot` (`role:tpg-sync`) may get and sync them, and read the Argo CD repositories (`repositories, get`; `tpg-rotate-credential` checks the connection state of `repo-tanzu-postgres-oci` and `repo-tpg-fleet`; without the line the step fails `RBAC_MISSING`). The deny lines are a marked block in `policy.csv` (`tpg-aks-infra argo/argocd-values.yaml`; on an existing hub, `scripts/hub/existing/check-argo.sh --yes` adds a line for every subject that could act on project `tpg`).
2. **Admission policy `tpg-application-sync`** on the hub. It refuses a new operation on a target Application unless argocd-server writes it for `workflow-bot`, and refuses switching on automated sync. It also covers a `kubectl edit` of the Application object, which Argo CD RBAC does not see. The Argo CD UI then shows `only the tpg workflows (Argo CD account workflow-bot) may sync tpg-...`.
3. **Detection.** Each workflow sync first checks who started the last operation on the Application, and reports `MANUAL_SYNC_DETECTED` (section 20) when a named user other than `workflow-bot` started it, or when it was an automated sync.

The hub Applications in project `tpg-hub` stay manageable. There is no break-glass role: fix the cause in Git and rerun the workflow.

```bash
# What exists and its state
argocd app list -l tpg.fleet/cluster=aks-tpg-poc-01
argocd app list -l tpg.fleet/component=operator
argocd app get tpg-aks-tpg-poc-01-orders-db --show-operation
argocd appset get tpg-instances
argocd cluster list

# Who started the last operation (workflow-bot, or workflow-bot:apiKey for its token)
argocd app get tpg-aks-tpg-poc-01-orders-db -o json | jq -r '.status.operationState.operation.initiatedBy'

# Hub workflows (templates, scripts, RBAC, admission policies) after a change in Git: project tpg-hub, allowed
argocd app get tpg-hub-workflows --refresh
argocd app sync tpg-hub-workflows && argocd app wait tpg-hub-workflows --health --timeout 300

# Regenerate Applications right after a fleet.yaml commit (same as the workflows; not a sync)
kubectl -n argocd annotate applicationset tpg-instances argocd.argoproj.io/application-set-refresh=true --overwrite
kubectl -n argocd annotate applicationset tpg-operator argocd.argoproj.io/application-set-refresh=true --overwrite

# Operator upgrade check: the rendered chart version and the fleet value file after the fleet.yaml commit
argocd app get tpg-aks-tpg-poc-01-operator -o json | jq '.spec.sources'
argocd app diff tpg-aks-tpg-poc-01-operator

# tpg-patch with pushMode=pr: the commit each Application was last synced at (the
# pull request branch until the merge), and the source revisions of the operator
argocd app history tpg-aks-tpg-poc-02-orders-db
argocd app get tpg-aks-tpg-poc-01-operator -o json | jq '.status.history[-1].revisions'

# Scale or patch check: the Postgres spec Argo CD will apply
argocd app manifests tpg-aks-tpg-poc-02-orders-db --source git | yq 'select(.kind == "Postgres") | .spec'

# The operator's CRDs and Deployment, which the workflows check directly before hard-refreshing
kubectl --context aks-tpg-poc-01 get crd postgres.sql.tanzu.vmware.com -o jsonpath='{.status.conditions[?(@.type=="Established")].status}'
kubectl --context aks-tpg-poc-01 -n tanzu-postgres-operator get deploy

# Troubleshooting a failed sync (read-only)
argocd app get tpg-aks-tpg-poc-01-orders-db --hard-refresh
argocd app history tpg-aks-tpg-poc-01-orders-db
argocd repo list

# These are refused for people on tpg/* (RBAC, then the admission policy)
#   argocd app sync tpg-aks-tpg-poc-01-orders-db        -> permission denied
#   argocd app rollback tpg-aks-tpg-poc-01-orders-db 3  -> permission denied
#   argocd app terminate-op tpg-aks-tpg-poc-01-orders-db
#   argocd app set tpg-aks-tpg-poc-01-orders-db --sync-policy automated
```

The delete workflows remove target Applications by removing their `clusters/fleet.yaml` entries (the ApplicationSet deletes the Application without cascade) and delete database objects in order; `argocd app delete` is refused for people.
